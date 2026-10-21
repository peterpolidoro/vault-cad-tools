# vault-cad-tools

Command-line tools for exchanging STEP files between Autodesk Vault and Git CAD
projects. The same repository contains portable Python code and Windows helpers.

**Current state:** offline project/import/request operations and a REST reader
are implemented. Windows STEP conversion and Vault upload adapters are pending.
No command currently submits export jobs or uploads files into Vault.

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
task validation. All 30 regression tests and the doctor task pass in the locked
Linux Pixi environment. When nesting Pixi in a pure Guix shell, include `glibc`,
`bash`, and `coreutils` alongside `pixi` for runtime detection and activation.
The Windows environment is resolved in the lockfile but still
needs installation and execution on the Windows machine.

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
a session created by the tool is closed after the command. Windows-integrated
authentication is not implemented. The reported server URL uses HTTP, so login
credentials and tokens lack TLS protection; discuss HTTPS with the administrator.
HTTP redirects are refused, and ambient proxies are not used for this internal API.

`search` returns one page, including the server's cursor. Use `--cursor` for the
next page. `file VERSION_ID`, `uses VERSION_ID`, and `job JOB_ID` return raw server
JSON. The reader follows the Windows report, pending verification against the
served schema. Search results are discovery aids, not a version lock.

```sh
python3 run.py --project ../free-standing-tank-enclosure --username USER download VERSION_ID --output ../free-standing-tank-enclosure/.cache/part.ipt
```

Downloads refuse to overwrite a destination. The `uses` query requests version
associations rather than latest associations; its exact behavior and any
pagination must be qualified before using it for a whole-assembly snapshot.

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

These commands **do not upload**. They package and validate a committed file for
the forthcoming Windows uploader. Existing destination names must cause failure;
automatic overwrite/check-in is outside the initial protocol. STEP bytes must
match the Git commit. LFS is not implemented yet. Read the Windows handoff before
implementing an uploader or processing any real request.

The first supported release will be established by one real part/assembly export
and one new-file publication verified in FreeCAD and Inventor. This scaffold
does not claim that end-to-end milestone.
