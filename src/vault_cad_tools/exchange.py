"""Portable, inspectable requests. No worker executes Vault writes in this release."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

from .project import ExchangeError, atomic_json, contained_path, digest, now, portable_path, read_json, require_step


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    if result.returncode:
        raise ExchangeError("Git operation failed; the project must have a committed HEAD")
    return result.stdout


def prepare_publication(project, relative, folder, exchange, name=None):
    """Package a committed STEP deliverable as a request. Nothing is uploaded.

    In the layout with one directory per Vault file the deliverable is an authored part's
    designs/parts/<key>/part.step, and the file is named <key>.step in Vault unless `name` says otherwise
    (every deliverable there is called part.step). In the earlier layout it is a file under step/, named as it is."""
    rel = portable_path(relative)
    part_dir = None
    if project.layout:
        key, part_dir = project.authored_part(relative)
        default_name = f"{key}.step"
    else:
        if rel.parts[0] != "step":
            raise ExchangeError("Publish authored deliverables from step/")
        default_name = rel.parts[-1]
    name = name or default_name
    try:
        named = len(portable_path(name).parts) == 1 and Path(name).suffix.lower() in (".step", ".stp")
    except ExchangeError:
        named = False
    if not named:
        raise ExchangeError("The Vault file name must be one portable name ending in .step or .stp")
    if not isinstance(folder, str) or not folder.startswith("$/"):
        raise ExchangeError("Supply the exact destination Vault folder, starting with $/")
    portable_path(folder[2:])
    source = contained_path(project.root, relative)
    require_step(source)
    if part_dir is not None:
        receipt = read_json(part_dir / "receipt.json") if (part_dir / "receipt.json").is_file() else None
        built = receipt.get("step") if isinstance(receipt, dict) else None
        if not isinstance(built, dict) or built.get("sha256") != digest(source):
            raise ExchangeError("part.step is not the file its receipt.json describes; build the part again before publishing")
    commit = git(project.root, "rev-parse", "--verify", "HEAD").decode().strip()
    object_id = git(project.root, "rev-parse", "--verify", f"{commit}:{relative}").decode().strip()
    committed = git(project.root, "cat-file", "blob", object_id)
    import hashlib
    sha = digest(source)
    if hashlib.sha256(committed).hexdigest() != sha:
        raise ExchangeError("Commit this STEP file before preparing publication; LFS files are not supported yet")
    exchange = Path(exchange).resolve()
    requests = exchange / "requests"
    requests.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".preparing-", dir=requests))
    request_id = str(uuid.uuid4())
    destination = requests / request_id
    try:
        payload = staging / "payload.step"
        shutil.copyfile(source, payload)
        if digest(payload) != sha:
            raise ExchangeError("STEP changed while preparing publication")
        request = {
            "schema_version": 1, "request_id": request_id, "operation": "add_step_file",
            "created_at": now(), "vault": {"id": project.vault["id"], "name": project.vault["name"]},
            "destination": {"folder": folder.rstrip("/"), "name": name, "if_exists": "fail"},
            "payload": {"path": "payload.step", "sha256": sha, "bytes": payload.stat().st_size},
            "provenance": {"git_commit": commit, "project_path": relative,
                           "root_assembly": project.vault["root_assembly"]},
        }
        atomic_json(staging / "request.json", request)
        os.rename(staging, destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return {"request_id": request_id, "directory": str(destination), "status": "prepared_only"}


def verify_request(directory):
    directory = Path(directory).resolve()
    request = read_json(directory / "request.json")
    if not isinstance(request, dict) or request.get("schema_version") != 1 or request.get("operation") != "add_step_file":
        raise ExchangeError("Unsupported request schema or operation")
    try:
        if str(uuid.UUID(request["request_id"])) != request["request_id"]:
            raise ValueError()
        destination = request["destination"]
        if destination["if_exists"] != "fail" or not destination["folder"].startswith("$/"):
            raise ValueError()
        portable_path(destination["folder"][2:])
        if len(portable_path(destination["name"]).parts) != 1:
            raise ValueError()
        if Path(destination["name"]).suffix.lower() not in (".step", ".stp"):
            raise ValueError()
        if not all(isinstance(request["vault"][key], str) and request["vault"][key] for key in ("id", "name")):
            raise ValueError()
        info = request["payload"]
        payload = contained_path(directory, info["path"])
        require_step(payload)
        if payload.stat().st_size != info["bytes"] or digest(payload) != info["sha256"]:
            raise ExchangeError("Publication payload does not match its manifest")
    except (KeyError, TypeError, ValueError, AttributeError):
        raise ExchangeError("Malformed publication request") from None
    return request
