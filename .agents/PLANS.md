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

## Validation and current handoff

34 portable Python tests pass in Guix and locked Windows Pixi. Windows completed
23 native pilot checks and 19 rerun checks in a disposable logged-in-session
workspace. Linux FreeCAD 1.1.3 confirms the exported two-panel geometry/placements.
The fresh-cache guard is Windows-qualified. All 44 verified-export input records
match acquisition/inventory; STEP DATA matches the first export byte for byte.

- [ ] Windows: execute the Linux receipt-join and changed-input guard changes,
  including `windows/Test-ExportReceipt.ps1` (11 offline cases), a real strict
  receipt and unchanged/changed-input pilot reruns. PowerShell is unavailable here.
- [ ] Windows: resolve the two McMaster per-part volume differences with explicit
  accuracy/override settings and per-body/local-frame geometry comparisons.
- [ ] Windows: native named-parameter monitor fixture, saved dimension edit and
  STEP export; manager requires design in Inventor, not just imported geometry.
- [ ] Both: per-part/configuration assets and explicit parent-relative instance
  manifest/BOM metadata for mechanical-docs. Geometry counts are not a BOM.

Windows script updates and Linux follow-up are uncommitted in the Linux checkout;
shared clones are unchanged. Raw results are in `2026-10-21-windows-native-pilot-01`
and `2026-10-21-linux-native-review-01` under the shared exchange evidence directory.
Full enclosure acceptance, service-mode execution, production editing, native
parameter authoring and Vault publication are not claimed. The new comparison
script is diagnostic (basename keys, body visibility, default mass properties);
the pilot is a panel-specific fixture, not a general-purpose safe assembly editor.
