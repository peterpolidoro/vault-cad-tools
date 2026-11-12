<#
.SYNOPSIS
PROBE: export part documents to STEP in one owned Inventor instance, in several variants (application protocol,
translator options, how the document is opened, the camera of its view, properties changed in memory only), and
record everything that identifies each file.

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
  open         how the part document is reached (default 'invisible'):
               'invisible'   Documents.Open(path, OpenVisible = false): the document has no view;
               'visible'     Documents.Open(path, OpenVisible = true): the document has a view;
               'referenced'  the document is taken from AllReferencedDocuments of -ViaAssembly, opened invisibly
                             and bound with Confirm-AcquiredInputs: exactly how Export-PartAssets.ps1 reaches a part.
               Passes run in the order referenced, invisible, visible; within a pass, variants run in the order given.
  camera       only with open = 'visible': change the camera of the first view before the export and leave it
               changed for later variants: @{ rotate_degrees = 40; zoom_factor = 0.5; orientation = 10759 }
               (rotation about the up vector through the target; zoom scales the view extents). Never saved.
  options      translator options to set after the exporter's own (name -> value), e.g. @{ Author = 'x' }
  properties   iProperties to set IN MEMORY before the export and restore after it, never saved:
               @{ 'Inventor Summary Information|Author' = 'MARKER' }. Requires -WorkOnCopies.
  output_name  fixed output file name (e.g. 'part.step'); the file then goes to <label>\<part name>\<output_name>
Translator options are set as Export-PartAssets.ps1 sets them (ApplicationProtocolType, IncludeSketches false
when present); nothing else is touched unless a variant says so.

-ViaAssembly REL and -Inventory dependency-inventory.json are needed for open = 'referenced'. The receipt then
also holds a view census: how many views the assembly and its referenced documents have when opened that way.
-WorkOnCopies copies each bound part into <OutputDirectory>\workspace (hash-verified) and opens the copy, with a
project file created there and removed again; the mirror is then not opened at all. Documents are never saved:
they are closed with SkipSave, and every opened file is re-hashed afterwards (a changed hash fails the run).
-ApplicationVisible shows the owned Inventor window for the run (only if a view cannot be had otherwise).

