"""Private export handoff and receipt proof; delegates unchanged native wrapper."""
import sys
sys.dont_write_bytecode = True
import hashlib
import importlib.util
import json
import os
from pathlib import Path

PROTOCOL = 'native-self-kernel-and-canonical-boundary-v1'
WRITER_PINS = {
    'Tests/VaneTests/NativeFixtureRetirement.swift': '8975a42cc5104149d1cdc00b28ddea8ff140f80ed2c16611db36dffab9e61196',
    'Tests/VaneTests/NativeFixtureDiagnostics.swift': '4c21c7af56954720336987ae1212d8ff59bb34db28e6917d0801238794ce89a3',
}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(wrapper, arguments, audit_dir, expected_bundle, binding, private_plan=None):
    """Capture after completed primary checks, then retain canonical receipt audit."""
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
    original_read, original_delete, original_commands = wrapper.read_private_json, wrapper.shutil.rmtree, wrapper.run_commands
    main_code = wrapper.main.__code__
    captured, errors, events, exits = {}, [], [], []
    scope = {}
    proof = {'protocol': PROTOCOL, 'binding': binding, 'external_initial_live_observation_performed': False,
             'identity_basis': 'immutable native writer actual kernel self PID/start/path at registration; canonical and current kernel exit checks',
             'original_delete_calls': 0, 'original_delete_returned': False, 'predelete_verified': False}
    proof.update(private_capture_required=private_plan is not None, private_capture_complete=False,
                 completed_primary_handoff_calls=0)

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

    def commands(primary, cleanup, invoke, check_hosts):
        # Wrap only main's exact completed callback; generic exit checks retain
        # their original behavior in timeout, cleanup and final audit paths.
        try:
            frame = main_frame()
            assert sys._getframe(1).f_code is main_code
            assert primary is frame.f_locals['primary'] and cleanup is frame.f_locals['cleanup']
            assert invoke is frame.f_locals['invoke'] and check_hosts is frame.f_locals['check_hosts']
        except Exception as error:
            errors.append('primary handoff binding: ' + repr(error))
            return original_commands(primary, cleanup, invoke, check_hosts)

        def completed_check_hosts():
            result = check_hosts()  # All original validation/exit/prior-cleanup checks first.
            if private_plan is not None:
                try:
                    proof['completed_primary_handoff_calls'] += 1
                    assert proof['completed_primary_handoff_calls'] == 1
                    assert frame.f_locals['check_hosts'] is check_hosts
                    directory, token = Path(frame.f_locals['directory']), frame.f_locals['token']
                    records = frame.f_locals['records']
                    assert original_read(directory / 'contract.json') == {'schema': 1, 'token': token}
                    for record in records:
                        wrapper.validate_record(record, token)
                        assert Path(record['host']['testBundlePath']).resolve() == expected_bundle
                    from f17_private_file_trace import collect
                    destination = audit_dir / 'private-exports'; destination.mkdir(mode=0o700)
                    capture = collect(directory, token, records, destination, expected_bundle,
                        binding['compiled_head'], private_plan['allowed_cases'], private_plan['expected_files'])
                    proof['private_exports_capture'] = capture
                    save('private-exports-capture.json', capture)
                    if capture['validation_errors']:
                        errors.extend('private exports: ' + item for item in capture['validation_errors'])
                    else:
                        proof['private_capture_complete'] = True
                    proof['original_check_hosts_completed_before_capture'] = True
                except Exception as error:
                    errors.append('private export capture: ' + repr(error))
            # Capture uncertainty never raises through canonical cleanup admission.
            return result

        return original_commands(primary, cleanup, invoke, completed_check_hosts)

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
    wrapper.read_private_json, wrapper.shutil.rmtree, wrapper.run_commands = read, delete, commands
    try:
        status = wrapper.main(arguments)
    finally:
        wrapper.read_private_json, wrapper.shutil.rmtree, wrapper.run_commands = original_read, original_delete, original_commands
        absent = bool(scope) and not Path(scope['directory']).exists()
        complete = bool(proof['predelete_verified'] and proof['original_delete_calls'] == 1 and proof['original_delete_returned'] and absent and not errors and (private_plan is None or proof['private_capture_complete']))
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
    parser.add_argument('--private-plan', type=Path, required=True)
    parser.add_argument('native_arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args(arguments)
    native = args.native_arguments
    if native and native[0] == '--':
        native = native[1:]
    root = Path.cwd().resolve(); manifest = Path(os.environ['VANE_BUILD_MANIFEST'])
    manifest_sha = os.environ['VANE_BUILD_MANIFEST_SHA']
    assert sha(manifest) == manifest_sha
    runtime = json.loads(manifest.read_text())
    assert runtime['head'] == os.environ['GITHUB_SHA'] == os.environ['VANE_F17_TRACE_SOURCE_HEAD']
    assert runtime['source'] == os.environ['VANE_F17_NATIVE_WRITER_SOURCE']
    assert runtime['metadata']['revision'] == runtime['head']
    assert os.environ['VANE_F17_PRIVATE_TRACE_V1'] == '1'
    binary = root / runtime['test_binary']
    assert sha(binary) == runtime['binary_sha256']
    wrapper_path = root / 'scripts/run-native-tests.py'
    assert sha(wrapper_path) == runtime['source_pins']['scripts/run-native-tests.py'] == 'ca6a8aa788bbd09b78f60d44e49dfea533d2e1e2f98c463c99df216c6325932b'
    for path, digest in WRITER_PINS.items(): assert sha(root / path) == digest
    for path, digest in runtime['native_writer_source_pins'].items(): assert sha(root / path) == digest
    spec = importlib.util.spec_from_file_location('canonical_owned_wrapper', wrapper_path)
    wrapper = importlib.util.module_from_spec(spec); spec.loader.exec_module(wrapper)
    binding = {'source': runtime['source'], 'compiled_head': runtime['head'], 'runtime_binary': str(binary),
               'runtime_binary_sha256': runtime['binary_sha256'],
               'runtime_manifest_sha256': manifest_sha,
               'canonical_wrapper_sha256': runtime['source_pins']['scripts/run-native-tests.py'],
               'native_writer_source_pins': {str(root / path): digest for path, digest in {**WRITER_PINS, **runtime['native_writer_source_pins']}.items()}}
    assert args.private_plan.resolve().parent == args.audit_dir.resolve()
    plan = wrapper.read_private_json(args.private_plan)
    proof = run(wrapper, native, args.audit_dir, root / runtime['test_bundle'], binding, private_plan=plan)
    return proof['qualification_exit']


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
