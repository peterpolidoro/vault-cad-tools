"""Read the exporter's package (schema 2) into a project with one directory per Vault file.

PROVISIONAL, like the package itself. The package is specified by a draft in
the sibling `mechanical-cad` repository (`docs/exporter-package.md`): a
`package.json` and, under `files/`, one directory per exported Vault file and
model state with `source.json` and `part.step` or `assembly.json`. The
exporter identifies a file by its Vault master id and model state and never
writes a key. This module finds or assigns the key and writes `references/`.

Unlike `layout_import.import_snapshot`, which converts the earlier package
into a new directory, this reads into a project that may already hold the
files:

- a file the project has keeps its key, whatever it is called in Vault now;
- a file whose Vault version, native hash, STEP bytes and exported record are
  what the project has is left untouched, so it keeps naming the export run
  it first came from;
- a package that holds an earlier version of a file than the project does is
  refused;
- what the project has and the package does not is reported, never removed.

Nothing is written until the whole package has been checked. The validator in
`mechanical-cad` is the reference for what the result must be; this module
checks what it needs in order not to write nonsense, and no more.
"""
from __future__ import annotations

import os
import re
import tomllib
from pathlib import Path

from .layout_import import (LAYOUT_SCHEMA_VERSION, LOCK_SCHEMA_VERSION, _Keys, _read_json, _sha, data_sha256,
                            write_json)
from .project import COMPONENT_ROOT, KEY, ExchangeError

OPERATION_LOCK = ".vault-cad-operation.lock"        # the lock file Project.transaction uses

PACKAGE_SCHEMA_VERSION = 2
PACKAGE_KIND = "vault-cad-export-package"
PACKAGE_FILE = re.compile(r"files/([^/]+)/(source\.json|part\.step|assembly\.json)")
SHA256 = re.compile(r"[a-f0-9]{64}")
RUN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")

VAULT_FIELDS = ("vault_id", "master_id", "version_id", "version_number", "revision", "lifecycle_state", "checkin_date",
                "path", "native_sha256")
STEP_FIELDS = ("sha256", "data_sha256", "bytes", "protocol", "length_unit", "header_normalised", "received_sha256")
SOURCE_ORDER = ("schema_version", "kind", "key", "name", "model_state", "vault", "step", "export", "properties",
                "bom_structure_default", "native", "materials")
CHILD_ORDER = ("name", "component", "kind", "master_id", "model_state", "transform", "bom_structure", "visible",
               "suppressed", "grounded", "flexible", "mirrored", "overrides")
CHILD_FLAGS = ("visible", "suppressed", "grounded", "flexible", "mirrored")
ASSEMBLY_FIELDS = {"schema_version", "name", "length_unit", "frame", "children"}


def is_package(path):
    """Whether a directory holds the package this module reads."""
    return (Path(path) / "package.json").is_file()


def _matrix(m):
    return (isinstance(m, list) and len(m) == 4
            and all(isinstance(r, list) and len(r) == 4
                    and all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in r) for r in m))


def _identity(master_id, model_state, where):
    if not isinstance(master_id, str) or not master_id:
        raise ExchangeError(f"{where}: the master id must be a non-empty string")
    if model_state is not None and not (isinstance(model_state, str) and model_state):
        raise ExchangeError(f"{where}: the model state must be a string or null")
    return master_id, model_state


