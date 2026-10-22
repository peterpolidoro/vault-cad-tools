<#
.SYNOPSIS
Windows executor for an `add_step_file` publication plan. DRY RUN ONLY in this release.

.DESCRIPTION
    & .\windows\Publish-StepToVault.ps1 -Plan <exchange>\plans\<uuid>.json -OutputDirectory NEW -DryRun

Reads a plan produced by `vault-cad plan-publish`, re-verifies the payload bytes against the plan,
loads the installed Vault client assemblies (Vault Client 2025, Explorer folder) by reflection only
and resolves every SDK member the plan names. No connection is opened, no credential is read, nothing
is sent. The resolved signatures and the argument values that WOULD be used are written to
<OutputDirectory>\dry-run.json. Exit 0 only when the payload verifies and every member resolves.

Without -DryRun the script refuses: a live add needs an explicit user-selected destination and a
qualified pilot (docs/exchange-protocol.md). The refusal is deliberate and is tested by the harness.
Live route (not executed here): WinAuthCredentials(ServerIdentities, vault, $false, DefaultNetworkCredentials)
-> WebServiceManager -> Connection(mgr, vault, userId, server, WindowsAuthentication) -> FileManager.AddFile(...).
#>
param(
    [Parameter(Mandatory = $true)][string]$Plan,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$DryRun,
    [string]$VaultClientDirectory = "C:\Program Files\Autodesk\Vault Client 2025\Explorer"
)
$ErrorActionPreference = "Stop"
if (-not $DryRun) {
    # Deterministic refusal BEFORE any file or assembly is touched; callers see a terminating error.
    throw "Live publication is refused: no user-selected destination has been authorized and the add route has no qualified pilot. Re-run with -DryRun to resolve the plan offline."
}
if (-not (Test-Path -LiteralPath $Plan)) { throw "Plan not found: $Plan" }
$planObj = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json
if ($planObj.schema_version -ne 1 -or $planObj.operation -ne "add_step_file" -or -not $planObj.dry_run) { throw "Unsupported plan (schema/operation/dry_run)" }
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$findings = [ordered]@{ generated_at = [DateTime]::UtcNow.ToString("o"); plan = (Resolve-Path -LiteralPath $Plan).Path; request_id = $planObj.request_id; mode = "dry_run"; live_execution_refused = $true; network_access = $false; credentials_read = $false }

# 1. payload re-verification (bytes on disk must still be what the plan and request describe)
$payloadPath = [string]$planObj.payload.path
$payloadOk = $false; $payloadNote = $null
if (-not (Test-Path -LiteralPath $payloadPath)) { $payloadNote = "payload missing: $payloadPath" } else {
    $sha = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant(); $bytes = (Get-Item -LiteralPath $payloadPath).Length
    $payloadOk = ($sha -eq [string]$planObj.payload.sha256 -and $bytes -eq [int64]$planObj.payload.bytes)
    if (-not $payloadOk) { $payloadNote = "payload differs from plan: sha256 $sha ($bytes bytes) vs $($planObj.payload.sha256) ($($planObj.payload.bytes) bytes)" }
    $head = [IO.File]::ReadAllBytes($payloadPath); $text = [Text.Encoding]::ASCII.GetString($head, 0, [Math]::Min(64, $head.Length))
    if ($text -notmatch 'ISO-10303-21;') { $payloadOk = $false; $payloadNote = "payload is not a STEP Part 21 file" }
}
$findings.payload = [ordered]@{ path = $payloadPath; verified = $payloadOk; note = $payloadNote; sha256 = $planObj.payload.sha256; bytes = $planObj.payload.bytes }
if ($planObj.status -ne "planned_not_executed") { $findings.plan_status_note = "plan status is '$($planObj.status)'; nothing would be executed" }

# 2. SDK member resolution by reflection (no instance is created)
# The resolver captures the directory by value and is removed again below: a handler left registered after the
# script ends would run with its variables out of scope on every later assembly load in the calling shell.
$clientDir = $VaultClientDirectory
$resolver = [ResolveEventHandler]{ param($s, $e) try { if (-not $clientDir) { return $null }; $n = (New-Object Reflection.AssemblyName($e.Name)).Name; $candidate = Join-Path $clientDir "$n.dll"; if (Test-Path -LiteralPath $candidate) { return [Reflection.Assembly]::LoadFrom($candidate) } } catch { }; return $null }.GetNewClosure()
[AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
function Load($name) { $candidate = Join-Path $VaultClientDirectory "$name.dll"; if (-not (Test-Path -LiteralPath $candidate)) { throw "Assembly not installed: $candidate" }; [Reflection.Assembly]::LoadFrom($candidate) }
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
    Resolve-Member $ws "Autodesk.Connectivity.WebServicesTools.WebServiceManager" ".ctor" @("IWebServiceCredentials") "ctor"
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

# 3. the call sequence that WOULD run, with concrete argument values from the plan (never executed here)
$lastWrite = $(if (Test-Path -LiteralPath $payloadPath) { (Get-Item -LiteralPath $payloadPath).LastWriteTimeUtc.ToString("o") } else { $null })
$findings.would_call = @(
    [ordered]@{ step = 1; call = "new Connection(new WebServiceManager(new WinAuthCredentials(serverIdentities, vault, false, CredentialCache.DefaultNetworkCredentials)), vault, userId, server, AuthenticationFlags.WindowsAuthentication)"; arguments = [ordered]@{ vault = $planObj.vault.name; server = "from the project's base_url host"; credentials = "current Windows identity; never written to disk" } },
    [ordered]@{ step = 2; call = "DocumentService.GetFolderByPath(path)"; arguments = [ordered]@{ path = $planObj.destination.folder }; expect = [ordered]@{ Id = $planObj.destination.folder_id } },
    [ordered]@{ step = 3; call = "DocumentService.GetLatestFilesByFolderId(folderId, true)"; arguments = [ordered]@{ folderId = $planObj.destination.folder_id }; expect = "no file named '$($planObj.destination.name)' (case-insensitive); otherwise refuse (if_exists: fail)" },
    [ordered]@{ step = 4; call = "journal: state 'uploading' BEFORE the mutating call" },
    [ordered]@{ step = 5; call = "FileManager.AddFile(folder, filename, comment, lastWrite, null, null, FileClassification.None, false, stream)"; arguments = [ordered]@{ filename = $planObj.destination.name; comment = $planObj.comment; lastWrite_utc = $lastWrite; classification = "None"; hidden = $false; contents_sha256 = $planObj.payload.sha256; contents_bytes = $planObj.payload.bytes }; on_timeout = "journal state 'ambiguous'; no automatic retry; reconcile-publish inspects the folder" },
    [ordered]@{ step = 6; call = "journal: state 'uploaded' with File.MasterId / File.Id; then vault-cad record-publish re-downloads version Id and compares bytes" }
)
$findings.verdict = [ordered]@{ payload_verified = $payloadOk; sdk_members_resolved = ($unresolved.Count -eq 0); resolved_count = $resolved.Count; unresolved_count = $unresolved.Count; dry_run_ok = ($payloadOk -and $unresolved.Count -eq 0) }
$findings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "dry-run.json") -Encoding UTF8
Write-Output "dry run: payload verified=$payloadOk; SDK members resolved=$($resolved.Count), unresolved=$($unresolved.Count); live execution refused; written $(Join-Path $OutputDirectory 'dry-run.json')"
if ($unresolved.Count) { $unresolved | ForEach-Object { Write-Output "  unresolved: $_" } }
if (-not $findings.verdict.dry_run_ok) { exit 1 }
