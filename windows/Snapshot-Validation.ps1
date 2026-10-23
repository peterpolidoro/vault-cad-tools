<#
.SYNOPSIS
Semantic validation of an Export-PartAssets output directory (scene.json, inventory-raw.json,
native-snapshot.json, export-receipt.json). Used by the exporter before it may declare a run
complete, and by Test-SnapshotOutputs.ps1.

.DESCRIPTION
    . (Join-Path $PSScriptRoot "Snapshot-Validation.ps1")
    $r = Test-SnapshotOutputs -Directory $dir [-ExpectParts 37] [-ExpectOccurrences 155] [-VerifyHashes]
    $r.ok, $r.failures (string[]), $r.summary

Checks: each JSON file parses to an OBJECT (a bare string such as the serialized type name of a
PowerShell variable is a failure); inventory has an items array whose entries carry a non-empty
part_id, an integer cad_instances >= 1 and null required/counted (unknown stock); part ids are
unique and identical between inventory and scene; scene occurrences reference known parts and
parent groups; every group reaches "root" through parent links without a cycle (a parent that
merely exists is not enough) and no occurrence hangs on a disconnected group; transforms are 4x4 numeric with last
row [0,0,0,1]; per-part cad_instances equal the number of scene occurrences of that part; totals
match native-snapshot counts and the optional expectations; a receipt marked complete must list
every asset referenced by the scene and, with -VerifyHashes, every listed file must hash as recorded.
#>
function Test-SnapshotOutputs {
    param([Parameter(Mandatory = $true)][string]$Directory, [int]$ExpectParts = -1, [int]$ExpectOccurrences = -1, [switch]$VerifyHashes)
    $failures = @(); $summary = [ordered]@{}
    function Read-JsonObject($name) {
        $p = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $p)) { return @{ ok = $false; error = "$name missing" } }
        try { $o = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { return @{ ok = $false; error = "$name does not parse: $($_.Exception.Message)" } }
        if ($null -eq $o -or $o -is [string] -or $o -is [ValueType] -or $o -is [array]) { return @{ ok = $false; error = "$name is not a JSON object (got $(if ($null -eq $o) { 'null' } else { $o.GetType().Name }): '$([string]$o)')" } }
        return @{ ok = $true; value = $o }
    }
    $scene = Read-JsonObject "scene.json"; $inv = Read-JsonObject "inventory-raw.json"; $snap = Read-JsonObject "native-snapshot.json"
    foreach ($r in @($scene, $inv, $snap)) { if (-not $r.ok) { $failures += $r.error } }
    if ($failures.Count -gt 0) { return [ordered]@{ ok = $false; failures = $failures; summary = $summary } }
    $scene = $scene.value; $inv = $inv.value; $snap = $snap.value
    if ($null -eq $inv.items -or $inv.items -isnot [array]) { $failures += "inventory-raw.json: items is not an array" }
    if ($null -eq $scene.parts -or $scene.parts -isnot [array]) { $failures += "scene.json: parts is not an array" }
    if ($null -eq $scene.occurrences -or $scene.occurrences -isnot [array]) { $failures += "scene.json: occurrences is not an array" }
    if ($null -eq $scene.assemblies -or $scene.assemblies -isnot [array]) { $failures += "scene.json: assemblies is not an array" }
    if ($failures.Count -gt 0) { return [ordered]@{ ok = $false; failures = $failures; summary = $summary } }
    $partIds = @{}; foreach ($p in $scene.parts) { $id = [string]$p.id; if (-not $id) { $failures += "scene part without id" } elseif ($partIds.ContainsKey($id)) { $failures += "duplicate scene part id '$id'" } else { $partIds[$id] = $p } }
    $groupIds = @{}; foreach ($g in $scene.assemblies) { $id = [string]$g.id; if (-not $id) { $failures += "assembly without id" } elseif ($groupIds.ContainsKey($id)) { $failures += "duplicate assembly id '$id'" } else { $groupIds[$id] = $g } }
    if (-not $groupIds.ContainsKey("root")) { $failures += "no 'root' assembly" }
    foreach ($g in $scene.assemblies) { if ([string]$g.id -eq "root") { if ($null -ne $g.parent_id) { $failures += "root has a parent" } } elseif (-not $g.parent_id -or -not $groupIds.ContainsKey([string]$g.parent_id)) { $failures += "assembly '$($g.id)' parent '$($g.parent_id)' unknown" } }
    # Connectivity: parent existence is not enough; every group must reach "root" through parent links without a cycle.
    function Test-ReachesRoot($id) {
        $visited = @{}; $cur = [string]$id
        while ($true) {
            if ($cur -eq "root") { return $true }
            if (-not $cur -or $visited.ContainsKey($cur) -or -not $groupIds.ContainsKey($cur)) { return $false }
            $visited[$cur] = $true
            $cur = [string]$groupIds[$cur].parent_id
        }
    }
    $reachesRoot = @{}
    foreach ($g in $scene.assemblies) { $id = [string]$g.id; if (-not $id -or $reachesRoot.ContainsKey($id)) { continue }; $reachesRoot[$id] = (Test-ReachesRoot $id); if (-not $reachesRoot[$id]) { $failures += "assembly '$id' does not reach 'root' (cycle or broken parent chain)" } }
    function Test-Matrix($m, $what) {
        if ($null -eq $m -or $m.Count -ne 4) { return "$what transform is not 4 rows" }
        for ($i = 0; $i -lt 4; $i++) { $row = $m[$i]; if ($null -eq $row -or $row.Count -ne 4) { return "$what transform row $i is not 4 cells" }; foreach ($v in $row) { if ($v -isnot [ValueType]) { return "$what transform has a non-numeric cell" } } }
        $last = $m[3]; if ([double]$last[0] -ne 0 -or [double]$last[1] -ne 0 -or [double]$last[2] -ne 0 -or [double]$last[3] -ne 1) { return "$what transform last row is not [0,0,0,1]" }
        return $null
    }
    foreach ($g in $scene.assemblies) { $e = Test-Matrix $g.transform "assembly '$($g.id)'"; if ($e) { $failures += $e }; foreach ($k in "suppressed", "mirrored") { if (-not ($g.PSObject.Properties.Name -contains $k)) { $failures += "assembly '$($g.id)' lacks explicit '$k'" } } }
    $occPerPart = @{}; $occIds = @{}
    foreach ($o in $scene.occurrences) {
        $id = [string]$o.id; if (-not $id) { $failures += "occurrence without id"; continue }
        if ($occIds.ContainsKey($id)) { $failures += "duplicate occurrence id '$id'" } else { $occIds[$id] = $true }
        if (-not $partIds.ContainsKey([string]$o.part_id)) { $failures += "occurrence '$id' references unknown part '$($o.part_id)'" }
        if (-not $groupIds.ContainsKey([string]$o.parent_id)) { $failures += "occurrence '$id' references unknown parent '$($o.parent_id)'" } elseif (-not $reachesRoot[[string]$o.parent_id]) { $failures += "occurrence '$id' hangs on group '$($o.parent_id)' that does not reach 'root'" }
        $e = Test-Matrix $o.transform "occurrence '$id'"; if ($e) { $failures += $e }
        # The scene contract keeps suppressed/mirrored EXPLICIT on every occurrence (the accepted baseline has them as false).
        foreach ($flag in "suppressed", "mirrored") { if (-not ($o.PSObject.Properties.Name -contains $flag)) { $failures += "occurrence '$id' lacks explicit '$flag'" } }
        $k = [string]$o.part_id; if (-not $occPerPart.ContainsKey($k)) { $occPerPart[$k] = 0 }; $occPerPart[$k]++
    }
    $invIds = @{}; $sumInstances = 0
    foreach ($it in $inv.items) {
        $id = [string]$it.part_id
        if (-not $id) { $failures += "inventory item without part_id"; continue }
        if ($invIds.ContainsKey($id)) { $failures += "duplicate inventory part_id '$id'" } else { $invIds[$id] = $true }
        if (-not $partIds.ContainsKey($id)) { $failures += "inventory part_id '$id' not in scene parts" }
        $n = $it.cad_instances
        if ($n -isnot [ValueType] -or [double]$n -ne [Math]::Floor([double]$n) -or [double]$n -lt 1) { $failures += "inventory item '$id' cad_instances '$n' is not an integer >= 1" } else { $sumInstances += [int]$n }
        if ($partIds.ContainsKey($id) -and $occPerPart.ContainsKey($id) -and [int]$n -ne $occPerPart[$id]) { $failures += "inventory item '$id' cad_instances $n differs from $($occPerPart[$id]) scene occurrences" }
        if ($null -ne $it.required -or $null -ne $it.counted) { $failures += "inventory item '$id' claims stock quantities (required/counted must be null)" }
    }
    foreach ($id in $partIds.Keys) { if (-not $invIds.ContainsKey($id)) { $failures += "scene part '$id' missing from inventory" } }
    $summary.parts = $partIds.Count; $summary.inventory_items = $invIds.Count; $summary.occurrences = $occIds.Count; $summary.inventory_instances = $sumInstances; $summary.assemblies = $groupIds.Count
    if ($sumInstances -ne $occIds.Count) { $failures += "inventory instances $sumInstances != scene occurrences $($occIds.Count)" }
    if ($snap.counts) { if ([int]$snap.counts.distinct_parts -ne $partIds.Count) { $failures += "native-snapshot distinct_parts $($snap.counts.distinct_parts) != scene parts $($partIds.Count)" }; if ([int]$snap.counts.leaf_occurrences -ne $occIds.Count) { $failures += "native-snapshot leaf_occurrences $($snap.counts.leaf_occurrences) != scene occurrences $($occIds.Count)" } } else { $failures += "native-snapshot.json has no counts" }
    if ($ExpectParts -ge 0 -and $partIds.Count -ne $ExpectParts) { $failures += "expected $ExpectParts parts, found $($partIds.Count)" }
    if ($ExpectOccurrences -ge 0 -and $occIds.Count -ne $ExpectOccurrences) { $failures += "expected $ExpectOccurrences occurrences, found $($occIds.Count)" }
    $receiptPath = Join-Path $Directory "export-receipt.json"
    if (Test-Path -LiteralPath $receiptPath) {
        $rr = Read-JsonObject "export-receipt.json"
        if (-not $rr.ok) { $failures += $rr.error } else {
            $receipt = $rr.value; $summary.receipt_status = $receipt.status
            $listed = @{}; foreach ($prop in $receipt.files.PSObject.Properties) { $listed[$prop.Name] = $prop.Value }
            foreach ($p in $scene.parts) { $ap = [string]$p.asset.path; if (-not $listed.ContainsKey($ap)) { $failures += "receipt does not list asset '$ap'" } elseif ($VerifyHashes) { $f = Join-Path $Directory ($ap -replace '/', '\'); if (-not (Test-Path -LiteralPath $f)) { $failures += "asset file missing: $ap" } elseif ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$listed[$ap].sha256) { $failures += "asset hash mismatch: $ap" } elseif ([string]$p.asset.sha256 -ne [string]$listed[$ap].sha256) { $failures += "scene/receipt hash disagreement: $ap" } } }
            foreach ($n in "scene.json", "inventory-raw.json", "native-snapshot.json") { if (-not $listed.ContainsKey($n)) { $failures += "receipt does not list $n" } elseif ($VerifyHashes -and (Get-FileHash -LiteralPath (Join-Path $Directory $n) -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$listed[$n].sha256) { $failures += "receipt hash mismatch: $n" } }
            if ([string]$receipt.status -eq "complete" -and $failures.Count -gt 0) { $failures += "receipt status is 'complete' although validation failed" }
        }
    }
    [ordered]@{ ok = ($failures.Count -eq 0); failures = $failures; summary = $summary }
}
