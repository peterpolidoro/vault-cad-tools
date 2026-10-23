# Vault <-> repository synchronisation: design document (revision 2, 2026-10-23, for review)

Status: DESIGN ONLY. No code beyond the probes and the W1 status change named below; no live Vault
write, check-out, check-in or production save is authorized by this document. Revision 1
(2026-10-22) described a native update/check-in adapter for the production root; Peter's
directives of 2026-10-23 (Linux messages `20261023T141829Z` and `20261023T142722Z`) redirect it
into a synchronisation design. Revision 1's mutating sequence is kept, condensed, as the deferred
route in section 9. Evidence for every "verified" statement below:
`vault-cad-exchange/evidence/2026-10-23-windows-sync-design-01/` (`REPORT.md`).

## 0. Directives this design follows

1. Inventor natives in Vault stay intact and authoritative while they match their STEP exports;
   a per-file sync state decides what may happen; a native in `in_sync` or `vault_newer` is
   never written.
2. A repository STEP never becomes a non-parametric native body in Vault. Repository STEP goes
   to Vault as a STEP file; for placing it in a native assembly the STEP stays the referenced
   source (section 5).
3. Linux controls the workflow; Windows performs only the Vault and Inventor interactions under
   the Windows user's authorization, through the shared directory: validated requests in,
   verified results out. A Windows-only loop only if every tool resolves in Pixi for win-64
   (section 1.3). Windows commands assume neither caller.
4. Folder-level discovery, dependency closure, incremental export with the strict acquisition
   binding kept (section 3).
5. Metadata travels with each STEP; the documentation build's needs are defined so the adapter
   from the raw snapshot to the documentation loader can leave the project scripts (section 4).

## 1. Topology

### 1.1 Roles

- Linux (Guix): owns the project repository state, the lock (`vault-lock.json`), the
  documentation build, request preparation and result validation. It decides; it never talks to
  Vault or Inventor.
- Windows (this host): executes requests against Vault (REST read-only, SDK for writes) and
  Inventor (owned, invisible instance with the dialog watchdog), writes receipts and results,
  keeps its journal host-local, writes nothing to Vault without an explicit, journaled request.
- Shared directory `U:\Repositories\vault-cad-exchange`: `requests/UUID/` (request + payloads),
  `plans/`, `results/`, `evidence/<run>/`, `coordination/` (mailbox and status). Today's
  `add_step_file` protocol is the template; section 6 extends it.

### 1.2 Caller-neutral Windows commands

Every Windows operation is one PowerShell entry point with the same shape: a request or plan
file in, an empty output directory, a receipt (`*-receipt.json`, `status`, `errors`, hashes of
every file written, the session and dialog records) out, exit code 0 only for `complete*`.
Nothing in them reads the Linux side; a Pixi task on win-64 (`pixi run ...`) or a Linux agent
dropping a request into the exchange can call them alike. Existing: `Get-VaultDependencySnapshot`
(closure of one root), `Export-PartAssets` (snapshot + STEP assets + `scene.json`),
`Publish-StepToVault` (plan execution, journaled), `Audit-NativeBom`, `Discover-VaultAssociations`.
Planned (section 6): `Discover-VaultFolder`, `Acquire-VaultVersions`, `Export-PartAssets
-Incremental`, `Update-StepInVault`, `Add-ReferenceAssembly`.

### 1.3 Windows-only loop: Pixi win-64 survey (nothing installed)

`pixi search --platform win-64` on the workspace channel (conda-forge, Python 3.12 pinned) and
PyPI metadata, recorded in `pixi-survey/`:

| Tool | win-64 | Package |
|---|---|---|
| FreeCAD | yes | conda-forge `freecad 2026.09.16` (py313 build and 7 others; about 119 MiB) |
| Typst | yes | conda-forge `typst 0.15.1` |
| Poppler | yes | conda-forge `poppler 26.09.0` |
| mkdocs-material | yes | conda-forge `mkdocs-material 9.7.7` (noarch) |
| Blender / bpy | partly | no `blender` on conda-forge for win-64; PyPI `bpy` has win_amd64 wheels only for Python 3.13 (5.1.0-5.2.3) or 3.11 (4.5.x, 5.0.x), never 3.12 |

