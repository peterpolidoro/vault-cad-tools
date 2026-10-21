<#
.SYNOPSIS
Offline regression checks for receipt provenance. Uses synthetic records in a temporary
directory; requires neither Inventor nor Vault. Run from Windows PowerShell:
  & .\windows\Test-ExportReceipt.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ("vault-cad-receipt-test-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
$builder = Join-Path $PSScriptRoot 'New-ExportReceipt.ps1'
$passed = 0
try {
    $step = Join-Path $root 'fixture.step'
    $nativePath = Join-Path $root 'fixture.ipt'
    Set-Content -LiteralPath $step -Encoding ASCII -Value "ISO-10303-21;`nHEADER;`nENDSEC;`nDATA;`nENDSEC;`nEND-ISO-10303-21;"
    Set-Content -LiteralPath $nativePath -Encoding ASCII -Value 'synthetic native bytes; not an Inventor file'
    $stepSha = (Get-FileHash -LiteralPath $step -Algorithm SHA256).Hash.ToLowerInvariant()
    $nativeSha = (Get-FileHash -LiteralPath $nativePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $vaultPath = '$/SYNTHETIC/fixture.ipt'
    $base = [ordered]@{
        meta = [ordered]@{
            output = $step; sha256 = $stepSha; output_bytes = (Get-Item -LiteralPath $step).Length
            document = $nativePath; is_assembly = $false; all_referenced_documents = @()
            all_referenced_document_count = 0; unresolved_references = @()
            native_inputs_verified = $true; native_input_count = 1
            native_inputs = @([ordered]@{
                path = $nativePath; vault_path = $vaultPath; version_id = '101'; master_id = '100'
                acquisition_sha256 = $nativeSha; current_sha256 = $nativeSha; verified = $true
            })
        }
        inv = [ordered]@{ vault_id = 'SYNTHETIC'; files = @([ordered]@{
            version_id = '101'; master_id = '100'; vault_path = $vaultPath; role = 'root'
        }) }
        acq = [ordered]@{ files = @([ordered]@{
            version_id = '101'; master_id = '100'; vault_path = $vaultPath
            local_path = $nativePath; sha256 = $nativeSha; bytes = (Get-Item -LiteralPath $nativePath).Length
        }) }
    }
    $serialized = $base | ConvertTo-Json -Depth 12
    $cases = @(
        @{ name = 'valid'; accept = $true; change = { param($d) } },
        @{ name = 'false_verdict'; accept = $false; change = { param($d) $d.meta.native_inputs_verified = $false } },
        @{ name = 'empty_inputs'; accept = $false; change = { param($d) $d.meta.native_inputs = @(); $d.meta.native_input_count = 0 } },
        @{ name = 'missing_inputs'; accept = $false; change = { param($d) $d.meta.PSObject.Properties.Remove('native_inputs') } },
        @{ name = 'hash_mismatch'; accept = $false; change = { param($d) $d.acq.files[0].sha256 = ('0' * 64) } },
        @{ name = 'master_mismatch'; accept = $false; change = { param($d) $d.inv.files[0].master_id = '999' } },
        @{ name = 'version_mismatch'; accept = $false; change = { param($d) $d.meta.native_inputs[0].version_id = '999' } },
        @{ name = 'path_mismatch'; accept = $false; change = { param($d) $d.meta.native_inputs[0].path += '.wrong' } },
        @{ name = 'missing_opened_document'; accept = $false; change = { param($d) $d.meta.all_referenced_documents = @('missing.ipt') } },
        @{ name = 'duplicate_acquisition'; accept = $false; change = { param($d) $d.acq.files = @($d.acq.files[0], $d.acq.files[0]) } },
        @{ name = 'unresolved_reference'; accept = $false; change = { param($d) $d.meta.unresolved_references = @('missing.ipt') } }
    )
    foreach ($case in $cases) {
        $data = $serialized | ConvertFrom-Json
        & ($case.change) $data
        foreach ($kind in @('meta', 'inv', 'acq')) {
            $data.$kind | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $root "$kind.json") -Encoding UTF8
        }
        $output = Join-Path $root ($case.name + '.json')
        $accepted = $false
        try {
            & $builder -Metadata (Join-Path $root 'meta.json') -Inventory (Join-Path $root 'inv.json') -Acquisition (Join-Path $root 'acq.json') -VaultPath $vaultPath -Output $output -RequireVerifiedInputs | Out-Null
            $accepted = $true
        } catch { $message = $_.Exception.Message }
        if ($accepted -ne $case.accept) { throw "FAIL $($case.name): accepted=$accepted; $message" }
        if (-not $case.accept -and (Test-Path -LiteralPath $output)) { throw "FAIL $($case.name): failed receipt was written" }
        if ($case.accept) {
            $receipt = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
            if (-not $receipt.source.native_inputs_verified -or $receipt.source.native_input_count -ne 1) { throw 'FAIL valid receipt fields' }
        }
        $passed++
        Write-Output "PASS $($case.name)"
    }
    Write-Output "$passed offline receipt checks passed"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
