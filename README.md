# vault-cad-tools

Windows follow-up (2026-10-21, evidence run `2026-10-21-windows-native-pilot-01`):
the native/STEP body-count difference is accounted for. Per-occurrence
measurement with `IsSolid` and visibility shows 503 native solid bodies of which
479 are visible; the STEP holds 479 visible solids. All 24 hidden bodies belong
to `MCMASTER 47065T245.ipt` (4 solids per occurrence, 1 visible, 8 occurrences).
Native/STEP Inventor extents agree closely. Two other parts still need targeted
volume/surface checks (8.46% and 12.30% differences); counts do not prove geometric
equivalence. The fresh-cache guard was validated with a same-size wrong file.
A command-line native pilot (STEP -> IPT -> IAM with named occurrences -> move,
constrain, export) passed 23 checks and is non-destructive on rerun. Exports can
now be bound to acquisition hashes of every opened document. Linux confirmed
identical STEP DATA between exports and the pilot placements in FreeCAD. All 34
portable tests pass on both hosts. Additional Linux PowerShell receipt/state guards
await Windows qualification. Details: `windows/README.md`.

Command-line tools for exchanging STEP files between Autodesk Vault and Git CAD
projects. The same repository contains portable Python code and Windows helpers.

**Current state:** offline project/import/request operations and a REST reader
are implemented and verified against the live Vault 2025 server from Windows.
A Windows export route exists (`windows/*.ps1`: dependency snapshot, local
Inventor STEP export, re-import check, receipt composition) and produced the
first real pilot part and assembly on 2026-10-21. No command submits Job
Processor jobs or uploads files into Vault; publication remains prepare-only.

## Environments

Linux:

```sh
guix shell --pure -m manifest.scm -- python3 run.py --help
guix shell --pure -m manifest.scm -- python3 -m unittest discover -s tests -v
```

Windows uses Pixi as the standard environment. Install Pixi once following
https://pixi.sh/latest/installation/, then run these from a local tools checkout:

```powershell
pixi install --locked
pixi run --locked doctor
pixi run --locked test
pixi run --locked cli --project ..\free-standing-tank-enclosure status
```

`pixi.toml` and `pixi.lock` define Python 3.12, Git, and their transitive packages
for Windows and Linux. Keep both files in Git. `--locked` prevents accidental
dependency re-resolution. Use `pixi update` deliberately when changing versions.
Guix remains the normal Linux environment; Pixi also supports Linux for portable
task validation. All regression tests and the doctor task pass in the locked
Linux Pixi environment. When nesting Pixi in a pure Guix shell, include `glibc`,
`bash`, and `coreutils` alongside `pixi` for runtime detection and activation.
On Windows the locked environment installed and passed `doctor` and all tests
(2026-10-21, Pixi 0.82.1 installed per-user with the official `install.ps1`;
the winget MSI needs administrator rights, which the workstation user lacks).

Pixi itself, Windows PowerShell, Autodesk Vault/Inventor/Inventor Server, Autodesk
SDK components, and Vault licensing/authentication are host prerequisites. They
are not installed by this manifest. `doctor` checks Python and Git and reports
Windows Autodesk files at default locations; it does not establish that a license,
SDK API, or conversion works. Add SDK/runtime dependencies once the Windows
adapter's actual requirements are established.

`python -m pip install .` installs the `vault-cad` entry point in a separately
managed Python environment if desired; the Pixi tasks use `run.py` directly and
do not need pip or an editable install.

## Pilot

The sibling `free-standing-tank-enclosure` repository owns the project config.
Run these from this tools checkout, inside the managed environment:

```sh
python3 run.py --project ../free-standing-tank-enclosure status
python3 run.py --project ../free-standing-tank-enclosure probe --output ../free-standing-tank-enclosure/.cache/probe-001
python3 run.py --project ../free-standing-tank-enclosure --username USER search 'Free Standing Enclosure.iam'
```

