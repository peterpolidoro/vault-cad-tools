"""What the import command shares, and the refusal of the earlier exporter's package."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from vault_cad_tools.cli import main
from vault_cad_tools.layout_import import _Keys, data_sha256, slug
from vault_cad_tools.project import ExchangeError


def step(name):
    return (f"ISO-10303-21;\r\nHEADER;\r\nFILE_NAME('{name}','2026-01-01T00:00:00',('someone'),(''),'p','o','');\r\n"
            f"ENDSEC;\r\nDATA;\r\n#1=PRODUCT('{name}');\r\nENDSEC;\r\nEND-ISO-10303-21;\r\n").encode()


class SharedHelpersTests(unittest.TestCase):
    def test_helpers(self):
        self.assertEqual(slug("MCMASTER 5537T293_T-Slotted Framing"), "mcmaster-5537t293-t-slotted-framing")
        self.assertEqual(slug("  2.5in  "), "2-5in")
        data = step("x")
        self.assertEqual(data_sha256(data), hashlib.sha256(data[data.index(b"DATA;"):]).hexdigest())
        with self.assertRaises(ExchangeError):
            data_sha256(b"no sections here")

    def test_keys_are_readable_and_unique(self):
        keys = _Keys()
        self.assertEqual(keys.assign("Base Plate", 11, None, ("a", 11)), "base-plate")
        self.assertEqual(keys.assign("Base Plate", 11, None, ("a", 11)), "base-plate")          # the same file again
        self.assertEqual(keys.assign("Base Plate", 12, None, ("b", 12)), "base-plate-12")       # another file of that name
        self.assertEqual(keys.assign("Bracket", 13, "Machined", ("c", 13, "Machined")), "bracket@machined")    # a model state

    def test_the_earlier_package_is_no_longer_read(self):
        with tempfile.TemporaryDirectory() as temp:
            package, dest = Path(temp) / "package", Path(temp) / "converted"
            (package / "assets").mkdir(parents=True)
            for name in ("native-snapshot.json", "scene.json", "export-receipt.json"):
                (package / name).write_text("{}", encoding="utf-8")
            self.assertEqual(main(["import-snapshot", str(package), "--into", str(dest), "--run", "run-1"]), 2)
            self.assertFalse(dest.exists())


if __name__ == "__main__":
    unittest.main()
