"""A project in the layout with one directory per Vault file: the index is read, checked against the
directories, and a verified publication is recorded in the authored part's vault.json. Offline."""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from test_publication import EXECUTION  # noqa: E402
from test_workflow import ProjectFixture, STEP  # noqa: E402
from vault_cad_tools.cli import main  # noqa: E402
from vault_cad_tools.exchange import prepare_publication, verify_request  # noqa: E402
from vault_cad_tools.layout_import import write_json  # noqa: E402
from vault_cad_tools.project import ExchangeError, Project, digest  # noqa: E402
from vault_cad_tools.publication import (  # noqa: E402
    Journal, StaticCatalog, import_publication_result, mark_uploaded, mark_uploading, plan_publication, record_result)

PIN = "references/parts/pin"
FRAME = "references/assemblies/frame"
BRACKET = "designs/parts/bracket"
DELIVERABLE = BRACKET + "/part.step"
NATIVE = "a" * 64


class LayoutFixture(ProjectFixture):
    """The base fixture's project, converted: one imported part, one imported assembly, one authored part."""

    def setUp(self):
        super().setUp()
        for d in (PIN, FRAME, BRACKET):
            (self.root / d).mkdir(parents=True)
        (self.root / PIN / "part.step").write_bytes(STEP)
        self.source(PIN, "part", "10", "101")
        self.source(FRAME, "assembly", "20", "201")
        (self.root / FRAME / "assembly.json").write_text("{}\n", encoding="utf-8")
        (self.root / DELIVERABLE).write_bytes(STEP + b"\n")
        (self.root / BRACKET / "build.py").write_text("def build(parameters):\n    return None\n", encoding="utf-8")
        write_json(self.root / BRACKET / "parameters.json", {"name": "Bracket"})
        self.receipt_for_bracket()
        self.lock = {"schema_version": 2, "components": [self.component("frame", "assembly", "20", "201"),
                                                         self.component("pin", "part", "10", "101")], "publications": []}
        write_json(self.root / "vault-lock.json", self.lock)
        (self.root / ".gitattributes").write_text("*.step -text -diff -merge\n", encoding="utf-8")
        self.git("init", "-q")
        self.commit("fixture")

    def source(self, path, kind, master, version, model_state="[Primary]"):
        write_json(self.root / path / "source.json", {
            "schema_version": 1, "kind": kind, "key": path.split("/")[-1], "model_state": model_state,
            "vault": {"vault_id": "28", "master_id": master, "version_id": version, "native_sha256": NATIVE}})

    def component(self, key, kind, master, version):
        part = kind == "part"
        return {"key": key, "path": f"references/{'parts' if part else 'assemblies'}/{key}", "kind": kind,
                "model_state": "[Primary]", "master_id": master, "version_id": version, "native_sha256": NATIVE,
                "step_sha256": digest(self.root / PIN / "part.step") if part else None,
                "step_data_sha256": "b" * 64 if part else None}

    def receipt_for_bracket(self):
        write_json(self.root / BRACKET / "receipt.json", {"schema_version": 1, "key": "bracket",
                                                          "step": {"sha256": digest(self.root / DELIVERABLE)}})

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-qm", message)

    def relock(self, change):
        change(self.lock)
        write_json(self.root / "vault-lock.json", self.lock)

    def states(self):
        return {r["path"]: r["state"] for r in self.project().status()["references"]}


