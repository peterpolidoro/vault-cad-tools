<#
.SYNOPSIS
Read-only Vault facts for every file of an acquisition record: is the acquired version still the latest, and
what do revision, lifecycle and check-out state say today? REST GET only.

.DESCRIPTION
    . .\windows\Set-VaultCadToken.ps1            # Windows-authenticated session token, process only (the one POST)
    & .\windows\Get-VaultFileFacts.ps1 -Acquisition acquisition.json -Inventory dependency-inventory.json `
        -OutputDirectory NEW -BaseUri http://SERVER/AutodeskDM/Services/api/vault/v2/ -VaultId ID

For every master id in the acquisition record this issues GET files/{master}/versions (paged) and GET
file-versions/{id} for the latest version (and for the acquired version when it is no longer the latest). It
records, per file: the acquired version id and number, the latest version id and number, whether anything
changed since the acquisition, revision, lifecycle definition and state, check-in date and whether the file is
checked out, each beside the value the dependency inventory recorded on the acquisition day. A value the server
did not return is null, never a guess; a file whose versions cannot be read is "unknown", never "unchanged".
It also lists the property system names the server returns for a file version, WITHOUT their values.

Outputs: vault-file-facts.json, vault-file-facts.csv, property-system-names.json, vault-file-facts-receipt.json
(status, counts, the GET count, failures) and raw\ (the responses as received; they contain property values).
Nothing is written to Vault; no request other than GET is sent by this script.
    & .\windows\Get-VaultFileFacts.ps1 -SelfTest      # offline cases for the joining logic
#>
param(
    [string]$Acquisition,
    [string]$Inventory,
    [string]$OutputDirectory,
    [string]$BaseUri,
    [string]$VaultId,
    [ValidateRange(1, 1000)][int]$PageLimit = 1000,
    [switch]$SelfTest
)
$ErrorActionPreference = "Stop"

function Get-PropertyValue($Record, [string]$SystemName) {
    # Value of an inline property by its system name; $null when the record or the property is absent.
    if ($null -eq $Record -or $null -eq $Record.properties) { return $null }
    foreach ($property in @($Record.properties)) { if ($property.definition -and [string]$property.definition.systemName -eq $SystemName) { return $property.value } }
    return $null
}
function Get-Field($Record, [string]$Name) { if ($null -eq $Record) { return $null }; $member = $Record.PSObject.Properties[$Name]; if ($member) { return $member.Value }; return $null }

function Resolve-FileFact {
    <# Pure join of one acquisition record with what the server returned. $Versions is the list from
       files/{master}/versions ($null when unreadable), $LatestRecord / $AcquiredRecord are file-version records. #>
    param($AcquisitionRecord, $InventoryRecord, $Versions, $LatestRecord, $AcquiredRecord)
    $problems = @()
    $fact = [ordered]@{ master_id = [string]$AcquisitionRecord.master_id; name = ([string]$AcquisitionRecord.vault_path).Split('/')[-1]; vault_path = [string]$AcquisitionRecord.vault_path
        acquired_version_id = [string]$AcquisitionRecord.version_id; acquired_version_number = $null; acquired_native_sha256 = Get-Field $AcquisitionRecord "sha256"
        latest_version_id = $null; latest_version_number = $null; versions_total = $null; changed_since_acquisition = $null
        revision = $null; lifecycle_definition = $null; lifecycle_state = $null; checkin_date = $null; is_checked_out = $null; is_hidden = $null; category = $null
        acquired_version = $null; inventory = $null; differs_from_inventory = @(); problems = @() }
    if ($InventoryRecord) {
        $fact.inventory = [ordered]@{ version_id = [string](Get-Field $InventoryRecord "version_id"); version = Get-Field $InventoryRecord "version"; revision = Get-Field $InventoryRecord "revision"; state = Get-Field $InventoryRecord "state"
            checkin_date = Get-Field $InventoryRecord "checkin_date"; is_checked_out = Get-Field $InventoryRecord "is_checked_out" }
        if ($fact.inventory.version_id -ne $fact.acquired_version_id) { $problems += "inventory version id $($fact.inventory.version_id) is not the acquired version id $($fact.acquired_version_id)" }
    } else { $problems += "no inventory record for this master" }
    $list = @($Versions | Where-Object { $null -ne $_ })
    if ($null -eq $Versions -or $list.Count -eq 0) {
        $problems += "versions of master $($fact.master_id) could not be read"
        $fact.problems = $problems; return $fact
    }
    $fact.versions_total = $list.Count
    $latest = $list | Sort-Object { [int]$_.version } | Select-Object -Last 1
    $fact.latest_version_id = [string]$latest.id; $fact.latest_version_number = [int]$latest.version
    $acquired = @($list | Where-Object { [string]$_.id -eq $fact.acquired_version_id })
    if ($acquired.Count -eq 1) { $fact.acquired_version_number = [int]$acquired[0].version } else { $problems += "the acquired version id $($fact.acquired_version_id) is not among the versions of master $($fact.master_id)" }
    $fact.changed_since_acquisition = ($fact.latest_version_id -ne $fact.acquired_version_id)
    $record = $(if ($LatestRecord) { $LatestRecord } else { $latest })
    if (-not $LatestRecord) { $problems += "latest version record $($fact.latest_version_id) could not be read; values come from the version list" }
    elseif ([string]$LatestRecord.id -ne $fact.latest_version_id) { $problems += "latest version record has id $($LatestRecord.id), expected $($fact.latest_version_id)"; $record = $latest }
    $fact.revision = Get-Field $record "revision"; $fact.lifecycle_state = Get-Field $record "state"; $fact.checkin_date = Get-Field $record "checkinDate"
    $fact.is_checked_out = Get-Field $record "isCheckedOut"; $fact.is_hidden = Get-Field $record "isHidden"; $fact.category = Get-Field $record "category"
    $fact.lifecycle_definition = Get-PropertyValue $record "LifeCycleDefinition"
    if ($fact.changed_since_acquisition) {
        $old = $(if ($AcquiredRecord) { $AcquiredRecord } elseif ($acquired.Count -eq 1) { $acquired[0] } else { $null })
        if ($old) { $fact.acquired_version = [ordered]@{ revision = Get-Field $old "revision"; lifecycle_state = Get-Field $old "state"; checkin_date = Get-Field $old "checkinDate"; lifecycle_definition = Get-PropertyValue $old "LifeCycleDefinition" } }
    }
    if ($fact.inventory) {
        $differs = @()
        if ($null -ne $fact.inventory.version -and $null -ne $fact.latest_version_number -and [int]$fact.inventory.version -ne $fact.latest_version_number) { $differs += "version" }
        if ([string]$fact.inventory.revision -ne [string]$fact.revision) { $differs += "revision" }
        if ([string]$fact.inventory.state -ne [string]$fact.lifecycle_state) { $differs += "lifecycle_state" }
        if ($null -ne $fact.inventory.is_checked_out -and $null -ne $fact.is_checked_out -and [bool]$fact.inventory.is_checked_out -ne [bool]$fact.is_checked_out) { $differs += "is_checked_out" }
        $then = $null; $now = $null
        try { $then = [DateTimeOffset]::Parse([string]$fact.inventory.checkin_date, [Globalization.CultureInfo]::InvariantCulture) } catch { }
        try { $now = [DateTimeOffset]::Parse([string]$fact.checkin_date, [Globalization.CultureInfo]::InvariantCulture) } catch { }
        if ($null -eq $then -or $null -eq $now) { if ([string]$fact.inventory.checkin_date -ne [string]$fact.checkin_date) { $differs += "checkin_date" } } elseif ($then -ne $now) { $differs += "checkin_date" }
        $fact.differs_from_inventory = $differs
    }
    $fact.problems = $problems
    return $fact
}

if ($SelfTest) {
    $results = @()
    function Case($name, [scriptblock]$body) {
        try { $detail = & $body; $script:results += [ordered]@{ case = $name; passed = $true; detail = "$detail" }; Write-Output "PASS $name $(if ($detail) { "- $detail" })" }
        catch { $script:results += [ordered]@{ case = $name; passed = $false; detail = $_.Exception.Message }; Write-Output "FAIL $name - $($_.Exception.Message)" }
    }
    function Assert($cond, $msg) { if (-not $cond) { throw $msg } }
    function Version($id, $number, $state, $revision, $date, $out) { [pscustomobject]@{ id = "$id"; version = $number; state = $state; revision = $revision; checkinDate = $date; isCheckedOut = $out; isHidden = $false; category = "MCAD Files"
        properties = @([pscustomobject]@{ value = "Flexible Release"; definition = [pscustomobject]@{ systemName = "LifeCycleDefinition" } }, [pscustomobject]@{ value = "secret"; definition = [pscustomobject]@{ systemName = "Comment" } }) } }
    $acq = [pscustomobject]@{ master_id = "100"; version_id = "105"; vault_path = '$/A/B/PLATE.ipt'; sha256 = "ab" }
    $inv = [pscustomobject]@{ version_id = "105"; version = 2; revision = "0"; state = "Work in Progress"; checkin_date = "2026-09-10T19:50:08.36Z"; is_checked_out = $false }
    $v1 = Version 101 1 "Work in Progress" "0" "2026-08-01T00:00:00Z" $false
    $v2 = Version 105 2 "Work in Progress" "0" "2026-09-10T19:50:08.360Z" $false
    $v3 = Version 110 3 "Released" "A" "2026-11-01T00:00:00Z" $false
    Case "F1 unchanged: latest is the acquired version, nothing differs from the inventory (date formats may differ)" {
        $f = Resolve-FileFact $acq $inv @($v1, $v2) $v2 $null
        Assert ($f.changed_since_acquisition -eq $false -and $f.latest_version_id -eq "105" -and $f.latest_version_number -eq 2 -and $f.acquired_version_number -eq 2 -and $f.versions_total -eq 2) "ids: $($f | ConvertTo-Json -Compress -Depth 4)"
        Assert (@($f.differs_from_inventory).Count -eq 0 -and @($f.problems).Count -eq 0 -and $f.lifecycle_definition -eq "Flexible Release" -and $f.name -eq "PLATE.ipt") "differs/problems: $($f | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "F2 a newer version exists: changed, with the acquired version's values kept beside the latest" {
        $f = Resolve-FileFact $acq $inv @($v3, $v1, $v2) $v3 $v2
        Assert ($f.changed_since_acquisition -eq $true -and $f.latest_version_id -eq "110" -and $f.latest_version_number -eq 3 -and $f.revision -eq "A" -and $f.lifecycle_state -eq "Released") "latest: $($f | ConvertTo-Json -Compress -Depth 4)"
        Assert ($f.acquired_version.revision -eq "0" -and $f.acquired_version.lifecycle_state -eq "Work in Progress" -and (@($f.differs_from_inventory) -join ',') -eq "version,revision,lifecycle_state,checkin_date") "acquired/differs: $($f | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "F3 checked out today on the same version: not a new version, but it differs from the inventory" {
        $out = Version 105 2 "Work in Progress" "0" "2026-09-10T19:50:08.36Z" $true
        $f = Resolve-FileFact $acq $inv @($v1, $out) $out $null
        Assert ($f.changed_since_acquisition -eq $false -and $f.is_checked_out -eq $true -and (@($f.differs_from_inventory) -join ',') -eq "is_checked_out") "state: $($f | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "F4 versions unreadable: unknown (null), never 'unchanged'" {
        $f = Resolve-FileFact $acq $inv $null $null $null
        Assert ($null -eq $f.changed_since_acquisition -and $null -eq $f.latest_version_id -and $null -eq $f.revision -and (@($f.problems) -join ';') -match 'could not be read') "state: $($f | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "F5 the acquired version id is missing from the server's list: reported as a problem" {
        $f = Resolve-FileFact $acq $inv @($v1, $v3) $v3 $null
        Assert ($f.changed_since_acquisition -eq $true -and $null -eq $f.acquired_version_number -and (@($f.problems) -join ';') -match 'not among the versions') "state: $($f | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "F6 no inventory record and no latest record: values from the version list, both reported" {
        $f = Resolve-FileFact $acq $null @($v1, $v2) $null $null
        Assert ($null -eq $f.inventory -and $f.lifecycle_state -eq "Work in Progress" -and (@($f.problems) -join ';') -match 'no inventory record' -and (@($f.problems) -join ';') -match 'could not be read') "state: $($f | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "F7 a property the server did not return is null, and property values never leak into the fact" {
        $bare = [pscustomobject]@{ id = "105"; version = 2; state = "Work in Progress"; revision = "0"; checkinDate = "2026-09-10T19:50:08.36Z"; isCheckedOut = $false }
        $f = Resolve-FileFact $acq $inv @($bare) $bare $null
        Assert ($null -eq $f.lifecycle_definition -and $null -eq $f.is_hidden -and ($f | ConvertTo-Json -Compress -Depth 4) -notmatch 'secret') "state: $($f | ConvertTo-Json -Compress -Depth 4)"
    }
    $passed = @($results | Where-Object passed).Count; $failed = @($results | Where-Object { -not $_.passed }).Count
    Write-Output "$passed passed, $failed failed"
    if ($failed -gt 0) { exit 1 }
    return
}

foreach ($required in @("Acquisition", "Inventory", "OutputDirectory", "BaseUri", "VaultId")) { if (-not (Get-Variable -Name $required -ValueOnly)) { throw "-$required is required" } }
# The bearer token must not travel through an ambient HTTP proxy: disable proxies for this process (P4).
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy
if (-not $env:VAULT_CAD_TOKEN) { throw "VAULT_CAD_TOKEN is not set; dot-source windows\Set-VaultCadToken.ps1 first" }
foreach ($file in @($Acquisition, $Inventory)) { if (-not (Test-Path -LiteralPath $file)) { throw "Record not found: $file" } }
$acquisitionJson = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
$inventoryJson = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json
if (-not $acquisitionJson.files -or -not $inventoryJson.files) { throw "Acquisition/inventory records have no files" }
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$rawDir = Join-Path $OutputDirectory "raw"; New-Item -ItemType Directory -Path $rawDir | Out-Null
$base = $BaseUri.TrimEnd('/') + "/vaults/$([Uri]::EscapeDataString($VaultId))/"
$headers = @{ Authorization = "Bearer $env:VAULT_CAD_TOKEN"; Accept = "application/json" }
$script:gets = 0; $script:failures = @()
function Get-Json($path, $query) {
    $url = $base + $path; if ($query) { $url += "?" + (($query.GetEnumerator() | ForEach-Object { "$([Uri]::EscapeDataString($_.Key))=$([Uri]::EscapeDataString([string]$_.Value))" }) -join '&') }
    $script:gets++
    try { return Invoke-RestMethod -Uri $url -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0 } catch { $script:failures += [ordered]@{ path = $path; error = $_.Exception.Message }; return $null }
}
function Get-Pages($path) {
    # ONE page, never a cursor: this server's paging cursor repeats and skips rows (see Discover-VaultFolder.ps1).
    # A listing that does not fit one page, or is shorter than the server's total, is refused ($null plus a failure).
    $data = Get-Json $path @{ limit = $PageLimit }
    if ($null -eq $data) { return $null }
    $rows = @($data.results); $total = $null; $more = $false
    try { if ($null -ne $data.pagination.totalResults) { $total = [int]$data.pagination.totalResults } } catch { }
    try { $more = [bool]$data.pagination.nextUrl } catch { }
    if ($more -or ($null -ne $total -and $rows.Count -ne $total)) { $script:failures += [ordered]@{ path = $path; error = "the listing does not fit one page of $PageLimit rows ($($rows.Count) of $total); refused" }; return $null }
    return ,$rows
}
function Utc { [DateTime]::UtcNow.ToString("o") }
$started = Utc
$inventoryByMaster = @{}; foreach ($entry in $inventoryJson.files) { $inventoryByMaster[[string]$entry.master_id] = $entry }
$facts = @(); $systemNames = @{}; $namesByKind = @{}
foreach ($entry in $acquisitionJson.files) {
    $master = [string]$entry.master_id
    $versions = Get-Pages "files/$master/versions"
    if ($null -ne $versions) { ConvertTo-Json -InputObject @($versions) -Depth 8 | Set-Content -LiteralPath (Join-Path $rawDir "files-$master-versions.json") -Encoding UTF8 }
    $latestRecord = $null; $acquiredRecord = $null
    if ($null -ne $versions -and @($versions).Count -gt 0) {
        $latestId = [string](@($versions) | Sort-Object { [int]$_.version } | Select-Object -Last 1).id
        $latestRecord = Get-Json "file-versions/$latestId" $null
        if ($latestRecord) { ConvertTo-Json -InputObject $latestRecord -Depth 8 | Set-Content -LiteralPath (Join-Path $rawDir "file-version-$latestId.json") -Encoding UTF8 }
        if ($latestId -ne [string]$entry.version_id) {
            $acquiredRecord = Get-Json "file-versions/$([string]$entry.version_id)" $null
            if ($acquiredRecord) { ConvertTo-Json -InputObject $acquiredRecord -Depth 8 | Set-Content -LiteralPath (Join-Path $rawDir "file-version-$([string]$entry.version_id).json") -Encoding UTF8 }
        }
    }
    $fact = Resolve-FileFact $entry $inventoryByMaster[$master] $versions $latestRecord $acquiredRecord
    $facts += $fact
    if ($latestRecord -and $latestRecord.properties) {
        $kind = [IO.Path]::GetExtension($fact.name).TrimStart('.').ToLowerInvariant()
        if (-not $namesByKind.ContainsKey($kind)) { $namesByKind[$kind] = @{} }
        foreach ($property in @($latestRecord.properties)) { $systemName = [string]$property.definition.systemName; if ($systemName) { $systemNames[$systemName] = [string]$property.definition.displayName; $namesByKind[$kind][$systemName] = $true } }
    }
    Write-Output ("{0,-70} acquired {1} (v{2}) latest {3} (v{4}) changed={5} rev={6} state={7} checkedOut={8}" -f $fact.name, $fact.acquired_version_id, $fact.acquired_version_number, $fact.latest_version_id, $fact.latest_version_number, $fact.changed_since_acquisition, $fact.revision, $fact.lifecycle_state, $fact.is_checked_out)
}
$changed = @($facts | Where-Object { $_.changed_since_acquisition -eq $true })
$unknown = @($facts | Where-Object { $null -eq $_.changed_since_acquisition })
$differing = @($facts | Where-Object { @($_.differs_from_inventory).Count -gt 0 })
$withProblems = @($facts | Where-Object { @($_.problems).Count -gt 0 })
$checkedOut = @($facts | Where-Object { $_.is_checked_out -eq $true })
$summary = [ordered]@{ files = $facts.Count; unchanged = @($facts | Where-Object { $_.changed_since_acquisition -eq $false }).Count; changed = $changed.Count; unknown = $unknown.Count
    checked_out = $checkedOut.Count; differing_from_inventory = $differing.Count; with_problems = $withProblems.Count
    lifecycle_states = @($facts | Group-Object { [string]$_.lifecycle_state } | ForEach-Object { "$($_.Name)=$($_.Count)" }); lifecycle_definitions = @($facts | Group-Object { [string]$_.lifecycle_definition } | ForEach-Object { "$($_.Name)=$($_.Count)" })
    revisions = @($facts | Group-Object { [string]$_.revision } | ForEach-Object { "$($_.Name)=$($_.Count)" })
    acquisition_date = $acquisitionJson.acquired_at; inventory_date = $inventoryJson.captured_at
    statement = $(if ($unknown.Count -gt 0 -or $withProblems.Count -gt 0) { "UNKNOWN for some files: $($unknown.Count) file(s) could not be compared and $($withProblems.Count) carry problems; see the facts" } elseif ($changed.Count -eq 0 -and $differing.Count -eq 0) { "Nothing has changed in Vault for these $($facts.Count) files since the acquisition: every acquired version id is still the latest, and revision, lifecycle state, check-in date and check-out state equal the inventory" } else { "CHANGED: $($changed.Count) file(s) have a newer version and $($differing.Count) differ from the inventory in some field; see the facts" }) }
ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; generated_at = (Utc); vault_id = $VaultId; acquisition = $Acquisition; inventory = $Inventory; summary = $summary; files = $facts }) -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "vault-file-facts.json") -Encoding UTF8
$facts | ForEach-Object { [pscustomobject]@{ master_id = $_.master_id; name = $_.name; acquired_version_id = $_.acquired_version_id; acquired_version_number = $_.acquired_version_number; latest_version_id = $_.latest_version_id; latest_version_number = $_.latest_version_number
        versions_total = $_.versions_total; changed_since_acquisition = $_.changed_since_acquisition; revision = $_.revision; lifecycle_definition = $_.lifecycle_definition; lifecycle_state = $_.lifecycle_state; checkin_date = $_.checkin_date; is_checked_out = $_.is_checked_out
        differs_from_inventory = (@($_.differs_from_inventory) -join ';'); problems = (@($_.problems) -join ';'); vault_path = $_.vault_path } } | Export-Csv -LiteralPath (Join-Path $OutputDirectory "vault-file-facts.csv") -NoTypeInformation -Encoding UTF8
$kinds = [ordered]@{}; foreach ($kind in ($namesByKind.Keys | Sort-Object)) { $kinds[$kind] = @($namesByKind[$kind].Keys | Sort-Object) }
$displayNames = [ordered]@{}; foreach ($key in ($systemNames.Keys | Sort-Object)) { $displayNames[$key] = $systemNames[$key] }
ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; generated_at = (Utc); note = "system names (and display names) of the properties returned inline by GET file-versions/{id}; values deliberately not recorded here"
        count = $systemNames.Count; system_names = @($systemNames.Keys | Sort-Object); display_names = $displayNames; by_file_kind = $kinds }) -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "property-system-names.json") -Encoding UTF8
$status = $(if ($script:failures.Count -eq 0 -and $unknown.Count -eq 0 -and $withProblems.Count -eq 0) { "complete" } else { "FAILED" })
ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; script = "windows/Get-VaultFileFacts.ps1"; status = $status; started_at = $started; finished_at = (Utc); host = $env:COMPUTERNAME
        method = "REST GET only (files/{master}/versions, file-versions/{id}); the session token was obtained beforehand by Set-VaultCadToken.ps1 (one POST sessions/win-auth) and is not recorded"
        get_requests = $script:gets; failures = @($script:failures); summary = $summary }) -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "vault-file-facts-receipt.json") -Encoding UTF8
Write-Output "GET requests: $($script:gets); failures: $($script:failures.Count)"
Write-Output $summary.statement
Write-Output "Receipt status: $status"
if ($status -ne "complete") { exit 1 }
