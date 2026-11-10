#!/usr/bin/env python3
import fcntl
import hashlib
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[2]
INSTALLER = Path(os.environ.get('INSTALLER_UNDER_TEST', REPO / 'scripts/install.sh'))


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='menubar-install-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'build/MenuBarHider.app'
        self.destination = self.root / 'Applications/MenuBarHider.app'
        self.support = self.root / 'home/Library/Application Support/MenuBarHider'
        self.support.mkdir(parents=True)
        self.journal = self.support / 'native-visibility.json'
        self.make_app(self.source, b'new executable', 'new resource')
        self.make_app(self.destination, b'old executable', 'old resource')
        self.commands = self.root / 'bin'
        self.commands.mkdir()
        python = self.commands / 'python3'
        python.write_text(
            f'#!{sys.executable}\n'
            'import os, pathlib, sys\n'
            'pathlib.Path.home = classmethod(lambda cls: pathlib.Path(os.environ["FIXTURE_ROOT"]) / "home")\n'
            'sys.argv = sys.argv[1:]\n'
            'exec(compile(sys.stdin.read(), "install.sh", "exec"))\n'
        )
        python.chmod(0o755)
        stub = f'#!{sys.executable}\n' + '''from pathlib import Path
import os, shutil, signal, sys, time
root = Path(os.environ['FIXTURE_ROOT'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
source = Path(os.environ['FIXTURE_SOURCE'])
destination = Path(os.environ['FIXTURE_DESTINATION'])
if name in ['pkill', 'kill', 'open']:
    (root/'forbidden-command').write_text(name)
    sys.exit(0)
if name == 'pgrep':
    counter = root/'process-checks'
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if os.environ.get('PROCESS_ERROR'): sys.exit(2)
    running = os.environ.get('APP_RUNNING') or (os.environ.get('LATE_RUNNING') and count >= 2)
    if running: print('99999')
    sys.exit(0 if running else 1)
if name in ['ditto', 'cp']:
    origin, target = Path(args[-2]), Path(args[-1])
    phase = 'stage' if origin == source else 'backup'
    if os.environ.get('FAIL_COPY') == phase:
        target.mkdir(parents=True)
        (target/'partial').write_text('partial copy')
        sys.exit(1)
    shutil.copytree(origin, target)
    if phase == 'backup' and os.environ.get('BAD_BACKUP'):
        (target/'Contents/MacOS/MenuBarHider').write_bytes(b'corrupted backup')
    if phase == 'stage' and os.environ.get('LATE_JOURNAL'):
        journal = root/'home/Library/Application Support/MenuBarHider/native-visibility.json'
        journal.write_text('{"version":1,"bundleIDs":["app.pending"]}')
if name == 'codesign':
    target = Path(args[-1])
    phase = 'source' if target == source else 'installed' if target == destination else 'stage'
    if phase == 'installed' and os.environ.get('HOLD_INSTALLED'):
        (root/'installed-verification-ready').write_text('ready')
        deadline = time.monotonic() + 10
        while not (root/'release-installed-verification').exists():
            if time.monotonic() >= deadline: sys.exit(3)
            time.sleep(0.01)
    if phase == 'installed' and os.environ.get('INTERRUPT_INSTALLED'):
        os.kill(os.getppid(), signal.SIGTERM)
    if os.environ.get('BAD_SIGNATURE') == phase: sys.exit(1)
    if phase == 'installed' and os.environ.get('CORRUPT_INSTALLED'):
        (target/'Contents/MacOS/MenuBarHider').write_bytes(b'corrupted installation')
'''
        for name in ['pgrep', 'codesign', 'ditto', 'cp', 'pkill', 'kill', 'open']:
            command = self.commands / name
            command.write_text(stub)
            command.chmod(0o755)

    @staticmethod
    def make_app(path, executable, resource):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'MenuBarHider',
            'CFBundleIdentifier': 'com.sava.MenuBarHider',
        }))
        (path / 'Contents/MacOS/MenuBarHider').write_bytes(executable)
        (path / 'Contents/resource').write_text(resource)

    def installer_environment(self, **options):
        env = os.environ.copy()
        env.update(PATH=str(self.commands) + ':' + env['PATH'], FIXTURE_ROOT=str(self.root),
                   FIXTURE_SOURCE=str(self.source), FIXTURE_DESTINATION=str(self.destination))
        env.update(options)
        return env

    def install(self, **options):
        env = self.installer_environment(**options)
        result = subprocess.run(['bash', str(INSTALLER), str(self.source), str(self.destination)],
                                cwd=self.root, env=env, text=True, capture_output=True)
        self.assertEqual((self.source / 'Contents/MacOS/MenuBarHider').read_bytes(), b'new executable')
        return result

    def assert_old_preserved(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.destination.is_dir(), result.stderr)
        self.assertTrue((self.destination / 'Contents/MacOS/MenuBarHider').is_file(), result.stderr)
        self.assertEqual((self.destination / 'Contents/MacOS/MenuBarHider').read_bytes(), b'old executable')
        self.assertEqual((self.destination / 'Contents/resource').read_text(), 'old resource')

    def test_never_terminates_or_launches_app(self):
        self.install()
        self.assertFalse((self.root / 'forbidden-command').exists(), 'installer terminated or launched an app')

    def test_running_app_refuses_before_copy(self):
        self.assert_old_preserved(self.install(APP_RUNNING='1'))

    def test_pending_journal_refuses_before_copy(self):
        self.journal.write_text('{"version":1,"bundleIDs":["app.pending"]}')
        self.assert_old_preserved(self.install())

    def test_stage_copy_failure_preserves_installed_app(self):
        self.assert_old_preserved(self.install(FAIL_COPY='stage'))

    def test_malformed_or_unreadable_journal_refuses(self):
        for data in ['not json', '{"version":2,"bundleIDs":[]}', '{"version":1,"bundleIDs":""}',
                     '{"version":true,"bundleIDs":[]}', '{"version":1,"bundleIDs":[3]}',
                     '{"version":1,"bundleIDs":["app.pending"],"bundleIDs":[]}']:
            with self.subTest(data=data):
                self.journal.write_text(data)
                self.assert_old_preserved(self.install())
        self.journal.write_text('{"version":1,"bundleIDs":[]}')
        self.journal.chmod(0)
        try:
            self.assert_old_preserved(self.install())
        finally:
            self.journal.chmod(0o600)

    def test_nonfile_journal_refuses(self):
        self.journal.mkdir()
        self.assert_old_preserved(self.install())
        self.journal.rmdir()
        self.journal.symlink_to(self.support / 'missing.json')
        self.assert_old_preserved(self.install())

    def test_process_check_failure_refuses(self):
        self.assert_old_preserved(self.install(PROCESS_ERROR='1'))

    def test_process_and_journal_are_rechecked_before_swap(self):
        for options in [{'LATE_RUNNING': '1'}, {'LATE_JOURNAL': '1'}]:
            with self.subTest(options=options):
                (self.root / 'process-checks').unlink(missing_ok=True)
                self.journal.unlink(missing_ok=True)
                self.assert_old_preserved(self.install(**options))

    def test_instance_lock_blocks_installation(self):
        with (self.support / 'instance.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assert_old_preserved(self.install())

    def test_backup_copy_or_hash_failure_preserves_installed_app(self):
        for options in [{'FAIL_COPY': 'backup'}, {'BAD_BACKUP': '1'}]:
            with self.subTest(options=options):
                self.assert_old_preserved(self.install(**options))

    def test_source_and_stage_signature_failure_preserves_installed_app(self):
        for phase in ['source', 'stage']:
            with self.subTest(phase=phase):
                self.assert_old_preserved(self.install(BAD_SIGNATURE=phase))

    def test_post_swap_failure_rolls_back_and_preserves_backup(self):
        for options in [{'BAD_SIGNATURE': 'installed'}, {'CORRUPT_INSTALLED': '1'}, {'INTERRUPT_INSTALLED': '1'}]:
            with self.subTest(options=options):
                self.assert_old_preserved(self.install(**options))
                backups = list(self.destination.parent.glob('.MenuBarHider-backup-*/MenuBarHider.app'))
                self.assertTrue(backups)
                self.assertTrue(all((p / 'Contents/MacOS/MenuBarHider').read_bytes() == b'old executable'
                                    for p in backups))

    def test_external_wrapper_sigterm_rolls_back_and_preserves_backup(self):
        ready = self.root / 'installed-verification-ready'
        release = self.root / 'release-installed-verification'
        process = subprocess.Popen(
            ['bash', str(INSTALLER), str(self.source), str(self.destination)],
            cwd=self.root, env=self.installer_environment(HOLD_INSTALLED='1'),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), 'installer did not reach post-swap verification')
            self.assertEqual((self.destination / 'Contents/MacOS/MenuBarHider').read_bytes(), b'new executable')
            process.send_signal(signal.SIGTERM)
        finally:
            release.touch()
            try:
                stdout, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate(timeout=10)
        result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        self.assert_old_preserved(result)
        backups = list(self.destination.parent.glob('.MenuBarHider-backup-*/MenuBarHider.app'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'Contents/MacOS/MenuBarHider').read_bytes(), b'old executable')

    def test_success_preserves_backup_and_matching_hash(self):
        self.journal.write_text('{"version":1,"bundleIDs":[]}')
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / 'Contents/MacOS/MenuBarHider').read_bytes(), b'new executable')
        backups = list(self.destination.parent.glob('.MenuBarHider-backup-*/MenuBarHider.app'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'Contents/MacOS/MenuBarHider').read_bytes(), b'old executable')
        self.assertEqual((backups[0] / 'Contents/resource').read_text(), 'old resource')
        expected = hashlib.sha256(b'old executable').hexdigest()
        self.assertIn(expected, (backups[0].parent / 'SHA256SUMS').read_text())
        self.assertFalse(list(self.destination.parent.glob('.MenuBarHider-install-*')))

    def test_symlink_lock_or_executable_refuses(self):
        target = self.root / 'other-lock'
        target.write_text('unchanged')
        lock = self.support / 'instance.lock'
        lock.symlink_to(target)
        self.assert_old_preserved(self.install())
        self.assertEqual(target.read_text(), 'unchanged')
        lock.unlink()
        executable = self.source / 'Contents/MacOS/MenuBarHider'
        moved = self.root / 'source-executable'
        executable.rename(moved)
        executable.symlink_to(moved)
        self.assert_old_preserved(self.install())

    def test_symlink_destination_refuses(self):
        import shutil
        shutil.rmtree(self.destination)
        self.destination.symlink_to(self.source, target_is_directory=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.destination.is_symlink())

    def test_absent_journal_allows_first_install(self):
        import shutil
        shutil.rmtree(self.destination)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / 'Contents/MacOS/MenuBarHider').read_bytes(), b'new executable')


if __name__ == '__main__':
    unittest.main()
