# Filesystem exchange protocol, draft v1

This protocol is exercised locally and with Windows Inventor STEP exports.
Vault publication (one gated add, qualified 2026-10-22) and publication-result ingestion are implemented; updates/check-ins are not. Request directories are
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
--workdir DIR [--execution FILE]` re-downloads version V, compares size and SHA-256
with the payload, writes `results/UUID.json` atomically with `status: verified` or
`mismatch`, and sets the journal to `verified` or `failed`. It never touches the
project lock. The result carries the request `fingerprint`, `destination.folder_id`
and an `execution` block recorded verbatim from the executor (`executed_at`,
`executed_by_host`, `comment_sent`, `server_version_number`, `server_file_size`,
`server_checksum`) separate from `verified_at`; unknown execution fields are refused.
The Linux side ingests only `verified` results, recomputes the fingerprint from the
request directory and never reads the journal. Keep the journal and the verify and
reconcile work directories per exchange root, not per evidence run.

Journal transitions are an explicit table: `planned -> uploading | refused | planned`;
`uploading -> uploaded | ambiguous | failed`; `ambiguous -> uploaded | refused |
planned` (reconcile only); `uploaded -> verified | failed` (record-publish only);
`refused -> planned`; `verified` and `failed` are terminal (manual review). The
executor drives the journal through `vault-cad mark-uploading`, `mark-uploaded
--master-id --version-id --execution FILE`, `mark-ambiguous --reason` and
`mark-failed --reason`; `record-publish` refuses unless the state is `uploaded`.
The journal lives on the executing host only (`%LOCALAPPDATA%\vault-cad-tools\journals\<exchange>\`
on Windows); the Linux side never writes it and ingests `results/` only.

`record-publish` writes `verified` only when the destination folder resolves (and
equals the executor's folder id), the catalog lists the reported version in that
folder under the destination name (case-insensitive, hidden included), the
re-downloaded bytes match the payload's size and SHA-256, and the executor's server
size and CRC32 checksum match the download (Vault's `Cksum` is zlib CRC32). Every
check is recorded in `results/UUID.json` under `checks`.

The live write is `windows/Publish-StepToVault.ps1 -Live`, gated to one request id,
destination folder and folder id, payload hash and a `planned` journal entry with the
plan's fingerprint; it signs in with Windows authentication carrying the named-user
license as the Autodesk ID token of the user signed in to the Identity Manager
(Vault 2025 answers license error 319 to an unlicensed read/write sign-in), checks the
folder id and the name again through the SDK, journals `uploading`, adds the file
through `Connection.FileManager.AddFile` (the raw `UploadFilePart` pair answered Vault
error 155) and journals `uploaded` with the returned ids, or `ambiguous` on any
exception. First verified pilot: 2026-10-22, request e1caf6c0, version 994252.
`-DryRun` re-verifies the payload and resolves every planned SDK member by reflection
without opening a connection.

## Publication result ingestion (implemented 2026-10-22)

`vault-cad --project DIR import-publish-result results/UUID.json [--exchange ROOT]` is the only
Linux step that touches the project lock. It accepts a result only when: schema 1,
operation `add_step_file`, status `verified`; the request directory `requests/UUID`
exists and re-verifies (payload re-hashed); the fingerprint recomputed from that request
equals the result's; payload and re-download hashes/sizes equal the request; destination
(folder, name, if_exists), vault id/name and provenance equal the request; the folder id
and the Vault master/version ids are present; every verification check is true (none
false, the six listing/byte checks present); the execution record is typed and names the
executing host and time; and the blob at `provenance.git_commit:project_path` in the
project's Git history hashes to the payload. It then appends one record to
`vault-lock.json` `publications` (request id, path, hash, size, commit, Vault ids and
version, destination with folder id, execution host/time/comment, verified time,
fingerprint, result file hash, whether the working-tree file still matches) under the
project operation lock. Re-importing an identical result is a no-op; a different result
under the same request id, or the same Vault version under another request, is refused.
The journal is never read.

## Publication result (original plan)

Write `results/UUID.json` atomically with request ID, operation status, payload
SHA-256, destination, and actual Vault master/version IDs. Record the Git commit
in the Vault check-in comment where supported. Successful results must be checked
against the request and a re-downloaded Vault file before recording a publication
in the project lock. Merely preparing a request must never add a publication entry.

Credentials and session tokens remain on the executing host. Use per-request
evidence and bounded error messages without secrets. Keep code/long-term plans
in Git; keep host-specific handoffs and raw probe output in the exchange area.
