<#
.SYNOPSIS
READ-ONLY discovery of one Vault folder: its files, which of them are root assemblies or standalone files within
the folder's own scope, the dependency closure of every root, and the parents outside that scope. REST GET only.

.DESCRIPTION
    . .\windows\Set-VaultCadToken.ps1            # Windows-authenticated session token, process only (the one POST)
    & .\windows\Discover-VaultFolder.ps1 -FolderPath '$/A/B/PROJECT' -OutputDirectory NEW `
        -BaseUri http://SERVER/AutodeskDM/Services/api/vault/v2/ -VaultId ID [-FolderId 123]

Step 1 of the synchronisation design's qualification (docs/native-checkin-adapter-design.md, 3.2), with review
finding R1 applied:

  scope       the files of the folder plus everything any of its assemblies uses (recursive Dependency closure);
  root        an assembly (.iam) in the folder that no file of the scope uses;
  standalone  a file of the folder that no file of the scope uses and that uses nothing itself;
  child       a file of the folder that some file of the scope uses;
  external_parents  parents outside the scope (another lab's assembly reusing a part, a drawing elsewhere):
              recorded for every file, never a reason to deny it the role of root or standalone.

Requests: folders (root, sub-folders, the folder itself), folders/{id}/contents (paged, includeHidden), and for
every file of the folder file-versions/{id}/parents and /uses (the exact version, getLatestAssocs=false), plus
/uses with recurse for every assembly and folders/{id} for the folders of closure members. No content is
downloaded; nothing is written to Vault; the token is never written.

Outputs: discovery.json (folder, sub_folders, files with role / parents / direct uses and the F1 facts, roots
with their closures, standalone files, closure members outside the folder), discovery-receipt.json, raw\.
    & .\windows\Discover-VaultFolder.ps1 -SelfTest      # offline cases for the role logic
#>
param(
    [string]$FolderPath,
    [string]$FolderId,
    [string]$OutputDirectory,
    [string]$BaseUri,
    [string]$VaultId,
    [ValidateRange(1, 1000)][int]$PageLimit = 1000,
    [switch]$SelfTest
)
$ErrorActionPreference = "Stop"

function Get-FileKind([string]$Name) {
    # The closed list of review finding R3.
    switch ([IO.Path]::GetExtension($Name).ToLowerInvariant()) { ".ipt" { "native_part" } ".iam" { "native_assembly" } ".step" { "step" } ".stp" { "step" } default { "other" } }
}

function Resolve-FolderRoles {
    <# Pure role logic. $Files: the folder's files (master_id, version_id, name). $ParentsByVersion and
       $UsesByVersion: version id -> list of records (master_id, version_id, name, association_type) for the DIRECT
       parents and children of that version. $ScopeMasters: hashtable whose keys are the master ids in scope. #>
    param($Files, $ParentsByVersion, $UsesByVersion, $ScopeMasters)
    $result = @()
    foreach ($file in @($Files)) {
        $parents = @($ParentsByVersion[[string]$file.version_id] | Where-Object { $null -ne $_ })
        $uses = @($UsesByVersion[[string]$file.version_id] | Where-Object { $null -ne $_ })
        $dependencyParents = @($parents | Where-Object { $_.association_type -eq "Dependency" })
        $internal = @($dependencyParents | Where-Object { $ScopeMasters.ContainsKey([string]$_.master_id) })
        $external = @($parents | Where-Object { -not $ScopeMasters.ContainsKey([string]$_.master_id) })
        $otherInternal = @($parents | Where-Object { $_.association_type -ne "Dependency" -and $ScopeMasters.ContainsKey([string]$_.master_id) })
        $dependencyUses = @($uses | Where-Object { $_.association_type -eq "Dependency" })
        $kind = Get-FileKind ([string]$file.name)
        $role = $(if ($internal.Count -gt 0) { "child" } elseif ($kind -eq "native_assembly") { "root" } elseif ($dependencyUses.Count -eq 0) { "standalone" } else { "standalone_with_dependencies" })
        $result += [pscustomobject]@{ master_id = [string]$file.master_id; version_id = [string]$file.version_id; name = [string]$file.name; kind = $kind; role = $role
            internal_parents = $internal; internal_non_dependency_parents = $otherInternal; external_parents = $external; uses_direct = $uses; dependency_uses_direct = $dependencyUses.Count }
    }
    return $result   # bare: callers wrap with @(...)
}

if ($SelfTest) {
    $results = @()
    function Case($name, [scriptblock]$body) {
        try { $detail = & $body; $script:results += [ordered]@{ case = $name; passed = $true; detail = "$detail" }; Write-Output "PASS $name $(if ($detail) { "- $detail" })" }
        catch { $script:results += [ordered]@{ case = $name; passed = $false; detail = $_.Exception.Message }; Write-Output "FAIL $name - $($_.Exception.Message)" }
    }
    function Assert($cond, $msg) { if (-not $cond) { throw $msg } }
    function File($master, $version, $name) { [pscustomobject]@{ master_id = "$master"; version_id = "$version"; name = $name } }
    function Link($master, $version, $name, $type) { [pscustomobject]@{ master_id = "$master"; version_id = "$version"; name = $name; association_type = $type } }
    function Roles($files, $parents, $uses, [string[]]$scope) { $set = @{}; foreach ($m in $scope) { $set[$m] = $true }; $map = @{}; foreach ($r in @(Resolve-FolderRoles $files $parents $uses $set)) { $map[$r.name] = $r }; return $map }
    $root = File 1 11 "ROOT.iam"; $sub = File 2 21 "SUB.iam"; $plate = File 3 31 "PLATE.ipt"; $step = File 4 41 "ENVELOPE.step"; $shared = File 5 51 "SHARED.ipt"
    Case "D1 one root, a sub-assembly and a part: only the top assembly is a root" {
        $r = Roles @($root, $sub, $plate) @{ "21" = @((Link 1 11 "ROOT.iam" "Dependency")); "31" = @((Link 2 21 "SUB.iam" "Dependency")) } @{ "11" = @((Link 2 21 "SUB.iam" "Dependency")); "21" = @((Link 3 31 "PLATE.ipt" "Dependency")) } @("1", "2", "3")
        Assert ($r["ROOT.iam"].role -eq "root" -and $r["SUB.iam"].role -eq "child" -and $r["PLATE.ipt"].role -eq "child") "roles: $(($r.Values | ForEach-Object { $_.name + '=' + $_.role }) -join ', ')"
    }
    Case "D2 R1: a parent outside the scope is recorded and does not disqualify the root" {
        $r = Roles @($root, $plate) @{ "11" = @((Link 900 901 "OTHER LAB.iam" "Dependency")); "31" = @((Link 1 11 "ROOT.iam" "Dependency"), (Link 900 901 "OTHER LAB.iam" "Dependency")) } @{ "11" = @((Link 3 31 "PLATE.ipt" "Dependency")) } @("1", "3")
        Assert ($r["ROOT.iam"].role -eq "root" -and @($r["ROOT.iam"].external_parents).Count -eq 1 -and $r["ROOT.iam"].external_parents[0].name -eq "OTHER LAB.iam") "root: $($r['ROOT.iam'] | ConvertTo-Json -Compress -Depth 4)"
        Assert ($r["PLATE.ipt"].role -eq "child" -and @($r["PLATE.ipt"].internal_parents).Count -eq 1 -and @($r["PLATE.ipt"].external_parents).Count -eq 1) "plate: $($r['PLATE.ipt'] | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "D3 a file with no parents and no uses is standalone (the published STEP)" {
        $r = Roles @($root, $step) @{} @{} @("1", "4")
        Assert ($r["ENVELOPE.step"].role -eq "standalone" -and $r["ENVELOPE.step"].kind -eq "step" -and $r["ROOT.iam"].role -eq "root") "roles: $(($r.Values | ForEach-Object { $_.name + '=' + $_.role }) -join ', ')"
    }
    Case "D4 a part used only by an assembly outside the scope is standalone here, with the external parent recorded" {
        $r = Roles @($shared) @{ "51" = @((Link 900 901 "OTHER LAB.iam" "Dependency")) } @{} @("5")
        Assert ($r["SHARED.ipt"].role -eq "standalone" -and @($r["SHARED.ipt"].external_parents).Count -eq 1 -and @($r["SHARED.ipt"].internal_parents).Count -eq 0) "shared: $($r['SHARED.ipt'] | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "D5 a parent that is in the closure but not in the folder (a library sub-assembly) makes the file a child" {
        $r = Roles @($root, $plate) @{ "31" = @((Link 700 701 "LIBRARY SUB.iam" "Dependency")) } @{ "11" = @((Link 700 701 "LIBRARY SUB.iam" "Dependency")) } @("1", "3", "700")
        Assert ($r["PLATE.ipt"].role -eq "child" -and $r["PLATE.ipt"].internal_parents[0].name -eq "LIBRARY SUB.iam") "plate: $($r['PLATE.ipt'] | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "D6 two assemblies that nothing in scope uses are two roots" {
        $second = File 6 61 "SECOND.iam"
        $r = Roles @($root, $second) @{} @{} @("1", "6")
        Assert ($r["ROOT.iam"].role -eq "root" -and $r["SECOND.iam"].role -eq "root") "roles: $(($r.Values | ForEach-Object { $_.name + '=' + $_.role }) -join ', ')"
    }
    Case "D7 an attachment parent (a visualization or a drawing attached, not a dependency) does not make a file a child" {
        $r = Roles @($root, $plate) @{ "31" = @((Link 1 11 "ROOT.iam" "Attachment")) } @{} @("1", "3")
        Assert ($r["PLATE.ipt"].role -eq "standalone" -and @($r["PLATE.ipt"].internal_non_dependency_parents).Count -eq 1) "plate: $($r['PLATE.ipt'] | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "D8 a part that depends on another file and has no parent in scope is reported as standalone_with_dependencies (a wrapper part)" {
        $wrapper = File 8 81 "ENVELOPE-reference.ipt"
        $r = Roles @($wrapper, $step) @{ "41" = @((Link 8 81 "ENVELOPE-reference.ipt" "Dependency")) } @{ "81" = @((Link 4 41 "ENVELOPE.step" "Dependency")) } @("8", "4")
        Assert ($r["ENVELOPE-reference.ipt"].role -eq "standalone_with_dependencies" -and $r["ENVELOPE.step"].role -eq "child") "roles: $(($r.Values | ForEach-Object { $_.name + '=' + $_.role }) -join ', ')"
    }
    $passed = @($results | Where-Object passed).Count; $failed = @($results | Where-Object { -not $_.passed }).Count
    Write-Output "$passed passed, $failed failed"
    if ($failed -gt 0) { exit 1 }
    return
}

foreach ($required in @("OutputDirectory", "BaseUri", "VaultId")) { if (-not (Get-Variable -Name $required -ValueOnly)) { throw "-$required is required" } }
if (-not $FolderPath -and -not $FolderId) { throw "Give -FolderPath, -FolderId, or both (then they must agree)" }
# The bearer token must not travel through an ambient HTTP proxy: disable proxies for this process (P4).
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy
if (-not $env:VAULT_CAD_TOKEN) { throw "VAULT_CAD_TOKEN is not set; dot-source windows\Set-VaultCadToken.ps1 first" }
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$rawDir = Join-Path $OutputDirectory "raw"; New-Item -ItemType Directory -Path $rawDir | Out-Null
$base = $BaseUri.TrimEnd('/') + "/vaults/$([Uri]::EscapeDataString($VaultId))/"
$headers = @{ Authorization = "Bearer $env:VAULT_CAD_TOKEN"; Accept = "application/json" }
$script:gets = 0; $script:failures = @()
function Utc { [DateTime]::UtcNow.ToString("o") }
function Get-Json($path, $query) {
    $url = $base + $path; if ($query) { $url += "?" + (($query.GetEnumerator() | ForEach-Object { "$([Uri]::EscapeDataString($_.Key))=$([Uri]::EscapeDataString([string]$_.Value))" }) -join '&') }
    $script:gets++
    try { return Invoke-RestMethod -Uri $url -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0 } catch { $script:failures += [ordered]@{ path = $path; error = $_.Exception.Message }; return $null }
}
function Get-Pages($path, $query) {
    <# ONE page, never a cursor. Observed on this server (Vault 2025, API 2.0.16, 2026-11-10): the paging cursor is
       id-based ("IdCursor-v1:<id>") while the rows are ordered by name, so following nextUrl repeats and skips rows
       (a 349-row listing came back as 474 rows with 198 distinct ids). The page size cap is 1000. A listing that
       does not fit one page, or whose row count is not the server's total, is refused ($null plus a failure). #>
    $pageQuery = @{}; if ($query) { foreach ($k in $query.Keys) { $pageQuery[$k] = $query[$k] } }; $pageQuery["limit"] = $PageLimit
    $data = Get-Json $path $pageQuery
    if ($null -eq $data) { return $null }
    $rows = @($data.results); $total = $null; $more = $false
    try { if ($null -ne $data.pagination.totalResults) { $total = [int]$data.pagination.totalResults } } catch { }
    try { $more = [bool]$data.pagination.nextUrl } catch { }
    if ($more -or ($null -ne $total -and $rows.Count -ne $total)) { $script:failures += [ordered]@{ path = $path; error = "the listing does not fit one page of $PageLimit rows ($($rows.Count) of $total); refused, because this server's paging cursor repeats and skips rows" }; return $null }
    $ids = @($rows | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    if ($ids.Count -and @($ids | Sort-Object -Unique).Count -ne $ids.Count) { $script:failures += [ordered]@{ path = $path; error = "the listing repeats row ids ($($ids.Count) rows, $(@($ids | Sort-Object -Unique).Count) distinct)" }; return $null }
    return ,$rows
}
function Save-Raw([string]$name, $value) { ConvertTo-Json -InputObject $value -Depth 10 | Set-Content -LiteralPath (Join-Path $rawDir $name) -Encoding UTF8 }
$started = Utc
# ---- resolve the folder ----
$folder = $null
if ($FolderId) { $folder = Get-Json "folders/$FolderId" $null; if (-not $folder) { throw "Folder $FolderId could not be read" } }
else {
    $segments = @($FolderPath.Trim().TrimEnd('/') -split '/' | Where-Object { $_ })
    if ($segments[0] -ne '$') { throw "-FolderPath must start with `$/" }
    $folder = Get-Json "folders/root" $null; if (-not $folder) { throw "The root folder could not be read" }
    foreach ($segment in ($segments | Select-Object -Skip 1)) {
        $children = Get-Pages "folders/$($folder.id)/sub-folders" $null
        $match = @($children | Where-Object { [string]$_.name -ieq $segment })
        if ($match.Count -ne 1) { throw "Folder segment '$segment' not found exactly once under '$($folder.fullName)'" }
        $folder = $match[0]
    }
    $folder = Get-Json "folders/$($folder.id)" $null
}
if ($FolderPath -and ([string]$folder.fullName).TrimEnd('/') -ine $FolderPath.Trim().TrimEnd('/')) { throw "Folder $($folder.id) is '$($folder.fullName)', not '$FolderPath'" }
Save-Raw "folder.json" $folder
$folderIdResolved = [string]$folder.id
Write-Output "Folder $folderIdResolved '$($folder.fullName)'"
$subFolders = Get-Pages "folders/$folderIdResolved/sub-folders" $null
$contents = Get-Pages "folders/$folderIdResolved/contents" @{ "option[includeHidden]" = "true" }
if ($null -eq $contents) { throw "The folder contents could not be listed: $(($script:failures | Select-Object -Last 1).error)" }
Save-Raw "contents.json" @($contents)
$fileRecords = @($contents | Where-Object { [string]$_.entityType -ne "Folder" })
$assocQuery = @{ "option[includeHidden]" = "true"; "option[getLatestAssocs]" = "false" }
function ConvertTo-Link($record, [string]$type) { [pscustomobject]@{ master_id = [string]$record.file.id; version_id = [string]$record.id; version = $record.version; name = [string]$record.name; folder_id = [string]$record.parentFolderId; state = $record.state; is_checked_out = $record.isCheckedOut; association_type = $type } }
$files = @(); $parentsByVersion = @{}; $usesByVersion = @{}; $closures = @{}
foreach ($record in $fileRecords) {
    $versionId = [string]$record.id
    $files += [pscustomobject]@{ master_id = [string]$record.file.id; version_id = $versionId; name = [string]$record.name; version = $record.version; revision = $record.revision; state = $record.state
        checkin_date = $record.checkinDate; is_checked_out = $record.isCheckedOut; is_hidden = $record.isHidden; size = $record.size; category = $record.category; has_visualization_attachment = $record.hasVisualizationAttachment }
    $parents = Get-Pages "file-versions/$versionId/parents" $assocQuery
    $uses = Get-Pages "file-versions/$versionId/uses" $assocQuery
    if ($null -ne $parents) { Save-Raw "parents-$versionId.json" @($parents); $parentsByVersion[$versionId] = @($parents | ForEach-Object { ConvertTo-Link $_.parentFile ([string]$_.fileAssocType) }) }
    if ($null -ne $uses) { Save-Raw "uses-$versionId.json" @($uses); $usesByVersion[$versionId] = @($uses | ForEach-Object { ConvertTo-Link $_.childFile ([string]$_.fileAssocType) }) }
    if ((Get-FileKind ([string]$record.name)) -eq "native_assembly") {
        $recursive = Get-Pages "file-versions/$versionId/uses" @{ "option[recurse]" = "true"; "option[getLatestAssocs]" = "false"; "option[includeHidden]" = "true" }
        if ($null -ne $recursive) { Save-Raw "uses-$versionId-recurse.json" @($recursive); $closures[$versionId] = @($recursive) }
    }
}
# ---- scope: the folder's masters plus every Dependency closure member ----
$scope = @{}; foreach ($file in $files) { $scope[$file.master_id] = $true }
foreach ($versionId in $closures.Keys) { foreach ($assoc in $closures[$versionId]) { if ([string]$assoc.fileAssocType -eq "Dependency") { $scope[[string]$assoc.childFile.file.id] = $true } } }
$roles = @(Resolve-FolderRoles $files $parentsByVersion $usesByVersion $scope)
$folderCache = @{ $folderIdResolved = [string]$folder.fullName }
function Get-FolderPath([string]$id) { if (-not $id) { return $null }; if (-not $folderCache.ContainsKey($id)) { $other = Get-Json "folders/$id" $null; $folderCache[$id] = $(if ($other) { [string]$other.fullName } else { $null }) }; return $folderCache[$id] }
function Add-Path($link) { $path = Get-FolderPath $link.folder_id; [ordered]@{ master_id = $link.master_id; version_id = $link.version_id; version = $link.version; name = $link.name; vault_path = $(if ($path) { "$path/$($link.name)" } else { $null }); state = $link.state; is_checked_out = $link.is_checked_out; association_type = $link.association_type } }
$byMaster = @{}; foreach ($file in $files) { $byMaster[$file.master_id] = $file }
$fileOutput = @()
foreach ($role in $roles) {
    $file = $byMaster[$role.master_id]
    $fileOutput += [ordered]@{ name = $file.name; kind = $role.kind; role = $role.role; master_id = $file.master_id; version_id = $file.version_id; version = $file.version; revision = $file.revision; lifecycle_state = $file.state
        checkin_date = $file.checkin_date; is_checked_out = $file.is_checked_out; is_hidden = $file.is_hidden; size = $file.size; category = $file.category; vault_path = "$($folder.fullName)/$($file.name)"
        parents_read = $parentsByVersion.ContainsKey($file.version_id); uses_read = $usesByVersion.ContainsKey($file.version_id)
        internal_parents = @($role.internal_parents | ForEach-Object { Add-Path $_ }); external_parents = @($role.external_parents | ForEach-Object { Add-Path $_ })
        internal_non_dependency_parents = @($role.internal_non_dependency_parents | ForEach-Object { Add-Path $_ }); uses_direct = @($role.uses_direct | ForEach-Object { Add-Path $_ }) }
}
$rootOutput = @()
foreach ($role in @($roles | Where-Object { $_.role -eq "root" })) {
    $members = @{}; $attachments = @(); $associations = @($closures[$role.version_id])
    foreach ($assoc in $associations) {
        $link = ConvertTo-Link $assoc.childFile ([string]$assoc.fileAssocType)
        if ($link.association_type -eq "Dependency") { if (-not $members.ContainsKey($link.version_id)) { $members[$link.version_id] = $link } } else { $attachments += (Add-Path $link) }
    }
    $closure = @($members.Values | Sort-Object name | ForEach-Object { $entry = Add-Path $_; $entry["in_folder"] = $byMaster.ContainsKey($_.master_id); $entry["kind"] = Get-FileKind $_.name; $entry })
    $versionsPerMaster = @($members.Values | Group-Object master_id | Where-Object { $_.Count -gt 1 })
    $rootOutput += [ordered]@{ name = $role.name; master_id = $role.master_id; version_id = $role.version_id; closure_read = $closures.ContainsKey($role.version_id); associations = $associations.Count
        closure_files = $closure.Count; closure_in_folder = @($closure | Where-Object { $_["in_folder"] }).Count; closure_outside_folder = @($closure | Where-Object { -not $_["in_folder"] }).Count
        closure_by_kind = @($closure | Group-Object { $_["kind"] } | ForEach-Object { "$($_.Name)=$($_.Count)" }); masters_with_several_versions = @($versionsPerMaster | ForEach-Object { $_.Name })
        external_parents = @($role.external_parents | ForEach-Object { Add-Path $_ }); attachments = $attachments; closure = $closure }
}
$outside = @{}
foreach ($root in $rootOutput) { foreach ($member in $root.closure) { if (-not $member["in_folder"]) { $folderOf = ([string]$member["vault_path"]) -replace '/[^/]*$', ''; if (-not $outside.ContainsKey($folderOf)) { $outside[$folderOf] = @{} }; $outside[$folderOf][[string]$member["master_id"]] = $true } } }
$unread = @($fileOutput | Where-Object { -not $_.parents_read -or -not $_.uses_read })
$summary = [ordered]@{ files_in_folder = $fileOutput.Count; by_kind = @($fileOutput | Group-Object { $_.kind } | ForEach-Object { "$($_.Name)=$($_.Count)" }); by_role = @($fileOutput | Group-Object { $_.role } | ForEach-Object { "$($_.Name)=$($_.Count)" })
    roots = @($rootOutput | ForEach-Object { $_.name }); standalone = @($fileOutput | Where-Object { $_.role -like "standalone*" } | ForEach-Object { $_.name })
    files_with_external_parents = @($fileOutput | Where-Object { @($_.external_parents).Count -gt 0 }).Count; distinct_external_parents = @($fileOutput | ForEach-Object { $_.external_parents | ForEach-Object { $_.master_id } } | Sort-Object -Unique).Count
    hidden_files_seen = @($fileOutput | Where-Object { $_.is_hidden -eq $true }).Count; checked_out = @($fileOutput | Where-Object { $_.is_checked_out -eq $true }).Count; sub_folders = @($subFolders | ForEach-Object { $_.name })
    scope_masters = $scope.Count; closure_folders_outside = @($outside.Keys | Sort-Object | ForEach-Object { "$_ ($($outside[$_].Count))" }); files_with_unread_associations = $unread.Count }
ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; generated_at = (Utc); vault_id = $VaultId; folder = [ordered]@{ id = $folderIdResolved; path = [string]$folder.fullName }
        rules = "R1: scope = folder files plus the recursive Dependency closure of its assemblies; root = assembly in the folder with no Dependency parent in scope; standalone = no Dependency parent in scope and no Dependency child; parents outside the scope are external_parents and never disqualify"
        note = "REST lists only what the session may see; folder listings were observed to omit hidden files, so hidden_files_seen = 0 is not proof that none exist (the SDK listing is the check)"
        summary = $summary; sub_folders = @($subFolders | ForEach-Object { [ordered]@{ id = [string]$_.id; name = [string]$_.name } }); files = $fileOutput; roots = $rootOutput }) -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "discovery.json") -Encoding UTF8
