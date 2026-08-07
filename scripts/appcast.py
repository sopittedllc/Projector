#!/usr/bin/env python3
"""Add a release to Projector's Sparkle appcast.

The appcast is the list of published builds the app reads on launch. It lives at
one unchanging URL on the repository's main branch, because the feed has to stay
put while the builds it lists do not:

    https://raw.githubusercontent.com/sopittedllc/Projector/main/appcast.xml

Called by scripts/build-release.sh once a DMG has been notarized, uploaded to a
GitHub release, and signed with the EdDSA key. Kept out of that script because
editing XML from bash means sed against a structured format, which works right
up until a release note contains an angle bracket.

Usage:
    appcast.py --appcast appcast.xml \\
               --version 2026.08.09 --build 20260809.1210 \\
               --url https://github.com/.../Projector-2026.08.09.dmg \\
               --length 11123842 --signature <base64> \\
               --min-system 12.0 --notes "..."

An entry whose short version matches one already listed replaces it, so a
same-day rebuild - which reuses the tag and clobbers the release asset - updates
its entry rather than adding a second one pointing at the same URL.
"""

import argparse
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

CHANNEL_TITLE = "Projector"
CHANNEL_DESCRIPTION = "Updates for Projector"
CHANNEL_LINK = "https://raw.githubusercontent.com/sopittedllc/Projector/main/appcast.xml"


def sparkle(tag):
    """Return a namespaced tag name in Sparkle's namespace."""
    return f"{{{SPARKLE_NS}}}{tag}"


def load_channel(path):
    """Return the <channel> element of the appcast, creating the file's shape if absent."""
    if os.path.exists(path) and os.path.getsize(path) > 0:
        tree = ET.parse(path)
        root = tree.getroot()
        channel = root.find("channel")
        if channel is None:
            raise SystemExit(f"{path}: no <channel> element - refusing to guess at its shape")
        return root, channel

    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = CHANNEL_TITLE
    ET.SubElement(channel, "link").text = CHANNEL_LINK
    ET.SubElement(channel, "description").text = CHANNEL_DESCRIPTION
    ET.SubElement(channel, "language").text = "en"
    return root, channel


def remove_existing(channel, short_version):
    """Drop any item already describing this short version."""
    for item in channel.findall("item"):
        existing = item.find(sparkle("shortVersionString"))
        if existing is not None and existing.text == short_version:
            channel.remove(item)


def build_item(args):
    """Build the <item> element for this release."""
    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.version
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))

    # Sparkle compares this one. It is CFBundleVersion, which build-release.sh
    # stamps as a date and time, so it increases with every build.
    ET.SubElement(item, sparkle("version")).text = args.build

    # What the user is shown. Matches the release tag and the DMG's name.
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version

    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.min_system

    if args.link:
        ET.SubElement(item, "link").text = args.link
    if args.notes:
        ET.SubElement(item, "description").text = args.notes

    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(args.length),
        "type": "application/octet-stream",
        sparkle("edSignature"): args.signature,
    })
    return item


def first_item_index(channel):
    """Index of the first existing <item>, or the end of the channel."""
    for index, child in enumerate(channel):
        if child.tag == "item":
            return index
    return len(channel)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True, help="Path to appcast.xml")
    parser.add_argument("--version", required=True, help="Short version, e.g. 2026.08.09")
    parser.add_argument("--build", required=True, help="CFBundleVersion, e.g. 20260809.1210")
    parser.add_argument("--url", required=True, help="Download URL of the DMG")
    parser.add_argument("--length", required=True, type=int, help="DMG size in bytes")
    parser.add_argument("--signature", required=True, help="EdDSA signature from sign_update")
    parser.add_argument("--min-system", default="12.0", help="Minimum macOS version")
    parser.add_argument("--link", default="", help="Release page URL")
    parser.add_argument("--notes", default="", help="Release notes shown in the update dialog")
    args = parser.parse_args()

    if not args.signature.strip():
        raise SystemExit("Refusing to write an item with an empty signature: "
                         "Sparkle would reject the update it describes.")

    root, channel = load_channel(args.appcast)
    remove_existing(channel, args.version)
    channel.insert(first_item_index(channel), build_item(args))

    ET.indent(root, space="  ")
    ET.ElementTree(root).write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast: {args.version} ({args.build}) -> {args.appcast}", file=sys.stderr)


if __name__ == "__main__":
    main()
