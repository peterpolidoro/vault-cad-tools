"""Join a READ-ONLY native BOM audit (windows/Audit-NativeBom.ps1), the exporter snapshot and the Vault
association discovery (windows/Discover-VaultAssociations.ps1) into the reviewable files the Linux
coordinator asked for: virtual-and-excluded.json, kit-boundaries.json, drawings.json,
coincident-tank.json, joint-coverage.json and bom-audit-summary.json.

Everything here is observation over recorded data. Nothing derives purchase quantities, stock or
specifications; "hardware_named" is a NAME-based identification of modeled rows and is labelled so.
Joint coverage categories follow the coordinator's list:
  a   hardware for the joint is in the native BOM but was not exported (virtual or unexported row)
  a2  hardware for the joint is in the native BOM and exported (modeled part rows)
  b   hardware appears only in a drawing parts list (needs drawings; none may exist)
  c   supplied inside a purchased kit per model/vendor data (needs named kit bodies or vendor data)
  d   absent from every native source inspected (no row, no virtual component, no compound part, no drawing)
  e   unknown: compound parts present whose bodies are unnamed, or groups not found in the audit
"""
import csv
import json
import shutil
from pathlib import Path

from .project import ExchangeError, atomic_json, now, read_json

HARDWARE_WORDS = ("screw", "bolt", "nut", "washer", "rivet", "fastener", "insert", "stud", "t-nut", "tnut",
                  "retaining ring", "shcs", "bhcs", "fhcs", "set screw", "threaded rod", "anchor", "pin ")
SUMMARY_SCHEMA = 1


def _load(directory, name, required=True):
    path = Path(directory) / name
    if not path.exists():
        if required:
            raise ExchangeError(f"Audit output missing: {path}")
        return None
    data = read_json(path)
    return data if data is not None else []


def hardware_named(*texts):
    """Name-based identification only: does any text contain a fastener-like word?"""
    blob = " " + " ".join(str(t).lower() for t in texts if t) + " "
    return any(word in blob for word in HARDWARE_WORDS)


def row_names(row):
    parts = []
    for d in row.get("component_definitions") or []:
        props = d.get("properties") or {}
        parts += [d.get("display_name"), d.get("document"), props.get("part_number"), props.get("description"), props.get("stock_number")]
    parts.append((row.get("referenced_file") or {}).get("path"))
    return [p for p in parts if p]


def document_summaries(rows, parts):
    """Per assembly document: structured level-1 rows and what they contain."""
    parts_by_doc = {p["document"]: p for p in parts if p.get("document")}
    docs = {}
    for row in rows:
        if row.get("view") != "Structured" or row.get("level") != 1:
            continue
        doc = docs.setdefault(row["document"], {"document": row["document"], "rows": 0, "item_quantity_sum": 0, "virtual_rows": 0,
                                                "reference_rows": 0, "phantom_rows": 0, "purchased_rows": 0,
                                                "hardware_named_rows": [], "compound_parts": [], "components": []})
        doc["rows"] += 1
        doc["item_quantity_sum"] += int(row.get("item_quantity") or 0)
        structure = (row.get("bom_structure") or {}).get("name") or ""
        doc["virtual_rows"] += 1 if row.get("is_virtual") else 0
        doc["reference_rows"] += 1 if structure == "Reference" else 0
        doc["phantom_rows"] += 1 if structure == "Phantom" else 0
        doc["purchased_rows"] += 1 if structure in ("Purchased", "Inseparable") else 0
        component_doc = next((d.get("document") for d in row.get("component_definitions") or [] if d.get("document")), None)
        entry = {"item_number": row.get("item_number"), "item_quantity": row.get("item_quantity"), "total_quantity": row.get("total_quantity"),
                 "bom_structure": structure or None, "component": component_doc, "is_virtual": bool(row.get("is_virtual")),
                 "hardware_named": hardware_named(*row_names(row))}
        doc["components"].append(entry)
        if entry["hardware_named"]:
            doc["hardware_named_rows"].append(entry)
        part = parts_by_doc.get(component_doc)
        if part and (part.get("multi_body") or int(part.get("solid_bodies") or 0) > 1):
            doc["compound_parts"].append({"component": component_doc, "solid_bodies": part.get("solid_bodies"),
                                          "hidden_solid_bodies": part.get("hidden_solid_bodies"), "visible_solid_bodies": part.get("visible_solid_bodies"),
                                          "bom_structure": (part.get("bom_structure") or {}).get("name"),
                                          "body_names": [b.get("name") for b in part.get("bodies") or []]})
    return docs