def _read_package(package):
    """Check the package against its own manifest and return (manifest, files by identity)."""
    manifest = _read_json(package / "package.json")
    if (not isinstance(manifest, dict) or manifest.get("schema_version") != PACKAGE_SCHEMA_VERSION
            or manifest.get("kind") != PACKAGE_KIND):
        raise ExchangeError(f"package.json is not a {PACKAGE_KIND} of schema {PACKAGE_SCHEMA_VERSION}")
    listed = manifest.get("files")
    if not isinstance(listed, dict) or not listed:
        raise ExchangeError("package.json lists no files")
    if not isinstance(manifest.get("vault_id"), str) or not manifest["vault_id"]:
        raise ExchangeError("package.json does not name the vault")
    root = manifest.get("root")
    if not isinstance(root, dict):
        raise ExchangeError("package.json does not name the root assembly")
    if manifest.get("not_exported") is None or not isinstance(manifest["not_exported"], list):
        raise ExchangeError("package.json must list what was not exported (an empty list when nothing was left out)")

    base = package / "files"
    present = {p.relative_to(package).as_posix() for p in base.rglob("*") if p.is_file()} if base.is_dir() else set()
    for rel in sorted(set(listed) ^ present):
        raise ExchangeError(f"{rel} is " + ("listed in package.json and missing" if rel in listed else
                                            "in the package and not listed in package.json"))
    directories = {}
    for rel, rec in sorted(listed.items()):
        m = PACKAGE_FILE.fullmatch(rel)
        if not m:
            raise ExchangeError(f"{rel}: a package holds files/<directory>/source.json, part.step or assembly.json only")
        data = (package / rel).read_bytes()
        if not isinstance(rec, dict) or _sha(data) != rec.get("sha256") or len(data) != rec.get("bytes"):
            raise ExchangeError(f"{rel} does not match package.json; the package is not the one that was exported")
        directories.setdefault(m.group(1), {})[m.group(2)] = data

    files = {}
    for name, held in sorted(directories.items()):
        where = f"files/{name}"
        if "source.json" not in held:
            raise ExchangeError(f"{where} has no source.json")
        source = _read_json(package / "files" / name / "source.json")
        if not isinstance(source, dict) or source.get("schema_version") != LAYOUT_SCHEMA_VERSION:
            raise ExchangeError(f"{where}/source.json: schema_version must be {LAYOUT_SCHEMA_VERSION}")
        kind = source.get("kind")
        if kind not in COMPONENT_ROOT:
            raise ExchangeError(f"{where}/source.json: kind must be part or assembly")
        unknown = sorted(set(source) - set(SOURCE_ORDER))
        if unknown or "key" in source:
            raise ExchangeError(f"{where}/source.json: " + ("the exporter does not write a key" if "key" in source
                                                           else f"unknown field {unknown[0]}"))
        if not isinstance(source.get("name"), str) or not source["name"]:
            raise ExchangeError(f"{where}/source.json: name must be a non-empty string")
        vault = source.get("vault")
        if not isinstance(vault, dict) or set(vault) != set(VAULT_FIELDS):
            raise ExchangeError(f"{where}/source.json: vault must have exactly its nine fields, null where unknown")
        if vault["vault_id"] != manifest["vault_id"]:
            raise ExchangeError(f"{where}/source.json: the file is from another vault than the package")
        identity = _identity(vault["master_id"], source.get("model_state"), f"{where}/source.json")
        if not isinstance(vault["version_id"], str) or not vault["version_id"]:
            raise ExchangeError(f"{where}/source.json: the version id must be a non-empty string")
        number = vault["version_number"]
        if number is not None and (isinstance(number, bool) or not isinstance(number, int)):
            raise ExchangeError(f"{where}/source.json: vault.version_number must be an integer or null")
        if vault["native_sha256"] is None or not SHA256.fullmatch(str(vault["native_sha256"])):
            raise ExchangeError(f"{where}/source.json: vault.native_sha256 must be the hash of the native file")
        export = source.get("export", {})
        if not isinstance(export, dict) or "run" in export:
            raise ExchangeError(f"{where}/source.json: export must be an object without a run; the import names the run")
        if identity in files:
            raise ExchangeError(f"{where}: master id {identity[0]} in model state {identity[1]} is in the package twice")
        entry = {"where": where, "kind": kind, "source": source, "identity": identity}
        if set(held) != {"source.json", "part.step" if kind == "part" else "assembly.json"}:
            raise ExchangeError(f"{where}: a {kind} has source.json and "
                                + ("part.step" if kind == "part" else "assembly.json") + ", and nothing else")
        if kind == "part":
            step, data = source.get("step"), held["part.step"]
            if not isinstance(step, dict) or set(step) != set(STEP_FIELDS):
                raise ExchangeError(f"{where}/source.json: step must have exactly its seven fields")
            if step["sha256"] != _sha(data) or step["bytes"] != len(data) or step["data_sha256"] != data_sha256(data):
                raise ExchangeError(f"{where}/source.json: step does not describe part.step")
            entry["step"] = data
        else:
            if "step" in source:
                raise ExchangeError(f"{where}/source.json: an assembly has no step record")
            entry["assembly"] = _read_json(package / "files" / name / "assembly.json")
        files[identity] = entry

    for entry in files.values():
        if entry["kind"] == "assembly":
            _check_assembly(entry, files, manifest["not_exported"])

    root_identity = _identity(root.get("master_id"), root.get("model_state"), "package.json root")
    held = files.get(root_identity)
    if held is None or held["kind"] != "assembly":
        raise ExchangeError("the root assembly named in package.json is not an assembly of the package")
    if held["source"]["vault"]["version_id"] != root.get("version_id"):
        raise ExchangeError("package.json and the root assembly's source.json name different versions")
    counts = manifest.get("counts")
    have = {"parts": sum(e["kind"] == "part" for e in files.values()),
            "assemblies": sum(e["kind"] == "assembly" for e in files.values())}
    if counts != have:
        raise ExchangeError(f"package.json counts {counts}; the package holds {have}")
    return manifest, files, root_identity


