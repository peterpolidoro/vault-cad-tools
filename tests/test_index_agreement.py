"""The index is derived in two places, and they have to agree.

The import here writes `vault-lock.json` from the directories it has just
written. The sibling `mechanical-cad` repository derives the same index from
the directories by itself (`python3 -m mechanical_cad lock PROJECT`), and its
validator refuses a project whose file differs from that. Each repository
tested its own half; this compares the two on what the import writes.

It needs the `mechanical-cad` checkout: where the environment's
MECHANICAL_CAD says, or beside this repository, or the directory the tests
are run from. Without one the tests are skipped. Under `guix shell --pure`
the variable is handed in with `-E '^MECHANICAL_CAD$'`.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from exporter_package import step_record, write_package  # noqa: E402
from test_package_import import ROOT, assembly, child, files, matrix, part, step  # noqa: E402
from vault_cad_tools.package_import import import_package  # noqa: E402

HERE = Path(__file__).resolve().parents[1]
PLACES = [Path(p) for p in (os.environ.get("MECHANICAL_CAD"), HERE.parent / "mechanical-cad", Path.cwd()) if p]
CHECKOUT = next((p for p in PLACES if (p / "mechanical_cad" / "layout.py").is_file()), PLACES[0])
THERE = (CHECKOUT / "mechanical_cad" / "layout.py").is_file()


@unittest.skipUnless(THERE, f"no mechanical-cad checkout at {CHECKOUT}; say where it is with MECHANICAL_CAD")
class IndexAgreementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.dest = self.base / "project"
        self.count = 0

    def package(self, held):
        self.count += 1
        return write_package(self.base / f"package-{self.count}", list(held.values()), ROOT)

    def derived_there(self):
        """The index as mechanical-cad derives it from the directories, whatever else it has to say of them."""
        env = dict(os.environ, PYTHONPATH=str(CHECKOUT), PYTHONDONTWRITEBYTECODE="1")
        done = subprocess.run([sys.executable, "-B", "-m", "mechanical_cad", "lock", str(self.dest)],
                              env=env, capture_output=True, text=True)
        self.assertTrue(done.stdout.lstrip().startswith("{"), done.stdout + done.stderr)
        return json.loads(done.stdout)

    def written_here(self):
        return json.loads((self.dest / "vault-lock.json").read_text(encoding="utf-8"))

    def test_a_first_import_writes_the_index_mechanical_cad_derives(self):
        import_package(self.package(files()), self.dest, "run-1")
        written = self.written_here()
        self.assertEqual([c["key"] for c in written["components"]], ["a", "b", "root", "sub"])
        self.assertEqual(written, self.derived_there())

    def test_they_agree_after_a_new_version_and_a_new_file(self):
        import_package(self.package(files()), self.dest, "run-1")
        held = files()
        held["b"] = part("B", "200", version="2", folder="PROJECT", data=step("B", "2"), number=2)
        held["c"] = part("C", "400")
        held["root"]["assembly"]["children"].append(child("C:1", "part", "400", matrix(0, 0, 7)))
        result = import_package(self.package(held), self.dest, "run-2")
        self.assertEqual((result["updated"], result["new"]), (["b"], ["c"]))
        written = self.written_here()
        self.assertEqual(next(c for c in written["components"] if c["key"] == "b")["version_id"], "2002")
        self.assertEqual(written, self.derived_there())

    def test_they_agree_on_one_file_in_two_model_states(self):
        held = files()
        other = copy.deepcopy(held["b"])
        other["source"]["model_state"] = "Flat Pattern"
        other["step"] = step("B", "flat")
        other["source"]["step"] = step_record(other["step"])
        held["b-flat"] = other
        flat = child("B:2", "part", "200", matrix(0, 9))
        flat["model_state"] = "Flat Pattern"
        held["root"]["assembly"]["children"].append(flat)
        import_package(self.package(held), self.dest, "run-1")
        written = self.written_here()
        states = {c["key"]: c["model_state"] for c in written["components"] if c["master_id"] == "200"}
        self.assertEqual(states, {"b": "[Primary]", "b@flat-pattern": "Flat Pattern"})
        self.assertEqual(written, self.derived_there())


if __name__ == "__main__":
    unittest.main()
