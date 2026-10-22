# vault-cad-tools

Pilot 02 (2026-10-21): 37 distinct STEP assets and 155 instance placements now
reconstruct the enclosure's 479 solids in FreeCAD. Default-accuracy Inventor
volume differences shrink to about 0.0022% at VeryHigh accuracy. Windows also
proved native parameter-driven sketches/extrusion and a depth edit/restore cycle
for the monitor fixture (29 checks). All 34 portable tests pass on both hosts;
11 offline receipt cases and the changed-input guard passed on Windows.

New scripts: `Export-PartAssets.ps1` (snapshot exporter), `Measure-PartBodies.ps1`
(diagnostic), `Invoke-NativeParameterPilot.ps1` (nominal monitor fixture),
`Inventor-Session.ps1` (shared instance ownership, project cleanup, input binding).
Exporter hardening (2026-10-21, run `2026-10-21-windows-exporter-hardening-01`): every
opened document (root, intermediate assemblies, parts) is bound to acquisition and
inventory before any asset is written; non-empty output directories, pre-existing
assets, ambiguous STEP units, model-state mismatches, factories, adaptive, substitute
and mirrored occurrences are refused; the Inventor instance is owned by PID and only
project entries the run added are removed. Its raw scene is still not mechanical-docs
loader input without an adapter. See `windows/README.md`. No Vault write adapter or
publication is implemented.

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
   It also exposes the interop enums; read enum values from there, not from memory.
8. `Inventor-Session.ps1` (dot-sourced): `Start-IsolatedInventor` creates a COM
   instance and binds it to the process that owns `MainFrameHWND`. If ownership
   cannot be proven, or the owner existed before the call (the interactive
   session), it only releases its COM reference and throws; nothing is called on
   the instance. Once ownership is proven, a later start failure quits that owned
   instance before rethrowing. `Use-TemporaryProject` registers/activates a project
   file transactionally: if activation fails after registration it removes the entry
   it added and deletes the file it created, then throws. `Stop-IsolatedInventor`
   closes documents, re-activates the previous project only if this run changed it,
   removes only the entry this run added, quits and waits for the PID to exit, and
   reports `Attempted` and `Observed` outcomes separately (project list and active
   project re-read); `Succeeded` is true only when every attempted action was
   observed. `Confirm-AcquiredInputs` binds the root and every referenced document
   to acquisition/inventory records (hash, master id, Vault path; duplicates and
   unresolved references rejected). All collaborators (COM factory, process list,
   owner resolver, releaser, liveness) are injectable for offline tests. Used by
   `Export-PartAssets.ps1` and `Measure-PartBodies.ps1`; the older scripts still
   use the process-list heuristic. `Step-Units.ps1` (`Get-StepLengthUnit`) and
   `Snapshot-Validation.ps1` (`Test-SnapshotOutputs`) are the other shared modules.
9. `Export-PartAssets.ps1 -NativeAssembly IAM -WorkspaceRoot MIRROR -OutputDirectory NEW -Acquisition ... -Inventory ...`
   (strict by default; `-AllowUnboundInputs` only for fixtures without Vault records)
   writes one STEP per distinct part document and model state plus
   `native-snapshot.json`, `scene.json` (draft-1 shaped: mm, row-major 4x4 for column
   vectors, parent-relative, `+Y` up declared with `basis_to_z_up`), `inventory-raw.json`
   and `export-receipt.json` (session PID, attempted/observed shutdown, guards,
   verified inputs, validation result, hashes). Every required guard query fails
   closed: an API error is an unknown configuration and is refused. Refuses:
   non-empty output directory, pre-existing asset, undeterminable or ambiguous
   governing STEP unit (every `GLOBAL_UNIT_ASSIGNED_CONTEXT` validated, all must
   agree), occurrence model state differing from the document's or definition's
   active state (parts and assemblies), iPart/iAssembly factories at the root or
   nested, adaptive, substitute (LOD) and mirrored occurrences, non-master LOD or
   positional representation at the root or on assembly occurrences. The unit check
   can only run after the translator has written the file, so that refusal leaves a
   partial asset behind in a `FAILED` run. The receipt is `complete` (exit 0) only
   when no error occurred, `Test-SnapshotOutputs` accepted the written manifests
   (object shapes, unique ids, references, 4x4 transforms, per-part instance counts,
   totals, receipt asset list and hashes) and the shutdown was observed to succeed.
   Flexible sub-assembly instance positions are preserved.
10. `Measure-PartBodies.ps1 -Part IPT[,IPT] -WorkspaceRoot MIRROR -OutputDirectory NEW`
    records per-body volumes with explicit attempted/succeeded/failed coverage,
    `MassProperties.Volume` at every accuracy, pairwise overlap coverage with an
    explicit `overlap_conclusion` (UNKNOWN when any pair could not be measured),
    exports each part standalone and re-imports it. It writes `measure-session.json`
    and exits 1 when the shutdown was not observed to succeed.
