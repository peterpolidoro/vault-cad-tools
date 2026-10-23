<#
.SYNOPSIS
Placement PILOT in a disposable copy of the acquired assembly: import a published STEP envelope to a native
IPT, place two grounded occurrences by computed transform in the copied root assembly, save only that copy.

.DESCRIPTION
    & .\windows\Invoke-MonitorPlacementPilot.ps1 -StepInput COPY\incoming\X.step -ExpectedStepSha256 SHA `
        -WorkspaceRoot COPY\workspace -RootAssembly 'DATA\...\Free Standing Enclosure.iam' `
        -MirrorRoot MIRROR -Acquisition acquisition.json -OutputDirectory NEW `
        -CenterXmm 597.0 -CenterZmm -418.9,-774.9 -RestYmm 584.16

Nothing outside -WorkspaceRoot (a disposable copy) is written; the mirror and the production assembly are
never opened. Every copied document is bound by SHA-256 to the acquisition record through its path relative
to the copy root, the STEP is bound to -ExpectedStepSha256, and after the run every copied file is re-hashed:
only the root copy may differ (it was saved with Save2(SaveDependents=false)) and the mirror root must be
unchanged. The envelope keeps its own axes; the script reports which local axis is the thinnest (taken as
the screen normal) and which is the longest, and builds a proper rotation (det +1) that maps the long axis
to world X, the thin axis to world +Y (screens facing +Y with native +Y up) and the remaining axis to Z.
Each occurrence is translated so that its world bounding box rests on -RestYmm with its centre at
(-CenterXmm, Z) for each entry of -CenterZmm. Occurrences are grounded (no mates are invented).
Outputs: placement-receipt.json (axes, transforms in cm and mm, world boxes, hashes before/after,
persistence check after reopen, session/shutdown, dialogs seen/dismissed), placement.log, dialogs.log (one JSON
line per dialog-like window of the owned instance; a dialog watchdog thread dismisses single-acknowledgement
dialogs only and never answers a choice; see Start-DialogWatchdog in Inventor-Session.ps1).
#>
param(
    [Parameter(Mandatory = $true)][string]$StepInput,
    [Parameter(Mandatory = $true)][string]$ExpectedStepSha256,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$RootAssembly,
    [Parameter(Mandatory = $true)][string]$MirrorRoot,
    [Parameter(Mandatory = $true)][string]$Acquisition,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [double]$CenterXmm = 597.0,
    [double[]]$CenterZmm = @(-418.9, -774.9),
    [double]$RestYmm = 584.16,
    [string]$PartSubfolder = "MONITOR",
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "placement-pilot",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")

foreach ($f in @($StepInput, $WorkspaceRoot, $MirrorRoot, $Acquisition)) { if (-not (Test-Path -LiteralPath $f)) { throw "Not found: $f" } }
$StepInput = (Resolve-Path -LiteralPath $StepInput).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$MirrorRoot = (Resolve-Path -LiteralPath $MirrorRoot).Path
if ($WorkspaceRoot.ToLowerInvariant().StartsWith($MirrorRoot.ToLowerInvariant())) { throw "The disposable workspace must not be inside the mirror" }
$rootPath = Join-Path $WorkspaceRoot $RootAssembly
if (-not (Test-Path -LiteralPath $rootPath)) { throw "Root assembly copy not found: $rootPath" }
$mirrorRootPath = Join-Path $MirrorRoot $RootAssembly
if (-not (Test-Path -LiteralPath $mirrorRootPath)) { throw "Mirror root assembly not found: $mirrorRootPath" }
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Utc { [DateTime]::UtcNow.ToString("o") }
$stepSha = Sha $StepInput
if ($stepSha -ne $ExpectedStepSha256.ToLowerInvariant()) { throw "STEP input hash $stepSha does not match the expected $ExpectedStepSha256" }
$acq = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
if (-not $acq.files) { throw "Acquisition record has no files" }
$acqByRel = @{}; foreach ($a in $acq.files) { $rel = ([string]$a.local_path).Substring($MirrorRoot.Length).TrimStart('\').ToLowerInvariant(); $acqByRel[$rel] = $a }
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$partDir = Join-Path $WorkspaceRoot $PartSubfolder
$iptPath = Join-Path $partDir ([IO.Path]::GetFileNameWithoutExtension($StepInput) + ".ipt")
if (Test-Path -LiteralPath $iptPath) { throw "Native part already exists, refusing to overwrite: $iptPath" }
$mirrorRootShaBefore = Sha $mirrorRootPath
$copyHashesBefore = [ordered]@{}; foreach ($f in Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File) { $copyHashesBefore[$f.FullName.Substring($WorkspaceRoot.Length + 1)] = Sha $f.FullName }

$kPart = 12290; $kAssembly = 12291
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
function Cells($m) { $rows = @(); for ($r = 1; $r -le 4; $r++) { $row = @(); for ($c = 1; $c -le 4; $c++) { $row += [double]$m.GetType().InvokeMember("Cell", [Reflection.BindingFlags]::GetProperty, $null, $m, @($r, $c)) }; $rows += ,$row }; return ,$rows }
function Set-Cell($m, $r, $c, $v) { [void]$m.GetType().InvokeMember("Cell", [Reflection.BindingFlags]::SetProperty, $null, $m, @([int]$r, [int]$c, [double]$v)) }
function ToMm($M) { $rot = @(); for ($i = 0; $i -lt 4; $i++) { $row = @(); for ($j = 0; $j -lt 4; $j++) { $v = $M[$i][$j]; if ($j -eq 3 -and $i -lt 3) { $v = $v * 10.0 }; $row += $v }; $rot += ,$row }; return ,$rot }
function Box($rb) { [ordered]@{ min = @($rb.MinPoint.X, $rb.MinPoint.Y, $rb.MinPoint.Z); max = @($rb.MaxPoint.X, $rb.MaxPoint.Y, $rb.MaxPoint.Z) } }
function Det3($M) { $M[0][0]*($M[1][1]*$M[2][2]-$M[1][2]*$M[2][1]) - $M[0][1]*($M[1][0]*$M[2][2]-$M[1][2]*$M[2][0]) + $M[0][2]*($M[1][0]*$M[2][1]-$M[1][1]*$M[2][0]) }
function Rotate-Box($box, $rot) {
    $pts = @(); foreach ($x in @($box.min[0], $box.max[0])) { foreach ($y in @($box.min[1], $box.max[1])) { foreach ($z in @($box.min[2], $box.max[2])) { $pts += ,@(($rot[0][0]*$x + $rot[0][1]*$y + $rot[0][2]*$z), ($rot[1][0]*$x + $rot[1][1]*$y + $rot[1][2]*$z), ($rot[2][0]*$x + $rot[2][1]*$y + $rot[2][2]*$z)) } } }
    [ordered]@{ min = @(($pts | ForEach-Object { $_[0] } | Measure-Object -Minimum).Minimum, ($pts | ForEach-Object { $_[1] } | Measure-Object -Minimum).Minimum, ($pts | ForEach-Object { $_[2] } | Measure-Object -Minimum).Minimum); max = @(($pts | ForEach-Object { $_[0] } | Measure-Object -Maximum).Maximum, ($pts | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum, ($pts | ForEach-Object { $_[2] } | Measure-Object -Maximum).Maximum) }
}
$log = Join-Path $OutputDirectory "placement.log"
function Log($s) { $line = "$(Utc) $s"; Add-Content -LiteralPath $log -Value $line; Write-Output $s }

$session = Start-IsolatedInventor
$app = $session.App
Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build))"
$project = $null; $errors = @(); $shutdown = $null; $watchdog = $null; $dialogs = $null
$watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $OutputDirectory "dialogs.log")
Log "Dialog watchdog started on pid $($session.Pid) (poll $($watchdog.IntervalMilliseconds) ms): $($watchdog.Policy)"
$receipt = [ordered]@{ schema_version = 1; generated_at = (Utc); pilot = "windows/Invoke-MonitorPlacementPilot.ps1"; status = "FAILED"; scope = "placement pilot in a disposable copy; not a design; grounded occurrences, no mates, no supports, no production save"
    inputs = [ordered]@{ step = $StepInput; step_sha256 = $stepSha; workspace_root = $WorkspaceRoot; root_assembly = $RootAssembly; mirror_root = $MirrorRoot; mirror_root_sha256_before = $mirrorRootShaBefore; acquisition_record = $Acquisition; requested = [ordered]@{ center_x_mm = $CenterXmm; center_z_mm = $CenterZmm; rest_y_mm = $RestYmm } } }
try {
    $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
    Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); created file: $($project.CreatedFile))"
    $tg = $app.TransientGeometry
    # ---- 1. STEP -> native IPT ----
    New-Item -ItemType Directory -Force -Path $partDir | Out-Null
    $doc = $app.Documents.Open($StepInput, $false)
    try {
        if ([int]$doc.DocumentType -ne $kPart) { throw "STEP import produced document type $($doc.DocumentType), not a part" }
        $cd = $doc.ComponentDefinition
        $bodies = [int]$cd.SurfaceBodies.Count; $solids = 0; for ($i = 1; $i -le $bodies; $i++) { if ($cd.SurfaceBodies.Item($i).IsSolid) { $solids++ } }
        $rb = Box $cd.RangeBox
        $doc.SaveAs($iptPath, $false)
        Log "Imported STEP -> $iptPath (bodies $bodies, solids $solids)"
    } finally { try { $doc.Close($true) } catch { $errors += "step document close: $($_.Exception.Message)" } }
    $iptSha = Sha $iptPath
    # envelope axes from the local range box (cm)
    $ext = @(($rb.max[0] - $rb.min[0]), ($rb.max[1] - $rb.min[1]), ($rb.max[2] - $rb.min[2]))
    $axisNames = @("X", "Y", "Z")
    $thin = 0; $long = 0; for ($i = 1; $i -lt 3; $i++) { if ($ext[$i] -lt $ext[$thin]) { $thin = $i }; if ($ext[$i] -gt $ext[$long]) { $long = $i } }
    if ($thin -eq $long) { throw "Envelope extents are degenerate: $($ext -join ', ')" }
    $other = (3 - $thin - $long)
    $receipt.envelope = [ordered]@{ ipt = $iptPath; ipt_sha256 = $iptSha; bodies = $bodies; solid_bodies = $solids; local_range_box_mm = [ordered]@{ min = @($rb.min | ForEach-Object { $_ * 10 }); max = @($rb.max | ForEach-Object { $_ * 10 }) }; local_extents_mm = @($ext | ForEach-Object { [Math]::Round($_ * 10, 3) }); longest_local_axis = $axisNames[$long]; thinnest_local_axis_taken_as_screen_normal = $axisNames[$thin]; remaining_local_axis = $axisNames[$other]; note = "the nominal envelope carries no screen marking; the thinnest axis is taken as the screen normal and its positive side faces +Y" }
    Log "Envelope extents (mm): X=$([Math]::Round($ext[0]*10,2)) Y=$([Math]::Round($ext[1]*10,2)) Z=$([Math]::Round($ext[2]*10,2)); long=$($axisNames[$long]) thin(screen normal)=$($axisNames[$thin]) other=$($axisNames[$other])"
    # ---- 2. rotation: local long -> world X, local thin -> world +Y, local other -> world Z (det +1) ----
    $rot = @(@(0.0,0.0,0.0),@(0.0,0.0,0.0),@(0.0,0.0,0.0))
    $rot[0][$long] = 1.0; $rot[1][$thin] = 1.0; $rot[2][$other] = 1.0
    if ((Det3 $rot) -lt 0) { $rot[2][$other] = -1.0 }
    $receipt.rotation = [ordered]@{ matrix_world_from_local = $rot; determinant = (Det3 $rot); mapping = "local $($axisNames[$long]) -> world X; local $($axisNames[$thin]) -> world +Y; local $($axisNames[$other]) -> world $(if ($rot[2][$other] -gt 0) { '+' } else { '-' })Z" }
    $rotBox = Rotate-Box $rb $rot   # cm, before translation
    # ---- 3. root copy: bind, place, ground, save ----
    $asm = $app.Documents.Open($rootPath, $false)
    try {
        $bound = @(); $unbound = @()
        foreach ($d in @($asm) + @($asm.AllReferencedDocuments)) {
            $full = [string]$d.FullFileName
            if (-not $full.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant())) { $unbound += [ordered]@{ path = $full; reason = "outside the disposable workspace" }; continue }
            $rel = $full.Substring($WorkspaceRoot.Length + 1).ToLowerInvariant()
            $a = $acqByRel[$rel]
            if (-not $a) { $unbound += [ordered]@{ path = $full; reason = "no acquisition record for relative path" }; continue }
            $sha = Sha $full
            $bound += [ordered]@{ relative_path = $rel; version_id = [string]$a.version_id; master_id = [string]$a.master_id; vault_path = $a.vault_path; sha256 = $sha; matches_acquisition = ($sha -eq [string]$a.sha256) }
        }
        if ($unbound.Count -or @($bound | Where-Object { -not $_.matches_acquisition }).Count) { throw "Copy binding failed: unbound=$($unbound | ConvertTo-Json -Compress) mismatched=$(@($bound | Where-Object { -not $_.matches_acquisition }) | ConvertTo-Json -Compress)" }
        Log "Bound $($bound.Count) copied documents to the acquisition record by relative path and hash"
        $receipt.binding = [ordered]@{ documents = $bound.Count; all_match = $true; inputs = $bound }
        $cdRoot = $asm.ComponentDefinition
        $before = [int]$cdRoot.Occurrences.Count
        $placed = @()
        for ($k = 0; $k -lt $CenterZmm.Count; $k++) {
            $cz = $CenterZmm[$k] / 10.0; $cx = $CenterXmm / 10.0; $restY = $RestYmm / 10.0
            # translation so that the rotated box rests on restY and is centred at (cx, cz)
            $tx = $cx - ($rotBox.min[0] + $rotBox.max[0]) / 2.0
            $ty = $restY - $rotBox.min[1]
            $tz = $cz - ($rotBox.min[2] + $rotBox.max[2]) / 2.0
            $m = $tg.CreateMatrix()
            for ($r = 0; $r -lt 3; $r++) { for ($c = 0; $c -lt 3; $c++) { Set-Cell $m ($r + 1) ($c + 1) $rot[$r][$c] } }
            Set-Cell $m 1 4 $tx; Set-Cell $m 2 4 $ty; Set-Cell $m 3 4 $tz
            $occ = $cdRoot.Occurrences.Add($iptPath, $m)
            $occ.Grounded = $true
            $world = Cells $occ.Transformation
            $wb = Box $occ.RangeBox
            $placed += [ordered]@{ occurrence = [string]$occ.Name; grounded = [bool]$occ.Grounded; requested_center_mm = @($CenterXmm, $null, $CenterZmm[$k]); requested_rest_y_mm = $RestYmm; transform_world_cm = $world; transform_world_mm = (ToMm $world); world_range_box_mm = [ordered]@{ min = @($wb.min | ForEach-Object { [Math]::Round($_ * 10, 3) }); max = @($wb.max | ForEach-Object { [Math]::Round($_ * 10, 3) }) }; world_center_mm = @([Math]::Round(($wb.min[0] + $wb.max[0]) * 5, 3), [Math]::Round(($wb.min[1] + $wb.max[1]) * 5, 3), [Math]::Round(($wb.min[2] + $wb.max[2]) * 5, 3)) }
            Log "Placed $($occ.Name): world box X[$([Math]::Round($wb.min[0]*10,1)),$([Math]::Round($wb.max[0]*10,1))] Y[$([Math]::Round($wb.min[1]*10,1)),$([Math]::Round($wb.max[1]*10,1))] Z[$([Math]::Round($wb.min[2]*10,1)),$([Math]::Round($wb.max[2]*10,1))] mm, grounded=$($occ.Grounded)"
        }
        $after = [int]$cdRoot.Occurrences.Count
        $asm.Save2($false)   # only the root copy; dependents are not saved
        Log "Saved root copy only (Save2 SaveDependents=false); occurrences $before -> $after"
        $receipt.placement = [ordered]@{ root_copy = $rootPath; occurrences_before = $before; occurrences_after = $after; placed = $placed; save = "Save2(SaveDependents=false) on the root copy" }
    } finally { try { $asm.Close($true) } catch { $errors += "root close: $($_.Exception.Message)" } }
    # ---- 4. persistence: reopen and read back ----
    $asm2 = $app.Documents.Open($rootPath, $false)
    try {
        $cd2 = $asm2.ComponentDefinition; $found = @()
        for ($i = 1; $i -le $cd2.Occurrences.Count; $i++) { $o = $cd2.Occurrences.Item($i); if ([string]$o.Definition.Document.FullFileName -ieq $iptPath) { $found += [ordered]@{ occurrence = [string]$o.Name; grounded = [bool]$o.Grounded; transform_world_mm = (ToMm (Cells $o.Transformation)) } } }
        $receipt.persistence = [ordered]@{ reopened = $true; envelope_occurrences_found = $found.Count; occurrences_total = [int]$cd2.Occurrences.Count; found = $found; transforms_identical = ($found.Count -eq $placed.Count -and (@(0..($found.Count - 1) | Where-Object { ($found[$_].transform_world_mm | ConvertTo-Json -Compress) -ne ($placed[$_].transform_world_mm | ConvertTo-Json -Compress) }).Count -eq 0)) }
        Log "Reopened: $($found.Count) envelope occurrences, total $($cd2.Occurrences.Count), transforms identical: $($receipt.persistence.transforms_identical)"
    } finally { try { $asm2.Close($true) } catch { $errors += "reopen close: $($_.Exception.Message)" } }
} catch {
    $errors += $_.Exception.Message; Log "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace }
} finally {
    $shutdown = Stop-IsolatedInventor $session $project
    if (-not $shutdown.Succeeded) { $errors += "shutdown not observed as complete: $($shutdown.Observed | ConvertTo-Json -Compress)" }
    Log "Shutdown: pid $($shutdown.Pid) exited=$($shutdown.Exited) succeeded=$($shutdown.Succeeded)"
    if ($watchdog) { $dialogs = Stop-DialogWatchdog $watchdog; Log "Dialog watchdog: $($dialogs.Polls) polls, $($dialogs.Events.Count) dialog window(s) seen, $($dialogs.Dismissed) dismissed, $($dialogs.Left) left alone$(if ($dialogs.Errors.Count) { '; errors: ' + ($dialogs.Errors -join ' | ') })" }
}
# ---- 5. integrity: mirror untouched; only the root copy (and the new part folder) changed ----
$changed = @(); $added = @(); $after = [ordered]@{}
foreach ($f in Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File) { $rel = $f.FullName.Substring($WorkspaceRoot.Length + 1); $sha = Sha $f.FullName; $after[$rel] = $sha; if ($copyHashesBefore.Contains($rel)) { if ($copyHashesBefore[$rel] -ne $sha) { $changed += $rel } } else { $added += $rel } }
$rootRelLower = $RootAssembly.ToLowerInvariant()
$unexpected = @($changed | Where-Object { $_.ToLowerInvariant() -ne $rootRelLower -and $_ -notlike "*.ipj" -and $_ -notlike "OldVersions\*" -and $_ -notlike "*\OldVersions\*" })
$mirrorRootShaAfter = Sha $mirrorRootPath
$receipt.integrity = [ordered]@{ mirror_root_sha256_after = $mirrorRootShaAfter; mirror_root_unchanged = ($mirrorRootShaAfter -eq $mirrorRootShaBefore); copy_files_changed = $changed; copy_files_added = $added; unexpected_changes = $unexpected; root_copy_sha256_before = $copyHashesBefore[$RootAssembly]; root_copy_sha256_after = $after[$RootAssembly] }
if (-not $receipt.integrity.mirror_root_unchanged) { $errors += "mirror root hash changed" }
if ($unexpected.Count) { $errors += "unexpected copied files changed: $($unexpected -join '; ')" }
$receipt.session = [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; inventor = "$($session.Version) build $($session.Build)"; pre_existing_inventor_pids = $session.PreExistingPids; shutdown = [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; observed = $shutdown.Observed; required = @($shutdown.Required); failed_required = @($shutdown.FailedRequired); notes = @($shutdown.Notes) } }
$receipt.dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; log = "dialogs.log"; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors); remaining_at_stop = @($dialogs.Remaining) } } else { $null })
$receipt.project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; created_file = $project.CreatedFile; entry_removed_by_run = $shutdown.ProjectEntryRemoved; previous_restored = $shutdown.PreviousProjectRestored } } else { $null })
$receipt.errors = $errors
$receipt.status = $(if ($errors.Count -eq 0 -and $shutdown.Succeeded -and $receipt.persistence -and $receipt.persistence.transforms_identical) { "complete" } else { "FAILED" })
ConvertTo-Json -InputObject $receipt -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "placement-receipt.json") -Encoding UTF8
Log "Placement pilot status: $($receipt.status)"
if ($receipt.status -ne "complete") { exit 1 }