def _check_assembly(entry, files, not_exported):
    where = entry["where"] + "/assembly.json"
    data = entry["assembly"]
    if not isinstance(data, dict) or data.get("schema_version") != LAYOUT_SCHEMA_VERSION:
        raise ExchangeError(f"{where}: schema_version must be {LAYOUT_SCHEMA_VERSION}")
    unknown = sorted(set(data) - ASSEMBLY_FIELDS)
    if unknown:
        raise ExchangeError(f"{where}: " + ("the exporter does not write a key" if "key" in unknown
                                            else f"unknown field {unknown[0]}"))
    if not isinstance(data.get("children"), list):
        raise ExchangeError(f"{where}: children must be a list")
    left_out = {(str(r.get("master_id")), r.get("model_state")): r.get("reason") for r in not_exported if isinstance(r, dict)}
    names = set()
    for child in data["children"]:
        if not isinstance(child, dict) or not isinstance(child.get("name"), str) or not child["name"]:
            raise ExchangeError(f"{where}: a child has no name")
        at = f"{where} {child['name']}"
        unknown = sorted(set(child) - set(CHILD_ORDER))
        if unknown or "component" in child:
            raise ExchangeError(f"{at}: " + ("the exporter names a component by master id and model state, not by key"
                                             if "component" in child else f"unknown field {unknown[0]}"))
        if child["name"] in names or "/" in child["name"]:
            raise ExchangeError(f"{at}: occurrence names are unique in an assembly and hold no '/'")
        names.add(child["name"])
        target = _identity(child.get("master_id"), child.get("model_state"), at)
        held = files.get(target)
        if held is None:
            reason = left_out.get(target)
            raise ExchangeError(f"{at}: master id {target[0]} in model state {target[1]} is not in the package"
                                + (f" (not exported: {reason})" if reason else ""))
        if child.get("kind") != held["kind"]:
            raise ExchangeError(f"{at}: kind is {child.get('kind')!r} and the component is a {held['kind']}")
        if not _matrix(child.get("transform")):
            raise ExchangeError(f"{at}: transform must be 4 by 4 numbers")
        if not isinstance(child.get("bom_structure"), str) or any(not isinstance(child.get(f), bool) for f in CHILD_FLAGS):
            raise ExchangeError(f"{at}: an exported child states its BOM structure and all five flags")
        overrides = child.get("overrides", [])
        if not isinstance(overrides, list) or any(
                not isinstance(o, dict) or set(o) != {"path", "transform"} or not _matrix(o["transform"])
                or not isinstance(o["path"], list) or not o["path"] or any(not isinstance(n, str) for n in o["path"])
                for o in overrides):
            raise ExchangeError(f"{at}: an override is a path of occurrence names and a transform")


