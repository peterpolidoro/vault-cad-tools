<#
.SYNOPSIS
Export one root assembly as the exporter's package (draft: mechanical-cad/docs/exporter-package.md): one
directory per Vault file and model state, with source.json and part.step or assembly.json, the occurrences in
the context of the root, and package.json. Read-only: nothing is saved and Vault is not contacted.

.DESCRIPTION
    & .\windows\Export-Package.ps1 -NativeAssembly ROOT.iam -WorkspaceRoot MIRROR `
        -Acquisition acquisition.json -Inventory dependency-inventory.json `
        -OutputDirectory PACKAGE -WorkDirectory WORK

THIS IS THE EXPORTER: a root assembly is exported for a project with this script (AP242, normalised headers,
one directory per Vault file), and "import-snapshot" reads its package into the project. Export-PartAssets.ps1
writes the earlier format; it is kept for now, is not run for new work and gets no further corrections.
Both directories must not exist or must be empty, and neither may lie inside the other.

  PACKAGE/package.json                    what was exported and the hash of every other file; written last, and
                                          only when everything below passed
  PACKAGE/occurrences.json                every occurrence in the context of the root: path, placement in its
                                          parent and in the root, whether it differs from its definition, flags
  PACKAGE/files/<master id>_<state>/      source.json for every file; part.step (AP242, header normalised) for a
                                          part; assembly.json (the children as the document defines them) for
                                          an assembly; the root's also states the frame (right-handed, +Y up)
  WORK/translator-output/                 the STEP files as the translator wrote them (their headers name the
                                          native file's author); never part of the package
  WORK/export-package-receipt.json        status, session, inputs, timings, checks; with host name and paths
  WORK/export.log, WORK/dialogs.log

Every file of the package except package.json is the same bytes when the same Vault versions are exported
again: no file but package.json carries a time, and none carries a workstation path, a host name, an account
name or a property that names a person (checked before package.json is written).

The split between this exporter and the import command: an assembly document is written once, from its own
component definition; the placements a flexible instance gives its descendants are NOT written as overrides.
occurrences.json holds every occurrence as Inventor places it in the root's context and says which differ from
their definition; the import command derives the overrides from it.

Supported subset and refusals as Export-PartAssets.ps1 (primary model states, master level of detail and
positional representation, rigid placements, no factories, adaptive or substitute occurrences; every guard
query fails closed), strict binding of every opened document to the acquisition record, and in addition:
  - a document that has a view (the STEP translator would write that view's camera);
  - a part.step that marks items invisible in a form that is not understood (Get-StepInvisibility);
  - a part whose translator file does not name the AP242 schema alone in FILE_SCHEMA in three attempts (the
    translator sometimes puts a second, unrelated name in front; such a file is never repaired or delivered,
    the part is exported again and every attempt is recorded);
  - a suppressed occurrence (its document is not loaded; not implemented for want of real data);
  - an occurrence whose placement differs from its definition without an enclosing flexible occurrence;
  - an instance whose children are not those of its document; two files that would share a directory;
  - a BOM structure the layout does not know; a text of the workstation in any file of the package;
  - a translator that does not report "Successful"; a file of the mirror that changed, appeared or disappeared
    during the run (every file of the mirror is hashed before Inventor starts and after it has exited).
Vault facts come from the two records of the acquisition; the exporter makes no Vault request.

A guard query returns what the API returned and holds no cast (Get-RequiredValue in Package-Format.ps1); a
collection must exist before it is counted or walked; what the API does not give is written as null.
Inventor is started inside the try whose finally stops it, and nothing after that runs outside a try: a receipt
is always written, with the number of times each guard was evaluated, and whatever fails after package.json was
written removes it. Only a run that ends "complete" leaves package.json: a run in which the watchdog dismissed a
dialog ends "complete_with_dialogs" and its package is withheld. That is decided before package.json is written,
so such a run writes none. What the receipt says about package.json is asked of the file system after the last
attempt to remove it; a package.json that could not be removed fails the run. A value Inventor returns as nothing
is null; a read of a document's length unit, or of its dirty flag after the export, that fails stops the run.
The receipt is schema_version 3 ($PackageReceiptSchemaVersion). Exit code 1 unless a complete package was left.
#>
param(
    [Parameter(Mandatory = $true)][string]$NativeAssembly,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$Acquisition,
    [Parameter(Mandatory = $true)][string]$Inventory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [string[]]$ForbiddenTerm = @(),
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")
. (Join-Path $PSScriptRoot "Package-Format.ps1")   # also Step-Header.ps1 and Step-Units.ps1

function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha($file) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() }
# ---- pre-flight (no Inventor yet) ----
foreach ($required in @($NativeAssembly, $WorkspaceRoot, $Acquisition, $Inventory)) { if (-not (Test-Path -LiteralPath $required)) { throw "Not found: $required" } }
$NativeAssembly = (Resolve-Path -LiteralPath $NativeAssembly).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\')
$acqJson = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
$invJson = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json
if (-not $acqJson.files -or -not $invJson.files) { throw "Acquisition/inventory records have no files" }
$vaultId = [string]$invJson.vault_id
if (-not $vaultId) { throw "The dependency inventory does not name the vault" }
foreach ($target in @($OutputDirectory, $WorkDirectory)) {
    if (Test-Path -LiteralPath $target) { if (@(Get-ChildItem -LiteralPath $target -Force).Count -gt 0) { throw "Refusing non-empty directory: $target" } } else { New-Item -ItemType Directory -Path $target | Out-Null }
}
$OutputDirectory = (Get-Item -LiteralPath $OutputDirectory).FullName.TrimEnd('\'); $WorkDirectory = (Get-Item -LiteralPath $WorkDirectory).FullName.TrimEnd('\')
if (($OutputDirectory + '\').StartsWith($WorkDirectory + '\', [StringComparison]::OrdinalIgnoreCase) -or ($WorkDirectory + '\').StartsWith($OutputDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "The package and the work directory must not contain each other" }
$filesDirectory = Join-Path $OutputDirectory "files"; New-Item -ItemType Directory -Path $filesDirectory | Out-Null
$rawDirectory = Join-Path $WorkDirectory "translator-output"; New-Item -ItemType Directory -Path $rawDirectory | Out-Null
$log = Join-Path $WorkDirectory "export.log"
function Log($line) { Add-Content -LiteralPath $log -Value "$(Utc) $line"; Write-Output $line }
$interopCandidates = @("$env:ProgramFiles\Autodesk\Inventor 2025\Bin\Public Assemblies\Autodesk.Inventor.Interop.dll", "$env:ProgramFiles\Autodesk\Inventor 2025\Bin\Autodesk.Inventor.Interop.dll")
$interopPath = $interopCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $interopPath) { throw "Autodesk.Inventor.Interop.dll not found in: $($interopCandidates -join '; ')" }
$interop = [Reflection.Assembly]::LoadFrom($interopPath)
$objectTypeEnum = $interop.GetType("Inventor.ObjectTypeEnum")
$acqByPath = @{}; foreach ($record in $acqJson.files) { $acqByPath[([string]$record.local_path).ToLowerInvariant()] = $record }
$invByVersion = @{}; foreach ($record in $invJson.files) { $invByVersion[[string]$record.version_id] = $record }

$kPart = 12290; $kAssembly = 12291; $kFileBrowseIOMechanism = 13059; $stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
$bomNames = @{ 51969 = "Default"; 51970 = "Normal"; 51971 = "Phantom"; 51972 = "Reference"; 51973 = "Purchased"; 51974 = "Inseparable"; 51975 = "Varies" }
$masterNames = @("Master", "[Primary]", "Primary")
$rotationTolerance = 1e-9; $lengthTolerance = 1e-7   # a rotation cell; a length in cm (1e-6 mm)
$maximumAttempts = 3                                 # exports of one part, until its FILE_SCHEMA names the AP242 schema alone
function Get-MapName($map, $i) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($i)) }
function Get-MapValue($map, $k) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($k)) }
function Set-MapValue($map, $k, $v) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($k, $v)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
function Cells($m) {
    # The 16 cells of an Inventor matrix. A matrix that is missing, or a cell that is not a number, is refused: [double]$null is 0.
    if ($null -eq $m) { throw "A placement matrix is missing; unknown configuration refused" }
    $rows = @()
    for ($r = 1; $r -le 4; $r++) { $row = @(); for ($c = 1; $c -le 4; $c++) { $cell = $m.GetType().InvokeMember("Cell", [Reflection.BindingFlags]::GetProperty, $null, $m, @($r, $c)); if (-not (Test-PackageNumber $cell)) { throw "Cell $r,$c of a placement matrix is not a number; unknown configuration refused" }; $row += [double]$cell }; $rows += ,$row }
    return ,$rows
}
function Mul($A, $B) { $R = @(); for ($i = 0; $i -lt 4; $i++) { $row = @(); for ($j = 0; $j -lt 4; $j++) { $s = 0.0; for ($k = 0; $k -lt 4; $k++) { $s += $A[$i][$k] * $B[$k][$j] }; $row += $s }; $R += ,$row }; return ,$R }
function InvRigid($M) {
    $R = @(); for ($i = 0; $i -lt 3; $i++) { $row = @(); for ($j = 0; $j -lt 3; $j++) { $row += [double]$M[$j][$i] }; $row += 0.0; $R += ,$row }
    $t = @($M[0][3], $M[1][3], $M[2][3])
    for ($i = 0; $i -lt 3; $i++) { $R[$i][3] = -($R[$i][0] * $t[0] + $R[$i][1] * $t[1] + $R[$i][2] * $t[2]) }
    $R += ,@(0.0, 0.0, 0.0, 1.0); return ,$R
}
function Deviation($A, $B) { return (Get-PackageFlatDeviation (Get-PackageFlat $A) (Get-PackageFlat $B)) }
$Identity = @(@(1.0, 0.0, 0.0, 0.0), @(0.0, 1.0, 0.0, 0.0), @(0.0, 0.0, 1.0, 0.0), @(0.0, 0.0, 0.0, 1.0))
function Relative($file) { if ($file.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant() + '\')) { return $file.Substring($WorkspaceRoot.Length + 1) }; return $file }
function Prop($doc, $set, $name) {
    # Descriptive metadata: optional. Only scalars reach the package.
    $value = $null; try { $value = $doc.PropertySets.Item($set).Item($name).Value } catch { return $null }
    if ($null -eq $value -or $value -is [string] -or $value -is [bool] -or (Test-PackageNumber $value)) { return $value }
    return [string]$value
}
# Guard queries fail CLOSED: Get-RequiredValue, Assert-RequiredObject and Get-RequiredCount (Package-Format.ps1) refuse
# an exception, nothing, a collection and another type than asked for. A query returns what the API returned and
# holds no cast: the cast of nothing is 0, False or "" and would pass the guard. $guards counts each guard where it
# is evaluated and has let the run pass; the receipt carries the counts.
function Get-BomName($value, $what) {
    # $value comes from a guard query of kind int. Called where its result is captured: it emits the name only.
    $name = $bomNames[$value]
    if ($PackageBomStructures -notcontains $name) { throw "Unsupported: BOM structure $value ($name) of $what" }
    Add-PackageGuardCheck $guards "bom_structure_known"
    return $name
}
function Assert-Rigid($matrix, $what) {
    $reason = Test-PackageRigid (Get-PackageFlat $matrix) $rotationTolerance
    if ($reason) { throw "Unsupported: the placement of $what is not a rotation and a translation: $reason" }
    Add-PackageGuardCheck $guards "rigid_placement"
}

# ---- parameters, holes and the features that repeat them (late-bound) ----
# What the API does not give is written as null, never as 0, False or an empty text: every optional value goes
# through Get-OptionalValue or Get-OptionalObject (Package-Format.ps1), whose queries hold no cast. A collection is
# assigned directly (one that leaves a script block is enumerated) and must exist before it is counted: a part whose
# parameters, features or hole features cannot be listed stops the export.
function Get-EnumName([string]$interface, [string]$property, $value) {
    if ($null -eq $value) { return $null }
    $type = $interop.GetType("Inventor.$interface"); $declared = $(if ($type) { $type.GetProperty($property) } else { $null })
    if ($declared -and $declared.PropertyType.IsEnum) { $name = [Enum]::GetName($declared.PropertyType, [int]$value); if ($name) { return $name } }
    return "$([int]$value)"
}
function Get-ObjectTypeName($object) { $value = Get-OptionalValue { $object.Type } "int"; if ($null -eq $value) { return $null }; $name = [Enum]::GetName($objectTypeEnum, $value); if ($name) { return $name }; return "ObjectTypeEnum $value" }
function Get-ParameterBrief($parameter) {
    if ($null -eq $parameter) { return $null }
    return [ordered]@{ parameter = (Get-OptionalValue { $parameter.Name } "string"); expression = (Get-OptionalValue { $parameter.Expression } "string"); value = (Get-OptionalValue { $parameter.Value } "double"); units = (Get-OptionalValue { $parameter.Units } "string") }
}
function Get-PointMm($point) {
    # X, Y, Z of a point in millimetres, or $null when the point or one of its coordinates is not known.
    if ($null -eq $point) { return $null }
    $x = Get-OptionalValue { $point.X } "double"; $y = Get-OptionalValue { $point.Y } "double"; $z = Get-OptionalValue { $point.Z } "double"
    if ($null -eq $x -or $null -eq $y -or $null -eq $z) { return $null }
    return @(($x * 10.0), ($y * 10.0), ($z * 10.0))
}
function Read-Parameters($definition, $units, $what) {
    # Every parameter of the part. The parameters must be listable (the caller stops otherwise); a single value may be null.
    $all = $definition.Parameters
    $count = Get-RequiredCount "parameters of $what" $all
    $kindOf = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($pair in @(@("model", "ModelParameters"), @("reference", "ReferenceParameters"), @("user", "UserParameters"))) {
        $collection = $all.GetType().InvokeMember($pair[1], [Reflection.BindingFlags]::GetProperty, $null, $all, $null)
        $members = Get-RequiredCount "$($pair[1]) of $what" $collection
        for ($i = 1; $i -le $members; $i++) { $kindOf[(Get-RequiredValue "name of a parameter of $what" { $collection.Item($i).Name } -Kind string)] = $pair[0] }
    }
    $list = @()
    for ($i = 1; $i -le $count; $i++) {
        $parameter = $all.Item($i); $name = Get-RequiredValue "name of parameter $i of $what" { $parameter.Name } -Kind string
        $raw = Get-OptionalObject { $parameter.Value }; $unitText = Get-OptionalValue { $parameter.Units } "string"
        $value = $(if ($null -eq $raw -or $raw -is [string] -or $raw -is [bool]) { $raw } else { [double]$raw })
        $text = $(if ($value -is [double]) { Get-OptionalValue { $units.GetStringFromValue($value, $unitText) } "string" } else { $null })
        $list += [ordered]@{ name = $name; kind = $(if ($kindOf.ContainsKey($name)) { $kindOf[$name] } else { "other" }); expression = (Get-OptionalValue { $parameter.Expression } "string"); units = $unitText
            value = $value; value_text = $text; comment = (Get-OptionalValue { $parameter.Comment } "string"); is_key = (Get-OptionalValue { $parameter.IsKey } "bool"); exposed_as_property = (Get-OptionalValue { $parameter.ExposedAsProperty } "bool") }
    }
    return ,$list
}
function Read-Features($definition, $what) {
    # The hole features and the pattern and mirror features of the part. The features and the hole features must be
    # listable; the parents and elements of one pattern and the centres of one hole may be unknown, and are then null.
    $features = $definition.Features
    $featureCount = Get-RequiredCount "features of $what" $features
    $patterns = @()
    for ($i = 1; $i -le $featureCount; $i++) {
        $feature = $features.Item($i)
        $typeCode = Get-RequiredValue "type of feature $i of $what" { $feature.Type } -Kind int
        $typeName = [Enum]::GetName($objectTypeEnum, $typeCode); if (-not $typeName) { $typeName = "ObjectTypeEnum $typeCode" }
        if ($typeName -notmatch 'Pattern|Mirror') { continue }
        $parents = $null; $parentFeatures = $null
        try {
            $parentFeatures = $feature.ParentFeatures
            if ($null -ne $parentFeatures) {
                $parentCount = Get-RequiredCount "parent features of a feature of $what" $parentFeatures; $parents = @()
                for ($j = 1; $j -le $parentCount; $j++) { $parents += (Get-RequiredValue "name of a parent feature in $what" { $parentFeatures.Item($j).Name } -Kind string) }
            }
        } catch { $parents = $null }
        if ($null -eq $parents) { $script:PackageOptionalReadFailures++ }
        $elements = $null; $suppressedElements = $null; $patternElements = $null
        try { $patternElements = $feature.PatternElements } catch { $patternElements = $null }
        if ($null -ne $patternElements) { $elements = Get-OptionalValue { $patternElements.Count } "int" }
        if ($null -eq $elements) { $script:PackageOptionalReadFailures++ }
        else {
            $suppressedElements = 0
            for ($j = 1; $j -le $elements; $j++) {
                $flag = Get-OptionalValue { $patternElements.Item($j).Suppressed } "bool"
                if ($null -eq $flag) { $suppressedElements = $null; $script:PackageOptionalReadFailures++; break }
                if ($flag) { $suppressedElements++ }
            }
        }
        $patterns += [ordered]@{ name = (Get-RequiredValue "name of feature $i of $what" { $feature.Name } -Kind string); type = $typeName; suppressed = (Get-OptionalValue { $feature.Suppressed } "bool"); parents = $parents
            elements = $elements; elements_suppressed = $suppressedElements; instances = $(if ($null -ne $elements -and $null -ne $suppressedElements) { $elements - $suppressedElements } else { $null }) }
    }
    $holes = @(); $holeFeatures = $features.HoleFeatures
    $holeCount = Get-RequiredCount "hole features of $what" $holeFeatures
    for ($i = 1; $i -le $holeCount; $i++) {
        $hole = $holeFeatures.Item($i); $name = Get-RequiredValue "name of hole feature $i of $what" { $hole.Name } -Kind string
        $holeType = Get-EnumName "HoleFeature" "HoleType" (Get-OptionalValue { $hole.HoleType } "int"); $tapped = Get-OptionalValue { $hole.Tapped } "bool"
        $entry = [ordered]@{ name = $name; suppressed = (Get-OptionalValue { $hole.Suppressed } "bool"); hole_type = $holeType; extent_type = (Get-EnumName "HoleFeature" "ExtentType" (Get-OptionalValue { $hole.ExtentType } "int"))
            extended_name = (Get-OptionalValue { $hole.ExtendedName } "string"); tapped = $tapped
            diameter = (Get-ParameterBrief (Get-OptionalObject { $hole.HoleDiameter })); depth_cm = (Get-OptionalValue { $hole.Depth } "double")
            counterbore = $null; countersink = $null; spotface = $null; thread = $null; clearance = $null; centres_mm = $null; repeated_by = @() }
        if ($holeType -eq "kCounterBoreHole") { $entry.counterbore = [ordered]@{ diameter = (Get-ParameterBrief (Get-OptionalObject { $hole.CBoreDiameter })); depth = (Get-ParameterBrief (Get-OptionalObject { $hole.CBoreDepth })) } }
        if ($holeType -eq "kCounterSinkHole") { $entry.countersink = [ordered]@{ diameter = (Get-ParameterBrief (Get-OptionalObject { $hole.CSinkDiameter })); angle = (Get-ParameterBrief (Get-OptionalObject { $hole.CSinkAngle })) } }
        if ($holeType -eq "kSpotFaceHole") { $entry.spotface = [ordered]@{ diameter = (Get-ParameterBrief (Get-OptionalObject { $hole.SpotFaceDiameter })); depth = (Get-ParameterBrief (Get-OptionalObject { $hole.SpotFaceDepth })) } }
        if ($tapped -eq $true) {
            # A tapped hole has no hole diameter: its size is in the thread data, in the unit of the thread standard.
            $tap = Get-OptionalObject { $hole.TapInfo }
            if ($tap) {
                $metric = Get-OptionalValue { $tap.Metric } "bool"
                $entry.thread = [ordered]@{ designation = (Get-OptionalValue { $tap.ThreadDesignation } "string"); thread_type = (Get-OptionalValue { $tap.ThreadType } "string"); class = (Get-OptionalValue { $tap.Class } "string")
                    internal = (Get-OptionalValue { $tap.Internal } "bool"); right_handed = (Get-OptionalValue { $tap.RightHanded } "bool"); metric = $metric; unit = $(if ($null -eq $metric) { $null } elseif ($metric) { "mm" } else { "in" })
                    nominal_size = (Get-OptionalValue { $tap.NominalSize } "string"); pitch = (Get-OptionalValue { $tap.Pitch } "double"); tap_drill_diameter = (Get-OptionalValue { $tap.TapDrillDiameter } "double")
                    major_diameter_min = (Get-OptionalValue { $tap.MajorDiameterMin } "double"); major_diameter_max = (Get-OptionalValue { $tap.MajorDiameterMax } "double")
                    minor_diameter_min = (Get-OptionalValue { $tap.MinorDiameterMin } "double"); minor_diameter_max = (Get-OptionalValue { $tap.MinorDiameterMax } "double")
                    pitch_diameter_min = (Get-OptionalValue { $tap.PitchDiameterMin } "double"); pitch_diameter_max = (Get-OptionalValue { $tap.PitchDiameterMax } "double")
                    full_thread_depth = (Get-OptionalValue { $tap.FullThreadDepth } "bool"); thread_depth = (Get-ParameterBrief (Get-OptionalObject { $tap.ThreadDepth })) }
            }
        }
        if ((Get-OptionalValue { $hole.IsClearanceHole } "bool") -eq $true) {
            $clearance = Get-OptionalObject { $hole.ClearanceInfo }
            if ($clearance) { $entry.clearance = [ordered]@{ standard = (Get-OptionalValue { $clearance.FastenerStandard } "string"); fastener_type = (Get-OptionalValue { $clearance.FastenerType } "string"); size = (Get-OptionalValue { $clearance.FastenerSize } "string")
                    fit = (Get-EnumName "HoleClearanceInfo" "FastenerFitType" (Get-OptionalValue { $clearance.FastenerFitType } "int")) } }
        }
        $centres = $null; $centrePoints = $null
        try {
            $centrePoints = $hole.HoleCenterPoints
            if ($null -ne $centrePoints) {
                $centreCount = Get-RequiredCount "centres of a hole of $what" $centrePoints; $centres = @()
                for ($j = 1; $j -le $centreCount; $j++) {
                    $item = $centrePoints.Item($j); $itemType = Get-ObjectTypeName $item
                    $point = $(if ($itemType -eq "kSketchPointObject") { Get-OptionalObject { $item.Geometry3d } } elseif ($itemType -eq "kWorkPointObject") { Get-OptionalObject { $item.Point } } else { $item })
                    $centres += ,(Get-PointMm $point)
                }
            }
        } catch { $centres = $null }
        if ($null -eq $centres) { $script:PackageOptionalReadFailures++ }
        $entry.centres_mm = $centres
        $entry.repeated_by = @($patterns | Where-Object { @($_.parents) -contains $name } | ForEach-Object { $_.name })
        $holes += $entry
    }
    return [pscustomobject]@{ holes = $holes; patterns = $patterns }
}

# ---- the guards of this run, and how often each was evaluated and let the run pass (0: the run did not reach it) ----
$guards = New-PackageGuardLedger @("inputs_bound_to_the_acquisition", "document_type_known", "no_document_has_a_view", "primary_model_state", "master_positional_representation_and_level_of_detail", "no_factory",
    "occurrence_not_suppressed_adaptive_or_substitute", "occurrence_places_a_bound_document", "rigid_placement", "bom_structure_known", "collection_gives_as_many_items_as_it_counts",
    "definition_equals_native_occurrence", "instance_has_its_documents_children", "placement_that_differs_has_a_flexible_occurrence_above", "translator_reports_successful",
    "file_schema_names_the_ap242_schema_alone", "attempts_have_the_same_data_section", "step_length_unit_determined", "invisibility_form_understood", "opened_files_unchanged_on_disk", "mirror_unchanged",
    "package_checked_before_package_json", "package_checked_with_package_json", "run_status_allows_a_complete_package")
$session = $null; $app = $null; $project = $null; $errors = @(); $warnings = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null; $completion = $null
$inputs = @(); $documents = [ordered]@{}; $rootRecord = $null; $script:context = @(); $translatorOptions = $null; $rawOutputs = [ordered]@{}; $headerNames = @(); $partTimings = @(); $timings = [ordered]@{}
$retried = @(); $packageWritten = $false; $mirrorBefore = $null; $mirror = $null; $status = "FAILED"; $withheld = $null
$changed = @(); $placed = @(); $notExported = @(); $forbidden = @(); $packageComplete = $false; $manifestPresent = $null; $outcome = $null; $prospective = $null; $completion = $null
# Inventor is started INSIDE the try whose finally stops it: nothing between the start and the try can fail and
# leave the instance running.
try {
    # every file of the mirror, before Inventor exists: afterwards none may have changed, appeared or disappeared
    $mirrorBefore = Get-PackageDirectoryHashes $WorkspaceRoot
    $session = Start-IsolatedInventor
    $app = $session.App
    Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build)); ownership via $($session.OwnershipMethod)"
    $watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $WorkDirectory "dialogs.log")
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); activated by this run: $($project.Activated))"
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $to = $app.TransientObjects
    Log "Opening $(Relative $NativeAssembly)"
    $asm = $app.Documents.Open($NativeAssembly, $false)
    try {
        if ((Get-RequiredValue "document type of the root" { $asm.DocumentType } -Kind int) -ne $kAssembly) { throw "Not an assembly document: $NativeAssembly" }
        # ---- bind every opened document BEFORE anything is read for the package ----
        $inputs = Confirm-AcquiredInputs $asm $acqJson $invJson
        Add-PackageGuardCheck $guards "inputs_bound_to_the_acquisition" @($inputs).Count
        Log "Bound $($inputs.Count) opened documents to acquisition/inventory ($(@($inputs | Where-Object { $_.kind -eq 'assembly' }).Count) assemblies, $(@($inputs | Where-Object { $_.kind -eq 'part' }).Count) parts)"
        $timings.open_and_bind_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        # ---- the documents: identity, model state, no view ----
        # the documents the root references are a collection that must exist and give as many items as it counts
        $referencedDocuments = $asm.AllReferencedDocuments
        $openedDocuments = @($asm) + @(Get-RequiredItems "documents the root references" $referencedDocuments)
        Add-PackageGuardCheck $guards "collection_gives_as_many_items_as_it_counts"
        foreach ($doc in $openedDocuments) {
            $file = Get-RequiredValue "file name of an opened document" { $doc.FullFileName } -Kind string; $lower = $file.ToLowerInvariant()
            if ($documents.Contains($lower)) { continue }
            $what = Relative $file
            $acquired = $acqByPath[$lower]; if (-not $acquired) { throw "Opened document is not in the acquisition record: $what" }
            $listed = $invByVersion[[string]$acquired.version_id]; if (-not $listed) { throw "Acquisition version $($acquired.version_id) is not in the dependency inventory" }
            $typeCode = Get-RequiredValue "document type of '$what'" { $doc.DocumentType } -Kind int
            $kind = $(if ($typeCode -eq $kAssembly) { "assembly" } elseif ($typeCode -eq $kPart) { "part" } else { throw "Unsupported: document type $typeCode of $what" })
            Add-PackageGuardCheck $guards "document_type_known"
            # the views are asked for as a collection that must exist: the count of nothing would be 0, "no view"
            $viewList = $doc.Views
            $views = Get-RequiredCount "views of '$what'" $viewList
            if ($views -gt 0) { throw "Refused: '$what' has $views view(s); a STEP file exported from it would carry that view's camera" }
            Add-PackageGuardCheck $guards "no_document_has_a_view"
            $definition = $doc.ComponentDefinition
            $state = Get-RequiredValue "model state of '$what'" { $definition.ModelStates.ActiveModelState.Name } -Kind string
            if ($masterNames -notcontains $state) { throw "Unsupported: '$what' is in model state '$state' (tested subset: primary model states only)" }
            Add-PackageGuardCheck $guards "primary_model_state"
            $vault = New-PackageVaultBlock -VaultId $vaultId -AcquisitionRecord $acquired -InventoryRecord $listed
            $folder = Get-PackageDirectoryName $vault.master_id $state
            foreach ($other in $documents.Values) { if ($other.Folder -ieq $folder) { throw "Refused: '$what' and '$($other.What)' would share the directory $folder" } }
            # null is for a unit Inventor returns as nothing; a read that fails stops the run, as it always did
            $unitCode = Get-GivenValue "length unit of '$what'" { $doc.UnitsOfMeasure.LengthUnits } "int"
            $documents[$lower] = [pscustomobject]@{ Document = $doc; What = $what; Kind = $kind; Name = [IO.Path]::GetFileNameWithoutExtension($file); ModelState = $state; Vault = $vault; Folder = $folder
                Placed = 0; Children = @(); ChildByName = @{}; LengthUnit = $(if ($null -ne $unitCode) { $lengthUnitNames[$unitCode] } else { $null }); DisplayName = (Get-OptionalValue { $doc.DisplayName } "string") }
        }
        $rootRecord = $documents[$NativeAssembly.ToLowerInvariant()]; $rootRecord.Placed = 1
        $rootDef = $asm.ComponentDefinition
        if (Get-RequiredValue "root IsiAssemblyFactory" { $rootDef.IsiAssemblyFactory }) { throw "Unsupported: root assembly is an iAssembly factory" }
        Add-PackageGuardCheck $guards "no_factory"
        function Get-Target($o, $what) {
            # The record of the document an occurrence places, with the guards on that occurrence. It emits the record only.
            if (Get-RequiredValue "Suppressed of '$what'" { $o.Suppressed }) { throw "Unsupported: suppressed occurrence '$what' (its document is not loaded; the package mode does not export it yet)" }
            if (Get-RequiredValue "Adaptive of '$what'" { $o.Adaptive }) { throw "Unsupported: adaptive occurrence '$what'" }
            if (Get-RequiredValue "IsSubstituteOccurrence of '$what'" { $o.IsSubstituteOccurrence }) { throw "Unsupported: substitute (LOD) occurrence '$what'" }
            Add-PackageGuardCheck $guards "occurrence_not_suppressed_adaptive_or_substitute"
            $placedFile = Get-RequiredValue "document of '$what'" { $o.Definition.Document.FullFileName } -Kind string
            $target = $documents[$placedFile.ToLowerInvariant()]
            if (-not $target) { throw "Occurrence '$what' places a document that is not among the opened, bound documents" }
            $placedType = Get-RequiredValue "DefinitionDocumentType of '$what'" { $o.DefinitionDocumentType } -Kind int
            $kind = $(if ($placedType -eq $kAssembly) { "assembly" } elseif ($placedType -eq $kPart) { "part" } else { "other" })
            if ($kind -ne $target.Kind) { throw "Occurrence '$what' is a $kind and its document is a $($target.Kind)" }
            Add-PackageGuardCheck $guards "occurrence_places_a_bound_document"
            $state = Get-RequiredValue "ActiveModelState of '$what'" { $o.ActiveModelState } -Kind string
            if ($state -ne $target.ModelState) { throw "Unsupported: occurrence '$what' uses model state '$state' but its document's active state is '$($target.ModelState)'" }
            Add-PackageGuardCheck $guards "primary_model_state"
            if ($kind -eq "assembly") {
                if (Get-RequiredValue "IsiAssemblyFactory of '$what'" { $o.Definition.IsiAssemblyFactory }) { throw "Unsupported: nested iAssembly factory '$what'" }
                $lod = Get-RequiredValue "ActiveLevelOfDetailRepresentation of '$what'" { $o.ActiveLevelOfDetailRepresentation } -Kind string
                $pos = Get-RequiredValue "ActivePositionalRepresentation of '$what'" { $o.ActivePositionalRepresentation } -Kind string
                if ($masterNames -notcontains $lod) { throw "Unsupported: assembly occurrence '$what' uses level of detail '$lod'" }
                if ($masterNames -notcontains $pos) { throw "Unsupported: assembly occurrence '$what' uses positional representation '$pos'" }
                Add-PackageGuardCheck $guards "master_positional_representation_and_level_of_detail"
            } else {
                if (Get-RequiredValue "IsiPartFactory of '$what'" { $o.Definition.IsiPartFactory }) { throw "Unsupported: iPart factory ('$what')" }
            }
            Add-PackageGuardCheck $guards "no_factory"
            return $target
        }
        function Get-Flags($o, $kind, $what) {
            # The BOM structure and the flags of an occurrence, each a required query.
            return [ordered]@{ bom_structure = (Get-BomName (Get-RequiredValue "BOMStructure of '$what'" { $o.BOMStructure } -Kind int) "'$what'"); visible = (Get-RequiredValue "Visible of '$what'" { $o.Visible }); suppressed = $false
                grounded = (Get-RequiredValue "Grounded of '$what'" { $o.Grounded }); flexible = $(if ($kind -eq "assembly") { Get-RequiredValue "Flexible of '$what'" { $o.Flexible } } else { $false }); mirrored = $false }
        }
        # ---- each assembly document once: its children as its own component definition holds them ----
        foreach ($record in @($documents.Values | Where-Object { $_.Kind -eq "assembly" })) {
            $definition = $record.Document.ComponentDefinition
            $positional = Get-RequiredValue "positional representation of '$($record.What)'" { $definition.RepresentationsManager.ActivePositionalRepresentation.Name } -Kind string
            $detail = Get-RequiredValue "level of detail of '$($record.What)'" { $definition.RepresentationsManager.ActiveLevelOfDetailRepresentation.Name } -Kind string
            if ($masterNames -notcontains $positional) { throw "Unsupported: '$($record.What)' is in positional representation '$positional' (master required)" }
            if ($masterNames -notcontains $detail) { throw "Unsupported: '$($record.What)' is in level of detail '$detail' (master required)" }
            Add-PackageGuardCheck $guards "master_positional_representation_and_level_of_detail"
            $record | Add-Member -NotePropertyName Representations -NotePropertyValue ([ordered]@{ design_view_representation = (Get-OptionalValue { $definition.RepresentationsManager.ActiveDesignViewRepresentation.Name } "string"); positional_representation = $positional; level_of_detail = $detail })
            # the occurrences are a collection that must exist and must give as many items as it counts
            $occurrenceList = $definition.Occurrences
            $expected = Get-RequiredCount "occurrences of '$($record.What)'" $occurrenceList
            $children = @()
            foreach ($o in $occurrenceList) {
                $name = Get-RequiredValue "name of an occurrence in '$($record.What)'" { $o.Name } -Kind string; $what = "$($record.Name) > $name"
                if ($name.Contains("/") -or $record.ChildByName.ContainsKey($name)) { throw "Unsupported: occurrence name '$name' in $($record.What) is repeated or holds '/'" }
                $target = Get-Target $o $what
                $transform = Cells $o.Transformation; Assert-Rigid $transform "'$what'"
                $child = [ordered]@{ name = $name; kind = $target.Kind; master_id = $target.Vault.master_id; model_state = $target.ModelState; transform = $transform }
                $flags = Get-Flags $o $target.Kind $what; foreach ($flag in $flags.Keys) { $child[$flag] = $flags[$flag] }
                $record.ChildByName[$name] = $child; $children += $child
            }
            if ($children.Count -ne $expected) { throw "Refused: '$($record.What)' counts $expected occurrences and gave $($children.Count)" }
            Add-PackageGuardCheck $guards "collection_gives_as_many_items_as_it_counts"
            $record.Children = $children
        }
        $timings.definitions_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        # ---- every occurrence in the context of the root ----
        function Walk($occurrences, $parentPath, $parentWorld, $parentRecord, $flexibleAbove) {
            # Called as a statement: files every occurrence in $script:context and goes into the sub-assemblies.
            $instance = $(if (@($parentPath).Count -gt 0) { "the instance '$($parentPath -join '/')'" } else { "the root" })
            $expected = Get-RequiredCount "occurrences of $instance of $($parentRecord.What)" $occurrences
            $names = @()
            foreach ($o in $occurrences) {
                $name = Get-RequiredValue "name of an occurrence of $instance" { $o.Name } -Kind string; $path = @($parentPath) + $name; $id = $path -join "/"; $names += $name
                $definition = $parentRecord.ChildByName[$name]
                if (-not $definition) { throw "Occurrence '$id' is not a child its document $($parentRecord.What) defines" }
                $target = Get-Target $o $id
                if ($target.Kind -ne $definition.kind -or $target.Vault.master_id -ne $definition.master_id -or $target.ModelState -ne $definition.model_state) { throw "Occurrence '$id' places another component than its document $($parentRecord.What) defines" }
                $world = Cells $o.Transformation; Assert-Rigid $world "'$id' in the root"
                $local = Mul (InvRigid $parentWorld) $world
                if ($path.Count -gt 1) {
                    # the definition read from the document must be what Inventor holds for this proxy
                    $nativeOccurrence = $o.NativeObject
                    Assert-RequiredObject "native occurrence of '$id'" $nativeOccurrence
                    $native = Cells $nativeOccurrence.Transformation; $check = Deviation $native $definition.transform
                    if ($check.rotation -gt 0 -or $check.length -gt 0) { throw "Occurrence '$id': the placement its document defines is not the one its native occurrence has" }
                    Add-PackageGuardCheck $guards "definition_equals_native_occurrence"
                }
                $deviation = Deviation $local $definition.transform
                $differs = ($deviation.rotation -gt $rotationTolerance -or $deviation.length -gt $lengthTolerance)
                if ($differs -and -not $flexibleAbove) { throw "Refused: the placement of '$id' differs from its definition (rotation $($deviation.rotation), length $($deviation.length) cm) and no enclosing occurrence is flexible" }
                Add-PackageGuardCheck $guards "placement_that_differs_has_a_flexible_occurrence_above"
                $flags = Get-Flags $o $target.Kind $id
                $entry = [ordered]@{ path = $path; kind = $target.Kind; master_id = $target.Vault.master_id; model_state = $target.ModelState; transform = $local; transform_root = $world; differs_from_definition = $differs }
                foreach ($flag in $flags.Keys) { $entry[$flag] = $flags[$flag] }
                $entry.flags_that_differ_from_definition = @($flags.Keys | Where-Object { $flags[$_] -ne $definition[$_] })
                $script:context += $entry; $target.Placed++
                if ($target.Kind -eq "assembly") { $subOccurrences = $o.SubOccurrences; Walk $subOccurrences $path $world $target ($flexibleAbove -or $flags.flexible) }
            }
            if ($names.Count -ne $expected) { throw "Refused: $instance of $($parentRecord.What) counts $expected occurrences and gave $($names.Count)" }
            Add-PackageGuardCheck $guards "collection_gives_as_many_items_as_it_counts"
            $defined = @($parentRecord.Children | ForEach-Object { $_.name })
            if (($names -join "/") -cne ($defined -join "/")) { throw "Refused: $instance of $($parentRecord.What) does not have the children its document defines" }
            Add-PackageGuardCheck $guards "instance_has_its_documents_children"
        }
        $rootOccurrences = $rootDef.Occurrences
        Walk $rootOccurrences @() $Identity $rootRecord $false
        $timings.context_walk_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        $differing = @($script:context | Where-Object { $_.differs_from_definition }).Count
        Log "Occurrences in context: $(@($script:context | Where-Object { $_.kind -eq 'part' }).Count) part, $(@($script:context | Where-Object { $_.kind -eq 'assembly' }).Count) sub-assembly; $differing differ from their definition; flags that differ from the definition on $(@($script:context | Where-Object { @($_.flags_that_differ_from_definition).Count -gt 0 }).Count)"
        # ---- the STEP files first, then everything else that is read from the documents ----
        # The translator sometimes names a second, unrelated schema in FILE_SCHEMA, in front of the AP242 one, for
        # the usual data section (AUTOMOTIVE_DESIGN, FEATURE_BASED_PROCESS_PLANNING, PROCESS_PLANNING_SCHEMA; what
        # was seen is in windows/README.md). Why is not known. Such a file is not repaired: the part is exported
        # again, a file is accepted only when it names the AP242 schema alone, every attempt must have the same
        # data section, and every attempt is recorded in the receipt and kept in WORK. The limit of three attempts
        # is not to be raised: a part that fails three times stops the run and is reported.
        $exported = @{}
        foreach ($record in $documents.Values) {
            if ($record.Placed -eq 0 -or $record.Kind -ne "part") { continue }
            $doc = $record.Document
            $partClock = [Diagnostics.Stopwatch]::StartNew()
            $directory = Join-Path $filesDirectory $record.Folder; New-Item -ItemType Directory -Path $directory | Out-Null
            $attempts = @(); $rawInfo = $null; $rawPath = $null; $result = $null
            for ($attempt = 1; $attempt -le $maximumAttempts -and $null -eq $rawInfo; $attempt++) {
                $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
                $opts = $to.CreateNameValueMap()
                if (-not (Get-RequiredValue "HasSaveCopyAsOptions for '$($record.What)'" { $translator.HasSaveCopyAsOptions($doc, $ctx, $opts) })) { throw "The STEP translator reports no options for '$($record.What)'" }
                Set-MapValue $opts "ApplicationProtocolType" 5; Set-MapValue $opts "IncludeSketches" $false
                foreach ($option in @("Author", "Organization", "Authorization", "Description")) { Set-MapValue $opts $option "" }
                $options = Read-Map $opts
                if (-not (Test-PackageSameNames @($options.Keys) $PackageTranslatorOptions)) { throw "The STEP translator reports other options than the eight known ones for '$($record.What)': $(@($options.Keys) -join ', ')" }
                $optionsText = ConvertTo-PackageJson $options
                if ($null -eq $translatorOptions) { $translatorOptions = $options } elseif ($optionsText -cne (ConvertTo-PackageJson $translatorOptions)) { throw "The translator options of '$($record.What)' differ from those of the first part" }
                $candidate = Join-Path $rawDirectory $(if ($attempt -eq 1) { "$($record.Folder).step" } else { "$($record.Folder).attempt-$attempt.step" })
                $medium = $to.CreateDataMedium(); $medium.FileName = $candidate
                $translator.SaveCopyAs($doc, $ctx, $opts, $medium)
                if (-not (Test-Path -LiteralPath $candidate)) { throw "The translator wrote no file for '$($record.What)'" }
                # the translator has to say "Successful": no result at all is not a success
                $result = (Read-Map $opts)["Translation Result"]
                if ($result -isnot [string] -or $result -cne "Successful") { throw "The translator did not report 'Successful' for '$($record.What)': it reported '$result'" }
                Add-PackageGuardCheck $guards "translator_reports_successful"
                $info = Get-StepFileInfo -Path $candidate
                $accepted = (@($info.header.schemas).Count -eq 1 -and $info.header.protocol -eq "AP242")
                $attempts += [ordered]@{ attempt = $attempt; file = [IO.Path]::GetFileName($candidate); schemas = @($info.header.schemas); accepted = $accepted; sha256 = $info.sha256; data_sha256 = $info.data_sha256; bytes = $info.bytes }
                if ($accepted) { $rawInfo = $info; $rawPath = $candidate } else { Log "  $($record.Folder): attempt $attempt names $(@($info.header.schemas).Count) schemas in FILE_SCHEMA ($(@($info.header.schemas) -join ' | ')); not accepted" }
            }
            if ($null -eq $rawInfo) { throw "Refused: the translator's file of '$($record.What)' did not name the AP242 schema alone in $maximumAttempts attempts: $(@($attempts | ForEach-Object { $_.schemas -join ' | ' }) -join ' ; ')" }
            Add-PackageGuardCheck $guards "file_schema_names_the_ap242_schema_alone"
            if (@($attempts | ForEach-Object { $_.data_sha256 } | Sort-Object -Unique).Count -ne 1) { throw "Refused: the attempts for '$($record.What)' do not have the same data section" }
            Add-PackageGuardCheck $guards "attempts_have_the_same_data_section"
            if ($attempts.Count -gt 1) { $retried += [ordered]@{ file = $record.What; directory = $record.Folder; attempts = $attempts }; $warnings += "'$($record.What)' was exported $($attempts.Count) times: the translator named a second schema in FILE_SCHEMA (the data section was the same each time)" }
            $exportSeconds = [Math]::Round($partClock.Elapsed.TotalSeconds, 2); $partClock.Restart()
            foreach ($text in @($rawInfo.header.author) + @($rawInfo.header.organization) + @($rawInfo.header.authorisation)) { if ($text) { $headerNames += [string]$text } }
            $unit = Get-StepLengthUnit $rawPath
            if (-not $unit.ok) { throw "STEP length unit of '$($record.What)' rejected: $($unit.reason)" }
            Add-PackageGuardCheck $guards "step_length_unit_determined"
            $stepPath = Join-Path $directory "part.step"
            $normalised = Set-StepFileHeader -Path $rawPath -OutPath $stepPath
            $invisible = Get-StepInvisibility -Path $stepPath
            if (-not $invisible.form_understood) { throw "Refused: the file of '$($record.What)' marks items invisible in a form that is not understood: $(@($invisible.problems) -join '; ')" }
            Add-PackageGuardCheck $guards "invisibility_form_understood"
            $counted = Get-StepEntityCounts -Path $stepPath
            $rawOutputs["files/$($record.Folder)/part.step"] = [ordered]@{ sha256 = $rawInfo.sha256; bytes = $rawInfo.bytes }
            $exported[$record.Folder] = [pscustomobject]@{ Normalised = $normalised; Protocol = $rawInfo.header.protocol; Unit = $unit.unit; Hidden = @($invisible.hidden_items).Count; Result = $result
                SolidsInFile = ([int]$counted["MANIFOLD_SOLID_BREP"] + [int]$counted["BREP_WITH_VOIDS"]); ExportSeconds = $exportSeconds; FileSeconds = [Math]::Round($partClock.Elapsed.TotalSeconds, 2) }
        }
        $timings.step_files_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        Log "STEP files: $($exported.Count) exported, each naming the AP242 schema alone; exported more than once: $($retried.Count)"
        # ---- then the records: properties, bodies, parameters and holes, the assemblies ----
        foreach ($record in $documents.Values) {
            if ($record.Placed -eq 0) { continue }
            $doc = $record.Document; $definition = $doc.ComponentDefinition
            $directory = Join-Path $filesDirectory $record.Folder; if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
            $properties = [ordered]@{ category = (Prop $doc "Inventor Document Summary Information" "Category"); description = (Prop $doc "Design Tracking Properties" "Description"); manufacturer = (Prop $doc "Design Tracking Properties" "Manufacturer")
                material = (Prop $doc "Design Tracking Properties" "Material"); part_number = (Prop $doc "Design Tracking Properties" "Part Number"); stock_number = (Prop $doc "Design Tracking Properties" "Stock Number")
                title = (Prop $doc "Inventor Summary Information" "Title"); vendor = (Prop $doc "Design Tracking Properties" "Vendor") }
            if ($record.Kind -eq "assembly") {
                $manifest = [ordered]@{ schema_version = $PackageLayoutSchemaVersion; name = $record.Name; length_unit = "cm" }
                # The root states the frame, as Export-PartAssets.ps1 declares it in scene.json: Inventor's axes as stored, +Y up.
                if ([object]::ReferenceEquals($record, $rootRecord)) { $manifest.frame = [ordered]@{ handedness = "right"; up_axis = "+Y" } }
                $manifest.children = $record.Children
                Write-PackageJsonFile (Join-Path $directory "assembly.json") $manifest
                $native = [ordered]@{ length_unit = $record.LengthUnit; instances_in_export = $record.Placed; children = @($record.Children).Count }
                foreach ($key in $record.Representations.Keys) { $native[$key] = $record.Representations[$key] }
                Write-PackageJsonFile (Join-Path $directory "source.json") ([ordered]@{ schema_version = $PackageLayoutSchemaVersion; kind = "assembly"; name = $record.Name; model_state = $record.ModelState; vault = $record.Vault
                        export = [ordered]@{}; properties = $properties; native = $native; materials = $null })
                continue
            }
            $step = $exported[$record.Folder]
            $partClock = [Diagnostics.Stopwatch]::StartNew()
            # the bodies are a collection that must exist and must give as many items as it counts
            $bodyList = $definition.SurfaceBodies
            $expectedBodies = Get-RequiredCount "bodies of '$($record.What)'" $bodyList
            $bodies = 0; $solids = 0; $visible = 0
            foreach ($body in $bodyList) { $bodies++; if (Get-RequiredValue "IsSolid of a body in '$($record.What)'" { $body.IsSolid }) { $solids++; if (Get-RequiredValue "Visible of a body in '$($record.What)'" { $body.Visible }) { $visible++ } } }
            if ($bodies -ne $expectedBodies) { throw "Refused: '$($record.What)' counts $expectedBodies bodies and gave $bodies" }
            Add-PackageGuardCheck $guards "collection_gives_as_many_items_as_it_counts"
            if ($step.SolidsInFile -ne $solids) { $warnings += "'$($record.What)': the file has $($step.SolidsInFile) solid instances and the part $solids solid bodies" }
            $failuresBefore = $script:PackageOptionalReadFailures
            $parameters = Read-Parameters $definition $doc.UnitsOfMeasure "'$($record.What)'"
            $features = Read-Features $definition "'$($record.What)'"
            $featureSeconds = [Math]::Round($partClock.Elapsed.TotalSeconds, 2)
            # the extent must be readable (six numbers); the volume may be unknown and is then null, not 0
            $box = $definition.RangeBox
            Assert-RequiredObject "range box of '$($record.What)'" $box
            $low = $box.MinPoint; $high = $box.MaxPoint
            Assert-RequiredObject "range box corners of '$($record.What)'" $low; Assert-RequiredObject "range box corners of '$($record.What)'" $high
            $extent = @((((Get-RequiredValue "range box of '$($record.What)'" { $high.X } -Kind number) - (Get-RequiredValue "range box of '$($record.What)'" { $low.X } -Kind number)) * 10.0),
                (((Get-RequiredValue "range box of '$($record.What)'" { $high.Y } -Kind number) - (Get-RequiredValue "range box of '$($record.What)'" { $low.Y } -Kind number)) * 10.0),
                (((Get-RequiredValue "range box of '$($record.What)'" { $high.Z } -Kind number) - (Get-RequiredValue "range box of '$($record.What)'" { $low.Z } -Kind number)) * 10.0))
            $volume = Get-OptionalValue { $definition.MassProperties.Volume } "double"
            $native = [ordered]@{ length_unit = $record.LengthUnit
                extent_mm = $extent
                volume_mm3 = $(if ($null -ne $volume) { $volume * 1000.0 } else { $null })
                bodies = [ordered]@{ solid_bodies = $solids; visible_solid_bodies = $visible; surface_bodies = $bodies }
                parameter_values = "value is in Inventor's database units (centimetre, radian); value_text is the same value in the parameter's own unit"
                parameters = $parameters; holes = $features.holes; patterns = $features.patterns }
            Write-PackageJsonFile (Join-Path $directory "source.json") ([ordered]@{ schema_version = $PackageLayoutSchemaVersion; kind = "part"; name = $record.Name; model_state = $record.ModelState; vault = $record.Vault
                    step = [ordered]@{ sha256 = $step.Normalised.output_sha256; data_sha256 = $step.Normalised.data_sha256; bytes = $step.Normalised.output_bytes; protocol = $step.Protocol; length_unit = $step.Unit; header_normalised = $true; received_sha256 = $null }
                    export = [ordered]@{ translator_result = $step.Result }; properties = $properties
                    bom_structure_default = (Get-BomName (Get-RequiredValue "BOMStructure of '$($record.What)'" { $definition.BOMStructure } -Kind int) "'$($record.What)'")
                    native = $native; materials = $null })
            $partTimings += [ordered]@{ file = $record.What; directory = $record.Folder; export_seconds = $step.ExportSeconds; file_checks_seconds = $step.FileSeconds; parameters_and_holes_seconds = $featureSeconds
                parameters = @($parameters).Count; holes = @($features.holes).Count; patterns = @($features.patterns).Count; values_not_read = ($script:PackageOptionalReadFailures - $failuresBefore)
                solid_bodies = $solids; solid_instances_in_file = $step.SolidsInFile; hidden_items = $step.Hidden; step_length_unit = $step.Unit; bytes = $step.Normalised.output_bytes }
            Log ("{0,-18} {1,-58} {2,9} bytes {3,-2} export {4,5}s features {5,5}s parameters={6} holes={7} patterns={8} hidden={9}" -f $record.Folder, $record.Name, $step.Normalised.output_bytes, $step.Unit, $step.ExportSeconds, $featureSeconds, @($parameters).Count, @($features.holes).Count, @($features.patterns).Count, $step.Hidden)
        }
        $timings.records_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        $occurrencesOut = @(foreach ($entry in $script:context) { $copy = [ordered]@{}; foreach ($key in $entry.Keys) { if ($key -ne "flags_that_differ_from_definition") { $copy[$key] = $entry[$key] } }; $copy })
        Write-PackageJsonFile (Join-Path $OutputDirectory "occurrences.json") ([ordered]@{ schema_version = $PackageOccurrencesSchemaVersion; root = [ordered]@{ master_id = $rootRecord.Vault.master_id; model_state = $rootRecord.ModelState }; length_unit = "cm"
                tolerance = [ordered]@{ rotation_cell = $rotationTolerance; length = $lengthTolerance }
                counts = [ordered]@{ occurrences = $occurrencesOut.Count; parts = @($occurrencesOut | Where-Object { $_.kind -eq "part" }).Count; assemblies = @($occurrencesOut | Where-Object { $_.kind -eq "assembly" }).Count; differ_from_definition = $differing }
                occurrences = $occurrencesOut })
        # A dirty flag that cannot be read is not "not dirty". A read that fails stops the run here, before the
        # package is said to be written (Get-GivenValue); a flag Inventor returns as nothing is counted and warned of.
        $dirty = @(); $dirtyUnknown = 0
        foreach ($held in $documents.Values) { $flag = Get-GivenValue "dirty flag of '$($held.What)' after the export" { $held.Document.Dirty } "bool"; if ($null -eq $flag) { $dirtyUnknown++ } elseif ($flag) { $dirty += $held.What } }
        if ($dirty.Count -gt 0) { $warnings += "dirty when the export ended (closed without saving): $($dirty -join '; ')" }
        if ($dirtyUnknown -gt 0) { $warnings += "Inventor gave no dirty flag for $dirtyUnknown document(s) when the export ended (closed without saving)" }
        $packageWritten = $true
    } finally { try { $asm.Close($true) } catch { $errors += "assembly close: $($_.Exception.Message)" } }
} catch {
    $errors += $_.Exception.Message
    try { Log "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace } } catch { }
} finally {
    # each step on its own: one that fails must not keep the next from running
    if ($session) {
        try { $shutdown = Stop-IsolatedInventor $session $project } catch { $errors += "the shutdown of the owned Inventor instance threw: $($_.Exception.Message)" }
        try { if (-not $shutdown -or -not $shutdown.Succeeded) { $errors += "shutdown not observed as complete: $(if ($shutdown) { "$($shutdown.Observed | ConvertTo-Json -Compress) notes=$($shutdown.Notes -join ' | ')" } else { 'no result' })" } } catch { $errors += "the shutdown could not be described: $($_.Exception.Message)" }
        try { Log "Shutdown: pid $($session.Pid) exited=$(if ($shutdown) { $shutdown.Exited }) succeeded=$(if ($shutdown) { $shutdown.Succeeded })" } catch { }
    }
    if ($watchdog) {
        try { $dialogs = Stop-DialogWatchdog $watchdog } catch { $errors += "the dialog watchdog could not be stopped: $($_.Exception.Message)" }
        try { if ($dialogs) { Log "Dialog watchdog: $($dialogs.Polls) polls, $($dialogs.Events.Count) dialog window(s) seen, $($dialogs.Dismissed) dismissed, $($dialogs.Left) left alone" } } catch { }
    }
}
# ---- after Inventor. Nothing from here on runs outside a try: whatever fails must still leave a receipt, and must
# ---- not leave a package.json behind (Test-PackageFormat.ps1, case P22, holds the script to this).
try {
    # no opened file, and no other file of the mirror, may have changed; none may have appeared or disappeared
    foreach ($bindingRecord in @($inputs)) { if ((Sha $bindingRecord.path) -ne [string]$bindingRecord.acquisition_sha256) { $changed += (Relative ([string]$bindingRecord.path)) } }
    if ($changed.Count -gt 0) { $errors += "opened documents changed on disk: $($changed -join '; ')" } elseif (@($inputs).Count -gt 0) { Add-PackageGuardCheck $guards "opened_files_unchanged_on_disk" @($inputs).Count }
    if ($null -ne $mirrorBefore) {
        $mirror = Compare-PackageDirectoryHashes $mirrorBefore (Get-PackageDirectoryHashes $WorkspaceRoot)
        if ($mirror.unchanged) { Add-PackageGuardCheck $guards "mirror_unchanged" $mirror.files_after }
        else { $errors += "the mirror changed during the run: changed [$(@($mirror.changed) -join '; ')], added [$(@($mirror.added) -join '; ')], removed [$(@($mirror.removed) -join '; ')]" }
    }
    $placed = @($documents.Values | Where-Object { $_.Placed -gt 0 })
    $notExported = @($documents.Values | Where-Object { $_.Placed -eq 0 } | ForEach-Object { [ordered]@{ master_id = $_.Vault.master_id; model_state = $_.ModelState; reason = "a referenced document that no occurrence places (for example the base of a derived part)" } })
    $openedVersions = @($inputs | ForEach-Object { [string]$_.version_id })
    foreach ($listed in @($invJson.files | Where-Object { $openedVersions -notcontains [string]$_.version_id })) { $notExported += [ordered]@{ master_id = [string]$listed.master_id; model_state = $null; reason = "in the dependency inventory and not opened by Inventor with the root assembly" } }
    $forbidden = @(@($env:COMPUTERNAME, $env:USERNAME, $env:USERPROFILE, $WorkspaceRoot) + @($ForbiddenTerm) + @($headerNames) | Where-Object { $_ } | Sort-Object -Unique)
    if ($errors.Count -eq 0 -and $packageWritten -and $shutdown -and $shutdown.Succeeded) {
        $repository = Split-Path -Parent $PSScriptRoot; $commit = $null; $modified = $null
        try { $answer = @(cmd /c "git -C ""$repository"" rev-parse HEAD 2>nul"); if ($LASTEXITCODE -eq 0 -and "$($answer[0])" -match '^[a-f0-9]{40}$') { $commit = "$($answer[0])"; $state = @(cmd /c "git -C ""$repository"" status --porcelain 2>nul"); if ($LASTEXITCODE -eq 0) { $modified = ($state.Count -gt 0) } } } catch { $commit = $null }
        # "counts" and "files" are filled by Complete-Package, which checks the package, writes package.json last,
        # checks again, and removes package.json when anything fails after it was written
        $manifest = [ordered]@{ schema_version = $PackageSchemaVersion; kind = $PackageKind; exported_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            exporter = [ordered]@{ name = "windows/Export-Package.ps1"; version = $commit; working_tree_modified = $modified; inventor = "$($session.Version) (build $($session.Build))" }
            translator_options = $translatorOptions; vault_id = $vaultId
            root = [ordered]@{ master_id = $rootRecord.Vault.master_id; version_id = $rootRecord.Vault.version_id; model_state = $rootRecord.ModelState }
            acquisition = [ordered]@{ captured_at = [string]$invJson.captured_at; acquired_at = [string]$acqJson.acquired_at; method = [string]$acqJson.method }
            counts = $null; not_exported = $notExported; translator_outputs = $rawOutputs; files = $null }
        $expectParts = @($placed | Where-Object { $_.Kind -eq "part" }).Count; $expectAssemblies = @($placed | Where-Object { $_.Kind -eq "assembly" }).Count; $expectOccurrences = @($script:context).Count
        # The status is known here, before package.json is written: the watchdog has been stopped. A run in which it
        # dismissed a dialog writes no package.json at all, so that a run killed in between cannot leave one behind.
        $prospective = Resolve-RunStatus -Status "complete" -Dialogs $dialogs
        if (-not (Test-PackageRunStatus $prospective)) { $withheld = "the run ends '$prospective': the watchdog dismissed a dialog, and what it acknowledged is only in this receipt, which stays on the workstation; package.json is not written" }
        $completion = Complete-Package -Directory $OutputDirectory -Manifest $manifest -ForbiddenTerms $forbidden -RotationTolerance $rotationTolerance -LengthTolerance $lengthTolerance -ExpectParts $expectParts -ExpectAssemblies $expectAssemblies -ExpectOccurrences $expectOccurrences -WithholdBecause "$withheld"
        if ($completion.ok) {
            Add-PackageGuardCheck $guards "package_checked_before_package_json"
            $status = $prospective
            if ($completion.manifest_written) { Add-PackageGuardCheck $guards "package_checked_with_package_json"; Add-PackageGuardCheck $guards "run_status_allows_a_complete_package" } else { $warnings += $withheld }
        } else {
            if ($completion.stage -ne "before package.json") { Add-PackageGuardCheck $guards "package_checked_before_package_json" }
            $errors += "the package failed its check ($($completion.stage)): $(@($completion.failures) -join '; ')"
        }
    }
} catch { $errors += "after Inventor was closed: $($_.Exception.Message)"; $status = "FAILED" }
# Only a run that ended "complete" leaves package.json. What the receipt says about the file is asked of the file
# system after the last attempt to remove it: a package.json that is still there fails the run and is reported.
try { if (-not (Test-PackageRunStatus $status)) { [void](Remove-PackageManifest $OutputDirectory) } } catch { $errors += "package.json could not be taken away: $($_.Exception.Message)" }
try {
    $outcome = Get-PackageOutcome $OutputDirectory $status
    $manifestPresent = $outcome.manifest_present; $packageComplete = $outcome.complete
    if ($outcome.problem) { $errors += $outcome.problem; if ($status -ceq "complete") { $status = "FAILED" } }
} catch { $errors += "the output directory could not be asked for package.json: $($_.Exception.Message)"; $status = "FAILED"; $packageComplete = $false }
# the receipt: always written; if it cannot be written in full the run is not recorded and its package is not complete
try {
    $receipt = [ordered]@{ schema_version = $PackageReceiptSchemaVersion; generated_at = (Utc); exporter = "windows/Export-Package.ps1"; status = $status; errors = $errors; warnings = $warnings
        package = $OutputDirectory; package_complete = $packageComplete; package_json_present = $manifestPresent; package_withheld_because = $withheld; work_directory = $WorkDirectory
        inventor = $(if ($session) { "$($session.Version) build $($session.Build)" } else { $null }); host = $env:COMPUTERNAME; interactive_desktop = [Environment]::UserInteractive; interop_assembly = $interopPath
        session = $(if ($session) { [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; started_at = $session.StartedAt.ToString("o"); pre_existing_inventor_pids = $session.PreExistingPids
                shutdown = $(if ($shutdown) { [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; attempted = $shutdown.Attempted; observed = $shutdown.Observed; unexpected_survivors = @($shutdown.UnexpectedSurvivors); notes = @($shutdown.Notes) } } else { $null }) } } else { $null })
        project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; entry_removed_by_run = $(if ($shutdown) { $shutdown.ProjectEntryRemoved } else { $null }); previous_active = $project.PreviousActive; previous_restored = $(if ($shutdown) { $shutdown.PreviousProjectRestored } else { $null }) } } else { $null })
        input_binding = [ordered]@{ mode = "strict acquisition binding"; opened_documents = @($inputs).Count; verified = @($inputs | Where-Object verified).Count; changed_on_disk_after_run = $changed; inputs = $inputs }
        mirror = $(if ($mirror) { [ordered]@{ hashed = "every file under the workspace root, before Inventor started and after it had exited"; files_before = $mirror.files_before; files_after = $mirror.files_after; changed = @($mirror.changed); added = @($mirror.added); removed = @($mirror.removed); unchanged = $mirror.unchanged } } else { $null })
        records = [ordered]@{ acquisition = $Acquisition; inventory = $Inventory; vault_facts_from = "the acquisition record (hash) and the dependency inventory of the same acquisition (version number, revision, lifecycle state, check-in date); no Vault request" }
        guards_note = "the number of times each guard was evaluated and let the run pass; 0 means the run did not reach it. Guard queries fail closed: an exception, nothing, a collection or another type than asked for stops the run"
        guards = $guards
        tolerance = [ordered]@{ rotation_cell = $rotationTolerance; length_cm = $lengthTolerance }
        counts = [ordered]@{ documents = $documents.Count; exported_parts = @($placed | Where-Object { $_.Kind -eq "part" }).Count; exported_assemblies = @($placed | Where-Object { $_.Kind -eq "assembly" }).Count; not_exported = @($notExported).Count
            occurrences = @($script:context).Count; occurrences_that_differ_from_definition = @($script:context | Where-Object { $_.differs_from_definition }).Count
            occurrences_whose_flags_differ_from_definition = @($script:context | Where-Object { @($_.flags_that_differ_from_definition).Count -gt 0 }).Count; feature_values_not_read = $script:PackageOptionalReadFailures }
        display_names_that_are_not_the_file_name = @($documents.Values | Where-Object { $_.DisplayName -and $_.DisplayName -ne $_.Name -and [IO.Path]::GetFileNameWithoutExtension($_.DisplayName) -ne $_.Name } | ForEach-Object { [ordered]@{ file = $_.What; display_name = $_.DisplayName } })
        flags_that_differ_from_definition = @($script:context | Where-Object { @($_.flags_that_differ_from_definition).Count -gt 0 } | ForEach-Object { [ordered]@{ occurrence = ($_.path -join "/"); flags = $_.flags_that_differ_from_definition } })
        timings = $timings; parts = $partTimings; translator_options = $translatorOptions; translator_outputs = $rawOutputs; exported_more_than_once = $retried; maximum_attempts = $maximumAttempts; header_names_found_in_translator_output = @($headerNames | Sort-Object -Unique)
        forbidden_terms_checked = @($forbidden).Count; validation = $(if ($completion) { [ordered]@{ ok = $completion.ok; stage = $completion.stage; failures = @($completion.failures); summary = $completion.summary } } else { [ordered]@{ ok = $false; stage = "not reached"; failures = @("the package was not checked") } })
        dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; log = "dialogs.log"; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors); remaining_at_stop = @($dialogs.Remaining) } } else { $null }) }
    ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath (Join-Path $WorkDirectory "export-package-receipt.json") -Encoding UTF8
} catch {
    $problem = $_.Exception.Message; $status = "FAILED"; $packageComplete = $false
    try { [void](Remove-PackageManifest $OutputDirectory) } catch { }
    try { $manifestPresent = Test-Path -LiteralPath (Join-Path $OutputDirectory "package.json") } catch { $manifestPresent = $null }
    try { ConvertTo-Json -InputObject ([ordered]@{ schema_version = $PackageReceiptSchemaVersion; generated_at = (Utc); exporter = "windows/Export-Package.ps1"; status = "FAILED"; errors = @($errors) + @("the receipt could not be written in full: $problem"); package_complete = $false; package_json_present = $manifestPresent }) -Depth 4 | Set-Content -LiteralPath (Join-Path $WorkDirectory "export-package-receipt.json") -Encoding UTF8 } catch { }
    Write-Output "ERROR: the receipt could not be written in full: $problem"
}
try { Log "Package status: $status; package.json $(if ($packageComplete) { 'written' } else { 'not left' }) ($(@($placed | Where-Object { $_.Kind -eq 'part' }).Count) parts, $(@($placed | Where-Object { $_.Kind -eq 'assembly' }).Count) assemblies, $(@($script:context).Count) occurrences in context)" } catch { }
if (-not $packageComplete -or $status -cne "complete") { exit 1 }
