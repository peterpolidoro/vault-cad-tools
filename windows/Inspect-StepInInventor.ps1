<#
.SYNOPSIS
Re-open STEP files in a separate, invisible Inventor instance and record what Inventor reads back.

.DESCRIPTION
Companion to Export-InventorStep.ps1: a basic completeness check that the exported STEP files load
in Inventor and yield solids/occurrences and an extent comparable to the native source. Imports
are kept in memory (SaveComponentDuringLoad=False) so nothing is written next to the STEP files;
documents are closed without saving. The interactive Inventor session is never touched; the
script aborts if COM attaches to an already running instance.

Writes <name>.step-inspection.json next to each STEP file. This is not geometric validation;
FreeCAD/Inventor human review remains necessary.
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Step,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
foreach ($s in $Step) { if (-not (Test-Path -LiteralPath $s)) { throw "STEP file not found: $s" } }
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
$kAssemblyDocument = 12291
$kFileBrowseIOMechanism = 13059
$stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
function Get-MapName($map, $index) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($index)) }
function Get-MapValue($map, $key) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($key)) }
function Set-MapValue($map, $key, $value) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($key, $value)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
function Utc { [DateTime]::UtcNow.ToString("o") }
function Measure-Occurrences($occurrences, $acc) {
    foreach ($o in $occurrences) {
        if ($o.Suppressed) { $acc.suppressed++; continue }
        if ($o.DefinitionDocumentType -eq 12290) {
            $acc.leaves++
            try { $acc.docs[$o.Definition.Document.FullFileName] = 1; $acc.bodies += $o.Definition.SurfaceBodies.Count } catch { $acc.unreadable++ }
        } elseif ($o.DefinitionDocumentType -eq 12291) {
            $acc.subassemblies++
            Measure-Occurrences $o.SubOccurrences $acc
        } else { $acc.other++ }
    }
}

