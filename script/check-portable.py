#!/usr/bin/env python3
"""Check script syntax and resource formats without running macOS tools."""

import json
from pathlib import Path
import plistlib
import subprocess


ROOT = Path(__file__).resolve().parent.parent


def main():
    scripts = ROOT / 'script'
    resources = ROOT / 'Resources'
    shell_files = sorted([*scripts.rglob('*.sh'), *scripts.rglob('*.env')])
    python_files = sorted(scripts.rglob('*.py'))
    plist_files = sorted([*resources.rglob('*.plist'), *resources.rglob('*.entitlements')])
    json_files = sorted(resources.rglob('*.json'))

    for path in shell_files:
        print(f'Bash syntax: {path.relative_to(ROOT)}', flush=True)
        subprocess.run(['bash', '-n', str(path)], check=True)
    for path in python_files:
        print(f'Python syntax: {path.relative_to(ROOT)}', flush=True)
        compile(path.read_bytes(), str(path), 'exec', dont_inherit=True)
    for path in plist_files:
        print(f'Property list: {path.relative_to(ROOT)}', flush=True)
        plistlib.loads(path.read_bytes())
    for path in json_files:
        print(f'JSON: {path.relative_to(ROOT)}', flush=True)
        json.loads(path.read_bytes())

    print(f'Passed: {len(shell_files)} Bash, {len(python_files)} Python, '
          f'{len(plist_files)} plist and {len(json_files)} JSON files. '
          'Syntax/format checks only; macOS build and behavioral tests run separately.')


if __name__ == '__main__':
    main()