Conclusion: a Windows-only loop is possible for four of the five; Blender scripting would need a
second Pixi environment pinned to Python 3.13 with a PyPI `bpy` wheel of several hundred MiB.
Not pursued: the Guix side already has all five, and the directive makes Linux control the
default. The commands stay caller-neutral so the option remains.

## 2. Sync state model

### 2.1 Facts

Per Vault file (keyed by Vault master id; a repository STEP without a Vault file is keyed by its
repository path until it has one):

| Fact | Source | Where it already lives |
|---|---|---|
| F1 latest Vault version id (and version number, check-in date, state) | REST `files/{master}/versions`, `folders/{id}/contents`, `file-versions/{id}` | lock `references[].source`, acquisition records |
| F2 native SHA-256 as acquired for the version we exported from | REST `file-versions/{id}/content` re-hashed on download | `acquisition.json` per run; lock `references[]` |
| F3 exported STEP SHA-256 (what the exporter produced from F2) | export receipt / `scene.json` asset hash | lock `references[]` |
| F4 repository STEP SHA-256 | Git tree at HEAD (and working tree, flagged separately) | repository |

Version ids are immutable in Vault, so F1 alone detects Vault-side change; F2 is the binding
check (the bytes we exported from are the bytes of that version) and the refusal trigger when
it disagrees with the lock.

### 2.2 States and what each permits

| State | Condition | Allowed action | Native touched |
|---|---|---|---|
| `in_sync` | F1 == lock version id and F4 == F3 | nothing | never |
| `vault_newer` | F1 newer than lock version id and F4 == F3 | acquire the new version, export, update lock and repo STEP | never |
| `repo_newer` | F1 == lock version id and F4 != F3 | repository STEP to Vault as a STEP file (`add_step_file` for a new deliverable, `update_step_file` for an existing STEP in Vault); for a STEP that was exported from a native: review signal only (2.4) | never |
| `both_changed` | F1 newer and F4 != F3 | stop; Linux reports; a person decides | never |
| `new_in_repo` | repository STEP with no lock record and no Vault file at the planned destination | `add_step_file` | n/a |
| `new_in_vault` | Vault file in the discovered closure or folder with no lock record | acquire and export | never |
| `unknown` | any fact unreadable, or F2 disagrees with the lock's native hash, or a lock record lacks a fact | refuse every write; report | never |

The state is computed by Linux from the lock plus a Windows discovery result (section 3), and
recomputed by Windows immediately before any write from the request's expected version ids:
a difference refuses the request (`refused`, nothing touched), as the publication journal
already does for destination collisions.

### 2.3 Lock record shape (proposal, extends `references[]`)

```json
{
  "master_id": "988153", "vault_path": "$/.../ENCLOSURE/Free Standing Enclosure.iam",
  "kind": "native_assembly",
  "vault": {"version_id": "991056", "version": 5, "checkin_date": "...", "state": "Work in Progress", "native_sha256": "..."},
  "export": {"path": "step/...step", "sha256": "...", "from_version_id": "991056", "exporter": "...", "exported_at": "..."},
  "repo": {"path": "step/...step", "sha256": "...", "git_commit": "..."},
  "sync_state": "in_sync", "computed_at": "...", "discovery_run": "evidence/..."
}
```

For a STEP that lives in Vault as a STEP (the published envelope, version 994252) the native is
the STEP itself: F2 equals F3, `kind` is `step`, and `update_step_file` is its write path.

### 2.4 Repository edits of exported natives

A STEP exported from a native and then edited in the repository (`repo_newer`) is never pushed
back as a native (directive 2). The design treats it as a review signal: Linux reports it, the
state stays `repo_newer`; if the designers then change the native it becomes `both_changed`.
Whether such a STEP should additionally be pushed to Vault as a STEP file next to the native is
an open question (section 10).