11. `Invoke-NativeParameterPilot.ps1 -Parameters parameters.json -WorkspaceRoot NEW -OutputDirectory NEW [-LinuxStep FILE]`
    authors a native part from named user parameters, saves, reopens, edits and
    restores a parameter, exports STEP and cross-checks an external STEP. Fixture only.
12. Offline tests (no Inventor): `Test-ExportReceipt.ps1` (11 receipt provenance
    cases), `Test-InventorSession.ps1` (23 mock lifecycle cases: unproven or
    pre-existing owner never mutated, start failure after proven ownership quits the
    owned instance, activation that throws before or AFTER changing the active
    project restores the previous project first and removes only the added entry,
    pre-existing entries survive rollback, a null or unreadable project manager makes
    every required cleanup observation false rather than null, removal/quit/close
    failures and a PID that never exits reported as not succeeded),
    `Test-StepLengthUnit.ps1` (10 STEP text
    fixtures: mm, cm, metre, inch, unknown, missing, mixed, unresolved, two length
    units, literal-dollar regex), `Test-SnapshotOutputs.ps1 -SelfTest` (11 manifest
    cases incl. scalar, truncated, duplicate, missing, count mismatch, claimed stock,
    a parent cycle and a self-parented group, both with their hanging occurrences)
    and `-Directory DIR -ExpectParts N -ExpectOccurrences M -VerifyHashes` on a real
    run, `Test-ScriptHygiene.ps1` (AST: parse errors, variables that differ from a
    parameter only by case, functions shadowed by built-ins).
13. `Invoke-ExporterGuardChecks.ps1 -NativeAssembly IAM -WorkspaceRoot MIRROR -Acquisition ... -Inventory ... -OutputRoot NEW [-FixtureAssembly IAM -FixtureWorkspace DIR] [-ExpectParts 37 -ExpectOccurrences 155]`
    runs the exporter for real and judges each case mechanically from the exit code
    (captured immediately), the receipt, the asset count, the output validation and
    the Inventor process list: non-empty output directory and strict mode without
    records (refused before Inventor), tampered intermediate hash (exit 1, `FAILED`,
    zero assets, shutdown observed), positive strict run, unbound fixture, and a
    pre-registered project entry that must survive the run. Ownership of that entry
    is tracked from before the setup instance runs: cleanup, in `finally`, removes
    only an entry or `.ipj` the setup created, an entry present beforehand must still
    be registered afterwards, and the setup and cleanup shutdown outcomes are part of
    the verdict. `-FixtureOnly` skips the strict Inventor cases. Writes
    `guard-checks.json` and one log per case.
14. `Publish-StepToVault.ps1 -Plan plans/UUID.json -OutputDirectory NEW -DryRun`
    re-verifies the payload named by a plan from `vault-cad plan-publish`, resolves
    the eleven SDK members of the add route by reflection against the installed Vault
    Client 2025 assemblies without opening a connection or reading a credential, and
    writes `dry-run.json` with the call sequence it would use. With `-Live -RequestId
    UUID -ExpectedFolder '$/...' -ExpectedFolderId N -ExpectedPayloadSha256 SHA -Journal
    FILE` it performs exactly one add: every gate must match the plan and the journal
    entry must be `planned`; it signs in with Windows authentication plus the Autodesk
    ID token of the user signed in to the Identity Manager (named-user license; the
    token stays in memory), re-checks folder id and name through the SDK, journals
    `uploading` via the CLI, adds the file through `Connection.FileManager.AddFile`
    (`-Route Vdf`, default) and journals `uploaded` with the returned ids and an
    `execution.json`, or `ambiguous` on any exception (no retry). Without either
    switch it refuses before touching anything. First verified live add: 2026-10-22
    (`evidence/2026-10-22-windows-vault-pilot-01/`).
15. `Audit-NativeBom.ps1 -NativeAssembly IAM -WorkspaceRoot MIRROR -OutputDirectory NEW -Acquisition ... -Inventory ...`
    is the READ-ONLY native bill-of-materials audit: it binds every opened document to
    the acquisition record, records every row of the model-data, structured (all
    levels) and parts-only BOM views of every assembly document (item number,
    quantities as the API reports them, BOM structure, merged/promoted/rolled-up,
    component definitions with model state, iProperties incl. custom ones, quantity
    base units, Vault ids), every instance's BOM structure / suppressed / excluded /
    reference / visible / grounded / constraint flags, virtual components, and per
    part the solid-body counts, visibility and body names (kit-boundary evidence).
    Views that are disabled in the stored document are enabled in memory only and
    recorded as such; nothing is saved, and every acquired file is re-hashed after the
    run (`inputs_unchanged_after_run` must be true for `complete`).
