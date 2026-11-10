#!/usr/bin/env python3
"""Build the WOOWTECH Podman HA package layer from a pinned private rebrand tree.

The public Podman repository contains only the builder and source revisions. The
custom integrations, artwork, and frontend assets stay in the private source and
the locally built OCI image; they are never copied into this Git checkout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parent.parent
LOCK = json.loads((REPO / "image/sources.lock.json").read_text(encoding="utf-8"))


def git_revision(path: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
    ).strip()


def release_asset(kind: str, supplied: Path | None, work: Path) -> Path:
    item = LOCK[kind]
    if supplied is None:
        folder = work / "release-assets" / kind
        folder.mkdir(parents=True)
        subprocess.run([
            "gh", "release", "download", item["tag"], "--repo", item["repository"],
            "--pattern", item["asset"], "--dir", str(folder),
        ], check=True)
    else:
        folder = supplied
    path = folder / item["asset"]
    if not path.is_file():
        raise ValueError(f"missing {kind} release asset: {path}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != item["sha256"]:
        raise ValueError(f"{kind} release asset checksum mismatch: {path}")
    return path


def add_protected_apps(archive: Path, config: Path) -> None:
    prefix = Path("custom_components/woow_protected_apps")
    with tarfile.open(archive, "r:gz") as package:
        for member in package.getmembers():
            relative = Path(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError(f"unsafe protected-apps archive path: {member.name}")
            if relative != prefix and prefix not in relative.parents:
                raise ValueError(f"unexpected protected-apps path: {member.name}")
            if not (member.isfile() or member.isdir()):
                raise ValueError(f"unsafe protected-apps archive member: {member.name}")
            if member.isdir():
                continue
            source = package.extractfile(member)
            if source is None:
                raise ValueError(f"cannot read protected-apps member: {member.name}")
            destination = config / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            with source, destination.open("wb") as output:
                shutil.copyfileobj(source, output)
    manifest = json.loads((config / prefix / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("domain") != "woow_protected_apps":
        raise ValueError("protected-apps release has the wrong integration domain")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rebrand", required=True, type=Path, help="local ha-rebrand checkout")
    parser.add_argument("--tag", default="localhost/woowtech/ha-preinstalled:2026.9.1-r3")
    parser.add_argument("--assets-dir", type=Path,
                        help="directory holding the two locked release assets; otherwise download with gh")
    args = parser.parse_args()
    source = args.rebrand.resolve()
    if not (source / "pipelines/shared/armbian-seed/MANIFEST.md").is_file():
        parser.error(f"{source} is not a ha-rebrand checkout")
    actual = git_revision(source)
    expected = LOCK["ha_rebrand"]["commit"]
    if actual != expected:
        parser.error(f"ha-rebrand is at {actual}; source lock requires {expected}")
    dirty = subprocess.check_output(
        ["git", "-C", str(source), "status", "--porcelain"], text=True
    )
    if dirty:
        parser.error("ha-rebrand checkout is modified; use a clean pinned checkout")

    with tempfile.TemporaryDirectory(prefix="woow-ha-build-") as name:
        work = Path(name)
        payload = work / "payload"
        config = payload / "config"
        config.mkdir(parents=True)
        shared = source / "pipelines/shared/armbian-seed"
        for category in ("custom_components", "themes", "blueprints", "www"):
            shutil.copytree(shared / category, config / category)
        browser = source / "brands/woowtech/tenant-config/custom_components/browser_mod"
        shutil.copytree(browser, config / "custom_components/browser_mod")
        add_protected_apps(release_asset("woow_protected_apps", args.assets_dir, work), config)
        mushroom = config / "www/community/lovelace-mushroom/mushroom.js"
        mushroom.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(release_asset("mushroom", args.assets_dir, work), mushroom)
        icon_source = source / "brands/woowtech/frontend/public/static/icons"
        icon_files = list(icon_source.iterdir())
        if len(icon_files) != 23 or any(not item.is_file() or item.is_symlink()
                                        for item in icon_files):
            parser.error("WoowTech frontend icon source changed; review the static assets")
        shutil.copytree(icon_source, payload / "frontend-icons")
        shutil.copy2(REPO / "image/configuration.yaml", config / "configuration.yaml")
        for basename in ("automations.yaml", "scripts.yaml", "scenes.yaml"):
            shutil.copy2(source / "pipelines/woowtech-cloud/config-seed" / basename,
                         config / basename)
        patch = source / "pipelines/shared/cloud-ha-mcp/patch_ha_mcp_tools.py"
        subprocess.run(["python3", str(patch), str(config / "custom_components/ha_mcp_tools")],
                       check=True)
        # This image runs HA-MCP in an isolated Podman process. Offering the
        # in-process server in the HA config flow would install its conflicting
        # Python dependencies into HA Core; keep the file/YAML tools entry.
        flow = config / "custom_components/ha_mcp_tools/config_flow.py"
        source_text = flow.read_text(encoding="utf-8")
        anchor = "menu_options=[ENTRY_TYPE_SERVER, ENTRY_TYPE_TOOLS],"
        if source_text.count(anchor) != 1:
            parser.error("ha_mcp_tools config flow changed; re-verify Podman server choice")
        flow.write_text(source_text.replace(anchor, "menu_options=[ENTRY_TYPE_TOOLS],"),
                        encoding="utf-8")
        components = [p for p in (config / "custom_components").iterdir() if p.is_dir()]
        themes = list((config / "themes").glob("*.yaml"))
        blueprints = list((config / "blueprints").rglob("*.yaml"))
        if len(components) != 22 or len(themes) != 14 or len(blueprints) != 22:
            parser.error("source inventory changed: expected 20 shared components + browser_mod "
                         "+ woow_protected_apps, "
                         "14 themes, and 22 shipped blueprints")
        requirements: set[str] = set()
        for component in components:
            manifest = json.loads((component / "manifest.json").read_text(encoding="utf-8"))
            requirements.update(manifest.get("requirements", []))
        (payload / "requirements.txt").write_text(
            "\n".join(sorted(requirements)) + "\n", encoding="utf-8"
        )
        shutil.copy2(REPO / "image/Containerfile", work / "Containerfile")
        shutil.copy2(REPO / "image/ha-mcp-launch.py", work / "ha-mcp-launch.py")
        shutil.copy2(REPO / "image/patch-frontend.py", work / "patch-frontend.py")
        # Validate the image payload before the time-consuming OCI build. An empty
        # target lets seed-config check path hygiene without reading any host data.
        empty = work / "empty-config"
        empty.mkdir()
        subprocess.run([
            "python3", str(REPO / "scripts/seed-config.py"), "--source", str(config),
            "--target", str(empty), "--state", str(work / "seed-state.json"),
            "--image", args.tag, "--dry-run",
        ], check=True)
        command = [
            "podman", "build", "--pull=never", "--layers", "-f", str(work / "Containerfile"),
            "-t", args.tag,
            "--build-arg", f"BASE_IMAGE={LOCK['ha_core']['upstream_image']}",
            "--build-arg", f"REBRAND_REV={expected}",
            "--build-arg", f"VERSION_CONTROL_REV={LOCK['ha_version_control']['commit']}",
            "--build-arg", f"HA_CORE_REV={LOCK['ha_core']['commit']}", str(work),
        ]
        subprocess.run(command, check=True)
    print(f"built {args.tag} from ha-rebrand {expected} and HA Core {LOCK['ha_core']['version']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
