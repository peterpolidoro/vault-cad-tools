"""Publication planning, journal transitions, reconcile and verification tests. Offline: fake catalogs and a local HTTP stub."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import threading
import unittest
import zlib
from urllib.parse import urlsplit, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from test_workflow import ProjectFixture, STEP  # noqa: E402
from vault_cad_tools.api import VaultClient  # noqa: E402
from vault_cad_tools.exchange import prepare_publication, verify_request  # noqa: E402
from vault_cad_tools.project import ExchangeError, atomic_json  # noqa: E402
from vault_cad_tools.publication import (  # noqa: E402
    Journal, RestCatalog, StaticCatalog, fingerprint, import_publication_result, mark_ambiguous, mark_failed, mark_uploaded,
    mark_uploading, normalize_execution, plan_publication, reconcile_publication, record_result, write_catalog_snapshot)

STEP_CRC = zlib.crc32(STEP) & 0xFFFFFFFF
UPLOADED_FILE = {"name": "new-part.step", "version_id": "901", "master_id": "900", "version": 1, "size": len(STEP)}
EXECUTION = {"executed_at": "2026-10-22T16:00:00Z", "executed_by_host": "test-host", "comment_sent": "vault-cad-tools request x",
             "folder_id": "77", "server_version_number": 1, "server_file_size": len(STEP), "server_checksum": STEP_CRC}


class PlanningFixture(ProjectFixture):
    def setUp(self):
        super().setUp()
        self.committed_part()
        self.exchange = self.base / "exchange"
        self.result = prepare_publication(self.project(), "step/new-part.step", "$/Projects/Incoming", self.exchange)
        self.request_dir = Path(self.result["directory"])
        self.request = verify_request(self.request_dir)
        self.rid = self.request["request_id"]
        self.journal = Journal(self.base / "journal.json")
        self.workdir = self.base / "work"

    def catalog(self, files=(), vault=None, folders=None, downloads=None):
        snapshot = {"vault": vault or {"id": "28", "name": "Test Vault"},
                    "folders": folders if folders is not None else [{"id": "77", "full_name": "$/Projects/Incoming", "files": list(files)}]}
        return StaticCatalog(snapshot, downloads)

    def plan(self, **kwargs):
        return plan_publication(self.request_dir, kwargs.pop("catalog", self.catalog()), self.journal, **kwargs)

    def upload(self, execution=EXECUTION):
        mark_uploading(self.journal, self.rid)
        mark_uploaded(self.journal, self.rid, {"master_id": "900", "version_id": "901"}, execution=execution)

    def after_upload_catalog(self, files=(UPLOADED_FILE,), payload=STEP):
        return self.catalog(files=list(files), downloads={"901": payload})

    def state(self):
        return self.journal.entry(self.rid)["state"]


class PlanTests(PlanningFixture):
    def test_plan_is_dry_run_and_journaled(self):
        plan = self.plan()
        self.assertTrue(plan["dry_run"])
        self.assertEqual(plan["status"], "planned_not_executed")
        self.assertEqual(plan["destination"]["folder_id"], "77")
        self.assertEqual(plan["payload"]["sha256"], self.request["payload"]["sha256"])
        self.assertIn("UploadFilePart", plan["sdk_calls"][4]["api"])
        self.assertEqual(self.state(), "planned")
        written = json.loads(Path(plan["plan_path"]).read_text(encoding="utf-8"))
        self.assertEqual(written["request_id"], self.rid)
        self.assertEqual(Path(plan["plan_path"]).parent.name, "plans")
        self.assertEqual(self.project().lock["publications"], [])
        for secret in ("token", "password", "authorization"):
            self.assertNotIn(secret, json.dumps(plan).lower())

    def test_vault_mismatch_refused(self):
        with self.assertRaisesRegex(ExchangeError, "vault mismatch"):
            self.plan(catalog=self.catalog(vault={"id": "29", "name": "Test Vault"}))
        with self.assertRaisesRegex(ExchangeError, "vault mismatch"):
            self.plan(catalog=self.catalog(vault={"id": "28", "name": "Other"}))
        self.assertEqual(self.state(), "refused")

    def test_missing_folder_refused_never_created(self):
        with self.assertRaisesRegex(ExchangeError, "does not exist"):
            self.plan(catalog=self.catalog(folders=[{"id": "1", "full_name": "$/Projects", "files": []}]))
        self.assertFalse((self.exchange / "plans").exists())

    def test_collision_refused_case_insensitively_then_replannable(self):
        files = [{"name": "NEW-PART.STEP", "version_id": "901", "master_id": "900", "version": 1, "size": 10}]
        with self.assertRaisesRegex(ExchangeError, "already contains"):
            self.plan(catalog=self.catalog(files=files))
        entry = self.journal.entry(self.rid)
        self.assertEqual(entry["state"], "refused")
        self.assertIn("collision", entry["notes"][-1]["note"])
        self.assertEqual(self.plan()["status"], "planned_not_executed")  # refused -> planned is legal

    def test_other_names_do_not_collide(self):
        files = [{"name": "new-part-v2.step", "version_id": "901", "master_id": "900", "version": 1, "size": 10}]
        self.assertEqual(self.plan(catalog=self.catalog(files=files))["existing_files_in_folder"], 0)

    def test_tampered_payload_refused_before_journal(self):
        (self.request_dir / "payload.step").write_bytes(STEP + b"x")
        with self.assertRaisesRegex(ExchangeError, "does not match"):
            self.plan()
        self.assertIsNone(self.journal.entry(self.rid))

    def test_identity_conflict_refused(self):
        self.plan()
        path = self.request_dir / "request.json"
        request = json.loads(path.read_text(encoding="utf-8"))
        request["destination"]["name"] = "renamed.step"
        atomic_json(path, request)
        with self.assertRaisesRegex(ExchangeError, "identity conflict"):
            self.plan()
        self.assertNotEqual(fingerprint(request), self.journal.entry(self.rid)["fingerprint"])

    def test_replanning_is_idempotent(self):
        first = self.plan()
        second = self.plan()
        self.assertEqual(first["fingerprint"], second["fingerprint"])
        self.assertEqual(len(self.journal.entry(self.rid)["attempts"]), 2)

    def test_ambiguous_blocks_retry_and_settlement(self):
        self.plan()
        mark_uploading(self.journal, self.rid)
        with self.assertRaisesRegex(ExchangeError, "reconcile"):
            self.plan()
        mark_ambiguous(self.journal, self.rid, "timeout")
        with self.assertRaisesRegex(ExchangeError, "reconcile"):
            self.plan()
        with self.assertRaisesRegex(ExchangeError, "reconcile"):
            mark_uploading(self.journal, self.rid)
        with self.assertRaisesRegex(ExchangeError, "Illegal journal transition ambiguous -> verified"):
            self.journal.record(self.rid, state="verified")

    def test_settled_request_has_no_calls(self):
        self.plan()
        self.upload()
        record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        plan = self.plan()
        self.assertEqual(plan["status"], "already_verified")
        self.assertEqual(plan["sdk_calls"], [])
        with self.assertRaisesRegex(ExchangeError, "not ready"):
            mark_uploading(self.journal, self.rid)

    def test_failed_is_terminal(self):
        self.plan()
        mark_uploading(self.journal, self.rid)
        mark_failed(self.journal, self.rid, "folder id changed between plan and upload")
        with self.assertRaisesRegex(ExchangeError, "manual review"):
            self.plan()
        with self.assertRaisesRegex(ExchangeError, "Illegal journal transition failed -> planned"):
            self.journal.record(self.rid, state="planned")

    def test_journal_rejects_unknown_schema(self):
        atomic_json(self.base / "bad.json", {"schema_version": 99})
        with self.assertRaises(ExchangeError):
            Journal(self.base / "bad.json")


class TransitionTests(PlanningFixture):
    def test_table_blocks_jumps_from_every_state(self):
        self.plan()
        for state in ("uploaded", "verified", "ambiguous", "failed"):
            with self.assertRaisesRegex(ExchangeError, "Illegal journal transition planned"):
                self.journal.record(self.rid, state=state)
        with self.assertRaisesRegex(ExchangeError, "Illegal journal transition planned -> ambiguous"):
            mark_ambiguous(self.journal, self.rid, "no call was made")
        with self.assertRaisesRegex(ExchangeError, "results can be recorded only from 'uploaded'"):
            record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        mark_uploading(self.journal, self.rid)
        with self.assertRaisesRegex(ExchangeError, "results can be recorded only from 'uploaded'"):
            record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        with self.assertRaisesRegex(ExchangeError, "Illegal journal transition uploading -> verified"):
            self.journal.record(self.rid, state="verified")
        mark_ambiguous(self.journal, self.rid, "timeout")
        with self.assertRaisesRegex(ExchangeError, "results can be recorded only from 'uploaded'"):
            record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        self.assertEqual(self.state(), "ambiguous")

    def test_reconcile_is_the_only_way_out_of_ambiguous(self):
        self.plan()
        mark_uploading(self.journal, self.rid)
        mark_ambiguous(self.journal, self.rid, "socket timeout after UploadFilePart")
        outcome = reconcile_publication(self.request_dir, self.after_upload_catalog(), self.journal, self.workdir)
        self.assertEqual(outcome["action"], "recovered")
        self.assertEqual(self.state(), "uploaded")
        result = record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.base / "work2")
        self.assertEqual(result["status"], "verified")
        self.assertEqual([h["to"] for h in self.journal.entry(self.rid)["history"]], ["uploading", "ambiguous", "uploaded", "verified"])

    def test_mark_uploaded_needs_ids_and_typed_execution(self):
        self.plan()
        mark_uploading(self.journal, self.rid)
        with self.assertRaisesRegex(ExchangeError, "master_id and version_id"):
            mark_uploaded(self.journal, self.rid, {"version_id": "901"})
        with self.assertRaisesRegex(ExchangeError, "must be an integer"):
            mark_uploaded(self.journal, self.rid, {"master_id": "900", "version_id": "901"}, execution={"server_file_size": "big"})
        with self.assertRaisesRegex(ExchangeError, "Unknown execution fields"):
            mark_uploaded(self.journal, self.rid, {"master_id": "900", "version_id": "901"}, execution={"token": "x"})
        with self.assertRaisesRegex(ExchangeError, "JSON object"):
            normalize_execution(["not", "a", "dict"])
        self.assertEqual(normalize_execution({"folder_id": 77, "server_checksum": "12"}), {"folder_id": "77", "server_checksum": 12})
        mark_uploaded(self.journal, self.rid, {"master_id": "900", "version_id": "901"}, execution=EXECUTION)
        self.assertEqual(self.journal.entry(self.rid)["execution"]["server_checksum"], STEP_CRC)


class ReconcileTests(PlanningFixture):
    def ambiguous(self):
        self.plan()
        mark_uploading(self.journal, self.rid)
        mark_ambiguous(self.journal, self.rid, "socket timeout after UploadFilePart")

    def test_absent_file_requires_acknowledgement(self):
        self.ambiguous()
        outcome = reconcile_publication(self.request_dir, self.catalog(), self.journal, self.workdir)
        self.assertEqual(outcome["action"], "awaiting_acknowledgement")
        self.assertEqual(self.state(), "ambiguous")
        outcome = reconcile_publication(self.request_dir, self.catalog(), self.journal, self.workdir, acknowledge_no_file=True)
        self.assertEqual(outcome["action"], "retry_permitted")
        self.assertEqual(self.plan()["status"], "planned_not_executed")

    def test_present_identical_file_is_recovered(self):
        self.ambiguous()
        outcome = reconcile_publication(self.request_dir, self.after_upload_catalog(), self.journal, self.workdir)
        self.assertEqual(outcome["action"], "recovered")
        entry = self.journal.entry(self.rid)
        self.assertEqual(entry["state"], "uploaded")
        self.assertEqual(entry["vault_ids"]["version_id"], "901")
        self.assertEqual(self.plan()["status"], "already_uploaded")

    def test_present_different_file_is_collision(self):
        self.ambiguous()
        files = [dict(UPLOADED_FILE, size=5)]
        outcome = reconcile_publication(self.request_dir, self.catalog(files=files, downloads={"901": b"other"}), self.journal, self.workdir)
        self.assertEqual(outcome["action"], "collision_after_ambiguous")
        self.assertEqual(self.state(), "refused")

    def test_settled_request_is_left_alone(self):
        self.plan()
        self.assertEqual(reconcile_publication(self.request_dir, self.catalog(), self.journal, self.workdir)["action"], "none")


class ResultTests(PlanningFixture):
    def test_verified_result_checks_folder_listing_bytes_size_and_crc(self):
        self.plan()
        self.upload()
        result = record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        self.assertEqual(result["status"], "verified")
        self.assertTrue(all(v is not False for v in result["checks"].values()))
        self.assertTrue(result["checks"]["server_checksum_matches_download_crc32"])
        self.assertTrue(result["checks"]["version_listed_in_folder"])
        self.assertEqual(result["fingerprint"], fingerprint(self.request))
        self.assertEqual(result["destination"]["folder_id"], "77")
        self.assertEqual(result["execution"]["server_version_number"], 1)
        path = Path(result["result_path"])
        self.assertEqual(path.parent.resolve(), (self.exchange / "results").resolve())
        self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["vault"]["version_id"], "901")
        self.assertEqual(self.state(), "verified")
        self.assertEqual(self.project().lock["publications"], [])

    def test_mismatch_when_version_not_listed_in_folder(self):
        self.plan()
        self.upload()
        with self.assertRaisesRegex(ExchangeError, "version_listed_in_folder"):
            record_result(self.request_dir, self.catalog(files=[], downloads={"901": STEP}), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        self.assertEqual(self.state(), "failed")

    def test_mismatch_when_listed_under_other_name(self):
        self.plan()
        self.upload()
        files = [dict(UPLOADED_FILE, name="something-else.step")]
        with self.assertRaisesRegex(ExchangeError, "listed_under_destination_name"):
            record_result(self.request_dir, self.catalog(files=files, downloads={"901": STEP}), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)

    def test_mismatch_when_bytes_differ(self):
        self.plan()
        self.upload()
        with self.assertRaisesRegex(ExchangeError, "sha256_matches_payload"):
            record_result(self.request_dir, self.after_upload_catalog(payload=STEP + b"corrupt"), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        result = json.loads((self.exchange / "results" / f"{self.rid}.json").read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "mismatch")

    def test_mismatch_when_server_size_or_checksum_disagree(self):
        self.plan()
        self.upload(execution=dict(EXECUTION, server_file_size=len(STEP) + 1))
        with self.assertRaisesRegex(ExchangeError, "server_file_size_matches_download"):
            record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        # a fresh request for the checksum case
        other = prepare_publication(self.project(), "step/new-part.step", "$/Projects/Incoming", self.exchange)
        other_dir = Path(other["directory"])
        rid = other["request_id"]
        plan_publication(other_dir, self.catalog(), self.journal)
        mark_uploading(self.journal, rid)
        mark_uploaded(self.journal, rid, {"master_id": "900", "version_id": "901"}, execution=dict(EXECUTION, server_checksum=STEP_CRC ^ 1))
        with self.assertRaisesRegex(ExchangeError, "server_checksum_matches_download_crc32"):
            record_result(other_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.base / "work3")

    def test_mismatch_when_executor_folder_id_differs(self):
        self.plan()
        self.upload(execution=dict(EXECUTION, folder_id="78"))
        with self.assertRaisesRegex(ExchangeError, "folder_id_matches_execution"):
            record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)

    def test_ids_must_match_the_journaled_upload(self):
        self.plan()
        self.upload()
        with self.assertRaisesRegex(ExchangeError, "differ from the ids journaled"):
            record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "999"}, self.workdir)
        with self.assertRaisesRegex(ExchangeError, "master_id and version_id"):
            record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"version_id": "901"}, self.workdir)

    def test_execution_from_journal_is_used_when_not_passed(self):
        self.plan()
        self.upload()
        result = record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        self.assertEqual(result["execution"]["executed_by_host"], "test-host")


class RestCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.requests = []
        folders = {"root": {"id": "1", "name": "$", "fullName": "$"},
                   "1": [{"id": "5", "name": "Projects", "fullName": "$/Projects"}],
                   "5": [{"id": "77", "name": "Incoming", "fullName": "$/Projects/Incoming"}],
                   "77": []}
        contents = {"77": [{"id": "901", "name": "Existing.STEP", "version": 2, "size": 3, "file": {"id": "900"}, "isHidden": True}]}

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

    def test_contents_include_hidden_paginate_and_map_ids(self):
        self.requests.clear()
        files = self.catalog.files_in_folder("77")
        self.assertEqual(files, [{"name": "Existing.STEP", "version_id": "901", "master_id": "900", "version": 2, "size": 3, "hidden": True}])
        self.assertTrue(all(q.get("option[includeHidden]") == ["true"] for path, q, _ in self.requests if path.endswith("/contents")))

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


class IngestTests(PlanningFixture):
    """Linux side: only a verified result that re-checks against its request and the project history is recorded."""

    def verified_result_path(self):
        self.plan()
        self.upload()
        result = record_result(self.request_dir, self.after_upload_catalog(), self.journal, {"master_id": "900", "version_id": "901"}, self.workdir)
        return Path(result["result_path"])

    def edit_result(self, path, mutate):
        data = json.loads(path.read_text(encoding="utf-8"))
        mutate(data)
        atomic_json(path, data)

    def test_import_records_publication_from_result_and_request(self):
        path = self.verified_result_path()
        out = import_publication_result(self.project(), path)
        self.assertTrue(out["changed"])
        pubs = self.project().lock["publications"]
        self.assertEqual(len(pubs), 1)
        rec = pubs[0]
        self.assertEqual(rec["request_id"], self.rid)
        self.assertEqual(rec["vault"], {"id": "28", "name": "Test Vault", "master_id": "900", "version_id": "901", "version": 1})
        self.assertEqual(rec["project_path"], "step/new-part.step")
        self.assertEqual(rec["git_commit"], self.request["provenance"]["git_commit"])
        self.assertEqual(rec["destination"], {"folder": "$/Projects/Incoming", "folder_id": "77", "name": "new-part.step"})
        self.assertEqual(rec["executed_by_host"], "test-host")
        self.assertEqual(rec["fingerprint"], fingerprint(self.request))
        self.assertTrue(rec["working_tree_matches_at_import"])
        self.assertTrue(rec["imported_at"])
        self.assertEqual(self.project().status()["publication_count"], 1)

    def test_reimport_of_identical_result_is_a_no_op(self):
        path = self.verified_result_path()
        import_publication_result(self.project(), path)
        again = import_publication_result(self.project(), path)
        self.assertFalse(again["changed"])
        self.assertEqual(len(self.project().lock["publications"]), 1)

    def test_only_verified_status_is_imported(self):
        path = self.verified_result_path()
        self.edit_result(path, lambda d: d.__setitem__("status", "mismatch"))
        with self.assertRaisesRegex(ExchangeError, "Only verified"):
            import_publication_result(self.project(), path)
        self.assertEqual(self.project().lock["publications"], [])

    def test_fingerprint_payload_and_checks_are_recomputed_or_required(self):
        path = self.verified_result_path()
        for mutate, message in (
                (lambda d: d.__setitem__("fingerprint", "0" * 64), "fingerprint"),
                (lambda d: d.__setitem__("payload_sha256", "1" * 64), "payload identity"),
                (lambda d: d.__setitem__("downloaded_bytes", 1), "re-download"),
                (lambda d: d["destination"].__setitem__("name", "other.step"), "destination differs"),
                (lambda d: d["destination"].pop("folder_id"), "folder id"),
                (lambda d: d["vault"].pop("version_id"), "vault identity"),
                (lambda d: d["checks"].__setitem__("version_listed_in_folder", False), "checks"),
                (lambda d: d["checks"].pop("listed_master_matches"), "checks"),
                (lambda d: d.__setitem__("execution", {"executed_at": "x"}), "executed_by_host"),
                (lambda d: d.__setitem__("execution", {"executed_at": "x", "executed_by_host": "h", "bogus": 1}), "Unknown execution"),
        ):
            original = path.read_bytes()
            self.edit_result(path, mutate)
            with self.assertRaisesRegex(ExchangeError, message):
                import_publication_result(self.project(), path)
            path.write_bytes(original)
        self.assertEqual(self.project().lock["publications"], [])
        self.assertTrue(import_publication_result(self.project(), path)["changed"])

    def test_result_must_sit_beside_its_request_in_the_exchange(self):
        path = self.verified_result_path()
        stray = self.base / "elsewhere" / "results" / path.name
        stray.parent.mkdir(parents=True)
        stray.write_bytes(path.read_bytes())
        with self.assertRaisesRegex(ExchangeError, "Request directory missing"):
            import_publication_result(self.project(), stray)
        renamed = path.with_name("not-the-id.json")
        renamed.write_bytes(path.read_bytes())
        with self.assertRaisesRegex(ExchangeError, "does not match its request id"):
            import_publication_result(self.project(), renamed, exchange=self.exchange)

    def test_committed_blob_must_hash_to_the_payload(self):
        path = self.verified_result_path()
        bogus = "f" * 40
        request_file = self.request_dir / "request.json"
        request = json.loads(request_file.read_text(encoding="utf-8"))
        request["provenance"]["git_commit"] = bogus
        atomic_json(request_file, request)
        self.edit_result(path, lambda d: d["provenance"].__setitem__("git_commit", bogus))
        with self.assertRaisesRegex(ExchangeError, "Git history"):
            import_publication_result(self.project(), path)
        self.assertEqual(self.project().lock["publications"], [])

    def test_conflicting_record_and_reused_vault_version_are_refused(self):
        path = self.verified_result_path()
        import_publication_result(self.project(), path)
        self.edit_result(path, lambda d: d["execution"].__setitem__("executed_by_host", "another-host"))
        with self.assertRaisesRegex(ExchangeError, "different data"):
            import_publication_result(self.project(), path)
        project = self.project()
        project.lock["publications"][0]["request_id"] = "11111111-1111-4111-8111-111111111111"
        atomic_json(project.lock_path, project.lock)
        self.edit_result(path, lambda d: d["execution"].__setitem__("executed_by_host", "test-host"))
        with self.assertRaisesRegex(ExchangeError, "already recorded under request"):
            import_publication_result(self.project(), path)
        self.assertEqual(len(self.project().lock["publications"]), 1)