def group_summaries(occurrences, docs):
    groups = []
    for occ in occurrences:
        if occ.get("definition_kind") not in ("assembly", "weldment"):
            continue
        doc = docs.get(occ.get("document")) or {}
        children = [o for o in occurrences if o.get("parent_id") == occ.get("id")]
        groups.append({"group_id": occ.get("id"), "document": occ.get("document"), "source": occ.get("source"),
                       "bom_structure": (occ.get("bom_structure") or {}).get("name"), "suppressed": occ.get("suppressed"),
                       "reference": occ.get("reference"), "excluded": occ.get("excluded"), "child_occurrences": len(children),
                       "child_suppressed": sum(1 for o in children if o.get("suppressed")),
                       "child_reference": sum(1 for o in children if o.get("reference")),
                       "child_virtual": sum(1 for o in children if o.get("definition_kind") == "virtual"),
                       "structured_rows": doc.get("rows", 0), "virtual_rows": doc.get("virtual_rows", 0),
                       "hardware_named_rows": doc.get("hardware_named_rows", []), "compound_parts": doc.get("compound_parts", []),
                       "components": doc.get("components", [])})
    return groups


def body_names_informative(names):
    """Generic Inventor body names (Solid1, Body2 ...) identify nothing; anything else is treated as a named body."""
    import re
    return [n for n in names or [] if n and not re.fullmatch(r"(?i)(solid|body|surface)\d*", str(n).strip())]


def joint_coverage(joints, groups, root_summary, exported_part_documents, drawings_available, drawings_checked=False):
    by_id = {g["group_id"]: g for g in groups}
    coverage = {}
    for joint in joints or []:
        if joint.get("scope") not in (None, "existing"):
            continue
        group_ids = list(joint.get("parent_group_ids") or [])
        found = [by_id[g] for g in group_ids if g in by_id]
        root_named = any(g in ("root", "ROOT") for g in group_ids)
        missing = [g for g in group_ids if g not in by_id and g not in ("root", "ROOT")]
        summaries = found + ([root_summary] if root_named and root_summary else [])
        hardware = []
        for s in summaries:
            hardware += [dict(h, group_id=s.get("group_id", "root")) for h in s.get("hardware_named_rows", [])]
        virtual_rows = sum(s.get("virtual_rows", 0) for s in summaries)
        compounds = []
        for s in summaries:
            compounds += [dict(c, group_id=s.get("group_id", "root")) for c in s.get("compound_parts", [])]
        exported = [h for h in hardware if h.get("component") in exported_part_documents]
        unexported = [h for h in hardware if h.get("component") not in exported_part_documents]
        named_kit_bodies = [c for c in compounds if body_names_informative(c.get("body_names"))]
        if virtual_rows or unexported:
            category, basis = "a", "virtual components or hardware-named rows exist in the native BOM of the named groups and are not among the exported parts"
        elif exported:
            category, basis = "a2", ("hardware-named rows exist in the native BOM of the named groups and are exported parts; whether those rows "
                                     "belong to THIS joint rather than another joint in the same group is not decidable from the BOM (see hardware_named_rows_exported)")
        elif named_kit_bodies:
            category, basis = "c", "compound parts in the named groups carry NAMED bodies that identify hardware"
        elif missing and not found and not root_named:
            category, basis = "e", "none of the named groups exists in the audited tree"
        elif compounds:
            category, basis = "e", "compound (multi-body) parts are present but their bodies are unnamed and no vendor kit data is in the model; whether hardware is supplied in the kit is undecidable from CAD"
        else:
            category, basis = "d", "no row, virtual component, compound part or drawing parts list in any native source inspected"
        if category in ("d", "e"):
            if drawings_checked and not drawings_available:
                basis += "; no drawing or presentation is associated with any version of the acquired files, so category b cannot apply"
            elif not drawings_checked:
                basis += "; drawings not checked (no complete all-versions discovery supplied), so category b stays possible"
        coverage[joint.get("id")] = {
            "supplementary_item_id": joint.get("supplementary_item_id"), "category": category, "basis": basis,
            "groups_named": group_ids, "groups_found": [g["group_id"] for g in found], "groups_not_in_audit": missing,
            "virtual_components": virtual_rows, "hardware_named_rows_exported": exported, "hardware_named_rows_not_exported": unexported,
            "compound_parts": compounds,
            "confidence": {"a": "high", "a2": "high", "c": "medium", "d": "high that CAD has nothing; unknown whether hardware is supplied",
                           "e": "low: undecidable from CAD", "b": "n/a"}[category],
            "no_inference": "thread, length, grade and quantity are not inferred from appearance",
        }
    return coverage


