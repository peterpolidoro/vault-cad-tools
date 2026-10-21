<#
.SYNOPSIS
Compose an export receipt (docs/exchange-protocol.md) from exporter metadata and Vault evidence.

.DESCRIPTION
Joins three records that were produced separately and verifiably:
  - <name>.export-metadata.json written by Export-InventorStep.ps1 (translator, options, counts, hash),
  - dependency-inventory.json and acquisition.json written by Get-VaultDependencySnapshot.ps1
    (exact Vault master/version ids, paths, native hashes of what was converted).
The STEP file is re-hashed and must match the metadata. For an assembly, every non-root file in the
inventory becomes a dependency entry with its native hash. Nothing here contacts Vault or Inventor.
#>
param(
    [Parameter(Mandatory = $true)][string]$Metadata,
    [Parameter(Mandatory = $true)][string]$Inventory,
    [Parameter(Mandatory = $true)][string]$Acquisition,
    [Parameter(Mandatory = $true)][string]$VaultPath,
    [string]$Output,
    [string]$Inspection,
    # Refuse to write a receipt unless the exporter verified every opened native document against
    # acquisition.json (Export-InventorStep.ps1 -Acquisition).
    [switch]$RequireVerifiedInputs
)
$ErrorActionPreference = "Stop"
$meta = Get-Content -LiteralPath $Metadata -Raw | ConvertFrom-Json
$inv = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json
$acq = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
$stepPath = $meta.output
if (-not (Test-Path -LiteralPath $stepPath)) { throw "STEP output named in metadata not found: $stepPath" }
$sha = (Get-FileHash -LiteralPath $stepPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sha -ne $meta.sha256) { throw "STEP file hash $sha differs from exporter metadata $($meta.sha256)" }
$src = $inv.files | Where-Object { $_.vault_path -eq $VaultPath } | Select-Object -First 1
if (-not $src) { throw "Vault path not present in the dependency inventory: $VaultPath" }
$acqByVersion = @{}
foreach ($a in $acq.files) {
    $id = [string]$a.version_id
    if (-not $id -or $acqByVersion.ContainsKey($id)) { throw "Missing or duplicate acquisition version id: $id" }
    $acqByVersion[$id] = $a
}
$native = $acqByVersion[[string]$src.version_id]
if (-not $native) { throw "No acquisition record for version $($src.version_id)" }
if ($meta.document -and ($meta.document -ne $native.local_path)) { throw "Exporter converted '$($meta.document)' but the acquisition record for this version is '$($native.local_path)'" }
if (-not $Output) { $Output = [IO.Path]::ChangeExtension($Metadata, $null).TrimEnd('.') -replace '\.export-metadata$', '' ; $Output = "$Output.export.json" }

