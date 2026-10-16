"""Database builder tests using synthetic sources shaped like the QUL exports, not Quran assets."""

import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "build_quran_db.py"
SURAHS = 114
LINES_PER_PAGE = 15
WORDS_PER_LINE = 4


def ayah_counts():
    # Any 114 counts summing to 6,236 exercise the same checks as the real ones.
    return [55 if number <= 80 else 54 for number in range(1, SURAHS + 1)]


class SyntheticSources:
    """Writes metadata JSON, a words SQLite export, and a pages SQLite export."""

    def __init__(self, root: Path):
        self.root = root
        self.counts = ayah_counts()
        self.bismillah = {n for n in range(1, SURAHS + 1) if n not in (1, 9)}

    def word_rows(self):
        rows, index = [], 0
        for surah, count in enumerate(self.counts, start=1):
            for ayah in range(1, count + 1):
                for position, text in enumerate(("اختبار", "نص", "٣"), start=1):
                    index += 1
                    rows.append((index, f"{surah}:{ayah}:{position}", surah, ayah, text))
        return rows

    def line_rows(self, words):
        lines = []
        by_surah = {}
        for index, _, surah, _, _ in words:
            by_surah.setdefault(surah, []).append(index)
        for surah in range(1, SURAHS + 1):
            lines.append(["surah_name", 1, None, None, surah])
            if surah in self.bismillah:
                lines.append(["basmallah", 1, None, None, None])
            indices = by_surah[surah]
            for start in range(0, len(indices), WORDS_PER_LINE):
                chunk = indices[start:start + WORDS_PER_LINE]
                lines.append(["ayah", 0, chunk[0], chunk[-1], None])
        rows = []
        for number, (kind, centered, first, last, surah) in enumerate(lines):
            page, line = divmod(number, LINES_PER_PAGE)
            rows.append((page + 1, line + 1, kind, centered,
                         "" if first is None else first, "" if last is None else last,
                         "" if surah is None else surah))
        return rows

    def write(self, words=None, lines=None):
        metadata = self.root / "metadata"
        layout = self.root / "layout"
        metadata.mkdir(exist_ok=True)
        layout.mkdir(exist_ok=True)
        surahs = {str(n): {"id": n, "name": f"Name {n}", "name_simple": f"Simple {n}",
                           "name_arabic": "سورة", "revelation_place": "makkah",
                           "verses_count": count, "bismillah_pre": n in self.bismillah}
                  for n, count in enumerate(self.counts, start=1)}
        (metadata / "surahs.json").write_text(json.dumps(surahs, ensure_ascii=False),
                                              encoding="utf-8")
        ayahs, identifier = {}, 0
        for surah, count in enumerate(self.counts, start=1):
            for ayah in range(1, count + 1):
                identifier += 1
                ayahs[str(identifier)] = {"id": identifier, "surah_number": surah,
                                          "ayah_number": ayah, "verse_key": f"{surah}:{ayah}"}
        (metadata / "ayahs.json").write_text(json.dumps(ayahs), encoding="utf-8")
        ordered = [(r["surah_number"], r["ayah_number"]) for r in ayahs.values()]
        for name, field, count in (("juz", "juz_number", 30), ("hizb", "hizb_number", 60), ("rub", "rub_number", 240)):
            size = -(-len(ordered) // count)
            division = {}
            for number in range(1, count + 1):
                mapping = {}
                for surah, ayah in ordered[(number - 1) * size:number * size]:
                    first = mapping.get(str(surah), f"{ayah}-{ayah}").split("-")[0]
                    mapping[str(surah)] = f"{first}-{ayah}"
                division[str(number)] = {field: number, "verse_mapping": mapping}
            (metadata / f"{name}.json").write_text(json.dumps(division), encoding="utf-8")

        words = self.word_rows() if words is None else words
        lines = self.line_rows(words) if lines is None else lines
        for name in ("words.db", "pages.db"):
            (layout / name).unlink(missing_ok=True)
        with sqlite3.connect(layout / "words.db") as connection:
            connection.execute("CREATE TABLE words (word_index INTEGER, word_key TEXT, "
                               "surah INTEGER, ayah INTEGER, text TEXT)")
            connection.executemany("INSERT INTO words VALUES (?, ?, ?, ?, ?)", words)
        connection.close()
        with sqlite3.connect(layout / "pages.db") as connection:
            connection.execute("CREATE TABLE pages (page_number INTEGER, line_number INTEGER, "
                               "line_type TEXT, is_centered INTEGER, first_word_id INTEGER, "
                               "last_word_id INTEGER, surah_number INTEGER)")
            connection.executemany("INSERT INTO pages VALUES (?, ?, ?, ?, ?, ?, ?)", lines)
        connection.close()
        (layout / "font.ttf").write_bytes(b"synthetic font")
        page_count = max(row[0] for row in lines)

        def entry(path):
            data = (self.root / path).read_bytes()
            return {"url": "https://example.invalid", "path": path,
                    "sha256": hashlib.sha256(data).hexdigest()}

        manifest = {
            "manifest_version": 1,
            "metadata": {"surahs": entry("metadata/surahs.json"),
                         "ayahs": entry("metadata/ayahs.json"),
                         "juz": entry("metadata/juz.json"),
                         "hizb": entry("metadata/hizb.json"),
                         "rub": entry("metadata/rub.json")},
            "layouts": {
                "sample": {"name": "Synthetic", "page_count": page_count,
                           "lines_per_page": LINES_PER_PAGE, "verified": True,
                           "verification_note": "synthetic",
                           "words": entry("layout/words.db"), "layout": entry("layout/pages.db"),
                           "font": entry("layout/font.ttf")},
            },
        }
        path = self.root / "manifest.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        return path


class BuildQuranDatabaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.sources = SyntheticSources(self.root)
        self.output = self.root / "out" / "quran.sqlite"

    def run_tool(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                              capture_output=True, text=True, check=False)

    def build(self, manifest, *extra):
        return self.run_tool("build", "--manifest", manifest, "--raw", self.root,
                             "--output", self.output, "--layout", "sample", *extra)

    def test_builds_deterministic_verified_database(self):
        manifest = self.sources.write()
        first = self.build(manifest)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_bytes = self.output.read_bytes()
        second = self.build(manifest)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first_bytes, self.output.read_bytes())

        verified = self.run_tool("verify", self.output)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        with sqlite3.connect(self.output) as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM ayahs").fetchone()[0], 6236)
            text = connection.execute("SELECT text FROM words WHERE layout = 'sample' "
                                      "AND surah = 2 AND ayah = 5 AND position = 1").fetchone()[0]
            self.assertEqual(text, "اختبار")
            self.assertEqual(connection.execute("SELECT juz, hizb, rub FROM ayahs WHERE surah = 114 "
                                                "AND ayah = 54").fetchone(), (30, 60, 240))
            pages = connection.execute("SELECT COUNT(*) FROM ayah_pages WHERE layout = 'sample' "
                                       "GROUP BY surah, ayah HAVING COUNT(*) > 1").fetchall()
            self.assertTrue(pages, "fixture should include ayahs spanning two pages")
        connection.close()
        self.assertEqual(list(self.output.parent.iterdir()), [self.output])

    def test_missing_or_changed_sources_are_refused(self):
        manifest = self.sources.write()
        (self.root / "layout" / "font.ttf").write_bytes(b"changed")
        result = self.build(manifest)
        self.assertEqual(result.returncode, 1)
        self.assertIn("sha256 mismatch", result.stderr)
        data = json.loads(manifest.read_text())
        data["metadata"]["ayahs"]["path"] = None
        manifest.write_text(json.dumps(data))
        result = self.build(manifest)
        self.assertIn("ayahs: no path recorded", result.stderr)
        self.assertFalse(self.output.exists())

    def test_unverified_layout_requires_explicit_flag(self):
        manifest = self.sources.write()
        data = json.loads(manifest.read_text())
        data["layouts"]["sample"]["verified"] = False
        manifest.write_text(json.dumps(data))
        refused = self.build(manifest)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("not verified", refused.stderr)
        allowed = self.build(manifest, "--allow-unverified")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        with sqlite3.connect(self.output) as connection:
            self.assertEqual(connection.execute("SELECT verified FROM layouts").fetchone()[0], 0)
        connection.close()

    def test_gap_in_line_coverage_fails_without_output(self):
        words = self.sources.word_rows()
        lines = self.sources.line_rows(words)
        index = next(i for i, row in enumerate(lines) if row[2] == "ayah" and row[0] > 3)
        page, line, kind, centered, first, last, surah = lines[index]
        lines[index] = (page, line, kind, centered, first + 1, last, surah)
        result = self.build(self.sources.write(words=words, lines=lines))
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"starts at word {first + 1}, expected {first}", result.stderr)
        self.assertFalse(self.output.exists())

    def test_word_key_mismatch_and_missing_ayah_are_reported(self):
        words = self.sources.word_rows()
        index, _, surah, ayah, text = words[10]
        words[10] = (index, f"{surah}:{ayah + 1}:1", surah, ayah, text)
        result = self.build(self.sources.write(words=words))
        self.assertIn("disagrees with", result.stderr)

        words = [row for row in self.sources.word_rows() if (row[2], row[3]) != (114, 54)]
        result = self.build(self.sources.write(words=words))
        self.assertEqual(result.returncode, 1)
        self.assertIn("1 ayahs have no words, first 114:54", result.stderr)

    def test_verify_detects_tampering(self):
        self.assertEqual(self.build(self.sources.write()).returncode, 0)
        with sqlite3.connect(self.output) as connection:
            connection.execute("UPDATE words SET text = 'x' WHERE word = 1")
        connection.close()
        result = self.run_tool("verify", self.output)
        self.assertEqual(result.returncode, 1)
        self.assertIn("content_sha256 does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
