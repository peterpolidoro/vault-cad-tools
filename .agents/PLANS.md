# Vault CAD tools living plan

## Objective

Support versioned Vault-to-STEP imports into project Git repositories and
publication of Linux-authored STEP files back to Vault, using a Windows adapter.

## Architecture decisions

- One tool repository for Linux and Windows; one separate repository per project.
- Python 3.11+ standard-library core, Guix on Linux, locked Pixi on Windows.
  Pixi manages Python 3.12/Git; Autodesk applications and licensing are host-managed.
- Vault REST for reads; installed Windows SDK for initial add/check-in adapter.
- Prefer built-in STEP jobs once qualified; capture actual parameters first.
- Filesystem exchange carries data manifests and payloads, never credentials or scripts.
- Imported references and authored deliverables have separate ownership.
- First publication operation adds a new file only; updates require a later
  qualified checkout/check-in adapter with expected-version checks.

## Milestones (2026-10-21)

- [x] Inspect empty local/shared repositories and the Windows capability report.
- [x] Record pilot root assembly supplied by Peter in the project repository.
- [x] Implement project status, import provenance checks, read-only REST commands,
  portable API capture, and committed-file publication request preparation.
- [x] Complete managed-environment tests (30 passed) and project CLI smoke check.
- [x] Copy reviewed scaffold to local/shared clones and verify identical bytes.
  Initial tools commit `94427de` and project commit `fbe2873` are present in both
  local/shared clones; the original Windows report is preserved.
- [x] Resolve Pixi dependencies for linux-64 and win-64; add doctor and Windows capture tasks.
- [x] Validate locked Pixi test/doctor tasks on Linux and synchronize the updated scaffold.
- [x] Prepare the Windows takeover handoff in `windows/README.md`, covering locked
  tests, real API qualification, an exact-version part/assembly export, and results
  for Linux FreeCAD validation. Peter committed that handoff as `28df37a`.
- [x] Install the locked environment and run doctor/tests on Windows (2026-10-21:
  Pixi 0.82.1 per-user install, `doctor` ready, 30/30 then 33/33 tests, project status OK).
- [x] Capture actual served OpenAPI from Windows (`api-capture/` in the exchange run;
  spec 2.0.16, server 30.4.28.0). Live corrections applied: `search` uses
  `file-versions?q=` (basic search is 403 for an AD account), logout 501 tolerated,
  `win-auth` helper added, `uses` returns association records.
- [ ] Capture successful built-in STEP job details. Blocked: no Job Processor runs on
  the workstation and the REST queue exposes only pending jobs by id, so no
  completed `Autodesk.Vault.STEP.Create.*` job could be inspected. Not required
  while the local Inventor route is used.
- [x] Resolve pilot assembly/dependencies and qualify exact-version STEP conversion
  (root 991056/master 988153 v5 + 43 dependency versions mirrored; part 991092 and
  the assembly exported to AP214 with receipts; re-import counts match except
  503 native vs 479 re-imported unfiltered SurfaceBodies, flagged for comparison).
- [x] Windows export route as reusable scripts: `Get-VaultDependencySnapshot.ps1`,
  `Export-InventorStep.ps1`, `Inspect-StepInInventor.ps1`, `New-ExportReceipt.ps1`,
  plus `Set-VaultCadToken.ps1`. Import smoke test with real receipts passed in a
  disposable project copy (repeat import is a no-op).
- [x] Linux: check both payload hashes, run FreeCAD 1.1.3 shape/extent checks,
  and import the matching panel into the project baseline. Assembly import is
  verified only in a disposable project; 479 valid solids do not establish
  completeness relative to the native model. Detailed evidence and Windows
  follow-up: `vault-cad-exchange/evidence/2026-10-21-linux-validation-01/`.
- [x] Retain receipt extensions (dependencies/validation) in the lock; 34 Guix
  tests pass, and real assembly imports retain all 43 dependency records.
- [x] Windows: reconcile SurfaceBodies vs IsSolid/visibility per component
  (`Compare-NativeAndStepAssembly.ps1`, run `2026-10-21-windows-native-pilot-01`):
  native 503 solid bodies, 479 visible; STEP 479; the 24 hidden bodies are all in
  `MCMASTER 47065T245.ipt` (4 per occurrence, 1 visible, 8 occurrences). Extents
  agree closely; face-evaluator bounds recorded in `comparison-tight/`. Linux
  found +8.46%/+12.30% volume changes in two other parts; acceptance remains pending
  targeted measurements rather than assuming no regeneration is needed.
