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
- [ ] Windows: reconcile SurfaceBodies vs IsSolid/visibility per component and
  compare precise native/STEP bounds; then accept or regenerate the assembly.
- [ ] Windows: validate the new fresh-cache-only acquisition guard. Matching file
  size no longer permits reusing an unverified local file. Also bind native hashes
  to inputs actually opened by the exporter and reject unresolved/mismatched refs.
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
returned cursor preserved. The STEP translator's `Open` with a by-reference
target fails from PowerShell, so the re-import check relies on `Documents.Open`
defaults. Export metadata counts come from an explicit occurrence-tree walk;
`AllLeafOccurrences` is not enumerable from PowerShell. Historical Windows body
counters use SurfaceBodies.Count without IsSolid filtering; their labels are not
strict solid-count evidence. The receipt builder still needs stronger checks
binding native input hashes to export-time data before general reuse.

## Validation

The 30 offline regression tests pass in the managed Guix environment. They cover
modified-reference preservation, rollback on manifest failure, source identity,
portable path/symlink handling, payload integrity, committed-byte checks, REST
query encoding, session cleanup, redirect refusal, and download failures. The
project CLI smoke check resolves the configured root assembly and empty lock.
Guix required an unsandboxed run to update its cached environment; no test used
Vault credentials or made live server writes. The locked Linux Pixi environment
also passes all 30 tests and doctor reports its Python/Git dependencies ready.
An HTTPError response cleanup issue exposed there was fixed and revalidated.
Pixi activation inside a pure Guix shell needs glibc detection tools, Bash, and
coreutils alongside Pixi. On Windows (2026-10-21) the locked environment passed
`doctor` and all 33 tests (three added: logout-501 tolerance, HTTP status on
errors, `search` endpoint). Live Vault reads, a 44-file exact-version mirror, two
Inventor STEP exports with receipts, their re-import in Inventor, and the import
smoke test are recorded with hashes in the shared exchange run
`2026-10-21-windows-qualification-01`. Linux now passes 34 tests and validates the
panel and assembly STEP shapes in FreeCAD. The assembly discrepancy remains
unresolved; human/design-intent review and reverse publication are outstanding.
The PowerShell cache guard added on Linux awaits Windows execution. Both real
imports are idempotent in a disposable project, including preservation of extra
receipt evidence. Windows patches plus Linux fixes are uncommitted in the Linux
checkouts; shared Git clones remain unchanged. Live checks must record real source
and result IDs/checksums; API reachability is not proof of conversion/publication.
