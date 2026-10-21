# Windows side of vault-cad-tools

## Latest Windows results (2026-10-21, command-line native pilot)

Evidence run: `vault-cad-exchange/evidence/2026-10-21-windows-native-pilot-01/`
(report `WINDOWS-NATIVE-PILOT-2026-10-21.md`). Executed on tools `163ed4c` /
project `f11b2ae` in Peter's interactive desktop session; no service mode is claimed.

- 34 tests pass on Windows. The fresh-cache guard rejected a same-size wrong file
  for version 991092 (exit 1, no acquisition record, planted file untouched).
- `Compare-NativeAndStepAssembly.ps1`: native 155 leaves / 503 solid bodies /
  479 visible; STEP 155 / 479 / 479. The only differing document is
  `MCMASTER 47065T245.ipt` (4 `IsSolid` bodies per occurrence, 1 visible, 8
  occurrences = 24). Extents agree closely. Total volume differs by 12.8 cm³;
  hidden bodies and other per-component differences partly offset each other.
- `Invoke-NativeAuthoringPilot.ps1`: STEP -> converted IPT (no reference), saved,
  reopened (1 solid, 47 x 0.125 x 47 in, 4291.6 cm^3); new IAM with PANEL_A
  (grounded) and PANEL_B placed by explicit matrices; unconstrained move persists
  across reopen; flush constraint on XZ planes with 1 in offset; an incompatible
  move is reported as not achieved with the constraint retained; compatible move
  persists; assembly STEP exported with a placement report. 23 checks passed; a
  rerun on the same workspace passed 19 checks with IPT, occurrences and constraint
  reused, never duplicated. IPT bytes unchanged throughout.
- `Export-InventorStep.ps1 -Acquisition` re-exported the enclosure with all 44
  opened documents hash-verified against `acquisition.json`; the receipt records
  `native_inputs_verified: true` (`exports-verified/`).
- Vault SDK inventory (`sdk-inventory/`): VDF `IFileManager.AddFile/CheckinFile/
  AcquireFiles/UndoCheckoutFile` and web-service `DocumentService.AddUploadedFile/
  CheckinUploadedFile/CheckoutFile` are present (30.4.28.0). The Inventor Vault
  add-in is installed and active but its automation type library is not registered
  for IDispatch enumeration. No upload adapter exists yet.

