# Vault CAD tools living plan

## Objective

Support versioned Vault-to-STEP imports into project Git repositories and
publication of Linux-authored STEP files back to Vault, using a Windows adapter.

The direction of the wider work is in the sibling `mechanical-cad` repository
(`docs/direction.md`). Finished checkpoints, with their evidence runs, are in
.agents/HISTORY.md and windows/HISTORY.md.

## Current state (2026-11-12)

Demonstrated, each once, on the enclosure pilot:

- Vault to repository: `Get-VaultDependencySnapshot.ps1` freezes and downloads
  the exact versions of one root assembly; `Export-PartAssets.ps1` exports one
  STEP per part document plus the instance, placement and BOM records, with
  every opened document bound to its acquired hash; `import-step`, since
  removed, recorded provenance in the project's `vault-lock.json`. Result: 37 parts, 155
  occurrences, 479 solids reconstructed in FreeCAD.
- Repository to Vault: one new-file add (`plan-publish`,
  `Publish-StepToVault.ps1 -Live`, `record-publish`, `import-publish-result`),
  request e1caf6c0, Vault version 994252, verified by exact-byte re-download.
- Read-only audits: `Audit-NativeBom.ps1`, `Discover-VaultAssociations.ps1`,
  `vault-cad bom-audit-summary`.
- In a disposable copy only: native parameter-driven authoring, the placement
  pilot, and the reference-model probe (a STEP kept as the linked source inside
  a wrapper part).

Added on 2026-11-10, provisional: `vault-cad import-snapshot`
(`src/vault_cad_tools/layout_import.py`), the first form of the import command
of the layout proposal. It reads the package `Export-PartAssets.ps1` writes
today and writes `references/` (one directory per Vault file) and the derived
lock into a new directory. Run as a dry run on the enclosure, its output
passes the proposal's acceptance test (37 parts, 7 assemblies, 44 overrides;
the scene flattened from it equals the exporter's). Nothing was written into
the enclosure's tracked tree.

Added on 2026-11-11, at Peter's request: the commands read both shapes of
`vault-lock.json`. A project with the index (schema 2, one directory per Vault
file) gets a `status` that compares each directory with the index and each
published part with what was published; `prepare-publish` takes an authored
part's `designs/parts/<key>/part.step`, requires it to be committed and to be
the file its `receipt.json` describes, and names it `<key>.step` in Vault
unless `--name` says otherwise; `import-publish-result` writes the record into
the part's `vault.json` and derives the index's `publications` again. The
earlier lock (schema 1) works as before; `import-step` refuses the new layout.
Run that day on the enclosure: `status` on the branch `layout-conversion`
reports 37 parts and 7 assemblies clean and the one publication as changed
since it was published; on `main`, with the earlier lock, 38 clean as before.
The index and `vault.json` written by these commands are byte for byte what
`mechanical-cad` writes for the same data, and `mechanical-cad`'s validator
and these commands derive the same publications from the branch. A request
was prepared from a scratch copy of the converted project and verified; no
publication cycle has been run on a real project in the new layout, and
nothing was sent to Vault.

Added on 2026-11-11, provisional: `import-snapshot` also reads the package
of the draft specification (`mechanical-cad/docs/exporter-package.md`, draft
2; `src/vault_cad_tools/package_import.py`), into a new directory or into a
project that holds the files. It keeps the keys the project has, leaves a
file untouched when its version, native hash, STEP bytes and exported record
are what the project has, refuses a package that is behind the project, and
reports what the project holds and the package does not. No exporter writes
that package yet: the tests and the trial use packages written on Linux
(`tests/exporter_package.py`). Tried that day on copies of the converted
enclosure: a package of what the project holds leaves all 44 directories
untouched; the same package with the 37 AP242 files of the Windows tests
rewrites the 37 parts and no assembly, and the result, measured again,
validates in `mechanical-cad` and flattens to the branch's scene apart from
the STEP files. Who derives the overrides of flexible instances, the
exporter or this command, was put to the Windows agent; the reader follows
the draft (the exporter does). The answer of 2026-11-12 is below: the
exporter writes the occurrences in context and this command derives them.

