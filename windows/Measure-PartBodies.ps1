<#
.SYNOPSIS
Per-body measurement of native Inventor parts, standalone STEP export, re-import, and comparison,
including a mass-properties accuracy sweep. Diagnostic for native-vs-STEP volume differences.

.DESCRIPTION
For each -Part (native .ipt from the acquisition mirror), in a separate hidden Inventor instance:
  1. open it (never saved), record units, model state, body list with IsSolid/Visible/face counts,
     per-body volume (SurfaceBody.Volume where callable), document MassProperties volume at every
     MassPropertiesAccuracyEnum value, and pairwise body-overlap volumes via transient Booleans;
  2. export it standalone to STEP (local frame, AP214, no sketches) under -OutputDirectory\assets;
  3. re-import that STEP with Documents.Open and repeat the measurements;
  4. write <name>.part-measure.json and print a comparison.
Nothing is written to the source files. The interactive Inventor session is untouched.
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Part,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Acquisition,
    [int]$ApplicationProtocolType = 3,
    [string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Import-InventorInterop.ps1")
foreach ($p in $Part) { if (-not (Test-Path -LiteralPath $p)) { throw "Part not found: $p" } }
New-Item -ItemType Directory -Force -Path $OutputDirectory, (Join-Path $OutputDirectory "assets") | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$acq = @{}; if ($Acquisition) { foreach ($a in (Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json).files) { $acq[([string]$a.local_path).ToLowerInvariant()] = $a } }
$kFileBrowseIOMechanism = 13059; $stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-MapName($map, $i) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($i)) }
function Get-MapValue($map, $k) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($k)) }
function Set-MapValue($map, $k, $v) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($k, $v)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
function Box($rb) { [ordered]@{ min = @($rb.MinPoint.X, $rb.MinPoint.Y, $rb.MinPoint.Z); max = @($rb.MaxPoint.X, $rb.MaxPoint.Y, $rb.MaxPoint.Z); extent = @(($rb.MaxPoint.X - $rb.MinPoint.X), ($rb.MaxPoint.Y - $rb.MinPoint.Y), ($rb.MaxPoint.Z - $rb.MinPoint.Z)) } }
function Body-Volume($b) {
    # Several call shapes: PowerShell's COM binder is picky about the optional Accuracy argument.
    try { return @{ value = [double]$b.Volume([Type]::Missing); method = "Volume(Type.Missing)" } } catch { }
    try { return @{ value = [double]$b.Volume(0.001); method = "Volume(0.001)" } } catch { }
    try { return @{ value = [double]$b.GetType().InvokeMember("Volume", [Reflection.BindingFlags]::InvokeMethod, $null, $b, @()); method = "InvokeMember Volume()" } } catch { return @{ value = $null; method = "unavailable: $($_.Exception.Message)" } }
}
$accuracyEnum = [Enum]::GetValues([Inventor.MassPropertiesAccuracyEnum]) | ForEach-Object { [ordered]@{ name = $_.ToString(); value = [int]$_ } }

function Measure-Part($doc, $label, $app) {
    $cd = $doc.ComponentDefinition
    $rec = [ordered]@{ label = $label; document = $doc.FullFileName; display_name = $doc.DisplayName; length_units = $lengthUnitNames[[int]$doc.UnitsOfMeasure.LengthUnits]
        model_state = $(try { $cd.ModelStates.ActiveModelState.Name } catch { "n/a" }); range_box_cm = (Box $cd.RangeBox); bodies = @(); mass_properties = @() }
    $mp = $cd.MassProperties
    $rec.mass_properties_default_accuracy = [int]$mp.Accuracy
    foreach ($a in $accuracyEnum) {
        try { $mp.Accuracy = $a.value; $rec.mass_properties += [ordered]@{ accuracy = $a.name; accuracy_value = $a.value; volume_cm3 = [double]$mp.Volume; area_cm2 = [double]$mp.Area } }
        catch { $rec.mass_properties += [ordered]@{ accuracy = $a.name; accuracy_value = $a.value; error = $_.Exception.Message } }
    }
    try { $mp.Accuracy = $rec.mass_properties_default_accuracy } catch { }
    $i = 0; $sum = 0.0; $sumVisible = 0.0; $bodies = @()
    foreach ($b in $cd.SurfaceBodies) {
        $i++; $v = Body-Volume $b
        $isSolid = $false; try { $isSolid = [bool]$b.IsSolid } catch { }
        $br = [ordered]@{ index = $i; name = $b.Name; is_solid = $isSolid; visible = [bool]$b.Visible; faces = $b.Faces.Count; volume_cm3 = $v.value; volume_method = $v.method; range_box_cm = (Box $b.RangeBox) }
        if ($v.value -ne $null) { $sum += $v.value; if ($br.visible) { $sumVisible += $v.value } }
        $bodies += $br; $rec.bodies += $br
    }
    $rec.body_count = $i; $rec.sum_body_volume_cm3 = $sum; $rec.sum_visible_body_volume_cm3 = $sumVisible
    # pairwise overlap via transient Booleans (copies; the document is not modified)
    $overlaps = @(); $tb = $app.TransientBRep
    $list = @(); foreach ($b in $cd.SurfaceBodies) { $list += $b }
    for ($x = 0; $x -lt $list.Count; $x++) { for ($y = $x + 1; $y -lt $list.Count; $y++) {
        try {
            $cx = $tb.Copy($list[$x]); $cy = $tb.Copy($list[$y])
            $tb.DoBoolean($cx, $cy, 50947)   # kBooleanTypeIntersect
            $ov = Body-Volume $cx
            if ($ov.value -ne $null -and $ov.value -gt 1e-9) { $overlaps += [ordered]@{ body_a = $x + 1; body_b = $y + 1; overlap_cm3 = $ov.value } }
        } catch { }
    } }
    $rec.pairwise_overlaps = $overlaps
    $rec.total_overlap_cm3 = ($overlaps | Measure-Object overlap_cm3 -Sum).Sum
    return $rec
}