The ByRef COM limitation is solved with `Import-InventorInterop.ps1` (C# helper).

## Latest Linux review (2026-10-21, native pilot)

Read `vault-cad-exchange/evidence/2026-10-21-linux-native-review-01/` and the newest
coordination/to-windows message before continuing. The previous body-count gap is
accounted for, and all 44 export input records match acquisition/inventory. The
verified export has exactly the same STEP DATA section as the previously validated
file. FreeCAD 1.1.3 confirms two valid pilot panels at the reported placements.
The 34 portable tests pass in Guix.

Full enclosure acceptance remains pending specific per-part checks: native/STEP
mass-property volumes differ by +12.30% for MCMASTER 5537T429_T-Slotted Framing and
+8.46% for MCMASTER 5537T293_T-Slotted Framing. Determine the cause with explicit
accuracy/override settings and per-body comparisons. Do not assert all volume
changes come from hidden bodies, or that equal counts prove surface equivalence.

Linux additionally tightened New-ExportReceipt.ps1 to verify the acquisition/
inventory/opened-input join, reject empty/false verification and incomplete strict
exports. Invoke-NativeAuthoringPilot.ps1 now refuses a changed STEP input in an
existing workspace and validates file-name arguments. These edits have not run
on Windows yet. First run PowerShell parser checks, then:

```powershell
& .\windows\Test-ExportReceipt.ps1
```

The 11 offline receipt cases need no Autodesk or server access. Also compose a
fresh strict receipt from the real verified export, and check the pilot unchanged-
input rerun and changed-input refusal in a disposable workspace. PowerShell is
not installed in the Linux review environment; Python tests do not cover it.

Compare-NativeAndStepAssembly.ps1 is diagnostic: basename grouping, body-level
visibility, caught measurement failures, default mass-property accuracy and
conservative bounds limit its conclusions. Use distinct source/configuration keys
and inherited occurrence state for the forthcoming manifest. The pilot is a fixed
panel fixture and may mutate its own test IAM on rerun; never point it at design
work. COM-instance/project cleanup should be hardened before general reuse.

Per-part export and the native parameter-driven monitor fixture can proceed
without a publication destination. No Vault write is requested or implemented.

## Status (Windows, 2026-10-21)

The handoff below was executed on the Windows workstation (Inventor 2025.3,
Vault Client 2025, Vault Professional Server 30.4.28.0 at `svault5`). Results,
evidence and hashes are in the shared exchange run directory
`vault-cad-exchange/evidence/2026-10-21-windows-qualification-01/`
(`WINDOWS-RESULTS-2026-10-21.md` there is the dated report). In short:

- Locked Pixi environment installed per-user; `doctor` ready; all tests pass
  (30 before, 33 after the API corrections below); project `status` correct.
- Live API corrections: `POST /sessions/win-auth` works with the Windows
  identity; basic `search-results` returns 403 for this account, so `search`
  now queries `file-versions?q=`; `DELETE /sessions/{id}` returns 501 and is
  tolerated; `uses` returns association records and paged in one page.
- Pilot resolved: root `Free Standing Enclosure.iam` is file-version 991056
  (master 988153, v5, Work in Progress) in folder 953863 whose real path is
  `$/DATA/PROJECTS/_PROJECTS BY LAB/SCHULZE (LAB)/ENCLOSURE` (the configured
  path lacked `/DATA`; corrected in the project checkout). 43 dependency
  versions across four folders, none checked out, no library/Content Center
  files; all 44 files mirrored locally with SHA-256s.
- Export route: local hidden Inventor instance via `Export-InventorStep.ps1`
  (Job Processor not used). Part and assembly STEP (AP214) produced with
  receipts; both re-open in Inventor with matching extents and occurrence
  counts (assembly: 14 top-level, 155 leaf occurrences; 503 native bodies vs
  479 after re-import, flagged for FreeCAD review).
- Import smoke test with the receipts passed in a disposable project copy,
  including the repeated no-op import. The main project baseline is untouched.

Scripts in this folder: `Export-Capabilities.ps1` (unauthenticated capture),
`Set-VaultCadToken.ps1` (Windows-identity token into `VAULT_CAD_TOKEN`),
`Get-VaultDependencySnapshot.ps1`, `Export-InventorStep.ps1`,
`Inspect-StepInInventor.ps1`, `New-ExportReceipt.ps1`. See the tools README,
section "Windows export route", for their contract. Call them with `&` from
PowerShell; `powershell -File` flattens array parameters.

Known gaps: no Job Processor runs on the workstation and the queue cannot be
inspected for finished jobs, so built-in STEP job parameters remain unknown; the
STEP translator's `Open` with a by-reference target fails from PowerShell, so
re-import uses `Documents.Open` defaults; the Vault SDK is present only as the
Explorer assemblies (`SDK\Setup.exe` not run), so no upload adapter exists yet.

## Original handoff — 2026-10-21

Please take the lead on Windows qualification and the first real Vault-to-STEP
export. Peter asked for this handoff. Linux can resume with FreeCAD geometry
validation once the exported part, assembly, and provenance are available.
Fix concrete Windows issues and implement a minimal local exporter if needed;
keep reusable code here and project data in `free-standing-tank-enclosure`.

## Starting state and checkout ownership

The Linux and shared clones were clean and synchronized when this handoff was
prepared: tools commit `94427de`, project commit `fbe2873`. This README and the
tools plan are subsequent, uncommitted handoff updates in both tools clones.
Read the shared copy immediately; it will not reach GitHub until Peter commits
and pushes it. Read each repository's `.agents/AGENTS.md` and living plan too.

Use sibling **local Windows checkouts** of the two repositories. Do not run Pixi
or develop in a checkout that another host is editing through the network share.
Check `git status` first; fast-forward a clean checkout with `git pull --ff-only`.
Preserve any existing work. Linux will leave implementation to Windows during
this phase. Leave commits and pushes to Peter unless he asks you to perform them.

The shared Linux paths are:

```text
/janelia/sciserv/polidorop/Repositories/github/vault-cad-tools
/janelia/sciserv/polidorop/Repositories/github/free-standing-tank-enclosure
```

Use the Windows drive/UNC mapping already available on this machine; do not
guess it. Put raw evidence and export payloads in a new, uniquely named directory
under the shared `vault-cad-exchange/` area, outside Git worktrees. Keep credentials
and tokens on the executing host and out of logs, receipts, and shared files.

The original `Vault-Inventor-STEP-Automation.md` in the tools repository records
installed capabilities. Preserve it. No authenticated end-to-end workflow has
been demonstrated yet. The portable suite passed 30 tests in Guix and Linux Pixi;
Windows execution, CAD conversion, and uploads remain unverified. The CLI has
read/import/request operations, but no export-job submission or upload adapter.

## 1. Qualify the locked environment and both repositories

From the local Windows tools checkout, run these in PowerShell and record each
command's exit code, output, Windows/Pixi versions, and both repository commits:

```powershell
pixi --version
pixi install --locked
pixi run --locked doctor
pixi run --locked test
pixi run --locked cli --project ..\free-standing-tank-enclosure status
```

The baseline is 30 passing tests, `portable_tools_ready: true`, and project status
identifying the configured assembly with empty reference/publication records.
Record failures and skips explicitly. Fix portability failures here, rerun the
affected checks, and run the suite after code changes. Do not regenerate the
lockfile merely to make installation pass; diagnose the actual failure first.
The project has no separate Python environment or test suite: its status check
and later geometry checks use the tools environment and CAD applications.

Install Pixi itself from https://pixi.sh/latest/installation/ if needed. Pixi
manages Python/Git; Windows PowerShell and Autodesk software/licensing are host
prerequisites. `doctor` detects files at default locations, not a working license
or SDK. Verify alternate install paths if needed. Establish exact compiler,
runtime, or interop requirements before adding dependencies for a Windows adapter.

## 2. Verify actual Vault reads and freeze a pilot snapshot

The configured server is `svault5`, vault `IDF VAULT`, vault ID `28`. The pilot is:

```text
$/PROJECTS/_PROJECTS BY LAB/SCHULZE (LAB)/ENCLOSURE/Free Standing Enclosure.iam
```

First capture the actual served schema and capabilities in a fresh directory:

```powershell
pixi run --locked capture-api -OutputDirectory "YOUR_SHARED_PATH\vault-cad-exchange\evidence\UNIQUE_RUN"
```

Replace the path with the real Windows share mapping. This capture does not
authenticate, submit jobs, or change Vault settings. The portable alternative is
`pixi run --locked cli --project ..\free-standing-tank-enclosure probe --output PATH`.
Record a resolvable FQDN/HTTPS endpoint if available; Linux could not resolve
`svault5`. Do not change server configuration during qualification.

Inspect the captured schema before relying on the draft reader's requests. Use
authorized credentials already available locally; Vault-account login and an
existing session token are supported, but integrated Windows authentication is
not implemented in the Python reader. If authentication is unavailable, finish
offline/SDK checks and report that specific blocker. Do not substitute fake IDs.

With working authentication:

- Search for the root, then verify its complete folder path and vault identity.
  Record root master ID, file-version ID, folder ID, and selected model state.
- Inspect `file VERSION_ID` and `uses VERSION_ID` against the served API. Resolve
  the exact referenced versions, including library components outside ENCLOSURE.
  Check paging, suppressed/substitute components, model states, and missing refs.
  Do not claim a complete snapshot from one search page or silently use latest
  dependencies in place of those referenced by the root version.
- Download one representative part and the assembly dependency set to an ignored
  local cache/workspace. Preserve the layout and Inventor project resolution
  needed to open them. Use the Vault SDK/client if it is needed for correct
  acquisition; record exact versions actually acquired. Do not check out files
  merely to read/export them.

Reader command forms, with real IDs and locally supplied authentication, are:

```powershell
pixi run --locked cli --project ..\free-standing-tank-enclosure --username USER search 'Free Standing Enclosure.iam'
pixi run --locked cli --project ..\free-standing-tank-enclosure --username USER file VERSION_ID
pixi run --locked cli --project ..\free-standing-tank-enclosure --username USER uses VERSION_ID
pixi run --locked cli --project ..\free-standing-tank-enclosure --username USER download VERSION_ID --output LOCAL_CACHE_PATH
```

`USER`, IDs, and the cache path above are placeholders, not resolved values.
Passwords are prompted when no token/password environment input is supplied.
Avoid credential-bearing transcripts and command-line passwords. Keep native
Inventor downloads outside tracked project files.

## 3. Produce one part and one assembly STEP

Determine whether an existing Job Processor can perform the STEP job types in
the original report. Inspect an actual successful job's parameters, source
version, output IDs, and associations before implementing job submission. Do not
infer parameters from handler names or alter global queue/lifecycle settings.
Use an existing result only if its exact source snapshot can be established.

If the job route is unavailable, use installed Inventor on local acquired copies
to export STEP. A minimal reproducible script or documented GUI export is enough
for this first geometry check. Record which route actually ran. Open the selected
model state, resolve all references, and never save conversion-induced changes
back to the native sources. Do not block a local export on configuring a server
job pipeline. If Inventor resolves a different dependency version, stop calling
it the frozen snapshot and reconcile the discrepancy before accepting the export.

Deliver a real part STEP, the assembly STEP, and one JSON export receipt per file
matching `docs/exchange-protocol.md`. Include actual source master/version IDs,
source paths, translator version, STEP protocol, model state, output SHA-256,
and the assembly dependency-version inventory. Record units, component/solid
counts and representative dimensions/placements as comparison evidence. Report
unresolved or omitted components explicitly. Filename similarity and a STEP
header alone are not conversion evidence.

Reopen the exports in Inventor to check basic geometry and completeness. Exercise
`import-step` and `status` in a **disposable project copy** with these receipts;
confirm a repeated identical import is a no-op. Leave the main project baseline
for Linux FreeCAD review. No production Vault upload is needed for this phase.

Autodesk's Vault 2025 documentation lists Inventor Server for built-in STEP jobs;
full Inventor COM automation has separate requirements. Verify the chosen route's
installed components and license rather than treating their requirements as
interchangeable:
https://help.autodesk.com/cloudhelp/2025/ENU/Vault-Admin/files/GUID-CDD7E780-3322-4560-AA31-43025A845824.htm

## 4. Return results and divide the remaining work

Write a dated Windows results report in the shared exchange run directory. Include:

- Repository commit IDs, any uncommitted changes, environment versions, commands,
  exit codes, test summary, and a distinction between passed/failed/not-run checks.
- Probe/schema location, verified API corrections, authentication method name
  without secrets, and the resolved pilot snapshot/dependency inventory.
- Export route, payload/receipt locations and hashes, Inventor observations,
  import smoke-check results, and exact blockers or unresolved questions.
- Code changes as reviewable patches including new files, or commit IDs once Peter
  has published them. Update the repository plans with actual results. Do not copy
  a Windows checkout over either Linux/shared checkout to transfer changes.

Return to Linux once these artifacts are ready (or with a precise blocker after
the independent checks). Linux will inspect the files in FreeCAD for units,
solids, dimensions, placements, and completeness, then establish the project
reference baseline. Windows remains the owner of Autodesk adapters; Linux owns
FreeCAD validation and Linux authoring, with portable code reviewed across both.

The later reverse-direction pilot needs a committed Linux-authored STEP and an
explicit Vault destination selected with Peter. Inspect available SDK assemblies
now if useful, but defer the live add until that target and payload are known.
Before enabling writes, implement request validation, collision refusal, retry
reconciliation/idempotency, and a result receipt. Verify a successful add by
re-downloading the payload and opening it in Inventor. `prepare-publish` and
`verify-request` currently prepare/check local data only; neither uploads it.
