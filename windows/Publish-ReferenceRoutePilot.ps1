<#
.SYNOPSIS
PILOT of the reference route (docs/native-checkin-adapter-design.md, 5.5): two adds to one Vault folder, the
wrapper part and then the assembly, each with its association declared. -Prepare writes the request, -DryRun
resolves it offline, -Live is the gated run. THE LIVE BRANCH HAS NOT BEEN RUN AGAINST VAULT: its lines were
rehearsed offline against a stand-in for the SDK types they touch (2026-11-20), never with -Live on a command line.

.DESCRIPTION
The three files lie in a scratch workspace where their Vault folder puts them (New-ReferenceRouteDocuments.ps1):
the STEP file, which is in Vault already, the wrapper part that holds it as a reference model, and the assembly
that places the wrapper. A live run adds the wrapper with a Dependency on the STEP file's version, then the
assembly with a Dependency on the wrapper's new version. Nothing else is written: no update, check-out or
check-in, no folder, no property, and the STEP file is not touched.

Prepare (offline; reads the three files, writes the request and a journal entry "planned"):
    & .\windows\Publish-ReferenceRoutePilot.ps1 -Prepare -Request NEW.json -Journal JOURNAL.json -WorkspaceRoot WORKSPACE `
        -Folder '$/A/B' -FolderId 123 -StepName X.step -StepMasterId 1 -StepVersionId 2 -StepVersionNumber 1 `
        -WrapperName X-reference.ipt -AssemblyName reference-pilot-01.iam

Dry run (offline: no connection, no credential read, nothing sent):
    & .\windows\Publish-ReferenceRoutePilot.ps1 -DryRun -Request REQUEST.json -OutputDirectory NEW [-Journal JOURNAL.json]
Checks the request and its fingerprint, hashes the three files again, resolves by reflection against the installed
Vault client assemblies every SDK member a live run calls, and writes dry-run.json: every call of a live run in
order, each write with the file's name, size and hash and the association declared, what is read before, how the
result would be verified, and what state Vault is in if the run stops between the two adds.

Live (two adds, explicitly gated):
    & .\windows\Publish-ReferenceRoutePilot.ps1 -Live -Request REQUEST.json -OutputDirectory NEW -RequestId UUID `
        -ExpectedFolder '$/A/B' -ExpectedFolderId 123 -ExpectedStepVersionId 2 -ExpectedWrapperSha256 SHA `
        -ExpectedAssemblySha256 SHA -Journal JOURNAL.json
Every gate must match the request; the three files must hash as requested; the journal entry must be "planned"
with the request's fingerprint. Then the sign-in of Publish-StepToVault.ps1 (Windows identity and the Autodesk ID
token of the user signed in on this machine, kept in memory), GetFolderByPath must return the expected folder id,
and GetLatestFilesByFolderId(id, includeHidden) must hold the STEP file at the expected version and no file of
the wrapper's or the assembly's name. Only then the journal moves and the files are added through
Connection.FileManager.AddFile, the route that worked for the two STEP adds:

    planned -> wrapper_uploading -> wrapper_uploaded -> assembly_uploading -> assembly_uploaded

An exception after a "..._uploading" moves the journal to "ambiguous_wrapper" or "ambiguous_assembly"; nothing is
retried, and a second run is refused because the entry is no longer "planned". If the run stops after the first
add, the wrapper is in Vault with its Dependency on the STEP file, the assembly is not, and the journal holds the
wrapper's ids.

The request carries an association's RefId, Source and ExpectedVaultPath; a live run sends what the request says.
A field the request leaves empty is not set at all: assigned a nothing, a text property of the SDK would hold an
empty text, which is not the same thing to send (found by the rehearsal of 2026-11-20). -Prepare takes the three
for each association (-WrapperRefId and so on); without them they are empty.
The BOM is null and the classification None; no visualization attachment is made by AddFile.
The connection is made with the user id 0, as both adds of Publish-StepToVault.ps1 were: the line that reads the
id asks the credentials for a SecurityHeader, which they do not have (reflection, 2026-11-20). Left as it ran.

    & .\windows\Publish-ReferenceRoutePilot.ps1 -SelfTest      # offline cases: the request, the gates, the folder listing, the journal
#>
param(
    [switch]$Prepare, [switch]$DryRun, [switch]$Live, [switch]$SelfTest,
    [string]$Request, [string]$OutputDirectory, [string]$Journal,
    # -Prepare
    [string]$WorkspaceRoot, [string]$Folder, [string]$FolderId, [string]$StepName, [string]$StepMasterId, [string]$StepVersionId, [int]$StepVersionNumber,
    [string]$WrapperName, [string]$AssemblyName, [string]$Provenance,
    [string]$WrapperRefId, [string]$WrapperSource, [string]$WrapperExpectedVaultPath, [string]$AssemblyRefId, [string]$AssemblySource, [string]$AssemblyExpectedVaultPath,
    # -Live: the gates
    [string]$RequestId, [string]$ExpectedFolder, [string]$ExpectedFolderId, [string]$ExpectedStepVersionId, [string]$ExpectedWrapperSha256, [string]$ExpectedAssemblySha256,
    [string]$Server = "svault5", [string]$VaultName = "IDF VAULT",
    [int]$TimeoutMilliseconds = 120000,
    [string]$VaultClientDirectory = "C:\Program Files\Autodesk\Vault Client 2025\Explorer"
)
$ErrorActionPreference = "Stop"
$chosen = @(@($Prepare, $DryRun, $Live, $SelfTest) | Where-Object { $_ }).Count
if ($chosen -ne 1) { throw "Nothing done: pass exactly one of -Prepare, -DryRun, -Live (with every gate) or -SelfTest." }
function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha([string]$file) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() }
$operationName = "add_reference_assembly_pilot"
$journalTransitions = @{ "planned" = @("wrapper_uploading"); "wrapper_uploading" = @("wrapper_uploaded", "ambiguous_wrapper"); "wrapper_uploaded" = @("assembly_uploading")
    "assembly_uploading" = @("assembly_uploaded", "ambiguous_assembly"); "assembly_uploaded" = @(); "ambiguous_wrapper" = @(); "ambiguous_assembly" = @() }

# ---------------------------------------------------------------------------------------------------------
# Pure: the request, its fingerprint, the gates, the folder listing, the journal
# ---------------------------------------------------------------------------------------------------------
function Get-RequestFingerprint($Req) {
    # SHA-256 over what a live run acts on, one line each, in a fixed order. Anything else in the request is a note.
    $lines = @("operation=$($Req.operation)", "request_id=$($Req.request_id)", "vault=$($Req.vault.name)|$($Req.vault.server)", "folder=$($Req.destination.folder)|$($Req.destination.folder_id)",
        "step=$($Req.referenced_step.name)|$($Req.referenced_step.master_id)|$($Req.referenced_step.version_id)|$($Req.referenced_step.sha256)|$($Req.referenced_step.bytes)")
    foreach ($add in @($Req.adds)) {
        $a = $add.association
        $lines += "add$($add.order)=$($add.role)|$($add.name)|$($add.bytes)|$($add.sha256)|$($add.comment)|$($a.type)|$($a.child)|$($a.ref_id)|$($a.source)|$($a.expected_vault_path)"
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))) -replace '-', '').ToLowerInvariant() } finally { $hasher.Dispose() }
}

