"""The provisional import-snapshot command, on a synthetic exporter package."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from vault_cad_tools.cli import main
from vault_cad_tools.layout_import import data_sha256, import_snapshot, slug
from vault_cad_tools.project import ExchangeError

WORKSPACE = "C:\\work\\vault-workspace\\"
BOM = b"\xef\xbb\xbf"


def step(name):
    return (f"ISO-10303-21;\r\nHEADER;\r\nFILE_NAME('{name}','2026-01-01T00:00:00',('someone'),(''),'p','o','');\r\n"
            f"ENDSEC;\r\nDATA;\r\n#1=PRODUCT('{name}');\r\nENDSEC;\r\nEND-ISO-10303-21;\r\n").encode()


def matrix(x=0.0, y=0.0, z=0.0):
    return [[1.0, 0.0, 0.0, x], [0.0, 1.0, 0.0, y], [0.0, 0.0, 1.0, z], [0.0, 0.0, 0.0, 1.0]]


def part(rel, master, asset):
    return {"id": rel + "|[Primary]", "document": WORKSPACE + rel, "model_state": "[Primary]",
            "display_name": rel.split("\\")[-1],
            "asset": {"path": asset, "format": "step", "protocol": "AP214", "sha256": None, "bytes": None,
                      "step_length_unit": "mm", "translator_options": {"ApplicationProtocolType": 3, "Author": ""}},
            "native_length_units": "mm", "range_box_cm": {"extent": [1.0, 2.0, 3.0]},
            "bodies": {"surface_bodies": 1, "solid_bodies": 1, "visible_solid_bodies": 1}, "volume_cm3": 6.0,
            "default_bom_structure": {"value": 51970, "name": "Normal"}, "properties": {"part_number": "P-" + master},
            "source": {"vault_id": "7", "version_id": master + "1", "master_id": master,
                       "vault_path": "$/" + rel.replace("\\", "/"), "native_sha256": "a" * 64}}


def node(kind, node_id, parent, local, definition=None, overridden=False, flexible=False, part_id=None, document=None):
    rec = {"id": node_id, "name": node_id.split("/")[-1], "parent_id": parent, "transform_local_cm": local,
           "transform_local_definition_cm": definition, "position_overridden_vs_definition": overridden,
           "mirrored": False, "visible": True, "suppressed": False, "grounded": False, "flexible": flexible,
           "bom_structure": {"value": 51970, "name": "Normal"}, "active_model_state": "[Primary]", "kind": kind}
    if kind == "part":
        rec["part_id"] = part_id
    else:
        rec["document"] = document
    return rec


class Package:
    """root: A:1, SUB:1 (rigid), SUB:2 (flexible; its B:1 sits 1 cm away from the definition)."""

    def __init__(self, base):
        self.dir = Path(base) / "package"
        (self.dir / "assets").mkdir(parents=True)
        a, b = "DATA\\LIB\\A.ipt", "DATA\\PROJECT\\B.ipt"
        self.snapshot = {
            "schema": "vault-cad-tools native snapshot 1", "generated_at": "2026-01-01T00:00:00Z",
            "inventor_version": "2025.3", "inventor_build": 1,
            "assembly": {"document": WORKSPACE + "DATA\\PROJECT\\Root.iam", "model_state": "[Primary]", "length_units": "in",
                         "source": {"vault_id": "7", "version_id": "9001", "master_id": "900",
                                    "vault_path": "$/DATA/PROJECT/Root.iam", "native_sha256": "b" * 64}},
            "parts": [part(a, "100", "assets/A__[Primary]__11111111.step"), part(b, "200", "assets/B__[Primary]__22222222.step")],
            "groups": [node("assembly", "SUB:1", "root", matrix(10), document=WORKSPACE + "DATA\\PROJECT\\Sub.iam"),
                       node("assembly", "SUB:2", "root", matrix(20), flexible=True, document=WORKSPACE + "DATA\\PROJECT\\Sub.iam")],
            "occurrences": [
                node("part", "A:1", "root", matrix(0, 5), part_id=a + "|[Primary]"),
                node("part", "SUB:1/A:1", "SUB:1", matrix(1), matrix(1), part_id=a + "|[Primary]"),
                node("part", "SUB:1/B:1", "SUB:1", matrix(2), matrix(2), part_id=b + "|[Primary]"),
                node("part", "SUB:2/A:1", "SUB:2", matrix(1 + 1e-13), matrix(1), part_id=a + "|[Primary]"),
                node("part", "SUB:2/B:1", "SUB:2", matrix(3), matrix(2), overridden=True, part_id=b + "|[Primary]"),
            ],
        }
        self.scene = {"schema_version": "draft-1", "coordinate_system": {"handedness": "right", "up_axis": "+Y"},
                      "source": {"exporter": "windows/Export-PartAssets.ps1 on Inventor 2025.3"},
                      "parts": [{"id": p["id"], "identifying_dimensions_mm": {"extent": [10.0, 20.0, 30.0]}, "volume_mm3": 6000.0}
                                for p in self.snapshot["parts"]]}
        self.write()

    def write(self, tamper=None):
        files = {}
        for p in self.snapshot["parts"]:
            data = step(p["display_name"])
            p["asset"].update(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
            (self.dir / p["asset"]["path"]).write_bytes(data if tamper != p["asset"]["path"] else data + b" ")
            files[p["asset"]["path"]] = {"sha256": p["asset"]["sha256"], "bytes": len(data)}
        for name, obj in (("native-snapshot.json", self.snapshot), ("scene.json", self.scene)):
            raw = BOM + json.dumps(obj, indent=2).replace("\n", "\r\n").encode()         # as PowerShell writes it
            (self.dir / name).write_bytes(raw)
            files[name] = {"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}
        (self.dir / "export-receipt.json").write_bytes(BOM + json.dumps({"schema_version": 1, "files": files}).encode())


class ImportSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.package = Package(self.base)
        self.dest = self.base / "converted"

    def convert(self, **kw):
        return import_snapshot(self.package.dir, self.dest, "run-1", **kw)

    def load(self, rel):
        return json.loads((self.dest / rel).read_text(encoding="utf-8"))

    def test_writes_one_directory_per_file(self):
        result = self.convert()
        self.assertEqual((result["parts"], result["assemblies"], result["overrides"], result["root"]), (2, 2, 1, "root"))
        self.assertEqual(sorted(p.name for p in (self.dest / "references/parts").iterdir()), ["a", "b"])
        self.assertEqual(sorted(p.name for p in (self.dest / "references/assemblies").iterdir()), ["root", "sub"])
        self.assertEqual(result["part_ids"], {"a": "DATA\\LIB\\A.ipt|[Primary]", "b": "DATA\\PROJECT\\B.ipt|[Primary]"})
        source = self.load("references/parts/a/source.json")
        data = (self.dest / "references/parts/a/part.step").read_bytes()
        self.assertEqual(data, (self.package.dir / "assets/A__[Primary]__11111111.step").read_bytes())
        self.assertEqual(source["step"], {"sha256": hashlib.sha256(data).hexdigest(), "data_sha256": data_sha256(data),
                                          "bytes": len(data), "protocol": "AP214", "length_unit": "mm",
                                          "header_normalised": False, "received_sha256": None})
        self.assertEqual(source["vault"], {"vault_id": "7", "master_id": "100", "version_id": "1001", "version_number": None,
                                           "revision": None, "lifecycle_state": None, "checkin_date": None,
                                           "path": "$/DATA/LIB/A.ipt", "native_sha256": "a" * 64})
        self.assertEqual(source["export"]["package_id"], "DATA\\LIB\\A.ipt|[Primary]")
        self.assertEqual(source["export"]["package_path"], "assets/A__[Primary]__11111111.step")
        self.assertEqual(source["native"]["extent_mm"], [10.0, 20.0, 30.0])
        self.assertNotIn("C:\\", json.dumps(self.load("references/assemblies/sub/source.json")))

    def test_assembly_manifests_hold_definitions_and_overrides(self):
        self.convert()
        root = self.load("references/assemblies/root/assembly.json")
        self.assertEqual(root["length_unit"], "cm")
        self.assertEqual(root["frame"], {"handedness": "right", "up_axis": "+Y"})
        self.assertEqual([(c["name"], c["component"], c["kind"], c["flexible"]) for c in root["children"]],
                         [("SUB:1", "sub", "assembly", False), ("SUB:2", "sub", "assembly", True), ("A:1", "a", "part", False)])
        self.assertNotIn("overrides", root["children"][0])
        self.assertEqual(root["children"][1]["overrides"], [{"path": ["B:1"], "transform": matrix(3)}])
        sub = self.load("references/assemblies/sub/assembly.json")
        self.assertNotIn("frame", sub)
        # the definition, not the flexible instance's placement
        self.assertEqual([(c["name"], c["transform"][0][3], c["master_id"]) for c in sub["children"]],
                         [("A:1", 1.0, "100"), ("B:1", 2.0, "200")])

    def test_lock_is_the_index_of_the_directories(self):
        self.convert()
        lock = self.load("vault-lock.json")
        self.assertEqual(lock["schema_version"], 2)
        self.assertEqual([c["key"] for c in lock["components"]], ["a", "b", "root", "sub"])
        self.assertEqual(lock["publications"], [])
        a = lock["components"][0]
        self.assertEqual(a["step_sha256"], self.load("references/parts/a/source.json")["step"]["sha256"])
        self.assertIsNone(lock["components"][3]["step_sha256"])

    def test_exporter_records_are_kept_byte_for_byte(self):
        result = self.convert()
        self.assertEqual(result["records_kept"], ["export-receipt.json", "native-snapshot.json", "scene.json"])
        for name in result["records_kept"]:
            self.assertEqual((self.dest / "references/receipts/run-1" / name).read_bytes(), (self.package.dir / name).read_bytes())

    def test_sub_assembly_identity_comes_from_the_inventory(self):
        self.assertEqual(self.convert()["identity_incomplete"], ["sub"])
        self.assertIsNone(self.load("references/assemblies/sub/source.json")["vault"]["master_id"])
        self.assertEqual(self.load("references/assemblies/sub/source.json")["vault"]["path"], "$/DATA/PROJECT/Sub.iam")
        inventory = self.base / "dependency-inventory.json"
        inventory.write_text(json.dumps({"root": {"vault_path": "$/DATA/PROJECT/Root.iam", "version": 5, "revision": "0",
                                                  "state": "Work in Progress", "checkin_date": "2026-01-02T00:00:00Z"},
                                         "files": [{"vault_path": "$/DATA/PROJECT/Sub.iam", "master_id": "300", "version_id": "3001",
                                                    "version": 2, "revision": "B", "state": "Released",
                                                    "checkin_date": "2026-01-03T00:00:00Z"}]}))
        self.dest = self.base / "converted-2"
        result = self.convert(inventory=inventory)
        self.assertEqual(result["identity_incomplete"], [])
        vault = self.load("references/assemblies/sub/source.json")["vault"]
        self.assertEqual((vault["master_id"], vault["version_id"], vault["version_number"], vault["revision"], vault["lifecycle_state"]),
                         ("300", "3001", 2, "B", "Released"))
        self.assertEqual(self.load("references/assemblies/root/source.json")["vault"]["version_number"], 5)
        self.assertEqual(self.load("references/assemblies/root/assembly.json")["children"][0]["master_id"], "300")
        self.assertIn("dependency-inventory.json", result["records_kept"])

    def test_same_name_in_two_folders_gets_two_keys(self):
        self.package.snapshot["parts"].append(part("DATA\\OTHER\\A.ipt", "400", "assets/A__[Primary]__33333333.step"))
        self.package.scene["parts"].append({"id": "DATA\\OTHER\\A.ipt|[Primary]"})
        self.package.write()
        result = self.convert()
        self.assertEqual(sorted(result["part_ids"]), ["a", "a-400", "b"])

    def test_refusals(self):
        (self.dest / "x").mkdir(parents=True)
        with self.assertRaisesRegex(ExchangeError, "not empty"):
            self.convert()
        self.dest = self.base / "other"
        with self.assertRaisesRegex(ExchangeError, "plain directory name"):
            import_snapshot(self.package.dir, self.dest, "../escape")
        self.package.write(tamper="assets/B__[Primary]__22222222.step")
        with self.assertRaisesRegex(ExchangeError, "does not match the export receipt"):
            self.convert()
        self.assertFalse(self.dest.exists())

    def test_instances_must_agree_with_their_definition(self):
        snap = self.package.snapshot
        saved = copy.deepcopy(snap)
        snap["occurrences"][3]["transform_local_definition_cm"] = matrix(1.5)          # SUB:2/A:1 against SUB:1/A:1
        self.package.write()
        with self.assertRaisesRegex(ExchangeError, "definition differs from the first instance"):
            self.convert()
        self.package.snapshot = snap = copy.deepcopy(saved)
        snap["occurrences"][2]["position_overridden_vs_definition"] = True               # under the rigid SUB:1
        self.package.write()
        with self.assertRaisesRegex(ExchangeError, "no enclosing instance is flexible"):
            self.convert()
        self.package.snapshot = snap = copy.deepcopy(saved)
        snap["occurrences"][0]["suppressed"] = True
        self.package.write()
        with self.assertRaisesRegex(ExchangeError, "suppressed or mirrored"):
            self.convert()
        self.package.snapshot = snap = copy.deepcopy(saved)
        del snap["occurrences"][4]
        self.package.write()
        with self.assertRaisesRegex(ExchangeError, "children differ from the other instances"):
            self.convert()

    def test_command_line(self):
        self.assertEqual(main(["import-snapshot", str(self.package.dir), "--into", str(self.dest), "--run", "run-1"]), 0)
        self.assertTrue((self.dest / "vault-lock.json").is_file())
        self.assertEqual(main(["import-snapshot", str(self.package.dir), "--into", str(self.dest), "--run", "run-1"]), 2)

    def test_helpers(self):
        self.assertEqual(slug("MCMASTER 5537T293_T-Slotted Framing"), "mcmaster-5537t293-t-slotted-framing")
        self.assertEqual(slug("  2.5in  "), "2-5in")
        data = step("x")
        self.assertEqual(data_sha256(data), hashlib.sha256(data[data.index(b"DATA;"):]).hexdigest())
        with self.assertRaises(ExchangeError):
            data_sha256(b"no sections here")


if __name__ == "__main__":
    unittest.main()
