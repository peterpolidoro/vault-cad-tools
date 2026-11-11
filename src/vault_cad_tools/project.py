"""Project metadata and guarded imports; no Autodesk dependencies."""
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
import tomllib
from urllib.parse import urlsplit


class ExchangeError(Exception):
    """A user-actionable failure, safe to display without a traceback."""


# vault-lock.json comes in two shapes. The earlier one (1) lists imported STEP files by path, with their evidence,
# and the publications with theirs. The index (2) belongs to the layout specified in mechanical-cad: one directory
# per Vault file under references/, authored parts under designs/parts/, and a lock that only repeats what those
# directories say. A project is in one layout or the other; the earlier one goes when the last project has moved.
LOCK_EARLIER = 1
LOCK_INDEX = 2
SHA256 = re.compile(r"[a-f0-9]{64}")
KEY = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*(?:@[a-z0-9]+(?:-[a-z0-9]+)*)?")
COMPONENT_ROOT = {"part": "references/parts", "assembly": "references/assemblies"}
PUBLICATION_FIELDS = ("request_id", "master_id", "version_id", "git_commit")


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        raise ExchangeError(f"Cannot read JSON file {path}: {exc}") from exc


def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".vault-cad-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def portable_path(value):
    if not isinstance(value, str) or not value:
        raise ExchangeError("Expected a nonempty relative path")
    parts = value.split("/")
    for part in parts:
        if (not part or part in (".", "..") or part.endswith((" ", "."))
                or re.search(r'[<>:"\\|?*\x00-\x1f]', part)
                or re.fullmatch(r"(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])", part.split(".")[0])):
            raise ExchangeError(f"Not a portable relative path: {value}")
    return PurePosixPath(value)


def contained_path(root, value):
    rel = portable_path(value)
    root = Path(root).resolve()
    result = root.joinpath(*rel.parts)
    cursor = root
    for part in rel.parts:
        cursor /= part
        if cursor.is_symlink():
            raise ExchangeError(f"Symlink in managed path: {value}")
    if not result.resolve().is_relative_to(root):
        raise ExchangeError(f"Path escapes project: {value}")
    return result


def require_step(path):
    """Check a STEP envelope, not geometric correctness."""
    path = Path(path)
    if path.suffix.lower() not in (".step", ".stp"):
        raise ExchangeError("Expected a .step or .stp file")
    with path.open("rb") as stream:
        start = stream.read(4096)
        stream.seek(max(0, path.stat().st_size - 4096))
        end = stream.read()
    if b"ISO-10303-21;" not in start or b"END-ISO-10303-21;" not in end:
        raise ExchangeError(f"Missing STEP Part 21 envelope: {path}")


