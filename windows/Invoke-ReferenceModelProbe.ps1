<#
.SYNOPSIS
PROBE (disposable copy only): can Inventor 2025 keep a repository STEP as a REFERENCED source instead of
converting it to a native body, and what does the resulting part/assembly list as file references?

.DESCRIPTION
    & .\windows\Invoke-ReferenceModelProbe.ps1 -StepInput COPY\incoming\X.step -ExpectedStepSha256 SHA `
        -WorkspaceRoot COPY\workspace -OutputDirectory NEW [-PartSubfolder MONITOR] [-ProjectName placement-pilot]

Creates, inside -WorkspaceRoot (a disposable copy; the mirror and the production assembly are never opened):
  1. a NEW part document whose only content is the STEP imported through
     ReferenceComponents.ImportedComponents (ImportedGenericComponentDefinition.ReferenceModel = true, the
     "reference model" / AnyCAD route), saved as <PartSubfolder>\<step name>-reference.ipt;
  2. a NEW assembly document with one grounded occurrence of that part, saved as <PartSubfolder>\reference-probe.iam.
Records for both: ImportedComponent.LinkedToFile / ReferencedFile / IsEmbedded / HealthStatus, body counts,
File.ReferencedFileDescriptors (full names, document types, status), AllReferencedDocuments, and a hash
inventory of the copy before/after (only the two new files may appear). A run that cannot create the reference
model records the exception as the answer. Dialog watchdog active; nothing outside -WorkspaceRoot is written.
Outputs: reference-model-probe.json, probe.log, dialogs.log.
#>
param(
    [Parameter(Mandatory = $true)][string]$StepInput,
    [Parameter(Mandatory = $true)][string]$ExpectedStepSha256,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$PartSubfolder = "MONITOR",
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "placement-pilot",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")

foreach ($f in @($StepInput, $WorkspaceRoot)) { if (-not (Test-Path -LiteralPath $f)) { throw "Not found: $f" } }
$StepInput = (Resolve-Path -LiteralPath $StepInput).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Utc { [DateTime]::UtcNow.ToString("o") }
$stepSha = Sha $StepInput
if ($stepSha -ne $ExpectedStepSha256.ToLowerInvariant()) { throw "STEP input hash $stepSha does not match the expected $ExpectedStepSha256" }
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$partDir = Join-Path $WorkspaceRoot $PartSubfolder
$stepName = [IO.Path]::GetFileNameWithoutExtension($StepInput)
$refIpt = Join-Path $partDir "$stepName-reference.ipt"
$refIam = Join-Path $partDir "reference-probe.iam"
foreach ($f in @($refIpt, $refIam)) { if (Test-Path -LiteralPath $f) { throw "Already exists, refusing to overwrite: $f" } }
$hashesBefore = [ordered]@{}; foreach ($f in Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File) { $hashesBefore[$f.FullName.Substring($WorkspaceRoot.Length + 1)] = Sha $f.FullName }
$log = Join-Path $OutputDirectory "probe.log"
function Log($s) { $line = "$(Utc) $s"; Add-Content -LiteralPath $log -Value $line; Write-Output $s }
function Descriptors($document) {
    $list = @()
    try { foreach ($d in (Get-CollectionItems $document.File.ReferencedFileDescriptors)) { $list += [ordered]@{ full_file_name = [string]$d.FullFileName; document_type = [int]$d.DocumentType; reference_status = [int]$d.ReferenceStatus; document_found = [bool]$d.DocumentFound; different_document = [bool]$d.DifferentDocument } } } catch { $list += [ordered]@{ error = $_.Exception.Message } }
    return ,$list
}
function AllReferenced($document) {
    $list = @()
    try { foreach ($d in (Get-CollectionItems $document.AllReferencedDocuments)) { $list += [string]$d.FullFileName } } catch { $list += "error: $($_.Exception.Message)" }
    return ,$list
}
$kPart = 12290; $kAssembly = 12291
$session = Start-IsolatedInventor
$app = $session.App
Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build))"
$project = $null; $errors = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null
$watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $OutputDirectory "dialogs.log")
$receipt = [ordered]@{ schema_version = 1; generated_at = (Utc); probe = "windows/Invoke-ReferenceModelProbe.ps1"; status = "FAILED"
    scope = "disposable copy only; new documents only; answers whether a STEP can stay a referenced source (reference model) in Inventor 2025 and what the documents then reference"
    inputs = [ordered]@{ step = $StepInput; step_sha256 = $stepSha; workspace_root = $WorkspaceRoot; reference_part = $refIpt; reference_assembly = $refIam } }
try {
    $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); created file: $($project.CreatedFile))"
    New-Item -ItemType Directory -Force -Path $partDir | Out-Null
    # ---- 1. new part with the STEP as a reference model ----
    $partTemplate = [string]$app.FileManager.GetTemplateFile($kPart)
    $doc = $app.Documents.Add($kPart, $partTemplate, $false)
    try {
        $ic = $doc.ComponentDefinition.ReferenceComponents.ImportedComponents
        $def = $ic.CreateDefinition($StepInput)
        $defInfo = [ordered]@{ type_name = $def.GetType().Name; com_type = [int]$def.Type; full_file_name = [string]$def.FullFileName; reference_model_default = $null; import_units_type = $null; set_reference_model = $null }
        try { $defInfo.reference_model_default = [bool]$def.ReferenceModel } catch { $defInfo.reference_model_default = "error: $($_.Exception.Message)" }
        try { $defInfo.import_units_type = [int]$def.ImportUnitsType } catch { }
        try { $def.ReferenceModel = $true; $defInfo.set_reference_model = [bool]$def.ReferenceModel } catch { $defInfo.set_reference_model = "error: $($_.Exception.Message)" }
        $receipt.definition = $defInfo
        Log "Imported component definition: $($defInfo.type_name) reference_model default=$($defInfo.reference_model_default) set=$($defInfo.set_reference_model)"
        $comp = $ic.Add($def)
        $compInfo = [ordered]@{ added = $true; name = [string]$comp.Name; linked_to_file = $null; referenced_file = $null; is_embedded = $null; health_status = $null; referenced_document_descriptor = $null }
        $receipt.imported_component = $compInfo   # recorded now; the fields below are filled in place
        try { $compInfo.linked_to_file = [bool]$comp.LinkedToFile } catch { $compInfo.linked_to_file = "error: $($_.Exception.Message)" }
        try { $compInfo.referenced_file = [string]$comp.ReferencedFile } catch { $compInfo.referenced_file = "error: $($_.Exception.Message)" }
        try { $compInfo.is_embedded = [bool]$comp.IsEmbedded } catch { $compInfo.is_embedded = "error: $($_.Exception.Message)" }
        try { $compInfo.health_status = [int]$comp.HealthStatus } catch { $compInfo.health_status = "error: $($_.Exception.Message)" }
        try { $rdd = $comp.ReferencedDocumentDescriptor; $compInfo.referenced_document_descriptor = $(if ($rdd) { [string]$rdd.FullDocumentName } else { $null }) } catch { $compInfo.referenced_document_descriptor = "error: $($_.Exception.Message)" }
        $cd = $doc.ComponentDefinition
        $bodies = [int]$cd.SurfaceBodies.Count; $solids = 0; for ($i = 1; $i -le $bodies; $i++) { if ($cd.SurfaceBodies.Item($i).IsSolid) { $solids++ } }
        $compInfo.surface_bodies = $bodies; $compInfo.solid_bodies = $solids
        # COM point coordinates arrive as single-element arrays here; cast before any arithmetic.
        try { $rb = $cd.RangeBox; $mn = $rb.MinPoint; $mx = $rb.MaxPoint; $compInfo.range_box_mm = [ordered]@{ min = @([double]$mn.X * 10, [double]$mn.Y * 10, [double]$mn.Z * 10); max = @([double]$mx.X * 10, [double]$mx.Y * 10, [double]$mx.Z * 10) } } catch { $compInfo.range_box_mm = "error: $($_.Exception.Message)" }
        try { $compInfo.features = [int]$cd.Features.Count } catch { $compInfo.features = "error: $($_.Exception.Message)" }
        Log "Imported component '$($compInfo.name)': linked=$($compInfo.linked_to_file) referenced_file=$($compInfo.referenced_file) embedded=$($compInfo.is_embedded) bodies=$bodies solids=$solids"
        $doc.SaveAs($refIpt, $false)
        $receipt.reference_part = [ordered]@{ path = $refIpt; sha256 = (Sha $refIpt); bytes = (Get-Item -LiteralPath $refIpt).Length; referenced_file_descriptors = (Descriptors $doc); all_referenced_documents = (AllReferenced $doc) }
        Log "Saved $refIpt; ReferencedFileDescriptors: $(@($receipt.reference_part.referenced_file_descriptors).Count); AllReferencedDocuments: $(@($receipt.reference_part.all_referenced_documents).Count)"
    } finally { try { $doc.Close($true) } catch { $errors += "part close: $($_.Exception.Message)" } }
    # ---- 2. new assembly with one grounded occurrence of the reference part ----
    $asmTemplate = [string]$app.FileManager.GetTemplateFile($kAssembly)
    $asm = $app.Documents.Add($kAssembly, $asmTemplate, $false)
    try {
        $m = $app.TransientGeometry.CreateMatrix()
        $occ = $asm.ComponentDefinition.Occurrences.Add($refIpt, $m)
        $occ.Grounded = $true
        $asm.SaveAs($refIam, $false)
        $receipt.reference_assembly = [ordered]@{ path = $refIam; sha256 = (Sha $refIam); bytes = (Get-Item -LiteralPath $refIam).Length; occurrences = [int]$asm.ComponentDefinition.Occurrences.Count; referenced_file_descriptors = (Descriptors $asm); all_referenced_documents = (AllReferenced $asm) }
        Log "Saved $refIam; ReferencedFileDescriptors: $(@($receipt.reference_assembly.referenced_file_descriptors).Count); AllReferencedDocuments: $(@($receipt.reference_assembly.all_referenced_documents).Count)"
    } finally { try { $asm.Close($true) } catch { $errors += "assembly close: $($_.Exception.Message)" } }
    # ---- 3. reopen the part and read the reference back ----
    $doc2 = $app.Documents.Open($refIpt, $false)
    try {
        $ic2 = $doc2.ComponentDefinition.ReferenceComponents.ImportedComponents
        $reopen = [ordered]@{ imported_components = [int]$ic2.Count; components = @() }
        for ($i = 1; $i -le $ic2.Count; $i++) { $c2 = $ic2.Item($i); $reopen.components += [ordered]@{ name = [string]$c2.Name; linked_to_file = $(try { [bool]$c2.LinkedToFile } catch { $null }); referenced_file = $(try { [string]$c2.ReferencedFile } catch { $null }); health_status = $(try { [int]$c2.HealthStatus } catch { $null }) } }
        $reopen.referenced_file_descriptors = Descriptors $doc2
        $receipt.reopened_part = $reopen
        Log "Reopened part: $($reopen.imported_components) imported component(s); descriptors $(@($reopen.referenced_file_descriptors).Count)"
    } finally { try { $doc2.Close($true) } catch { $errors += "reopen close: $($_.Exception.Message)" } }
} catch {
    $errors += $_.Exception.Message; Log "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace }
} finally {
    $shutdown = Stop-IsolatedInventor $session $project
    if (-not $shutdown.Succeeded) { $errors += "shutdown not observed as complete: $($shutdown.Observed | ConvertTo-Json -Compress)" }
    Log "Shutdown: pid $($shutdown.Pid) exited=$($shutdown.Exited) succeeded=$($shutdown.Succeeded)"
    if ($watchdog) { $dialogs = Stop-DialogWatchdog $watchdog; Log "Dialog watchdog: $($dialogs.Polls) polls, $($dialogs.Events.Count) dialog window(s) seen, $($dialogs.Dismissed) dismissed, $($dialogs.Left) left alone" }
}
$changed = @(); $added = @()
foreach ($f in Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File) { $rel = $f.FullName.Substring($WorkspaceRoot.Length + 1); $sha = Sha $f.FullName; if ($hashesBefore.Contains($rel)) { if ($hashesBefore[$rel] -ne $sha) { $changed += $rel } } else { $added += $rel } }
$expectedAdded = @($refIpt.Substring($WorkspaceRoot.Length + 1), $refIam.Substring($WorkspaceRoot.Length + 1))
$unexpected = @(@($changed | Where-Object { $_ -notlike "*.ipj" }) + @($added | Where-Object { $expectedAdded -notcontains $_ -and $_ -notlike "*\OldVersions\*" }))
$receipt.integrity = [ordered]@{ copy_files_changed = $changed; copy_files_added = $added; unexpected = $unexpected }
if ($unexpected.Count) { $errors += "unexpected changes in the copy: $($unexpected -join '; ')" }
$receipt.session = [ordered]@{ pid = $session.Pid; inventor = "$($session.Version) build $($session.Build)"; shutdown = [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; observed = $shutdown.Observed; failed_required = @($shutdown.FailedRequired); notes = @($shutdown.Notes) } }
$receipt.project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_added_by_run = $project.AddedEntry; entry_removed_by_run = $shutdown.ProjectEntryRemoved; previous_restored = $shutdown.PreviousProjectRestored } } else { $null })
$receipt.dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors) } } else { $null })
$receipt.errors = $errors
$receipt.status = $(if ($errors.Count -eq 0 -and $shutdown.Succeeded -and $receipt.reopened_part) { Resolve-RunStatus -Status "complete" -Dialogs $dialogs } else { "FAILED" })
ConvertTo-Json -InputObject $receipt -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "reference-model-probe.json") -Encoding UTF8
Log "Probe status: $($receipt.status)"
if ($receipt.status -notlike "complete*") { exit 1 }
