"""Prospective canonical-boundary proof; delegates unchanged native wrapper behavior."""
import sys
sys.dont_write_bytecode = True
import hashlib
import importlib.util
import json
import os
from pathlib import Path

PROTOCOL = 'native-self-kernel-and-canonical-boundary-v1'
SOURCE = '605caadc1f8c8df99fc833cd7dfd191c702dbd9a'
LEGACY_HEAD = '8ed979de0242990c23ab955b4b866bc78e32f737'
MANIFEST_SHA = 'c77c7af65c2bfd41e5c77b6e8dbd7584a4bcc9268f22cecf7685afec04a4e357'
WRITER_PINS = {
    'Tests/VaneTests/NativeFixtureRetirement.swift': '8975a42cc5104149d1cdc00b28ddea8ff140f80ed2c16611db36dffab9e61196',
    'Tests/VaneTests/NativeFixtureDiagnostics.swift': '4c21c7af56954720336987ae1212d8ff59bb34db28e6917d0801238794ce89a3',
}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(wrapper, arguments, audit_dir, expected_bundle, binding):
    """Only canonical read and verified pre-deletion boundaries are interposed."""
    audit_dir = Path(audit_dir)
    assert audit_dir.is_absolute() and not audit_dir.is_symlink()
    assert audit_dir.resolve() == audit_dir, 'Audit path aliases are not accepted'
    assert audit_dir.is_dir()
    assert audit_dir.stat().st_uid == os.geteuid() and audit_dir.stat().st_mode & 0o777 == 0o700
    assert sha(wrapper.__file__) == binding['canonical_wrapper_sha256']
    assert sha(binding['runtime_binary']) == binding['runtime_binary_sha256']
    for path, digest in binding['native_writer_source_pins'].items():
        assert sha(path) == digest
    expected_bundle = Path(expected_bundle).resolve()
    original_read, original_delete = wrapper.read_private_json, wrapper.shutil.rmtree
    main_code = wrapper.main.__code__
    captured, errors, events, exits = {}, [], [], []
    scope = {}
    proof = {'protocol': PROTOCOL, 'binding': binding, 'external_initial_live_observation_performed': False,
             'identity_basis': 'immutable native writer actual kernel self PID/start/path at registration; canonical and current kernel exit checks',
             'original_delete_calls': 0, 'original_delete_returned': False, 'predelete_verified': False}

    def save(name, value):
        path = audit_dir / name
        path.write_text(json.dumps(value, indent=2) + '\n')
        path.chmod(0o600)

    def main_frame():
        frame = sys._getframe(1)
        while frame is not None:
            if frame.f_code is main_code and frame.f_globals is wrapper.__dict__:
                return frame
            frame = frame.f_back
        raise ValueError('Canonical main frame unavailable')

    def read(path):
        value = original_read(path)  # Original private-read exceptions remain unchanged.
        try:
            frame = main_frame()
            directory, token = Path(frame.f_locals['directory']), frame.f_locals['token']
            assert Path(path).parent == directory
            if scope:
                assert scope == {'directory': str(directory), 'token': token}
            else:
                scope.update(directory=str(directory), token=token)
            name = Path(path).name
            if name == 'contract.json':
                assert value == {'schema': 1, 'token': token}
            elif name == 'cleanup-host.json' or name.startswith('host-'):
                wrapper.validate_record(value, token)
                assert Path(value['host']['testBundlePath']).resolve() == expected_bundle
            else:
                assert name == 'complete.json'
            copied = json.loads(json.dumps(value))
            captured[name] = copied
            filename = f'canonical-read-{len(events):04d}-{name}'
            save(filename, copied)
            events.append({'file': name, 'copy': filename, 'representation': 'exact parsed value returned by unchanged canonical private reader; original byte formatting not claimed'})
        except Exception as error:
            errors.append('canonical read audit: ' + repr(error))
        return value

    def delete(path, *args, **kwargs):
        proof['original_delete_calls'] += 1
        try:
            frame = main_frame()
            assert sys._getframe(1).f_code is main_code
            assert frame.f_locals['verified_cleanup'] is True
            directory, token = Path(frame.f_locals['directory']), frame.f_locals['token']
            assert Path(path) == directory and scope == {'directory': str(directory), 'token': token}
            records = frame.f_locals['records']
            assert records, 'No native primary identity records'
            cleanup = captured['cleanup-host.json']
            wrapper.validate_record(cleanup, token)
            cleanup_identity = (cleanup['host']['pid'], cleanup['host']['start'])
            assert cleanup_identity not in {(r['host']['pid'], r['host']['start']) for r in records}, 'Cleanup must be a distinct fresh native launch'
            for record in [*records, cleanup]:
                wrapper.validate_record(record, token)
                assert Path(record['host']['testBundlePath']).resolve() == expected_bundle
            for record in records:
                host = record['host']
                assert captured[f"host-{host['pid']}-{host['start']}.json"] == record
            completion = captured['complete.json']
            expected_ids = sorted({entry['storeID'].lower() for record in records for entry in record['profiles']})
            assert completion == {'schema': 1, 'token': token, 'retiredIDs': expected_ids}
            for record in [*records, cleanup]:
                host = record['host']; observed = wrapper.process_identity(host['pid'])
                gone = observed is None or observed['start'] != host['start']
                exits.append({'host': host, 'current_kernel_identity': observed, 'verified_exited': gone})
                assert gone, 'Exact native launch remains alive'
            wrapper.require_exited_hosts([*records, cleanup])
            proof.update(predelete_verified=True, canonical_verified_cleanup=True,
                         canonical_status_before_delete=frame.f_locals['status'],
                         primary_native_self_records=records, cleanup_native_self_record=cleanup,
                         completion=completion, exact_owned_ids=expected_ids, kernel_exit_checks=exits)
            save('predelete-proof.json', proof)
        except Exception as error:
            errors.append('canonical predelete audit: ' + repr(error))
        # Audit uncertainty never blocks, replaces or broadens original cleanup.
        result = original_delete(path, *args, **kwargs)
        proof['original_delete_returned'] = True
        return result

    status = None
    wrapper.read_private_json, wrapper.shutil.rmtree = read, delete
    try:
        status = wrapper.main(arguments)
    finally:
        wrapper.read_private_json, wrapper.shutil.rmtree = original_read, original_delete
        absent = bool(scope) and not Path(scope['directory']).exists()
        complete = bool(proof['predelete_verified'] and proof['original_delete_calls'] == 1 and proof['original_delete_returned'] and absent and not errors)
        proof.update(canonical_status=status, canonical_reads=events, scope=scope,
                     contract_directory_absent=absent, audit_errors=errors,
                     proof_complete=complete,
                     qualification_exit=status if status not in (None, 0) else 0 if complete else 70,
                     F17_fixed=False, historical_failed_run_unchanged=True)
        save('boundary-proof.json', proof)
    return proof


