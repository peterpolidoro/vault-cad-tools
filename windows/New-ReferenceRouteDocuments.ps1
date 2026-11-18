<#
.SYNOPSIS
The two documents of the reference route (docs/native-checkin-adapter-design.md, 5.4 and 5.5): a wrapper part whose
only content is a STEP file as a reference model, and an assembly that places only the wrapper. New documents in a
scratch workspace; no existing document is opened or saved, and Vault is not contacted.

.DESCRIPTION
    & .\windows\New-ReferenceRouteDocuments.ps1 -StepFile WORKSPACE\...\X.step -ExpectedStepSha256 SHA `
        -WorkspaceRoot WORKSPACE -AssemblyName reference-pilot-01.iam -OutputDirectory NEW [-WrapperName X-reference.ipt]

-WorkspaceRoot stands for Vault's "$": the STEP file lies in it where its Vault folder puts it, and the two new
documents are saved beside it, so that the three files have in the workspace the places they would have in Vault.

  1. a NEW part, <WrapperName> (default: the STEP file's name with "-reference.ipt"), whose only content is the
     STEP file imported through ReferenceComponents.ImportedComponents with ReferenceModel = true;
  2. a NEW assembly, <AssemblyName>, with one grounded occurrence of the wrapper at the origin;
  3. both are closed, then the assembly is opened again and what it and the wrapper say of their references is
     read: is the STEP file still linked, found beside the wrapper, and up to date. Nothing is saved then.

    & .\windows\New-ReferenceRouteDocuments.ps1 -ReopenOnly -StepFile ... -ExpectedStepSha256 SHA -WorkspaceRoot OTHER `
        -AssemblyName reference-pilot-01.iam -OutputDirectory NEW -ExpectedWrapperSha256 SHA -ExpectedAssemblySha256 SHA

-ReopenOnly makes nothing: it does step 3 on documents that exist, for a workspace that was copied or moved to
another place. That is the test of how the wrapper holds the STEP file: by a place relative to itself (the link
holds wherever the three files are moved together, as a Vault workspace needs) or by the path it was made at.

Recorded for both documents: size and SHA-256; every entry of File.ReferencedFileDescriptors (the full name, the
name Inventor resolves it to, the relative name, the library, the location type, the internal name of the file
referenced, and whether the reference is missing or its location differs); AllReferencedDocuments; for the
wrapper the imported component (LinkedToFile, IsEmbedded, HealthStatus), the bodies and the solids. Every file
of the workspace is hashed before Inventor starts and after it has exited: making the documents may add the two
files and nothing else, -ReopenOnly may change nothing.

iLogic: nothing is switched off. The record says whether the iLogic add-in is loaded, which templates the two
documents were made from, and whether the documents hold a rule or an event trigger; the dialog watchdog records
every dialog of the owned instance and dismisses none that offers a choice.

Inventor is started inside the try whose finally stops it; the record is always written.
Outputs: reference-route-documents.json, documents.log, dialogs.log. Exit code 1 unless the status is "complete".
#>
param(
    [Parameter(Mandatory = $true)][string]$StepFile,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedStepSha256,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._-]*\.iam$')][string]$AssemblyName,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._-]*\.ipt$')][string]$WrapperName,
    [switch]$ReopenOnly,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedWrapperSha256,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedAssemblySha256,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-reference-route",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")
. (Join-Path $PSScriptRoot "Package-Format.ps1")   # the hashes of a directory; also Step-Header.ps1 and Step-Units.ps1