def _to_matrix(value):
    return [[float(x) for x in r] for r in value]


def coincident_occurrences(snapshot, occurrences, tolerance_mm=1e-6, rotation_tolerance=1e-9):
    flags = {o.get("id"): o for o in occurrences}
    by_part = {}
    for occ in snapshot.get("occurrences") or []:
        if occ.get("kind") == "part" and occ.get("transform_world_cm"):
            by_part.setdefault(occ["part_id"], []).append(occ)
    pairs = []
    for part_id, occs in by_part.items():
        for i in range(len(occs)):
            for j in range(i + 1, len(occs)):
                a, b = _to_matrix(occs[i]["transform_world_cm"]), _to_matrix(occs[j]["transform_world_cm"])
                translation = max(abs(a[r][3] - b[r][3]) * 10.0 for r in range(3))
                rotation = max(abs(a[r][c] - b[r][c]) for r in range(3) for c in range(3))
                if translation <= tolerance_mm and rotation <= rotation_tolerance:
                    fa, fb = flags.get(occs[i]["id"], {}), flags.get(occs[j]["id"], {})
                    pairs.append({"part_id": part_id, "occurrences": [occs[i]["id"], occs[j]["id"]],
                                  "translation_difference_mm": translation, "rotation_difference": rotation,
                                  "bom_structure": [(fa.get("bom_structure") or {}).get("name"), (fb.get("bom_structure") or {}).get("name")],
                                  "reference": [fa.get("reference"), fb.get("reference")], "suppressed": [fa.get("suppressed"), fb.get("suppressed")],
                                  "visible": [fa.get("visible"), fb.get("visible")], "grounded": [fa.get("grounded"), fb.get("grounded")],
                                  "constraints": [fa.get("constraints"), fb.get("constraints")]})
    return pairs


def part_totals(rows, part_document):
    return [{"document": row.get("document"), "view": row.get("view"), "item_number": row.get("item_number"), "item_quantity": row.get("item_quantity"),
             "total_quantity": row.get("total_quantity"), "bom_structure": (row.get("bom_structure") or {}).get("name"), "rolled_up": row.get("rolled_up")}
            for row in rows if row.get("view") == "PartsOnly"
            for d in row.get("component_definitions") or [] if d.get("document") == part_document]


def vault_history(discovery_dir, master_id):
    """Version history of a master from the discovery's raw files/{id}/versions capture (read-only)."""
    if not discovery_dir or not master_id:
        return None
    path = Path(discovery_dir) / "raw" / f"master-{master_id}-versions.json"
    if not path.exists():
        return None
    versions = read_json(path) or []
    if isinstance(versions, dict):  # a single-version master serializes as one object
        versions = [versions]
    return [{"version": v.get("version"), "version_id": str(v.get("id")), "created": v.get("createDate"), "last_modified": v.get("lastModifiedDate"),
             "checkin": v.get("checkinDate"), "created_by": v.get("createUserName"), "state": v.get("state")} for v in versions if isinstance(v, dict)]


