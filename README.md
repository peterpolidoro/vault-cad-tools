# vault-cad-tools

Command-line tools for exchanging STEP files between Autodesk Vault and Git CAD
projects. The same repository contains portable Python code and Windows helpers.

**Status (2026-11-10).** Each of the following has been demonstrated once, on
the enclosure pilot:

- **Vault to repository.** An exact-version snapshot of one root assembly (44
  files) was exported with a local Inventor instance as 37 per-part STEP files
  plus placement and BOM records for 155 occurrences, every opened document
  bound to its acquired hash. The project imported them with provenance in
  `vault-lock.json`, and FreeCAD reconstructs the assembly's 479 solids from
  them.
- **Repository to Vault.** One new STEP file was added through the Vault SDK
  from a gated, journaled request and verified by an exact-byte re-download
  (2026-10-22).
- **Read-only audits.** The native BOM views, and the drawing and attachment
  associations of every acquired version.
- **Pilots in a disposable copy only.** Native parameter-driven authoring,
  placing a STEP envelope in an assembly, and keeping a STEP as a referenced
  source inside a wrapper part.

Not implemented: updating or checking in an existing Vault file, folder-level
discovery, change detection against the lock, incremental re-export, a single
synchronisation command, unattended operation, and export through the Job
Processor. The synchronisation between Vault and a repository is a design
document only (`docs/native-checkin-adapter-design.md`). Nothing writes to
Vault without Peter's explicit request.

The 102 portable tests pass in the Guix environment (2026-11-12). The Windows
side's own suites and results are recorded in `windows/HISTORY.md`.

Where this work is going, and the layout of project repositories that the
exporter and importer write, are kept in the sibling `mechanical-cad`
repository (`docs/direction.md`, `docs/layout-specification.md`). Peter
decided the layout's choices on 2026-11-11, and the enclosure has been in it
since 2026-11-12. The exporter's package is specified there as a draft
(`docs/exporter-package.md`) that Peter has not reviewed.

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
OpenAPI description. The Vault server's name does not resolve from the Linux
workstation; run the probe on Windows or configure a reachable base URL.

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

