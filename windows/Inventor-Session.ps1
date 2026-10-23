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
        # L6: a project FILE this run created is removed again (after the entry), and its removal is required.
        $attempted.remove_created_file = [bool]$Project.CreatedFile
        if ($Project.CreatedFile) {
            $required.created_file_removed = $true
            try { if (Test-Path -LiteralPath $Project.ProjectFile) { Remove-Item -LiteralPath $Project.ProjectFile -Force } } catch { $notes += "created file removal: $($_.Exception.Message)" }
        }
        $observed.created_file_removed = $(if (-not $Project.CreatedFile) { $null } else { -not (Test-Path -LiteralPath $Project.ProjectFile) })
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

# ---------------------------------------------------------------------------------------------------------
# Dialog watchdog (added 2026-10-23). The placement pilot stood still for 19 hours inside Document.Save2 on
# an owned, invisible Inventor instance: a "Before Save" iLogic event-driven rule of the production assembly
# referenced an external rule ("Part Number Cleaner") that does not exist on this workstation; the iLogic
# add-in showed a modal WinForms error window (one visible OK button) and, behind it, a disabled
# "AIP Migration Errors" dialog. Application.SilentOperation does not cover add-in forms. The watchdog runs
# on a second thread (a runspace in this process; the COM call blocks only the calling thread), records
# EVERY dialog-like top-level window of the owned pid (never of any other process) and dismisses ONLY a
# window whose visible, enabled answer buttons are exactly one acknowledgement (OK / Close / Continue). A
# window offering any choice (Yes/No, Save/Don't Save, Retry/Cancel, OK+Cancel) is recorded and left alone,
# so an unattended run can never answer a question; a disabled window (another modal above it) is recorded
# as blocked and re-examined once it becomes enabled. Inventor's own dialogs are HIDDEN while the application
# is invisible and their children inherit that, so for a hidden window the buttons are judged by Enabled only
# and the window is dismissed only while the main frame is disabled (a modal loop is running); a hidden dialog
# of an application whose main frame is enabled is not blocking anything and is only recorded.
# ---------------------------------------------------------------------------------------------------------
$InventorSessionModulePath = $PSCommandPath
if (-not ('VaultCad.Win32Windows' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace VaultCad {
    public class WindowInfo {
        public long Handle; public string ClassName; public string Text; public bool Visible; public bool Enabled; public int ControlId;
        public List<WindowInfo> Children = new List<WindowInfo>();
    }
    public static class Win32Windows {
        public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWnd, EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
        const uint SMTO_ABORTIFHUNG = 0x0002;
        public static bool SendTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint timeoutMs) { IntPtr r; return SendMessageTimeout(hWnd, msg, wParam, lParam, SMTO_ABORTIFHUNG, timeoutMs, out r) != IntPtr.Zero; }
        static string TextOf(IntPtr h) {
            var sb = new StringBuilder(4096);
            GetWindowText(h, sb, sb.Capacity);
            if (sb.Length == 0) { IntPtr r; SendMessageTimeout(h, 0x000D, (IntPtr)sb.Capacity, sb, SMTO_ABORTIFHUNG, 300, out r); }
            return sb.ToString();
        }
        static WindowInfo Describe(IntPtr h) {
            var c = new StringBuilder(256); GetClassName(h, c, c.Capacity);
            return new WindowInfo { Handle = h.ToInt64(), ClassName = c.ToString(), Text = TextOf(h), Visible = IsWindowVisible(h), Enabled = IsWindowEnabled(h), ControlId = GetDlgCtrlID(h) };
        }
        public static List<WindowInfo> TopLevelWindows(int pid, bool withChildren) {
            var list = new List<WindowInfo>();
            EnumWindows((h, l) => {
                uint p; GetWindowThreadProcessId(h, out p);
                if ((int)p == pid) {
                    var w = Describe(h);
                    if (withChildren) { EnumChildWindows(h, (ch, l2) => { w.Children.Add(Describe(ch)); return true; }, IntPtr.Zero); }
                    list.Add(w);
                }
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }
}
"@
}
try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop } catch { }

$DialogAcknowledgeLabels = @("OK", "Close", "Continue")
$DialogChoiceLabels = @("Yes", "No", "Cancel", "Retry", "Try Again", "Abort", "Ignore", "Save", "Don't Save", "Do not save", "Skip", "Skip All", "Accept", "Reject", "Apply", "Overwrite", "Replace", "Keep", "Update", "Open", "Delete", "Help", "Details", "Show Details", "More Info", "Yes to All", "No to All")
$DialogWatchdogPolicy = "records every dialog-like top-level window of the owned Inventor pid; dismisses only a window whose visible, enabled answer buttons are exactly one acknowledgement (OK/Close/Continue); any window offering a choice is left alone; a disabled window is recorded as blocked"

function Get-DialogLabel($Control) { (((([string]$Control.Text) -replace '&', '') -replace '\.\.\.$', '') -replace '\s+', ' ').Trim() }

function Resolve-DialogAction {
    <# Pure decision (offline-testable; see Test-InventorSession.ps1 S19-S28). Returns Action dismiss | leave | blocked,
       the Control to use for a dismissal, the answer Labels found and a Reason. -MainFrameEnabled is the owner
       application's main frame state at the same instant ($null when unknown): a hidden window is dismissed only
       while that frame is disabled, i.e. a modal loop is actually blocking the application. #>
    param([Parameter(Mandatory = $true)]$Window, [Nullable[bool]]$MainFrameEnabled = $null)
    $windowVisible = [bool]$Window.Visible
    $controls = @()
    foreach ($child in @($Window.Children)) {
        # children of a hidden window are hidden too (inherited), so visibility is informative only for visible windows
        if (-not $child.Enabled) { continue }
        if ($windowVisible -and -not $child.Visible) { continue }
        $label = Get-DialogLabel $child
        if (-not $label) { continue }
        if ($DialogAcknowledgeLabels -contains $label) { $controls += [pscustomobject]@{ Handle = [int64]$child.Handle; Label = $label; ControlId = [int]$child.ControlId; Kind = "acknowledge" } }
        elseif ($DialogChoiceLabels -contains $label) { $controls += [pscustomobject]@{ Handle = [int64]$child.Handle; Label = $label; ControlId = [int]$child.ControlId; Kind = "choice" } }
    }
    $labels = @($controls | ForEach-Object { $_.Label })
    if (-not $Window.Enabled) { return [pscustomobject]@{ Action = "blocked"; Control = $null; Labels = $labels; Reason = "window disabled (another modal window is above it); nothing sent, re-examined when enabled" } }
    if (-not $windowVisible) {
        if ($null -eq $MainFrameEnabled) { return [pscustomobject]@{ Action = "leave"; Control = $null; Labels = $labels; Reason = "hidden window and the application modal state is unknown (no main frame handle); nothing sent" } }
        if ($MainFrameEnabled) { return [pscustomobject]@{ Action = "leave"; Control = $null; Labels = $labels; Reason = "hidden window while the application main frame is enabled (no modal loop); not blocking, nothing sent" } }
    }
    $choices = @($controls | Where-Object { $_.Kind -eq "choice" }); $acks = @($controls | Where-Object { $_.Kind -eq "acknowledge" })
    if ($choices.Count -gt 0) { return [pscustomobject]@{ Action = "leave"; Control = $null; Labels = $labels; Reason = "offers a choice ($($labels -join '/')); never answered automatically" } }
    if ($acks.Count -eq 1) { return [pscustomobject]@{ Action = "dismiss"; Control = $acks[0]; Labels = $labels; Reason = "single acknowledgement button '$($acks[0].Label)'" } }
    if ($acks.Count -eq 0) { return [pscustomobject]@{ Action = "leave"; Control = $null; Labels = $labels; Reason = "no acknowledgement button" } }
    return [pscustomobject]@{ Action = "leave"; Control = $null; Labels = $labels; Reason = "several acknowledgement buttons ($($labels -join '/'))" }
}

function Get-OwnedDialogWindows {
    <# Dialog-like top-level windows of ONE process: visible windows and #32770 dialogs (even invisible, as Inventor's
       were while the application itself was invisible), excluding the main frame and windows with neither a title
       nor an answer button. #>
    param([Parameter(Mandatory = $true)][int]$OwnerPid, [long]$MainFrameHandle = 0)
    $found = @()
    foreach ($window in [VaultCad.Win32Windows]::TopLevelWindows($OwnerPid, $true)) {
        if ($window.Handle -eq $MainFrameHandle) { continue }
        if (-not $window.Visible -and $window.ClassName -ne '#32770') { continue }
        $hasAnswer = $false
        foreach ($child in $window.Children) { $label = Get-DialogLabel $child; if ($label -and (($DialogAcknowledgeLabels -contains $label) -or ($DialogChoiceLabels -contains $label))) { $hasAnswer = $true; break } }
        if ([string]::IsNullOrWhiteSpace($window.Text) -and -not $hasAnswer) { continue }
        $found += $window
    }
    return $found   # bare: callers use @(...) or foreach; a comma-wrapped empty array would reach them as ONE empty item
}

function Invoke-DialogDismissal {
    <# Tries, in order and only until the window is gone: BM_CLICK to the button, UIA Invoke on it, WM_COMMAND
       BN_CLICKED to the window, UIA WindowPattern.Close, WM_CLOSE. Each step waits and re-checks; everything is recorded. #>
    param([Parameter(Mandatory = $true)]$Window, [Parameter(Mandatory = $true)]$Control, [int]$WaitMilliseconds = 1500)
    $hwnd = [IntPtr][int64]$Window.Handle; $ctl = [IntPtr][int64]$Control.Handle; $wasVisible = [bool]$Window.Visible
    $gone = { (-not [VaultCad.Win32Windows]::IsWindow($hwnd)) -or ($wasVisible -and -not [VaultCad.Win32Windows]::IsWindowVisible($hwnd)) }
    $attempts = @(
        @{ name = "BM_CLICK to '$($Control.Label)'"; act = { [void][VaultCad.Win32Windows]::SendTimeout($ctl, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero, 1000) } },
        @{ name = "UIA InvokePattern on '$($Control.Label)'"; act = { $el = [System.Windows.Automation.AutomationElement]::FromHandle($ctl); $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } },
        @{ name = "WM_COMMAND BN_CLICKED id $($Control.ControlId)"; act = { [void][VaultCad.Win32Windows]::PostMessage($hwnd, 0x0111, [IntPtr]([int64]$Control.ControlId), $ctl) } },
        @{ name = "UIA WindowPattern.Close"; act = { $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd); $el.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } },
        @{ name = "WM_CLOSE"; act = { [void][VaultCad.Win32Windows]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) } }
    )
    $steps = @()
    foreach ($attempt in $attempts) {
        if (& $gone) { break }
        $err = $null; try { & $attempt.act } catch { $err = $_.Exception.Message }
        Start-Sleep -Milliseconds $WaitMilliseconds
        $steps += [ordered]@{ step = $attempt.name; error = $err; window_gone_after = [bool](& $gone) }
    }
    [pscustomobject]@{ Dismissed = [bool](& $gone); Steps = $steps }
}