class Project:
    def __init__(self, root):
        self.root = Path(root).resolve()
        try:
            with (self.root / "vault-project.toml").open("rb") as stream:
                self.config = tomllib.load(stream)
        except (OSError, ValueError) as exc:
            raise ExchangeError(f"Cannot load vault-project.toml: {exc}") from exc
        if self.config.get("schema_version") != 1:
            raise ExchangeError("Unsupported project schema_version")
        self.vault = self.config.get("vault", {})
        for key in ("base_url", "name", "id", "root_assembly"):
            if not isinstance(self.vault.get(key), str) or not self.vault[key]:
                raise ExchangeError(f"Missing vault.{key}")
        url = urlsplit(self.vault["base_url"])
        if (url.scheme not in ("http", "https") or not url.hostname
                or url.username or url.password or url.query or url.fragment):
            raise ExchangeError("vault.base_url must be an HTTP(S) URL without credentials or query")
        if not self.vault["root_assembly"].startswith("$/"):
            raise ExchangeError("vault.root_assembly must be a Vault path starting with $/")
        self.lock_path = contained_path(self.root, "vault-lock.json")
        self.lock = read_json(self.lock_path)
        if not isinstance(self.lock, dict) or not isinstance(self.lock.get("publications"), list):
            raise ExchangeError("Invalid vault-lock.json schema")
        version = self.lock.get("schema_version")
        if version == LOCK_INDEX and isinstance(self.lock.get("components"), list):
            self.layout = True
            self._check_index()
            return
        if version != LOCK_EARLIER or not isinstance(self.lock.get("references"), dict):
            raise ExchangeError("Invalid vault-lock.json schema")
        self.layout = False
        seen = set()
        for path, record in self.lock["references"].items():
            rel = portable_path(path)
            if rel.parts[0] != "references" or path.casefold() in seen:
                raise ExchangeError("Invalid or case-colliding reference paths in lock file")
            contained_path(self.root, path)
            if not isinstance(record, dict) or not re.fullmatch(r"[a-f0-9]{64}", str(record.get("sha256", ""))):
                raise ExchangeError(f"Invalid checksum for reference {path}")
            source = record.get("source")
            if not isinstance(source, dict) or not all(
                    isinstance(source.get(key), str) and source[key]
                    for key in ("vault_id", "master_id", "version_id", "path")):
                raise ExchangeError(f"Invalid source provenance for reference {path}")
            seen.add(path.casefold())

    def _check_index(self):
        """The index is data another command wrote; check its shape before anything is built on it."""
        seen = set()
        for c in self.lock["components"]:
            if not isinstance(c, dict) or not isinstance(c.get("key"), str) or not KEY.fullmatch(c["key"]):
                raise ExchangeError("Invalid component in vault-lock.json")
            key, kind = c["key"], c.get("kind")
            if kind not in COMPONENT_ROOT or c.get("path") != f"{COMPONENT_ROOT[kind]}/{key}" or key in seen:
                raise ExchangeError(f"Invalid or repeated component {key} in vault-lock.json")
            seen.add(key)
            contained_path(self.root, c["path"])
            for field in ("master_id", "version_id", "model_state"):
                if c.get(field) is not None and not (isinstance(c[field], str) and c[field]):
                    raise ExchangeError(f"Invalid {field} for {key} in vault-lock.json")
            for field in ("native_sha256", "step_sha256", "step_data_sha256"):
                if c.get(field) is not None and not (isinstance(c[field], str) and SHA256.fullmatch(c[field])):
                    raise ExchangeError(f"Invalid {field} for {key} in vault-lock.json")
            if (kind == "part") != (c.get("step_sha256") is not None):
                raise ExchangeError(f"{key}: a part has a STEP checksum in vault-lock.json and an assembly has none")
        for p in self.lock["publications"]:
            if (not isinstance(p, dict) or not isinstance(p.get("key"), str) or not KEY.fullmatch(p["key"])
                    or p.get("path") != f"designs/parts/{p['key']}"
                    or not all(isinstance(p.get(f), str) and p[f] for f in PUBLICATION_FIELDS)
                    or not (isinstance(p.get("step_sha256"), str) and SHA256.fullmatch(p["step_sha256"]))):
                raise ExchangeError("Invalid publication in vault-lock.json")
            contained_path(self.root, p["path"])

    def authored_part(self, relative):
        """(key, directory) of the authored part whose deliverable is designs/parts/<key>/part.step."""
        parts = portable_path(relative).parts
        if len(parts) != 4 or parts[:2] != ("designs", "parts") or parts[3] != "part.step" or not KEY.fullmatch(parts[2]):
            raise ExchangeError("The deliverable of an authored part is designs/parts/<key>/part.step")
        return parts[2], contained_path(self.root, "/".join(parts[:3]))

    def derive_publications(self):
        """The publications of the index: what the vault.json files under designs/parts/ say, by key."""
        out = []
        parts = self.root / "designs" / "parts"
        for d in sorted(parts.iterdir(), key=lambda p: p.name) if parts.is_dir() else []:
            record = d / "vault.json"
            if not d.is_dir() or not KEY.fullmatch(d.name) or not record.is_file():
                continue
            data = read_json(record)
            if not isinstance(data, dict) or data.get("schema_version") != 1 or not isinstance(data.get("publications"), list):
                raise ExchangeError(f"Invalid publication record designs/parts/{d.name}/vault.json")
            for p in data["publications"]:
                if not isinstance(p, dict):
                    raise ExchangeError(f"Invalid publication record designs/parts/{d.name}/vault.json")
                out.append({"key": d.name, "path": f"designs/parts/{d.name}", "request_id": p.get("request_id"),
                            "master_id": p.get("master_id"), "version_id": p.get("version_id"),
                            "step_sha256": p.get("step_sha256"), "git_commit": p.get("git_commit")})
        return out

    def _index_status(self):
        """Do the directories still say what the index says? Nothing is read from Vault."""
        records = []
        indexed = set()
        for c in sorted(self.lock["components"], key=lambda c: c["path"]):
            indexed.add(c["path"])
            d = contained_path(self.root, c["path"])
            source = d / "source.json"
            step = d / "part.step"
            if not source.is_file() or (c["kind"] == "part" and not step.is_file()):
                state = "missing"
            else:
                data = read_json(source)
                vault = data.get("vault") if isinstance(data, dict) and isinstance(data.get("vault"), dict) else {}
                same = (isinstance(data, dict) and data.get("key") == c["key"] and data.get("kind") == c["kind"]
                        and data.get("model_state") == c.get("model_state")
                        and all(vault.get(f) == c.get(f) for f in ("master_id", "version_id", "native_sha256")))
                if same and c["kind"] == "part":
                    same = digest(step) == c["step_sha256"]
                state = "clean" if same else "modified"
            records.append({"path": c["path"], "kind": c["kind"], "state": state,
                            "source": {"master_id": c.get("master_id"), "version_id": c.get("version_id")}})
        for kind, top in COMPONENT_ROOT.items():
            base = self.root.joinpath(*top.split("/"))
            for d in sorted(base.iterdir(), key=lambda p: p.name) if base.is_dir() else []:
                if d.is_dir() and f"{top}/{d.name}" not in indexed:
                    records.append({"path": f"{top}/{d.name}", "kind": kind, "state": "not_in_index", "source": {}})
        publications = []
        for p in self.lock["publications"]:
            step = contained_path(self.root, p["path"]) / "part.step"
            publications.append({"path": p["path"], "request_id": p["request_id"], "version_id": p["version_id"],
                                 "part_step": "missing" if not step.is_file() else (
                                     "as_published" if digest(step) == p["step_sha256"] else "changed_since_publication")})
        if self.lock["publications"] != self.derive_publications():
            records.append({"path": "vault-lock.json", "kind": "index", "state": "modified", "source": {},
                            "note": "the publications differ from the vault.json files under designs/parts/"})
        return {"project": self.config.get("project", {}).get("name"),
                "root_assembly": self.vault["root_assembly"], "layout": "one directory per Vault file",
                "references": records, "publication_count": len(publications), "publications": publications}

    @contextmanager
    def transaction(self):
        path = contained_path(self.root, ".vault-cad-operation.lock")
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError as exc:
            raise ExchangeError("Another operation or stale .vault-cad-operation.lock exists") from exc
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write(str(os.getpid()))
            # Reload after acquiring the lock to avoid stale concurrent manifests.
            self.lock = Project(self.root).lock
            yield
        finally:
            path.unlink()

    def status(self):
        if self.layout:
            return self._index_status()
        records = []
        for name, entry in sorted(self.lock["references"].items()):
            path = contained_path(self.root, name)
            state = "missing" if not path.is_file() else (
                "clean" if digest(path) == entry["sha256"] else "modified")
            records.append({"path": name, "state": state,
                            "source": entry.get("source", {})})
        return {"project": self.config.get("project", {}).get("name"),
                "root_assembly": self.vault["root_assembly"], "references": records,
                "publication_count": len(self.lock["publications"])}

    def import_step(self, source, relative, receipt_path):
        if self.layout:
            raise ExchangeError("import-step writes the earlier layout. This project keeps one directory per Vault "
                                "file; its references are written by import-snapshot")
        source = Path(source).resolve()
        require_step(source)
        target = contained_path(self.root, relative)
        if portable_path(relative).parts[0] != "references" or target.suffix.lower() not in (".step", ".stp"):
            raise ExchangeError("Imported STEP files must live under references/ with a STEP extension")
        receipt = read_json(receipt_path)
        if not isinstance(receipt, dict) or receipt.get("schema_version") != 1:
            raise ExchangeError("Unsupported export receipt")
        meta, exporter = receipt.get("source", {}), receipt.get("exporter", {})
        if not isinstance(meta, dict) or not isinstance(exporter, dict):
            raise ExchangeError("Invalid export receipt metadata")
        for key in ("vault_id", "master_id", "version_id", "path"):
            if not isinstance(meta.get(key), str) or not meta[key]:
                raise ExchangeError(f"Export receipt requires source.{key}")
        if meta["vault_id"] != self.vault["id"] or not meta["path"].startswith("$/"):
            raise ExchangeError("Export receipt belongs to another vault or has an invalid Vault path")
        for key in ("name", "version", "model_state", "protocol"):
            if not isinstance(exporter.get(key), str) or not exporter[key]:
                raise ExchangeError(f"Export receipt requires exporter.{key}")
        sha = digest(source)
        if sha != receipt.get("sha256"):
            raise ExchangeError("Export receipt checksum does not match the STEP file")
        # Keep receipt extensions, including assembly dependencies and geometry
        # observations. Dropping these loses the evidence for the frozen snapshot.
        # Preserved observations are data, not a claim that geometry was validated.
        entry = {key: value for key, value in receipt.items() if key != "schema_version"}
        with self.transaction():
            for name in self.lock["references"]:
                if name.casefold() == relative.casefold() and name != relative:
                    raise ExchangeError("Reference path collides on Windows")
            old = self.lock["references"].get(relative)
            if target.exists():
                if old is None or digest(target) != old["sha256"]:
                    raise ExchangeError("Refusing to overwrite an untracked or locally modified reference")
            if old and (old["source"]["master_id"] != meta["master_id"]):
                raise ExchangeError("Reference path is already assigned to another Vault file")
            if old == entry and target.exists():
                return {"path": relative, "changed": False, "sha256": sha}
            target.parent.mkdir(parents=True, exist_ok=True)
            # Stage bytes and verify the actual copy before replacing a managed file.
            fd, tmp_name = tempfile.mkstemp(prefix=".vault-cad-", dir=target.parent)
            os.close(fd)
            tmp = Path(tmp_name)
            backup = None
            installed = False
            try:
                shutil.copyfile(source, tmp)
                if digest(tmp) != sha:
                    raise ExchangeError("STEP source changed while being copied")
                if target.exists():
                    fd, backup_name = tempfile.mkstemp(prefix=".vault-cad-backup-", dir=target.parent)
                    os.close(fd)
                    backup = Path(backup_name)
                    shutil.copyfile(target, backup)
                os.replace(tmp, target)
                installed = True
                self.lock["references"][relative] = entry
                atomic_json(self.lock_path, self.lock)
            except Exception:
                if installed:
                    if backup is not None:
                        os.replace(backup, target)
                    else:
                        target.unlink(missing_ok=True)
                self.lock = read_json(self.lock_path)
                raise
            finally:
                tmp.unlink(missing_ok=True)
                if backup is not None:
                    backup.unlink(missing_ok=True)
        return {"path": relative, "changed": True, "sha256": sha}
