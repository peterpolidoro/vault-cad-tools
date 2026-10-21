# Windows agent handoff — 2026-10-21

Please take the lead on Windows qualification and the first real Vault-to-STEP
export. Peter asked for this handoff. Linux can resume with FreeCAD geometry
validation once the exported part, assembly, and provenance are available.
Fix concrete Windows issues and implement a minimal local exporter if needed;
keep reusable code here and project data in `free-standing-tank-enclosure`.

## Starting state and checkout ownership

The Linux and shared clones were clean and synchronized when this handoff was
prepared: tools commit `94427de`, project commit `fbe2873`. This README and the
tools plan are subsequent, uncommitted handoff updates in both tools clones.
Read the shared copy immediately; it will not reach GitHub until Peter commits
and pushes it. Read each repository's `.agents/AGENTS.md` and living plan too.

Use sibling **local Windows checkouts** of the two repositories. Do not run Pixi
or develop in a checkout that another host is editing through the network share.
Check `git status` first; fast-forward a clean checkout with `git pull --ff-only`.
Preserve any existing work. Linux will leave implementation to Windows during
this phase. Leave commits and pushes to Peter unless he asks you to perform them.

The shared Linux paths are:

```text
/janelia/sciserv/polidorop/Repositories/github/vault-cad-tools
/janelia/sciserv/polidorop/Repositories/github/free-standing-tank-enclosure
```

Use the Windows drive/UNC mapping already available on this machine; do not
guess it. Put raw evidence and export payloads in a new, uniquely named directory
under the shared `vault-cad-exchange/` area, outside Git worktrees. Keep credentials
and tokens on the executing host and out of logs, receipts, and shared files.

The original `Vault-Inventor-STEP-Automation.md` in the tools repository records
installed capabilities. Preserve it. No authenticated end-to-end workflow has
been demonstrated yet. The portable suite passed 30 tests in Guix and Linux Pixi;
Windows execution, CAD conversion, and uploads remain unverified. The CLI has
read/import/request operations, but no export-job submission or upload adapter.

## 1. Qualify the locked environment and both repositories

From the local Windows tools checkout, run these in PowerShell and record each
command's exit code, output, Windows/Pixi versions, and both repository commits:

```powershell
pixi --version
pixi install --locked
pixi run --locked doctor
pixi run --locked test
pixi run --locked cli --project ..\free-standing-tank-enclosure status
```

The baseline is 30 passing tests, `portable_tools_ready: true`, and project status
identifying the configured assembly with empty reference/publication records.
Record failures and skips explicitly. Fix portability failures here, rerun the
affected checks, and run the suite after code changes. Do not regenerate the
lockfile merely to make installation pass; diagnose the actual failure first.
The project has no separate Python environment or test suite: its status check
and later geometry checks use the tools environment and CAD applications.

Install Pixi itself from https://pixi.sh/latest/installation/ if needed. Pixi
manages Python/Git; Windows PowerShell and Autodesk software/licensing are host
prerequisites. `doctor` detects files at default locations, not a working license
or SDK. Verify alternate install paths if needed. Establish exact compiler,
runtime, or interop requirements before adding dependencies for a Windows adapter.

## 2. Verify actual Vault reads and freeze a pilot snapshot

The configured server is `svault5`, vault `IDF VAULT`, vault ID `28`. The pilot is:

```text
$/PROJECTS/_PROJECTS BY LAB/SCHULZE (LAB)/ENCLOSURE/Free Standing Enclosure.iam
```

First capture the actual served schema and capabilities in a fresh directory:

```powershell
pixi run --locked capture-api -OutputDirectory "YOUR_SHARED_PATH\vault-cad-exchange\evidence\UNIQUE_RUN"
```

Replace the path with the real Windows share mapping. This capture does not
authenticate, submit jobs, or change Vault settings. The portable alternative is
`pixi run --locked cli --project ..\free-standing-tank-enclosure probe --output PATH`.
Record a resolvable FQDN/HTTPS endpoint if available; Linux could not resolve
`svault5`. Do not change server configuration during qualification.

Inspect the captured schema before relying on the draft reader's requests. Use
authorized credentials already available locally; Vault-account login and an
existing session token are supported, but integrated Windows authentication is
not implemented in the Python reader. If authentication is unavailable, finish
offline/SDK checks and report that specific blocker. Do not substitute fake IDs.

With working authentication:

- Search for the root, then verify its complete folder path and vault identity.
  Record root master ID, file-version ID, folder ID, and selected model state.
