<#
.SYNOPSIS
Record a Vault file version and the versions of its dependencies, and mirror them locally for conversion.

.DESCRIPTION
Read-only against Vault (Vault Data API, Windows-integrated session). For a root file-version id:
  1. reads the file-version object and its recursive child associations
     (GET /file-versions/{id}/uses?option[recurse]=true&option[getLatestAssocs]=false), following
     cursorState pagination; or, with -AsCheckedIn, rebuilds them by check-in date (see below);
  2. resolves every folder to its full Vault path and writes dependency-inventory.json
     (version id, master id, version number, state, folder, path, size, who references it);
  3. unless -NoDownload, downloads each exact file version into <CacheRoot>\<Vault path without $/>,
     refusing all existing destination files (use a fresh CacheRoot), and writes acquisition.json with SHA-256 per file.
The mirror root stands in for Vault's "$" so Inventor resolves relative references unchanged.
Never checks files out, never writes to Vault. The token stays in memory; neither it nor the session's id is
printed or recorded. Requests: one POST sessions/win-auth (the sign-in), then GET only. They are counted by kind
in snapshot-receipt.json, which is written with -NoDownload too.
Verified against Vault Professional Server 2025 (30.4) on 2026-10-21; DELETE /sessions returns 501 there.

WHICH VERSIONS OF THE CHILDREN. Observed on this server on 2026-11-16 (API 2.0.16): GET file-versions/{id}/uses
gives the children of exactly that version of the parent, but it gives every child at its LATEST version,
whatever getLatestAssocs and releaseBiased are set to; /parents answers the same way. For the latest version of a
root that is what "get latest" gives a user. For an earlier version it is a mix that never existed in Vault: the
old root with today's children, and with today's children of those.
-AsCheckedIn rebuilds what the root version was checked in with, by date: every child at its newest version
checked in at or before the root version, and that version's own children in the same way. Requests: GET
file-versions/{id}/uses without recursion for every version followed, GET files/{master}/versions for every
child. It is a rule applied to dates, not a record read from Vault; dependency-inventory.json says which of the
two ways was used ("resolution"), and a child without a version that early stops the run.

ONLY VERSIONS CHECKED IN ARE PINNED. A file that is checked out is named by the place of its check-out, a row with
a check-in date of year 1 that is not a version checked in (Vault-Version.ps1); the server names a checked-out
child that way under every parent. isCheckedOut is true on every row of a checked-out file and decides nothing here.
  - A ROOT that is such a row is refused before its closure is asked for: nothing is downloaded,
    snapshot-receipt.json has the status refused_check_out_place and names the file, and the exit code is 2.
  - A MEMBER that is such a row is taken at its last version checked in, the row before it in
    files/{master}/versions, and that version's own children are followed in place of the place's. It is what
    "get latest" gives everyone but the person who has the file checked out. Requests for each such member: GET
    files/{master}/versions and GET file-versions/{id}/uses with recursion for the version taken. The inventory
    says so of the member (stands_for_check_out_place: the id and number of the place, and since when), the
    receipt lists and counts them, and the status is complete. A member with no version checked in stops the run.
  - A row without a date that can be read is refused as before (refused_no_check_in_date).
With -AsCheckedIn a member is never such a row: the rule takes versions checked in only, so a child that is
checked out today comes at its newest version checked in by then.
    & .\windows\Get-VaultDependencySnapshot.ps1 -SelfTest      # offline cases for both rules
#>
param(
    [string]$RootVersionId,
    [string]$OutputDirectory,
    [string]$CacheRoot,
    [string]$BaseUri = "http://svault5/AutodeskDM/Services/api/vault/v2/",
    [string]$VaultName = "IDF VAULT",
    [string]$VaultId = "28",
    [string]$AppCode = "vault-cad-tools",
    [switch]$NoDownload,
    [switch]$AsCheckedIn,
    [switch]$SelfTest
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Vault-Version.ps1")

function Find-NotCheckedIn {
    <# Pure. Which rows of a closure are not versions checked in (Vault-Version.ps1). $Top: the file-version record
       of the root. $Rows: the association rows (parentFile, childFile), as the server gave them or as
       Resolve-ClosureByDate chose them. Returns one record for each such row, the root first, a member once with
       everything that uses it; nothing when every row is a version checked in. No user is named. #>
    param($Top, $Rows)
    $found = @(); $index = @{}
    $candidates = @([pscustomobject]@{ row = $Top; place = "root"; parent = $null })
    foreach ($association in @($Rows)) { if ($null -ne $association -and $null -ne $association.childFile) { $candidates += [pscustomobject]@{ row = $association.childFile; place = "member"; parent = $association.parentFile } } }
    foreach ($candidate in $candidates) {
        $standing = Get-VaultVersionStanding $candidate.row.checkinDate
        if ($standing -eq "checked_in") { continue }
        $id = [string]$candidate.row.id
        if (-not $index.ContainsKey($id)) {
            $index[$id] = [pscustomobject]@{ version_id = $id; master_id = [string]$candidate.row.file.id; name = [string]$candidate.row.name; version = $candidate.row.version; as = $candidate.place; version_is = $standing
                checked_out_since = $(if ($standing -eq "check_out_place") { $candidate.row.checkoutDate } else { $null }); folder_id = [string]$candidate.row.parentFolderId; used_by = @() }
            $found += $index[$id]
        }
        if ($null -ne $candidate.parent) { $user = "$($candidate.parent.name)@$($candidate.parent.id)"; if ($index[$id].used_by -notcontains $user) { $index[$id].used_by += $user } }
    }
    return $found   # bare: callers wrap with @(...)
}

function Select-RowsReachedFromTheRoot {
    <# Pure. The association rows that are reached from the root by following parent to child, each once, in the
       order given. A row whose parent is reached no more (because that parent was exchanged for another version)
       is left out, with everything that hung below it and is reached no other way. #>
    param($Top, $Rows)
    $byParent = @{}
    foreach ($row in @($Rows)) { if ($null -eq $row) { continue }; $parentId = [string]$row.parentFile.id; if (-not $byParent.ContainsKey($parentId)) { $byParent[$parentId] = @() }; $byParent[$parentId] += $row }
    $reached = @{}; $pending = New-Object System.Collections.Queue; $pending.Enqueue([string]$Top.id)
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if ($reached.ContainsKey($current)) { continue }; $reached[$current] = $true
        foreach ($row in @($byParent[$current])) { if ($null -ne $row) { $pending.Enqueue([string]$row.childFile.id) } }
    }
    $kept = @(); $listed = @{}
    foreach ($row in @($Rows)) {
        if ($null -eq $row -or -not $reached.ContainsKey([string]$row.parentFile.id)) { continue }
        $key = "$($row.parentFile.id)|$($row.childFile.id)|$($row.fileAssocType)"
        if ($listed.ContainsKey($key)) { continue }; $listed[$key] = $true
        $kept += $row
    }
    return $kept   # bare: callers wrap with @(...)
}

