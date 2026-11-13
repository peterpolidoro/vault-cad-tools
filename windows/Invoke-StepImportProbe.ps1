<#
.SYNOPSIS
Reads one STEP file into an owned, invisible Inventor instance and records what Inventor makes of it: for a file
that Inventor did not write (a whole assembly built with FreeCAD, for example).

.DESCRIPTION
Read-only towards everything but -WorkDirectory. No Vault access. No production document is opened.

The file is read the way Inspect-StepInInventor.ps1 reads one: with the STEP translator's Open and nothing
written, so the documents exist in memory only, and every document is closed without saving. Which options
decide that depends on the version: of SaveToDisk, EnableSaveComponentDuringLoad and SaveComponentDuringLoad the
script sets to False whichever the translator reports for the file, and records them. Unlike that script this
one runs in an instance it has proven to own (Inventor-Session.ps1), under the dialog watchdog, with a temporary
project whose file lies in -WorkDirectory, and it records the tree.

Recorded in step-import-probe.json:
  - the file: size, SHA-256 (compared with -ExpectedSha256 before Inventor starts), header, schema, length unit and
    entity counts as its text gives them (Step-Header.ps1, Step-Units.ps1);
  - the translator's options for the file as reported, as used and after the read; the duration; every dialog;
  - the document: type, name, length unit, range box (cm), the assembly's own volume where Inventor gives it;
  - the tree: every occurrence with its path of names, kind, the name of its document, its placement in the root
    (cm), and for a part its bodies and solid bodies;
  - every part document once: bodies, solid bodies, how many occurrences place it, and its volume (cm3) at the
    default accuracy and at k_VeryHigh; the sums over all part occurrences.
What the counts rest on (kind, suppression, the collections) is read as guard queries of Package-Format.ps1; a
value that is only described is null when Inventor does not give it.

With -Convert the file is read a second time with those options set to True and the destination folders set to
<WorkDirectory>\native, so that Inventor writes native documents, and the files that appeared under
-WorkDirectory are listed. Put the STEP file itself into -WorkDirectory for that: Inventor may save beside the
source. The documents are a disposable copy.

Inventor is started inside the try whose finally stops it, and nothing after that runs outside a try: a receipt
is always written. Outputs in -OutputDirectory: step-import-probe.json, probe.log, dialogs.log.
Exit code 1 unless the status is complete.
#>
param(
    [Parameter(Mandatory = $true)][string]$Step,
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidatePattern('^([0-9a-f]{64})?$')][string]$ExpectedSha256 = "",
    [hashtable]$OpenOption = @{},
    [switch]$Convert,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-step-import",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")
. (Join-Path $PSScriptRoot "Package-Format.ps1")   # guard queries; also Step-Header.ps1 and Step-Units.ps1
. (Join-Path $PSScriptRoot "Import-InventorInterop.ps1")   # TranslatorAddIn.Open has an out parameter