function Start-DialogWatchdog {
    param([Parameter(Mandatory = $true)][int]$OwnerPid, [long]$MainFrameHandle = 0, [string]$LogPath, [int]$IntervalMilliseconds = 1000)
    $state = [hashtable]::Synchronized(@{ Stop = $false; Polls = 0; StartedAt = [DateTime]::UtcNow.ToString("o")
        Events = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)); Errors = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $runspace.Open()
    $worker = [powershell]::Create(); $worker.Runspace = $runspace
    [void]$worker.AddScript({
        param($state, $modulePath, $ownerPid, $mainFrame, $logPath, $interval)
        . $modulePath
        $seen = @{}
        while (-not $state.Stop) {
            $state.Polls = [int]$state.Polls + 1
            try {
                $frameEnabled = $null; if ($mainFrame) { $frameEnabled = [bool][VaultCad.Win32Windows]::IsWindowEnabled([IntPtr][int64]$mainFrame) }
                foreach ($window in (Get-OwnedDialogWindows -OwnerPid $ownerPid -MainFrameHandle $mainFrame)) {
                    $key = "$($window.Handle)|$($window.Text)|$($window.Enabled)|$($window.Visible)|$frameEnabled"
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $decision = Resolve-DialogAction -Window $window -MainFrameEnabled $frameEnabled
                    $event = [ordered]@{ seen_at = [DateTime]::UtcNow.ToString("o"); handle = $window.Handle; class = $window.ClassName; title = $window.Text; visible = $window.Visible; enabled = $window.Enabled; main_frame_enabled = $frameEnabled
                        texts = @($window.Children | Where-Object { ($_.Visible -or -not $window.Visible) -and -not [string]::IsNullOrWhiteSpace($_.Text) } | ForEach-Object { $_.Text } | Select-Object -Unique)
                        answer_controls = @($decision.Labels); action = $decision.Action; reason = $decision.Reason; dismissed = $null; dismissal = @() }
                    if ($decision.Action -eq "dismiss") { $outcome = Invoke-DialogDismissal -Window $window -Control $decision.Control; $event.dismissed = $outcome.Dismissed; $event.dismissal = @($outcome.Steps) }
                    [void]$state.Events.Add($event)
                    if ($logPath) { Add-Content -LiteralPath $logPath -Value (ConvertTo-Json -InputObject $event -Compress -Depth 5) }
                }
            } catch { [void]$state.Errors.Add("$([DateTime]::UtcNow.ToString('o')) $($_.Exception.Message)") }
            Start-Sleep -Milliseconds $interval
        }
    }).AddArgument($state).AddArgument($InventorSessionModulePath).AddArgument($OwnerPid).AddArgument($MainFrameHandle).AddArgument($LogPath).AddArgument($IntervalMilliseconds)
    $handle = $worker.BeginInvoke()
    [pscustomobject]@{ State = $state; Worker = $worker; Runspace = $runspace; Handle = $handle; OwnerPid = $OwnerPid; IntervalMilliseconds = $IntervalMilliseconds; LogPath = $LogPath; Policy = $DialogWatchdogPolicy }
}

