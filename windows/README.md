# Windows side of vault-cad-tools

## Current result — read-only native BOM, kit and drawing audit (2026-10-22)

Evidence: `vault-cad-exchange/evidence/2026-10-22-windows-native-bom-audit-01/` (report
`REPORT.md`; deliverables `bom-rows.csv/json`, `virtual-and-excluded.json`, `drawings.json`,
`kit-boundaries.json`, `coincident-tank.json`, `joint-coverage.json`). Requested by
`to-windows/20261022T161838Z-linux-bom-audit-go-ahead-and-patch-answers.md`; read-only,
no Vault write, nothing saved, accepted baseline untouched.

- `Audit-NativeBom.ps1` on the acquired root 991056 (44 documents bound): 7 assembly
  documents, all three BOM views already enabled as stored (nothing enabled in
  memory), 202 rows recorded, 171 instances, 0 suppressed / excluded / reference /
  virtual components, 37 parts all with Normal BOM structure (none Purchased), 8
  compound (multi-body) parts whose bodies are unnamed (`Solid1..n`); custom
  iProperties recorded (McMaster origin fields on the purchased models). All 44
  inputs hash as acquired after the run.
- `Discover-VaultAssociations.ps1 -AllVersions` (GET only, 188 requests): no drawing
  or presentation is associated with any of the 44 acquired versions nor with any of
  the 15 other versions of their masters; the only attachments are the 44 hidden
  design-visualization DWFs; 16 other assemblies across labs reuse these parts.
- Joint coverage (`vault-cad bom-audit-summary`): 7 joints have hardware-named rows in
  their groups (washers, shoulder screws, all exported; whether they belong to the
  joint is not decidable), 2 joints have nothing in any native source (handle to
  panel, top panel), 7 are unknown because the groups' only candidates are compound
  purchased models with unnamed bodies (casters, toggle clamps, 47065T245 with three
  hidden bodies). No native BOM row exists that was not exported.
- Coincident tank: root `SHULZE 2W.353 TANK:1` and `TANK SUPPORT FRAME:1/SHULZE 2W.353
  TANK:1` differ by 6.4e-13 mm; both Normal, visible, enabled, not Reference, three
  constraints each; the parts-only view counts three tanks (the third in `TANK SUPPORT
  FRAME:2`). Unresolved by CAD alone: no native flag marks either as reference-only.

## Earlier result — restart work plan: lifecycle, harness and null-guard fixes; Vault publication dry run (2026-10-22)

Evidence: `vault-cad-exchange/evidence/2026-10-22-windows-review-fixes-vault-dryrun-01/`
(report `WINDOWS-REVIEW-FIXES-VAULT-DRYRUN-2026-10-22.md`, patch
`patches/vault-cad-tools-restart-fixes-and-publication-dryrun.patch` against `0705b40`,
superseding the hardening-02 patch). Work plan answered:
`to-windows/20261022T131939Z-linux-windows-restart-and-work-plan.md`; review
`2026-10-22-linux-restart-review-01/REVIEW.md`. The uncommitted hardening-02 work was
verified byte-identical to its recorded patch before anything changed.

- Review item 1, unknown cleanup observations: `Stop-IsolatedInventor` now lists the
  observations it REQUIRES (documents closed, PID exited, no unexpected process, plus
  previous project active / added entry removed / pre-existing entry still registered
  whenever those actions applied); each must be observed `true`, a null or unreadable
  project manager records them as `false`, and `null` is reserved for actions that
  never applied. Mock cases S14-S17.
- Review item 2, rollback: `Use-TemporaryProject` tracks whether activation was
  attempted and, on any failure after it, re-activates the previous project FIRST,
  observes the active project, then removes only the entry/file it created. New mocks
  change state before throwing (S6b), return without changing it (S6c), and protect a
  pre-existing entry (S6d); S6e refuses a null project manager before any mutation.
- Review item 3, harness ownership: `Invoke-ExporterGuardChecks.ps1` records whether
  the entry and the `.ipj` existed before its setup instance, cleans up in `finally`,
  removes only what setup created, and counts setup and cleanup shutdowns in the
  verdict. Run A (entry absent, 6/6): setup added it, cleanup removed it. Run B
  (`-FixtureOnly`, entry registered beforehand by a separate owned instance, 4/4):
  setup added nothing, exporter and cleanup preserved it, the external cleanup removed
  it; the persisted list ended as `Default`, `Inventor Electrical Project` both times.
- Review item 4, guard values: `Require` validates the RAW result before any cast
  (null, collections, wrong type, empty strings are refusals) and the exporter is
  restricted to primary model states. No false refusal: strict run complete, 37 parts /
  155 occurrences, 44 documents bound, units 21 in / 15 mm / 1 cm, all 37 DATA
  sections identical to the accepted baseline (header timestamp differs).
- Tree connectivity: `Snapshot-Validation.ps1` walks every group's ancestors to `root`
  and flags cycles, self-parents and occurrences hanging on disconnected groups (two
  new self-test cases).
