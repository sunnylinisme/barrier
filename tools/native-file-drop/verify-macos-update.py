#!/usr/bin/env python3
"""Check signed update identity without launching either app or changing privacy grants.

Usage: python3 verify-macos-update.py OLD_APP NEW_APP
This checks code identity compatibility, not a real macOS privacy-permission upgrade.
"""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def codesign(*arguments):
    result = subprocess.run(['/usr/bin/codesign', *arguments], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ValueError(result.stdout.strip() or 'codesign failed')
    return result.stdout


def inventory(app):
    if not app.is_dir():
        raise ValueError(f'App directory does not exist: {app}')
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    executable = info.get('CFBundleExecutable')
    if (not isinstance(executable, str) or not executable or
            Path(executable).name != executable or executable in ('.', '..')):
        raise ValueError(f'Invalid CFBundleExecutable: {app}')
    if not (app / 'Contents/MacOS' / executable).is_file():
        raise ValueError(f'Missing app executable: {app}')
    helpers = app / 'Contents/Helpers'
    if not helpers.is_dir() or not any(helpers.iterdir()):
        raise ValueError(f'Missing bundled helpers: {app}')
    entries = {'.': app}
    for directory in (helpers, app / 'Contents/Frameworks'):
        if directory.is_symlink():
            raise ValueError(f'Unexpected symlink: {directory}')
        for file in directory.rglob('*'):
            if file.is_symlink():
                raise ValueError(f'Unexpected symlink: {file}')
            if file.is_file():
                entries[file.relative_to(app).as_posix()] = file
    return entries


def requirement(path):
    codesign('--verify', '--deep', '--strict', '--all-architectures', str(path))
    details = codesign('--display', '--verbose=2', '-r-', str(path))
    if re.search(r'^Signature=adhoc\s*$', details, re.MULTILINE):
        raise ValueError(f'Ad-hoc signature cannot preserve update identity: {path}')
    match = re.search(r'^\s*(?:#\s*)?designated\s*=>\s*(.+)$', details, re.MULTILINE)
    if not match:
        raise ValueError(f'Missing designated requirement: {path}')
    return match.group(1)


def verify_update(old_app, new_app):
    old, new = inventory(old_app), inventory(new_app)
    if old.keys() != new.keys():
        removed, added = sorted(old.keys() - new.keys()), sorted(new.keys() - old.keys())
        raise ValueError(f'Bundled code inventory changed; removed={removed}, added={added}')
    for name in sorted(old):
        old_requirement, new_requirement = requirement(old[name]), requirement(new[name])
        # With -R, the '=' distinguishes a requirement expression from a file path.
        for target, expected in ((new[name], old_requirement), (old[name], new_requirement)):
            codesign('--verify', '--strict', '--all-architectures', '-R=' + expected, str(target))
        print(f'PASS: {name} has valid signatures and mutually compatible update identity')
    print('PASS: signed update identity is compatible. No app was launched or privacy grant changed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('old_app', type=Path)
    parser.add_argument('new_app', type=Path)
    args = parser.parse_args()
    try:
        verify_update(args.old_app.resolve(), args.new_app.resolve())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
