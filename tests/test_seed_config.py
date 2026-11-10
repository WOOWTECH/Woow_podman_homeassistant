"""The seed is installed before HA starts and must preserve operator changes."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts/seed-config.py"


class SeedConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.source = root / "source"
        self.target = root / "target"
        self.state = root / "state.json"
        self.source.mkdir()
        self.target.mkdir()

    def put(self, path, text):
        dest = self.source / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8")

    def run_seed(self):
        return subprocess.run([
            sys.executable, str(SCRIPT), "--source", str(self.source),
            "--target", str(self.target), "--state", str(self.state),
            "--image", "localhost/test:2026.9.1-r1",
        ], capture_output=True, text=True)

    def test_first_install_and_managed_upgrade_keep_local_yaml(self):
        self.put("custom_components/demo/manifest.json", '{"version":"1"}')
        self.put("themes/woow.yaml", "woow:\n  primary-color: blue\n")
        self.put("configuration.yaml", "default_config:\n")
        self.assertEqual(self.run_seed().returncode, 0)
        self.assertEqual((self.target / "custom_components/demo/manifest.json").read_text(),
                         '{"version":"1"}')
        (self.target / "configuration.yaml").write_text("default_config:\n# local\n")
        self.put("custom_components/demo/manifest.json", '{"version":"2"}')
        self.put("configuration.yaml", "default_config:\nfrontend:\n")
        result = self.run_seed()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / "custom_components/demo/manifest.json").read_text(),
                         '{"version":"2"}')
        self.assertEqual((self.target / "configuration.yaml").read_text(),
                         "default_config:\n# local\n")
        self.assertIn("kept_local=1", result.stdout)

    def test_conflict_aborts_without_partial_package_update(self):
        self.put("custom_components/demo/manifest.json", '{"version":"1"}')
        self.assertEqual(self.run_seed().returncode, 0)
        before = json.loads(self.state.read_text())
        (self.target / "custom_components/demo/manifest.json").write_text("local change")
        self.put("custom_components/demo/manifest.json", '{"version":"2"}')
        self.put("themes/new.yaml", "new: {}\n")
        result = self.run_seed()
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.target / "themes/new.yaml").exists())
        self.assertEqual(json.loads(self.state.read_text()), before)

    def test_new_instance_registers_bundled_resources_once(self):
        self.put("www/config-editor-fullpage.js", "export const editor = true;")
        self.put("www/community/lovelace-mushroom/mushroom.js", "export const card = true;")
        first = self.run_seed()
        self.assertEqual(first.returncode, 0, first.stderr)
        path = self.target / ".storage/lovelace_resources"
        data = json.loads(path.read_text())
        self.assertEqual(data["key"], "lovelace_resources")
        self.assertEqual(data["version"], 1)
        self.assertEqual(data["minor_version"], 1)
        self.assertEqual([item["url"] for item in data["data"]["items"]], [
            "/local/config-editor-fullpage.js",
            "/local/community/lovelace-mushroom/mushroom.js",
        ])
        self.assertEqual(len({item["id"] for item in data["data"]["items"]}), 2)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.run_seed().returncode, 0)
        self.assertEqual(json.loads(path.read_text()), data)

        # A pre-existing HA instance owns its .storage, even without resources.
        path.unlink()
        self.assertEqual(self.run_seed().returncode, 0)
        self.assertFalse(path.exists())

    def test_rejects_identity_state_and_symlinks(self):
        self.put(".storage/auth", "identity")
        self.assertEqual(self.run_seed().returncode, 1)
        (self.source / ".storage/auth").unlink()
        (self.source / ".storage").rmdir()
        self.put("themes/woow.yaml", "woow: {}\n")
        (self.source / "themes/link.yaml").symlink_to("woow.yaml")
        self.assertEqual(self.run_seed().returncode, 1)
        (self.source / "themes/link.yaml").unlink()
        (self.target / "themes").symlink_to(self.source / "themes", target_is_directory=True)
        self.assertEqual(self.run_seed().returncode, 1)


if __name__ == "__main__":
    unittest.main()
