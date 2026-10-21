<#
.SYNOPSIS
Native Inventor authoring proof: build a part from named parameters (sketch + extrusion driven by
user parameters), save, reopen, edit a parameter, recompute, restore, export STEP, and cross-check
an externally supplied STEP of the same nominal envelope. No GUI interaction.

.DESCRIPTION
Fixture: the Alienware AW2725Q stand-free nominal envelope described by the Linux
parameters.json (mm). Coordinate convention follows that file: origin at the center of the body
front rectangle, +X right, +Y up, +Z toward the viewer; the body is extruded from the XY plane
(Z=0) toward -Z by body_depth. A second, construction-only sketch "ActiveDisplay" holds the
active-display rectangle driven by active_width/active_height/active_center_y.

Steps and checks (recorded in parameter-pilot-session.json):
  1. new part document from the default template, document units set to mm, user parameters
     body_width, body_height, body_depth, active_width, active_height, active_center_y (mm);
  2. sketch "BodyOutline" on the XY work plane, rectangle fully constrained by dimension
     constraints whose expressions reference the parameters (width, height, corner to origin);
  3. extrusion "BodyExtrusion" by expression "body_depth" in the negative direction;
  4. verify extents/volume, save as .ipt, close, reopen, verify parameters and geometry again;
  5. set body_depth to -EditDepthMm, Update(), verify; restore, verify; save; export STEP;
  6. open -LinuxStep (optional) and record its solids/extents/volume for comparison.