def main(arguments):
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-dir', type=Path, required=True)
    parser.add_argument('native_arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args(arguments)
    native = args.native_arguments
    if native and native[0] == '--':
        native = native[1:]
    root = Path.cwd().resolve(); manifest = Path(os.environ['VANE_BUILD_MANIFEST'])
    assert sha(manifest) == MANIFEST_SHA
    runtime = json.loads(manifest.read_text())
    assert runtime['head'] == LEGACY_HEAD and runtime['source'] == SOURCE
    binary = root / runtime['test_binary']
    assert sha(binary) == runtime['binary_sha256'] == 'bfd9068f715e1ddd4fbf0c8691b458b83f68e8c1345426743471adc005cdc229'
    wrapper_path = root / 'scripts/run-native-tests.py'
    assert sha(wrapper_path) == runtime['source_pins']['scripts/run-native-tests.py']
    spec = importlib.util.spec_from_file_location('canonical_owned_wrapper', wrapper_path)
    wrapper = importlib.util.module_from_spec(spec); spec.loader.exec_module(wrapper)
    binding = {'source': SOURCE, 'compiled_head': LEGACY_HEAD, 'runtime_binary': str(binary),
               'runtime_binary_sha256': runtime['binary_sha256'],
               'runtime_manifest_sha256': MANIFEST_SHA,
               'canonical_wrapper_sha256': runtime['source_pins']['scripts/run-native-tests.py'],
               'native_writer_source_pins': {str(root / path): digest for path, digest in WRITER_PINS.items()}}
    proof = run(wrapper, native, args.audit_dir, root / runtime['test_bundle'], binding)
    return proof['qualification_exit']


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