def coincident_report(pairs, occurrences, rows, discovery_dir):
    flags = {o.get("id"): o for o in occurrences}
    report = []
    for pair in pairs:
        part_doc = pair["part_id"].split("|")[0]
        details = []
        for occ_id in pair["occurrences"]:
            f = flags.get(occ_id, {})
            parent = flags.get(f.get("parent_id"), {}) if f.get("parent_id") not in (None, "root") else None
            details.append({"occurrence": occ_id, "suppressed": f.get("suppressed"), "enabled": f.get("enabled"), "visible": f.get("visible"), "excluded": f.get("excluded"),
                            "reference": f.get("reference"), "bom_structure": (f.get("bom_structure") or {}).get("name"), "grounded": f.get("grounded"),
                            "constraints": f.get("constraints"), "constraint_types": f.get("constraint_types"), "joints": f.get("joints"),
                            "model_state": f.get("active_model_state"), "design_view": f.get("design_view"), "source": f.get("source"),
                            "parent_group": None if parent is None else {"id": parent.get("id"), "bom_structure": (parent.get("bom_structure") or {}).get("name"),
                                                                           "reference": parent.get("reference"), "suppressed": parent.get("suppressed"), "flexible": parent.get("flexible"), "source": parent.get("source")}})
        all_normal = all(d["bom_structure"] == "Normal" and not d["reference"] and not d["suppressed"] and d["visible"] for d in details)
        masters = {d["source"]["master_id"] for d in details if d.get("source")}
        parent_masters = {d["parent_group"]["source"]["master_id"] for d in details if d.get("parent_group") and d["parent_group"].get("source")}
        history = {m: vault_history(discovery_dir, m) for m in masters | parent_masters}
        report.append({**pair, "occurrence_details": details, "parts_only_totals": part_totals(rows, part_doc),
                       "vault_history": history,
                       "conclusion": "unresolved" if all_normal else "see flags",
                       "evidence": ("both placements are Normal, visible, enabled, not Reference and not suppressed, so the native BOM counts both; "
                                    "the geometry is coincident, which is consistent with either a redundant duplicate or an intentional alternate placement; "
                                    "no native flag marks one of them as reference-only, therefore CAD alone cannot decide" if all_normal else
                                    "at least one placement is marked Reference, suppressed or hidden; see occurrence_details")})
    return report


def drawings_json(discovery_dir):
    if not discovery_dir:
        return {"available": False, "note": "no Vault association discovery supplied"}
    per_file = _load(discovery_dir, "drawings-and-attachments.json")
    external = _load(discovery_dir, "external-parents.json")
    receipt = _load(discovery_dir, "discovery-receipt.json", required=False) or {}
    other = _load(discovery_dir, "drawings-on-other-versions.json", required=False) or []
    attachment_kinds = {}
    for f in per_file:
        for a in f.get("attachments") or []:
            attachment_kinds[a.get("kind")] = attachment_kinds.get(a.get("kind"), 0) + 1
    drawings = [e for e in external if e.get("kind") in ("drawing", "presentation")]
    # M3: "no drawing on any version" may only be claimed from a COMPLETE discovery that checked every version.
    complete = receipt.get("status") == "complete" and bool(receipt.get("all_versions_pass"))
    return {"available": True, "complete_all_versions": complete,
            "method": "Vault REST GET only: file-versions/{id}/parents and /uses for every acquired version (exact associations), "
                      "plus parents of every other version of each acquired master (files/{master}/versions)",
            "status": receipt.get("status"), "all_versions_pass": receipt.get("all_versions_pass"), "acquired_versions": len(per_file), "counts": receipt.get("counts"),
            "drawings_or_presentations_on_acquired_versions": drawings, "drawings_or_presentations_on_other_versions": other,
            "attachment_kinds": attachment_kinds,
            "external_parent_assemblies": [{"name": e.get("name"), "version": e.get("version"), "folder": e.get("folder_path"), "version_id": e.get("version_id")} for e in external if e.get("kind") == "assembly"],
            "parts_lists_read": [] if not drawings and not other else "not read: see report",
            "note": ("no drawing or presentation exists on any version of the acquired masters, so no parts list or balloon could be read"
                     if complete and not drawings and not other else
                     ("drawings not checked completely: discovery receipt is not complete with an all-versions pass; category b stays possible"
                      if not complete else None))}