- [x] Windows: validated the fresh-cache-only guard (same-size wrong file for 991092
  refused, exit 1, no record). `Export-InventorStep.ps1 -Acquisition` now binds every
  opened document to its acquisition hash and refuses unresolved/mismatched inputs.
  The actual `exports-verified/` records pass Linux cross-checks. Linux strengthened
  `New-ExportReceipt.ps1 -RequireVerifiedInputs`; its new negative cases await Windows.
- [x] Windows: command-line native pilot (`Invoke-NativeAuthoringPilot.ps1`): STEP ->
  converted IPT, new IAM with named/grounded occurrences, explicit transforms, move,
  flush constraint with incompatible-move reporting, STEP export, placement report;
  23 checks, same-input fixture rerun without duplicates (19 checks). ByRef COM calls via the C# helper
  `Import-InventorInterop.ps1`.
- [ ] Both: design per-part STEP plus an explicit assembly instance/placement
  manifest (placement-report.json is a first concrete sample of the needed fields).
- [ ] Implement Windows SDK new-file upload, verified receipts, and retry idempotency
  (SDK assemblies 30.4.28.0 present in the Explorer folder; `SDK\Setup.exe` not run).
- [ ] Complete FreeCAD/Inventor pilot and then add update/check-in conflict handling.

## Current limitations

`svault5` does not resolve in the Linux session, including outside the sandbox;
Windows reaches it directly over plain HTTP. Authenticated REST reads are
verified from Windows with the Windows identity; Vault-account login
(`POST /sessions`) is implemented but was not exercised live. The Python CLI has
no integrated Windows authentication; the PowerShell helper supplies the token.
No Vault writes have occurred. Publication commands only prepare/validate
requests. Automatic export job submission, publication-result import, and LFS
payload resolution remain future work. Search is deliberately one page with the
returned cursor preserved. ByRef COM calls (`CreateGeometryProxy`, translator
`Open`) are made through the compiled C# helper; `Inspect-StepInInventor.ps1` still
falls back to `Documents.Open` defaults. Export metadata counts come from an
explicit occurrence-tree walk; `AllLeafOccurrences` is not enumerable from
PowerShell. `SurfaceBody.Volume()` is not callable from PowerShell; volumes come
from `MassProperties.Volume`. The first export run's `solid_body_count` /
`leaf_body_count` fields are unfiltered SurfaceBodies counts; the comparison run
provides `IsSolid`/visibility-filtered counts. Exports made before the
`-Acquisition` option carry no `native_inputs` record. All Windows automation ran
in an interactive desktop session; unattended service mode is unqualified.

## Validation and current handoff — pilot 02

Peter committed the prior Linux/Windows work as 498279f (project 43f99b8).
34 portable tests pass in Guix and Windows Pixi. Windows passed 11 offline receipt
cases, four real negative receipt cases, 19 repeated native-pilot checks and the
changed-input refusal before any new directory/Inventor process. The native
parameter fixture passed 29 checks and Linux FreeCAD validates its STEP.

- [x] Resolve earlier volume differences with explicit VeryHigh accuracy (~0.0022%).
- [x] Per-part assets and raw instance/BOM metadata: 37 parts, 155 occurrences,
  flexible instance placements preserved. Linux matches all 479 solid signatures
  against the earlier acquisition-bound full export; accepted project reference.
- [x] Native monitor parameter/sketch/extrusion creation, reopen/edit/restore/export.
- [x] Harden Export-PartAssets.ps1 (run `2026-10-21-windows-exporter-hardening-01`):
  strict binding of all 44 opened documents before export via
  `Confirm-AcquiredInputs`; refusal of non-empty output, pre-existing assets, unknown
  or ambiguous STEP units, model-state mismatch, factories, adaptive/substitute/
  mirrored occurrences, non-master LOD; vault ids taken from the inventory record.
  Negative cases recorded (non-empty dir, missing records, tampered intermediate
  assembly hash → FAILED receipt, zero assets). Positive strict run complete.
- [x] Instance ownership and project cleanup (`Inventor-Session.ps1`): PID from
  `MainFrameHWND`, pre-existing processes refused, only run-added project entries
  removed (pre-registered entry preserved in qualification), shutdown waited and
  reported. Adopted by `Export-PartAssets.ps1` and `Measure-PartBodies.ps1`.
