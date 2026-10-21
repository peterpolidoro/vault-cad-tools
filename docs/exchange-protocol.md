# Filesystem exchange protocol, draft v1

This protocol is exercised locally. Live Autodesk conversion/publication and
publication-result ingestion are not implemented yet. Request directories are
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
strings. Additional `source` and `exporter` fields are preserved, allowing job ID,
dependency-version lists, export options, and validation records. An assembly
receipt must eventually include its resolved dependency versions and component
states; the importer currently cannot verify dependency completeness itself.
The Windows worker must establish the source/output relationship from actual
job results and file associations, not just a filename search.

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

## Publication result (planned)

Write `results/UUID.json` atomically with request ID, operation status, payload
SHA-256, destination, and actual Vault master/version IDs. Record the Git commit
in the Vault check-in comment where supported. Successful results must be checked
against the request and a re-downloaded Vault file before recording a publication
in the project lock. Merely preparing a request must never add a publication entry.

Credentials and session tokens remain on the executing host. Use per-request
evidence and bounded error messages without secrets. Keep code/long-term plans
in Git; keep host-specific handoffs and raw probe output in the exchange area.
