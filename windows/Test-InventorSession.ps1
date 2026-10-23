<#
.SYNOPSIS
Offline tests for Inventor-Session.ps1 using mock COM objects that record every call.
No Inventor, Vault or network access. Run:  & .\windows\Test-InventorSession.ps1
Exit code 0 when all cases pass; prints PASS/FAIL per case and a summary.
Note for mock authors: Windows PowerShell 5.1 SWALLOWS exceptions thrown by ScriptProperty getters (the
property reads as $null) but propagates ScriptMethod and ScriptProperty SETTER exceptions, so failure
injection must go through methods or setters (COM property reads do propagate as RuntimeException).
#>
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")

    function New-Entry($path, $st) {
        $e = [pscustomobject]@{ FullFileName = $path; Name = [IO.Path]::GetFileNameWithoutExtension($path); State = $st }
        $e | Add-Member -MemberType ScriptMethod -Name Activate -Value { param($ignore) [void]$this.State.Calls.Add("Activate:$($this.FullFileName)"); if ($this.State.Fail['Activate']) { throw "mock: Activate failed" }; if ($this.State.Fail['ActivateNoop']) { return }; $this.State.Active = $this.FullFileName; $m = $this.State.Fail['ActivateAfterMutation']; if ($m -and ($m -eq $true -or $this.FullFileName -ieq [string]$m)) { throw "mock: Activate failed after changing the active project" } } -PassThru |
             Add-Member -MemberType ScriptMethod -Name Remove -Value { [void]$this.State.Calls.Add("Remove:$($this.FullFileName)"); if ($this.State.Fail['Remove']) { throw "mock: Remove failed" }; $this.State.Entries.Remove($this) } -PassThru
    }
function New-MockInventor {
    param([string[]]$ProjectFiles = @("C:\mock\Default.ipj"), [string]$Active = "C:\mock\Default.ipj", [hashtable]$Fail = @{}, [int]$Documents = 0)
    $state = [pscustomobject]@{ Calls = (New-Object System.Collections.ArrayList); Entries = (New-Object System.Collections.ArrayList); Active = $Active; Fail = $Fail; Visible = $true; SilentOperation = $false; Docs = (New-Object System.Collections.ArrayList) }
    foreach ($p in $ProjectFiles) { [void]$state.Entries.Add((New-Entry $p $state)) }
    $projects = [pscustomobject]@{ State = $state }
    $projects | Add-Member -MemberType ScriptProperty -Name Count -Value { $this.State.Entries.Count } -PassThru |
                Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) if ($this.State.Fail['Item']) { throw "mock: project list unreadable" }; $this.State.Entries[$i - 1] } -PassThru |
                Add-Member -MemberType ScriptMethod -Name AddExisting -Value { param($path) [void]$this.State.Calls.Add("AddExisting:$path"); if ($this.State.Fail['AddExisting']) { throw "mock: AddExisting failed" }; $e = New-Entry $path $this.State; [void]$this.State.Entries.Add($e); $e } | Out-Null
    $dpm = [pscustomobject]@{ State = $state; DesignProjects = $projects }
    $dpm | Add-Member -MemberType ScriptProperty -Name ActiveDesignProject -Value { $a = $this.State.Active; [pscustomobject]@{ FullFileName = $a; Name = [IO.Path]::GetFileNameWithoutExtension($a) } } | Out-Null
    for ($d = 0; $d -lt $Documents; $d++) { $doc = [pscustomobject]@{ State = $state; Index = $d }; $doc | Add-Member -MemberType ScriptMethod -Name Close -Value { param($skip) [void]$this.State.Calls.Add("Close"); if ($this.State.Fail['Close']) { throw "mock: Close failed" }; $this.State.Docs.Remove($this) } | Out-Null; [void]$state.Docs.Add($doc) }
    $docs = [pscustomobject]@{ State = $state }
    $docs | Add-Member -MemberType ScriptProperty -Name Count -Value { $this.State.Docs.Count } -PassThru | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) $this.State.Docs[$i - 1] } -PassThru | Out-Null
    $app = [pscustomobject]@{ State = $state; DesignProjectManager = $dpm; Documents = $docs; MainFrameHWND = 4242 }
    $app | Add-Member -MemberType ScriptProperty -Name SoftwareVersion -Value { if ($this.State.Fail['SoftwareVersion']) { throw "mock: SoftwareVersion failed" }; [pscustomobject]@{ DisplayVersion = "mock"; BuildIdentifier = 0 } } -PassThru |
           Add-Member -MemberType ScriptProperty -Name Visible -Value { $this.State.Visible } -SecondValue { param($v) if ($this.State.Fail['Visible']) { throw "mock: Visible set failed" }; [void]$this.State.Calls.Add("Visible=$v"); $this.State.Visible = $v } -PassThru |
           Add-Member -MemberType ScriptProperty -Name SilentOperation -Value { $this.State.SilentOperation } -SecondValue { param($v) [void]$this.State.Calls.Add("SilentOperation=$v"); $this.State.SilentOperation = $v } -PassThru |
           Add-Member -MemberType ScriptMethod -Name Quit -Value { [void]$this.State.Calls.Add("Quit"); if ($this.State.Fail['Quit']) { throw "mock: Quit failed" } } -PassThru | Out-Null
    return $app
}
$released = New-Object System.Collections.ArrayList
$releaser = { param($app) [void]$released.Add($app) }
$results = @()
function Case($name, [scriptblock]$body) {
    try { $detail = & $body; $script:results += [ordered]@{ case = $name; passed = $true; detail = "$detail" }; Write-Output "PASS $name $(if ($detail) { "- $detail" })" }
    catch { $script:results += [ordered]@{ case = $name; passed = $false; detail = $_.Exception.Message }; Write-Output "FAIL $name - $($_.Exception.Message)" }
}
function Assert($cond, $msg) { if (-not $cond) { throw $msg } }
function Mutating($app) { @($app.State.Calls | Where-Object { $_ -ne "" }) }
$start = @{ ProcessLister = { @(1000, 2000) }; ProcessInfo = { param($id) [pscustomobject]@{ ProcessName = "Inventor"; StartTime = (Get-Date) } }; Releaser = $releaser; SettleSeconds = 0 }