def summarize(audit_dir, snapshot_path, output_dir, joints_path=None, discovery_dir=None):
    audit_dir = Path(audit_dir)
    receipt = _load(audit_dir, "audit-receipt.json")
    if receipt.get("status") != "complete":
        raise ExchangeError(f"Audit receipt status is {receipt.get('status')!r}; refusing to summarize an incomplete audit")
    if not (receipt.get("post_run_integrity") or {}).get("inputs_unchanged_after_run"):
        raise ExchangeError("Audit receipt does not prove the acquired inputs were unchanged after the run")
    rows = _load(audit_dir, "bom-rows.json")
    occurrences = _load(audit_dir, "occurrence-bom-flags.json")
    parts = _load(audit_dir, "purchased-parts-bodies.json")
    virtuals = _load(audit_dir, "virtual-components.json")
    views = _load(audit_dir, "bom-views.json")
    snapshot = read_json(snapshot_path)
    joints_doc = read_json(joints_path) if joints_path else None
    joints = (joints_doc or {}).get("joints") if isinstance(joints_doc, dict) else joints_doc
    docs = document_summaries(rows, parts)
    root_name = str((snapshot.get("assembly") or {}).get("document", "")).replace("/", "\\").split("\\")[-1].lower()
    root_doc = next((d for d in docs if d.replace("/", "\\").split("\\")[-1].lower() == root_name), None)
    root_summary = dict(docs.get(root_doc) or {}, group_id="root") if root_doc else {}
    groups = group_summaries(occurrences, docs)
    exported_part_documents = {str(p.get("id", "")).split("|")[0] for p in snapshot.get("parts") or []}
    native_part_documents = {d.get("document") for r in rows if r.get("view") == "PartsOnly" and r.get("document") == root_doc
                             for d in r.get("component_definitions") or [] if d.get("document")}
    drawings = drawings_json(discovery_dir)
    drawings_available = bool((drawings.get("drawings_or_presentations_on_acquired_versions") or drawings.get("drawings_or_presentations_on_other_versions")))
    drawings_checked = bool(drawings.get("complete_all_versions"))
    coverage = joint_coverage(joints, groups, root_summary, exported_part_documents, drawings_available, drawings_checked)
    pairs = coincident_occurrences(snapshot, occurrences)
    coincident = coincident_report(pairs, occurrences, rows, discovery_dir)
    virtual_and_excluded = {
        "schema_version": SUMMARY_SCHEMA, "generated_at": now(),
        "virtual_components": virtuals,
        "suppressed_occurrences": [{"id": o["id"], "parent_id": o.get("parent_id"), "document": o.get("document")} for o in occurrences if o.get("suppressed")],
        "excluded_occurrences": [{"id": o["id"], "parent_id": o.get("parent_id"), "document": o.get("document")} for o in occurrences if o.get("excluded")],
        "reference_occurrences": [{"id": o["id"], "parent_id": o.get("parent_id"), "document": o.get("document")} for o in occurrences if o.get("reference")],
        "reference_or_phantom_rows": [{"document": r.get("document"), "view": r.get("view"), "item_number": r.get("item_number"), "bom_structure": (r.get("bom_structure") or {}).get("name")}
                                      for r in rows if (r.get("bom_structure") or {}).get("name") in ("Reference", "Phantom")],
        "hide_suppressed_components_in_bom": {v.get("document"): (v.get("stored_flags") or {}).get("hide_suppressed_components_in_bom") for v in views},
        "note": "an empty list is an observation: the API reported no such component in the acquired snapshot",
    }
    kits = []
    for p in parts:
        names = [b.get("name") for b in p.get("bodies") or []]
        informative = body_names_informative(names)
        props = p.get("properties") or {}
        kits.append({"document": p.get("document"), "source": p.get("source"), "part_number": props.get("part_number"), "description": props.get("description"),
                     "vendor": props.get("vendor"), "manufacturer": props.get("manufacturer"), "stock_number": props.get("stock_number"), "material": props.get("material"),
                     "custom_iproperties": props.get("custom"), "bom_structure": (p.get("bom_structure") or {}).get("name"),
                     "bom_structure_purchased_or_inseparable": p.get("bom_structure_purchased_or_inseparable"),
                     "solid_bodies": p.get("solid_bodies"), "visible_solid_bodies": p.get("visible_solid_bodies"), "hidden_solid_bodies": p.get("hidden_solid_bodies"),
                     "body_names": names, "named_bodies": informative,
                     "embedded_hardware_modeled": ("unknown: compound geometry with unnamed bodies; vendor kit contents are not in the model data" if (p.get("multi_body") or int(p.get("solid_bodies") or 0) > 1) and not informative
                                                   else ("named bodies present: " + ", ".join(informative) if informative else "single body: no embedded hardware modeled")),
                     "quantity": p.get("quantity")})
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    for name in ("bom-rows.json", "bom-rows.csv"):
        src = audit_dir / name
        if src.exists() and not (output_dir / name).exists():
            shutil.copyfile(src, output_dir / name)
    atomic_json(output_dir / "virtual-and-excluded.json", virtual_and_excluded)
    atomic_json(output_dir / "kit-boundaries.json", {"schema_version": SUMMARY_SCHEMA, "generated_at": now(), "parts": kits,
                                                     "note": "Vendor iProperty names the in-house shop for fabricated parts as well; it is recorded, not used as a classifier"})
    atomic_json(output_dir / "drawings.json", drawings)
    atomic_json(output_dir / "coincident-tank.json", {"schema_version": SUMMARY_SCHEMA, "generated_at": now(), "pairs": coincident})
    atomic_json(output_dir / "joint-coverage.json", {"schema_version": SUMMARY_SCHEMA, "generated_at": now(), "categories": {
        "a": "in native BOM, not exported", "a2": "in native BOM and exported", "b": "drawing parts list only", "c": "supplied inside a purchased kit per model/vendor data",
        "d": "absent from all native sources", "e": "unknown"}, "joints": coverage})
    summary = {"schema_version": SUMMARY_SCHEMA, "generated_at": now(), "audit_directory": str(audit_dir), "audit_status": receipt.get("status"),
               "inputs_unchanged_after_run": True, "counts": receipt.get("counts"),
               "assembly_documents": [{"document": v.get("document"), "stored_flags": v.get("stored_flags"), "enabled_in_memory_only": v.get("enabled_in_memory_only"), "views": v.get("views")} for v in views],
               "native_parts": len(native_part_documents), "exported_parts": len(exported_part_documents),
               "native_parts_not_exported": sorted(native_part_documents - exported_part_documents),
               "exported_parts_not_in_native_parts_only_view": sorted(exported_part_documents - native_part_documents),
               "groups": groups, "joint_coverage_categories": {k: v["category"] for k, v in coverage.items()},
               "coincident_pairs": len(coincident), "virtual_components": len(virtuals), "drawings_available": drawings_available,
               "drawings_checked_all_versions": drawings_checked,
               "caveats": ["CAD instance counts and native BOM quantities are not purchase quantities or stock.",
                           "hardware_named is a name-based identification of modeled rows, not a specification.",
                           "Absence of a row proves only that CAD does not model the item; kit contents must be checked physically or against vendor documents."]}
    atomic_json(output_dir / "bom-audit-summary.json", summary)
    return summary
