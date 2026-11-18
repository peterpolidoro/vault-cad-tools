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
every file of the folder file-versions/{id}/parents and /uses (of exactly that version, getLatestAssocs=false; the
server names every parent and child at its latest version, see Get-VaultDependencySnapshot.ps1), plus
/uses with recurse for every assembly and folders/{id} for the folders of closure members. No content is
downloaded; nothing is written to Vault; the token is never written.

THE FOLDERS ON THE PATH, from the root to the folder, are recorded with id, name, path and category, and nothing
else of any level (folders_on_the_path). With -FolderPath they are the one row of each level's listing that the
walk follows: the listings name the other folders of every level, and none of that is kept. With -FolderId no
level is listed: the folders above are read one by one (GET folders/{id}), each by the parent the one below names.

A ROW THAT IS NOT A VERSION CHECKED IN. A file that is checked out is listed by the place of its check-out, a row
with a check-in date of year 1 (Vault-Version.ps1). Every file, parent, child and closure member says what its
row is (version_is: checked_in, check_out_place, no_check_in_date); a row that is not a version checked in has no
checkin_date, and a file of the folder at a check-out place says since when (checked_out_since). The summary
counts them. A root is still a root: its closure is then what the server holds for the check-out, not what a
version was checked in with, and Get-VaultDependencySnapshot.ps1 refuses to pin it.

Outputs: discovery.json (folder, folders_on_the_path, sub_folders, files with role / parents / direct uses and the
F1 facts, roots with their closures, standalone files, closure members outside the folder),
discovery-receipt.json, raw\ (the folder, its contents and the associations as the server gave them; of the
folders above, nothing).
    & .\windows\Discover-VaultFolder.ps1 -SelfTest      # offline cases: the roles, the path, the check-out places
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
. (Join-Path $PSScriptRoot "Vault-Version.ps1")

function Get-FileKind([string]$Name) {
    # The closed list of review finding R3.
    switch ([IO.Path]::GetExtension($Name).ToLowerInvariant()) { ".ipt" { "native_part" } ".iam" { "native_assembly" } ".step" { "step" } ".stp" { "step" } default { "other" } }
}

function ConvertTo-PathFolder($Answer) {
    # What is kept of a folder on the path: these four, and nothing else of the answer or of the level it came from.
    [ordered]@{ id = [string]$Answer.id; name = [string]$Answer.name; path = [string]$Answer.fullName; category = $(if ($null -ne $Answer.category) { [string]$Answer.category } else { $null }) }
}

function Resolve-FolderWalk {
    <# Pure. From the root folder down the segments of a path. $GetSubFolders: script block, folder id -> the rows
       of GET folders/{id}/sub-folders (nothing when the listing could not be read). Returns the folders on the
       path as the server gave them, the root first: of each listing the one row the walk follows, and no other. #>
    param($Root, [string[]]$Segments, [scriptblock]$GetSubFolders)
    $walked = @($Root); $at = $Root
    foreach ($segment in @($Segments)) {
        $children = & $GetSubFolders ([string]$at.id)
        $found = @($children | Where-Object { $null -ne $_ -and [string]$_.name -ieq $segment })
        if ($found.Count -ne 1) { throw "Folder segment '$segment' not found exactly once under '$($at.fullName)'" }
        $at = $found[0]; $walked += $at
    }
    return $walked   # bare: callers wrap with @(...)
}

function Resolve-FolderAncestors {
    <# Pure. From a folder up to the root, by the parent each folder object names (parentFolderId; the root has
       none). $GetFolder: script block, folder id -> the answer of GET folders/{id} (nothing when it could not be
       read). No level is listed. Returns the folders on the path as the server gave them, the root first.
       Refused: a parent that cannot be read or answers with another id, a folder met twice, more than 64 levels. #>
    param($Start, [scriptblock]$GetFolder)
    $climbed = @($Start); $seen = @{}; $seen[[string]$Start.id] = $true; $at = $Start
    while ($null -ne $at.parentFolderId -and "$($at.parentFolderId)") {
        $parentId = [string]$at.parentFolderId
        if ($seen.ContainsKey($parentId)) { throw "Folder $parentId is above itself on the way up from '$($Start.fullName)'; refused" }
        if ($climbed.Count -ge 64) { throw "More than 64 folders above '$($Start.fullName)'; refused" }
        $parent = & $GetFolder $parentId
        if ($null -eq $parent) { throw "Folder $parentId, the parent of '$($at.fullName)', could not be read" }
        if ([string]$parent.id -ne $parentId) { throw "Folder $parentId was asked for and folder '$($parent.id)' was answered; refused" }
        $seen[$parentId] = $true; $climbed = @($parent) + $climbed; $at = $parent
    }
    return $climbed   # bare: callers wrap with @(...)
}

