"""Planning, journaling and verification for `add_step_file` publication.

Nothing in this module writes to Vault. It validates a prepared request again, checks the
destination through a READ-ONLY catalog (an offline snapshot or the Vault REST API), refuses
collisions, keeps an idempotency journal keyed by request id and payload/destination
fingerprint with an explicit state-transition table, blocks every retry after an ambiguous
mutation, and verifies a reported result by confirming through the catalog that the version
sits in the destination folder under the destination name and by re-downloading the exact
bytes (size, SHA-256 and Vault's CRC32 checksum). The write itself belongs to the Windows
executor `windows/Publish-StepToVault.ps1`, which drives the journal through the CLI
(`mark-uploading` before the SDK call, `mark-uploaded` or `mark-ambiguous` after it).

Journal states and the only legal transitions (M2):
  planned   -> uploading (mark_uploading) | refused (plan refusal) | planned (re-plan)
  uploading -> uploaded (mark_uploaded) | ambiguous (mark_ambiguous) | failed (mark_failed, pre-upload error)
  ambiguous -> uploaded | refused | planned          (reconcile_publication only)
  uploaded  -> verified | failed                    (record_result only)
  refused   -> planned (re-plan after the cause is fixed)
  verified, failed: terminal (manual review; nothing is retried automatically)
The executor journal lives on the executing host (P1); the Linux side ingests `results/`
only and recomputes the fingerprint from the request directory.

SDK route (Vault Professional 2025, 30.4.28; verified by reflection, WSDL and a read-only
sign-in probe on 2026-10-22): WinAuthCredentials(ServerIdentities, vault, readOnly,
DefaultNetworkCredentials) -> WebServiceManager; DocumentService.GetFolderByPath /
GetLatestFilesByFolderId(folderId, includeHidden=true); FilestoreService.UploadFilePart(Stream)
-> ticket; DocumentService.AddUploadedFile(folderId, fileName, comment, lastWrite, null, null,
FileClassification.None, hidden=false, ByteArray ticket) -> File {Id, MasterId, VerNum,
FileSize, Cksum}. Vault's Cksum equals zlib CRC32 of the bytes (probe: 1252855278 on both
sides). REST (API 2.0.16) has no upload; it is used here only to read and to re-download.
"""
import hashlib
import json
from pathlib import Path
import uuid
import tempfile
import zlib

from .api import component
from .exchange import verify_request
from .project import ExchangeError, atomic_json, contained_path, digest, now, portable_path, read_json

JOURNAL_SCHEMA = 1
PLAN_SCHEMA = 1
RESULT_SCHEMA = 1
STATES = ("planned", "uploading", "ambiguous", "uploaded", "verified", "failed", "refused")
TRANSITIONS = {
    "planned": {"uploading", "refused", "planned"},
    "uploading": {"uploaded", "ambiguous", "failed"},
    "ambiguous": {"uploaded", "refused", "planned"},
    "uploaded": {"verified", "failed"},
    "refused": {"planned", "refused"},
    "verified": set(),
    "failed": set(),
}
RETRY_BLOCKING = ("uploading", "ambiguous")
SETTLED = ("uploaded", "verified")
TERMINAL_FAILED = ("failed",)
EXECUTION_FIELDS = {
    "executed_at": str, "executed_by_host": str, "comment_sent": str, "folder_id": str,
    "server_version_number": int, "server_file_size": int, "server_checksum": int,
}