Tests: 112 portable tests pass in the Guix environment (run 2026-11-11; 12 of
them are new, for the package, in `tests/test_package_import.py`, 13 are for
the index, in `tests/test_layout_project.py`, and 10 are for the earlier
package). On Windows 87 passed under Pixi on 2026-11-11, from
the commit before the index was added; the 25 newer ones have not been run
there. On Windows all 115 passed under Pixi on 2026-11-12, and the offline
suites pass (run 2026-11-12: script hygiene over 38 scripts with a 9-case
self-test of the checks, 37 session mock cases, 3 watchdog, 12 snapshot, 10
STEP unit, 11 receipt, 27 STEP header and entity cases, 27 package format
cases, 7 Vault facts and 8 folder discovery cases). The package reader was
run on Windows that day on a copy of the exporter's first package
(`import_package` into an empty directory); `import-snapshot` on a project
has not been run there.

Added on 2026-11-11 by the Windows side, with its three read-only AP242 tests
(record in `windows/HISTORY.md`; reviewed and applied on Linux):
`Step-Header.ps1` reads a data section as text (entity counts, what a file
marks invisible and whether in the form `mechanical-cad` understands, the
instances that differ between two exports, whether a difference is confined
to the saved view); `Invoke-StepExportProbe.ps1` can reach a part as the
exporter does, open it with a view and move the camera;
`Compare-StepExports.ps1` lists differing instances. Measured: AP242 exports
made without a view are byte-identical in their data sections between
sessions, and the exporter runs without a view; with a view the file carries
that view's camera, and nothing outside what `CAMERA_MODEL_D3` reaches
changes; no translator option leaves out the hidden bodies or the saved view;
of the 37 parts one has an `INVISIBILITY`, in the understood form. Linux
compared the 37 AP242 files with the tracked AP214 parts by measured geometry
that day: 37 of 37 the same (`mechanical-cad/docs/layout-proposal.md`,
"Windows tests of 2026-11-11"). `Export-PartAssets.ps1` is untouched: its
default is still AP214, it does not normalise headers, and it writes the
earlier package.

Added on 2026-11-12 by the Windows side (record in `windows/HISTORY.md`; not
yet reviewed on Linux):

- `Invoke-AssemblyStepProbe.ps1`: Inventor's own STEP export of the root
  assembly as one file, as evidence. Read as text, every placement of the file
  equals Inventor's placement in context for all 171 occurrences, and the 44
  that differ from a sub-assembly's own definition are exactly the 44
  overridden occurrences of the snapshot. The recorded placements, the
  derived overrides included, are confirmed by a file Inventor wrote itself.
- `Export-Package.ps1` with `Package-Format.ps1`: the package of draft 2 as a
  mode of its own. Run twice on the enclosure with strict binding: 37 parts,
  7 assemblies, 171 occurrences, every file but `package.json` byte-identical
  between the runs; the 37 `part.step` are the files Linux compared on
  2026-11-11. It differs from draft 2 where Inventor does: an assembly's
  children are written as the document defines them and what a flexible
  instance does to its descendants is in `occurrences.json` (every
  occurrence in the root's context, marked when it differs from its
  definition), not in `overrides`; the hash of the translator's file is in
  `package.json`, because it changes with every export; a suppressed
  occurrence stops the run. The committed reader refuses the package for
  `occurrences.json` and accepts it without that file.
- The STEP translator sometimes names a second, unrelated schema in
  `FILE_SCHEMA` (rule in `windows/README.md`). The new exporter exports such
  a part again and never repairs a header.
- The three findings of the Linux review of 2026-11-11 on `Step-Header.ps1`
  are corrected.
