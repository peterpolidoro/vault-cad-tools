"""Which files of a project are what Vault holds today: a mirror compared with a discovery of its folder.

    vault-cad --project PROJECT sync-status DISCOVERY.json [--output FILE]

DISCOVERY.json is what windows/Discover-VaultFolder.ps1 writes (REST, GET only): the files of a Vault folder,
the root assemblies among them, and for every root its closure, each file at the version Vault names for it
today. Vault names the children of any version of a root at their latest versions, so a root version does not
say what a mirror should hold; every file of the mirror is asked for by itself (found on 2026-11-16).

Nothing is asked of Vault here and nothing of the project is changed. What comes back, and goes to FILE when one
is named, has no time of its own: the same discovery and the same project give the same bytes.

For every component the project mirrors (references/):

    in_sync         the project holds the version Vault names today
    vault_newer     Vault names another version: the file was checked in again
    checked_out     Vault lists the file by the place of a check-out, not by a version checked in
    not_in_closure  the project holds it and the root's closure in Vault no longer does

A file that is checked out is listed by a row that is not a version (windows/Vault-Version.ps1; the discovery
says `version_is` of every row since 2026-11-17). Its id is not that of anything checked in, so it is never
`vault_newer`; and the discovery does not say which version was checked in last, so it is not `in_sync` either,
and `current` is false while any file is `checked_out`. A discovery written before that day has no `version_is`
and is read as before.

`new_in_vault` lists what the root's closure has and the project does not. For every publication of the project
(a part under designs/ with a vault.json): `in_sync` when Vault still holds the version that was published,
`vault_newer` when it holds another, `checked_out` as above, `not_in_folder` when the folder that was discovered
does not have the file;
and whether the part's part.step is still the file that was published. `other_files_in_the_folder` are what the
folder holds that belongs neither to the root's closure nor to a publication, another root assembly for one.
`current` says whether a refresh would change anything in references/.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

from .package_import import _project_roots, _read_json, _read_project
from .project import ExchangeError, atomic_json

SCHEMA_VERSION = 1
KINDS = {"native_part": "part", "native_assembly": "assembly", "step": "step"}


def _text(value):
    return value if isinstance(value, str) and value else None


def _standing(vault, held_version_id, missing):
    """What a file the project holds is beside the row Vault lists for it today."""
    if vault is None:
        return missing
    if vault.get("version_is") not in (None, "checked_in"):         # the place of a check-out, or a row without a date
        return "checked_out"
    return "in_sync" if vault["version_id"] == held_version_id else "vault_newer"


def _discovery(path):
    data = _read_json(Path(path))
    if (not isinstance(data, dict) or data.get("schema_version") != 1 or not isinstance(data.get("files"), list)
            or not isinstance(data.get("roots"), list) or not _text(data.get("vault_id"))):
        raise ExchangeError(f"{path} is not a discovery.json of windows/Discover-VaultFolder.ps1 (schema 1)")
    for where, rows in (("files", data["files"]), *((f"the closure of {r.get('name')!r}", r.get("closure"))
                                                   for r in data["roots"] if isinstance(r, dict))):
        if not isinstance(rows, list) or not all(isinstance(f, dict) and _text(f.get("master_id")) and _text(f.get("version_id"))
                                                 for f in rows):
            raise ExchangeError(f"{path}: {where} must list files with a master id and a version id")
    return data


def sync_status(project_dir, discovery_path, output=None):
    project_dir = Path(project_dir)
    project = _read_project(project_dir)
    if project is None:
        raise ExchangeError(f"{project_dir} has no vault-lock.json: it is not a project with a mirror")
    discovery = _discovery(discovery_path)
    roots = _project_roots(project)
    if len(roots) != 1:
        raise ExchangeError("the project mirrors " + (f"{len(roots)} root assemblies ({', '.join(sorted(roots.values()))})"
                                                      if roots else "no root assembly") + "; sync-status reads a mirror of one")
    (root_master, _state), root_key = next(iter(roots.items()))
    held_root = project["components"][root_key]
    vault_id = (held_root["source"].get("vault") or {}).get("vault_id")
    if vault_id is not None and str(vault_id) != discovery["vault_id"]:
        raise ExchangeError(f"the discovery is of vault {discovery['vault_id']} and the project mirrors vault {vault_id}")
    found = [r for r in discovery["roots"] if isinstance(r, dict) and r.get("master_id") == root_master]
    if not found:
        raise ExchangeError(f"the discovery has no root assembly with master id {root_master} ({root_key}); "
                            "it is of another folder, or the assembly is used by another file there now")
    vault_root = found[0]
    if vault_root.get("closure_read") is not True:
        raise ExchangeError(f"the discovery did not read the closure of {root_key}; nothing can be said of its files")

    today = {vault_root["master_id"]: {"version_id": vault_root["version_id"], "name": vault_root.get("name"),
                                       "kind": "native_assembly"}}
    for f in vault_root["closure"]:
        if f["master_id"] in today and today[f["master_id"]]["version_id"] != f["version_id"]:
            raise ExchangeError(f"the discovery names master {f['master_id']} at two versions in one closure")
        today[f["master_id"]] = f
    folder = {f["master_id"]: f for f in discovery["files"]}
    for master, f in folder.items():                # the folder's listing has what the closure rows leave out
        if master in today:
            today[master] = {**f, **today[master]}

    components, held_masters = [], set()
    for key in sorted(project["components"]):
        index = project["components"][key]["index"]
        held_masters.add(index["master_id"])
        vault = today.get(index["master_id"])
        row = {"key": key, "kind": index["kind"], "master_id": index["master_id"], "held_version_id": index["version_id"],
               "vault_version_id": vault["version_id"] if vault else None,
               "state": _standing(vault, index["version_id"], "not_in_closure")}
        if vault and (vault.get("is_checked_out") or row["state"] == "checked_out"):
            row["checked_out_in_vault"] = True
        components.append(row)
    new = sorted(({"name": f.get("name"), "kind": KINDS.get(f.get("kind"), f.get("kind")), "master_id": master,
                   "version_id": f["version_id"]} for master, f in today.items() if master not in held_masters),
                 key=lambda r: (r["name"] or "", r["master_id"]))

    publications, published_masters = [], set()
    for pub in sorted(project["lock"]["publications"], key=lambda p: (p.get("key") or "", p.get("version_id") or "")):
        published_masters.add(pub.get("master_id"))
        vault = folder.get(pub.get("master_id"))
        step = project_dir.joinpath(*str(pub.get("path", "")).split("/")) / "part.step"
        publications.append({
            "key": pub.get("key"), "master_id": pub.get("master_id"), "published_version_id": pub.get("version_id"),
            "vault_version_id": vault["version_id"] if vault else None,
            "state": _standing(vault, pub.get("version_id"), "not_in_folder"),
            "part_step_is_the_published_file": step.is_file() and hashlib.sha256(step.read_bytes()).hexdigest() == pub.get("step_sha256")})
    others = sorted(({"name": f.get("name"), "kind": KINDS.get(f.get("kind"), f.get("kind")), "role": f.get("role"),
                      "master_id": master} for master, f in folder.items()
                     if master not in today and master not in published_masters), key=lambda r: (r["name"] or "", r["master_id"]))

    counts = {state: sum(1 for c in components if c["state"] == state) for state in ("in_sync", "vault_newer", "checked_out", "not_in_closure")}
    counts["new_in_vault"] = len(new)
    result = {"schema_version": SCHEMA_VERSION,
              "discovery": {"generated_at": discovery.get("generated_at"), "vault_id": discovery["vault_id"]},
              "root": {"key": root_key, "master_id": root_master},
              "current": counts["in_sync"] == len(components) and not new,
              "counts": counts, "components": components, "new_in_vault": new,
              "publications": publications, "other_files_in_the_folder": others}
    if output:
        atomic_json(Path(output), result)
    return result