function Resolve-ClosureAtLastCheckIn {
    <# Pure: it sends nothing itself. The closure of a root as the server answers it, with every member that is the
       place of a check-out taken at its last version checked in, and that version's own children followed in
       place of the place's.
       $Top: the file-version record of the root, a version checked in. $Rows: the rows of GET
       file-versions/{root}/uses with recursion (parentFile, childFile, fileAssocType). $GetUses: script block,
       version id -> the rows of the same request for that version. $GetVersions: script block, master id -> every
       row of GET files/{master}/versions. Both throw when the server cannot be read.
       Returns rows (when nothing was exchanged: the rows as given; otherwise the rows reached from the root after
       the exchange, each once; a row whose child was exchanged says which place it stands for) and taken (one
       record for each member exchanged, with what uses it; no user is named).
       Left for the caller to refuse: a row without a check-in date that can be read.
       Refused here: a member of which the server lists no version checked in, and the root's own file as a member. #>
    param($Top, $Rows, [scriptblock]$GetUses, [scriptblock]$GetVersions)
    $edges = @(@($Rows) | Where-Object { $null -ne $_ }); $taken = @(); $exchanged = @{}
    while ($true) {
        $place = $null
        foreach ($row in $edges) { if ((Get-VaultVersionStanding $row.childFile.checkinDate) -eq "check_out_place" -and -not $exchanged.ContainsKey([string]$row.childFile.id)) { $place = $row.childFile; break } }
        if ($null -eq $place) { break }
        $placeId = [string]$place.id; $master = [string]$place.file.id; $exchanged[$placeId] = $true
        if ($master -eq [string]$Top.file.id) { throw "'$($place.name)' is the root's own file, named as a member at the place of a check-out; refused" }
        $versions = @(& $GetVersions $master | Where-Object { $null -ne $_ })
        $checkedIn = @($versions | Where-Object { (Get-VaultVersionStanding $_.checkinDate) -eq "checked_in" } | Sort-Object { [int]$_.version })
        if ($checkedIn.Count -eq 0) { throw "'$($place.name)' (master $master) is checked out and the server lists no version of it that was checked in; refused" }
        $last = $checkedIn[-1]
        if ([int]$last.version -ge [int]$place.version) { throw "'$($place.name)' (master $master): the last version checked in has the number $($last.version) and the place of the check-out $($place.version); refused" }
        $usedBy = @(); $replaced = @()
        foreach ($row in $edges) {
            if ([string]$row.childFile.id -ne $placeId) { $replaced += $row; continue }
            $user = "$($row.parentFile.name)@$($row.parentFile.id)"; if ($usedBy -notcontains $user) { $usedBy += $user }
            $replaced += [pscustomobject]@{ id = $row.id; fileAssocType = $row.fileAssocType; parentFile = $row.parentFile; childFile = $last; stands_for_version_id = $placeId }
        }
        # that version's own children, in place of the place's; what hung below the place and is reached no other way goes
        $own = @(& $GetUses ([string]$last.id) | Where-Object { $null -ne $_ })
        $edges = @(Select-RowsReachedFromTheRoot $Top (@($replaced) + @($own)))
        $taken += [pscustomobject]@{ name = [string]$place.name; master_id = $master; taken_version_id = [string]$last.id; taken_version = $last.version; taken_checkin_date = $last.checkinDate
            stands_for_version_id = $placeId; stands_for_version = $place.version; checked_out_since = $place.checkoutDate; used_by = $usedBy }
    }
    return [pscustomobject]@{ rows = $edges; taken = $taken }
}

function Resolve-ClosureByDate {
    <# What a version of a file used when it was checked in, rebuilt by date. Pure: it sends nothing itself.
       $Top: the file-version record of the root. $GetUses: script block, version id -> the rows of GET
       file-versions/{id}/uses WITHOUT recursion (parentFile, childFile, fileAssocType): the children of exactly
       that version, each as the server names it. $GetVersions: script block, master id -> every version record of
       that master. Both throw when the server cannot be read; no rows means no children.
       Returns rows shaped like the server's (parentFile, childFile, fileAssocType, id), where childFile is the
       version chosen, with reported_version_id beside it: the version the server named.
       A row that is not a version checked in (the place of a check-out, whose date is of year 1 and so "before"
       every root) is never chosen and never the root.
       Refused: a child with no version checked in at or before the root version, and a master without versions. #>
    param($Top, [scriptblock]$GetUses, [scriptblock]$GetVersions)
    if ((Get-VaultVersionStanding $Top.checkinDate) -ne "checked_in") { throw "'$($Top.name)' version $($Top.id) is not a version checked in (check-in date '$($Top.checkinDate)'): there is no date to rebuild by; refused" }
    $moment = [DateTimeOffset]::Parse([string]$Top.checkinDate, [Globalization.CultureInfo]::InvariantCulture)
    $rows = @(); $followed = @{}; $pending = New-Object System.Collections.Queue
    $pending.Enqueue($Top)
    while ($pending.Count -gt 0) {
        $parent = $pending.Dequeue()
        if ($followed.ContainsKey([string]$parent.id)) { continue }
        $followed[[string]$parent.id] = $true
        foreach ($row in @(& $GetUses ([string]$parent.id))) {
            $reported = $row.childFile; $master = [string]$reported.file.id
            if ($master -eq [string]$Top.file.id) { throw "'$($parent.name)' version $($parent.id) uses the root itself; refused" }
            $all = @(& $GetVersions $master)
            if ($all.Count -eq 0) { throw "The server listed no version of '$($reported.name)' (master $master); refused" }
            $early = @($all | Where-Object { (Get-VaultVersionStanding $_.checkinDate) -eq "checked_in" } | Where-Object { [DateTimeOffset]::Parse([string]$_.checkinDate, [Globalization.CultureInfo]::InvariantCulture) -le $moment } | Sort-Object { [int]$_.version })
            if ($early.Count -eq 0) { throw "'$($reported.name)' has no version checked in at or before $($Top.checkinDate), when '$($Top.name)' version $($Top.id) was checked in; refused" }
            $chosen = $early[-1]
            $rows += [pscustomobject]@{ id = $row.id; fileAssocType = $row.fileAssocType; parentFile = $parent; childFile = $chosen; reported_version_id = [string]$reported.id }
            $pending.Enqueue($chosen)
        }
    }
    return $rows   # bare: callers wrap with @(...)
}