- The six findings of the Linux review of 2026-11-12 on `Export-Package.ps1`
  are answered (record in `windows/HISTORY.md`): guard queries hold no cast
  and a collection must exist before it is counted; everything after
  Inventor runs inside a `try`, the receipt is always written and whatever
  fails after `package.json` was written removes it; the receipt counts how
  often each guard was evaluated; the whole mirror is hashed before and
  after; Inventor is started inside the `try` that stops it; and a run that
  ends `complete_with_dialogs` leaves no `package.json`. The same holds in
  `Invoke-AssemblyStepProbe.ps1`. The package written afterwards has every
  file but `package.json` byte for byte as before.

Imported and merged on 2026-11-12: the package of
`2026-11-12-windows-package-findings-01` went into the enclosure (44
directories rewritten, keys kept, 44 overrides derived) and Peter merged the
branch, so `main` of the enclosure (7a1af68) is in the layout with one
directory per Vault file, with AP242 part files. A second import of the same
Vault versions (the first package) into a clone of `main` leaves all 44
directories untouched and adds only its receipts directory. What `main` gives
on Linux is in the shared evidence `2026-11-12-linux-main-baseline-01`.

Removed that day (e85c85e): `import-step`, the earlier
lock (schema 1) and publishing from `step/`, with their tests. No project is
left in the earlier layout. `Project` reads the index only and refuses the
earlier lock with the reason; `prepare-publish` and `import-publish-result`
take an authored part's `designs/parts/<key>/part.step` only. What the import
tests showed of the shared helpers is kept (portable paths, symlinks in a
managed path, JSON with a byte-order mark, the operation lock), and a test
now shows that a failure to write the index leaves no `vault.json` behind.
102 tests pass; `status` on the enclosure's `main` is byte for byte what it
was. The last commit that reads the earlier lock is a66ca5a. Still there:
`layout_import.py`, which reads the package `Export-PartAssets.ps1` writes,
and on Windows the scripts of that package and of the single-file export;
the Windows agent has been asked for a list of them, with no deletion.

Not implemented: update or check-in of an existing Vault file, folder-level
discovery, change detection against the lock, incremental re-export, a single
`sync` command, unattended operation. The synchronisation design
(`docs/native-checkin-adapter-design.md`, revision 2) is a document; its four
review findings are noted at its top.

## The layout proposal and what it changes here

Peter wants the structure of STEP files and metadata settled and the enclosure
re-exported into it. The proposal (`mechanical-cad/docs/layout-proposal.md`, not
accepted) is one directory per Vault file, for parts and for assemblies. If it
is accepted, this repository changes as follows:

- `windows/Export-PartAssets.ps1`: every file identified by its Vault master id
  and model state instead of a name that hashes the Vault path; one child list
  per assembly document in place of one flattened `scene.json`; no absolute
  workstation paths; a normalised STEP header (fixed name and timestamp, empty
  author). The exporter never sees a repository key.
- The import command: assigns a readable key to each new master id and is the
  only writer of the project's `references/` tree apart from the facts command
  of `mechanical-cad`; keeps the exporter's run-level records unchanged under
  `references/receipts/`. `import-snapshot` does this for the present package
  format, into an empty directory only, and since 2026-11-11 for the package
  keyed by master id, into a project that already has keys. No exporter
  writes that package yet.
- The lock: a derived index of the directories (design document 2.3 is
  replaced); the validator recomputes it.
- The planned `metadata.json` (design 4.2, 4.3): replaced by a `source.json`
  per directory; Linux check results go to a separate `facts.json`.
- The publication record: moves from the lock into the authored part's
  directory.
- The planned `scene-check` and `scene-metadata` commands: the flatten step and
  the validator in `mechanical-cad` take their place.

