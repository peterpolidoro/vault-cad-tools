<#
.SYNOPSIS
Windows executor for an `add_step_file` publication plan: dry run (reflection only) or ONE gated live add.

.DESCRIPTION
Dry run (no connection, no credential read, nothing sent):
    & .\windows\Publish-StepToVault.ps1 -Plan <exchange>\plans\<uuid>.json -OutputDirectory NEW -DryRun
Re-verifies the payload bytes against the plan, resolves every SDK member the plan names by reflection
against the installed Vault client assemblies and writes <OutputDirectory>\dry-run.json.

Live add (exactly one file, explicitly gated):
    & .\windows\Publish-StepToVault.ps1 -Plan ... -OutputDirectory NEW -Live -RequestId UUID `
        -ExpectedFolder '$/...' -ExpectedFolderId 953863 -ExpectedPayloadSha256 <sha> -Journal <host-local journal.json>
Every gate must match the plan (request id, destination folder and folder id, payload hash, status
`planned_not_executed`, operation `add_step_file`, vault name), the payload must still hash as planned and
lie inside the request directory, and the journal entry must be `planned` with the plan's fingerprint.
Then: Windows-authenticated sign-in (WinAuthCredentials, current process identity, nothing written) carrying
the named-user license as the Autodesk ID token of the user signed in to the Identity Manager on this machine
(-LicenseMode Token, the default; static AutodeskAccount queries only, no Login dialog, token kept in memory;
Vault 2025 answers license error 319 to an unlicensed read/write sign-in),
`GetFolderByPath` must return the expected folder id, `GetLatestFilesByFolderId(id, includeHidden)` must
not contain the name (case-insensitive); only then the journal is moved to `uploading` through the CLI
(`vault-cad mark-uploading`) and the file is added through the Vault Data Framework
(`-Route Vdf`, default: `Connection.FileManager.AddFile(Folder, name, comment, lastWrite, null, null,
FileClassification.None, hidden=false, Stream)`; `-Route Soap` keeps the raw `UploadFilePart` +
`AddUploadedFile` pair, which answered Vault error 155 on this server). On success the returned ids,
version number, size and checksum are recorded and the
journal moves to `uploaded` (`mark-uploaded --execution`). Any exception after `uploading` moves it to
`ambiguous` (`mark-ambiguous`); nothing is retried. The sign-in is disposed in every path.
Outputs: live-run.json, execution.json (the typed execution record for record-publish), execution-details.json.
No update, check-in or check-out exists in this script.
#>
param(
    [Parameter(Mandatory = $true)][string]$Plan,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$DryRun,
    [switch]$Live,
    [string]$RequestId,
    [string]$ExpectedFolder,
    [string]$ExpectedFolderId,
    [string]$ExpectedPayloadSha256,
    [string]$Journal,
    [string]$Server = "svault5",
    [string]$VaultName = "IDF VAULT",
    [ValidateSet("Token", "Default")][string]$LicenseMode = "Token",
    [ValidateSet("Vdf", "Soap")][string]$Route = "Vdf",
    [int]$TimeoutMilliseconds = 120000,
    [string]$VaultClientDirectory = "C:\Program Files\Autodesk\Vault Client 2025\Explorer",
    [string]$PixiPath = "$env:USERPROFILE\.pixi\bin\pixi.exe"
)
$ErrorActionPreference = "Stop"
if ($DryRun -and $Live) { throw "Choose either -DryRun or -Live" }
if (-not $DryRun -and -not $Live) {
    # Deterministic refusal BEFORE any file or assembly is touched; callers see a terminating error.
    throw "Nothing done: pass -DryRun to resolve the plan offline, or -Live with every gate (-RequestId, -ExpectedFolder, -ExpectedFolderId, -ExpectedPayloadSha256, -Journal) for the one authorized add."
}
if (-not (Test-Path -LiteralPath $Plan)) { throw "Plan not found: $Plan" }
$planObj = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json
if ($planObj.schema_version -ne 1 -or $planObj.operation -ne "add_step_file" -or -not $planObj.dry_run) { throw "Unsupported plan (schema/operation/dry_run)" }
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$toolsRoot = Split-Path $PSScriptRoot -Parent
function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }

# ---- payload re-verification; the payload must be payload.step INSIDE the plan's request directory (P2) ----
$requestDir = [string]$planObj.request_directory
$payloadPath = [string]$planObj.payload.path
$payloadOk = $false; $payloadNote = $null
$inside = $requestDir -and $payloadPath.ToLowerInvariant().StartsWith(($requestDir.TrimEnd('\') + '\').ToLowerInvariant()) -and ([IO.Path]::GetFileName($payloadPath) -ieq "payload.step")
if (-not $inside) { $payloadNote = "payload path is not <request_directory>\payload.step: $payloadPath" }
elseif (-not (Test-Path -LiteralPath $payloadPath)) { $payloadNote = "payload missing: $payloadPath" }
else {
    $sha = Sha $payloadPath; $bytes = (Get-Item -LiteralPath $payloadPath).Length
    $payloadOk = ($sha -eq [string]$planObj.payload.sha256 -and $bytes -eq [int64]$planObj.payload.bytes)
    if (-not $payloadOk) { $payloadNote = "payload differs from plan: sha256 $sha ($bytes bytes) vs $($planObj.payload.sha256) ($($planObj.payload.bytes) bytes)" }
    $head = [IO.File]::ReadAllBytes($payloadPath); $text = [Text.Encoding]::ASCII.GetString($head, 0, [Math]::Min(64, $head.Length))
    if ($text -notmatch 'ISO-10303-21;') { $payloadOk = $false; $payloadNote = "payload is not a STEP Part 21 file" }
}

# ---- assembly loading with a scoped resolver (removed again in every path) ----
$clientDir = $VaultClientDirectory
$resolver = [ResolveEventHandler]{ param($s, $e) try { if (-not $clientDir) { return $null }; $n = (New-Object Reflection.AssemblyName($e.Name)).Name; $candidate = Join-Path $clientDir "$n.dll"; if (Test-Path -LiteralPath $candidate) { return [Reflection.Assembly]::LoadFrom($candidate) } } catch { }; return $null }.GetNewClosure()
function Load($name) { $candidate = Join-Path $VaultClientDirectory "$name.dll"; if (-not (Test-Path -LiteralPath $candidate)) { throw "Assembly not installed: $candidate" }; [Reflection.Assembly]::LoadFrom($candidate) }

if ($DryRun) {
    $findings = [ordered]@{ generated_at = (Utc); plan = (Resolve-Path -LiteralPath $Plan).Path; request_id = $planObj.request_id; mode = "dry_run"; live_execution_refused = $true; network_access = $false; credentials_read = $false }
    $findings.payload = [ordered]@{ path = $payloadPath; verified = $payloadOk; note = $payloadNote; sha256 = $planObj.payload.sha256; bytes = $planObj.payload.bytes }
    if ($planObj.status -ne "planned_not_executed") { $findings.plan_status_note = "plan status is '$($planObj.status)'; nothing would be executed" }
    [AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
    $resolved = @(); $unresolved = @()
    function Resolve-Member($asm, $typeName, $memberName, [string[]]$paramTypeNames, $kind = "method") {
        $t = $asm.GetType($typeName)
        if (-not $t) { $script:unresolved += "$typeName (type not found)"; return }
        $found = $null
        if ($kind -eq "ctor") { foreach ($c in $t.GetConstructors()) { $names = @($c.GetParameters() | ForEach-Object { $_.ParameterType.Name }); if ((@($names) -join ',') -eq ($paramTypeNames -join ',')) { $found = $c; break } } }
        elseif ($kind -eq "enum") { if ($t.IsEnum -and [Enum]::GetNames($t) -contains $memberName) { $found = $memberName } }
        else { foreach ($m in $t.GetMethods()) { if ($m.Name -ne $memberName) { continue }; $names = @($m.GetParameters() | ForEach-Object { $_.ParameterType.Name }); if (-not $paramTypeNames -or (@($names) -join ',') -eq ($paramTypeNames -join ',')) { $found = $m; break } } }
        if ($found) { $script:resolved += [ordered]@{ type = $typeName; member = $(if ($kind -eq 'ctor') { '.ctor' } else { $memberName }); parameters = @($paramTypeNames); assembly = $asm.GetName().Name; file_version = [Diagnostics.FileVersionInfo]::GetVersionInfo($asm.Location).FileVersion } }
        else { $script:unresolved += "$typeName::$memberName($($paramTypeNames -join ','))" }
    }
    try {
        $ws = Load "Autodesk.Connectivity.WebServices"; $vdf = Load "Autodesk.DataManagement.Client.Framework.Vault"
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.ServerIdentities" ".ctor" @() "ctor"
        Resolve-Member $ws "Autodesk.Connectivity.WebServicesTools.WinAuthCredentials" ".ctor" @("ServerIdentities", "String", "Boolean", "NetworkCredential") "ctor"
        Resolve-Member $ws "Autodesk.Connectivity.WebServicesTools.WebServiceManager" ".ctor" @("IWebServiceCredentials", "Int32") "ctor"
        Resolve-Member $vdf "Autodesk.DataManagement.Client.Framework.Vault.Currency.Connections.Connection" ".ctor" @("WebServiceManager", "String", "Int64", "String", "AuthenticationFlags") "ctor"
        Resolve-Member $vdf "Autodesk.DataManagement.Client.Framework.Vault.Currency.Connections.AuthenticationFlags" "WindowsAuthentication" @() "enum"
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.DocumentService" "GetFolderByPath" @("String")
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.DocumentService" "GetLatestFilesByFolderId" @("Int64", "Boolean")
        Resolve-Member $vdf "Autodesk.DataManagement.Client.Framework.Vault.Services.Connection.IFileManager" "AddFile" @("Folder", "String", "String", "DateTime", "FileAssocParam[]", "BOM", "FileClassification", "Boolean", "Stream")
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.FilestoreService" "UploadFilePart" @("Stream")
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.DocumentService" "AddUploadedFile" @("Int64", "String", "String", "DateTime", "FileAssocParam[]", "BOM", "FileClassification", "Boolean", "ByteArray")
        Resolve-Member $ws "Autodesk.Connectivity.WebServices.FileClassification" "None" @() "enum"
    } catch { $unresolved += "assembly load: $($_.Exception.Message)" } finally { [AppDomain]::CurrentDomain.remove_AssemblyResolve($resolver) }
    $findings.sdk = [ordered]@{ client_directory = $VaultClientDirectory; resolved = $resolved; unresolved = $unresolved }
    $lastWrite = $(if ($payloadOk) { (Get-Item -LiteralPath $payloadPath).LastWriteTimeUtc.ToString("o") } else { $null })
    $findings.would_call = @(
        [ordered]@{ step = 1; call = "new WebServiceManager(new WinAuthCredentials(serverIdentities, vault, false, CredentialCache.DefaultNetworkCredentials), timeout)"; arguments = [ordered]@{ vault = $planObj.vault.name; server = $Server; credentials = "current Windows identity; never written to disk" } },
        [ordered]@{ step = 2; call = "DocumentService.GetFolderByPath(path)"; arguments = [ordered]@{ path = $planObj.destination.folder }; expect = [ordered]@{ Id = $planObj.destination.folder_id } },
        [ordered]@{ step = 3; call = "DocumentService.GetLatestFilesByFolderId(folderId, true)"; arguments = [ordered]@{ folderId = $planObj.destination.folder_id }; expect = "no file named '$($planObj.destination.name)' (case-insensitive); otherwise refuse (if_exists: fail)" },
        [ordered]@{ step = 4; call = "vault-cad mark-uploading (journal planned -> uploading) BEFORE the mutating call" },
        [ordered]@{ step = 5; call = "FilestoreService.UploadFilePart(stream) -> ticket; DocumentService.AddUploadedFile(folderId, filename, comment, lastWrite, null, null, FileClassification.None, false, ticket)"; arguments = [ordered]@{ filename = $planObj.destination.name; comment = $planObj.comment; lastWrite_utc = $lastWrite; classification = "None"; hidden = $false; contents_sha256 = $planObj.payload.sha256; contents_bytes = $planObj.payload.bytes }; on_exception = "vault-cad mark-ambiguous; no automatic retry; reconcile-publish inspects the folder" },
        [ordered]@{ step = 6; call = "vault-cad mark-uploaded --master-id File.MasterId --version-id File.Id --execution execution.json; then vault-cad record-publish re-downloads version Id and compares folder listing, bytes, size and CRC32" }
    )
    $findings.verdict = [ordered]@{ payload_verified = $payloadOk; sdk_members_resolved = ($unresolved.Count -eq 0); resolved_count = $resolved.Count; unresolved_count = $unresolved.Count; dry_run_ok = ($payloadOk -and $unresolved.Count -eq 0) }
    $findings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "dry-run.json") -Encoding UTF8
    Write-Output "dry run: payload verified=$payloadOk; SDK members resolved=$($resolved.Count), unresolved=$($unresolved.Count); live execution not performed; written $(Join-Path $OutputDirectory 'dry-run.json')"
    if ($unresolved.Count) { $unresolved | ForEach-Object { Write-Output "  unresolved: $_" } }
    if (-not $findings.verdict.dry_run_ok) { exit 1 }
    exit 0
}

# ======================================================================================================
# LIVE: one gated add
# ======================================================================================================
$run = [ordered]@{ generated_at = (Utc); plan = (Resolve-Path -LiteralPath $Plan).Path; request_id = $planObj.request_id; mode = "live"; host = $env:COMPUTERNAME; status = "not_started"; gates = [ordered]@{}; notes = @() }
function Finish($status, $exitCode) {
    $run.status = $status; $run.finished_at = (Utc)
    $run | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "live-run.json") -Encoding UTF8
    Write-Output "live run: $status (see $(Join-Path $OutputDirectory 'live-run.json'))"
    exit $exitCode
}
foreach ($g in "RequestId", "ExpectedFolder", "ExpectedFolderId", "ExpectedPayloadSha256", "Journal") { if (-not (Get-Variable -Name $g -ValueOnly)) { $run.notes += "missing gate -$g"; Finish "refused_gates_incomplete" 2 } }
if (-not (Test-Path -LiteralPath $PixiPath)) { $run.notes += "pixi not found at $PixiPath"; Finish "refused_no_cli" 2 }
$run.gates.request_id_matches = ([string]$planObj.request_id -eq $RequestId)
$run.gates.folder_matches = ([string]$planObj.destination.folder -eq $ExpectedFolder)
$run.gates.folder_id_matches = ([string]$planObj.destination.folder_id -eq [string]$ExpectedFolderId)
$run.gates.payload_sha_matches = ([string]$planObj.payload.sha256 -ieq $ExpectedPayloadSha256)
$run.gates.plan_status_planned = ([string]$planObj.status -eq "planned_not_executed")
$run.gates.operation_add_step_file = ([string]$planObj.operation -eq "add_step_file")
$run.gates.vault_name_matches = ([string]$planObj.vault.name -eq $VaultName)
$run.gates.payload_verified_on_disk = $payloadOk
$run.gates.payload_note = $payloadNote
$journalEntry = $null
try { $j = Get-Content -LiteralPath $Journal -Raw | ConvertFrom-Json; $journalEntry = $j.requests.($planObj.request_id) } catch { $run.notes += "journal unreadable: $($_.Exception.Message)" }
$run.gates.journal_entry_planned = ($null -ne $journalEntry -and [string]$journalEntry.state -eq "planned")
$run.gates.journal_fingerprint_matches = ($null -ne $journalEntry -and [string]$journalEntry.fingerprint -eq [string]$planObj.fingerprint)
$failedGates = @($run.gates.GetEnumerator() | Where-Object { $_.Key -ne "payload_note" -and $_.Value -ne $true } | ForEach-Object { $_.Key })
if ($failedGates.Count) { $run.notes += "gates failed: $($failedGates -join ', ')"; Finish "refused_gates" 2 }

$name = [string]$planObj.destination.name; $comment = [string]$planObj.comment; $folderId = [int64]$planObj.destination.folder_id
$cliLog = @()
function Invoke-JournalCli([string[]]$cliArgs) {
    Push-Location $toolsRoot
    try { $global:LASTEXITCODE = 0; $out = & $PixiPath run -q --locked cli @cliArgs 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE } finally { Pop-Location }
    $script:cliLog += [ordered]@{ at = (Utc); args = ($cliArgs -join ' '); exit = $code; output = ($out -join "`n") }
    if ($code -ne 0) { throw "CLI '$($cliArgs[0])' failed (exit $code): $($out -join ' ')" }
    return (($out -join "`n") | ConvertFrom-Json)
}
[AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
$mgr = $null; $uploadingMarked = $false
try {
    $ws = Load "Autodesk.Connectivity.WebServices"
    $si = New-Object Autodesk.Connectivity.WebServices.ServerIdentities; $si.DataServer = $Server; $si.FileServer = $Server
    $nc = [System.Net.CredentialCache]::DefaultNetworkCredentials
    if ($LicenseMode -eq "Token") {
        # Named-user license: the Autodesk ID token of the user already signed in to the Identity Manager on this
        # machine (static AutodeskAccount queries; the Login dialog is never invoked). The token stays in memory.
        $acctT = $ws.GetType("Autodesk.Connectivity.WebServicesTools.AutodeskAccount")
        function Acct($name) { $m = $acctT.GetMethod($name, [Reflection.BindingFlags]'Public,Static', $null, [Type[]]@(), $null); return $m.Invoke($null, @()) }
        $loggedIn = [bool](Acct "IsLoggedIn"); $valid = [bool](Acct "IsLoginValid")
        $run.sign_in = [ordered]@{ method = "WinAuthCredentials(process identity) + Autodesk ID OAuth token (named-user license); token not recorded"; autodesk_logged_in = $loggedIn; autodesk_login_valid = $valid; autodesk_user_id = $(try { [string](Acct "GetUserId") } catch { $null }); server = $Server; vault = $VaultName; timeout_ms = $TimeoutMilliseconds }
        if (-not ($loggedIn -and $valid)) { $run.notes += "no valid Autodesk ID sign-in in the Identity Manager; a named-user license cannot be obtained without a dialog"; Finish "refused_no_autodesk_login" 2 }
        $token = [string](Acct "GetOAuthToken")
        if (-not $token) { $run.notes += "Identity Manager returned no token"; Finish "refused_no_autodesk_token" 2 }
        $cred = New-Object Autodesk.Connectivity.WebServicesTools.WinAuthCredentials($si, $VaultName, $token, $nc)
        $token = $null
    } else {
        $cred = New-Object Autodesk.Connectivity.WebServicesTools.WinAuthCredentials($si, $VaultName, $false, $nc)
        $run.sign_in = [ordered]@{ method = "WinAuthCredentials (process identity), readOnly=false, default licensing"; server = $Server; vault = $VaultName; timeout_ms = $TimeoutMilliseconds }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $mgr = New-Object Autodesk.Connectivity.WebServicesTools.WebServiceManager($cred, $TimeoutMilliseconds)
    $run.sign_in.seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    # ---- pre-checks, BEFORE the journal moves ----
    $folder = $mgr.DocumentService.GetFolderByPath($ExpectedFolder)
    $run.precheck = [ordered]@{ folder_id_from_server = [string]$folder.Id; folder_full_name = $folder.FullName }
    if ([string]$folder.Id -ne [string]$ExpectedFolderId) { $run.notes += "server folder id $($folder.Id) != expected $ExpectedFolderId"; Finish "refused_folder_id" 2 }
    $latest = @($mgr.DocumentService.GetLatestFilesByFolderId($folder.Id, $true))
    $run.precheck.latest_files_including_hidden = $latest.Count
    $collision = @($latest | Where-Object { $_.Name -ieq $name })
    $run.precheck.name_collision = $collision.Count
    if ($collision.Count) { $run.notes += "name collision: $($collision[0].Name) (master $($collision[0].MasterId), version $($collision[0].Id))"; Finish "refused_collision" 2 }
    # ---- journal: uploading ----
    $marked = Invoke-JournalCli @("mark-uploading", $requestDir, "--journal", $Journal)
    if ([string]$marked.state -ne "uploading") { throw "journal did not move to uploading: $($marked | ConvertTo-Json -Compress)" }
    $uploadingMarked = $true
    $run.status = "uploading"
    # ---- the mutating call ----
    $lastWrite = (Get-Item -LiteralPath $payloadPath).LastWriteTimeUtc
    $sw.Restart()
    if ($Route -eq "Vdf") {
        # The supported SDK route: the Vault Data Framework FileManager performs the file-store upload and the
        # registration itself (the raw single-part UploadFilePart call answered Vault error 155 on this server).
        $vdf = Load "Autodesk.DataManagement.Client.Framework.Vault"
        $flagsT = $vdf.GetType("Autodesk.DataManagement.Client.Framework.Vault.Currency.Connections.AuthenticationFlags")
        $uid = [int64]0; try { $uid = [int64]$mgr.WebServiceCredentials.SecurityHeader.UserId } catch { }
        $conn = New-Object Autodesk.DataManagement.Client.Framework.Vault.Currency.Connections.Connection($mgr, $VaultName, $uid, $Server, [Enum]::Parse($flagsT, "WindowsAuthentication"))
        $folderEntity = New-Object Autodesk.DataManagement.Client.Framework.Vault.Currency.Entities.Folder($conn, $folder)
        if ([string]$folderEntity.Id -ne [string]$ExpectedFolderId) { throw "VDF folder entity id $($folderEntity.Id) != expected $ExpectedFolderId" }
        $stream = [IO.File]::OpenRead($payloadPath)
        try { $iter = $conn.FileManager.AddFile($folderEntity, $name, $comment, $lastWrite, [Autodesk.Connectivity.WebServices.FileAssocParam[]]$null, [Autodesk.Connectivity.WebServices.BOM]$null, [Autodesk.Connectivity.WebServices.FileClassification]::None, $false, $stream) } finally { $stream.Dispose() }
        $executedAt = (Utc)
        $run.upload = [ordered]@{ route = "VDF IFileManager.AddFile(Folder, name, comment, lastWrite, null, null, FileClassification.None, hidden=false, Stream)"; bytes = (Get-Item -LiteralPath $payloadPath).Length; seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2) }
        $run.add = [ordered]@{ version_id = [string]$iter.EntityIterationId; master_id = [string]$iter.EntityMasterId; name = [string]$iter.EntityName; version_number = [int]$iter.VersionNumber; file_size = [int64]$iter.Size; checksum = [int64]$iter.Checksum; folder_id = [string]$iter.FolderId; classification = [string]$iter.FileClassification; hidden = [bool]$iter.IsHidden; checked_out = [bool]$iter.IsCheckedOut }
        $routeText = "VDF IFileManager.AddFile over a WinAuth + Autodesk ID token session"
    } else {
        $stream = [IO.File]::OpenRead($payloadPath)
        try { $ticket = $mgr.FilestoreService.UploadFilePart($stream) } finally { $stream.Dispose() }
        $run.upload = [ordered]@{ route = "SOAP FilestoreService.UploadFilePart (single part)"; part_bytes = (Get-Item -LiteralPath $payloadPath).Length; ticket_bytes = $(if ($ticket) { $ticket.Length } else { 0 }); seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2) }
        $ba = New-Object Autodesk.Connectivity.WebServices.ByteArray; $ba.Bytes = $ticket
        $sw.Restart()
        $file = $mgr.DocumentService.AddUploadedFile($folderId, $name, $comment, $lastWrite, [Autodesk.Connectivity.WebServices.FileAssocParam[]]$null, [Autodesk.Connectivity.WebServices.BOM]$null, [Autodesk.Connectivity.WebServices.FileClassification]::None, $false, $ba)
        $executedAt = (Utc)
        $run.add = [ordered]@{ seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2); version_id = [string]$file.Id; master_id = [string]$file.MasterId; name = $file.Name; version_number = [int]$file.VerNum; file_size = [int64]$file.FileSize; checksum = [int64]$file.Cksum; folder_id = [string]$file.FolderId; classification = [string]$file.FileClass; hidden = [bool]$file.Hidden; checked_out = [bool]$file.CheckedOut }
        $routeText = "SOAP FilestoreService.UploadFilePart + DocumentService.AddUploadedFile (single part)"
    }
    if ([string]$run.add.folder_id -ne [string]$ExpectedFolderId -or [string]$run.add.name -ne $name) { $run.notes += "server returned folder $($run.add.folder_id) / name '$($run.add.name)' (expected $ExpectedFolderId / '$name'); recorded for record-publish to judge" }
    $execution = [ordered]@{ executed_at = $executedAt; executed_by_host = $env:COMPUTERNAME; comment_sent = $comment; folder_id = [string]$ExpectedFolderId; server_version_number = [int]$run.add.version_number; server_file_size = [int64]$run.add.file_size; server_checksum = [int64]$run.add.checksum }
    $execution | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory "execution.json") -Encoding UTF8
    [ordered]@{ generated_at = (Utc); request_id = $RequestId; route = $routeText; sign_in = $run.sign_in; precheck = $run.precheck; upload = $run.upload; add = $run.add; comment_sent = $comment; last_write_utc = $lastWrite.ToString("o") } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "execution-details.json") -Encoding UTF8
    $uploaded = Invoke-JournalCli @("mark-uploaded", $requestDir, "--journal", $Journal, "--master-id", [string]$run.add.master_id, "--version-id", [string]$run.add.version_id, "--execution", (Join-Path $OutputDirectory "execution.json"))
    $run.journal_after = [string]$uploaded.state
    $run.cli = $cliLog
    Finish "uploaded" 0
} catch {
    $msg = $_.Exception.Message; if ($_.Exception.InnerException) { $msg += " | inner: " + $_.Exception.InnerException.Message }
    $run.error = $msg
    if ($uploadingMarked) {
        try { $amb = Invoke-JournalCli @("mark-ambiguous", $requestDir, "--journal", $Journal, "--reason", ("live add threw after uploading was journaled: " + $msg.Substring(0, [Math]::Min(300, $msg.Length)))); $run.journal_after = [string]$amb.state } catch { $run.notes += "mark-ambiguous failed: $($_.Exception.Message)" }
        $run.cli = $cliLog
        Finish "ambiguous_no_retry" 1
    }
    $run.cli = $cliLog
    Finish "failed_before_upload" 1
} finally {
    if ($mgr) { try { $mgr.Dispose() } catch { } }
    [AppDomain]::CurrentDomain.remove_AssemblyResolve($resolver)
}