A root assembly is exported for a project with `Export-Package.ps1` (item 26
below), and `import-snapshot` reads its package into the project.
`Export-PartAssets.ps1` (item 9) writes the earlier package and
`Export-InventorStep.ps1` (item 2) one STEP file per document; they are kept
for now, are not run for new work and get no further corrections. The scripts
that serve only the earlier formats are listed at the end of
`windows/README.md`; nothing of that list is removed yet.

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
   owner resolver, releaser, liveness) are injectable for offline tests.
   `Start-DialogWatchdog`/`Stop-DialogWatchdog` run a watchdog thread over the owned
   pid's dialog-like windows: every one is recorded (`dialogs.log`, receipt field
   `dialogs`), only a window whose visible, enabled buttons are exactly one
   acknowledgement (OK/Close/Continue) is dismissed, a choice is never answered
   (added after a Before-Save iLogic error form of the production assembly blocked
   `Save2` for 19 hours; `SilentOperation` does not cover add-in forms); `Resolve-RunStatus`
   turns a run's `complete` into `complete_with_dialogs` when anything was dismissed (W1). Used by
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
    cases), `Test-InventorSession.ps1` (39 mock cases: unproven or
    pre-existing owner never mutated, start failure after proven ownership quits the
    owned instance, activation that throws before or AFTER changing the active
    project restores the previous project first and removes only the added entry,
    pre-existing entries survive rollback, a null or unreadable project manager makes
    every required cleanup observation false rather than null, removal/quit/close
    failures and a PID that never exits reported as not succeeded; dialog decisions
    S19-S28: a single visible OK is dismissed, Yes/No, Save/Don't Save and OK+Cancel
    are left alone, a disabled window is blocked, hidden buttons do not count, a hidden dialog is dismissed only while the application main frame is disabled by a modal loop;
    S29-S31 run status: a dismissed dialog makes `complete_with_dialogs`, record-only keeps
    `complete`, FAILED stays; S32 and S33: `Confirm-AcquiredInputs` refuses a root whose
    referenced documents, or a document whose file descriptors, are missing as a
    collection or give fewer items than they count),
    `Test-DialogWatchdog.ps1` (live but without Inventor: child powershell
    MessageBoxes; an OK-only box is dismissed so the child exits by itself, a Yes/No
    box is recorded and left alone, the window scan is scoped to one pid),
    `Test-StepLengthUnit.ps1` (10 STEP text
    fixtures: mm, cm, metre, inch, unknown, missing, mixed, unresolved, two length
    units, literal-dollar regex), `Test-SnapshotOutputs.ps1 -SelfTest` (12 manifest
    cases incl. scalar, truncated, duplicate, missing, count mismatch, claimed stock,
    a parent cycle and a self-parented group, both with their hanging occurrences)
    and `-Directory DIR -ExpectParts N -ExpectOccurrences M -VerifyHashes` on a real
    run, `Test-ScriptHygiene.ps1` (AST: parse errors, variables that differ from a
    parameter only by case, functions shadowed by built-ins, one variable spelled
    with different casing in the same scope; every run first proves these checks on
    nine built-in snippets and fails if they cannot find their own target),
    `Test-StepHeader.ps1` (27 cases on synthetic STEP text: header fields, the
    data-section hash, the normalised header, refusals; entity counts, the form of
    an INVISIBILITY mark, entity differences, whether a difference is confined
    to the saved view, a `FILE_SCHEMA` that names two schemas),
    `Test-PackageFormat.ps1` (33 cases: the package's JSON, directory names and
    Vault block, and the check of a written package on synthetic ones: the
    manifest, `source.json`, `part.step`, `assembly.json`, `occurrences.json`,
    forbidden text, two runs compared; guard queries and optional reads, the
    guards a run evaluated, a directory before and after, the completion of a
    package with `package.json` written last and removed by whatever fails after
    it; a collection that must give as many items as it counts, a count that is
    handed its collection, a value that is given or nothing, a package withheld
    before `package.json` is written, and what the file system says about
    `package.json` after a removal that failed; and `Export-Package.ps1`,
    `Invoke-AssemblyStepProbe.ps1` and `Invoke-StepImportProbe.ps1` read as syntax
    trees: no cast in a guard query, no count asked in one step, Inventor started
    inside the `try` whose `finally` stops it, nothing outside a `try` afterwards
    or in that `finally`), `Get-VaultFileFacts.ps1
    -SelfTest` (7 cases of the join with the inventory) and
    `Discover-VaultFolder.ps1 -SelfTest` (8 cases of the root and standalone rule).
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

17. `Invoke-MonitorPlacementPilot.ps1 -StepInput COPY\incoming\X.step -ExpectedStepSha256 SHA -WorkspaceRoot COPY\workspace -RootAssembly 'DATA\...\Root.iam' -MirrorRoot MIRROR -Acquisition acquisition.json -OutputDirectory NEW [-CenterXmm -CenterZmm -RestYmm]`
    is a placement PILOT in a disposable copy of the acquired tree (never the mirror,
    never production): it imports a hash-bound STEP envelope to a native IPT, reports the
    envelope's own axes (longest and thinnest extents), builds a proper rotation that
    maps the long axis to X and the thin axis to +Y, places one grounded occurrence per
    requested centre resting on the requested height, saves ONLY the root copy
    (`Save2(SaveDependents=false)`), reopens it to prove persistence, and re-hashes every
    copied file and the mirror root. `placement-receipt.json` carries the transforms in
    cm and mm, the world boxes and the hash evidence; `dialogs.log` and the receipt's
    `dialogs` field record every dialog the watchdog saw; the status is `complete`, or
    `complete_with_dialogs` when the watchdog dismissed anything (W1). Supports, mates and
    acrylic are not invented.