Measured on 2026-11-10 from the enclosure repository: two exports of one Vault
version differ only in the header's file name and timestamp, and their data
sections are byte-identical (one part). The asset name suffix is a hash of the
Vault path and model state. All 37 STEP headers carry an account-like name in
the `author` field (four distinct names, none of them the exporting account),
although the exporter passed an empty `Author` translator option. `scene.json`
and `native-snapshot.json` carry absolute Windows paths.

Measured on Windows on 2026-11-10 (the five read-only tests; record in
`windows/HISTORY.md`): nine AP214 exports per part, from nine Inventor instances
over 20 days, have byte-identical data sections for three parts, and normalise
to identical files. The header's author is the native file's Summary
Information "Author"; a non-empty translator option overrides it, the header's
name is the output file name, and no option controls the time stamp, so the
exporter has to rewrite `FILE_NAME` after the translator has run
(`windows/Step-Header.ps1`, same bytes as `mechanical-cad`'s normaliser). AP242
adds a saved-view block and, for the part with hidden bodies, writes the hidden
solids with an `INVISIBILITY` entity where AP214 omits them. Nothing has changed
in Vault for the 44 files since 2026-10-21; revision, lifecycle definition and
state reach REST for every file. Parameters, hole features with tap and
clearance data and hole centres read from PowerShell; thread features and
sheet metal were not exercised. In the ENCLOSURE folder `SLLB Enclosure.iam` is
a second root under finding R1.

## Target workflow (Peter, 2026-10-23)

Give an agent a Vault location; it mirrors every file of that project at exact
versions, converts them to STEP with metadata into a Git repository, and
generates the project documentation that lives in that repository and is served
as GitHub Pages. When Vault changes, synchronise the new Vault state into the
repository. When a user or agent adds or modifies STEP files or the assembly in
the repository, update Vault so both stay in step.

Directives:

- Inventor natives in Vault stay intact and authoritative while they match their
  STEP exports. The sync keeps a per-file state (`in_sync`, `vault_newer`,
  `repo_newer`, `both_changed`, `new_in_repo`, `new_in_vault`, `unknown`) and
  never touches a native that is in sync or newer in Vault.
- Pushing STEP into Vault never converts it into a non-parametric body. STEP is
  stored as STEP; placing a repository STEP into a native assembly keeps the
  STEP as the referenced source (route to be qualified, disposable copy first).
- Linux controls the workflow. Windows performs only the Vault and Inventor
  interactions under the Windows user's authorization, through validated
  request files in and verified result files out. A Windows-only loop is an
  option only if every tool resolves through Pixi on Windows (it does not:
  Blender); the Windows commands are written so that either arrangement can
  call them.
- Authoring (2026-10-23): new parts are parametric Python programs producing
  B-rep STEP. Inventor is not an authoring tool unless a collaborator insists.
  glTF is derived from STEP on Linux. Materials: the exporter records the CAD
  claim, each project curates. Full text: `docs/authoring-and-materials.md`.
- Live Vault writes only on Peter's explicit request; design document before
  code.
- Licence (2026-11-10): 3-clause BSD, copyright Howard Hughes Medical Institute.

## Architecture decisions

- One tool repository for Linux and Windows; one separate repository per project.
- Python 3.11+ standard-library core, Guix on Linux, locked Pixi on Windows.
  Pixi manages Python 3.12 and Git; Autodesk applications and licensing are
  host-managed.
- Vault REST for reads; the installed Windows SDK for writes
  (`FileManager.AddFile`; the raw upload call answers Vault error 155).
- Export through a local, owned Inventor instance. The Job Processor route is
  not used: no processor runs on the workstation and the built-in job's
  parameters could not be captured.
- Filesystem exchange carries data manifests and payloads, never credentials or
  scripts.
- Imported references and authored deliverables have separate ownership.
- The publication journal lives on the executing host; Linux ingests only
  `results/`.

## Next work

1. Reviewed on Linux on 2026-11-12 (evidence
   `2026-11-12-linux-windows-package-review-01/REVIEW.md`), and the draft is
   now draft 3: the exporter writes `occurrences.json` and no overrides, and
   the import command derives them; the hash of the translator's file stays
   in `package.json`; a suppressed occurrence stops the export until a
   project has one to try; a file whose `FILE_SCHEMA` names a second schema
   is exported again and never delivered or repaired. The review's findings
   on `Export-Package.ps1` (a guard that a cast can defeat, what happens when
   a step after the export fails) were corrected on Windows that day, and
   the corrections were reviewed on Linux (evidence
   `2026-11-12-linux-windows-package-findings-review-01/REVIEW.md`): all six
   are there, the package the corrected exporter writes is the first one in
   every file but `package.json`, and a run in which a dialog was dismissed
   delivers no package. Six smaller remarks of that review wait for the next
   change of the script; none needs a run of its own. Peter has not reviewed
   the draft.
2. The import command reads the real package since 2026-11-12
   (`_read_occurrences` in `package_import.py`). Tried that day on a copy of
   the enclosure's branch: 44 files rewritten, all keys kept, 44 overrides
   derived (32 and 12), and after `step_facts.py` the copy validates, its
   flattened scene equals the branch's with no placement differing, and it
   matches Inventor's own STEP export of the root assembly solid for solid.
   The same import went into the branch itself on 2026-11-12 and is merged
   (see the current state). Not built: removing what a package no longer
   has.
3. Asked of the Windows agent on 2026-11-12
   (`to-windows/20261112T181749Z-...`): the checks on the new layout on
   Windows (the tests, `status`, `mechanical_cad validate`, a repeat import
   that changes nothing), the six remarks, `Export-Package.ps1` described as
   the exporter, a list of the scripts that serve only the earlier package
   or layout, one run of the changed exporter, and Inventor reading the STEP
   file of the whole enclosure that FreeCAD built on Linux. When its list is
   there and Peter has seen it: remove `layout_import.py`'s reading of the
   earlier package and the Windows scripts on the list.
4. Then the synchronisation design's qualification on the new layout:
   read-only `discover_folder` with the sync states computed on Linux
   (`vault-cad sync-status`, written to `sync-status.json`, never into the
   lock), the incremental export dry run, an `update_step_file` plan.

## Open items

- The name an authored part gets in Vault. `prepare-publish` uses `<key>.step`
  unless `--name` is given; the pilot of 2026-10-22 went in as
  `AW2725Q-nominal-envelope.step`. For Peter to settle before the next
  publication, with the wrapper-part naming question of the design document.
- The index has two derivations, one here (`import-snapshot` for the
  components, in `layout_import.py` for the earlier package and in
  `package_import.derive_components` for the new one, and
  `Project.derive_publications` for the publications) and one in
  `mechanical-cad` (`derive_lock`, which the validator holds the file to). They
  agree on the fixture of the tests and on the converted enclosure. Nothing
  tests them against each other automatically.
- The new commands have not been run on Windows, where `plan-publish` and
  `record-publish` run. Those two do not read the lock, and the request format
  is unchanged.
- `prepare-publish` checks that the part is committed and is the file its
  receipt describes. It does not evaluate the part's `checks.json`; whoever
  prepares a publication runs `mechanical_cad validate` and `check` first.
- Five scripts do not start Inventor through `Inventor-Session.ps1`:
  `Export-InventorStep.ps1`, `Inspect-StepInInventor.ps1`,
  `Compare-NativeAndStepAssembly.ps1`, `Invoke-NativeAuthoringPilot.ps1`,
  `Invoke-NativeParameterPilot.ps1`. Keep them to the single-user interactive
  session they were qualified in until they are moved.
- The material and appearance claim per part and body
  (`docs/authoring-and-materials.md` 4.1) is not recorded by the exporter.
- `Export-Package.ps1` stops on a suppressed occurrence: Inventor does not
  load its document, and no project has one to test on. Its stops for a
  document with a view and for an `INVISIBILITY` in another form have not
  fired on real data. Not met on real data either: a flexible instance inside
  a flexible instance, two instances of one document flexed differently,
  thread features, patterns of holes other than a mirror.
- Why the STEP translator sometimes names a second schema in `FILE_SCHEMA` is
  not known; it has only been seen in runs of `Export-Package.ps1`.
- Seven older scripts start their owned Inventor instance a few statements
  before the `try` whose `finally` stops it, and write their receipt outside
  a `try`: `Export-PartAssets.ps1`, `Invoke-StepExportProbe.ps1`,
  `Get-PartFeatureDump.ps1`, `Audit-NativeBom.ps1`, `Measure-PartBodies.ps1`,
  `Invoke-MonitorPlacementPilot.ps1`, `Invoke-ReferenceModelProbe.ps1`. A
  failure of their first log line or of the watchdog's start would leave the
  instance running. `Export-Package.ps1` and `Invoke-AssemblyStepProbe.ps1`
  are corrected and held to the structure by `Test-PackageFormat.ps1`; the
  others were left as they are, as asked for the exporter.
- `Export-Package.ps1` has no switch to accept the package of a run in which
  the watchdog dismissed a dialog. If a dialog comes back on every run of a
  project, that needs a decision.
- The Vault paths of the enclosure run through folders named after labs, so
  `vault.path` in every `source.json` carries those names.
- Design document revision 3: fold in findings R1 to R4 and the layout; correct
  3.2 (the ENCLOSURE folder has two roots under R1, not one) and 3.1 (a REST
  listing is reliable only as a single page of up to 1000 rows).
- The disposable live pilot of the reference-model route (design 5.5): what
  Vault records for wrapper part to STEP is unverified. Needs Peter's
  authorization and a destination.
- Update or check-in of an existing file (`update_step_file`), and the native
  update of a production assembly (design section 9): deferred until the sync
  model exists and Peter asks.
- The questions for Peter in section 10 of the design document (iLogic on
  save, wrapper-part naming and folder, lab properties on added files, whether
  repository edits of exported natives are also pushed as STEP, the SDK listing
  for hidden files).
- Built-in STEP job details were never captured. Not needed while the local
  Inventor route is used.
- `pyproject.toml` carries no licence field: the SPDX form needs setuptools 77
  or later, the build requirement is `setuptools>=65`, and the Windows Pixi
  lock is not to be re-resolved as a side effect. Add it with the next
  deliberate manifest and lock update.
- Guix packages for OCP, build123d and CadQuery are Peter's own deferred work
  (2026-10-23). When it starts, they go into `mechanical-cad`, used as a Guix
  channel. No agent starts this on its own.
- Server, vault and folder names are in tracked files here (README, the survey,
  three PowerShell scripts' defaults and comments). Whether they stay is one of
  the unsettled questions in `mechanical-cad/docs/direction.md`.

## Current limitations

The Vault server's name does not resolve from the Linux workstation; Windows
reaches it over plain HTTP. Authenticated REST reads are verified from Windows
with the Windows identity; Vault-account login (`POST /sessions`) is implemented
but was not exercised live. The Python CLI has no integrated Windows
authentication; the PowerShell helper supplies the token. One file has been
written to Vault, by the gated executor. Automatic export job submission and LFS
payload resolution are not implemented. Search is deliberately one page with the
returned cursor preserved. ByRef COM calls (`CreateGeometryProxy`, translator
`Open`) are made through the compiled C# helper; `Inspect-StepInInventor.ps1`
still falls back to `Documents.Open` defaults. Export metadata counts come from
an explicit occurrence-tree walk; `AllLeafOccurrences` is not enumerable from
PowerShell (its count reads through `InvokeMember`). `SurfaceBody.Volume()` is not callable from PowerShell; volumes come
from `MassProperties.Volume`. All Windows automation ran in an interactive
desktop session; unattended service mode is unqualified.
