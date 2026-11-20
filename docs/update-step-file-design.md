# A revision of a published STEP file as a new version: `update_step_file`

Status: a design of 2026-11-17, written on Linux for the Windows side to read and correct. **Nothing
in it is built, and no check-out or check-in has ever been sent to Vault from these tools.** It fills in
the row `update_step_file` of `native-checkin-adapter-design.md`, section 6, and keeps to the rules of
`exchange-protocol.md`. Where it says "not known", the pilot of section 8 is what finds out.

Read from the Windows side on 2026-11-20, against the installed client by reflection and with no member
invoked: nine remarks, all taken, each marked "(Windows, 2026-11-20)" where it changed the text. Two of
them change the design: a check-out that is refused need not throw (section 6, after step 4), and
"checked out to this account" cannot be read the obvious way while the connection is made with user
id 0 (section 6, steps 1 and 5).

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
- Read the same way on 2026-11-20 (Windows, none invoked):
  - `AcquireFiles` returns `AcquireFilesResults` (`IsCancelled`, `FileResults`). Each
    `FileAcquisitionResult` has a `Status` (`NotExecuted`, `Success`, `Skipped`,
    `FileNeedsSyncOnRemoteSite`, `Exception`, `Restriction`), an `Exception` and `Restrictions` beside
    it, and `NewFileIteration`.
  - `AcquireFilesSettings` is made from a connection and a Boolean whose meaning reflection does not
    give. It has `LocalPath`, `CheckoutComment`, `CreateMetaDataFile`, `DefaultAcquisitionOption` and
    options for gathering relationships.
  - `UndoCheckoutFile` takes the iteration and a `Stream`, or a path. What the stream is for is not
    known; it may receive the file's content as it was.
  - `FileIteration` has `IsCheckedOutToCurrentUser` and `CheckedOutUserId`; `Connection` has `UserID`.
    `DocumentService.GetLatestFilesByFolderId`, which the reference-route pilot resolves and has
    rehearsed, gives `File` with `CheckedOut`, `CkOutUserId`, `Locked`, `Hidden` and
    `ControlledByChangeOrder`.
- **The connection was made with user id 0 until 2026-11-20**, and both adds ran that way: the line
  that read the id asked the credentials for a `SecurityHeader`, which they do not have; the id is
  under the credentials' `Session.User`. An add did not need it. Corrected that day in both publishing
  scripts, as a change reviewed by itself: the id is read from the session right after the sign-in,
  and a session that gives none, or 0, is refused before the folder is asked, with the journal not
  moved. Rehearsed whole against the stand-in, never run against Vault. Whether a check-out or a
  check-in works through a connection made with the id is still not known.
- In Windows PowerShell a null given to a text parameter or property of a .NET member arrives as an
  empty text (found by the rehearsal of the reference route on 2026-11-20). Where a null is meant it
  is sent as `[NullString]::Value`, or the property is not set.
- A file that is checked out shows through REST with one row more than its versions: the place of the
  check-out, listed with the next number, a check-out date and a check-in date of year 1 (seen on
  another project's file on 2026-11-17). `isCheckedOut` is true on every row of such a file and tells
  nothing of one row. `windows/Vault-Version.ps1` is the rule that says what a row is.
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
3. It is the latest version of the master (`files/{master_id}/versions`), by the rule of
   `windows/Vault-Version.ps1`: the last row that is a version checked in. No version checked in has a
   higher number.
4. It is not checked out, which is to say that no row of the master is the place of a check-out (the
   flag `isCheckedOut` is not what is asked), and it is not hidden.
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

`checking_out -> planned` is taken only when the check-out did not happen, whether the SDK threw or
returned a status that is not `Success`, and a read afterwards shows the file not checked out and its
latest version the expected one: a clean refusal, by a lifecycle rule for one. The status and the
restrictions the SDK gave are recorded with it. Everything else that goes wrong after a write was sent
is `ambiguous`. (Windows, 2026-11-20: a refused check-out need not throw.)

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

1. Sign in as for an add, and read this account's user id from the session (the credentials'
   `Session.User`). An id of 0 is refused: the run would not know its own check-out from another
   user's. The sign-in can fail for a token of the Autodesk identity service that has run out, which
   `IsLoginValid` does not foresee (2026-11-20); that is before the journal moves and costs nothing,
   and the operator has the Vault client open when the executor runs. (Windows, 2026-11-20)
