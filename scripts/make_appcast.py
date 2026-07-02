#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""Prepend a release item to the Sparkle appcast (appcast/appcast.xml).

Deterministic, stdlib-only, and unit-testable — unlike Sparkle's
generate_appcast, which needs the dmg files and keychain on hand.

Usage:
  make_appcast.py --version 1.7.0 \
      --dmg-url https://github.com/gabrimatic/local-whisper/releases/download/v1.7.0/LocalWhisper-1.7.0.dmg \
      --length 377487360 \
      --ed-signature <base64 EdDSA sig from Sparkle sign_update> \
      --notes-url https://github.com/gabrimatic/local-whisper/releases/tag/v1.7.0 \
      [--appcast appcast/appcast.xml] [--pub-date "Wed, 02 Jul 2026 12:00:00 +0000"]
"""

import argparse
import email.utils
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MINIMUM_SYSTEM_VERSION = "26.0"


def prepend_item(
    appcast_path: Path,
    version: str,
    dmg_url: str,
    length: int,
    ed_signature: str,
    notes_url: str,
    pub_date: "str | None" = None,
) -> None:
    ET.register_namespace("sparkle", SPARKLE_NS)
    tree = ET.parse(appcast_path)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit(f"no <channel> in {appcast_path}")

    for existing in channel.findall("item"):
        existing_version = existing.findtext(f"{{{SPARKLE_NS}}}shortVersionString")
        if existing_version == version:
            raise SystemExit(f"appcast already has an item for {version}")

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Local Whisper {version}"
    ET.SubElement(item, "pubDate").text = pub_date or email.utils.formatdate(usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = MINIMUM_SYSTEM_VERSION
    ET.SubElement(item, f"{{{SPARKLE_NS}}}releaseNotesLink").text = notes_url
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": dmg_url,
            "length": str(length),
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}edSignature": ed_signature,
        },
    )

    # Newest first: insert before any existing items.
    first_item_idx = next(
        (i for i, child in enumerate(list(channel)) if child.tag == "item"),
        len(list(channel)),
    )
    channel.insert(first_item_idx, item)
    ET.indent(tree, space="  ")
    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)


def main(argv: "list[str]") -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--dmg-url", required=True)
    parser.add_argument("--length", type=int, required=True)
    parser.add_argument("--ed-signature", required=True)
    parser.add_argument("--notes-url", required=True)
    parser.add_argument("--pub-date", default=None)
    parser.add_argument(
        "--appcast",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "appcast" / "appcast.xml",
    )
    args = parser.parse_args(argv)
    prepend_item(
        args.appcast,
        args.version,
        args.dmg_url,
        args.length,
        args.ed_signature,
        args.notes_url,
        args.pub_date,
    )
    print(f"appcast updated: {args.appcast}")


if __name__ == "__main__":
    main(sys.argv[1:])
