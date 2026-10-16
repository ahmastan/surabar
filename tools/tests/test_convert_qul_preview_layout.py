"""Preview layout converter tests using synthetic HTML shaped like QUL's preview pages."""

from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "convert_qul_preview_layout.py"


def line(number, classes, body=""):
    return f'<div class="line-container" data-line="{number}"><div class="line {classes}" id="line-{number}">{body}</div></div>'


def words(*locations):
    return "".join(f'<span class="char char-word" data-location="{loc}"><a href="#">نص</a></span>' for loc in locations)


class ConvertPreviewLayoutTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.pages = self.root / "pages"
        self.pages.mkdir()
        self.words = self.root / "words.db"
        with sqlite3.connect(self.words) as connection:
            connection.execute("CREATE TABLE words (id INTEGER, location TEXT)")
            connection.executemany("INSERT INTO words VALUES (?, ?)",
                                   [(1, "1:1:1"), (2, "1:1:2"), (3, "1:2:1"), (4, "2:1:1"), (5, "2:1:2")])
        connection.close()

    def write_page(self, number, *lines):
        (self.pages / f"p{number}.html").write_text(
            f'<html><nav>Page</nav><div id="page-{number}" class="page">{"".join(lines)}</div></html>', encoding="utf-8")

    def run_tool(self, count=2, *extra):
        return subprocess.run([sys.executable, str(SCRIPT), "--pages", str(self.pages), "--words", str(self.words),
                               "--output", str(self.root / "out.db"), "--page-count", str(count), "--name", "Test",
                               *extra], capture_output=True, text=True, check=False)

    def rows(self):
        with sqlite3.connect(self.root / "out.db") as connection:
            result = connection.execute("SELECT * FROM pages ORDER BY page_number, line_number").fetchall()
        connection.close()
        return result

    def test_converts_lines_and_drops_trailing_padding(self):
        self.write_page(1, line(1, "line--surah-name", '<span class="surah-name-v4-icon">surah001</span>'),
                        line(2, "line--center", words("1:1:1", "1:1:2")), line(3, "line--center", words("1:2:1")),
                        line(4, ""), line(5, ""))
        self.write_page(2, line(1, "line--surah-name", "surah002"), line(2, "line--center line--bismillah", "﷽"),
                        line(3, "", words("2:1:1", "2:1:2")))
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows(), [
            (1, 1, "surah_name", 0, None, None, 1),
            (1, 2, "ayah", 1, 1, 2, None),
            (1, 3, "ayah", 1, 3, 3, None),
            (2, 1, "surah_name", 0, None, None, 2),
            (2, 2, "basmallah", 1, None, None, None),
            (2, 3, "ayah", 0, 4, 5, None),
        ])

    def test_rejects_gaps_unknown_words_and_missing_pages(self):
        self.write_page(1, line(1, "", words("1:1:1")), line(2, ""), line(3, "", words("1:1:2")))
        result = self.run_tool(count=1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("empty line before the end", result.stderr)

        self.write_page(1, line(1, "", words("1:1:1", "9:9:9")))
        self.assertIn("unknown word location 9:9:9", self.run_tool(count=1).stderr)

        self.write_page(1, line(1, "", words("1:1:1", "1:2:1")))
        self.assertIn("not consecutive", self.run_tool(count=1).stderr)

        self.write_page(1, line(1, "", words("1:1:1")), line(2, "", words("1:2:1")))
        self.assertIn("starts at word 3 after word 1", self.run_tool(count=1).stderr)

        self.write_page(1, line(1, "line--surah-name", "surah001" + words("1:1:1")))
        self.assertIn("heading line contains words", self.run_tool(count=1).stderr)

        self.write_page(1, line(1, "", words("1:1:1")))
        self.write_page(2, line(1, "", words("1:2:1")))
        self.assertIn("page 2: starts at word 3 after word 1", self.run_tool(count=2).stderr)

        self.write_page(2, line(1, "", words("1:1:2")))
        self.assertIn("missing", self.run_tool(count=3).stderr)

    def test_defective_page_can_be_patched_from_another_export(self):
        self.write_page(1, line(1, "", words("1:1:1", "1:1:2", "1:2:1")), line(2, ""), line(3, "", words("2:1:1", "2:1:2")))
        patch = self.root / "patch.db"
        with sqlite3.connect(patch) as connection:
            connection.execute("CREATE TABLE pages (page_number, line_number, line_type, is_centered, "
                               "first_word_id, last_word_id, surah_number)")
            connection.executemany("INSERT INTO pages VALUES (?, ?, ?, ?, ?, ?, ?)",
                                   [(1, 1, "ayah", 0, 1, 2, ""), (1, 2, "ayah", 0, 3, 4, ""), (1, 3, "ayah", 0, 5, 5, "")])
        connection.close()
        result = self.run_tool(1, "--patch-from", str(patch), "--patch-pages", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows(), [(1, 1, "ayah", 0, 1, 2, None), (1, 2, "ayah", 0, 3, 4, None), (1, 3, "ayah", 0, 5, 5, None)])

        # A patch must cover exactly the same words as the preview page it replaces.
        self.write_page(1, line(1, "", words("1:1:1", "1:1:2", "1:2:1", "2:1:1")))
        self.assertIn("patch covers words (1, 5), preview (1, 4)",
                      self.run_tool(1, "--patch-from", str(patch), "--patch-pages", "1").stderr)


if __name__ == "__main__":
    unittest.main()