$before = @(Get-Process -Name Inventor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$app = New-Object -ComObject Inventor.Application
Start-Sleep -Seconds 3
$after = @(Get-Process -Name Inventor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$newPids = @($after | Where-Object { $before -notcontains $_ })
if ($newPids.Count -eq 0) {
    Write-Output "COM attached to an already running Inventor instance; aborting without touching it."
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
    exit 3
}
Write-Output "New Inventor instance pid $($newPids -join ',') version $($app.SoftwareVersion.DisplayVersion) build $($app.SoftwareVersion.BuildIdentifier)"
$errors = @(); $dpm = $null; $proj = $null; $previous = $null
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
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid)
    if (-not $translator.Activated) { $translator.Activate() }
    $to = $app.TransientObjects

    foreach ($stepPath in $Step) {
        $stepPath = (Resolve-Path -LiteralPath $stepPath).Path
        $name = [IO.Path]::GetFileNameWithoutExtension($stepPath)
        $outPath = Join-Path (Split-Path -LiteralPath $stepPath) "$name.step-inspection.json"
        $result = [ordered]@{ step = $stepPath; step_bytes = (Get-Item -LiteralPath $stepPath).Length
            step_sha256 = (Get-FileHash -LiteralPath $stepPath -Algorithm SHA256).Hash.ToLowerInvariant()
            inventor_version = $app.SoftwareVersion.DisplayVersion; inventor_build = $app.SoftwareVersion.BuildIdentifier; inspected_at = Utc }
        $docsBefore = $app.Documents.Count
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
        $opts = $to.CreateNameValueMap()
        $medium = $to.CreateDataMedium(); $medium.FileName = $stepPath
        $openOptions = [ordered]@{}
        try { if ($translator.HasOpenOptions($medium, $ctx, $opts)) { $openOptions = Read-Map $opts } } catch { Write-Output "HasOpenOptions unavailable: $($_.Exception.Message)" }
        $result.import_default_options = $openOptions
        if ($openOptions.Contains("SaveComponentDuringLoad")) { Set-MapValue $opts "SaveComponentDuringLoad" $false }
        $result.import_options_used = Read-Map $opts
        $doc = $null
        Write-Output "Importing $stepPath via translator Open"
        try {
            $target = $null
            $translator.Open($medium, $ctx, $opts, [ref]$target)
            $doc = $target
        } catch { Write-Output "Translator Open failed ($($_.Exception.Message)); falling back to Documents.Open" }
        if (-not $doc) {
            # Fallback: Documents.Open with default import options. For an assembly STEP, Inventor may
            # write component files under the active project's imported-components folder, which is
            # inside WorkspaceRoot here.
            $result.import_route = "Documents.Open (default options)"
            $doc = $app.Documents.Open($stepPath, $false)
        } else { $result.import_route = "TranslatorAddIn.Open" }
        $sw.Stop()
        if (-not $doc) { $doc = $app.ActiveDocument }
        if (-not $doc) { throw "Import produced no document for $name" }
        try {
            $result.import_seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            $result.document_type = $doc.DocumentType
            $result.is_assembly = ($doc.DocumentType -eq $kAssemblyDocument)
            $units = [int]$doc.UnitsOfMeasure.LengthUnits
            $result.length_units = if ($lengthUnitNames.ContainsKey($units)) { $lengthUnitNames[$units] } else { "enum $units" }
            $cd = $doc.ComponentDefinition
            if ($result.is_assembly) {
                $result.occurrence_count = $cd.Occurrences.Count
                $acc = @{ leaves = 0; suppressed = 0; subassemblies = 0; other = 0; bodies = 0; unreadable = 0; docs = @{} }
                Measure-Occurrences $cd.Occurrences $acc
                $result.leaf_occurrence_count = $acc.leaves
                $result.subassembly_occurrences = $acc.subassemblies
                $result.distinct_leaf_documents = $acc.docs.Count
                $result.leaf_body_count = $acc.bodies
                $result.unreadable_leaf_definitions = $acc.unreadable
                $result.documents_created = $app.Documents.Count - $docsBefore
            } else {
                $result.solid_body_count = $cd.SurfaceBodies.Count
            }
            $rb = $cd.RangeBox
            $result.range_box_cm = [ordered]@{ min = @($rb.MinPoint.X, $rb.MinPoint.Y, $rb.MinPoint.Z); max = @($rb.MaxPoint.X, $rb.MaxPoint.Y, $rb.MaxPoint.Z) }
            $result.extent_cm = @(($rb.MaxPoint.X - $rb.MinPoint.X), ($rb.MaxPoint.Y - $rb.MinPoint.Y), ($rb.MaxPoint.Z - $rb.MinPoint.Z))
            Write-Output ("Re-imported {0}: type {1}, units {2}, occurrences {3}, leaves {4}, bodies {5}, extent_cm {6}, {7}s" -f $name, $result.document_type, $result.length_units, $result.occurrence_count, $result.leaf_occurrence_count, $(if ($result.is_assembly) { $result.leaf_body_count } else { $result.solid_body_count }), ($result.extent_cm -join ' x '), $result.import_seconds)
        } finally {
            # Close every document the import created, never saving.
            while ($app.Documents.Count -gt $docsBefore) { $app.Documents.Item($app.Documents.Count).Close($true) }
        }
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outPath -Encoding UTF8
        Write-Output "Inspection record: $outPath"
    }
} catch {
    $errors += $_.Exception.Message
    Write-Output "ERROR: $($_.Exception.Message)"
} finally {
    try {
        if ($dpm -and $previous) { foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $previous) { $p.Activate($false) } } }
        if ($proj) { $proj.Remove() }
    } catch { Write-Output "Could not restore the project list: $($_.Exception.Message)" }
    try { $app.Quit() } catch { Write-Output "Quit failed: $($_.Exception.Message)" }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
}
if ($errors.Count -gt 0) { exit 1 }
