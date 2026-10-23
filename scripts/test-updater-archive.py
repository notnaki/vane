#!/usr/bin/env python3
"""Adversarial fixtures against the exact production ZIP extractor; no app launches."""
import argparse
import io
import os
import pathlib
import plistlib
import stat
import struct
import subprocess
import tempfile
import zipfile
import warnings

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--signed-app", type=pathlib.Path, help="Read-only round-trip of an existing signed and stapled app; never launches it")
arguments = parser.parse_args()


class StreamingBuffer(io.BytesIO):
    def seek(self, *_):
        raise OSError("non-seekable fixture")


def archive(entries, compression=zipfile.ZIP_DEFLATED, streaming=False):
    stream = StreamingBuffer() if streaming else io.BytesIO()
    with zipfile.ZipFile(stream, 'w', compression=compression) as output:
        for name, body, mode in entries:
            entry = zipfile.ZipInfo(name)
            entry.create_system = 3
            entry.external_attr = mode << 16
            entry.compress_type = compression
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', UserWarning)
                output.writestr(entry, body)
    return bytearray(stream.getvalue())


def patch(data, signature, offset, fmt, value):
    result = bytearray(data)
    struct.pack_into(fmt, result, result.index(signature) + offset, value)
    return result


with tempfile.TemporaryDirectory(prefix='vane-update-archive-') as temporary:
    root = pathlib.Path(temporary)
    binary = root / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(ROOT / 'Sources/Vane/UpdateArchive.swift'),
                    str(ROOT / 'Tests/UpdaterArchive/main.swift'), '-lz', '-o', str(binary)], check=True)
    good = archive([('Vane.app/', b'', stat.S_IFDIR | 0o755),
                    ('Vane.app/Contents/', b'', stat.S_IFDIR | 0o755),
                    ('Vane.app/Contents/payload', b'correct payload', stat.S_IFREG | 0o755)])
    many = archive([(f'Vane.app/f{i}', b'x', stat.S_IFREG | 0o644) for i in range(3)])
    bomb = archive([('Vane.app/payload', b'x' * 10000, stat.S_IFREG | 0o644)])
    two_files = archive([('Vane.app/a', b'x' * 60, stat.S_IFREG | 0o644),
                         ('Vane.app/b', b'y' * 60, stat.S_IFREG | 0o644)])
    metadata = bytes.fromhex('0005160700020000') + b'\0' * 18
    cases = [('metadata accepted', archive([('Vane.app/._payload', metadata, stat.S_IFREG | 0o644)]), '', True),
             ('metadata not materialized', archive([('Vane.app/._payload', metadata, stat.S_IFREG | 0o644)]), '', True),
             ('metadata invalid', archive([('Vane.app/._payload', b'not metadata', stat.S_IFREG | 0o644)]), '', False),
             ('empty deflated file', archive([('Vane.app/empty', b'', stat.S_IFREG | 0o644)]), '', True),
             ('existing destination preserved', good, 'existing', False),
             ('encrypted flag', patch(patch(good, b'PK\x01\x02', 8, '<H', 1), b'PK\x03\x04', 6, '<H', 1), '', False),
             ('version mismatch', patch(good, b'PK\x03\x04', 4, '<H', 10), '', False),
             ('overlapping local records', patch(many, b'PK\x01\x02', 42, '<I', 1), '', False),
             ('normal deflate', good, '', True),
             ('normal stored', archive([('Vane.app/payload', b'hello', stat.S_IFREG | 0o644)], zipfile.ZIP_STORED), '', True),
             ('data descriptors', archive([('Vane.app/data', b'descriptor payload', stat.S_IFREG | 0o644)], streaming=True), '', True),
             ('compressed budget', good, 'compressed', False),
             ('runtime deadline', archive([('Vane.app/large', b'x' * (30 * 1024 * 1024), stat.S_IFREG | 0o644)]), 'runtime', False),
             ('empty', b'', '', False), ('truncated', good[:-8], '', False),
             ('file budget', bomb, 'file', False), ('total budget', two_files, 'total', False),
             ('entry budget', many, 'entries', False),
             ('implicit directory budget', archive([('Vane.app/a/b', b'x', stat.S_IFREG | 0o644)]), 'entries', False), ('path budget', good, 'path', False),
             ('depth budget', good, 'depth', False), ('deadline', good, 'deadline', False),
             ('dishonest expanded size', patch(patch(bomb, b'PK\x03\x04', 22, '<I', 1), b'PK\x01\x02', 24, '<I', 1), '', False),
             ('local-central name mismatch', good.replace(b'Vane.app/Contents/payload', b'Vane.app/Contents/evilpay', 1), '', False),
             ('CRC mismatch', patch(patch(bomb, b'PK\x01\x02', 16, '<I', 1), b'PK\x03\x04', 14, '<I', 1), '', False),
             ('multidisk', patch(good, b'PK\x05\x06', 4, '<H', 1), '', False),
             ('ZIP64 sentinel', patch(good, b'PK\x05\x06', 10, '<H', 65535), '', False),
             ('unsupported codec', archive([('Vane.app/x', b'x', stat.S_IFREG | 0o644)], zipfile.ZIP_LZMA), '', False)]
    for name in ['../escape', '/tmp/escape', 'Vane.app/../escape', 'Vane.app//x', 'Vane.app/./x', 'Vane.app/x\\y', 'Vane.app/..']:
        cases.append((f'unsafe path {name}', archive([(name, b'x', stat.S_IFREG | 0o644)]), '', False))
    for label, entries in [
        ('symlink', [('Vane.app/link', b'../../escape', stat.S_IFLNK | 0o777)]),
        ('fifo', [('Vane.app/fifo', b'', stat.S_IFIFO | 0o644)]),
        ('duplicate', [('Vane.app/a', b'a', stat.S_IFREG | 0o644), ('Vane.app/a', b'b', stat.S_IFREG | 0o644)]),
        ('case collision', [('Vane.app/A', b'a', stat.S_IFREG | 0o644), ('Vane.app/a', b'b', stat.S_IFREG | 0o644)]),
        ('unicode collision', [('Vane.app/é', b'a', stat.S_IFREG | 0o644), ('Vane.app/e\u0301', b'b', stat.S_IFREG | 0o644)]),
        ('unicode ancestor collision', [('Vane.app/é/a', b'a', stat.S_IFREG | 0o644), ('Vane.app/e\u0301/b', b'b', stat.S_IFREG | 0o644)]),
        ('set-id executable sanitized', [('Vane.app/bin', b'x', stat.S_IFREG | 0o6755)]),
        ('file ancestor', [('Vane.app/a', b'a', stat.S_IFREG | 0o644), ('Vane.app/a/b', b'b', stat.S_IFREG | 0o644)])]:
        cases.append((label, archive(entries), '', label == 'set-id executable sanitized'))
    failures = []
    for index, (name, data, limit, accepted) in enumerate(cases):
        path = root / f'fixture-{index}.zip'
        path.write_bytes(data)
        destination = root / f'extract-{index}'
        result = subprocess.run([str(binary), str(path), str(destination), limit], text=True, capture_output=True, timeout=10)
        ok = result.returncode == (0 if accepted else 1)
        if accepted and name == 'normal deflate':
            payload = destination / 'Vane.app/Contents/payload'
            ok = ok and payload.read_bytes() == b'correct payload' and bool(payload.stat().st_mode & stat.S_IXUSR)
        if accepted and name == 'metadata not materialized':
            ok = ok and not (destination / 'Vane.app/._payload').exists()
        if accepted and name == 'set-id executable sanitized':
            mode = (destination / 'Vane.app/bin').stat().st_mode
            ok = ok and bool(mode & stat.S_IXUSR) and not bool(mode & (stat.S_ISUID | stat.S_ISGID))
        print(f'{"PASS" if ok else "FAIL"}: {name}: {result.stdout.strip()} {result.stderr.strip()}')
        if not ok:
            failures.append(name)
    # Production archives come from ditto. Extended metadata must not make a valid payload fail.
    app = root / 'ditto-source/Vane.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(app / 'Contents/MacOS/Vane')],
                   input='int main(void) { return 0; }\n', text=True, check=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.github.notnaki.vane.archive-fixture',
        'CFBundleExecutable': 'Vane', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0.0'}))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    os.chmod(app / 'Contents/MacOS/Vane', 0o755)
    subprocess.run(['xattr', '-w', 'com.vane.fixture', 'metadata', str(app)], check=True)
    packaged = root / 'ditto.zip'
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(packaged)], check=True)
    result = subprocess.run([str(binary), str(packaged), str(root / 'ditto-output')], text=True, capture_output=True, timeout=10)
    ok = result.returncode == 0 and (root / 'ditto-output/Vane.app/Contents/MacOS/Vane').read_bytes() == (app / 'Contents/MacOS/Vane').read_bytes()
    print(f'{"PASS" if ok else "FAIL"}: actual ditto archive: {result.stdout.strip()} {result.stderr.strip()}')
    if ok:
        verified = subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=4', str(root / 'ditto-output/Vane.app')],
                                  capture_output=True, text=True)
        ok = verified.returncode == 0
        if not ok:
            with zipfile.ZipFile(packaged) as packaged_zip:
                print('archive entries:', packaged_zip.namelist())
            print('source verification:', subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=4', str(app)], capture_output=True, text=True).stderr)
        print(f'{"PASS" if ok else "FAIL"}: signed bundle survives production extraction: {verified.stderr.strip()}')
    if not ok:
        failures.append('ditto/signature')
    if arguments.signed_app:
        signed_archive = root / 'signed-release.zip'
        subprocess.run(['ditto', '-c', '-k', '--keepParent', str(arguments.signed_app), str(signed_archive)], check=True)
        signed_destination = root / 'signed-release'
        subprocess.run([str(binary), str(signed_archive), str(signed_destination)], check=True)
        extracted_app = signed_destination / arguments.signed_app.name
        for command in [['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(extracted_app)],
                        ['spctl', '--assess', '--ignore-cache', '--type', 'execute', '--verbose=4', str(extracted_app)],
                        ['xcrun', 'stapler', 'validate', str(extracted_app)]]:
            verified = subprocess.run(command, capture_output=True, text=True)
            print(f'{"PASS" if verified.returncode == 0 else "FAIL"}: signed release {command[0]}: {verified.stdout.strip()} {verified.stderr.strip()}')
            if verified.returncode != 0:
                failures.append(command[0])
    if failures:
        raise SystemExit(f'Failed: {failures}')
