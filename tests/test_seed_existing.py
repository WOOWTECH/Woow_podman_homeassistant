import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('existing_seed', Path(__file__).parents[1] / 'scripts/seed-existing-config.py')
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


class ExistingHASeed(unittest.TestCase):
    def component(self, root, version, code):
        p = root / 'custom_components/example'
        p.mkdir(parents=True)
        (p / 'manifest.json').write_text(json.dumps({'version': version}))
        (p / '__init__.py').write_text(code)

    def test_newer_component_is_retained_as_whole_tree(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp)/'seed', Path(temp)/'config'
            self.component(source, '1.2.2', 'older')
            self.component(target, '1.3.2', 'newer local')
            (source/'custom_components/example/old_only.py').write_text('must not mix versions')
            policy, actions, _, _ = seed.plan(source, target)
            self.assertEqual(policy['example']['action'], 'preserve')
            self.assertEqual(actions, [])

    def test_upgrade_keeps_user_yaml_and_extra_files(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp)/'seed', Path(temp)/'config'
            self.component(source, '2.0.15', 'new')
            self.component(target, '2.0.0', 'old')
            (source/'configuration.yaml').write_text('factory: yes')
            (target/'configuration.yaml').write_text('private: keep')
            (target/'custom_components/example/local-settings.json').write_text('private')
            policy, actions, kept, _ = seed.plan(source, target)
            self.assertEqual(policy['example']['action'], 'upgrade')
            self.assertIn('configuration.yaml', kept)
            self.assertEqual(len(actions), 2)
            self.assertTrue((target/'custom_components/example/local-settings.json').exists())

    def test_target_symlink_fails_before_mutation(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target, other = Path(temp)/'seed', Path(temp)/'config', Path(temp)/'other'
            self.component(source, '1.0.0', 'new')
            target.mkdir(); other.mkdir()
            (target/'custom_components').symlink_to(other, target_is_directory=True)
            with self.assertRaises(ValueError):seed.plan(source, target)
            self.assertEqual(list(other.iterdir()), [])

    def test_unknown_version_does_not_authorize_replacement(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp)/'seed', Path(temp)/'config'
            self.component(source, '2.0.0', 'new')
            self.component(target, 'custom-build', 'custom')
            policy, actions, _, _ = seed.plan(source, target)
            self.assertEqual(policy['example']['action'], 'preserve')
            self.assertEqual(actions, [])