def fingerprint(request):
    """Identity of WHAT would be published WHERE; independent of request id and timestamps."""
    material = {
        "operation": request["operation"],
        "vault": {"id": request["vault"]["id"], "name": request["vault"]["name"]},
        "destination": {"folder": request["destination"]["folder"], "name": request["destination"]["name"],
                        "if_exists": request["destination"]["if_exists"]},
        "payload": {"sha256": request["payload"]["sha256"], "bytes": request["payload"]["bytes"]},
    }
    return hashlib.sha256(json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def crc32_of(path):
    value = 0
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value = zlib.crc32(chunk, value)
    return value & 0xFFFFFFFF


def normalize_execution(execution):
    """Typed, closed set of executor observations (L2). Non-dict input is refused."""
    if execution is None:
        return {}
    if not isinstance(execution, dict):
        raise ExchangeError("The execution record must be a JSON object")
    unknown = sorted(set(execution) - set(EXECUTION_FIELDS))
    if unknown:
        raise ExchangeError(f"Unknown execution fields: {', '.join(unknown)}")
    result = {}
    for field, kind in EXECUTION_FIELDS.items():
        value = execution.get(field)
        if value is None:
            continue
        if kind is int:
            if isinstance(value, bool) or not isinstance(value, int):
                if isinstance(value, str) and value.strip().lstrip("-").isdigit():
                    value = int(value)
                else:
                    raise ExchangeError(f"Execution field {field} must be an integer")
        elif kind is str:
            if not isinstance(value, (str, int)) or isinstance(value, bool):
                raise ExchangeError(f"Execution field {field} must be a string")
            value = str(value)
        result[field] = value
    return result


class Catalog:
    """Read-only view of a vault. Implementations must never mutate anything."""

    def vault_identity(self):
        raise NotImplementedError

    def folder_by_path(self, path):
        raise NotImplementedError

    def files_in_folder(self, folder_id):
        raise NotImplementedError

    def download(self, version_id, destination):
        raise NotImplementedError


class StaticCatalog(Catalog):
    """Offline snapshot for tests and dry runs:
    {"vault": {"id": "28", "name": "..."}, "folders": [{"id": "7", "full_name": "$/A/B",
      "files": [{"name": "x.step", "version_id": "901", "master_id": "900", "version": 1, "size": 123}]}]}
    `downloads` maps version ids to bytes for re-download verification."""

    def __init__(self, snapshot, downloads=None):
        if not isinstance(snapshot, dict) or not isinstance(snapshot.get("folders"), list):
            raise ExchangeError("Catalog snapshot must contain a folders list")
        self.snapshot = snapshot
        self.downloads = downloads or {}

    def vault_identity(self):
        vault = self.snapshot.get("vault") or {}
        return {"id": str(vault.get("id")), "name": vault.get("name")}

    def folder_by_path(self, path):
        for folder in self.snapshot["folders"]:
            if str(folder.get("full_name", "")).rstrip("/").casefold() == path.rstrip("/").casefold():
                return {"id": str(folder["id"]), "full_name": folder["full_name"]}
        return None

    def files_in_folder(self, folder_id):
        for folder in self.snapshot["folders"]:
            if str(folder.get("id")) == str(folder_id):
                return [dict(f, version_id=str(f["version_id"]), master_id=str(f.get("master_id")))
                        for f in folder.get("files", [])]
        raise ExchangeError(f"Unknown folder id {folder_id}")

    def download(self, version_id, destination):
        if str(version_id) not in self.downloads:
            raise ExchangeError(f"Catalog has no content for version {version_id}")
        destination = Path(destination)
        if destination.exists():
            raise ExchangeError(f"Download destination already exists: {destination}")
        destination.write_bytes(self.downloads[str(version_id)])


class RestCatalog(Catalog):
    """Read-only lookups through the Vault Data API (GET only); hidden files included (P3)."""

    def __init__(self, client, vault_id, page_limit=100, max_pages=1000):
        self.client = client
        self.vault_id = str(vault_id)
        self.prefix = "vaults/" + component(vault_id) + "/"
        self.page_limit = page_limit
        self.max_pages = max_pages

    def _pages(self, path, query=None):
        cursor = None
        for _ in range(self.max_pages):
            params = dict(query or {})
            params["limit"] = self.page_limit
            if cursor:
                params["cursorState"] = cursor
            data = self.client.json(path, query=params)
            results = data.get("results") if isinstance(data, dict) else None
            if not isinstance(results, list):
                raise ExchangeError(f"Unexpected Vault response shape for {path}")
            yield from results
            pagination = data.get("pagination") if isinstance(data.get("pagination"), dict) else {}
            next_cursor = pagination.get("cursorState")
            if not results or not next_cursor or next_cursor == cursor:
                return
            cursor = next_cursor
        raise ExchangeError(f"Vault listing of {path} did not terminate within {self.max_pages} pages")

    def vault_identity(self):
        vaults = self.client.json("vaults")
        entries = vaults.get("results", vaults) if isinstance(vaults, dict) else vaults
        for entry in entries or []:
            if isinstance(entry, dict) and str(entry.get("id")) == self.vault_id:
                return {"id": str(entry["id"]), "name": entry.get("name")}
        raise ExchangeError(f"Vault id {self.vault_id} is not listed by the server")

    def folder_by_path(self, path):
        if not path.startswith("$/"):
            raise ExchangeError("Vault folder paths start with $/")
        current = self.client.json(self.prefix + "folders/root")
        if not isinstance(current, dict) or "id" not in current:
            raise ExchangeError("Unexpected root folder response")
        walked = "$"
        for part in [p for p in path[2:].split("/") if p]:
            match = None
            for sub in self._pages(self.prefix + "folders/" + component(current["id"]) + "/sub-folders"):
                if isinstance(sub, dict) and str(sub.get("name", "")).casefold() == part.casefold():
                    match = sub
                    break
            if match is None:
                return None
            walked += "/" + str(match.get("name"))
            full = match.get("fullName")
            if full and str(full).casefold() != walked.casefold():
                raise ExchangeError(f"Folder path mismatch while walking: server says {full!r}, expected {walked!r}")
            current = match
        return {"id": str(current["id"]), "full_name": current.get("fullName", walked)}

    def files_in_folder(self, folder_id):
        files = []
        for fv in self._pages(self.prefix + "folders/" + component(folder_id) + "/contents", {"option[includeHidden]": "true"}):
            if not isinstance(fv, dict) or "name" not in fv:
                continue
            master = fv.get("file") if isinstance(fv.get("file"), dict) else {}
            files.append({"name": fv["name"], "version_id": str(fv.get("id")), "master_id": str(master.get("id")),
                          "version": fv.get("version"), "size": fv.get("size"), "hidden": fv.get("isHidden")})
        return files

    def download(self, version_id, destination):
        self.client.download(self.prefix + "file-versions/" + component(version_id) + "/content", destination)


class Journal:
    """Idempotency journal: request id -> fingerprint, state, attempts, returned Vault ids.
    Lives on the executing host; every state change must be a legal transition."""

    def __init__(self, path):
        self.path = Path(path)
        if self.path.exists():
            data = read_json(self.path)
            if not isinstance(data, dict) or data.get("schema_version") != JOURNAL_SCHEMA or not isinstance(data.get("requests"), dict):
                raise ExchangeError(f"Unsupported publication journal: {self.path}")
        else:
            data = {"schema_version": JOURNAL_SCHEMA, "requests": {}}
        self.data = data

    def entry(self, request_id):
        return self.data["requests"].get(request_id)

    def save(self):
        atomic_json(self.path, self.data)

    def begin(self, request, request_fingerprint):
        request_id = request["request_id"]
        existing = self.entry(request_id)
        if existing is not None:
            if existing.get("fingerprint") != request_fingerprint:
                raise ExchangeError(f"Journal identity conflict: request {request_id} was journaled with a different "
                                    "destination/payload fingerprint; refusing to plan or execute it")
            return existing
        entry = {"fingerprint": request_fingerprint, "state": "planned", "created_at": now(), "updated_at": now(),
                 "destination": dict(request["destination"]), "payload_sha256": request["payload"]["sha256"],
                 "payload_bytes": request["payload"]["bytes"], "attempts": [], "vault_ids": None, "execution": None, "notes": []}
        self.data["requests"][request_id] = entry
        self.save()
        return entry

    def record(self, request_id, state=None, note=None, attempt=None, vault_ids=None, execution=None):
        entry = self.entry(request_id)
        if entry is None:
            raise ExchangeError(f"Request {request_id} is not journaled")
        if state is not None:
            if state not in STATES:
                raise ExchangeError(f"Unknown journal state {state}")
            current = entry["state"]
            if state not in TRANSITIONS[current]:
                raise ExchangeError(f"Illegal journal transition {current} -> {state} for request {request_id}")
            if state != current:
                entry.setdefault("history", []).append({"at": now(), "from": current, "to": state})
            entry["state"] = state
        if note:
            entry["notes"].append({"at": now(), "note": note})
        if attempt:
            entry["attempts"].append(dict(attempt, at=now()))
        if vault_ids is not None:
            entry["vault_ids"] = vault_ids
        if execution is not None:
            entry["execution"] = execution
        entry["updated_at"] = now()
        self.save()
        return entry

    def readiness(self, request_id):
        state = self.entry(request_id)["state"]
        if state in RETRY_BLOCKING:
            raise ExchangeError(f"Request {request_id} is in state '{state}': a timeout is not evidence that no file was "
                                "created; run reconcile before any retry")
        if state in TERMINAL_FAILED:
            raise ExchangeError(f"Request {request_id} is in state 'failed': manual review required; nothing is retried automatically")
        if state in SETTLED:
            return "already_" + state
        return "ready"


def _exchange_root(request_dir, exchange=None):
    request_dir = Path(request_dir).resolve()
    if exchange:
        return Path(exchange).resolve()
    if request_dir.parent.name == "requests":
        return request_dir.parent.parent
    raise ExchangeError("Cannot infer the exchange root; pass it explicitly")


def _journaled_request(request_dir, journal):
    request_dir = Path(request_dir).resolve()
    request = verify_request(request_dir)
    entry = journal.entry(request["request_id"])
    if entry is None or entry.get("fingerprint") != fingerprint(request):
        raise ExchangeError(f"Request {request['request_id']} is not journaled with this fingerprint")
    return request_dir, request, entry


def plan_publication(request_dir, catalog, journal, exchange=None, comment_prefix="vault-cad-tools"):
    """Re-validate a request and produce an executable, dry-run plan. Refuses vault/folder mismatch,
    name collisions (case-insensitive, hidden included, `if_exists: fail`), journal identity conflicts,
    ambiguous retries and failed requests."""
    request_dir = Path(request_dir).resolve()
    request = verify_request(request_dir)
    request_id = request["request_id"]
    fp = fingerprint(request)
    journal.begin(request, fp)
    readiness = journal.readiness(request_id)
    identity = catalog.vault_identity()
    if str(identity.get("id")) != request["vault"]["id"] or identity.get("name") != request["vault"]["name"]:
        if readiness == "ready":
            journal.record(request_id, state="refused", note="destination vault mismatch")
        raise ExchangeError("Destination vault mismatch: the request names vault "
                            f"{request['vault']['id']} '{request['vault']['name']}' but the catalog is "
                            f"{identity.get('id')} '{identity.get('name')}'")
    destination = request["destination"]
    folder = catalog.folder_by_path(destination["folder"])
    if folder is None:
        if readiness == "ready":
            journal.record(request_id, state="refused", note="destination folder does not exist")
        raise ExchangeError(f"Destination folder {destination['folder']} does not exist; folders are never created implicitly")
    collisions = [f for f in catalog.files_in_folder(folder["id"]) if str(f.get("name", "")).casefold() == destination["name"].casefold()]
    if collisions and readiness == "ready":
        journal.record(request_id, state="refused", note="name collision: " + ", ".join(
            f"{c['name']} (master {c.get('master_id')}, version {c.get('version_id')})" for c in collisions))
        raise ExchangeError(f"Destination already contains {collisions[0]['name']} in {destination['folder']} "
                            "(if_exists: fail; names are compared case-insensitively, hidden files included)")
    payload = request_dir / request["payload"]["path"]
    plan = {
        "schema_version": PLAN_SCHEMA, "request_id": request_id, "operation": request["operation"],
        "generated_at": now(), "dry_run": True,
        "status": "planned_not_executed" if readiness == "ready" else readiness,
        "request_directory": str(request_dir), "fingerprint": fp,
        "vault": {"id": identity["id"], "name": identity["name"]},
        "destination": {"folder": destination["folder"], "folder_id": folder["id"],
                        "folder_full_name": folder.get("full_name"), "name": destination["name"], "if_exists": destination["if_exists"]},
        "payload": {"path": str(payload), "sha256": request["payload"]["sha256"], "bytes": request["payload"]["bytes"]},
        "comment": f"{comment_prefix} request {request_id}; git {request['provenance']['git_commit']}; "
                   f"{request['provenance']['project_path']}",
        "existing_files_in_folder": len(collisions),
        "sdk_calls": [] if readiness != "ready" else [
            {"step": 1, "api": "WinAuthCredentials(ServerIdentities, vaultName, readOnly=false, DefaultNetworkCredentials) -> WebServiceManager",
             "arguments": {"vault": identity["name"]}},
            {"step": 2, "api": "DocumentService.GetFolderByPath(path)", "arguments": {"path": destination["folder"]},
             "expect": {"Id": folder["id"]}},
            {"step": 3, "api": "DocumentService.GetLatestFilesByFolderId(folderId, includeHidden=true)",
             "arguments": {"folderId": folder["id"]}, "expect": {"no_file_named": destination["name"]}},
            {"step": 4, "api": "journal: mark-uploading (planned -> uploading) BEFORE the mutating call"},
            {"step": 5, "api": "FilestoreService.UploadFilePart(Stream) -> ticket; DocumentService.AddUploadedFile(folderId, fileName, comment, lastWrite, null, null, FileClassification.None, hidden=false, ByteArray ticket)",
             "arguments": {"folderId": folder["id"], "fileName": destination["name"], "comment": "see plan.comment",
                           "lastWrite": "payload file mtime (UTC)", "contents": "payload bytes, sha256 " + request["payload"]["sha256"]},
             "returns": "File {Id (version id), MasterId, VerNum, FileSize, Cksum}",
             "on_exception": "journal: mark-ambiguous; no automatic retry; reconcile-publish inspects the folder"},
            {"step": 6, "api": "journal: mark-uploaded with File.MasterId / File.Id and the execution record"},
            {"step": 7, "api": "record-publish: catalog confirms the version sits in the folder under the name; REST GET "
                               + "vaults/" + identity["id"] + "/file-versions/{version_id}/content compared by size, SHA-256 and CRC32",
             "verify": {"sha256": request["payload"]["sha256"], "bytes": request["payload"]["bytes"]}},
        ],
        "retry_policy": "a timeout or lost response marks the journal 'ambiguous'; no automatic retry; reconcile inspects the folder for the name and compares bytes",
        "journal": {"path": str(journal.path), "state": journal.entry(request_id)["state"]},
        "live_execution": "NOT performed here; windows/Publish-StepToVault.ps1 -Live must be gated to this request id, folder id and payload hash",
    }
    journal.record(request_id, attempt={"kind": "plan", "status": plan["status"], "folder_id": folder["id"]})
    plan["journal"]["state"] = journal.entry(request_id)["state"]
    plans = _exchange_root(request_dir, exchange) / "plans"
    atomic_json(plans / f"{request_id}.json", plan)
    plan["plan_path"] = str(plans / f"{request_id}.json")
    return plan


def mark_uploading(journal, request_id):
    """Executor, immediately before the mutating SDK call."""
    if journal.readiness(request_id) != "ready":
        raise ExchangeError(f"Request {request_id} is not ready for upload")
    return journal.record(request_id, state="uploading", attempt={"kind": "upload", "status": "started"})


def mark_uploaded(journal, request_id, vault_ids, execution=None):
    """Executor, after the SDK returned the new file's ids."""
    if not isinstance(vault_ids, dict) or not vault_ids.get("version_id") or not vault_ids.get("master_id"):
        raise ExchangeError("mark_uploaded needs the actual Vault master_id and version_id")
    ids = {"master_id": str(vault_ids["master_id"]), "version_id": str(vault_ids["version_id"])}
    return journal.record(request_id, state="uploaded", vault_ids=ids, execution=normalize_execution(execution),
                          attempt={"kind": "upload", "status": "returned_ids", **ids})


def mark_ambiguous(journal, request_id, reason):
    """Executor, when the mutating call timed out, threw or its response was lost."""
    return journal.record(request_id, state="ambiguous", note=f"ambiguous mutation: {reason}",
                          attempt={"kind": "upload", "status": "ambiguous", "reason": reason})


def mark_failed(journal, request_id, reason):
    """Executor, for a definite failure BEFORE any byte reached the file store (pre-checks after mark_uploading)."""
    return journal.record(request_id, state="failed", note=f"failed before upload: {reason}",
                          attempt={"kind": "upload", "status": "failed", "reason": reason})


def reconcile_publication(request_dir, catalog, journal, workdir, acknowledge_no_file=False):
    """Resolve an 'uploading'/'ambiguous' request by inspecting Vault READ-ONLY.
    File present with identical bytes -> 'uploaded' (ids recorded). Present with different bytes -> 'refused'.
    Absent -> stays ambiguous unless the operator explicitly acknowledges that nothing was created."""
    request_dir, request, entry = _journaled_request(request_dir, journal)
    request_id = request["request_id"]
    if entry["state"] not in RETRY_BLOCKING:
        return {"request_id": request_id, "state": entry["state"], "action": "none"}
    folder = catalog.folder_by_path(request["destination"]["folder"])
    if folder is None:
        raise ExchangeError("Destination folder vanished; manual inspection required")
    name = request["destination"]["name"]
    found = [f for f in catalog.files_in_folder(folder["id"]) if str(f.get("name", "")).casefold() == name.casefold()]
    if not found:
        if acknowledge_no_file:
            journal.record(request_id, state="planned", note="reconcile: no file in destination; operator acknowledged; retry permitted")
            return {"request_id": request_id, "state": "planned", "action": "retry_permitted"}
        journal.record(request_id, note="reconcile: no file in destination; retry NOT permitted without acknowledgement")
        return {"request_id": request_id, "state": "ambiguous", "action": "awaiting_acknowledgement"}
    candidate = found[0]
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    target = workdir / f"{request_id}.reconcile.step"
    if target.exists():
        raise ExchangeError(f"Reconcile download target already exists: {target}")
    catalog.download(candidate["version_id"], target)
    same = digest(target) == request["payload"]["sha256"] and target.stat().st_size == request["payload"]["bytes"]
    if same:
        ids = {"master_id": candidate.get("master_id"), "version_id": candidate["version_id"], "version": candidate.get("version")}
        journal.record(request_id, state="uploaded", vault_ids=ids, note="reconcile: destination file has the exact payload bytes")
        return {"request_id": request_id, "state": "uploaded", "action": "recovered", "vault_ids": ids, "downloaded": str(target)}
    journal.record(request_id, state="refused", note=f"reconcile: {candidate['name']} exists with DIFFERENT bytes (collision after ambiguous mutation)")
    return {"request_id": request_id, "state": "refused", "action": "collision_after_ambiguous", "downloaded": str(target)}


def record_result(request_dir, catalog, journal, vault_ids, workdir, exchange=None, execution=None):
    """Verify a reported upload (M1) and write results/<id>.json. Requires journal state `uploaded`.
    Verified only when: the destination folder resolves (and matches the executor's folder id when given),
    the catalog lists the reported version in that folder under the destination name (case-insensitive,
    hidden included), the re-downloaded bytes match the payload's size and SHA-256, and the executor's
    server size / CRC32 checksum (when given) match the download. Anything else is `mismatch` -> `failed`.
    The project lock is never touched here; the Linux side ingests only `verified` results."""
    request_dir, request, entry = _journaled_request(request_dir, journal)
    request_id = request["request_id"]
    if entry["state"] != "uploaded":
        raise ExchangeError(f"Request {request_id} is in state '{entry['state']}'; results can be recorded only from "
                            "'uploaded' (after mark-uploaded or a reconcile that recovered the file)")
    if not isinstance(vault_ids, dict) or not vault_ids.get("version_id") or not vault_ids.get("master_id"):
        raise ExchangeError("A result needs the actual Vault master_id and version_id")
    vault_ids = {"master_id": str(vault_ids["master_id"]), "version_id": str(vault_ids["version_id"])}
    if entry.get("vault_ids") and (str(entry["vault_ids"].get("version_id")) != vault_ids["version_id"]
                                   or str(entry["vault_ids"].get("master_id")) != vault_ids["master_id"]):
        raise ExchangeError("Reported ids differ from the ids journaled at upload time")
    execution = normalize_execution(execution if execution is not None else entry.get("execution"))
    destination = dict(request["destination"])
    checks = {}
    folder = catalog.folder_by_path(destination["folder"])
    checks["folder_resolved"] = folder is not None
    if folder is not None:
        destination["folder_id"] = folder["id"]
        checks["folder_id_matches_execution"] = (str(execution["folder_id"]) == folder["id"]) if execution.get("folder_id") is not None else None
        listing = catalog.files_in_folder(folder["id"])
        listed = [f for f in listing if str(f.get("version_id")) == vault_ids["version_id"]]
        checks["version_listed_in_folder"] = bool(listed)
        checks["listed_under_destination_name"] = bool(listed) and str(listed[0].get("name", "")).casefold() == destination["name"].casefold()
        checks["listed_master_matches"] = bool(listed) and str(listed[0].get("master_id")) == vault_ids["master_id"]
        catalog_size = listed[0].get("size") if listed else None
    else:
        catalog_size = None
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    target = workdir / f"{request_id}.verify.step"
    if target.exists():
        raise ExchangeError(f"Verification download target already exists: {target}")
    catalog.download(vault_ids["version_id"], target)
    downloaded_sha = digest(target)
    size = target.stat().st_size
    crc = crc32_of(target)
    checks["sha256_matches_payload"] = downloaded_sha == request["payload"]["sha256"]
    checks["size_matches_payload"] = size == request["payload"]["bytes"]
    checks["catalog_size_matches_download"] = (int(catalog_size) == size) if catalog_size is not None else None
    checks["server_file_size_matches_download"] = (execution["server_file_size"] == size) if execution.get("server_file_size") is not None else None
    checks["server_checksum_matches_download_crc32"] = ((execution["server_checksum"] & 0xFFFFFFFF) == crc) if execution.get("server_checksum") is not None else None
    verified = all(v is not False for v in checks.values()) and checks["folder_resolved"] and checks["version_listed_in_folder"] \
        and checks["listed_under_destination_name"] and checks["sha256_matches_payload"] and checks["size_matches_payload"]
    result = {
        "schema_version": RESULT_SCHEMA, "request_id": request_id, "operation": request["operation"],
        "fingerprint": fingerprint(request),
        "status": "verified" if verified else "mismatch", "verified_at": now(), "checks": checks,
        "execution": {field: execution.get(field) for field in EXECUTION_FIELDS},
        "payload_sha256": request["payload"]["sha256"], "payload_bytes": request["payload"]["bytes"],
        "downloaded_sha256": downloaded_sha, "downloaded_bytes": size, "downloaded_crc32": crc, "downloaded_path": str(target),
        "destination": destination, "vault": {"id": request["vault"]["id"], "name": request["vault"]["name"], **vault_ids},
        "provenance": dict(request["provenance"]),
    }
    journal.record(request_id, state="verified" if verified else "failed", vault_ids=vault_ids,
                   note="result verified: folder listing, exact bytes, size and checksum agree" if verified
                   else "result mismatch: " + ", ".join(k for k, v in checks.items() if v is False),
                   attempt={"kind": "verify", "status": result["status"]})
    results = _exchange_root(request_dir, exchange) / "results"
    atomic_json(results / f"{request_id}.json", result)
    result["result_path"] = str(results / f"{request_id}.json")
    if not verified:
        raise ExchangeError(f"Result for version {vault_ids['version_id']} recorded as mismatch: "
                            + ", ".join(k for k, v in checks.items() if v is False))
    return result


def write_catalog_snapshot(path, catalog, folder_paths):
    """Save a READ-ONLY catalog snapshot (vault identity, folders, their files) for offline planning."""
    identity = catalog.vault_identity()
    folders = []
    for folder_path in folder_paths:
        folder = catalog.folder_by_path(folder_path)
        if folder is None:
            folders.append({"full_name": folder_path, "missing": True})
            continue
        folders.append({"id": folder["id"], "full_name": folder.get("full_name", folder_path), "files": catalog.files_in_folder(folder["id"])})
    snapshot = {"schema_version": 1, "captured_at": now(), "vault": identity, "folders": [f for f in folders if not f.get("missing")],
                "missing_folders": [f["full_name"] for f in folders if f.get("missing")]}
    atomic_json(path, snapshot)
    return snapshot


def temporary_workdir(prefix="vault-cad-verify-"):
    return Path(tempfile.mkdtemp(prefix=prefix))


# ----------------------------------------------------------------- Linux ingestion

REQUIRED_RESULT_CHECKS = ("folder_resolved", "version_listed_in_folder", "listed_under_destination_name",
                          "listed_master_matches", "sha256_matches_payload", "size_matches_payload")


def import_publication_result(project, result_path, exchange=None):
    """Record a `verified` publication result in the project lock (`publications`).

    The result file is data from another host. Before anything is recorded it is
    re-checked here: schema and status, the request directory it names (re-verified,
    payload re-hashed), the fingerprint recomputed from that request, payload and
    re-download hashes and sizes, destination/vault/provenance identity against the
    request, every verification check true, a typed execution record, and the
    committed blob at the provenance commit still hashing to the payload. The journal
    is never read. Repeating the import of an identical result is a no-op; a different
    result under the same request id, or the same Vault version under another request,
    is refused."""
    import subprocess
    result_path = Path(result_path).resolve()
    result = read_json(result_path)
    if not isinstance(result, dict) or result.get("schema_version") != RESULT_SCHEMA or result.get("operation") != "add_step_file":
        raise ExchangeError("Unsupported publication result schema or operation")
    if result.get("status") != "verified":
        raise ExchangeError(f"Only verified results are imported; this one is {result.get('status')!r}")
    request_id = result.get("request_id")
    try:
        if not isinstance(request_id, str) or str(uuid.UUID(request_id)) != request_id:
            raise ValueError()
    except ValueError:
        raise ExchangeError("Result names an invalid request id") from None
    if exchange:
        root = Path(exchange).resolve()
    elif result_path.parent.name == "results":
        root = result_path.parent.parent
    else:
        raise ExchangeError("Cannot infer the exchange root from the result path; pass --exchange")
    if result_path.name != f"{request_id}.json":
        raise ExchangeError("Result file name does not match its request id")
    request_dir = root / "requests" / request_id
    if not request_dir.is_dir():
        raise ExchangeError(f"Request directory missing for {request_id}")
    request = verify_request(request_dir)
    if request["request_id"] != request_id:
        raise ExchangeError("Request directory holds a different request id")
    if result.get("fingerprint") != fingerprint(request):
        raise ExchangeError("Result fingerprint differs from the fingerprint recomputed from the request")
    payload = request["payload"]
    if result.get("payload_sha256") != payload["sha256"] or result.get("payload_bytes") != payload["bytes"]:
        raise ExchangeError("Result payload identity differs from the request")
    if result.get("downloaded_sha256") != payload["sha256"] or result.get("downloaded_bytes") != payload["bytes"]:
        raise ExchangeError("Result re-download does not match the payload")
    destination = result.get("destination")
    if not isinstance(destination, dict) or any(destination.get(k) != request["destination"][k] for k in ("folder", "name", "if_exists")):
        raise ExchangeError("Result destination differs from the request")
    folder_id = destination.get("folder_id")
    if not isinstance(folder_id, str) or not folder_id.strip():
        raise ExchangeError("Result destination lacks the Vault folder id")
    vault = result.get("vault")
    if (not isinstance(vault, dict) or vault.get("id") != request["vault"]["id"] or vault.get("name") != request["vault"]["name"]
            or not all(isinstance(vault.get(k), str) and vault[k].strip() for k in ("master_id", "version_id"))):
        raise ExchangeError("Result vault identity or ids are missing or differ from the request")
    if result.get("provenance") != request["provenance"]:
        raise ExchangeError("Result provenance differs from the request")
    checks = result.get("checks")
    if not isinstance(checks, dict) or any(v is False for v in checks.values()) or any(checks.get(k) is not True for k in REQUIRED_RESULT_CHECKS):
        raise ExchangeError("Result verification checks are incomplete or not all true")
    execution = normalize_execution(result.get("execution"))
    if execution.get("folder_id") not in (None, folder_id):
        raise ExchangeError("Executor folder id differs from the result destination")
    for key in ("executed_at", "executed_by_host"):
        if not execution.get(key):
            raise ExchangeError(f"Execution record lacks {key}")
    provenance = request["provenance"]
    rel = portable_path(provenance["project_path"])
    if rel.parts[0] != "step":
        raise ExchangeError("Published deliverables come from step/")
    contained_path(project.root, provenance["project_path"])
    try:
        blob = subprocess.run(["git", "-C", str(project.root), "cat-file", "blob", f"{provenance['git_commit']}:{provenance['project_path']}"],
                              capture_output=True, check=True).stdout
    except subprocess.CalledProcessError:
        raise ExchangeError("The provenance commit or path is not in this project's Git history") from None
    if hashlib.sha256(blob).hexdigest() != payload["sha256"]:
        raise ExchangeError("The committed deliverable at the provenance commit does not hash to the payload")
    working = project.root / provenance["project_path"]
    entry = {
        "request_id": request_id, "operation": "add_step_file", "project_path": provenance["project_path"],
        "sha256": payload["sha256"], "bytes": payload["bytes"], "git_commit": provenance["git_commit"],
        "vault": {"id": vault["id"], "name": vault["name"], "master_id": vault["master_id"], "version_id": vault["version_id"],
                  "version": execution.get("server_version_number")},
        "destination": {"folder": destination["folder"], "folder_id": folder_id, "name": destination["name"]},
        "executed_at": execution["executed_at"], "executed_by_host": execution["executed_by_host"],
        "comment_sent": execution.get("comment_sent"), "verified_at": result.get("verified_at"),
        "fingerprint": result["fingerprint"], "result_sha256": digest(result_path),
        "working_tree_matches_at_import": working.is_file() and digest(working) == payload["sha256"],
    }
    with project.transaction():
        publications = project.lock["publications"]
        for existing in publications:
            if not isinstance(existing, dict):
                raise ExchangeError("Corrupt publications list in vault-lock.json")
            if existing.get("request_id") == request_id:
                same = {k: v for k, v in existing.items() if k != "imported_at"} == entry
                if same:
                    return {"request_id": request_id, "changed": False, "vault": entry["vault"]}
                raise ExchangeError(f"Request {request_id} is already recorded with different data; refusing to overwrite")
            ev = existing.get("vault") or {}
            if ev.get("id") == vault["id"] and ev.get("version_id") == vault["version_id"]:
                raise ExchangeError(f"Vault version {vault['version_id']} is already recorded under request {existing.get('request_id')}")
        publications.append(dict(entry, imported_at=now()))
        atomic_json(project.lock_path, project.lock)
    return {"request_id": request_id, "changed": True, "vault": entry["vault"], "project_path": entry["project_path"]}