- Vault publication, offline: `src/vault_cad_tools/publication.py` (fingerprint,
  journal with retry blocking, plan, reconcile, exact-byte result verification,
  static and REST read-only catalogs), CLI `plan-publish`, `reconcile-publish`,
  `record-publish`, `catalog-snapshot`, 21 tests; `Publish-StepToVault.ps1 -DryRun`
  resolved 11 of 11 SDK members and refused live mode before creating anything. Live
  READ-ONLY probes: the ENCLOSURE folder resolved to id 953863 (31 files, no STEP), a
  synthetic request planned `planned_not_executed`; two requests targeting the
  existing `panel-spacer.stp` (exact and case-variant name) were refused with the
  collision journaled; no session token reached any written file.
- SDK discovery: no SDK folder is installed; the Vault Client 2025 Explorer assemblies
  (30.4.28) provide the route `WinAuthCredentials -> WebServiceManager -> Connection ->
  IFileManager.AddFile` (SOAP `UploadFilePart` + `AddUploadedFile`); REST 2.0.16 is
  read-only for files. Still needing a live pilot with a user-selected destination:
  the Windows-auth connection, `AddFile` and its returned ids, re-download of the new
  version and the timeout-to-ambiguous path.
- Offline suites: hygiene 22 scripts, session mocks 23, unit fixtures 10, validator
  11, receipt 11, Python 55.
- Not changed: older scripts still use the process-list heuristic; no Vault write;
  accepted geometry untouched.

## Earlier result — Linux review R1-R6 corrected (2026-10-21)

Evidence: `vault-cad-exchange/evidence/2026-10-21-windows-exporter-hardening-02/`
(report `WINDOWS-EXPORTER-HARDENING-02-2026-10-21.md`, patch
`patches/vault-cad-tools-exporter-review-fixes.patch` against `0705b40`). Review
being answered: `2026-10-21-linux-exporter-review-01/REVIEW.md`.

- R1 inventory output: `inventory-raw.json` is an object again (37 items / 155
  CAD instances strict, 1 / 2 fixture); the output variable no longer shares a name
  with the `-Inventory` parameter. `Snapshot-Validation.ps1` validates scene,
  inventory, snapshot and receipt before a run may be `complete`; its self-test
  rejects scalar, truncated, duplicate, missing, miscounted and stock-claiming
  manifests. `Test-ScriptHygiene.ps1` flags parameter/variable case clashes.
- R2 ownership: an unproven or pre-existing COM owner is only released; the mock
  cases assert that nothing is called on the instance. A start failure after proven
  ownership quits the owned instance before rethrowing.
- R3 lifecycle: `Use-TemporaryProject` rolls back a registration whose activation
  fails; `Stop-IsolatedInventor` reports attempted vs observed outcomes (project
  list and active project re-read, PID exit awaited) and `Succeeded` is false on a
  removal, quit or close failure or a PID that never exits. Both the exporter and
  `Measure-PartBodies.ps1` set `FAILED` / exit 1 unless the shutdown was observed;
  receipts and `measure-session.json` carry attempted/observed.
- R4 guards: every required guard query goes through `Require`, which refuses the
  configuration on any API error. Added: nested iAssembly factories, assembly
  occurrence model state vs its definition, assembly occurrence LOD and positional
  representation, root LOD and positional representation must be master-like.
  Still not exercised by fixtures: the snapshot and the two-panel fixture contain
  no factory, adaptive, substitute, mirrored or non-master configurations.
- R5 units: `Step-Units.ps1` validates every `GLOBAL_UNIT_ASSIGNED_CONTEXT`
  (resolvable references, exactly one recognized length unit) and requires all
  contexts to agree; 10 text fixtures. Unit rejection necessarily happens after the
  translator has written the file: the run is `FAILED` and the partial asset must
  not be consumed.
- R6 harness: `Invoke-ExporterGuardChecks.ps1` judges each case from the exit code
  (captured immediately), receipt, asset count, output validation and process list.
  6 of 6 passed: non-empty output directory and strict mode without records refused
  before Inventor starts; tampered intermediate hash (`CASTER ASSEMBLY.iam`) gives
  exit 1, `FAILED`, zero assets, shutdown observed (28.5 s); strict run complete
  with 37 parts / 155 occurrences and hashes verified (124.9 s, owned PID 90240,
  interactive PID 69232 untouched); fixture complete; pre-registered project entry
  preserved and previous project restored, cleanup left `Default` and
  `Inventor Electrical Project`.
- Geometry: all 37 strict assets have DATA sections byte-identical to the accepted
  hardening-01 assets (only the STEP header timestamp differs). The accepted
  baseline is not replaced by this run.
- Offline suites: hygiene over 21 scripts, 15 session mock cases, 10 unit fixtures,
  9 validator cases, 11 receipt cases, 34 Python tests.
- Not changed: the older scripts still use the process-list heuristic; migration is
  gated on integration of this patch.

## Earlier result — snapshot exporter hardened, first pass (2026-10-21)

