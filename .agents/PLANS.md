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
  for Linux FreeCAD validation. The handoff/plan updates are uncommitted in both
  tools clones. Windows owns the next integration phase in separate local checkouts.
- [ ] Install the locked environment and run doctor/tests on Windows.
- [ ] Capture actual served OpenAPI and successful STEP job details from Windows.
- [ ] Resolve pilot assembly/dependencies and qualify exact-version STEP conversion.
- [ ] Implement Windows SDK new-file upload, verified receipts, and retry idempotency.
- [ ] Complete FreeCAD/Inventor pilot and then add update/check-in conflict handling.

## Current limitations

`svault5` does not resolve in this Linux session, including outside the sandbox.
Authenticated REST behavior and Windows execution are unverified. No STEP files
have been exported and no Vault writes have occurred. Publication commands only
prepare/validate requests. Automatic export job submission, assembly traversal
pagination, publication-result import, and LFS payload resolution remain future
work. Search is deliberately one page with the returned cursor preserved.

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
coreutils alongside Pixi. Windows/PowerShell execution and actual CAD geometry
remain unverified. Live checks must record real source
and result IDs/checksums; API reachability is not proof of conversion/publication.