if ($SelfTest) {
    $results = @()
    function Case($name, [scriptblock]$body) {
        try { $detail = & $body; $script:results += [ordered]@{ case = $name; passed = $true; detail = "$detail" }; Write-Output "PASS $name $(if ($detail) { "- $detail" })" }
        catch { $script:results += [ordered]@{ case = $name; passed = $false; detail = $_.Exception.Message }; Write-Output "FAIL $name - $($_.Exception.Message)" }
    }
    function Assert($cond, $msg) { if (-not $cond) { throw $msg } }
    function Throws([scriptblock]$body, [string]$pattern) { try { & $body | Out-Null } catch { if ($_.Exception.Message -match $pattern) { return $true }; throw "threw '$($_.Exception.Message)', expected /$pattern/" }; throw "did not throw, expected /$pattern/" }
    function Version($master, $id, $number, $date, $name) { [pscustomobject]@{ id = "$id"; version = $number; checkinDate = $date; name = $name; file = [pscustomobject]@{ id = "$master" } } }
    function Row($parent, $child) { [pscustomobject]@{ id = "assoc-$($parent.id)-$($child.file.id)"; fileAssocType = "Dependency"; parentFile = $parent; childFile = $child } }
    # A root with two versions; a frame with three, the last checked in after the root's first; a pin; a clip that came later.
    $rootOld = Version 1 11 1 "2026-01-20T10:00:05.5Z" "ROOT.iam"; $rootNew = Version 1 12 2 "2026-03-01T09:00:10Z" "ROOT.iam"
    $frame1 = Version 2 21 1 "2026-01-05T08:00:00Z" "FRAME.iam"; $frame2 = Version 2 22 2 "2026-01-20T10:00:05.5Z" "FRAME.iam"; $frame3 = Version 2 23 3 "2026-03-01T09:00:02Z" "FRAME.iam"
    $pin = Version 3 31 1 "2025-12-01T00:00:00Z" "PIN.ipt"; $clip = Version 4 41 1 "2026-02-10T00:00:00Z" "CLIP.ipt"
    $versionsOf = @{ "1" = @($rootOld, $rootNew); "2" = @($frame3, $frame1, $frame2); "3" = @($pin); "4" = @($clip) }
    # the server names every child at its latest version: the frame as version 3 under the old root as well
    $usesOf = @{ "11" = @((Row $rootOld $frame3)); "12" = @((Row $rootNew $frame3)); "21" = @((Row $frame1 $pin)); "22" = @((Row $frame2 $pin)); "23" = @((Row $frame3 $pin), (Row $frame3 $clip)); "31" = @(); "41" = @() }
    $getUses = { param($id) if (-not $usesOf.ContainsKey($id)) { throw "uses of $id not readable" }; $usesOf[$id] }
    $getVersions = { param($master) $versionsOf[$master] }
    Case "S1 a child is taken at its newest version checked in at or before the root version, not at the one the server names" {
        $rows = @(Resolve-ClosureByDate $rootOld $getUses $getVersions)
        $frame = @($rows | Where-Object { $_.childFile.name -eq "FRAME.iam" })
        Assert ($frame.Count -eq 1 -and $frame[0].childFile.id -eq "22" -and $frame[0].reported_version_id -eq "23" -and $frame[0].parentFile.id -eq "11") "frame: $($frame | ConvertTo-Json -Compress -Depth 4)"
        "version 2, checked in at the same instant as the root, where the server names version 3"
    }
    Case "S2 the children of the version chosen are followed, not those of the version the server names" {
        $rows = @(Resolve-ClosureByDate $rootOld $getUses $getVersions)
        $names = @($rows | ForEach-Object { $_.childFile.name }) -join ","
        Assert ($names -eq "FRAME.iam,PIN.ipt" -and @($rows | Where-Object { $_.childFile.name -eq "PIN.ipt" })[0].parentFile.id -eq "22") "children: $names"
        "the clip, which the frame gained in version 3, is not in the closure of the old root"
    }
    Case "S3 the latest root gives what the server gives: every child at the version the server names" {
        $rows = @(Resolve-ClosureByDate $rootNew $getUses $getVersions)
        Assert ($rows.Count -eq 3 -and @($rows | Where-Object { [string]$_.childFile.id -ne $_.reported_version_id }).Count -eq 0) "rows: $($rows | ForEach-Object { $_.childFile.name + '@' + $_.childFile.id })"
    }
    Case "S4 a child with no version checked in early enough stops the run" {
        $tooOld = Version 1 10 0 "2025-01-01T00:00:00Z" "ROOT.iam"
        $table = @{ "10" = @((Row $tooOld $frame3)) }
        Assert (Throws { Resolve-ClosureByDate $tooOld { param($id) $table[$id] } $getVersions } "FRAME\.iam' has no version checked in at or before 2025-01-01") "a child that did not exist yet was taken"
    }
    Case "S5 a master without versions, and a version whose children cannot be read, stop the run" {
        Assert (Throws { Resolve-ClosureByDate $rootOld $getUses { param($master) @() } } "listed no version of 'FRAME\.iam'") "a master without versions passed"
        Assert (Throws { Resolve-ClosureByDate $rootOld { param($id) throw "404" } $getVersions } "404") "children that could not be read passed as none"
    }
    Case "S6 a file that uses nothing gives no rows, and a root that is listed as its own child is refused" {
        Assert (@(Resolve-ClosureByDate $pin $getUses $getVersions).Count -eq 0) "a part without children gave rows"
        $loop = @{ "11" = @((Row $rootOld $rootNew)) }
        Assert (Throws { Resolve-ClosureByDate $rootOld { param($id) $loop[$id] } $getVersions } "uses the root itself") "a root used by itself passed"
    }
    # ---- rows that are not versions checked in ----
    function Place($master, $id, $number, $name, $since) { [pscustomobject]@{ id = "$id"; version = $number; checkinDate = "0001-01-01T00:00:00Z"; name = $name; isCheckedOut = $true; checkoutDate = $since; checkoutUserName = "SOMEBODY ELSE"; parentFolderId = "30"; file = [pscustomobject]@{ id = "$master" } } }
    Case "S7 a row with a check-in date of year 1 is the place of a check-out, whatever isCheckedOut says" {
        $cases = @(@("2026-08-14T21:54:28.797Z", "checked_in"), @("0001-01-01T00:00:00Z", "check_out_place"), @($null, "no_check_in_date"), @("", "no_check_in_date"), @("soon", "no_check_in_date"), @([DateTime]::MinValue, "check_out_place"))
        foreach ($pair in $cases) { $got = Get-VaultVersionStanding $pair[0]; Assert ($got -eq $pair[1]) "'$($pair[0])' is $got, expected $($pair[1])" }
        $earlier = Version 5 51 1 "2026-02-01T00:00:00Z" "RIG.iam"; $earlier | Add-Member -NotePropertyName isCheckedOut -NotePropertyValue $true
        Assert (@(Find-NotCheckedIn $earlier @()).Count -eq 0) "a version checked in of a file that is checked out was taken for the place of the check-out"
        "$($cases.Count) dates"
    }
    Case "S8 a root that is the place of a check-out is found, with since when and without a user's name" {
        $found = @(Find-NotCheckedIn (Place 5 52 2 "RIG.iam" "2026-08-18T18:19:12.86Z") @())
        Assert ($found.Count -eq 1 -and $found[0].as -eq "root" -and $found[0].version_is -eq "check_out_place" -and $found[0].name -eq "RIG.iam" -and $found[0].version_id -eq "52" -and $found[0].master_id -eq "5" -and $found[0].checked_out_since -eq "2026-08-18T18:19:12.86Z") "found: $($found | ConvertTo-Json -Compress -Depth 4)"
        Assert (($found | ConvertTo-Json -Compress -Depth 4) -notmatch "SOMEBODY ELSE") "the record names a user"
    }
    Case "S9 a member that is the place of a check-out is found once, with every parent that uses it; a closure of versions checked in gives nothing" {
        $platePlace = Place 6 62 2 "PLATE.ipt" "2026-09-01T10:00:00Z"
        $rows = @((Row $rootNew $frame3), (Row $rootNew $platePlace), (Row $frame3 $pin), (Row $frame3 $platePlace))
        $found = @(Find-NotCheckedIn $rootNew $rows)
        Assert ($found.Count -eq 1 -and $found[0].as -eq "member" -and $found[0].name -eq "PLATE.ipt" -and $found[0].version_id -eq "62" -and (@($found[0].used_by) -join ",") -eq "ROOT.iam@12,FRAME.iam@23") "found: $($found | ConvertTo-Json -Compress -Depth 4)"
        Assert (@(Find-NotCheckedIn $rootNew @((Row $rootNew $frame3), (Row $frame3 $pin), (Row $frame3 $clip))).Count -eq 0) "versions checked in were found"
        $undated = [pscustomobject]@{ id = "71"; version = 1; name = "ODD.ipt"; file = [pscustomobject]@{ id = "7" } }
        $odd = @(Find-NotCheckedIn $rootNew @((Row $rootNew $undated)))
        Assert ($odd.Count -eq 1 -and $odd[0].version_is -eq "no_check_in_date" -and $null -eq $odd[0].checked_out_since) "a row without a check-in date: $($odd | ConvertTo-Json -Compress -Depth 4)"
        Assert (@(Find-NotCheckedIn (Place 5 52 2 "RIG.iam" "2026-08-18T18:19:12.86Z") @((Row $rootNew $platePlace))).Count -eq 2) "the root and a member, both"
    }
    Case "S10 by check-in date a child that is checked out today comes at its newest version checked in, never at the place of its check-out" {
        $plate1 = Version 6 61 1 "2026-02-20T00:00:00Z" "PLATE.ipt"; $platePlace = Place 6 62 2 "PLATE.ipt" "2026-09-01T10:00:00Z"
        $table = @{ "12" = @((Row $rootNew $platePlace)); "61" = @(); "62" = @() }
        $rows = @(Resolve-ClosureByDate $rootNew { param($id) $table[$id] } { param($master) @($platePlace, $plate1) })
        Assert ($rows.Count -eq 1 -and $rows[0].childFile.id -eq "61" -and $rows[0].reported_version_id -eq "62") "rows: $($rows | ForEach-Object { $_.childFile.name + '@' + $_.childFile.id })"
        Assert (@(Find-NotCheckedIn $rootNew $rows).Count -eq 0) "the version chosen is not a version checked in"
        Assert (Throws { Resolve-ClosureByDate $rootNew { param($id) $table[$id] } { param($master) @($platePlace) } } "PLATE\.ipt' has no version checked in at or before") "a file with nothing but the place of a check-out was taken"
        "version 1, where the server names the place of the check-out as version 2"
    }
    Case "S11 by check-in date a root that is the place of a check-out is refused: there is no date to rebuild by" {
        Assert (Throws { Resolve-ClosureByDate (Place 5 52 2 "RIG.iam" "2026-08-18T18:19:12.86Z") $getUses $getVersions } "RIG\.iam' version 52 is not a version checked in") "the place of a check-out was taken as a root"
    }
    # ---- a member at the place of a check-out, taken at its last version checked in ----
    # A bracket in three rows: versions 1 and 2 checked in, and the place of a check-out as "version 3". Version 2
    # uses the pin and the clip; the place is listed with the pin and a part that was never checked in with it.
    $bracket1 = Version 8 81 1 "2026-01-10T00:00:00Z" "BRACKET.iam"; $bracket2 = Version 8 82 2 "2026-02-10T00:00:00Z" "BRACKET.iam"; $bracketPlace = Place 8 83 3 "BRACKET.iam" "2026-09-01T10:00:00Z"
    $washer = Version 9 91 1 "2026-01-02T00:00:00Z" "WASHER.ipt"
    $rowsOfTheRoot = @((Row $rootNew $frame3), (Row $rootNew $bracketPlace), (Row $frame3 $pin), (Row $frame3 $clip), (Row $bracketPlace $pin), (Row $bracketPlace $washer))
    $usesAgain = @{ "82" = @((Row $bracket2 $pin), (Row $bracket2 $clip)) }
    $versionsAgain = @{ "8" = @($bracketPlace, $bracket1, $bracket2) }
    Case "S12 a member that is the place of a check-out is taken at its last version checked in, with that version's children and not the place's" {
        $asked = New-Object System.Collections.ArrayList
        $closure = Resolve-ClosureAtLastCheckIn $rootNew $rowsOfTheRoot { param($id) [void]$asked.Add("uses $id"); if (-not $usesAgain.ContainsKey($id)) { throw "uses of $id not readable" }; $usesAgain[$id] } { param($master) [void]$asked.Add("versions $master"); $versionsAgain[$master] }
        $children = @($closure.rows | ForEach-Object { "$($_.parentFile.name)@$($_.parentFile.id)>$($_.childFile.name)@$($_.childFile.id)" })
        Assert (($children -join ";") -ceq "ROOT.iam@12>FRAME.iam@23;ROOT.iam@12>BRACKET.iam@82;FRAME.iam@23>PIN.ipt@31;FRAME.iam@23>CLIP.ipt@41;BRACKET.iam@82>PIN.ipt@31;BRACKET.iam@82>CLIP.ipt@41") "rows: $($children -join ';')"
        Assert (@($closure.rows | Where-Object { $_.childFile.name -eq "WASHER.ipt" -or [string]$_.childFile.id -eq "83" -or [string]$_.parentFile.id -eq "83" }).Count -eq 0) "something of the place is left"
        $one = @($closure.taken)
        Assert ($one.Count -eq 1 -and $one[0].name -eq "BRACKET.iam" -and $one[0].taken_version_id -eq "82" -and $one[0].taken_version -eq 2 -and $one[0].stands_for_version_id -eq "83" -and $one[0].stands_for_version -eq 3 -and $one[0].checked_out_since -eq "2026-09-01T10:00:00Z" -and (@($one[0].used_by) -join ",") -eq "ROOT.iam@12") "taken: $($one | ConvertTo-Json -Compress -Depth 4)"
        Assert (@($closure.rows | Where-Object { $_.stands_for_version_id -eq "83" }).Count -eq 1 -and (($closure | ConvertTo-Json -Compress -Depth 6) -notmatch "SOMEBODY ELSE") -and ($asked -join ",") -eq "versions 8,uses 82") "the row exchanged, a user's name, or the requests: $($asked -join ',')"
        Assert (@(Find-NotCheckedIn $rootNew $closure.rows).Count -eq 0) "a row that is not a version checked in is left"
        "version 2 for the place that is listed as version 3; two requests"
    }
    Case "S13 a closure of versions checked in is given back as it came, and nothing is asked" {
        $plain = @((Row $rootNew $frame3), (Row $frame3 $pin), (Row $frame3 $clip))
        $closure = Resolve-ClosureAtLastCheckIn $rootNew $plain { param($id) throw "nothing is to be asked" } { param($master) throw "nothing is to be asked" }
        Assert (@($closure.taken).Count -eq 0 -and @($closure.rows).Count -eq 3 -and [object]::ReferenceEquals($closure.rows[0], $plain[0]) -and [object]::ReferenceEquals($closure.rows[2], $plain[2])) "rows: $(@($closure.rows).Count), taken: $(@($closure.taken).Count)"
    }
    Case "S14 a part that the place and another parent both use stays; a second place below the version taken is exchanged too" {
        $lever1 = Version 10 101 1 "2026-01-03T00:00:00Z" "LEVER.ipt"; $leverPlace = Place 10 102 2 "LEVER.ipt" "2026-09-02T10:00:00Z"
        $rows = @((Row $rootNew $bracketPlace), (Row $rootNew $washer), (Row $bracketPlace $washer))
        $closure = Resolve-ClosureAtLastCheckIn $rootNew $rows { param($id) if ($id -eq "82") { @((Row $bracket2 $leverPlace)) } elseif ($id -eq "101") { @() } else { throw "uses of $id not readable" } } { param($master) if ($master -eq "8") { @($bracket1, $bracket2, $bracketPlace) } else { @($lever1, $leverPlace) } }
        $children = @($closure.rows | ForEach-Object { "$($_.parentFile.id)>$($_.childFile.name)@$($_.childFile.id)" })
        Assert (($children -join ";") -ceq "12>BRACKET.iam@82;12>WASHER.ipt@91;82>LEVER.ipt@101") "rows: $($children -join ';')"
        Assert ((@($closure.taken | ForEach-Object { "$($_.name):$($_.taken_version_id) for $($_.stands_for_version_id)" }) -join ";") -ceq "BRACKET.iam:82 for 83;LEVER.ipt:101 for 102") "taken: $($closure.taken | ConvertTo-Json -Compress -Depth 4)"
    }
    Case "S15 a member with nothing but the place of a check-out, and versions or children that cannot be read, stop the run; a row without a date is left for the caller to refuse" {
        Assert (Throws { Resolve-ClosureAtLastCheckIn $rootNew @((Row $rootNew $bracketPlace)) { param($id) @() } { param($master) @($bracketPlace) } } "BRACKET\.iam' \(master 8\) is checked out and the server lists no version of it that was checked in") "a file with no version checked in was taken"
        Assert (Throws { Resolve-ClosureAtLastCheckIn $rootNew @((Row $rootNew $bracketPlace)) { param($id) @() } { param($master) throw "versions not readable" } } "versions not readable") "versions that could not be read passed"
        Assert (Throws { Resolve-ClosureAtLastCheckIn $rootNew @((Row $rootNew $bracketPlace)) { param($id) throw "uses not readable" } { param($master) @($bracket1, $bracket2, $bracketPlace) } } "uses not readable") "children that could not be read passed as none"
        $undated = [pscustomobject]@{ id = "71"; version = 1; name = "ODD.ipt"; file = [pscustomobject]@{ id = "7" } }
        $closure = Resolve-ClosureAtLastCheckIn $rootNew @((Row $rootNew $undated)) { param($id) throw "nothing is to be asked" } { param($master) throw "nothing is to be asked" }
        Assert (@($closure.taken).Count -eq 0 -and @(Find-NotCheckedIn $rootNew $closure.rows).Count -eq 1) "a row without a date was exchanged or lost"
        $later = Version 8 84 4 "2026-10-01T00:00:00Z" "BRACKET.iam"
        Assert (Throws { Resolve-ClosureAtLastCheckIn $rootNew @((Row $rootNew $bracketPlace)) { param($id) @() } { param($master) @($bracket2, $bracketPlace, $later) } } "the last version checked in has the number 4 and the place of the check-out 3") "a version checked in above the place passed"
    }
    $passed = @($results | Where-Object passed).Count; $failed = @($results | Where-Object { -not $_.passed }).Count
    Write-Output "$passed passed, $failed failed"
    if ($failed -gt 0) { exit 1 }
    return
}

