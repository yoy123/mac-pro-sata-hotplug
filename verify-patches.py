#!/usr/bin/env python3
"""Read-only check of OpenCore AHCI patches against the installed x86_64 driver."""
import argparse
import base64
import hashlib
import pathlib
import plistlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
DRIVER = pathlib.Path('/System/Library/Extensions/AppleAHCIPort.kext/Contents/MacOS/AppleAHCIPort')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=pathlib.Path, nargs='?', default=ROOT / 'config-sample.plist')
    parser.add_argument('--driver', type=pathlib.Path, default=DRIVER)
    args = parser.parse_args()
    sample = plistlib.loads((ROOT / 'config-sample.plist').read_bytes())
    config = plistlib.loads(args.config.read_bytes())
    patches = config['Kernel']['Patch'] if 'Kernel' in config else config['Kernel-Patch']
    acpi = config['ACPI']['Add'] if 'ACPI' in config else config['ACPI-Add']
    ok = True
    with tempfile.TemporaryDirectory() as td:
        thin = pathlib.Path(td) / 'AppleAHCIPort'
        archs = subprocess.check_output(['lipo', '-archs', str(args.driver)], text=True).split()
        if 'x86_64' not in archs:
            parser.error('Driver has no x86_64 slice')
        if archs == ['x86_64']:
            binary = args.driver.read_bytes()
        else:
            subprocess.run(['lipo', str(args.driver), '-thin', 'x86_64', '-output', str(thin)], check=True)
            binary = thin.read_bytes()
    for expected in sample['Kernel-Patch']:
        matching = [p for p in patches if p.get('Comment') == expected['Comment'] and p.get('Identifier') == expected['Identifier']]
        if len(matching) != 1:
            print('FAIL:', expected['Comment'], 'expected exactly one entry'); ok = False; continue
        p = matching[0]
        count = binary.count(expected['Find'])
        fields_ok = all(p.get(k) == expected[k] for k in ('Find', 'Replace', 'Enabled', 'Count', 'Arch', 'Base', 'Limit', 'Mask', 'ReplaceMask', 'Skip', 'MinKernel', 'MaxKernel'))
        if any(p.get(k) == base64.b64encode(expected[k]) for k in ('Find', 'Replace')):
            print('FAIL: double-encoded Base64 detected; use raw bytes in plist data values.')
        valid = fields_ok and count == 1
        print('PASS:' if valid else 'FAIL:', expected['Comment'], 'x86_64 matches:', count, 'config fields correct:', fields_ok)
        ok &= valid
    entries = [a for a in acpi if a.get('Path') == 'SSDT-COMRESET.aml' and a.get('Enabled')]
    acpi_ok = len(entries) == 1
    if 'ACPI' in config:
        installed = args.config.parent / 'ACPI/SSDT-COMRESET.aml'
        acpi_ok &= installed.is_file() and installed.read_bytes() == (ROOT / 'ACPI/SSDT-COMRESET.aml').read_bytes()
    print('PASS:' if acpi_ok else 'FAIL:', 'SSDT entry and installed AML (if full config)')
    ok &= acpi_ok
    print('Driver x86_64 SHA256:', hashlib.sha256(binary).hexdigest())
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
