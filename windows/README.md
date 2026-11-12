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

Offline suites, none of which needs Inventor or Vault: `Test-ExportReceipt.ps1`,
`Test-InventorSession.ps1`, `Test-DialogWatchdog.ps1`, `Test-StepLengthUnit.ps1`,
`Test-SnapshotOutputs.ps1 -SelfTest`, `Test-StepHeader.ps1`,
`Test-PackageFormat.ps1`, `Get-VaultFileFacts.ps1 -SelfTest`,
`Discover-VaultFolder.ps1 -SelfTest`, `Test-ScriptHygiene.ps1`.

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
- Git: the shared clones under `U:\Repositories\github\` are the only remote used on
  this machine (`shared`); Peter pushes to GitHub and fast-forwards them.

## Rules that came out of the pilots

- Every script that drives Inventor should start it through
  `Inventor-Session.ps1` (owned instance, project cleanup, dialog watchdog).
  `Export-PartAssets.ps1`, `Measure-PartBodies.ps1`, `Audit-NativeBom.ps1`,
  `Invoke-MonitorPlacementPilot.ps1`, `Invoke-ReferenceModelProbe.ps1`,
  `Invoke-ExporterGuardChecks.ps1`, `Invoke-StepExportProbe.ps1`,
  `Get-PartFeatureDump.ps1`, `Invoke-AssemblyStepProbe.ps1` and
  `Export-Package.ps1` do. `Export-InventorStep.ps1`,
  `Inspect-StepInInventor.ps1`, `Compare-NativeAndStepAssembly.ps1`,
  `Invoke-NativeAuthoringPilot.ps1` and `Invoke-NativeParameterPilot.ps1` do not
  yet: use them only in the single-user interactive session they were
  qualified in.
- A run that ends `complete_with_dialogs` had a dialog dismissed by the
  watchdog. Read the receipt's `dialogs` field before accepting it.
- A package is complete only after a run that ended `complete`. When a run of
  `Export-Package.ps1` ends `complete_with_dialogs`, the script takes
  `package.json` away again and exits 1. The reason: what the watchdog
  acknowledged is only in the run's receipt, the receipt stays on the
  workstation, and whoever reads the package cannot see it; a package that
  says it is complete must not depend on something its reader cannot check.
  The other files stay where they are, without `package.json`, as after any
  failed run. There is no switch to accept such a package: read `dialogs` in
  the receipt, remove the cause and run again. A dialog that comes back on
  every run is for Peter to decide.
- Production documents are opened from the acquired mirror and never saved.
  Pilots that save anything work in a disposable copy of the mirror.
- All automation so far ran in an interactive desktop session. Unattended
  service mode is not qualified.
- A REST listing is read as one page (`limit` up to 1000) and accepted only
  when its row count equals the server's `totalResults`. This server's paging
  cursor is id-based while rows are ordered by name; following it repeats and
  skips rows.
- The STEP translator takes the header's author from the native file's Summary
  Information "Author" when its own `Author` option is empty, the header's name
  from the output file name, and has no option for the time stamp. A fixed
  header is written afterwards with `Set-StepFileHeader` (`Step-Header.ps1`),
  which changes the `FILE_NAME` statement only.
- An AP242 export carries a saved view (`CAMERA_MODEL_D3` and what it reaches).
  A document opened without a view gets a fixed default camera, so the file is
  the same in every session; a document that has a view gets that view's
  camera, and the file changes with it. `Export-PartAssets.ps1` opens the root
  invisibly and no document has a view. Keep it so: never export for the
  repository from a document opened visibly.
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
  `Get-RequiredValue`, `Assert-RequiredObject` and `Get-RequiredCount` of
  `Package-Format.ps1`, and `Get-OptionalValue` for what may be unknown and is
  then null. `Test-PackageFormat.ps1` (P21) reads `Export-Package.ps1` and
  `Invoke-AssemblyStepProbe.ps1` as syntax trees and fails when a guard query
  or an optional read holds a cast.
- Start Inventor inside the `try` whose `finally` stops it, and run nothing
  outside a `try` after it: the receipt is always written, and whatever fails
  after `package.json` was written removes it (`Complete-Package`).
  `Test-PackageFormat.ps1` (P22) holds the same two scripts to that structure.
  The older scripts that start an owned instance do not have it yet (see the
  open items in `.agents/PLANS.md`).
- In PowerShell the comma binds tighter than arithmetic: write
  `@(($x * 10), ($y * 10))`, never `@($x * 10, $y * 10)`. A hashtable literal
  is case-insensitive and its dot access returns the value of a key named
  `count`; use an ordinal dictionary and `get_Count()` where either matters.
