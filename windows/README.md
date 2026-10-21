# Windows qualification handoff

The existing `Vault-Inventor-STEP-Automation.md` in this shared checkout is the
Windows investigation report. Preserve it. Its endpoint inventory and installed
handlers are observations, not proof of an authenticated export/upload round trip.

The pilot root is:

`$/PROJECTS/_PROJECTS BY LAB/SCHULZE (LAB)/ENCLOSURE/Free Standing Enclosure.iam`

Linux currently cannot resolve `svault5`. Please collect evidence from Windows:

First set up the locked Pixi environment in a **local** checkout. Pixi installs
Python and Git; Autodesk applications and Windows PowerShell stay host-managed.
Install Pixi itself from https://pixi.sh/latest/installation/ if needed.

```powershell
pixi install --locked
pixi run --locked doctor
pixi run --locked test
pixi run --locked cli --project ..\free-standing-tank-enclosure status
```

Save the doctor's output and the test summary with the host handoff. Default-path
file detection is not runtime or license validation. If the SDK adapter needs a
compiler, .NET runtime, or Python interop library, establish its exact version
first and add an appropriate managed dependency or documented host prerequisite.

1. Run the unauthenticated capture below. It reads capabilities only and does not
   change Vault settings, submit jobs, or authenticate.
2. Record a resolvable server FQDN if one exists. Check HTTPS availability with
   the administrator; do not alter server configuration as part of a probe.
3. With authorized local authentication, resolve the root assembly master ID,
   version ID, folder ID, relevant model state, and exact referenced versions.
   Keep credentials and bearer tokens out of shared output.
4. Determine whether a Job Processor is already running and whether its STEP
   types are enabled. Capture a normal Create STEP job for the pilot, including
   actual parameters, outcome, and output file/version IDs and associations.
   Installed handlers alone do not establish that the job will run.
5. Supply one part STEP and an assembly STEP with export receipts matching
   `docs/exchange-protocol.md`. Record known model-state/dependency limitations.
6. Inspect available SDK assemblies and establish a minimal new-STEP-file add
   workflow. Before any real upload, select an authored STEP and explicit Vault
   destination with Peter. Implement request validation, collision refusal,
   retry reconciliation, and a result receipt before enabling an upload worker.

Use a fresh output directory on the shared drive:

```powershell
pixi run --locked capture-api -OutputDirectory "YOUR_SHARED_PATH\vault-cad-exchange\evidence\windows-probe-001"
```

`pixi run --locked cli --project ..\free-standing-tank-enclosure probe --output PATH`
is another option. Authentication via a Vault account or an
existing session token is supported by the draft Python reader. Integrated
Windows authentication is not yet implemented there.

Autodesk's Vault 2025 docs list Inventor Server for built-in STEP generation;
full Inventor COM automation has separate requirements. Verify actual components
and Vault licensing rather than assuming the report's blanket Inventor-license
requirement. See:
https://help.autodesk.com/cloudhelp/2025/ENU/Vault-Admin/files/GUID-CDD7E780-3322-4560-AA31-43025A845824.htm

Keep development code in a local checkout and exchange commits/patches with the
Linux agent. Initial scaffold copies are uncommitted. Avoid simultaneous edits
to the same shared checkout. Record observations in a uniquely named handoff
file and distinguish verified results from hypotheses.
