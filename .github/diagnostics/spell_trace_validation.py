"""Validate only the scoped buffered trace; this never executes SDK/test code."""
import re


def validate(text, slot):
    errors, events, footer = [], [], None
    lines = [line for line in text.splitlines() if line.startswith('F17_SPELL ')]
    if not slot['trace_enabled']:
        return {'events': [], 'footer': None, 'validation_errors':
                ['flag-off control emitted spell instrumentation'] if lines else []}
    try:
        for line in lines:
            is_footer = line.startswith('F17_SPELL footer ')
            tokens = line.split()[2 if is_footer else 1:]
            fields = {}
            for token in tokens:
                key, separator, value = token.partition('=')
                assert separator and key not in fields, 'malformed/duplicate trace field'
                fields[key] = value
            if is_footer:
                assert footer is None, 'duplicate footer'
                footer = fields
                continue
            expected = {'event', 'kind', 'phase', 'tick', 'call', 'receiver', 'class', 'tag',
                        'sequence', 'range', 'checkingTypes', 'thread', 'mainThread'}
            assert fields.keys() == expected, 'event fields changed'
            event = {}
            for key, value in fields.items():
                if key == 'range':
                    assert re.fullmatch(r'\d+,\d+', value), 'bad range'
                    event[key] = [int(part) for part in value.split(',')]
                else:
                    assert re.fullmatch(r'[0-9a-f]+' if key in ('receiver', 'class') else r'-?\d+', value)
                    event[key] = int(value, 16 if key in ('receiver', 'class') else 10)
            assert event['event'] == len(events), 'missing/duplicate/out-of-order event'
            assert 1 <= event['kind'] <= 9 and event['tick'] > 0, 'event kind/time'
            assert event['thread'] > 0 and event['mainThread'] in (0, 1), 'thread identity unavailable'
            assert event['phase'] in slot['allowed_phases'], 'unexpected case phase'
            events.append(event)
        assert footer is not None, 'no footer'
        numeric = {'problems', 'recorded', 'dropped', 'unpublished', 'closeInFlight', 'currentInFlight',
                   'factoryInstalled', 'factoryRestored', 'factoryOriginalNow', 'candidateInstalled',
                   'candidateRestored', 'candidateOriginalNow', 'bindingTicks', 'nonmatching'}
        literals = {'clock': 'mach_continuous_time', 'tagAttribution': 'page-not-field',
                    'preFactoryInitialization': 'UNOBSERVED', 'preBindingCalls': 'UNKNOWN',
                    'indefiniteHangBuffer': 'NOT-PERSISTENT',
                    'waitEntry': 'after-original-5s-deadline-construction',
                    'functionExit': 'may-follow-diagnostics', 'longSpanBlockingCause': 'UNKNOWN'}
        assert footer.keys() == numeric | literals.keys() | {'timebase'}, 'footer fields changed'
        for key in numeric:
            assert re.fullmatch(r'\d+', footer[key]), 'non-numeric footer'
            footer[key] = int(footer[key])
        for key, expected in literals.items():
            assert footer[key] == expected, 'interpretation label changed: ' + key
        assert re.fullmatch(r'[1-9]\d*/[1-9]\d*', footer['timebase']), 'bad timebase'
        for key in ('problems', 'dropped', 'unpublished', 'closeInFlight', 'currentInFlight'):
            assert footer[key] == 0, 'incomplete/invalid evidence: ' + key
        assert footer['recorded'] == len(events) <= 512, 'event inventory mismatch'
        for key in ('factoryInstalled', 'factoryRestored', 'factoryOriginalNow'):
            assert footer[key] == 1, 'factory ownership/restoration missing'
        assert footer['candidateInstalled'] in (0, 1)
        for key in ('candidateRestored', 'candidateOriginalNow'):
            assert footer[key] == footer['candidateInstalled'], 'candidate restoration incomplete'
        calls, waits, completed_waits = {}, [], []
        for event in events:
            kind, call = event['kind'], event['call']
            if kind in (2, 4):
                assert call > 0 and call not in calls, 'SDK call identity reused'
                calls[call] = [event]
            elif kind in (3, 5):
                assert call in calls and len(calls[call]) == 1, 'unmatched SDK return'
                start = calls[call][0]
                assert kind == start['kind'] + 1 and event['tick'] >= start['tick'], 'SDK pair order/time'
                assert (event['thread'], event['mainThread']) == (start['thread'], start['mainThread']), 'SDK pair thread changed'
                if kind == 5:
                    for key in ('receiver', 'class', 'tag', 'range', 'checkingTypes'):
                        assert event[key] == start[key], 'candidate pair metadata changed: ' + key
                calls[call].append(event)
            else:
                assert call == 0, 'non-SDK event has call ID'
                if kind == 6:
                    waits.append([event])
                elif kind in (8, 9):
                    assert waits and len(waits[-1]) == 1, 'wait outcome lacks unique entry'
                    waits[-1].append(event)
                elif kind == 7:
                    assert waits and len(waits[-1]) == 2, 'wait exit before actual outcome'
                    completed_waits.append(waits.pop() + [event])
        assert all(len(pair) == 2 for pair in calls.values()), 'SDK START without RETURN'
        assert not waits, 'wait entry/outcome without exit'
        candidates = [pair for pair in calls.values() if pair[0]['kind'] == 4]
        assert len(candidates) >= slot['minimum_candidate_pairs'], 'expected real SDK candidate calls missing'
        if slot['minimum_candidate_pairs']:
            assert footer['candidateInstalled'] == 1
        if slot.get('required_phase') is not None:
            assert any(e['kind'] == 1 and e['phase'] == slot['required_phase'] for e in events), 'explicit control phase missing'
        if slot['require_wait_outcomes']:
            assert any(w[1]['kind'] == 8 for w in completed_waits), 'actual wait success missing'
            assert any(w[1]['kind'] == 9 for w in completed_waits), 'actual wait failure missing'
            assert 'real-sdk-spell-trace-control' in text, 'real SDK diagnostic control record missing'
    except (AssertionError, KeyError, TypeError, ValueError) as error:
        errors.append('spell trace uncertainty: ' + (str(error) or type(error).__name__))
    return {'events': events, 'footer': footer, 'validation_errors': errors,
            'interpretation': 'Wrapper brackets only; no exclusive server time, DOM attribution or F17 cause proof'}


