<#
.SYNOPSIS
Shared helpers for scripts that drive a separate Inventor instance: ownership-bound start,
transactional temporary-project handling, shutdown with observed (not intended) outcomes, and
strict binding of opened native documents to acquisition/inventory records.

.DESCRIPTION
Dot-source from a script in the same folder:

    . (Join-Path $PSScriptRoot "Inventor-Session.ps1")
    $session = Start-IsolatedInventor                      # throws unless a NEW process is proven to own the object
    $project = Use-TemporaryProject $session.App $ipjPath  # rolls back its own registration if activation fails
    ... work ...
    $shutdown = Stop-IsolatedInventor $session $project    # reports Attempted vs Observed; Succeeded only if all observed
    if (-not $shutdown.Succeeded) { ... fail the run ... }

Ownership: the owning process id is read from Application.MainFrameHWND via GetWindowThreadProcessId.
If ownership cannot be established, or the owner existed before the call (the user's interactive
session), the helper ONLY releases its COM reference and throws; it never calls Quit, Close, Visible,
SilentOperation or anything else on an unproven instance. Once ownership is proven, a later start
failure quits that owned instance before rethrowing so no owned process is leaked.
Project list: an entry that already existed is never removed; an entry this call added is removed
again if activation fails (rollback, after first re-activating the previous project) or at shutdown.
Shutdown re-reads the project list, the active project and the document count, waits for the owned
PID to exit, and reports what was observed. Every cleanup action that was applicable is REQUIRED to be
observed as successful (a null or unreadable project manager counts as not observed); only actions
that never applied are reported as null.
Collections are accessed by Count/Item(i) (1-based, as in the Inventor API) so they can be mocked.
All collaborators (COM factory, process list, owner resolver, process info, releaser, liveness) are
injectable for offline tests (see Test-InventorSession.ps1).
#>
if (-not ('VaultCad.Win32' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace VaultCad {
    public static class Win32 {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        public static int ProcessIdFromWindow(IntPtr hWnd) { uint pid; GetWindowThreadProcessId(hWnd, out pid); return (int)pid; }
    }
}
"@
}

function Get-InventorPids { @(Get-Process -Name Inventor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) }
function Resolve-InventorOwnerPid($app) { $hwnd = [IntPtr][int64]$app.MainFrameHWND; if ($hwnd -eq [IntPtr]::Zero) { return 0 }; [VaultCad.Win32]::ProcessIdFromWindow($hwnd) }
function Release-ComObject($obj) { try { if ($obj -and [Runtime.InteropServices.Marshal]::IsComObject($obj)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($obj) } } catch { } }
function Get-CollectionItems($collection) { $list = @(); $c = [int]$collection.Count; for ($i = 1; $i -le $c; $i++) { $list += $collection.Item($i) }; return ,$list }
function Find-ProjectEntry($dpm, [string]$path) { foreach ($e in (Get-CollectionItems $dpm.DesignProjects)) { if ($e.FullFileName -ieq $path) { return $e } }; return $null }

function Start-IsolatedInventor {
    param(
        [scriptblock]$Factory = { New-Object -ComObject Inventor.Application },
        [scriptblock]$ProcessLister = { Get-InventorPids },
        [scriptblock]$OwnerResolver = { param($app) Resolve-InventorOwnerPid $app },
        [scriptblock]$ProcessInfo = { param($id) Get-Process -Id $id -ErrorAction SilentlyContinue },
        [scriptblock]$Releaser = { param($app) Release-ComObject $app },
        [int]$SettleSeconds = 3
    )
    $before = @(& $ProcessLister | ForEach-Object { $_ })
    $app = & $Factory
    if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }
    # ($PID is PowerShell's read-only automatic variable; use another name.)
    $ownerPid = 0; $resolveError = $null
    try { $ownerPid = [int](& $OwnerResolver $app) } catch { $resolveError = $_.Exception.Message }
    if ($ownerPid -le 0) {
        & $Releaser $app
        throw "Ownership of the Inventor COM object could not be established ($(if ($resolveError) { $resolveError } else { 'no main window / pid 0' })); the reference was released and nothing was called on the instance"
    }
    if ($before -contains $ownerPid) {
        & $Releaser $app
        throw "Inventor COM object belongs to pre-existing process $ownerPid (interactive session); the reference was released and nothing was called on the instance"
    }
    # Ownership proven: a failure from here on must still clean up the owned instance.
    try {
        $proc = & $ProcessInfo $ownerPid
        if (-not $proc -or $proc.ProcessName -ne "Inventor") { throw "Owning process $ownerPid is not an Inventor process" }
        $version = $app.SoftwareVersion.DisplayVersion; $build = $app.SoftwareVersion.BuildIdentifier
        $app.Visible = $false
        $app.SilentOperation = $true
        return [pscustomobject]@{ App = $app; Pid = $ownerPid; OwnershipMethod = "Application.MainFrameHWND -> GetWindowThreadProcessId; pid absent from the pre-call Inventor process list"; StartedAt = $proc.StartTime; Version = $version; Build = $build; PreExistingPids = $before; Releaser = $Releaser }
    } catch {
        $reason = $_.Exception.Message
        try { $app.Quit() } catch { $reason += " (and Quit of the owned instance failed: $($_.Exception.Message))" }
        & $Releaser $app
        throw "Start failed after ownership of process $ownerPid was proven; the owned instance was quit: $reason"
    }
}