function Resolve-RunStatus {
    <# W1 (Linux review 2026-10-23): a run in which the watchdog DISMISSED anything must not end as a plain
       'complete'; it becomes 'complete_with_dialogs' so a reader cannot accept it as clean without reading the
       receipt's 'dialogs' field. Dialogs that were only recorded (left alone) keep 'complete'. Any other status
       (FAILED, ...) is returned unchanged. #>
    param([Parameter(Mandatory = $true)][string]$Status, $Dialogs)
    if ($Status -ne "complete") { return $Status }
    if ($Dialogs -and [int]$Dialogs.Dismissed -gt 0) { return "complete_with_dialogs" }
    return "complete"
}

function Stop-DialogWatchdog {
    param([Parameter(Mandatory = $true)]$Watchdog, [int]$WaitSeconds = 15)
    $problems = @(); $remaining = @()
    try { foreach ($window in @(Get-OwnedDialogWindows -OwnerPid $Watchdog.OwnerPid)) { $remaining += [ordered]@{ handle = $window.Handle; class = $window.ClassName; title = $window.Text; enabled = $window.Enabled; visible = $window.Visible } } } catch { $problems += "final window scan: $($_.Exception.Message)" }
    $Watchdog.State.Stop = $true
    try {
        if (-not $Watchdog.Handle.AsyncWaitHandle.WaitOne($WaitSeconds * 1000)) { $problems += "watchdog thread did not stop within $WaitSeconds s; stopped forcibly"; $Watchdog.Worker.Stop() }
        try { [void]$Watchdog.Worker.EndInvoke($Watchdog.Handle) } catch { $problems += "watchdog thread: $($_.Exception.Message)" }
    } finally {
        try { $Watchdog.Worker.Dispose() } catch { }
        try { $Watchdog.Runspace.Close(); $Watchdog.Runspace.Dispose() } catch { }
    }
    $events = @($Watchdog.State.Events)
    [pscustomobject]@{ Policy = $Watchdog.Policy; OwnerPid = $Watchdog.OwnerPid; StartedAt = $Watchdog.State.StartedAt; StoppedAt = [DateTime]::UtcNow.ToString("o"); Polls = [int]$Watchdog.State.Polls
        Events = $events; Errors = @(@($Watchdog.State.Errors) + $problems); Remaining = $remaining
        Dismissed = @($events | Where-Object { $_.dismissed -eq $true }).Count; Left = @($events | Where-Object { $_.action -ne "dismiss" }).Count }
}
