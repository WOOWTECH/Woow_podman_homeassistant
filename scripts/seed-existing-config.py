#!/usr/bin/env python3
"""Seed a reviewed HA image into an existing installation, preserving local content.

Used only by the separate existing-device upgrade recipe, after a cold backup.
Existing component trees at equal/newer/unknown versions are retained in full.
Older components receive the newer packaged files; files absent from that package
are not deleted. Existing blueprints, themes, YAML and other assets are retained.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile

DIRECTORIES = {'custom_components', 'themes', 'blueprints', 'www'}
FILES = {'configuration.yaml', 'automations.yaml', 'scripts.yaml', 'scenes.yaml'}


def version(value):
    match = re.fullmatch(r'v?(\d+)\.(\d+)(?:\.(\d+))?', str(value))
    return tuple(int(x or 0) for x in match.groups()) if match else None


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def safe_target(root, relative):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Target must be a real directory')
    path = root
    for part in Path(relative).parts:
        if part in ('..', '.'):
            raise ValueError('Invalid relative path')
        path /= part
        if path.is_symlink():
            raise ValueError('Refusing a symbolic link in target')
    return path


def atomic_write(path, content, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.woow-existing-seed-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def plan(source, target):
    approved = {}
    if source.is_symlink() or not source.is_dir():
        raise ValueError('Source must be a real directory')
    # Complete validation precedes all mutations.
    for root, dirs, files in os.walk(source, followlinks=False):
        for name in dirs + files:
            item = Path(root) / name
            relative = item.relative_to(source)
            if item.is_symlink() or relative.parts[0] not in DIRECTORIES | FILES:
                raise ValueError('Unapproved seed path')
            if name in dirs:
                if relative.parts[0] not in DIRECTORIES:
                    raise ValueError('Unexpected seed directory')
                continue
            if not item.is_file() or (relative.parts[0] in FILES and len(relative.parts) != 1):
                raise ValueError('Non-regular seed entry')
            if relative.parts[0] in DIRECTORIES and len(relative.parts) == 1:
                raise ValueError('Expected seed directory')
            dest = safe_target(target, relative)
            if dest.exists() and not dest.is_file():
                raise ValueError('Existing destination is not a file')
            approved[relative.as_posix()] = (item, dest)
    policy = {}
    for relative, (item, dest) in approved.items():
        parts = Path(relative).parts
        if len(parts) == 3 and parts[0] == 'custom_components' and parts[2] == 'manifest.json':
            name = parts[1]
            new = json.loads(item.read_text()).get('version')
            old = json.loads(dest.read_text()).get('version') if dest.exists() else None
            exists = dest.parent.exists()
            upgrade = bool(exists and version(old) and version(new) and version(new) > version(old))
            policy[name] = {'before': old, 'packaged': new, 'action': 'upgrade' if upgrade else 'preserve' if exists else 'add'}
    actions = []
    kept = []
    identical = {}
    for relative, (item, dest) in sorted(approved.items()):
        parts = Path(relative).parts
        if parts[0] == 'custom_components':
            if len(parts) < 3 or parts[1] not in policy:
                raise ValueError('Component has no manifest')
            if policy[parts[1]]['action'] == 'preserve':
                kept.append(relative)
                continue
        wanted = digest(item)
        if dest.exists() and digest(dest) == wanted:
            identical[relative] = wanted
        elif dest.exists() and parts[0] != 'custom_components':
            kept.append(relative)
        else:
            actions.append((relative, item, dest))
    return policy, actions, kept, identical


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'target', 'state'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    policy, actions, kept, managed = plan(args.source, args.target)
    if not args.dry_run:
        for relative, source, target in actions:
            atomic_write(target, source.read_bytes(), stat.S_IMODE(source.stat().st_mode) & 0o755)
            managed[relative] = digest(source)
        state = {'format': 1, 'image': args.image, 'files': managed, 'existing_device_policy': policy,
                 'preserved_relative_paths': kept}
        atomic_write(args.state, (json.dumps(state, indent=2) + '\n').encode(), 0o600)
    print(json.dumps({'component_policy': policy, 'files_to_write': len(actions),
                      'existing_files_preserved': len(kept), 'dry_run': args.dry_run}))


if __name__ == '__main__':
    main()
