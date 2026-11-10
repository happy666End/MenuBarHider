#!/bin/bash
set -euo pipefail
exec python3 - "${1:?provide the built MenuBarHider.app path}" "${2:-/Applications/MenuBarHider.app}" <<'PY'
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


def check_process():
    result = subprocess.run(['pgrep', '-x', 'MenuBarHider'], capture_output=True)
    if result.returncode == 0:
        raise RuntimeError('Quit MenuBarHider normally before installing; it may own hidden menu bar settings.')
    if result.returncode != 1:
        raise RuntimeError('Could not confirm that MenuBarHider is stopped.')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('The recovery journal contains duplicate keys.')
        result[key] = value
    return result


def check_journal(support):
    try:
        descriptor = os.open(support / 'native-visibility.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        if error.errno == errno.ENOENT:
            return
        raise
    with os.fdopen(descriptor, 'r', encoding='utf-8') as journal:
        if not stat.S_ISREG(os.fstat(journal.fileno()).st_mode):
            raise ValueError('The recovery journal is not a regular file.')
        record = json.load(journal, object_pairs_hook=unique_object)
    if (not isinstance(record, dict) or type(record.get('version')) is not int or record['version'] != 1
            or not isinstance(record.get('bundleIDs'), list)
            or not all(isinstance(item, str) for item in record['bundleIDs'])):
        raise ValueError('The recovery journal has an unsupported format.')
    if record['bundleIDs']:
        raise RuntimeError('Pending menu bar recovery: reopen MenuBarHider, restore visibility, and quit normally first.')


def acquire_lock(support):
    support.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = os.open(support, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        descriptor = os.open('instance.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                             0o600, dir_fd=directory)
    finally:
        os.close(directory)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_nlink != 1):
            raise ValueError('The application instance lock is not a private regular file.')
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def executable_hash(app):
    with (app / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    if info.get('CFBundleIdentifier') != 'com.sava.MenuBarHider' or info.get('CFBundleExecutable') != 'MenuBarHider':
        raise ValueError(f'Unexpected application bundle: {app}')
    descriptor = os.open(app / 'Contents/MacOS/MenuBarHider', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as executable:
        if not stat.S_ISREG(os.fstat(executable.fileno()).st_mode):
            raise ValueError(f'The app executable is not a regular file: {app}')
        digest = hashlib.sha256()
        for block in iter(lambda: executable.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def verify(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def installed_identity(destination):
    try:
        metadata = destination.lstat()
    except OSError as error:
        if error.errno == errno.ENOENT:
            return None
        raise
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f'The installation destination is not a regular app directory: {destination}')
    return metadata.st_dev, metadata.st_ino


def rename(source, destination, flags):
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    function = library.renamex_np
    function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(os.fsencode(source), os.fsencode(destination), flags) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def interrupted(signum, frame):
    raise InterruptedError(f'Installation interrupted by signal {signum}.')


def main():
    source = Path(os.path.abspath(sys.argv[1]))
    destination = Path(os.path.abspath(sys.argv[2]))
    support = Path.home() / 'Library/Application Support/MenuBarHider'
    lock = None
    stage = None
    backup = None
    exchange = None
    complete = False
    try:
        check_process()
        lock = acquire_lock(support)
        check_journal(support)
        if source == destination or source.is_symlink():
            raise ValueError('The build must be a separate application directory, not a symlink.')
        verify(source)
        source_hash = executable_hash(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        parent = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        os.close(parent)
        identity = installed_identity(destination)
        stage = Path(tempfile.mkdtemp(prefix='.MenuBarHider-install-', dir=destination.parent))
        candidate = stage / 'MenuBarHider.app'
        subprocess.run(['ditto', str(source), str(candidate)], check=True)
        verify(candidate)
        if executable_hash(candidate) != source_hash:
            raise ValueError('The staged executable does not match the verified build.')
        old_hash = None
        if identity is not None:
            old_hash = executable_hash(destination)
            backup = Path(tempfile.mkdtemp(prefix='.MenuBarHider-backup-', dir=destination.parent))
            print(f'Backup directory: {backup}', flush=True)
            subprocess.run(['ditto', str(destination), str(backup / 'MenuBarHider.app')], check=True)
            if executable_hash(backup / 'MenuBarHider.app') != old_hash or executable_hash(destination) != old_hash:
                raise ValueError('The backup executable does not match the installed app.')
            (backup / 'SHA256SUMS').write_text(
                f'{old_hash}  MenuBarHider.app/Contents/MacOS/MenuBarHider\n', encoding='utf-8')
        if installed_identity(destination) != identity:
            raise RuntimeError('The installed app changed while preparing the replacement.')
        if old_hash is not None and executable_hash(destination) != old_hash:
            raise RuntimeError('The installed executable changed while preparing the replacement.')
        check_process()
        check_journal(support)
        # Record the completed exchange before an interrupt can trigger rollback.
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
        try:
            # Darwin RENAME_SWAP exchanges directories; RENAME_EXCL protects a first install.
            rename(candidate, destination, 0x00000002 if identity is not None else 0x00000004)
            exchange = 'swap' if identity is not None else 'first'
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        verify(destination)
        if executable_hash(destination) != source_hash:
            raise ValueError('The installed executable does not match the verified build.')
        complete = True
        print(f'Installed: {destination}. Open it when ready.')
        return 0
    except BaseException as error:
        print(f'Installation stopped: {error}', file=sys.stderr)
        if exchange is not None:
            try:
                if exchange == 'swap':
                    rename(candidate, destination, 0x00000002)
                else:
                    rename(destination, candidate, 0x00000004)
                exchange = None
                print('The previous installation state was restored.', file=sys.stderr)
            except BaseException as rollback_error:
                print(f'Automatic rollback failed: {rollback_error}. Preserve {stage} and {backup}.', file=sys.stderr)
        return 1
    finally:
        if stage is not None and (exchange is None or complete):
            try:
                shutil.rmtree(stage)
            except OSError as error:
                print(f'Could not remove temporary installation directory {stage}: {error}', file=sys.stderr)
        if lock is not None:
            os.close(lock)


for watched_signal in [signal.SIGTERM, signal.SIGHUP]:
    signal.signal(watched_signal, interrupted)
sys.exit(main())
PY
