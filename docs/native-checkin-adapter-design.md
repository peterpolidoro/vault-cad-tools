# Native update / check-in adapter: design document (2026-10-22, for review)

Status: DESIGN ONLY. Nothing in this document is implemented as a live operation. No
production check-out, check-in, save or Vault write is authorized by it. It records what
the first verified add (request e1caf6c0, version 994252) and the placement pilot
(`evidence/2026-10-22-windows-placement-pilot-01/`) taught, and proposes the route for
publishing a modified native assembly (IAM) together with a new native part (IPT) to Vault.

## 1. Scope and non-goals

In scope: one assembly document already in Vault, modified in a disposable copy by
placing new native parts, checked in as a new version with its dependencies declared;
the new parts added as new files; everything journaled, verified and reversible up to
the final check-in. Out of scope: lifecycle/revision changes, item/BOM records, drawings,
renames, moves, deletes, properties beyond the check-in comment, Job Processor jobs,
multi-user merge of concurrent edits.

## 2. Facts established so far

- Vault Professional 2025 (30.4.28). Writing sessions need a named-user license; the SDK
  takes it as the Autodesk ID token of the user signed in to the Identity Manager
  (`AutodeskAccount.GetOAuthToken()`); an unlicensed read/write sign-in fails with error
  319. Windows authentication maps the executing account to the Vault user.
- Adding a file works through `Connection.FileManager.AddFile(Folder, name, comment,
  lastWrite, FileAssocParam[] associations, BOM bom, FileClassification, hidden, Stream)`;
  the raw `UploadFilePart` + `AddUploadedFile` pair answered error 155 and is not used.
- Vault `Cksum` is zlib CRC32; exact-byte re-download through REST is the verification.
- REST (API 2.0.16) is read-only for files: folder walk, contents, `file-versions/{id}`,
  `/uses` and `/parents` associations (`fileAssocType` Dependency or Attachment), content.
- Inventor side (placement pilot): a STEP opened by Inventor becomes a part document and is
  saved as IPT; occurrences are added with `Occurrences.Add(path, matrix)` and grounded;
  `Document.Save2(SaveDependents=false)` saves only the root copy; the copy's children keep
  their acquired hashes. The saved IAM references the new IPT by its path relative to the
  project workspace, listed by `File.ReferencedFileDescriptors`.
- Unattended saves of the production assembly are NOT silent (placement pilot, 2026-10-22/23):
  the assembly carries iLogic event-driven rules; its "Before Save" trigger runs the external
  rule `Part Number Cleaner`, which is not present on this workstation (no external rule
  directory configured). The iLogic add-in then shows a modal WinForms error window (one OK
  button) that `Application.SilentOperation` does not suppress, and an `AIP Migration Errors`
  dialog queued behind it; `Document.Save2` blocked for 19 hours until the form was closed
  from outside. The save itself completed correctly afterwards. The session module now runs
  a dialog watchdog thread (`Start-DialogWatchdog`) that records every dialog of the owned
  instance and dismisses only single-acknowledgement dialogs, never a choice.
- Associations as Vault sees them for the production root (version 991056): 43
  Dependency children (the acquired set) and one Attachment (the visualization DWF).

## 3. Operation and request (protocol v2 proposal)

New operation `update_native_assembly`, prepared on Linux from a Windows placement result:

```json
{
  "schema_version": 2, "request_id": "UUID", "operation": "update_native_assembly",
  "vault": {"id": "28", "name": "IDF VAULT"},
  "target": {"master_id": "988153", "expected_version_id": "991056", "vault_path": "$/.../Free Standing Enclosure.iam"},
  "payloads": {
    "assembly": {"path": "Free Standing Enclosure.iam", "sha256": "...", "bytes": 0},
    "new_parts": [{"path": "MONITOR/AW2725Q-nominal-envelope.ipt", "sha256": "...", "bytes": 0,
                   "destination": {"folder": "$/.../ENCLOSURE", "name": "AW2725Q-nominal-envelope.ipt", "if_exists": "fail"},
                   "derived_from": {"version_id": "994252", "sha256": "f7edc118...62ad3"}}]
  },
  "dependencies": [{"master_id": "...", "expected_version_id": "...", "source": "<reference string as stored in the IAM>"}],
  "if_changed": "fail",
  "provenance": {"git_commit": "...", "placement_receipt_sha256": "..."}
}
```

`dependencies` lists every child the saved IAM references, as recorded by the placement
pilot from `ReferencedFileDescriptors`, each pinned to the acquired version id. The
assembly payload is the saved root copy; the acquisition hashes of untouched children
are part of the binding, never re-uploaded.

## 4. Preconditions checked before any journal move

1. Request verified (schema, hashes, portable paths, STEP/IPT/IAM envelopes).
2. Journal entry `planned` with the request fingerprint; host-local journal.
3. Named-user session available (`IsLoggedIn`/`IsLoginValid`), server and vault match.
4. For the target and every dependency: `DocumentService.GetLatestFileByMasterId(master)`
   returns exactly `expected_version_id`, the file is not checked out, not locked, not
   controlled by a change order, and its lifecycle state permits check-in for this user
   (`GetEffectivePermissions`). Any difference: refuse, state `refused`, nothing touched.