function Test-Request($Req) {
    # What is wrong with a request, as texts; nothing when it is one this script acts on.
    $wrong = @()
    if ($null -eq $Req) { return @("the request is nothing") }
    if ($Req.schema_version -ne 1) { $wrong += "schema_version is not 1" }
    if ([string]$Req.operation -cne $operationName) { $wrong += "operation is not $operationName" }
    if ([string]$Req.request_id -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') { $wrong += "request_id is not a UUID in small letters" }
    if (-not [string]$Req.vault.name -or -not [string]$Req.vault.server) { $wrong += "vault name or server missing" }
    if ([string]$Req.destination.folder -notmatch '^\$/' -or [string]$Req.destination.folder -match '/$') { $wrong += "destination folder is not a Vault path" }
    if ([string]$Req.destination.folder_id -notmatch '^\d+$') { $wrong += "destination folder id is not a number" }
    $step = $Req.referenced_step
    if ([string]$step.name -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]*\.(step|stp)$') { $wrong += "the STEP file's name" }
    foreach ($field in "master_id", "version_id") { if ([string]$step.$field -notmatch '^\d+$') { $wrong += "the STEP file's $field is not a number" } }
    if ([string]$step.sha256 -notmatch '^[0-9a-f]{64}$') { $wrong += "the STEP file's hash" }
    $adds = @($Req.adds)
    if ($adds.Count -ne 2) { $wrong += "there must be two adds, the wrapper and the assembly; there are $($adds.Count)"; return $wrong }
    $expect = @(@{ order = 1; role = "wrapper"; pattern = '^[A-Za-z0-9][A-Za-z0-9 ._-]*\.ipt$'; child = "referenced_step" }, @{ order = 2; role = "assembly"; pattern = '^[A-Za-z0-9][A-Za-z0-9 ._-]*\.iam$'; child = "wrapper" })
    for ($i = 0; $i -lt 2; $i++) {
        $add = $adds[$i]; $want = $expect[$i]
        if ($add.order -ne $want.order -or [string]$add.role -cne $want.role) { $wrong += "add $($i + 1) must be the $($want.role), order $($want.order)" }
        if ([string]$add.name -notmatch $want.pattern) { $wrong += "the $($want.role)'s name" }
        if ([string]$add.sha256 -notmatch '^[0-9a-f]{64}$') { $wrong += "the $($want.role)'s hash" }
        if ($null -eq $add.bytes -or [int64]$add.bytes -le 0) { $wrong += "the $($want.role)'s size" }
        if ([string]$add.association.type -cne "Dependency" -or [string]$add.association.child -cne $want.child) { $wrong += "the $($want.role) must declare one Dependency on the $($want.child)" }
    }
    $names = @([string]$step.name, [string]$adds[0].name, [string]$adds[1].name)
    if (@($names | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique).Count -ne 3) { $wrong += "the three file names are not three different names" }
    if ([string]$Req.status -cne "planned_not_executed") { $wrong += "status is '$($Req.status)', not planned_not_executed" }
    if ([string]$Req.fingerprint -cne (Get-RequestFingerprint $Req)) { $wrong += "the fingerprint is not that of the request's content" }
    return $wrong   # bare: callers wrap with @(...)
}

function Get-RequestFile($Req, [string]$Name) {
    # Where a file of the request lies: the workspace root stands for "$", the destination folder gives the rest.
    $below = ([string]$Req.destination.folder).Substring(2) -replace '/', '\'
    return (Join-Path (Join-Path ([string]$Req.workspace_root) $below) $Name)
}

function Test-RequestFiles($Req, [scriptblock]$Measure) {
    # Do the three files lie where the request says and hash as it says. $Measure: path -> @{ sha256; bytes }, or nothing for a file that is not there.
    $wrong = @()
    $wanted = @([pscustomobject]@{ what = "the STEP file"; name = [string]$Req.referenced_step.name; sha256 = [string]$Req.referenced_step.sha256; bytes = $Req.referenced_step.bytes })
    foreach ($add in @($Req.adds)) { $wanted += [pscustomobject]@{ what = "the $($add.role)"; name = [string]$add.name; sha256 = [string]$add.sha256; bytes = $add.bytes } }
    foreach ($one in $wanted) {
        $file = Get-RequestFile $Req $one.name
        $found = & $Measure $file
        if ($null -eq $found) { $wrong += "$($one.what) is not at $file"; continue }
        if ([string]$found.sha256 -cne $one.sha256) { $wrong += "$($one.what) hashes as $($found.sha256), requested $($one.sha256)" }
        if ([int64]$found.bytes -ne [int64]$one.bytes) { $wrong += "$($one.what) has $($found.bytes) bytes, requested $($one.bytes)" }
    }
    return $wrong   # bare: callers wrap with @(...)
}

function Get-LiveGateFailures($Req, $Given, $Entry) {
    # The gates of a live run that do not hold. $Given: what was passed on the command line. $Entry: the journal's entry for the request.
    $gates = [ordered]@{
        request_id_matches = ([string]$Req.request_id -ceq [string]$Given.RequestId)
        folder_matches = ([string]$Req.destination.folder -ceq [string]$Given.ExpectedFolder)
        folder_id_matches = ([string]$Req.destination.folder_id -ceq [string]$Given.ExpectedFolderId)
        step_version_matches = ([string]$Req.referenced_step.version_id -ceq [string]$Given.ExpectedStepVersionId)
        wrapper_sha_matches = ([string]@($Req.adds)[0].sha256 -ieq [string]$Given.ExpectedWrapperSha256)
        assembly_sha_matches = ([string]@($Req.adds)[1].sha256 -ieq [string]$Given.ExpectedAssemblySha256)
        vault_name_matches = ([string]$Req.vault.name -ceq [string]$Given.VaultName)
        server_matches = ([string]$Req.vault.server -ieq [string]$Given.Server)
        journal_entry_planned = ($null -ne $Entry -and [string]$Entry.state -ceq "planned")
        journal_fingerprint_matches = ($null -ne $Entry -and [string]$Entry.fingerprint -ceq [string]$Req.fingerprint)
    }
    return @($gates.Keys | Where-Object { $gates[$_] -ne $true })
}

function Test-FolderListing($Req, $Files) {
    # The destination folder as GetLatestFilesByFolderId lists it (hidden files too): the STEP file must be there at
    # the version requested, and no file may have the wrapper's or the assembly's name. $Files: Name, Id, MasterId.
    $listed = @($Files | Where-Object { $null -ne $_ })
    $step = @($listed | Where-Object { [string]$_.Name -ieq [string]$Req.referenced_step.name })
    $taken = @(); foreach ($add in @($Req.adds)) { foreach ($file in $listed) { if ([string]$file.Name -ieq [string]$add.name) { $taken += "$($file.Name) (master $($file.MasterId), version $($file.Id))" } } }
    $verdict = "ok"
    if ($step.Count -ne 1) { $verdict = "refused_step_not_in_folder" }
    elseif ([string]$step[0].Id -cne [string]$Req.referenced_step.version_id -or [string]$step[0].MasterId -cne [string]$Req.referenced_step.master_id) { $verdict = "refused_step_version" }
    elseif ($taken.Count -gt 0) { $verdict = "refused_collision" }
    return [ordered]@{ verdict = $verdict; latest_files_including_hidden = $listed.Count; step_files_of_the_name = $step.Count
        step_version_in_folder = $(if ($step.Count -eq 1) { [string]$step[0].Id } else { $null }); step_master_in_folder = $(if ($step.Count -eq 1) { [string]$step[0].MasterId } else { $null }); name_collisions = $taken }
}

function Get-AssociationTexts($Declared) {
    # The text fields a FileAssocParam is to be given, from an association of the request: only those the request
    # states. A field that is nothing is left out, and the SDK object keeps its own nothing for it.
    $texts = [ordered]@{}
    foreach ($pair in @(@("RefId", "ref_id"), @("Source", "source"), @("ExpectedVaultPath", "expected_vault_path"))) {
        $value = $Declared.($pair[1])
        if ($null -ne $value) { $texts[$pair[0]] = [string]$value }
    }
    return $texts
}

function Move-JournalEntry($Entry, [string]$To, $Details) {
    # One step of a request's journal entry. Refused: a step the table does not allow. Returns the entry, changed.
    if ($null -eq $Entry) { throw "The journal has no entry for the request" }
    $from = [string]$Entry["state"]
    if (-not $journalTransitions.ContainsKey($from) -or $journalTransitions[$from] -cnotcontains $To) { throw "The journal entry is '$from': a move to '$To' is not allowed" }
    $step = [ordered]@{ state = $To; at = (Utc) }
    if ($Details) { foreach ($key in $Details.Keys) { $step[$key] = $Details[$key] } }
    $Entry["state"] = $To; $Entry["history"] = @($Entry["history"] | Where-Object { $null -ne $_ }) + @($step)
    return $Entry
}

function Read-PilotJournal([string]$Path) {
    # The journal as ordered tables: { schema_version, journal, requests: { <id>: { state, fingerprint, history } } }.
    $book = [ordered]@{ schema_version = 1; journal = "reference-route pilot (windows/Publish-ReferenceRoutePilot.ps1)"; requests = [ordered]@{} }
    if (-not (Test-Path -LiteralPath $Path)) { return $book }
    $read = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($read.schema_version -ne 1 -or $null -eq $read.requests) { throw "Not a journal of this pilot: $Path" }
    foreach ($property in $read.requests.PSObject.Properties) {
        $entry = [ordered]@{}; foreach ($field in $property.Value.PSObject.Properties) { $entry[$field.Name] = $field.Value }
        $history = @(); foreach ($step in @($property.Value.history)) { if ($null -eq $step) { continue }; $copy = [ordered]@{}; foreach ($field in $step.PSObject.Properties) { $copy[$field.Name] = $field.Value }; $history += $copy }
        $entry["history"] = $history
        $book.requests[$property.Name] = $entry
    }
    return $book
}

function Write-PilotJournal([string]$Path, $JournalTable) {
    # Written beside its place and moved onto it, so that a journal is never half written.
    $temporary = "$Path.writing"
    ConvertTo-Json -InputObject $JournalTable -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

if ($SelfTest) {
    $results = @()
    function Case($name, [scriptblock]$body) {
        try { $detail = & $body; $script:results += [ordered]@{ case = $name; passed = $true; detail = "$detail" }; Write-Output "PASS $name $(if ($detail) { "- $detail" })" }
        catch { $script:results += [ordered]@{ case = $name; passed = $false; detail = $_.Exception.Message }; Write-Output "FAIL $name - $($_.Exception.Message)" }
    }
    function Assert($cond, $msg) { if (-not $cond) { throw $msg } }
    function Throws([scriptblock]$body, [string]$pattern) { try { & $body | Out-Null } catch { if ($_.Exception.Message -match $pattern) { return $true }; throw "threw '$($_.Exception.Message)', expected /$pattern/" }; throw "did not throw, expected /$pattern/" }
    function New-Sample {
        $sample = [pscustomobject]@{ schema_version = 1; operation = $operationName; request_id = "0a1b2c3d-0000-4000-8000-00000000abcd"; status = "planned_not_executed"; workspace_root = 'C:\scratch\workspace'
            vault = [pscustomobject]@{ name = "A VAULT"; server = "server" }; destination = [pscustomobject]@{ folder = '$/A/TEST'; folder_id = "30" }
            referenced_step = [pscustomobject]@{ name = "model.step"; master_id = "40"; version_id = "41"; version = 1; sha256 = ("a" * 64); bytes = 1000 }
            adds = @([pscustomobject]@{ order = 1; role = "wrapper"; name = "model-reference.ipt"; sha256 = ("b" * 64); bytes = 2000; comment = "the wrapper"; association = [pscustomobject]@{ type = "Dependency"; child = "referenced_step"; ref_id = $null; source = $null; expected_vault_path = $null } },
                [pscustomobject]@{ order = 2; role = "assembly"; name = "pilot.iam"; sha256 = ("c" * 64); bytes = 3000; comment = "the assembly"; association = [pscustomobject]@{ type = "Dependency"; child = "wrapper"; ref_id = $null; source = $null; expected_vault_path = $null } })
            fingerprint = $null }
        $sample.fingerprint = Get-RequestFingerprint $sample
        return $sample
    }
    function Listed($name, $id, $master) { [pscustomobject]@{ Name = $name; Id = $id; MasterId = $master } }
    $given = @{ RequestId = "0a1b2c3d-0000-4000-8000-00000000abcd"; ExpectedFolder = '$/A/TEST'; ExpectedFolderId = "30"; ExpectedStepVersionId = "41"; ExpectedWrapperSha256 = ("b" * 64); ExpectedAssemblySha256 = ("c" * 64); VaultName = "A VAULT"; Server = "server" }
    Case "R1 a request as prepared is one this script acts on" {
        $wrong = @(Test-Request (New-Sample)); Assert ($wrong.Count -eq 0) "wrong: $($wrong -join '; ')"
    }
    Case "R2 a request changed after its fingerprint was taken is refused, whatever was changed" {
        $changes = @({ param($r) $r.destination.folder_id = "31" }, { param($r) $r.referenced_step.version_id = "42" }, { param($r) $r.adds[0].sha256 = ("d" * 64) }, { param($r) $r.adds[1].name = "other.iam" },
            { param($r) $r.adds[0].association.ref_id = "something" }, { param($r) $r.adds[1].comment = "another comment" }, { param($r) $r.vault.server = "another" })
        foreach ($change in $changes) { $sample = New-Sample; & $change $sample; Assert (@(Test-Request $sample) -contains "the fingerprint is not that of the request's content") "a change passed: $change" }
        "$($changes.Count) changes, each found"
    }
    Case "R3 a request of another kind, executed already, with the adds in the wrong order, with one add, or with an assembly that depends on the STEP file is refused" {
        $sample = New-Sample; $sample.operation = "add_step_file"; Assert (@(Test-Request $sample) -contains "operation is not $operationName") "another operation passed"
        $sample = New-Sample; $sample.status = "executed"; Assert ((@(Test-Request $sample) -join ";") -match "status is 'executed'") "an executed request passed"
        $sample = New-Sample; $sample.adds = @($sample.adds[1], $sample.adds[0]); Assert ((@(Test-Request $sample) -join ";") -match "add 1 must be the wrapper") "the assembly before the wrapper passed"
        $sample = New-Sample; $sample.adds = @($sample.adds[0]); Assert ((@(Test-Request $sample) -join ";") -match "there must be two adds") "one add passed"
        $sample = New-Sample; $sample.adds[1].association.child = "referenced_step"; Assert ((@(Test-Request $sample) -join ";") -match "the assembly must declare one Dependency on the wrapper") "an assembly that depends on the STEP file passed"
        $sample = New-Sample; $sample.adds[0].name = "model-reference.iam"; Assert ((@(Test-Request $sample) -join ";") -match "the wrapper's name") "a wrapper that is not a part passed"
        Assert ((@(Test-Request $null) -join ";") -eq "the request is nothing") "nothing passed as a request"
    }
    Case "R4 the three files must lie in the workspace where the folder puts them and hash as requested" {
        $sample = New-Sample; $sizes = @{ "model.step" = @{ sha256 = ("a" * 64); bytes = 1000 }; "model-reference.ipt" = @{ sha256 = ("b" * 64); bytes = 2000 }; "pilot.iam" = @{ sha256 = ("c" * 64); bytes = 3000 } }
        $asked = New-Object System.Collections.ArrayList
        $wrong = @(Test-RequestFiles $sample { param($file) [void]$asked.Add($file); $sizes[[IO.Path]::GetFileName($file)] })
        Assert ($wrong.Count -eq 0 -and ($asked -join "|") -ceq 'C:\scratch\workspace\A\TEST\model.step|C:\scratch\workspace\A\TEST\model-reference.ipt|C:\scratch\workspace\A\TEST\pilot.iam') "wrong: $($wrong -join '; '); asked: $($asked -join '|')"
        $sizes["model-reference.ipt"] = @{ sha256 = ("e" * 64); bytes = 2000 }; $sizes.Remove("pilot.iam")
        $wrong = @(Test-RequestFiles $sample { param($file) $sizes[[IO.Path]::GetFileName($file)] })
        Assert ($wrong.Count -eq 2 -and $wrong[0] -match '^the wrapper hashes as e+, requested b+$' -and $wrong[1] -match '^the assembly is not at ') "wrong: $($wrong -join '; ')"
    }
    Case "G1 every gate of a live run holds for the request, its gates and a journal entry that is planned" {
        $sample = New-Sample; $entry = [ordered]@{ state = "planned"; fingerprint = $sample.fingerprint }
        Assert (@(Get-LiveGateFailures $sample $given $entry).Count -eq 0) "failed: $(@(Get-LiveGateFailures $sample $given $entry) -join ', ')"
    }
    Case "G2 each gate fails by itself: another id, folder, folder id, STEP version, hash, vault or server, and a journal entry that is missing, moved on or of another request" {
        $sample = New-Sample; $entry = [ordered]@{ state = "planned"; fingerprint = $sample.fingerprint }
        $pairs = @(@("RequestId", "0a1b2c3d-0000-4000-8000-00000000abce", "request_id_matches"), @("ExpectedFolder", '$/A/TEST2', "folder_matches"), @("ExpectedFolderId", "31", "folder_id_matches"), @("ExpectedStepVersionId", "42", "step_version_matches"),
            @("ExpectedWrapperSha256", ("c" * 64), "wrapper_sha_matches"), @("ExpectedAssemblySha256", ("b" * 64), "assembly_sha_matches"), @("VaultName", "ANOTHER", "vault_name_matches"), @("Server", "another", "server_matches"))
        foreach ($pair in $pairs) { $other = @{}; foreach ($key in $given.Keys) { $other[$key] = $given[$key] }; $other[$pair[0]] = $pair[1]; $failed = @(Get-LiveGateFailures $sample $other $entry); Assert ($failed.Count -eq 1 -and $failed[0] -eq $pair[2]) "-$($pair[0]): $($failed -join ', ')" }
        Assert ((@(Get-LiveGateFailures $sample $given $null) -join ",") -eq "journal_entry_planned,journal_fingerprint_matches") "no journal entry"
        Assert ((@(Get-LiveGateFailures $sample $given ([ordered]@{ state = "wrapper_uploaded"; fingerprint = $sample.fingerprint })) -join ",") -eq "journal_entry_planned") "an entry that moved on"
        Assert ((@(Get-LiveGateFailures $sample $given ([ordered]@{ state = "planned"; fingerprint = ("f" * 64) })) -join ",") -eq "journal_fingerprint_matches") "an entry of another request"
        Assert (@(Get-LiveGateFailures $sample @{} $entry).Count -eq 8) "no gate given at all"
        "$($pairs.Count) gates and three journal entries"
    }
    Case "F1 the folder must hold the STEP file at the version requested and no file of the two names; nothing counts as no file" {
        $sample = New-Sample
        $fine = Test-FolderListing $sample @((Listed "MODEL.step" "41" "40"), (Listed "other.txt" "51" "50"))
        Assert ($fine.verdict -eq "ok" -and $fine.latest_files_including_hidden -eq 2 -and $fine.step_version_in_folder -eq "41") "fine: $($fine | ConvertTo-Json -Compress)"
        Assert ((Test-FolderListing $sample @((Listed "model.step" "45" "40"))).verdict -eq "refused_step_version") "a newer version of the STEP file passed"
        Assert ((Test-FolderListing $sample @((Listed "model.step" "41" "99"))).verdict -eq "refused_step_version") "another master of the name passed"
        Assert ((Test-FolderListing $sample @($null)).verdict -eq "refused_step_not_in_folder" -and (Test-FolderListing $sample @($null)).latest_files_including_hidden -eq 0) "nothing was counted as a file"
        Assert ((Test-FolderListing $sample $null).verdict -eq "refused_step_not_in_folder") "no answer passed"
        $taken = Test-FolderListing $sample @((Listed "model.step" "41" "40"), (Listed "MODEL-REFERENCE.IPT" "61" "60"))
        Assert ($taken.verdict -eq "refused_collision" -and $taken.name_collisions.Count -eq 1 -and $taken.name_collisions[0] -eq "MODEL-REFERENCE.IPT (master 60, version 61)") "taken: $($taken | ConvertTo-Json -Compress)"
        Assert ((Test-FolderListing $sample @((Listed "model.step" "41" "40"), (Listed "pilot.iam" "71" "70"))).verdict -eq "refused_collision") "an assembly of the name passed"
    }
    Case "A1 an association is given only the texts the request states: a field that is nothing is not set, an empty text is an empty text" {
        $sample = New-Sample
        Assert ((Get-AssociationTexts $sample.adds[0].association).Count -eq 0) "a request with nothing in the three fields gives fields to set"
        $sample.adds[0].association.ref_id = "an id"; $sample.adds[0].association.expected_vault_path = '$/A/TEST/model.step'
        $texts = Get-AssociationTexts $sample.adds[0].association
        Assert ((@($texts.Keys) -join ",") -ceq "RefId,ExpectedVaultPath" -and $texts["RefId"] -ceq "an id" -and $texts["ExpectedVaultPath"] -ceq '$/A/TEST/model.step' -and -not $texts.Contains("Source")) "texts: $($texts | ConvertTo-Json -Compress)"
        $sample.adds[1].association.source = ""
        $empty = Get-AssociationTexts $sample.adds[1].association
        Assert ($empty.Count -eq 1 -and $empty["Source"] -ceq "" -and $empty["Source"] -is [string]) "an empty text in the request is not sent as one"
        # what the rule guards against: a nothing assigned to a text property is an empty text in Windows PowerShell
        $probe = New-Object System.Exception; Assert ($null -eq $probe.HelpLink) "the probe's text property does not start as nothing"
        $probe.HelpLink = $null
        Assert ($probe.HelpLink -ceq "" -and $null -ne $probe.HelpLink) "a nothing assigned to a text property stayed a nothing here; the rule would not be needed"
        "three fields; and a nothing assigned to a text property of a .NET object is an empty text here"
    }
    Case "J1 the journal moves along the two adds and nowhere else" {
        $entry = [ordered]@{ state = "planned"; fingerprint = "x"; history = @() }
        foreach ($to in "wrapper_uploading", "wrapper_uploaded", "assembly_uploading", "assembly_uploaded") { $entry = Move-JournalEntry $entry $to @{ note = $to } }
        Assert ($entry["state"] -eq "assembly_uploaded" -and @($entry["history"]).Count -eq 4 -and @($entry["history"])[1]["note"] -eq "wrapper_uploaded") "entry: $($entry | ConvertTo-Json -Compress -Depth 5)"
        Assert (Throws { Move-JournalEntry $entry "wrapper_uploading" $null } "'assembly_uploaded': a move to 'wrapper_uploading' is not allowed") "a second run after the last add passed"
        foreach ($pair in @(@("planned", "wrapper_uploaded"), @("planned", "assembly_uploading"), @("wrapper_uploaded", "wrapper_uploading"), @("wrapper_uploading", "assembly_uploading"), @("ambiguous_wrapper", "wrapper_uploading"), @("ambiguous_assembly", "assembly_uploading"), @("unknown", "wrapper_uploading"))) {
            Assert (Throws { Move-JournalEntry ([ordered]@{ state = $pair[0]; history = @() }) $pair[1] $null } "is not allowed") "$($pair[0]) -> $($pair[1]) passed"
        }
        Assert ((Move-JournalEntry ([ordered]@{ state = "wrapper_uploading"; history = @() }) "ambiguous_wrapper" @{ reason = "threw" })["state"] -eq "ambiguous_wrapper") "an add that threw"
        Assert (Throws { Move-JournalEntry $null "wrapper_uploading" $null } "no entry") "no entry passed"
    }
    Case "J2 a journal written and read again holds the same entries, and a file that is not this journal is refused" {
        $directory = Join-Path ([IO.Path]::GetTempPath()) ("reference-route-pilot-selftest-" + [Guid]::NewGuid().ToString("N")); New-Item -ItemType Directory -Path $directory | Out-Null
        try {
            $file = Join-Path $directory "journal.json"
            $book = Read-PilotJournal $file; Assert ($book.requests.Count -eq 0) "a journal that is not there has entries"
            $book.requests["id-1"] = Move-JournalEntry ([ordered]@{ state = "planned"; fingerprint = "x"; history = @() }) "wrapper_uploading" @{ note = "first" }
            Write-PilotJournal $file $book
            $again = Read-PilotJournal $file
            Assert ($again.requests["id-1"]["state"] -eq "wrapper_uploading" -and @($again.requests["id-1"]["history"]).Count -eq 1 -and @($again.requests["id-1"]["history"])[0]["note"] -eq "first" -and -not (Test-Path -LiteralPath "$file.writing")) "read again: $($again | ConvertTo-Json -Compress -Depth 6)"
            $again.requests["id-1"] = Move-JournalEntry $again.requests["id-1"] "wrapper_uploaded" @{ version_id = "61" }; Write-PilotJournal $file $again
            Assert ((Read-PilotJournal $file).requests["id-1"]["history"][1]["version_id"] -eq "61") "the second step was not kept"
            Set-Content -LiteralPath $file -Value '{ "requests": 5 }' -Encoding UTF8
            Assert (Throws { Read-PilotJournal $file } "Not a journal of this pilot") "another file passed as the journal"
        } finally { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
    $passed = @($results | Where-Object passed).Count; $failed = @($results | Where-Object { -not $_.passed }).Count
    Write-Output "$passed passed, $failed failed"
    if ($failed -gt 0) { exit 1 }
    return
}

# ---------------------------------------------------------------------------------------------------------
# -Prepare: the request and its journal entry, from the three files as they lie in the workspace
# ---------------------------------------------------------------------------------------------------------
if ($Prepare) {
    foreach ($required in "Request", "Journal", "WorkspaceRoot", "Folder", "FolderId", "StepName", "StepMasterId", "StepVersionId", "WrapperName", "AssemblyName") { if (-not (Get-Variable -Name $required -ValueOnly)) { throw "-$required is required with -Prepare" } }
    if (Test-Path -LiteralPath $Request) { throw "Refusing to overwrite a request: $Request" }
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\')
    $new = [pscustomobject]@{ schema_version = 1; operation = $operationName; request_id = [Guid]::NewGuid().ToString("D").ToLowerInvariant(); status = "planned_not_executed"; prepared_at = (Utc); prepared_on = $env:COMPUTERNAME
        note = "PILOT. Two adds to one folder, the wrapper part and then the assembly, each with one Dependency declared. Nothing else is written. A live run needs the explicit word of the folder's owner for exactly this request."
        provenance = $(if ($Provenance) { $Provenance } else { $null }); workspace_root = $WorkspaceRoot
        vault = [pscustomobject]@{ name = $VaultName; server = $Server }; destination = [pscustomobject]@{ folder = $Folder; folder_id = $FolderId }
        referenced_step = [pscustomobject]@{ name = $StepName; master_id = $StepMasterId; version_id = $StepVersionId; version = $StepVersionNumber; sha256 = $null; bytes = $null }
        adds = @([pscustomobject]@{ order = 1; role = "wrapper"; name = $WrapperName; sha256 = $null; bytes = $null; comment = $null; association = [pscustomobject]@{ type = "Dependency"; child = "referenced_step"; ref_id = $null; source = $null; expected_vault_path = $null } },
            [pscustomobject]@{ order = 2; role = "assembly"; name = $AssemblyName; sha256 = $null; bytes = $null; comment = $null; association = [pscustomobject]@{ type = "Dependency"; child = "wrapper"; ref_id = $null; source = $null; expected_vault_path = $null } })
        fingerprint = $null }
    foreach ($one in @($new.referenced_step, $new.adds[0], $new.adds[1])) {
        $file = Get-RequestFile $new $one.name; if (-not (Test-Path -LiteralPath $file)) { throw "Not found: $file" }
        $one.sha256 = Sha $file; $one.bytes = (Get-Item -LiteralPath $file).Length
    }
    $new.adds[0].comment = "Reference-route pilot of vault-cad-tools, request $($new.request_id): wrapper part that holds $StepName (version id $StepVersionId) as a reference model. Made by New-ReferenceRouteDocuments.ps1; no authored geometry."
    $new.adds[1].comment = "Reference-route pilot of vault-cad-tools, request $($new.request_id): assembly that places only the wrapper part $WrapperName. Made by New-ReferenceRouteDocuments.ps1."
    # the three texts of each association: stated only when given; an unbound text parameter is empty and states nothing
    foreach ($pair in @(@($new.adds[0].association, "Wrapper"), @($new.adds[1].association, "Assembly"))) {
        foreach ($field in @(@("ref_id", "RefId"), @("source", "Source"), @("expected_vault_path", "ExpectedVaultPath"))) {
            if ($PSBoundParameters.ContainsKey($pair[1] + $field[1])) { $pair[0].($field[0]) = [string]$PSBoundParameters[$pair[1] + $field[1]] }
        }
    }
    $new.fingerprint = Get-RequestFingerprint $new
    $wrong = @(Test-Request $new); if ($wrong.Count) { throw "The request prepared is not one this script acts on: $($wrong -join '; ')" }
    $journalTable = Read-PilotJournal $Journal
    if ($journalTable.requests.Contains($new.request_id)) { throw "The journal has an entry for $($new.request_id) already" }
    ConvertTo-Json -InputObject $new -Depth 8 | Set-Content -LiteralPath $Request -Encoding UTF8
    $journalTable.requests[$new.request_id] = [ordered]@{ state = "planned"; fingerprint = $new.fingerprint; operation = $operationName; request = (Resolve-Path -LiteralPath $Request).Path; history = @([ordered]@{ state = "planned"; at = (Utc) }) }
    Write-PilotJournal $Journal $journalTable
    Write-Output "prepared: request $($new.request_id), fingerprint $($new.fingerprint); journal entry 'planned' in $Journal"
    Write-Output "  the STEP file  $StepName  $($new.referenced_step.bytes) bytes  $($new.referenced_step.sha256)  (in Vault: master $StepMasterId, version id $StepVersionId)"
    foreach ($add in $new.adds) { Write-Output "  add $($add.order): $($add.name)  $($add.bytes) bytes  $($add.sha256)" }
    exit 0
}

# ---------------------------------------------------------------------------------------------------------
# -DryRun and -Live: the request, checked
# ---------------------------------------------------------------------------------------------------------
foreach ($required in "Request", "OutputDirectory") { if (-not (Get-Variable -Name $required -ValueOnly)) { throw "-$required is required" } }
if (-not (Test-Path -LiteralPath $Request)) { throw "Request not found: $Request" }
$req = Get-Content -LiteralPath $Request -Raw -Encoding UTF8 | ConvertFrom-Json
$requestWrong = @(Test-Request $req)
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$measure = { param($file) if (Test-Path -LiteralPath $file) { @{ sha256 = (Sha $file); bytes = (Get-Item -LiteralPath $file).Length } } else { $null } }
# a list stays a list: through $(if ...) an empty one would become nothing
$filesWrong = @("not looked at: the request is not one this script acts on"); if ($requestWrong.Count -eq 0) { $filesWrong = @(Test-RequestFiles $req $measure) }
$journalEntry = $null; $journalNote = $null
if ($Journal) { try { $journalEntry = (Read-PilotJournal $Journal).requests[[string]$req.request_id] } catch { $journalNote = "journal unreadable: $($_.Exception.Message)" } }
$clientDir = $VaultClientDirectory
$resolver = [ResolveEventHandler]{ param($s, $e) try { if (-not $clientDir) { return $null }; $n = (New-Object Reflection.AssemblyName($e.Name)).Name; $candidate = Join-Path $clientDir "$n.dll"; if (Test-Path -LiteralPath $candidate) { return [Reflection.Assembly]::LoadFrom($candidate) } } catch { }; return $null }.GetNewClosure()
function Load($name) { $candidate = Join-Path $VaultClientDirectory "$name.dll"; if (-not (Test-Path -LiteralPath $candidate)) { throw "Assembly not installed: $candidate" }; [Reflection.Assembly]::LoadFrom($candidate) }

if ($DryRun) {
    $findings = [ordered]@{ generated_at = (Utc); script = "windows/Publish-ReferenceRoutePilot.ps1"; mode = "dry_run"; request = (Resolve-Path -LiteralPath $Request).Path; request_id = $req.request_id; fingerprint = $req.fingerprint
        live_execution_refused = $true; network_access = $false; credentials_read = $false; sdk_members_invoked = 0 }
    $findings.request_check = [ordered]@{ acts_on_it = ($requestWrong.Count -eq 0); wrong = $requestWrong }
    $findings.files_check = [ordered]@{ as_requested = ($filesWrong.Count -eq 0); wrong = $filesWrong }
    $findings.journal_check = [ordered]@{ journal = $(if ($Journal) { $Journal } else { $null }); entry_found = ($null -ne $journalEntry); state = $(if ($journalEntry) { [string]$journalEntry["state"] } else { $null }); fingerprint_matches = ($null -ne $journalEntry -and [string]$journalEntry["fingerprint"] -ceq [string]$req.fingerprint); note = $journalNote }
    [AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
    $resolved = @(); $unresolved = @()
    function Resolve-Member($asm, $typeName, $memberName, [string[]]$paramTypeNames, $kind = "method") {
        $t = $asm.GetType($typeName)
        if (-not $t) { $script:unresolved += "$typeName (type not found)"; return }
        $found = $null
        if ($kind -eq "ctor") { foreach ($c in $t.GetConstructors()) { $names = @($c.GetParameters() | ForEach-Object { $_.ParameterType.Name }); if ((@($names) -join ',') -eq ($paramTypeNames -join ',')) { $found = $c; break } } }
        elseif ($kind -eq "enum") { if ($t.IsEnum -and [Enum]::GetNames($t) -contains $memberName) { $found = $memberName } }
        elseif ($kind -eq "static") { $found = $t.GetMethod($memberName, [Reflection.BindingFlags]'Public,Static', $null, [Type[]]@(), $null) }
        elseif ($kind -eq "property") { $property = $t.GetProperty($memberName); if ($property -and $property.CanWrite -and $property.PropertyType.Name -eq $paramTypeNames[0]) { $found = $property } }
        else { foreach ($m in $t.GetMethods()) { if ($m.Name -ne $memberName) { continue }; $names = @($m.GetParameters() | ForEach-Object { $_.ParameterType.Name }); if (-not $paramTypeNames -or (@($names) -join ',') -eq ($paramTypeNames -join ',')) { $found = $m; break } } }
        if ($found) { $script:resolved += [ordered]@{ type = $typeName; member = $(if ($kind -eq 'ctor') { '.ctor' } else { $memberName }); kind = $kind; parameters = @($paramTypeNames); assembly = $asm.GetName().Name; file_version = [Diagnostics.FileVersionInfo]::GetVersionInfo($asm.Location).FileVersion } }
        else { $script:unresolved += "${typeName}::$memberName($($paramTypeNames -join ','))" }
    }
    try {
        $ws = Load "Autodesk.Connectivity.WebServices"; $vdf = Load "Autodesk.DataManagement.Client.Framework.Vault"
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.ServerIdentities" ".ctor" @() "ctor"
        foreach ($query in "IsLoggedIn", "IsLoginValid", "GetUserId", "GetOAuthToken") { Resolve-Member $ws "Autodesk.Connectivity.WebServicesTools.AutodeskAccount" $query @() "static" }
        Resolve-Member $ws "Autodesk.Connectivity.WebServicesTools.WinAuthCredentials" ".ctor" @("ServerIdentities", "String", "String", "NetworkCredential") "ctor"
        Resolve-Member $ws "Autodesk.Connectivity.WebServicesTools.WebServiceManager" ".ctor" @("IWebServiceCredentials", "Int32") "ctor"
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.DocumentService" "GetFolderByPath" @("String")
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.DocumentService" "GetLatestFilesByFolderId" @("Int64", "Boolean")
        Resolve-Member $vdf "Autodesk.DataManagement.Client.Framework.Vault.Currency.Connections.Connection" ".ctor" @("WebServiceManager", "String", "Int64", "String", "AuthenticationFlags") "ctor"
        Resolve-Member $vdf "Autodesk.DataManagement.Client.Framework.Vault.Currency.Connections.AuthenticationFlags" "WindowsAuthentication" @() "enum"
        Resolve-Member $vdf "Autodesk.DataManagement.Client.Framework.Vault.Currency.Entities.Folder" ".ctor" @("Connection", "Folder") "ctor"
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.FileAssocParam" ".ctor" @() "ctor"
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.FileAssocParam" "CldFileId" @("Int64") "property"
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.FileAssocParam" "Typ" @("AssociationType") "property"
        foreach ($text in "RefId", "Source", "ExpectedVaultPath") { Resolve-Member $ws "Autodesk.Connectivity.WebServices.FileAssocParam" $text @("String") "property" }
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.AssociationType" "Dependency" @() "enum"
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.FileClassification" "None" @() "enum"
        Resolve-Member $vdf "Autodesk.DataManagement.Client.Framework.Vault.Services.Connection.IFileManager" "AddFile" @("Folder", "String", "String", "DateTime", "FileAssocParam[]", "BOM", "FileClassification", "Boolean", "Stream")
    } catch { $unresolved += "assembly load: $($_.Exception.Message)" } finally { [AppDomain]::CurrentDomain.remove_AssemblyResolve($resolver) }
    $findings.sdk = [ordered]@{ client_directory = $VaultClientDirectory; resolved = $resolved; unresolved = $unresolved }
    $adds = @($req.adds); $stepPath = "$($req.destination.folder)/$($req.referenced_step.name)"
    function Describe-Add([int]$step, [string]$kind, $add, [string]$childFileId, [string]$childText) {
        $file = Get-RequestFile $req $add.name
        [ordered]@{ step = $step; kind = $kind; call = "connection.FileManager.AddFile(folderEntity, filename, comment, lastWrite, associations, bom, classification, hidden, stream)"; writes_to_vault = $true
            file = [ordered]@{ name = $add.name; vault_path = "$($req.destination.folder)/$($add.name)"; bytes = $add.bytes; sha256 = $add.sha256; local_path = $file; last_write_utc = $(if (Test-Path -LiteralPath $file) { (Get-Item -LiteralPath $file).LastWriteTimeUtc.ToString("o") } else { $null }) }
            comment = $add.comment; classification = "None"; hidden = $false; bom = $null
            associations = @([ordered]@{ Typ = "Dependency"; CldFileId = $childFileId; child = $childText; RefId = $add.association.ref_id; Source = $add.association.source; ExpectedVaultPath = $add.association.expected_vault_path })
            makes = "a new file (master and version 1) in the folder; no visualization attachment (AddFile has no parameter for one)"; on_exception = "the journal moves to ambiguous_$($add.role); nothing is retried" }
    }
    $findings.would_send = @(
        [ordered]@{ step = 1; kind = "sign-in"; writes_to_vault = $false; call = "AutodeskAccount.IsLoggedIn(), IsLoginValid(), GetUserId(), GetOAuthToken() (static; no Login dialog); new WebServiceManager(new WinAuthCredentials(serverIdentities, vault, token, CredentialCache.DefaultNetworkCredentials), timeout)"; arguments = [ordered]@{ vault = $req.vault.name; server = $req.vault.server; credentials = "current Windows identity, and the named-user license as the token of the Autodesk ID signed in on this machine; the token stays in memory; nothing written to disk" } },
        [ordered]@{ step = 2; kind = "read"; writes_to_vault = $false; call = "DocumentService.GetFolderByPath(path)"; arguments = [ordered]@{ path = $req.destination.folder }; expect = [ordered]@{ Id = $req.destination.folder_id }; otherwise = "refused_folder_id" },
        [ordered]@{ step = 3; kind = "read"; writes_to_vault = $false; call = "DocumentService.GetLatestFilesByFolderId(folderId, true)"; arguments = [ordered]@{ folderId = $req.destination.folder_id; includeHidden = $true }
            expect = "one file named '$($req.referenced_step.name)' with Id $($req.referenced_step.version_id) and MasterId $($req.referenced_step.master_id); no file named '$($adds[0].name)' or '$($adds[1].name)' (case-insensitive); a nothing in the answer is not counted as a file"; otherwise = "refused_step_not_in_folder, refused_step_version or refused_collision; the journal has not moved" },
        [ordered]@{ step = 4; kind = "local"; writes_to_vault = $false; call = "new Connection(webServiceManager, vault, userId, server, AuthenticationFlags.WindowsAuthentication); new Entities.Folder(connection, folder)"; expect = "the folder entity's id is $($req.destination.folder_id)" },
        [ordered]@{ step = 5; kind = "journal"; writes_to_vault = $false; call = "planned -> wrapper_uploading, BEFORE the first add" },
        (Describe-Add 6 "ADD 1 of 2" $adds[0] ([string]$req.referenced_step.version_id) "$stepPath, version id $($req.referenced_step.version_id) (master $($req.referenced_step.master_id)), in Vault since it was published"),
        [ordered]@{ step = 7; kind = "journal"; writes_to_vault = $false; call = "wrapper_uploading -> wrapper_uploaded, with the master id and the version id the first add returned" },
        [ordered]@{ step = 8; kind = "journal"; writes_to_vault = $false; call = "wrapper_uploaded -> assembly_uploading, BEFORE the second add" },
        (Describe-Add 9 "ADD 2 of 2" $adds[1] "<the version id the first add returned>" "$($req.destination.folder)/$($adds[0].name), the version the first add made"),
        [ordered]@{ step = 10; kind = "journal"; writes_to_vault = $false; call = "assembly_uploading -> assembly_uploaded, with the master id and the version id the second add returned" }
    )
    $findings.writes_to_vault = [ordered]@{ count = 2; files = @($adds | ForEach-Object { [ordered]@{ order = $_.order; name = $_.name; vault_path = "$($req.destination.folder)/$($_.name)"; bytes = $_.bytes; sha256 = $_.sha256 } })
        nothing_else = "no update, check-out or check-in; no folder; no property; the STEP file gets no new version (it gains a parent: the wrapper)" }
    $findings.verification_after = @(
        "GET folders/$($req.destination.folder_id)/contents: three files, the STEP file still at version id $($req.referenced_step.version_id)",
        "GET file-versions/<assembly version>/uses with recurse: the wrapper (Dependency), and under it the STEP file at version id $($req.referenced_step.version_id) (Dependency); two rows",
        "GET file-versions/$($req.referenced_step.version_id)/parents: one row, the wrapper's version (Dependency)",
        "GET file-versions/<wrapper version>/parents: one row, the assembly's version (Dependency)",
        "GET file-versions/<id>/content of both new versions: the bytes hash as requested ($($adds[0].sha256.Substring(0, 12)), $($adds[1].sha256.Substring(0, 12)))",
        "GET file-versions/<id> of both: version 1, the folder, the size; the category, lifecycle state and properties the server gave; classification; hasVisualizationAttachment and visualizationAttachmentStatus",
        "what REST does not show of an association: RefId, Source, ExpectedVaultPath (DocumentService.GetFileAssociationsByIds would)"
    )
    $findings.if_the_run_stops_between_the_two_adds = [ordered]@{
        vault = "the wrapper $($adds[0].name) is in the folder as a new file, version 1, with a Dependency on the STEP file's version $($req.referenced_step.version_id); the assembly is not in Vault; the STEP file has one parent and its versions are as before; nothing is checked out"
        journal = "wrapper_uploaded with the wrapper's master id and version id when the first add returned; ambiguous_wrapper when the first add threw (the folder must be read to know whether the wrapper is there); ambiguous_assembly when the second add threw (the wrapper is there, the assembly may be)"
        afterwards = "a second run of this request is refused (the entry is not 'planned', and the wrapper's name is taken). Adding the assembly alone, or removing the wrapper, is a new decision; this script does neither" }
    $findings.not_known = @(
        "what the Inventor add-in writes into RefId, Source and ExpectedVaultPath of an association: the request has them null, and a live run sends null",
        "whether Vault's own client then resolves the references on 'Open' and 'Get' as it does for files checked in by the add-in (Inventor itself resolves them by the relative name: verified in a moved workspace)",
        "which category, lifecycle and property values the server gives a new .ipt and a new .iam added this way",
        "whether the Job Processor makes a visualization for them unasked"
    )
    $ok = ($requestWrong.Count -eq 0 -and $filesWrong.Count -eq 0 -and $unresolved.Count -eq 0 -and (-not $Journal -or ($findings.journal_check.entry_found -and $findings.journal_check.state -ceq "planned" -and $findings.journal_check.fingerprint_matches)))
    $findings.verdict = [ordered]@{ request_acts = ($requestWrong.Count -eq 0); files_as_requested = ($filesWrong.Count -eq 0); sdk_members_resolved = ($unresolved.Count -eq 0); resolved_count = $resolved.Count; unresolved_count = $unresolved.Count
        journal_entry_planned = $(if ($Journal) { ($findings.journal_check.entry_found -and $findings.journal_check.state -ceq "planned" -and $findings.journal_check.fingerprint_matches) } else { $null }); dry_run_ok = $ok }
    ConvertTo-Json -InputObject $findings -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "dry-run.json") -Encoding UTF8
    Write-Output "dry run: request acts=$($requestWrong.Count -eq 0); files as requested=$($filesWrong.Count -eq 0); SDK members resolved=$($resolved.Count), unresolved=$($unresolved.Count); journal entry planned=$($findings.verdict.journal_entry_planned); live execution not performed; written $(Join-Path $OutputDirectory 'dry-run.json')"
    foreach ($text in @($requestWrong) + @($filesWrong) + @($unresolved)) { Write-Output "  not as it must be: $text" }
    if (-not $ok) { exit 1 }
    exit 0
}

# ======================================================================================================
# LIVE: two gated adds. NOT RUN against Vault. Rehearsed offline against a stand-in on 2026-11-20.
# ======================================================================================================
$run = [ordered]@{ generated_at = (Utc); script = "windows/Publish-ReferenceRoutePilot.ps1"; request = (Resolve-Path -LiteralPath $Request).Path; request_id = $req.request_id; mode = "live"; host = $env:COMPUTERNAME; status = "not_started"; gates = [ordered]@{}; notes = @() }
function Finish($status, $exitCode) {
    $run.status = $status; $run.finished_at = (Utc)
    ConvertTo-Json -InputObject $run -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "live-run.json") -Encoding UTF8
    Write-Output "live run: $status (see $(Join-Path $OutputDirectory 'live-run.json'))"
    exit $exitCode
}
foreach ($gate in "RequestId", "ExpectedFolder", "ExpectedFolderId", "ExpectedStepVersionId", "ExpectedWrapperSha256", "ExpectedAssemblySha256", "Journal") { if (-not (Get-Variable -Name $gate -ValueOnly)) { $run.notes += "missing gate -$gate"; Finish "refused_gates_incomplete" 2 } }
if ($requestWrong.Count) { $run.notes += "the request: $($requestWrong -join '; ')"; Finish "refused_request" 2 }
if ($filesWrong.Count) { $run.notes += "the files: $($filesWrong -join '; ')"; Finish "refused_files" 2 }
if ($journalNote) { $run.notes += $journalNote }
$failedGates = @(Get-LiveGateFailures $req @{ RequestId = $RequestId; ExpectedFolder = $ExpectedFolder; ExpectedFolderId = $ExpectedFolderId; ExpectedStepVersionId = $ExpectedStepVersionId; ExpectedWrapperSha256 = $ExpectedWrapperSha256; ExpectedAssemblySha256 = $ExpectedAssemblySha256; VaultName = $VaultName; Server = $Server } $journalEntry)
$run.gates = [ordered]@{ failed = $failedGates; request_acts = $true; files_as_requested = $true }
if ($failedGates.Count) { $run.notes += "gates failed: $($failedGates -join ', ')"; Finish "refused_gates" 2 }
function Step-Journal([string]$to, $details) {
    # Read, move one step, write: the file is the record, and a step that is not allowed stops the run.
    $table = Read-PilotJournal $Journal
    $table.requests[[string]$req.request_id] = Move-JournalEntry $table.requests[[string]$req.request_id] $to $details
    Write-PilotJournal $Journal $table
    $script:journalState = $to
}
$adds = @($req.adds); $journalState = "planned"; $mgr = $null
function New-Association([int64]$childFileId, $declared) {
    $param = New-Object Autodesk.Connectivity.WebServices.FileAssocParam
    $param.CldFileId = $childFileId; $param.Typ = [Autodesk.Connectivity.WebServices.AssociationType]::Dependency
    # Only what the request states is set. A nothing assigned to a text property would be sent as an empty text.
    $texts = Get-AssociationTexts $declared
    foreach ($name in $texts.Keys) { $param.$name = $texts[$name] }
    return $param
}
[AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
try {
    $ws = Load "Autodesk.Connectivity.WebServices"
    $si = New-Object Autodesk.Connectivity.WebServices.ServerIdentities; $si.DataServer = $Server; $si.FileServer = $Server
    # Named-user license: the Autodesk ID token of the user already signed in to the Identity Manager on this machine
    # (static AutodeskAccount queries; the Login dialog is never invoked). The token stays in memory.
    $acctT = $ws.GetType("Autodesk.Connectivity.WebServicesTools.AutodeskAccount")
    function Acct($name) { $m = $acctT.GetMethod($name, [Reflection.BindingFlags]'Public,Static', $null, [Type[]]@(), $null); return $m.Invoke($null, @()) }
    $loggedIn = [bool](Acct "IsLoggedIn"); $valid = [bool](Acct "IsLoginValid")
    $run.sign_in = [ordered]@{ method = "WinAuthCredentials(process identity) + Autodesk ID OAuth token (named-user license); token not recorded"; autodesk_logged_in = $loggedIn; autodesk_login_valid = $valid; server = $Server; vault = $VaultName; timeout_ms = $TimeoutMilliseconds }
    if (-not ($loggedIn -and $valid)) { $run.notes += "no valid Autodesk ID sign-in in the Identity Manager; a named-user license cannot be obtained without a dialog"; Finish "refused_no_autodesk_login" 2 }
    $token = [string](Acct "GetOAuthToken")
    if (-not $token) { $run.notes += "Identity Manager returned no token"; Finish "refused_no_autodesk_token" 2 }
    $cred = New-Object Autodesk.Connectivity.WebServicesTools.WinAuthCredentials($si, $VaultName, $token, [System.Net.CredentialCache]::DefaultNetworkCredentials)
    $token = $null
    $mgr = New-Object Autodesk.Connectivity.WebServicesTools.WebServiceManager($cred, $TimeoutMilliseconds)
    # ---- pre-checks, BEFORE the journal moves ----
    $serverFolder = $mgr.DocumentService.GetFolderByPath($ExpectedFolder)
    $run.precheck = [ordered]@{ folder_id_from_server = [string]$serverFolder.Id; folder_full_name = $serverFolder.FullName }
    if ([string]$serverFolder.Id -ne [string]$ExpectedFolderId) { $run.notes += "server folder id $($serverFolder.Id) != expected $ExpectedFolderId"; Finish "refused_folder_id" 2 }
    # An empty folder may answer with nothing, and @($null).Count is 1 in Windows PowerShell: a nothing is left out.
    $latest = @($mgr.DocumentService.GetLatestFilesByFolderId($serverFolder.Id, $true) | Where-Object { $null -ne $_ })
    $listing = Test-FolderListing $req $latest
    foreach ($key in $listing.Keys) { $run.precheck[$key] = $listing[$key] }
    if ($listing.verdict -ne "ok") { $run.notes += "the folder is not as the request needs it: $($listing.verdict)"; Finish $listing.verdict 2 }
    $vdf = Load "Autodesk.DataManagement.Client.Framework.Vault"
    $flagsT = $vdf.GetType("Autodesk.DataManagement.Client.Framework.Vault.Currency.Connections.AuthenticationFlags")
    $uid = [int64]0; try { $uid = [int64]$mgr.WebServiceCredentials.SecurityHeader.UserId } catch { }
    $conn = New-Object Autodesk.DataManagement.Client.Framework.Vault.Currency.Connections.Connection($mgr, $VaultName, $uid, $Server, [Enum]::Parse($flagsT, "WindowsAuthentication"))
    $folderEntity = New-Object Autodesk.DataManagement.Client.Framework.Vault.Currency.Entities.Folder($conn, $serverFolder)
    if ([string]$folderEntity.Id -ne [string]$ExpectedFolderId) { throw "VDF folder entity id $($folderEntity.Id) != expected $ExpectedFolderId" }
    $run.adds = @()
    $childFileId = [int64]$req.referenced_step.version_id
    foreach ($add in $adds) {
        $file = Get-RequestFile $req $add.name
        if ((Sha $file) -cne [string]$add.sha256) { throw "$($add.name) no longer hashes as requested" }
        # ---- the journal moves BEFORE the mutating call ----
        Step-Journal "$($add.role)_uploading" @{ name = [string]$add.name }
        $run.status = "$($add.role)_uploading"
        $lastWrite = (Get-Item -LiteralPath $file).LastWriteTimeUtc
        $association = New-Association $childFileId $add.association
        $stream = [IO.File]::OpenRead($file)
        try { $iteration = $conn.FileManager.AddFile($folderEntity, [string]$add.name, [string]$add.comment, $lastWrite, [Autodesk.Connectivity.WebServices.FileAssocParam[]]@($association), [Autodesk.Connectivity.WebServices.BOM]$null, [Autodesk.Connectivity.WebServices.FileClassification]::None, $false, $stream) } finally { $stream.Dispose() }
        $added = [ordered]@{ role = [string]$add.role; executed_at = (Utc); name = [string]$iteration.EntityName; master_id = [string]$iteration.EntityMasterId; version_id = [string]$iteration.EntityIterationId; version_number = [int]$iteration.VersionNumber
            file_size = [int64]$iteration.Size; checksum = [int64]$iteration.Checksum; folder_id = [string]$iteration.FolderId; classification = [string]$iteration.FileClassification; hidden = [bool]$iteration.IsHidden; checked_out = [bool]$iteration.IsCheckedOut
            association_declared = [ordered]@{ Typ = "Dependency"; CldFileId = [string]$childFileId; RefId = $association.RefId; Source = $association.Source; ExpectedVaultPath = $association.ExpectedVaultPath }; comment_sent = [string]$add.comment; last_write_utc = $lastWrite.ToString("o") }
        $run.adds += $added
        Step-Journal "$($add.role)_uploaded" @{ name = $added.name; master_id = $added.master_id; version_id = $added.version_id }
        $run.status = "$($add.role)_uploaded"
        $childFileId = [int64]$iteration.EntityIterationId   # the assembly depends on the version this add made
    }
    $run.journal_after = $journalState
    Finish "uploaded" 0
} catch {
    $msg = $_.Exception.Message; if ($_.Exception.InnerException) { $msg += " | inner: " + $_.Exception.InnerException.Message }
    $run.error = $msg
    if ($journalState -like "*_uploading") {
        $role = $journalState -replace '_uploading$', ''
        try { Step-Journal "ambiguous_$role" @{ reason = $msg.Substring(0, [Math]::Min(300, $msg.Length)) } } catch { $run.notes += "the journal could not be moved to ambiguous_${role}: $($_.Exception.Message)" }
        $run.journal_after = $journalState
        Finish "ambiguous_${role}_no_retry" 1
    }
    $run.journal_after = $journalState
    if ($journalState -eq "planned") { Finish "failed_before_upload" 1 }
    Finish "failed_after_$journalState" 1
} finally {
    if ($mgr) { try { $mgr.Dispose() } catch { } }
    [AppDomain]::CurrentDomain.remove_AssemblyResolve($resolver)
}
