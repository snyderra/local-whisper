# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""Contract checks for the standalone-app build/sign/release pipeline."""

import importlib.util
import plistlib
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def test_entitlements_are_minimal_and_notarizable():
    payload = plistlib.loads((ROOT / "packaging" / "entitlements.plist").read_bytes())

    assert payload["com.apple.security.device.audio-input"] is True
    assert payload["com.apple.security.automation.apple-events"] is True
    # Notarization rejects get-task-allow; CPython/MLX need no JIT entitlement.
    assert "com.apple.security.get-task-allow" not in payload
    assert "com.apple.security.cs.allow-jit" not in payload


def test_sign_script_uses_hardened_runtime_inside_out():
    sign = _read("scripts/sign_bundle.sh")

    assert "--options runtime" in sign
    assert "packaging/entitlements.plist" in sign
    assert 'SIGN_IDENTITY="${SIGN_IDENTITY:--}"' in sign
    # --deep is deprecated for signing (wrong order); verification only.
    for line in sign.splitlines():
        stripped = line.strip()
        if "--deep" in stripped and not stripped.startswith("#"):
            assert "--verify" in stripped, line


def test_notarize_script_is_credential_gated():
    notarize = _read("scripts/notarize_app.sh")

    assert "notarytool submit" in notarize
    assert "--wait" in notarize
    assert "notarytool log" in notarize
    assert "stapler staple" in notarize
    assert "notarization skipped: no credentials" in notarize
    assert "exit 0" in notarize


def test_dmg_script_marks_adhoc_artifacts():
    dmg = _read("scripts/make_dmg.sh")

    assert "hdiutil create" in dmg
    assert "ULMO" in dmg
    assert '-adhoc"' in dmg or 'SUFFIX="-adhoc"' in dmg


def test_bundle_build_pins_identity_and_runtime_flags():
    build = _read("scripts/build_bundle.sh")

    assert "LWBundledRuntime" in build
    assert "NSMicrophoneUsageDescription" in build
    assert "com.local-whisper" in build
    assert "UV_PYTHON_PREFERENCE=only-managed" in build
    # Sparkle keys are injected only when configured (credential-gated).
    assert "SPARKLE_ED_PUBLIC_KEY" in build
    assert "SUFeedURL" in build


def test_release_workflow_triggers_and_uploads():
    workflow = _read(".github/workflows/release-app.yml")

    assert "types: [published]" in workflow
    assert "workflow_dispatch:" in workflow
    assert "runs-on: macos-15" in workflow
    assert "contents: write" in workflow
    assert "does not match tag" in workflow  # pyproject/tag guard
    assert "gh release upload" in workflow
    assert "SIGN_IDENTITY=-" in workflow  # ad-hoc fallback without secrets


def test_docs_pages_workflow_publishes_appcast():
    workflow = _read(".github/workflows/docs-pages.yml")

    assert '- "appcast/**"' in workflow
    assert "cp ../appcast/appcast.xml ../_site/appcast.xml" in workflow


def _load_make_appcast():
    spec = importlib.util.spec_from_file_location(
        "make_appcast", ROOT / "scripts" / "make_appcast.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_make_appcast_prepends_valid_item(tmp_path):
    make_appcast = _load_make_appcast()
    appcast = tmp_path / "appcast.xml"
    appcast.write_text(_read("appcast/appcast.xml"), encoding="utf-8")

    make_appcast.prepend_item(
        appcast, "1.7.0",
        "https://github.com/gabrimatic/local-whisper/releases/download/v1.7.0/LocalWhisper-1.7.0.dmg",
        377487360, "fakesig==",
        "https://github.com/gabrimatic/local-whisper/releases/tag/v1.7.0",
        pub_date="Wed, 02 Jul 2026 12:00:00 GMT",
    )
    make_appcast.prepend_item(
        appcast, "1.7.1",
        "https://github.com/gabrimatic/local-whisper/releases/download/v1.7.1/LocalWhisper-1.7.1.dmg",
        377487361, "fakesig2==",
        "https://github.com/gabrimatic/local-whisper/releases/tag/v1.7.1",
        pub_date="Thu, 03 Jul 2026 12:00:00 GMT",
    )

    tree = ET.parse(appcast)  # valid XML
    ns = {"sparkle": make_appcast.SPARKLE_NS}
    items = tree.getroot().find("channel").findall("item")
    assert len(items) == 2
    # Newest first
    assert items[0].findtext("sparkle:shortVersionString", namespaces=ns) == "1.7.1"
    enclosure = items[0].find("enclosure")
    assert enclosure.get("url").endswith("/v1.7.1/LocalWhisper-1.7.1.dmg")
    assert enclosure.get(f"{{{make_appcast.SPARKLE_NS}}}edSignature") == "fakesig2=="
    assert items[0].findtext("sparkle:minimumSystemVersion", namespaces=ns) == "26.0"


def test_make_appcast_rejects_duplicate_version(tmp_path):
    make_appcast = _load_make_appcast()
    appcast = tmp_path / "appcast.xml"
    appcast.write_text(_read("appcast/appcast.xml"), encoding="utf-8")

    args = (
        appcast, "1.7.0", "https://example.com/a.dmg", 1, "sig==",
        "https://example.com/notes",
    )
    make_appcast.prepend_item(*args)
    with pytest.raises(SystemExit):
        make_appcast.prepend_item(*args)
