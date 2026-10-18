"""Appcast tests: items are added, replaced by build number, and ordered newest first."""

from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import appcast  # noqa: E402

PUBLISHED = datetime(2026, 10, 17, 12, 0, tzinfo=timezone.utc)


def item(version: str, build: int, notes: str = "- Notes") -> ET.Element:
    return appcast.make_item(version=version, build=build, url=f"https://example.com/Surabar-{version}.zip",
                             length=1000 + build, signature=f"sig{build}=", notes=notes,
                             minimum_system="14.0", published=PUBLISHED)


def builds(feed: str) -> list[str]:
    return [i.findtext(appcast.tag("version")) for i in ET.fromstring(feed).find("channel").findall("item")]


class AppcastTests(unittest.TestCase):
    def test_new_feed_has_one_complete_item(self):
        feed = appcast.add_release(None, item("0.1.0", 1, "- First release & more"))
        channel = ET.fromstring(feed).find("channel")
        self.assertEqual(channel.findtext("title"), "Surabar")
        entry = channel.find("item")
        self.assertEqual(entry.findtext(appcast.tag("shortVersionString")), "0.1.0")
        self.assertEqual(entry.findtext(appcast.tag("minimumSystemVersion")), "14.0")
        self.assertEqual(entry.find("description").get(appcast.tag("format")), "markdown")
        self.assertEqual(entry.findtext("description"), "- First release & more\n")
        enclosure = entry.find("enclosure")
        self.assertEqual(enclosure.get("length"), "1001")
        self.assertEqual(enclosure.get(appcast.tag("edSignature")), "sig1=")
        self.assertEqual(entry.findtext("pubDate"), "Sat, 17 Oct 2026 12:00:00 +0000")

    def test_newest_build_first_and_older_items_kept(self):
        feed = appcast.add_release(None, item("0.1.0", 1))
        feed = appcast.add_release(feed, item("0.2.0", 3))
        feed = appcast.add_release(feed, item("0.1.1", 2))
        self.assertEqual(builds(feed), ["3", "2", "1"])

    def test_same_build_is_replaced(self):
        feed = appcast.add_release(None, item("0.1.0", 1, "old"))
        feed = appcast.add_release(feed, item("0.1.0", 1, "new"))
        entries = ET.fromstring(feed).find("channel").findall("item")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].findtext("description"), "new\n")

    def test_output_is_deterministic(self):
        first = appcast.add_release(appcast.add_release(None, item("0.1.0", 1)), item("0.1.1", 2))
        again = appcast.add_release(first, item("0.1.1", 2))
        self.assertEqual(first, again)
        self.assertTrue(first.startswith('<?xml version="1.0" encoding="utf-8"?>\n<rss'))
        self.assertIn('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', first)

    def test_rejects_items_without_build_numbers(self):
        broken = '<rss version="2.0"><channel><item><title>x</title></item></channel></rss>'
        with self.assertRaises(ValueError):
            appcast.add_release(broken, item("0.1.0", 1))


if __name__ == "__main__":
    unittest.main()