def _read_project(dest):
    """What an existing project holds: its index, checked against its directories. None for a new directory."""
    lock_path = dest / "vault-lock.json"
    if not lock_path.is_file():
        if (dest / "references").exists():
            raise ExchangeError(f"{dest} has references/ and no vault-lock.json; import into a project or a new directory")
        return None
    lock = _read_json(lock_path)
    if (not isinstance(lock, dict) or lock.get("schema_version") != LOCK_SCHEMA_VERSION
            or not isinstance(lock.get("components"), list) or not isinstance(lock.get("publications"), list)):
        raise ExchangeError("vault-lock.json is not the index of a project with one directory per Vault file")
    components, by_identity = {}, {}
    for c in lock["components"]:
        if not isinstance(c, dict) or not isinstance(c.get("key"), str) or not KEY.fullmatch(c["key"]) \
                or c.get("kind") not in COMPONENT_ROOT or c.get("path") != f"{COMPONENT_ROOT[c['kind']]}/{c['key']}" \
                or c["key"] in components:
            raise ExchangeError("Invalid or repeated component in vault-lock.json")
        d = dest.joinpath(*c["path"].split("/"))
        source = _read_json(d / "source.json") if (d / "source.json").is_file() else None
        vault = source.get("vault") if isinstance(source, dict) and isinstance(source.get("vault"), dict) else {}
        same = (isinstance(source, dict) and source.get("key") == c["key"] and source.get("kind") == c["kind"]
                and source.get("model_state") == c.get("model_state")
                and all(vault.get(f) == c.get(f) for f in ("master_id", "version_id", "native_sha256")))
        if same and c["kind"] == "part":
            step = d / "part.step"
            same = step.is_file() and _sha(step.read_bytes()) == c.get("step_sha256")
        if same and c["kind"] == "assembly":
            same = (d / "assembly.json").is_file()
        if not same:
            raise ExchangeError(f"{c['path']} is not what vault-lock.json says it is; restore it before importing")
        rec = {"key": c["key"], "kind": c["kind"], "dir": d, "source": source, "index": c}
        components[c["key"]] = rec
        if c.get("master_id") is None:
            raise ExchangeError(f"{c['key']} has no master id in vault-lock.json; a package cannot be matched to it")
        identity = (c["master_id"], c.get("model_state"))
        if identity in by_identity:
            raise ExchangeError(f"{c['key']} and {by_identity[identity]['key']} are the same Vault file and model state")
        by_identity[identity] = rec
    for kind, top in COMPONENT_ROOT.items():
        base = dest.joinpath(*top.split("/"))
        for d in sorted(base.iterdir()) if base.is_dir() else []:
            if d.is_dir() and d.name not in components:
                raise ExchangeError(f"{top}/{d.name} is not in vault-lock.json; restore the project before importing")
    return {"lock": lock, "components": components, "by_identity": by_identity}


def _authored_keys(dest):
    keys = set()
    for sub in ("parts", "assemblies"):
        base = dest / "designs" / sub
        if base.is_dir():
            keys.update(d.name for d in base.iterdir() if d.is_dir())
    return keys


def _check_project_vault(dest, manifest, root_source):
    """The package is of the vault and the root assembly the project names, when the project names them."""
    path = dest / "vault-project.toml"
    if not path.is_file():
        return False
    try:
        with path.open("rb") as stream:
            vault = tomllib.load(stream).get("vault", {})
    except (OSError, ValueError) as exc:
        raise ExchangeError(f"Cannot load vault-project.toml: {exc}") from exc
    if vault.get("id") != manifest["vault_id"]:
        raise ExchangeError("the package is from another vault than vault-project.toml names")
    have, want = root_source["vault"]["path"], vault.get("root_assembly")
    if not isinstance(have, str) or not isinstance(want, str) or have.casefold() != want.casefold():
        raise ExchangeError("the package's root assembly is not the root_assembly of vault-project.toml")
    return True