Inventor API lengths are cm internally; all reported numbers are converted to mm once.
#>
param(
    [Parameter(Mandatory = $true)][string]$Parameters,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$LinuxStep,
    [string]$ExpectedLinuxStepSha256,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$PartName = "AW2725Q-nominal-envelope-native",
    [double]$EditDepthMm = 80.0,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-param-pilot",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Parameters)) { throw "parameters.json not found: $Parameters" }
$pj = Get-Content -LiteralPath $Parameters -Raw | ConvertFrom-Json
if ($pj.units -ne "mm") { throw "parameters.json units must be mm (got '$($pj.units)')" }
$dim = $pj.dimensions_mm
$P = [ordered]@{ body_width = [double]$dim.body_width; body_height = [double]$dim.body_height; body_depth = [double]$dim.body_depth; active_width = [double]$dim.active_width; active_height = [double]$dim.active_height; active_center_y = [double]$pj.coordinate_system.active_center_y_mm }
if ($LinuxStep) { if (-not (Test-Path -LiteralPath $LinuxStep)) { throw "LinuxStep not found: $LinuxStep" }; $ls = (Get-FileHash -LiteralPath $LinuxStep -Algorithm SHA256).Hash.ToLowerInvariant(); if ($ExpectedLinuxStepSha256 -and $ls -ne $ExpectedLinuxStepSha256.ToLowerInvariant()) { throw "LinuxStep hash $ls differs from expected" } }
New-Item -ItemType Directory -Force -Path $WorkspaceRoot, $OutputDirectory | Out-Null
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path; $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$iptPath = Join-Path $WorkspaceRoot "$PartName.ipt"
$stepOut = Join-Path $OutputDirectory "$PartName.step"
# NB: PowerShell variable names are case-insensitive; never reuse $p here because $P holds the inputs.
foreach ($existing in @($iptPath, $stepOut, (Join-Path $OutputDirectory "parameter-pilot-session.json"), (Join-Path $OutputDirectory "$PartName.export.json"))) { if (Test-Path -LiteralPath $existing) { throw "Refusing to overwrite $existing (use fresh WorkspaceRoot/OutputDirectory)" } }

# Enum values come from the interop assembly (loaded by the helper), not from hand-typed constants:
# DimensionOrientationEnum is kHorizontalDim=19201, kVerticalDim=19202, kAlignedDim=19203 on Inventor 2025.
. (Join-Path $PSScriptRoot "Import-InventorInterop.ps1")
$kPart = [int][Inventor.DocumentTypeEnum]::kPartDocumentObject; $kFileBrowseIOMechanism = [int][Inventor.IOMechanismEnum]::kFileBrowseIOMechanism; $stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
$kMillimeterLengthUnits = [int][Inventor.UnitsTypeEnum]::kMillimeterLengthUnits; $kHorizontalDim = [int][Inventor.DimensionOrientationEnum]::kHorizontalDim; $kVerticalDim = [int][Inventor.DimensionOrientationEnum]::kVerticalDim
$kNegativeExtentDirection = [int][Inventor.PartFeatureExtentDirectionEnum]::kNegativeExtentDirection; $kNewBodyOperation = [int][Inventor.PartFeatureOperationEnum]::kNewBodyOperation
function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-MapName($map, $i) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($i)) }
function Get-MapValue($map, $k) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($k)) }
function Set-MapValue($map, $k, $v) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($k, $v)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
function Approx($a, $b, $tol) { [Math]::Abs([double]$a - [double]$b) -le $tol }
# Named Measure-Envelope: "measure" is a built-in alias (Measure-Object) that would shadow a function called Measure.
function Measure-Envelope($doc) {
    $cd = $doc.ComponentDefinition; $rb = $cd.RangeBox
    $solids = 0; foreach ($b in $cd.SurfaceBodies) { if ($b.IsSolid) { $solids++ } }
    [ordered]@{ surface_bodies = $cd.SurfaceBodies.Count; solid_bodies = $solids
        min_mm = @(($rb.MinPoint.X * 10), ($rb.MinPoint.Y * 10), ($rb.MinPoint.Z * 10)); max_mm = @(($rb.MaxPoint.X * 10), ($rb.MaxPoint.Y * 10), ($rb.MaxPoint.Z * 10))
        extent_mm = @((($rb.MaxPoint.X - $rb.MinPoint.X) * 10), (($rb.MaxPoint.Y - $rb.MinPoint.Y) * 10), (($rb.MaxPoint.Z - $rb.MinPoint.Z) * 10))
        volume_mm3 = $(try { [double]$cd.MassProperties.Volume * 1000 } catch { $null }) }
}
function Params($doc) {
    # Index-based: COM collection enumeration from inside a function proved unreliable here.
    $up = $doc.ComponentDefinition.Parameters.UserParameters; $list = @()
    for ($i = 1; $i -le $up.Count; $i++) { $u = $up.Item($i); $list += [ordered]@{ name = $u.Name; expression = $u.Expression; value_cm = [double]$u.Value; value_mm = ([double]$u.Value * 10); units = $u.Units } }
    return ,$list
}
$session = [ordered]@{ started_at = Utc; host = $env:COMPUTERNAME; user = $env:USERNAME; interactive_desktop = [Environment]::UserInteractive; parameters_source = $Parameters; parameters_sha256 = (Sha $Parameters); source_pdf_sha256 = $pj.source.sha256
    inputs_mm = $P; workspace_root = $WorkspaceRoot; ipt_path = $iptPath; steps = @(); checks = @(); errors = @(); gui_interaction_required = $false
    convention = "Origin at center of body front rectangle; +X right, +Y up, +Z toward viewer; body extruded from the XY plane (Z=0) toward -Z by body_depth; ActiveDisplay sketch is construction geometry on Z=0 centered at (0, active_center_y)." }
function Step($name, $data) {
    # Merge by copying: PowerShell cannot add an OrderedDictionary to another dictionary.
    $rec = [ordered]@{ step = $name; at = Utc }; foreach ($k in @($data.Keys)) { $rec[$k] = $data[$k] }
    $script:session.steps += $rec; Write-Output "[$name] $($data | ConvertTo-Json -Compress -Depth 5)"
}
function Check($name, [bool]$ok, $detail) { $script:session.checks += [ordered]@{ check = $name; passed = $ok; detail = "$detail" }; Write-Output ("  CHECK {0}: {1} {2}" -f $name, $(if ($ok) { "PASS" } else { "FAIL" }), $detail) }
function Check-Envelope($label, $m, $w, $h, $d) {
    Check "$label`_one_solid" ($m.solid_bodies -eq 1) "solids=$($m.solid_bodies)"
    Check "$label`_extent" ((Approx $m.extent_mm[0] $w 1e-3) -and (Approx $m.extent_mm[1] $h 1e-3) -and (Approx $m.extent_mm[2] $d 1e-3)) ("extent_mm=" + (($m.extent_mm | ForEach-Object { [Math]::Round($_, 4) }) -join " x ") + " expected $w x $h x $d")
    Check "$label`_front_plane_z0_body_negative_z" ((Approx $m.max_mm[2] 0 1e-3) -and (Approx $m.min_mm[2] (-$d) 1e-3) -and (Approx $m.min_mm[0] (-$w / 2) 1e-3) -and (Approx $m.min_mm[1] (-$h / 2) 1e-3)) ("min_mm=" + (($m.min_mm | ForEach-Object { [Math]::Round($_, 4) }) -join ",") + " max_mm=" + (($m.max_mm | ForEach-Object { [Math]::Round($_, 4) }) -join ","))
    $expectedVol = $w * $h * $d
    Check "$label`_volume" ($m.volume_mm3 -ne $null -and (Approx $m.volume_mm3 $expectedVol ($expectedVol * 1e-6))) "volume_mm3=$($m.volume_mm3) expected $expectedVol"
}