18. `Invoke-ReferenceModelProbe.ps1 -StepInput FILE -ExpectedStepSha256 SHA -WorkspaceRoot COPY -OutputDirectory NEW`
    answers, in a disposable copy and with new documents only, whether Inventor keeps a STEP
    as a REFERENCED source (`ImportedComponents` with `ReferenceModel = true`) and what the
    wrapper part and a new assembly then list in `File.ReferencedFileDescriptors` and
    `AllReferencedDocuments`; verified 2026-10-23 (linked, embedded cache, the STEP visible only
    through the descriptors). The Vault <-> repository synchronisation design (sync states,
    folder discovery, incremental export, metadata contract, the reference-model route, the
    deferred native check-in) is a design document only: `docs/native-checkin-adapter-design.md`.
19. `Step-Header.ps1` (dot-sourced): `Get-StepFileInfo` reads a STEP file as bytes and returns
    its SHA-256, the data-section SHA-256 (from the `DATA` keyword to the end of the file),
    the `FILE_NAME`, `FILE_DESCRIPTION` and `FILE_SCHEMA` fields and the protocol;
    `Set-StepFileHeader` replaces the `FILE_NAME` statement and nothing else, by default with
    the normalised header of the layout specification (name `part.step`, time stamp
    `1970-01-01T00:00:00`, empty author, organization and authorisation), refuses to
    overwrite and proves on every call that the data-section hash is unchanged. It is a
    port of `mechanical-cad/mechanical_cad/stepfile.py` and gives the same bytes (49 real
    files compared on 2026-11-10). It also reads the data section as text:
    `Get-StepEntityCounts` (instances per entity type), `Get-StepEntities`,
    `Get-StepInvisibility` (what a file marks invisible, and whether the mark has the one
    form `mechanical-cad` understands), `Compare-StepEntities` (instances that differ
    between two files) and `Test-StepViewBlockConfinement` (whether two exports differ
    only in the saved view, that is in what `CAMERA_MODEL_D3` reaches).
    `Get-StepEntityCounts` counts `BREP_WITH_VOIDS` beside `MANIFOLD_SOLID_BREP` by
    default. `Get-StepInvisibility` follows the reference in every case it has: the item
    a styled item styles is its third parameter, and a representation that would lose
    every item is refused. `Get-StepFileInfo` returns every name of `FILE_SCHEMA` in
    `schemas`; `schema` and `protocol` are those of the first.
20. `Invoke-StepExportProbe.ps1 -Part REL[,REL] -WorkspaceRoot MIRROR -Acquisition acquisition.json -OutputDirectory NEW [-Variant @{label; protocol; open; camera; options; properties; output_name},...] [-ViaAssembly REL -Inventory dependency-inventory.json] [-WorkOnCopies]`
    exports parts in ONE owned Inventor instance per call, in named variants (application
    protocol, translator options, iProperties changed in memory only and only on copies),
    with every part bound to its acquired hash first and re-hashed afterwards; the receipt
    holds size, both hashes, schema, header fields, length unit, entity counts and the
    translator options reported and read back. A variant's `open` says how the document is
    reached: `invisible` (opened by itself without a view), `visible` (with a view, whose
    camera a `camera` entry can rotate, zoom or set) or `referenced` (taken from the
    invisibly opened, hash-bound assembly, exactly as `Export-PartAssets.ps1` reaches a
    part; the receipt then holds a census of views). Documents are never saved.
21. `Compare-StepExports.ps1 -Path A.step,B.step[,...] [-Label ...] [-OutputPath NEW.json] [-ListDifferingEntities] [-AllowDifferences]`
    says whether several exports of one part have identical data sections, which header
    lines differ, whether they normalise to identical files and, on request, which entity
    instances differ (type and text).
22. `Get-VaultFileFacts.ps1 -Acquisition acquisition.json -Inventory dependency-inventory.json -OutputDirectory NEW -BaseUri URL -VaultId ID`
    (REST GET only) reports for every acquired master the latest version id and number,
    whether anything changed since the acquisition, revision, lifecycle definition and
    state, check-in date and check-out state beside the inventory's values, and the
    property system names the server returns, without values.