Evidence: `vault-cad-exchange/evidence/2026-10-21-windows-exporter-hardening-01/`
(report `WINDOWS-EXPORTER-HARDENING-2026-10-21.md`). Base tools `0705b40`. The
Linux review of this run requested the corrections above; its `inventory-raw.json`
files are the string artefact described in R1.

- New `Inventor-Session.ps1`: instance ownership by `MainFrameHWND` → PID (refuses a
  pre-existing process), project entry handling that removes only what the run added,
  shutdown that waits for the PID, and `Confirm-AcquiredInputs` for strict binding.
- `Export-PartAssets.ps1` is strict by default: 44 opened documents (7 assemblies, 37
  parts) bound before any asset is written. Refused in qualification: non-empty output
  directory (0.5 s, no Inventor), missing records in strict mode, and an acquisition
  record with a tampered intermediate-assembly hash (run stopped after binding, zero
  assets written, `FAILED` receipt, PID exited, project restored). Positive strict run:
  37 parts, 155 occurrences, asset units 21 in / 15 mm / 1 cm, receipt `complete`.
- Pre-registered project entry: with `vault-cad-exporter.ipj` registered beforehand,
  the exporter reports `entry_pre_existed: true`, does not remove it, and re-activates
  the previous project; a separate cleanup removed the test entry. Peter's list is
  unchanged (`Default`, `Inventor Electrical Project`).
- `Measure-PartBodies.ps1` reports coverage explicitly: for `MCMASTER 5537T429`, 10 of
  11 body volumes measured and 55 of 55 overlap pairs unmeasurable, so the overlap
  conclusion is UNKNOWN; the VeryHigh mass-property agreement (0.002 %) stands.
- Hardcoded vault/project identities removed from the exporter; Vault ids come from
  the inventory record. Tests: 34/34 Python, 11/11 offline receipt cases.
- Not changed: the older scripts (`Export-InventorStep`, `Inspect-StepInInventor`,
  `Compare-NativeAndStepAssembly`, the two pilots) still use the process-list
  heuristic; moving them to the session module is a follow-up.

## Earlier result — pilot 02, Linux reviewed

Evidence: `vault-cad-exchange/evidence/2026-10-21-windows-native-pilot-02/` and
`2026-10-21-linux-native-review-02/`. Linux code base is now 498279f; the Windows
submission was a full diff from 163ed4c containing already-committed work. Only
new changes were integrated; do not replay the whole old patch on current main.

- `Measure-PartBodies.ps1 -Part IPT[,IPT] -WorkspaceRoot MIRROR -OutputDirectory NEW`
  measures bodies and sweeps mass-property accuracy without saving source parts.
  VeryHigh measurements reduce both flagged differences to about 0.0022%. Some
  body/overlap calls remain unavailable; an empty overlap list is not proof of no
  interference. FreeCAD/native kernels still differ in one compound's volume.
- `Export-PartAssets.ps1 -NativeAssembly IAM -WorkspaceRoot MIRROR -OutputDirectory NEW
  -Acquisition acquisition.json -Inventory dependency-inventory.json` exports part
  assets and raw hierarchy/instance/BOM metadata. 37 part assets, 155 leaves and
  17 groups including root passed Linux reconstruction. Two flexible groups need
  instance-specific positions; definition-only walking misplaces 44 occurrences.
  Unit counts are 21 inch, 15 mm and one cm. FreeCAD returns mm after STEP import.
- `Invoke-NativeParameterPilot.ps1 -Parameters parameters.json -WorkspaceRoot NEW
  -OutputDirectory NEW [-LinuxStep FILE -ExpectedLinuxStepSha256 SHA]` builds the
  nominal AW2725Q envelope from six named dimensions, sketches and extrusion.
  Native reopen/edit/restore/export checks passed (29); Linux validates its STEP.
- `Test-ExportReceipt.ps1`: 11 cases pass, plus four real negative receipt cases.
  Changed-input pilot refusal now precedes even output-directory creation.

These are scoped pilots, not general production editors. Always use fresh output
folders. The new per-part exporter records source/actual hashes but does not yet
refuse every mismatch or bind intermediate assembly hashes as the strict monolithic
exporter does. It assumes the qualified primary-state case; other states/adaptive
geometry, inherited representation overrides, collisions and unknown units need
explicit rejection/qualification. PID ownership and project-list cleanup also
need hardening before concurrent production use. No Vault write or service mode
is qualified. Fixture receipts with local source kind are not Vault receipts.

Raw scene.json contains extended fields and nonportable IDs; its draft-1 label is
not a claim that mechanical-docs accepts it. Preserve raw metadata, map IDs with a
sidecar and apply the supplied proper basis rotation once at the root. Use distinct
nodes for flexible assembly occurrences while sharing part geometry. Do not make
new inch/mm copies just for the renderer: FreeCAD normalizes STEP to mm internally.


## Earlier Windows results (2026-10-21, command-line native pilot)

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

## Earlier Linux review (2026-10-21, native pilot)

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
