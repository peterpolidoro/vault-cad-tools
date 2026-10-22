"""Planning, journaling and verification for `add_step_file` publication.

Nothing in this module writes to Vault. It validates a prepared request again, checks the
destination through a READ-ONLY catalog (an offline snapshot or the Vault REST API), refuses
collisions, keeps an idempotency journal keyed by request id and payload/destination
fingerprint, blocks automatic retries after an ambiguous mutation, and verifies a reported
result by re-downloading the exact bytes. The write itself belongs to a Windows executor
(`windows/Publish-StepToVault.ps1`) that today only resolves the SDK calls in dry-run mode.

SDK route (Vault Professional 2025, 30.4.28; verified by reflection and WSDL on 2026-10-22,
see the evidence run `2026-10-22-windows-review-fixes-vault-dryrun-01/sdk-discovery/`):

  login    WinAuthCredentials(ServerIdentities{DataServer, FileServer}, vaultName, readOnly=false,
           CredentialCache.DefaultNetworkCredentials) -> WebServiceManager(credentials)
           -> Connection(mgr, vault, userId, server, AuthenticationFlags.WindowsAuthentication)
  lookup   DocumentService.GetFolderByPath(path); DocumentService.GetLatestFilesByFolderId(folderId, true)
  add      IFileManager.AddFile(Folder parent, string filename, string comment, DateTime lastWrite,
           FileAssocParam[] null, BOM null, FileClassification.None, bool hidden=false, Stream contents)
           (SOAP equivalent: FilestoreService.UploadFilePart(Stream) -> ticket;
            DocumentService.AddUploadedFile(folderId, fileName, comment, lastWrite, null, null, None, false, ticket))
           returns File {Id = version id, MasterId, VerNum, FileSize, Cksum}
  verify   REST GET vaults/{v}/file-versions/{Id}/content, compared byte for byte with the payload

REST on this server (API 2.0.16) has no upload operation; it is used here only to read.
"""
import hashlib
import json
from pathlib import Path
import tempfile

from .api import component
from .exchange import verify_request
from .project import ExchangeError, atomic_json, digest, now, read_json

JOURNAL_SCHEMA = 1
PLAN_SCHEMA = 1
RESULT_SCHEMA = 1
STATES = ("planned", "uploading", "ambiguous", "uploaded", "verified", "failed", "refused")
RETRY_BLOCKING = ("uploading", "ambiguous")
SETTLED = ("uploaded", "verified")


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
    """Read-only lookups through the Vault Data API (GET only)."""

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
        for fv in self._pages(self.prefix + "folders/" + component(folder_id) + "/contents"):
            if not isinstance(fv, dict) or "name" not in fv:
                continue
            master = fv.get("file") if isinstance(fv.get("file"), dict) else {}
            files.append({"name": fv["name"], "version_id": str(fv.get("id")), "master_id": str(master.get("id")),
                          "version": fv.get("version"), "size": fv.get("size")})
        return files

    def download(self, version_id, destination):
        self.client.download(self.prefix + "file-versions/" + component(version_id) + "/content", destination)


class Journal:
    """Idempotency journal: request id -> fingerprint, state, attempts, returned Vault ids."""

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
                 "payload_bytes": request["payload"]["bytes"], "attempts": [], "vault_ids": None, "notes": []}
        self.data["requests"][request_id] = entry
        self.save()
        return entry

    def record(self, request_id, state=None, note=None, attempt=None, vault_ids=None):
        entry = self.entry(request_id)
        if entry is None:
            raise ExchangeError(f"Request {request_id} is not journaled")
        if state is not None:
            if state not in STATES:
                raise ExchangeError(f"Unknown journal state {state}")
            entry["state"] = state
        if note:
            entry["notes"].append({"at": now(), "note": note})
        if attempt:
            entry["attempts"].append(dict(attempt, at=now()))
        if vault_ids is not None:
            entry["vault_ids"] = vault_ids
        entry["updated_at"] = now()
        self.save()
        return entry

    def readiness(self, request_id):
        state = self.entry(request_id)["state"]
        if state in RETRY_BLOCKING:
            raise ExchangeError(f"Request {request_id} is in state '{state}': a timeout is not evidence that no file was "
                                "created; run reconcile before any retry")
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


