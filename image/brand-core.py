#!/usr/bin/env python3
"""Apply the pinned WoowTech brand to the 2026.9.1 Core and compiled UI.

The locale-specific rules come from the locked private ha-rebrand checkout. Keep
upstream integration identifiers, package names, URLs, and third-party names.
"""

from __future__ import annotations

import json
from pathlib import Path
import re

from brand_rules import TYPO_STEMS, apply_keyscoped, apply_locale


CORE = Path("/usr/src/homeassistant/homeassistant")
FRONTEND = Path("/usr/local/lib/python3.14/site-packages/hass_frontend")
LOCALE = re.compile(r"^(.*)-[0-9a-f]{32}$")
PRODUCT = re.compile(r"Home[ \u00a0-]?Assistant[a-z]{0,6}")
TYPO = [re.compile(re.escape(word) + r"[a-z]{0,6}") for word in sorted(TYPO_STEMS, key=len, reverse=True)]
APP_HINT = {
    "en": ("The app store requires HAOS. This Podman edition includes integrations, "
           "themes and blueprints; other services run as separate packages."),
    "zh-Hant": ("應用程式商店僅適用於 HAOS。本 Podman 版本已預裝整合、主題與藍圖；"
                "其他服務請使用獨立套件。"),
}


def replace_exact(path: Path, old: str, new: str) -> None:
    content = path.read_text(encoding="utf-8")
    if content.count(old) != 1:
        raise ValueError(f"unexpected 2026.9.1 source: {path}: {old!r}")
    path.write_text(content.replace(old, new), encoding="utf-8")


def text_leaves(value: object, key: str = ""):
    if isinstance(value, dict):
        for name, child in value.items():
            yield from text_leaves(child, f"{key}.{name}" if key else name)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from text_leaves(child, f"{key}.{index}" if key else str(index))
    elif isinstance(value, str):
        yield key, value


def brand_text(value: str, locale: str, key: str, brand_keys: set[str]) -> str:
    result = PRODUCT.sub("woowtech", value)
    for pattern in TYPO:
        result = pattern.sub("woowtech", result)
    result = apply_locale(result, locale)
    if key in brand_keys:
        result = apply_keyscoped(result, locale)
    if key == "ui.panel.config.apps.info.installation_hint" and locale in APP_HINT:
        result = APP_HINT[locale]
    return result


def transform(value: object, locale: str, brand_keys: set[str], key: str = "") -> object:
    if isinstance(value, dict):
        return {name: transform(child, locale, brand_keys,
                                f"{key}.{name}" if key else name)
                for name, child in value.items()}
    if isinstance(value, list):
        return [transform(child, locale, brand_keys,
                          f"{key}.{index}" if key else str(index))
                for index, child in enumerate(value)]
    if isinstance(value, str):
        return brand_text(value, locale, key, brand_keys)
    return value


def rewrite_json(path: Path, locale: str, brand_keys: set[str]) -> int:
    original = json.loads(path.read_text(encoding="utf-8"))
    updated = transform(original, locale, brand_keys)
    if updated == original:
        return 0
    updated_leaves = dict(text_leaves(updated))
    count = sum(old != updated_leaves.get(key) for key, old in text_leaves(original))
    path.write_text(json.dumps(updated, ensure_ascii=False, separators=(",", ":")) + "\n",
                    encoding="utf-8")
    for suffix in (".gz", ".br"):
        path.with_name(path.name + suffix).unlink(missing_ok=True)
    return count


def brand_keys(path: Path) -> set[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return {key for key, value in text_leaves(data) if "Home Assistant" in value}


def patch_core() -> None:
    const = CORE / "const.py"
    source = const.read_text(encoding="utf-8")
    for marker in ('MAJOR_VERSION: Final = 2026', 'MINOR_VERSION: Final = 9',
                   'PATCH_VERSION: Final = "1"'):
        if marker not in source:
            raise ValueError(f"Core version mismatch: {marker}")
    replace_exact(const, 'APPLICATION_NAME: Final = "HomeAssistant"',
                  'APPLICATION_NAME: Final = "woowtech"')
    frontend = CORE / "components/frontend/__init__.py"
    replace_exact(frontend, 'DEFAULT_THEME_COLOR = "#2980b9"',
                  'DEFAULT_THEME_COLOR = "#6183fc"')
    replace_exact(frontend, '"name": "Home Assistant",', '"name": "woowtech",')
    replace_exact(frontend, '"short_name": "Home Assistant",',
                  '"short_name": "woowtech",')

    components = CORE / "components"
    total = 0
    for component in components.iterdir():
        if not component.is_dir():
            continue
        manifest = component / "manifest.json"
        if manifest.exists():
            data = json.loads(manifest.read_text(encoding="utf-8"))
            name = data.get("name")
            if isinstance(name, str) and "Home Assistant" in name:
                data["name"] = PRODUCT.sub("woowtech", name)
                manifest.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n",
                                    encoding="utf-8")
        master = component / "strings.json"
        if not master.exists():
            master = component / "translations/en.json"
        keys = brand_keys(master) if master.exists() else set()
        if (component / "strings.json").exists():
            total += rewrite_json(component / "strings.json", "en", keys)
        translations = component / "translations"
        if translations.is_dir():
            for path in translations.glob("*.json"):
                total += rewrite_json(path, path.stem, keys)
    print(f"backend display strings changed: {total}", flush=True)


def patch_frontend() -> None:
    for name in ("index.html", "authorize.html", "onboarding.html"):
        path = FRONTEND / name
        source = path.read_text(encoding="utf-8")
        path.write_text(source.replace("Home Assistant", "woowtech"), encoding="utf-8")
        for suffix in (".gz", ".br"):
            path.with_name(path.name + suffix).unlink(missing_ok=True)
    translations = FRONTEND / "static/translations"
    keys: set[str] = set()
    for path in translations.rglob("en-*.json"):
        if LOCALE.match(path.stem):
            keys.update(brand_keys(path))
    total = 0
    for path in translations.rglob("*.json"):
        match = LOCALE.match(path.stem)
        if match:
            total += rewrite_json(path, match.group(1), keys)
    print(f"frontend display strings changed: {total}", flush=True)

    changed = 0
    for folder in (FRONTEND / "frontend_latest", FRONTEND / "frontend_es5"):
        for path in folder.glob("*.js"):
            source = path.read_text(encoding="utf-8", errors="ignore")
            updated = source.replace("Home Assistant", "woowtech")
            if updated != source:
                changed += source.count("Home Assistant")
                path.write_text(updated, encoding="utf-8")
                for suffix in (".gz", ".br"):
                    path.with_name(path.name + suffix).unlink(missing_ok=True)
    if changed < 100:
        raise ValueError(f"unexpected compiled UI: only {changed} brand references")
    print(f"compiled JavaScript references changed: {changed}", flush=True)

    # Post-build JavaScript edits invalidate the precache integrity list. This
    # Podman edition serves assets directly, as the old cloud pipeline did.
    for name in ("service_worker.js", "sw-modern.js", "sw-legacy.js"):
        for suffix in ("", ".gz", ".br", ".map"):
            (FRONTEND / f"{name}{suffix}").unlink(missing_ok=True)


if __name__ == "__main__":
    patch_core()
    patch_frontend()