function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha([string]$file) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() }
foreach ($required in @($StepFile, $WorkspaceRoot)) { if (-not (Test-Path -LiteralPath $required)) { throw "Not found: $required" } }
$StepFile = (Resolve-Path -LiteralPath $StepFile).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\')
if (-not $StepFile.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant() + '\')) { throw "The STEP file is not inside the workspace root: $StepFile" }
$stepSha = Sha $StepFile
if ($stepSha -ne $ExpectedStepSha256.ToLowerInvariant()) { throw "The STEP file hashes as $stepSha, not as the expected $ExpectedStepSha256" }
if (-not $WrapperName) { $WrapperName = [IO.Path]::GetFileNameWithoutExtension($StepFile) + "-reference.ipt" }
$folder = Split-Path -Parent $StepFile
$wrapper = Join-Path $folder $WrapperName; $assembly = Join-Path $folder $AssemblyName
if ($ReopenOnly) {
    foreach ($existing in @($wrapper, $assembly)) { if (-not (Test-Path -LiteralPath $existing)) { throw "-ReopenOnly: not found: $existing" } }
    if ($ExpectedWrapperSha256 -and (Sha $wrapper) -ne $ExpectedWrapperSha256.ToLowerInvariant()) { throw "The wrapper hashes as $(Sha $wrapper), not as the expected $ExpectedWrapperSha256" }
    if ($ExpectedAssemblySha256 -and (Sha $assembly) -ne $ExpectedAssemblySha256.ToLowerInvariant()) { throw "The assembly hashes as $(Sha $assembly), not as the expected $ExpectedAssemblySha256" }
} else {
    foreach ($existing in @($wrapper, $assembly)) { if (Test-Path -LiteralPath $existing) { throw "Already exists, refusing to overwrite: $existing" } }
}
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
if ($OutputDirectory.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant() + '\') -or $OutputDirectory -ieq $WorkspaceRoot) { throw "The output directory must not lie inside the workspace root" }
$logFile = Join-Path $OutputDirectory "documents.log"
function Log([string]$line) { Add-Content -LiteralPath $logFile -Value "$(Utc) $line"; Write-Output $line }
function Relative([string]$file) { if ($file.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant() + '\')) { return $file.Substring($WorkspaceRoot.Length + 1) }; return $file }
function Read-Given([scriptblock]$query) {
    # What the API gives, as it gives it; nothing stays nothing, and a read that fails is recorded as such.
    try { $value = & $query; if ($null -eq $value) { return $null }; if ($value -is [string] -or $value -is [bool] -or $value -is [int] -or $value -is [double]) { return $value }; return "$value" }
    catch { $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }; return "unreadable: $($inner.Message)" }
}
$healthNames = @{}; $locationNames = @{}; $fileTypeNames = @{}
try {
    # the names of three enumerations, from the interop assembly on disk; without it the numbers stand alone
    $interop = [Reflection.Assembly]::LoadFrom("$env:ProgramFiles\Autodesk\Inventor 2025\Bin\Public Assemblies\Autodesk.Inventor.Interop.dll")
    foreach ($pair in @(@("Inventor.HealthStatusEnum", $healthNames), @("Inventor.LocationTypeEnum", $locationNames), @("Inventor.FileTypeEnum", $fileTypeNames))) {
        $enumType = $interop.GetType($pair[0]); foreach ($enumName in [Enum]::GetNames($enumType)) { $pair[1][[int][Enum]::Parse($enumType, $enumName)] = $enumName }
    }
} catch { }
function Get-EnumName($names, $value) { if ($value -is [int] -and $names.ContainsKey($value)) { return $names[$value] }; return $null }
function Get-Descriptors($document) {
    # Every file the document's file references (Inventor.FileDescriptor): where Inventor finds it and what the file holds of it.
    $list = @()
    $collection = $document.File.ReferencedFileDescriptors
    for ($i = 1; $i -le $collection.Count; $i++) {
        $descriptor = $collection.Item($i)
        $full = [string]$descriptor.FullFileName; $location = Read-Given { $descriptor.LocationType }; $fileType = Read-Given { $descriptor.ReferencedFileType }
        $list += [ordered]@{ full_file_name = $full; below_the_workspace_root = (Relative $full); inside_the_workspace_root = ($full -ne (Relative $full)); exists_on_disk = (Test-Path -LiteralPath $full)
            resolved_full_file_name = (Read-Given { $descriptor.ResolvedFullFileName }); relative_file_name = (Read-Given { $descriptor.RelativeFileName }); library_name = (Read-Given { $descriptor.LibraryName })
            location_type = $location; location_type_name = (Get-EnumName $locationNames $location); referenced_file_type = $fileType; referenced_file_type_name = (Get-EnumName $fileTypeNames $fileType)
            referenced_file_internal_name = (Read-Given { $descriptor.ReferencedFileInternalName }); file_save_counter = (Read-Given { $descriptor.FileSaveCounter })
            reference_missing = (Read-Given { $descriptor.ReferenceMissing }); reference_disabled = (Read-Given { $descriptor.ReferenceDisabled }); reference_replaced = (Read-Given { $descriptor.ReferenceReplaced })
            reference_location_different = (Read-Given { $descriptor.ReferenceLocationDifferent }); reference_internal_name_different = (Read-Given { $descriptor.ReferenceInternalNameDifferent }) }
    }
    return $list   # bare: callers wrap with @(...)
}
function Get-AllReferenced($document) {
    $list = @(); $collection = $document.AllReferencedDocuments
    for ($i = 1; $i -le $collection.Count; $i++) { $list += (Relative ([string]$collection.Item($i).FullFileName)) }
    return $list   # bare: callers wrap with @(...)
}
function Get-ILogicTraces($document) {
    # Whether a document holds an iLogic rule or an event trigger: the names of its property sets and attribute sets that say so.
    $names = @()
    try { $sets = $document.PropertySets; for ($i = 1; $i -le $sets.Count; $i++) { $set = $sets.Item($i); foreach ($text in @([string]$set.Name, [string]$set.DisplayName, [string]$set.InternalName)) { if ($text -match 'iLogic') { $names += "property set: $text"; break } } } } catch { $names += "property sets unreadable: $($_.Exception.Message)" }
    try { $sets = $document.AttributeSets; for ($i = 1; $i -le $sets.Count; $i++) { $text = [string]$sets.Item($i).Name; if ($text -match 'iLogic') { $names += "attribute set: $text" } } } catch { $names += "attribute sets unreadable: $($_.Exception.Message)" }
    return $names   # bare: callers wrap with @(...)
}
function Get-WrapperFacts($document) {
    # The imported components of a wrapper part, its bodies, and what its file references.
    $definition = $document.ComponentDefinition
    $components = @(); $imported = $definition.ReferenceComponents.ImportedComponents
    for ($i = 1; $i -le $imported.Count; $i++) {
        $component = $imported.Item($i); $health = Read-Given { $component.HealthStatus }
        $components += [ordered]@{ name = (Read-Given { $component.Name }); linked_to_file = (Read-Given { $component.LinkedToFile }); is_embedded = (Read-Given { $component.IsEmbedded }); suppress_link_to_file = (Read-Given { $component.SuppressLinkToFile })
            health_status = $health; health_status_name = (Get-EnumName $healthNames $health)
            referenced_file = (Read-Given { $component.ReferencedFile.FullFileName }); reference_model = (Read-Given { $component.Definition.ReferenceModel }) }
    }
    $bodies = $definition.SurfaceBodies; $solids = 0; for ($i = 1; $i -le $bodies.Count; $i++) { if ($bodies.Item($i).IsSolid -eq $true) { $solids++ } }
    $box = $null
    try { $range = $definition.RangeBox; $low = $range.MinPoint; $high = $range.MaxPoint; $box = [ordered]@{ min = @(([double]$low.X * 10), ([double]$low.Y * 10), ([double]$low.Z * 10)); max = @(([double]$high.X * 10), ([double]$high.Y * 10), ([double]$high.Z * 10)) } } catch { $box = "unreadable: $($_.Exception.Message)" }
    return [ordered]@{ imported_components = $components; surface_bodies = [int]$bodies.Count; solid_bodies = $solids; features = (Read-Given { $definition.Features.Count }); range_box_mm = $box
        file_internal_name = (Read-Given { $document.File.InternalName })
        referenced_file_descriptors = @(Get-Descriptors $document); all_referenced_documents = @(Get-AllReferenced $document); ilogic = @(Get-ILogicTraces $document); dirty = (Read-Given { $document.Dirty }) }
}

$kPart = 12290; $kAssembly = 12291; $upToDate = 11778; $iLogicAddIn = "{3BDD8D79-2179-4B11-8A5A-257B1C0263AC}"
$session = $null; $project = $null; $watchdog = $null; $dialogs = $null; $shutdown = $null; $errors = @(); $before = $null; $integrity = $null; $status = "FAILED"
$record = [ordered]@{ schema_version = 1; generated_at = (Utc); script = "windows/New-ReferenceRouteDocuments.ps1"; mode = $(if ($ReopenOnly) { "reopen_only" } else { "make_and_reopen" }); status = $status
    scope = "new documents in a scratch workspace; no existing document is opened or saved; Vault is not contacted"
    inputs = [ordered]@{ workspace_root = $WorkspaceRoot; step_file = (Relative $StepFile); step_sha256 = $stepSha; step_bytes = (Get-Item -LiteralPath $StepFile).Length; wrapper = (Relative $wrapper); assembly = (Relative $assembly) } }
try {
    $before = Get-PackageDirectoryHashes $WorkspaceRoot
    $session = Start-IsolatedInventor
    $app = $session.App
    Log "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build))"
    $watchdog = Start-DialogWatchdog -OwnerPid $session.Pid -MainFrameHandle ([int64]$app.MainFrameHWND) -LogPath (Join-Path $OutputDirectory "dialogs.log")
    try {
        $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
        Log "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); created file: $($project.CreatedFile))"
        $addIn = $null; try { $addIn = $app.ApplicationAddIns.ItemById($iLogicAddIn) } catch { }
        $record.ilogic = [ordered]@{ add_in_found = ($null -ne $addIn); add_in_activated = $(if ($addIn) { Read-Given { $addIn.Activated } } else { $null }); add_in_name = $(if ($addIn) { Read-Given { $addIn.DisplayName } } else { $null })
            done_about_it = "nothing switched off or changed; the documents below say whether they hold a rule or an event trigger, and the dialog record says what appeared" }
        if (-not $ReopenOnly) {
            # ---- 1. the wrapper: a new part whose only content is the STEP file as a reference model ----
            $partTemplate = [string]$app.FileManager.GetTemplateFile($kPart)
            $part = $app.Documents.Add($kPart, $partTemplate, $false)
            try {
                $imported = $part.ComponentDefinition.ReferenceComponents.ImportedComponents
                $definition = $imported.CreateDefinition($StepFile)
                $default = Read-Given { $definition.ReferenceModel }
                $definition.ReferenceModel = $true
                if ($definition.ReferenceModel -ne $true) { throw "ReferenceModel could not be set on the import definition" }
                $component = $imported.Add($definition)
                $record.made_wrapper = [ordered]@{ template = $partTemplate; definition_type = $definition.GetType().Name; reference_model_by_default = $default; import_units_type = (Read-Given { $definition.ImportUnitsType }); imported_component = (Read-Given { $component.Name }) }
                $part.SaveAs($wrapper, $false)
                $record.made_wrapper.facts_when_saved = Get-WrapperFacts $part
                Log "Saved $(Relative $wrapper): $($record.made_wrapper.facts_when_saved.solid_bodies) solid(s), $(@($record.made_wrapper.facts_when_saved.referenced_file_descriptors).Count) file reference(s)"
            } finally { try { $part.Close($true) } catch { $errors += "wrapper close: $($_.Exception.Message)" } }
            # ---- 2. the assembly: a new assembly that places only the wrapper ----
            $assemblyTemplate = [string]$app.FileManager.GetTemplateFile($kAssembly)
            $made = $app.Documents.Add($kAssembly, $assemblyTemplate, $false)
            try {
                $occurrence = $made.ComponentDefinition.Occurrences.Add($wrapper, $app.TransientGeometry.CreateMatrix())
                $occurrence.Grounded = $true
                $made.SaveAs($assembly, $false)
                $record.made_assembly = [ordered]@{ template = $assemblyTemplate; occurrences = [int]$made.ComponentDefinition.Occurrences.Count; occurrence_name = (Read-Given { $occurrence.Name }); grounded = (Read-Given { $occurrence.Grounded })
                    referenced_file_descriptors = @(Get-Descriptors $made); all_referenced_documents = @(Get-AllReferenced $made); ilogic = @(Get-ILogicTraces $made) }
                Log "Saved $(Relative $assembly): $($record.made_assembly.occurrences) occurrence(s), $(@($record.made_assembly.referenced_file_descriptors).Count) file reference(s)"
            } finally { try { $made.Close($true) } catch { $errors += "assembly close: $($_.Exception.Message)" } }
            if ([int]$app.Documents.Count -ne 0) { throw "Documents are still open after both were closed: $($app.Documents.Count)" }
        }
        $record.files = [ordered]@{ wrapper = [ordered]@{ path = (Relative $wrapper); bytes = (Get-Item -LiteralPath $wrapper).Length; sha256 = (Sha $wrapper) }; assembly = [ordered]@{ path = (Relative $assembly); bytes = (Get-Item -LiteralPath $assembly).Length; sha256 = (Sha $assembly) } }
        # ---- 3. the assembly opened again: does the link hold ----
        $opened = $app.Documents.Open($assembly, $false)
        try {
            $occurrences = $opened.ComponentDefinition.Occurrences
            $placed = @(); for ($i = 1; $i -le $occurrences.Count; $i++) { $one = $occurrences.Item($i); $placed += [ordered]@{ name = (Read-Given { $one.Name }); places = (Relative ([string]$one.Definition.Document.FullFileName)); grounded = (Read-Given { $one.Grounded }); suppressed = (Read-Given { $one.Suppressed }) } }
            $reopened = [ordered]@{ assembly = [ordered]@{ occurrences = $placed; file_internal_name = (Read-Given { $opened.File.InternalName }); referenced_file_descriptors = @(Get-Descriptors $opened); all_referenced_documents = @(Get-AllReferenced $opened); ilogic = @(Get-ILogicTraces $opened); dirty = (Read-Given { $opened.Dirty }) }; wrapper = $null }
            $wrapperDocument = $null
            for ($i = 1; $i -le $opened.AllReferencedDocuments.Count; $i++) { $candidate = $opened.AllReferencedDocuments.Item($i); if ([string]$candidate.FullFileName -ieq $wrapper) { $wrapperDocument = $candidate } }
            if ($null -eq $wrapperDocument) { throw "The assembly opened again does not reference the wrapper at $(Relative $wrapper)" }
            $reopened.wrapper = Get-WrapperFacts $wrapperDocument
            $record.reopened = $reopened
            $components = @($reopened.wrapper.imported_components); $references = @($reopened.wrapper.referenced_file_descriptors)
            $holds = [ordered]@{ the_assembly_places_only_the_wrapper = ($placed.Count -eq 1 -and $placed[0].places -ieq (Relative $wrapper))
                the_wrapper_has_one_imported_component = ($components.Count -eq 1)
                it_is_linked_to_a_file = ($components.Count -eq 1 -and $components[0].linked_to_file -eq $true)
                it_is_up_to_date = ($components.Count -eq 1 -and $components[0].health_status -eq $upToDate)
                the_wrapper_references_one_file = ($references.Count -eq 1)
                that_file_is_the_step_file_beside_it = ($references.Count -eq 1 -and $references[0].full_file_name -ieq $StepFile -and $references[0].reference_missing -eq $false)
                the_wrapper_has_one_solid = ($reopened.wrapper.solid_bodies -eq 1)
                nothing_is_dirty = ($reopened.assembly.dirty -eq $false -and $reopened.wrapper.dirty -eq $false) }
            $record.link = [ordered]@{ holds = (@($holds.Values | Where-Object { $_ -ne $true }).Count -eq 0); checks = $holds }
            Log "Opened again: the link holds = $($record.link.holds) ($(@($holds.Keys | Where-Object { $holds[$_] -ne $true }) -join ', '))"
        } finally { try { $opened.Close($true) } catch { $errors += "close after reopening: $($_.Exception.Message)" } }
    } catch { $errors += $_.Exception.Message; Log "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace } }
} catch { $errors += $_.Exception.Message
} finally {
    if ($session) { try { $shutdown = Stop-IsolatedInventor $session $project } catch { $errors += "stop: $($_.Exception.Message)" } }
    if ($watchdog) { try { $dialogs = Stop-DialogWatchdog $watchdog } catch { $errors += "watchdog: $($_.Exception.Message)" } }
}
if ($session -and (-not $shutdown -or -not $shutdown.Succeeded)) { $errors += "the shutdown of the owned instance was not observed as complete" }
# ---- the workspace afterwards: the two new files and nothing else; with -ReopenOnly nothing at all ----
try {
    $compared = Compare-PackageDirectoryHashes $before (Get-PackageDirectoryHashes $WorkspaceRoot)
    $allowed = $(if ($ReopenOnly) { @() } else { @((Relative $wrapper), (Relative $assembly)) })
    $unexpected = @(@($compared.changed) + @($compared.removed) + @(@($compared.added) | Where-Object { $allowed -notcontains ($_ -replace '/', '\') }))
    $missing = @($allowed | Where-Object { @(@($compared.added) | ForEach-Object { $_ -replace '/', '\' }) -notcontains $_ })
    $integrity = [ordered]@{ files_before = $compared.files_before; files_after = $compared.files_after; added = @($compared.added); changed = @($compared.changed); removed = @($compared.removed); unexpected = $unexpected; expected_and_not_added = $missing }
    if ($unexpected.Count -gt 0) { $errors += "the workspace changed beyond the two new files: $($unexpected -join '; ')" }
    if ($missing.Count -gt 0 -and $errors.Count -eq 0) { $errors += "not added: $($missing -join '; ')" }
} catch { $errors += "workspace comparison: $($_.Exception.Message)" }
$record.workspace = $integrity
$record.session = $(if ($session) { [ordered]@{ pid = $session.Pid; inventor = "$($session.Version) build $($session.Build)"; shutdown = $(if ($shutdown) { [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited } } else { $null }) } } else { $null })
$record.project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; previous_active = $project.PreviousActive; entry_added_by_run = $project.AddedEntry; created_file = $project.CreatedFile; entry_removed_by_run = $(if ($shutdown) { $shutdown.ProjectEntryRemoved } else { $null }); previous_restored = $(if ($shutdown) { $shutdown.PreviousProjectRestored } else { $null }) } } else { $null })
$record.dialogs = $(if ($dialogs) { [ordered]@{ policy = $dialogs.Policy; polls = $dialogs.Polls; seen = $dialogs.Events.Count; dismissed = $dialogs.Dismissed; left_alone = $dialogs.Left; events = @($dialogs.Events); errors = @($dialogs.Errors) } } else { $null })
$record.errors = $errors
if ($errors.Count -eq 0 -and $record.Contains("link") -and $record.link.holds -ne $true) { $status = "link_does_not_hold" }
elseif ($errors.Count -eq 0 -and $record.Contains("link")) { $status = Resolve-RunStatus -Status "complete" -Dialogs $dialogs }
$record.status = $status; $record.finished_at = (Utc)
ConvertTo-Json -InputObject $record -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "reference-route-documents.json") -Encoding UTF8
Log "Status: $status"
if ($status -ne "complete") { exit 1 }
