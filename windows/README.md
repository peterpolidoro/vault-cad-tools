# Windows side of vault-cad-tools

PowerShell scripts that perform the Vault and Inventor operations on a Windows
workstation with Inventor 2025 and the Vault Client 2025 installed. Linux
decides what is done; these scripts do only what a request or an operator asks,
and write receipts. Nothing here writes to Vault without Peter's explicit
request.

- What each script does and how to call it: the repository
  [README](../README.md), section "Windows export route".
- The request and result formats: [docs/exchange-protocol.md](../docs/exchange-protocol.md).
- The synchronisation design (a document, not code):
  [docs/native-checkin-adapter-design.md](../docs/native-checkin-adapter-design.md).
- What was run here, with evidence runs and suite counts:
  [HISTORY.md](HISTORY.md).
- Where the work is going and what is next: `.agents/PLANS.md`, and the newest
  message addressed to Windows in the shared coordination directory.

## Exporting a root assembly for a project

`Export-Package.ps1` is the exporter. It writes the package that
`import-snapshot` reads into a project: one directory per Vault file with
`source.json` and `part.step` (AP242, header normalised) or `assembly.json`,
`occurrences.json`, and `package.json`, which is written last. The package is
specified in `mechanical-cad/docs/exporter-package.md`.

```powershell
& .\windows\Export-Package.ps1 -NativeAssembly ROOT.iam -WorkspaceRoot MIRROR `
    -Acquisition acquisition.json -Inventory dependency-inventory.json `
    -OutputDirectory PACKAGE -WorkDirectory WORK
```

An export of unchanged Vault versions changes nothing in a project: every file
of the package but `package.json` is the same bytes, and `import-snapshot`
reports every reference as unchanged.

The earlier exporter, `Export-PartAssets.ps1`, and the scripts that served
only it or the export of single files were removed on 2026-11-13. The last
section of this file says which.

## Environment

```powershell
pixi install --locked
pixi run --locked doctor
pixi run --locked test
```

Pixi is installed per user with the official `install.ps1` (the winget MSI
needs administrator rights). `--locked` prevents re-resolving dependencies; do
not update the lock as a side effect. Autodesk applications, the Vault SDK
assemblies that ship with the Vault Client, and licensing are host
prerequisites that Pixi does not manage.

Call the scripts with `&` from PowerShell. `powershell -File` flattens array
parameters.

Offline suites, none of which needs Inventor or Vault:
`Test-InventorSession.ps1`, `Test-DialogWatchdog.ps1`, `Test-StepLengthUnit.ps1`,
`Test-StepHeader.ps1`,
`Test-PackageFormat.ps1`, `Get-VaultFileFacts.ps1 -SelfTest`,
`Discover-VaultFolder.ps1 -SelfTest`, `Get-VaultDependencySnapshot.ps1 -SelfTest`,
`Publish-ReferenceRoutePilot.ps1 -SelfTest`, `Test-ScriptHygiene.ps1`.

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
- Before a live add, `Publish-StepToVault.ps1 -DryRun` on the plan. It resolves by
  reflection the seventeen SDK members of both license modes and both routes, and its
  `would_call` names the calls of the mode and route given, which by default are those
  of a live run. It invokes none of them: whether an Autodesk ID is signed in is asked
  by the live run, which refuses before the journal moves.
- The reference route (design 5.5) is a pilot and its live branch has not been run.
  The lines of that branch were rehearsed whole on 2026-11-20 against a stand-in
  for the SDK types they touch, never against Vault.
  `New-ReferenceRouteDocuments.ps1` makes the wrapper part and the assembly in a
  scratch workspace laid out as the Vault folder is; `Publish-ReferenceRoutePilot.ps1
  -Prepare` writes the request and a journal entry of its own (not the publication
  journal), `-DryRun` checks both, resolves the SDK members by reflection and writes
  every call a live run would make, each add with its file, hash and association.
  `-Live` has its gates (request id, folder and folder id, the STEP file's version,
  both hashes, the journal) and adds two files, the wrapper and then the assembly;
  it needs the folder owner's word for exactly that request. What the Inventor
  add-in writes into an association's `RefId`, `Source` and `ExpectedVaultPath` is
  not known (the one read that would show it failed at its sign-in on 2026-11-20
  and was not tried again): the request carries them, null as prepared, and
  `-Prepare` takes them as parameters once they are known. A field that is null
  in the request is not set on the association at all.