function Sha($file) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() }
function Utc { [DateTime]::UtcNow.ToString("o") }
# ---- pre-flight (no Inventor yet) ----
if (-not (Test-Path -LiteralPath $Step -PathType Leaf)) { throw "STEP file not found: $Step" }
$source = (Resolve-Path -LiteralPath $Step).Path
if (-not (Test-Path -LiteralPath $WorkDirectory -PathType Container)) { New-Item -ItemType Directory -Path $WorkDirectory | Out-Null }
$WorkDirectory = (Resolve-Path -LiteralPath $WorkDirectory).Path.TrimEnd('\')
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
if ($OutputDirectory.ToLowerInvariant().StartsWith($WorkDirectory.ToLowerInvariant() + '\') -or $OutputDirectory -ieq $WorkDirectory) { throw "The output directory must not lie in the work directory" }
$sourceInWork = $source.ToLowerInvariant().StartsWith($WorkDirectory.ToLowerInvariant() + '\')
if ($Convert -and -not $sourceInWork) { throw "With -Convert the STEP file has to lie in the work directory: Inventor may save beside the source" }
$foreign = @(Get-ChildItem -LiteralPath $WorkDirectory -Force | Where-Object { $_.FullName -ine $source })
if ($foreign.Count -gt 0) { throw "Refusing a work directory that holds more than the STEP file: $WorkDirectory" }
$log = Join-Path $OutputDirectory "probe.log"
function Log($line) { Add-Content -LiteralPath $log -Value "$(Utc) $line"; Write-Output $line }
$sourceSha = Sha $source; $sourceBytes = (Get-Item -LiteralPath $source).Length; $nativeDirectory = Join-Path $WorkDirectory "native"
if ($ExpectedSha256 -and $sourceSha -cne $ExpectedSha256) { throw "The STEP file has SHA-256 $sourceSha, expected $ExpectedSha256" }

$kPart = 12290; $kAssembly = 12291; $kFileBrowseIOMechanism = 13059; $stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
$countedEntities = @("MANIFOLD_SOLID_BREP", "BREP_WITH_VOIDS", "NEXT_ASSEMBLY_USAGE_OCCURRENCE", "PRODUCT", "PRODUCT_DEFINITION", "PRODUCT_DEFINITION_SHAPE", "SHAPE_REPRESENTATION",
    "ADVANCED_BREP_SHAPE_REPRESENTATION", "SHAPE_REPRESENTATION_RELATIONSHIP", "CONTEXT_DEPENDENT_SHAPE_REPRESENTATION", "ITEM_DEFINED_TRANSFORMATION", "MAPPED_ITEM", "STYLED_ITEM", "INVISIBILITY")
function Get-MapName($map, $i) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($i)) }
function Get-MapValue($map, $k) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($k)) }
function Set-MapValue($map, [string]$k, $v) {
    # A value that came through the pipeline is wrapped in a PSObject, and COM answers a wrapped value with "Type
    # mismatch": the name is taken as a plain string and the value is unwrapped.
    if ($null -ne $v) { $v = $v.PSObject.BaseObject }
    [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, [object[]]@($k, $v))
}
function Read-Map($map) {
    # Name and value of every entry; a value that is not a scalar (another map, an object) is named by its type.
    $entries = [ordered]@{}
    for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $value = Get-MapValue $map $n; $entries[$n] = $(if (Test-PackageScalar $value) { $value } else { "<$($value.GetType().Name)>" }) }
    return $entries
}
function Cells($m) {
    # The 16 cells of an Inventor matrix. A matrix that is missing, or a cell that is not a number, is refused: [double]$null is 0.
    if ($null -eq $m) { throw "A placement matrix is missing" }
    $rows = @()
    for ($r = 1; $r -le 4; $r++) { $row = @(); for ($c = 1; $c -le 4; $c++) { $cell = $m.GetType().InvokeMember("Cell", [Reflection.BindingFlags]::GetProperty, $null, $m, @($r, $c)); if (-not (Test-PackageNumber $cell)) { throw "Cell $r,$c of a placement matrix is not a number" }; $row += [double]$cell }; $rows += ,$row }
    return ,$rows
}
function Get-Box($box, [string]$what) {
    # Both corners of a range box in cm, as six required numbers.
    Assert-RequiredObject "range box of $what" $box
    $low = $box.MinPoint; $high = $box.MaxPoint
    Assert-RequiredObject "range box corners of $what" $low; Assert-RequiredObject "range box corners of $what" $high
    $lowCells = @((Get-RequiredValue "range box of $what" { $low.X } -Kind number), (Get-RequiredValue "range box of $what" { $low.Y } -Kind number), (Get-RequiredValue "range box of $what" { $low.Z } -Kind number))
    $highCells = @((Get-RequiredValue "range box of $what" { $high.X } -Kind number), (Get-RequiredValue "range box of $what" { $high.Y } -Kind number), (Get-RequiredValue "range box of $what" { $high.Z } -Kind number))
    return [ordered]@{ min = @($lowCells | ForEach-Object { [double]$_ }); max = @($highCells | ForEach-Object { [double]$_ }) }
}
$script:nodes = @(); $script:partDocuments = [ordered]@{}
function Add-Nodes($occurrences, [string[]]$parentPath, [int]$depth) {
    # Called as a statement only: it files what it finds in $script:nodes and $script:partDocuments and returns
    # nothing. A collection must exist and must give as many items as it counts.
    $whose = $(if ($parentPath.Count) { "'$($parentPath -join '/')'" } else { "the root" })
    $expected = Get-RequiredCount "occurrences of $whose" $occurrences
    $seen = 0
    foreach ($o in $occurrences) {
        $seen++
        $name = Get-RequiredValue "name of an occurrence of $whose" { $o.Name } -Kind string
        $path = @($parentPath) + @($name); $id = $path -join "/"
        $typeCode = Get-RequiredValue "DefinitionDocumentType of '$id'" { $o.DefinitionDocumentType } -Kind int
        $kind = $(if ($typeCode -eq $kAssembly) { "assembly" } elseif ($typeCode -eq $kPart) { "part" } else { "other:$typeCode" })
        $suppressed = Get-RequiredValue "Suppressed of '$id'" { $o.Suppressed }
        $record = [ordered]@{ path = $path; depth = $depth; kind = $kind; suppressed = $suppressed }
        if ($suppressed) { $script:nodes += $record; continue }
        $definition = $o.Definition; Assert-RequiredObject "definition of '$id'" $definition
        $document = $definition.Document; Assert-RequiredObject "document of '$id'" $document
        $documentName = Get-RequiredValue "display name of the document of '$id'" { $document.DisplayName } -Kind string
        $record.document = $documentName
        $record.document_file = Get-OptionalValue { $document.FullFileName } "string"
        $record.visible = Get-OptionalValue { $o.Visible } "bool"
        $record.grounded = Get-OptionalValue { $o.Grounded } "bool"
        $record.transform_root_cm = Cells $o.Transformation
        if ($kind -eq "assembly") {
            $children = $o.SubOccurrences
            $record.children = Get-RequiredCount "occurrences of '$id'" $children
            $script:nodes += $record
            Add-Nodes $children $path ($depth + 1)
        } elseif ($kind -eq "part") {
            $bodies = $definition.SurfaceBodies
            $record.bodies = Get-RequiredCount "bodies of '$id'" $bodies
            if (-not $script:partDocuments.Contains($documentName)) {
                $solids = 0; $given = 0; $unitCode = Get-OptionalValue { $document.UnitsOfMeasure.LengthUnits } "int"
                foreach ($body in $bodies) { $given++; if (Get-RequiredValue "IsSolid of a body of '$id'" { $body.IsSolid }) { $solids++ } }
                if ($given -ne $record.bodies) { throw "The bodies of '$id' count $($record.bodies) and gave $given" }
                $script:partDocuments[$documentName] = [ordered]@{ document = $documentName; bodies = $record.bodies; solid_bodies = $solids; occurrences = 0; first_occurrence = $id
                    length_unit = $(if ($null -ne $unitCode) { $lengthUnitNames[$unitCode] } else { $null }); definition = $definition }
            }
            $script:partDocuments[$documentName].occurrences++
            $record.solid_bodies = $script:partDocuments[$documentName].solid_bodies
            $script:nodes += $record
        } else { $script:nodes += $record }
    }
    if ($seen -ne $expected) { throw "The occurrences of $whose count $expected and gave $seen" }
}
function Read-Import($translator, $to, $app, [bool]$save) {
    # One read of the file. Returns one object: the document (or $null), the options and the duration; the caller
    # logs. Nothing is written to the pipeline here.
    $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
    $opts = $to.CreateNameValueMap()
    $medium = $to.CreateDataMedium(); $medium.FileName = $source
    $hasOptions = Get-RequiredValue "HasOpenOptions of the STEP translator" { $translator.HasOpenOptions($medium, $ctx, $opts) }
    $reported = Read-Map $opts
    # The options that decide whether Inventor writes documents while it reads: whichever of them it reports.
    $saveOptions = @(@("SaveToDisk", "EnableSaveComponentDuringLoad", "SaveComponentDuringLoad") | Where-Object { $reported.Contains($_) })
    $failure = $null
    try {
        foreach ($optionName in $saveOptions) { Set-MapValue $opts $optionName $save }
        if ($save) {
            if ($saveOptions.Count -eq 0) { $failure = "the translator reports none of the options that make it write documents" }
            if ($reported.Contains("SaveLocationIndex")) { Set-MapValue $opts "SaveLocationIndex" 2 }
            foreach ($optionName in @("ComponentDestFolder", "AssemDestFolder")) { if ($reported.Contains($optionName)) { Set-MapValue $opts $optionName ($nativeDirectory + '\') } }
        }
        foreach ($optionName in @($OpenOption.Keys)) {
            if ($reported.Contains([string]$optionName)) { Set-MapValue $opts $optionName $OpenOption[$optionName] } else { $failure = "the translator reports no option '$optionName' for this file" }
        }
    } catch { $failure = "an option of the translator could not be set: $($_.Exception.Message)" }
    $used = Read-Map $opts
    $openDocuments = $app.Documents
    $documentsBefore = Get-RequiredCount "open documents" $openDocuments
    $started = Utc; $clock = [Diagnostics.Stopwatch]::StartNew(); $document = $null
    if (-not $failure) { try { $document = [VaultCad.InventorInterop]::TranslatorOpen($translator, $medium, $ctx, $opts) } catch { $failure = $_.Exception.Message; if ($_.Exception.InnerException) { $failure = "$failure | $($_.Exception.InnerException.Message)" } } }
    $clock.Stop()
    return [pscustomobject]@{ Document = $document; Failure = $failure; HasOptions = $hasOptions; Reported = $reported; SaveOptions = $saveOptions; Used = $used; After = (Read-Map $opts)
        Started = $started; Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); DocumentsBefore = $documentsBefore }
}

# ---- the file's text, before Inventor ----
$text = [ordered]@{ errors = @() }
try {
    $info = Get-StepFileInfo -Path $source
    $text.data_sha256 = $info.data_sha256; $text.file_schema = $info.file_schema_statement; $text.protocol = $info.header.protocol; $text.schemas = @($info.header.schemas); $text.header = $info.header
} catch { $text.errors += "header: $($_.Exception.Message)" }
try {
    $unit = Get-StepLengthUnit $source
    $text.length_unit = $unit.unit; $text.length_unit_ok = $unit.ok; $text.length_unit_reason = $unit.reason
    $text.length_units_of_contexts = @(@($unit.contexts) | ForEach-Object { $_.unit } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" })
} catch { $text.errors += "length unit: $($_.Exception.Message)" }
try { $text.entity_counts = Get-StepEntityCounts -Path $source -Type $countedEntities } catch { $text.errors += "entity counts: $($_.Exception.Message)" }

$session = $null; $app = $null; $project = $null; $errors = @(); $warnings = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null; $status = "FAILED"
$translatorInfo = $null; $import = $null; $rootRecord = $null; $counts = $null; $partRecords = @(); $conversion = $null; $timings = [ordered]@{}
try {
    $session = Start-IsolatedInventor
    $app = $session.App
    Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build)); started $($session.StartedAt.ToString('o')); application visible: $(Get-RequiredValue 'Visible of the application' { $app.Visible })"
    $watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $OutputDirectory "dialogs.log")
    $project = Use-TemporaryProject $app (Join-Path $WorkDirectory "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); created file: $($project.CreatedFile))"
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); Assert-RequiredObject "the STEP translator add-in" $translator
    if (-not (Get-RequiredValue "Activated of the STEP translator" { $translator.Activated })) { $translator.Activate() }
    $translatorInfo = [ordered]@{ display_name = (Get-OptionalValue { $translator.DisplayName } "string"); client_id = $stepTranslatorClsid; activated = (Get-OptionalValue { $translator.Activated } "bool") }
    $to = $app.TransientObjects
    $accuracyHigh = [int][Inventor.MassPropertiesAccuracyEnum]::k_VeryHigh

    # ---- the read in memory ----
    Log "Reading $source ($sourceBytes bytes) with the translator's Open, nothing written"
    $read = Read-Import $translator $to $app $false
    $import = [ordered]@{ route = "TranslatorAddIn.Open; set to False: $(if ($read.SaveOptions.Count) { $read.SaveOptions -join ', ' } else { 'nothing (the translator reports no such option)' })"
        has_open_options = $read.HasOptions; options_reported = $read.Reported; options_used = $read.Used; options_after = $read.After
        started = $read.Started; seconds = $read.Seconds; failure = $read.Failure; returned_a_document = ($null -ne $read.Document) }
    $timings.read_seconds = $read.Seconds
    Log "Translator Open returned after $($read.Seconds) s: $(if ($read.Failure) { "FAILED: $($read.Failure)" } elseif ($read.Document) { 'a document' } else { 'no document' })"
    try {
        if ($read.Failure) { throw "The translator could not read the file: $($read.Failure)" }
        $doc = $read.Document
        if ($null -eq $doc) { throw "The translator returned no document" }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $openDocuments = $app.Documents
        $import.documents_in_memory = (Get-RequiredCount "open documents" $openDocuments) - $read.DocumentsBefore
        $typeCode = Get-RequiredValue "document type" { $doc.DocumentType } -Kind int
        $definition = $doc.ComponentDefinition; Assert-RequiredObject "component definition of the document" $definition
        $rootRecord = [ordered]@{ document_type = $typeCode; kind = $(if ($typeCode -eq $kAssembly) { "assembly" } elseif ($typeCode -eq $kPart) { "part" } else { "other:$typeCode" })
            display_name = (Get-OptionalValue { $doc.DisplayName } "string"); full_file_name = (Get-OptionalValue { $doc.FullFileName } "string")
            length_units = $lengthUnitNames[(Get-RequiredValue "length unit of the document" { $doc.UnitsOfMeasure.LengthUnits } -Kind int)]
            dirty = (Get-OptionalValue { $doc.Dirty } "bool"); range_box_cm = (Get-Box $definition.RangeBox "the document") }
        if ($rootRecord.kind -eq "assembly") {
            $top = $definition.Occurrences
            $rootRecord.top_level_occurrences = Get-RequiredCount "occurrences of the root" $top
            Add-Nodes $top @() 1
            $rootRecord.volume_cm3_default_accuracy = Get-OptionalValue { $definition.MassProperties.Volume } "double"
        } elseif ($rootRecord.kind -eq "part") {
            $bodies = $definition.SurfaceBodies
            $rootRecord.bodies = Get-RequiredCount "bodies of the document" $bodies
            $rootRecord.volume_cm3_default_accuracy = Get-OptionalValue { $definition.MassProperties.Volume } "double"
        }
        $timings.tree_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        # every part document once: its volume at the default accuracy and at k_VeryHigh
        foreach ($entry in $script:partDocuments.Values) {
            $properties = $entry.definition.MassProperties
            $entry.volume_cm3_default_accuracy = Get-OptionalValue { $properties.Volume } "double"
            $entry.volume_cm3_very_high = $null
            if ($null -ne $properties) { try { $properties.Accuracy = $accuracyHigh; $entry.volume_cm3_very_high = Get-OptionalValue { $properties.Volume } "double" } catch { $warnings += "volume of '$($entry.document)' at k_VeryHigh: $($_.Exception.Message)" } }
            $entry.Remove("definition")
            $partRecords += $entry
        }
        $timings.volumes_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        $partNodes = @($script:nodes | Where-Object { $_.kind -eq "part" -and -not $_.suppressed }); $assemblyNodes = @($script:nodes | Where-Object { $_.kind -eq "assembly" -and -not $_.suppressed })
        $unreadDefault = @($partRecords | Where-Object { $null -eq $_.volume_cm3_default_accuracy }).Count; $unreadHigh = @($partRecords | Where-Object { $null -eq $_.volume_cm3_very_high }).Count
        $sumDefault = 0.0; $sumHigh = 0.0
        foreach ($entry in $partRecords) { if ($null -ne $entry.volume_cm3_default_accuracy) { $sumDefault += $entry.volume_cm3_default_accuracy * $entry.occurrences }; if ($null -ne $entry.volume_cm3_very_high) { $sumHigh += $entry.volume_cm3_very_high * $entry.occurrences } }
        $counts = [ordered]@{ occurrences = @($script:nodes).Count; part_occurrences = $partNodes.Count; sub_assembly_occurrences = $assemblyNodes.Count
            suppressed = @($script:nodes | Where-Object { $_.suppressed }).Count; other = @($script:nodes | Where-Object { $_.kind -like "other:*" }).Count
            invisible = @($script:nodes | Where-Object { -not $_.suppressed -and $_.visible -eq $false }).Count; greatest_depth = $(if ($script:nodes.Count) { ($script:nodes | ForEach-Object { $_.depth } | Measure-Object -Maximum).Maximum } else { 0 })
            part_documents = $partRecords.Count; bodies_over_all_part_occurrences = ($partNodes | ForEach-Object { $_.bodies } | Measure-Object -Sum).Sum
            solid_bodies_over_all_part_occurrences = ($partNodes | ForEach-Object { $_.solid_bodies } | Measure-Object -Sum).Sum
            volume_cm3_over_all_part_occurrences_default_accuracy = $sumDefault; part_documents_without_a_volume_at_default_accuracy = $unreadDefault
            volume_cm3_over_all_part_occurrences_very_high = $sumHigh; part_documents_without_a_volume_at_very_high = $unreadHigh }
        Log "Document: $($rootRecord.kind), unit $($rootRecord.length_units); occurrences $($counts.part_occurrences) part, $($counts.sub_assembly_occurrences) sub-assembly; $($counts.part_documents) part documents; solid bodies $($counts.solid_bodies_over_all_part_occurrences)"
        Log "Volume over all part occurrences: $([Math]::Round($sumHigh * 1000.0, 0)) mm3 at k_VeryHigh ($unreadHigh not read), $([Math]::Round($sumDefault * 1000.0, 0)) mm3 at the default accuracy ($unreadDefault not read)"
    } finally {
        # every document the read created is closed, never saved
        try { while ($app.Documents.Count -gt $read.DocumentsBefore) { $app.Documents.Item($app.Documents.Count).Close($true) } } catch { $errors += "closing the documents of the read: $($_.Exception.Message)" }
    }

    # ---- the conversion into native documents, only when asked for ----
    if ($Convert) {
        $filesBefore = @(Get-ChildItem -LiteralPath $WorkDirectory -Recurse -File -Force | ForEach-Object { $_.FullName })
        if (-not (Test-Path -LiteralPath $nativeDirectory)) { New-Item -ItemType Directory -Path $nativeDirectory | Out-Null }
        Log "Reading the file again so that Inventor writes native documents under $nativeDirectory"
        $second = Read-Import $translator $to $app $true
        $conversion = [ordered]@{ route = "TranslatorAddIn.Open; set to True: $($second.SaveOptions -join ', '); destination folders: $nativeDirectory"; options_used = $second.Used; options_after = $second.After; started = $second.Started; seconds = $second.Seconds
            failure = $second.Failure; returned_a_document = ($null -ne $second.Document) }
        $timings.convert_seconds = $second.Seconds
        try {
            if ($second.Failure) { throw "The translator could not convert the file: $($second.Failure)" }
            if ($null -ne $second.Document) {
                $conversion.root_full_file_name = Get-OptionalValue { $second.Document.FullFileName } "string"
                $conversion.root_dirty_after_the_read = Get-OptionalValue { $second.Document.Dirty } "bool"
            }
        } finally {
            try { while ($app.Documents.Count -gt $second.DocumentsBefore) { $app.Documents.Item($app.Documents.Count).Close($true) } } catch { $errors += "closing the documents of the conversion: $($_.Exception.Message)" }
        }
        $created = @(Get-ChildItem -LiteralPath $WorkDirectory -Recurse -File -Force | Where-Object { $filesBefore -notcontains $_.FullName })
        $conversion.files_written = $created.Count; $conversion.bytes_written = ($created | Measure-Object -Property Length -Sum).Sum
        $conversion.by_extension = [ordered]@{}; foreach ($group in ($created | Group-Object { $_.Extension.ToLowerInvariant() } | Sort-Object Name)) { $conversion.by_extension[$group.Name] = [ordered]@{ files = $group.Count; bytes = ($group.Group | Measure-Object -Property Length -Sum).Sum } }
        $conversion.files = @($created | Sort-Object FullName | ForEach-Object { [ordered]@{ name = $_.FullName.Substring($WorkDirectory.Length + 1); bytes = $_.Length } })
        Log "Conversion: $($second.Seconds) s; $($created.Count) file(s) written, $($conversion.bytes_written) bytes: $(($conversion.by_extension.Keys | ForEach-Object { "$_ $($conversion.by_extension[$_].files)" }) -join ', ')"
    }
    if ($errors.Count -eq 0) { $status = "complete" }
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
# ---- after Inventor. Nothing from here on runs outside a try: whatever fails must still leave a receipt.
try {
    if ($errors.Count -gt 0) { $status = "FAILED" }
    $status = Resolve-RunStatus -Status $status -Dialogs $dialogs
    if ((Sha $source) -cne $sourceSha) { $errors += "the STEP file changed during the run"; $status = "FAILED" }
} catch { $errors += "after Inventor was closed: $($_.Exception.Message)"; $status = "FAILED" }
try {
    $receipt = [ordered]@{ schema_version = 1; generated_at = (Utc); probe = "windows/Invoke-StepImportProbe.ps1"; status = $status; errors = $errors; warnings = $warnings
        scope = "one STEP file read into an owned Inventor instance with the translator's Open; documents in memory only and closed without saving$(if ($Convert) { '; then read again so that Inventor writes native documents into the work directory' })"
        host = $env:COMPUTERNAME; inventor = $(if ($session) { "$($session.Version) build $($session.Build)" } else { $null })
        step = [ordered]@{ file = $source; bytes = $sourceBytes; sha256 = $sourceSha; expected_sha256 = $(if ($ExpectedSha256) { $ExpectedSha256 } else { $null }); in_the_work_directory = $sourceInWork; text = $text }
        work_directory = $WorkDirectory
        session = $(if ($session) { [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; started_at = $session.StartedAt.ToString("o"); pre_existing_inventor_pids = $session.PreExistingPids
                shutdown = $(if ($shutdown) { [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; observed = $shutdown.Observed; failed_required = @($shutdown.FailedRequired); notes = @($shutdown.Notes) } } else { $null }) } } else { $null })
        project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; created_file = $project.CreatedFile } } else { $null })
        translator = $translatorInfo; import = $import; document = $rootRecord; counts = $counts; part_documents = $partRecords; occurrences = @($script:nodes); conversion = $conversion; timings = $timings
        dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; log = "dialogs.log"; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors) } } else { $null }) }
    ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "step-import-probe.json") -Encoding UTF8
} catch {
    $problem = $_.Exception.Message; $status = "FAILED"
    try { ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; generated_at = (Utc); probe = "windows/Invoke-StepImportProbe.ps1"; status = "FAILED"; errors = @($errors) + @("the receipt could not be written in full: $problem") }) -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory "step-import-probe.json") -Encoding UTF8 } catch { }
    try { Write-Output "ERROR: the receipt could not be written in full: $problem" } catch { }
}
try { Log "Probe status: $status" } catch { }
if ($status -cne "complete") { exit 1 }
