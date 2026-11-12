#!/usr/bin/env python3
"""Validate the medo plugin manifest against the Noctalia rules we rely on.

Runs in CI and locally (`make manifest`). Stdlib only, so it works on any
Python 3.11+ runner. Exits 1 when anything is wrong, printing every problem
instead of stopping at the first.
"""

from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = ROOT / "medo"
MANIFEST = PLUGIN_DIR / "plugin.toml"
TRANSLATIONS = PLUGIN_DIR / "translations" / "en.json"

# The shell's plugin_api ceiling on the supported Noctalia release (5.4.1).
# Raising this is a conscious act: it drops compatibility with older shells.
MAX_PLUGIN_API = 43

ENTRY_KINDS = (
    "widget",
    "shortcut",
    "launcher_provider",
    "desktop_widget",
    "panel",
    "layer",
    "service",
)

SETTING_TYPES = {
    "string",
    "string_list",
    "string_map",
    "bool",
    "int",
    "double",
    "select",
    "file",
    "folder",
    "glyph",
    "color",
}

ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9_-]*$")
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")

errors: list[str] = []
warnings: list[str] = []


def error(message: str) -> None:
    errors.append(message)


def warn(message: str) -> None:
    warnings.append(message)


def load_toml(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except FileNotFoundError:
        error(f"missing manifest: {path.relative_to(ROOT)}")
    except tomllib.TOMLDecodeError as exc:
        error(f"invalid TOML in {path.relative_to(ROOT)}: {exc}")
    return {}


def load_translations() -> dict[str, str]:
    try:
        data = json.loads(TRANSLATIONS.read_text(encoding="utf-8"))
    except FileNotFoundError:
        error(f"missing translations: {TRANSLATIONS.relative_to(ROOT)}")
        return {}
    except json.JSONDecodeError as exc:
        error(f"invalid JSON in {TRANSLATIONS.relative_to(ROOT)}: {exc}")
        return {}
    if not isinstance(data, dict):
        error(f"{TRANSLATIONS.relative_to(ROOT)} must be a JSON object")
        return {}
    return data


def check_top_level(manifest: dict) -> None:
    for key in ("id", "name", "version", "plugin_api", "description"):
        if key not in manifest:
            error(f"manifest is missing required key '{key}'")

    plugin_id = manifest.get("id", "")
    if plugin_id and not ID_RE.match(plugin_id):
        error(f"id '{plugin_id}' must look like 'author/plugin' (lowercase, - and _ allowed)")

    version = str(manifest.get("version", ""))
    if version and not VERSION_RE.match(version):
        error(f"version '{version}' must be MAJOR.MINOR.PATCH")

    api = manifest.get("plugin_api")
    if not isinstance(api, int):
        error("plugin_api must be an integer")
    elif api < 3:
        error(f"plugin_api {api} is below the minimum supported level (3)")
    elif api > MAX_PLUGIN_API:
        error(
            f"plugin_api {api} exceeds the shell ceiling ({MAX_PLUGIN_API}); "
            "bump MAX_PLUGIN_API in tools/check_manifest.py only with the shell update"
        )


def check_settings(scope: str, settings: object, translations: dict[str, str]) -> None:
    if not isinstance(settings, list):
        error(f"{scope}: 'setting' must be an array of tables")
        return
    seen: set[str] = set()
    for index, setting in enumerate(settings):
        where = f"{scope}.setting[{index}]"
        if not isinstance(setting, dict):
            error(f"{where}: must be a table")
            continue
        key = setting.get("key")
        if not isinstance(key, str) or not key:
            error(f"{where}: missing 'key'")
            continue
        if key in seen:
            error(f"{where}: duplicate setting key '{key}'")
        seen.add(key)

        kind = setting.get("type")
        if kind not in SETTING_TYPES:
            error(f"{where} ('{key}'): unknown type '{kind}', expected one of {sorted(SETTING_TYPES)}")

        for field, required in (("label_key", True), ("description_key", False)):
            value = setting.get(field)
            if value is None:
                if required:
                    error(f"{where} ('{key}'): missing '{field}'")
                continue
            if not isinstance(value, str) or value not in translations:
                error(f"{where} ('{key}'): '{field}' value '{value}' has no entry in translations/en.json")

        if kind == "select":
            options = setting.get("options")
            if not isinstance(options, list) or not options:
                error(f"{where} ('{key}'): select needs a non-empty 'options' array")
            elif not all(isinstance(option, dict) and "value" in option for option in options):
                error(f"{where} ('{key}'): every select option needs a 'value'")


def check_entries(manifest: dict, translations: dict[str, str]) -> None:
    seen_ids: dict[str, str] = {}
    entries = 0

    for kind in ENTRY_KINDS:
        for index, entry in enumerate(manifest.get(kind, [])):
            entries += 1
            where = f"[[{kind}]] #{index + 1}"
            if not isinstance(entry, dict):
                error(f"{where}: must be a table")
                continue

            entry_id = entry.get("id")
            if not isinstance(entry_id, str) or not entry_id:
                error(f"{where}: missing 'id'")
                continue
            if entry_id in seen_ids:
                error(f"{where}: duplicate entry id '{entry_id}' (already used by {seen_ids[entry_id]})")
            seen_ids[entry_id] = kind

            script = entry.get("entry")
            if not isinstance(script, str) or not script:
                error(f"{where} ('{entry_id}'): missing 'entry'")
                continue
            if script.startswith("/"):
                error(f"{where} ('{entry_id}'): entry must be plugin-relative, got '{script}'")
                continue
            path = PLUGIN_DIR / script
            if not path.is_file():
                error(f"{where} ('{entry_id}'): entry file '{script}' does not exist")
            elif path.stat().st_size == 0:
                error(f"{where} ('{entry_id}'): entry file '{script}' is empty")

            if kind == "panel":
                width = entry.get("width")
                if not isinstance(width, int) or width <= 0:
                    error(f"{where} ('{entry_id}'): panel needs a positive integer 'width'")
                height = entry.get("height")
                if height == "content":
                    if not isinstance(entry.get("max_height"), int):
                        error(f"{where} ('{entry_id}'): height = \"content\" requires integer 'max_height'")
                elif height == "fill":
                    if entry.get("placement") != "floating":
                        error(f"{where} ('{entry_id}'): height = \"fill\" requires placement = \"floating\"")
                elif not isinstance(height, int) or height <= 0:
                    error(f"{where} ('{entry_id}'): panel needs a positive integer 'height' or \"content\"")

            if kind == "panel":
                keyboard = entry.get("keyboard_focus")
                if keyboard is not None and keyboard not in ("on_demand", "exclusive", "none"):
                    error(f"{where} ('{entry_id}'): keyboard_focus must be on_demand, exclusive or none")
                keys = entry.get("capture_keys")
                if keys is not None:
                    if not isinstance(keys, list) or not keys:
                        error(f"{where} ('{entry_id}'): capture_keys must be a non-empty array")
                    elif not all(isinstance(key, str) and key for key in keys):
                        error(f"{where} ('{entry_id}'): capture_keys entries must be non-empty strings")
                    elif len(set(keys)) != len(keys):
                        error(f"{where} ('{entry_id}'): capture_keys contains duplicates")
                    elif path.is_file() and "function onKey" not in path.read_text(encoding="utf-8"):
                        error(f"{where} ('{entry_id}'): declares capture_keys but defines no onKey")

            if "setting" in entry:
                check_settings(f"{where} ('{entry_id}')", entry["setting"], translations)

    if entries == 0:
        error("manifest declares no entries")
    if entries and not any(kind in manifest for kind in ("widget", "panel", "service")):
        warn("no widget, panel or service entry; the plugin would be invisible")


def main() -> int:
    if not MANIFEST.is_file():
        print(f"error: {MANIFEST.relative_to(ROOT)} not found", file=sys.stderr)
        return 1

    translations = load_translations()
    manifest = load_toml(MANIFEST)
    if manifest:
        check_top_level(manifest)
        check_settings("plugin", manifest.get("setting", []), translations)
        check_entries(manifest, translations)

    plugin_id = manifest.get("id", "<unknown>")
    print(f"{plugin_id}: {len(errors)} error(s), {len(warnings)} warning(s)")
    for message in warnings:
        print(f"  warning: {message}")
    for message in errors:
        print(f"  error: {message}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
