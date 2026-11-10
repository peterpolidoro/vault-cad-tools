<#
.SYNOPSIS
PROBE: export part documents to STEP in one owned Inventor instance, in several variants (application protocol,
translator options, properties changed in memory only), and record everything that identifies each file.

.DESCRIPTION
    & .\windows\Invoke-StepExportProbe.ps1 -Part 'DATA\...\A.ipt','DATA\...\B.ipt' -WorkspaceRoot MIRROR `
        -Acquisition acquisition.json -OutputDirectory NEW `
        -Variant @{ label = 'ap214'; protocol = 3 }, @{ label = 'ap242'; protocol = 5 }

Each -Part is a path relative to -WorkspaceRoot (the acquired mirror). Before Inventor starts, every part is
bound by SHA-256 to its acquisition record; a part that is not recorded or does not match is refused. Each
invocation is ONE Inventor instance (the owned, invisible instance of Inventor-Session.ps1, with the dialog
watchdog), so "separate sessions" means separate invocations.

A variant is a hashtable:
  label        directory name under -OutputDirectory (letters, digits, '-', '_')
  protocol     ApplicationProtocolType: 2 AP203, 3 AP214, 4 AP203E2, 5 AP242 (default 3)
  options      translator options to set after the exporter's own (name -> value), e.g. @{ Author = 'x' }
  properties   iProperties to set IN MEMORY before the export and restore after it, never saved:
               @{ 'Inventor Summary Information|Author' = 'MARKER' }. Requires -WorkOnCopies.
  output_name  fixed output file name (e.g. 'part.step'); the file then goes to <label>\<part name>\<output_name>
Translator options are set as Export-PartAssets.ps1 sets them (ApplicationProtocolType, IncludeSketches false
when present); nothing else is touched unless a variant says so.

-WorkOnCopies copies each bound part into <OutputDirectory>\workspace (hash-verified) and opens the copy, with a
project file created there and removed again; the mirror is then not opened at all. Documents are never saved:
they are closed with SkipSave, and every opened file is re-hashed afterwards (a changed hash fails the run).

Per export the receipt records: size, SHA-256, the data-section SHA-256 (from DATA to the end), the FILE_SCHEMA
statement and protocol, every FILE_NAME field, the header lines, the detected length unit, the translator
options as read back after the export (including "Translation Result") and whether the export dirtied the
document. Per part it records the summary, document-summary and design-tracking iProperties (scalar values).
Outputs: step-export-probe.json, probe.log, dialogs.log, the STEP files.
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Part,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$Acquisition,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [object[]]$Variant = @(@{ label = "ap214"; protocol = 3 }),
    [switch]$WorkOnCopies,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")
. (Join-Path $PSScriptRoot "Step-Units.ps1")
. (Join-Path $PSScriptRoot "Step-Header.ps1")

