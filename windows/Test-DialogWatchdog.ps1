<#
.SYNOPSIS
Live self-test of the dialog watchdog in Inventor-Session.ps1 WITHOUT Inventor, Vault or network: child
powershell processes show real modal MessageBoxes.
  W1 an informational box (OK only, titled like Inventor's "AIP Migration Errors"): the watchdog must record
     it and dismiss it, so the child exits by itself with code 7;
  W2 a Yes/No question: the watchdog must record it and leave it alone (the test then stops its own child);
  W3 Get-OwnedDialogWindows scoped to one pid: the W2 question of another process is never reported.
Each box appears briefly on the interactive desktop. Run: & .\windows\Test-DialogWatchdog.ps1
#>
param([int]$TimeoutSeconds = 25)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")
$results = @()
function Case($name, [scriptblock]$body) {
    try { $detail = & $body; $script:results += [ordered]@{ case = $name; passed = $true; detail = "$detail" }; Write-Output "PASS $name $(if ($detail) { "- $detail" })" }
    catch { $script:results += [ordered]@{ case = $name; passed = $false; detail = $_.Exception.Message }; Write-Output "FAIL $name - $($_.Exception.Message)" }
}
function Assert($cond, $msg) { if (-not $cond) { throw $msg } }
function Start-DialogChild([string]$title, [string]$buttons) {
    $command = "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('vault-cad-tools dialog watchdog self-test', '$title', [System.Windows.Forms.MessageBoxButtons]::$buttons); exit 7"
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-STA", "-WindowStyle", "Hidden", "-Command", "`"$command`"") -PassThru
}
function Wait-ForDialog([int]$ownerPid, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    do { $windows = @(Get-OwnedDialogWindows -OwnerPid $ownerPid); if ($windows.Count -gt 0) { return ,$windows }; Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt $deadline)
    return ,@()
}
$tempLog = Join-Path $env:TEMP ("vault-cad-watchdog-selftest-" + [guid]::NewGuid().ToString("N") + ".log")
$child1 = $null; $child2 = $null
try {
    Case "W1 informational OK-only box of a child process is recorded and dismissed; the child exits by itself (code 7)" {
        $script:child1 = Start-DialogChild "AIP Migration Errors" "OK"
        $windows = Wait-ForDialog $child1.Id 10
        Assert ($windows.Count -ge 1) "the child's dialog never appeared"
        $watchdog = Start-DialogWatchdog -OwnerPid $child1.Id -LogPath $tempLog -IntervalMilliseconds 300
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not $child1.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        $report = Stop-DialogWatchdog $watchdog
        $hit = @($report.Events | Where-Object { $_.title -eq "AIP Migration Errors" })
        Assert ($child1.HasExited) "child still running after $TimeoutSeconds s; events: $(ConvertTo-Json -InputObject @($report.Events) -Compress -Depth 5); errors: $($report.Errors -join ' | ')"
        Assert ($child1.ExitCode -eq 7) "child exit code $($child1.ExitCode), expected 7 (dialog closed by the watchdog, then exit 7)"
        Assert ($hit.Count -eq 1 -and $hit[0].action -eq "dismiss" -and $hit[0].dismissed -eq $true -and $hit[0].class -eq '#32770' -and (@($hit[0].answer_controls) -join ',') -eq "OK") "event: $(ConvertTo-Json -InputObject $hit -Compress -Depth 5)"
        Assert ((Test-Path -LiteralPath $tempLog) -and @(Get-Content -LiteralPath $tempLog).Count -ge 1) "dialog log not written"
        Assert ($report.Errors.Count -eq 0) "watchdog errors: $($report.Errors -join ' | ')"
        Assert (@($report.Remaining).Count -eq 0) "remaining-at-stop must be empty once the child has exited: $(ConvertTo-Json -InputObject @($report.Remaining) -Compress)"
        "dismissed by step '$(@($hit[0].dismissal)[0].step)' after $($report.Polls) polls"
    }
    Case "W2 Yes/No question of a child process is recorded and LEFT ALONE (the child keeps waiting)" {
        $script:child2 = Start-DialogChild "Watchdog question test" "YesNo"
        $windows = Wait-ForDialog $child2.Id 10
        Assert ($windows.Count -ge 1) "the child's question never appeared"
        $watchdog = Start-DialogWatchdog -OwnerPid $child2.Id -IntervalMilliseconds 300
        Start-Sleep -Seconds 3
        $report = Stop-DialogWatchdog $watchdog
        $hit = @($report.Events | Where-Object { $_.title -eq "Watchdog question test" })
        Assert (-not $child2.HasExited) "the child exited: the watchdog answered a question"
        Assert ($hit.Count -eq 1 -and $hit[0].action -eq "leave" -and $hit[0].reason -match 'choice' -and $null -eq $hit[0].dismissed -and @($hit[0].dismissal).Count -eq 0) "event: $(ConvertTo-Json -InputObject $hit -Compress -Depth 5)"
        Assert ((@($hit[0].answer_controls) -contains "Yes") -and (@($hit[0].answer_controls) -contains "No")) "answer controls: $(@($hit[0].answer_controls) -join ',')"
        Assert ($report.Remaining.Count -ge 1 -and $report.Remaining[0].title -eq "Watchdog question test") "remaining at stop: $(ConvertTo-Json -InputObject @($report.Remaining) -Compress)"
        "left alone; labels $(@($hit[0].answer_controls) -join '/'); still open at stop"
    }
    Case "W3 window scan is scoped to one pid: this process sees none of the child's windows" {
        $mine = @(Get-OwnedDialogWindows -OwnerPid $PID | Where-Object { $_.Text -eq "Watchdog question test" })
        Assert ($mine.Count -eq 0) "the child's question was attributed to pid $PID"
        "pid $PID reports no child dialog"
    }
} finally {
    foreach ($child in @($child1, $child2)) { if ($child -and -not $child.HasExited) { try { Stop-Process -Id $child.Id -Force } catch { } } }
    if (Test-Path -LiteralPath $tempLog) { Remove-Item -LiteralPath $tempLog -Force }
}
$passed = @($results | Where-Object passed).Count; $failed = @($results | Where-Object { -not $_.passed }).Count
Write-Output "$passed passed, $failed failed"
if ($env:VAULT_CAD_TEST_JSON) { $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:VAULT_CAD_TEST_JSON -Encoding UTF8 }
if ($failed -gt 0) { exit 1 }