## 3. Folder-level discovery, dependency closure, incremental export

### 3.1 What the REST reader answers (verified 2026-10-23, `rest-capability-probe/`)

The server's own OpenAPI document (`openapi-spec.yml`, API 2.0.16, 65 paths) and live reads:

- `folders/{id}`, `folders/{id}/sub-folders`, `folders/{id}/contents`: the ENCLOSURE folder
  lists 32 files (24 IPT, 7 IAM, 1 STEP; no sub-folders); each record carries name, version id,
  master id, version number, state, `isCheckedOut`, `isHidden`, `checkinDate`, size,
  `hasVisualizationAttachment`, `parentFolderId`.
- `file-versions/{id}`: the same record plus 77 inline `properties` (system properties,
  lifecycle definition and state, revision, category, iLogic rule status, `HasDrawing`,
  `HasModelState`, and the lab's user-defined properties: `*(C) DESIGN DEPARTMENT`,
  `*(C) LAB/DEPT`, `*(C) REQUESTING SCIENTIST`, `*(C) JOB ID`, `*(I) VENDOR`,
  `(I) PART NUMBER - LEGACY`, plus the Inventor-mapped `Title`, `Description`, `Material`,
  `PartNumber`, `StockNumber`, `Author`). A `/properties` sub-path does not exist (404).
- `files/{master}/versions`: every version of a master (the root has 5).
- `file-versions/{id}/uses` (with `recurse`) and `/parents`: associations with
  `fileAssocType` Dependency or Attachment; the root has 7 direct, 44 recursive associations
  and 0 parents; the published STEP has 0 parents.
- `file-versions/{id}/content`: exact bytes (CRC32 and SHA-256 verified in the pilot).
- `property-definitions`: 119 definitions (id, display name, system name, data type).
- `file-versions?q=` and `search-results` (GET and POST): text search.
- Writes: only `sessions`, `jobs` (POST), `search-results` (POST) and option endpoints accept
  anything but GET. No file add, check-out, check-in or property write exists in this API.

What REST cannot answer, so the SDK (or Inventor) is needed:

- hidden files: earlier runs showed folder listings omit hidden files even with
  `includeHidden=true`; `DocumentService.GetLatestFilesByFolderId(id, true)` lists them;
- the reference strings as stored inside an IAM (`RefId`, `Source`) that `CheckinFile`
  associations require: SDK `GetFileAssociationsByIds` or Inventor's `ReferencedFileDescriptors`;
- any write (section 6 uses `FileManager.AddFile`, `CheckoutFile`, `CheckinFile`,
  `UndoCheckoutFile`, property updates);
- which non-Inventor files an Inventor file references when they are not in Vault (only the
  Inventor document knows; see 5.4).

### 3.2 Discovery algorithm (`Discover-VaultFolder`, read-only)

1. List the folder (and, when asked, its sub-folders) through REST; record every file with the
   fields above; note `isHidden` and `isCheckedOut`.
2. Roots: IAM files whose `/parents` is empty within the vault (verified: `Free Standing
   Enclosure.iam` v5 has none; the six other IAMs in the folder are children). Standalone files:
   zero parents and zero uses (the published STEP). Everything else is a child of some root.
3. Closure per root: `/uses?recurse=true` (paged until the server total is reached, as
   `Get-VaultDependencySnapshot` does); Attachments (visualization DWF) are recorded, not
   acquired.
4. Output `discovery.json`: folder, roots with their closures (master, version id, version,
   path, state, checked-out flag, association type), standalone files, hidden files seen (none
   visible to REST), the folder's sub-folders, and for every file the facts F1 of section 2.
   Linux joins it with the lock and computes the states.

### 3.3 Incremental acquisition and export

- Acquire only versions whose (master, version id) is absent from the lock or differs from it;
  each download is re-hashed (F2) and bound as today (`acquisition.json`).
- The mirror workspace keeps every file at the pinned version; before opening, every file in the
  closure is re-hashed against its acquisition record (strict binding of
  `Confirm-AcquiredInputs`, unchanged).