16. `Discover-VaultAssociations.ps1 -Inventory dependency-inventory.json -OutputDirectory NEW [-AllVersions]`
    (after dot-sourcing `Set-VaultCadToken.ps1`) lists, with HTTP GET only, the parents
    (drawings, presentations, other assemblies) and children/attachments of every
    acquired version with exact-version associations, describes every external parent
    (folder path, version, referenced model versions) and, with `-AllVersions`, checks
    every other version of each acquired master for drawing associations. Nothing is
    downloaded and the token is never written.

The portable `vault-cad bom-audit-summary --audit DIR --snapshot native-snapshot.json [--joints joint-audit.json] [--discovery DIR] --output NEW`
joins those outputs into `virtual-and-excluded.json`, `kit-boundaries.json`,
`drawings.json`, `coincident-tank.json` (same-part occurrences with identical world
placement, their native flags, parts-only totals and Vault version history) and
`joint-coverage.json` (per reviewed joint: category a in native BOM not exported, a2
in native BOM and exported, b drawing parts list only, c supplied in a kit per
model/vendor data, d absent from all native sources, e unknown), refusing an audit
whose receipt is not `complete` or whose inputs changed. Tests: `tests/test_bom_audit.py`.

Run them with `&` from PowerShell (not `powershell -File`, which flattens array
parameters). Evidence lives in the shared exchange area under
`vault-cad-exchange/evidence/2026-10-21-windows-qualification-01/` (first export),
`.../2026-10-21-windows-native-pilot-01/` (comparison, native pilot, verified export),
`.../2026-10-21-windows-native-pilot-02/` (guards, volumes, part assets, parameters),
`.../2026-10-21-windows-exporter-hardening-01/` (strict exporter qualification),
`.../2026-10-21-windows-exporter-hardening-02/` (Linux review R1-R6 corrections,
offline suites, mechanical guard harness) and
`.../2026-10-22-windows-review-fixes-vault-dryrun-01/` (lifecycle, harness-ownership
and null-guard corrections; Vault SDK discovery and the offline publication dry run).

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

Planning, journal and verification are implemented offline or READ-ONLY against
Vault (details in `docs/exchange-protocol.md`):

```sh
python3 run.py --project ../free-standing-tank-enclosure catalog-snapshot --output snapshot.json --folder '$/AGREED/DESTINATION'
python3 run.py plan-publish /path/to/vault-cad-exchange/requests/REQUEST_ID --journal journal.json --catalog snapshot.json
python3 run.py --project ../free-standing-tank-enclosure plan-publish /path/to/vault-cad-exchange/requests/REQUEST_ID --journal journal.json
python3 run.py --project ../free-standing-tank-enclosure reconcile-publish REQUEST_DIR --journal journal.json --workdir /tmp/reconcile
python3 run.py --project ../free-standing-tank-enclosure record-publish REQUEST_DIR --journal journal.json --master-id M --version-id V --workdir /tmp/verify
```

`plan-publish` re-validates the request, refuses a vault id/name mismatch, a
destination folder that does not exist (folders are never created implicitly) and
any case-insensitive name collision, journals the request id with the fingerprint
of what would be published where, and writes `plans/UUID.json` listing the exact
SDK calls; the same id with a different fingerprint is refused as an identity
conflict, and an `uploading`/`ambiguous` journal state blocks every retry until
`reconcile-publish` has inspected the destination (identical bytes recover the
request with its Vault ids; different bytes record a collision; no file needs an
explicit `--acknowledge-no-file`). The journal follows an explicit transition table
(`mark-uploading`, `mark-uploaded`, `mark-ambiguous`, `mark-failed` are the executor's
moves) and lives on the executing host. `record-publish` accepts only an `uploaded`
request, confirms through the catalog that the version sits in the destination folder
under the destination name, re-downloads it and compares size, SHA-256 and CRC32 with
the payload and the executor's server values, then writes `results/UUID.json` with
every check. None of these commands uploads; `tests/test_publication.py` covers them
(31 cases with fake catalogs and a local HTTP stub), and the Windows executor is item
14 above.

After Windows has verified an add, Linux records it in the project lock:

```sh
python3 run.py --project ../free-standing-tank-enclosure import-publish-result /path/to/vault-cad-exchange/results/REQUEST_ID.json
```

`import-publish-result` re-checks the result against its request directory (fingerprint,
payload and re-download hashes, destination, vault ids, provenance, every verification
check, typed execution record) and against the project's Git history (the committed blob
at the provenance commit must hash to the payload) before appending a `publications`
record; it never reads the executor journal. Identical re-imports are no-ops; conflicting
ones are refused. First qualified live add: 2026-10-22, request `e1caf6c0-...`, Vault
version 994252 (`vault-cad-exchange/evidence/2026-10-22-windows-vault-pilot-01/`).

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
