#!/usr/bin/env python3
"""Exercise build scripts in disposable repositories with system commands stubbed.

Only command paths are substituted in fixture copies. PlistBuddy, Bash and file
operations run for real; signing, installation, process control and launch APIs
are represented by commands that can only operate inside the temporary fixture.
"""

import json
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
STUB = r'''#!/usr/bin/python3
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import os

name, args = Path(sys.argv[0]).name, sys.argv[1:]
work = Path(os.environ['BUILD_SCRIPT_TEST_WORK'])
event = {'command': name, 'args': args}

def fixture_path(value):
    path = Path(value)
    if not path.resolve().is_relative_to(work.resolve()):
        raise RuntimeError('Command escaped disposable fixture: ' + value)
    return path

if name == 'codesign' and '--sign' in args:
    bundle = fixture_path(args[-1])
    entitlements = fixture_path(args[args.index('--entitlements') + 1])
    event['entitlements'] = plistlib.loads(entitlements.read_bytes())
    if os.environ.get('BUILD_SCRIPT_TEST_NATIVE_CODESIGN') != '1':
        (bundle / '.test-signature.plist').write_bytes(plistlib.dumps(event['entitlements']))

with (work / 'commands.jsonl').open('a') as log:
    log.write(json.dumps(event) + '\n')

failure = os.environ.get('BUILD_SCRIPT_TEST_FAIL')
if failure == name or (failure == 'verify' and name == 'codesign' and '--verify' in args):
    sys.exit(1)
if failure == 'verify-installed' and name == 'codesign' and '--verify' in args:
    if Path(args[-1]).resolve() != Path(os.environ['BUILD_SCRIPT_TEST_SOURCE']).resolve():
        sys.exit(1)

if name == 'codesign' and os.environ.get('BUILD_SCRIPT_TEST_NATIVE_CODESIGN') == '1':
    fixture_path(args[-1])
    sys.exit(subprocess.call(['/usr/bin/codesign', *args]))

if name == 'swift' and '--show-bin-path' in args:
    print(work / 'build-bin')
elif name == 'codesign' and '--verify' in args:
    fixture_path(args[-1]).joinpath('.test-signature.plist').read_bytes()
elif name == 'rm':
    for arg in args:
        if arg.startswith('-'):
            continue
        path = fixture_path(arg)
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
elif name == 'ditto':
    source, target = map(fixture_path, args[-2:])
    if '-c' in args:
        target.write_bytes(b'isolated release archive')
    else:
        # Fail safely if a regression attempts recursive copying in the fixture.
        if any(parent.is_dir() and source.is_dir() and parent.samefile(source)
               for parent in target.parents):
            raise RuntimeError('Refusing to copy fixture bundle into itself')
        shutil.copytree(source, target)
elif name == 'generate-icon':
    resources = fixture_path(args[0])
    resources.joinpath('Assets.car').write_bytes(b'fixture icon')
    resources.joinpath('AppIcon.icns').write_bytes(b'fixture icon')
elif name in ('open', 'lsregister'):
    fixture_path(args[-1]).joinpath('Contents/MacOS/Eligo').read_bytes()
elif name == 'lldb':
    fixture_path(args[-1]).read_bytes()
elif name not in ('swift', 'codesign', 'pkill', 'pgrep', 'sleep', 'log'):
    raise RuntimeError('Unexpected stub command: ' + name)
'''


class BuildScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='eligo-build-script-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name).resolve()
        self.repo = self.work / 'repository with spaces'
        self.bin = self.work / 'command-stubs'
        self.bin.mkdir()
        self.stub = self.bin / 'stub'
        self.stub.write_text(STUB)
        self.stub.chmod(0o755)
        for name in ('swift', 'codesign', 'rm', 'ditto', 'pkill', 'pgrep',
                     'lldb', 'open', 'lsregister', 'sleep', 'log', 'generate-icon'):
            self.bin.joinpath(name).symlink_to(self.stub)
        self.repo.joinpath('script').mkdir(parents=True)
        self.repo.joinpath('Resources').mkdir()
        self.work.joinpath('build-bin').mkdir()
        self.work.joinpath('build-bin/Eligo').write_bytes(b'fixture executable')
        self.work.joinpath('tmp').mkdir()
        self.applications = self.work / 'Applications'
        self.applications.mkdir()
        for relative in ('script/app-metadata.env', 'VERSION',
                         'Resources/Info.plist', 'Resources/Eligo.entitlements'):
            shutil.copy2(ROOT / relative, self.repo / relative)
        for script in ('build_and_run.sh', 'release.sh'):
            source = ROOT.joinpath('script', script).read_text()
            for absolute, name in (
                ('/usr/bin/codesign', 'codesign'),
                ('/usr/bin/ditto', 'ditto'),
                ('/usr/bin/open', 'open'),
                ('/usr/bin/log', 'log'),
                ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
                 'LaunchServices.framework/Support/lsregister', 'lsregister'),
            ):
                # lsregister is assigned inside quotes; other paths are commands.
                replacement = str(self.bin / name) if name == 'lsregister' else shlex.quote(str(self.bin / name))
                source = source.replace(absolute, replacement)
            source = source.replace('"$ROOT_DIR/script/generate_app_icon.sh"',
                                    shlex.quote(str(self.bin / 'generate-icon')))
            # Model the default system installation directory inside the fixture.
            source = source.replace('/Applications', str(self.applications))
            self.repo.joinpath('script', script).write_text(source)
        self.env = {
            'PATH': str(self.bin) + ':/usr/bin:/bin',
            'TMPDIR': str(self.work / 'tmp'),
            'BUILD_SCRIPT_TEST_WORK': str(self.work),
            'LOCAL_BUILD_NUMBER': '123',
            'BUILD_SCRIPT_TEST_SOURCE': str(self.app),
        }

    @property
    def app(self):
        return self.repo / 'dist/Eligo.app'

    def run_script(self, mode='run', install_dir=None, script='build_and_run.sh', relative_entry=False, **env):
        self.work.joinpath('commands.jsonl').unlink(missing_ok=True)
        environment = {**self.env, **env}
        if install_dir is not None:
            environment['INSTALL_DIR'] = str(install_dir)
        entry = str(Path('script') / script) if relative_entry else str(self.repo / 'script' / script)
        return subprocess.run(
            ['/bin/bash', entry, mode],
            cwd=self.repo, env=environment, capture_output=True, text=True,
        )

    def events(self, command=None):
        log = self.work / 'commands.jsonl'
        events = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return [event for event in events if command is None or event['command'] == command]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_debug_entitlements_cleaned(self):
        self.assertEqual(list(self.work.joinpath('tmp').glob('eligo-debug-entitlements.*')), [])

    def test_relative_entry_ignores_cdpath_checkout_and_preserves_it(self):
        template = self.repo / 'Resources/Info.plist'
        info = plistlib.loads(template.read_bytes())
        info['FixtureCheckout'] = 'A'
        template.write_bytes(plistlib.dumps(info))
        self.work.joinpath('build-bin/Eligo').write_bytes(b'checkout A executable')
        other = self.work / 'checkout B with spaces'
        shutil.copytree(self.repo, other)
        other.joinpath('VERSION').write_text('9.9.9\n')
        info['FixtureCheckout'] = 'B'
        other.joinpath('Resources/Info.plist').write_bytes(plistlib.dumps(info))
        other.joinpath('dist/Eligo.app').mkdir(parents=True)
        other.joinpath('dist/Eligo.app/keep-existing-bundle').write_bytes(b'keep checkout B bundle')
        before = {str(path.relative_to(other)): path.read_bytes() if path.is_file() else None
                  for path in other.rglob('*')}
        for mode in ('run', '--debug', 'verify'):
            with self.subTest(mode=mode):
                self.assert_success(self.run_script(mode, relative_entry=True, CDPATH=str(other) + ':.'))
                signing = next(event for event in self.events('codesign') if '--sign' in event['args'])
                self.assertEqual(signing['args'][-1], str(self.app))
                built = plistlib.loads(self.app.joinpath('Contents/Info.plist').read_bytes())
                self.assertEqual(built['FixtureCheckout'], 'A')
                self.assertEqual(built['CFBundleShortVersionString'], self.repo.joinpath('VERSION').read_text().strip())
                self.assertEqual(self.app.joinpath('Contents/MacOS/Eligo').read_bytes(), b'checkout A executable')
                after = {str(path.relative_to(other)): path.read_bytes() if path.is_file() else None
                         for path in other.rglob('*')}
                self.assertEqual(after, before)
                self.assert_debug_entitlements_cleaned()

    def test_debug_signs_with_temporary_debug_entitlements(self):
        canonical = self.repo / 'Resources/Eligo.entitlements'
        canonical.write_bytes(plistlib.dumps({'com.apple.security.cs.disable-library-validation': True}))
        original = canonical.read_bytes()
        self.assert_success(self.run_script('--debug'))
        signing = next(event for event in self.events('codesign') if '--sign' in event['args'])
        self.assertIs(signing['entitlements'].get('com.apple.security.get-task-allow'), True)
        self.assertIs(signing['entitlements']['com.apple.security.cs.disable-library-validation'], True)
        self.assertIn('runtime', signing['args'])
        temporary = Path(signing['args'][signing['args'].index('--entitlements') + 1])
        self.assertNotEqual(temporary, canonical)
        self.assertFalse(temporary.exists())
        self.assertEqual(canonical.read_bytes(), original)

    def test_installing_into_dist_keeps_the_signed_bundle_in_place(self):
        self.assert_success(self.run_script('run', self.repo / 'dist'))
        self.assertEqual(self.app.joinpath('Contents/MacOS/Eligo').read_bytes(), b'fixture executable')
        self.assertEqual(self.events('ditto'), [])
        signing = next(index for index, event in enumerate(self.events())
                       if event['command'] == 'codesign' and '--sign' in event['args'])
        self.assertFalse(any(event['command'] == 'rm' for event in self.events()[signing + 1:]))
        self.assertEqual(self.events('open')[-1]['args'], ['-n', str(self.app)])

    def test_debug_uses_the_verified_installation_binary(self):
        destination = self.work / 'other install directory'
        self.assert_success(self.run_script('debug', destination))
        installed = destination / 'Eligo.app'
        self.assertEqual(self.events('lldb')[-1]['args'], ['--', str(installed / 'Contents/MacOS/Eligo')])
        verification = [event for event in self.events('codesign') if '--verify' in event['args']]
        self.assertEqual(verification[-1]['args'][-1], str(installed))
        signature = plistlib.loads(installed.joinpath('.test-signature.plist').read_bytes())
        self.assertIs(signature['com.apple.security.get-task-allow'], True)

    def test_installation_inside_source_is_rejected_without_changing_the_bundle(self):
        nested = self.app / 'new installation'
        result = self.run_script('run', nested)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('inside the built bundle', result.stderr)
        self.assertFalse(nested.exists())
        self.assertEqual(self.app.joinpath('Contents/MacOS/Eligo').read_bytes(), b'fixture executable')
        self.assertEqual(self.events('ditto'), [])
        self.assertEqual(self.events('open'), [])

    def test_debug_then_run_rebuild_removes_debug_permission(self):
        self.assert_success(self.run_script('debug'))
        self.assertIs(plistlib.loads(self.app.joinpath('.test-signature.plist').read_bytes())
                      ['com.apple.security.get-task-allow'], True)
        self.assert_success(self.run_script('run'))
        self.assertNotIn('com.apple.security.get-task-allow',
                         plistlib.loads(self.app.joinpath('.test-signature.plist').read_bytes()))
        self.assertNotIn('com.apple.security.get-task-allow', plistlib.loads(
            self.applications.joinpath('Eligo.app/.test-signature.plist').read_bytes()))
        self.assert_debug_entitlements_cleaned()

    def test_ordinary_modes_use_canonical_entitlements_and_valid_installation(self):
        for mode in ('run', 'verify', '--verify', 'logs', '--logs', 'telemetry', '--telemetry'):
            with self.subTest(mode=mode):
                self.assert_success(self.run_script(mode))
                signing = next(event for event in self.events('codesign') if '--sign' in event['args'])
                self.assertEqual(signing['args'][signing['args'].index('--entitlements') + 1],
                                 str(self.repo / 'Resources/Eligo.entitlements'))
                self.assertNotIn('com.apple.security.get-task-allow', signing['entitlements'])
                self.assertEqual(self.events('open')[-1]['args'],
                                 ['-n', str(self.applications / 'Eligo.app')])
                self.assertEqual(self.events('lldb'), [])

    def test_equivalent_directory_spellings_skip_installation_copy(self):
        alias = self.repo / 'dist alias'
        alias.symlink_to(self.repo / 'dist', target_is_directory=True)
        self.repo.joinpath('unrelated cdpath/dist').mkdir(parents=True)
        for directory in ('dist/', './dist/../dist//', 'dist alias', str(alias) + '/'):
            with self.subTest(directory=directory):
                self.assert_success(self.run_script('run', directory,
                                    CDPATH=str(self.repo / 'unrelated cdpath')))
                self.assertEqual(self.events('ditto'), [])
                self.assertEqual(self.events('open')[-1]['args'], ['-n', str(self.app)])
                self.assertEqual(self.events('lsregister')[-1]['args'], ['-f', str(self.app)])

    def test_debug_and_verify_can_use_the_bundle_in_place(self):
        for mode in ('--debug', 'debug', 'verify', '--verify'):
            with self.subTest(mode=mode):
                self.assert_success(self.run_script(mode, 'dist'))
                self.assertEqual(self.events('ditto'), [])
                launch = self.events('lldb') if 'debug' in mode else self.events('open')
                self.assertTrue(launch)
                self.assertEqual(Path(launch[-1]['args'][-1]).resolve(),
                                 self.app / 'Contents/MacOS/Eligo' if 'debug' in mode else self.app)

    def test_symlink_to_source_bundle_is_kept_and_used_in_place(self):
        parent = self.work / 'bundle alias directory'
        parent.mkdir()
        link = parent / 'Eligo.app'
        link.symlink_to(self.app, target_is_directory=True)
        self.assert_success(self.run_script('debug', parent))
        self.assertTrue(link.is_symlink())
        self.assertEqual(self.events('ditto'), [])
        self.assertEqual(self.events('lldb')[-1]['args'], ['--', str(self.app / 'Contents/MacOS/Eligo')])

    def test_default_installation_replaces_a_distinct_bundle_and_verifies_it(self):
        installed = self.applications / 'Eligo.app'
        installed.mkdir()
        installed.joinpath('old-installation').write_text('old')
        self.assert_success(self.run_script())
        self.assertEqual(self.events('ditto')[-1]['args'], [str(self.app), str(installed)])
        self.assertFalse(installed.joinpath('old-installation').exists())
        self.assertEqual(installed.joinpath('Contents/MacOS/Eligo').read_bytes(), b'fixture executable')
        self.assertTrue(self.app.exists())

    def test_missing_installation_parents_are_created_after_path_validation(self):
        destination = self.work / 'new parent' / 'new applications'
        self.assert_success(self.run_script('run', destination))
        self.assertEqual(destination.joinpath('Eligo.app/Contents/MacOS/Eligo').read_bytes(),
                         b'fixture executable')
        self.assertEqual(self.events('ditto')[-1]['args'], [str(self.app), str(destination / 'Eligo.app')])

    def test_parent_symlink_and_dot_dot_use_physical_directory_semantics(self):
        physical = self.work / 'physical parent'
        physical.joinpath('child').mkdir(parents=True)
        alias = self.repo / 'parent alias'
        alias.symlink_to(physical / 'child', target_is_directory=True)
        self.assert_success(self.run_script('run', str(alias) + '/../new applications'))
        self.assertEqual(physical.joinpath('new applications/Eligo.app/Contents/MacOS/Eligo').read_bytes(),
                         b'fixture executable')
        self.assertFalse(self.repo.joinpath('new applications').exists())

    def test_ancestor_target_is_rejected_without_deleting_the_source(self):
        ancestor = self.work / 'Eligo.app'
        ancestor.mkdir()
        self.repo = self.repo.rename(ancestor / 'checkout with spaces')
        self.assert_path_failure_preserves_source(self.run_script('run', self.work),
                                                 'contains the built bundle')
        self.assertTrue(self.repo.joinpath('script/build_and_run.sh').exists())

    def test_case_variant_nested_target_is_rejected_without_changing_source(self):
        if not self.work.joinpath('BUILD-BIN').is_dir():
            self.skipTest('Requires a case-insensitive filesystem')
        directory = self.repo / 'DIST/ELIGO.APP/new installation'
        self.assert_path_failure_preserves_source(self.run_script('run', directory),
                                                 'inside the built bundle')
        self.assertFalse(directory.exists())

    def test_case_variant_ancestor_target_is_rejected_without_deleting_source(self):
        if not self.work.joinpath('BUILD-BIN').is_dir():
            self.skipTest('Requires a case-insensitive filesystem')
        ancestor = self.work / 'ELIGO.APP'
        ancestor.mkdir()
        self.repo = self.repo.rename(ancestor / 'checkout with spaces')
        self.assert_path_failure_preserves_source(self.run_script('run', self.work),
                                                 'contains the built bundle')
        self.assertTrue(self.repo.joinpath('script/build_and_run.sh').exists())

    def assert_path_failure_preserves_source(self, result, reason):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason, result.stderr)
        self.assertEqual(self.app.joinpath('Contents/MacOS/Eligo').read_bytes(), b'fixture executable')
        self.assertEqual(self.events('ditto'), [])
        self.assertEqual(self.events('open'), [])
        self.assertEqual(self.events('lldb'), [])

    def test_non_directory_installation_parent_preserves_source(self):
        invalid = self.work / 'not a directory'
        invalid.write_text('keep this file')
        self.assert_path_failure_preserves_source(self.run_script('run', invalid), 'not a directory')
        self.assertEqual(invalid.read_text(), 'keep this file')

    def test_dangling_installation_parent_preserves_source_and_symlink(self):
        invalid = self.work / 'dangling directory'
        invalid.symlink_to(self.work / 'does not exist', target_is_directory=True)
        self.assert_path_failure_preserves_source(self.run_script('debug', invalid), 'dangling symlink')
        self.assertTrue(invalid.is_symlink())
        self.assert_debug_entitlements_cleaned()

    def test_dangling_installation_bundle_preserves_source_and_symlink(self):
        invalid = self.applications / 'Eligo.app'
        invalid.symlink_to(self.work / 'does not exist', target_is_directory=True)
        self.assert_path_failure_preserves_source(self.run_script(), 'dangling symlink')
        self.assertTrue(invalid.is_symlink())

    def test_missing_directory_traversal_fails_without_creating_anything(self):
        self.assert_path_failure_preserves_source(
            self.run_script('run', 'missing/../dist'), 'traversal through a missing directory')
        self.assertFalse(self.repo.joinpath('missing').exists())

    def test_unknown_mode_is_rejected_before_process_build_or_install_commands(self):
        result = self.run_script('--verfiy')
        self.assertEqual(result.returncode, 2)
        self.assertIn('usage:', result.stderr)
        self.assertEqual(self.events(), [])
        self.assertFalse(self.repo.joinpath('dist').exists())
        self.assertFalse(self.repo.joinpath('.build-home').exists())

    def test_invalid_build_number_is_rejected_before_side_effects(self):
        result = self.run_script('run', LOCAL_BUILD_NUMBER='not-a-number')
        self.assertEqual(result.returncode, 2)
        self.assertIn('positive integer', result.stderr)
        self.assertEqual(self.events(), [])
        self.assertFalse(self.app.exists())

    def test_signing_or_source_verification_failure_stops_before_installation(self):
        for failure in ('codesign', 'verify'):
            with self.subTest(failure=failure):
                result = self.run_script('debug', BUILD_SCRIPT_TEST_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.events('ditto'), [])
                self.assertEqual(self.events('lldb'), [])
                self.assert_debug_entitlements_cleaned()

    def test_installation_verification_failure_stops_before_registration_and_debugging(self):
        result = self.run_script('debug', BUILD_SCRIPT_TEST_FAIL='verify-installed')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events('lsregister'), [])
        self.assertEqual(self.events('lldb'), [])
        self.assert_debug_entitlements_cleaned()

    def test_debugger_failure_still_cleans_temporary_entitlements(self):
        result = self.run_script('debug', BUILD_SCRIPT_TEST_FAIL='lldb')
        self.assertNotEqual(result.returncode, 0)
        self.assert_debug_entitlements_cleaned()
        self.assertEqual(self.events('open'), [])

    def test_native_signatures_keep_debug_permission_out_of_run_verify_and_release(self):
        # Sign a disposable Mach-O executable; it is never executed or installed.
        binary = self.work / 'build-bin/Eligo'
        compiled = subprocess.run(['/usr/bin/clang', '-x', 'c', '-', '-o', str(binary)],
                                  input='int main(void) { return 0; }\n',
                                  capture_output=True, text=True)
        self.assert_success(compiled)
        canonical = self.repo.joinpath('Resources/Eligo.entitlements').read_bytes()
        for mode, script, bundle in (
            ('--debug', 'build_and_run.sh', self.applications / 'Eligo.app'),
            ('run', 'build_and_run.sh', self.applications / 'Eligo.app'),
            ('verify', 'build_and_run.sh', self.applications / 'Eligo.app'),
            ('--adhoc', 'release.sh', self.repo / 'dist/release/Eligo.app'),
        ):
            with self.subTest(mode=mode):
                self.assert_success(self.run_script(mode, script=script, BUILD_SCRIPT_TEST_NATIVE_CODESIGN='1'))
                details = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(bundle)],
                                         capture_output=True)
                self.assertEqual(details.returncode, 0, details.stderr.decode())
                entitlements = plistlib.loads(details.stdout) if details.stdout.strip() else {}
                if mode == '--debug':
                    self.assertIs(entitlements.get('com.apple.security.get-task-allow'), True)
                else:
                    self.assertNotIn('com.apple.security.get-task-allow', entitlements)
                self.assertEqual(self.repo.joinpath('Resources/Eligo.entitlements').read_bytes(), canonical)
                self.assert_debug_entitlements_cleaned()


if __name__ == '__main__':
    unittest.main(verbosity=2)
