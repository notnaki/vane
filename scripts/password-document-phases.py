#!/usr/bin/env python3
"""Bounded private phase files, independent of SwiftPM's test-output stream."""
import json
import math
import os
from pathlib import Path
import re
import stat
import time

MAX_EVENTS = 256
MAX_BYTES = 16384


def private_directory(path):
    value = os.fspath(path)
    if not value.startswith('/') or value != os.path.normpath(value) or value == '/':
        raise ValueError('phase directory must be canonical and absolute')
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in value.split('/')[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        info = os.fstat(descriptor)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('phase directory must have its current owner and mode0700')
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def read_private(descriptor, name):
    if '/' in name or name in ('.', '..'): raise ValueError('invalid phase file name')
    child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=descriptor)
    try:
        info = os.fstat(child)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or not 0 < info.st_size <= MAX_BYTES):
            raise ValueError('phase file must be a bounded current-owner regular file with mode0600')
        raw = os.read(child, MAX_BYTES + 1)
        if len(raw) > MAX_BYTES: raise ValueError('phase file exceeded its read bound')
        return json.loads(raw)
    finally:
        os.close(child)


def publish_private(directory, name, value):
    """Publish a complete0600 context without following or replacing any file."""
    import uuid
    temporary = '.phase-' + uuid.uuid4().hex
    raw = (json.dumps(value, sort_keys=True) + '\n').encode()
    if len(raw) > MAX_BYTES: raise ValueError('phase context too large')
    descriptor = private_directory(directory)
    try:
        child = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=descriptor)
        try:
            os.fchmod(child, 0o600)
            with os.fdopen(child, 'wb', closefd=False) as stream: stream.write(raw)
        finally: os.close(child)
        os.link(temporary, name, src_dir_fd=descriptor, dst_dir_fd=descriptor, follow_symlinks=False)
    finally:
        try: os.unlink(temporary, dir_fd=descriptor)
        except FileNotFoundError: pass
        os.close(descriptor)


def matching_host(claim, host):
    return (isinstance(claim, dict) and isinstance(host, dict)
            and all(type(claim.get(key)) is int and claim[key] > 0 and claim[key] == host.get(key) for key in ('pid', 'start'))
            and isinstance(claim.get('path'), str) and os.path.isabs(claim['path'])
            and isinstance(host.get('path'), str)
            and os.path.realpath(claim['path']) == os.path.realpath(host['path']))


class PhaseReader:
    def __init__(self, directory, token, runner, collector):
        self.directory, self.token, self.runner, self.collector = Path(directory), token, runner, collector
        self.events, self.errors = [], []
        self.descriptor, self.context, self.sequence = None, None, 0

    def poll(self):
        if self.errors: return []
        fresh = []
        try:
            if not re.fullmatch('[a-f0-9]{32}', self.token): raise ValueError('invalid phase channel token')
            if self.descriptor is None: self.descriptor = private_directory(self.directory)
            names = os.listdir(self.descriptor)
            if len(names) > MAX_EVENTS + 4: raise ValueError('phase channel exceeded file-count bound')
            if any(name not in ('context.json', 'samplers-ready.json') and not re.fullmatch(r'event-[0-9]{4}\.json', name)
                   and not name.startswith('.phase-') for name in names):
                raise ValueError('unexpected phase channel entry')
            if 'context.json' not in names: return []
            if self.context is None:
                context = read_private(self.descriptor, 'context.json')
                if (context.get('schema') != 1 or context.get('channelToken') != self.token
                        or not isinstance(context.get('nativeToken'), str)
                        or not re.fullmatch('[a-f0-9]{32}', context['nativeToken'])):
                    raise ValueError('phase context token/schema mismatch')
                native = private_directory(context['nativeDirectory'])
                os.close(native)
                self.runner.load_records(context['nativeDirectory'], context['nativeToken'])
                self.context = context
                self.collector.manifest = (Path(context['nativeDirectory']), context['nativeToken'])
            events = sorted(name for name in names if name.startswith('event-'))
            if len(events) > MAX_EVENTS: raise ValueError('phase record-count bound exceeded')
            for name in events:
                sequence = int(name[6:10])
                if sequence <= self.sequence: continue
                if sequence != self.sequence + 1: raise ValueError('phase sequence gap')
                value = read_private(self.descriptor, name)
                if (value.get('schema') != 1 or value.get('channelToken') != self.token
                        or value.get('nativeToken') != self.context['nativeToken']
                        or type(value.get('sequence')) is not int or value['sequence'] != sequence):
                    raise ValueError('phase record token/schema/sequence mismatch')
                hosts = self.runner.load_records(self.context['nativeDirectory'], self.context['nativeToken'])
                host = value.get('host')
                if not any(matching_host(host, row['host']) for row in hosts):
                    raise ValueError('phase producer is not a manifest-owned host launch')
                if (type(value.get('monotonicNs')) is not int or value['monotonicNs'] <= 0
                        or type(value.get('wallSeconds')) not in (int, float) or not math.isfinite(value['wallSeconds'])
                        or not isinstance(value.get('phase'), str) or not re.fullmatch('[a-z][a-z0-9-]{0,63}', value['phase'])
                        or not isinstance(value.get('fields'), dict)):
                    raise ValueError('invalid bounded phase payload')
                receipt = {'source': value, 'receiptMonotonicNs': time.monotonic_ns(),
                           'receiptWallSeconds': time.time(),
                           'hostLiveAtReceipt': matching_host(host, self.runner.process_identity(host['pid']))}
                fields = value['fields']
                now = receipt['receiptMonotonicNs'] / 1e9
                if value['phase'] == 'process':
                    if not matching_host(fields.get('ui'), host): raise ValueError('process receipt UI does not match phase producer')
                    self.collector.line('PASSWORD DOCUMENT PROCESS ' + json.dumps(fields), now=now)
                elif value['phase'] == 'calibration-held':
                    self.collector.calibration_hold(fields.get('token'), value['monotonicNs'])
                elif value['phase'] == 'commit':
                    token = fields.get('token')
                    if not isinstance(token, str) or not 0 < len(token) <= 64: raise ValueError('invalid navigation token')
                    self.collector.line('PASSWORD DOCUMENT COMMIT ' + token, now=now)
                self.sequence = sequence
                self.events.append(receipt)
                fresh.append(receipt)
        except (ValueError, OSError, KeyError, TypeError) as error:
            self.errors.append(str(error))
        return fresh

    def report(self):
        return {'events': self.events, 'errors': self.errors, 'valid': not self.errors and bool(self.events)}

    def close(self):
        if self.descriptor is not None:
            os.close(self.descriptor)
            self.descriptor = None