- Git: the shared clones under `U:\Repositories\github\` are the only remote used on
  this machine (`shared`); Peter pushes to GitHub and fast-forwards them.

## Rules that came out of the pilots

- A walk to a Vault folder by its path (`vault-cad catalog-snapshot`, `plan-publish`,
  `Discover-VaultFolder.ps1 -FolderPath`) asks the server for the sub-folders of every
  level above it. In a personal area those are other people's folders: keep the
  folders on the path, each with its id, and nothing of what else a level holds.
  `Discover-VaultFolder.ps1` records them so (`folders_on_the_path`: id, name, path
  and category, the root first). Given `-FolderId` alone it lists no level: it reads
  the folders above one by one, each by the parent the one below names.
- A file that is checked out is listed by the place of its check-out, a row that
  is not a version checked in. The row stands above the file's versions with the
  next version number and a check-in date of year 1; `folders/{id}/contents` names
  the file by it, `files/{master}/versions` lists it last, and a parent that is
  checked out is named by it. `isCheckedOut` is true on every row of such a file,
  on its earlier versions too, so only the date tells them apart
  (`Vault-Version.ps1`). `Discover-VaultFolder.ps1` says of every file, parent,
  child and closure member what its row is (`version_is`), records no check-in
  date for such a row and counts them; a root is still a root.
  `Get-VaultDependencySnapshot.ps1` refuses such a row as the root: nothing is
  downloaded, `snapshot-receipt.json` has the status `refused_check_out_place`
  and names the file, the exit code is 2. A member that is such a row is taken
  at its last version checked in, the row before it in `files/{master}/versions`,
  and that version's own children are followed in place of the place's: what
  "get latest" gives everyone but the person who has the file checked out. The
  inventory says so of the member (`stands_for_check_out_place`, with the id of
  the place), the receipt lists and counts such members, and the status is
  `complete`. With `-AsCheckedIn` a member is never such a row.
  `Get-VaultFileFacts.ps1` reads the latest version by the same rule, the last
  row that is a version checked in: a check-out is reported as one
  (`checked_out`, since when, the id of the place) and is not a change.
- Every script that drives Inventor should start it through
  `Inventor-Session.ps1` (owned instance, project cleanup, dialog watchdog).
  `Measure-PartBodies.ps1`, `Audit-NativeBom.ps1`,
  `Invoke-MonitorPlacementPilot.ps1`, `Invoke-ReferenceModelProbe.ps1`,
  `Invoke-StepExportProbe.ps1`,
  `Get-PartFeatureDump.ps1`, `Invoke-AssemblyStepProbe.ps1`,
  `Invoke-StepImportProbe.ps1`, `New-ReferenceRouteDocuments.ps1` and
  `Export-Package.ps1` do.
  `Compare-NativeAndStepAssembly.ps1`,
  `Invoke-NativeAuthoringPilot.ps1` and `Invoke-NativeParameterPilot.ps1` do not
  yet: use them only in the single-user interactive session they were
  qualified in.
- A wrapper part holds its STEP file by a name relative to itself, and an
  assembly its wrapper likewise (`FileDescriptor.RelativeFileName` is the bare
  file name when the files share a folder). Moved together to another root, the
  three files open with the link held and nothing to save; Inventor then says
  that the location differs (`ReferenceLocationDifferent`) and that nothing is
  missing. `File.ReferencedFileDescriptors` holds `FileDescriptor` objects, not
  `ReferencedFileDescriptor`: they have no `DocumentFound` and no logical-name
  call. A document made from Autodesk's standard templates holds no iLogic rule
  and no event trigger, so saving it runs none.
- A sub-assembly used in two model states is two documents with one file name
  (`FullDocumentName` ends in `<state>` for the one that is not primary), and
  each has its own suppressed occurrences. `Export-Package.ps1` takes a document
  by its full document name and its state from the document (`ModelStateName`),
  and binds both documents to the one acquired file. The file's active model
  state and its level of detail say what the file was saved in, the same for
  both documents, and decide nothing: a level of detail is accepted when it is
  the master or names a model state of the file. An occurrence must be in the
  model state of the document it places. A part in a model state that is not
  its primary one still stops the export.
- A suppressed occurrence is not a child. The assembly's `source.json` names
  each under `native.suppressed_occurrences` (the name, and the master id and
  path of the file it would place where they can be read without unsuppressing
  anything); the field is absent when the document has none, so the files of a
  project without model states are the bytes they were. `package.json` counts
  them (`counts.suppressed_occurrences`, always there). The package check
  refuses a child that is suppressed or is named as suppressed, and a count
  that is not the number named. A file of the acquisition that only suppressed
  occurrences place is under `not_exported`.
- A STEP file may mark an item invisible that is also a member of a named group
  (`APPLIED_GROUP_ASSIGNMENT`); the parts of Inventor's gear generator do, for
  the surface of the pitch diameter. `Get-StepInvisibility` does not understand
  that form and the exporter stops at such a part. Nothing was loosened: what
  the reader should do with it is for `mechanical-cad` to decide, since its
  reader has the same rule.
- A part without a body (a composite of surfaces and no solid) does not stop
  the exporter: its STEP file holds open shells and no solid, and its record
  has no solid body, no surface body and a volume of 0. Whether a package
  should hold such a part is not decided.
- A run that ends `complete_with_dialogs` had a dialog dismissed by the
  watchdog. Read the receipt's `dialogs` field before accepting it.
- A package is complete only after a run that ended `complete`. When a run of
  `Export-Package.ps1` ends `complete_with_dialogs`, the script writes no
  `package.json` and exits 1. The status is known before the file would be
  written, because the watchdog has been stopped by then, so a run that is
  killed cannot leave a `package.json` behind. The reason for the rule: what
  the watchdog acknowledged is only in the run's receipt, the receipt stays on
  the workstation, and whoever reads the package cannot see it; a package
  that says it is complete must not depend on something its reader cannot
  check. The other files stay where they are, without `package.json`, as
  after any failed run. There is no switch to accept such a package: read
  `dialogs` in the receipt, remove the cause and run again. A dialog that
  comes back on every run is for Peter to decide.
- What a receipt says about `package.json` is asked of the file system after
  the last attempt to remove it (`Get-PackageOutcome`). A `package.json`
  that could not be removed is reported as present and fails the run: to
  whoever reads the directory it says "complete", whatever the receipt says.
- The exporter's receipt, `export-package-receipt.json`, is `schema_version` 4
  (`$PackageReceiptSchemaVersion` in `Package-Format.ps1`). Since 3 it says
  whether `package.json` is in the directory (`package_json_present`), and
  `validation.stage` can be `withheld`. Since 4 its guards are named for model
  states and suppressed occurrences, and its counts say how many files were
  opened, how many of them in more than one model state, and how many
  suppressed occurrences were named. `Test-PackageFormat.ps1` (P35) holds
  both places where the exporter writes a receipt to that number.
- Production documents are opened from the acquired mirror and never saved.
  Pilots that save anything work in a disposable copy of the mirror.
- All automation so far ran in an interactive desktop session. Unattended
  service mode is not qualified.
- A REST listing is read as one page (`limit` up to 1000) and accepted only
  when its row count equals the server's `totalResults`. This server's paging
  cursor is id-based while rows are ordered by name; following it repeats and
  skips rows.
- In Windows PowerShell 5.1 a null assigned to a text property of a .NET object
  is stored as an empty text. What must stay unset is not assigned at all
  (`Get-AssociationTexts` in `Publish-ReferenceRoutePilot.ps1`).
- A live branch can be rehearsed whole without `-Live`: the lines after the
  parameter block are taken from the script's syntax tree and run in a process
  of their own, with stand-in assemblies under the SDK's names in place of the
  client's directory. The stand-in is held against the installed client by
  reflection (every type and member the branch touches, same signatures) before
  its answers count for anything. The tools are with the evidence of 2026-11-20.
- A sign-in through an Autodesk ID can fail when the token the identity service
  holds has run out and its refresh has not finished. On 2026-11-20 the SDK
  threw at the web service manager with the message "0", and the identity
  service's own log shows the token asked for while the refresh was still
  running. The Vault client was not open that day; open, it keeps the token
  fresh. No script here tries a sign-in again.
- The server names the children of an old version at their latest versions.
  `GET file-versions/{id}/uses` gives the children of exactly that version of
  the parent, which masters they are, but it gives every child at its latest
  version, whatever `getLatestAssocs` and `releaseBiased` are set to;
  `/parents` answers the same way. For the latest version of a root that is
  what "get latest" gives a user. For an earlier version it is a mix that
  never existed in Vault: the old root with today's children, and with
  today's children of those. `Get-VaultDependencySnapshot.ps1 -AsCheckedIn`
  rebuilds what the version was checked in with, by date: every child at its
  newest version checked in at or before the root version, and that
  version's own children in the same way. It is a rule applied to dates, not
  a record read from Vault; `dependency-inventory.json` says which of the two
  ways was used (`resolution`).
- A version that is not the latest has no lifecycle state in the server's
  answers, so `vault.lifecycle_state` is an empty text for it in a package.
- No script shows or records a Vault session's id or its token, and none
  sends a web request other than a GET, apart from the sign-in
  (`POST sessions/win-auth`). `Test-ScriptHygiene.ps1` (checks 5 and 6) holds
  every script of this directory to both. `Get-VaultDependencySnapshot.ps1`
  counts its requests by kind in `snapshot-receipt.json`; the folder
  discovery and the file facts count theirs in their receipts.
- Every acquisition gets a mirror root of its own. The exporter makes its
  project file in the mirror root and removes it again, so a mirror holds the
  acquired files and nothing else, before a run and after it.
- The STEP translator takes the header's author from the native file's Summary
  Information "Author" when its own `Author` option is empty, the header's name
  from the output file name, and has no option for the time stamp. A fixed
  header is written afterwards with `Set-StepFileHeader` (`Step-Header.ps1`),
  which changes the `FILE_NAME` statement only.
- An AP242 export carries a saved view (`CAMERA_MODEL_D3` and what it reaches).
  A document opened without a view gets a fixed default camera, so the file is
  the same in every session; a document that has a view gets that view's
  camera, and the file changes with it. `Export-Package.ps1` opens the root
  invisibly and refuses a document that has a view. Keep it so: never export
  for the repository from a document opened visibly.
- AP242 also writes the bodies that are hidden in the part, marked by an
  `INVISIBILITY` entity; no translator option leaves them or the saved view
  out. A solid with an internal void is a `BREP_WITH_VOIDS`, not a
  `MANIFOLD_SOLID_BREP`: count both when counting solids.
- The STEP translator sometimes names a second, unrelated schema in
  `FILE_SCHEMA`, in front of the AP242 one, for the usual data section. Seen on
  2026-11-12 in four of the eight runs of `Export-Package.ps1` (four files in
  215 exports: `AUTOMOTIVE_DESIGN` twice, `FEATURE_BASED_PROCESS_PLANNING`,
  `PROCESS_PLANNING_SCHEMA`; the 25th, 13th, 26th and 10th export of their
  runs), and in none of 203 exports by `Invoke-StepExportProbe.ps1`,
  `Invoke-AssemblyStepProbe.ps1` and `Export-PartAssets.ps1` on three days.
  Why is not known; writing all STEP files before anything else is read from
  the documents did not remove it. `Export-Package.ps1` never delivers or
  repairs such a file: it exports the part again, accepts only a file that
  names the AP242 schema alone, requires every attempt to have the same data
  section, and records every attempt. Wherever a file's protocol matters, look
  at `schemas` of `Get-StepFileInfo`, not only at the first name.
- Inventor's own STEP export of an assembly has one product per document and
  one usage per child of each assembly document, each product in its
  document's length unit, and it writes a flexible sub-assembly with the
  positions it has in the assembly, not with those of its own document.
- A COM collection that leaves a script block or a function is enumerated by
  PowerShell and arrives as an array, or as its only element: assign it
  directly (`$items = $feature.ParentFeatures`). A cast of `$null` invents a
  value (`[double]$null` is 0, `[bool]$null` is False, `[string]$null` is ""):
  test for `$null` before casting what an API may not return.
- Build relative file names from the directory entries, not by cutting a
  prefix off a full path: a directory given in its 8.3 form, as `%TEMP%` is
  on this workstation, lists its files under their long names.
- A guard query returns what the API returned and holds no cast. `[int]$null`
  is 0, `[bool]$null` is False and `[string]$null` is an empty text, so
  `{ [int]$doc.Views.Count }` reads a missing collection as "no view" and
  passes its guard. A collection is asked for as an object that must exist:
  `$null.Count` is 0 and `foreach` over `$null` runs zero times. Use
  `Get-RequiredValue`, `Assert-RequiredObject`, `Get-RequiredCount` and
  `Get-RequiredItems` of `Package-Format.ps1`, and `Get-OptionalValue` for
  what may be unknown and is then null. `Test-PackageFormat.ps1` (P21) reads
  `Export-Package.ps1`, `Invoke-AssemblyStepProbe.ps1` and
  `Invoke-StepImportProbe.ps1` as syntax trees and fails when a guard query or
  an optional read holds a cast.
- Never ask for a count in one step. `{ $manager.Views.Count }` gives 0 for a
  collection that is missing, also without a cast. Hand the collection over:
  `Get-RequiredCount` and `Get-RequiredItems` refuse a missing one, and
  `Get-OptionalCount` returns nothing for it. `Test-PackageFormat.ps1` (P29)
  finds a count asked in one step in the three scripts.
- "Inventor returns nothing" and "the read failed" are two things.
  `Get-OptionalValue` turns both into null and counts the failures; it is for
  what is only described. `Get-GivenValue` returns null for nothing and stops
  the run when the read fails. The exporter reads a document's length unit
  with it, so `native.length_unit: null` never stands for a failed read.
- What a run states about every document is required, not given. The exporter
  says which documents were dirty when the export ended, so it reads every
  `Dirty` flag with `Get-RequiredValue`: a flag that Inventor returns as
  nothing stops the run as a read that fails does, because nothing is not
  "not dirty". `Test-PackageFormat.ps1` (P34) fails when the exporter reads
  `Dirty` in any other way.
- Start Inventor inside the `try` whose `finally` stops it, and run nothing
  outside a `try` after it: the receipt is always written, and whatever fails
  after `package.json` was written removes it (`Complete-Package`). In that
  `finally` every statement is a `try` of its own, so that one that throws
  cannot skip the watchdog's stop. `Test-PackageFormat.ps1` (P22, P33) holds
  the three scripts to that structure. The older scripts that start an owned
  instance do not have it yet (see the open items in `.agents/PLANS.md`).
- A value that came through the pipeline is wrapped in a `PSObject`, and COM
  answers a wrapped value with "Type mismatch" (`DISP_E_TYPEMISMATCH`): an
  option name taken from `... | Where-Object` has to be cast to `[string]`
  before it goes into `InvokeMember`.
- Reading a STEP file that Inventor did not write (`Invoke-StepImportProbe.ps1`):
  the translator's `Open` needs the C# helper of `Import-InventorInterop.ps1`.
  In Inventor 2025 the options that make it write documents while it reads
  are `SaveToDisk` and `EnableSaveComponentDuringLoad`; there is no
  `SaveComponentDuringLoad`. Inventor names an occurrence after the first
  attribute of its `NEXT_ASSEMBLY_USAGE_OCCURRENCE`, the id, and not after the
  second, the name; it names a document after its `PRODUCT`. When it writes
  native documents it puts them beside the STEP file, in a directory named
  after it. A file whose usages carry the occurrence's name as their id shows
  those names in Inventor unchanged, also where a name repeats under another
  parent (the enclosure's file: 172 names, 125 distinct, none changed).
  A product that several usages share becomes one document with as many
  occurrences, each where its usage puts it: the enclosure's file with one
  product per sub-assembly gives 8 assembly documents where a product per
  instance gave 18, and the same 172 occurrences. The root document is named
  after the STEP file, not after the root product.
- The volume of a document can leave a body out without saying so. Inventor
  computes a volume to a precision. `SurfaceBody.Volume(percent)` fails with
  `E_FAIL` when it cannot reach the precision asked for, and the document's
  `MassProperties.Volume` at that accuracy is then the sum of the other
  bodies. Seen on `MCMASTER 5537T429_T-Slotted Framing`: one of its 11 bodies
  is missing from the volume at `k_VeryHigh` (0.0001 %), and in the native
  document also at the default accuracy, `k_Low` (0.01 %). Once `k_VeryHigh`
  has been asked, the document answers with that number at every accuracy.
  So a part's volume is no check on its own, and a higher accuracy is not a
  better number: measure the bodies one by one
  (`Invoke-StepImportProbe.ps1 -BodyVolumesOf`, `Measure-PartBodies.ps1`).
- In PowerShell the comma binds tighter than arithmetic: write
  `@(($x * 10), ($y * 10))`, never `@($x * 10, $y * 10)`. A hashtable literal
  is case-insensitive and its dot access returns the value of a key named
  `count`; use an ordinal dictionary and `get_Count()` where either matters.

## Removed on 2026-11-13: the scripts of the earlier format

Peter saw the list of 2026-11-13 and had them removed; the Linux role removed
the files, and with them the reading of the earlier package in
`import-snapshot`. 14a235a is the last commit that has them.

| Script | What it served |
| --- | --- |
| `Export-PartAssets.ps1` | The earlier package: `assets/`, `native-snapshot.json`, `scene.json`, `inventory-raw.json`, `export-receipt.json`; AP214 by default |
| `Snapshot-Validation.ps1` | The check of that package |
| `Test-SnapshotOutputs.ps1` | The suite of that check, 12 cases |
| `Invoke-ExporterGuardChecks.ps1` | The qualification of `Export-PartAssets.ps1` in Inventor |
| `Export-InventorStep.ps1` | The single-file export: one STEP file per document, a whole assembly as one file |
| `New-ExportReceipt.ps1` | The receipt of the single-file export |
| `Test-ExportReceipt.ps1` | The suite of that receipt, 11 checks |
| `Inspect-StepInInventor.ps1` | The re-read of a single-file export in Inventor |

Eight offline suites were left of ten, and the hygiene suite checks 31
scripts. No script names a removed one. A ninth suite came on 2026-11-16,
`Get-VaultDependencySnapshot.ps1 -SelfTest`.
`bom-audit-summary --snapshot` still takes a `native-snapshot.json`; nothing
writes a new one, and a project keeps the one it has.

Not on the list, though they date from the same weeks:
`Get-VaultDependencySnapshot.ps1` writes the acquisition records and the
mirror that `Export-Package.ps1` binds to. `Compare-NativeAndStepAssembly.ps1`
was written for the single-file export but takes any STEP file of a whole
assembly. `Publish-StepToVault.ps1` executes a plan and reads no layout. The
pilots and probes (`Invoke-*Pilot.ps1`, `Invoke-ReferenceModelProbe.ps1`,
`Invoke-StepExportProbe.ps1`, `Measure-PartBodies.ps1`) take their files as
parameters and belong to no package format.