$receipt = [ordered]@{
    schema_version = 1
    source = [ordered]@{
        vault_id = [string]$inv.vault_id; master_id = [string]$src.master_id; version_id = [string]$src.version_id; path = $VaultPath
        version = $src.version; revision = $src.revision; state = $src.state; folder_id = [string]$src.folder_id
        checkin_date = $src.checkin_date; native_sha256 = $native.sha256; native_bytes = $native.bytes
        acquisition = "$($acq.method) at $($acq.acquired_at)"; local_workspace_mirror = $native.local_path
    }
    exporter = [ordered]@{
        name = "Autodesk Inventor STEP translator add-in via windows/Export-InventorStep.ps1 (COM automation)"
        version = "Inventor $($meta.inventor_version) build $($meta.inventor_build)"
        model_state = $meta.model_state; protocol = $meta.protocol
        application_protocol_type = $meta.translator_options_used.ApplicationProtocolType
        translator_options = $meta.translator_options_used
        route = "separate hidden Inventor instance on $env:COMPUTERNAME; Vault Job Processor not used"
        project_file = $meta.project_file; exported_at = $meta.exported_at; export_seconds = $meta.export_seconds
        native_saved = $meta.native_saved
    }
    sha256 = $sha
    output_bytes = $meta.output_bytes
    validation = [ordered]@{
        length_units = $meta.length_units; model_state_count = $meta.model_state_count
        all_referenced_document_count = $meta.all_referenced_document_count
        unresolved_references = @($meta.unresolved_references)
        occurrence_count = $meta.occurrence_count; leaf_occurrence_count = $meta.leaf_occurrence_count
        subassembly_occurrences = $meta.subassembly_occurrences; suppressed_occurrences = $meta.suppressed_occurrences
        distinct_leaf_documents = $meta.distinct_leaf_documents; leaf_body_count = $meta.leaf_body_count
        solid_body_count = $meta.solid_body_count
        range_box_cm = $meta.range_box_cm; extent_cm = $meta.extent_cm
        extent_in = @($meta.extent_cm | ForEach-Object { [Math]::Round($_ / 2.54, 3) })
    }
}
if ($null -ne $meta.native_inputs) {
    # Verify the join as well as the exporter's verdict. Otherwise a receipt could
    # attach an unrelated acquisition record (or an empty/false verdict) to STEP.
    $inputs = @($meta.native_inputs)
    if ($meta.native_inputs_verified -isnot [bool] -or -not $meta.native_inputs_verified -or $inputs.Count -eq 0) {
        throw "Exporter native-input verification is false, missing, or empty"
    }
    if ($inputs.Count -ne $meta.native_input_count -or $inputs.Count -ne (1 + @($meta.all_referenced_documents).Count)) {
        throw "Native-input count does not match the opened document list"
    }
    $seen = @{}
    foreach ($inputRecord in $inputs) {
        $id = [string]$inputRecord.version_id
        $a = $acqByVersion[$id]
        $matches = @($inv.files | Where-Object { [string]$_.version_id -eq $id })
        if ($inputRecord.verified -isnot [bool] -or -not $inputRecord.verified -or -not $a -or $matches.Count -ne 1) {
            throw "Unverified or ambiguous native input: version $id"
        }
        $v = $matches[0]
        if ($inputRecord.current_sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
            $inputRecord.current_sha256 -ne $inputRecord.acquisition_sha256 -or
            $inputRecord.current_sha256 -ne $a.sha256 -or
            $inputRecord.path -ne $a.local_path -or
            [string]$inputRecord.master_id -ne [string]$a.master_id -or
            [string]$inputRecord.master_id -ne [string]$v.master_id -or
            $inputRecord.vault_path -ne $a.vault_path -or $inputRecord.vault_path -ne $v.vault_path) {
            throw "Native input does not match acquisition/inventory: version $id"
        }
        $key = [string]$inputRecord.path
        if (-not $key -or $seen.ContainsKey($key)) { throw "Missing or duplicate native input path: $key" }
        $seen[$key] = $true
    }
    foreach ($path in (@($meta.document) + @($meta.all_referenced_documents))) {
        if (-not $path -or -not $seen.ContainsKey([string]$path)) { throw "Opened document absent from verified inputs: $path" }
    }
    if ($RequireVerifiedInputs -and @($meta.unresolved_references).Count -gt 0) {
        throw "A verified complete export cannot have unresolved references"
    }
    $receipt.source.native_inputs_verified = [bool]$meta.native_inputs_verified
    $receipt.source.native_input_count = $meta.native_input_count
    $receipt.native_inputs = @($meta.native_inputs)
    # Every opened document must be the acquired exact version.
    $unverified = @($meta.native_inputs | Where-Object { -not $_.verified })
    if ($unverified.Count -gt 0) { throw "Exporter metadata lists $($unverified.Count) unverified native input(s); refusing to write a receipt" }
    $acqVersions = @($acq.files | ForEach-Object { [string]$_.version_id })
    $openedVersions = @($meta.native_inputs | ForEach-Object { [string]$_.version_id })
    $receipt.source.acquired_but_not_opened = @($acqVersions | Where-Object { $openedVersions -notcontains $_ })
} elseif ($RequireVerifiedInputs) {
    throw "Exporter metadata has no native_inputs record; rerun Export-InventorStep.ps1 with -Acquisition"
} else {
    $receipt.source.native_inputs_verified = $false
}
if ($Inspection -and (Test-Path -LiteralPath $Inspection)) {
    $insp = Get-Content -LiteralPath $Inspection -Raw | ConvertFrom-Json
    if ($insp.step_sha256 -ne $sha) { throw "Inspection record hash does not match this STEP file" }
    $receipt.validation.inventor_reimport = [ordered]@{
        route = $insp.import_route; length_units = $insp.length_units; occurrence_count = $insp.occurrence_count
        leaf_occurrence_count = $insp.leaf_occurrence_count; leaf_body_count = $insp.leaf_body_count
        solid_body_count = $insp.solid_body_count; extent_cm = $insp.extent_cm; import_seconds = $insp.import_seconds
    }
}
if ($meta.is_assembly) {
    $deps = @()
    foreach ($d in $inv.files) {
        if ($d.role -eq "root" -or $d.version_id -eq $src.version_id) { continue }
        $n = $acqByVersion[[string]$d.version_id]
        if (-not $n) { throw "Missing acquisition record for dependency version $($d.version_id)" }
        $deps += [ordered]@{ name = $d.name; vault_path = $d.vault_path; master_id = [string]$d.master_id; version_id = [string]$d.version_id
            version = $d.version; revision = $d.revision; state = $d.state; folder_id = [string]$d.folder_id
            native_sha256 = $n.sha256; native_bytes = $n.bytes; referenced_by = @($d.parents) }
    }
    $receipt.dependencies = $deps
    $receipt.dependency_count = $deps.Count
    $receipt.dependency_note = "Vault 'uses' traversal (recursive, version associations) listed $($deps.Count) dependency versions; Inventor resolved $($meta.all_referenced_document_count) referenced documents from the local mirror with $(@($meta.unresolved_references).Count) unresolved."
}
$receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Output -Encoding UTF8
Write-Output "Receipt written: $Output (source version $($receipt.source.version_id), master $($receipt.source.master_id), sha256 $sha)"
