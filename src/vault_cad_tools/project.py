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
        if (not isinstance(self.lock, dict) or self.lock.get("schema_version") != 1
                or not isinstance(self.lock.get("references"), dict)
                or not isinstance(self.lock.get("publications"), list)):
            raise ExchangeError("Invalid vault-lock.json schema")
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
