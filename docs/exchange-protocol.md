# Filesystem exchange protocol, draft v1

This protocol is exercised locally and with Windows Inventor STEP exports.
Vault publication and publication-result ingestion are not implemented yet. Request directories are
data, not executable instructions. Use a separate checkout on each machine.

## Export receipt

`import-step` accepts one STEP payload plus a JSON receipt:

```json
{
  "schema_version": 1,
  "source": {
    "vault_id": "28",
    "master_id": "ACTUAL_MASTER_ID",
    "version_id": "ACTUAL_VERSION_ID",
    "path": "$/ACTUAL/VAULT/PATH.ipt"
  },
  "exporter": {
    "name": "Autodesk Inventor Server",
    "version": "ACTUAL_TRANSLATOR_BUILD",
    "model_state": "ACTUAL_MODEL_STATE",
    "protocol": "ACTUAL_STEP_PROTOCOL"
  },
  "sha256": "ACTUAL_64_CHARACTER_SHA256"
}
```

Values above are placeholders explaining the schema, not test results. IDs are
strings. All receipt fields except the envelope's `schema_version` are preserved
in the reference lock entry, including top-level `dependencies`, `validation`,
and additional `source`/`exporter` fields. An assembly
receipt must include its resolved dependency versions and component
states; the importer currently cannot verify dependency completeness itself.
The Windows worker must establish the source/output relationship from actual
job results and file associations or exact-version acquisition and local export
records, not just a filename search. Preserving validation observations does not
mean the importer verifies their geometry or their dependency completeness.

`vault-lock.json` maps relative paths to checksums and this provenance. Reimports
of the same bytes and metadata are no-ops. Locally edited managed references
cause a conflict. To recover after an interrupted import, inspect the reference
checksum and receipt before repairing the lock; never silently accept mismatches.

## Publication request

The packager creates a unique `requests/UUID/` directory containing `request.json`
and `payload.step`. It stages under `.preparing-*` and renames only after the
payload and manifest are complete. A worker must ignore staging directories.

The manifest includes schema version, UUID, `operation: add_step_file`, vault
identity, an explicit destination folder and filename, `if_exists: fail`, payload
path/size/hash, and the source Git commit/path. Paths within a request must be
relative, portable between Windows/Linux, and must not use symlinks. All strings
are data; no command, PowerShell expression, or arbitrary script is supported.

The Windows adapter must revalidate the payload, verify the target vault/folder,
reject an existing filename, and add the STEP through the supported Vault SDK.
Never route it into an Inventor source file or an automatically regenerated STEP.

Retry handling is required before enabling writes. Journal request IDs and their
payload/destination fingerprints. Before retrying a possibly completed upload,
inspect Vault for the existing result and verify identity/content; a timeout is
not evidence that no file was created. Do not automatically retry an ambiguous
mutation. Updates/check-ins need a separate operation with an expected existing
file-version ID; they are not supported by v1.

## Publication plan, journal and reconcile (implemented offline, 2026-10-22)

`vault-cad plan-publish REQUEST_DIR --journal FILE [--catalog SNAPSHOT]` re-runs the
request verification, then checks the destination through a READ-ONLY catalog: the
offline snapshot written by `catalog-snapshot`, or the Vault REST API (GET only). It
refuses a vault id/name mismatch, a destination folder that does not exist (folders
are never created implicitly), and any file in that folder whose name matches
case-insensitively (`if_exists: fail`). The accepted plan is written atomically to
`plans/UUID.json` and lists the exact SDK calls an executor would make, in order:
Windows-authenticated `WebServiceManager`/`Connection`, `GetFolderByPath`,
`GetLatestFilesByFolderId`, `IFileManager.AddFile(... FileClassification.None, hidden
false, payload stream)`, journal update, exact-byte re-download. A plan is not an
execution: `dry_run` is always true.

The journal (`--journal`) maps each request id to the fingerprint of what would be
published where (operation, vault, folder, name, payload hash and size), a state
(`planned`, `uploading`, `ambiguous`, `uploaded`, `verified`, `failed`, `refused`),
attempts, notes and returned Vault ids. The same request id with a different
fingerprint is an identity conflict and is refused. An executor must record
`uploading` before the mutating call and `ambiguous` on a timeout or lost response;
both states block planning and uploading until `reconcile-publish` has inspected the
destination: a file with the requested name and identical bytes recovers the request
as `uploaded` with its ids, different bytes record a collision, and no file leaves the
request ambiguous unless the operator passes `--acknowledge-no-file`.

## Publication result (planned; verification implemented)

`vault-cad record-publish REQUEST_DIR --journal FILE --master-id M --version-id V
--workdir DIR` re-downloads version V, compares size and SHA-256 with the payload,
writes `results/UUID.json` atomically with `status: verified` or `mismatch`, and sets
the journal to `verified` or `failed`. It never touches the project lock.

The live write (`windows/Publish-StepToVault.ps1` without `-DryRun`) is refused until
an explicit, user-selected destination and a qualified pilot exist; in `-DryRun` mode
the script re-verifies the payload and resolves every planned SDK member by reflection
against the installed Vault client assemblies without opening a connection.

## Publication result (original plan)

Write `results/UUID.json` atomically with request ID, operation status, payload
SHA-256, destination, and actual Vault master/version IDs. Record the Git commit
in the Vault check-in comment where supported. Successful results must be checked
against the request and a re-downloaded Vault file before recording a publication
in the project lock. Merely preparing a request must never add a publication entry.

Credentials and session tokens remain on the executing host. Use per-request
evidence and bounded error messages without secrets. Keep code/long-term plans
in Git; keep host-specific handoffs and raw probe output in the exchange area.
