<#
.SYNOPSIS
Mechanical positive/negative qualification of Export-PartAssets.ps1. Each case states an expected
outcome class and is judged from the exit code (captured immediately), the receipt (status,
shutdown, project fields), the asset count, the semantic output validation and the Inventor process
list, never from prose.

.DESCRIPTION
Requires Inventor (the exporter runs for real). Cases:
  nonempty_output_directory    -> refused_preflight (exception before Inventor; no receipt, no process)
  strict_without_records       -> refused_preflight
  tampered_intermediate_hash   -> refused_after_open (exit 1, receipt FAILED, 0 assets, shutdown succeeded)
  positive_strict              -> complete (exit 0, receipt complete, validation with hashes ok)
  fixture_unbound              -> complete (fixture with -AllowUnboundInputs)
  preregistered_project_entry  -> complete + entry_pre_existed, not removed, still registered; then cleaned up
Writes <OutputRoot>\guard-checks.json plus one <case>.log per case and exits 1 if any case failed.
The interactive Inventor session and its project list are never touched except by the
pre-registration setup/cleanup, which uses separately owned instances and restores the persisted list.
#>
param(
    [Parameter(Mandatory = $true)][string]$NativeAssembly,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$Acquisition,
    [Parameter(Mandatory = $true)][string]$Inventory,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$FixtureAssembly,
    [string]$FixtureWorkspace,
    [int]$ExpectParts = -1,
    [int]$ExpectOccurrences = -1,
    [switch]$SkipPreRegisteredProjectCheck,
    [switch]$FixtureOnly
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")
. (Join-Path $PSScriptRoot "Snapshot-Validation.ps1")
$exporter = Join-Path $PSScriptRoot "Export-PartAssets.ps1"
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$script:cases = @()
function Invoke-Case {
    # Emits progress text; the case record is appended to $script:cases (read $script:cases[-1]).
    param([string]$Name, [string]$Expect, [hashtable]$Arguments, [int]$Parts = -1, [int]$Occurrences = -1)
    $pidsBefore = @(Get-InventorPids)
    $thrown = $null; $exit = $null; $t0 = Get-Date; $lines = New-Object System.Collections.ArrayList
    $global:LASTEXITCODE = 0
    try {
        & $exporter @Arguments 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { if (-not $thrown) { $thrown = $_.Exception.Message }; [void]$lines.Add("ERR: $($_.Exception.Message)") } else { [void]$lines.Add("$_") } }
        $exit = $LASTEXITCODE
    } catch { $thrown = $_.Exception.Message; $exit = $LASTEXITCODE; [void]$lines.Add("THROWN: $thrown") }
    $seconds = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $out = $Arguments.OutputDirectory
    $receipt = $null; if (Test-Path -LiteralPath (Join-Path $out "export-receipt.json")) { try { $receipt = Get-Content -LiteralPath (Join-Path $out "export-receipt.json") -Raw | ConvertFrom-Json } catch { $receipt = [pscustomobject]@{ status = "UNPARSEABLE" } } }
    $assets = if (Test-Path -LiteralPath (Join-Path $out "assets")) { @(Get-ChildItem -LiteralPath (Join-Path $out "assets") -File).Count } else { -1 }
    Start-Sleep -Seconds 2
    $pidsAfter = @(Get-InventorPids); $leaked = @($pidsAfter | Where-Object { $pidsBefore -notcontains $_ })
    $validation = $null; if ($receipt -and $receipt.status -eq "complete") { $validation = Test-SnapshotOutputs -Directory $out -ExpectParts $Parts -ExpectOccurrences $Occurrences -VerifyHashes }
    $shutdownOk = $(if ($receipt -and $receipt.session -and $receipt.session.shutdown) { [bool]$receipt.session.shutdown.succeeded } else { $null })
    $observed = [ordered]@{ thrown = $thrown; exit_code = $exit; receipt_status = $(if ($receipt) { $receipt.status } else { "none" }); receipt_errors = $(if ($receipt) { @($receipt.errors) } else { @() }); assets_written = $assets; leaked_inventor_processes = $leaked.Count
        shutdown_succeeded = $shutdownOk; validation_ok = $(if ($validation) { $validation.ok } else { $null }); validation_failures = $(if ($validation) { @($validation.failures) } else { @() }); validation_summary = $(if ($validation) { $validation.summary } else { $null }); seconds = $seconds }
    $passed = switch ($Expect) {
        "refused_preflight"  { [bool]$thrown -and -not $receipt -and $assets -eq -1 -and $leaked.Count -eq 0 }
        "refused_after_open" { -not $thrown -and $exit -eq 1 -and $receipt -and $receipt.status -eq "FAILED" -and $assets -eq 0 -and $shutdownOk -eq $true -and $leaked.Count -eq 0 }
        "complete"           { -not $thrown -and $exit -eq 0 -and $receipt -and $receipt.status -eq "complete" -and $shutdownOk -eq $true -and $validation -and $validation.ok -and $leaked.Count -eq 0 }
        default              { $false }
    }
    $rec = [ordered]@{ case = $Name; expected = $Expect; passed = [bool]$passed; observed = $observed; output_directory = $out }
    $script:cases += $rec
    $lines | Set-Content -LiteralPath (Join-Path $OutputRoot "$Name.log") -Encoding UTF8
    Write-Output ("## {0}: {1} (expected {2}; exit={3} receipt={4} assets={5} shutdown_ok={6} leaked={7} thrown={8}; {9}s)" -f $Name, $(if ($passed) { "PASS" } else { "FAIL" }), $Expect, $exit, $observed.receipt_status, $assets, $shutdownOk, $leaked.Count, $(if ($thrown) { "'" + $thrown + "'" } else { "no" }), $seconds)
    if ($receipt -and $receipt.errors) { foreach ($e in @($receipt.errors)) { Write-Output "    receipt error: $e" } }
    if ($validation -and -not $validation.ok) { foreach ($f in @($validation.failures)) { Write-Output "    validation: $f" } }
}

