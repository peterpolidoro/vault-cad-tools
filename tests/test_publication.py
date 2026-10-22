"""Publication planning, journal, reconcile and verification tests. Offline: fake catalogs and a local HTTP stub."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import threading
import unittest
from urllib.parse import urlsplit, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from test_workflow import ProjectFixture, STEP  # noqa: E402
from vault_cad_tools.api import VaultClient  # noqa: E402
from vault_cad_tools.exchange import prepare_publication, verify_request  # noqa: E402
from vault_cad_tools.project import ExchangeError, atomic_json  # noqa: E402
from vault_cad_tools.publication import (  # noqa: E402
    Journal, RestCatalog, StaticCatalog, fingerprint, mark_ambiguous, mark_uploading, plan_publication,
    reconcile_publication, record_result, write_catalog_snapshot)


class PlanningFixture(ProjectFixture):
    def setUp(self):
        super().setUp()
        self.committed_part()
        self.exchange = self.base / "exchange"
        self.result = prepare_publication(self.project(), "step/new-part.step", "$/Projects/Incoming", self.exchange)
        self.request_dir = Path(self.result["directory"])
        self.request = verify_request(self.request_dir)
        self.journal = Journal(self.base / "journal.json")
        self.workdir = self.base / "work"

    def catalog(self, files=(), vault=None, folders=None, downloads=None):
        snapshot = {"vault": vault or {"id": "28", "name": "Test Vault"},
                    "folders": folders if folders is not None else [{"id": "77", "full_name": "$/Projects/Incoming", "files": list(files)}]}
        return StaticCatalog(snapshot, downloads)

    def plan(self, **kwargs):
        return plan_publication(self.request_dir, kwargs.pop("catalog", self.catalog()), self.journal, **kwargs)


class PlanTests(PlanningFixture):
    def test_plan_is_dry_run_and_journaled(self):
        plan = self.plan()
        self.assertTrue(plan["dry_run"])
        self.assertEqual(plan["status"], "planned_not_executed")
        self.assertEqual(plan["destination"]["folder_id"], "77")
        self.assertEqual(plan["payload"]["sha256"], self.request["payload"]["sha256"])
        self.assertIn("AddFile", plan["sdk_calls"][3]["api"])
        self.assertEqual(self.journal.entry(self.request["request_id"])["state"], "planned")
        written = json.loads(Path(plan["plan_path"]).read_text(encoding="utf-8"))
        self.assertEqual(written["request_id"], self.request["request_id"])
        self.assertEqual(Path(plan["plan_path"]).parent.name, "plans")
        self.assertEqual(self.project().lock["publications"], [])
        for secret in ("token", "password", "Authorization"):
            self.assertNotIn(secret, json.dumps(plan).lower().replace("authorization", "Authorization"))

    def test_vault_mismatch_refused(self):
        with self.assertRaisesRegex(ExchangeError, "vault mismatch"):
            self.plan(catalog=self.catalog(vault={"id": "29", "name": "Test Vault"}))
        with self.assertRaisesRegex(ExchangeError, "vault mismatch"):
            self.plan(catalog=self.catalog(vault={"id": "28", "name": "Other"}))
        self.assertEqual(self.journal.entry(self.request["request_id"])["state"], "refused")

    def test_missing_folder_refused_never_created(self):
        with self.assertRaisesRegex(ExchangeError, "does not exist"):
            self.plan(catalog=self.catalog(folders=[{"id": "1", "full_name": "$/Projects", "files": []}]))
        self.assertFalse((self.exchange / "plans").exists())

    def test_collision_refused_case_insensitively(self):
        files = [{"name": "NEW-PART.STEP", "version_id": "901", "master_id": "900", "version": 1, "size": 10}]
        with self.assertRaisesRegex(ExchangeError, "already contains"):
            self.plan(catalog=self.catalog(files=files))
        entry = self.journal.entry(self.request["request_id"])
        self.assertEqual(entry["state"], "refused")
        self.assertIn("collision", entry["notes"][-1]["note"])

    def test_other_names_do_not_collide(self):
        files = [{"name": "new-part-v2.step", "version_id": "901", "master_id": "900", "version": 1, "size": 10}]
        self.assertEqual(self.plan(catalog=self.catalog(files=files))["existing_files_in_folder"], 0)

    def test_tampered_payload_refused_before_journal(self):
        (self.request_dir / "payload.step").write_bytes(STEP + b"x")
        with self.assertRaisesRegex(ExchangeError, "does not match"):
            self.plan()
        self.assertIsNone(self.journal.entry(self.request["request_id"]))

    def test_identity_conflict_refused(self):
        self.plan()
        path = self.request_dir / "request.json"
        request = json.loads(path.read_text(encoding="utf-8"))
        request["destination"]["name"] = "renamed.step"
        atomic_json(path, request)
        with self.assertRaisesRegex(ExchangeError, "identity conflict"):
            self.plan()
        self.assertNotEqual(fingerprint(request), self.journal.entry(self.request["request_id"])["fingerprint"])

    def test_replanning_is_idempotent(self):
        first = self.plan()
        second = self.plan()
        self.assertEqual(first["fingerprint"], second["fingerprint"])
        self.assertEqual(len(self.journal.entry(self.request["request_id"])["attempts"]), 2)

    def test_ambiguous_blocks_retry(self):
        self.plan()
        mark_uploading(self.journal, self.request["request_id"])
        with self.assertRaisesRegex(ExchangeError, "reconcile"):
            self.plan()
        mark_ambiguous(self.journal, self.request["request_id"], "timeout")
        with self.assertRaisesRegex(ExchangeError, "reconcile"):
            self.plan()
        with self.assertRaisesRegex(ExchangeError, "reconcile"):
            mark_uploading(self.journal, self.request["request_id"])
        self.journal.record(self.request["request_id"], state="verified", vault_ids={"master_id": "1", "version_id": "2"})
        with self.assertRaisesRegex(ExchangeError, "not ready"):
            mark_uploading(self.journal, self.request["request_id"])

    def test_settled_request_has_no_calls(self):
        self.plan()
        self.journal.record(self.request["request_id"], state="verified", vault_ids={"master_id": "1", "version_id": "2"})
        plan = self.plan()
        self.assertEqual(plan["status"], "already_verified")
        self.assertEqual(plan["sdk_calls"], [])

    def test_journal_rejects_unknown_schema(self):
        atomic_json(self.base / "bad.json", {"schema_version": 99})
        with self.assertRaises(ExchangeError):
            Journal(self.base / "bad.json")


class ReconcileTests(PlanningFixture):
    def ambiguous(self):
        self.plan()
        mark_uploading(self.journal, self.request["request_id"])
        mark_ambiguous(self.journal, self.request["request_id"], "socket timeout after UploadFilePart")

    def test_absent_file_requires_acknowledgement(self):
        self.ambiguous()
        outcome = reconcile_publication(self.request_dir, self.catalog(), self.journal, self.workdir)
        self.assertEqual(outcome["action"], "awaiting_acknowledgement")
        self.assertEqual(self.journal.entry(self.request["request_id"])["state"], "ambiguous")
        outcome = reconcile_publication(self.request_dir, self.catalog(), self.journal, self.workdir, acknowledge_no_file=True)
        self.assertEqual(outcome["action"], "retry_permitted")
        self.assertEqual(self.plan()["status"], "planned_not_executed")

    def test_present_identical_file_is_recovered(self):
        self.ambiguous()
        files = [{"name": "new-part.step", "version_id": "901", "master_id": "900", "version": 1, "size": len(STEP)}]
        outcome = reconcile_publication(self.request_dir, self.catalog(files=files, downloads={"901": STEP}), self.journal, self.workdir)
        self.assertEqual(outcome["action"], "recovered")
        entry = self.journal.entry(self.request["request_id"])
        self.assertEqual(entry["state"], "uploaded")
        self.assertEqual(entry["vault_ids"]["version_id"], "901")
        self.assertEqual(self.plan()["status"], "already_uploaded")

    def test_present_different_file_is_collision(self):
        self.ambiguous()
        files = [{"name": "new-part.step", "version_id": "901", "master_id": "900", "version": 1, "size": 5}]
        outcome = reconcile_publication(self.request_dir, self.catalog(files=files, downloads={"901": b"other"}), self.journal, self.workdir)
        self.assertEqual(outcome["action"], "collision_after_ambiguous")
        self.assertEqual(self.journal.entry(self.request["request_id"])["state"], "refused")

    def test_settled_request_is_left_alone(self):
        self.plan()
        self.assertEqual(reconcile_publication(self.request_dir, self.catalog(), self.journal, self.workdir)["action"], "none")


class ResultTests(PlanningFixture):
    def test_verified_result_written_atomically(self):
        self.plan()
        result = record_result(self.request_dir, self.catalog(downloads={"901": STEP}), self.journal,
                               {"master_id": "900", "version_id": "901"}, self.workdir)
        self.assertEqual(result["status"], "verified")
        path = Path(result["result_path"])
        # The exchange path may be spelled with a Windows short name (POLIDO~1); compare resolved paths.
        self.assertEqual(path.parent.resolve(), (self.exchange / "results").resolve())
        self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["vault"]["version_id"], "901")
        self.assertEqual(self.journal.entry(self.request["request_id"])["state"], "verified")
        self.assertEqual(self.project().lock["publications"], [])

    def test_mismatch_is_recorded_not_verified(self):
        self.plan()
        with self.assertRaisesRegex(ExchangeError, "does not match"):
            record_result(self.request_dir, self.catalog(downloads={"901": STEP + b"corrupt"}), self.journal,
                          {"master_id": "900", "version_id": "901"}, self.workdir)
        result = json.loads((self.exchange / "results" / f"{self.request['request_id']}.json").read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "mismatch")
        self.assertEqual(self.journal.entry(self.request["request_id"])["state"], "failed")

    def test_result_needs_both_ids(self):
        self.plan()
        with self.assertRaisesRegex(ExchangeError, "master_id and version_id"):
            record_result(self.request_dir, self.catalog(), self.journal, {"version_id": "901"}, self.workdir)


class RestCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.requests = []
        folders = {"root": {"id": "1", "name": "$", "fullName": "$"},
                   "1": [{"id": "5", "name": "Projects", "fullName": "$/Projects"}],
                   "5": [{"id": "77", "name": "Incoming", "fullName": "$/Projects/Incoming"}],
                   "77": []}
        contents = {"77": [{"id": "901", "name": "Existing.STEP", "version": 2, "size": 3, "file": {"id": "900"}}]}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self, code, body):
                data = json.dumps(body).encode("utf-8") if not isinstance(body, bytes) else body
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                parts = urlsplit(self.path)
                cls.requests.append((parts.path, parse_qs(parts.query), self.headers.get("Authorization")))
                segments = parts.path.strip("/").split("/")
                if segments[-1] == "vaults":
                    return self.respond(200, {"results": [{"id": "28", "name": "Test Vault"}]})
                if segments[-2:] == ["folders", "root"]:
                    return self.respond(200, folders["root"])
                if segments[-1] == "sub-folders":
                    return self.respond(200, {"results": folders.get(segments[-2], []), "pagination": {}})
                if segments[-1] == "contents":
                    cursor = parse_qs(parts.query).get("cursorState", [None])[0]
                    if cursor is None:
                        return self.respond(200, {"results": contents.get(segments[-2], []), "pagination": {"cursorState": "page2"}})
                    return self.respond(200, {"results": [], "pagination": {"cursorState": "page2"}})
                if segments[-1] == "content":
                    return self.respond(200, b"abc")
                return self.respond(404, {})

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.catalog = RestCatalog(VaultClient(f"http://127.0.0.1:{cls.server.server_port}/api/", "test-token"), "28")

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def test_identity_and_folder_walk(self):
        self.assertEqual(self.catalog.vault_identity(), {"id": "28", "name": "Test Vault"})
        folder = self.catalog.folder_by_path("$/projects/incoming")
        self.assertEqual(folder["id"], "77")
        self.assertIsNone(self.catalog.folder_by_path("$/Projects/Missing"))
        self.assertTrue(all(auth == "Bearer test-token" for _, _, auth in self.requests))

    def test_contents_pagination_terminates_and_maps_ids(self):
        files = self.catalog.files_in_folder("77")
        self.assertEqual(files, [{"name": "Existing.STEP", "version_id": "901", "master_id": "900", "version": 2, "size": 3}])

    def test_snapshot_capture_is_read_only_and_downloads_exact_bytes(self):
        with_temp = Path(__import__("tempfile").mkdtemp())
        snapshot = write_catalog_snapshot(with_temp / "snapshot.json", self.catalog, ["$/Projects/Incoming", "$/Projects/Nope"])
        self.assertEqual(snapshot["missing_folders"], ["$/Projects/Nope"])
        self.assertEqual(snapshot["folders"][0]["files"][0]["name"], "Existing.STEP")
        self.catalog.download("901", with_temp / "dl.step")
        self.assertEqual((with_temp / "dl.step").read_bytes(), b"abc")
        self.assertTrue(all(path.startswith("/api/") for path, _, _ in self.requests))


if __name__ == "__main__":
    unittest.main()
