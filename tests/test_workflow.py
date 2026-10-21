"""Behavioral regression tests; fixtures contain envelopes, not real CAD solids."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from vault_cad_tools.api import VaultClient, session
from vault_cad_tools.exchange import prepare_publication, verify_request
from vault_cad_tools.project import ExchangeError, Project, atomic_json, digest, portable_path


STEP = b"ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\nENDSEC;\nEND-ISO-10303-21;\n"


class ProjectFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "project"
        self.root.mkdir()
        (self.root / "vault-project.toml").write_text('''schema_version = 1
[project]
name = "test"
[vault]
base_url = "http://localhost/api/"
name = "Test Vault"
id = "28"
root_assembly = "$/Projects/Enclosure.iam"
''', encoding="utf-8")
        atomic_json(self.root / "vault-lock.json", {"schema_version": 1, "references": {}, "publications": []})
        self.payload = self.base / "export.step"
        self.payload.write_bytes(STEP)
        self.receipt_path = self.base / "export.json"
        self.receipt = {
            "schema_version": 1,
            "source": {"vault_id": "28", "master_id": "10", "version_id": "101", "path": "$/Projects/part.ipt"},
            "exporter": {"name": "test fixture", "version": "1", "model_state": "Primary", "protocol": "AP214"},
            "sha256": digest(self.payload),
        }
        atomic_json(self.receipt_path, self.receipt)

    def project(self):
        return Project(self.root)

    def import_payload(self, name="references/part.step"):
        return self.project().import_step(self.payload, name, self.receipt_path)

    def update_receipt(self, version="102"):
        self.receipt["sha256"] = digest(self.payload)
        self.receipt["source"]["version_id"] = version
        atomic_json(self.receipt_path, self.receipt)

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, check=True)
        return result.stdout.decode().strip()

    def committed_part(self):
        (self.root / "step").mkdir()
        part = self.root / "step" / "new-part.step"
        part.write_bytes(STEP)
        (self.root / ".gitattributes").write_text("*.step -text -diff -merge\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("add", ".gitattributes", "step/new-part.step")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        return part


class ImportTests(ProjectFixture):
    def test_records_exact_provenance_and_is_idempotent(self):
        result = self.import_payload()
        self.assertTrue(result["changed"])
        lock_before = (self.root / "vault-lock.json").read_bytes()
        self.assertEqual(self.project().status()["references"][0]["source"]["version_id"], "101")
        self.assertFalse(self.import_payload()["changed"])
        self.assertEqual((self.root / "vault-lock.json").read_bytes(), lock_before)

    def test_update_clean_reference(self):
        self.import_payload()
        self.payload.write_bytes(STEP.replace(b"DATA;", b"DATA; /* changed */"))
        self.update_receipt()
        self.import_payload()
        self.assertEqual(self.project().status()["references"][0]["source"]["version_id"], "102")
        self.assertEqual(digest(self.root / "references/part.step"), digest(self.payload))

    def test_modified_reference_survives_refresh(self):
        self.import_payload()
        target = self.root / "references/part.step"
        target.write_bytes(STEP + b"local modification")
        with self.assertRaisesRegex(ExchangeError, "locally modified"):
            self.import_payload()
        self.assertTrue(target.read_bytes().endswith(b"local modification"))
        self.assertEqual(self.project().status()["references"][0]["state"], "modified")

    def test_untracked_reference_is_not_overwritten(self):
        target = self.root / "references/part.step"
        target.parent.mkdir()
        target.write_bytes(STEP)
        with self.assertRaisesRegex(ExchangeError, "untracked"):
            self.import_payload()

    def test_wrong_checksum_has_no_side_effect(self):
        self.receipt["sha256"] = "0" * 64
        atomic_json(self.receipt_path, self.receipt)
        with self.assertRaisesRegex(ExchangeError, "checksum"):
            self.import_payload()
        self.assertFalse((self.root / "references").exists())

    def test_wrong_vault_is_rejected(self):
        self.receipt["source"]["vault_id"] = "29"
        atomic_json(self.receipt_path, self.receipt)
        with self.assertRaisesRegex(ExchangeError, "another vault"):
            self.import_payload()

    def test_reference_identity_cannot_be_reassigned(self):
        self.import_payload()
        self.receipt["source"]["master_id"] = "99"
        atomic_json(self.receipt_path, self.receipt)
        with self.assertRaisesRegex(ExchangeError, "another Vault file"):
            self.import_payload()

    def test_windows_case_collision(self):
        self.import_payload()
        with self.assertRaisesRegex(ExchangeError, "collides"):
            self.import_payload("references/PART.step")

    def test_rejects_paths_outside_reference_area(self):
        for name in ("references/../../escape.step", "references/C:/escape.step", "step/authored.step", "/absolute.step"):
            with self.subTest(name=name), self.assertRaises(ExchangeError):
                self.import_payload(name)

    def test_rejects_symlink(self):
        outside = self.base / "outside"
        outside.mkdir()
        try:
            (self.root / "references").symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest("Symlink creation requires privileges on this host")
        with self.assertRaisesRegex(ExchangeError, "Symlink"):
            self.import_payload()
        self.assertEqual(list(outside.iterdir()), [])

    def test_rejects_non_step_content(self):
        self.payload.write_bytes(b"<html>login screen</html>")
        self.update_receipt()
        with self.assertRaisesRegex(ExchangeError, "envelope"):
            self.import_payload()

    def test_manifest_failure_restores_existing_file(self):
        self.import_payload()
        self.payload.write_bytes(STEP.replace(b"DATA;", b"DATA; /* newer */"))
        self.update_receipt()
        with patch("vault_cad_tools.project.atomic_json", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.import_payload()
        self.assertEqual((self.root / "references/part.step").read_bytes(), STEP)
        self.assertEqual(self.project().status()["references"][0]["state"], "clean")
        self.assertFalse((self.root / ".vault-cad-operation.lock").exists())

    def test_manifest_failure_removes_new_import(self):
        with patch("vault_cad_tools.project.atomic_json", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.import_payload()
        self.assertFalse((self.root / "references/part.step").exists())
        self.assertEqual(self.project().status()["references"], [])

    def test_operation_lock_refuses_concurrent_import(self):
        (self.root / ".vault-cad-operation.lock").write_text("another process")
        with self.assertRaisesRegex(ExchangeError, "Another operation"):
            self.import_payload()

    def test_missing_reference_status(self):
        self.import_payload()
        (self.root / "references/part.step").unlink()
        self.assertEqual(self.project().status()["references"][0]["state"], "missing")

    def test_windows_bom_receipt(self):
        self.receipt_path.write_text(json.dumps(self.receipt), encoding="utf-8-sig")
        self.assertTrue(self.import_payload()["changed"])

    def test_reserved_windows_names(self):
        for name in ("references/NUL.step", "references/COM1.step", "references/file. ", "references/a\\b.step"):
            with self.subTest(name=name), self.assertRaises(ExchangeError):
                portable_path(name)


class PublicationTests(ProjectFixture):
    def prepare(self):
        return prepare_publication(self.project(), "step/new-part.step", "$/Projects/Incoming", self.base / "exchange")

    def test_only_packages_committed_bytes(self):
        self.committed_part()
        result = self.prepare()
        request = verify_request(result["directory"])
        self.assertEqual(request["provenance"]["git_commit"], self.git("rev-parse", "HEAD"))
        self.assertEqual(request["destination"]["if_exists"], "fail")
        self.assertEqual(request["operation"], "add_step_file")
        self.assertEqual(self.project().lock["publications"], [])
        self.assertEqual(result["status"], "prepared_only")

    def test_uncommitted_modification_is_refused(self):
        part = self.committed_part()
        part.write_bytes(STEP + b"changed")
        with self.assertRaisesRegex(ExchangeError, "Commit this STEP"):
            self.prepare()
        self.assertFalse((self.base / "exchange").exists())

    def test_corrupt_payload_is_refused(self):
        self.committed_part()
        result = self.prepare()
        payload = Path(result["directory"]) / "payload.step"
        payload.write_bytes(STEP + b"tampered")
        with self.assertRaisesRegex(ExchangeError, "does not match"):
            verify_request(result["directory"])

    def test_payload_escape_is_refused(self):
        self.committed_part()
        result = self.prepare()
        path = Path(result["directory"]) / "request.json"
        request = json.loads(path.read_text())
        request["payload"]["path"] = "../payload.step"
        atomic_json(path, request)
        with self.assertRaises(ExchangeError):
            verify_request(result["directory"])

    def test_reference_cannot_be_published(self):
        self.import_payload()
        with self.assertRaisesRegex(ExchangeError, "authored"):
            prepare_publication(self.project(), "references/part.step", "$/Projects", self.base / "exchange")

    def test_unsafe_destination_is_refused(self):
        self.committed_part()
        with self.assertRaises(ExchangeError):
            prepare_publication(self.project(), "step/new-part.step", "$/../other", self.base / "exchange")


class RestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self, code, body=b"", **headers):
                self.send_response(code)
                self.send_header("Content-Length", str(len(body)))
                for key, value in headers.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                cls.requests.append(("GET", self.path, self.headers.get("Authorization")))
                if self.path == "/api/redirect":
                    self.respond(302, Location="/api/target")
                elif self.path == "/api/file":
                    self.respond(200, STEP)
                elif self.path == "/api/fail":
                    self.respond(401, b"do-not-echo-this-secret")
                else:
                    self.respond(200, b'{"results":[],"pagination":{"cursorState":"next"}}')

            def do_POST(self):
                cls.requests.append(("POST", self.path, self.headers.get("Authorization")))
                self.rfile.read(int(self.headers["Content-Length"]))
                self.respond(200, b'{"id":"session-1","accessToken":"test-token"}')

            def do_DELETE(self):
                cls.requests.append(("DELETE", self.path, self.headers.get("Authorization")))
                self.respond(204)

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}/api/"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.requests.clear()

    def test_query_encoding_and_pagination_preserved(self):
        client = VaultClient(self.base_url, "test-token")
        result = client.json("search", query={"q": "Free Standing & Enclosure", "option[latestOnly]": "true"})
        self.assertEqual(result["pagination"]["cursorState"], "next")
        self.assertIn("q=Free+Standing+%26+Enclosure", self.requests[0][1])
        self.assertEqual(self.requests[0][2], "Bearer test-token")

    def test_session_cleanup_even_on_operation_error(self):
        client = VaultClient(self.base_url)
        with self.assertRaisesRegex(RuntimeError, "operation failed"):
            with session(client, "Vault", "username", "password"):
                self.assertEqual(client.token, "test-token")
                raise RuntimeError("operation failed")
        self.assertEqual(self.requests[-1][:2], ("DELETE", "/api/sessions/session-1"))
        self.assertIsNone(client.token)

    def test_external_token_session_is_not_deleted(self):
        client = VaultClient(self.base_url, "external-token")
        with session(client, "Vault"):
            client.json("data")
        self.assertEqual([item[0] for item in self.requests], ["GET"])

    def test_redirect_does_not_forward_credentials(self):
        client = VaultClient(self.base_url, "test-token")
        with self.assertRaisesRegex(ExchangeError, "HTTP 302"):
            client.json("redirect")
        self.assertEqual(len(self.requests), 1)

    def test_error_body_is_not_printed(self):
        with self.assertRaises(ExchangeError) as error:
            VaultClient(self.base_url).json("fail")
        self.assertNotIn("secret", str(error.exception))

    def test_download_and_overwrite_protection(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "part.step"
            client = VaultClient(self.base_url)
            client.download("file", target)
            self.assertEqual(target.read_bytes(), STEP)
            with self.assertRaisesRegex(ExchangeError, "already exists"):
                client.download("file", target)

    def test_failed_download_does_not_leave_destination(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "part.step"
            with self.assertRaises(ExchangeError):
                VaultClient(self.base_url).download("fail", target)
            self.assertEqual(list(Path(temp).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
