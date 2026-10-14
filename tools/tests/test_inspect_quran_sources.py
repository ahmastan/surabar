"""CLI regression tests using synthetic temporary inputs, not Quran assets."""

import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "inspect_quran_sources.py"


class SourceInspectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def run_inspector(self, directory=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(directory or self.root)],
            capture_output=True, text=True, check=False,
        )

    def test_missing_and_empty_directories_fail_clearly(self):
        missing = self.run_inspector(self.root / "missing")
        self.assertEqual(missing.returncode, 1)
        self.assertIn("does not exist", missing.stderr)
        empty = self.run_inspector()
        self.assertEqual(empty.returncode, 1)
        self.assertIn("No source files", empty.stderr)

    def test_inspects_json_and_sqlite_without_changing_files(self):
        source = self.root / "words.json"
        source.write_text('[{"text":"اختبار","position":1}]', encoding="utf-8-sig")
        database = self.root / "layout.sqlite"
        with sqlite3.connect(database) as connection:
            connection.execute('CREATE TABLE "pages" (page_number INTEGER, line_number INTEGER)')
            connection.execute('INSERT INTO pages VALUES (1, 1)')
        before = {p.name: p.read_bytes() for p in self.root.iterdir()}

        result = self.run_inspector()
        self.assertEqual(result.returncode, 0, result.stderr)
        files = {f["path"]: f for f in json.loads(result.stdout)["files"]}
        self.assertEqual(files["words.json"]["first_entry_fields"], ["text", "position"])
        self.assertEqual(files["layout.sqlite"]["tables"], [{
            "name": "pages",
            "columns": [{"name": "page_number", "type": "INTEGER"},
                        {"name": "line_number", "type": "INTEGER"}],
        }])
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.root.iterdir()})
        for name, content in before.items():
            self.assertEqual(files[name]["sha256"], hashlib.sha256(content).hexdigest())

    def test_bad_input_is_reported_without_hiding_valid_files(self):
        (self.root / "bad.json").write_text("{")
        (self.root / "good.json").write_text('{"sample": []}')
        result = self.run_inspector()
        self.assertEqual(result.returncode, 1)
        files = {f["path"]: f for f in json.loads(result.stdout)["files"]}
        self.assertIn("error", files["bad.json"])
        self.assertEqual(files["good.json"]["sample_keys"], ["sample"])

    def test_nested_binary_hashes_are_repeatable_and_symlinks_are_skipped(self):
        folder = self.root / "fonts"
        folder.mkdir()
        binary = folder / "sample.bin"
        binary.write_bytes(b"synthetic binary\x00" * 100000)
        (self.root / "alias.bin").symlink_to(binary)
        (self.root / ".DS_Store").write_bytes(b"ignored")
        first = self.run_inspector()
        second = self.run_inspector()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, second.stdout)
        files = json.loads(first.stdout)["files"]
        self.assertEqual([f["path"] for f in files], ["fonts/sample.bin"])
        self.assertEqual(files[0]["sha256"], hashlib.sha256(binary.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
