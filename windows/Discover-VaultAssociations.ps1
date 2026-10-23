<#
.SYNOPSIS
READ-ONLY Vault discovery of drawings, presentations and attachments associated with every file version
of an acquisition (dependency-inventory.json), through the Vault Data API with HTTP GET only.

.DESCRIPTION
    . .\windows\Set-VaultCadToken.ps1            # Windows-authenticated session token, process only
    & .\windows\Discover-VaultAssociations.ps1 -Inventory dependency-inventory.json -OutputDirectory NEW

For each acquired version: GET file-versions/{id}/parents (who uses it: drawings, presentations, parent
assemblies) and GET file-versions/{id}/uses (children, including attachments), both with
option[includeHidden]=true and option[getLatestAssocs]=false so the EXACT acquired version's associations
are reported, not the latest ones. Every distinct parent that is not in the acquisition (drawing,
presentation, other assembly) is then described (GET file-versions/{id}, its folder, and its own
uses so the model versions it references are known). Raw responses are kept under raw/.
No content is downloaded, nothing is written to Vault, the token is never written.

Outputs: drawings-and-attachments.json (per acquired file: parents and attachments), external-parents.json
(each drawing/presentation/foreign parent with folder path, version and referenced model versions),
discovery-receipt.json (counts, GET count, status).
#>
param(
    [Parameter(Mandatory = $true)][string]$Inventory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$BaseUri,
    [Parameter(Mandatory = $true)][string]$VaultId,
    [int]$PageLimit = 100,
    [switch]$AllVersions
)
$ErrorActionPreference = "Stop"
# Server and vault come from the project configuration (vault-project.toml [vault] base_url / id), never from defaults (L5).
# The bearer token must not travel through an ambient HTTP proxy: disable proxies for this process (P4).
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy
if (-not $env:VAULT_CAD_TOKEN) { throw "VAULT_CAD_TOKEN is not set; dot-source windows\Set-VaultCadToken.ps1 first" }
if (-not (Test-Path -LiteralPath $Inventory)) { throw "Inventory record not found: $Inventory" }
$inv = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json
if (-not $inv.files) { throw "Inventory record has no files" }
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory "raw") | Out-Null
$base = $BaseUri.TrimEnd('/') + "/vaults/$([Uri]::EscapeDataString($VaultId))/"
$headers = @{ Authorization = "Bearer $env:VAULT_CAD_TOKEN"; Accept = "application/json" }
$script:gets = 0; $script:failures = @()
function Get-Json($path, $query) {
    $url = $base + $path; if ($query) { $url += "?" + (($query.GetEnumerator() | ForEach-Object { "$([Uri]::EscapeDataString($_.Key))=$([Uri]::EscapeDataString([string]$_.Value))" }) -join '&') }
    $script:gets++
    try { return Invoke-RestMethod -Uri $url -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0 } catch { $script:failures += [ordered]@{ path = $path; error = $_.Exception.Message }; return $null }
}
function Get-Pages($path, $query) {
    $all = @(); $cursor = $null
    for ($page = 0; $page -lt 200; $page++) {
        $q = @{}; foreach ($k in $query.Keys) { $q[$k] = $query[$k] }; $q["limit"] = $PageLimit; if ($cursor) { $q["cursorState"] = $cursor }
        $data = Get-Json $path $q
        if ($null -eq $data) { return ,$all }
        $results = @($data.results); $all += $results
        $next = $null; try { $next = $data.pagination.cursorState } catch { }
        if (-not $results.Count -or -not $next -or $next -eq $cursor) { break }
        $cursor = $next
    }
    return ,$all
}
function Classify($name) { $ext = [IO.Path]::GetExtension([string]$name).ToLowerInvariant(); switch ($ext) { ".idw" { "drawing" } ".dwg" { "drawing" } ".ipn" { "presentation" } ".iam" { "assembly" } ".ipt" { "part" } ".dwf" { "visualization" } ".dwfx" { "visualization" } ".xlsx" { "spreadsheet" } ".xls" { "spreadsheet" } ".pdf" { "pdf" } ".docx" { "document" } ".txt" { "text" } default { "other:$ext" } } }
function FileRec($fv) { if ($null -eq $fv) { return $null }; [ordered]@{ name = $fv.name; version_id = [string]$fv.id; master_id = $(try { [string]$fv.file.id } catch { $null }); version = $fv.version; parent_folder_id = [string]$fv.parentFolderId; classification = $(try { [string]$fv.classification } catch { $null }); state = $fv.state; kind = (Classify $fv.name); checked_out = $fv.isCheckedOut } }

