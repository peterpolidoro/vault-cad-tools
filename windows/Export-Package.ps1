<#
.SYNOPSIS
Export one root assembly as the exporter's package (draft: mechanical-cad/docs/exporter-package.md): one
directory per Vault file and model state, with source.json and part.step or assembly.json, the occurrences in
the context of the root, and package.json. Read-only: nothing is saved and Vault is not contacted.

.DESCRIPTION
    & .\windows\Export-Package.ps1 -NativeAssembly ROOT.iam -WorkspaceRoot MIRROR `
        -Acquisition acquisition.json -Inventory dependency-inventory.json `
        -OutputDirectory PACKAGE -WorkDirectory WORK

A mode of its own beside Export-PartAssets.ps1, whose output, default protocol and tests are unchanged.
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
  - a BOM structure the layout does not know; a text of the workstation in any file of the package.
Vault facts come from the two records of the acquisition; the exporter makes no Vault request.
Exit code 1 unless the status is complete.
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
function Cells($m) { $rows = @(); for ($r = 1; $r -le 4; $r++) { $row = @(); for ($c = 1; $c -le 4; $c++) { $row += [double]$m.GetType().InvokeMember("Cell", [Reflection.BindingFlags]::GetProperty, $null, $m, @($r, $c)) }; $rows += ,$row }; return ,$rows }
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
# Required guard queries fail CLOSED: an exception means the configuration is unknown and is refused.
function Require($what, [scriptblock]$query, [ValidateSet("bool", "string", "int")][string]$Kind = "bool") {
    $raw = $null
    try { $raw = & $query } catch { throw "Required guard query '$what' failed; unknown configuration refused: $($_.Exception.Message)" }
    if ($null -eq $raw) { throw "Required guard query '$what' returned null; unknown configuration refused" }
    if ($raw -is [array]) { throw "Required guard query '$what' returned a collection; unknown configuration refused" }
    switch ($Kind) {
        "bool"   { if ($raw -isnot [bool]) { throw "Required guard query '$what' returned '$raw' ($($raw.GetType().Name)), not a boolean; unknown configuration refused" }; return [bool]$raw }
        "string" { if ($raw -isnot [string] -or [string]::IsNullOrWhiteSpace($raw)) { throw "Required guard query '$what' returned an empty or non-string value ($($raw.GetType().Name)); unknown configuration refused" }; return [string]$raw }
        "int"    { if ($raw -isnot [int] -and $raw -isnot [long] -and $raw -isnot [int16] -and $raw -isnot [byte]) { throw "Required guard query '$what' returned '$raw' ($($raw.GetType().Name)), not an integer; unknown configuration refused" }; return [int]$raw }
    }
}
function Get-BomName($value, $what) {
    $name = $bomNames[[int]$value]
    if ($PackageBomStructures -notcontains $name) { throw "Unsupported: BOM structure $value ($name) of $what" }
    return $name
}
function Assert-Rigid($matrix, $what) { $reason = Test-PackageRigid (Get-PackageFlat $matrix) $rotationTolerance; if ($reason) { throw "Unsupported: the placement of $what is not a rotation and a translation: $reason" } }

