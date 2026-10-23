# Windows side of vault-cad-tools

## Operating preconditions for live Vault writes

- A valid Autodesk ID sign-in in the Autodesk Identity Manager on the executing
  workstation: Vault 2025 grants read/write client sessions a named-user license only,
  which the SDK takes as that account's token (`AutodeskAccount.GetOAuthToken()`, no
  dialog, token kept in memory). Without it the read/write sign-in fails with
  `VaultLicenseException` 319; read-only sessions need no license.
- Windows authentication to the Vault server with an account mapped in the vault
  (`Set-VaultCadToken.ps1` and the REST read path use the same identity).
- Add files through `Connection.FileManager.AddFile` (`-Route Vdf`); the raw
  `FilestoreService.UploadFilePart` + `AddUploadedFile` pair answered Vault error 155 on
  this server and stays available only for diagnosis (`-Route Soap`).
- Git: the shared clones under `U:\Repositories\github\` are the only remote used on
  this machine (`shared`); Peter pushes to GitHub and fast-forwards them.

## Current result — synchronisation design (revision 2), reference-model probe, REST and Pixi surveys, W1 (2026-10-23)

Evidence: `vault-cad-exchange/evidence/2026-10-23-windows-sync-design-01/` (report `REPORT.md`).
Requested by `to-windows/20261023T141829Z-...` (Peter's directives) and
`to-windows/20261023T142722Z-...` (review). Base: tools `b84e944` + patch `ad3b8431`; project
`b19018f`. No Vault write; no production document opened; nothing committed.

- `docs/native-checkin-adapter-design.md` rewritten as the synchronisation design: per-file
  sync states (`in_sync`, `vault_newer`, `repo_newer`, `both_changed`, `new_in_repo`,
  `new_in_vault`, `unknown`) from the Vault version id, the acquired native hash, the exported
  STEP hash and the repository STEP hash; natives never written in `in_sync`/`vault_newer`;
  folder discovery (roots = IAMs without parents, standalone = no parents and no uses, closure
  by recursive `uses`), incremental acquisition and export with the strict binding kept; the
  metadata contract (`scene.json` + `metadata.json`); protocol v2 request kinds; qualification
  plan; the revision-1 native check-in condensed as the deferred route; open questions.
- Reference-model probe (`Invoke-ReferenceModelProbe.ps1`, disposable copy, new documents
  only): Inventor 2025 accepts the published STEP as a reference model
  (`ImportedGenericComponentDefinition.ReferenceModel = true`); the imported component is
  `LinkedToFile`, `IsEmbedded` (cached translation), health 11778; the wrapper part's
  `File.ReferencedFileDescriptors` lists exactly the STEP while `AllReferencedDocuments` is
  empty; a new assembly placing the wrapper lists only the wrapper. Hence directive 2's route:
  wrapper IPT with the link kept, STEP authoritative, associations IAM -> IPT -> STEP declared
  on add; binding must also walk file descriptors. Vault's own record of IPT -> STEP is
  unverified (needs the disposable live pilot, with authorization).
- REST (read-only, verified): folder contents with `isHidden`/`isCheckedOut`, sub-folders,
  version records with 77 inline properties (lifecycle, revision, category, lab UDPs), all
  versions of a master, `uses`/`parents`, content, 119 property definitions, text search; the
  server's OpenAPI document (65 paths) has no file write at all. Hidden files, reference strings
  (`RefId`/`Source`) and every write need the SDK.
- Pixi win-64: FreeCAD, Typst, Poppler, mkdocs-material resolve on conda-forge; `bpy` only as a
  PyPI wheel for Python 3.13 or 3.11 (workspace pins 3.12); nothing installed.
- W1: `Resolve-RunStatus` gives `complete_with_dialogs` when the watchdog dismissed anything
  (exporter, placement pilot, probe); `Test-SnapshotOutputs` flags `complete*` with failures;
  mock cases S29-S31. Suites: hygiene 27 scripts, 37 mock cases, 3 watchdog, 12 snapshot,
  10 STEP, 11 receipt, 77 Python.

## Earlier result — monitor placement pilot in a disposable copy; adapter design document; dialog watchdog (2026-10-22/23)

Evidence: `vault-cad-exchange/evidence/2026-10-22-windows-placement-pilot-01/` (report
`REPORT.md`). Requested by `to-windows/20261022T182324Z-linux-pilot-ingested-and-placement-route-confirmed.md`;
scope reduced by `to-windows/20261022T185545Z-linux-priority-change-phase-1-build.md`
(finish only what was in progress in the copy, record it, stop). Base: tools `b84e944`,
project `b19018f`. No Vault write, no production save, check-out or check-in; the mirror
root hash is unchanged.

- Acquisition: the published envelope was re-downloaded read-only from Vault version
  994252 and bound by hash (`f7edc118...62ad3`, 7189 bytes); a disposable copy of the
  acquired tree under the project checkout's `.cache/placement-pilot-01/` verified 44/44
  files against `acquisition.json` before anything was opened.
- `Invoke-MonitorPlacementPilot.ps1`: STEP -> `MONITOR\AW2725Q-nominal-envelope.ipt`
  (1 solid body; local extents X 609.51, Y 355.97, Z 72.63 mm; thinnest axis Z taken as
  the screen normal, longest X). Rotation local X -> world X, local Z -> world +Y, local
  Y -> world -Z (det +1). Two grounded occurrences in the root copy: centres
  (597.0, 620.5, -418.9) and (597.0, 620.5, -774.9) mm, each resting on Y 584.16, world
  boxes X[292.2, 901.8] Y[584.2, 656.8] Z[-596.9, -240.9] and Z[-952.9, -596.9]. Saved
  only the root copy (`Save2(SaveDependents=false)`, 14 -> 16 occurrences); reopened: both
  found, transforms identical. Integrity: mirror root unchanged; in the copy only the root
  IAM changed and `OldVersions\Free Standing Enclosure.0009.iam` plus the new IPT appeared.
- Height note for Linux: the accepted snapshot puts the lower platform top
  (`TANK SUPPORT FRAME:2/TANK SUPPORT PLATFORM:1`) at native Y 501.6 mm; 584.16 mm is the
  top of the lower tank resting on it. Placed as instructed, not iterated.
- Hang found and fixed in the tooling: `Save2` blocked for 19 h behind a modal iLogic
  error form ("RunExternalRule: Cannot find an external rule file named: Part Number
  Cleaner", a Before-Save event trigger of the production assembly) with a disabled
  `AIP Migration Errors` dialog queued behind it; `SilentOperation` does not cover add-in
  forms. Closing the form from outside let the run finish correctly (save, persistence
  check, shutdown, project entry removed, previous project restored). `Inventor-Session.ps1`
  now has a dialog watchdog thread (`Start-DialogWatchdog`/`Stop-DialogWatchdog`): it
  records every dialog-like window of the owned pid and dismisses only single-acknowledgement
  dialogs (OK/Close/Continue), never a choice; used by the pilot and `Export-PartAssets.ps1`
  (`dialogs.log`, receipt field `dialogs`). Decision tests S19-S28 (mocks) and
  `Test-DialogWatchdog.ps1` (child MessageBox processes: an OK-only box is dismissed, a
  Yes/No box is left alone, the scan is scoped to one pid).
- Export of the copy for the Linux geometry check (`export/placement-pilot-01/`,
  `Export-PartAssets.ps1 -AllowUnboundInputs` because the copy's paths differ from the
  acquisition's mirror paths): receipt `complete`; 38 distinct parts, 16 groups, 157 leaf
  occurrences (37/155 before the placement: one new part, two new occurrences), 0 suppressed,
  range check over 157 leaves with max deviation 0.0197 cm, clean shutdown.
  `Test-SnapshotOutputs -ExpectParts 38 -ExpectOccurrences 157 -VerifyHashes` passes
  (`export/validation-placement-pilot-01.log`); the two envelope occurrences are in
  `native-snapshot.json` with world transforms identical to the placement receipt;
  `export/export-input-crosscheck.json` binds the 45 opened documents to the acquisition
  record (43 unchanged children match by SHA-256, the root copy differs as expected, the
  IPT is new). Watchdog during that export: one hidden `AIP Migration Errors` dialog
  (#32770, enabled, application not modal) recorded and left alone, nothing dismissed.
  A second, identical export after the hidden-dialog fix (`export/placement-pilot-02/`, receipt `complete`, 38 parts / 157 leaf occurrences) recorded the same hidden dialog as action `leave` ("hidden window while the application main frame is enabled (no modal loop); not blocking, nothing sent"; main frame enabled: True) over 90 polls, 0 dismissed.
- Design document `docs/native-checkin-adapter-design.md` (no implementation): request
  v2 `update_native_assembly`, preconditions including expected version ids and the
  iLogic/dialog hygiene, the add / check-out / associate / check-in / verify sequence with
  journal states, failure handling, open questions (including iLogic on save),
  qualification on a disposable assembly first.
- Cleanups L1, L3, L5, P4 and hygiene check 4 (one variable spelled with different casing
  in one scope) are in the same patch; `README.md` and `docs/` updated.

## Earlier result — first verified live Vault add (2026-10-22)

Evidence: `vault-cad-exchange/evidence/2026-10-22-windows-vault-pilot-01/` (report
`REPORT.md`). Authorized by Peter for exactly one file: request
`e1caf6c0-5802-49a2-9bc8-831912ddf81c`, `AW2725Q-nominal-envelope.step` (7189 bytes,
SHA-256 `f7edc118...62ad3`) into `$/DATA/PROJECTS/_PROJECTS BY LAB/SCHULZE (LAB)/ENCLOSURE`
(folder 953863). Base: tools `99050de`, project `4690c43`.

- Gating first: M1 (`record_result` confirms the version through the catalog and
  compares size, SHA-256 and CRC32 with the download and the executor's server
  values), M2 (journal transition table; `record_result`/`mark_ambiguous` cannot settle
  from `planned`/`uploading`/`ambiguous`), M3, L2, L4, L6, P3 and the payload-path
  check of P2 implemented; 69 Python tests, 24 session mocks, hygiene over 24 scripts.
- Three live attempts, journaled: (1) unlicensed read/write sign-in refused by the
  server with license error 319 before any upload (journal stayed `planned`); (2)
  named-user sign-in and both pre-checks passed, the raw `FilestoreService.UploadFilePart`
  answered Vault error 155, journal `ambiguous`, reconcile found no file, acknowledged
  back to `planned`; (3) `Connection.FileManager.AddFile` succeeded: version 994252,
  master 994251, v1, 7189 bytes, CRC32 682328604, comment carries the Git commit.
- `record-publish` verified all ten checks; `results/e1caf6c0-...json` at the exchange
  root; journal `verified` with the full history.
- Licensing: Vault 2025 needs a named-user license for any write; the SDK takes it as
  the Autodesk ID token of the user signed in to the Identity Manager (static
  `AutodeskAccount.GetOAuthToken()`, no dialog, token never written).
- Read-only drawing check: no IDW/DWG/IPN in the ENCLOSURE or 2W.353 folders and none
  associated with `SLLB Enclosure.iam` v3 or `2W.353 TOP ASSY.iam` v3.

## Earlier result — read-only native BOM, kit and drawing audit (2026-10-22)

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