function Use-TemporaryProject {
    param([Parameter(Mandatory = $true)]$App, [Parameter(Mandatory = $true)][string]$ProjectFile, [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj")
    $dpm = $App.DesignProjectManager
    if (-not $dpm) { throw "DesignProjectManager unavailable; refusing to register a temporary project" }
    $previous = [string]$dpm.ActiveDesignProject.FullFileName
    if (-not $previous) { throw "The active design project could not be read; refusing to register a temporary project" }
    $createdFile = $false; $addedEntry = $false; $activationAttempted = $false
    # Rollback order: restore the previously active project FIRST (activation may have changed state before
    # throwing, or verification may have failed), observe the result, then remove only what this call added.
    $rollback = {
        $notes = @()
        if ($activationAttempted) {
            try {
                $prev = Find-ProjectEntry $dpm $previous
                if ($prev) { $prev.Activate($false) } else { $notes += "previous project entry '$previous' not found" }
            } catch { $notes += "previous project re-activation threw: $($_.Exception.Message)" }
            # Observed, not intended: read the active project back whatever the re-activation call did.
            $notes += "previous project restored: $(try { [string]$dpm.ActiveDesignProject.FullFileName -ieq $previous } catch { $false })"
        }
        if ($addedEntry) { try { $e = Find-ProjectEntry $dpm $ProjectFile; if ($e) { $e.Remove() }; $notes += "added entry removed: $($null -eq (Find-ProjectEntry $dpm $ProjectFile))" } catch { $notes += "added entry removal failed: $($_.Exception.Message)" } }
        if ($createdFile) { try { Remove-Item -LiteralPath $ProjectFile -Force; $notes += "created file deleted" } catch { $notes += "created file delete failed: $($_.Exception.Message)" } }
        return $notes
    }
    if (-not (Test-Path -LiteralPath $ProjectFile)) {
        if (-not (Test-Path -LiteralPath $TemplateProject)) { throw "Project template not found: $TemplateProject" }
        Copy-Item -LiteralPath $TemplateProject -Destination $ProjectFile; $createdFile = $true
    }
    try {
        $entry = Find-ProjectEntry $dpm $ProjectFile
        if (-not $entry) {
            $entry = $dpm.DesignProjects.AddExisting($ProjectFile); $addedEntry = $true
            if (-not (Find-ProjectEntry $dpm $ProjectFile)) { throw "AddExisting returned but the entry is not registered" }
        }
        $activated = $false
        if ($previous -ine $ProjectFile) {
            $activationAttempted = $true
            $entry.Activate($false); $activated = $true
            $nowActive = [string]$dpm.ActiveDesignProject.FullFileName
            if ($nowActive -ine $ProjectFile) { throw "Activate returned but the active project is '$nowActive'" }
        }
    } catch {
        $notes = & $rollback
        throw "Temporary project setup failed ($($_.Exception.Message)); rollback: $($notes -join '; ')"
    }
    [pscustomobject]@{ ProjectFile = $ProjectFile; PreviousActive = $previous; EntryPreExisted = (-not $addedEntry); AddedEntry = $addedEntry; CreatedFile = $createdFile; Activated = $activated; Active = $dpm.ActiveDesignProject.FullFileName }
}

function Stop-IsolatedInventor {
    param(
        [Parameter(Mandatory = $true)]$Session, $Project,
        [int]$WaitSeconds = 60, [int]$PollMilliseconds = 500,
        [scriptblock]$ProcessAlive = { param($id) [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) },
        [scriptblock]$ProcessLister = { Get-InventorPids }
    )
    $app = $Session.App; $notes = @(); $attempted = [ordered]@{}; $observed = [ordered]@{}
    $attempted.close_documents = $true
    try { while ([int]$app.Documents.Count -gt 0) { $app.Documents.Item($app.Documents.Count).Close($true) } } catch { $notes += "document close: $($_.Exception.Message)" }
    $observed.documents_closed = $(try { [int]$app.Documents.Count -eq 0 } catch { $false })
    # Required observations must be POSITIVELY observed; $null is reserved for actions that were never applicable.
    $required = [ordered]@{ documents_closed = $true; process_exited = $true; no_unexpected_inventor_processes = $true }
    if ($Project) {
        $dpm = $null; try { $dpm = $app.DesignProjectManager } catch { $notes += "project manager unavailable: $($_.Exception.Message)" }
        if (-not $dpm) { $notes += "project manager unavailable (null): required project observations are recorded as not observed" }
        $attempted.restore_previous_project = [bool]$Project.Activated
        if ($Project.Activated) { $required.previous_project_active = $true }
        if ($dpm -and $Project.Activated) {
            try { $prev = Find-ProjectEntry $dpm $Project.PreviousActive; if ($prev) { $prev.Activate($false) } else { $notes += "previous project entry '$($Project.PreviousActive)' not found" } } catch { $notes += "project restore: $($_.Exception.Message)" }
        }
        $observed.previous_project_active = $(if (-not $Project.Activated) { $null } elseif ($dpm) { try { [string]$dpm.ActiveDesignProject.FullFileName -ieq $Project.PreviousActive } catch { $notes += "active project check: $($_.Exception.Message)"; $false } } else { $false })
        $attempted.remove_added_entry = [bool]$Project.AddedEntry
        if ($Project.AddedEntry) { $required.added_entry_removed = $true }
        if ($dpm -and $Project.AddedEntry) {
            try { $e = Find-ProjectEntry $dpm $Project.ProjectFile; if ($e) { $e.Remove() } } catch { $notes += "entry removal: $($_.Exception.Message)" }
        }
        $observed.added_entry_removed = $(if (-not $Project.AddedEntry) { $null } elseif ($dpm) { try { $null -eq (Find-ProjectEntry $dpm $Project.ProjectFile) } catch { $notes += "entry removal check: $($_.Exception.Message)"; $false } } else { $false })
        if ($Project.EntryPreExisted) { $required.preexisting_entry_still_registered = $true }
        $observed.preexisting_entry_still_registered = $(if (-not $Project.EntryPreExisted) { $null } elseif ($dpm) { try { $null -ne (Find-ProjectEntry $dpm $Project.ProjectFile) } catch { $notes += "pre-existing entry check: $($_.Exception.Message)"; $false } } else { $false })
    }
    $attempted.quit = $true
    try { $app.Quit() } catch { $notes += "quit: $($_.Exception.Message)" }
    if ($Session.Releaser) { & $Session.Releaser $app } else { Release-ComObject $app }
    $deadline = (Get-Date).AddSeconds($WaitSeconds); $exited = $false
    do { if (-not (& $ProcessAlive $Session.Pid)) { $exited = $true; break }; if ((Get-Date) -ge $deadline) { break }; Start-Sleep -Milliseconds $PollMilliseconds } while ($true)
    if (-not $exited) { $notes += "process $($Session.Pid) still running after $WaitSeconds s (not killed)" }
    $observed.process_exited = $exited
    $surviving = @(& $ProcessLister | ForEach-Object { $_ })
    $unexpected = @($surviving | Where-Object { $Session.PreExistingPids -notcontains $_ })
    $observed.unexpected_inventor_processes = $unexpected
    $observed.no_unexpected_inventor_processes = ($unexpected.Count -eq 0)
    $failedRequired = @(); foreach ($k in @($required.Keys)) { if ($observed[$k] -ne $true) { $failedRequired += $k } }
    $succeeded = ($failedRequired.Count -eq 0)
    [pscustomobject]@{ Pid = $Session.Pid; Exited = $exited; Succeeded = [bool]$succeeded; Attempted = $attempted; Observed = $observed; Required = @($required.Keys); FailedRequired = $failedRequired; UnexpectedSurvivors = $unexpected; Notes = $notes
        ProjectEntryRemoved = ($observed.added_entry_removed -eq $true); ProjectEntryPreserved = ($observed.preexisting_entry_still_registered -eq $true); PreviousProjectRestored = ($observed.previous_project_active -eq $true) }
}

function Confirm-AcquiredInputs {
    <#
    Bind every opened native document (root + AllReferencedDocuments) to acquisition.json and
    dependency-inventory.json. Throws on: unresolved references, duplicate acquisition/inventory
    records, a document absent from acquisition, hash mismatch with acquisition, or an acquisition
    record whose master id / vault path disagrees with the inventory. Returns the verified input list.
    #>
    param([Parameter(Mandatory = $true)]$Document, [Parameter(Mandatory = $true)]$Acquisition, [Parameter(Mandatory = $true)]$Inventory)
    $acqByPath = @{}; $acqByVersion = @{}
    foreach ($a in $Acquisition.files) {
        $p = ([string]$a.local_path).ToLowerInvariant(); $v = [string]$a.version_id
        if (-not $p -or $acqByPath.ContainsKey($p)) { throw "Duplicate or empty acquisition local_path: $($a.local_path)" }
        if (-not $v -or $acqByVersion.ContainsKey($v)) { throw "Duplicate or empty acquisition version id: $v" }
        $acqByPath[$p] = $a; $acqByVersion[$v] = $a
    }
    $invByVersion = @{}
    foreach ($f in $Inventory.files) { $v = [string]$f.version_id; if (-not $v -or $invByVersion.ContainsKey($v)) { throw "Duplicate or empty inventory version id: $v" }; $invByVersion[$v] = $f }
    $docs = @($Document) + @($Document.AllReferencedDocuments)
    $missing = @(); foreach ($d in $docs) { foreach ($fd in $d.File.ReferencedFileDescriptors) { if ($fd.ReferenceMissing) { $missing += $fd.FullFileName } } }
    if ($missing.Count -gt 0) { throw "Unresolved references: $($missing -join '; ')" }
    $inputs = @(); $seen = @{}
    foreach ($d in $docs) {
        $path = $d.FullFileName; $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
        $a = $acqByPath[$key]; if (-not $a) { throw "Opened document is not in the acquisition record: $path" }
        $cur = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($cur -ne [string]$a.sha256) { throw "Opened document differs from the acquired version $($a.version_id): $path" }
        $i = $invByVersion[[string]$a.version_id]; if (-not $i) { throw "Acquisition version $($a.version_id) is not in the dependency inventory" }
        if ([string]$i.master_id -ne [string]$a.master_id -or [string]$i.vault_path -ne [string]$a.vault_path) { throw "Acquisition and inventory disagree for version $($a.version_id)" }
        $kind = if ($d.DocumentType -eq 12291) { "assembly" } elseif ($d.DocumentType -eq 12290) { "part" } else { "other:$($d.DocumentType)" }
        $inputs += [ordered]@{ path = $path; kind = $kind; version_id = [string]$a.version_id; master_id = [string]$a.master_id; vault_path = $a.vault_path; version = $i.version; state = $i.state
            acquisition_sha256 = $a.sha256; current_sha256 = $cur; verified = $true
            model_state = $(try { $d.ComponentDefinition.ModelStates.ActiveModelState.Name } catch { $null })
            model_state_count = $(try { $d.ComponentDefinition.ModelStates.Count } catch { $null })
            positional_representation = $(if ($kind -eq "assembly") { try { $d.ComponentDefinition.RepresentationsManager.ActivePositionalRepresentation.Name } catch { $null } } else { $null })
            level_of_detail = $(if ($kind -eq "assembly") { try { $d.ComponentDefinition.RepresentationsManager.ActiveLevelOfDetailRepresentation.Name } catch { $null } } else { $null }) }
    }
    return ,$inputs
}