- `Export-PartAssets -Incremental -Lock lock.json`: the snapshot (`native-snapshot.json`,
  `scene.json`, `inventory-raw.json`) is always regenerated from the opened root, because
  transforms and occurrence sets can change without any part changing; STEP assets are
  re-exported only for parts whose native hash changed or whose asset is missing, and reused
  otherwise after re-hashing the existing asset against the lock (`asset.sha256`). The receipt
  lists which assets were reused and from which record.
- The exported `scene.json` and the lock receive F3 for every part; Linux commits the STEP files
  and the lock together (F4 then equals F3, `in_sync`).

## 4. Metadata that travels with each STEP

### 4.1 Recorded today (`native-snapshot.json`, `scene.json`, `inventory-raw.json`)

Per part: stable id (`<workspace-relative path>|<model state>`), document, display name, model
state and model-state count, iPart membership, `properties` (part number, description, material,
stock number, vendor, manufacturer, title, category from Design Tracking Properties), default BOM
structure, body counts, volume, range box, native length unit, asset (path, format, AP, SHA-256,
bytes, STEP length unit with the strict unit-context check, translator options), `source` (vault
id, version id, master id, vault path, version, state, native SHA-256 when bound), instance
count. Per occurrence: id, parent, depth, local and world transforms, determinant, visibility,
grounded, flexible, BOM structure, model state, kind, part id. Per group (sub-assembly): the
same plus flexible/suppressed/mirrored flags. `inventory-raw.json` aggregates per part: CAD
instance counts, BOM structures, part number, description, material, vendor.

### 4.2 Added by this design

From Vault (REST inline properties, keyed by `systemName`, under `source.vault_properties`):
lifecycle definition and state, revision, category, check-in date and user, `HasDrawing`,
`iLogicRuleStatus`, and the lab's user-defined properties listed in 3.1. From the export: the
exporter version, the request id and the discovery run that produced the acquisition.

### 4.3 What a documentation build needs (the contract)

`scene.json` is the single input of the documentation loader; `metadata.json` (new, same
export) carries everything else keyed by part id. The loader needs: stable part id and display
name; part number, description, material, vendor, stock number; quantity per sub-assembly and
total (from occurrences); BOM structure to exclude Phantom/Reference and mark Purchased; asset
path, hash and units for renders; world transforms and grouping for views; Vault provenance
(path, version, state) and the lab properties for the record page; warnings (unit mismatch,
unbound inputs, dialogs dismissed). The adapter from the raw snapshot to the loader therefore
moves into the tools as `vault-cad scene-check` (schema and cross-count validation, already done
by `Test-SnapshotOutputs` on Windows) and `vault-cad scene-metadata` (joins `scene.json`,
`metadata.json` and the lock); the project scripts then consume only those two files.

## 5. Keeping a repository STEP as the referenced source (directive 2)

### 5.1 Documentation

- Autodesk Inventor help ("About AnyCAD and Importing Files from other CAD Systems", 2021 to
  2026 editions) lists STEP among the formats that can be imported as a reference model; the
  2025 page "To Import Files as an AnyCAD Reference or Convert Model" describes Reference Model
  as maintaining a link to the selected file to monitor and update as the model changes, and
  Convert Model as a new Inventor file not linked to the original. Autodesk cautions that a
  STEP update is a new translation that can leave geometry unresolved, so the reference route
  suits files that change rarely.
- Autodesk Vault (Inventor add-in): AnyCAD references are uploaded with the assembly and their
  structure; Vault manages such third-party files only through the Inventor model that
  references them (Autodesk Vault blog, 2016). Current Vault 2025 behaviour is to be verified in
  the disposable live pilot (5.5); the SDK route declares the association explicitly anyway.

### 5.2 API (Inventor 2025 interop, reflected)

