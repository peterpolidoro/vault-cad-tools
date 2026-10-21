<#
.SYNOPSIS
Command-line pilot: STEP -> converted native IPT -> new IAM with named, placed occurrences ->
move / constrain -> assembly STEP, using a separate hidden Inventor instance. No GUI interaction.

.DESCRIPTION
Proves the API-driven native authoring path on a licensed Inventor installation in the
logged-in user's desktop session. Steps and the evidence each writes:

  1. Isolated Inventor COM instance (aborts if COM attached to an already running one);
     the user's interactive session and active project are untouched (temporary single-user
     project activated in the new instance, restored on exit).
  2. Import -StepInput as a CONVERTED native part (Documents.Open; no reference to the STEP
     remains), save it as <WorkspaceRoot>\parts\<name>.ipt, close, reopen and record bodies
     (SurfaceBodies, IsSolid), volume, range box, referenced files (expected 0).
  3. Create <WorkspaceRoot>\assemblies\pilot.iam, place two occurrences of that IPT with
     explicit transforms and stable names (PANEL_A grounded, PANEL_B free), save, reopen and
     verify the transforms; move PANEL_B (unconstrained), update, save, reopen, verify;
     the IPT bytes are hashed before/after and must not change.
  4. Add a Flush constraint between the XZ work planes (offset -ConstraintOffsetCm), then
     request an incompatible translation for PANEL_B; report requested vs achieved after
     Update(); the constraint must still exist and be unsuppressed. Then a compatible move.
  5. Export pilot.iam to STEP (AP214, no sketches), write placement-report.json,
     pilot-assembly.export.json (local-fixture receipt; not a Vault export) and
     pilot-session.json with every step's outcome.

Retries are non-destructive: an existing output file is never overwritten; an occurrence is
only added if no occurrence with that name exists; the IPT is reused only if its hash matches
the recorded one. Inventor API lengths are centimeters; the report also gives inches and mm.
#>
param(
    [Parameter(Mandatory = $true)][string]$StepInput,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$ExpectedStepSha256,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$PartName = "PANEL_FIXTURE",
    [double]$ConstraintOffsetCm = 2.54,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-pilot",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Import-InventorInterop.ps1")   # C# helper for ByRef COM calls (geometry proxies)
if (-not (Test-Path -LiteralPath $StepInput)) { throw "STEP input not found: $StepInput" }
$StepInput = (Resolve-Path -LiteralPath $StepInput).Path
$stepSha = (Get-FileHash -LiteralPath $StepInput -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedStepSha256 -and ($stepSha -ne $ExpectedStepSha256.ToLowerInvariant())) { throw "STEP input hash $stepSha does not match expected $ExpectedStepSha256" }
# Guard first, before anything is created: an existing workspace must belong to this STEP input.
$statePath = Join-Path $WorkspaceRoot "pilot-state.json"
$state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
if ($state -and $state.step_input_sha256 -ne $stepSha) {
    throw "Pilot workspace belongs to a different STEP input; use a fresh WorkspaceRoot"
}
New-Item -ItemType Directory -Force -Path $WorkspaceRoot, "$WorkspaceRoot\parts", "$WorkspaceRoot\assemblies", $OutputDirectory | Out-Null
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$iptPath = Join-Path $WorkspaceRoot "parts\$PartName.ipt"
$iamPath = Join-Path $WorkspaceRoot "assemblies\pilot.iam"
$statePath = Join-Path $WorkspaceRoot "pilot-state.json"
$stepOut = Join-Path $OutputDirectory "pilot-assembly.step"
foreach ($p in @($stepOut, (Join-Path $OutputDirectory "placement-report.json"), (Join-Path $OutputDirectory "pilot-assembly.export.json"), (Join-Path $OutputDirectory "pilot-session.json"))) {
    if (Test-Path -LiteralPath $p) { throw "Refusing to overwrite existing output $p (use a fresh OutputDirectory)" }
}

