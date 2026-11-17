# A revision of a published STEP file as a new version: `update_step_file`

Status: a design of 2026-11-17, written on Linux for the Windows side to read and correct. **Nothing
in it is built, and no check-out or check-in has ever been sent to Vault from these tools.** It fills in
the row `update_step_file` of `native-checkin-adapter-design.md`, section 6, and keeps to the rules of
`exchange-protocol.md`. Where it says "not known", the pilot of section 8 is what finds out.

## 1. What it is for, and what it is not

A part written in a repository changes, and its STEP file in Vault should follow: a new version of the
same file, under the same master id, so that an Inventor assembly that references it sees the change. In
the sync model this is the state `repo_newer` of a STEP file that the repository owns (design 2.2).

It is not a new file, a rename or a move. It does not change the lifecycle state or the revision: the
version number goes up by one and everything else the server holds for the file stays. It never touches
a native file, and never a STEP file that was exported from a native.

## 2. What it rests on

- An add goes through `Connection.FileManager.AddFile`: verified twice (versions 994252 and 998336).
  The raw `FilestoreService.UploadFilePart` answered Vault error 155 on 2026-10-22, so a check-in that
  needs an upload ticket of its own (`DocumentService.CheckinUploadedFile`) is not the route.
- The connection's file manager offers, in the installed client 30.4.28 (listed by reflection on
  2026-11-17, none invoked): `AcquireFiles(AcquireFilesSettings)` with the option `Checkout` (the options
  are `NoAction`, `Download`, `Checkout`); `CheckinFile(FileIteration, comment, keepCheckedOut,
  lastWrite, associations, bom, copyBom, newFileName, classification, hidden, Stream)`; and
  `UndoCheckoutFile(FileIteration, Stream)`.