`PartComponentDefinition.ReferenceComponents.ImportedComponents.CreateDefinition(path)` returns
an `ImportedGenericComponentDefinition` with `ReferenceModel` (read/write), `ImportUnitsType`,
`ImportedModelEntities`, `SaveFilesLocation`; `ImportedComponents.Add(definition)` returns an
`ImportedComponent` with `LinkedToFile`, `ReferencedFile`, `IsEmbedded`, `HealthStatus`,
`BreakLinkToFile`, `SuppressLinkToFile`, `ReferencedDocumentDescriptor`.

### 5.3 Probe in the disposable copy (verified, `reference-model-probe-02/`)

`Invoke-ReferenceModelProbe.ps1` created, in the copy only, a new part whose only content is
the published envelope STEP imported as a reference model, and a new assembly placing it:

- `CreateDefinition` accepted the STEP; `ReferenceModel` defaults to false and was set to true.
- `Add` produced an imported component named after the STEP with `LinkedToFile = true`,
  `IsEmbedded = true` (Inventor caches the translated body in the part while keeping the link),
  health status up to date, one solid body, one feature.
- Saved as `MONITOR\AW2725Q-nominal-envelope-reference.ipt` (84,992 bytes). Its
  `File.ReferencedFileDescriptors` lists exactly one entry: the STEP file (`DocumentFound =
  false`, and `DocumentType`/`ReferenceStatus` unreadable, because it is not an Inventor
  document); `AllReferencedDocuments` is empty.
- The new assembly `MONITOR\reference-probe.iam` lists the wrapper part as its only reference;
  the STEP is reachable only through the part's descriptors.
- Reopening the part shows one imported component, still linked and healthy. Nothing else in
  the copy changed; the mirror was not opened. Watchdog: one hidden non-blocking dialog, left
  alone; status `complete`.

### 5.4 Consequences for the design

- Route R, recommended for a repository STEP that a native assembly must contain: a wrapper
  part `<name>-reference.ipt` holding only the reference-model import, placed in the assembly.
  The authoritative geometry is the STEP; a change in the repository STEP is pushed as a new
  STEP version (`update_step_file`) and the wrapper refreshes on next open (a new translation;
  the receipt must report the health status after refresh). The wrapper is a native file without
  authored geometry; it is created and updated only by this tooling.
- Vault associations: the wrapper references the STEP by file path, so the STEP must be in the
  same Vault project tree at the referenced relative location; for the ENCLOSURE folder that is
  the already published `AW2725Q-nominal-envelope.step` (version 994252) next to the wrapper.
  Associations to declare on add: IAM -> wrapper IPT (Dependency), wrapper IPT -> STEP
  (Dependency), both with the reference strings read from `ReferencedFileDescriptors`.
- Binding: because `AllReferencedDocuments` does not see non-Inventor references,
  `Confirm-AcquiredInputs` and the exporter must also walk `File.ReferencedFileDescriptors` and
  bind foreign references (STEP) by hash to the lock; today's walks would silently miss them.
- Not a route: converting the STEP to a native body and checking that in (revision 1, section
  5a) is withdrawn.

### 5.5 Qualification still needed (no production document)

A disposable live pilot, only with Peter's authorization and a destination folder: add the
wrapper IPT and a NEW assembly referencing it (and nothing from production) to Vault with the
STEP association declared; then read back through REST `uses`/`parents` what Vault recorded for
IPT -> STEP; then push a changed STEP as a new version and observe the wrapper's health status
after reopening. This is the first live native route (agreed with Linux in `142722Z`, item 4).

## 6. Operations (exchange protocol v2, request kinds)

| Kind | Side | Reads/writes | Result |
|---|---|---|---|
| `discover_folder` | Windows | REST only | `discovery.json`: roots, closures, standalone, F1 facts |
| `acquire_versions` | Windows | REST content | acquisition records (F2), mirror updated at pinned versions |
| `export_snapshot` | Windows (Inventor) | mirror only | snapshot, `scene.json`, `metadata.json`, assets (incremental) |
| `add_step_file` | Windows (SDK) | Vault add | as today (verified 994252) |
| `update_step_file` | Windows (SDK) | check-out, check-in of an existing STEP master with `expected_version_id`; `UndoCheckoutFile` on failure | new version id, bytes re-verified |
| `add_reference_assembly` | Windows (Inventor + SDK) | new wrapper IPT and new IAM, adds only, associations declared | ids, associations observed |
| `update_native_assembly` | deferred (section 9) | check-out/check-in of a production IAM | not before the sync model exists and Peter asks |