Case "S1 unknown owner (pid 0): throws, released, NO mutating call" {
    $released.Clear(); $app = New-MockInventor
    $threw = $null; try { Start-IsolatedInventor -Factory { $app } -OwnerResolver { 0 } @start | Out-Null } catch { $threw = $_.Exception.Message }
    Assert $threw "did not throw"; Assert ($released.Count -eq 1) "reference not released"; Assert ((Mutating $app).Count -eq 0) "mutating calls: $((Mutating $app) -join ',')"
    "message: $threw"
}
Case "S1b owner resolver throws: throws, released, NO mutating call" {
    $released.Clear(); $app = New-MockInventor
    $threw = $null; try { Start-IsolatedInventor -Factory { $app } -OwnerResolver { throw "no window" } @start | Out-Null } catch { $threw = $_.Exception.Message }
    Assert $threw "did not throw"; Assert ($released.Count -eq 1) "not released"; Assert ((Mutating $app).Count -eq 0) "mutating calls: $((Mutating $app) -join ',')"
}
Case "S2 pre-existing owner: throws, released, NO mutating call" {
    $released.Clear(); $app = New-MockInventor
    $threw = $null; try { Start-IsolatedInventor -Factory { $app } -OwnerResolver { 2000 } @start | Out-Null } catch { $threw = $_.Exception.Message }
    Assert ($threw -match "pre-existing process 2000") "wrong/no error: $threw"; Assert ($released.Count -eq 1) "not released"; Assert ((Mutating $app).Count -eq 0) "mutating calls: $((Mutating $app) -join ',')"
}
Case "S3 fresh owner: session returned, only Visible/SilentOperation set" {
    $released.Clear(); $app = New-MockInventor
    $s = Start-IsolatedInventor -Factory { $app } -OwnerResolver { 3000 } @start
    Assert ($s.Pid -eq 3000) "pid"; Assert ($app.State.Visible -eq $false -and $app.State.SilentOperation -eq $true) "settings not applied"
    $calls = Mutating $app; Assert (($calls -join ',') -eq "Visible=False,SilentOperation=True") "unexpected calls: $($calls -join ',')"
    "calls: $($calls -join ',')"
}
Case "S4 start fails after ownership proven (Visible setter throws): owned instance quit, released, error propagated" {
    $released.Clear(); $app = New-MockInventor -Fail @{ Visible = $true }
    $threw = $null; try { Start-IsolatedInventor -Factory { $app } -OwnerResolver { 3000 } @start | Out-Null } catch { $threw = $_.Exception.Message }
    Assert ($threw -match "ownership of process 3000 was proven") "wrong error: $threw"; Assert ((Mutating $app) -contains "Quit") "owned instance not quit"; Assert ($released.Count -eq 1) "not released"
    "calls: $((Mutating $app) -join ',')"
}
Case "S4b start fails after ownership proven (owner is not an Inventor process): quit before any setting, released, error propagated" {
    $released.Clear(); $app = New-MockInventor; $bad = $start.Clone(); $bad.ProcessInfo = { param($id) [pscustomobject]@{ ProcessName = "NotInventor"; StartTime = (Get-Date) } }
    $threw = $null; try { Start-IsolatedInventor -Factory { $app } -OwnerResolver { 3000 } @bad | Out-Null } catch { $threw = $_.Exception.Message }
    Assert ($threw -match "ownership of process 3000 was proven" -and $threw -match "not an Inventor process") "wrong error: $threw"
    Assert ((($app.State.Calls) -join ',') -eq "Quit") "calls other than Quit: $(($app.State.Calls) -join ',')"; Assert ($released.Count -eq 1) "not released"
}
Case "S5 temporary project: entry absent -> added and activated; state truthful" {
    $app = New-MockInventor; $f = [IO.Path]::GetTempFileName()
    $p = Use-TemporaryProject $app $f
    Assert ($p.AddedEntry -and $p.Activated -and -not $p.EntryPreExisted) "state: $($p | ConvertTo-Json -Compress)"; Assert ($app.State.Active -eq $f) "not active"
    Remove-Item $f -Force
}
Case "S6 activation throws before changing state (every Activate throws): previous observed still active, entry rolled back, error propagated" {
    $app = New-MockInventor -Fail @{ Activate = $true }; $f = [IO.Path]::GetTempFileName()
    $threw = $null; try { Use-TemporaryProject $app $f | Out-Null } catch { $threw = $_.Exception.Message }
    Assert ($threw -match "previous project re-activation threw" -and $threw -match "previous project restored: True" -and $threw -match "added entry removed: True") "rollback not observed: $threw"; Assert ($app.DesignProjectManager.DesignProjects.Count -eq 1) "entry still registered"
    Remove-Item $f -Force
}
Case "S6b activation changes the active project and then throws: previous project restored FIRST, added entry removed, error propagated" {
    $app = New-MockInventor; $f = [IO.Path]::GetTempFileName(); $app.State.Fail['ActivateAfterMutation'] = $f
    $threw = $null; try { Use-TemporaryProject $app $f | Out-Null } catch { $threw = $_.Exception.Message }
    Assert ($threw -match "previous project restored: True" -and $threw -match "added entry removed: True") "rollback incomplete: $threw"
    Assert ($app.State.Active -eq "C:\mock\Default.ipj") "previous project not active: $($app.State.Active)"; Assert ($app.DesignProjectManager.DesignProjects.Count -eq 1) "entry still registered"
    $calls = @($app.State.Calls); $iRestore = [array]::IndexOf($calls, "Activate:C:\mock\Default.ipj"); $iRemove = [array]::IndexOf($calls, "Remove:$f")
    Assert ($iRestore -ge 0 -and $iRemove -gt $iRestore) "restore did not precede removal: $($calls -join ',')"
    Remove-Item $f -Force; "calls: $($calls -join ',')"
}
Case "S6c activation returns without changing the active project: verification fails, entry rolled back" {
    $app = New-MockInventor -Fail @{ ActivateNoop = $true }; $f = [IO.Path]::GetTempFileName()
    $threw = $null; try { Use-TemporaryProject $app $f | Out-Null } catch { $threw = $_.Exception.Message }
    Assert ($threw -match "Activate returned but the active project is" -and $threw -match "added entry removed: True") "unexpected: $threw"; Assert ($app.DesignProjectManager.DesignProjects.Count -eq 1) "entry still registered"
    Remove-Item $f -Force
}
Case "S6d pre-existing entry whose activation mutates then throws: previous restored, pre-existing entry NOT removed" {
    $f = [IO.Path]::GetTempFileName(); $app = New-MockInventor -ProjectFiles @("C:\mock\Default.ipj", $f); $app.State.Fail['ActivateAfterMutation'] = $f
    $threw = $null; try { Use-TemporaryProject $app $f | Out-Null } catch { $threw = $_.Exception.Message }
    Assert ($threw -match "previous project restored: True") "not restored: $threw"; Assert ($app.State.Active -eq "C:\mock\Default.ipj") "previous not active"
    Assert ($app.DesignProjectManager.DesignProjects.Count -eq 2 -and ((Mutating $app) -notcontains "Remove:$f")) "pre-existing entry removed: $((Mutating $app) -join ',')"
    Remove-Item $f -Force
}
Case "S6e null project manager: registration refused before any mutation" {
    $app = New-MockInventor; $app.DesignProjectManager = $null; $f = [IO.Path]::GetTempFileName()
    $threw = $null; try { Use-TemporaryProject $app $f | Out-Null } catch { $threw = $_.Exception.Message }
    Assert ($threw -match "DesignProjectManager unavailable") "unexpected: $threw"; Assert ((Mutating $app).Count -eq 0) "calls: $((Mutating $app) -join ',')"
    Remove-Item $f -Force
}
Case "S7 pre-existing registered and active entry: nothing added or activated" {
    $f = [IO.Path]::GetTempFileName(); $app = New-MockInventor -ProjectFiles @("C:\mock\Default.ipj", $f) -Active $f
    $p = Use-TemporaryProject $app $f
    Assert ($p.EntryPreExisted -and -not $p.AddedEntry -and -not $p.Activated) "state: $($p | ConvertTo-Json -Compress)"; Assert ((Mutating $app).Count -eq 0) "calls: $((Mutating $app) -join ',')"
    Remove-Item $f -Force
}
Case "S8 shutdown normal: docs closed, previous restored, added entry removed, exited, Succeeded" {
    $app = New-MockInventor -Documents 2; $f = [IO.Path]::GetTempFileName(); $p = Use-TemporaryProject $app $f
    $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $p -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert ($r.Succeeded) "not succeeded: $($r | ConvertTo-Json -Compress -Depth 4)"; Assert ($r.Observed.documents_closed -and $r.PreviousProjectRestored -and $r.ProjectEntryRemoved -and $r.Exited) "observed: $($r.Observed | ConvertTo-Json -Compress)"
    Assert ($app.State.Active -eq "C:\mock\Default.ipj") "previous not active"; Remove-Item $f -Force
}
Case "S9 shutdown with Remove failing: ProjectEntryRemoved false (observed), Succeeded false, note recorded" {
    $app = New-MockInventor; $f = [IO.Path]::GetTempFileName(); $p = Use-TemporaryProject $app $f; $app.State.Fail['Remove'] = $true
    $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $p -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert (-not $r.ProjectEntryRemoved -and -not $r.Succeeded) "should not succeed: $($r | ConvertTo-Json -Compress -Depth 4)"; Assert (($r.Notes -join ';') -match "entry removal") "note missing"
    Remove-Item $f -Force
}
Case "S10 shutdown with pre-existing entry: entry preserved (observed), Succeeded" {
    $f = [IO.Path]::GetTempFileName(); $app = New-MockInventor -ProjectFiles @("C:\mock\Default.ipj", $f); $p = Use-TemporaryProject $app $f
    $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $p -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert ($r.ProjectEntryPreserved -and -not $r.ProjectEntryRemoved -and $r.PreviousProjectRestored -and $r.Succeeded) "state: $($r | ConvertTo-Json -Compress -Depth 4)"
    Assert ((Mutating $app) -notcontains "Remove:$f") "pre-existing entry was removed"; Remove-Item $f -Force
}
Case "S11 shutdown with process never exiting: Exited false, Succeeded false" {
    $app = New-MockInventor; $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $null -ProcessAlive { $true } -ProcessLister { @(1000, 3000) } -WaitSeconds 0 -PollMilliseconds 1
    Assert (-not $r.Exited -and -not $r.Succeeded -and $r.UnexpectedSurvivors -contains 3000) "state: $($r | ConvertTo-Json -Compress -Depth 4)"
}
Case "S12 shutdown with Quit throwing: note recorded, Succeeded reflects liveness" {
    $app = New-MockInventor -Fail @{ Quit = $true }; $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $null -ProcessAlive { $true } -ProcessLister { @(1000, 3000) } -WaitSeconds 0 -PollMilliseconds 1
    Assert ((($r.Notes -join ';') -match "quit:") -and -not $r.Succeeded) "state: $($r | ConvertTo-Json -Compress -Depth 4)"
}
Case "S13 shutdown with Close throwing: documents_closed false, Succeeded false" {
    $app = New-MockInventor -Documents 1 -Fail @{ Close = $true }; $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $null -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert (-not $r.Observed.documents_closed -and -not $r.Succeeded) "state: $($r | ConvertTo-Json -Compress -Depth 4)"
}
Case "S14 shutdown with a null project manager after this run activated and added an entry: required observations false, Succeeded false" {
    $app = New-MockInventor; $f = [IO.Path]::GetTempFileName(); $p = Use-TemporaryProject $app $f; $app.DesignProjectManager = $null
    $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $p -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert ($r.Observed.previous_project_active -eq $false -and $r.Observed.added_entry_removed -eq $false -and -not $r.Succeeded) "state: $($r | ConvertTo-Json -Compress -Depth 4)"
    Assert (($r.FailedRequired -contains "previous_project_active") -and ($r.FailedRequired -contains "added_entry_removed")) "failed required: $($r.FailedRequired -join ',')"; Assert (($r.Notes -join ';') -match "project manager unavailable") "note missing: $($r.Notes -join ';')"
    Remove-Item $f -Force
}
Case "S15 shutdown with an unreadable project list and a pre-existing entry: preservation not observed, Succeeded false" {
    $f = [IO.Path]::GetTempFileName(); $app = New-MockInventor -ProjectFiles @("C:\mock\Default.ipj", $f); $p = Use-TemporaryProject $app $f; $app.State.Fail['Item'] = $true
    $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $p -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert ($r.Observed.preexisting_entry_still_registered -eq $false -and -not $r.ProjectEntryPreserved -and -not $r.Succeeded) "state: $($r | ConvertTo-Json -Compress -Depth 4)"
    Remove-Item $f -Force
}
Case "S16 shutdown with a null project manager and a pre-existing, already active entry: preservation required, Succeeded false; inapplicable observations stay null" {
    $f = [IO.Path]::GetTempFileName(); $app = New-MockInventor -ProjectFiles @("C:\mock\Default.ipj", $f) -Active $f; $p = Use-TemporaryProject $app $f; $app.DesignProjectManager = $null
    $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $p -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert ($null -eq $r.Observed.previous_project_active -and $null -eq $r.Observed.added_entry_removed) "inapplicable observations must stay null: $($r.Observed | ConvertTo-Json -Compress)"
    Assert ($r.Observed.preexisting_entry_still_registered -eq $false -and -not $r.Succeeded -and ($r.FailedRequired -contains "preexisting_entry_still_registered")) "state: $($r | ConvertTo-Json -Compress -Depth 4)"
    Remove-Item $f -Force
}
Case "S18 shutdown removes the project FILE this run created (and only then); a pre-existing file is kept" {
    $app = New-MockInventor; $created = Join-Path ([IO.Path]::GetTempPath()) ("vault-cad-mock-" + [Guid]::NewGuid() + ".ipj"); $template = [IO.Path]::GetTempFileName()
    $p = Use-TemporaryProject $app $created $template
    Assert ($p.CreatedFile -and (Test-Path -LiteralPath $created)) "file not created from template"
    $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $p -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert ($r.Succeeded -and $r.Observed.created_file_removed -eq $true -and -not (Test-Path -LiteralPath $created)) "created file not removed: $($r | ConvertTo-Json -Compress -Depth 4)"
    Assert (@($r.Required) -contains "created_file_removed") "removal not required"
    $existing = [IO.Path]::GetTempFileName(); $app2 = New-MockInventor; $p2 = Use-TemporaryProject $app2 $existing
    $r2 = Stop-IsolatedInventor ([pscustomobject]@{ App = $app2; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }) $p2 -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert ($r2.Succeeded -and $null -eq $r2.Observed.created_file_removed -and (Test-Path -LiteralPath $existing)) "pre-existing file touched: $($r2.Observed | ConvertTo-Json -Compress)"
    Remove-Item $existing, $template -Force
}
Case "S17 shutdown with a null project manager and NO project handed over: no project observation required, Succeeded" {
    $app = New-MockInventor; $app.DesignProjectManager = $null; $s = [pscustomobject]@{ App = $app; Pid = 3000; PreExistingPids = @(1000); Releaser = $releaser }
    $r = Stop-IsolatedInventor $s $null -ProcessAlive { $false } -ProcessLister { @(1000) } -WaitSeconds 1
    Assert ($r.Succeeded -and (@($r.Required) -notcontains "previous_project_active") -and (@($r.Required) -join ',') -eq "documents_closed,process_exited,no_unexpected_inventor_processes") "state: $($r | ConvertTo-Json -Compress -Depth 4)"
}
# ---- dialog watchdog decision (pure; the Win32/UIA side is exercised by Test-DialogWatchdog.ps1 with child MessageBox processes) ----
function New-MockWindow([string]$class, [string]$title, [bool]$enabled, [bool]$visible, $children) { [pscustomobject]@{ Handle = 1000; ClassName = $class; Text = $title; Visible = $visible; Enabled = $enabled; Children = @($children) } }
function New-MockControl([string]$text, [bool]$visible, [bool]$enabled, [int]$id) { [pscustomobject]@{ Handle = 2000 + $id; ClassName = "Button"; Text = $text; Visible = $visible; Enabled = $enabled; ControlId = $id } }
Case "S19 dialog decision: iLogic error form, one visible OK, hidden Apply/Extra/Second/Cancel -> dismiss via OK" {
    $window = New-MockWindow "WindowsForms10.Window.8.app.0" "iLogic Event-Driven Rule" $true $true @((New-MockControl "RunExternalRule: Cannot find an external rule file named: `"Part Number Cleaner`"" $true $true 5), (New-MockControl "OK" $true $true 1), (New-MockControl "Apply" $false $true 2), (New-MockControl "Extra" $false $true 3), (New-MockControl "Second" $false $true 4), (New-MockControl "Cancel" $false $true 6))
    $decision = Resolve-DialogAction $window
    Assert ($decision.Action -eq "dismiss" -and $decision.Control.Label -eq "OK" -and $decision.Control.ControlId -eq 1 -and (@($decision.Labels) -join ',') -eq "OK") "decision: $($decision | ConvertTo-Json -Compress)"
}
Case "S20 dialog decision: hidden #32770 'AIP Migration Errors' (hidden OK and Static, as observed) while the main frame is DISABLED (modal loop) -> dismiss via OK" {
    $window = New-MockWindow "#32770" "AIP Migration Errors" $true $false @((New-MockControl "OK" $false $true 1), (New-MockControl "The following AIP files experienced problems during migration" $false $true 1001), (New-MockControl "" $false $true 1002))
    $decision = Resolve-DialogAction -Window $window -MainFrameEnabled $false
    Assert ($decision.Action -eq "dismiss" -and $decision.Control.ControlId -eq 1 -and $decision.Control.Label -eq "OK") "decision: $($decision | ConvertTo-Json -Compress)"
}
Case "S21 dialog decision: Yes/No question -> leave, no control chosen" {
    $decision = Resolve-DialogAction (New-MockWindow "#32770" "Autodesk Inventor Professional" $true $true @((New-MockControl "&Yes" $true $true 6), (New-MockControl "&No" $true $true 7), (New-MockControl "Save changes?" $true $true 1001)))
    Assert ($decision.Action -eq "leave" -and $null -eq $decision.Control -and $decision.Reason -match 'choice' -and (@($decision.Labels) -join ',') -eq "Yes,No") "decision: $($decision | ConvertTo-Json -Compress)"
}
Case "S22 dialog decision: Save / Don't Save / Cancel -> leave" {
    $decision = Resolve-DialogAction (New-MockWindow "#32770" "Autodesk Inventor Professional" $true $true @((New-MockControl "&Save" $true $true 1), (New-MockControl "Do&n't Save" $true $true 2), (New-MockControl "Cancel" $true $true 3)))
    Assert ($decision.Action -eq "leave" -and $null -eq $decision.Control -and (@($decision.Labels) -join ',') -eq "Save,Don't Save,Cancel") "decision: $($decision | ConvertTo-Json -Compress)"
}
Case "S23 dialog decision: OK + Cancel is a choice -> leave" {
    $decision = Resolve-DialogAction (New-MockWindow "#32770" "Resolve Link" $true $true @((New-MockControl "OK" $true $true 1), (New-MockControl "Cancel" $true $true 2)))
    Assert ($decision.Action -eq "leave" -and $null -eq $decision.Control -and $decision.Reason -match 'choice') "decision: $($decision | ConvertTo-Json -Compress)"
}
Case "S24 dialog decision: disabled window (another modal above it) with a single OK -> blocked, nothing chosen" {
    $decision = Resolve-DialogAction (New-MockWindow "#32770" "AIP Migration Errors" $false $false @((New-MockControl "OK" $true $true 1)))
    Assert ($decision.Action -eq "blocked" -and $null -eq $decision.Control -and (@($decision.Labels) -join ',') -eq "OK") "decision: $($decision | ConvertTo-Json -Compress)"
}
Case "S25 dialog decision: no answer button at all (tool window) -> leave" {
    $decision = Resolve-DialogAction (New-MockWindow "WindowsForms10.Window.0.app.0" "" $true $true @((New-MockControl "some label" $true $true 9)))
    Assert ($decision.Action -eq "leave" -and $null -eq $decision.Control -and $decision.Reason -match 'no acknowledgement') "decision: $($decision | ConvertTo-Json -Compress)"
}
Case "S26 dialog decision: hidden or disabled buttons do not count; two visible acknowledgements -> leave" {
    $decision = Resolve-DialogAction (New-MockWindow "#32770" "Info" $true $true @((New-MockControl "OK" $true $true 1), (New-MockControl "Close" $true $true 2), (New-MockControl "Yes" $false $true 3), (New-MockControl "No" $true $false 4)))
    Assert ($decision.Action -eq "leave" -and $decision.Reason -match 'several' -and (@($decision.Labels) -join ',') -eq "OK,Close") "decision: $($decision | ConvertTo-Json -Compress)"
}
Case "S27 dialog decision: the same hidden dialog while the main frame is ENABLED (no modal loop, as seen during the export) -> leave" {
    $window = New-MockWindow "#32770" "AIP Migration Errors" $true $false @((New-MockControl "OK" $false $true 1))
    $decision = Resolve-DialogAction -Window $window -MainFrameEnabled $true
    Assert ($decision.Action -eq "leave" -and $null -eq $decision.Control -and $decision.Reason -match 'enabled' -and (@($decision.Labels) -join ',') -eq "OK") "decision: $($decision | ConvertTo-Json -Compress)"
}
Case "S28 dialog decision: hidden dialog with unknown modal state (no main frame handle) -> leave" {
    $decision = Resolve-DialogAction (New-MockWindow "#32770" "AIP Migration Errors" $true $false @((New-MockControl "OK" $false $true 1)))
    Assert ($decision.Action -eq "leave" -and $null -eq $decision.Control -and $decision.Reason -match 'unknown') "decision: $($decision | ConvertTo-Json -Compress)"
}
# ---- W1: run status with dialogs ----
Case "S29 run status: a dismissed dialog turns 'complete' into 'complete_with_dialogs'" {
    $d = [pscustomobject]@{ Dismissed = 1; Left = 0; Events = @(1) }
    Assert ((Resolve-RunStatus -Status "complete" -Dialogs $d) -eq "complete_with_dialogs") "status not escalated"
}
Case "S30 run status: dialogs only recorded (left alone) keep 'complete'; no watchdog keeps 'complete'" {
    $d = [pscustomobject]@{ Dismissed = 0; Left = 2; Events = @(1, 2) }
    Assert ((Resolve-RunStatus -Status "complete" -Dialogs $d) -eq "complete" -and (Resolve-RunStatus -Status "complete" -Dialogs $null) -eq "complete") "status changed although nothing was dismissed"
}
Case "S31 run status: FAILED stays FAILED whatever the watchdog did" {
    $d = [pscustomobject]@{ Dismissed = 3; Left = 0; Events = @(1, 2, 3) }
    Assert ((Resolve-RunStatus -Status "FAILED" -Dialogs $d) -eq "FAILED") "FAILED was altered"
}
$passed = @($results | Where-Object passed).Count; $failed = @($results | Where-Object { -not $_.passed }).Count
Write-Output "$passed passed, $failed failed"
if ($env:VAULT_CAD_TEST_JSON) { $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:VAULT_CAD_TEST_JSON -Encoding UTF8 }
if ($failed -gt 0) { exit 1 }