- A file that is checked out shows through REST as a latest version with `isCheckedOut` true, a
  check-out date, and a check-in date of year 1 (seen on another project's file on 2026-11-17).
- Both published files are in the state "Work in Progress", revision 0. Whether this account may check
  such a file out is not known; whether a released file can be checked out is not known either.
- Version ids do not change once made. Vault's checksum of a file is CRC32.

## 3. The request

`requests/UUID/request.json` as for an add, with `operation: update_step_file` and:

| Field | Meaning |
|---|---|
| `target.master_id` | the file in Vault |
| `target.expected_version_id` | the version the repository published last: the last entry of the part's `vault.json` |
| `target.expected_sha256`, `target.expected_bytes` | the bytes of that version, as that publication recorded them |
| `destination.folder`, `destination.name` | where the file is, as that publication recorded it |
| `destination.if_changed` | always `fail`: a latest version that is not the expected one refuses the request |
| `payload` | the new bytes, with size and SHA-256; they differ from the expected version's |
| `provenance` | the commit and the path, as for an add |

There is no `if_exists`. `prepare-publish` says which operation it prepares and why: a part without a
`vault.json` is an add; a part whose `part.step` at the commit has the hash of its last publication has
nothing to publish and is refused; otherwise it is an update of that publication's master. The
fingerprint of an update is made of the operation, the vault, the master id, the expected version id,
the destination and the payload's hash and size.

## 4. The plan (`plan-publish`; GET only)

It verifies the request and then reads the server. Each of these refuses the request when it does not
hold, and nothing is touched:

1. The vault is the one named.
2. `file-versions/{expected_version_id}` exists, belongs to `master_id`, has the destination's name and
   lies in the destination's folder. A file that was renamed or moved in Vault is somebody's doing that
   the repository does not know of.
3. It is the latest version of the master (`files/{master_id}/versions`): none has a higher number, and
   none is the place of a check-out.
4. It is not checked out and not hidden.
5. Its bytes, downloaded, have `expected_sha256`: what is replaced is what was published.

The plan records the lifecycle state, the revision and the number of versions it saw, and lists the SDK
calls of section 6 in order. A plan is not an execution.

The catalog gains two reads for this: a file version by its id, and the versions of a master.

## 5. The journal

An update has more places to stop than an add, because it is two writes and the first one is visible
to everyone. Its states, beside `planned`, `refused`, `ambiguous`, `uploaded`, `verified` and `failed`:

| State | Written | Means |
|---|---|---|
| `checking_out` | before the check-out is sent | a check-out may have happened |
| `checked_out` | after the server shows the file checked out to this account | the file is held; nothing is changed yet |
| `checking_in` | before the check-in is sent | a new version may exist |
| `undoing` | before the undo is sent | the check-out may be gone |

Transitions:

    planned      -> checking_out | refused | planned
    checking_out -> checked_out | planned | ambiguous
    checked_out  -> checking_in | undoing
    checking_in  -> uploaded | ambiguous
    undoing      -> planned | ambiguous
    uploaded     -> verified | failed
    ambiguous    -> planned | checked_out | uploaded | refused      (reconcile only)

`checking_out -> planned` is taken only when the server answered the check-out with an error and a read
afterwards shows the file not checked out and its latest version the expected one: a clean refusal,
by a lifecycle rule for one. Everything else that goes wrong after a write was sent is `ambiguous`.

`reconcile-publish` reads the server and settles an ambiguous update without writing:

| What the server shows | The request becomes |
|---|---|
| latest version is the expected one, not checked out | `planned` |
| the file is checked out to this account, no new version | `checked_out`; the operator continues or undoes |
| a new version, checked in, with the payload's bytes | `uploaded`, with its ids |
| anything else: other bytes, or checked out to another user | `refused`, with a note; a person decides |

A request in `checking_out`, `checked_out`, `checking_in`, `undoing` or `ambiguous` blocks every other
plan and write for the same master.

## 6. The executor (`-Live`, on Windows)

Gates, all before the sign-in: the request id, the expected folder and its id, the expected hash of the
payload, the expected master id and version id, and a journal entry `planned` with the plan's
fingerprint. Then:

1. Sign in as for an add.
2. Read through the SDK: the latest version of the master is the expected one; it is not checked out
   and not locked; its folder id and name are the expected ones. Otherwise `refused`.
3. Journal `checking_out`.
4. Check the file out: `AcquireFiles` with `Checkout` and without a download.
5. Read: the file is checked out to this account. Journal `checked_out`, with what the server says.
6. Journal `checking_in`.
7. `CheckinFile` with the payload as the stream, the same file name, `keepCheckedOut` false, the
   comment an add sends, no BOM, classification `None`, not hidden. A STEP file has no children, so it
   declares no associations.
8. Journal `uploaded` with the ids, the version number, the size and the checksum the server returned.

If step 4 throws: read, and take `planned` or `ambiguous` as section 5 says. If a read at step 5 does
not show what it should: `ambiguous`. If step 7 throws: `ambiguous`, always, and **no undo**: the check-in
may have happened, and an undo after a check-in that happened would be a write to a file in a state
nobody looked at. The undo (`UndoCheckoutFile`) is sent only from `checked_out`, when the run decides
before step 6 not to go on, or later by the operator's command. The session is signed out in `finally`.

`-DryRun` verifies the payload and resolves every member by reflection without a connection, as now.

A file left checked out is visible in Vault as checked out by the account that ran the executor. The way
back is `reconcile-publish` and then an undo, which is a write and needs the same word a write needs.

## 7. Verification and the result

`record-publish` writes `verified` only when all of these hold, each recorded as a check:

- the new version belongs to the target master, and its number is the expected version's and one more;
- the versions of the master are those the plan saw and this one;
- the file is not checked out; its name, folder, lifecycle state and revision are what the plan saw;
- the expected version is still there with its size and checksum;
- the bytes of the new version, downloaded, have the payload's size and SHA-256, and the server's size
  and CRC32 are theirs.

The result carries `operation: update_step_file`, the target, `previous_version_id`, the new ids and
the execution record. `import-publish-result` appends the publication to the part's `vault.json` under
the same master. It refuses a result whose master is not the part's, or whose `previous_version_id` is
not the version of the part's last publication.

## 8. What is not known, and the pilot that finds out

All in Peter's test folder, on the test copy published there on 2026-11-17 (master 998335, version
998336), and only when he allows each write. In this order:

1. **A check-out and its undo, and nothing else.** Does `AcquireFiles` with `Checkout` and no download
   need a local path, and what does the server record of it? May this account check out a file in
   "Work in Progress"? After the undo: is the latest version the old one, and is the list of versions
   what it was? Two writes, and Vault ends as it began.
2. **The update**, with the payload section 10 settles. What does the server do with the properties it
   filled in at the add, and with the comment? Is the version number 2?
3. **What the assembly of the reference route shows afterwards**, once that pilot's wrapper part and
   assembly are in the folder: which version of the STEP file the wrapper's `uses` names in Vault, and
   the wrapper's health in Inventor after the newer file is fetched and the part opened.

## 9. Order of building

1. On Linux: the request, the plan, the journal's states and transitions, reconcile, record and import
   for this operation, with tests against a static catalog. No PowerShell.
2. On Windows: this design read and corrected; the executor's branch with its dry run.
3. The pilot of section 8.

## 10. For Peter

- Which payload the pilot's update uses. The file in the test folder is a test copy of the monitor's
  reference model; no repository records that publication, and the part in the enclosure's repository
  should not change for a test. Proposed: the same model built with one parameter changed in a scratch
  clone of the enclosure, so that the wrapper part of the reference route has something to follow. The
  provenance wants a commit: it would be made in the scratch clone only and never pushed, if Peter
  allows an agent that. The other way is a scratch part published as a file of its own and then
  updated, which the wrapper does not see.
- During a check-out, and for as long as a run that stopped leaves it, the file shows in Vault as
  checked out by his account.
- A revision in Vault's sense, the lifecycle's letter or number, is never changed by this operation.
  Whether a change in the repository should ever do that is not asked here.