# ---- parameters, holes and the features that repeat them (late-bound; a value that cannot be read is null) ----
$script:featureNulls = 0
function Read-Optional([scriptblock]$query) { try { return (& $query) } catch { $script:featureNulls++; return $null } }
function Read-Value([scriptblock]$query, [ValidateSet("double", "bool", "int", "string")][string]$As) {
    # A typed value, or $null when the read fails or the API returns nothing: a cast of $null would invent 0, False or "".
    $raw = $null
    try { $raw = & $query } catch { $script:featureNulls++; return $null }
    if ($null -eq $raw) { return $null }
    switch ($As) { "double" { return [double]$raw } "bool" { return [bool]$raw } "int" { return [int]$raw } default { return [string]$raw } }
}
# Read-Optional is for scalars and single objects only: a COM collection returned from a script block is
# enumerated by PowerShell and arrives as an array. Collections are assigned directly, inside try.
function Get-EnumName([string]$interface, [string]$property, $value) {
    if ($null -eq $value) { return $null }
    $type = $interop.GetType("Inventor.$interface"); $declared = $(if ($type) { $type.GetProperty($property) } else { $null })
    if ($declared -and $declared.PropertyType.IsEnum) { $name = [Enum]::GetName($declared.PropertyType, [int]$value); if ($name) { return $name } }
    return "$([int]$value)"
}
function Get-ObjectTypeName($object) { $value = Read-Value { $object.Type } "int"; if ($null -eq $value) { return $null }; $name = [Enum]::GetName($objectTypeEnum, $value); if ($name) { return $name }; return "ObjectTypeEnum $value" }
function Get-ParameterBrief($parameter) {
    if ($null -eq $parameter) { return $null }
    return [ordered]@{ parameter = (Read-Value { $parameter.Name } "string"); expression = (Read-Value { $parameter.Expression } "string"); value = (Read-Value { $parameter.Value } "double"); units = (Read-Value { $parameter.Units } "string") }
}
function Get-PointMm($point) {
    # X, Y, Z of a point in millimetres, or $null when the point or one of its coordinates is not known.
    if ($null -eq $point) { return $null }
    $x = Read-Value { $point.X } "double"; $y = Read-Value { $point.Y } "double"; $z = Read-Value { $point.Z } "double"
    if ($null -eq $x -or $null -eq $y -or $null -eq $z) { return $null }
    return @(($x * 10.0), ($y * 10.0), ($z * 10.0))
}
function Read-Parameters($definition, $units) {
    # Every parameter of the part. A failure to list them is an error (the caller stops); a single value may be null.
    $all = $definition.Parameters
    $kindOf = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($pair in @(@("model", "ModelParameters"), @("reference", "ReferenceParameters"), @("user", "UserParameters"))) {
        $collection = $all.GetType().InvokeMember($pair[1], [Reflection.BindingFlags]::GetProperty, $null, $all, $null)
        for ($i = 1; $i -le [int]$collection.Count; $i++) { $kindOf[[string]$collection.Item($i).Name] = $pair[0] }
    }
    $list = @()
    for ($i = 1; $i -le [int]$all.Count; $i++) {
        $parameter = $all.Item($i); $name = [string]$parameter.Name
        $raw = Read-Optional { $parameter.Value }; $unitText = Read-Value { $parameter.Units } "string"
        $value = $(if ($null -eq $raw -or $raw -is [string] -or $raw -is [bool]) { $raw } else { [double]$raw })
        $text = $(if ($value -is [double]) { Read-Value { $units.GetStringFromValue($value, $unitText) } "string" } else { $null })
        $list += [ordered]@{ name = $name; kind = $(if ($kindOf.ContainsKey($name)) { $kindOf[$name] } else { "other" }); expression = (Read-Value { $parameter.Expression } "string"); units = $unitText
            value = $value; value_text = $text; comment = (Read-Value { $parameter.Comment } "string"); is_key = (Read-Value { $parameter.IsKey } "bool"); exposed_as_property = (Read-Value { $parameter.ExposedAsProperty } "bool") }
    }
    return ,$list
}
function Read-Features($definition) {
    # The hole features and the pattern and mirror features of the part: @{ holes; patterns }.
    $features = $definition.Features
    $patterns = @()
    for ($i = 1; $i -le [int]$features.Count; $i++) {
        $feature = $features.Item($i); $typeName = Get-ObjectTypeName $feature
        if ($typeName -notmatch 'Pattern|Mirror') { continue }
        $parents = @(); $parentFeatures = $null
        try { $parentFeatures = $feature.ParentFeatures; for ($j = 1; $j -le [int]$parentFeatures.Count; $j++) { $parents += [string]$parentFeatures.Item($j).Name } } catch { $script:featureNulls++; $parents = $null }
        $elements = $null; $suppressedElements = $null; $patternElements = $null
        try { $patternElements = $feature.PatternElements; $elements = [int]$patternElements.Count } catch { $script:featureNulls++; $elements = $null }
        if ($null -ne $elements) { $suppressedElements = 0; for ($j = 1; $j -le $elements; $j++) { if (Read-Value { $patternElements.Item($j).Suppressed } "bool") { $suppressedElements++ } } }
        $patterns += [ordered]@{ name = [string]$feature.Name; type = $typeName; suppressed = (Read-Value { $feature.Suppressed } "bool"); parents = $parents
            elements = $elements; elements_suppressed = $suppressedElements; instances = $(if ($null -ne $elements) { $elements - $suppressedElements } else { $null }) }
    }
    $holes = @(); $holeFeatures = $features.HoleFeatures
    for ($i = 1; $i -le [int]$holeFeatures.Count; $i++) {
        $hole = $holeFeatures.Item($i); $name = [string]$hole.Name
        $holeType = Get-EnumName "HoleFeature" "HoleType" (Read-Value { $hole.HoleType } "int"); $tapped = Read-Value { $hole.Tapped } "bool"
        $entry = [ordered]@{ name = $name; suppressed = (Read-Value { $hole.Suppressed } "bool"); hole_type = $holeType; extent_type = (Get-EnumName "HoleFeature" "ExtentType" (Read-Value { $hole.ExtentType } "int"))
            extended_name = (Read-Value { $hole.ExtendedName } "string"); tapped = $tapped
            diameter = (Get-ParameterBrief (Read-Optional { $hole.HoleDiameter })); depth_cm = (Read-Value { $hole.Depth } "double")
            counterbore = $null; countersink = $null; spotface = $null; thread = $null; clearance = $null; centres_mm = $null; repeated_by = @() }
        if ($holeType -eq "kCounterBoreHole") { $entry.counterbore = [ordered]@{ diameter = (Get-ParameterBrief (Read-Optional { $hole.CBoreDiameter })); depth = (Get-ParameterBrief (Read-Optional { $hole.CBoreDepth })) } }
        if ($holeType -eq "kCounterSinkHole") { $entry.countersink = [ordered]@{ diameter = (Get-ParameterBrief (Read-Optional { $hole.CSinkDiameter })); angle = (Get-ParameterBrief (Read-Optional { $hole.CSinkAngle })) } }
        if ($holeType -eq "kSpotFaceHole") { $entry.spotface = [ordered]@{ diameter = (Get-ParameterBrief (Read-Optional { $hole.SpotFaceDiameter })); depth = (Get-ParameterBrief (Read-Optional { $hole.SpotFaceDepth })) } }
        if ($tapped -eq $true) {
            # A tapped hole has no hole diameter: its size is in the thread data, in the unit of the thread standard.
            $tap = Read-Optional { $hole.TapInfo }
            if ($tap) {
                $metric = Read-Value { $tap.Metric } "bool"
                $entry.thread = [ordered]@{ designation = (Read-Value { $tap.ThreadDesignation } "string"); thread_type = (Read-Value { $tap.ThreadType } "string"); class = (Read-Value { $tap.Class } "string")
                    internal = (Read-Value { $tap.Internal } "bool"); right_handed = (Read-Value { $tap.RightHanded } "bool"); metric = $metric; unit = $(if ($null -eq $metric) { $null } elseif ($metric) { "mm" } else { "in" })
                    nominal_size = (Read-Value { $tap.NominalSize } "string"); pitch = (Read-Value { $tap.Pitch } "double"); tap_drill_diameter = (Read-Value { $tap.TapDrillDiameter } "double")
                    major_diameter_min = (Read-Value { $tap.MajorDiameterMin } "double"); major_diameter_max = (Read-Value { $tap.MajorDiameterMax } "double")
                    minor_diameter_min = (Read-Value { $tap.MinorDiameterMin } "double"); minor_diameter_max = (Read-Value { $tap.MinorDiameterMax } "double")
                    pitch_diameter_min = (Read-Value { $tap.PitchDiameterMin } "double"); pitch_diameter_max = (Read-Value { $tap.PitchDiameterMax } "double")
                    full_thread_depth = (Read-Value { $tap.FullThreadDepth } "bool"); thread_depth = (Get-ParameterBrief (Read-Optional { $tap.ThreadDepth })) }
            }
        }
        if ((Read-Value { $hole.IsClearanceHole } "bool") -eq $true) {
            $clearance = Read-Optional { $hole.ClearanceInfo }
            if ($clearance) { $entry.clearance = [ordered]@{ standard = (Read-Value { $clearance.FastenerStandard } "string"); fastener_type = (Read-Value { $clearance.FastenerType } "string"); size = (Read-Value { $clearance.FastenerSize } "string")
                    fit = (Get-EnumName "HoleClearanceInfo" "FastenerFitType" (Read-Value { $clearance.FastenerFitType } "int")) } }
        }
        try {
            $centrePoints = $hole.HoleCenterPoints; $centres = @()
            for ($j = 1; $j -le [int]$centrePoints.Count; $j++) {
                $item = $centrePoints.Item($j); $itemType = Get-ObjectTypeName $item
                $point = $(if ($itemType -eq "kSketchPointObject") { Read-Optional { $item.Geometry3d } } elseif ($itemType -eq "kWorkPointObject") { Read-Optional { $item.Point } } else { $item })
                $centres += ,(Get-PointMm $point)
            }
            $entry.centres_mm = $centres
        } catch { $script:featureNulls++; $entry.centres_mm = $null }
        $entry.repeated_by = @($patterns | Where-Object { @($_.parents) -contains $name } | ForEach-Object { $_.name })
        $holes += $entry
    }
    return [pscustomobject]@{ holes = $holes; patterns = $patterns }
}