Per export the receipt records: size, SHA-256, the data-section SHA-256 (from DATA to the end), the FILE_SCHEMA
statement and protocol, every FILE_NAME field, the header lines, the detected length unit, the counts of
MANIFOLD_SOLID_BREP, BREP_WITH_VOIDS, INVISIBILITY, CAMERA_MODEL_D3, VIEW_VOLUME, PLANAR_BOX and DRAUGHTING_MODEL
entities (the log line's solids are the first two together), the
translator options before and after the export (including "Translation Result"), the number of views, the camera
before and after a camera change, and the document's dirty flag at each step. Per part it records Inventor's
body counts and the summary, document-summary and design-tracking iProperties (scalar values).
Outputs: step-export-probe.json, probe.log, dialogs.log, the STEP files.
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Part,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$Acquisition,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [object[]]$Variant = @(@{ label = "ap214"; protocol = 3 }),
    [switch]$WorkOnCopies,
    [string]$ViaAssembly,
    [string]$Inventory,
    [switch]$ApplicationVisible,
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
$openModes = @("referenced", "invisible", "visible")
$cameraKeys = @("rotate_degrees", "zoom_factor", "orientation")
$variants = @()
foreach ($v in $Variant) {
    if ($v -isnot [System.Collections.IDictionary]) { throw "Each -Variant must be a hashtable" }
    $label = [string]$v["label"]; if ($label -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Variant label '$label' is not a plain name" }
    $protocol = $(if ($v.Contains("protocol")) { [int]$v["protocol"] } else { 3 }); if (-not $protocolNames.ContainsKey($protocol)) { throw "Variant '$label': protocol $protocol is not one of 2, 3, 4, 5" }
    $open = $(if ($v.Contains("open")) { [string]$v["open"] } else { "invisible" }); if ($openModes -notcontains $open) { throw "Variant '$label': open '$open' is not one of $($openModes -join ', ')" }
    $outputName = $(if ($v.Contains("output_name")) { [string]$v["output_name"] } else { $null })
    if ($outputName -and $outputName -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]*\.(step|stp)$') { throw "Variant '$label': output_name '$outputName' is not a plain STEP file name" }
    $options = [ordered]@{}; if ($v.Contains("options") -and $v["options"]) { foreach ($k in $v["options"].Keys) { $options[[string]$k] = $v["options"][$k] } }
    $properties = [ordered]@{}; if ($v.Contains("properties") -and $v["properties"]) { foreach ($k in $v["properties"].Keys) { if (([string]$k).Split('|').Count -ne 2) { throw "Variant '$label': property key '$k' must be 'Property set|Property name'" }; $properties[[string]$k] = [string]$v["properties"][$k] } }
    $cameraChange = $null
    if ($v.Contains("camera") -and $v["camera"]) {
        if ($open -ne "visible") { throw "Variant '$label': a camera change needs open = 'visible'" }
        $cameraChange = [ordered]@{}; foreach ($k in $v["camera"].Keys) { if ($cameraKeys -notcontains [string]$k) { throw "Variant '$label': camera key '$k' is not one of $($cameraKeys -join ', ')" }; $cameraChange[[string]$k] = [double]$v["camera"][$k] }
    }
    if ($properties.Count -gt 0 -and -not $WorkOnCopies) { throw "Variant '$label' sets properties in memory; that is only allowed with -WorkOnCopies" }
    if ($open -eq "referenced") {
        if (-not $ViaAssembly -or -not $Inventory) { throw "Variant '$label': open = 'referenced' needs -ViaAssembly and -Inventory" }
        if ($WorkOnCopies) { throw "Variant '$label': open = 'referenced' cannot be combined with -WorkOnCopies" }
        if ($properties.Count -gt 0) { throw "Variant '$label': properties cannot be changed on a referenced document" }
    }
    if (@($variants | Where-Object { $_.label -eq $label }).Count) { throw "Duplicate variant label '$label'" }
    $variants += [pscustomobject]@{ label = $label; protocol = $protocol; open = $open; camera = $cameraChange; output_name = $outputName; options = $options; properties = $properties }
}
$modes = @($openModes | Where-Object { $name = $_; @($variants | Where-Object { $_.open -eq $name }).Count -gt 0 })
# ---- bind every part to the acquisition record BEFORE anything is opened ----
$acq = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
if (-not $acq.files) { throw "Acquisition record has no files" }
$invJson = $null; $assemblyPath = $null
if ($modes -contains "referenced") {
    if (-not (Test-Path -LiteralPath $Inventory)) { throw "Inventory record not found: $Inventory" }
    $invJson = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json
    if (-not $invJson.files) { throw "Inventory record has no files" }
    $assemblyPath = Join-Path $WorkspaceRoot $ViaAssembly.TrimStart('\')
    if (-not (Test-Path -LiteralPath $assemblyPath)) { throw "Assembly not found in the workspace: $ViaAssembly" }
}
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
$countedEntities = @("MANIFOLD_SOLID_BREP", "BREP_WITH_VOIDS", "INVISIBILITY", "CAMERA_MODEL_D3", "VIEW_VOLUME", "PLANAR_BOX", "DRAUGHTING_MODEL")
function Get-MapName($map, $i) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($i)) }
function Get-MapValue($map, $k) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($k)) }
function Set-MapValue($map, $k, $v) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($k, $v)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
function Read-MapTypes($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $value = Get-MapValue $map $n; $r[$n] = $(if ($null -eq $value) { "null" } else { $value.GetType().Name }) }; return $r }
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
function Read-Bodies($definition) {
    # Inventor's own body counts, as Export-PartAssets.ps1 takes them.
    $surface = 0; $solid = 0; $visibleSolid = 0
    foreach ($body in $definition.SurfaceBodies) { $surface++; if ($body.IsSolid) { $solid++; if ($body.Visible) { $visibleSolid++ } } }
    [ordered]@{ surface_bodies = $surface; solid_bodies = $solid; visible_solid_bodies = $visibleSolid }
}
function Get-Xyz($geometry) { @(([double]$geometry.X), ([double]$geometry.Y), ([double]$geometry.Z)) }
function Read-Camera($view) {
    $cam = $view.Camera
    $state = [ordered]@{ eye = (Get-Xyz $cam.Eye); target = (Get-Xyz $cam.Target); up = (Get-Xyz $cam.UpVector); perspective = [bool]$cam.Perspective; perspective_angle = $null
        view_orientation_type = [int]$cam.ViewOrientationType; extents = $null; extents_error = $null }
    try { $state.perspective_angle = [double]$cam.PerspectiveAngle } catch { }
    try { $width = 0.0; $height = 0.0; $cam.GetExtents([ref]$width, [ref]$height); $state.extents = @(([double]$width), ([double]$height)) } catch { $state.extents_error = $_.Exception.Message }
    return $state
}
function Set-CameraChange($application, $view, $change) {
    # Rotates the eye about the up vector through the target, scales the view extents, or sets a named orientation.
    $cam = $view.Camera; $applied = [ordered]@{}
    if ($change.Contains("orientation")) { $cam.ViewOrientationType = [int]$change["orientation"]; $applied["orientation"] = [int]$change["orientation"] }
    if ($change.Contains("rotate_degrees")) {
        $eye = Get-Xyz $cam.Eye; $target = Get-Xyz $cam.Target; $up = Get-Xyz $cam.UpVector
        $angle = [double]$change["rotate_degrees"] * [Math]::PI / 180.0
        $norm = [Math]::Sqrt(($up[0] * $up[0]) + ($up[1] * $up[1]) + ($up[2] * $up[2]))
        $axis = @(($up[0] / $norm), ($up[1] / $norm), ($up[2] / $norm))
        $arm = @(($eye[0] - $target[0]), ($eye[1] - $target[1]), ($eye[2] - $target[2]))
        $cross = @((($axis[1] * $arm[2]) - ($axis[2] * $arm[1])), (($axis[2] * $arm[0]) - ($axis[0] * $arm[2])), (($axis[0] * $arm[1]) - ($axis[1] * $arm[0])))
        $dot = ($axis[0] * $arm[0]) + ($axis[1] * $arm[1]) + ($axis[2] * $arm[2])
        $cosine = [Math]::Cos($angle); $sine = [Math]::Sin($angle)
        $rotated = @(); for ($index = 0; $index -lt 3; $index++) { $rotated += (($arm[$index] * $cosine) + ($cross[$index] * $sine) + ($axis[$index] * $dot * (1 - $cosine))) }
        $cam.Eye = $application.TransientGeometry.CreatePoint(($target[0] + $rotated[0]), ($target[1] + $rotated[1]), ($target[2] + $rotated[2]))
        $applied["rotate_degrees"] = [double]$change["rotate_degrees"]
    }
    if ($change.Contains("zoom_factor")) {
        $factor = [double]$change["zoom_factor"]
        try { $width = 0.0; $height = 0.0; $cam.GetExtents([ref]$width, [ref]$height); $cam.SetExtents(([double]$width * $factor), ([double]$height * $factor)); $applied["zoom_factor"] = $factor; $applied["extents_set"] = @(([double]$width * $factor), ([double]$height * $factor)) } catch { $applied["zoom_error"] = $_.Exception.Message }
    }
    $cam.ApplyWithoutTransition()
    try { $view.Update() } catch { $applied["update_error"] = $_.Exception.Message }
    return $applied
}
function Invoke-VariantExport($doc, $b, $v, $views) {
    # One export of one document in one variant; returns the receipt entry (with its own 'errors' list).
    $entryErrors = @()
    $base = [IO.Path]::GetFileNameWithoutExtension($b.relative_path)
    $outDir = Join-Path $OutputDirectory $v.label; if ($v.output_name) { $outDir = Join-Path $outDir $base }
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $outPath = Join-Path $outDir $(if ($v.output_name) { $v.output_name } else { "$base.step" })
    if (Test-Path -LiteralPath $outPath) { throw "Output already exists: $outPath" }
    $cameraBefore = $null; $cameraAfter = $null; $cameraApplied = $null; $dirtyBeforeCamera = $null; $dirtyAfterCamera = $null
    if ($v.open -eq "visible" -and $views -gt 0) {
        $view = $doc.Views.Item(1)
        try { $cameraBefore = Read-Camera $view } catch { $entryErrors += "camera read: $($_.Exception.Message)" }
        if ($v.camera) {
            $dirtyBeforeCamera = [bool]$doc.Dirty
            try { $cameraApplied = Set-CameraChange $app $view $v.camera; $cameraAfter = Read-Camera $view } catch { $entryErrors += "camera change: $($_.Exception.Message)" }
            $dirtyAfterCamera = [bool]$doc.Dirty
        }
    } elseif ($v.camera) { $entryErrors += "camera change requested but the document has no view" }
    $restore = [ordered]@{}; $propertyErrors = @()
    foreach ($key in $v.properties.Keys) {
        $setName = $key.Split('|')[0]; $propertyName = $key.Split('|')[1]
        try { $property = $doc.PropertySets.Item($setName).Item($propertyName); $restore[$key] = $property.Value; $property.Value = $v.properties[$key] } catch { $propertyErrors += "$key`: $($_.Exception.Message)" }
    }
    $dirtyBefore = [bool]$doc.Dirty
    $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
    $opts = $to.CreateNameValueMap()
    $hasOptions = [bool]$translator.HasSaveCopyAsOptions($doc, $ctx, $opts)
    $reported = $(if ($hasOptions) { Read-Map $opts } else { $null }); $reportedTypes = $(if ($hasOptions) { Read-MapTypes $opts } else { $null })
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
    $entry = [ordered]@{ variant = $v.label; open = $v.open; part = $b.relative_path; master_id = $b.master_id; version_id = $b.version_id; protocol_requested = $protocolNames[$v.protocol]; application_protocol_type = $v.protocol
        file = $outPath.Substring($OutputDirectory.Length + 1) -replace '\\', '/'; export_started = $started; export_finished = $finished; export_error = $exportError
        views = $views; camera_change_requested = $v.camera; camera_change_applied = $cameraApplied; camera_before = $cameraBefore; camera_after = $cameraAfter
        dirty_before_camera_change = $dirtyBeforeCamera; dirty_after_camera_change = $dirtyAfterCamera
        options_set = $v.options; option_errors = $optionErrors; properties_set_in_memory = $v.properties; properties_previous = $restore; property_errors = $propertyErrors
        translator_options_reported = $reported; translator_option_types = $reportedTypes; translator_options_before = $optionsBefore; translator_options_after = (Read-Map $opts)
        dirty_before_export = $dirtyBefore; dirty_after_export = $dirtyAfter }
    if (-not $exportError -and (Test-Path -LiteralPath $outPath)) {
        $info = Get-StepFileInfo -Path $outPath
        $unit = Get-StepLengthUnit $outPath
        $entry.bytes = $info.bytes; $entry.sha256 = $info.sha256; $entry.data_sha256 = $info.data_sha256; $entry.header_sha256 = $info.header_sha256; $entry.data_offset = $info.data_offset
        $entry.file_schema = $info.file_schema_statement; $entry.protocol_in_file = $info.header.protocol; $entry.header = $info.header; $entry.header_lines = $info.header_lines
        $entry.step_length_unit = $unit.unit; $entry.step_length_unit_detection = $unit
        $entry.entity_counts = Get-StepEntityCounts -Path $outPath -Type $countedEntities
        if ($info.header.protocol -ne $protocolNames[$v.protocol]) { $entryErrors += "the file's schema says $($info.header.protocol), requested $($protocolNames[$v.protocol])" }
        if (-not $unit.ok) { $entryErrors += "length unit rejected: $($unit.reason)" }
        $logLine = ("{0,-22} {1,-10} {2,-56} {3,9} bytes {4} data={5} solids={6} invisibility={7} camera={8} views={9} result={10}" -f $v.label, $v.open, $base, $info.bytes, $info.header.protocol, $info.data_sha256.Substring(0, 12), ($entry.entity_counts["MANIFOLD_SOLID_BREP"] + $entry.entity_counts["BREP_WITH_VOIDS"]), $entry.entity_counts["INVISIBILITY"], $entry.entity_counts["CAMERA_MODEL_D3"], $views, $entry.translator_options_after["Translation Result"])
    } else { $entryErrors += "export failed: $exportError"; $logLine = "EXPORT FAILED $($v.label) $base : $exportError" }
    if ($propertyErrors.Count) { $entryErrors += $propertyErrors }
    if ($optionErrors.Count) { $entryErrors += "option errors: $($optionErrors -join '; ')" }
    $entry.errors = $entryErrors
    # The log line travels in the entry: this function's output is captured by the caller, so it must emit
    # exactly one object (a Write-Output here would be returned alongside the entry).
    $entry.log_line = $logLine
    return $entry
}
function Add-Export($entry, $b, $v) {
    # Logs the entry's line, files the entry and its errors. Called from the script scope only.
    Log $entry.log_line; $entry.Remove("log_line")
    $script:exports += $entry
    foreach ($message in @($entry.errors)) { $script:errors += "$($b.relative_path) [$($v.label)]: $message" }
}