foreach ($required in @("RootVersionId", "OutputDirectory")) { if (-not (Get-Variable -Name $required -ValueOnly)) { throw "-$required is required" } }
$endpoint = [Uri]$BaseUri
if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -notin @("http", "https") -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment) { throw "BaseUri must be an HTTP(S) URL without credentials, query, or fragment." }
if (-not $NoDownload -and -not $CacheRoot) { throw "Supply -CacheRoot or -NoDownload" }
$B = $BaseUri.TrimEnd('/')
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
function Utc { [DateTime]::UtcNow.ToString("o") }
# Windows credentials and the returned token must not travel through an ambient HTTP proxy (P4).
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy
$started = Utc
# Every request this script sends, by kind. The sign-in is the one request that is not a GET.
$requests = [ordered]@{ sign_in_post = 0; get = 0; download_get = 0 }
$root = $null; $list = @(); $uses = @{ results = @(); pages = $null; total = 0 }; $resolution = $null; $notCheckedIn = @(); $taken = @()

$body = @{ input = @{ vault = $VaultName; appCode = $AppCode } } | ConvertTo-Json -Depth 3
$requests["sign_in_post"]++
$session = Invoke-RestMethod -Uri "$B/sessions/win-auth" -Method Post -ContentType "application/json" -Body $body -UseDefaultCredentials -MaximumRedirection 0 -TimeoutSec 30
if (-not $session.accessToken) { throw "win-auth returned no access token" }
$h = @{ Authorization = "Bearer $($session.accessToken)" }
Write-Output "Signed in as '$($session.userInformation.name)' on vault '$($session.vaultInformation.name)' (id $($session.vaultInformation.id)); the token and the session's id are not shown"
if ([string]$session.vaultInformation.id -ne $VaultId) { throw "Signed into vault id $($session.vaultInformation.id), expected $VaultId" }
function GetJ($rel) { $requests["get"]++; Invoke-RestMethod -Uri "$B/$rel" -Headers $h -MaximumRedirection 0 -TimeoutSec 120 }
function Write-SnapshotReceipt([string]$status, [int]$downloaded, [int]$failed) {
    [ordered]@{ schema_version = 1; script = "windows/Get-VaultDependencySnapshot.ps1"; status = $status; started_at = $started; finished_at = (Utc); host = $env:COMPUTERNAME
        method = "one POST sessions/win-auth (the sign-in, Windows-integrated; its token and the session's id are not recorded), then GET only: file-versions/{id}, file-versions/{id}/uses, files/{master}/versions (with -AsCheckedIn, and for a member that is checked out), folders/{id}, and file-versions/{id}/content for every download"
        requests = $requests; root_version_id = $RootVersionId; root_name = $root.name; root_version = $root.version; files_in_the_inventory = $list.Count; association_count = $uses.results.Count
        resolution = $resolution; as_checked_in = [bool]$AsCheckedIn; children_at_another_version_than_the_server_names = $(if ($AsCheckedIn) { $moved.Count } else { $null })
        not_checked_in = @($notCheckedIn)
        members_taken_at_their_last_check_in = @($taken).Count; taken_at_their_last_check_in = @($taken)
        no_download = [bool]$NoDownload; cache_root = $(if ($NoDownload -or -not (Test-Path -LiteralPath $CacheRoot)) { $null } else { (Resolve-Path -LiteralPath $CacheRoot).Path }); downloaded = $downloaded; problems = $failed } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory "snapshot-receipt.json") -Encoding UTF8
}
function Stop-NotCheckedIn {
    # Nothing is pinned and nothing downloaded: the files are named, the receipt says why, and the run ends with 2.
    $status = $(if (@($notCheckedIn | Where-Object { $_.version_is -eq "check_out_place" }).Count -gt 0) { "refused_check_out_place" } else { "refused_no_check_in_date" })
    foreach ($entry in $notCheckedIn) {
        $what = $(if ($entry.version_is -eq "check_out_place") { "the place of a check-out$(if ($entry.checked_out_since) { " since $($entry.checked_out_since)" }), not a version checked in" } else { "a row without a check-in date that can be read" })
        Write-Output "REFUSED $($entry.as) '$($entry.name)' (version id $($entry.version_id), master $($entry.master_id)$(if ($entry.vault_path) { ", $($entry.vault_path)" })): $what$(if (@($entry.used_by).Count) { "; used by $(@($entry.used_by) -join ', ')" })"
    }
    Write-SnapshotReceipt $status 0 0
    Write-Output "Status: $status. Nothing was downloaded. Requests: $($requests["sign_in_post"]) sign-in, $($requests["get"]) GET, $($requests["download_get"]) download"
    exit 2
}
function GetOnePage($rel) {
    # ONE page, never a cursor: this server's paging cursor repeats and skips rows (Discover-VaultFolder.ps1).
    # An answer without rows of its own, or a listing that does not fit one page, is refused.
    $answer = GetJ $rel
    if ($null -eq $answer -or -not $answer.PSObject.Properties["results"]) { throw "The answer to '$rel' has no results; refused" }
    $rows = @($answer.results); $total = $null; $more = $false
    try { if ($null -ne $answer.pagination.totalResults) { $total = [int]$answer.pagination.totalResults } } catch { }
    try { $more = [bool]$answer.pagination.nextUrl } catch { }
    if ($more -or ($null -ne $total -and $rows.Count -ne $total)) { throw "The listing '$rel' does not fit one page ($($rows.Count) of $total); refused" }
    return $rows   # bare: callers wrap with @(...)
}
function GetAll($rel) {
    $all = @(); $cursor = $null; $pages = 0
    do {
        $url = $rel; if ($cursor) { $url += "&cursorState=" + [uri]::EscapeDataString($cursor) }
        $r = GetJ $url; $pages++
        $all += @($r.results)
        $cursor = $r.pagination.cursorState
    } while ($cursor)
    return @{ results = $all; pages = $pages; total = $r.pagination.totalResults }
}