Every request carries the expected version id of every Vault file it touches or references,
the hashes of its payloads and the provenance commit; every result carries the verification
checks, the executor record, and the dialog record; the journal keeps the transition table of
`publication.py` with states added per kind (`checked_out`, `checked_in`, `undo_attempted`).

## 7. Run status and dialogs (W1, implemented)

`Resolve-RunStatus` in `Inventor-Session.ps1`: a run whose watchdog dismissed anything ends as
`complete_with_dialogs`, never plain `complete`; dialogs only recorded keep `complete`; `FAILED`
is never softened. `Export-PartAssets`, `Invoke-MonitorPlacementPilot` and the probe use it;
`Test-SnapshotOutputs` treats `complete*` with failures as a contradiction. Readers must open the
receipt's `dialogs` field before accepting `complete_with_dialogs`.

## 8. Qualification plan (gradual, design before code)

1. Read-only: `discover_folder` against ENCLOSURE; Linux computes the states from the lock and
   checks them against today's known facts (root v5, STEP v1, 43 children).
2. Incremental export dry run on the mirror (no Vault write): reuse decisions listed, snapshot
   regenerated, scene validated.
3. `update_step_file` plan only (plan file, no execution) for the published STEP.
4. Disposable live pilot of 5.5 (authorization needed).
5. Only then, and only if wanted: `update_native_assembly` on a disposable copy of a production
   assembly checked into a folder Peter chooses.

## 9. Deferred: native update / check-in of an existing assembly (revision 1, condensed)

Request `update_native_assembly` (target master and expected version id; new parts; the
dependency set pinned to version ids; `if_changed: fail`). Preconditions: request verified;
journal `planned`; named-user session (`AutodeskAccount` token; error 319 without it); for the
target and every dependency the latest version equals the expected id, nothing checked out,
locked or under a change order, permissions allow check-in; destination collisions checked with
hidden files; the local IAM's references equal the declared set; dialog watchdog running; iLogic
policy decided (section 10). Sequence: add new parts (`AddFile`), `CheckoutFile` the target
(verify version and checked-out-to-us), build `FileAssocParam[]` from the reference descriptors,
`CheckinFile` with the saved IAM, verify (latest version, associations through `uses`, bytes).
Failure: before check-in `UndoCheckoutFile` and back to `planned` only after the server shows
the file checked in at the expected version; during or after check-in `ambiguous`, reconciled
by reading the server. Facts kept from revision 1: `AddFile` works, raw `UploadFilePart` answers
error 155, Vault `Cksum` is CRC32, REST is read-only for files.

## 10. Open questions for Peter (recorded, not acted on)

- iLogic on save: the production assembly's Before-Save trigger runs the external rule `Part
  Number Cleaner`, absent here. Linux recommends deactivating the iLogic add-in in the owned
  instance for disposable pilots (recorded in the receipt) and obtaining the designers' rule
  files before any production check-in.
- Monitor height reference: platform top 501.6 mm versus the instructed 584.16 mm (paused).
- Wrapper parts: is a `<name>-reference.ipt` per repository STEP acceptable in the designers'
  folders (a native without authored geometry), and under which naming and folder?
- Lab properties: which Vault user-defined properties must be set on files the tooling adds
  (today `AddFile` sets none; existing files show property compliance 1.0).
- Repository edits of exported natives (2.4): review signal only, or also pushed to Vault as a
  STEP next to the native?
- Hidden files: none are visible in ENCLOSURE through REST; should discovery always run the
  SDK listing to be sure?
- Windows-only loop: not pursued unless asked (1.3).