23. `Get-PartFeatureDump.ps1 -Part REL[,REL] -WorkspaceRoot MIRROR -Acquisition acquisition.json -OutputDirectory NEW`
    dumps, without saving, what the Inventor API returns for parameters, hole features
    (tap, clearance, extent, placement, centres), thread features, patterns and sheet-metal
    data. Property names come from the interop assembly by reflection; every call that
    throws is listed in `call-failures.json`.
24. `Discover-VaultFolder.ps1 -FolderPath '$/A/B' [-FolderId ID] -OutputDirectory NEW -BaseUri URL -VaultId ID`
    (REST GET only) lists a Vault folder and classifies its files within the folder's own
    scope (review finding R1): a root is an assembly no file of the scope uses, a
    standalone file is used by none and uses nothing, parents outside the scope are
    recorded as `external_parents` and never disqualify. `discovery.json` holds the files
    with their roles and the closure of every root.
25. `Invoke-AssemblyStepProbe.ps1 -NativeAssembly IAM -WorkspaceRoot MIRROR -Acquisition ... -Inventory ... -OutputDirectory NEW`
    has Inventor's STEP translator write a whole assembly as ONE file (AP242 unless told
    otherwise), from the root opened and bound exactly as the exporter opens it, without
    changing a representation and without saving. The receipt holds the active
    representations, Inventor's occurrence tree with every flag and placement, the
    translator's options, the file's entity counts and the hash of every file of the
    mirror before and after. Such a file is evidence for a comparison with the recorded
    placements; it is not part of any package. What its receipt states as a fact (an
    occurrence is not suppressed, is visible; a document has no view; nothing is dirty)
    is read as a guard query; a flag it only describes is null when Inventor does not
    give it.
26. `Export-Package.ps1 -NativeAssembly IAM -WorkspaceRoot MIRROR -Acquisition ... -Inventory ... -OutputDirectory PACKAGE -WorkDirectory WORK`
    writes the package of `mechanical-cad/docs/exporter-package.md` (draft 3), strict
    binding only: `files/<master id>_<state>/` with `source.json` and `part.step` (AP242,
    header normalised) or `assembly.json` (the children as the document defines them),
    `occurrences.json` (every occurrence in the root's context: its placement in its parent
    and in the root, whether it differs from its definition, its flags) and, last and only
    when every check passed, `package.json`. It is the exporter: a root assembly is
    exported for a project with this script. `Export-PartAssets.ps1` writes the earlier
    format; its output and its default protocol are unchanged. Every file
    but `package.json` is the same bytes when the same versions are exported again, and no
    file carries a workstation path or a host or account name (checked before
    `package.json` is written). The translator's own files, the run's receipt and the logs
    go to WORK and stay on the workstation. Besides the exporter's refusals it stops when
    a document has a view, when a file marks items invisible in a form that is not
    understood, on a suppressed occurrence, and when a placement differs from its
    definition under no flexible occurrence. The translator sometimes names a second,
    unrelated schema in a file's `FILE_SCHEMA`: such a file is neither delivered nor
    repaired, the part is exported again (three attempts at most, the same data section
    required each time) and every attempt is recorded. Every file of the mirror is hashed
    before Inventor starts and after it has exited; a file that changed, appeared or
    disappeared fails the run. The receipt is always written and says how often each guard
    was evaluated. `package.json` is written last, whatever fails after it removes it, and
    only a run that ends `complete` leaves it: a run in which the watchdog dismissed a
    dialog ends `complete_with_dialogs`, exits 1 and leaves no `package.json`. That is
    decided before the file is written, so such a run writes none. What the receipt
    says about the file (`package_json_present`) is asked of the file system after the
    last attempt to remove it, and a `package.json` that is still there fails the run.
    A read of a document's length unit that fails stops the run; null is for a unit
    Inventor returns as nothing.
    Draft 3 of the specification follows the exporter
    in two things draft 2 had otherwise: the placements of flexible instances are not
    written as `overrides` (the import command derives them from `occurrences.json`),
    and the hash of the translator's file is in `package.json`, because it changes with
    every export.