$kPart = 12290; $kAssembly = 12291; $kFileBrowseIOMechanism = 13059
$stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-MapName($map, $i) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($i)) }
function Get-MapValue($map, $k) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($k)) }
function Set-MapValue($map, $k, $v) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($k, $v)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
# COM methods with ByRef (out) parameters need reflection with ParameterModifier from PowerShell.
function Invoke-ByRef($target, [string]$method, [object[]]$arguments, [int[]]$byRefIndexes) {
    $mods = New-Object System.Reflection.ParameterModifier($arguments.Count)
    foreach ($i in $byRefIndexes) { $mods[$i] = $true }
    $r = $target.GetType().InvokeMember($method, [Reflection.BindingFlags]::InvokeMethod, $null, $target, $arguments, @($mods), $null, $null)
    return @{ result = $r; arguments = $arguments }
}
function Matrix-Cells($m) { $rows = @(); for ($r = 1; $r -le 4; $r++) { $row = @(); for ($c = 1; $c -le 4; $c++) { $row += [double]$m.GetType().InvokeMember("Cell", [Reflection.BindingFlags]::GetProperty, $null, $m, @($r, $c)) }; $rows += ,$row }; return $rows }
function Translation-Record($m) { $t = $m.Translation; [ordered]@{ cm = @($t.X, $t.Y, $t.Z); in = @(($t.X / 2.54), ($t.Y / 2.54), ($t.Z / 2.54)); mm = @(($t.X * 10), ($t.Y * 10), ($t.Z * 10)); matrix = (Matrix-Cells $m) } }
function Occurrence-Record($occ) {
    [ordered]@{ name = $occ.Name; grounded = $occ.Grounded; suppressed = $occ.Suppressed; visible = $occ.Visible
        document = $occ.ReferencedDocumentDescriptor.FullDocumentName; definition_document_type = $occ.DefinitionDocumentType
        transformation = (Translation-Record $occ.Transformation) }
}
function Body-Record($doc) {
    $cd = $doc.ComponentDefinition; $bodies = @(); $solids = 0
    foreach ($b in $cd.SurfaceBodies) { $isSolid = [bool]$b.IsSolid; if ($isSolid) { $solids++ }; $bodies += [ordered]@{ name = $b.Name; is_solid = $isSolid; visible = $b.Visible; faces = $b.Faces.Count } }
    # SurfaceBody.Volume() is not callable through PowerShell's COM binder; MassProperties.Volume (cm^3) is.
    $vol = $null; try { $vol = [double]$cd.MassProperties.Volume } catch { }
    $rb = $cd.RangeBox
    [ordered]@{ surface_body_count = $cd.SurfaceBodies.Count; solid_body_count = $solids; total_volume_cm3 = $vol; total_volume_mm3 = $(if ($vol -ne $null) { $vol * 1000 } else { $null })
        range_box_cm = [ordered]@{ min = @($rb.MinPoint.X, $rb.MinPoint.Y, $rb.MinPoint.Z); max = @($rb.MaxPoint.X, $rb.MaxPoint.Y, $rb.MaxPoint.Z) }
        extent_cm = @(($rb.MaxPoint.X - $rb.MinPoint.X), ($rb.MaxPoint.Y - $rb.MinPoint.Y), ($rb.MaxPoint.Z - $rb.MinPoint.Z)); bodies = $bodies }
}
function Approx($a, $b, $tol = 1e-6) { [Math]::Abs([double]$a - [double]$b) -le $tol }
function Vec-Approx($v, $x, $y, $z) { (Approx $v[0] $x) -and (Approx $v[1] $y) -and (Approx $v[2] $z) }

$session = [ordered]@{ started_at = Utc; host = $env:COMPUTERNAME; user = $env:USERNAME; interactive_desktop = [Environment]::UserInteractive
    windows_session_id = (Get-Process -Id $PID).SessionId; step_input = $StepInput; step_input_sha256 = $stepSha; workspace_root = $WorkspaceRoot
    ipt_path = $iptPath; iam_path = $iamPath; steps = @(); checks = @(); errors = @(); gui_interaction_required = $false }
