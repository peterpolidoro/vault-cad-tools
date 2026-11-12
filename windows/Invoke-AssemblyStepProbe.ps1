<#
.SYNOPSIS
Read-only check: Inventor's own STEP export of a whole assembly, as ONE file, from the acquired mirror.

.DESCRIPTION
Opens the assembly exactly as Export-PartAssets.ps1 opens the root for a snapshot: an owned, invisible Inventor
instance, the temporary project of the mirror, Documents.Open(path, OpenVisible = false), and every opened
document bound to the acquisition record and the dependency inventory by hash before anything is exported.
No representation is changed. The STEP translator then writes the assembly document itself into one file, with
the option values the part exports use (the protocol given, sketches not included, everything else as the
translator reports it). The document is closed without saving. Nothing is written outside -OutputDirectory,
which must not exist or must be empty. Vault is not contacted.

A STEP file of a whole assembly is evidence for a comparison (mechanical-cad/tools/compare_assembly_step.py);
it is not part of any package and nothing here changes what the exporter writes.

Recorded in assembly-step-probe.json:
  - the bound inputs, each against its acquisition record;
  - the active model state, design view representation, positional representation and level of detail of the
    root and of every sub-assembly occurrence, and how many views the root and its referenced documents have;
  - Inventor's occurrence tree: every occurrence with its path, kind, document, model state, world placement
    (cm) and flags (suppressed, visible, excluded, BOM structure, flexible, adaptive, substitute, grounded),
    the counts of part and sub-assembly occurrences, and AllLeafOccurrences as Inventor counts them;
  - the translator's options as reported for the assembly document and as set, the duration and the result;
  - the dirty flag of the root at each step and the referenced documents that are dirty after the export;
  - SHA-256 and size of every file under -WorkspaceRoot before Inventor starts and after it has exited;
  - from the file's text (Step-Header.ps1, Step-Units.ps1): header, protocol, length unit, entity counts and
    what Get-StepInvisibility finds.
The STEP file is kept as the translator wrote it; its header may name the author of the native file.
Outputs: <OutputName>, assembly-step-probe.json, probe.log, dialogs.log. Exit code 1 unless the status is complete.
#>
param(
    [Parameter(Mandatory = $true)][string]$NativeAssembly,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$Acquisition,
    [Parameter(Mandatory = $true)][string]$Inventory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidateSet(2, 3, 4, 5)][int]$ApplicationProtocolType = 5,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._-]*\.(step|stp)$')][string]$OutputName = "root-assembly.step",
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")
. (Join-Path $PSScriptRoot "Step-Units.ps1")
. (Join-Path $PSScriptRoot "Step-Header.ps1")