$neDir = Join-Path $OutputRoot "neg-nonempty"; New-Item -ItemType Directory -Force -Path $neDir | Out-Null; "stale" | Set-Content -LiteralPath (Join-Path $neDir "stale.txt")
Invoke-Case -Name "nonempty_output_directory" -Expect "refused_preflight" -Arguments @{ NativeAssembly = $NativeAssembly; WorkspaceRoot = $WorkspaceRoot; OutputDirectory = $neDir; Acquisition = $Acquisition; Inventory = $Inventory }
Invoke-Case -Name "strict_without_records" -Expect "refused_preflight" -Arguments @{ NativeAssembly = $NativeAssembly; WorkspaceRoot = $WorkspaceRoot; OutputDirectory = (Join-Path $OutputRoot "neg-norecords") }
if (-not $FixtureOnly) {
    $tampered = Join-Path $OutputRoot "tampered-acquisition.json"
    $acq = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
    $victim = @($acq.files | Where-Object { $_.local_path -like "*.iam" -and $_.local_path -ine $NativeAssembly }) | Select-Object -First 1
    if (-not $victim) { $victim = @($acq.files | Where-Object { $_.local_path -ine $NativeAssembly }) | Select-Object -First 1 }
    $victim.sha256 = ("0" * 64); $acq | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tampered -Encoding UTF8
    Write-Output "tampered record: $($victim.local_path) (version $($victim.version_id)) sha256 set to all zeros"
    Invoke-Case -Name "tampered_intermediate_hash" -Expect "refused_after_open" -Arguments @{ NativeAssembly = $NativeAssembly; WorkspaceRoot = $WorkspaceRoot; OutputDirectory = (Join-Path $OutputRoot "neg-tampered"); Acquisition = $tampered; Inventory = $Inventory }
    Invoke-Case -Name "positive_strict" -Expect "complete" -Parts $ExpectParts -Occurrences $ExpectOccurrences -Arguments @{ NativeAssembly = $NativeAssembly; WorkspaceRoot = $WorkspaceRoot; OutputDirectory = (Join-Path $OutputRoot "part-assets-strict"); Acquisition = $Acquisition; Inventory = $Inventory }
} else { Write-Output "FixtureOnly: strict (Inventor) cases skipped" }
if ($FixtureAssembly -and $FixtureWorkspace) {
    Invoke-Case -Name "fixture_unbound" -Expect "complete" -Arguments @{ NativeAssembly = $FixtureAssembly; WorkspaceRoot = $FixtureWorkspace; OutputDirectory = (Join-Path $OutputRoot "part-assets-fixture"); AllowUnboundInputs = $true }
    if (-not $SkipPreRegisteredProjectCheck) {
        # Ownership is tracked from BEFORE setup: cleanup removes only what setup created; an entry (or .ipj file)
        # present before setup must still be there afterwards. Cleanup runs in finally; its shutdown is part of the verdict.
        $ipj = Join-Path (Resolve-Path -LiteralPath $FixtureWorkspace).Path "vault-cad-exporter.ipj"
        $setupCreatedFile = $false; $setupOwnsEntry = $false; $existedBeforeSetup = $null; $sd = $null; $sd2 = $null; $still = $null; $removed = $null; $preserved = $null; $listAfter = @(); $rec = $null; $proj = $null
        if (-not (Test-Path -LiteralPath $ipj)) { Copy-Item -LiteralPath "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj" -Destination $ipj; $setupCreatedFile = $true }
        $setup = Start-IsolatedInventor
        try { $dpm = $setup.App.DesignProjectManager; $existedBeforeSetup = [bool](Find-ProjectEntry $dpm $ipj); if (-not $existedBeforeSetup) { [void]$dpm.DesignProjects.AddExisting($ipj); $setupOwnsEntry = [bool](Find-ProjectEntry $dpm $ipj) } } finally { $sd = Stop-IsolatedInventor $setup $null }
        Write-Output "pre-registration setup: entry existed before setup=$existedBeforeSetup, added by setup=$setupOwnsEntry, ipj created by setup=$setupCreatedFile, setup shutdown succeeded=$($sd.Succeeded)"
        try {
            Invoke-Case -Name "preregistered_project_entry" -Expect "complete" -Arguments @{ NativeAssembly = $FixtureAssembly; WorkspaceRoot = $FixtureWorkspace; OutputDirectory = (Join-Path $OutputRoot "part-assets-fixture-preregistered"); AllowUnboundInputs = $true }
            $rec = $script:cases[-1]
            $receipt = $null; if (Test-Path -LiteralPath (Join-Path $rec.output_directory "export-receipt.json")) { $receipt = Get-Content -LiteralPath (Join-Path $rec.output_directory "export-receipt.json") -Raw | ConvertFrom-Json }
            $proj = $(if ($receipt) { $receipt.project } else { $null })
        } finally {
            $cleanup = Start-IsolatedInventor
            try {
                $dpm = $cleanup.App.DesignProjectManager; $still = [bool](Find-ProjectEntry $dpm $ipj)
                if ($setupOwnsEntry) { $e = Find-ProjectEntry $dpm $ipj; if ($e) { $e.Remove() }; $removed = -not [bool](Find-ProjectEntry $dpm $ipj) } else { $preserved = [bool](Find-ProjectEntry $dpm $ipj) }
                $listAfter = @((Get-CollectionItems $dpm.DesignProjects) | ForEach-Object { $_.FullFileName })
            } finally { $sd2 = Stop-IsolatedInventor $cleanup $null }
            if ($setupCreatedFile) { try { Remove-Item -LiteralPath $ipj -Force } catch { Write-Output "    cleanup: could not delete setup-created $ipj : $($_.Exception.Message)" } }
        }
        $entryOutcomeOk = $(if ($setupOwnsEntry) { $removed -eq $true } else { $preserved -eq $true })
        $ok = ($null -ne $rec -and $rec.passed) -and $proj -and $proj.entry_pre_existed -eq $true -and $proj.entry_added_by_run -eq $false -and $proj.entry_removed_by_run -eq $false -and $proj.entry_preserved -eq $true -and $proj.previous_restored -eq $true -and $still -eq $true -and $entryOutcomeOk -and $sd.Succeeded -eq $true -and $sd2.Succeeded -eq $true
        if ($null -eq $rec) { $rec = [ordered]@{ case = "preregistered_project_entry"; expected = "complete"; passed = $false; observed = [ordered]@{ error = "exporter case did not run" }; output_directory = $null }; $script:cases += $rec }
        $rec.passed = [bool]$ok
        $rec.observed.preregistered = [ordered]@{ entry_existed_before_setup = $existedBeforeSetup; entry_added_by_setup = $setupOwnsEntry; ipj_created_by_setup = $setupCreatedFile; setup_shutdown_succeeded = $(if ($sd) { $sd.Succeeded }); entry_pre_existed = $(if ($proj) { $proj.entry_pre_existed }); entry_added_by_run = $(if ($proj) { $proj.entry_added_by_run }); entry_removed_by_run = $(if ($proj) { $proj.entry_removed_by_run }); entry_preserved = $(if ($proj) { $proj.entry_preserved }); previous_restored = $(if ($proj) { $proj.previous_restored }); still_registered_after_exporter = $still; removed_by_cleanup = $removed; preserved_by_cleanup = $preserved; persisted_list_after_cleanup = $listAfter; cleanup_shutdown_succeeded = $(if ($sd2) { $sd2.Succeeded }) }
        Write-Output ("## preregistered_project_entry (project-list assertions): {0}; existed_before_setup={1} added_by_setup={2} pre_existed={3} removed_by_run={4} preserved={5} previous_restored={6} still_registered={7} removed_by_cleanup={8} preserved_by_cleanup={9} setup_ok={10} cleanup_ok={11}; list after cleanup: {12}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $existedBeforeSetup, $setupOwnsEntry, $(if ($proj) { $proj.entry_pre_existed }), $(if ($proj) { $proj.entry_removed_by_run }), $(if ($proj) { $proj.entry_preserved }), $(if ($proj) { $proj.previous_restored }), $still, $removed, $preserved, $(if ($sd) { $sd.Succeeded }), $(if ($sd2) { $sd2.Succeeded }), ($listAfter -join '; '))
    }
}
$passedCount = @($script:cases | Where-Object passed).Count; $failedCount = @($script:cases | Where-Object { -not $_.passed }).Count
[ordered]@{ generated_at = [DateTime]::UtcNow.ToString("o"); host = $env:COMPUTERNAME; exporter = $exporter; passed = $passedCount; failed = $failedCount; cases = $script:cases } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot "guard-checks.json") -Encoding UTF8
Write-Output "$passedCount passed, $failedCount failed -> $(Join-Path $OutputRoot 'guard-checks.json')"
if ($failedCount -gt 0) { exit 1 }