$session = Start-IsolatedInventor
$app = $session.App
Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build)); ownership via $($session.OwnershipMethod)"
$project = $null; $errors = @(); $warnings = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null; $validation = $null
$watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $WorkDirectory "dialogs.log")
$inputs = @(); $documents = [ordered]@{}; $rootRecord = $null; $script:context = @(); $translatorOptions = $null; $rawOutputs = [ordered]@{}; $headerNames = @(); $partTimings = @(); $timings = [ordered]@{}
$retried = @(); $packageWritten = $false; $clock = [Diagnostics.Stopwatch]::StartNew()
try {
    $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); activated by this run: $($project.Activated))"
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $to = $app.TransientObjects
    Log "Opening $(Relative $NativeAssembly)"
    $asm = $app.Documents.Open($NativeAssembly, $false)
    try {
        if ([int]$asm.DocumentType -ne $kAssembly) { throw "Not an assembly document: $NativeAssembly" }
        # ---- bind every opened document BEFORE anything is read for the package ----
        $inputs = Confirm-AcquiredInputs $asm $acqJson $invJson
        Log "Bound $($inputs.Count) opened documents to acquisition/inventory ($(@($inputs | Where-Object { $_.kind -eq 'assembly' }).Count) assemblies, $(@($inputs | Where-Object { $_.kind -eq 'part' }).Count) parts)"
        $timings.open_and_bind_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        # ---- the documents: identity, model state, no view ----
        foreach ($doc in @($asm) + @($asm.AllReferencedDocuments)) {
            $file = [string]$doc.FullFileName; $lower = $file.ToLowerInvariant()
            if ($documents.Contains($lower)) { continue }
            $what = Relative $file
            $acquired = $acqByPath[$lower]; if (-not $acquired) { throw "Opened document is not in the acquisition record: $what" }
            $listed = $invByVersion[[string]$acquired.version_id]; if (-not $listed) { throw "Acquisition version $($acquired.version_id) is not in the dependency inventory" }
            $kind = $(if ([int]$doc.DocumentType -eq $kAssembly) { "assembly" } elseif ([int]$doc.DocumentType -eq $kPart) { "part" } else { throw "Unsupported: document type $([int]$doc.DocumentType) of $what" })
            $views = Require "views of '$what'" { [int]$doc.Views.Count } -Kind int
            if ($views -gt 0) { throw "Refused: '$what' has $views view(s); a STEP file exported from it would carry that view's camera" }
            $definition = $doc.ComponentDefinition
            $state = Require "model state of '$what'" { $definition.ModelStates.ActiveModelState.Name } -Kind string
            if ($masterNames -notcontains $state) { throw "Unsupported: '$what' is in model state '$state' (tested subset: primary model states only)" }
            $vault = New-PackageVaultBlock -VaultId $vaultId -AcquisitionRecord $acquired -InventoryRecord $listed
            $folder = Get-PackageDirectoryName $vault.master_id $state
            foreach ($other in $documents.Values) { if ($other.Folder -ieq $folder) { throw "Refused: '$what' and '$($other.What)' would share the directory $folder" } }
            $documents[$lower] = [pscustomobject]@{ Document = $doc; What = $what; Kind = $kind; Name = [IO.Path]::GetFileNameWithoutExtension($file); ModelState = $state; Vault = $vault; Folder = $folder
                Placed = 0; Children = @(); ChildByName = @{}; LengthUnit = $lengthUnitNames[[int]$doc.UnitsOfMeasure.LengthUnits]; DisplayName = (Read-Value { $doc.DisplayName } "string") }
        }
        $rootRecord = $documents[$NativeAssembly.ToLowerInvariant()]; $rootRecord.Placed = 1
        $rootDef = $asm.ComponentDefinition
        if (Require "root IsiAssemblyFactory" { $rootDef.IsiAssemblyFactory }) { throw "Unsupported: root assembly is an iAssembly factory" }
        function Get-Target($o, $what) {
            # The record of the document an occurrence places, with the guards on that occurrence.
            if (Require "Suppressed of '$what'" { $o.Suppressed }) { throw "Unsupported: suppressed occurrence '$what' (its document is not loaded; the package mode does not export it yet)" }
            if (Require "Adaptive of '$what'" { $o.Adaptive }) { throw "Unsupported: adaptive occurrence '$what'" }
            if (Require "IsSubstituteOccurrence of '$what'" { $o.IsSubstituteOccurrence }) { throw "Unsupported: substitute (LOD) occurrence '$what'" }
            $target = $documents[([string]$o.Definition.Document.FullFileName).ToLowerInvariant()]
            if (-not $target) { throw "Occurrence '$what' places a document that is not among the opened, bound documents" }
            $kind = $(if ([int]$o.DefinitionDocumentType -eq $kAssembly) { "assembly" } elseif ([int]$o.DefinitionDocumentType -eq $kPart) { "part" } else { "other" })
            if ($kind -ne $target.Kind) { throw "Occurrence '$what' is a $kind and its document is a $($target.Kind)" }
            $state = Require "ActiveModelState of '$what'" { $o.ActiveModelState } -Kind string
            if ($state -ne $target.ModelState) { throw "Unsupported: occurrence '$what' uses model state '$state' but its document's active state is '$($target.ModelState)'" }
            if ($kind -eq "assembly") {
                if (Require "IsiAssemblyFactory of '$what'" { $o.Definition.IsiAssemblyFactory }) { throw "Unsupported: nested iAssembly factory '$what'" }
                $lod = Require "ActiveLevelOfDetailRepresentation of '$what'" { $o.ActiveLevelOfDetailRepresentation } -Kind string
                $pos = Require "ActivePositionalRepresentation of '$what'" { $o.ActivePositionalRepresentation } -Kind string
                if ($masterNames -notcontains $lod) { throw "Unsupported: assembly occurrence '$what' uses level of detail '$lod'" }
                if ($masterNames -notcontains $pos) { throw "Unsupported: assembly occurrence '$what' uses positional representation '$pos'" }
            } elseif (Require "IsiPartFactory of '$what'" { $o.Definition.IsiPartFactory }) { throw "Unsupported: iPart factory ('$what')" }
            return $target
        }
        function Get-Flags($o, $kind, $what) {
            # The BOM structure and the flags of an occurrence, each a required query.
            return [ordered]@{ bom_structure = (Get-BomName (Require "BOMStructure of '$what'" { [int]$o.BOMStructure } -Kind int) "'$what'"); visible = (Require "Visible of '$what'" { $o.Visible }); suppressed = $false
                grounded = (Require "Grounded of '$what'" { $o.Grounded }); flexible = $(if ($kind -eq "assembly") { Require "Flexible of '$what'" { $o.Flexible } } else { $false }); mirrored = $false }
        }
        # ---- each assembly document once: its children as its own component definition holds them ----
        foreach ($record in @($documents.Values | Where-Object { $_.Kind -eq "assembly" })) {
            $definition = $record.Document.ComponentDefinition
            $positional = Require "positional representation of '$($record.What)'" { $definition.RepresentationsManager.ActivePositionalRepresentation.Name } -Kind string
            $detail = Require "level of detail of '$($record.What)'" { $definition.RepresentationsManager.ActiveLevelOfDetailRepresentation.Name } -Kind string
            if ($masterNames -notcontains $positional) { throw "Unsupported: '$($record.What)' is in positional representation '$positional' (master required)" }
            if ($masterNames -notcontains $detail) { throw "Unsupported: '$($record.What)' is in level of detail '$detail' (master required)" }
            $record | Add-Member -NotePropertyName Representations -NotePropertyValue ([ordered]@{ design_view_representation = (Read-Value { $definition.RepresentationsManager.ActiveDesignViewRepresentation.Name } "string"); positional_representation = $positional; level_of_detail = $detail })
            $children = @()
            foreach ($o in $definition.Occurrences) {
                $name = [string]$o.Name; $what = "$($record.Name) > $name"
                if (-not $name -or $name.Contains("/") -or $record.ChildByName.ContainsKey($name)) { throw "Unsupported: occurrence name '$name' in $($record.What) is empty, repeated or holds '/'" }
                $target = Get-Target $o $what
                $transform = Cells $o.Transformation; Assert-Rigid $transform "'$what'"
                $child = [ordered]@{ name = $name; kind = $target.Kind; master_id = $target.Vault.master_id; model_state = $target.ModelState; transform = $transform }
                $flags = Get-Flags $o $target.Kind $what; foreach ($flag in $flags.Keys) { $child[$flag] = $flags[$flag] }
                $record.ChildByName[$name] = $child; $children += $child
            }
            $record.Children = $children
        }
        $timings.definitions_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        # ---- every occurrence in the context of the root ----
        function Walk($occurrences, $parentPath, $parentWorld, $parentRecord, $flexibleAbove) {
            # Called as a statement: files every occurrence in $script:context and goes into the sub-assemblies.
            $names = @()
            foreach ($o in $occurrences) {
                $name = [string]$o.Name; $path = @($parentPath) + $name; $id = $path -join "/"; $names += $name
                $definition = $parentRecord.ChildByName[$name]
                if (-not $definition) { throw "Occurrence '$id' is not a child its document $($parentRecord.What) defines" }
                $target = Get-Target $o $id
                if ($target.Kind -ne $definition.kind -or $target.Vault.master_id -ne $definition.master_id -or $target.ModelState -ne $definition.model_state) { throw "Occurrence '$id' places another component than its document $($parentRecord.What) defines" }
                $world = Cells $o.Transformation; Assert-Rigid $world "'$id' in the root"
                $local = Mul (InvRigid $parentWorld) $world
                if ($path.Count -gt 1) {
                    # the definition read from the document must be what Inventor holds for this proxy
                    $native = Cells $o.NativeObject.Transformation; $check = Deviation $native $definition.transform
                    if ($check.rotation -gt 0 -or $check.length -gt 0) { throw "Occurrence '$id': the placement its document defines is not the one its native occurrence has" }
                }
                $deviation = Deviation $local $definition.transform
                $differs = ($deviation.rotation -gt $rotationTolerance -or $deviation.length -gt $lengthTolerance)
                if ($differs -and -not $flexibleAbove) { throw "Refused: the placement of '$id' differs from its definition (rotation $($deviation.rotation), length $($deviation.length) cm) and no enclosing occurrence is flexible" }
                $flags = Get-Flags $o $target.Kind $id
                $entry = [ordered]@{ path = $path; kind = $target.Kind; master_id = $target.Vault.master_id; model_state = $target.ModelState; transform = $local; transform_root = $world; differs_from_definition = $differs }
                foreach ($flag in $flags.Keys) { $entry[$flag] = $flags[$flag] }
                $entry.flags_that_differ_from_definition = @($flags.Keys | Where-Object { $flags[$_] -ne $definition[$_] })
                $script:context += $entry; $target.Placed++
                if ($target.Kind -eq "assembly") { Walk $o.SubOccurrences $path $world $target ($flexibleAbove -or $flags.flexible) }
            }
            $defined = @($parentRecord.Children | ForEach-Object { $_.name })
            if (($names -join "/") -cne ($defined -join "/")) { throw "Refused: the instance '$($parentPath -join '/')' of $($parentRecord.What) does not have the children its document defines" }
        }
        Walk $rootDef.Occurrences @() $Identity $rootRecord $false
        $timings.context_walk_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        $differing = @($script:context | Where-Object { $_.differs_from_definition }).Count
        Log "Occurrences in context: $(@($script:context | Where-Object { $_.kind -eq 'part' }).Count) part, $(@($script:context | Where-Object { $_.kind -eq 'assembly' }).Count) sub-assembly; $differing differ from their definition; flags that differ from the definition on $(@($script:context | Where-Object { @($_.flags_that_differ_from_definition).Count -gt 0 }).Count)"
        # ---- the STEP files first, then everything else that is read from the documents ----
        # The translator sometimes names a second, unrelated schema in FILE_SCHEMA, in front of the AP242 one, for
        # the usual data section (AUTOMOTIVE_DESIGN, FEATURE_BASED_PROCESS_PLANNING, PROCESS_PLANNING_SCHEMA; what
        # was seen is in windows/README.md). Why is not known. Such a file is not repaired: the part is exported
        # again, a file is accepted only when it names the AP242 schema alone, every attempt must have the same
        # data section, and every attempt is recorded in the receipt and kept in WORK.
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
                if (-not $translator.HasSaveCopyAsOptions($doc, $ctx, $opts)) { throw "The STEP translator reports no options for '$($record.What)'" }
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
                $result = (Read-Map $opts)["Translation Result"]
                if ($null -ne $result -and $result -ne "Successful") { throw "The translator reports '$result' for '$($record.What)'" }
                $info = Get-StepFileInfo -Path $candidate
                $accepted = (@($info.header.schemas).Count -eq 1 -and $info.header.protocol -eq "AP242")
                $attempts += [ordered]@{ attempt = $attempt; file = [IO.Path]::GetFileName($candidate); schemas = @($info.header.schemas); accepted = $accepted; sha256 = $info.sha256; data_sha256 = $info.data_sha256; bytes = $info.bytes }
                if ($accepted) { $rawInfo = $info; $rawPath = $candidate } else { Log "  $($record.Folder): attempt $attempt names $(@($info.header.schemas).Count) schemas in FILE_SCHEMA ($(@($info.header.schemas) -join ' | ')); not accepted" }
            }
            if ($null -eq $rawInfo) { throw "Refused: the translator's file of '$($record.What)' did not name the AP242 schema alone in $maximumAttempts attempts: $(@($attempts | ForEach-Object { $_.schemas -join ' | ' }) -join ' ; ')" }
            if (@($attempts | ForEach-Object { $_.data_sha256 } | Sort-Object -Unique).Count -ne 1) { throw "Refused: the attempts for '$($record.What)' do not have the same data section" }
            if ($attempts.Count -gt 1) { $retried += [ordered]@{ file = $record.What; directory = $record.Folder; attempts = $attempts }; $warnings += "'$($record.What)' was exported $($attempts.Count) times: the translator named a second schema in FILE_SCHEMA (the data section was the same each time)" }
            $exportSeconds = [Math]::Round($partClock.Elapsed.TotalSeconds, 2); $partClock.Restart()
            foreach ($text in @($rawInfo.header.author) + @($rawInfo.header.organization) + @($rawInfo.header.authorisation)) { if ($text) { $headerNames += [string]$text } }
            $unit = Get-StepLengthUnit $rawPath
            if (-not $unit.ok) { throw "STEP length unit of '$($record.What)' rejected: $($unit.reason)" }
            $stepPath = Join-Path $directory "part.step"
            $normalised = Set-StepFileHeader -Path $rawPath -OutPath $stepPath
            $invisible = Get-StepInvisibility -Path $stepPath
            if (-not $invisible.form_understood) { throw "Refused: the file of '$($record.What)' marks items invisible in a form that is not understood: $(@($invisible.problems) -join '; ')" }
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
            $bodies = 0; $solids = 0; $visible = 0
            foreach ($body in $definition.SurfaceBodies) { $bodies++; if (Require "IsSolid of a body in '$($record.What)'" { $body.IsSolid }) { $solids++; if ($body.Visible) { $visible++ } } }
            if ($step.SolidsInFile -ne $solids) { $warnings += "'$($record.What)': the file has $($step.SolidsInFile) solid instances and the part $solids solid bodies" }
            $nullsBefore = $script:featureNulls
            $parameters = Read-Parameters $definition $doc.UnitsOfMeasure
            $features = Read-Features $definition
            $featureSeconds = [Math]::Round($partClock.Elapsed.TotalSeconds, 2)
            $box = $definition.RangeBox
            $native = [ordered]@{ length_unit = $record.LengthUnit
                extent_mm = @((($box.MaxPoint.X - $box.MinPoint.X) * 10.0), (($box.MaxPoint.Y - $box.MinPoint.Y) * 10.0), (($box.MaxPoint.Z - $box.MinPoint.Z) * 10.0))
                volume_mm3 = $(try { [double]$definition.MassProperties.Volume * 1000.0 } catch { $null })
                bodies = [ordered]@{ solid_bodies = $solids; visible_solid_bodies = $visible; surface_bodies = $bodies }
                parameter_values = "value is in Inventor's database units (centimetre, radian); value_text is the same value in the parameter's own unit"
                parameters = $parameters; holes = $features.holes; patterns = $features.patterns }
            Write-PackageJsonFile (Join-Path $directory "source.json") ([ordered]@{ schema_version = $PackageLayoutSchemaVersion; kind = "part"; name = $record.Name; model_state = $record.ModelState; vault = $record.Vault
                    step = [ordered]@{ sha256 = $step.Normalised.output_sha256; data_sha256 = $step.Normalised.data_sha256; bytes = $step.Normalised.output_bytes; protocol = $step.Protocol; length_unit = $step.Unit; header_normalised = $true; received_sha256 = $null }
                    export = [ordered]@{ translator_result = $step.Result }; properties = $properties
                    bom_structure_default = (Get-BomName (Require "BOMStructure of '$($record.What)'" { [int]$definition.BOMStructure } -Kind int) "'$($record.What)'")
                    native = $native; materials = $null })
            $partTimings += [ordered]@{ file = $record.What; directory = $record.Folder; export_seconds = $step.ExportSeconds; file_checks_seconds = $step.FileSeconds; parameters_and_holes_seconds = $featureSeconds
                parameters = @($parameters).Count; holes = @($features.holes).Count; patterns = @($features.patterns).Count; values_not_read = ($script:featureNulls - $nullsBefore)
                solid_bodies = $solids; solid_instances_in_file = $step.SolidsInFile; hidden_items = $step.Hidden; step_length_unit = $step.Unit; bytes = $step.Normalised.output_bytes }
            Log ("{0,-18} {1,-58} {2,9} bytes {3,-2} export {4,5}s features {5,5}s parameters={6} holes={7} patterns={8} hidden={9}" -f $record.Folder, $record.Name, $step.Normalised.output_bytes, $step.Unit, $step.ExportSeconds, $featureSeconds, @($parameters).Count, @($features.holes).Count, @($features.patterns).Count, $step.Hidden)
        }
        $timings.records_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); $clock.Restart()
        $occurrencesOut = @(foreach ($entry in $script:context) { $copy = [ordered]@{}; foreach ($key in $entry.Keys) { if ($key -ne "flags_that_differ_from_definition") { $copy[$key] = $entry[$key] } }; $copy })
        Write-PackageJsonFile (Join-Path $OutputDirectory "occurrences.json") ([ordered]@{ schema_version = $PackageOccurrencesSchemaVersion; root = [ordered]@{ master_id = $rootRecord.Vault.master_id; model_state = $rootRecord.ModelState }; length_unit = "cm"
                tolerance = [ordered]@{ rotation_cell = $rotationTolerance; length = $lengthTolerance }
                counts = [ordered]@{ occurrences = $occurrencesOut.Count; parts = @($occurrencesOut | Where-Object { $_.kind -eq "part" }).Count; assemblies = @($occurrencesOut | Where-Object { $_.kind -eq "assembly" }).Count; differ_from_definition = $differing }
                occurrences = $occurrencesOut })
        $dirty = @($documents.Values | Where-Object { [bool]$_.Document.Dirty } | ForEach-Object { $_.What })
        if ($dirty.Count -gt 0) { $warnings += "dirty when the export ended (closed without saving): $($dirty -join '; ')" }
        $packageWritten = $true
    } finally { try { $asm.Close($true) } catch { $errors += "assembly close: $($_.Exception.Message)" } }
} catch {
    $errors += $_.Exception.Message; Log "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace }
} finally {
    $shutdown = Stop-IsolatedInventor $session $project
    if (-not $shutdown.Succeeded) { $errors += "shutdown not observed as complete: $($shutdown.Observed | ConvertTo-Json -Compress) notes=$($shutdown.Notes -join ' | ')" }
    Log "Shutdown: pid $($shutdown.Pid) exited=$($shutdown.Exited) succeeded=$($shutdown.Succeeded)"
    if ($watchdog) { $dialogs = Stop-DialogWatchdog $watchdog; Log "Dialog watchdog: $($dialogs.Polls) polls, $($dialogs.Events.Count) dialog window(s) seen, $($dialogs.Dismissed) dismissed, $($dialogs.Left) left alone" }
}
# ---- integrity: no opened file may have changed on disk ----
$changed = @(); foreach ($bindingRecord in @($inputs)) { if ((Sha $bindingRecord.path) -ne [string]$bindingRecord.acquisition_sha256) { $changed += (Relative ([string]$bindingRecord.path)) } }
if ($changed.Count -gt 0) { $errors += "opened documents changed on disk: $($changed -join '; ')" }
# ---- the package is checked before package.json says it is complete ----
$placed = @($documents.Values | Where-Object { $_.Placed -gt 0 })
$notExported = @($documents.Values | Where-Object { $_.Placed -eq 0 } | ForEach-Object { [ordered]@{ master_id = $_.Vault.master_id; model_state = $_.ModelState; reason = "a referenced document that no occurrence places (for example the base of a derived part)" } })
$openedVersions = @($inputs | ForEach-Object { [string]$_.version_id })
foreach ($listed in @($invJson.files | Where-Object { $openedVersions -notcontains [string]$_.version_id })) { $notExported += [ordered]@{ master_id = [string]$listed.master_id; model_state = $null; reason = "in the dependency inventory and not opened by Inventor with the root assembly" } }
$forbidden = @(@($env:COMPUTERNAME, $env:USERNAME, $env:USERPROFILE, $WorkspaceRoot) + @($ForbiddenTerm) + @($headerNames) | Where-Object { $_ } | Sort-Object -Unique)
$status = "FAILED"
if ($errors.Count -eq 0 -and $packageWritten -and $shutdown.Succeeded) {
    $validation = Test-PackageOutputs -Directory $OutputDirectory -ForbiddenTerms $forbidden -AllowMissingManifest -RotationTolerance $rotationTolerance -LengthTolerance $lengthTolerance
    if (-not $validation.ok) { $errors += "the package failed its check: $(@($validation.failures) -join '; ')" }
    elseif ($validation.summary.parts -ne @($placed | Where-Object { $_.Kind -eq "part" }).Count -or $validation.summary.assemblies -ne @($placed | Where-Object { $_.Kind -eq "assembly" }).Count -or $validation.summary.occurrences -ne @($script:context).Count) { $errors += "the package does not hold what was exported: $($validation.summary | ConvertTo-Json -Compress)" }
    else {
        $repository = Split-Path -Parent $PSScriptRoot; $commit = $null; $modified = $null
        try { $answer = @(cmd /c "git -C ""$repository"" rev-parse HEAD 2>nul"); if ($LASTEXITCODE -eq 0 -and "$($answer[0])" -match '^[a-f0-9]{40}$') { $commit = "$($answer[0])"; $state = @(cmd /c "git -C ""$repository"" status --porcelain 2>nul"); if ($LASTEXITCODE -eq 0) { $modified = ($state.Count -gt 0) } } } catch { $commit = $null }
        $files = [ordered]@{}; $map = Get-PackageFileMap $OutputDirectory
        foreach ($name in $map.Keys) { $bytes = [IO.File]::ReadAllBytes($map[$name]); $files[$name] = [ordered]@{ sha256 = (Get-PackageSha $bytes); bytes = $bytes.Length } }
        Write-PackageJsonFile (Join-Path $OutputDirectory "package.json") ([ordered]@{ schema_version = $PackageSchemaVersion; kind = $PackageKind; exported_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                exporter = [ordered]@{ name = "windows/Export-Package.ps1"; version = $commit; working_tree_modified = $modified; inventor = "$($session.Version) (build $($session.Build))" }
                translator_options = $translatorOptions; vault_id = $vaultId
                root = [ordered]@{ master_id = $rootRecord.Vault.master_id; version_id = $rootRecord.Vault.version_id; model_state = $rootRecord.ModelState }
                acquisition = [ordered]@{ captured_at = [string]$invJson.captured_at; acquired_at = [string]$acqJson.acquired_at; method = [string]$acqJson.method }
                counts = [ordered]@{ parts = $validation.summary.parts; assemblies = $validation.summary.assemblies }
                not_exported = $notExported; translator_outputs = $rawOutputs; files = $files })
        $final = Test-PackageOutputs -Directory $OutputDirectory -ForbiddenTerms $forbidden -RotationTolerance $rotationTolerance -LengthTolerance $lengthTolerance
        if ($final.ok) { $validation = $final; $status = Resolve-RunStatus -Status "complete" -Dialogs $dialogs }
        else { $errors += "the package failed its check after package.json was written: $(@($final.failures) -join '; ')"; $validation = $final; Remove-Item -LiteralPath (Join-Path $OutputDirectory "package.json") -Force }
    }
}
$receipt = [ordered]@{ schema_version = 1; generated_at = (Utc); exporter = "windows/Export-Package.ps1"; status = $status; errors = $errors; warnings = $warnings
    package = $OutputDirectory; package_complete = (Test-Path -LiteralPath (Join-Path $OutputDirectory "package.json")); work_directory = $WorkDirectory
    inventor = "$($session.Version) build $($session.Build)"; host = $env:COMPUTERNAME; interactive_desktop = [Environment]::UserInteractive; interop_assembly = $interopPath
    session = [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; started_at = $session.StartedAt.ToString("o"); pre_existing_inventor_pids = $session.PreExistingPids; shutdown = [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; attempted = $shutdown.Attempted; observed = $shutdown.Observed; unexpected_survivors = @($shutdown.UnexpectedSurvivors); notes = @($shutdown.Notes) } }
    project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; entry_removed_by_run = $shutdown.ProjectEntryRemoved; previous_active = $project.PreviousActive; previous_restored = $shutdown.PreviousProjectRestored } } else { $null })
    input_binding = [ordered]@{ mode = "strict acquisition binding"; opened_documents = @($inputs).Count; verified = @($inputs | Where-Object verified).Count; changed_on_disk_after_run = $changed; inputs = $inputs }
    records = [ordered]@{ acquisition = $Acquisition; inventory = $Inventory; vault_facts_from = "the acquisition record (hash) and the dependency inventory of the same acquisition (version number, revision, lifecycle state, check-in date); no Vault request" }
    guards = [ordered]@{ inputs_bound_before_export = $true; no_document_has_a_view = $true; primary_model_states_only = $true; master_lod_and_positional_required = $true; factories_rejected = $true; adaptive_substitute_suppressed_rejected = $true; rigid_placements_only = $true
        definition_equals_native_occurrence = $true; instances_have_their_documents_children = $true; a_placement_that_differs_needs_a_flexible_occurrence_above = $true; invisibility_form_understood = $true; file_schema_names_the_ap242_schema_alone = $true; attempts_have_the_same_data_section = $true; guard_queries_fail_closed = $true }
    tolerance = [ordered]@{ rotation_cell = $rotationTolerance; length_cm = $lengthTolerance }
    counts = [ordered]@{ documents = $documents.Count; exported_parts = @($placed | Where-Object { $_.Kind -eq "part" }).Count; exported_assemblies = @($placed | Where-Object { $_.Kind -eq "assembly" }).Count; not_exported = $notExported.Count
        occurrences = @($script:context).Count; occurrences_that_differ_from_definition = @($script:context | Where-Object { $_.differs_from_definition }).Count
        occurrences_whose_flags_differ_from_definition = @($script:context | Where-Object { @($_.flags_that_differ_from_definition).Count -gt 0 }).Count; feature_values_not_read = $script:featureNulls }
    display_names_that_are_not_the_file_name = @($documents.Values | Where-Object { $_.DisplayName -and $_.DisplayName -ne $_.Name -and [IO.Path]::GetFileNameWithoutExtension($_.DisplayName) -ne $_.Name } | ForEach-Object { [ordered]@{ file = $_.What; display_name = $_.DisplayName } })
    flags_that_differ_from_definition = @($script:context | Where-Object { @($_.flags_that_differ_from_definition).Count -gt 0 } | ForEach-Object { [ordered]@{ occurrence = ($_.path -join "/"); flags = $_.flags_that_differ_from_definition } })
    timings = $timings; parts = $partTimings; translator_options = $translatorOptions; translator_outputs = $rawOutputs; exported_more_than_once = $retried; maximum_attempts = $maximumAttempts; header_names_found_in_translator_output = @($headerNames | Sort-Object -Unique)
    forbidden_terms_checked = $forbidden.Count; validation = $(if ($validation) { [ordered]@{ ok = $validation.ok; failures = @($validation.failures); summary = $validation.summary } } else { [ordered]@{ ok = $false; failures = @("validation did not run") } })
    dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; log = "dialogs.log"; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors); remaining_at_stop = @($dialogs.Remaining) } } else { $null }) }
ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath (Join-Path $WorkDirectory "export-package-receipt.json") -Encoding UTF8
Log "Package status: $status ($(@($placed | Where-Object { $_.Kind -eq 'part' }).Count) parts, $(@($placed | Where-Object { $_.Kind -eq 'assembly' }).Count) assemblies, $(@($script:context).Count) occurrences in context)"
if ($status -notlike "complete*") { exit 1 }