$before = @(Get-Process -Name Inventor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$app = New-Object -ComObject Inventor.Application
Start-Sleep -Seconds 3
$after = @(Get-Process -Name Inventor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$newPids = @($after | Where-Object { $before -notcontains $_ })
if ($newPids.Count -eq 0) { Write-Output "COM attached to an already running Inventor instance; aborting."; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app); exit 3 }
Write-Output "New Inventor instance pid $($newPids -join ',') version $($app.SoftwareVersion.DisplayVersion) build $($app.SoftwareVersion.BuildIdentifier)"
$dpm = $null; $proj = $null; $previous = $null; $errors = @()
try {
    $app.Visible = $false; $app.SilentOperation = $true
    $dpm = $app.DesignProjectManager; $previous = $dpm.ActiveDesignProject.FullFileName
    $ipj = Join-Path $WorkspaceRoot "$ProjectName.ipj"
    if (-not (Test-Path -LiteralPath $ipj)) { Copy-Item -LiteralPath $TemplateProject -Destination $ipj }
    foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $ipj) { $proj = $p } }
    if (-not $proj) { $proj = $dpm.DesignProjects.AddExisting($ipj) }
    $proj.Activate($false)
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $to = $app.TransientObjects
    foreach ($partPath in $Part) {
        $name = [IO.Path]::GetFileNameWithoutExtension($partPath)
        $outJson = Join-Path $OutputDirectory "$name.part-measure.json"
        $stepOut = Join-Path $OutputDirectory "assets\$name.step"
        if ((Test-Path -LiteralPath $outJson) -or (Test-Path -LiteralPath $stepOut)) { throw "Refusing to overwrite outputs for $name" }
        $nativeSha = Sha $partPath
        Write-Output "Opening native $partPath"
        $doc = $app.Documents.Open($partPath, $false)
        try {
            $native = Measure-Part $doc "native" $app
            $native.sha256 = $nativeSha
            $a = $acq[$partPath.ToLowerInvariant()]
            if ($a) { $native.vault = [ordered]@{ version_id = [string]$a.version_id; master_id = [string]$a.master_id; vault_path = $a.vault_path; acquisition_sha256 = $a.sha256; acquisition_matches = ($a.sha256 -eq $nativeSha) } }
            $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
            $opts = $to.CreateNameValueMap()
            if ($translator.HasSaveCopyAsOptions($doc, $ctx, $opts)) { Set-MapValue $opts "ApplicationProtocolType" $ApplicationProtocolType; if ((Read-Map $opts).Contains("IncludeSketches")) { Set-MapValue $opts "IncludeSketches" $false } }
            $medium = $to.CreateDataMedium(); $medium.FileName = $stepOut
            $translator.SaveCopyAs($doc, $ctx, $opts, $medium)
            $export = [ordered]@{ path = $stepOut; sha256 = (Sha $stepOut); bytes = (Get-Item -LiteralPath $stepOut).Length; options = (Read-Map $opts); protocol = "AP$(@{2='203';3='214';4='203E2';5='242'}[$ApplicationProtocolType])" }
        } finally { $doc.Close($true) }
        Write-Output "Re-importing $stepOut"
        $docsBefore = $app.Documents.Count
        $re = $app.Documents.Open($stepOut, $false)
        try { $reimport = Measure-Part $re "step-reimport" $app } finally { while ($app.Documents.Count -gt $docsBefore) { $app.Documents.Item($app.Documents.Count).Close($true) } }
        $cmp = [ordered]@{ body_count = @($native.body_count, $reimport.body_count); sum_body_volume_cm3 = @($native.sum_body_volume_cm3, $reimport.sum_body_volume_cm3)
            total_overlap_cm3 = @($native.total_overlap_cm3, $reimport.total_overlap_cm3)
            mass_properties_by_accuracy = @(foreach ($m in $native.mass_properties) { $r2 = $reimport.mass_properties | Where-Object { $_.accuracy -eq $m.accuracy } | Select-Object -First 1; [ordered]@{ accuracy = $m.accuracy; native_cm3 = $m.volume_cm3; step_cm3 = $(if ($r2) { $r2.volume_cm3 } else { $null }); delta_cm3 = $(if ($r2 -and $m.volume_cm3 -ne $null -and $r2.volume_cm3 -ne $null) { $r2.volume_cm3 - $m.volume_cm3 } else { $null }) } })
            per_body = @(for ($k = 0; $k -lt [Math]::Max($native.bodies.Count, $reimport.bodies.Count); $k++) { $nb = if ($k -lt $native.bodies.Count) { $native.bodies[$k] } else { $null }; $sb = if ($k -lt $reimport.bodies.Count) { $reimport.bodies[$k] } else { $null }; [ordered]@{ index = $k + 1; native_name = $(if ($nb) { $nb.name }); native_visible = $(if ($nb) { $nb.visible }); native_faces = $(if ($nb) { $nb.faces }); native_volume_cm3 = $(if ($nb) { $nb.volume_cm3 }); native_extent_cm = $(if ($nb) { $nb.range_box_cm.extent }); step_name = $(if ($sb) { $sb.name }); step_faces = $(if ($sb) { $sb.faces }); step_volume_cm3 = $(if ($sb) { $sb.volume_cm3 }); step_extent_cm = $(if ($sb) { $sb.range_box_cm.extent }) } }) }
        $result = [ordered]@{ generated_at = Utc; inventor_version = $app.SoftwareVersion.DisplayVersion; inventor_build = $app.SoftwareVersion.BuildIdentifier; part = $partPath; native = $native; export = $export; reimport = $reimport; comparison = $cmp
            note = "Volumes in cm^3 from SurfaceBody.Volume (per body) and MassProperties.Volume (document) at each MassPropertiesAccuracyEnum value. Overlaps are intersections of transient copies (kBooleanTypeIntersect); the native file is never modified." }
        $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outJson -Encoding UTF8
        Write-Output ("{0}: bodies native={1} step={2}; sum body volume native={3} step={4} cm3; overlap native={5} step={6} cm3; body volume method: {7}" -f $name, $native.body_count, $reimport.body_count, [Math]::Round($native.sum_body_volume_cm3, 6), [Math]::Round($reimport.sum_body_volume_cm3, 6), $native.total_overlap_cm3, $reimport.total_overlap_cm3, $native.bodies[0].volume_method)
        foreach ($m in $cmp.mass_properties_by_accuracy) { Write-Output ("   MassProperties {0,-32} native={1} step={2} delta={3}" -f $m.accuracy, $m.native_cm3, $m.step_cm3, $m.delta_cm3) }
        foreach ($pb in $cmp.per_body) { Write-Output ("   body {0,2}: native {1,-10} vis={2} faces={3,4} vol={4} | step {5,-10} faces={6,4} vol={7}" -f $pb.index, $pb.native_name, $pb.native_visible, $pb.native_faces, $pb.native_volume_cm3, $pb.step_name, $pb.step_faces, $pb.step_volume_cm3) }
        if ($native.pairwise_overlaps.Count -gt 0) { Write-Output "   native overlaps: $(($native.pairwise_overlaps | ForEach-Object { "$($_.body_a)&$($_.body_b)=$([Math]::Round($_.overlap_cm3,6))" }) -join ' ')" }
        if ($reimport.pairwise_overlaps.Count -gt 0) { Write-Output "   step overlaps:   $(($reimport.pairwise_overlaps | ForEach-Object { "$($_.body_a)&$($_.body_b)=$([Math]::Round($_.overlap_cm3,6))" }) -join ' ')" }
    }
} catch {
    $errors += $_.Exception.Message; Write-Output "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
} finally {
    try { while ($app.Documents.Count -gt 0) { $app.Documents.Item($app.Documents.Count).Close($true) } } catch { }
    try { if ($dpm -and $previous) { foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $previous) { $p.Activate($false) } } }; if ($proj) { $proj.Remove() } } catch { Write-Output "Could not restore project list: $($_.Exception.Message)" }
    try { $app.Quit() } catch { }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
}
if ($errors.Count -gt 0) { exit 1 }
