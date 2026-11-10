# Vault CAD tools living plan

## Objective

Support versioned Vault-to-STEP imports into project Git repositories and
publication of Linux-authored STEP files back to Vault, using a Windows adapter.

The direction of the wider work is in the sibling `mechanical-cad` repository
(`docs/direction.md`). Finished checkpoints, with their evidence runs, are in
.agents/HISTORY.md and windows/HISTORY.md.

## Current state (2026-11-10)

Demonstrated, each once, on the enclosure pilot:

- Vault to repository: `Get-VaultDependencySnapshot.ps1` freezes and downloads
  the exact versions of one root assembly; `Export-PartAssets.ps1` exports one
  STEP per part document plus the instance, placement and BOM records, with
  every opened document bound to its acquired hash; `import-step` records
  provenance in the project's `vault-lock.json`. Result: 37 parts, 155
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

Tests: 87 portable tests pass in the Guix environment (run 2026-11-10; 10 of
them are new, for `import-snapshot`). On Windows the same 87 pass under Pixi
and the offline suites pass (run 2026-11-10: script hygiene over 34 scripts
with a 9-case self-test of the checks, 37 session mock cases, 3 watchdog, 12
snapshot, 10 STEP unit, 11 receipt, 11 STEP header, 7 Vault facts and 8 folder
discovery cases). `import-snapshot` itself has not been run on Windows.

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
  format, into an empty directory only: it does not yet import into a project
  that already has keys, and it does not read a package keyed by master id,
  because no exporter writes one.
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

1. Peter: the protocol. Linux compared the AP214 and AP242 pairs of the
   Windows layout tests in FreeCAD on 2026-11-10: two of the three parts are
   the same geometry in both; for the part with hidden bodies FreeCAD reads the
   AP242 file as four solids (37 306.4 mm³) and the AP214 file as one
   (34 485.9 mm³). Recommended: AP214
   (`mechanical-cad/docs/layout-proposal.md`, "Open choices").
2. Linux, once the layout is accepted: run `import-snapshot` on a branch of
   the enclosure (the rest of that conversion is in the enclosure's plan);
   specify the exporter's package in `mechanical-cad` and make the import
   command read it, keep existing keys, and refuse what the lock says is newer
   in the repository; retire `import-step` and the old lock shape.
3. Windows: the exporter writes the new package; re-export the enclosure.
4. Then the synchronisation design's qualification on the new layout:
   read-only `discover_folder` with the sync states computed on Linux
   (`vault-cad sync-status`, written to `sync-status.json`, never into the
   lock), the incremental export dry run, an `update_step_file` plan.

## Open items

- Five scripts do not start Inventor through `Inventor-Session.ps1`:
  `Export-InventorStep.ps1`, `Inspect-StepInInventor.ps1`,
  `Compare-NativeAndStepAssembly.ps1`, `Invoke-NativeAuthoringPilot.ps1`,
  `Invoke-NativeParameterPilot.ps1`. Keep them to the single-user interactive
  session they were qualified in until they are moved.
- The material and appearance claim per part and body
  (`docs/authoring-and-materials.md` 4.1) is not recorded by the exporter.
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
PowerShell. `SurfaceBody.Volume()` is not callable from PowerShell; volumes come
from `MassProperties.Volume`. All Windows automation ran in an interactive
desktop session; unattended service mode is unqualified.