function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Utc { [DateTime]::UtcNow.ToString("o") }
foreach ($f in @($WorkspaceRoot, $Acquisition)) { if (-not (Test-Path -LiteralPath $f)) { throw "Not found: $f" } }
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\')
$protocolNames = @{ 2 = "AP203"; 3 = "AP214"; 4 = "AP203E2"; 5 = "AP242" }
$variants = @()
foreach ($v in $Variant) {
    if ($v -isnot [System.Collections.IDictionary]) { throw "Each -Variant must be a hashtable" }
    $label = [string]$v["label"]; if ($label -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Variant label '$label' is not a plain name" }
    $protocol = $(if ($v.Contains("protocol")) { [int]$v["protocol"] } else { 3 }); if (-not $protocolNames.ContainsKey($protocol)) { throw "Variant '$label': protocol $protocol is not one of 2, 3, 4, 5" }
    $outputName = $(if ($v.Contains("output_name")) { [string]$v["output_name"] } else { $null })
    if ($outputName -and $outputName -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]*\.(step|stp)$') { throw "Variant '$label': output_name '$outputName' is not a plain STEP file name" }
    $options = [ordered]@{}; if ($v.Contains("options") -and $v["options"]) { foreach ($k in $v["options"].Keys) { $options[[string]$k] = $v["options"][$k] } }
    $properties = [ordered]@{}; if ($v.Contains("properties") -and $v["properties"]) { foreach ($k in $v["properties"].Keys) { if (([string]$k).Split('|').Count -ne 2) { throw "Variant '$label': property key '$k' must be 'Property set|Property name'" }; $properties[[string]$k] = [string]$v["properties"][$k] } }
    if ($properties.Count -gt 0 -and -not $WorkOnCopies) { throw "Variant '$label' sets properties in memory; that is only allowed with -WorkOnCopies" }
    if (@($variants | Where-Object { $_.label -eq $label }).Count) { throw "Duplicate variant label '$label'" }
    $variants += [pscustomobject]@{ label = $label; protocol = $protocol; output_name = $outputName; options = $options; properties = $properties }
}
# ---- bind every part to the acquisition record BEFORE anything is opened ----
$acq = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
if (-not $acq.files) { throw "Acquisition record has no files" }
$cacheRoot = ([string]$acq.cache_root).TrimEnd('\')
$acqByRel = @{}; foreach ($a in $acq.files) { $local = [string]$a.local_path; if ($local.ToLowerInvariant().StartsWith($cacheRoot.ToLowerInvariant())) { $acqByRel[$local.Substring($cacheRoot.Length).TrimStart('\').ToLowerInvariant()] = $a } }
$bound = @()
foreach ($rel in $Part) {
    $relPath = $rel.TrimStart('\')
    $full = Join-Path $WorkspaceRoot $relPath
    if (-not (Test-Path -LiteralPath $full)) { throw "Part not found in the workspace: $relPath" }
    $record = $acqByRel[$relPath.ToLowerInvariant()]
    if (-not $record) { throw "Part '$relPath' has no acquisition record; refusing to open it" }
    $hash = Sha $full
    if ($hash -ne ([string]$record.sha256).ToLowerInvariant()) { throw "Part '$relPath' hash $hash does not match its acquisition record $($record.sha256)" }
    $bound += [pscustomobject]@{ relative_path = $relPath; source_path = $full; open_path = $full; sha256 = $hash; master_id = [string]$record.master_id; version_id = [string]$record.version_id; vault_path = [string]$record.vault_path }
}
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$projectRoot = $WorkspaceRoot
if ($WorkOnCopies) {
    $projectRoot = Join-Path $OutputDirectory "workspace"; New-Item -ItemType Directory -Path $projectRoot | Out-Null
    foreach ($b in $bound) {
        $target = Join-Path $projectRoot $b.relative_path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $b.source_path -Destination $target
        if ((Sha $target) -ne $b.sha256) { throw "Copy of '$($b.relative_path)' does not have the acquired hash" }
        $b.open_path = $target
    }
}
$log = Join-Path $OutputDirectory "probe.log"
function Log($s) { $line = "$(Utc) $s"; Add-Content -LiteralPath $log -Value $line; Write-Output $s }
$kPart = 12290; $kFileBrowseIOMechanism = 13059; $stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
function Get-MapName($map, $i) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($i)) }
function Get-MapValue($map, $k) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($k)) }
function Set-MapValue($map, $k, $v) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($k, $v)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
function Read-PropertySets($doc) {
    # Scalar iProperties of the three standard sets; a value that cannot be read is recorded as such.
    $sets = [ordered]@{}
    foreach ($setName in @("Inventor Summary Information", "Inventor Document Summary Information", "Design Tracking Properties")) {
        $values = [ordered]@{}
        try {
            $set = $doc.PropertySets.Item($setName)
            for ($i = 1; $i -le $set.Count; $i++) {
                $property = $set.Item($i); $name = [string]$property.Name
                try { $value = $property.Value; if ($null -eq $value) { $values[$name] = $null } elseif ($value -is [string] -or $value -is [bool] -or $value -is [int] -or $value -is [double] -or $value -is [long]) { $values[$name] = $value } elseif ($value -is [DateTime]) { $values[$name] = $value.ToString("o") } else { $values[$name] = "<$($value.GetType().Name)>" } } catch { $values[$name] = "<unreadable: $($_.Exception.Message)>" }
            }
        } catch { $values["<error>"] = $_.Exception.Message }
        $sets[$setName] = $values
    }
    return $sets
}

$session = Start-IsolatedInventor
$app = $session.App
Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build)); started $($session.StartedAt.ToString('o'))"
$project = $null; $errors = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null
$watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $OutputDirectory "dialogs.log")
$exports = @(); $partRecords = @(); $defaultOptions = $null
try {
    $project = Use-TemporaryProject $app (Join-Path $projectRoot "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); created file: $($project.CreatedFile))"
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $translatorInfo = [ordered]@{ display_name = [string]$translator.DisplayName; client_id = $stepTranslatorClsid; activated = [bool]$translator.Activated }
    $to = $app.TransientObjects
    foreach ($b in $bound) {
        $doc = $app.Documents.Open($b.open_path, $false)
        try {
            if ([int]$doc.DocumentType -ne $kPart) { throw "'$($b.relative_path)' is not a part document" }
            $partRecord = [ordered]@{ relative_path = $b.relative_path; master_id = $b.master_id; version_id = $b.version_id; vault_path = $b.vault_path; native_sha256 = $b.sha256
                opened_from = $(if ($WorkOnCopies) { "copy in the output directory" } else { "acquired mirror" }); length_units = $lengthUnitNames[[int]$doc.UnitsOfMeasure.LengthUnits]
                dirty_after_open = [bool]$doc.Dirty; properties = (Read-PropertySets $doc) }
            $base = [IO.Path]::GetFileNameWithoutExtension($b.relative_path)
            foreach ($v in $variants) {
                $outDir = Join-Path $OutputDirectory $v.label; if ($v.output_name) { $outDir = Join-Path $outDir $base }
                New-Item -ItemType Directory -Force -Path $outDir | Out-Null
                $outPath = Join-Path $outDir $(if ($v.output_name) { $v.output_name } else { "$base.step" })
                if (Test-Path -LiteralPath $outPath) { throw "Output already exists: $outPath" }
                $restore = [ordered]@{}; $propertyErrors = @()
                foreach ($key in $v.properties.Keys) {
                    $setName = $key.Split('|')[0]; $propertyName = $key.Split('|')[1]
                    try { $property = $doc.PropertySets.Item($setName).Item($propertyName); $restore[$key] = $property.Value; $property.Value = $v.properties[$key] } catch { $propertyErrors += "$key`: $($_.Exception.Message)" }
                }
                $dirtyBefore = [bool]$doc.Dirty
                $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
                $opts = $to.CreateNameValueMap()
                $hasOptions = [bool]$translator.HasSaveCopyAsOptions($doc, $ctx, $opts)
                if ($null -eq $defaultOptions -and $hasOptions) { $defaultOptions = Read-Map $opts }
                $optionErrors = @()
                if ($hasOptions) {
                    Set-MapValue $opts "ApplicationProtocolType" $v.protocol
                    if ((Read-Map $opts).Contains("IncludeSketches")) { Set-MapValue $opts "IncludeSketches" $false }
                    foreach ($name in $v.options.Keys) { try { Set-MapValue $opts $name $v.options[$name] } catch { $optionErrors += "$name`: $($_.Exception.Message)" } }
                }
                $optionsBefore = Read-Map $opts
                $medium = $to.CreateDataMedium(); $medium.FileName = $outPath
                $exportError = $null; $started = Utc
                try { $translator.SaveCopyAs($doc, $ctx, $opts, $medium) } catch { $exportError = $_.Exception.Message }
                $finished = Utc
                $dirtyAfter = [bool]$doc.Dirty
                foreach ($key in $restore.Keys) { try { $doc.PropertySets.Item($key.Split('|')[0]).Item($key.Split('|')[1]).Value = $restore[$key] } catch { $propertyErrors += "restore $key`: $($_.Exception.Message)" } }
                $entry = [ordered]@{ variant = $v.label; part = $b.relative_path; master_id = $b.master_id; version_id = $b.version_id; protocol_requested = $protocolNames[$v.protocol]; application_protocol_type = $v.protocol
                    file = $outPath.Substring($OutputDirectory.Length + 1) -replace '\\', '/'; export_started = $started; export_finished = $finished; export_error = $exportError
                    options_set = $v.options; option_errors = $optionErrors; properties_set_in_memory = $v.properties; properties_previous = $restore; property_errors = $propertyErrors
                    translator_options_before = $optionsBefore; translator_options_after = (Read-Map $opts); dirty_before_export = $dirtyBefore; dirty_after_export = $dirtyAfter }
                if (-not $exportError -and (Test-Path -LiteralPath $outPath)) {
                    $info = Get-StepFileInfo -Path $outPath
                    $unit = Get-StepLengthUnit $outPath
                    $entry.bytes = $info.bytes; $entry.sha256 = $info.sha256; $entry.data_sha256 = $info.data_sha256; $entry.header_sha256 = $info.header_sha256; $entry.data_offset = $info.data_offset
                    $entry.file_schema = $info.file_schema_statement; $entry.protocol_in_file = $info.header.protocol; $entry.header = $info.header; $entry.header_lines = $info.header_lines
                    $entry.step_length_unit = $unit.unit; $entry.step_length_unit_detection = $unit
                    if ($info.header.protocol -ne $protocolNames[$v.protocol]) { $errors += "$($entry.file): the file's schema says $($info.header.protocol), requested $($protocolNames[$v.protocol])" }
                    if (-not $unit.ok) { $errors += "$($entry.file): length unit rejected: $($unit.reason)" }
                    Log ("{0,-10} {1,-62} {2,9} bytes  {3}  author={4}  unit={5}  result={6}" -f $v.label, $base, $info.bytes, $info.header.protocol, (@($info.header.author) -join '|'), $unit.unit, $entry.translator_options_after["Translation Result"])
                } else { $errors += "$($b.relative_path) [$($v.label)]: export failed: $exportError"; Log "EXPORT FAILED $($v.label) $base : $exportError" }
                if ($propertyErrors.Count) { $errors += "$($b.relative_path) [$($v.label)]: $($propertyErrors -join '; ')" }
                if ($optionErrors.Count) { $errors += "$($b.relative_path) [$($v.label)]: option errors: $($optionErrors -join '; ')" }
                $exports += $entry
            }
            $partRecord.dirty_before_close = [bool]$doc.Dirty
            $partRecords += $partRecord
        } finally { try { $doc.Close($true) } catch { $errors += "close '$($b.relative_path)': $($_.Exception.Message)" } }
    }
} catch {
    $errors += $_.Exception.Message; Log "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace }
} finally {
    $shutdown = Stop-IsolatedInventor $session $project
    if (-not $shutdown.Succeeded) { $errors += "shutdown not observed as complete: $($shutdown.Observed | ConvertTo-Json -Compress)" }
    Log "Shutdown: pid $($shutdown.Pid) exited=$($shutdown.Exited) succeeded=$($shutdown.Succeeded)"
    if ($watchdog) { $dialogs = Stop-DialogWatchdog $watchdog; Log "Dialog watchdog: $($dialogs.Polls) polls, $($dialogs.Events.Count) dialog window(s) seen, $($dialogs.Dismissed) dismissed, $($dialogs.Left) left alone" }
}
# ---- integrity: nothing that was opened may have changed on disk ----
$integrity = @()
foreach ($b in $bound) {
    $sourceAfter = Sha $b.source_path; $openedAfter = $(if ($b.open_path -ne $b.source_path) { Sha $b.open_path } else { $sourceAfter })
    $integrity += [ordered]@{ relative_path = $b.relative_path; acquired_sha256 = $b.sha256; mirror_sha256_after = $sourceAfter; mirror_unchanged = ($sourceAfter -eq $b.sha256); opened_file_sha256_after = $openedAfter; opened_file_unchanged = ($openedAfter -eq $b.sha256) }
    if ($sourceAfter -ne $b.sha256) { $errors += "the mirror file '$($b.relative_path)' changed on disk" }
    if ($openedAfter -ne $b.sha256) { $errors += "the opened file '$($b.relative_path)' changed on disk (a document was saved)" }
}
$status = $(if ($errors.Count -eq 0 -and $shutdown.Succeeded -and $exports.Count -eq ($bound.Count * $variants.Count)) { Resolve-RunStatus -Status "complete" -Dialogs $dialogs } else { "FAILED" })
$receipt = [ordered]@{ schema_version = 1; generated_at = (Utc); probe = "windows/Invoke-StepExportProbe.ps1"; status = $status; errors = $errors
    scope = "read-only STEP export probe; documents are never saved; opened files re-hashed after the run"
    host = $env:COMPUTERNAME; inventor = "$($session.Version) build $($session.Build)"; workspace_root = $WorkspaceRoot; acquisition_record = $Acquisition; work_on_copies = [bool]$WorkOnCopies
    session = [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; started_at = $session.StartedAt.ToString("o"); pre_existing_inventor_pids = $session.PreExistingPids
        shutdown = [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; observed = $shutdown.Observed; failed_required = @($shutdown.FailedRequired); notes = @($shutdown.Notes) } }
    project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; created_file = $project.CreatedFile; entry_removed_by_run = $shutdown.ProjectEntryRemoved; previous_restored = $shutdown.PreviousProjectRestored } } else { $null })
    translator = $translatorInfo; translator_default_options = $defaultOptions
    variants = @($variants | ForEach-Object { [ordered]@{ label = $_.label; protocol = $protocolNames[$_.protocol]; output_name = $_.output_name; options = $_.options; properties = $_.properties } })
    parts = $partRecords; exports = $exports; integrity = $integrity
    dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; log = "dialogs.log"; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors) } } else { $null }) }
ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "step-export-probe.json") -Encoding UTF8
Log "Probe status: $status ($($exports.Count) export(s) of $($bound.Count) part(s) in $($variants.Count) variant(s))"
if ($status -notlike "complete*") { exit 1 }