$session = Start-IsolatedInventor
$app = $session.App
if ($ApplicationVisible) { $app.Visible = $true }
Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build)); started $($session.StartedAt.ToString('o')); application visible: $([bool]$app.Visible)"
$project = $null; $errors = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null
$watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $OutputDirectory "dialogs.log")
$exports = @(); $defaultOptions = $null; $defaultOptionTypes = $null; $viewCensus = $null; $assemblyInputs = @()
$partRecords = [ordered]@{}; foreach ($b in $bound) { $partRecords[$b.relative_path] = [ordered]@{ relative_path = $b.relative_path; master_id = $b.master_id; version_id = $b.version_id; vault_path = $b.vault_path; native_sha256 = $b.sha256
        opened_from = $(if ($WorkOnCopies) { "copy in the output directory" } else { "acquired mirror" }); length_units = $null; bodies = $null; properties = $null; opens = @() } }
function Add-PartFacts($doc, $b) {
    $partRecord = $partRecords[$b.relative_path]
    if ($null -eq $partRecord.bodies) { $partRecord.length_units = $lengthUnitNames[[int]$doc.UnitsOfMeasure.LengthUnits]; $partRecord.bodies = Read-Bodies $doc.ComponentDefinition; $partRecord.properties = Read-PropertySets $doc }
}
try {
    $project = Use-TemporaryProject $app (Join-Path $projectRoot "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); created file: $($project.CreatedFile))"
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $translatorInfo = [ordered]@{ display_name = [string]$translator.DisplayName; client_id = $stepTranslatorClsid; activated = [bool]$translator.Activated }
    $to = $app.TransientObjects
    # ---- pass 1: documents reached as the snapshot exporter reaches them ----
    if ($modes -contains "referenced") {
        $asm = $app.Documents.Open($assemblyPath, $false)
        try {
            $assemblyInputs = Confirm-AcquiredInputs $asm $acq $invJson
            $referenced = @{}; $withViews = 0
            foreach ($d in @($asm.AllReferencedDocuments)) { $referenced[([string]$d.FullFileName).ToLowerInvariant()] = $d; if ([int]$d.Views.Count -gt 0) { $withViews++ } }
            $viewCensus = [ordered]@{ assembly = $ViaAssembly; opened = "Documents.Open(path, OpenVisible = false) in the owned instance, as Export-PartAssets.ps1 opens the root"; application_visible = [bool]$app.Visible
                assembly_views = [int]$asm.Views.Count; referenced_documents = $referenced.Count; referenced_documents_with_views = $withViews; inputs_bound = @($assemblyInputs).Count; assembly_dirty_after_open = [bool]$asm.Dirty }
            Log "Assembly opened invisibly: $($viewCensus.assembly_views) view(s); $($referenced.Count) referenced documents, $withViews with a view; $(@($assemblyInputs).Count) inputs bound"
            foreach ($b in $bound) {
                $doc = $referenced[$b.source_path.ToLowerInvariant()]
                if (-not $doc) { throw "'$($b.relative_path)' is not a referenced document of $ViaAssembly" }
                if ([int]$doc.DocumentType -ne $kPart) { throw "'$($b.relative_path)' is not a part document" }
                Add-PartFacts $doc $b
                $views = [int]$doc.Views.Count
                $partRecords[$b.relative_path].opens += [ordered]@{ mode = "referenced"; views = $views; dirty_after_open = [bool]$doc.Dirty }
                foreach ($v in @($variants | Where-Object { $_.open -eq "referenced" })) { Add-Export (Invoke-VariantExport $doc $b $v $views) $b $v }
            }
            $viewCensus.assembly_dirty_before_close = [bool]$asm.Dirty
        } finally { try { $asm.Close($true) } catch { $errors += "close assembly: $($_.Exception.Message)" } }
    }
    # ---- passes 2 and 3: the part document opened by itself, without and with a view ----
    foreach ($mode in @("invisible", "visible")) {
        if ($modes -notcontains $mode) { continue }
        foreach ($b in $bound) {
            $doc = $app.Documents.Open($b.open_path, ($mode -eq "visible"))
            try {
                if ([int]$doc.DocumentType -ne $kPart) { throw "'$($b.relative_path)' is not a part document" }
                Add-PartFacts $doc $b
                $views = [int]$doc.Views.Count; $viewAdded = $false; $viewError = $null
                if ($mode -eq "visible" -and $views -eq 0) { try { [void]$doc.Views.Add(); $viewAdded = $true; $views = [int]$doc.Views.Count } catch { $viewError = $_.Exception.Message } }
                $openRecord = [ordered]@{ mode = $mode; views = $views; view_added_by_probe = $viewAdded; view_error = $viewError; dirty_after_open = [bool]$doc.Dirty; dirty_before_close = $null }
                if ($null -eq $defaultOptions) { $ctx0 = $to.CreateTranslationContext(); $ctx0.Type = $kFileBrowseIOMechanism; $opts0 = $to.CreateNameValueMap(); if ($translator.HasSaveCopyAsOptions($doc, $ctx0, $opts0)) { $defaultOptions = Read-Map $opts0; $defaultOptionTypes = Read-MapTypes $opts0 } }
                foreach ($v in @($variants | Where-Object { $_.open -eq $mode })) { Add-Export (Invoke-VariantExport $doc $b $v $views) $b $v }
                $openRecord.dirty_before_close = [bool]$doc.Dirty
                $partRecords[$b.relative_path].opens += $openRecord
            } finally { try { $doc.Close($true) } catch { $errors += "close '$($b.relative_path)': $($_.Exception.Message)" } }
        }
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
$assemblyChanged = @()
foreach ($bindingRecord in @($assemblyInputs)) { if ((Sha $bindingRecord.path) -ne [string]$bindingRecord.acquisition_sha256) { $assemblyChanged += [string]$bindingRecord.path; $errors += "the mirror file '$($bindingRecord.path)' changed on disk" } }
$status = $(if ($errors.Count -eq 0 -and $shutdown.Succeeded -and $exports.Count -eq ($bound.Count * $variants.Count)) { Resolve-RunStatus -Status "complete" -Dialogs $dialogs } else { "FAILED" })
$receipt = [ordered]@{ schema_version = 2; generated_at = (Utc); probe = "windows/Invoke-StepExportProbe.ps1"; status = $status; errors = $errors
    scope = "read-only STEP export probe; documents are never saved; opened files re-hashed after the run"
    host = $env:COMPUTERNAME; inventor = "$($session.Version) build $($session.Build)"; workspace_root = $WorkspaceRoot; acquisition_record = $Acquisition; work_on_copies = [bool]$WorkOnCopies
    application_visible = [bool]$ApplicationVisible; passes = $modes; via_assembly = $ViaAssembly; view_census = $viewCensus
    session = [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; started_at = $session.StartedAt.ToString("o"); pre_existing_inventor_pids = $session.PreExistingPids
        shutdown = [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; observed = $shutdown.Observed; failed_required = @($shutdown.FailedRequired); notes = @($shutdown.Notes) } }
    project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; created_file = $project.CreatedFile; entry_removed_by_run = $shutdown.ProjectEntryRemoved; previous_restored = $shutdown.PreviousProjectRestored } } else { $null })
    translator = $translatorInfo; translator_default_options = $defaultOptions; translator_default_option_types = $defaultOptionTypes
    variants = @($variants | ForEach-Object { [ordered]@{ label = $_.label; protocol = $protocolNames[$_.protocol]; open = $_.open; camera = $_.camera; output_name = $_.output_name; options = $_.options; properties = $_.properties } })
    parts = @($partRecords.Values); exports = $exports; integrity = $integrity
    assembly_inputs = [ordered]@{ bound = @($assemblyInputs).Count; changed_on_disk = $assemblyChanged }
    dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; log = "dialogs.log"; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors) } } else { $null }) }
ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "step-export-probe.json") -Encoding UTF8
Log "Probe status: $status ($($exports.Count) export(s) of $($bound.Count) part(s) in $($variants.Count) variant(s); passes: $($modes -join ', '))"
if ($status -notlike "complete*") { exit 1 }