function Get-FoldersOnThePath {
    <# Pure. The record of the folders on a path, the root first: id, name, path and category of each, and nothing
       else. Refused: a path that does not start at the root "$", and a folder whose path is not the path of the
       one before it and its own name. #>
    param($Chain)
    $records = @(@($Chain) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-PathFolder $_ })
    if ($records.Count -eq 0 -or $records[0]["path"] -cne '$') { throw "The folders on the path do not start at the root `$ (the first is '$(if ($records.Count) { $records[0]["path"] })'); refused" }
    for ($i = 1; $i -lt $records.Count; $i++) {
        $expected = $records[$i - 1]["path"] + "/" + $records[$i]["name"]
        if ($records[$i]["path"] -ine $expected) { throw "Folder $($records[$i]["id"]) is '$($records[$i]["path"])', not '$expected': the folders are not one path; refused" }
    }
    return $records   # bare: callers wrap with @(...)
}

function ConvertTo-FileRecord($Row) {
    # A file of the folder, from its row in folders/{id}/contents. A row that is not a version checked in has no check-in date.
    $standing = Get-VaultVersionStanding $Row.checkinDate
    [pscustomobject]@{ master_id = [string]$Row.file.id; version_id = [string]$Row.id; name = [string]$Row.name; version = $Row.version; revision = $Row.revision; state = $Row.state
        checkin_date = (Get-VaultCheckinDate $Row.checkinDate); version_is = $standing; checked_out_since = $(if ($standing -eq "check_out_place") { $Row.checkoutDate } else { $null })
        is_checked_out = $Row.isCheckedOut; is_hidden = $Row.isHidden; size = $Row.size; category = $Row.category; has_visualization_attachment = $Row.hasVisualizationAttachment }
}