def plan_publication(request_dir, catalog, journal, exchange=None, comment_prefix="vault-cad-tools"):
    """Re-validate a request and produce an executable, dry-run plan. Refuses vault/folder mismatch,
    name collisions (case-insensitive, `if_exists: fail`), journal identity conflicts and ambiguous retries."""
    request_dir = Path(request_dir).resolve()
    request = verify_request(request_dir)
    request_id = request["request_id"]
    fp = fingerprint(request)
    journal.begin(request, fp)
    readiness = journal.readiness(request_id)
    identity = catalog.vault_identity()
    if str(identity.get("id")) != request["vault"]["id"] or identity.get("name") != request["vault"]["name"]:
        journal.record(request_id, state="refused", note="destination vault mismatch")
        raise ExchangeError("Destination vault mismatch: the request names vault "
                            f"{request['vault']['id']} '{request['vault']['name']}' but the catalog is "
                            f"{identity.get('id')} '{identity.get('name')}'")
    destination = request["destination"]
    folder = catalog.folder_by_path(destination["folder"])
    if folder is None:
        journal.record(request_id, state="refused", note="destination folder does not exist")
        raise ExchangeError(f"Destination folder {destination['folder']} does not exist; folders are never created implicitly")
    collisions = [f for f in catalog.files_in_folder(folder["id"]) if str(f.get("name", "")).casefold() == destination["name"].casefold()]
    if collisions and readiness == "ready":
        journal.record(request_id, state="refused", note="name collision: " + ", ".join(
            f"{c['name']} (master {c.get('master_id')}, version {c.get('version_id')})" for c in collisions))
        raise ExchangeError(f"Destination already contains {collisions[0]['name']} in {destination['folder']} "
                            "(if_exists: fail; names are compared case-insensitively)")
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
            {"step": 1, "api": "Autodesk.Connectivity.WebServicesTools.WinAuthCredentials(ServerIdentities, vaultName, readOnly=false, DefaultNetworkCredentials) -> WebServiceManager -> Connection(..., AuthenticationFlags.WindowsAuthentication)",
             "arguments": {"vault": identity["name"]}},
            {"step": 2, "api": "DocumentService.GetFolderByPath(path)", "arguments": {"path": destination["folder"]},
             "expect": {"Id": folder["id"]}},
            {"step": 3, "api": "DocumentService.GetLatestFilesByFolderId(folderId, includeHidden=true)",
             "arguments": {"folderId": folder["id"]}, "expect": {"no_file_named": destination["name"]}},
            {"step": 4, "api": "IFileManager.AddFile(Folder parent, string filename, string comment, DateTime lastWrite, FileAssocParam[] null, BOM null, FileClassification.None, bool hidden=false, Stream contents)",
             "arguments": {"parent": folder["id"], "filename": destination["name"], "comment": "see plan.comment",
                           "lastWrite": "payload file mtime (UTC)", "contents": "payload bytes, sha256 " + request["payload"]["sha256"]},
             "returns": "File {Id (version id), MasterId, VerNum, FileSize, Cksum}"},
            {"step": 5, "api": "journal.record(state='uploaded', vault_ids={master_id, version_id})"},
            {"step": 6, "api": "REST GET " + "vaults/" + identity["id"] + "/file-versions/{version_id}/content",
             "verify": {"sha256": request["payload"]["sha256"], "bytes": request["payload"]["bytes"]}},
        ],
        "retry_policy": "a timeout or lost response marks the journal 'ambiguous'; no automatic retry; reconcile inspects the folder for the name and compares bytes",
        "journal": {"path": str(journal.path), "state": journal.entry(request_id)["state"]},
        "live_execution": "NOT performed here; requires windows/Publish-StepToVault.ps1 without -DryRun, which is refused until a user-selected destination and a qualified live pilot exist",
    }
    journal.record(request_id, attempt={"kind": "plan", "status": plan["status"], "folder_id": folder["id"]})
    plan["journal"]["state"] = journal.entry(request_id)["state"]
    plans = _exchange_root(request_dir, exchange) / "plans"
    atomic_json(plans / f"{request_id}.json", plan)
    plan["plan_path"] = str(plans / f"{request_id}.json")
    return plan


def mark_uploading(journal, request_id):
    """Called by an executor immediately before the mutating SDK call."""
    if journal.readiness(request_id) != "ready":
        raise ExchangeError(f"Request {request_id} is not ready for upload")
    return journal.record(request_id, state="uploading", attempt={"kind": "upload", "status": "started"})