function Step($name, $data) { $script:session.steps += ([ordered]@{ step = $name; at = Utc } + $data); Write-Output "[$name] $($data | ConvertTo-Json -Compress -Depth 4)" }
function Check($name, [bool]$ok, $detail) { $script:session.checks += [ordered]@{ check = $name; passed = $ok; detail = $detail }; Write-Output ("  CHECK {0}: {1} {2}" -f $name, $(if ($ok) { "PASS" } else { "FAIL" }), $detail) }

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
    $app.Visible = $false
    $app.SilentOperation = $true
    $dpm = $app.DesignProjectManager
    $previous = $dpm.ActiveDesignProject.FullFileName
    $ipj = Join-Path $WorkspaceRoot "$ProjectName.ipj"
    if (-not (Test-Path -LiteralPath $ipj)) { Copy-Item -LiteralPath $TemplateProject -Destination $ipj }
    foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $ipj) { $proj = $p } }
    if (-not $proj) { $proj = $dpm.DesignProjects.AddExisting($ipj) }
    $proj.Activate($false)
    $session.project_file = $dpm.ActiveDesignProject.FullFileName
    Step "project" @{ active = $session.project_file; previous = $previous }
    $tg = $app.TransientGeometry; $to = $app.TransientObjects

    # ---- Step 2: STEP -> converted IPT ----
    if ((Test-Path -LiteralPath $iptPath) -and $state -and ($state.ipt_sha256 -eq (Sha $iptPath))) {
        Step "import" @{ reused_existing_ipt = $true; ipt_sha256 = $state.ipt_sha256 }
    } else {
        if (Test-Path -LiteralPath $iptPath) { throw "Existing $iptPath does not match the recorded pilot state; refusing to overwrite" }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $doc = $app.Documents.Open($StepInput, $false)
        try {
            $imp = [ordered]@{ document_type = $doc.DocumentType; is_part = ($doc.DocumentType -eq $kPart); import_seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
                referenced_file_descriptors = $doc.File.ReferencedFileDescriptors.Count; full_file_name_after_open = $doc.FullFileName }
            try { $imp.anycad_imported_components = $doc.ComponentDefinition.ReferenceComponents.ImportedComponents.Count } catch { $imp.anycad_imported_components = "n/a" }
            $imp.converted_not_referenced = ($imp.referenced_file_descriptors -eq 0 -and ($imp.anycad_imported_components -eq 0 -or $imp.anycad_imported_components -eq "n/a"))
            $imp.length_units = $lengthUnitNames[[int]$doc.UnitsOfMeasure.LengthUnits]
            $imp.bodies_before_save = Body-Record $doc
            $doc.SaveAs($iptPath, $false)   # SaveCopyAs=False: the open document becomes the saved IPT
            $imp.full_file_name_after_saveas = $doc.FullFileName
        } finally { $doc.Close($true) }
        $imp.ipt_sha256 = Sha $iptPath; $imp.ipt_bytes = (Get-Item -LiteralPath $iptPath).Length
        Step "import" $imp
        Check "import_converted_not_referenced" $imp.converted_not_referenced "referenced descriptors=$($imp.referenced_file_descriptors) anycad=$($imp.anycad_imported_components)"
        Check "import_saved_as_ipt" ($imp.full_file_name_after_saveas -ieq $iptPath) $imp.full_file_name_after_saveas
    }
    $iptSha0 = Sha $iptPath
    # reopen the saved IPT
    $doc = $app.Documents.Open($iptPath, $false)
    try {
        $re = Body-Record $doc
        $re.referenced_file_descriptors = $doc.File.ReferencedFileDescriptors.Count; $re.length_units = $lengthUnitNames[[int]$doc.UnitsOfMeasure.LengthUnits]
        try { $re.model_state = $doc.ComponentDefinition.ModelStates.ActiveModelState.Name } catch { }
        Step "ipt_reopen" $re
        Check "ipt_reopen_one_solid" ($re.solid_body_count -eq 1) "solids=$($re.solid_body_count) bodies=$($re.surface_body_count)"
        Check "ipt_reopen_no_external_references" ($re.referenced_file_descriptors -eq 0) "descriptors=$($re.referenced_file_descriptors)"
        Check "ipt_reopen_extent_47x0.125x47in" ((Approx ($re.extent_cm[0] / 2.54) 47 1e-3) -and (Approx ($re.extent_cm[1] / 2.54) 0.125 1e-3) -and (Approx ($re.extent_cm[2] / 2.54) 47 1e-3)) ("extent_in=" + (($re.extent_cm | ForEach-Object { [Math]::Round($_ / 2.54, 4) }) -join " x "))
    } finally { $doc.Close($true) }
    Check "ipt_bytes_unchanged_after_reopen" ((Sha $iptPath) -eq $iptSha0) $iptSha0
    [ordered]@{ ipt_sha256 = $iptSha0; step_input_sha256 = $stepSha; created_at = Utc } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

    # ---- Step 3: assembly with two named occurrences ----
    $placeA = @(0.0, 0.0, 0.0); $placeB = @(0.0, 2.54, 0.0)            # B stacked 1 in above A along Y (panel thickness axis)
    $moveB1 = @(5.08, 7.62, 0.0)                                      # unconstrained move: +2 in X, Y to 3 in
    if (Test-Path -LiteralPath $iamPath) { $asm = $app.Documents.Open($iamPath, $false); Step "iam_open_existing" @{ path = $iamPath } }
    else { $asm = $app.Documents.Add($kAssembly, $app.FileManager.GetTemplateFile($kAssembly), $false); $asm.SaveAs($iamPath, $false); Step "iam_create" @{ path = $asm.FullFileName; length_units = $lengthUnitNames[[int]$asm.UnitsOfMeasure.LengthUnits] } }
    try {
        $cd = $asm.ComponentDefinition
        function Ensure-Occurrence($name, $xyz, [bool]$ground) {
            foreach ($o in $cd.Occurrences) { if ($o.Name -eq $name) { return @{ occurrence = $o; added = $false } } }
            $m = $tg.CreateMatrix(); $m.SetTranslation($tg.CreateVector($xyz[0], $xyz[1], $xyz[2]))
            $o = $cd.Occurrences.Add($iptPath, $m); $o.Name = $name; $o.Grounded = $ground
            return @{ occurrence = $o; added = $true }
        }
        $ra = Ensure-Occurrence "PANEL_A" $placeA $true
        $rb = Ensure-Occurrence "PANEL_B" $placeB $false
        $occA = $ra.occurrence; $occB = $rb.occurrence
        $asm.Update(); $asm.Save()
        Step "iam_place" @{ occurrence_count = $cd.Occurrences.Count; added_A = $ra.added; added_B = $rb.added; A = (Occurrence-Record $occA); B = (Occurrence-Record $occB) }
        Check "iam_two_occurrences_no_duplicates" ($cd.Occurrences.Count -eq 2) "count=$($cd.Occurrences.Count) (rerun reuses existing named occurrences instead of adding)"
        Check "iam_A_grounded_B_free" ($occA.Grounded -and -not $occB.Grounded) "A.grounded=$($occA.Grounded) B.grounded=$($occB.Grounded)"
        if ($rb.added) { Check "iam_B_initial_placement" (Vec-Approx (Translation-Record $occB.Transformation).cm $placeB[0] $placeB[1] $placeB[2]) ((Translation-Record $occB.Transformation).cm -join ",") }
        else { Step "iam_place_reused" @{ note = "PANEL_B already existed; initial placement check skipped on rerun"; B = (Occurrence-Record $occB) } }
    } finally { $asm.Close($true) }
    Check "ipt_bytes_unchanged_after_placement" ((Sha $iptPath) -eq $iptSha0) (Sha $iptPath)

    # reopen and verify placements, then move B (unconstrained)
    $asm = $app.Documents.Open($iamPath, $false)
    try {
        $cd = $asm.ComponentDefinition; $occA = $cd.Occurrences.ItemByName("PANEL_A"); $occB = $cd.Occurrences.ItemByName("PANEL_B")
        $reopen = @{ A = (Occurrence-Record $occA); B = (Occurrence-Record $occB); resolved_references = $asm.AllReferencedDocuments.Count; unresolved = @() }
        foreach ($fd in $asm.File.ReferencedFileDescriptors) { if ($fd.ReferenceMissing) { $reopen.unresolved += $fd.FullFileName } }
        Step "iam_reopen_after_place" $reopen
        if ($rb.added) { Check "iam_reopen_placements_persist" ((Vec-Approx $reopen.A.transformation.cm 0 0 0) -and (Vec-Approx $reopen.B.transformation.cm $placeB[0] $placeB[1] $placeB[2])) "A=$($reopen.A.transformation.cm -join ',') B=$($reopen.B.transformation.cm -join ',')" }
        Check "iam_reopen_references_resolved" ($reopen.unresolved.Count -eq 0 -and $reopen.resolved_references -eq 1) "resolved=$($reopen.resolved_references) unresolved=$($reopen.unresolved.Count)"
        # On a rerun the flush constraint from the previous run already exists; then the Y request
        # cannot be honoured and the expected result is the constrained position, not the request.
        $preExistingConstraint = ($cd.Constraints.Count -gt 0)
        $expectedB = if ($preExistingConstraint) { @($moveB1[0], $ConstraintOffsetCm, $moveB1[2]) } else { $moveB1 }
        $m = $tg.CreateMatrix(); $m.SetTranslation($tg.CreateVector($moveB1[0], $moveB1[1], $moveB1[2]))
        $occB.Transformation = $m
        $asm.Update()
        $afterMove = @{ requested_cm = $moveB1; expected_cm = $expectedB; pre_existing_constraints = $cd.Constraints.Count; A = (Occurrence-Record $occA); B = (Occurrence-Record $occB) }
        $asm.Save()
        Step "iam_move_B_unconstrained" $afterMove
        Check "move_B_achieved_or_constrained" (Vec-Approx $afterMove.B.transformation.cm $expectedB[0] $expectedB[1] $expectedB[2]) "achieved=$($afterMove.B.transformation.cm -join ',') expected=$($expectedB -join ',') pre-existing constraints=$($cd.Constraints.Count)"
        Check "move_A_unchanged" (Vec-Approx $afterMove.A.transformation.cm 0 0 0) ($afterMove.A.transformation.cm -join ",")
    } finally { $asm.Close($true) }
    Check "ipt_bytes_unchanged_after_move" ((Sha $iptPath) -eq $iptSha0) (Sha $iptPath)

    # reopen after the move, then constraint test
    $asm = $app.Documents.Open($iamPath, $false)
    try {
        $cd = $asm.ComponentDefinition; $occA = $cd.Occurrences.ItemByName("PANEL_A"); $occB = $cd.Occurrences.ItemByName("PANEL_B")
        $r2 = @{ A = (Occurrence-Record $occA); B = (Occurrence-Record $occB) }
        Step "iam_reopen_after_move" $r2
        Check "iam_reopen_move_persisted" (Vec-Approx $r2.B.transformation.cm $expectedB[0] $expectedB[1] $expectedB[2]) "B=$($r2.B.transformation.cm -join ',') expected=$($expectedB -join ',')"

        # ---- Step 4: flush constraint on XZ work planes, then an incompatible move ----
        function Plane-Proxy($occ) {
            $wp = $null; try { $wp = $occ.Definition.WorkPlanes.Item("XZ Plane") } catch { $wp = $occ.Definition.WorkPlanes.Item(2) }
            return [VaultCad.InventorInterop]::CreateGeometryProxy($occ, $wp)   # ByRef out-parameter needs the C# helper
        }
        $constraintsBefore = $cd.Constraints.Count
        $flush = $null; foreach ($c in $cd.Constraints) { if ($c.Name -eq "FLUSH_XZ_A_B") { $flush = $c } }
        $constraintReused = ($null -ne $flush)
        if (-not $flush) {
            $proxyA = Plane-Proxy $occA; $proxyB = Plane-Proxy $occB
            $flush = $cd.Constraints.AddFlushConstraint($proxyA, $proxyB, $ConstraintOffsetCm)
            $flush.Name = "FLUSH_XZ_A_B"
        }
        $asm.Update()
        $afterC = @{ constraints_before = $constraintsBefore; constraints_after = $cd.Constraints.Count; reused_existing_constraint = $constraintReused; constraint_name = $flush.Name; constraint_type = $flush.Type; health_status = $flush.HealthStatus; suppressed = $flush.Suppressed
            offset_cm = $ConstraintOffsetCm; B = (Occurrence-Record $occB); A = (Occurrence-Record $occA) }
        Step "constraint_add_flush" $afterC
        Check "constraint_exactly_one" ($cd.Constraints.Count -eq 1) "count=$($cd.Constraints.Count) reused=$constraintReused"
        $constraintsBefore = 0
        Check "constraint_moved_B_to_offset" (Approx $afterC.B.transformation.cm[1] $ConstraintOffsetCm 1e-6) "B.y=$($afterC.B.transformation.cm[1]) expected $ConstraintOffsetCm; B.x kept=$($afterC.B.transformation.cm[0])"
        # incompatible request: Y = 3 in while the constraint fixes Y at the offset
        $req = @(5.08, 7.62, 0.0)
        $m = $tg.CreateMatrix(); $m.SetTranslation($tg.CreateVector($req[0], $req[1], $req[2]))
        $setError = $null
        try { $occB.Transformation = $m } catch { $setError = $_.Exception.Message }
        $asm.Update()
        $got = (Translation-Record $occB.Transformation).cm
        $incompat = [ordered]@{ requested_cm = $req; achieved_cm = $got; set_error = $setError; achieved_equals_requested = (Vec-Approx $got $req[0] $req[1] $req[2])
            constraint_still_present = ($cd.Constraints.Count -eq $constraintsBefore + 1); constraint_suppressed = $flush.Suppressed; constraint_health = $flush.HealthStatus
            verdict = $(if (Vec-Approx $got $req[0] $req[1] $req[2]) { "REQUESTED TRANSFORM ACHIEVED (unexpected under constraint)" } else { "incompatible move not achieved; constraint retained" }) }
        Step "constraint_incompatible_move" $incompat
        Check "incompatible_move_reported_not_achieved" (-not $incompat.achieved_equals_requested -and $incompat.constraint_still_present -and -not $incompat.constraint_suppressed) $incompat.verdict
        # compatible request: move in-plane (X) only, keep constrained Y
        $req2 = @(10.16, $ConstraintOffsetCm, 0.0)
        $m = $tg.CreateMatrix(); $m.SetTranslation($tg.CreateVector($req2[0], $req2[1], $req2[2]))
        $occB.Transformation = $m; $asm.Update()
        $got2 = (Translation-Record $occB.Transformation).cm
        Step "constraint_compatible_move" @{ requested_cm = $req2; achieved_cm = $got2 }
        Check "compatible_move_achieved" (Vec-Approx $got2 $req2[0] $req2[1] $req2[2] ) ($got2 -join ",")
        $asm.Save()
        $finalOcc = @{ A = (Occurrence-Record $occA); B = (Occurrence-Record $occB) }
    } finally { $asm.Close($true) }
    Check "ipt_bytes_unchanged_after_constraints" ((Sha $iptPath) -eq $iptSha0) (Sha $iptPath)

    # reopen once more to confirm persistence, then export STEP
    $asm = $app.Documents.Open($iamPath, $false)
    try {
        $cd = $asm.ComponentDefinition; $occA = $cd.Occurrences.ItemByName("PANEL_A"); $occB = $cd.Occurrences.ItemByName("PANEL_B")
        $persist = @{ A = (Occurrence-Record $occA); B = (Occurrence-Record $occB); constraints = $cd.Constraints.Count }
        Step "iam_reopen_final" $persist
        Check "final_placements_persist" ((Vec-Approx $persist.B.transformation.cm 10.16 $ConstraintOffsetCm 0) -and (Vec-Approx $persist.A.transformation.cm 0 0 0) -and $persist.constraints -eq 1) "B=$($persist.B.transformation.cm -join ',') constraints=$($persist.constraints)"

        # ---- Step 5: export assembly STEP ----
        $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
        $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
        $opts = $to.CreateNameValueMap(); if ($translator.HasSaveCopyAsOptions($asm, $ctx, $opts)) { Set-MapValue $opts "ApplicationProtocolType" 3; if ((Read-Map $opts).Contains("IncludeSketches")) { Set-MapValue $opts "IncludeSketches" $false } }
        $medium = $to.CreateDataMedium(); $medium.FileName = $stepOut
        $translator.SaveCopyAs($asm, $ctx, $opts, $medium)
        $outSha = Sha $stepOut
        Step "export_step" @{ output = $stepOut; bytes = (Get-Item -LiteralPath $stepOut).Length; sha256 = $outSha; options = (Read-Map $opts) }
        $placement = [ordered]@{ schema_version = 1; generated_at = Utc; assembly = $iamPath; assembly_sha256 = (Sha $iamPath); assembly_length_units = $lengthUnitNames[[int]$asm.UnitsOfMeasure.LengthUnits]
            component_ipt = $iptPath; component_ipt_sha256 = (Sha $iptPath); step_export = $stepOut; step_export_sha256 = $outSha
            occurrences = @((Occurrence-Record $occA), (Occurrence-Record $occB))
            constraints = @(foreach ($c in $cd.Constraints) { [ordered]@{ name = $c.Name; type = $c.Type; suppressed = $c.Suppressed; health_status = $c.HealthStatus; offset_cm = $(try { [double]$c.Offset.Value } catch { $null }) } })
            note = "Inventor API lengths are centimeters; 'in' and 'mm' are conversions. Transform matrices are row-major 4x4 from Matrix.Cell." }
        $placement | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "placement-report.json") -Encoding UTF8
        $receipt = [ordered]@{ schema_version = 1
            source = [ordered]@{ kind = "local-pilot-fixture"; vault_id = "28"; master_id = "none"; version_id = "none"; path = "local:$iamPath"
                fixture_step = $StepInput; fixture_step_sha256 = $stepSha; fixture_origin = "project references/ENCLOSURE TOP PANEL.step (Vault version 991092) converted to native IPT"; component_ipt_sha256 = (Sha $iptPath); assembly_iam_sha256 = (Sha $iamPath) }
            exporter = [ordered]@{ name = "Autodesk Inventor STEP translator via windows/Invoke-NativeAuthoringPilot.ps1"; version = "Inventor $($session.inventor_version) build $($session.inventor_build)"; model_state = $(try { $cd.ModelStates.ActiveModelState.Name } catch { "n/a" }); protocol = "AP214"; translator_options = (Read-Map $opts); route = "separate hidden Inventor instance on $env:COMPUTERNAME, interactive desktop session"; exported_at = Utc }
            sha256 = $outSha; output_bytes = (Get-Item -LiteralPath $stepOut).Length
            validation = [ordered]@{ occurrence_count = $cd.Occurrences.Count; placement_report = "placement-report.json"; not_a_vault_export = $true } }
        $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "pilot-assembly.export.json") -Encoding UTF8
    } finally { $asm.Close($true) }
    Check "ipt_bytes_unchanged_after_export" ((Sha $iptPath) -eq $iptSha0) (Sha $iptPath)
} catch {
    $session.errors += $_.Exception.Message
    Write-Output "ERROR: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
} finally {
    # Close documents first: a project cannot be re-activated while documents are open.
    try { while ($app.Documents.Count -gt 0) { $app.Documents.Item($app.Documents.Count).Close($true) } } catch { }
    try { if ($dpm -and $previous) { foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $previous) { $p.Activate($false) } } }; if ($proj) { $proj.Remove() } } catch { Write-Output "Could not restore project list: $($_.Exception.Message)" }
    try { $app.Quit() } catch { Write-Output "Quit failed: $($_.Exception.Message)" }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
    $session.finished_at = Utc
    $session.passed = @($session.checks | Where-Object passed).Count; $session.failed = @($session.checks | Where-Object { -not $_.passed }).Count
    $session | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "pilot-session.json") -Encoding UTF8
    Write-Output "Session record: $(Join-Path $OutputDirectory 'pilot-session.json')  checks passed=$($session.passed) failed=$($session.failed) errors=$($session.errors.Count)"
}
if ($session.errors.Count -gt 0 -or $session.failed -gt 0) { exit 1 }
