#!/usr/bin/env python3
"""Add a release to Surabar's Sparkle appcast (Python standard library).

Reads the previous appcast (if any), replaces or adds the item for this build, and writes the
feed with the newest build first. Sparkle compares sparkle:version, which is the app's
CFBundleVersion (CURRENT_PROJECT_VERSION), so every release needs a higher build number.
The release notes are Markdown, shown by Sparkle's update window. tools/release.sh calls this
with the signature from Sparkle's sign_update.
"""

import argparse
from email.utils import format_datetime
from datetime import datetime, timezone
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def tag(name: str) -> str:
    return f"{{{SPARKLE}}}{name}"


def new_feed() -> ET.Element:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Surabar"
    ET.SubElement(channel, "link").text = "https://github.com/ahmastan/surabar"
    ET.SubElement(channel, "description").text = "Updates for Surabar, the macOS menu bar Quran reader."
    ET.SubElement(channel, "language").text = "en"
    return rss


def make_item(*, version: str, build: int, url: str, length: int, signature: str, notes: str,
              minimum_system: str, published: datetime) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(published)
    ET.SubElement(item, tag("version")).text = str(build)
    ET.SubElement(item, tag("shortVersionString")).text = version
    ET.SubElement(item, tag("minimumSystemVersion")).text = minimum_system
    ET.SubElement(item, "description", {tag("format"): "markdown"}).text = notes.strip() + "\n"
    ET.SubElement(item, "enclosure", {
        "url": url,
        "length": str(length),
        "type": "application/octet-stream",
        tag("edSignature"): signature,
    })
    return item


def build_number(item: ET.Element) -> int:
    value = item.findtext(tag("version"))
    if value is None or not value.strip().isdigit():
        raise ValueError("an appcast item has no numeric sparkle:version")
    return int(value)


def add_release(existing: str | None, item: ET.Element) -> str:
    """Returns the feed with `item` added; an item with the same build number is replaced."""
    rss = ET.fromstring(existing) if existing else new_feed()
    channel = rss.find("channel")
    if channel is None:
        raise ValueError("the appcast has no channel")
    build = build_number(item)
    items = [old for old in channel.findall("item") if build_number(old) != build] + [item]
    for old in channel.findall("item"):
        channel.remove(old)
    for each in sorted(items, key=build_number, reverse=True):
        channel.append(each)
    ET.indent(rss, space="  ")
    return '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(rss, encoding="unicode") + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--previous", type=Path, help="the published appcast, if there is one")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, e.g. 0.1.0")
    parser.add_argument("--build", type=int, required=True, help="CFBundleVersion, e.g. 1")
    parser.add_argument("--url", required=True, help="the update ZIP's download URL")
    parser.add_argument("--length", type=int, required=True)
    parser.add_argument("--signature", required=True, help="sparkle:edSignature from sign_update")
    parser.add_argument("--notes", type=Path, required=True, help="Markdown release notes")
    parser.add_argument("--minimum-system", default="14.0")
    args = parser.parse_args()
    previous = args.previous.read_text(encoding="utf-8") if args.previous and args.previous.exists() else None
    item = make_item(version=args.version, build=args.build, url=args.url, length=args.length,
                     signature=args.signature, notes=args.notes.read_text(encoding="utf-8"),
                     minimum_system=args.minimum_system, published=datetime.now(timezone.utc))
    try:
        args.output.write_text(add_release(previous, item), encoding="utf-8")
    except (ValueError, ET.ParseError) as error:
        print(f"appcast: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
