<#
.SYNOPSIS
Read-only dump of what the Inventor API returns for a part's parameters, hole features, thread features, patterns
and sheet-metal data, with a record of every call that fails from PowerShell.

.DESCRIPTION
    & .\windows\Get-PartFeatureDump.ps1 -Part 'DATA\...\PLATE.ipt' -WorkspaceRoot MIRROR `
        -Acquisition acquisition.json -OutputDirectory NEW

Each -Part is a path relative to -WorkspaceRoot (the acquired mirror) and is bound by SHA-256 to its acquisition
record before Inventor starts. Documents are opened in the owned, invisible instance of Inventor-Session.ps1
(dialog watchdog active), read, and closed with SkipSave; every opened file is re-hashed afterwards.

Property names are not guessed: for each object the script takes the property list of its interface from
Autodesk.Inventor.Interop.dll (reflection) and reads every non-indexed property through late binding. Scalars
are recorded as returned (lengths in Inventor's internal centimetres, angles in radians), enum values with their
names, Parameter-valued properties as name / expression / value / units, points in millimetres. A call that
throws is recorded in call-failures.json with the object, the member and the message; nothing is substituted.

Outputs: <part name>.features.json per part (document, parameters, features, hole_features, thread_features,
pattern_features, sheet_metal), feature-dump.json (summary per part), call-failures.json,
feature-dump-receipt.json, probe.log, dialogs.log.
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Part,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$Acquisition,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")

function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Utc { [DateTime]::UtcNow.ToString("o") }
foreach ($f in @($WorkspaceRoot, $Acquisition)) { if (-not (Test-Path -LiteralPath $f)) { throw "Not found: $f" } }
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\')
$interopCandidates = @("$env:ProgramFiles\Autodesk\Inventor 2025\Bin\Public Assemblies\Autodesk.Inventor.Interop.dll", "$env:ProgramFiles\Autodesk\Inventor 2025\Bin\Autodesk.Inventor.Interop.dll")
$interopPath = $interopCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $interopPath) { throw "Autodesk.Inventor.Interop.dll not found in: $($interopCandidates -join '; ')" }
$interop = [Reflection.Assembly]::LoadFrom($interopPath)
$objectTypeEnum = $interop.GetType("Inventor.ObjectTypeEnum")

# ---- bind every part to the acquisition record BEFORE anything is opened ----
$acq = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
if (-not $acq.files) { throw "Acquisition record has no files" }
$cacheRoot = ([string]$acq.cache_root).TrimEnd('\')
$acqByRel = @{}; foreach ($a in $acq.files) { $local = [string]$a.local_path; if ($local.ToLowerInvariant().StartsWith($cacheRoot.ToLowerInvariant())) { $acqByRel[$local.Substring($cacheRoot.Length).TrimStart('\').ToLowerInvariant()] = $a } }
$bound = @()
foreach ($rel in $Part) {
    $relPath = $rel.TrimStart('\'); $full = Join-Path $WorkspaceRoot $relPath
    if (-not (Test-Path -LiteralPath $full)) { throw "Part not found in the workspace: $relPath" }
    $record = $acqByRel[$relPath.ToLowerInvariant()]
    if (-not $record) { throw "Part '$relPath' has no acquisition record; refusing to open it" }
    $hash = Sha $full
    if ($hash -ne ([string]$record.sha256).ToLowerInvariant()) { throw "Part '$relPath' hash $hash does not match its acquisition record $($record.sha256)" }
    $bound += [pscustomobject]@{ relative_path = $relPath; path = $full; sha256 = $hash; master_id = [string]$record.master_id; version_id = [string]$record.version_id; vault_path = [string]$record.vault_path }
}
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$log = Join-Path $OutputDirectory "probe.log"
function Log($s) { $line = "$(Utc) $s"; Add-Content -LiteralPath $log -Value $line; Write-Output $s }

# ---- late-bound reading with a record of every failure ----
$script:callsMade = 0; $script:probesMade = 0; $script:callFailures = New-Object System.Collections.ArrayList; $script:currentPart = ""
$skipAlways = @("Application", "Parent", "AttributeSets", "Faces", "SideFaces", "EndFaces", "SurfaceBodies", "SurfaceBody", "RangeBox", "Appearance", "FeatureDimensions", "Parameters", "Participants", "OwnedBy",
    "Dependents", "DrivenBy", "CustomPropertyFormat", "ExpressionList", "Tolerance", "StartEdge", "ThreadedFace", "Sketch", "TapInfo", "Extent", "PlacementDefinition", "HoleCenterPoints", "ClearanceInfo", "ThreadInfo", "ParentFeatures")
function Read-Member($Object, [string]$Member, [string]$Context, [switch]$Quiet) {
    # -Quiet is for PROBES whose failure is an answer, not an API failure (does this object have a Type property?);
    # they are counted in probesMade and never listed as failed calls.
    if ($Quiet) { $script:probesMade++ } else { $script:callsMade++ }
    try { return ,($Object.GetType().InvokeMember($Member, [Reflection.BindingFlags]::GetProperty, $null, $Object, $null)) }
    catch {
        if (-not $Quiet) {
            $message = $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message })
            [void]$script:callFailures.Add([ordered]@{ part = $script:currentPart; object = $Context; member = $Member; error = $message })
        }
        return $null
    }
}
function Get-TypeName($Object, [string]$Context) {
    # The ObjectTypeEnum name of a COM object ("kHoleFeatureObject"), the .NET type name of anything else, or $null
    # for a COM object without a Type property (transient geometry: Point, Vector, UnitVector have none).
    if ($null -eq $Object) { return $null }
    if (-not [Runtime.InteropServices.Marshal]::IsComObject($Object)) { return $Object.GetType().Name }
    $value = Read-Member $Object "Type" $Context -Quiet
    if ($null -eq $value) { return $null }
    $name = [Enum]::GetName($objectTypeEnum, [int]$value)
    if ($name) { return $name }; return "ObjectTypeEnum $([int]$value)"
}
function Get-InterfaceName([string]$TypeName) { if ($TypeName -match '^k(.+)Object$') { return $Matches[1] }; return $null }
function Get-Coordinates($Point, [string]$Context, [double]$Scale, [switch]$Planar) {
    # X, Y (and Z unless -Planar: a Point2d has no Z) multiplied by Scale.
    $x = Read-Member $Point "X" $Context; $y = Read-Member $Point "Y" $Context
    if ($null -eq $x -or $null -eq $y) { return $null }
    if ($Planar) { return @(([double]$x * $Scale), ([double]$y * $Scale)) }
    $z = Read-Member $Point "Z" $Context
    if ($null -eq $z) { return $null }
    return @(([double]$x * $Scale), ([double]$y * $Scale), ([double]$z * $Scale))
}
function Get-ParameterBrief($Parameter, [string]$Context) {
    if ($null -eq $Parameter) { return $null }
    [ordered]@{ name = Read-Member $Parameter "Name" $Context; expression = Read-Member $Parameter "Expression" $Context; value = Read-Member $Parameter "Value" $Context; units = Read-Member $Parameter "Units" $Context }
}
function Convert-Value($Value, $PropertyType, [string]$Context) {
    if ($null -eq $Value) { return $null }
    if ($PropertyType -and $PropertyType.IsEnum) { $name = [Enum]::GetName($PropertyType, [int]$Value); return [ordered]@{ value = [int]$Value; name = $name } }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [double] -or $Value -is [single] -or $Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [DateTime]) { return $Value.ToString("o") }
    if ([Runtime.InteropServices.Marshal]::IsComObject($Value)) {
        # Transient geometry is recognised from the interface's declared property type: these objects have no Type property.
        if ($PropertyType -and $PropertyType.Name -match '^(Point|Vector|UnitVector)$') { return [ordered]@{ object = $PropertyType.Name; xyz = (Get-Coordinates $Value $Context 1.0) } }
        if ($PropertyType -and $PropertyType.Name -match '^(Point2d|Vector2d|UnitVector2d)$') { return [ordered]@{ object = $PropertyType.Name; xy = (Get-Coordinates $Value $Context 1.0 -Planar) } }
        $typeName = Get-TypeName $Value $Context
        if ($null -eq $typeName) {
            $x = Read-Member $Value "X" $Context -Quiet; $y = Read-Member $Value "Y" $Context -Quiet; $z = Read-Member $Value "Z" $Context -Quiet
            if ($null -ne $x -and $null -ne $y -and $null -ne $z) { return [ordered]@{ object = "transient geometry (no Type property; read as X, Y, Z)"; xyz = @(([double]$x), ([double]$y), ([double]$z)) } }
            return "<COM object without a Type property>"
        }
        if ($typeName -match 'Parameter') { return Get-ParameterBrief $Value $Context }
        if ($typeName -match 'ObjectsEnumerator|ObjectCollection') {
            $items = @(); $count = Read-Member $Value "Count" $Context
            for ($i = 1; $i -le [int]$count; $i++) { $item = $null; try { $item = $Value.Item($i) } catch { [void]$script:callFailures.Add([ordered]@{ part = $script:currentPart; object = $Context; member = "Item($i)"; error = $_.Exception.Message }) }; $items += ,(Convert-Value $item $null "$Context[$i]") }
            return $items
        }
        return "<$typeName>"
    }
    return "<$($Value.GetType().Name)>"
}
function Read-Scalars($Object, [string]$InterfaceName, [string]$Context, [string[]]$Only) {
    # Every non-indexed property of the interface (or only the listed ones), read late-bound.
    $result = [ordered]@{}
    if ($null -eq $Object) { return $result }
    $type = $interop.GetType("Inventor.$InterfaceName")
    if (-not $type) { $result["<error>"] = "interface Inventor.$InterfaceName not found in the interop assembly"; return $result }
    foreach ($property in ($type.GetProperties() | Where-Object { $_.GetIndexParameters().Count -eq 0 } | Sort-Object Name)) {
        if ($Only) { if ($Only -notcontains $property.Name) { continue } } elseif ($skipAlways -contains $property.Name) { continue }
        $value = Read-Member $Object $property.Name "$Context"
        $result[$property.Name] = Convert-Value $value $property.PropertyType "$Context.$($property.Name)"
    }
    return $result
}
function Get-Items($Collection, [string]$Context) {
    $list = @(); if ($null -eq $Collection) { return ,$list }
    $count = Read-Member $Collection "Count" $Context
    for ($i = 1; $i -le [int]$count; $i++) { try { $list += $Collection.Item($i) } catch { [void]$script:callFailures.Add([ordered]@{ part = $script:currentPart; object = $Context; member = "Item($i)"; error = $_.Exception.Message }) } }
    return ,$list
}
function Get-HoleCentres($Hole, [string]$Context) {
    $centres = @()
    foreach ($item in (Get-Items (Read-Member $Hole "HoleCenterPoints" $Context) "$Context.HoleCenterPoints")) {
        $typeName = Get-TypeName $item "$Context.HoleCenterPoints item"
        $entry = [ordered]@{ object = $typeName; point_mm = $null; sketch = $null; sketch_point_2d = $null }
        if ($typeName -eq "kSketchPointObject") {
            $geometry3d = Read-Member $item "Geometry3d" "$Context.SketchPoint"
            if ($geometry3d) { $entry.point_mm = Get-Coordinates $geometry3d "$Context.SketchPoint.Geometry3d" 10.0 }
            $geometry2d = Read-Member $item "Geometry" "$Context.SketchPoint"
            if ($geometry2d) { $entry.sketch_point_2d = Get-Coordinates $geometry2d "$Context.SketchPoint.Geometry" 10.0 -Planar }
            $sketch = Read-Member $item "Parent" "$Context.SketchPoint"
            if ($sketch) { $entry.sketch = Read-Member $sketch "Name" "$Context.SketchPoint.Parent" }
        } elseif ($typeName -eq "kWorkPointObject") {
            $point = Read-Member $item "Point" "$Context.WorkPoint"
            if ($point) { $entry.point_mm = Get-Coordinates $point "$Context.WorkPoint.Point" 10.0 }
        } elseif ($typeName -eq "kPointObject") { $entry.point_mm = Get-Coordinates $item "$Context.Point" 10.0 }
        $centres += $entry
    }
    return ,$centres
}

$kPart = 12290
$sheetMetalSubType = "{9C464203-9BAE-11D3-8BAD-0060B0CE6BB4}"
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
$session = Start-IsolatedInventor
$app = $session.App
Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build)); interop $interopPath"
$project = $null; $errors = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null; $summaries = @()
$watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $OutputDirectory "dialogs.log")
try {
    $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); created file: $($project.CreatedFile))"
    foreach ($b in $bound) {
        $script:currentPart = $b.relative_path
        $failuresBefore = $script:callFailures.Count; $callsBefore = $script:callsMade
        $doc = $app.Documents.Open($b.path, $false)
        try {
            if ([int]$doc.DocumentType -ne $kPart) { throw "'$($b.relative_path)' is not a part document" }
            $cd = $doc.ComponentDefinition
            $uom = $doc.UnitsOfMeasure
            $definitionType = Get-TypeName $cd "ComponentDefinition"
            $subType = [string]$doc.SubType
            $dump = [ordered]@{ schema_version = 1; generated_at = (Utc); part = $b.relative_path; master_id = $b.master_id; version_id = $b.version_id; vault_path = $b.vault_path; native_sha256 = $b.sha256
                units_note = "values are as the API returns them: lengths in centimetres, angles in radians; 'value_text' is the same value formatted by UnitsOfMeasure in the parameter's own units; points are converted to millimetres"
                document = [ordered]@{ sub_type = $subType; is_sheet_metal = ($subType -ieq $sheetMetalSubType); component_definition_type = $definitionType
                    length_units = $lengthUnitNames[[int]$uom.LengthUnits]; model_states = $(try { [int]$cd.ModelStates.Count } catch { $null }); dirty_after_open = [bool]$doc.Dirty } }
            # ---- parameters ----
            $parameters = @()
            $allParameters = Read-Member $cd "Parameters" "ComponentDefinition"
            foreach ($parameter in (Get-Items $allParameters "Parameters")) {
                $entry = Read-Scalars $parameter "Parameter" "Parameter" $null
                $kind = $entry["ParameterType"]
                $interfaceName = $(if ($kind -and $kind.name -eq "kModelParameter") { "ModelParameter" } else { $null })
                if ($interfaceName) { foreach ($extra in @("BuiltIn", "Renamed")) { $entry[$extra] = Convert-Value (Read-Member $parameter $extra "ModelParameter") $null "ModelParameter.$extra" } }
                $text = $null
                try { $script:callsMade++; $text = [string]$uom.GetStringFromValue([double]$entry["Value"], [string]$entry["Units"]) } catch { [void]$script:callFailures.Add([ordered]@{ part = $script:currentPart; object = "UnitsOfMeasure"; member = "GetStringFromValue(Parameter '$($entry["Name"])')"; error = $_.Exception.Message }) }
                $entry["value_text"] = $text
                $parameters += $entry
            }
            $dump.parameter_collections = [ordered]@{}
            foreach ($collection in @("ModelParameters", "ReferenceParameters", "UserParameters", "ParameterTables", "DerivedParameterTables", "CustomParameterGroups")) { $c = Read-Member $allParameters $collection "Parameters"; $dump.parameter_collections[$collection] = $(if ($c) { Read-Member $c "Count" "Parameters.$collection" } else { $null }) }
            $dump.parameters = $parameters
            # ---- all features, in browser order ----
            $features = Read-Member $cd "Features" "ComponentDefinition"
            $featureList = @(); $byType = [ordered]@{}; $patterns = @()
            foreach ($feature in (Get-Items $features "Features")) {
                $typeName = Get-TypeName $feature "Feature"
                $name = Read-Member $feature "Name" "Feature"
                $featureList += [ordered]@{ name = $name; type = $typeName; suppressed = Read-Member $feature "Suppressed" "Feature '$name'"; health = Convert-Value (Read-Member $feature "HealthStatus" "Feature '$name'") ($interop.GetType("Inventor.HealthStatusEnum")) "Feature.HealthStatus" }
                if (-not $byType.Contains($typeName)) { $byType[$typeName] = 0 }; $byType[$typeName]++
                if ($typeName -match 'Pattern|Mirror') {
                    $interfaceName = Get-InterfaceName $typeName
                    $pattern = [ordered]@{ name = $name; type = $typeName; properties = (Read-Scalars $feature $interfaceName "$interfaceName '$name'" $null); parent_features = @() }
                    foreach ($parent in (Get-Items (Read-Member $feature "ParentFeatures" "$interfaceName '$name'") "$interfaceName '$name'.ParentFeatures")) { $pattern.parent_features += [ordered]@{ name = Read-Member $parent "Name" "ParentFeature"; type = Get-TypeName $parent "ParentFeature" } }
                    $patterns += $pattern
                }
            }
            $dump.features_by_type = $byType; $dump.features = $featureList; $dump.pattern_features = $patterns
            # ---- hole features ----
            $holes = @()
            foreach ($hole in (Get-Items (Read-Member $features "HoleFeatures" "Features") "HoleFeatures")) {
                $name = Read-Member $hole "Name" "HoleFeature"; $context = "HoleFeature '$name'"
                $entry = [ordered]@{ name = $name; properties = (Read-Scalars $hole "HoleFeature" $context $null); tap_info = $null; clearance_info = $null; extent = $null; placement = $null; centres = $null; sketch = $null }
                if ($entry.properties["Tapped"] -eq $true) {
                    $tap = Read-Member $hole "TapInfo" $context
                    $tapType = Get-TypeName $tap "$context.TapInfo"; $tapInterface = Get-InterfaceName $tapType
                    if (-not $tapInterface -or -not $interop.GetType("Inventor.$tapInterface")) { $tapInterface = "HoleTapInfo" }
                    $entry.tap_info = [ordered]@{ object = $tapType; interface = $tapInterface; properties = (Read-Scalars $tap $tapInterface "$context.TapInfo" $null) }
                }
                if ($entry.properties["IsClearanceHole"] -eq $true) { $entry.clearance_info = Read-Scalars (Read-Member $hole "ClearanceInfo" $context) "HoleClearanceInfo" "$context.ClearanceInfo" $null }
                $extent = Read-Member $hole "Extent" $context
                if ($extent) { $extentType = Get-TypeName $extent "$context.Extent"; $extentInterface = Get-InterfaceName $extentType; $entry.extent = [ordered]@{ object = $extentType; properties = $(if ($extentInterface) { Read-Scalars $extent $extentInterface "$context.Extent" $null } else { $null }) } }
                $placement = Read-Member $hole "PlacementDefinition" $context
                if ($placement) { $placementType = Get-TypeName $placement "$context.PlacementDefinition"; $placementInterface = Get-InterfaceName $placementType; $entry.placement = [ordered]@{ object = $placementType; properties = $(if ($placementInterface) { Read-Scalars $placement $placementInterface "$context.PlacementDefinition" $null } else { $null }) } }
                $entry.centres = Get-HoleCentres $hole $context
                $sketch = Read-Member $hole "Sketch" $context
                if ($sketch) { $entry.sketch = Read-Member $sketch "Name" "$context.Sketch" }
                $holes += $entry
            }
            $dump.hole_features = $holes
            # ---- thread features ----
            $threads = @()
            foreach ($thread in (Get-Items (Read-Member $features "ThreadFeatures" "Features") "ThreadFeatures")) {
                $name = Read-Member $thread "Name" "ThreadFeature"; $context = "ThreadFeature '$name'"
                $entry = [ordered]@{ name = $name; properties = (Read-Scalars $thread "ThreadFeature" $context $null); thread_info = $null; threaded_faces = $null }
                $info = Read-Member $thread "ThreadInfo" $context
                if ($info) { $infoType = Get-TypeName $info "$context.ThreadInfo"; $infoInterface = Get-InterfaceName $infoType; if (-not $infoInterface -or -not $interop.GetType("Inventor.$infoInterface")) { $infoInterface = "ThreadInfo" }; $entry.thread_info = [ordered]@{ object = $infoType; interface = $infoInterface; properties = (Read-Scalars $info $infoInterface "$context.ThreadInfo" $null) } }
                $faces = Read-Member $thread "ThreadedFace" $context
                if ($faces) { $entry.threaded_faces = Read-Member $faces "Count" "$context.ThreadedFace" }
                $threads += $entry
            }
            $dump.thread_features = $threads
            # ---- sheet metal ----
            $dump.sheet_metal = $null
            if ($dump.document.is_sheet_metal) {
                $dump.sheet_metal = Read-Scalars $cd "SheetMetalComponentDefinition" "SheetMetalComponentDefinition" @("Thickness", "BendRadius", "BendReliefDepth", "BendReliefWidth", "CornerReliefSize", "GapSize", "MinimumRemnant", "TransitionRadius", "HasFlatPattern", "UseSheetMetalStyleMaterial", "UseSheetMetalStyleThickness", "UseSheetMetalStyleUnfoldMethod")
                $style = Read-Member $cd "ActiveSheetMetalStyle" "SheetMetalComponentDefinition"
                if ($style) { $dump.sheet_metal["ActiveSheetMetalStyle"] = Read-Member $style "Name" "SheetMetalStyle" }
            }
            $dump.document.dirty_before_close = [bool]$doc.Dirty
            $dump.calls = [ordered]@{ made = ($script:callsMade - $callsBefore); failed = ($script:callFailures.Count - $failuresBefore) }
            $base = [IO.Path]::GetFileNameWithoutExtension($b.relative_path)
            ConvertTo-Json -InputObject $dump -Depth 14 | Set-Content -LiteralPath (Join-Path $OutputDirectory "$base.features.json") -Encoding UTF8
            $tapped = @($holes | Where-Object { $_.properties["Tapped"] -eq $true })
            $summary = [ordered]@{ part = $b.relative_path; file = "$base.features.json"; is_sheet_metal = $dump.document.is_sheet_metal; length_units = $dump.document.length_units; parameters = $parameters.Count
                features = $featureList.Count; features_by_type = $byType; hole_features = $holes.Count; tapped_hole_features = $tapped.Count; hole_centres = (@($holes | ForEach-Object { @($_.centres).Count }) | Measure-Object -Sum).Sum
                thread_designations = @($tapped | ForEach-Object { $_.tap_info.properties["ThreadDesignation"] } | Sort-Object -Unique); thread_features = $threads.Count; pattern_features = $patterns.Count
                calls_made = $dump.calls.made; calls_failed = $dump.calls.failed; dirty_before_close = $dump.document.dirty_before_close }
            $summaries += $summary
            Log ("{0,-48} sheetmetal={1} parameters={2} features={3} holes={4} (tapped {5}: {6}) threads={7} patterns={8} calls={9} failed={10}" -f $base, $summary.is_sheet_metal, $summary.parameters, $summary.features, $summary.hole_features, $summary.tapped_hole_features, ($summary.thread_designations -join ', '), $summary.thread_features, $summary.pattern_features, $summary.calls_made, $summary.calls_failed)
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
$integrity = @()
foreach ($b in $bound) { $after = Sha $b.path; $integrity += [ordered]@{ relative_path = $b.relative_path; acquired_sha256 = $b.sha256; sha256_after = $after; unchanged = ($after -eq $b.sha256) }; if ($after -ne $b.sha256) { $errors += "the mirror file '$($b.relative_path)' changed on disk" } }
$failureList = @($script:callFailures)
$byMember = @($failureList | Group-Object { "$($_.object -replace " '.*?'", '') :: $($_.member -replace '\(.*\)', '()')" } | Sort-Object Count -Descending | ForEach-Object { [ordered]@{ call = $_.Name; count = $_.Count; example_error = $_.Group[0].error } })
ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; generated_at = (Utc); calls_made = $script:callsMade; calls_failed = $failureList.Count; probes_made = $script:probesMade
        note = "calls are late-bound property reads of members the interop interface declares; a failure is the exception the read raised. Probes (does this object have a Type property; X, Y, Z of an untyped object) are counted apart and never listed: transient geometry objects (Point, Vector, UnitVector) have no Type property"
        by_call = $byMember; failures = $failureList }) -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "call-failures.json") -Encoding UTF8
ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; generated_at = (Utc); parts = $summaries }) -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "feature-dump.json") -Encoding UTF8
$status = $(if ($errors.Count -eq 0 -and $shutdown.Succeeded -and $summaries.Count -eq $bound.Count) { Resolve-RunStatus -Status "complete" -Dialogs $dialogs } else { "FAILED" })
$receipt = [ordered]@{ schema_version = 1; generated_at = (Utc); probe = "windows/Get-PartFeatureDump.ps1"; status = $status; errors = $errors
    scope = "read-only feature dump; documents are never saved; opened files re-hashed after the run"; host = $env:COMPUTERNAME; inventor = "$($session.Version) build $($session.Build)"; interop_assembly = $interopPath
    workspace_root = $WorkspaceRoot; acquisition_record = $Acquisition; calls_made = $script:callsMade; calls_failed = $failureList.Count; probes_made = $script:probesMade
    session = [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; started_at = $session.StartedAt.ToString("o"); shutdown = [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; observed = $shutdown.Observed; failed_required = @($shutdown.FailedRequired); notes = @($shutdown.Notes) } }
    project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; entry_removed_by_run = $shutdown.ProjectEntryRemoved; previous_restored = $shutdown.PreviousProjectRestored } } else { $null })
    parts = $summaries; integrity = $integrity
    dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; log = "dialogs.log"; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors) } } else { $null }) }
ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "feature-dump-receipt.json") -Encoding UTF8
Log "Feature dump status: $status ($($summaries.Count) of $($bound.Count) part(s); $($script:callsMade) calls, $($failureList.Count) failed)"
if ($status -notlike "complete*") { exit 1 }