$acquired = @{}; foreach ($f in $inv.files) { $acquired[[string]$f.version_id] = $f }
$perFile = @(); $external = @{}
$assocQuery = @{ "option[includeHidden]" = "true"; "option[getLatestAssocs]" = "false"; "option[recurse]" = "false" }
foreach ($f in $inv.files) {
    $vid = [string]$f.version_id
    $parents = Get-Pages "file-versions/$vid/parents" $assocQuery
    $uses = Get-Pages "file-versions/$vid/uses" $assocQuery
    ConvertTo-Json -InputObject @($parents) -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "raw\$vid-parents.json") -Encoding UTF8
    ConvertTo-Json -InputObject @($uses) -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "raw\$vid-uses.json") -Encoding UTF8
    $parentRecs = @(); foreach ($a in $parents) { $p = FileRec $a.parentFile; if ($null -eq $p) { continue }; $p.association_type = [string]$a.fileAssocType; $p.in_acquisition = $acquired.ContainsKey($p.version_id); $parentRecs += $p; if (-not $p.in_acquisition -and -not $external.ContainsKey($p.version_id)) { $external[$p.version_id] = $p } }
    $childRecs = @(); foreach ($a in $uses) { $c = FileRec $a.childFile; if ($null -eq $c) { continue }; $c.association_type = [string]$a.fileAssocType; $c.in_acquisition = $acquired.ContainsKey($c.version_id); $childRecs += $c }
    $perFile += [ordered]@{ vault_path = $f.vault_path; name = $f.name; version_id = $vid; master_id = [string]$f.master_id; version = $f.version
        parents = $parentRecs; parents_count = $parentRecs.Count; drawings = @($parentRecs | Where-Object { $_.kind -in @("drawing", "presentation") }); attachments = @($childRecs | Where-Object { $_.association_type -eq "Attachment" }); dependencies_count = @($childRecs | Where-Object { $_.association_type -eq "Dependency" }).Count
        children_outside_acquisition = @($childRecs | Where-Object { -not $_.in_acquisition }) }
    Write-Output ("  {0}: parents {1} (drawings/presentations {2}), attachments {3}" -f $f.name, $parentRecs.Count, @($parentRecs | Where-Object { $_.kind -in @("drawing", "presentation") }).Count, @($childRecs | Where-Object { $_.association_type -eq "Attachment" }).Count)
}
# describe every external parent (drawing, presentation, foreign assembly): folder path and referenced model versions
$folderCache = @{}
function FolderPath($id) { if (-not $id) { return $null }; if ($folderCache.ContainsKey($id)) { return $folderCache[$id] }; $fo = Get-Json "folders/$id" $null; $path = $(if ($fo) { $fo.fullName } else { $null }); $folderCache[$id] = $path; return $path }
$externalRecs = @()
foreach ($vid in $external.Keys) {
    $p = $external[$vid]
    $detail = Get-Json "file-versions/$vid" $null
    $usesRaw = Get-Pages "file-versions/$vid/uses" $assocQuery
    ($usesRaw | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $OutputDirectory "raw\external-$vid-uses.json") -Encoding UTF8
    $refs = @(); foreach ($a in $usesRaw) { $c = FileRec $a.childFile; if ($null -eq $c) { continue }; $c.association_type = [string]$a.fileAssocType; $c.in_acquisition = $acquired.ContainsKey($c.version_id); $c.acquired_version_of_same_master = $(if (-not $c.in_acquisition) { ($inv.files | Where-Object { [string]$_.master_id -eq $c.master_id } | ForEach-Object { [string]$_.version_id }) -join ',' } else { $null }); $refs += $c }
    $externalRecs += [ordered]@{ name = $p.name; kind = $p.kind; version_id = $vid; master_id = $p.master_id; version = $(if ($detail) { $detail.version } else { $p.version }); state = $(if ($detail) { $detail.state } else { $p.state }); folder_path = (FolderPath $p.parent_folder_id); folder_id = $p.parent_folder_id; last_modified = $(if ($detail) { $detail.lastModifiedDate } else { $null }); size = $(if ($detail) { $detail.size } else { $null })
        references = $refs; references_in_acquisition = @($refs | Where-Object in_acquisition).Count; references_other_versions_of_acquired_masters = @($refs | Where-Object { -not $_.in_acquisition -and $_.acquired_version_of_same_master }).Count }
}
$drawings = @($externalRecs | Where-Object { $_.kind -in @("drawing", "presentation") })
Write-Output ("external parents: {0} ({1} drawings/presentations, {2} assemblies, {3} other); GET requests {4}, failures {5}" -f $externalRecs.Count, $drawings.Count, @($externalRecs | Where-Object { $_.kind -eq 'assembly' }).Count, @($externalRecs | Where-Object { $_.kind -notin @('drawing', 'presentation', 'assembly') }).Count, $script:gets, $script:failures.Count)
# ---- all versions of every acquired master: a drawing may be associated with another version than the acquired one ----
$otherVersionDrawings = @(); $versionsChecked = 0; $mastersChecked = 0
if ($AllVersions) {
    foreach ($f in $inv.files) {
        $mastersChecked++
        $versions = Get-Pages "files/$([string]$f.master_id)/versions" @{}
        ConvertTo-Json -InputObject @($versions) -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "raw\master-$($f.master_id)-versions.json") -Encoding UTF8
        foreach ($ver in $versions) {
            $vid2 = [string]$ver.id
            if ($acquired.ContainsKey($vid2)) { continue }
            $versionsChecked++
            $pars = Get-Pages "file-versions/$vid2/parents" $assocQuery
            foreach ($a in $pars) { $p = FileRec $a.parentFile; if ($null -eq $p) { continue }; if ($p.kind -in @("drawing", "presentation")) { $p.association_type = [string]$a.fileAssocType; $p.associated_with_version_id = $vid2; $p.associated_with_version = $ver.version; $p.master_id_of_acquired_file = [string]$f.master_id; $p.acquired_file = $f.name; $p.folder_path = (FolderPath $p.parent_folder_id); $otherVersionDrawings += $p } }
        }
    }
    Write-Output ("all-versions pass: {0} masters, {1} non-acquired versions checked, {2} drawing/presentation associations on other versions" -f $mastersChecked, $versionsChecked, $otherVersionDrawings.Count)
    # -InputObject keeps an empty result as a JSON array (piping an empty array writes nothing at all)
    ConvertTo-Json -InputObject @($otherVersionDrawings) -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "drawings-on-other-versions.json") -Encoding UTF8
}
ConvertTo-Json -InputObject @($perFile) -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "drawings-and-attachments.json") -Encoding UTF8
ConvertTo-Json -InputObject @($externalRecs) -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "external-parents.json") -Encoding UTF8
$status = $(if ($script:failures.Count -eq 0) { "complete" } else { "INCOMPLETE" })
[ordered]@{ schema_version = 1; generated_at = [DateTime]::UtcNow.ToString("o"); tool = "windows/Discover-VaultAssociations.ps1"; status = $status; read_only = "HTTP GET only; no content downloaded; token kept in process"; vault_id = $VaultId; acquired_versions = $inv.files.Count; all_versions_pass = [bool]$AllVersions; get_requests = $script:gets; failures = $script:failures
    counts = [ordered]@{ files_with_parents = @($perFile | Where-Object { $_.parents_count -gt 0 }).Count; files_with_drawings = @($perFile | Where-Object { $_.drawings.Count -gt 0 }).Count; files_with_attachments = @($perFile | Where-Object { $_.attachments.Count -gt 0 }).Count; attachment_kinds = (@($perFile | ForEach-Object { $_.attachments } | ForEach-Object { $_.kind }) | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '; external_parents = $externalRecs.Count; drawings_or_presentations = $drawings.Count; drawings_referencing_acquired_versions = @($drawings | Where-Object { $_.references_in_acquisition -gt 0 }).Count; drawings_referencing_other_versions = @($drawings | Where-Object { $_.references_other_versions_of_acquired_masters -gt 0 }).Count; masters_checked_all_versions = $mastersChecked; non_acquired_versions_checked = $versionsChecked; drawings_on_other_versions = $otherVersionDrawings.Count } } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "discovery-receipt.json") -Encoding UTF8
Write-Output "Discovery status: $status"
if ($status -ne "complete") { exit 1 }