`probe` is unauthenticated. It captures server info, the vault list, and the served
OpenAPI description. The initial Linux session could not resolve `svault5`; run
the probe on Windows or configure a reachable base URL. See `windows/README.md`.

For authenticated reads, set `VAULT_CAD_TOKEN` to an existing session token, or
use `--username` to prompt for a Vault-account password. `VAULT_CAD_USERNAME` and
`VAULT_CAD_PASSWORD` can be supplied by a local secret manager. Never put them in
Git or the exchange directory. An externally supplied token is not logged out;
a session created by the tool is closed after the command (Vault 2025 answers
501 to the logout call; that is tolerated silently and the session expires
server-side). On Windows, dot-source `windows\Set-VaultCadToken.ps1` to obtain a
token with your Windows identity (`POST /sessions/win-auth`, verified) without
typing a password. The reported server URL uses HTTP, so login credentials and
tokens lack TLS protection; discuss HTTPS with the administrator. HTTP redirects
are refused, and ambient proxies are not used for this internal API.

`search` queries `GET /vaults/{id}/file-versions?q=...` (files only) and returns
one page, including the server's cursor; use `--cursor` for the next page. The
basic-search endpoint `search-results` returned HTTP 403 for an ordinary Active
Directory account on Vault 2025, so it is not used. `file VERSION_ID`, `uses
VERSION_ID`, and `job JOB_ID` return raw server JSON. `uses` results are
association records (`parentFile`, `childFile`, `fileAssocType`), not bare files.
Search results are discovery aids, not a version lock.

```sh
python3 run.py --project ../free-standing-tank-enclosure --username USER download VERSION_ID --output ../free-standing-tank-enclosure/.cache/part.ipt
```

Downloads refuse to overwrite a destination. The `uses` query requests version
associations rather than latest associations. On Vault 2025 the recursive query
for the pilot assembly returned all 45 associations in one page (`limit=500`);
`windows\Get-VaultDependencySnapshot.ps1` follows `cursorState` paging anyway and
fails if the page count does not reach `totalResults`.

## Windows export route (verified 2026-10-21)

The Job Processor route is not used yet: no processor runs on the workstation,
built-in STEP job parameters are undocumented, and the queue does not expose
completed jobs for inspection. Instead, four PowerShell scripts under `windows/`
run on a machine with Inventor 2025 installed and Vault access:

1. `Get-VaultDependencySnapshot.ps1 -RootVersionId ID -OutputDirectory EVIDENCE -CacheRoot MIRROR`
   freezes the exact dependency versions of a file version (recursive `uses`),
   writes `dependency-inventory.json`, and downloads every version into
   `MIRROR\<Vault path without $/>` with `acquisition.json` (SHA-256 per file).
   The mirror root stands in for Vault's `$`, so Inventor resolves references
   unchanged. Nothing is checked out.
2. `Export-InventorStep.ps1 -WorkspaceRoot MIRROR -Document PATH[,PATH] -OutputDirectory OUT`
   starts a separate hidden Inventor instance (aborting if COM attached to a
   running one), activates a temporary single-user project whose workspace is
   the mirror, exports STEP (AP214 by default, sketches excluded, other
   translator defaults kept), records units, model state, occurrence/body
   counts, range box and unresolved references in `<name>.export-metadata.json`,
   never saves native files, then restores the user's project list and quits.
3. `Inspect-StepInInventor.ps1 -Step FILE[,FILE] -WorkspaceRoot MIRROR` re-imports
   the STEP files in another hidden instance and writes `<name>.step-inspection.json`
   (occurrences, bodies, extent) for comparison with the export metadata.
4. `New-ExportReceipt.ps1 -Metadata ... -Inventory ... -Acquisition ... -VaultPath '$/...'`
   joins those records into the `docs/exchange-protocol.md` receipt, re-hashing
   the STEP file and embedding the dependency inventory for assemblies. With
   `-RequireVerifiedInputs` it refuses metadata that was not bound to acquisition.

