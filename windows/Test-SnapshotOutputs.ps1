<#
.SYNOPSIS
Validate Export-PartAssets output directories semantically, and self-test the validator with
synthetic good/bad manifests. Offline; no Inventor or Vault access.

    & .\windows\Test-SnapshotOutputs.ps1 -SelfTest
    & .\windows\Test-SnapshotOutputs.ps1 -Directory <run>\part-assets-strict -ExpectParts 37 -ExpectOccurrences 155 -VerifyHashes
#>
param([string[]]$Directory = @(), [int]$ExpectParts = -1, [int]$ExpectOccurrences = -1, [switch]$VerifyHashes, [switch]$SelfTest)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Snapshot-Validation.ps1")
$passed = 0; $failed = 0
function Report($name, $ok, $detail) { if ($ok) { $script:passed++; Write-Output "PASS $name $detail" } else { $script:failed++; Write-Output "FAIL $name $detail" } }
if ($SelfTest) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("vault-cad-snapshot-test-" + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $I = @(@(1,0,0,0),@(0,1,0,0),@(0,0,1,0),@(0,0,0,1))
        $scene = [ordered]@{ schema_version = "draft-1"; parts = @(@{ id = "p1"; asset = @{ path = "assets/p1.step"; sha256 = "0" * 64 } }, @{ id = "p2"; asset = @{ path = "assets/p2.step"; sha256 = "1" * 64 } }); assemblies = @(@{ id = "root"; parent_id = $null; transform = $I }, @{ id = "g1"; parent_id = "root"; transform = $I }); occurrences = @(@{ id = "o1"; part_id = "p1"; parent_id = "root"; transform = $I }, @{ id = "o2"; part_id = "p2"; parent_id = "g1"; transform = $I }, @{ id = "o3"; part_id = "p2"; parent_id = "g1"; transform = $I }) }
        $inventory = [ordered]@{ items = @(@{ part_id = "p1"; cad_instances = 1; required = $null; counted = $null }, @{ part_id = "p2"; cad_instances = 2; required = $null; counted = $null }) }
        $snapshot = [ordered]@{ counts = @{ distinct_parts = 2; leaf_occurrences = 3 } }
        function Write-Case($name, $sceneObj, $invObj, $snapObj, [string]$rawInventory) {
            $d = Join-Path $root $name; New-Item -ItemType Directory -Path $d | Out-Null
            $sceneObj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $d "scene.json") -Encoding UTF8
            if ($rawInventory) { $rawInventory | Set-Content (Join-Path $d "inventory-raw.json") -Encoding UTF8 } else { $invObj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $d "inventory-raw.json") -Encoding UTF8 }
            $snapObj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $d "native-snapshot.json") -Encoding UTF8
            return $d
        }
        $good = Write-Case "good" $scene $inventory $snapshot $null
        $r = Test-SnapshotOutputs -Directory $good -ExpectParts 2 -ExpectOccurrences 3; Report "self good manifests" $r.ok "$($r.summary | ConvertTo-Json -Compress) $($r.failures -join '; ')"
        $r = Test-SnapshotOutputs -Directory (Write-Case "scalar" $scene $inventory $snapshot '"System.Collections.Specialized.OrderedDictionary"'); Report "self scalar inventory rejected" (-not $r.ok -and ($r.failures -join ';') -match "not a JSON object") ($r.failures -join '; ')
        $r = Test-SnapshotOutputs -Directory (Write-Case "truncated" $scene $inventory $snapshot '{"items": [{"part_id": "p1", "cad_inst'); Report "self truncated inventory rejected" (-not $r.ok -and ($r.failures -join ';') -match "does not parse") ($r.failures -join '; ')
        $dup = [ordered]@{ items = @($inventory.items[0], $inventory.items[0], $inventory.items[1]) }
        $r = Test-SnapshotOutputs -Directory (Write-Case "duplicate" $scene $dup $snapshot $null); Report "self duplicate item rejected" (-not $r.ok -and ($r.failures -join ';') -match "duplicate inventory part_id") ($r.failures -join '; ')
        $missing = [ordered]@{ items = @($inventory.items[0]) }
        $r = Test-SnapshotOutputs -Directory (Write-Case "missing" $scene $missing $snapshot $null); Report "self missing item rejected" (-not $r.ok -and ($r.failures -join ';') -match "missing from inventory") ($r.failures -join '; ')
        $wrongCount = [ordered]@{ items = @($inventory.items[0], @{ part_id = "p2"; cad_instances = 5; required = $null; counted = $null }) }
        $r = Test-SnapshotOutputs -Directory (Write-Case "count" $scene $wrongCount $snapshot $null); Report "self instance count mismatch rejected" (-not $r.ok -and ($r.failures -join ';') -match "differs from 2 scene occurrences") ($r.failures -join '; ')
        $stock = [ordered]@{ items = @($inventory.items[0], @{ part_id = "p2"; cad_instances = 2; required = 2; counted = $null }) }
        $r = Test-SnapshotOutputs -Directory (Write-Case "stock" $scene $stock $snapshot $null); Report "self claimed stock quantity rejected" (-not $r.ok -and ($r.failures -join ';') -match "claims stock") ($r.failures -join '; ')
        $badScene = [ordered]@{ schema_version = "draft-1"; parts = $scene.parts; assemblies = $scene.assemblies; occurrences = @(@{ id = "o1"; part_id = "nope"; parent_id = "root"; transform = $I }) }
        $r = Test-SnapshotOutputs -Directory (Write-Case "badref" $badScene $inventory $snapshot $null); Report "self unknown part reference rejected" (-not $r.ok -and ($r.failures -join ';') -match "unknown part") ($r.failures -join '; ')
        $cycle = [ordered]@{ schema_version = "draft-1"; parts = $scene.parts; assemblies = @(@{ id = "root"; parent_id = $null; transform = $I }, @{ id = "g1"; parent_id = "g2"; transform = $I }, @{ id = "g2"; parent_id = "g1"; transform = $I }); occurrences = $scene.occurrences }
        $r = Test-SnapshotOutputs -Directory (Write-Case "cycle" $cycle $inventory $snapshot $null); Report "self parent cycle rejected (groups and their occurrences)" (-not $r.ok -and ($r.failures -join ';') -match "assembly 'g1' does not reach 'root'" -and ($r.failures -join ';') -match "assembly 'g2' does not reach 'root'" -and ($r.failures -join ';') -match "occurrence 'o2' hangs on group 'g1'") ($r.failures -join '; ')
        $selfParent = [ordered]@{ schema_version = "draft-1"; parts = $scene.parts; assemblies = @(@{ id = "root"; parent_id = $null; transform = $I }, @{ id = "g1"; parent_id = "g1"; transform = $I }); occurrences = $scene.occurrences }
        $r = Test-SnapshotOutputs -Directory (Write-Case "selfparent" $selfParent $inventory $snapshot $null); Report "self self-parented group rejected" (-not $r.ok -and ($r.failures -join ';') -match "assembly 'g1' does not reach 'root'") ($r.failures -join '; ')
        $r = Test-SnapshotOutputs -Directory (Write-Case "expect" $scene $inventory $snapshot $null) -ExpectParts 37; Report "self expectation mismatch rejected" (-not $r.ok -and ($r.failures -join ';') -match "expected 37 parts") ($r.failures -join '; ')
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}
foreach ($d in $Directory) {
    $r = Test-SnapshotOutputs -Directory $d -ExpectParts $ExpectParts -ExpectOccurrences $ExpectOccurrences -VerifyHashes:$VerifyHashes
    Report "directory $d" $r.ok "$($r.summary | ConvertTo-Json -Compress) $(if ($r.failures) { '| ' + ($r.failures -join '; ') })"
}
Write-Output "$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
