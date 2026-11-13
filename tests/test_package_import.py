"""import-snapshot on the exporter's package (schema 2): into a new directory and into a project that holds the files."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from exporter_package import from_project, sha, step_record, write_package
from vault_cad_tools.cli import main
from vault_cad_tools.layout_import import data_sha256
from vault_cad_tools.package_import import import_package, is_package
from vault_cad_tools.project import ExchangeError

STATE = "[Primary]"
ROOT = ("900", STATE)


def step(name, body="1"):
    return (f"ISO-10303-21;\r\nHEADER;\r\nFILE_NAME('part.step','1970-01-01T00:00:00',(''),(''),'p','o','');\r\n"
            f"FILE_SCHEMA(('AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF {{ 1 0 10303 442 1 1 4 }}'));\r\n"
            f"ENDSEC;\r\nDATA;\r\n#1=PRODUCT('{name}','{body}');\r\nENDSEC;\r\nEND-ISO-10303-21;\r\n").encode()


def matrix(x=0.0, y=0.0, z=0.0):
    return [[1.0, 0.0, 0.0, x], [0.0, 1.0, 0.0, y], [0.0, 0.0, 1.0, z], [0.0, 0.0, 0.0, 1.0]]


def vault(master, version, path, number=1, native="a"):
    return {"vault_id": "7", "master_id": master, "version_id": version, "version_number": number, "revision": "0",
            "lifecycle_state": "Work in Progress", "checkin_date": "2026-01-01T00:00:00Z", "path": path,
            "native_sha256": native * 64}


def part(name, master, version="1", folder="LIB", data=None, **vault_fields):
    data = data if data is not None else step(name)
    return {"source": {"schema_version": 1, "kind": "part", "name": name, "model_state": STATE,
                       "vault": vault(master, master + version, f"$/DATA/{folder}/{name}.ipt", **vault_fields),
                       "step": step_record(data), "export": {"translator_output_sha256": "f" * 64},
                       "properties": {"part_number": "P-" + master}, "bom_structure_default": "Normal",
                       "native": {"length_unit": "mm", "extent_mm": [10.0, 20.0, 30.0], "volume_mm3": 6000.0,
                                  "bodies": {"surface_bodies": 1, "solid_bodies": 1, "visible_solid_bodies": 1}},
                       "materials": None},
            "step": data}


def child(name, kind, master, transform, flexible=False, overrides=None):
    rec = {"name": name, "kind": kind, "master_id": master, "model_state": STATE, "transform": transform,
           "bom_structure": "Normal", "visible": True, "suppressed": False, "grounded": False, "flexible": flexible,
           "mirrored": False}
    if overrides:
        rec["overrides"] = overrides
    return rec


def assembly(name, master, children, version="1", frame=None, **vault_fields):
    manifest = {"schema_version": 1, "name": name, "length_unit": "cm"}
    if frame:
        manifest["frame"] = frame
    manifest["children"] = children
    return {"source": {"schema_version": 1, "kind": "assembly", "name": name, "model_state": STATE,
                       "vault": vault(master, master + version, f"$/DATA/PROJECT/{name}.iam", native="b", **vault_fields),
                       "export": {}, "native": {"length_unit": "in"}},
            "assembly": manifest}


def files():
    """Root: A:1, SUB:1 (rigid), SUB:2 (flexible; its B:1 sits 1 cm away from where Sub puts it)."""
    return {
        "a": part("A", "100"),
        "b": part("B", "200", folder="PROJECT"),
        "sub": assembly("Sub", "300", [child("A:1", "part", "100", matrix(1)), child("B:1", "part", "200", matrix(2))]),
        "root": assembly("Root", "900", [
            child("A:1", "part", "100", matrix(0, 5)),
            child("SUB:1", "assembly", "300", matrix(10)),
            child("SUB:2", "assembly", "300", matrix(20), flexible=True, overrides=[{"path": ["B:1"], "transform": matrix(3)}]),
        ], frame={"handedness": "right", "up_axis": "+Y"}),
    }


def tree(root):
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in sorted(Path(root).rglob("*")) if p.is_file()}


class PackageImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.dest = self.base / "project"
        self.count = 0

    def package(self, held=None, **kw):
        self.count += 1
        return write_package(self.base / f"package-{self.count}", list((held or files()).values()), ROOT, **kw)

    def load(self, rel):
        return json.loads((self.dest / rel).read_text(encoding="utf-8"))

    def first(self):
        return import_package(self.package(), self.dest, "run-1")

    def refused(self, message, held=None, run="run-2", **kw):
        package = kw.pop("package", None) or self.package(held, **kw)
        before = tree(self.dest) if self.dest.exists() else None
        with self.assertRaisesRegex(ExchangeError, message):
            import_package(package, self.dest, run)
        self.assertEqual(tree(self.dest) if self.dest.exists() else None, before)       # a refusal writes nothing

    def test_first_import_writes_one_directory_per_file(self):
        package = self.package()
        self.assertTrue(is_package(package))
        result = import_package(package, self.dest, "run-1")
        self.assertEqual((result["parts"], result["assemblies"], result["root"]), (2, 2, "root"))
        self.assertEqual(result["new"], ["a", "b", "root", "sub"])
        self.assertEqual((result["updated"], result["rewritten"], result["unchanged"], result["not_in_package"]), ([], [], [], []))
        self.assertEqual(result["to_measure"], ["a", "b"])
        self.assertFalse(result["vault_and_root_checked_against_project"])
        self.assertEqual((self.dest / "references/receipts/run-1/package.json").read_bytes(), (package / "package.json").read_bytes())
        data = (self.dest / "references/parts/a/part.step").read_bytes()
        self.assertEqual(data, step("A"))
        source = self.load("references/parts/a/source.json")
        self.assertEqual(list(source)[:6], ["schema_version", "kind", "key", "name", "model_state", "vault"])
        self.assertEqual((source["key"], source["step"]["sha256"], source["step"]["protocol"]), ("a", sha(data), "AP242"))
        self.assertEqual(source["export"], {"run": "run-1", "translator_output_sha256": "f" * 64})
        raw = (self.dest / "references/parts/a/source.json").read_bytes()
        self.assertFalse(raw.startswith(b"\xef\xbb\xbf") or b"\r" in raw)                # the layout's JSON, not PowerShell's
        root = self.load("references/assemblies/root/assembly.json")
        self.assertEqual((root["key"], root["frame"]["up_axis"], root["length_unit"]), ("root", "+Y", "cm"))
        self.assertEqual([(c["name"], c["component"], c["master_id"]) for c in root["children"]],
                         [("A:1", "a", "100"), ("SUB:1", "sub", "300"), ("SUB:2", "sub", "300")])
        # the exporter states B:1 below SUB:2 in context; the override on the flexible instance is derived from that
        self.assertEqual(root["children"][2]["overrides"], [{"path": ["B:1"], "transform": matrix(3)}])
        self.assertNotIn("overrides", root["children"][1])
        self.assertEqual(result["overrides"], 1)
        self.assertEqual((self.dest / "references/receipts/run-1/occurrences.json").read_bytes(),
                         (package / "occurrences.json").read_bytes())
        self.assertEqual(self.load("references/assemblies/sub/source.json")["export"], {"run": "run-1"})
        lock = self.load("vault-lock.json")
        self.assertEqual((lock["schema_version"], lock["publications"]), (2, []))
        self.assertEqual([c["key"] for c in lock["components"]], ["a", "b", "root", "sub"])
        self.assertEqual(lock["components"][0], {
            "key": "a", "path": "references/parts/a", "kind": "part", "model_state": STATE, "master_id": "100",
            "version_id": "1001", "native_sha256": "a" * 64, "step_sha256": sha(data), "step_data_sha256": data_sha256(data)})
        self.assertEqual(lock["components"][2]["step_sha256"], None)
        self.assertFalse((self.dest / ".vault-cad-operation.lock").exists())

    def test_the_same_package_again_changes_no_directory(self):
        self.first()
        before = tree(self.dest)
        result = import_package(self.package(exported_at="2026-02-02T00:00:00Z"), self.dest, "run-2")
        self.assertEqual((result["unchanged"], result["new"], result["updated"], result["rewritten"], result["to_measure"]),
                         (["a", "b", "root", "sub"], [], [], [], []))
        after = tree(self.dest)
        self.assertEqual({k: v for k, v in after.items() if "/run-2/" not in k}, before)
        self.assertIn("references/receipts/run-2/package.json", after)
        self.assertEqual(self.load("references/parts/a/source.json")["export"]["run"], "run-1")   # the export it came from

    def test_a_new_version_replaces_that_file_and_keeps_its_key(self):
        self.first()
        before = tree(self.dest)
        held = files()
        # Vault: B has a new version, and was renamed and moved on the way
        held["b"] = part("Bracket", "200", version="2", folder="ELSEWHERE", data=step("Bracket", "2"), number=2, native="c")
        result = import_package(self.package(held), self.dest, "run-2")
        self.assertEqual((result["updated"], result["unchanged"], result["new"], result["to_measure"]),
                         (["b"], ["a", "root", "sub"], [], ["b"]))
        after = tree(self.dest)
        changed = sorted(k for k in after if before.get(k) != after[k])
        self.assertEqual(changed, ["references/parts/b/part.step", "references/parts/b/source.json",
                                   "references/receipts/run-2/occurrences.json",
                                   "references/receipts/run-2/package.json", "vault-lock.json"])
        source = self.load("references/parts/b/source.json")
        self.assertEqual((source["key"], source["name"], source["vault"]["version_number"], source["export"]["run"]),
                         ("b", "Bracket", 2, "run-2"))
        entry = next(c for c in self.load("vault-lock.json")["components"] if c["key"] == "b")
        self.assertEqual((entry["version_id"], entry["step_sha256"]), ("2002", sha(step("Bracket", "2"))))

    def test_the_same_version_exported_differently_is_rewritten(self):
        self.first()
        held = files()
        held["a"]["source"]["properties"]["description"] = "now exported"       # the record differs, the STEP does not
        held["sub"]["assembly"]["children"][0]["transform"] = matrix(1.5)
        result = import_package(self.package(held), self.dest, "run-2")
        self.assertEqual((result["rewritten"], result["unchanged"], result["updated"], result["to_measure"]),
                         (["a", "sub"], ["b", "root"], [], []))
        self.assertEqual(self.load("references/parts/a/source.json")["export"]["run"], "run-2")
        self.assertEqual(self.load("references/assemblies/sub/assembly.json")["children"][0]["transform"], matrix(1.5))

    def test_new_files_get_keys_that_nothing_else_has(self):
        self.first()
        (self.dest / "designs/parts/c").mkdir(parents=True)                      # an authored part already called c
        held = files()
        held["c"] = part("C", "400")
        held["a2"] = part("A", "101", folder="OTHER")                            # another Vault file with A's name
        held["sub"]["assembly"]["children"] += [child("C:1", "part", "400", matrix(4)), child("A:2", "part", "101", matrix(5))]
        result = import_package(self.package(held), self.dest, "run-2")
        self.assertEqual((result["new"], result["rewritten"], result["unchanged"]), (["a-101", "c-400"], ["sub"], ["a", "b", "root"]))
        children = self.load("references/assemblies/sub/assembly.json")["children"]
        self.assertEqual([c["component"] for c in children], ["a", "b", "c-400", "a-101"])
        self.assertEqual(result["to_measure"], ["a-101", "c-400"])

    def test_what_the_package_no_longer_has_is_reported_and_kept(self):
        self.first()
        held = files()
        del held["b"]
        held["sub"]["assembly"]["children"].pop()
        held["root"]["assembly"]["children"][2].pop("overrides")
        result = import_package(self.package(held), self.dest, "run-2")
        self.assertEqual((result["not_in_package"], result["rewritten"], result["unchanged"]), (["b"], ["root", "sub"], ["a"]))
        self.assertTrue((self.dest / "references/parts/b/part.step").is_file())
        self.assertIn("b", [c["key"] for c in self.load("vault-lock.json")["components"]])

    def test_a_project_names_its_vault_and_root_and_keeps_its_publications(self):
        self.first()
        lock = self.load("vault-lock.json")
        lock["publications"] = [{"key": "envelope", "path": "designs/parts/envelope", "request_id": "r", "master_id": "1",
                                 "version_id": "2", "step_sha256": "e" * 64, "git_commit": "c"}]
        (self.dest / "vault-lock.json").write_text(json.dumps(lock))
        toml = '[vault]\nid = "7"\nroot_assembly = "$/data/project/ROOT.iam"\n'
        (self.dest / "vault-project.toml").write_text(toml)
        result = import_package(self.package(), self.dest, "run-2")
        self.assertTrue(result["vault_and_root_checked_against_project"])
        self.assertEqual(self.load("vault-lock.json")["publications"], lock["publications"])
        (self.dest / "vault-project.toml").write_text(toml.replace('"7"', '"8"'))
        self.refused("another vault than vault-project.toml", run="run-3")
        (self.dest / "vault-project.toml").write_text(toml.replace("ROOT.iam", "Other.iam"))
        self.refused("not the root_assembly of vault-project.toml", run="run-3")

    def test_a_package_from_a_project_is_what_the_project_holds(self):
        self.first()
        before = tree(self.dest)
        package = from_project(self.dest, self.base / "from-project", "root")
        result = import_package(package, self.dest, "run-2")
        self.assertEqual(result["unchanged"], ["a", "b", "root", "sub"])
        self.assertEqual({k: v for k, v in tree(self.dest).items() if "/run-2/" not in k}, before)
        other = step("A", "another export")
        package = from_project(self.dest, self.base / "from-project-2", "root", replace_step={"a": (other, {"protocol": "AP214"})})
        result = import_package(package, self.dest, "run-3")
        self.assertEqual((result["rewritten"], result["to_measure"]), (["a"], ["a"]))
        self.assertEqual((self.dest / "references/parts/a/part.step").read_bytes(), other)

    def test_a_package_that_is_not_what_was_exported_is_refused(self):
        package = self.package()
        (package / "files/100_primary/part.step").write_bytes(step("A") + b" ")
        self.refused("files/100_primary/part.step does not match package.json", package=package, run="run-1")
        package = self.package()
        (package / "files/100_primary/notes.txt").write_text("x")
        self.refused("notes.txt is in the package and not listed", package=package, run="run-1")
        package = self.package()
        (package / "files/200_primary/part.step").unlink()
        self.refused("files/200_primary/part.step is listed in package.json and missing", package=package, run="run-1")
        held = files()
        held["a"]["source"]["step"]["bytes"] += 1
        self.refused("step does not describe part.step", held, run="run-1")
        held = files()
        held["a"]["source"]["key"] = "a"
        self.refused("the exporter does not write a key", held, run="run-1")
        held = files()
        held["a"]["source"]["export"]["run"] = "x"
        self.refused("export must be an object without a run", held, run="run-1")
        held = files()
        held["a"]["source"]["vault"]["vault_id"] = "8"
        self.refused("from another vault than the package", held, run="run-1")
        held = files()
        del held["a"]["source"]["vault"]["revision"]
        self.refused("vault must have exactly its nine fields", held, run="run-1")
        held = files()
        held["dup"] = dict(part("Other", "100"), directory="another-name")      # the identity is in source.json
        self.refused("master id 100 in model state .Primary. is in the package twice", held, run="run-1")
        self.assertFalse(self.dest.exists())

    def test_an_assembly_that_cannot_be_placed_is_refused(self):
        held = files()
        held["sub"]["assembly"]["children"].append(child("X:1", "part", "555", matrix()))
        self.refused("X:1: master id 555 in model state .Primary. is not in the package$", held, run="run-1")
        self.refused(r"is not in the package \(not exported: no geometry\)", held, run="run-1",
                     not_exported=[{"master_id": "555", "model_state": STATE, "reason": "no geometry"}])
        for change, message in (
                (lambda c: c.update(component="a"), "by master id and model state, not by key"),
                (lambda c: c.update(kind="assembly"), "kind is 'assembly' and the component is a part"),
                (lambda c: c.update(transform=[[1, 0, 0, 0]]), "transform must be 4 by 4 numbers"),
                (lambda c: c.pop("grounded"), "states its BOM structure and all five flags"),
                (lambda c: c.update(name="B:1"), "occurrence names are unique")):
            held = files()
            change(held["sub"]["assembly"]["children"][0])
            self.refused(message, held, run="run-1")
        self.refused("SUB:2: the exporter writes no overrides; occurrences.json states the placements in context",
                     run="run-1", strip_overrides=False)
        held = files()
        held["sub"]["assembly"]["key"] = "sub"
        self.refused("assembly.json: the exporter does not write a key", held, run="run-1")
        held = files()
        del held["root"]
        self.refused("the root assembly named in package.json is not an assembly of the package", held, run="run-1")

    def test_a_project_that_is_ahead_of_the_package_or_not_what_its_index_says_is_refused(self):
        held = files()
        held["b"] = part("B", "200", version="2", folder="PROJECT", data=step("B", "2"), number=2, native="c")
        import_package(self.package(held), self.dest, "run-1")
        self.refused("b: the project holds version 2, later than the package's 1")
        older = files()
        older["b"]["source"]["vault"]["version_number"] = None
        self.refused("b: .* a version number is unknown; their order cannot be told", older)
        same_number = files()
        same_number["b"]["source"]["vault"]["version_number"] = 2
        self.refused("b: two version ids for version 2", same_number)
        other_native = copy.deepcopy(held)
        other_native["b"]["source"]["vault"]["native_sha256"] = "d" * 64
        self.refused("b: the same Vault version with another native file", other_native)
        as_assembly = copy.deepcopy(held)
        as_assembly["b"] = assembly("B", "200", [], version="2", number=2)
        as_assembly["sub"]["assembly"]["children"][1]["kind"] = "assembly"
        self.refused("the project holds master id 200 as a part", as_assembly)
        self.refused("references/receipts/run-1 exists", held, run="run-1")
        self.refused("the run name must be a plain directory name", held, run="../x")
        (self.dest / ".vault-cad-operation.lock").write_text("1")
        self.refused("Another operation or stale", held)
        (self.dest / ".vault-cad-operation.lock").unlink()
        (self.dest / "references/parts/a/part.step").write_bytes(b"edited")
        self.refused("references/parts/a is not what vault-lock.json says it is", held)
        (self.dest / "references/parts/a/part.step").write_bytes(step("A"))
        (self.dest / "references/parts/stray").mkdir()
        self.refused("references/parts/stray is not in vault-lock.json", held)
        (self.dest / "references/parts/stray").rmdir()
        (self.dest / "vault-lock.json").write_text(json.dumps({"schema_version": 1, "references": {}, "publications": []}))
        self.refused("vault-lock.json is not the index", held)
        (self.dest / "vault-lock.json").unlink()
        self.refused("has references/ and no vault-lock.json", held)

    def occurrence(self, data, *path):
        return next(o for o in data["occurrences"] if o["path"] == list(path))

    def test_the_placements_in_context_have_to_agree_with_the_documents(self):
        def edited(change):
            def edit(data):
                change(data)
                return data
            return edit

        cases = (
            (lambda d: None, "the package has no occurrences.json", None),
            (lambda d: d.update(schema_version=2), "occurrences.json: schema_version must be 1", None),
            (lambda d: d["root"].update(master_id="300"), "is of another root assembly than package.json names", None),
            (lambda d: d.pop("tolerance"), "tolerance must state rotation_cell and length", None),
            (lambda d: d.update(length_unit="mm"), "occurrences.json is in 'mm' and files/.*/assembly.json in 'cm'", None),
            (lambda d: d["occurrences"].pop(), "SUB:2: the occurrence lacks B:1, which its document defines", None),
            (lambda d: d["occurrences"].append(dict(d["occurrences"][0])), "A:1: is listed twice", None),
            (lambda d: d["occurrences"].insert(0, d["occurrences"].pop()), "SUB:2/B:1: is listed before the assembly", None),
            (lambda d: self.occurrence(d, "A:1").update(master_id="200"), "A:1: is not the component", None),
            (lambda d: self.occurrence(d, "SUB:1", "A:1").update(visible=False), "SUB:1/A:1: its BOM structure or a flag", None),
            (lambda d: self.occurrence(d, "SUB:1", "B:1").update(differs_from_definition=True),
             "SUB:1/B:1: differs_from_definition is true and its placement says otherwise", None),
            (lambda d: self.occurrence(d, "SUB:2", "B:1").update(differs_from_definition=False),
             "SUB:2/B:1: differs_from_definition is false and its placement says otherwise", None),
            (lambda d: self.occurrence(d, "SUB:1", "A:1").update(transform_root=matrix(99)),
             "SUB:1/A:1: transform_root is not its parent's placement in the root times its own", None),
            (lambda d: d["counts"].update(occurrences=3), "counts 3 occurrences and lists 7", None),
        )
        for change, message, _ in cases:
            if message.startswith("the package has no"):
                self.refused(message, run="run-1", edit_occurrences=lambda d: None)
            else:
                self.refused(message, run="run-1", edit_occurrences=edited(change))

    def test_a_placement_that_differs_needs_a_flexible_occurrence_above_it(self):
        held = files()
        held["root"]["assembly"]["children"][2]["flexible"] = False          # the helper still states B:1 as posed
        self.refused("SUB:2/B:1: it is not where its document puts it and no occurrence above it is flexible",
                     held, run="run-1")

    def test_instances_of_one_document_that_are_posed_differently_are_refused(self):
        # Root places Mid twice; Mid places Sub flexibly; only in MID:1 is Sub's B:1 moved: Mid's manifest
        # cannot say that for one of its instances, and an override on an outer instance is not written
        held = files()
        held["mid"] = assembly("Mid", "500", [child("SUB:1", "assembly", "300", matrix(4), flexible=True)])
        held["root"] = assembly("Root", "900", [child("MID:1", "assembly", "500", matrix(10)),
                                                child("MID:2", "assembly", "500", matrix(20))])

        def pose_one(data):
            moved = self.occurrence(data, "MID:1", "SUB:1", "B:1")
            moved.update(transform=matrix(3), transform_root=matrix(17), differs_from_definition=True)
            return data

        self.refused("MID:2/SUB:1: two instances of one document pose SUB:1 differently", held, run="run-1",
                     edit_occurrences=pose_one)

        def pose_both(data):
            for mid, at in (("MID:1", 17), ("MID:2", 27)):
                self.occurrence(data, mid, "SUB:1", "B:1").update(transform=matrix(3), transform_root=matrix(at),
                                                                   differs_from_definition=True)
            return data

        result = import_package(self.package(held, edit_occurrences=pose_both), self.dest, "run-1")
        self.assertEqual(result["overrides"], 1)                              # once, in Mid's manifest
        mid = self.load("references/assemblies/mid/assembly.json")
        self.assertEqual(mid["children"][0]["overrides"], [{"path": ["B:1"], "transform": matrix(3)}])

    def test_command_line(self):
        package = self.package()
        self.assertEqual(main(["import-snapshot", str(package), "--into", str(self.dest), "--run", "run-1"]), 0)
        self.assertTrue((self.dest / "references/assemblies/root/assembly.json").is_file())
        self.assertEqual(main(["import-snapshot", str(package), "--into", str(self.dest), "--run", "run-2"]), 0)
        self.assertEqual(main(["import-snapshot", str(package), "--into", str(self.dest), "--run", "run-2"]), 2)


if __name__ == "__main__":
    unittest.main()