def _ordered(record, order):
    return {k: record[k] for k in order if k in record}


def import_package(package, dest, run):
    """Read one exporter package into the project (or the new, empty directory) `dest`.

    run: the name under which package.json is kept (references/receipts/<run>/); it must be new.
    Returns what happened to every file of the package, by key.
    """
    package, dest = Path(package), Path(dest)
    if not RUN.fullmatch(run or ""):
        raise ExchangeError("the run name must be a plain directory name")
    manifest, files, root_identity = _read_package(package)
    if dest.exists() and not dest.is_dir():
        raise ExchangeError(f"{dest} is not a directory")
    project = _read_project(dest) if dest.exists() else None
    if project is None and dest.exists() and any(dest.iterdir()):
        raise ExchangeError(f"{dest} is neither a project with an index nor empty")
    receipts = dest / "references" / "receipts" / run
    if receipts.exists():
        raise ExchangeError(f"references/receipts/{run} exists; every import has its own run name")
    vault_checked = _check_project_vault(dest, manifest, files[root_identity]["source"])

    # keys: the project's own for what it has, a new one from the name for what it does not
    existing = project["by_identity"] if project else {}
    keys = _Keys()
    for key in (set(project["components"]) if project else set()) | _authored_keys(dest):
        keys.used[key] = ("held", key)
    for identity, entry in sorted(files.items(), key=lambda kv: (kv[1]["source"]["name"].lower(), kv[0][0])):
        held = existing.get(identity)
        if held is None:
            entry["key"] = keys.assign(entry["source"]["name"], identity[0], identity[1], ("package", identity))
            if not KEY.fullmatch(entry["key"]) or len(entry["key"]) > 80:
                raise ExchangeError(f"{entry['where']}: no valid key can be made from the name {entry['source']['name']!r}")
            continue
        if held["kind"] != entry["kind"]:
            raise ExchangeError(f"{entry['where']}: the project holds master id {identity[0]} as a {held['kind']} ({held['key']})")
        entry["key"], entry["held"] = held["key"], held

    # what the project gets for each file, and whether that is what it has
    outcome = {"new": [], "updated": [], "rewritten": [], "unchanged": []}
    for identity, entry in files.items():
        source = dict(entry["source"], key=entry["key"], export={"run": run, **entry["source"].get("export", {})})
        entry["write_source"] = _ordered(source, SOURCE_ORDER)
        if entry["kind"] == "assembly":
            children = []
            for child in entry["assembly"]["children"]:
                target = files[(child["master_id"], child.get("model_state"))]
                children.append(_ordered(dict(child, component=target["key"]), CHILD_ORDER))
            manifest_out = {"schema_version": LAYOUT_SCHEMA_VERSION, "key": entry["key"], "name": entry["assembly"].get("name")}
            manifest_out.update({k: entry["assembly"][k] for k in ("length_unit", "frame") if k in entry["assembly"]})
            manifest_out["children"] = children
            entry["write_assembly"] = manifest_out
        held = entry.get("held")
        if held is None:
            outcome["new"].append(entry["key"])
            entry["state"] = "new"
            continue
        have, new = held["source"]["vault"], entry["source"]["vault"]
        if have["version_id"] != new["version_id"]:
            a, b = have.get("version_number"), new.get("version_number")
            if not isinstance(a, int) or not isinstance(b, int) or isinstance(a, bool) or isinstance(b, bool):
                raise ExchangeError(f"{entry['key']}: the project holds version id {have['version_id']} and the package "
                                    f"{new['version_id']}, and a version number is unknown; their order cannot be told")
            if b < a:
                raise ExchangeError(f"{entry['key']}: the project holds version {a}, later than the package's {b}")
            if b == a:
                raise ExchangeError(f"{entry['key']}: two version ids for version {a}")
            entry["state"] = "updated"
        else:
            if have.get("native_sha256") != new["native_sha256"]:
                raise ExchangeError(f"{entry['key']}: the same Vault version with another native file than the project holds")
            same = ({k: v for k, v in held["source"].items() if k != "export"}
                    == {k: v for k, v in entry["write_source"].items() if k != "export"})
            if same and entry["kind"] == "part":
                same = held["index"].get("step_sha256") == entry["source"]["step"]["sha256"]
            if same and entry["kind"] == "assembly":
                same = _read_json(held["dir"] / "assembly.json") == entry["write_assembly"]
            entry["state"] = "unchanged" if same else "rewritten"
        outcome[entry["state"]].append(entry["key"])

    # ---- nothing has been written up to here ----
    dest.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(dest / OPERATION_LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise ExchangeError(f"Another operation or stale {OPERATION_LOCK} exists") from exc
    os.close(fd)
    try:
        for top in COMPONENT_ROOT.values():
            dest.joinpath(*top.split("/")).mkdir(parents=True, exist_ok=True)
        receipts.mkdir(parents=True)
        (receipts / "package.json").write_bytes((package / "package.json").read_bytes())
        to_measure = []
        for entry in files.values():
            if entry["state"] == "unchanged":
                continue
            d = dest.joinpath(*COMPONENT_ROOT[entry["kind"]].split("/")) / entry["key"]
            d.mkdir(exist_ok=True)
            if entry["kind"] == "part":
                step = d / "part.step"
                if not step.is_file() or step.read_bytes() != entry["step"]:
                    tmp = d / "part.step.tmp"
                    tmp.write_bytes(entry["step"])
                    os.replace(tmp, step)
                    to_measure.append(entry["key"])
            else:
                write_json(d / "assembly.json", entry["write_assembly"])
            write_json(d / "source.json", entry["write_source"])
        lock = {"schema_version": LOCK_SCHEMA_VERSION, "components": derive_components(dest),
                "publications": project["lock"]["publications"] if project else []}
        write_json(dest / "vault-lock.json", lock)
    finally:
        (dest / OPERATION_LOCK).unlink()

    in_package = {entry["key"] for entry in files.values()}
    return {
        "destination": str(dest), "run": run, "root": files[root_identity]["key"],
        "parts": sum(e["kind"] == "part" for e in files.values()),
        "assemblies": sum(e["kind"] == "assembly" for e in files.values()),
        **{state: sorted(found) for state, found in outcome.items()},
        "not_in_package": sorted(set(project["components"]) - in_package) if project else [],
        "to_measure": sorted(to_measure),
        "vault_and_root_checked_against_project": vault_checked,
        "not_exported": manifest["not_exported"],
    }


def derive_components(root):
    """The components of the index: what the directories under references/ say, by key."""
    out = []
    for kind, top in COMPONENT_ROOT.items():
        base = Path(root).joinpath(*top.split("/"))
        for d in sorted(base.iterdir(), key=lambda p: p.name) if base.is_dir() else []:
            if not d.is_dir():
                continue
            source = _read_json(d / "source.json")
            vault = source.get("vault") if isinstance(source.get("vault"), dict) else {}
            data = (d / "part.step").read_bytes() if kind == "part" else None
            out.append({"key": d.name, "path": f"{top}/{d.name}", "kind": kind, "model_state": source.get("model_state"),
                        "master_id": vault.get("master_id"), "version_id": vault.get("version_id"),
                        "native_sha256": vault.get("native_sha256"),
                        "step_sha256": _sha(data) if data is not None else None,
                        "step_data_sha256": data_sha256(data) if data is not None else None})
    return sorted(out, key=lambda c: c["key"])