function Sha($file) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() }
function Utc { [DateTime]::UtcNow.ToString("o") }
# ---- pre-flight (no Inventor yet) ----
foreach ($required in @($NativeAssembly, $WorkspaceRoot, $Acquisition, $Inventory)) { if (-not (Test-Path -LiteralPath $required)) { throw "Not found: $required" } }
$NativeAssembly = (Resolve-Path -LiteralPath $NativeAssembly).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\')
if (-not $NativeAssembly.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant() + '\')) { throw "The assembly is not under the workspace root" }
$acqJson = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
$invJson = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json
if (-not $acqJson.files -or -not $invJson.files) { throw "Acquisition/inventory records have no files" }
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$outPath = Join-Path $OutputDirectory $OutputName
$log = Join-Path $OutputDirectory "probe.log"
function Log($line) { Add-Content -LiteralPath $log -Value "$(Utc) $line"; Write-Output $line }

$kPart = 12290; $kAssembly = 12291; $kFileBrowseIOMechanism = 13059; $stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
$protocolNames = @{ 2 = "AP203"; 3 = "AP214"; 4 = "AP203E2"; 5 = "AP242" }
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
$bomNames = @{ 51969 = "Default"; 51970 = "Normal"; 51971 = "Phantom"; 51972 = "Reference"; 51973 = "Purchased"; 51974 = "Inseparable"; 51975 = "Varies" }
$countedEntities = @("MANIFOLD_SOLID_BREP", "BREP_WITH_VOIDS", "NEXT_ASSEMBLY_USAGE_OCCURRENCE", "PRODUCT", "PRODUCT_DEFINITION", "PRODUCT_DEFINITION_SHAPE", "SHAPE_REPRESENTATION",
    "ADVANCED_BREP_SHAPE_REPRESENTATION", "SHAPE_REPRESENTATION_RELATIONSHIP", "CONTEXT_DEPENDENT_SHAPE_REPRESENTATION", "ITEM_DEFINED_TRANSFORMATION", "MAPPED_ITEM", "STYLED_ITEM",
    "OVER_RIDING_STYLED_ITEM", "INVISIBILITY", "CAMERA_MODEL_D3", "DRAUGHTING_MODEL", "SHELL_BASED_SURFACE_MODEL", "GEOMETRIC_CURVE_SET")
function Get-MapName($map, $i) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($i)) }
function Get-MapValue($map, $k) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($k)) }
function Set-MapValue($map, $k, $v) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($k, $v)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
function Read-MapTypes($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $value = Get-MapValue $map $n; $r[$n] = $(if ($null -eq $value) { "null" } else { $value.GetType().Name }) }; return $r }
function Cells($m) { $rows = @(); for ($r = 1; $r -le 4; $r++) { $row = @(); for ($c = 1; $c -le 4; $c++) { $row += [double]$m.GetType().InvokeMember("Cell", [Reflection.BindingFlags]::GetProperty, $null, $m, @($r, $c)) }; $rows += ,$row }; return ,$rows }
function Relative($file) { if ($file.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant() + '\')) { return $file.Substring($WorkspaceRoot.Length + 1) }; return $file }
function Read-Tree($root) {
    # Every file under the root: relative path -> SHA-256 and size.
    $tree = [ordered]@{}
    foreach ($item in (Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName)) { $tree[$item.FullName.Substring($root.Length + 1)] = [ordered]@{ sha256 = (Sha $item.FullName); bytes = $item.Length } }
    return $tree
}
function Try-Read([scriptblock]$query) { try { return (& $query) } catch { return $null } }   # descriptive values only
function Get-AllLeafCount($occurrences) {
    # AllLeafOccurrences is a property with an optional argument; late-bound it has to be invoked, not read.
    try { $leaves = $occurrences.GetType().InvokeMember("AllLeafOccurrences", [Reflection.BindingFlags]::GetProperty, $null, $occurrences, $null); return [int]$leaves.Count } catch { return $null }
}

$treeBefore = Read-Tree $WorkspaceRoot
$session = Start-IsolatedInventor
$app = $session.App
Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build)); started $($session.StartedAt.ToString('o')); application visible: $([bool]$app.Visible)"
$project = $null; $errors = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null
$watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $OutputDirectory "dialogs.log")
$inputs = @(); $rootRecord = $null; $viewCensus = $null; $export = $null; $translatorInfo = $null
$script:census = @()
function Add-Occurrences($occurrences, $parentPath, $depth, $parentVisible) {
    # Called as a statement only: it files what it finds in $script:census and returns nothing.
    foreach ($o in $occurrences) {
        $id = $(if ($parentPath) { "$parentPath/$($o.Name)" } else { [string]$o.Name })
        $kind = $(if ([int]$o.DefinitionDocumentType -eq $kAssembly) { "assembly" } elseif ([int]$o.DefinitionDocumentType -eq $kPart) { "part" } else { "other:$([int]$o.DefinitionDocumentType)" })
        $suppressed = [bool]$o.Suppressed
        $record = [ordered]@{ id = $id; name = [string]$o.Name; depth = $depth; kind = $kind; suppressed = $suppressed }
        if ($suppressed) { $script:census += $record; continue }
        $visible = [bool]$o.Visible; $bom = Try-Read { [int]$o.BOMStructure }
        $record.document = Relative ([string]$o.Definition.Document.FullFileName)
        $record.model_state = Try-Read { [string]$o.ActiveModelState }
        $record.visible = $visible; $record.visible_effective = ($parentVisible -and $visible)
        $record.excluded = Try-Read { [bool]$o.Excluded }
        $record.bom_structure = $(if ($null -ne $bom) { $bomNames[$bom] } else { $null })
        $record.grounded = Try-Read { [bool]$o.Grounded }; $record.adaptive = Try-Read { [bool]$o.Adaptive }; $record.substitute = Try-Read { [bool]$o.IsSubstituteOccurrence }
        $record.flexible = Try-Read { [bool]$o.Flexible }
        $record.transform_world_cm = Cells $o.Transformation
        if ($kind -eq "assembly") {
            $record.design_view_representation = Try-Read { [string]$o.ActiveDesignViewRepresentation }
            $record.positional_representation = Try-Read { [string]$o.ActivePositionalRepresentation }
            $record.level_of_detail = Try-Read { [string]$o.ActiveLevelOfDetailRepresentation }
            $record.children = [int]$o.SubOccurrences.Count
            $script:census += $record
            Add-Occurrences $o.SubOccurrences $id ($depth + 1) ($parentVisible -and $visible)
        } else { $script:census += $record }
    }
}
try {
    $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); created file: $($project.CreatedFile))"
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $translatorInfo = [ordered]@{ display_name = [string]$translator.DisplayName; client_id = $stepTranslatorClsid; activated = [bool]$translator.Activated }
    $to = $app.TransientObjects
    Log "Opening $(Relative $NativeAssembly) with Documents.Open(path, OpenVisible = false)"
    $asm = $app.Documents.Open($NativeAssembly, $false)
    try {
        if ([int]$asm.DocumentType -ne $kAssembly) { throw "Not an assembly document: $NativeAssembly" }
        $dirtyAfterOpen = [bool]$asm.Dirty
        $inputs = Confirm-AcquiredInputs $asm $acqJson $invJson
        Log "Bound $($inputs.Count) opened documents to acquisition/inventory ($(@($inputs | Where-Object { $_.kind -eq 'assembly' }).Count) assemblies, $(@($inputs | Where-Object { $_.kind -eq 'part' }).Count) parts)"
        $rootDef = $asm.ComponentDefinition; $manager = $rootDef.RepresentationsManager
        $rootRecord = [ordered]@{ document = (Relative $NativeAssembly); length_units = $lengthUnitNames[[int]$asm.UnitsOfMeasure.LengthUnits]
            model_state = [string]$rootDef.ModelStates.ActiveModelState.Name; model_states = [int]$rootDef.ModelStates.Count
            design_view_representation = [string]$manager.ActiveDesignViewRepresentation.Name; design_view_representations = (Try-Read { [int]$manager.DesignViewRepresentations.Count })
            positional_representation = [string]$manager.ActivePositionalRepresentation.Name; positional_representations = (Try-Read { [int]$manager.PositionalRepresentations.Count })
            level_of_detail = [string]$manager.ActiveLevelOfDetailRepresentation.Name; levels_of_detail = (Try-Read { [int]$manager.LevelOfDetailRepresentations.Count })
            top_level_occurrences = [int]$rootDef.Occurrences.Count; all_leaf_occurrences = (Get-AllLeafCount $rootDef.Occurrences)
            representations_changed_by_probe = $false }
        Log "Root: model state $($rootRecord.model_state), design view '$($rootRecord.design_view_representation)', positional '$($rootRecord.positional_representation)', level of detail '$($rootRecord.level_of_detail)'; $($rootRecord.top_level_occurrences) top-level occurrences, AllLeafOccurrences $($rootRecord.all_leaf_occurrences)"
        $referenced = @($asm.AllReferencedDocuments); $withViews = @($referenced | Where-Object { [int]$_.Views.Count -gt 0 })
        $viewCensus = [ordered]@{ application_visible = [bool]$app.Visible; assembly_views = [int]$asm.Views.Count; referenced_documents = $referenced.Count; referenced_documents_with_views = $withViews.Count
            documents_with_views = @($withViews | ForEach-Object { Relative ([string]$_.FullFileName) }) }
        Log "Views: assembly $($viewCensus.assembly_views); $($referenced.Count) referenced documents, $($withViews.Count) with a view"
        $walk = [Diagnostics.Stopwatch]::StartNew()
        Add-Occurrences $rootDef.Occurrences "" 1 $true
        $walkSeconds = [Math]::Round($walk.Elapsed.TotalSeconds, 1)
        Log "Occurrences: $(@($script:census | Where-Object { $_.kind -eq 'part' }).Count) part, $(@($script:census | Where-Object { $_.kind -eq 'assembly' }).Count) sub-assembly, $(@($script:census | Where-Object { $_.suppressed }).Count) suppressed (walk $walkSeconds s)"
        # ---- the export: the assembly document itself, with the option values the part exports use ----
        $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
        $opts = $to.CreateNameValueMap()
        $hasOptions = [bool]$translator.HasSaveCopyAsOptions($asm, $ctx, $opts)
        $reported = $(if ($hasOptions) { Read-Map $opts } else { $null }); $reportedTypes = $(if ($hasOptions) { Read-MapTypes $opts } else { $null })
        if ($hasOptions) { Set-MapValue $opts "ApplicationProtocolType" $ApplicationProtocolType; if ((Read-Map $opts).Contains("IncludeSketches")) { Set-MapValue $opts "IncludeSketches" $false } }
        $optionsBefore = Read-Map $opts
        $medium = $to.CreateDataMedium(); $medium.FileName = $outPath
        $dirtyBeforeExport = [bool]$asm.Dirty; $exportError = $null; $started = Utc
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try { $translator.SaveCopyAs($asm, $ctx, $opts, $medium) } catch { $exportError = $_.Exception.Message }
        $seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $finished = Utc
        $dirtyDocuments = @($referenced | Where-Object { [bool]$_.Dirty } | ForEach-Object { Relative ([string]$_.FullFileName) })
        $export = [ordered]@{ file = $OutputName; document_exported = (Relative $NativeAssembly); protocol_requested = $protocolNames[$ApplicationProtocolType]; application_protocol_type = $ApplicationProtocolType
            has_save_copy_as_options = $hasOptions; translator_options_reported = $reported; translator_option_types = $reportedTypes; translator_options_before = $optionsBefore; translator_options_after = (Read-Map $opts)
            export_started = $started; export_finished = $finished; seconds = $seconds; export_error = $exportError
            dirty_after_open = $dirtyAfterOpen; dirty_before_export = $dirtyBeforeExport; dirty_after_export = [bool]$asm.Dirty; referenced_documents_dirty_after_export = $dirtyDocuments
            views_after_export = [int]$asm.Views.Count }
        if ($exportError) { throw "The translator failed: $exportError" }
        if (-not (Test-Path -LiteralPath $outPath)) { throw "The translator returned and wrote no file" }
        Log "Exported $OutputName in $seconds s: $((Get-Item -LiteralPath $outPath).Length) bytes; translation result: $($export.translator_options_after['Translation Result'])"
    } finally { try { $asm.Close($true) } catch { $errors += "assembly close: $($_.Exception.Message)" } }
} catch {
    $errors += $_.Exception.Message; Log "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace }
} finally {
    $shutdown = Stop-IsolatedInventor $session $project
    if (-not $shutdown.Succeeded) { $errors += "shutdown not observed as complete: $($shutdown.Observed | ConvertTo-Json -Compress)" }
    Log "Shutdown: pid $($shutdown.Pid) exited=$($shutdown.Exited) succeeded=$($shutdown.Succeeded)"
    if ($watchdog) { $dialogs = Stop-DialogWatchdog $watchdog; Log "Dialog watchdog: $($dialogs.Polls) polls, $($dialogs.Events.Count) dialog window(s) seen, $($dialogs.Dismissed) dismissed, $($dialogs.Left) left alone" }
}
# ---- integrity: no file of the mirror may have changed, appeared or disappeared ----
$treeAfter = Read-Tree $WorkspaceRoot
$changed = @(); $added = @(); $removed = @()
foreach ($name in $treeBefore.Keys) { if (-not $treeAfter.Contains($name)) { $removed += $name } elseif ($treeAfter[$name].sha256 -ne $treeBefore[$name].sha256) { $changed += $name } }
foreach ($name in $treeAfter.Keys) { if (-not $treeBefore.Contains($name)) { $added += $name } }
if ($changed.Count + $added.Count + $removed.Count -gt 0) { $errors += "the mirror changed: $($changed.Count) changed, $($added.Count) added, $($removed.Count) removed" }
$inputsChanged = @()
foreach ($bindingRecord in @($inputs)) { if ((Sha $bindingRecord.path) -ne [string]$bindingRecord.acquisition_sha256) { $inputsChanged += (Relative ([string]$bindingRecord.path)) } }
if ($inputsChanged.Count -gt 0) { $errors += "opened documents changed on disk: $($inputsChanged -join '; ')" }
Log "Mirror: $($treeBefore.Count) files before, $($treeAfter.Count) after; changed $($changed.Count), added $($added.Count), removed $($removed.Count); bound inputs changed on disk: $($inputsChanged.Count)"
# ---- the file's text ----
$text = $null
if (Test-Path -LiteralPath $outPath) {
    $text = [ordered]@{ errors = @() }
    try {
        $info = Get-StepFileInfo -Path $outPath
        $text.bytes = $info.bytes; $text.sha256 = $info.sha256; $text.data_sha256 = $info.data_sha256; $text.data_offset = $info.data_offset
        $text.file_schema = $info.file_schema_statement; $text.protocol = $info.header.protocol; $text.header = $info.header
        if ($info.header.protocol -ne $protocolNames[$ApplicationProtocolType]) { $text.errors += "the file's schema says $($info.header.protocol), requested $($protocolNames[$ApplicationProtocolType])" }
    } catch { $text.errors += "header: $($_.Exception.Message)" }
    try { $unit = Get-StepLengthUnit $outPath; $text.length_unit = $unit.unit; $text.length_unit_ok = $unit.ok; $text.length_unit_reason = $unit.reason; $text.length_unit_contexts = @($unit.contexts).Count
        $text.length_units_of_contexts = @(@($unit.contexts) | ForEach-Object { $_.unit } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }) } catch { $text.errors += "length unit: $($_.Exception.Message)" }
    try { $text.entity_counts = Get-StepEntityCounts -Path $outPath -Type $countedEntities; $text.solid_instances = [int]$text.entity_counts["MANIFOLD_SOLID_BREP"] + [int]$text.entity_counts["BREP_WITH_VOIDS"] } catch { $text.errors += "entity counts: $($_.Exception.Message)" }
    try { $text.invisibility = Get-StepInvisibility -Path $outPath } catch { $text.errors += "invisibility: $($_.Exception.Message)" }
    foreach ($message in @($text.errors)) { $errors += "text of the file: $message" }
    Log "Text: $($text.protocol), length unit $($text.length_unit) (ok=$($text.length_unit_ok)); solids $($text.solid_instances) (MANIFOLD_SOLID_BREP $($text.entity_counts['MANIFOLD_SOLID_BREP']), BREP_WITH_VOIDS $($text.entity_counts['BREP_WITH_VOIDS'])); NEXT_ASSEMBLY_USAGE_OCCURRENCE $($text.entity_counts['NEXT_ASSEMBLY_USAGE_OCCURRENCE']); INVISIBILITY $($text.entity_counts['INVISIBILITY'])"
} else { $errors += "no STEP file was written" }
$partOccurrences = @($script:census | Where-Object { $_.kind -eq "part" -and -not $_.suppressed }); $assemblyOccurrences = @($script:census | Where-Object { $_.kind -eq "assembly" -and -not $_.suppressed })
$counts = [ordered]@{ occurrences = @($script:census).Count; part_occurrences = $partOccurrences.Count; sub_assembly_occurrences = $assemblyOccurrences.Count
    suppressed = @($script:census | Where-Object { $_.suppressed }).Count; invisible = @($script:census | Where-Object { -not $_.suppressed -and -not $_.visible }).Count
    invisible_effective = @($script:census | Where-Object { -not $_.suppressed -and -not $_.visible_effective }).Count; excluded = @($script:census | Where-Object { $_.excluded }).Count
    flexible = @($script:census | Where-Object { $_.flexible }).Count; adaptive = @($script:census | Where-Object { $_.adaptive }).Count; substitute = @($script:census | Where-Object { $_.substitute }).Count
    reference_bom_structure = @($script:census | Where-Object { $_.bom_structure -eq "Reference" }).Count; phantom_bom_structure = @($script:census | Where-Object { $_.bom_structure -eq "Phantom" }).Count
    distinct_part_documents = @($partOccurrences | ForEach-Object { "$($_.document)|$($_.model_state)" } | Sort-Object -Unique).Count
    distinct_assembly_documents = @($assemblyOccurrences | ForEach-Object { "$($_.document)|$($_.model_state)" } | Sort-Object -Unique).Count }