$before = @(Get-Process -Name Inventor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$app = New-Object -ComObject Inventor.Application
Start-Sleep -Seconds 3
$after = @(Get-Process -Name Inventor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$newPids = @($after | Where-Object { $before -notcontains $_ })
if ($newPids.Count -eq 0) { Write-Output "COM attached to an already running Inventor instance; aborting."; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app); exit 3 }
$session.inventor_pid = $newPids; $session.inventor_version = $app.SoftwareVersion.DisplayVersion; $session.inventor_build = $app.SoftwareVersion.BuildIdentifier
Write-Output "New Inventor instance pid $($newPids -join ',') version $($session.inventor_version) build $($session.inventor_build)"
$dpm = $null; $proj = $null; $previous = $null
try {
    $app.Visible = $false; $app.SilentOperation = $true
    $dpm = $app.DesignProjectManager; $previous = $dpm.ActiveDesignProject.FullFileName
    $ipj = Join-Path $WorkspaceRoot "$ProjectName.ipj"
    if (-not (Test-Path -LiteralPath $ipj)) { Copy-Item -LiteralPath $TemplateProject -Destination $ipj }
    foreach ($dp in $dpm.DesignProjects) { if ($dp.FullFileName -ieq $ipj) { $proj = $dp } }
    if (-not $proj) { $proj = $dpm.DesignProjects.AddExisting($ipj) }
    $proj.Activate($false)
    $tg = $app.TransientGeometry; $to = $app.TransientObjects

    # ---- 1. new part, mm, parameters ----
    $doc = $app.Documents.Add($kPart, $app.FileManager.GetTemplateFile($kPart), $false)
    $doc.UnitsOfMeasure.LengthUnits = $kMillimeterLengthUnits
    $cd = $doc.ComponentDefinition; $up = $cd.Parameters.UserParameters
    $created = @()
    foreach ($pair in @(@("body_width", $P.body_width), @("body_height", $P.body_height), @("body_depth", $P.body_depth), @("active_width", $P.active_width), @("active_height", $P.active_height), @("active_center_y", $P.active_center_y))) {
        $expr = [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0} mm", [double]$pair[1])
        $u = $up.AddByExpression($pair[0], $expr, "mm")
        $created += [ordered]@{ name = $u.Name; expression = $u.Expression; value_cm = [double]$u.Value }
    }
    Step "parameters_created" @{ created = $created; user_parameter_count = $up.Count; parameters = (Params $doc); document_length_units = [int]$doc.UnitsOfMeasure.LengthUnits }
    Check "parameters_present" ($up.Count -eq 6 -and (Params $doc).Count -eq 6) "count=$($up.Count)"

    # ---- 2. body sketch, fully constrained by parameter-driven dimensions ----
    $xy = $cd.WorkPlanes.Item(3)
    $sk = $cd.Sketches.Add($xy); $sk.Name = "BodyOutline"
    # The sketch origin point only exists once the part origin is projected into the sketch.
    $origin = $sk.AddByProjectingEntity($cd.WorkPoints.Item(1))
    $w = $P.body_width / 10.0; $h = $P.body_height / 10.0   # cm for the API
    $lines = $sk.SketchLines.AddAsTwoPointRectangle($tg.CreatePoint2d(-$w / 2, -$h / 2), $tg.CreatePoint2d($w / 2, $h / 2))
    $hl = $null; $vl = $null; $corner = $null
    foreach ($l in $lines) { $a = $l.StartSketchPoint; $b = $l.EndSketchPoint; if ([Math]::Abs($a.Geometry.Y - $b.Geometry.Y) -lt 1e-9) { if (-not $hl) { $hl = $l } } else { if (-not $vl) { $vl = $l } }; foreach ($pt in @($a, $b)) { if ($pt.Geometry.X -gt 0 -and $pt.Geometry.Y -gt 0) { $corner = $pt } } }
    $dims = [ordered]@{}
    $dW = $sk.DimensionConstraints.AddTwoPointDistance($hl.StartSketchPoint, $hl.EndSketchPoint, $kHorizontalDim, $tg.CreatePoint2d(0, -$h / 2 - 3)); $dW.Parameter.Expression = "body_width"; $dims.width = $dW.Parameter.Name
    $dH = $sk.DimensionConstraints.AddTwoPointDistance($vl.StartSketchPoint, $vl.EndSketchPoint, $kVerticalDim, $tg.CreatePoint2d($w / 2 + 3, 0)); $dH.Parameter.Expression = "body_height"; $dims.height = $dH.Parameter.Name
    $posErr = $null
    try { $dX = $sk.DimensionConstraints.AddTwoPointDistance($origin, $corner, $kHorizontalDim, $tg.CreatePoint2d($w / 4, $h / 2 + 3)); $dX.Parameter.Expression = "body_width / 2"; $dims.corner_x = $dX.Parameter.Name
          $dY = $sk.DimensionConstraints.AddTwoPointDistance($origin, $corner, $kVerticalDim, $tg.CreatePoint2d(-$w / 2 - 3, $h / 4)); $dY.Parameter.Expression = "body_height / 2"; $dims.corner_y = $dY.Parameter.Name } catch { $posErr = $_.Exception.Message }
    $doc.Update()
    $fully = $(try { [int]$sk.ConstraintStatus } catch { $null })
    $fullyName = $(try { [Enum]::GetName(("Inventor.ConstraintStatusEnum" -as [type]), $fully) } catch { $null })
    Step "body_sketch" @{ dimensions = $dims; position_dimension_error = $posErr; constraint_status = $fully; constraint_status_name = $fullyName; dimension_constraints = $sk.DimensionConstraints.Count; geometric_constraints = $sk.GeometricConstraints.Count }
    Check "body_sketch_dimensions_parameter_driven" ($dims.Count -ge 2 -and -not $posErr) "dims=$(($dims.Keys) -join ',') err=$posErr"

    # ---- 3. extrusion toward -Z by expression ----
    $prof = $sk.Profiles.AddForSolid()
    $ext = $cd.Features.ExtrudeFeatures.AddByDistanceExtent($prof, "body_depth", $kNegativeExtentDirection, $kNewBodyOperation); $ext.Name = "BodyExtrusion"
    # ---- active display construction sketch ----
    $sk2 = $cd.Sketches.Add($xy); $sk2.Name = "ActiveDisplay"
    $origin2 = $sk2.AddByProjectingEntity($cd.WorkPoints.Item(1))
    $aw = $P.active_width / 10.0; $ah = $P.active_height / 10.0; $cy = $P.active_center_y / 10.0
    $l2 = $sk2.SketchLines.AddAsTwoPointRectangle($tg.CreatePoint2d(-$aw / 2, $cy - $ah / 2), $tg.CreatePoint2d($aw / 2, $cy + $ah / 2))
    $hl2 = $null; $vl2 = $null; $corner2 = $null
    foreach ($l in $l2) { $l.Construction = $true; $a = $l.StartSketchPoint; $b = $l.EndSketchPoint; if ([Math]::Abs($a.Geometry.Y - $b.Geometry.Y) -lt 1e-9) { if (-not $hl2) { $hl2 = $l } } else { if (-not $vl2) { $vl2 = $l } }; foreach ($pt in @($a, $b)) { if ($pt.Geometry.X -gt 0 -and $pt.Geometry.Y -gt ($cy + $ah / 4)) { $corner2 = $pt } } }
    $dims2 = [ordered]@{}; $posErr2 = $null
    try { $e1 = $sk2.DimensionConstraints.AddTwoPointDistance($hl2.StartSketchPoint, $hl2.EndSketchPoint, $kHorizontalDim, $tg.CreatePoint2d(0, $cy - $ah / 2 - 2)); $e1.Parameter.Expression = "active_width"; $dims2.width = $e1.Parameter.Name
          $e2 = $sk2.DimensionConstraints.AddTwoPointDistance($vl2.StartSketchPoint, $vl2.EndSketchPoint, $kVerticalDim, $tg.CreatePoint2d($aw / 2 + 2, $cy)); $e2.Parameter.Expression = "active_height"; $dims2.height = $e2.Parameter.Name
          $e3 = $sk2.DimensionConstraints.AddTwoPointDistance($origin2, $corner2, $kHorizontalDim, $tg.CreatePoint2d($aw / 4, $cy + $ah / 2 + 2)); $e3.Parameter.Expression = "active_width / 2"; $dims2.corner_x = $e3.Parameter.Name
          $e4 = $sk2.DimensionConstraints.AddTwoPointDistance($origin2, $corner2, $kVerticalDim, $tg.CreatePoint2d(-$aw / 2 - 2, $cy / 2)); $e4.Parameter.Expression = "active_center_y + active_height / 2"; $dims2.corner_y = $e4.Parameter.Name } catch { $posErr2 = $_.Exception.Message }
    $doc.Update()
    Step "active_display_sketch" @{ dimensions = $dims2; error = $posErr2; construction = $true }
    Check "active_display_dimensions_parameter_driven" ($dims2.Count -eq 4 -and -not $posErr2) "dims=$(($dims2.Keys) -join ',') err=$posErr2"

    # ---- 4. verify, save, reopen ----
    $m0 = Measure-Envelope $doc; Step "measure_before_save" $m0
    Check-Envelope "built" $m0 $P.body_width $P.body_height $P.body_depth
    $doc.SaveAs($iptPath, $false); $doc.Close($true)
    $sha0 = Sha $iptPath
    Step "saved" @{ ipt = $iptPath; sha256 = $sha0; bytes = (Get-Item -LiteralPath $iptPath).Length }
    $doc = $app.Documents.Open($iptPath, $false)
    $cd = $doc.ComponentDefinition; $up = $cd.Parameters.UserParameters
    $m1 = Measure-Envelope $doc; $pr = Params $doc
    Step "reopened" @{ measure = $m1; parameters = $pr; sketches = @(foreach ($s in $cd.Sketches) { $s.Name }); features = @(foreach ($f in $cd.Features) { $f.Name }) }
    Check-Envelope "reopened" $m1 $P.body_width $P.body_height $P.body_depth
    # @(...) is required: a single matching dictionary's .Count would be its key count, not 1.
    $depthMatches = @($pr | Where-Object { $_.name -eq "body_depth" -and (Approx $_.value_mm $P.body_depth 1e-6) })
    Check "reopened_parameters_intact" ($depthMatches.Count -eq 1 -and $pr.Count -eq 6) "count=$($pr.Count) body_depth_mm=$(($pr | Where-Object { $_.name -eq 'body_depth' } | ForEach-Object { $_.value_mm }) -join ',')"
    Check "reopened_named_sketches_and_feature" (@($cd.Sketches | ForEach-Object Name) -contains "BodyOutline" -and @($cd.Sketches | ForEach-Object Name) -contains "ActiveDisplay" -and @($cd.Features | ForEach-Object Name) -contains "BodyExtrusion") ((@($cd.Sketches | ForEach-Object Name) + @($cd.Features | ForEach-Object Name)) -join ",")

    # ---- 5. edit body_depth, recompute, verify, restore ----
    $up.Item("body_depth").Expression = ("{0} mm" -f $EditDepthMm); $doc.Update()
    $m2 = Measure-Envelope $doc; Step "edited_body_depth" @{ new_expression = $up.Item("body_depth").Expression; measure = $m2 }
    Check-Envelope "edited" $m2 $P.body_width $P.body_height $EditDepthMm
    $up.Item("body_depth").Expression = ("{0} mm" -f $P.body_depth); $doc.Update()
    $m3 = Measure-Envelope $doc; Step "restored_body_depth" @{ expression = $up.Item("body_depth").Expression; measure = $m3 }
    Check-Envelope "restored" $m3 $P.body_width $P.body_height $P.body_depth
    $doc.Save(); $sha1 = Sha $iptPath
    Step "saved_after_restore" @{ sha256 = $sha1; changed_bytes_vs_first_save = ($sha1 -ne $sha0) }

    # ---- export STEP ----
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
    $opts = $to.CreateNameValueMap(); if ($translator.HasSaveCopyAsOptions($doc, $ctx, $opts)) { Set-MapValue $opts "ApplicationProtocolType" 3; if ((Read-Map $opts).Contains("IncludeSketches")) { Set-MapValue $opts "IncludeSketches" $false } }
    $medium = $to.CreateDataMedium(); $medium.FileName = $stepOut
    $translator.SaveCopyAs($doc, $ctx, $opts, $medium)
    $stepSha = Sha $stepOut
    Step "export_step" @{ output = $stepOut; sha256 = $stepSha; bytes = (Get-Item -LiteralPath $stepOut).Length; options = (Read-Map $opts) }
    $doc.Close($true)
    # re-import our own STEP
    $docsBefore = $app.Documents.Count
    $re = $app.Documents.Open($stepOut, $false)
    try { $m4 = Measure-Envelope $re; Step "reimport_own_step" $m4; Check-Envelope "own_step_reimport" $m4 $P.body_width $P.body_height $P.body_depth } finally { while ($app.Documents.Count -gt $docsBefore) { $app.Documents.Item($app.Documents.Count).Close($true) } }

    # ---- 6. Linux STEP cross-check ----
    if ($LinuxStep) {
        $docsBefore = $app.Documents.Count
        $ld = $app.Documents.Open($LinuxStep, $false)
        try { $m5 = Measure-Envelope $ld; Step "linux_step_in_inventor" ([ordered]@{ path = $LinuxStep; sha256 = $ls; measure = $m5 }); Check-Envelope "linux_step" $m5 $P.body_width $P.body_height $P.body_depth } finally { while ($app.Documents.Count -gt $docsBefore) { $app.Documents.Item($app.Documents.Count).Close($true) } }
    }
    $receipt = [ordered]@{ schema_version = 1
        source = [ordered]@{ kind = "native-parameter-fixture"; vault_id = "28"; master_id = "none"; version_id = "none"; path = "local:$iptPath"; parameters_json_sha256 = (Sha $Parameters); source_pdf_sha256 = $pj.source.sha256; ipt_sha256 = $sha1; inputs_mm = $P }
        exporter = [ordered]@{ name = "Autodesk Inventor STEP translator via windows/Invoke-NativeParameterPilot.ps1"; version = "Inventor $($session.inventor_version) build $($session.inventor_build)"; model_state = "[Primary]"; protocol = "AP214"; translator_options = (Read-Map $opts); route = "separate hidden Inventor instance on $env:COMPUTERNAME, interactive desktop session"; exported_at = Utc }
        sha256 = $stepSha; output_bytes = (Get-Item -LiteralPath $stepOut).Length
        validation = [ordered]@{ convention = $session.convention; measured_mm = $m3; not_a_vault_export = $true; not_a_production_part = $true } }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "$PartName.export.json") -Encoding UTF8
} catch {
    $session.errors += $_.Exception.Message; Write-Output "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
} finally {
    try { while ($app.Documents.Count -gt 0) { $app.Documents.Item($app.Documents.Count).Close($true) } } catch { }
    try { if ($dpm -and $previous) { foreach ($dp in $dpm.DesignProjects) { if ($dp.FullFileName -ieq $previous) { $dp.Activate($false) } } }; if ($proj) { $proj.Remove() } } catch { Write-Output "Could not restore project list: $($_.Exception.Message)" }
    try { $app.Quit() } catch { }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
    $session.finished_at = Utc; $session.passed = @($session.checks | Where-Object passed).Count; $session.failed = @($session.checks | Where-Object { -not $_.passed }).Count
    $session | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "parameter-pilot-session.json") -Encoding UTF8
    Write-Output "Session record: $(Join-Path $OutputDirectory 'parameter-pilot-session.json')  checks passed=$($session.passed) failed=$($session.failed) errors=$($session.errors.Count)"
}
if ($session.errors.Count -gt 0 -or $session.failed -gt 0) { exit 1 }