27. `Package-Format.ps1` (dot-sourced): the package's JSON writer (two spaces, LF, keys in
    the order given, a double written so that it reads back the same), directory names,
    the nine vault fields from the two records of the acquisition, `Test-PackageOutputs`
    (a written package against itself), `Find-PackageForbiddenText`,
    `Compare-PackageRuns`, `Complete-Package` (checks, writes `package.json` last, checks
    again, removes it when anything fails after it), `Get-PackageDirectoryHashes` and
    `Compare-PackageDirectoryHashes`, and what the scripts that drive Inventor ask the API
    through: `Get-RequiredValue`, `Assert-RequiredObject` and `Get-RequiredCount` (guard
    queries that refuse nothing, a failure, a collection and another type, and hold no
    cast), `Get-RequiredItems` (a collection that must exist and give as many items as it
    counts), `Get-OptionalValue` and `Get-OptionalObject` (null when the API gives nothing),
    `Get-OptionalCount` (handed the collection itself: a count asked in one step is 0 for
    a collection that is missing), `Get-GivenValue` (null for nothing, a read that fails
    stops the run), `Get-PackageOutcome` (whether `package.json` is there and whether that
    fits the run's status), and a ledger of the guards a run evaluated.
28. `Invoke-StepImportProbe.ps1 -Step FILE -WorkDirectory WORK -OutputDirectory NEW [-ExpectedSha256 SHA] [-Convert]`
    reads one STEP file that Inventor did not write (a whole assembly built with FreeCAD,
    for example) into an owned, invisible instance with the translator's `Open`, nothing
    written and every document closed without saving, under the dialog watchdog. The
    receipt holds what the file's text says (header, schema, length unit, entity counts),
    the translator's options, the document's type and unit, every occurrence with its path
    of names and its placement, and for every part document its bodies and its volume at
    the default accuracy and at `k_VeryHigh`. With `-Convert` the file is read a second
    time so that Inventor writes native documents into WORK, a disposable copy, and the
    files that appeared are listed. No Vault access. `Inspect-StepInInventor.ps1` (item 3)
    is the older re-read of a single-file export and is unchanged.

REST listings are read as ONE page (`limit` up to 1000) whose row count must equal the
server's `totalResults`: on this server the paging cursor is id-based while rows are ordered
by name, so following it repeats and skips rows. A listing that does not fit is refused.
The results of items 19 to 24 on the enclosure are in
`vault-cad-exchange/evidence/2026-11-10-windows-layout-tests-01/`; the AP242 tests of
2026-11-11 (stability, the saved view, the translator's options, all 37 parts) are in
`.../2026-11-11-windows-ap242-tests-01/`. Inventor's own STEP export of the root assembly
(item 25) is in `.../2026-11-12-windows-assembly-step-01/`, and the first two packages
written by item 26 are in `.../2026-11-12-windows-package-01/`. The run after the Linux
review's findings on the script were corrected is in
`.../2026-11-12-windows-package-findings-01/`. What Inventor makes of the STEP file of
the whole enclosure that FreeCAD built on Linux (item 28), and the run of the exporter
after the six remarks of the Linux review were corrected, are in
`.../2026-11-13-windows-new-layout-02/`.

The portable `vault-cad bom-audit-summary --audit DIR --snapshot native-snapshot.json [--joints joint-audit.json] [--discovery DIR] --output NEW`
joins those outputs into `virtual-and-excluded.json`, `kit-boundaries.json`,
`drawings.json`, `coincident-tank.json` (same-part occurrences with identical world
placement, their native flags, parts-only totals and Vault version history) and
`joint-coverage.json` (per reviewed joint: category a in native BOM not exported, a2
in native BOM and exported, b drawing parts list only, c supplied in a kit per
model/vendor data, d absent from all native sources, e unknown), refusing an audit
whose receipt is not `complete` or whose inputs changed. Tests: `tests/test_bom_audit.py`.

Run them with `&` from PowerShell (not `powershell -File`, which flattens array
parameters). The dated results are in `windows/HISTORY.md`. Evidence lives in the
shared exchange area under
`vault-cad-exchange/evidence/2026-10-21-windows-qualification-01/` (first export),
`.../2026-10-21-windows-native-pilot-01/` (comparison, native pilot, verified export),
`.../2026-10-21-windows-native-pilot-02/` (guards, volumes, part assets, parameters),
`.../2026-10-21-windows-exporter-hardening-01/` (strict exporter qualification),
`.../2026-10-21-windows-exporter-hardening-02/` (Linux review R1-R6 corrections,
offline suites, mechanical guard harness) and
`.../2026-10-22-windows-review-fixes-vault-dryrun-01/` (lifecycle, harness-ownership
and null-guard corrections; Vault SDK discovery and the offline publication dry run).

## The project layout

A project keeps one directory per Vault file, as specified in
`mechanical-cad/docs/layout-specification.md`: imported files under
`references/parts/<key>/` and `references/assemblies/<key>/`, written by
`import-snapshot`; authored parts under `designs/parts/<key>/`, whose
`part.step` is the deliverable. `vault-lock.json` (schema 2) is an index of
those directories. `status` reports whether each directory still says what the
index says, and whether each published part is still the file that was
published.

The earlier layout (lock schema 1: single STEP files under `references/`,
imported with `import-step`, and deliverables under `step/`) is no longer
read. It went on 2026-11-12, when the enclosure, the one project in it, had
been converted. The commands refuse such a lock and say why; the last commit
that reads it is a66ca5a.

## Convert an exported snapshot into one directory per Vault file

```sh
python3 run.py import-snapshot /path/to/the/earlier/package \
    --into /path/to/a/new/directory --run legacy-snapshot-991056 \
    [--inventory dependency-inventory.json] [--acquisition acquisition.json]
```

`import-snapshot` reads the package `windows/Export-PartAssets.ps1` wrote
(`native-snapshot.json`, `scene.json`, `export-receipt.json`, `assets/`),
verifies it against its receipt, and writes into a new directory:
`references/parts/<key>/` and `references/assemblies/<key>/` with a
`source.json` each, a `part.step` copied byte for byte, an `assembly.json`
listing each assembly's direct children at their definition placements with
the placements of flexible instances as overrides, the exporter's records
unchanged under `references/receipts/<run>/`, and `vault-lock.json` as the
index of those directories. The dependency inventory and acquisition record of
the same acquisition, when given, supply the Vault identity of the
sub-assembly documents and the version number, revision, lifecycle state and
check-in date of every file.

It refuses a package that does not match its receipt, a destination that is
not empty, suppressed or mirrored occurrences, and instances whose definitions
disagree. The layout it writes is specified and validated in `mechanical-cad`
(`docs/layout-specification.md`, `python3 -m mechanical_cad validate`); Peter
decided its choices on 2026-11-11. For this package the command writes into a
new directory and does not touch a project's existing `references/` or lock.
Tests: `tests/test_layout_import.py`.

### The package with `package.json`: into a project, keeping its keys

```sh
python3 run.py import-snapshot /path/to/package --into ../free-standing-tank-enclosure --run RUN
```

Provisional. When the package directory holds a `package.json`, the command
reads the package specified in `mechanical-cad/docs/exporter-package.md`
(draft 3): one directory per Vault file and model state under `files/`, with
`source.json` and `part.step` or `assembly.json`, every file identified by
master id and model state and none by a key, and `occurrences.json` beside
`package.json` with every occurrence in the root's context.
`windows/Export-Package.ps1` writes it since 2026-11-12 (item 26 of the
Windows route). `tests/exporter_package.py` writes such a package for the
tests, by hand or from what a project holds.

The exporter writes no overrides: `assembly.json` has each document's own
children, and `occurrences.json` says where every occurrence is in context
and whether that differs from its document. This command derives the
layout's overrides from the two. Each occurrence that differs becomes an
override on the nearest flexible occurrence above it, in the manifest of the
document that places that occurrence. Before that it checks that the
occurrences are the children the documents define, that
`differs_from_definition` and `transform_root` agree with the placements
within the tolerance the file states, and that every assembly occurrence has
all its document's children. It refuses what the layout cannot record: a
flag or BOM structure that differs in context, a difference with no flexible
occurrence above it, instances of one document that would need different
overrides, and a child entry that carries `overrides`.

`--into` is a project with an index, or a new or empty directory. The whole
package and the project are checked before anything is written:

- every file must match `package.json`, nothing may be unlisted, and the vault
  and root assembly must be those of the project's `vault-project.toml`;
- the project's directories must be what `vault-lock.json` says they are;
- a file the project holds keeps its key, whatever its name and path in Vault
  are now; a new file gets a key from its name that no imported or authored
  component has;
- a package holding an earlier version of a file than the project is refused,
  as is one whose order cannot be told because a version number is unknown.

Then each file is new, updated (a new Vault version), rewritten (the same
version, exported differently) or unchanged. An unchanged directory is not
touched and keeps naming the run it came from; unchanged means the same
version id, native hash and STEP bytes and the same exported record
(`source.json` without its `export` block; for an assembly also its children).
What the project holds and the package does not is reported and kept.
`package.json` and `occurrences.json` are copied to
`references/receipts/<run>/`, the index is derived
again with its publications kept, and the result names the parts whose
`part.step` changed, which `mechanical-cad/tools/step_facts.py` has to measure
before the project validates. `--inventory` and `--acquisition` belong to the
earlier package. Tests: `tests/test_package_import.py`.

## Prepare a new-file publication

Build and commit the authored part first. Then supply an agreed Vault
destination and filesystem exchange path:

```sh
python3 run.py --project ../free-standing-tank-enclosure prepare-publish designs/parts/KEY/part.step --vault-folder '$/AGREED/DESTINATION' --exchange /path/to/vault-cad-exchange [--name NAME.step]
python3 run.py verify-request /path/to/vault-cad-exchange/requests/REQUEST_ID
```

The request is refused unless `part.step` is committed and is the file the
part's `receipt.json` describes (build the part again if it is not). Every
deliverable is called `part.step`, so the file is named `KEY.step` in Vault
unless `--name` gives another name; the name a part has in Vault is Peter's to
settle, and this default is provisional.

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

After Windows has verified an add, Linux records it in the project:

```sh
python3 run.py --project ../free-standing-tank-enclosure import-publish-result /path/to/vault-cad-exchange/results/REQUEST_ID.json
```

`import-publish-result` re-checks the result against its request directory (fingerprint,
payload and re-download hashes, destination, vault ids, provenance, every verification
check, typed execution record) and against the project's Git history (the committed blob
at the provenance commit must hash to the payload) before it records anything; it never
reads the executor journal. The record goes into the part's `designs/parts/KEY/vault.json`
(request id, master id, version id, Git commit, STEP hash), and the `publications` of the
index in `vault-lock.json` are derived again from those files; the evidence of the
publication stays in the result file. Identical re-imports are no-ops; conflicting
ones, and a Vault version already recorded under another request, are refused. First qualified live add: 2026-10-22, request `e1caf6c0-...`, Vault
version 994252 (`vault-cad-exchange/evidence/2026-10-22-windows-vault-pilot-01/`).

None of the Linux commands uploads. The one live write is
`windows/Publish-StepToVault.ps1 -Live` (item 14 above), gated to a single
request. Existing destination names must cause failure; updating or checking in
an existing file is outside the implemented protocol. STEP bytes must match the
Git commit. LFS is not implemented.

Both halves of the first milestone exist as evidence: a real part and assembly
export verified in FreeCAD and re-opened in Inventor, and one new-file
publication verified by exact-byte re-download. Using the published STEP from
Inventor as a referenced model was shown only in a disposable copy (item 18);
what Vault itself records for that reference has not been verified.

## Licence

3-clause BSD, copyright Howard Hughes Medical Institute; see [LICENSE](LICENSE).
