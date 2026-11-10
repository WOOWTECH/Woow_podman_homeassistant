#!/usr/bin/env python3
"""Merge an image's public Home Assistant seed into a host-owned config directory.

Only package files are accepted. User files are never overwritten unless they still
match the checksum recorded when this repository seeded them on a previous install.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import uuid

SEED_DIRS = {"custom_components", "themes", "blueprints", "www"}
SEED_FILES = {"configuration.yaml", "automations.yaml", "scripts.yaml", "scenes.yaml"}
LOVELACE_RESOURCES = (
    ("www/config-editor-fullpage.js", "/local/config-editor-fullpage.js"),
    ("www/community/lovelace-mushroom/mushroom.js",
     "/local/community/lovelace-mushroom/mushroom.js"),
)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def seed_files(source: Path) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for root, dirs, files in os.walk(source, followlinks=False):
        folder = Path(root)
        for name in dirs:
            child = folder / name
            if child.is_symlink():
                raise ValueError(f"seed contains a symbolic link: {child}")
            relative = child.relative_to(source)
            if relative.parts[0] not in SEED_DIRS:
                raise ValueError(f"image /config contains an unapproved directory: {relative}")
        for name in files:
            item = folder / name
            if item.is_symlink() or not item.is_file():
                raise ValueError(f"seed contains a non-regular file: {item}")
            relative = item.relative_to(source)
            top = relative.parts[0]
            if not ((top in SEED_DIRS and len(relative.parts) > 1) or
                    (top in SEED_FILES and len(relative.parts) == 1)):
                raise ValueError(f"image /config contains an unapproved path: {relative}")
            if (name == ".DS_Store" or name.endswith((".pyc", ".orig", "~")) or
                    ".git" in relative.parts or "__pycache__" in relative.parts or
                    (top == "custom_components" and len(relative.parts) > 2 and
                     relative.parts[2] in {"tests", "docs"})):
                raise ValueError(f"seed contains development or backup material: {relative}")
            found[relative.as_posix()] = item
    return found


def safe_target(target: Path, relative: str) -> Path:
    item = target / relative
    if target.is_symlink():
        raise ValueError(f"config path is a symbolic link: {target}")
    current = target
    for part in Path(relative).parts[:-1]:
        current /= part
        if current.is_symlink():
            raise ValueError(f"config path is a symbolic link: {current}")
    if item.is_symlink():
        raise ValueError(f"config file is a symbolic link: {item}")
    return item


def atomic_copy(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".woow-ha-seed-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as output, source.open("rb") as inp:
            shutil.copyfileobj(inp, output)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(name, stat.S_IMODE(source.stat().st_mode) & 0o755)
        os.replace(name, target)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def seed_lovelace_resources(target: Path, files: dict[str, Path], dry_run: bool) -> bool:
    """Register the two bundled JS modules on a new instance without copying identity."""
    if not all(path in files for path, _ in LOVELACE_RESOURCES):
        return False
    storage = target / ".storage"
    if storage.is_symlink():
        raise ValueError(f"config path is a symbolic link: {storage}")
    # An existing .storage belongs to HA/the operator. Never rewrite its resource mode.
    if storage.exists():
        if not storage.is_dir():
            raise ValueError(f"config path is not a directory: {storage}")
        return False
    if dry_run:
        return True
    storage.mkdir(mode=0o700)
    resource_file = safe_target(target, ".storage/lovelace_resources")
    payload = {
        "version": 1, "minor_version": 1, "key": "lovelace_resources",
        "data": {"items": [
            {"id": uuid.uuid4().hex, "url": url, "type": "module"}
            for _, url in LOVELACE_RESOURCES
        ]},
    }
    fd, name = tempfile.mkstemp(prefix=".woow-ha-resources-", dir=storage)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(payload, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(name, 0o600)
        os.replace(name, resource_file)
    finally:
        if os.path.exists(name):
            os.unlink(name)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--image", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not args.source.is_dir() or not args.target.is_dir():
        parser.error("source and target must already be directories")
    files = seed_files(args.source)
    try:
        previous = json.loads(args.state.read_text(encoding="utf-8"))
    except FileNotFoundError:
        previous = {}
    if previous and previous.get("format") != 1:
        raise ValueError(f"unsupported seed state format: {args.state}")
    known = previous.get("files", {})
    current: dict[str, str] = dict(known)
    copied = updated = present = conflicts = kept = 0
    planned: list[tuple[Path, Path]] = []
    for relative, source in sorted(files.items()):
        destination = safe_target(args.target, relative)
        wanted = digest(source)
        if destination.exists() and not destination.is_file():
            conflicts += 1
            print(f"seed conflict: {relative} is not a file", file=sys.stderr)
            continue
        actual = digest(destination) if destination.exists() else None
        if actual == wanted:
            present += 1
            current[relative] = wanted
        elif actual is None or known.get(relative) == actual:
            planned.append((source, destination))
            if actual is None:
                copied += 1
            else:
                updated += 1
            current[relative] = wanted
        elif relative in SEED_FILES:
            kept += 1
            print(f"seed: kept local {relative}")
        else:
            conflicts += 1
            print(f"seed conflict: {relative} was changed locally; kept it", file=sys.stderr)
    if conflicts:
        print(f"seed: {conflicts} package file conflicts; no files were changed", file=sys.stderr)
        return 2
    resources_planned = seed_lovelace_resources(args.target, files, True)
    if not args.dry_run:
        for source, destination in planned:
            atomic_copy(source, destination)
        if resources_planned:
            seed_lovelace_resources(args.target, files, False)
        args.state.parent.mkdir(parents=True, exist_ok=True)
        data = {"format": 1, "image": args.image, "files": current}
        fd, name = tempfile.mkstemp(prefix=".seed-state-", dir=args.state.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                json.dump(data, output, indent=2, sort_keys=True)
                output.write("\n")
            os.chmod(name, 0o600)
            os.replace(name, args.state)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    print(f"seed: {len(files)} files; copied={copied} updated={updated} "
          f"present={present} kept_local={kept} resources_new={int(resources_planned)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"seed error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