Binding exports to exact versions: `Export-InventorStep.ps1 -Acquisition acquisition.json`
re-hashes the root and every document Inventor actually opened, requires each to be
listed in the acquisition record with the same SHA-256, refuses unresolved references
(unless `-AllowUnresolvedReferences`), and records `native_inputs` in the metadata;
the receipt then carries `native_inputs_verified` and `acquired_but_not_opened`.

Measurement and native authoring (added for the command-line pilot):

5. `Compare-NativeAndStepAssembly.ps1 -NativeAssembly IAM -WorkspaceRoot MIRROR -Step FILE -OutputDirectory OUT [-TightBounds]`
   measures both sides per leaf occurrence and per distinct document
   (SurfaceBodies, `IsSolid` solids, visible solids, `MassProperties.Volume`,
   RangeBox, optional face-evaluator tight bounds) and writes `comparison.json`
   listing the documents whose counts differ.
6. `Invoke-NativeAuthoringPilot.ps1 -StepInput FILE -WorkspaceRoot NEW -OutputDirectory OUT`
   imports a STEP as a converted part, saves it as an IPT, builds a new IAM with
   two named occurrences (one grounded), moves one, adds a named flush constraint,
   reports an incompatible move as not achieved, exports STEP and writes a
   placement report. Reruns reuse the IPT (by hash), occurrences (by name) and the
   constraint (by name) instead of duplicating them; outputs are never overwritten.
   This is a fixed two-panel fixture (47 × 1/8 × 47 inches), not a general assembly
   editor. Use a dedicated disposable workspace; changed STEP inputs are refused.
7. `Import-InventorInterop.ps1` (dot-sourced) compiles a two-method C# helper
   against `Autodesk.Inventor.Interop.dll` for the ByRef COM calls PowerShell cannot
   make (`CreateGeometryProxy`, translator `Open`). No extra packages are needed.

Run them with `&` from PowerShell (not `powershell -File`, which flattens array
parameters). Evidence lives in the shared exchange area under
`vault-cad-exchange/evidence/2026-10-21-windows-qualification-01/` (first export)
and `.../2026-10-21-windows-native-pilot-01/` (comparison, native pilot, verified export).

## Import a Windows-generated STEP

Create an export receipt according to `docs/exchange-protocol.md`, using actual
source IDs, settings, and a SHA-256 of the output. Then:

```sh
python3 run.py --project ../free-standing-tank-enclosure import-step /path/to/part.step --receipt /path/to/part.export.json --as references/part.step
```

The importer validates the checksum and STEP envelope, refuses to overwrite
untracked/modified references, records provenance, and rejects Windows filename
collisions and paths outside `references/`. It does **not** validate CAD geometry.
Inspect the result in FreeCAD before accepting it. Commit models and lock-file
updates together. Keep edits in project `designs/` and authored exports in `step/`.

## Prepare a new-file publication

Commit the authored STEP first. Then supply an agreed Vault destination and
filesystem exchange path:

```sh
python3 run.py --project ../free-standing-tank-enclosure prepare-publish step/new-part.step --vault-folder '$/AGREED/DESTINATION' --exchange /path/to/vault-cad-exchange
python3 run.py verify-request /path/to/vault-cad-exchange/requests/REQUEST_ID
```

These commands **do not upload**. They package and validate a committed file for
the forthcoming Windows uploader. Existing destination names must cause failure;
automatic overwrite/check-in is outside the initial protocol. STEP bytes must
match the Git commit. LFS is not implemented yet. Read the Windows handoff before
implementing an uploader or processing any real request.

The first supported release will be established by one real part/assembly export
and one new-file publication verified in FreeCAD and Inventor. The export half
exists as evidence (pilot part and assembly with receipts, re-opened in Inventor);
targeted enclosure checks and the publication half are still open, so the end-to-end
milestone is not claimed.