- [x] Linux review R1-R6 (`2026-10-21-linux-exporter-review-01`) corrected in run
  `2026-10-21-windows-exporter-hardening-02`: inventory output object renamed and
  every emitted manifest validated by `Snapshot-Validation.ps1` before a
  `complete` receipt (R1); unproven or pre-existing COM owner is only released,
  never quit, hidden or changed (R2); transactional project registration with
  rollback, shutdown reporting attempted vs observed outcomes, `Succeeded`
  propagated to receipt status and exit code in both tools, owned instance quit on
  a start failure after proven ownership (R3); fail-closed `Require` guard queries,
  nested factory, assembly model-state and root LOD/positional checks (R4);
  `Step-Units.ps1` validates every unit context and requires agreement, unit
  rejection after translation documented as a FAILED partial run (R5);
  `Invoke-ExporterGuardChecks.ps1` judges negative/positive cases from exit code,
  receipt, assets, validation and process list (R6). Offline: 15 session mock
  cases, 10 unit fixtures, 9 validator cases, 11 receipt cases, AST hygiene, 34
  Python tests. Accepted geometry baseline untouched.
- [x] Restart review cases 1-4 and tree connectivity (`2026-10-22-linux-restart-review-01`,
  run `2026-10-22-windows-review-fixes-vault-dryrun-01`): required cleanup
  observations must be positively observed (null/unreadable project manager = not
  observed, never success); rollback re-activates the previous project before removing
  run-owned entries/files, with mocks that mutate before throwing; the guard harness
  tracks entry/.ipj ownership from before setup, cleans up in `finally` and counts
  setup/cleanup shutdowns (two live runs: entry absent and entry pre-existing);
  `Require` validates raw values before casts and the exporter is restricted to
  primary model states; `Snapshot-Validation.ps1` rejects cycles and disconnected
  groups. Offline: 23 session mocks, 11 validator cases, hygiene over 22 scripts.
  Strict run unchanged (37/155, DATA sections identical to the accepted baseline).
- [x] Vault publication adapter, offline/dry-run only: `publication.py` (fingerprint
  journal with identity-conflict and ambiguous-retry blocking, plan, reconcile,
  exact-byte result verification; static and REST read-only catalogs), CLI
  `plan-publish`/`reconcile-publish`/`record-publish`/`catalog-snapshot`,
  `windows/Publish-StepToVault.ps1 -DryRun` (11 SDK members resolved by reflection,
  live mode refused), 21 tests. SDK route discovered from the installed Vault Client
  2025 assemblies and server WSDLs: WinAuth `WebServiceManager`/`Connection`,
  `IFileManager.AddFile` (SOAP `UploadFilePart` + `AddUploadedFile`); REST 2.0.16 is
  read-only for files. Live read-only probes: destination folder resolved, no-collision
  plan, two collision refusals against an existing `.stp`.
- [x] Read-only native BOM, kit and drawing audit (run
  `2026-10-22-windows-native-bom-audit-01`, requested by Linux for purchasing
  readiness): `Audit-NativeBom.ps1` (all BOM views and rows, instance flags, virtual
  components, body counts, nothing saved, inputs re-hashed), `Discover-VaultAssociations.ps1`
  (GET-only parents/uses for every acquired version and every other version of each
  master) and `vault-cad bom-audit-summary` (joint coverage categories, coincident
  occurrences with native flags and Vault history, kit boundaries). Model counts are
  never purchase quantities; conclusions are observations with confidence levels.
- [ ] Move the remaining Inventor scripts to `Inventor-Session.ps1`; keep them scoped
  to the qualified single-user interactive pilot until then (gated on Linux
  integration of the review patch).
- [ ] Documentation adapter and FreeCAD-mm normalization fix. Source header units
  are provenance; Part.read already returns mm. Keep raw snapshot fields and
  instance nodes; scene keys/extra fields/basis need adapting to the strict loader.
- [x] First live add qualified (run `2026-10-22-windows-vault-pilot-01`, Peter's
  destination `$/DATA/PROJECTS/_PROJECTS BY LAB/SCHULZE (LAB)/ENCLOSURE`, request
  e1caf6c0): M1/M2/M3/L2/L4/L6/P3 fixed with tests first; three journaled attempts
  (license error 319 unlicensed; Vault error 155 on raw `UploadFilePart`, reconciled;
  `FileManager.AddFile` succeeded, version 994252); `record-publish` verified 10/10
  checks; journal host-local (P1). Named-user license via the Identity Manager token.