def validate_original18(text, slot):
    """One original F17 observation, including explicit absent natural coverage."""
    result = validate(text, slot)
    events, footer, errors = result['events'], result['footer'], result['validation_errors']
    target = 'VaneTests.PasswordAutofillTests testEmbeddedSelectionCannotAuthorizeMainDocumentUsernameStep'
    blocks = list(re.finditer(re.escape("Test Case '-[" + target + "]' started.") +
        r'(.*?)' + re.escape("Test Case '-[" + target + "]' ") + r'(passed|failed|skipped) \(', text, re.S))
    phases = [event['phase'] for event in events if event['kind'] == 1]
    getters = sum(event['kind'] == 2 for event in events)
    candidates = sum(event['kind'] == 4 for event in events)
    result['native_target_status'] = blocks[0][2] if len(blocks) == 1 else 'MISSING/AMBIGUOUS'
    if len(blocks) != 1:
        errors.append('original F17 native case boundaries unavailable; no scoped complete-stream claim')
    else:
        block_lines = [line for line in blocks[0][1].splitlines() if line.startswith('F17_SPELL ')]
        all_lines = [line for line in text.splitlines() if line.startswith('F17_SPELL ')]
        if block_lines != all_lines:
            errors.append('spell instrumentation outside original F17 body or missing scoped stream')
        if blocks[0][2] == 'passed' and phases != list(range(1, 16)):
            errors.append('passing F17 lacks its exact original observation phase sequence1..15')
    result['observed_phase_sequence'] = phases
    result['unobserved_passing_path_phases'] = [phase for phase in range(1, 16) if phase not in phases]
    result['natural_coverage'] = {
        'genuine_factory_start_count': getters,
        'genuine_candidate_start_count': candidates,
        'binding_observed': bool(footer and footer['candidateInstalled']),
        'status': ('NO NATURAL GETTER OBSERVED: candidate receiver binding unestablished' if not getters else
                   'NATURAL GETTER OBSERVED, NO CANDIDATE CALL RECORDED' if not candidates else
                   'SPECIFIC RECEIVER CANDIDATE CALLS OBSERVED AFTER NATURAL BINDING'),
        'unlogged_nonmatching_count': footer['nonmatching'] if footer else None,
        'absence_limit': 'Zero records do not prove absence of text-service calls, including cached receivers/private paths before binding.',
        'cold_state': 'UNPROVEN; original13-case focused history may naturally initialize services before F17.',
        'DOM_field_or_document_generation': 'UNKNOWN; shared receiver/page tag cannot establish it.',
        'completion_latency': 'NOT OBSERVED; original completion pointers/results remain untouched.'}
    versions = [line for line in text.splitlines() if 'phase=spell-trace-engine-runtime ' in line]
    result['runtime_bundle_records'] = versions
    if len(versions) != 1 or 'provenance=current-runtime-only-not-historical' not in versions[0]:
        errors.append('actual current-runtime bundle metadata record missing/ambiguous')
    result['runtime_bundle_identity_limit'] = 'Current-run observation only; never identifies the historical runner binary.'
    result['wait_outcomes'] = [{'event': e['event'], 'kind': 'success' if e['kind'] == 8 else 'failure',
                              'phase': e['phase'], 'tick': e['tick']} for e in events if e['kind'] in (8, 9)]
    result['actual_wait_stream'] = [e for e in events if e['kind'] in (6, 7, 8, 9)]
    pending, password_waits = [], []
    for event in result['actual_wait_stream']:
        if event['kind'] == 6:
            pending.append([event])
        elif event['kind'] in (8, 9) and pending:
            pending[-1].append(event)
        elif event['kind'] == 7 and pending:
            triple = pending.pop() + [event]
            if (len(triple) == 3 and [e['kind'] for e in triple] == [6, 8, 7] and
                    all(e['phase'] == 12 for e in triple) and
                    triple[0]['tick'] <= triple[1]['tick'] <= triple[2]['tick']):
                password_waits.append(triple)
    result['successful_phase12_password_waits'] = password_waits
    if result['native_target_status'] == 'passed' and not password_waits:
        errors.append('passing F17 lacks monotonic phase12 password-load WAIT_START/SUCCESS/FUNCTION_EXIT')
    starts, spans = {}, []
    if footer:
        numerator, denominator = map(int, footer['timebase'].split('/'))
        for event in events:
            if event['kind'] in (2, 4): starts[event['call']] = event
            elif event['kind'] in (3, 5) and event['call'] in starts:
                start = starts[event['call']]
                spans.append({'call': event['call'], 'kind': 'factory' if event['kind'] == 3 else 'candidate',
                    'start_phase': start['phase'], 'return_phase': event['phase'],
                    'start_tick': start['tick'], 'return_tick': event['tick'],
                    'wrapper_bracket_ns': (event['tick'] - start['tick']) * numerator / denominator,
                    'thread': start['thread'], 'mainThread': start['mainThread'],
                    'wait_outcome_events_inside_bracket': [outcome['event'] for outcome in result['wait_outcomes']
                        if start['tick'] <= outcome['tick'] <= event['tick']]})
    result['observed_spans'] = spans
    result['interpretation'] = ('First instrumented focused18 F17 observation only. Complete format can coexist with absent natural coverage. '
        'Wrapper spans include observation/preemption and possible nested run-loop progress. Wait outcomes precede actual diagnostics; '
        'function exit may follow diagnostics and is not the5s deadline. Native navigation records use ProcessInfo.systemUptime, '
        'not an assumed identical clock origin to mach_continuous_time; no causal cross-clock join is made. No historical F17/CI repair proof.')
    return result