def mark_ambiguous(journal, request_id, reason):
    """Called by an executor when the mutating call timed out or its response was lost."""
    return journal.record(request_id, state="ambiguous", note=f"ambiguous mutation: {reason}",
                          attempt={"kind": "upload", "status": "ambiguous", "reason": reason})


def reconcile_publication(request_dir, catalog, journal, workdir, acknowledge_no_file=False):
    """Resolve an 'uploading'/'ambiguous' request by inspecting Vault READ-ONLY.
    File present with identical bytes -> 'uploaded' (ids recorded). Present with different bytes -> 'refused'.
    Absent -> stays ambiguous unless the operator explicitly acknowledges that nothing was created."""
    request_dir = Path(request_dir).resolve()
    request = verify_request(request_dir)
    request_id = request["request_id"]
    entry = journal.entry(request_id)
    if entry is None or entry.get("fingerprint") != fingerprint(request):
        raise ExchangeError(f"Request {request_id} is not journaled with this fingerprint")
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


EXECUTION_FIELDS = ("executed_at", "executed_by_host", "comment_sent", "folder_id", "server_version_number", "server_file_size", "server_checksum")


def record_result(request_dir, catalog, journal, vault_ids, workdir, exchange=None, execution=None):
    """Verify a reported upload by re-downloading the exact version and write results/<id>.json.
    `execution` carries what the executor observed (EXECUTION_FIELDS: when and on which host the add ran,
    the comment actually sent, the destination folder id, the server-returned VerNum/FileSize/Cksum); it is
    recorded verbatim next to the independent verification. The project lock is never touched here; the
    Linux side ingests only `verified` results and recomputes the fingerprint from the request directory."""
    request_dir = Path(request_dir).resolve()
    request = verify_request(request_dir)
    request_id = request["request_id"]
    entry = journal.entry(request_id)
    if entry is None or entry.get("fingerprint") != fingerprint(request):
        raise ExchangeError(f"Request {request_id} is not journaled with this fingerprint")
    if not isinstance(vault_ids, dict) or not vault_ids.get("version_id") or not vault_ids.get("master_id"):
        raise ExchangeError("A result needs the actual Vault master_id and version_id")
    vault_ids = {"master_id": str(vault_ids["master_id"]), "version_id": str(vault_ids["version_id"])}
    execution = dict(execution or {})
    unknown = sorted(set(execution) - set(EXECUTION_FIELDS))
    if unknown:
        raise ExchangeError(f"Unknown execution fields: {', '.join(unknown)}")
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    target = workdir / f"{request_id}.verify.step"
    if target.exists():
        raise ExchangeError(f"Verification download target already exists: {target}")
    catalog.download(vault_ids["version_id"], target)
    downloaded_sha = digest(target)
    size = target.stat().st_size
    verified = downloaded_sha == request["payload"]["sha256"] and size == request["payload"]["bytes"]
    destination = dict(request["destination"])
    if execution.get("folder_id") is not None:
        destination["folder_id"] = str(execution["folder_id"])
    result = {
        "schema_version": RESULT_SCHEMA, "request_id": request_id, "operation": request["operation"],
        "fingerprint": fingerprint(request),
        "status": "verified" if verified else "mismatch", "verified_at": now(),
        "execution": {field: execution.get(field) for field in EXECUTION_FIELDS},
        "payload_sha256": request["payload"]["sha256"], "payload_bytes": request["payload"]["bytes"],
        "downloaded_sha256": downloaded_sha, "downloaded_bytes": size, "downloaded_path": str(target),
        "destination": destination, "vault": {"id": request["vault"]["id"], "name": request["vault"]["name"], **vault_ids},
        "provenance": dict(request["provenance"]),
    }
    journal.record(request_id, state="verified" if verified else "failed", vault_ids=vault_ids,
                   note="result verified by exact-byte re-download" if verified else "re-downloaded bytes differ from the payload",
                   attempt={"kind": "verify", "status": result["status"]})
    results = _exchange_root(request_dir, exchange) / "results"
    atomic_json(results / f"{request_id}.json", result)
    result["result_path"] = str(results / f"{request_id}.json")
    if not verified:
        raise ExchangeError(f"Re-downloaded version {vault_ids['version_id']} does not match the payload; result recorded as mismatch")
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