2. Read through the SDK, with `DocumentService.GetLatestFilesByFolderId`, the read the reference-route
   pilot already resolves: the latest version of the master is the expected one; it is not checked out
   and not locked; its folder id and name are the expected ones. Otherwise `refused`.
3. Journal `checking_out`.
4. Check the file out: `AcquireFiles` with the option `Checkout` for the file and without a download.
   `LocalPath` is a scratch directory outside every checkout and mirror, `CreateMetaDataFile` is
   false, and the directory is listed afterwards: whether the client writes anything to disk for a
   check-out without a download is for the pilot. (Windows, 2026-11-20)
5. Read the server, whatever step 4 returned or threw, and let the read decide. `Success`, and the file
   checked out to this account: journal `checked_out`, with what the server says. No `Success`, the
   file not checked out and its latest version the expected one: `planned`, with the status and the
   restrictions recorded. Everything else: `ambiguous`. "To this account" is the file's `CkOutUserId`
   compared with the id read at step 1 by the executor itself, not `IsCheckedOutToCurrentUser`, which
   compares inside the SDK with whatever id the connection was made with. (Windows, 2026-11-20)
6. Journal `checking_in`.
7. `CheckinFile` with the iteration the check-out returned (`FileAcquisitionResult.NewFileIteration`),
   not the one read at step 2; the payload as the stream; the file's own name as the new file name,
   on purpose, so that no null has to be sent for it; `keepCheckedOut` false, the comment an add
   sends, no BOM, classification `None`, not hidden. A STEP file has no children, so it declares no
   associations. (Windows, 2026-11-20)
8. Journal `uploaded` with the ids, the version number, the size and the checksum the server returned.

If the read at step 5 cannot be made: `ambiguous`. If step 7 throws: `ambiguous`, always, and **no
undo**: the check-in may have happened, and an undo after a check-in that happened would be a write to
a file in a state nobody looked at. The undo (`UndoCheckoutFile`, with the iteration the check-out
returned; what its stream is for is not known) is sent only from `checked_out`, when the run decides
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

0. **Read only, before any write** (Windows, 2026-11-20): sign in, read this account's user id from
   the session and see that it is not 0, and read the file through the SDK as step 2 of section 6
   does.
1. **A check-out and its undo, and nothing else.** Does `AcquireFiles` with `Checkout` and no download
   need a local path, what is the Boolean of its settings, and what is written to the local path?
   What does the server record of the check-out, and what does REST show while it lasts (expected:
   the row of the place)? May this account check out a file in "Work in Progress"? What is the undo's
   stream for? After the undo: is the row of the place gone, is the latest version the old one, and
   is the list of versions what it was? Two writes, and Vault ends as it began.
2. **The update**, with the payload section 10 settles. What does the server do with the properties it
   filled in at the add, and with the comment? Is the version number 2?
3. **What the assembly of the reference route shows afterwards**, once that pilot's wrapper part and
   assembly are in the folder: which version of the STEP file the wrapper's `uses` names in Vault, and
   the wrapper's health in Inventor after the newer file is fetched and the part opened. It needs
   the reference route run live, which waits for Peter's word.

Before any of it runs live, the executor's branch is rehearsed whole against a stand-in for the SDK
types it touches, as the pilot's live branch was on 2026-11-20. The stand-in needs these types added
and held against the installed client by reflection first; the tools for both are in the evidence of
that day.

## 9. Order of building

1. On Linux: the request, the plan, the journal's states and transitions, reconcile, record and import
   for this operation, with tests against a static catalog. No PowerShell.
2. On Windows: this design read and corrected (done, 2026-11-20). Then the user id of the connection
   corrected in the two publishing scripts, as a change of its own with its own review and rehearsal;
   then the executor's branch with its dry run, rehearsed against the stand-in.
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