- Inspect `file VERSION_ID` and `uses VERSION_ID` against the served API. Resolve
  the exact referenced versions, including library components outside ENCLOSURE.
  Check paging, suppressed/substitute components, model states, and missing refs.
  Do not claim a complete snapshot from one search page or silently use latest
  dependencies in place of those referenced by the root version.
- Download one representative part and the assembly dependency set to an ignored
  local cache/workspace. Preserve the layout and Inventor project resolution
  needed to open them. Use the Vault SDK/client if it is needed for correct
  acquisition; record exact versions actually acquired. Do not check out files
  merely to read/export them.

Reader command forms, with real IDs and locally supplied authentication, are:

```powershell
pixi run --locked cli --project ..\free-standing-tank-enclosure --username USER search 'Free Standing Enclosure.iam'
pixi run --locked cli --project ..\free-standing-tank-enclosure --username USER file VERSION_ID
pixi run --locked cli --project ..\free-standing-tank-enclosure --username USER uses VERSION_ID
pixi run --locked cli --project ..\free-standing-tank-enclosure --username USER download VERSION_ID --output LOCAL_CACHE_PATH
```

`USER`, IDs, and the cache path above are placeholders, not resolved values.
Passwords are prompted when no token/password environment input is supplied.
Avoid credential-bearing transcripts and command-line passwords. Keep native
Inventor downloads outside tracked project files.

## 3. Produce one part and one assembly STEP

Determine whether an existing Job Processor can perform the STEP job types in
the original report. Inspect an actual successful job's parameters, source
version, output IDs, and associations before implementing job submission. Do not
infer parameters from handler names or alter global queue/lifecycle settings.
Use an existing result only if its exact source snapshot can be established.

If the job route is unavailable, use installed Inventor on local acquired copies
to export STEP. A minimal reproducible script or documented GUI export is enough
for this first geometry check. Record which route actually ran. Open the selected
model state, resolve all references, and never save conversion-induced changes
back to the native sources. Do not block a local export on configuring a server
job pipeline. If Inventor resolves a different dependency version, stop calling
it the frozen snapshot and reconcile the discrepancy before accepting the export.

Deliver a real part STEP, the assembly STEP, and one JSON export receipt per file
matching `docs/exchange-protocol.md`. Include actual source master/version IDs,
source paths, translator version, STEP protocol, model state, output SHA-256,
and the assembly dependency-version inventory. Record units, component/solid
counts and representative dimensions/placements as comparison evidence. Report
unresolved or omitted components explicitly. Filename similarity and a STEP
header alone are not conversion evidence.

Reopen the exports in Inventor to check basic geometry and completeness. Exercise
`import-step` and `status` in a **disposable project copy** with these receipts;
confirm a repeated identical import is a no-op. Leave the main project baseline
for Linux FreeCAD review. No production Vault upload is needed for this phase.

Autodesk's Vault 2025 documentation lists Inventor Server for built-in STEP jobs;
full Inventor COM automation has separate requirements. Verify the chosen route's
installed components and license rather than treating their requirements as
interchangeable:
https://help.autodesk.com/cloudhelp/2025/ENU/Vault-Admin/files/GUID-CDD7E780-3322-4560-AA31-43025A845824.htm

## 4. Return results and divide the remaining work

Write a dated Windows results report in the shared exchange run directory. Include:

- Repository commit IDs, any uncommitted changes, environment versions, commands,
  exit codes, test summary, and a distinction between passed/failed/not-run checks.
- Probe/schema location, verified API corrections, authentication method name
  without secrets, and the resolved pilot snapshot/dependency inventory.
- Export route, payload/receipt locations and hashes, Inventor observations,
  import smoke-check results, and exact blockers or unresolved questions.
- Code changes as reviewable patches including new files, or commit IDs once Peter
  has published them. Update the repository plans with actual results. Do not copy
  a Windows checkout over either Linux/shared checkout to transfer changes.

Return to Linux once these artifacts are ready (or with a precise blocker after
the independent checks). Linux will inspect the files in FreeCAD for units,
solids, dimensions, placements, and completeness, then establish the project
reference baseline. Windows remains the owner of Autodesk adapters; Linux owns
FreeCAD validation and Linux authoring, with portable code reviewed across both.

The later reverse-direction pilot needs a committed Linux-authored STEP and an
explicit Vault destination selected with Peter. Inspect available SDK assemblies
now if useful, but defer the live add until that target and payload are known.
Before enabling writes, implement request validation, collision refusal, retry
reconciliation/idempotency, and a result receipt. Verify a successful add by
re-downloading the payload and opening it in Inventor. `prepare-publish` and
`verify-request` currently prepare/check local data only; neither uploads it.
