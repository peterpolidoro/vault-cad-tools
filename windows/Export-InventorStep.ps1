<#
.SYNOPSIS
Export Inventor documents to STEP in a separate, invisible Inventor instance and record metadata.

.DESCRIPTION
Local export route for the Vault CAD workflow (Job Processor route not used). Requires a licensed
Autodesk Inventor installation on this machine. The script:

  1. starts a NEW Inventor instance over COM and aborts if COM attached to an already running one,
     so an interactive session is never touched;
  2. activates a dedicated single-user project file (<WorkspaceRoot>\<ProjectName>.ipj) whose
     workspace is -WorkspaceRoot, a local mirror of the Vault folder tree ($/ -> WorkspaceRoot),
     so relative references resolve exactly as acquired;
  3. opens each -Document invisibly, records units, model state, occurrence counts, range box and
     unresolved references, exports STEP through Inventor's STEP translator add-in with explicit
     options, hashes the output and writes <name>.export-metadata.json next to <name>.step;
  4. closes documents WITHOUT saving, restores the previously active project, removes the
     temporary project list entry and quits its Inventor instance.

Existing output files are never overwritten. Metadata JSON is evidence for the exchange receipt;
it is not the receipt itself (see docs/exchange-protocol.md).

.EXAMPLE
powershell -NoProfile -File windows\Export-InventorStep.ps1 -WorkspaceRoot C:\path\.cache\vault-workspace `
  -Document 'C:\path\.cache\vault-workspace\DATA\PROJECTS\X\Assembly.iam' -OutputDirectory U:\exchange\evidence\run\exports
#>
param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string[]]$Document,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidateSet(2, 3, 4, 5)][int]$ApplicationProtocolType = 3,
    [string]$ProjectName = "vault-cad-exporter",
    # Single-user project template; Inventor's stock Default.ipj has no workspace entry, so the
    # workspace is the folder containing the copied .ipj (the DesignProjects COM collection on
    # Inventor 2025 exposes AddExisting but no AddNew).
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj",
    # acquisition.json from Get-VaultDependencySnapshot.ps1: every document Inventor actually opens
    # (root and all referenced documents) must be listed there and hash identically now, otherwise the
    # export is refused. This binds the output to exact Vault versions rather than to file names.
    [string]$Acquisition,
    # Unresolved references normally refuse the export; pass this only for a deliberate partial export.
    [switch]$AllowUnresolvedReferences
)
$ErrorActionPreference = "Stop"
$acquisitionRecords = $null
if ($Acquisition) {
    if (-not (Test-Path -LiteralPath $Acquisition)) { throw "Acquisition record not found: $Acquisition" }
    $acquisitionRecords = @{}
    foreach ($a in (Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json).files) { $acquisitionRecords[([string]$a.local_path).ToLowerInvariant()] = $a }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
foreach ($d in $Document) { if (-not (Test-Path -LiteralPath $d)) { throw "Document not found: $d" } }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$protocolNames = @{ 2 = "AP203"; 3 = "AP214"; 4 = "AP203E2"; 5 = "AP242" }
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
$kAssemblyDocument = 12291
$kFileBrowseIOMechanism = 13059
$stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"

# COM parameterized properties (NameValueMap.Name(i)/Value(name)) need reflection from PowerShell.
function Get-MapName($map, $index) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($index)) }
function Get-MapValue($map, $key) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($key)) }
function Set-MapValue($map, $key, $value) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($key, $value)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
function Utc { [DateTime]::UtcNow.ToString("o") }
# Walk the occurrence tree explicitly: PowerShell's COM binding does not enumerate
# ComponentOccurrences.AllLeafOccurrences reliably (it yields a single item).
function Measure-Occurrences($occurrences, $acc) {
    foreach ($o in $occurrences) {
        if ($o.Suppressed) { $acc.suppressed++; continue }
        if ($o.DefinitionDocumentType -eq 12290) {        # kPartDocumentObject
            $acc.leaves++
            try { $acc.docs[$o.Definition.Document.FullFileName] = 1; $acc.bodies += $o.Definition.SurfaceBodies.Count } catch { $acc.unreadable++ }
        } elseif ($o.DefinitionDocumentType -eq 12291) {  # kAssemblyDocumentObject
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

$session = [ordered]@{
    started_at = Utc; host = $env:COMPUTERNAME; user = $env:USERNAME
    inventor_version = $app.SoftwareVersion.DisplayVersion; inventor_build = $app.SoftwareVersion.BuildIdentifier
    inventor_pid = $newPids; workspace_root = $WorkspaceRoot; project_file = $null
    application_protocol_type = $ApplicationProtocolType; protocol = $protocolNames[$ApplicationProtocolType]
    exports = @(); errors = @()
}
Write-Output "New Inventor instance pid $($newPids -join ',') version $($session.inventor_version) build $($session.inventor_build)"

$dpm = $null; $proj = $null; $previous = $null
try {
    $app.Visible = $false
    $app.SilentOperation = $true
    $dpm = $app.DesignProjectManager
    $previous = $dpm.ActiveDesignProject.FullFileName
    $ipj = Join-Path $WorkspaceRoot "$ProjectName.ipj"
    if (-not (Test-Path -LiteralPath $ipj)) {
        if (-not (Test-Path -LiteralPath $TemplateProject)) { throw "Project template not found: $TemplateProject" }
        Copy-Item -LiteralPath $TemplateProject -Destination $ipj
        Write-Output "Created project file $ipj from $TemplateProject"
    }
    foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $ipj) { $proj = $p } }
    if (-not $proj) { $proj = $dpm.DesignProjects.AddExisting($ipj) }
    $proj.Activate($false)
    $active = $dpm.ActiveDesignProject
    $session.project_file = $active.FullFileName
    Write-Output "Active project: $($active.FullFileName) (workspace '$($active.WorkspacePath)'); previously: $previous"

    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid)
    if (-not $translator.Activated) { $translator.Activate() }
    $to = $app.TransientObjects

    foreach ($docPath in $Document) {
        $name = [IO.Path]::GetFileNameWithoutExtension($docPath)
        $stepPath = Join-Path $OutputDirectory "$name.step"
        $metaPath = Join-Path $OutputDirectory "$name.export-metadata.json"
        if ((Test-Path -LiteralPath $stepPath) -or (Test-Path -LiteralPath $metaPath)) { throw "Refusing to overwrite existing output for $name" }
        Write-Output "Opening $docPath"
        $opened = [Diagnostics.Stopwatch]::StartNew()
        $doc = $app.Documents.Open($docPath, $false)
        try {
            $meta = [ordered]@{
                document = $doc.FullFileName; document_type = $doc.DocumentType
                is_assembly = ($doc.DocumentType -eq $kAssemblyDocument); open_seconds = [Math]::Round($opened.Elapsed.TotalSeconds, 1)
                inventor_version = $session.inventor_version; inventor_build = $session.inventor_build
                workspace_root = $WorkspaceRoot; project_file = $session.project_file
            }
            $units = [int]$doc.UnitsOfMeasure.LengthUnits
            $meta.length_units = if ($lengthUnitNames.ContainsKey($units)) { $lengthUnitNames[$units] } else { "enum $units" }
            $missing = @(); $direct = @()
            foreach ($fd in $doc.File.ReferencedFileDescriptors) { $direct += $fd.FullFileName; if ($fd.ReferenceMissing) { $missing += $fd.FullFileName } }
            $allDocs = @(); foreach ($rd in $doc.AllReferencedDocuments) { $allDocs += $rd.FullFileName; foreach ($fd in $rd.File.ReferencedFileDescriptors) { if ($fd.ReferenceMissing -and ($missing -notcontains $fd.FullFileName)) { $missing += $fd.FullFileName } } }
            $meta.direct_reference_count = $direct.Count
            $meta.all_referenced_documents = $allDocs
            $meta.all_referenced_document_count = $allDocs.Count
            $meta.unresolved_references = $missing
            if ($missing.Count -gt 0 -and -not $AllowUnresolvedReferences) { throw "Export refused: $($missing.Count) unresolved reference(s): $($missing -join '; ')" }
            if ($acquisitionRecords -ne $null) {
                $inputs = @(); $bad = 0
                foreach ($p in (@($doc.FullFileName) + $allDocs)) {
                    $rec = $acquisitionRecords[$p.ToLowerInvariant()]
                    $cur = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
                    $ok = [bool]($rec -and ([string]$rec.sha256 -eq $cur))
                    if (-not $ok) { $bad++ }
                    $inputs += [ordered]@{ path = $p; vault_path = $(if ($rec) { $rec.vault_path } else { $null }); version_id = $(if ($rec) { [string]$rec.version_id } else { $null }); master_id = $(if ($rec) { [string]$rec.master_id } else { $null })
                        acquisition_sha256 = $(if ($rec) { $rec.sha256 } else { $null }); current_sha256 = $cur; verified = $ok }
                }
                $meta.native_inputs = $inputs; $meta.native_input_count = $inputs.Count; $meta.native_inputs_verified = ($bad -eq 0); $meta.acquisition_record = $Acquisition
                if ($bad -gt 0) { throw "Export refused: $bad of $($inputs.Count) opened native document(s) are missing from or differ from $Acquisition" }
            }
            $cd = $doc.ComponentDefinition
            try { $meta.model_state = $cd.ModelStates.ActiveModelState.Name; $meta.model_state_count = $cd.ModelStates.Count } catch { $meta.model_state = "not available"; $meta.model_state_count = $null }
            if ($meta.is_assembly) {
                $meta.occurrence_count = $cd.Occurrences.Count
                $acc = @{ leaves = 0; suppressed = 0; subassemblies = 0; other = 0; bodies = 0; unreadable = 0; docs = @{} }
                Measure-Occurrences $cd.Occurrences $acc
                $meta.leaf_occurrence_count = $acc.leaves
                $meta.suppressed_occurrences = $acc.suppressed
                $meta.subassembly_occurrences = $acc.subassemblies
                $meta.other_occurrences = $acc.other
                $meta.distinct_leaf_documents = $acc.docs.Count
                $meta.leaf_body_count = $acc.bodies
                $meta.unreadable_leaf_definitions = $acc.unreadable
            } else {
                $meta.solid_body_count = $cd.SurfaceBodies.Count
            }
            $rb = $cd.RangeBox
            $meta.range_box_cm = [ordered]@{ min = @($rb.MinPoint.X, $rb.MinPoint.Y, $rb.MinPoint.Z); max = @($rb.MaxPoint.X, $rb.MaxPoint.Y, $rb.MaxPoint.Z) }
            $meta.extent_cm = @(($rb.MaxPoint.X - $rb.MinPoint.X), ($rb.MaxPoint.Y - $rb.MinPoint.Y), ($rb.MaxPoint.Z - $rb.MinPoint.Z))

            $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
            $opts = $to.CreateNameValueMap()
            $defaults = [ordered]@{}
            if ($translator.HasSaveCopyAsOptions($doc, $ctx, $opts)) { $defaults = Read-Map $opts }
            $meta.translator_default_options = $defaults
            Set-MapValue $opts "ApplicationProtocolType" $ApplicationProtocolType
            if ($defaults.Contains("IncludeSketches")) { Set-MapValue $opts "IncludeSketches" $false }
            $meta.translator_options_used = Read-Map $opts
            $meta.protocol = $protocolNames[$ApplicationProtocolType]
            $medium = $to.CreateDataMedium(); $medium.FileName = $stepPath
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $translator.SaveCopyAs($doc, $ctx, $opts, $medium)
            $sw.Stop()
            if (-not (Test-Path -LiteralPath $stepPath)) { throw "Translator reported success but $stepPath does not exist" }
            $item = Get-Item -LiteralPath $stepPath
            $meta.output = $stepPath; $meta.output_bytes = $item.Length
            $meta.sha256 = (Get-FileHash -LiteralPath $stepPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $meta.export_seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            $meta.exported_at = Utc
            $meta.native_saved = $false
            $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metaPath -Encoding UTF8
            $session.exports += $meta
            Write-Output ("Exported {0}: {1} bytes, sha256 {2}, {3}s, units {4}, model state '{5}', refs {6}, unresolved {7}, occurrences {8}, leaves {9} (suppressed {10}), bodies {11}" -f $name, $meta.output_bytes, $meta.sha256, $meta.export_seconds, $meta.length_units, $meta.model_state, $meta.all_referenced_document_count, $missing.Count, $meta.occurrence_count, $meta.leaf_occurrence_count, $meta.suppressed_occurrences, $(if ($meta.is_assembly) { $meta.leaf_body_count } else { $meta.solid_body_count }))
        } finally {
            $doc.Close($true)   # SkipSave: never write conversion-induced changes to native files
        }
    }
} catch {
    $session.errors += $_.Exception.Message
    Write-Output "ERROR: $($_.Exception.Message)"
} finally {
    try {
        if ($dpm -and $previous) { foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $previous) { $p.Activate($false) } } }
        if ($proj) { $proj.Remove() }   # drop the temporary entry from the user's project list; the .ipj file stays
    } catch { Write-Output "Could not restore the project list: $($_.Exception.Message)" }
    try { $app.Quit() } catch { Write-Output "Quit failed: $($_.Exception.Message)" }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
    $session.finished_at = Utc
    $session | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "export-session.json") -Encoding UTF8
    Write-Output "Session record: $(Join-Path $OutputDirectory 'export-session.json')"
}
if ($session.errors.Count -gt 0) { exit 1 }
