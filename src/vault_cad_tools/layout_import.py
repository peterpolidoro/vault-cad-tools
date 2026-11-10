"""Write an exporter package into the proposed repository layout.

PROVISIONAL. The layout (one directory per Vault file, a manifest per assembly)
is a proposal kept in the sibling `mechanical-cad` repository
(`docs/layout-proposal.md`, `docs/layout-specification.md`); Peter has not
accepted it. This module is the first form of the import command that proposal
describes. It reads the package `windows/Export-PartAssets.ps1` writes today
(`native-snapshot.json`, `scene.json`, `export-receipt.json`, `assets/`) and
writes `references/` and the derived `vault-lock.json` into a new directory.
The validator in `mechanical-cad` is the reference for what it must produce.

It never guesses: a Vault fact the package does not carry is written as null,
and an instance that disagrees with its definition without being a recorded
override is an error. STEP files are copied byte for byte.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
from pathlib import Path

from .project import ExchangeError

LAYOUT_SCHEMA_VERSION = 1
LOCK_SCHEMA_VERSION = 2
PRIMARY_STATES = (None, "[Primary]", "Primary")
ROTATION_TOL = 1e-9
LENGTH_TOL_CM = 1e-9
KEY_MAX = 80
RECORD_FILES = ("export-receipt.json", "native-snapshot.json", "scene.json", "inventory-raw.json")
_DATA = re.compile(rb"ENDSEC\s*;\s*(DATA)\s*;")


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _read_json(path):
    raw = Path(path).read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):          # PowerShell writes a byte-order mark
        raw = raw[3:]
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ExchangeError(f"{path}: {exc}") from None


def _scalar(v):
    return v is None or isinstance(v, (bool, int, float, str))


def _emit(v, level, out):
    pad, inner = "  " * level, "  " * (level + 1)
    if isinstance(v, dict):
        if not v:
            out.append("{}")
            return
        out.append("{\n")
        items = list(v.items())
        for i, (k, x) in enumerate(items):
            out.append(inner + json.dumps(k, ensure_ascii=False) + ": ")
            _emit(x, level + 1, out)
            out.append(",\n" if i < len(items) - 1 else "\n")
        out.append(pad + "}")
    elif isinstance(v, list):
        if not v:
            out.append("[]")
        elif all(_scalar(x) for x in v):
            out.append("[" + ", ".join(json.dumps(x, ensure_ascii=False) for x in v) + "]")
        else:
            out.append("[\n")
            for i, x in enumerate(v):
                out.append(inner)
                _emit(x, level + 1, out)
                out.append(",\n" if i < len(v) - 1 else "\n")
            out.append(pad + "]")
    else:
        out.append(json.dumps(v, ensure_ascii=False))


def _write_json(path, obj):
    """UTF-8 without a byte-order mark, LF, lists of scalars on one line."""
    out = []
    _emit(obj, 0, out)
    tmp = Path(str(path) + ".tmp")
    tmp.write_bytes(("".join(out) + "\n").encode("utf-8"))
    os.replace(tmp, path)


def data_sha256(data):
    """SHA-256 of a STEP file from its `DATA` keyword to the end of the file."""
    m = _DATA.search(data)
    if not m:
        raise ExchangeError("the STEP file has no DATA section after its header")
    return _sha(data[m.start(1):])


def slug(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "unnamed"


def _stem(filename):
    base = filename.replace("\\", "/").split("/")[-1]
    return base.rsplit(".", 1)[0] if "." in base else base


def _deviation(a, b):
    rot = max(abs(a[r][c] - b[r][c]) for r in range(3) for c in range(3))
    tra = max(abs(a[r][3] - b[r][3]) for r in range(3))
    return rot, tra


class _Keys:
    """Readable keys, unique across the repository."""

    def __init__(self):
        self.used = {}

    def assign(self, name, master_id, model_state, identity):
        base = slug(name)
        if len(base) > KEY_MAX - 12:                     # room for a master id or a counter after it
            base = base[:KEY_MAX - 12].rsplit("-", 1)[0]
        key = base
        if key in self.used and self.used[key] != identity:
            key = f"{base}-{slug(str(master_id))}" if master_id else None
            n = 2
            while key is None or (key in self.used and self.used[key] != identity):
                key = f"{base}-{n}"
                n += 1
        if model_state not in PRIMARY_STATES:
            key = f"{key}@{slug(model_state)}"
        self.used[key] = identity
        return key


def import_snapshot(package, dest, run, inventory=None, acquisition=None):
    """Convert one `Export-PartAssets.ps1` package into the layout under `dest`.

    package: directory with native-snapshot.json, scene.json, export-receipt.json and assets/.
    dest: a directory that does not exist yet or is empty.
    run: the name under which the exporter's records are kept (references/receipts/<run>/).
    inventory, acquisition: optional dependency-inventory.json and acquisition.json of the
    same acquisition; they supply the Vault facts of the sub-assembly documents and the
    version number, revision, lifecycle state and check-in date of every file.
    """
    package, dest = Path(package), Path(dest)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", run or ""):
        raise ExchangeError("the run name must be a plain directory name")
    if dest.exists() and any(dest.iterdir()):
        raise ExchangeError(f"{dest} exists and is not empty; convert into a new directory")
    for name in ("export-receipt.json", "native-snapshot.json", "scene.json"):
        if not (package / name).is_file():
            raise ExchangeError(f"{package / name} is missing")
    receipt = _read_json(package / "export-receipt.json")
    snapshot = _read_json(package / "native-snapshot.json")
    scene = _read_json(package / "scene.json")

    # 1. the package is what its receipt says it is
    for rel, rec in receipt.get("files", {}).items():
        f = package / rel
        if not f.is_file() or _sha(f.read_bytes()) != rec.get("sha256"):
            raise ExchangeError(f"{rel} does not match the export receipt; the package is not the one that was exported")

    inv = {}
    if inventory:
        data = _read_json(inventory)
        for rec in list(data.get("files", [])) + [data.get("root") or {}]:
            if rec.get("vault_path"):
                inv[rec["vault_path"].lower()] = rec
    acq = {}
    if acquisition:
        for rec in _read_json(acquisition).get("files", []):
            if rec.get("vault_path"):
                acq[rec["vault_path"].lower()] = rec

    scene_parts = {p["id"]: p for p in scene["parts"]}
    if set(scene_parts) != {p["id"] for p in snapshot["parts"]}:
        raise ExchangeError("scene.json and native-snapshot.json do not list the same parts")

    # 2. where the workspace starts in the exporter's absolute document paths
    first = snapshot["parts"][0]
    rel = first["id"].split("|")[0]
    if not first["document"].endswith(rel):
        raise ExchangeError("cannot find the workspace root in the exporter's document paths")
    workspace = first["document"][:-len(rel)]

    def vault_path_of(document):
        if not document.startswith(workspace):
            raise ExchangeError(f"a document lies outside the exported workspace: {_stem(document)}")
        return "$/" + document[len(workspace):].replace("\\", "/")

    def vault_block(src, vault_path):
        src = src or {}
        extra = inv.get((vault_path or "").lower(), {})
        native = src.get("native_sha256") or acq.get((vault_path or "").lower(), {}).get("sha256")
        version = extra.get("version")
        return {
            "vault_id": src.get("vault_id") or (snapshot.get("assembly", {}).get("source", {}).get("vault_id") if extra else None),
            "master_id": src.get("master_id") or extra.get("master_id"),
            "version_id": src.get("version_id") or extra.get("version_id"),
            "version_number": version if isinstance(version, int) and not isinstance(version, bool) else None,
            "revision": extra.get("revision"),
            "lifecycle_state": extra.get("state"),
            "checkin_date": extra.get("checkin_date"),
            "path": src.get("vault_path") or vault_path,
            "native_sha256": native,
        }

    exporter = scene.get("source", {}).get("exporter") or receipt.get("exporter")
    export_common = {"run": run, "exporter": exporter, "exported_at": snapshot.get("generated_at"),
                     "inventor_version": snapshot.get("inventor_version"), "inventor_build": snapshot.get("inventor_build")}
    keys = _Keys()

    # 3. parts
    parts = {}          # package part id -> record
    for p in sorted(snapshot["parts"], key=lambda p: (p["display_name"].lower(), p["id"])):
        vault = vault_block(p.get("source"), vault_path_of(p["document"]))
        key = keys.assign(_stem(p["display_name"]), vault["master_id"], p.get("model_state"), ("part", p["id"]))
        asset = p["asset"]
        data = (package / asset["path"]).read_bytes()
        if _sha(data) != asset["sha256"]:
            raise ExchangeError(f"{asset['path']} does not match the hash in the snapshot")
        sp = scene_parts[p["id"]]
        native = {"length_unit": p.get("native_length_units"), "bodies": p.get("bodies"),
                  "extent_mm": (sp.get("identifying_dimensions_mm") or {}).get("extent"), "volume_mm3": sp.get("volume_mm3"),
                  "range_box_cm": p.get("range_box_cm"), "volume_cm3": p.get("volume_cm3")}
        source = {
            "schema_version": LAYOUT_SCHEMA_VERSION, "kind": "part", "key": key, "name": _stem(p["display_name"]),
            "model_state": p.get("model_state"), "vault": vault,
            "step": {"sha256": asset["sha256"], "data_sha256": data_sha256(data), "bytes": len(data),
                     "protocol": asset.get("protocol"), "length_unit": asset.get("step_length_unit"),
                     "header_normalised": False, "received_sha256": None},
            "export": dict(export_common, package_id=p["id"], package_path=asset["path"],
                           translator_options=asset.get("translator_options"),
                           step_length_unit_detection=asset.get("step_length_unit_detection")),
            "properties": p.get("properties"),
            "bom_structure_default": (p.get("default_bom_structure") or {}).get("name"),
            "native": native, "materials": None,
        }
        parts[p["id"]] = {"key": key, "source": source, "data": data}

    # 4. assembly documents: the root and every distinct sub-assembly definition
    groups = {g["id"]: g for g in snapshot["groups"]}
    occurrences = snapshot["occurrences"]
    root_doc = snapshot["assembly"]["document"]
    documents = {root_doc: {"instances": ["root"], "model_state": snapshot["assembly"].get("model_state"),
                            "source": snapshot["assembly"].get("source"),
                            "length_unit": snapshot["assembly"].get("length_units")}}
    for g in snapshot["groups"]:
        d = documents.setdefault(g["document"], {"instances": [], "model_state": g.get("active_model_state"), "source": None,
                                                 "length_unit": None})
        d["instances"].append(g["id"])
    for doc in sorted(documents, key=lambda d: (_stem(d).lower(), d)):
        info = documents[doc]
        vault = vault_block(info["source"], vault_path_of(doc))
        info["vault"] = vault
        info["key"] = keys.assign(_stem(doc), vault["master_id"], info["model_state"], ("assembly", doc))

    children_of = {}
    for node in list(snapshot["groups"]) + list(occurrences):
        children_of.setdefault(node["parent_id"], []).append(node)

    def component_of(node):
        if node["kind"] == "part":
            return parts[node["part_id"]]["key"], parts[node["part_id"]]["source"]["vault"]["master_id"]
        info = documents[node["document"]]
        return info["key"], info["vault"]["master_id"]

    def entry(node, at_root):
        m = node["transform_local_cm"] if at_root else node["transform_local_definition_cm"]
        if m is None:
            raise ExchangeError(f"{node['id']}: the snapshot has no definition transform for it")
        if node.get("suppressed") or node.get("mirrored"):
            raise ExchangeError(f"{node['id']}: suppressed or mirrored occurrences are not converted")
        comp, master = component_of(node)
        return {"name": node["name"], "component": comp, "kind": node["kind"], "master_id": master,
                "model_state": node.get("active_model_state"), "transform": m,
                "bom_structure": (node.get("bom_structure") or {}).get("name"),
                "visible": bool(node.get("visible")), "suppressed": False, "grounded": bool(node.get("grounded")),
                "flexible": bool(node.get("flexible")), "mirrored": False}

    manifests = {}
    for doc, info in documents.items():
        at_root = doc == root_doc
        reference = None
        for inst in info["instances"]:
            entries = [entry(n, at_root) for n in children_of.get(inst, [])]
            if reference is None:
                reference = entries
                continue
            if [e["name"] for e in entries] != [e["name"] for e in reference]:
                raise ExchangeError(f"{inst}: its children differ from the other instances of {_stem(doc)}")
            for a, b in zip(reference, entries):
                rot, tra = _deviation(a["transform"], b["transform"])
                same = all(a[k] == b[k] for k in a if k != "transform")
                if not same or rot > ROTATION_TOL or tra > LENGTH_TOL_CM:
                    raise ExchangeError(f"{inst}/{b['name']}: this instance's definition differs from the first instance's")
        manifest = {"schema_version": LAYOUT_SCHEMA_VERSION, "key": info["key"], "name": _stem(doc), "length_unit": "cm"}
        if at_root:
            cs = scene.get("coordinate_system", {})
            manifest["frame"] = {"handedness": cs.get("handedness", "right"), "up_axis": cs.get("up_axis", "+Z")}
        manifest["children"] = reference or []
        manifests[doc] = manifest

    # 5. placements that differ from the definition: recorded on the nearest flexible instance, in its parent's manifest
    overrides = {}      # (parent document, flexible child name) -> {path tuple: matrix}
    count = 0
    for node in list(snapshot["groups"]) + list(occurrences):
        if not node.get("position_overridden_vs_definition"):
            continue
        path = [node["name"]]
        anc = groups.get(node["parent_id"])
        while anc is not None and not anc.get("flexible"):
            path.insert(0, anc["name"])
            anc = groups.get(anc["parent_id"])
        if anc is None:
            raise ExchangeError(f"{node['id']}: its position differs from its definition but no enclosing instance is flexible")
        parent_doc = root_doc if anc["parent_id"] == "root" else groups[anc["parent_id"]]["document"]
        slot = overrides.setdefault((parent_doc, anc["name"]), {})
        m = node["transform_local_cm"]
        prev = slot.get(tuple(path))
        if prev is not None:
            rot, tra = _deviation(prev, m)
            if rot > ROTATION_TOL or tra > LENGTH_TOL_CM:
                raise ExchangeError(f"{node['id']}: two instances of its parent place it differently; that needs an "
                                    "override on an outer instance, which this converter does not write")
        else:
            slot[tuple(path)] = m
            count += 1
    for (doc, child_name), slot in overrides.items():
        child = next(c for c in manifests[doc]["children"] if c["name"] == child_name)
        child["overrides"] = [{"path": list(p), "transform": m} for p, m in slot.items()]

    # 6. write
    (dest / "references" / "parts").mkdir(parents=True)
    (dest / "references" / "assemblies").mkdir(parents=True)
    records = dest / "references" / "receipts" / run
    records.mkdir(parents=True)
    kept = []
    for name in RECORD_FILES:
        if (package / name).is_file():
            shutil.copyfile(package / name, records / name)
            kept.append(name)
    for src, name in ((inventory, "dependency-inventory.json"), (acquisition, "acquisition.json")):
        if src:
            shutil.copyfile(src, records / name)
            kept.append(name)
    for name in kept:
        if name in receipt.get("files", {}) and _sha((records / name).read_bytes()) != receipt["files"][name]["sha256"]:
            raise ExchangeError(f"{name}: the kept copy does not match the export receipt")

    lock = []
    for rec in parts.values():
        d = dest / "references" / "parts" / rec["key"]
        d.mkdir()
        (d / "part.step").write_bytes(rec["data"])
        _write_json(d / "source.json", rec["source"])
        s = rec["source"]
        lock.append({"key": rec["key"], "path": f"references/parts/{rec['key']}", "kind": "part",
                     "model_state": s["model_state"], "master_id": s["vault"]["master_id"],
                     "version_id": s["vault"]["version_id"], "native_sha256": s["vault"]["native_sha256"],
                     "step_sha256": s["step"]["sha256"], "step_data_sha256": s["step"]["data_sha256"]})
    for doc, info in documents.items():
        d = dest / "references" / "assemblies" / info["key"]
        d.mkdir()
        _write_json(d / "assembly.json", manifests[doc])
        _write_json(d / "source.json", {
            "schema_version": LAYOUT_SCHEMA_VERSION, "kind": "assembly", "key": info["key"], "name": _stem(doc),
            "model_state": info["model_state"], "vault": info["vault"],
            "export": dict(export_common, package_id=("root" if doc == root_doc else _stem(doc))),
            "native": {"length_unit": info["length_unit"], "instances_in_export": len(info["instances"])},
        })
        lock.append({"key": info["key"], "path": f"references/assemblies/{info['key']}", "kind": "assembly",
                     "model_state": info["model_state"], "master_id": info["vault"]["master_id"],
                     "version_id": info["vault"]["version_id"], "native_sha256": info["vault"]["native_sha256"],
                     "step_sha256": None, "step_data_sha256": None})
    _write_json(dest / "vault-lock.json", {"schema_version": LOCK_SCHEMA_VERSION,
                                           "components": sorted(lock, key=lambda c: c["key"]), "publications": []})

    return {
        "destination": str(dest), "run": run,
        "parts": len(parts), "assemblies": len(documents), "overrides": count,
        "records_kept": kept,
        "identity_incomplete": sorted(c["key"] for c in lock if not c["master_id"] or not c["version_id"]),
        "part_ids": {rec["key"]: pid for pid, rec in parts.items()},
        "root": documents[root_doc]["key"],
    }