5. New part destination: folder exists, no case-insensitive collision (hidden included).
6. The local IAM's `ReferencedFileDescriptors` equal the request's dependency set plus the
   new parts; the IAM is not referencing anything outside the workspace copy.
7. Unattended-session hygiene: the dialog watchdog is running on the owned instance; the
   iLogic external rules referenced by the target's event triggers are either resolvable
   (external rule directory configured with the production rule files) or the iLogic add-in
   is deactivated for the owned instance, decided and recorded per request (see open
   questions); a run whose watchdog recorded a dialog it had to leave alone is `failed`,
   never retried blind.

## 5. Mutating sequence (executor, Windows, journaled)

| Step | SDK | Journal |
|---|---|---|
| a | `FileManager.AddFile` for each new part (part documents have no children; `associations` null) | `uploading` -> `parts_added` with ids |
| b | `DocumentService.CheckoutFile(fileId, CheckoutFileOptions.Master, machine, localPath, comment, out ticket)` on the target version; verify the returned File is `expected_version_id` and now checked out to this user | `checked_out` |
| c | Build `FileAssocParam[]`: for every child (acquired versions by `CldFileId` = their file version id, plus the new parts' returned ids) with `Typ = Dependency`, `RefId`/`Source` from the IAM's reference descriptors, `ExpectedVaultPath` = child's vault path | |
| d | `FileManager.CheckinFile(FileIteration target, comment, keepCheckedOut=false, lastWrite, associations, bom=null, copyBom=false, newFileName=null, classification, hidden=false, Stream of the saved IAM)` | `uploading_checkin` -> `checked_in` with new version id |
| e | Verification: `GetLatestFileByMasterId` is the new version; `GetFileAssociationsByIds` (or REST `/uses`) lists exactly the declared children; re-download the IAM version and compare bytes; new parts re-downloaded and compared | `verified` |

Failure handling: any exception after (b) and before (d) returns -> `UndoCheckoutFile`
(journal `undo_attempted` -> `planned` only after the server shows the file checked in at
`expected_version_id` again and not checked out); any exception during or after (d)
-> `ambiguous`; reconcile inspects the latest version id, checked-out status, the
association list and the bytes before deciding `checked_in`, `refused` or `planned`.
New parts added in (a) before a later refusal stay in Vault (adds are not undone) and are
reported; a later retry of the same request treats them as existing with `if_exists: fail`
unless their ids are carried over in the journal.

## 6. Open questions (need the Linux reviewer and Peter)

- Whether the production root may receive a version from this route at all, or whether
  the monitor work lives in a new assembly document in the ENCLOSURE folder (preferred for
  the first live run: no check-out of a designer's file, no association rewrite of 43
  children, only adds).
- `BOM` parameter semantics for assemblies on `CheckinFile` (null vs the Inventor BOM
  structure the Vault add-in writes); whether the server requires `BOM` for `.iam`.
- Visualization attachment: the Vault add-in attaches a DWF on check-in; this adapter would
  not; is that acceptable for a pilot version?
- Category and lifecycle defaults the server assigns to SDK-added files (the pilot STEP got
  `None` classification, state Work in Progress); whether `FileClassification.DesignDocument`
  must be set for IPT/IAM.
- Which user the check-in comment and ownership should show (executing account).
- iLogic on save: the production assembly's event-driven rules run on every save and the
  `Part Number Cleaner` external rule is part of the designers' environment, not ours.
  Options: obtain the rule files and configure the external rule directory in the
  temporary project (rules then run as in the designers' sessions, with whatever they
  change), or deactivate the iLogic add-in in the owned instance (the saved assembly then
  skips part-number clean-up and any other trigger). Peter and Linux decide which is the
  intended behaviour of an automated check-in.

## 7. Qualification plan (no production write)

1. Dry run (offline): from the placement pilot's saved copy compute the dependency set,
   expected version ids from the acquisition, the association list and the planned calls;
   write `plans/UUID.json`; unit tests for refusal on version drift, missing child, extra
   reference, checked-out target, collision of a new part.
2. Disposable live pilot (needs Peter's explicit authorization): a NEW assembly document
   `placement-pilot.iam` referencing the new IPT and nothing from production, added to a
   folder Peter chooses; then one check-out/check-in cycle on that disposable IAM to prove
   (b)-(e), undo-checkout and reconcile. Zero risk to the production assembly.
3. Only after review of both: the production route, if wanted, with a fresh request.

## 8. Journal and result shapes

Journal states added: `parts_added`, `checked_out`, `uploading_checkin`, `checked_in`,
`undo_attempted`; transitions follow the same table discipline as `publication.py`
(`TRANSITIONS`), `record()` refuses jumps. Result `results/UUID.json` gains
`target.new_version_id`, `new_parts[]` with ids, `associations_declared` and
`associations_observed`, `checks` for each verification above, and the same `execution`
block as today.