$status = $(if ($errors.Count -eq 0 -and $shutdown.Succeeded -and $export -and -not $export.export_error) { Resolve-RunStatus -Status "complete" -Dialogs $dialogs } else { "FAILED" })
$receipt = [ordered]@{ schema_version = 1; generated_at = (Utc); probe = "windows/Invoke-AssemblyStepProbe.ps1"; status = $status; errors = $errors
    scope = "read-only STEP export of the assembly document itself; no representation changed; nothing saved; every file of the mirror hashed before and after"
    host = $env:COMPUTERNAME; inventor = "$($session.Version) build $($session.Build)"; workspace_root = $WorkspaceRoot; acquisition_record = $Acquisition; inventory_record = $Inventory
    opened = "Documents.Open(path, OpenVisible = false) in the owned instance, as Export-PartAssets.ps1 opens the root"
    session = [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; started_at = $session.StartedAt.ToString("o"); pre_existing_inventor_pids = $session.PreExistingPids
        shutdown = [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; observed = $shutdown.Observed; failed_required = @($shutdown.FailedRequired); notes = @($shutdown.Notes) } }
    project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; created_file = $project.CreatedFile; entry_removed_by_run = $shutdown.ProjectEntryRemoved; previous_restored = $shutdown.PreviousProjectRestored } } else { $null })
    input_binding = [ordered]@{ mode = "strict acquisition binding"; opened_documents = @($inputs).Count; verified = @($inputs | Where-Object verified).Count; assemblies = @($inputs | Where-Object { $_.kind -eq "assembly" }).Count; parts = @($inputs | Where-Object { $_.kind -eq "part" }).Count
        changed_on_disk_after_run = $inputsChanged; inputs = $inputs }
    root = $rootRecord; view_census = $viewCensus; translator = $translatorInfo; export = $export; text_of_the_file = $text
    occurrence_counts = $counts; occurrences = @($script:census)
    mirror = [ordered]@{ files_before = $treeBefore.Count; files_after = $treeAfter.Count; changed = $changed; added = $added; removed = $removed; unchanged = ($changed.Count + $added.Count + $removed.Count -eq 0); before = $treeBefore; after = $treeAfter }
    dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; log = "dialogs.log"; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors) } } else { $null }) }
ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "assembly-step-probe.json") -Encoding UTF8
Log "Probe status: $status"
if ($status -notlike "complete*") { exit 1 }
