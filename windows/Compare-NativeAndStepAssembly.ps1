<#
.SYNOPSIS
Measure a native Inventor assembly and a STEP file per occurrence in a hidden Inventor instance
and compare them: SurfaceBodies, IsSolid-filtered solids, visibility, volume, range boxes.

.DESCRIPTION
Answers "which components account for a body-count difference?" with per-occurrence and
per-distinct-document records for both sides:
  - native: the .iam from the acquisition mirror (WorkspaceRoot stands in for Vault "$");
  - step:   the exported STEP re-imported with Documents.Open (in-memory components).
For every leaf occurrence: occurrence path, document, SurfaceBodies.Count, bodies with
IsSolid, visible solid bodies, occurrence visibility/suppression, MassProperties.Volume (cm^3,
Inventor default accuracy), the occurrence RangeBox (conservative) and, optionally, a tighter
box from the union of face SurfaceEvaluator range boxes (-TightBounds; slow on large models).
Distinct-document aggregates carry multiplicity. The comparison keys native documents by file
name without extension and STEP components by their imported document display name.

Nothing is saved; both documents are closed without saving; the interactive Inventor session
and the user's project list are untouched. This is measurement evidence, not design approval.
#>
param(
    [Parameter(Mandatory = $true)][string]$NativeAssembly,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$Step,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$TightBounds,
    [string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
foreach ($p in @($NativeAssembly, $Step)) { if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" } }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
foreach ($n in "native-measure.json", "step-measure.json", "comparison.json") { if (Test-Path -LiteralPath (Join-Path $OutputDirectory $n)) { throw "Refusing to overwrite $n in $OutputDirectory" } }
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$kPart = 12290; $kAssembly = 12291
function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Box($rb) { if ($rb) { [ordered]@{ min = @($rb.MinPoint.X, $rb.MinPoint.Y, $rb.MinPoint.Z); max = @($rb.MaxPoint.X, $rb.MaxPoint.Y, $rb.MaxPoint.Z) } } else { $null } }
function Union($a, $b) { if (-not $a) { return $b }; if (-not $b) { return $a }; [ordered]@{ min = @([Math]::Min($a.min[0], $b.min[0]), [Math]::Min($a.min[1], $b.min[1]), [Math]::Min($a.min[2], $b.min[2])); max = @([Math]::Max($a.max[0], $b.max[0]), [Math]::Max($a.max[1], $b.max[1]), [Math]::Max($a.max[2], $b.max[2])) } }
function Extent($box) { if ($box) { @(($box.max[0] - $box.min[0]), ($box.max[1] - $box.min[1]), ($box.max[2] - $box.min[2])) } else { $null } }

function Measure-Tree($occurrences, $path, $acc) {
    foreach ($o in $occurrences) {
        $name = $o.Name; $here = if ($path) { "$path/$name" } else { $name }
        if ($o.Suppressed) { $acc.records += [ordered]@{ path = $here; suppressed = $true; leaf = $null }; continue }
        if ($o.DefinitionDocumentType -eq $kAssembly) { Measure-Tree $o.SubOccurrences $here $acc; continue }
        $docName = $null; $docPath = $null
        try { $docPath = $o.Definition.Document.FullFileName; $docName = $o.Definition.Document.DisplayName } catch { }
        $key = if ($docPath) { [IO.Path]::GetFileNameWithoutExtension($docPath) } elseif ($docName) { [IO.Path]::GetFileNameWithoutExtension($docName) } else { $name -replace ':\d+$', '' }
        $bodies = 0; $solids = 0; $visibleSolids = 0; $faces = 0; $tight = $null
        foreach ($b in $o.SurfaceBodies) {   # occurrence-space proxies
            $bodies++
            $isSolid = $false; try { $isSolid = [bool]$b.IsSolid } catch { }
            if ($isSolid) { $solids++; $vis = $true; try { $vis = [bool]$b.Visible } catch { }; if ($vis) { $visibleSolids++ } }
            try { $faces += $b.Faces.Count } catch { }
            if ($TightBounds -and $isSolid) { foreach ($f in $b.Faces) { try { $tight = Union $tight (Box $f.Evaluator.RangeBox) } catch { } } }
        }
        $vol = $null; try { $vol = [double]$o.MassProperties.Volume } catch { }
        $rec = [ordered]@{ path = $here; key = $key; document = $(if ($docPath) { $docPath } else { $docName }); suppressed = $false; occurrence_visible = $o.Visible
            surface_bodies = $bodies; solid_bodies = $solids; visible_solid_bodies = $visibleSolids; faces = $faces; volume_cm3 = $vol
            range_box_cm = (Box $o.RangeBox); tight_box_cm = $tight }
        $acc.records += $rec
        $acc.totals.leaves++; $acc.totals.surface_bodies += $bodies; $acc.totals.solid_bodies += $solids; $acc.totals.visible_solid_bodies += $visibleSolids; $acc.totals.faces += $faces
        if ($vol -ne $null) { $acc.totals.volume_cm3 += $vol }
        $acc.totals.range_union = Union $acc.totals.range_union $rec.range_box_cm
        if ($tight) { $acc.totals.tight_union = Union $acc.totals.tight_union $tight }
        if (-not $acc.by_key.Contains($key)) { $acc.by_key[$key] = [ordered]@{ key = $key; document = $rec.document; occurrences = 0; surface_bodies_per_occurrence = $bodies; solid_bodies_per_occurrence = $solids; visible_solid_bodies_per_occurrence = $visibleSolids; volume_cm3_per_occurrence = $vol; surface_bodies_total = 0; solid_bodies_total = 0; volume_cm3_total = 0.0; inconsistent_per_occurrence_counts = $false } }
        $k = $acc.by_key[$key]; $k.occurrences++; $k.surface_bodies_total += $bodies; $k.solid_bodies_total += $solids; if ($vol -ne $null) { $k.volume_cm3_total += $vol }
        if ($k.surface_bodies_per_occurrence -ne $bodies -or $k.solid_bodies_per_occurrence -ne $solids) { $k.inconsistent_per_occurrence_counts = $true }
    }
}
function Measure-Document($doc, $label) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $acc = @{ records = @(); by_key = [ordered]@{}; totals = [ordered]@{ leaves = 0; surface_bodies = 0; solid_bodies = 0; visible_solid_bodies = 0; faces = 0; volume_cm3 = 0.0; range_union = $null; tight_union = $null } }
    $cd = $doc.ComponentDefinition
    Measure-Tree $cd.Occurrences "" $acc
    $docVol = $null; try { $docVol = [double]$cd.MassProperties.Volume } catch { }
    $topLevel = @(); foreach ($o in $cd.Occurrences) { $sub = @{ records = @(); by_key = [ordered]@{}; totals = [ordered]@{ leaves = 0; surface_bodies = 0; solid_bodies = 0; visible_solid_bodies = 0; faces = 0; volume_cm3 = 0.0; range_union = $null; tight_union = $null } }; if ($o.DefinitionDocumentType -eq $kAssembly) { Measure-Tree $o.SubOccurrences $o.Name $sub } else { Measure-Tree @($o) "" $sub }; $topLevel += [ordered]@{ name = $o.Name; is_assembly = ($o.DefinitionDocumentType -eq $kAssembly); leaves = $sub.totals.leaves; surface_bodies = $sub.totals.surface_bodies; solid_bodies = $sub.totals.solid_bodies; visible_solid_bodies = $sub.totals.visible_solid_bodies; volume_cm3 = $sub.totals.volume_cm3; volume_mm3 = ($sub.totals.volume_cm3 * 1000) } }
    [ordered]@{ label = $label; document = $doc.FullFileName; display_name = $doc.DisplayName; document_type = $doc.DocumentType; measured_at = Utc; seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        top_level_occurrences = $cd.Occurrences.Count; totals = $acc.totals; document_mass_properties_volume_cm3 = $docVol
        document_range_box_cm = (Box $cd.RangeBox); document_range_extent_cm = (Extent (Box $cd.RangeBox)); leaf_range_union_extent_cm = (Extent $acc.totals.range_union); tight_union_extent_cm = (Extent $acc.totals.tight_union)
        top_level = $topLevel; by_document = @($acc.by_key.Values); occurrences = $acc.records }
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

    Write-Output "Opening native $NativeAssembly"
    $native = $app.Documents.Open($NativeAssembly, $false)
    try {
        $missing = @(); foreach ($rd in @($native) + @($native.AllReferencedDocuments)) { foreach ($fd in $rd.File.ReferencedFileDescriptors) { if ($fd.ReferenceMissing) { $missing += $fd.FullFileName } } }
        $nm = Measure-Document $native "native"
        $nm.sha256 = Sha $NativeAssembly; $nm.all_referenced_document_count = $native.AllReferencedDocuments.Count; $nm.unresolved_references = $missing
        $nm.inventor_version = $app.SoftwareVersion.DisplayVersion; $nm.inventor_build = $app.SoftwareVersion.BuildIdentifier
        $nm | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "native-measure.json") -Encoding UTF8
        Write-Output ("native: leaves {0}, bodies {1}, solids {2}, visible solids {3}, volume {4} cm3, doc volume {5} cm3, extent {6} cm, {7}s" -f $nm.totals.leaves, $nm.totals.surface_bodies, $nm.totals.solid_bodies, $nm.totals.visible_solid_bodies, [Math]::Round($nm.totals.volume_cm3, 3), $nm.document_mass_properties_volume_cm3, (($nm.document_range_extent_cm | ForEach-Object { [Math]::Round($_, 4) }) -join " x "), $nm.seconds)
    } finally { $native.Close($true) }

    Write-Output "Importing STEP $Step"
    $docsBefore = $app.Documents.Count
    $stepDoc = $app.Documents.Open($Step, $false)
    try {
        $sm = Measure-Document $stepDoc "step"
        $sm.sha256 = Sha $Step; $sm.documents_created = $app.Documents.Count - $docsBefore
        $sm | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "step-measure.json") -Encoding UTF8
        Write-Output ("step:   leaves {0}, bodies {1}, solids {2}, visible solids {3}, volume {4} cm3, doc volume {5} cm3, extent {6} cm, {7}s" -f $sm.totals.leaves, $sm.totals.surface_bodies, $sm.totals.solid_bodies, $sm.totals.visible_solid_bodies, [Math]::Round($sm.totals.volume_cm3, 3), $sm.document_mass_properties_volume_cm3, (($sm.document_range_extent_cm | ForEach-Object { [Math]::Round($_, 4) }) -join " x "), $sm.seconds)
    } finally { while ($app.Documents.Count -gt $docsBefore) { $app.Documents.Item($app.Documents.Count).Close($true) } }

    # ---- comparison ----
    $keys = @($nm.by_document | ForEach-Object key) + @($sm.by_document | ForEach-Object key) | Sort-Object -Unique
    $rows = @(); $diffRows = @()
    foreach ($k in $keys) {
        $n = $nm.by_document | Where-Object { $_.key -eq $k } | Select-Object -First 1
        $s = $sm.by_document | Where-Object { $_.key -eq $k } | Select-Object -First 1
        $row = [ordered]@{ key = $k
            native = $(if ($n) { [ordered]@{ occurrences = $n.occurrences; bodies_per = $n.surface_bodies_per_occurrence; solids_per = $n.solid_bodies_per_occurrence; visible_solids_per = $n.visible_solid_bodies_per_occurrence; bodies_total = $n.surface_bodies_total; solids_total = $n.solid_bodies_total; volume_cm3_per = $n.volume_cm3_per_occurrence; inconsistent = $n.inconsistent_per_occurrence_counts } } else { $null })
            step = $(if ($s) { [ordered]@{ occurrences = $s.occurrences; bodies_per = $s.surface_bodies_per_occurrence; solids_per = $s.solid_bodies_per_occurrence; visible_solids_per = $s.visible_solid_bodies_per_occurrence; bodies_total = $s.surface_bodies_total; solids_total = $s.solid_bodies_total; volume_cm3_per = $s.volume_cm3_per_occurrence; inconsistent = $s.inconsistent_per_occurrence_counts } } else { $null }) }
        $row.delta_bodies_total = $(if ($n -and $s) { $s.surface_bodies_total - $n.surface_bodies_total } else { $null })
        $row.delta_solids_total = $(if ($n -and $s) { $s.solid_bodies_total - $n.solid_bodies_total } else { $null })
        $row.delta_occurrences = $(if ($n -and $s) { $s.occurrences - $n.occurrences } else { $null })
        $row.delta_volume_cm3_per = $(if ($n -and $s -and $n.volume_cm3_per_occurrence -ne $null -and $s.volume_cm3_per_occurrence -ne $null) { $s.volume_cm3_per_occurrence - $n.volume_cm3_per_occurrence } else { $null })
        $row.status = $(if (-not $n) { "only_in_step" } elseif (-not $s) { "only_in_native" } elseif ($row.delta_bodies_total -ne 0 -or $row.delta_occurrences -ne 0) { "differs" } else { "same_counts" })
        $rows += $row; if ($row.status -ne "same_counts") { $diffRows += $row }
    }
    $cmp = [ordered]@{ generated_at = Utc; native = [ordered]@{ document = $NativeAssembly; sha256 = $nm.sha256; totals = $nm.totals; document_volume_cm3 = $nm.document_mass_properties_volume_cm3; document_extent_cm = $nm.document_range_extent_cm; tight_extent_cm = $nm.tight_union_extent_cm; unresolved_references = $nm.unresolved_references }
        step = [ordered]@{ document = $Step; sha256 = $sm.sha256; totals = $sm.totals; document_volume_cm3 = $sm.document_mass_properties_volume_cm3; document_extent_cm = $sm.document_range_extent_cm; tight_extent_cm = $sm.tight_union_extent_cm }
        delta = [ordered]@{ leaves = $sm.totals.leaves - $nm.totals.leaves; surface_bodies = $sm.totals.surface_bodies - $nm.totals.surface_bodies; solid_bodies = $sm.totals.solid_bodies - $nm.totals.solid_bodies; visible_solid_bodies = $sm.totals.visible_solid_bodies - $nm.totals.visible_solid_bodies; volume_cm3 = $sm.totals.volume_cm3 - $nm.totals.volume_cm3 }
        documents_with_differences = $diffRows; documents = $rows
        note = "Counts are per leaf occurrence (occurrence-space body proxies). 'bodies' = SurfaceBodies.Count (unfiltered); 'solids' = bodies with IsSolid; 'visible solids' additionally Visible. Volumes from MassProperties (Inventor default accuracy), cm^3. Range boxes are Inventor RangeBox (conservative); tight boxes only when -TightBounds." }
    $cmp | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "comparison.json") -Encoding UTF8
    Write-Output ("delta step-native: leaves {0}, bodies {1}, solids {2}, visible solids {3}, volume {4} cm3" -f $cmp.delta.leaves, $cmp.delta.surface_bodies, $cmp.delta.solid_bodies, $cmp.delta.visible_solid_bodies, [Math]::Round($cmp.delta.volume_cm3, 4))
    Write-Output "documents with differences: $($diffRows.Count)"
    foreach ($r in $diffRows) { Write-Output ("  {0,-14} {1}: native occ={2} bodies/occ={3} solids/occ={4} | step occ={5} bodies/occ={6} solids/occ={7} | dBodies={8}" -f $r.status, $r.key, $(if ($r.native) { $r.native.occurrences } else { '-' }), $(if ($r.native) { $r.native.bodies_per } else { '-' }), $(if ($r.native) { $r.native.solids_per } else { '-' }), $(if ($r.step) { $r.step.occurrences } else { '-' }), $(if ($r.step) { $r.step.bodies_per } else { '-' }), $(if ($r.step) { $r.step.solids_per } else { '-' }), $r.delta_bodies_total) }
} catch {
    $errors += $_.Exception.Message; Write-Output "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
} finally {
    try { while ($app.Documents.Count -gt 0) { $app.Documents.Item($app.Documents.Count).Close($true) } } catch { }
    try { if ($dpm -and $previous) { foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $previous) { $p.Activate($false) } } }; if ($proj) { $proj.Remove() } } catch { Write-Output "Could not restore project list: $($_.Exception.Message)" }
    try { $app.Quit() } catch { }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
}
if ($errors.Count -gt 0) { exit 1 }