- [ ] Remaining cleanups from the Linux review: L1 (refuse-not-coerce, schema checks,
  no output overwrite in `bom_audit.py`), L3 (group-level `suppressed` and root
  fields in `assemblies[]`; validator enforcing `suppressed`/`mirrored`), L5
  (server/vault defaults from project config; no workstation name in tests), P4
  (proxy opt-out for the bearer token in PowerShell).
- [ ] Next milestone (proposal only, no edits yet): place the monitor model in a
  disposable copy of the root assembly (STEP -> native IPT via the qualified
  converter, constrained, exported for Linux check), then the native update/check-in
  adapter with expected-version checks and dependency handling; production edits
  and native check-ins stay unauthorized until that route is reviewed.

- [x] Linux (2026-10-22T16:54:49Z): Windows full patch `dd415d54...` integrated UNCOMMITTED on
  0705b40 in this worktree; 60 portable tests pass in Guix; independent static review
  recorded in `vault-cad-exchange/evidence/2026-10-22-linux-bom-audit-review-01/`.
  Audit outputs for run `2026-10-22-windows-native-bom-audit-01` are accepted: Linux
  matched the 37 parts-only rows and all 155 quantities to the project scene and all
  16 joint ids; that run's discovery receipt is `complete` with `all_versions_pass`.
- [ ] Windows M3: `bom_audit.py` may state "no drawing on any version" only when a
  discovery with `status: complete` and `all_versions_pass: true` was supplied;
  otherwise write "not checked". Today the sentence is emitted without `--discovery`.
- [ ] Windows M1/M2: `record_result` must confirm through the catalog that
  `version_id` sits in the destination folder under the destination name and compare
  server size/checksum with the download; add an explicit journal transition table so
  `planned`/`uploading`/`ambiguous` cannot be settled without `reconcile-publish`.
- [ ] Windows P1: the journal is load-once/rewrite-all; before any host shares it,
  make it single-writer per host or locked, or keep the executor journal on Windows
  and let Linux ingest only `results/`.
- [ ] Cleanups: `bom_audit.py` refuses rather than coerces (null/`"2 in"` quantities,
  missing keys, schema) and never overwrites outputs; typed `--execution` values and
  non-dict refusal; restore group-level `suppressed` in `assemblies[]` (dropped by the
  rewrite) or declare the change, and make `Test-SnapshotOutputs` enforce
  `suppressed`/`mirrored` presence; post-run hash check fails on a missing input;
  `svault5`/vault 28 defaults belong to project config; no workstation name in tests;
  delete the run-created `.ipj` on Stop; `includeHidden` in `files_in_folder`;
  proxy opt-out in `Discover-VaultAssociations.ps1`.

- [x] FIRST LIVE VAULT ADD (2026-10-22T18:23:24Z): request e1caf6c0 -> `AW2725Q-nominal-envelope.step`,
  master 994251 / version 994252 in `$/DATA/PROJECTS/_PROJECTS BY LAB/SCHULZE (LAB)/ENCLOSURE`
  (folder 953863); Windows `record-publish` 10/10 checks; Linux re-check and
  `import-publish-result` (new) recorded it in the project lock. Windows patch 8ae939da
  (M1/M2/M3, L2/L4/L6, P2/P3, gated live executor) integrated uncommitted here; 76 tests.
  Protocol facts: Vault 2025 writes need the Autodesk ID named-user token of the
  Identity Manager user (error 319 otherwise); raw SOAP `UploadFilePart` fails with 155,
  `Connection.FileManager.AddFile` is the route; REST folder contents omit hidden files, the
  SDK listing with includeHidden is the collision check; journal lives on the executor host.
- [ ] Windows: monitor placement pilot in a disposable copy (two envelopes from version
  994252 on the lower platform), export for Linux review; then a DESIGN DOCUMENT for the
  native update/check-in adapter (expected version ids, dependencies, journal model, dry run)
  before any production check-out/check-in. Cleanups L1, L3, L5, P4.

Code/results are uncommitted in the Linux CAD repositories; shared Git clones
are unchanged by this review. Raw results live in 2026-10-21-windows-native-pilot-02
and 2026-10-21-linux-native-review-02 under the shared exchange evidence directory.
No Vault writes, production assembly edits or service-mode qualification occurred.
