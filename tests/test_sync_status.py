"""sync-status: a project's mirror compared with a discovery of its Vault folder."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from exporter_package import write_package
from test_package_import import ROOT, STATE, assembly, child, files, matrix, part

from vault_cad_tools.cli import main
from vault_cad_tools.package_import import import_package
from vault_cad_tools.project import ExchangeError
from vault_cad_tools.sync_status import sync_status

KIND = {"part": "native_part", "assembly": "native_assembly"}


def vault_file(entry, **changes):
    source = entry["source"]
    row = {"name": source["name"], "kind": KIND[source["kind"]], "master_id": source["vault"]["master_id"],
           "version_id": source["vault"]["version_id"], "version": source["vault"]["version_number"],
           "is_checked_out": False, "vault_path": source["vault"]["path"]}
    row.update(changes)
    return row


def discovery(held, change=None, folder=(), **top):
    """What Discover-VaultFolder.ps1 would write for a folder whose root assembly uses `held` (without the root)."""
    closure = {name: vault_file(entry) for name, entry in held.items() if name != "root"}
    if change:
        change(closure)
    root = held["root"]["source"]["vault"]
    data = {"schema_version": 1, "generated_at": "2026-02-01T00:00:00Z", "vault_id": "7",
            "files": [dict(vault_file(held["root"]), role="root")] + [dict(f, role="child") for f in closure.values()] + list(folder),
            "roots": [{"name": "Root.iam", "master_id": root["master_id"], "version_id": root["version_id"],
                       "closure_read": True, "closure": list(closure.values())}]}
    data.update(top)
    return data


class SyncStatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.project = self.base / "project"
        import_package(write_package(self.base / "package", list(files().values()), ROOT), self.project, "run-1")

    def status(self, data, output=None):
        path = self.base / "discovery.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return sync_status(self.project, path, output)

    def states(self, result):
        return {c["key"]: c["state"] for c in result["components"]}

    def test_a_mirror_of_what_vault_holds_is_current(self):
        result = self.status(discovery(files()))
        self.assertTrue(result["current"])
        self.assertEqual(result["counts"], {"in_sync": 4, "vault_newer": 0, "not_in_closure": 0, "new_in_vault": 0})
        self.assertEqual(self.states(result), {"a": "in_sync", "b": "in_sync", "root": "in_sync", "sub": "in_sync"})
        self.assertEqual((result["root"], result["new_in_vault"], result["publications"]),
                         ({"key": "root", "master_id": "900"}, [], []))

    def test_what_was_checked_in_again_is_named_and_what_is_checked_out_is_flagged(self):
        def later(closure):
            closure["b"].update(version_id="2002", version=2)
            closure["a"]["is_checked_out"] = True
        result = self.status(discovery(files(), later))
        self.assertFalse(result["current"])
        self.assertEqual(self.states(result), {"a": "in_sync", "b": "vault_newer", "root": "in_sync", "sub": "in_sync"})
        rows = {c["key"]: c for c in result["components"]}
        self.assertEqual((rows["b"]["held_version_id"], rows["b"]["vault_version_id"]), ("2001", "2002"))
        self.assertTrue(rows["a"]["checked_out_in_vault"])
        self.assertNotIn("checked_out_in_vault", rows["b"])
        # the root itself counts like any other file
        data = discovery(files())
        data["roots"][0]["version_id"] = "9002"
        self.assertEqual(self.states(self.status(data))["root"], "vault_newer")

    def test_what_the_assembly_gained_and_lost_is_named(self):
        def other_closure(closure):
            del closure["b"]
            closure["c"] = vault_file(part("Clip", "400"))
        result = self.status(discovery(files(), other_closure))
        self.assertEqual(self.states(result)["b"], "not_in_closure")
        self.assertEqual(result["new_in_vault"], [{"name": "Clip", "kind": "part", "master_id": "400", "version_id": "4001"}])
        self.assertEqual((result["current"], result["counts"]["new_in_vault"], result["counts"]["not_in_closure"]), (False, 1, 1))

    def test_what_else_the_folder_holds_is_listed_apart(self):
        extra = [dict(vault_file(assembly("Other", "950", [child("A:1", "part", "100", matrix(1))])), role="root"),
                 dict(vault_file(part("Loose", "500")), role="standalone")]
        result = self.status(discovery(files(), folder=extra))
        self.assertTrue(result["current"])
        self.assertEqual(result["other_files_in_the_folder"],
                         [{"name": "Loose", "kind": "part", "role": "standalone", "master_id": "500"},
                          {"name": "Other", "kind": "assembly", "role": "root", "master_id": "950"}])

    def test_a_publication_is_compared_with_the_file_in_the_folder(self):
        part_dir = self.project / "designs/parts/envelope"
        part_dir.mkdir(parents=True)
        (part_dir / "part.step").write_bytes(b"the published file")
        lock_path = self.project / "vault-lock.json"
        lock = json.loads(lock_path.read_text())
        lock["publications"] = [{"key": "envelope", "path": "designs/parts/envelope", "request_id": "r", "master_id": "600",
                                 "version_id": "6001", "step_sha256": hashlib.sha256(b"the published file").hexdigest(),
                                 "git_commit": "c"}]
        lock_path.write_text(json.dumps(lock))
        published = {"name": "envelope.step", "kind": "step", "role": "standalone", "master_id": "600", "version_id": "6001"}
        result = self.status(discovery(files(), folder=[published]))
        self.assertEqual(result["publications"], [{"key": "envelope", "master_id": "600", "published_version_id": "6001",
                                                   "vault_version_id": "6001", "state": "in_sync",
                                                   "part_step_is_the_published_file": True}])
        self.assertEqual(result["other_files_in_the_folder"], [])
        (part_dir / "part.step").write_bytes(b"built again")
        result = self.status(discovery(files(), folder=[dict(published, version_id="6002")]))
        self.assertEqual((result["publications"][0]["state"], result["publications"][0]["part_step_is_the_published_file"]),
                         ("vault_newer", False))
        self.assertEqual(self.status(discovery(files()))["publications"][0]["state"], "not_in_folder")
        self.assertTrue(result["current"])                         # a publication is not part of the mirror

    def test_a_discovery_of_something_else_is_refused(self):
        cases = [
            (lambda d: d["roots"][0].update(master_id="950"), "no root assembly with master id 900"),
            (lambda d: d.update(vault_id="8"), "is of vault 8 and the project mirrors vault 7"),
            (lambda d: d["roots"][0].update(closure_read=False), "did not read the closure of root"),
            (lambda d: d.update(schema_version=2), "is not a discovery.json"),
            (lambda d: d["roots"][0]["closure"][0].pop("version_id"), "must list files with a master id and a version id"),
            (lambda d: d["roots"][0]["closure"].append(dict(d["roots"][0]["closure"][0], version_id="x")), "at two versions"),
        ]
        for change, message in cases:
            data = discovery(files())
            change(data)
            with self.assertRaisesRegex(ExchangeError, message):
                self.status(data)
        with self.assertRaisesRegex(ExchangeError, "has no vault-lock.json"):
            sync_status(self.base / "nothing", self.base / "discovery.json")

    def test_the_same_discovery_and_project_give_the_same_file_and_nothing_in_the_project_changes(self):
        before = {p.relative_to(self.project).as_posix(): p.read_bytes() for p in self.project.rglob("*") if p.is_file()}
        out = self.base / "out" / "sync-status.json"
        first = self.status(discovery(files()), out)
        written = out.read_bytes()
        self.assertEqual(json.loads(written), first)
        self.status(discovery(files()), out)
        self.assertEqual(out.read_bytes(), written)
        self.assertEqual({p.relative_to(self.project).as_posix(): p.read_bytes() for p in self.project.rglob("*") if p.is_file()}, before)

    def test_command_line(self):
        path = self.base / "discovery.json"
        path.write_text(json.dumps(discovery(files())), encoding="utf-8")
        self.assertEqual(main(["--project", str(self.project), "sync-status", str(path)]), 0)


if __name__ == "__main__":
    unittest.main()
