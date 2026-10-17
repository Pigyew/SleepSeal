#!/usr/bin/env python3
"""Release and installer failure tests. All installer commands/paths are sandboxed."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


metadata = module('release_metadata', 'release-metadata.py')
localizations = module('localization_checks', 'check-localizations.py')


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sleepseal-metadata-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.v = metadata.version()
        self.commit = 'a' * 40
        self.source = {'VERSION': 'b' * 64}
        info = {'CFBundleIdentifier': 'local.sleepseal.guard', 'CFBundleShortVersionString': self.v['SLEEPSEAL_VERSION'],
                'CFBundleVersion': self.v['SLEEPSEAL_BUILD'], 'LSMinimumSystemVersion': self.v['SLEEPSEAL_MIN_MACOS']}
        self.info = self.root / 'build/SleepSeal.app/Contents/Info.plist'
        self.info.parent.mkdir(parents=True)
        self.info.write_bytes(plistlib.dumps(info))
        binary = self.root / 'build/SleepSeal.app/Contents/MacOS/SleepSeal'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'mocked app binary')
        (self.root / 'build/PowerControl').write_bytes(b'mocked helper binary')
        self.arch, self.minimum = 'arm64', '13.0'
        for patch in (mock.patch.object(metadata, 'ROOT', self.root), mock.patch.object(metadata, 'version', return_value=self.v),
                      mock.patch.object(metadata, 'source_hashes', return_value=self.source), mock.patch.object(metadata, 'run', side_effect=self.fake_command),
                      mock.patch.object(metadata.subprocess, 'run')):
            patch.start()
            self.addCleanup(patch.stop)
        self.record = {'version': self.v, 'commit': self.commit, 'source_sha256': self.source.copy(), 'outputs_sha256': metadata.output_hashes(), 'dirty': False,
                       'github_run_id': '77', 'package': {'name': metadata.package_name(self.v), 'sha256': ''}}
        self.save()

    def fake_command(self, *args):
        if args[:3] == ('git', 'rev-parse', 'HEAD'):
            return self.commit
        if args[0] == '/usr/bin/lipo':
            return self.arch
        if args[0] == '/usr/bin/otool':
            return f'cmd LC_BUILD_VERSION\nminos {self.minimum}\nsdk 15.5'
        raise AssertionError(f'Unexpected native command in mock test: {args}')

    def save(self):
        metadata.write_json(self.root / 'build/build-manifest.json', self.record)

    def test_matching_build_passes(self):
        self.assertEqual(metadata.verify_build()['commit'], self.commit)

    def test_changed_source_requires_rebuild(self):
        self.record['source_sha256'] = {'VERSION': 'stale'}
        self.save()
        with self.assertRaisesRegex(ValueError, 'Sources or version changed'):
            metadata.verify_build()

    def test_changed_helper_is_rejected(self):
        (self.root / 'build/PowerControl').write_bytes(b'stale helper')
        with self.assertRaisesRegex(ValueError, 'Build outputs changed'):
            metadata.verify_build()

    def test_unlisted_extra_resource_is_rejected(self):
        (self.info.parent / 'old-resource.txt').write_text('stale')
        with self.assertRaisesRegex(ValueError, 'Build outputs changed'):
            metadata.verify_build()

    def test_symlink_output_is_rejected(self):
        (self.info.parent / 'linked-resource').symlink_to(self.info)
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            metadata.verify_build()

    def test_wrong_architecture_is_rejected(self):
        self.arch = 'x86_64'
        with self.assertRaisesRegex(ValueError, 'arm64-only'):
            metadata.verify_build()

    def test_wrong_deployment_target_is_rejected(self):
        self.minimum = '14.0'
        with self.assertRaisesRegex(ValueError, 'Deployment target'):
            metadata.verify_build()

    def test_wrong_bundle_version_is_rejected(self):
        info = plistlib.loads(self.info.read_bytes())
        info['CFBundleVersion'] = '1'
        self.info.write_bytes(plistlib.dumps(info))
        self.record['outputs_sha256'] = metadata.output_hashes()
        self.save()
        with self.assertRaisesRegex(ValueError, 'metadata'):
            metadata.verify_build()

    def prepare_package(self):
        name = metadata.package_name(self.v)
        (self.root / 'build' / name).write_bytes(b'mock package')
        self.record['package']['sha256'] = metadata.digest(self.root / 'build' / name)
        metadata.write_json(self.root / 'build' / (name + '.manifest.json'), self.record)
        (self.root / 'build' / (name + '.sha256')).write_text(f"{self.record['package']['sha256']}  {name}\n")
        return name

    def verify_package(self):
        with mock.patch.object(sys, 'argv', ['release-metadata.py', 'verify-package', str(self.root / 'build'), '--commit', self.commit, '--require-clean']), mock.patch.dict(os.environ, {'GITHUB_RUN_ID': '77'}):
            metadata.main()

    def test_release_package_and_provenance_match(self):
        self.prepare_package()
        self.verify_package()

    def test_replaced_release_asset_is_rejected(self):
        name = self.prepare_package()
        (self.root / 'build' / name).write_bytes(b'replaced')
        with self.assertRaisesRegex(ValueError, 'integrity'):
            self.verify_package()

    def test_wrong_workflow_run_is_rejected(self):
        self.record['github_run_id'] = 'other run'
        self.prepare_package()
        with self.assertRaisesRegex(ValueError, 'workflow run'):
            self.verify_package()

    def test_dirty_release_is_rejected(self):
        self.record['dirty'] = True
        self.prepare_package()
        with self.assertRaisesRegex(ValueError, 'clean'):
            self.verify_package()

    def test_wrong_release_commit_is_rejected(self):
        self.record['commit'] = 'different commit'
        self.prepare_package()
        with self.assertRaisesRegex(ValueError, 'commit'):
            self.verify_package()

    def test_checksum_file_tampering_is_rejected(self):
        name = self.prepare_package()
        (self.root / 'build' / (name + '.sha256')).write_text('bad checksum')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.verify_package()

    def test_tag_must_match_single_version_source(self):
        with mock.patch.object(sys, 'argv', ['release-metadata.py', 'check-tag', 'v0.0.0']):
            with self.assertRaisesRegex(ValueError, 'tag'):
                metadata.main()


class LocalizationTests(unittest.TestCase):
    def test_localized_keys_and_formats(self):
        self.assertGreater(localizations.check(), 200)

    def test_positional_reordering_keeps_types(self):
        self.assertEqual(localizations.arguments('%@ %lld %f'), localizations.arguments('%3$f %2$lld %1$@'))

    def test_incompatible_object_and_integer_are_detected(self):
        self.assertNotEqual(localizations.arguments('%@'), localizations.arguments('%d'))

    def test_length_and_star_arguments_are_checked(self):
        self.assertNotEqual(localizations.arguments('%d'), localizations.arguments('%lld'))
        self.assertEqual(localizations.arguments('%*.*f'), localizations.arguments('%3$*1$.*2$f'))

    def test_escaped_percent_has_no_argument(self):
        self.assertFalse(localizations.arguments('100%% complete'))

    def test_mixed_positions_and_percent_n_are_rejected(self):
        for value in ('%1$@ %d', '%n'):
            with self.assertRaises(ValueError):
                localizations.arguments(value)


# This shim has no installer privileges. All paths must be inside the fixture;
# launchctl, sudo, open and chown are simulated and never executed.
SHIM = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, stat, subprocess, sys, tempfile
root = pathlib.Path(os.environ['SLEEPSEAL_FIXTURE_ROOT'])
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'commands.jsonl').open('a') as log:
    log.write(json.dumps([command] + args) + '\n')
if os.environ.get('SLEEPSEAL_FIXTURE_FAIL') == command:
    sys.exit(75)
def safe(value):
    path = pathlib.Path(value)
    if not path.is_absolute() or not path.is_relative_to(root):
        raise RuntimeError('Sandbox command refused external path: ' + value)
    return path
if command == 'id':
    print('0' if args == ['-u'] else 'fixture-user')
elif command == 'stat':
    path = safe(args[-1])
    if args[1] == '%u':
        print(os.environ.get('SLEEPSEAL_FIXTURE_UID', '501') if path.name == 'console' else ('501' if os.environ.get('SLEEPSEAL_FIXTURE_USER_APP') and path.name == 'SleepSeal.app' else '0'))
    else:
        print(oct(stat.S_IMODE(path.stat().st_mode))[2:])
elif command == 'PlistBuddy':
    print(plistlib.loads(safe(args[-1]).read_bytes())['CFBundleIdentifier'])
elif command == 'chown':
    safe(args[-1])
elif command == 'chmod':
    safe(args[-1]).chmod(int(args[0], 8))
elif command == 'install':
    path = safe(args[-1]); path.mkdir(parents=True, exist_ok=True); path.chmod(0o755)
elif command == 'mktemp':
    pattern = safe(args[0]); fd, name = tempfile.mkstemp(prefix=pattern.name.replace('XXXXXX', ''), dir=pattern.parent); os.close(fd); print(name)
elif command == 'printf':
    sys.exit(subprocess.run(['/usr/bin/printf'] + args).returncode)
elif command == 'visudo':
    text = safe(args[-1]).read_text(); assert '#501 ALL=(root) NOPASSWD:' in text; assert 'NOPASSWD: ALL' not in text
elif command == 'mv':
    os.replace(safe(args[-2]), safe(args[-1]))
elif command == 'rm':
    for arg in args:
        if not arg.startswith('-'):
            path = safe(arg)
            if path.exists(): path.unlink()
elif command in ('launchctl', 'sudo', 'open'):
    pass
elif command == 'echo':
    print(' '.join(args))
else:
    raise RuntimeError('Unsupported sandbox command: ' + command)
'''


class InstallerSandboxTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sleepseal-installer-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.shims = self.root / 'shims'
        self.shims.mkdir()
        self.env = dict(os.environ, SLEEPSEAL_FIXTURE_ROOT=str(self.root))
        for directory in ('Applications', 'Library/PrivilegedHelperTools', 'Library/Application Support', 'private/etc/sudoers.d', 'dev'):
            path = self.root / directory
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(0o755)
        (self.root / 'dev/console').touch()
        self.app = self.root / 'Applications/SleepSeal.app'
        (self.app / 'Contents').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.sleepseal.guard'}))
        self.helper = self.root / 'Library/PrivilegedHelperTools/local.sleepseal.PowerControl'
        self.helper.write_text('mock helper, never executable')
        self.helper.chmod(0o755)

    def execute(self, script):
        source = (ROOT / 'Packaging/Scripts' / script).read_text()
        # Rewrite a copy, never production scripts. Inject all commands as well as
        # every system data path before any shell process is allowed to run.
        commands = set(re.findall(r'/(?:usr/(?:bin|sbin|libexec)|bin)/[A-Za-z][A-Za-z0-9_-]*', source))
        for command in sorted(commands, key=len, reverse=True):
            shim = self.shims / Path(command).name
            shim.write_text(SHIM)
            shim.chmod(0o755)
            source = source.replace(command, str(shim))
        for path in ('/Applications', '/Library', '/private/etc', '/dev/console'):
            source = source.replace(path, str(self.root / path.lstrip('/')))
        self.assertFalse(re.search(r'(?<![\w/])/(?:usr/(?:bin|sbin|libexec)|bin)/', source))
        return subprocess.run(['/bin/sh', '-c', source], env=self.env, text=True, capture_output=True)

    def rule(self):
        return self.root / 'private/etc/sudoers.d/sleepseal_v2_501'

    def test_preinstall_accepts_normal_fixed_installation(self):
        result = self.execute('preinstall')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_preinstall_rejects_non_gui_account(self):
        self.env['SLEEPSEAL_FIXTURE_UID'] = '0'
        self.assertNotEqual(self.execute('preinstall').returncode, 0)

    def test_preinstall_rejects_writable_helper(self):
        self.helper.chmod(0o777)
        self.assertNotEqual(self.execute('preinstall').returncode, 0)

    def test_preinstall_rejects_symlink_helper(self):
        self.helper.unlink()
        self.helper.symlink_to(self.root / 'mock-target')
        self.assertNotEqual(self.execute('preinstall').returncode, 0)

    def test_preinstall_rejects_user_owned_existing_app(self):
        self.env['SLEEPSEAL_FIXTURE_USER_APP'] = '1'
        self.assertNotEqual(self.execute('preinstall').returncode, 0)

    def test_preinstall_rejects_unrelated_app(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'another.app'}))
        self.assertNotEqual(self.execute('preinstall').returncode, 0)

    def test_postinstall_creates_only_fixed_account_grant(self):
        result = self.execute('postinstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('#501 ALL=(root) NOPASSWD:', self.rule().read_text())
        self.assertNotIn('NOPASSWD: ALL', self.rule().read_text())
        record = self.root / 'Library/Application Support/SleepSeal/authorized-users/501'
        self.assertEqual(record.read_text(), '501\n')
        self.assertEqual(record.stat().st_mode & 0o777, 0o444)
        calls = [json.loads(line) for line in (self.root / 'commands.jsonl').read_text().splitlines()]
        self.assertEqual(sum(call[0] == 'launchctl' for call in calls), 1)
        self.assertFalse(any(call[0] in ('sudo', 'open') for call in calls))

    def test_postinstall_visudo_failure_preserves_existing_rule(self):
        self.rule().write_text('existing grant\n')
        self.env['SLEEPSEAL_FIXTURE_FAIL'] = 'visudo'
        self.assertNotEqual(self.execute('postinstall').returncode, 0)
        self.assertEqual(self.rule().read_text(), 'existing grant\n')
        self.assertFalse(list(self.rule().parent.glob('.sleepseal.*')))

    def test_postinstall_move_failure_does_not_publish_new_grant(self):
        self.env['SLEEPSEAL_FIXTURE_FAIL'] = 'mv'
        self.assertNotEqual(self.execute('postinstall').returncode, 0)
        self.assertFalse(self.rule().exists())
        self.assertFalse(list(self.rule().parent.glob('.sleepseal.*')))

    def test_postinstall_rejects_symlink_authorization(self):
        self.rule().symlink_to(self.root / 'elsewhere')
        self.assertNotEqual(self.execute('postinstall').returncode, 0)
        self.assertFalse((self.root / 'elsewhere').exists())

    def test_postinstall_ui_launch_failure_keeps_usable_install(self):
        self.env['SLEEPSEAL_FIXTURE_FAIL'] = 'launchctl'
        result = self.execute('postinstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.rule().exists())
        self.assertTrue(self.app.is_dir())


if __name__ == '__main__':
    unittest.main(verbosity=2)