function ConvertTo-Link($Row, [string]$Type) {
    # A parent or a child as an association names it: the file-version record of the other end.
    [pscustomobject]@{ master_id = [string]$Row.file.id; version_id = [string]$Row.id; version = $Row.version; name = [string]$Row.name; folder_id = [string]$Row.parentFolderId; state = $Row.state
        is_checked_out = $Row.isCheckedOut; version_is = (Get-VaultVersionStanding $Row.checkinDate); association_type = $Type }
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
    # ---- the folders on the path ----
    function Throws([scriptblock]$body, [string]$pattern) { try { & $body | Out-Null } catch { if ($_.Exception.Message -match $pattern) { return $true }; throw "threw '$($_.Exception.Message)', expected /$pattern/" }; throw "did not throw, expected /$pattern/" }
    function Folder($id, $name, $fullName, $category, $parentId) {
        $answer = [ordered]@{ id = "$id"; name = $name; fullName = $fullName; createUserName = "SOMEBODY ELSE"; subfolderCount = 3; properties = @([pscustomobject]@{ value = "SOMEBODY ELSE" }) }
        if ($category) { $answer["category"] = $category }; if ($parentId) { $answer["parentFolderId"] = "$parentId" }
        [pscustomobject]$answer
    }
    $top = Folder 1 '$' '$' $null $null
    $labs = Folder 10 "LABS" '$/LABS' "Documentation Folder" 1; $otherLab = Folder 11 "A LAB BESIDE" '$/A LAB BESIDE' "Documentation Folder" 1
    $lab = Folder 20 "LAB A" '$/LABS/LAB A' "Documentation Folder" 10; $labBeside = Folder 21 "ANOTHER LAB" '$/LABS/ANOTHER LAB' "Documentation Folder" 10
    $project = Folder 30 "PROJECT" '$/LABS/LAB A/PROJECT' "Project Folder" 20; $projectBeside = Folder 31 "A PROJECT BESIDE" '$/LABS/LAB A/A PROJECT BESIDE' "Project Folder" 20
    $listings = @{ "1" = @($otherLab, $labs); "10" = @($lab, $labBeside); "20" = @($projectBeside, $project) }
    $answers = @{ "1" = $top; "10" = $labs; "20" = $lab; "30" = $project }
    Case "D9 a walk by path records the folders on the path, the root first, with id, name, path and category, and nothing of what else a level holds" {
        $asked = New-Object System.Collections.ArrayList
        $chain = @(Resolve-FolderWalk $top @("labs", "LAB A", "PROJECT") { param($id) [void]$asked.Add($id); $listings[$id] })
        $records = @(Get-FoldersOnThePath $chain)
        Assert ((($records | ForEach-Object { "$($_["id"])=$($_["path"])" }) -join ";") -ceq '1=$;10=$/LABS;20=$/LABS/LAB A;30=$/LABS/LAB A/PROJECT') "the path: $(($records | ForEach-Object { "$($_["id"])=$($_["path"])" }) -join ';')"
        Assert (($asked -join ",") -eq "1,10,20") "listings asked: $($asked -join ',')"
        $written = ConvertTo-Json -InputObject $records -Depth 6
        Assert ($written -notmatch 'BESIDE|ANOTHER LAB|SOMEBODY ELSE|subfolderCount|properties') "something else of a level was kept: $written"
        Assert (@($records | Where-Object { (@($_.Keys) -join ",") -ne "id,name,path,category" }).Count -eq 0) "a folder has other fields than the four"
        Assert ($null -eq $records[0]["category"] -and $records[3]["category"] -ceq "Project Folder" -and $records[1]["name"] -ceq "LABS") "categories and names: $written"
        "three listings of two rows each: one row of each kept, and the root"
    }
    Case "D10 a segment that is not there, or there twice, and a level that cannot be listed, stop the walk" {
        Assert (Throws { Resolve-FolderWalk $top @("LABS", "NO SUCH LAB") { param($id) $listings[$id] } } "'NO SUCH LAB' not found exactly once under '\$/LABS'") "a missing segment passed"
        Assert (Throws { Resolve-FolderWalk $top @("LABS") { param($id) @($labs, $labs) } } "'LABS' not found exactly once") "a segment found twice passed"
        Assert (Throws { Resolve-FolderWalk $top @("LABS") { param($id) $null } } "'LABS' not found exactly once") "a level that could not be listed passed"
        Assert (@(Resolve-FolderWalk $top @() { param($id) throw "nothing is to be listed for the root itself" }).Count -eq 1) "the root alone is not a path of one folder"
    }
    Case "D11 a folder given by its id is followed upward by the parent each folder names; no level is listed" {
        $asked = New-Object System.Collections.ArrayList
        $chain = @(Resolve-FolderAncestors $project { param($id) [void]$asked.Add($id); $answers[$id] })
        $records = @(Get-FoldersOnThePath $chain)
        Assert ((($records | ForEach-Object { $_["id"] }) -join ",") -eq "1,10,20,30") "the path: $(($records | ForEach-Object { $_["id"] }) -join ',')"
        Assert (($asked -join ",") -eq "20,10,1") "folders asked: $($asked -join ',')"
        Assert ((ConvertTo-Json -InputObject $records -Depth 6) -notmatch 'SOMEBODY ELSE|parentFolderId') "more than the four fields was kept"
        Assert (@(Get-FoldersOnThePath @(Resolve-FolderAncestors $top { param($id) throw "the root has no parent to ask for" })).Count -eq 1) "the root alone"
        "three folders asked for, one after another; the root is the one without a parent"
    }
    Case "D12 the way up stops at a parent that cannot be read, at another folder than the one asked for, and at a folder that is above itself" {
        Assert (Throws { Resolve-FolderAncestors $project { param($id) if ($id -eq "10") { $null } else { $answers[$id] } } } "Folder 10, the parent of '\$/LABS/LAB A', could not be read") "an unreadable parent passed"
        Assert (Throws { Resolve-FolderAncestors $project { param($id) $answers["1"] } } "Folder 20 was asked for and folder '1' was answered") "another folder than the one asked for passed"
        $loopA = Folder 50 "A" '$/A' $null 51; $loopB = Folder 51 "B" '$/B' $null 50
        Assert (Throws { Resolve-FolderAncestors $loopA { param($id) if ($id -eq "51") { $loopB } else { $loopA } } } "Folder 50 is above itself") "a loop passed"
    }
    Case "D13 folders that are not one path from the root are refused" {
        Assert (Throws { Get-FoldersOnThePath @($labs, $lab) } "do not start at the root") "a path that starts below the root passed"
        Assert (Throws { Get-FoldersOnThePath @($top, $labs, $project) } "Folder 30 is '\$/LABS/LAB A/PROJECT', not '\$/LABS/PROJECT'") "a path with a level left out passed"
        Assert (Throws { Get-FoldersOnThePath @() } "do not start at the root") "no folder at all passed"
    }
    # ---- rows that are not versions checked in ----
    function Listed($master, $id, $number, $date, $name, $checkedOut, $checkoutDate) { [pscustomobject]@{ id = "$id"; name = $name; version = $number; checkinDate = $date; isCheckedOut = $checkedOut; checkoutDate = $checkoutDate; checkoutUserName = "SOMEBODY ELSE"; state = "Work in Progress"; parentFolderId = "30"; file = [pscustomobject]@{ id = "$master" } } }
    Case "D14 what a row is follows from its check-in date, not from isCheckedOut" {
        $cases = @(@("2026-08-14T21:54:28.797Z", "checked_in"), @("0001-01-01T00:00:00Z", "check_out_place"), @("0001-01-01T00:00:00", "check_out_place"), @($null, "no_check_in_date"), @("", "no_check_in_date"), @("not a date", "no_check_in_date"),
            @([DateTime]::MinValue, "check_out_place"), @((New-Object DateTime 2026, 8, 14), "checked_in"), @([DateTimeOffset]::MinValue, "check_out_place"))
        foreach ($pair in $cases) { $got = Get-VaultVersionStanding $pair[0]; Assert ($got -eq $pair[1]) "'$($pair[0])' is $got, expected $($pair[1])" }
        $earlier = ConvertTo-FileRecord (Listed 7 72 2 "2026-08-14T21:54:28.797Z" "RIG.iam" $true "2026-08-14T14:03:09.793Z")
        Assert ($earlier.version_is -eq "checked_in" -and $earlier.checkin_date -eq "2026-08-14T21:54:28.797Z" -and $null -eq $earlier.checked_out_since -and $earlier.is_checked_out -eq $true) "a version checked in of a file that is checked out: $($earlier | ConvertTo-Json -Compress)"
        "$($cases.Count) dates; isCheckedOut is true on every row of a checked-out file"
    }
    Case "D15 a file listed by the place of its check-out has no check-in date, says since when, and names no user" {
        $place = ConvertTo-FileRecord (Listed 7 73 3 "0001-01-01T00:00:00Z" "RIG.iam" $true "2026-08-18T18:19:12.86Z")
        Assert ($place.version_is -eq "check_out_place" -and $null -eq $place.checkin_date -and $place.checked_out_since -eq "2026-08-18T18:19:12.86Z" -and $place.version -eq 3 -and $place.version_id -eq "73") "the place: $($place | ConvertTo-Json -Compress)"
        Assert (($place | ConvertTo-Json -Compress) -notmatch 'SOMEBODY ELSE|0001-01-01') "the record names a user or keeps the date of year 1"
        $link = ConvertTo-Link (Listed 7 73 3 "0001-01-01T00:00:00Z" "RIG.iam" $true "2026-08-18T18:19:12.86Z") "Dependency"
        Assert ($link.version_is -eq "check_out_place" -and $link.association_type -eq "Dependency" -and $link.folder_id -eq "30") "the link: $($link | ConvertTo-Json -Compress)"
        Assert ((ConvertTo-Link (Listed 8 81 1 "2026-01-05T08:00:00Z" "PIN.ipt" $false $null) "Dependency").version_is -eq "checked_in") "a version checked in, as a link"
    }
    Case "D16 an assembly at a check-out place that nothing in scope uses is still a root" {
        $rig = ConvertTo-FileRecord (Listed 7 73 3 "0001-01-01T00:00:00Z" "RIG.iam" $true "2026-08-18T18:19:12.86Z")
        $pin = ConvertTo-FileRecord (Listed 8 81 1 "2026-01-05T08:00:00Z" "PIN.ipt" $false $null)
        $r = Roles @($rig, $pin) @{ "81" = @((ConvertTo-Link (Listed 7 73 3 "0001-01-01T00:00:00Z" "RIG.iam" $true "2026-08-18T18:19:12.86Z") "Dependency")) } @{ "73" = @((ConvertTo-Link (Listed 8 81 1 "2026-01-05T08:00:00Z" "PIN.ipt" $false $null) "Dependency")) } @("7", "8")
        Assert ($r["RIG.iam"].role -eq "root" -and $r["PIN.ipt"].role -eq "child" -and $r["PIN.ipt"].internal_parents[0].version_is -eq "check_out_place") "roles: $(($r.Values | ForEach-Object { $_.name + '=' + $_.role }) -join ', ')"
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
$folder = $null; $chain = @()
if ($FolderId) {
    # By its id: no level is listed. The folders above are read one by one, each by the parent the one below names.
    $folder = Get-Json "folders/$FolderId" $null; if (-not $folder) { throw "Folder $FolderId could not be read" }
    $chain = @(Resolve-FolderAncestors $folder { param($id) Get-Json "folders/$id" $null })
    $pathRead = "upward from the folder, GET folders/{id} of each folder above it; no level was listed"
}
else {
    # By its path: every level above it is listed. Of each listing the one row on the path is kept, and no other.
    $segments = @($FolderPath.Trim().TrimEnd('/') -split '/' | Where-Object { $_ })
    if ($segments[0] -ne '$') { throw "-FolderPath must start with `$/" }
    $top = Get-Json "folders/root" $null; if (-not $top) { throw "The root folder could not be read" }
    $chain = @(Resolve-FolderWalk $top @($segments | Select-Object -Skip 1) { param($id) Get-Pages "folders/$id/sub-folders" $null })
    $folder = Get-Json "folders/$($chain[-1].id)" $null; if (-not $folder) { throw "Folder $($chain[-1].id) could not be read" }
    $chain[-1] = $folder
    $pathRead = "downward from the root, GET folders/{id}/sub-folders of each folder above it; of each listing the one row on the path was kept"
}
if ($FolderPath -and ([string]$folder.fullName).TrimEnd('/') -ine $FolderPath.Trim().TrimEnd('/')) { throw "Folder $($folder.id) is '$($folder.fullName)', not '$FolderPath'" }
$foldersOnThePath = @(Get-FoldersOnThePath $chain)
if ($foldersOnThePath[-1]["id"] -ne [string]$folder.id) { throw "The folders on the path end at folder $($foldersOnThePath[-1]["id"]), not at folder $($folder.id)" }
Save-Raw "folder.json" $folder
$folderIdResolved = [string]$folder.id
Write-Output "Folder $folderIdResolved '$($folder.fullName)'"
Write-Output "Folders on the path: $(($foldersOnThePath | ForEach-Object { "$($_["name"]) $($_["id"])" }) -join ' > ')"
$subFolders = Get-Pages "folders/$folderIdResolved/sub-folders" $null
$contents = Get-Pages "folders/$folderIdResolved/contents" @{ "option[includeHidden]" = "true" }
if ($null -eq $contents) { throw "The folder contents could not be listed: $(($script:failures | Select-Object -Last 1).error)" }
Save-Raw "contents.json" @($contents)
$fileRecords = @($contents | Where-Object { [string]$_.entityType -ne "Folder" })
$assocQuery = @{ "option[includeHidden]" = "true"; "option[getLatestAssocs]" = "false" }
$files = @(); $parentsByVersion = @{}; $usesByVersion = @{}; $closures = @{}
foreach ($record in $fileRecords) {
    $versionId = [string]$record.id
    $files += ConvertTo-FileRecord $record
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
function Add-Path($link) { $path = Get-FolderPath $link.folder_id; [ordered]@{ master_id = $link.master_id; version_id = $link.version_id; version = $link.version; name = $link.name; vault_path = $(if ($path) { "$path/$($link.name)" } else { $null }); state = $link.state; is_checked_out = $link.is_checked_out; version_is = $link.version_is; association_type = $link.association_type } }
$byMaster = @{}; foreach ($file in $files) { $byMaster[$file.master_id] = $file }
$fileOutput = @()
foreach ($role in $roles) {
    $file = $byMaster[$role.master_id]
    $fileOutput += [ordered]@{ name = $file.name; kind = $role.kind; role = $role.role; master_id = $file.master_id; version_id = $file.version_id; version = $file.version; revision = $file.revision; lifecycle_state = $file.state
        checkin_date = $file.checkin_date; version_is = $file.version_is; checked_out_since = $file.checked_out_since; is_checked_out = $file.is_checked_out; is_hidden = $file.is_hidden; size = $file.size; category = $file.category; vault_path = "$($folder.fullName)/$($file.name)"
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
    $rootOutput += [ordered]@{ name = $role.name; master_id = $role.master_id; version_id = $role.version_id; version_is = $byMaster[$role.master_id].version_is; closure_read = $closures.ContainsKey($role.version_id); associations = $associations.Count
        closure_members_not_checked_in = @($closure | Where-Object { $_["version_is"] -ne "checked_in" } | ForEach-Object { $_["name"] })
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
    scope_masters = $scope.Count; closure_folders_outside = @($outside.Keys | Sort-Object | ForEach-Object { "$_ ($($outside[$_].Count))" }); files_with_unread_associations = $unread.Count
    folders_on_the_path = $foldersOnThePath.Count
    check_out_places = @($fileOutput | Where-Object { $_.version_is -eq "check_out_place" }).Count; files_at_a_check_out_place = @($fileOutput | Where-Object { $_.version_is -eq "check_out_place" } | ForEach-Object { $_.name })
    files_without_a_check_in_date = @($fileOutput | Where-Object { $_.version_is -eq "no_check_in_date" } | ForEach-Object { $_.name })
    roots_at_a_check_out_place = @($rootOutput | Where-Object { $_.version_is -eq "check_out_place" } | ForEach-Object { $_.name })
    roots_with_closure_members_not_checked_in = @($rootOutput | Where-Object { @($_.closure_members_not_checked_in).Count -gt 0 } | ForEach-Object { "$($_.name) ($(@($_.closure_members_not_checked_in).Count))" }) }
ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; generated_at = (Utc); vault_id = $VaultId; folder = [ordered]@{ id = $folderIdResolved; path = [string]$folder.fullName }
        folders_on_the_path = $foldersOnThePath; folders_on_the_path_read = $pathRead
        versions = "version_is says what the row is that the server lists for a file: checked_in, a version checked in; check_out_place, the place of a check-out (the file is checked out; the row has a check-in date of year 1, which is not recorded); no_check_in_date, a row without a date that can be read. is_checked_out is true on every row of a checked-out file and does not tell them apart"
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
Write-Output "Listed by the place of a check-out, not by a version checked in: $($summary.check_out_places) file(s) of the folder$(if ($summary.check_out_places) { ' (' + ($summary.files_at_a_check_out_place -join '; ') + ')' }); roots among them: $(if (@($summary.roots_at_a_check_out_place).Count) { $summary.roots_at_a_check_out_place -join '; ' } else { 'none' }); roots with such a member in the closure: $(if (@($summary.roots_with_closure_members_not_checked_in).Count) { $summary.roots_with_closure_members_not_checked_in -join '; ' } else { 'none' })"
Write-Output "Receipt status: $status"
if ($status -ne "complete") { exit 1 }
