"""Tests for the BOM audit summarizer with synthetic audit outputs (no Inventor, no Vault)."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from vault_cad_tools.bom_audit import body_names_informative, coincident_occurrences, hardware_named, summarize  # noqa: E402
from vault_cad_tools.project import ExchangeError, atomic_json  # noqa: E402

I = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
SHIFTED = [[1, 0, 0, 5], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]


def row(document, view, level, item, qty, component, structure="Normal", virtual=False, part_number=None, description=None):
    return {"document": document, "view": view, "level": level, "parent_item": None, "item_number": item, "item_quantity": qty,
            "total_quantity": str(qty), "bom_structure": {"name": structure}, "is_virtual": virtual, "rolled_up": view == "PartsOnly",
            "component_definitions": [{"kind": "virtual" if virtual else "part", "document": component, "display_name": component,
                                       "properties": {"part_number": part_number, "description": description}}],
            "referenced_file": None if virtual else {"path": component}, "component_occurrences": []}


def occ(id_, parent, kind, document, structure="Normal", **flags):
    base = {"id": id_, "parent_id": parent, "definition_kind": kind, "document": document, "bom_structure": {"name": structure},
            "suppressed": False, "reference": False, "excluded": False, "visible": True, "enabled": True, "grounded": False,
            "constraints": 2, "constraint_types": [1, 2], "joints": 0, "active_model_state": "[Primary]",
            "source": {"master_id": "m-" + document} if document else None}
    base.update(flags)
    return base


class BomAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.audit = self.base / "audit"
        self.audit.mkdir()
        rows = [
            row("ROOT.iam", "Structured", 1, "1", 1, "GROUP.iam"),
            row("ROOT.iam", "Structured", 1, "2", 2, "TANK.ipt"),
            row("ROOT.iam", "Structured", 1, "3", 1, "WASHER.ipt", part_number="90313A107", description="Oversized Washer"),
            row("ROOT.iam", "PartsOnly", 1, "1", 3, "TANK.ipt"),
            row("ROOT.iam", "PartsOnly", 1, "2", 1, "CASTER.ipt"),
            row("ROOT.iam", "PartsOnly", 1, "3", 1, "PLATE.ipt"),
            row("ROOT.iam", "PartsOnly", 1, "4", 1, "WASHER.ipt"),
            row("GROUP.iam", "Structured", 1, "1", 1, "CASTER.ipt"),
            row("GROUP.iam", "Structured", 1, "2", 1, "PLATE.ipt"),
            row("OTHER.iam", "Structured", 1, "1", 4, None, virtual=True, part_number="M6 screw", description="Virtual hardware"),
            row("BARE.iam", "Structured", 1, "1", 1, "PLATE.ipt"),
        ]
        atomic_json(self.audit / "bom-rows.json", rows)
        (self.audit / "bom-rows.csv").write_text("document,view\n", encoding="utf-8")
        atomic_json(self.audit / "occurrence-bom-flags.json", [
            occ("GROUP:1", "root", "assembly", "GROUP.iam"),
            occ("GROUP:1/CASTER:1", "GROUP:1", "part", "CASTER.ipt"),
            occ("GROUP:1/PLATE:1", "GROUP:1", "part", "PLATE.ipt"),
            occ("TANK:1", "root", "part", "TANK.ipt"),
            occ("TANK:2", "root", "part", "TANK.ipt"),
            occ("TANK:3", "root", "part", "TANK.ipt", structure="Reference", reference=True),
            occ("WASHER:1", "root", "part", "WASHER.ipt"),
            occ("OTHER:1", "root", "assembly", "OTHER.iam"),
            occ("OTHER:1/V:1", "OTHER:1", "virtual", None),
            occ("BARE:1", "root", "assembly", "BARE.iam"),
            occ("BARE:1/PLATE:1", "BARE:1", "part", "PLATE.ipt", suppressed=True),
        ])
        atomic_json(self.audit / "purchased-parts-bodies.json", [
            {"document": "CASTER.ipt", "bom_structure": {"name": "Normal"}, "multi_body": True, "solid_bodies": 5, "hidden_solid_bodies": 3, "visible_solid_bodies": 2,
             "bodies": [{"name": "Solid1"}, {"name": "Solid2"}], "properties": {"vendor": "HHMI: JRC - JET", "custom": {"Kit": "yes"}}},
            {"document": "PLATE.ipt", "bom_structure": {"name": "Normal"}, "multi_body": False, "solid_bodies": 1, "hidden_solid_bodies": 0, "visible_solid_bodies": 1,
             "bodies": [{"name": "Solid1"}], "properties": {}},
            {"document": "WASHER.ipt", "bom_structure": {"name": "Normal"}, "multi_body": False, "solid_bodies": 1, "hidden_solid_bodies": 0, "visible_solid_bodies": 1,
             "bodies": [{"name": "Solid1"}], "properties": {"part_number": "90313A107"}},
            {"document": "TANK.ipt", "bom_structure": {"name": "Normal"}, "multi_body": False, "solid_bodies": 1, "hidden_solid_bodies": 0, "visible_solid_bodies": 1,
             "bodies": [{"name": "Solid1"}], "properties": {"vendor": "ADVANCED ACRYLICS"}},
        ])
        atomic_json(self.audit / "virtual-components.json", [{"where": "bom_row", "document": "OTHER.iam"}])
        atomic_json(self.audit / "bom-views.json", [{"document": "ROOT.iam", "stored_flags": {"structured_view_enabled": True, "hide_suppressed_components_in_bom": True},
                                                      "enabled_in_memory_only": [], "views": []}])
        self.receipt = {"status": "complete", "post_run_integrity": {"inputs_unchanged_after_run": True}, "counts": {"bom_rows": len(rows)}}
        atomic_json(self.audit / "audit-receipt.json", self.receipt)
        self.snapshot = self.base / "native-snapshot.json"
        atomic_json(self.snapshot, {"assembly": {"document": "C:\\x\\ROOT.iam"},
                                    "parts": [{"id": "TANK.ipt|[Primary]"}, {"id": "CASTER.ipt|[Primary]"}, {"id": "PLATE.ipt|[Primary]"}, {"id": "WASHER.ipt|[Primary]"}],
                                    "occurrences": [
                                        {"id": "TANK:1", "kind": "part", "part_id": "TANK.ipt|[Primary]", "transform_world_cm": I},
                                        {"id": "TANK:2", "kind": "part", "part_id": "TANK.ipt|[Primary]", "transform_world_cm": I},
                                        {"id": "TANK:3", "kind": "part", "part_id": "TANK.ipt|[Primary]", "transform_world_cm": SHIFTED},
                                        {"id": "GROUP:1/PLATE:1", "kind": "part", "part_id": "PLATE.ipt|[Primary]", "transform_world_cm": I}]})
        self.joints = self.base / "joint-audit.json"
        atomic_json(self.joints, {"joints": [
            {"id": "caster_to_plate", "supplementary_item_id": "SUP-001", "scope": "existing", "parent_group_ids": ["GROUP:1"]},
            {"id": "virtual_covered", "supplementary_item_id": "SUP-099", "scope": "existing", "parent_group_ids": ["OTHER:1"]},
            {"id": "washers_at_root", "supplementary_item_id": "SUP-011", "scope": "existing", "parent_group_ids": ["root"]},
            {"id": "bare_group", "supplementary_item_id": "SUP-050", "scope": "existing", "parent_group_ids": ["BARE:1"]},
            {"id": "unknown_group", "supplementary_item_id": "SUP-098", "scope": "existing", "parent_group_ids": ["NOPE:1"]},
            {"id": "new_design", "supplementary_item_id": "SUP-017", "scope": "new_design", "parent_group_ids": []},
        ]})
        self.discovery = self.base / "discovery"
        (self.discovery / "raw").mkdir(parents=True)
        atomic_json(self.discovery / "drawings-and-attachments.json", [{"name": "TANK.ipt", "version_id": "1", "parents": [], "drawings": [], "attachments": [{"kind": "visualization"}]}])
        atomic_json(self.discovery / "external-parents.json", [{"name": "OTHER ASSY.iam", "kind": "assembly", "version": 2, "folder_path": "$/X", "version_id": "9"}])
        atomic_json(self.discovery / "discovery-receipt.json", {"status": "complete", "all_versions_pass": True, "counts": {"drawings_or_presentations": 0}})
        atomic_json(self.discovery / "drawings-on-other-versions.json", [])
        atomic_json(self.discovery / "raw" / "master-m-TANK.ipt-versions.json", [{"id": "1", "version": 1, "createDate": "2023-01-01", "lastModifiedDate": "2023-01-01", "createUserName": "A", "state": "WIP"}])
        self.out = self.base / "out"

    def test_name_based_helpers(self):
        self.assertTrue(hardware_named("MCMASTER 90313A107_18-8 Stainless Steel Oversized Washer"))
        self.assertFalse(hardware_named("CASTER MOUNTING PLATE"))
        self.assertEqual(body_names_informative(["Solid1", "Body12", "Nut", None]), ["Nut"])

    def test_requested_files_and_joint_categories(self):
        summary = summarize(self.audit, self.snapshot, self.out, joints_path=self.joints, discovery_dir=self.discovery)
        for name in ("bom-rows.json", "bom-rows.csv", "virtual-and-excluded.json", "drawings.json", "kit-boundaries.json", "coincident-tank.json", "joint-coverage.json", "bom-audit-summary.json"):
            self.assertTrue((self.out / name).exists(), name)
        coverage = json.loads((self.out / "joint-coverage.json").read_text(encoding="utf-8"))["joints"]
        self.assertEqual(coverage["caster_to_plate"]["category"], "e")  # compound caster, unnamed bodies
        self.assertEqual(coverage["virtual_covered"]["category"], "a")  # virtual component, not exported
        self.assertEqual(coverage["washers_at_root"]["category"], "a2")  # washer rows at root are exported parts
        self.assertEqual(coverage["bare_group"]["category"], "d")
        self.assertEqual(coverage["unknown_group"]["category"], "e")
        self.assertEqual(coverage["unknown_group"]["groups_not_in_audit"], ["NOPE:1"])
        self.assertNotIn("new_design", coverage)
        self.assertIn("category b cannot apply", coverage["bare_group"]["basis"])
        self.assertEqual(summary["native_parts_not_exported"], [])
        tank = json.loads((self.out / "coincident-tank.json").read_text(encoding="utf-8"))["pairs"]
        self.assertEqual(len(tank), 1)
        self.assertEqual(sorted(tank[0]["occurrences"]), ["TANK:1", "TANK:2"])
        self.assertEqual(tank[0]["conclusion"], "unresolved")
        self.assertEqual(tank[0]["parts_only_totals"][0]["item_quantity"], 3)
        self.assertEqual(tank[0]["vault_history"]["m-TANK.ipt"][0]["version"], 1)
        vx = json.loads((self.out / "virtual-and-excluded.json").read_text(encoding="utf-8"))
        self.assertEqual([o["id"] for o in vx["suppressed_occurrences"]], ["BARE:1/PLATE:1"])
        self.assertEqual([o["id"] for o in vx["reference_occurrences"]], ["TANK:3"])
        self.assertEqual(len(vx["virtual_components"]), 1)
        kits = json.loads((self.out / "kit-boundaries.json").read_text(encoding="utf-8"))["parts"]
        caster = next(k for k in kits if k["document"] == "CASTER.ipt")
        self.assertTrue(caster["embedded_hardware_modeled"].startswith("unknown"))
        self.assertEqual(caster["custom_iproperties"], {"Kit": "yes"})
        drawings = json.loads((self.out / "drawings.json").read_text(encoding="utf-8"))
        self.assertEqual(drawings["drawings_or_presentations_on_acquired_versions"], [])
        self.assertEqual(drawings["attachment_kinds"], {"visualization": 1})

    def test_drawing_claim_requires_complete_all_versions_discovery(self):
        # no discovery at all
        summary = summarize(self.audit, self.snapshot, self.out, joints_path=self.joints)
        self.assertFalse(summary["drawings_checked_all_versions"])
        coverage = json.loads((self.out / "joint-coverage.json").read_text(encoding="utf-8"))["joints"]
        self.assertIn("drawings not checked", coverage["bare_group"]["basis"])
        self.assertNotIn("category b cannot apply", coverage["bare_group"]["basis"])
        # discovery without the all-versions pass
        atomic_json(self.discovery / "discovery-receipt.json", {"status": "complete", "all_versions_pass": False, "counts": {}})
        out2 = self.base / "out2"
        summarize(self.audit, self.snapshot, out2, joints_path=self.joints, discovery_dir=self.discovery)
        drawings = json.loads((out2 / "drawings.json").read_text(encoding="utf-8"))
        self.assertFalse(drawings["complete_all_versions"])
        self.assertIn("drawings not checked completely", drawings["note"])
        coverage = json.loads((out2 / "joint-coverage.json").read_text(encoding="utf-8"))["joints"]
        self.assertIn("category b stays possible", coverage["bare_group"]["basis"])

    def test_incomplete_or_unverified_audit_is_refused(self):
        atomic_json(self.audit / "audit-receipt.json", dict(self.receipt, status="FAILED"))
        with self.assertRaisesRegex(ExchangeError, "incomplete"):
            summarize(self.audit, self.snapshot, self.out)
        atomic_json(self.audit / "audit-receipt.json", {"status": "complete", "post_run_integrity": {"inputs_unchanged_after_run": False}})
        with self.assertRaisesRegex(ExchangeError, "unchanged"):
            summarize(self.audit, self.snapshot, self.out)

    def test_coincidence_tolerance_is_in_mm(self):
        occs = [{"id": "A", "kind": "part", "part_id": "p", "transform_world_cm": I},
                {"id": "B", "kind": "part", "part_id": "p", "transform_world_cm": [[1, 0, 0, 0.0000002], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]}]
        self.assertEqual(len(coincident_occurrences({"occurrences": occs}, [])), 0)  # 2e-6 mm > 1e-6 mm
        self.assertEqual(len(coincident_occurrences({"occurrences": occs}, [], tolerance_mm=1e-5)), 1)


if __name__ == "__main__":
    unittest.main()