class IndexTests(LayoutFixture):
    def test_the_index_is_read_and_the_directories_agree_with_it(self):
        project = self.project()
        self.assertTrue(project.layout)
        status = project.status()
        self.assertEqual(self.states(), {FRAME: "clean", PIN: "clean"})
        self.assertEqual((status["publication_count"], status["publications"]), (0, []))
        self.assertEqual(main(["--project", str(self.root), "status"]), 0)

    def test_the_earlier_lock_is_still_read(self):
        ProjectFixture.setUp(self)
        self.assertFalse(self.project().layout)
        self.assertEqual(self.project().status()["references"], [])

    def test_a_changed_missing_or_unindexed_reference_is_reported(self):
        (self.root / PIN / "part.step").write_bytes(STEP + b" ")
        self.assertEqual(self.states()[PIN], "modified")
        self.assertEqual(main(["--project", str(self.root), "status"]), 1)
        (self.root / PIN / "part.step").unlink()
        self.assertEqual(self.states()[PIN], "missing")
        (self.root / PIN / "part.step").write_bytes(STEP)
        self.source(FRAME, "assembly", "20", "202")                 # the directory names another Vault version
        self.assertEqual(self.states(), {FRAME: "modified", PIN: "clean"})
        self.source(FRAME, "assembly", "20", "201")
        (self.root / "references/parts/stray").mkdir()
        self.assertEqual(self.states()["references/parts/stray"], "not_in_index")

    def test_a_malformed_index_is_refused(self):
        for change in (lambda lock: lock["components"][1].update(path="references/parts/other"),
                       lambda lock: lock["components"][1].update(key="Pin"),
                       lambda lock: lock["components"][1].update(step_sha256="short"),
                       lambda lock: lock["components"][0].update(step_sha256="c" * 64),      # an assembly has no STEP
                       lambda lock: lock["components"].append(dict(lock["components"][1])),
                       lambda lock: lock["publications"].append({"key": "bracket", "path": "designs/parts/bracket"}),
                       lambda lock: lock.update(schema_version=3)):
            with self.subTest(change=change):
                good = json.loads(json.dumps(self.lock))
                self.relock(change)
                with self.assertRaisesRegex(ExchangeError, "vault-lock.json"):
                    self.project()
                self.lock = good
                write_json(self.root / "vault-lock.json", self.lock)
        self.project()

    def test_import_step_belongs_to_the_earlier_layout(self):
        with self.assertRaisesRegex(ExchangeError, "earlier layout"):
            self.import_payload("references/part.step")
        self.assertFalse((self.root / "references/part.step").exists())


class PrepareTests(LayoutFixture):
    def prepare(self, relative=DELIVERABLE, **kwargs):
        return prepare_publication(self.project(), relative, "$/Projects/Incoming", self.base / "exchange", **kwargs)

    def test_the_deliverable_is_the_authored_part_and_is_named_after_its_key(self):
        request = verify_request(self.prepare()["directory"])
        self.assertEqual(request["destination"]["name"], "bracket.step")
        self.assertEqual(request["provenance"]["project_path"], DELIVERABLE)
        self.assertEqual(request["payload"]["sha256"], digest(self.root / DELIVERABLE))
        named = verify_request(self.prepare(name="BRACKET rev A.step")["directory"])
        self.assertEqual(named["destination"]["name"], "BRACKET rev A.step")

    def test_only_an_authored_part_can_be_published(self):
        for relative in (PIN + "/part.step", BRACKET + "/build.py", "step/new-part.step", "designs/parts/Bracket/part.step",
                         "designs/parts/bracket/sub/part.step"):
            with self.subTest(relative=relative), self.assertRaisesRegex(ExchangeError, "designs/parts/<key>/part.step"):
                self.prepare(relative)
        for name in ("sub/bracket.step", "bracket.txt", "CON.step"):
            with self.subTest(name=name), self.assertRaisesRegex(ExchangeError, "Vault file name"):
                self.prepare(name=name)
        self.assertFalse((self.base / "exchange" / "requests").exists() and any((self.base / "exchange" / "requests").iterdir()))

    def test_a_part_that_is_not_what_its_receipt_describes_is_refused(self):
        (self.root / DELIVERABLE).write_bytes(STEP + b"\n\n")
        self.commit("edited by hand")
        with self.assertRaisesRegex(ExchangeError, "build the part again"):
            self.prepare()
        (self.root / BRACKET / "receipt.json").unlink()
        self.commit("no receipt")
        with self.assertRaisesRegex(ExchangeError, "build the part again"):
            self.prepare()

    def test_an_uncommitted_part_is_refused(self):
        (self.root / DELIVERABLE).write_bytes(STEP + b"\n\n")
        self.receipt_for_bracket()
        with self.assertRaisesRegex(ExchangeError, "Commit this STEP file"):
            self.prepare()


