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

What the receipt states as a fact is read as one: the flags its counts rest on (suppressed, visible), the kind and
document of an occurrence, the views and the dirty flags are guard queries that hold no cast (Get-RequiredValue in
Package-Format.ps1), and a collection must exist and give as many items as it counts. A flag that is only
described (excluded, grounded, adaptive, substitute, flexible) is null when Inventor does not give it, and the
receipt counts those. So is the number of items of a collection that is only described (Get-OptionalCount: the
collection is handed over, because a count asked in one step gives 0 for a collection that is missing). Flexible is asked of an assembly occurrence only; Inventor does not define it for a part
occurrence, which is recorded as not flexible. Inventor is started inside the try whose finally stops it, and
nothing after that runs outside a try: a receipt is always written.
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
. (Join-Path $PSScriptRoot "Package-Format.ps1")   # guard queries and directory hashes; also Step-Header.ps1 and Step-Units.ps1

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
function Cells($m) {
    # The 16 cells of an Inventor matrix. A matrix that is missing, or a cell that is not a number, is refused: [double]$null is 0.
    if ($null -eq $m) { throw "A placement matrix is missing" }
    $rows = @()
    for ($r = 1; $r -le 4; $r++) { $row = @(); for ($c = 1; $c -le 4; $c++) { $cell = $m.GetType().InvokeMember("Cell", [Reflection.BindingFlags]::GetProperty, $null, $m, @($r, $c)); if (-not (Test-PackageNumber $cell)) { throw "Cell $r,$c of a placement matrix is not a number" }; $row += [double]$cell }; $rows += ,$row }
    return ,$rows
}
function Relative($file) { if ($file.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant() + '\')) { return $file.Substring($WorkspaceRoot.Length + 1) }; return $file }
function Get-AllLeafCount($occurrences) {
    # AllLeafOccurrences is a property with an optional argument; late-bound it has to be invoked, not read.
    # $null when it cannot be read: the count of nothing is 0 in PowerShell and would look like "no leaves".
    try { $leaves = $occurrences.GetType().InvokeMember("AllLeafOccurrences", [Reflection.BindingFlags]::GetProperty, $null, $occurrences, $null) } catch { return $null }
    if ($null -eq $leaves) { return $null }
    return (Get-OptionalCount $leaves)
}

$session = $null; $app = $null; $project = $null; $errors = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null
$inputs = @(); $rootRecord = $null; $viewCensus = $null; $export = $null; $translatorInfo = $null; $treeBefore = $null; $mirror = $null; $text = $null; $counts = $null
$inputsChanged = @(); $status = "FAILED"
$script:census = @()
function Add-Occurrences($occurrences, $parentPath, $depth, $parentVisible) {
    # Called as a statement only: it files what it finds in $script:census and returns nothing. The collection must
    # exist and must give as many items as it counts.
    $whose = $(if ($parentPath) { "'$parentPath'" } else { "the root" })
    $expected = Get-RequiredCount "occurrences of $whose" $occurrences
    $seen = 0
    foreach ($o in $occurrences) {
        $seen++
        $name = Get-RequiredValue "name of an occurrence of $whose" { $o.Name } -Kind string
        $id = $(if ($parentPath) { "$parentPath/$name" } else { $name })
        $typeCode = Get-RequiredValue "DefinitionDocumentType of '$id'" { $o.DefinitionDocumentType } -Kind int
        $kind = $(if ($typeCode -eq $kAssembly) { "assembly" } elseif ($typeCode -eq $kPart) { "part" } else { "other:$typeCode" })
        $suppressed = Get-RequiredValue "Suppressed of '$id'" { $o.Suppressed }
        $record = [ordered]@{ id = $id; name = $name; depth = $depth; kind = $kind; suppressed = $suppressed }
        if ($suppressed) { $script:census += $record; continue }
        $visible = Get-RequiredValue "Visible of '$id'" { $o.Visible }; $bom = Get-OptionalValue { $o.BOMStructure } "int"
        $record.document = Relative (Get-RequiredValue "document of '$id'" { $o.Definition.Document.FullFileName } -Kind string)
        $record.model_state = Get-OptionalValue { $o.ActiveModelState } "string"
        $record.visible = $visible; $record.visible_effective = ($parentVisible -and $visible)
        $record.excluded = Get-OptionalValue { $o.Excluded } "bool"
        $record.bom_structure = $(if ($null -ne $bom) { $bomNames[$bom] } else { $null })
        $record.grounded = Get-OptionalValue { $o.Grounded } "bool"; $record.adaptive = Get-OptionalValue { $o.Adaptive } "bool"; $record.substitute = Get-OptionalValue { $o.IsSubstituteOccurrence } "bool"
        # Inventor defines Flexible for an occurrence of an assembly only: a part occurrence is recorded as not
        # flexible, as Export-Package.ps1 records it, and is not counted among the flags that were not read.
        $record.flexible = $(if ($kind -eq "assembly") { Get-OptionalValue { $o.Flexible } "bool" } else { $false })
        $record.transform_world_cm = Cells $o.Transformation
        if ($kind -eq "assembly") {
            $record.design_view_representation = Get-OptionalValue { $o.ActiveDesignViewRepresentation } "string"
            $record.positional_representation = Get-OptionalValue { $o.ActivePositionalRepresentation } "string"
            $record.level_of_detail = Get-OptionalValue { $o.ActiveLevelOfDetailRepresentation } "string"
            $subOccurrences = $o.SubOccurrences
            $record.children = Get-RequiredCount "occurrences of '$id'" $subOccurrences
            $script:census += $record
            Add-Occurrences $subOccurrences $id ($depth + 1) ($parentVisible -and $visible)
        } else { $script:census += $record }
    }
    if ($seen -ne $expected) { throw "The occurrences of $whose count $expected and gave $seen" }
}
# Inventor is started INSIDE the try whose finally stops it: nothing between the start and the try can fail and
# leave the instance running.
try {
    # every file of the mirror, before Inventor exists
    $treeBefore = Get-PackageDirectoryHashes $WorkspaceRoot
    $session = Start-IsolatedInventor
    $app = $session.App
    Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build)); started $($session.StartedAt.ToString('o')); application visible: $(Get-RequiredValue 'Visible of the application' { $app.Visible })"
    $watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $OutputDirectory "dialogs.log")
    $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); created file: $($project.CreatedFile))"
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $translatorInfo = [ordered]@{ display_name = (Get-OptionalValue { $translator.DisplayName } "string"); client_id = $stepTranslatorClsid; activated = (Get-OptionalValue { $translator.Activated } "bool") }
    $to = $app.TransientObjects
    Log "Opening $(Relative $NativeAssembly) with Documents.Open(path, OpenVisible = false)"
    $asm = $app.Documents.Open($NativeAssembly, $false)
    try {
        if ((Get-RequiredValue "document type of the root" { $asm.DocumentType } -Kind int) -ne $kAssembly) { throw "Not an assembly document: $NativeAssembly" }
        $dirtyAfterOpen = Get-RequiredValue "Dirty of the root after opening" { $asm.Dirty }
        $inputs = Confirm-AcquiredInputs $asm $acqJson $invJson
        Log "Bound $($inputs.Count) opened documents to acquisition/inventory ($(@($inputs | Where-Object { $_.kind -eq 'assembly' }).Count) assemblies, $(@($inputs | Where-Object { $_.kind -eq 'part' }).Count) parts)"
        $rootDef = $asm.ComponentDefinition; $manager = $rootDef.RepresentationsManager
        $rootOccurrences = $rootDef.Occurrences
        $unitCode = Get-OptionalValue { $asm.UnitsOfMeasure.LengthUnits } "int"
        $rootRecord = [ordered]@{ document = (Relative $NativeAssembly); length_units = $(if ($null -ne $unitCode) { $lengthUnitNames[$unitCode] } else { $null })
            model_state = (Get-RequiredValue "model state of the root" { $rootDef.ModelStates.ActiveModelState.Name } -Kind string); model_states = (Get-OptionalCount $rootDef.ModelStates)
            design_view_representation = (Get-RequiredValue "design view representation of the root" { $manager.ActiveDesignViewRepresentation.Name } -Kind string); design_view_representations = (Get-OptionalCount $manager.DesignViewRepresentations)
            positional_representation = (Get-RequiredValue "positional representation of the root" { $manager.ActivePositionalRepresentation.Name } -Kind string); positional_representations = (Get-OptionalCount $manager.PositionalRepresentations)
            level_of_detail = (Get-RequiredValue "level of detail of the root" { $manager.ActiveLevelOfDetailRepresentation.Name } -Kind string); levels_of_detail = (Get-OptionalCount $manager.LevelOfDetailRepresentations)
            top_level_occurrences = (Get-RequiredCount "top-level occurrences" $rootOccurrences); all_leaf_occurrences = (Get-AllLeafCount $rootOccurrences)
            representations_changed_by_probe = $false }
        Log "Root: model state $($rootRecord.model_state), design view '$($rootRecord.design_view_representation)', positional '$($rootRecord.positional_representation)', level of detail '$($rootRecord.level_of_detail)'; $($rootRecord.top_level_occurrences) top-level occurrences, AllLeafOccurrences $($rootRecord.all_leaf_occurrences)"
        # the views: of the root and of every referenced document, each a collection that must exist
        $rootViews = $asm.Views
        # the documents the root references are a collection that must exist and give as many items as it counts
        $referencedDocuments = $asm.AllReferencedDocuments
        $referenced = @(Get-RequiredItems "documents the root references" $referencedDocuments); $withViews = @()
        foreach ($document in $referenced) { $documentViews = $document.Views; if ((Get-RequiredCount "views of a referenced document" $documentViews) -gt 0) { $withViews += (Relative (Get-RequiredValue "file name of a referenced document" { $document.FullFileName } -Kind string)) } }
        $viewCensus = [ordered]@{ application_visible = (Get-RequiredValue "Visible of the application" { $app.Visible }); assembly_views = (Get-RequiredCount "views of the root" $rootViews); referenced_documents = $referenced.Count; referenced_documents_with_views = $withViews.Count
            documents_with_views = $withViews }
        Log "Views: assembly $($viewCensus.assembly_views); $($referenced.Count) referenced documents, $($withViews.Count) with a view"
        $walk = [Diagnostics.Stopwatch]::StartNew()
        Add-Occurrences $rootOccurrences "" 1 $true
        $walkSeconds = [Math]::Round($walk.Elapsed.TotalSeconds, 1)
        Log "Occurrences: $(@($script:census | Where-Object { $_.kind -eq 'part' }).Count) part, $(@($script:census | Where-Object { $_.kind -eq 'assembly' }).Count) sub-assembly, $(@($script:census | Where-Object { $_.suppressed }).Count) suppressed (walk $walkSeconds s)"
        # ---- the export: the assembly document itself, with the option values the part exports use ----
        $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
        $opts = $to.CreateNameValueMap()
        $hasOptions = Get-RequiredValue "HasSaveCopyAsOptions for the root" { $translator.HasSaveCopyAsOptions($asm, $ctx, $opts) }
        $reported = $(if ($hasOptions) { Read-Map $opts } else { $null }); $reportedTypes = $(if ($hasOptions) { Read-MapTypes $opts } else { $null })
        if ($hasOptions) { Set-MapValue $opts "ApplicationProtocolType" $ApplicationProtocolType; if ((Read-Map $opts).Contains("IncludeSketches")) { Set-MapValue $opts "IncludeSketches" $false } }
        $optionsBefore = Read-Map $opts
        $medium = $to.CreateDataMedium(); $medium.FileName = $outPath
        $dirtyBeforeExport = Get-RequiredValue "Dirty of the root before the export" { $asm.Dirty }; $exportError = $null; $started = Utc
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try { $translator.SaveCopyAs($asm, $ctx, $opts, $medium) } catch { $exportError = $_.Exception.Message }
        $seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $finished = Utc
        # a dirty flag that cannot be read is not "not dirty"
        $dirtyDocuments = @(); $dirtyUnknown = 0
        foreach ($document in $referenced) { $flag = Get-OptionalValue { $document.Dirty } "bool"; if ($null -eq $flag) { $dirtyUnknown++ } elseif ($flag) { $dirtyDocuments += (Relative ([string]$document.FullFileName)) } }
        $export = [ordered]@{ file = $OutputName; document_exported = (Relative $NativeAssembly); protocol_requested = $protocolNames[$ApplicationProtocolType]; application_protocol_type = $ApplicationProtocolType
            has_save_copy_as_options = $hasOptions; translator_options_reported = $reported; translator_option_types = $reportedTypes; translator_options_before = $optionsBefore; translator_options_after = (Read-Map $opts)
            export_started = $started; export_finished = $finished; seconds = $seconds; export_error = $exportError
            dirty_after_open = $dirtyAfterOpen; dirty_before_export = $dirtyBeforeExport; dirty_after_export = (Get-RequiredValue "Dirty of the root after the export" { $asm.Dirty })
            referenced_documents_dirty_after_export = $dirtyDocuments; referenced_documents_whose_dirty_flag_was_not_read = $dirtyUnknown
            views_after_export = (Get-RequiredCount "views of the root after the export" $rootViews) }
        if ($exportError) { throw "The translator failed: $exportError" }
        if (-not (Test-Path -LiteralPath $outPath)) { throw "The translator returned and wrote no file" }
        $translationResult = $export.translator_options_after["Translation Result"]
        if ($translationResult -isnot [string] -or $translationResult -cne "Successful") { throw "The translator did not report 'Successful': it reported '$translationResult'" }
        Log "Exported $OutputName in $seconds s: $((Get-Item -LiteralPath $outPath).Length) bytes; translation result: $translationResult"
    } finally { try { $asm.Close($true) } catch { $errors += "assembly close: $($_.Exception.Message)" } }
} catch {
    $errors += $_.Exception.Message
    try { Log "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace } } catch { }
} finally {
    # each step on its own: one that fails must not keep the next from running
    if ($session) {
        try { $shutdown = Stop-IsolatedInventor $session $project } catch { $errors += "the shutdown of the owned Inventor instance threw: $($_.Exception.Message)" }
        try { if (-not $shutdown -or -not $shutdown.Succeeded) { $errors += "shutdown not observed as complete: $(if ($shutdown) { $shutdown.Observed | ConvertTo-Json -Compress } else { 'no result' })" } } catch { $errors += "the shutdown could not be described: $($_.Exception.Message)" }
        try { Log "Shutdown: pid $($session.Pid) exited=$(if ($shutdown) { $shutdown.Exited }) succeeded=$(if ($shutdown) { $shutdown.Succeeded })" } catch { }
    }
    if ($watchdog) {
        try { $dialogs = Stop-DialogWatchdog $watchdog } catch { $errors += "the dialog watchdog could not be stopped: $($_.Exception.Message)" }
        try { if ($dialogs) { Log "Dialog watchdog: $($dialogs.Polls) polls, $($dialogs.Events.Count) dialog window(s) seen, $($dialogs.Dismissed) dismissed, $($dialogs.Left) left alone" } } catch { }
    }
}
# ---- after Inventor. Nothing from here on runs outside a try: whatever fails must still leave a receipt
# ---- (Test-PackageFormat.ps1, case P22, holds the script to this).
try {
    # no file of the mirror may have changed, appeared or disappeared
    if ($null -ne $treeBefore) {
        $mirror = Compare-PackageDirectoryHashes $treeBefore (Get-PackageDirectoryHashes $WorkspaceRoot)
        if (-not $mirror.unchanged) { $errors += "the mirror changed: $(@($mirror.changed).Count) changed, $(@($mirror.added).Count) added, $(@($mirror.removed).Count) removed" }
    } else { $errors += "the mirror was not hashed before the run" }
    foreach ($bindingRecord in @($inputs)) { if ((Sha $bindingRecord.path) -ne [string]$bindingRecord.acquisition_sha256) { $inputsChanged += (Relative ([string]$bindingRecord.path)) } }
    if ($inputsChanged.Count -gt 0) { $errors += "opened documents changed on disk: $($inputsChanged -join '; ')" }
    if ($mirror) { Log "Mirror: $($mirror.files_before) files before, $($mirror.files_after) after; changed $(@($mirror.changed).Count), added $(@($mirror.added).Count), removed $(@($mirror.removed).Count); bound inputs changed on disk: $($inputsChanged.Count)" }
    # ---- the file's text ----
    if (Test-Path -LiteralPath $outPath) {
        $text = [ordered]@{ errors = @() }
        try {
            $info = Get-StepFileInfo -Path $outPath
            $text.bytes = $info.bytes; $text.sha256 = $info.sha256; $text.data_sha256 = $info.data_sha256; $text.data_offset = $info.data_offset
            $text.file_schema = $info.file_schema_statement; $text.protocol = $info.header.protocol; $text.schemas = @($info.header.schemas); $text.header = $info.header
            if ($info.header.protocol -ne $protocolNames[$ApplicationProtocolType]) { $text.errors += "the file's schema says $($info.header.protocol), requested $($protocolNames[$ApplicationProtocolType])" }
            if (@($info.header.schemas).Count -ne 1) { $text.errors += "FILE_SCHEMA names $(@($info.header.schemas).Count) schemas: $(@($info.header.schemas) -join ' | ')" }
        } catch { $text.errors += "header: $($_.Exception.Message)" }
        # an assembly file has one unit context per product; they need not agree, and that is recorded, not refused
        try { $unit = Get-StepLengthUnit $outPath; $text.length_unit = $unit.unit; $text.length_unit_ok = $unit.ok; $text.length_unit_reason = $unit.reason; $text.length_unit_contexts = @($unit.contexts).Count
            $text.length_units_of_contexts = @(@($unit.contexts) | ForEach-Object { $_.unit } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }) } catch { $text.errors += "length unit: $($_.Exception.Message)" }
        try { $text.entity_counts = Get-StepEntityCounts -Path $outPath -Type $countedEntities; $text.solid_instances = $text.entity_counts["MANIFOLD_SOLID_BREP"] + $text.entity_counts["BREP_WITH_VOIDS"] } catch { $text.errors += "entity counts: $($_.Exception.Message)" }
        try { $text.invisibility = Get-StepInvisibility -Path $outPath } catch { $text.errors += "invisibility: $($_.Exception.Message)" }
        foreach ($message in @($text.errors)) { $errors += "text of the file: $message" }
        Log "Text: $($text.protocol), length unit $($text.length_unit) (ok=$($text.length_unit_ok)); solids $($text.solid_instances) (MANIFOLD_SOLID_BREP $($text.entity_counts['MANIFOLD_SOLID_BREP']), BREP_WITH_VOIDS $($text.entity_counts['BREP_WITH_VOIDS'])); NEXT_ASSEMBLY_USAGE_OCCURRENCE $($text.entity_counts['NEXT_ASSEMBLY_USAGE_OCCURRENCE']); INVISIBILITY $($text.entity_counts['INVISIBILITY'])"
    } else { $errors += "no STEP file was written" }
    $partOccurrences = @($script:census | Where-Object { $_.kind -eq "part" -and -not $_.suppressed }); $assemblyOccurrences = @($script:census | Where-Object { $_.kind -eq "assembly" -and -not $_.suppressed })
    $described = @("excluded", "grounded", "adaptive", "substitute", "flexible", "bom_structure", "model_state")
    $counts = [ordered]@{ occurrences = @($script:census).Count; part_occurrences = $partOccurrences.Count; sub_assembly_occurrences = $assemblyOccurrences.Count
        suppressed = @($script:census | Where-Object { $_.suppressed }).Count; invisible = @($script:census | Where-Object { -not $_.suppressed -and -not $_.visible }).Count
        invisible_effective = @($script:census | Where-Object { -not $_.suppressed -and -not $_.visible_effective }).Count; excluded = @($script:census | Where-Object { $_.excluded }).Count
        flexible = @($script:census | Where-Object { $_.flexible }).Count; adaptive = @($script:census | Where-Object { $_.adaptive }).Count; substitute = @($script:census | Where-Object { $_.substitute }).Count
        reference_bom_structure = @($script:census | Where-Object { $_.bom_structure -eq "Reference" }).Count; phantom_bom_structure = @($script:census | Where-Object { $_.bom_structure -eq "Phantom" }).Count
        occurrences_with_a_described_flag_that_was_not_read = @($script:census | Where-Object { $entry = $_; -not $entry.suppressed -and @($described | Where-Object { $null -eq $entry[$_] }).Count -gt 0 }).Count
        distinct_part_documents = @($partOccurrences | ForEach-Object { "$($_.document)|$($_.model_state)" } | Sort-Object -Unique).Count
        distinct_assembly_documents = @($assemblyOccurrences | ForEach-Object { "$($_.document)|$($_.model_state)" } | Sort-Object -Unique).Count }
    if ($errors.Count -eq 0 -and $shutdown -and $shutdown.Succeeded -and $export -and -not $export.export_error) { $status = Resolve-RunStatus -Status "complete" -Dialogs $dialogs }
} catch { $errors += "after Inventor was closed: $($_.Exception.Message)"; $status = "FAILED" }
# the receipt: always written
try {
    $receipt = [ordered]@{ schema_version = 2; generated_at = (Utc); probe = "windows/Invoke-AssemblyStepProbe.ps1"; status = $status; errors = $errors
        scope = "read-only STEP export of the assembly document itself; no representation changed; nothing saved; every file of the mirror hashed before and after"
        host = $env:COMPUTERNAME; inventor = $(if ($session) { "$($session.Version) build $($session.Build)" } else { $null }); workspace_root = $WorkspaceRoot; acquisition_record = $Acquisition; inventory_record = $Inventory
        opened = "Documents.Open(path, OpenVisible = false) in the owned instance, as Export-PartAssets.ps1 opens the root"
        session = $(if ($session) { [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; started_at = $session.StartedAt.ToString("o"); pre_existing_inventor_pids = $session.PreExistingPids
                shutdown = $(if ($shutdown) { [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; observed = $shutdown.Observed; failed_required = @($shutdown.FailedRequired); notes = @($shutdown.Notes) } } else { $null }) } } else { $null })
        project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; created_file = $project.CreatedFile; entry_removed_by_run = $(if ($shutdown) { $shutdown.ProjectEntryRemoved } else { $null }); previous_restored = $(if ($shutdown) { $shutdown.PreviousProjectRestored } else { $null }) } } else { $null })
        input_binding = [ordered]@{ mode = "strict acquisition binding"; opened_documents = @($inputs).Count; verified = @($inputs | Where-Object verified).Count; assemblies = @($inputs | Where-Object { $_.kind -eq "assembly" }).Count; parts = @($inputs | Where-Object { $_.kind -eq "part" }).Count
            changed_on_disk_after_run = $inputsChanged; inputs = $inputs }
        root = $rootRecord; view_census = $viewCensus; translator = $translatorInfo; export = $export; text_of_the_file = $text
        occurrence_counts = $counts; occurrences = @($script:census)
        mirror = $(if ($mirror) { [ordered]@{ files_before = $mirror.files_before; files_after = $mirror.files_after; changed = @($mirror.changed); added = @($mirror.added); removed = @($mirror.removed); unchanged = $mirror.unchanged; before = $treeBefore } } else { $null })
        dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; log = "dialogs.log"; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors) } } else { $null }) }
    ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "assembly-step-probe.json") -Encoding UTF8
} catch {
    $problem = $_.Exception.Message; $status = "FAILED"
    try { ConvertTo-Json -InputObject ([ordered]@{ schema_version = 2; generated_at = (Utc); probe = "windows/Invoke-AssemblyStepProbe.ps1"; status = "FAILED"; errors = @($errors) + @("the receipt could not be written in full: $problem") }) -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory "assembly-step-probe.json") -Encoding UTF8 } catch { }
    Write-Output "ERROR: the receipt could not be written in full: $problem"
}
try { Log "Probe status: $status" } catch { }
if ($status -notlike "complete*") { exit 1 }
