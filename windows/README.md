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
`Test-SnapshotOutputs.ps1 -SelfTest`, `Test-ScriptHygiene.ps1`.

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
  `Invoke-MonitorPlacementPilot.ps1`, `Invoke-ReferenceModelProbe.ps1` and
  `Invoke-ExporterGuardChecks.ps1` do. `Export-InventorStep.ps1`,
  `Inspect-StepInInventor.ps1`, `Compare-NativeAndStepAssembly.ps1`,
  `Invoke-NativeAuthoringPilot.ps1` and `Invoke-NativeParameterPilot.ps1` do not
  yet: use them only in the single-user interactive session they were
  qualified in.
- A run that ends `complete_with_dialogs` had a dialog dismissed by the
  watchdog. Read the receipt's `dialogs` field before accepting it.
- Production documents are opened from the acquired mirror and never saved.
  Pilots that save anything work in a disposable copy of the mirror.
- All automation so far ran in an interactive desktop session. Unattended
  service mode is not qualified.