class RecordTests(LayoutFixture):
    """Linux side of a publication: the verified result ends up in the part's vault.json and in the index."""

    def published(self, master="900", version="901"):
        result = prepare_publication(self.project(), DELIVERABLE, "$/Projects/Incoming", self.base / "exchange")
        request_dir = Path(result["directory"])
        request = verify_request(request_dir)
        journal = Journal(self.base / f"journal-{version}.json")
        payload = (self.root / DELIVERABLE).read_bytes()
        listed = {"name": "bracket.step", "version_id": version, "master_id": master, "version": 1, "size": len(payload)}
        execution = dict(EXECUTION, server_file_size=len(payload), server_checksum=None)
        empty = StaticCatalog({"vault": {"id": "28", "name": "Test Vault"},
                               "folders": [{"id": "77", "full_name": "$/Projects/Incoming", "files": []}]})
        plan_publication(request_dir, empty, journal)
        mark_uploading(journal, request["request_id"])
        mark_uploaded(journal, request["request_id"], {"master_id": master, "version_id": version}, execution=execution)
        after = StaticCatalog({"vault": {"id": "28", "name": "Test Vault"},
                               "folders": [{"id": "77", "full_name": "$/Projects/Incoming", "files": [listed]}]}, {version: payload})
        out = record_result(request_dir, after, journal, {"master_id": master, "version_id": version}, self.base / f"work-{version}")
        return request, Path(out["result_path"])

    def test_a_verified_result_is_recorded_in_the_part_and_in_the_index(self):
        request, result = self.published()
        out = import_publication_result(self.project(), result)
        self.assertTrue(out["changed"] and out["part_step_matches_publication"])
        record = {"request_id": request["request_id"], "master_id": "900", "version_id": "901",
                  "git_commit": self.git("rev-parse", "HEAD"), "step_sha256": digest(self.root / DELIVERABLE)}
        self.assertEqual(json.loads((self.root / BRACKET / "vault.json").read_text()), {"schema_version": 1, "publications": [record]})
        project = self.project()
        self.assertEqual(project.lock["publications"], [dict(key="bracket", path=BRACKET, **record)])
        self.assertEqual(project.lock["components"], self.lock["components"])          # the references are not touched
        self.assertEqual(project.status()["publications"],
                         [{"path": BRACKET, "request_id": request["request_id"], "version_id": "901", "part_step": "as_published"}])
        self.assertEqual(main(["--project", str(self.root), "status"]), 0)
        again = import_publication_result(self.project(), result)
        self.assertFalse(again["changed"])
        self.assertEqual(len(self.project().lock["publications"]), 1)

    def test_a_second_publication_is_appended_and_a_rebuilt_part_is_reported(self):
        _, first = self.published()
        import_publication_result(self.project(), first)
        self.commit("first publication recorded")
        (self.root / DELIVERABLE).write_bytes(STEP + b"\n\n")
        self.receipt_for_bracket()
        self.commit("rebuilt")
        self.assertEqual(self.project().status()["publications"][0]["part_step"], "changed_since_publication")
        _, second = self.published(version="902")
        import_publication_result(self.project(), second)
        versions = [p["version_id"] for p in self.project().lock["publications"]]
        self.assertEqual(versions, ["901", "902"])
        self.assertEqual([p["part_step"] for p in self.project().status()["publications"]], ["changed_since_publication", "as_published"])

    def test_a_reused_vault_version_and_a_hand_edited_record_are_refused(self):
        _, first = self.published()
        import_publication_result(self.project(), first)
        self.commit("first publication recorded")
        _, same_version = self.published()                                  # another request reporting version 901 again
        with self.assertRaisesRegex(ExchangeError, "Vault version 901 is already recorded"):
            import_publication_result(self.project(), same_version)
        record = self.root / BRACKET / "vault.json"
        data = json.loads(record.read_text())
        data["publications"][0]["master_id"] = "999"
        write_json(record, data)
        with self.assertRaisesRegex(ExchangeError, "already recorded with different data"):
            import_publication_result(self.project(), first)
        states = {r["path"]: r["state"] for r in self.project().status()["references"]}
        self.assertEqual(states["vault-lock.json"], "modified")             # the index no longer repeats the record

    def test_a_working_file_that_is_gone_is_reported_not_refused(self):
        request, result = self.published()
        (self.root / BRACKET / "part.step").unlink()
        out = import_publication_result(self.project(), result)             # the committed blob still verifies
        self.assertFalse(out["part_step_matches_publication"])


if __name__ == "__main__":
    unittest.main()