$status = $(if ($script:failures.Count -eq 0 -and $unread.Count -eq 0 -and @($rootOutput | Where-Object { -not $_.closure_read }).Count -eq 0) { "complete" } else { "FAILED" })
ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; script = "windows/Discover-VaultFolder.ps1"; status = $status; started_at = $started; finished_at = (Utc); host = $env:COMPUTERNAME
        method = "REST GET only; the session token was obtained beforehand by Set-VaultCadToken.ps1 (one POST sessions/win-auth) and is not recorded"; get_requests = $script:gets; failures = @($script:failures); summary = $summary }) -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "discovery-receipt.json") -Encoding UTF8
Write-Output "Files in folder: $($fileOutput.Count) ($($summary.by_kind -join ', ')); roles: $($summary.by_role -join ', ')"
Write-Output "Roots: $($summary.roots -join '; '); standalone: $($summary.standalone -join '; ')"
foreach ($root in $rootOutput) { Write-Output "  $($root.name): closure $($root.closure_files) files ($($root.closure_in_folder) in the folder, $($root.closure_outside_folder) outside), $(@($root.attachments).Count) attachment(s), $(@($root.external_parents).Count) external parent(s)" }
Write-Output "Files with external parents: $($summary.files_with_external_parents) (distinct external parents: $($summary.distinct_external_parents)); GET requests: $($script:gets); failures: $($script:failures.Count)"
Write-Output "Receipt status: $status"
if ($status -ne "complete") { exit 1 }
