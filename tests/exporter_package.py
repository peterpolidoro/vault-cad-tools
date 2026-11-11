"""Write the exporter's package (schema 2) without the exporter: for tests and trials.

The package is specified in `mechanical-cad/docs/exporter-package.md`. Two
ways to make one here: `write_package` from records given by hand, and
`from_project`, the package an exporter would deliver for the files a project
with one directory per Vault file already holds (the inverse of the import).
JSON is written as PowerShell writes it, with a byte-order mark and CRLF.
"""
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from vault_cad_tools.layout_import import data_sha256

BOM = b"\xef\xbb\xbf"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def directory_name(master_id, model_state):
    state = re.sub(r"[^a-z0-9]+", "-", (model_state or "").lower()).strip("-")
    return f"{master_id}_{state}"


def step_record(data, protocol="AP242", length_unit="mm"):
    return {"sha256": sha(data), "data_sha256": data_sha256(data), "bytes": len(data), "protocol": protocol,
            "length_unit": length_unit, "header_normalised": True, "received_sha256": None}


def powershell_json(obj):
    return BOM + json.dumps(obj, indent=2).replace("\n", "\r\n").encode()


def write_package(out, files, root, vault_id="7", exported_at="2026-01-02T00:00:00Z", not_exported=()):
    """files: a list of {"source": {...}, "step": bytes} or {"source": {...}, "assembly": {...}}.

    A file may name its "directory"; otherwise it is <master id>_<state>, as the exporter names it.
    root: (master id, model state) of the root assembly. Returns the package directory.
    """
    out = Path(out)
    listed = {}

    def put(rel, data):
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        listed[rel] = {"sha256": sha(data), "bytes": len(data)}

    root_version = None
    for f in files:
        source = f["source"]
        name = f.get("directory") or directory_name(source["vault"]["master_id"], source["model_state"])
        put(f"files/{name}/source.json", powershell_json(source))
        if source["kind"] == "part":
            put(f"files/{name}/part.step", f["step"])
        else:
            put(f"files/{name}/assembly.json", powershell_json(f["assembly"]))
        if (source["vault"]["master_id"], source["model_state"]) == tuple(root):
            root_version = source["vault"]["version_id"]
    manifest = {
        "schema_version": 2, "kind": "vault-cad-export-package", "exported_at": exported_at,
        "exporter": {"name": "tests/exporter_package.py", "version": "test", "inventor": None},
        "translator_options": {"ApplicationProtocolType": 5}, "vault_id": vault_id,
        "root": {"master_id": root[0], "version_id": root_version, "model_state": root[1]},
        "acquisition": {"captured_at": "2026-01-01T00:00:00Z", "method": "test"},
        "counts": {"parts": sum(f["source"]["kind"] == "part" for f in files),
                   "assemblies": sum(f["source"]["kind"] == "assembly" for f in files)},
        "not_exported": list(not_exported), "files": listed,
    }
    (out / "package.json").write_bytes(powershell_json(manifest))
    return out


def from_project(project, out, root_key, replace_step=None, exported_at="2026-01-02T00:00:00Z"):
    """The package an exporter would deliver for what `project` holds under references/.

    replace_step: {part key: (bytes, {step fields to set})}, to stand in for another export of the same
    Vault versions (another protocol, a normalised header).
    """
    project = Path(project)
    lock = json.loads((project / "vault-lock.json").read_text(encoding="utf-8"))
    by_key = {c["key"]: c for c in lock["components"]}
    files, root = [], None
    for c in lock["components"]:
        d = project / c["path"]
        source = json.loads((d / "source.json").read_text(encoding="utf-8"))
        source.pop("key")
        source["export"] = {}
        entry = {"source": source}
        if c["kind"] == "part":
            data = (d / "part.step").read_bytes()
            if replace_step and c["key"] in replace_step:
                data, fields = replace_step[c["key"]]
                source["step"] = dict(source["step"], sha256=sha(data), data_sha256=data_sha256(data), bytes=len(data), **fields)
            source["export"] = {"translator_output_sha256": sha(data)}
            entry["step"] = data
        else:
            assembly = json.loads((d / "assembly.json").read_text(encoding="utf-8"))
            assembly.pop("key")
            for child in assembly["children"]:
                target = by_key[child.pop("component")]
                child["master_id"], child["model_state"] = target["master_id"], target["model_state"]
            entry["assembly"] = assembly
        if c["key"] == root_key:
            root = (c["master_id"], c["model_state"])
        files.append(entry)
    vault_id = files[0]["source"]["vault"]["vault_id"]
    return write_package(out, files, root, vault_id=vault_id, exported_at=exported_at)