$root = GetJ "vaults/$VaultId/file-versions/$RootVersionId"
$root | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "file-version-$RootVersionId.json") -Encoding UTF8
$moved = @()
# The root must be a version checked in. If it is not, its closure is not asked for.
$notCheckedIn = @(Find-NotCheckedIn $root @())
if ($notCheckedIn.Count -gt 0) { Stop-NotCheckedIn }
if ($AsCheckedIn) {
    $versionLists = @{}
    $byDate = @(Resolve-ClosureByDate $root { param($id) GetOnePage "vaults/$VaultId/file-versions/$id/uses?option%5BgetLatestAssocs%5D=false&limit=1000" } {
            param($master) if (-not $versionLists.ContainsKey($master)) { $versionLists[$master] = @(GetOnePage "vaults/$VaultId/files/$master/versions?limit=1000") }; $versionLists[$master] })
    $uses = @{ results = $byDate; pages = $null; total = $byDate.Count }
    ConvertTo-Json -InputObject $byDate -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "uses-$RootVersionId-as-checked-in.json") -Encoding UTF8
    $moved = @($byDate | Where-Object { [string]$_.childFile.id -ne $_.reported_version_id })
    Write-Output "Root $($root.name) v$($root.version), checked in $($root.checkinDate); children by check-in date: $($byDate.Count) association(s), $($moved.Count) at another version than the server names"
    foreach ($row in $moved) { Write-Output "  by date: $($row.childFile.name) v$($row.childFile.version) ($($row.childFile.id), checked in $($row.childFile.checkinDate)) under $($row.parentFile.name); the server names version id $($row.reported_version_id)" }
} else {
    $uses = GetAll "vaults/$VaultId/file-versions/$RootVersionId/uses?option%5Brecurse%5D=true&option%5BgetLatestAssocs%5D=false&limit=500"
    $uses.results | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "uses-$RootVersionId-recurse.json") -Encoding UTF8
    Write-Output "Root $($root.name) v$($root.version) ($($root.state)); associations: $($uses.results.Count) over $($uses.pages) page(s), server total $($uses.total)"
    if ($uses.total -and ($uses.results.Count -ne $uses.total)) { throw "Association paging incomplete: $($uses.results.Count) of $($uses.total)" }
    # A member that is the place of a check-out is taken at its last version checked in, with that version's own
    # children. When there is none, nothing is asked and the rows stay as the server gave them.
    $closure = Resolve-ClosureAtLastCheckIn $root $uses.results {
        param($id)
        $own = GetAll "vaults/$VaultId/file-versions/$id/uses?option%5Brecurse%5D=true&option%5BgetLatestAssocs%5D=false&limit=500"
        if ($own.total -and ($own.results.Count -ne $own.total)) { throw "Association paging incomplete for version ${id}: $($own.results.Count) of $($own.total)" }
        ConvertTo-Json -InputObject @($own.results) -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "uses-$id-recurse.json") -Encoding UTF8
        $own.results
    } {
        param($master)
        $rows = @(GetOnePage "vaults/$VaultId/files/$master/versions?limit=1000")
        ConvertTo-Json -InputObject $rows -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "versions-of-master-$master.json") -Encoding UTF8
        $rows
    }
    $taken = @($closure.taken)
    if ($taken.Count -gt 0) {
        $uses = @{ results = @($closure.rows); pages = $uses.pages; total = $uses.total }
        ConvertTo-Json -InputObject @($closure.rows) -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "uses-$RootVersionId-with-check-outs-at-their-last-check-in.json") -Encoding UTF8
        foreach ($one in $taken) { Write-Output "TAKEN at its last version checked in: '$($one.name)' version id $($one.taken_version_id) (v$($one.taken_version), checked in $($one.taken_checkin_date)) for the place of a check-out $($one.stands_for_version_id) (listed as v$($one.stands_for_version)$(if ($one.checked_out_since) { ", since $($one.checked_out_since)" })); used by $(@($one.used_by) -join ', ')" }
    }
}
$resolution = $(if ($AsCheckedIn) { "by check-in date: every child at its newest version checked in at or before the root version, and that version's own children in the same way; a rule applied to dates, not a record read from Vault" }
    else { "as the server answers: the children of exactly this version of the root, each at the version GET file-versions/{id}/uses names, which on this server is its latest version$(if (@($taken).Count -gt 0) { "; $(@($taken).Count) member(s) that are checked out were taken at their last version checked in, each with that version's own children" })" })

$folderIds = @([string]$root.parentFolderId) + @($uses.results | ForEach-Object { [string]$_.childFile.parentFolderId }) | Sort-Object -Unique
$folders = [ordered]@{}
foreach ($fid in $folderIds) { $f = GetJ "vaults/$VaultId/folders/$fid"; $folders[$fid] = $f.fullName; Write-Output "folder $fid = $($f.fullName)$(if ($f.isLibrary) { ' (library)' })" }
function Record($v, $role) {
    [ordered]@{ version_id = [string]$v.id; master_id = [string]$v.file.id; name = $v.name; version = $v.version; revision = $v.revision; state = $v.state
        folder_id = [string]$v.parentFolderId; vault_path = "$($folders[[string]$v.parentFolderId])/$($v.name)"; size = $v.size
        checkin_date = (Get-VaultCheckinDate $v.checkinDate); version_is = (Get-VaultVersionStanding $v.checkinDate); is_checked_out = $v.isCheckedOut; role = $role; parents = @() }
}
$files = [ordered]@{}
$files[[string]$root.id] = Record $root "root"
foreach ($a in $uses.results) {
    $c = $a.childFile
    if (-not $files.Contains([string]$c.id)) { $files[[string]$c.id] = Record $c $a.fileAssocType }
    $files[[string]$c.id].parents += "$($a.parentFile.name)@$($a.parentFile.id)"
}
# a member taken in place of a check-out says which place it stands for
foreach ($one in $taken) { if ($files.Contains([string]$one.taken_version_id)) { $files[[string]$one.taken_version_id]["stands_for_check_out_place"] = [ordered]@{ version_id = [string]$one.stands_for_version_id; version = $one.stands_for_version; checked_out_since = $one.checked_out_since } } }
$list = @($files.Values | Sort-Object { $_.vault_path })
$dupNames = @($list | Group-Object name | Where-Object Count -gt 1 | ForEach-Object Name)
$checkedOut = @($list | Where-Object is_checked_out | ForEach-Object name)
# Every member must be a version checked in. The records name the files with their Vault paths.
$notCheckedIn = @(Find-NotCheckedIn $root $uses.results)
foreach ($entry in $notCheckedIn) { $entry | Add-Member -NotePropertyName vault_path -NotePropertyValue "$($folders[$entry.folder_id])/$($entry.name)" }
$inventory = [ordered]@{ captured_at = Utc; base_uri = "$B/"; vault_id = $VaultId; vault_name = $VaultName; resolution = $resolution; root = $files[[string]$root.id]
    association_count = $uses.results.Count; association_total = $uses.total; association_types = @($uses.results | Group-Object fileAssocType | ForEach-Object { "$($_.Name)=$($_.Count)" })
    folders = $folders; duplicate_names = $dupNames; checked_out = $checkedOut; not_checked_in = @($notCheckedIn | ForEach-Object { $_.name })
    taken_at_their_last_check_in = @($taken | ForEach-Object { $_.name }); files = $list }
$inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "dependency-inventory.json") -Encoding UTF8
Write-Output "Inventory: $($list.Count) unique files (incl. root), duplicate names: $(if ($dupNames) { $dupNames -join ', ' } else { 'none' }), checked out: $(if ($checkedOut) { $checkedOut -join ', ' } else { 'none' }), not a version checked in: $(if ($notCheckedIn.Count) { $notCheckedIn.Count } else { 'none' }), taken at their last version checked in: $(if (@($taken).Count) { @($taken).Count } else { 'none' })"
if ($notCheckedIn.Count -gt 0) { Stop-NotCheckedIn }

if ($NoDownload) { Write-SnapshotReceipt "complete" 0 0; Write-Output "Download skipped (-NoDownload). Requests: $($requests["sign_in_post"]) sign-in, $($requests["get"]) GET"; return }
$acq = @(); $problems = 0
foreach ($f in $list) {
    $rel = $f.vault_path.Substring(2) -replace '/', '\'
    $dst = Join-Path $CacheRoot $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -LiteralPath $dst) | Out-Null
    if (Test-Path -LiteralPath $dst) {
        # Equal size does not identify a Vault version. Until reuse is checked
        # against trusted version/checksum evidence, require a fresh mirror.
        Write-Output "CONFLICT existing file is not verified for version $($f.version_id): $rel. Use a fresh CacheRoot."
        $problems++
        continue
    }
    $tmp = "$dst.vault-cad-download"
    try {
        $requests["download_get"]++
        Invoke-WebRequest -Uri "$B/vaults/$VaultId/file-versions/$($f.version_id)/content" -Headers $h -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 600 -OutFile $tmp
        $len = (Get-Item -LiteralPath $tmp).Length
        if ($len -ne $f.size) { throw "size $len differs from Vault size $($f.size)" }
        Move-Item -LiteralPath $tmp -Destination $dst
        $sha = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant()
        $acq += [ordered]@{ version_id = $f.version_id; master_id = $f.master_id; vault_path = $f.vault_path; local_path = $dst; bytes = $len; expected_bytes = $f.size; size_match = $true; sha256 = $sha; reused_existing = $false }
        Write-Output "OK   $($f.version_id) $rel ($len bytes, sha256 $($sha.Substring(0,12)))"
    } catch {
        $problems++; Write-Output "FAIL $($f.version_id) $rel : $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
[ordered]@{ acquired_at = Utc; method = "Vault Data API GET /vaults/$VaultId/file-versions/{id}/content, Windows-integrated session"; cache_root = (Resolve-Path -LiteralPath $CacheRoot).Path; problems = $problems; files = $acq } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "acquisition.json") -Encoding UTF8
Write-SnapshotReceipt $(if ($problems -eq 0) { "complete" } else { "FAILED" }) $acq.Count $problems
Write-Output "Acquisition: $($acq.Count) files recorded, $problems problem(s); acquisition.json written. Requests: $($requests["sign_in_post"]) sign-in, $($requests["get"]) GET, $($requests["download_get"]) download"
if ($problems -gt 0) { exit 1 }
