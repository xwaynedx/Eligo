#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Compile through the same standalone wrapper used by an owner during recovery.
bash "$ROOT_DIR/script/repair-routing-preferences.sh"

python3 - "$ROOT_DIR" <<'PY'
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
tool = root / '.build/routing-recovery/repair-routing-preferences'
fixtures = root / 'Tests/EligoTests/Fixtures'


def run(*args, success=True):
    result = subprocess.run([str(tool), *map(str, args)], capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    return result


with tempfile.TemporaryDirectory(prefix='eligo-recovery-smoke-') as work:
    directory = Path(work)
    blob = (fixtures / 'host-legacy-invalid-v2.json').read_bytes()
    source = directory / 'export.plist'
    original = plistlib.dumps({'RoutingPreferences.v2': blob, 'unrelated': b'keep'})
    source.write_bytes(original)

    inspected = run('inspect', source)
    records = [json.loads(line) for line in inspected.stdout.splitlines() if line.startswith('{')]
    assert [r['invalidRuleNumber'] for r in records if 'invalidRuleNumber' in r] == [2]
    assert [r['invalidScopeNumber'] for r in records if 'invalidScopeNumber' in r] == [3]
    assert [r['scopeNumber'] for r in records if 'scopeNumber' in r] == [1, 2]
    assert 'privateBrowsing' in inspected.stdout

    # No silent selection, invalid-host removal, or output on incomplete choices.
    rejected = directory / 'rejected'
    run('prepare', source, '--keep', '4', '--output', rejected, success=False)
    assert not rejected.exists()
    choices = ['--keep', '4', '--discard-rules', '2', '--keep-scope', '2', '--discard-scope', '3']
    prepared = directory / 'prepared'
    run('prepare', source, *choices, '--output', prepared)
    assert (prepared / 'original-routing.json').read_bytes() == blob
    assert (prepared / 'original.plist').read_bytes() == original
    candidate = json.loads((prepared / 'candidate-routing.json').read_bytes())
    assert [r['id'][-4:] for r in candidate['rules']] == ['0001', '0004', '0005']
    assert candidate['rules'][1]['destinationID']['mode'] == 'privateBrowsing'
    assert [m['normalizedHost'] for m in candidate['scope']['matchers']] == ['scope.example', 'outside.example']
    assert candidate['alwaysShowChooser'] is True
    exported = plistlib.loads((prepared / 'candidate.plist').read_bytes())
    assert exported['RoutingPreferences.v2'] == (prepared / 'candidate-routing.json').read_bytes()
    assert exported['unrelated'] == b'keep'

    existing = run('prepare', source, *choices, '--output', prepared, success=False)
    assert 'Choose a new directory' in existing.stderr

    # Two independent processes: one creates the directory, one reports EEXIST
    # with the same actionable message. Neither can overwrite the other's data.
    race = directory / 'concurrent'
    command = [str(tool), 'prepare', str(source), *choices, '--output', str(race)]
    processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
    results = [(p, p.communicate()) for p in processes]
    assert sorted(p.returncode for p, _ in results) == [0, 1]
    loser = next(stderr for p, (_, stderr) in results if p.returncode != 0)
    assert 'Choose a new directory' in loser
    assert (race / 'original-routing.json').read_bytes() == blob
    assert (race / 'candidate-routing.json').read_bytes() == (prepared / 'candidate-routing.json').read_bytes()
    assert source.read_bytes() == original

    # The legacy stable payload remains healthy; the repair tool does not
    # reinterpret compatibility hosts as invalid or offer a needless repair.
    healthy = directory / 'healthy.plist'
    healthy.write_bytes(plistlib.dumps({'RoutingPreferences.v2': (fixtures / 'host-legacy-compatible-v2.json').read_bytes()}))
    assert 'No host-normalization repairs' in run('inspect', healthy).stdout
    run('prepare', healthy, '--output', directory / 'unneeded', success=False)
    assert not (directory / 'unneeded').exists()

    # Old IPv6 spellings can now conflict even when their targets are identical.
    # Inspect must retain every original target and require a choice per group.
    ipv6_blob = (fixtures / 'host-ipv6-legacy-v2.json').read_bytes()
    ipv6_source = directory / 'ipv6.plist'
    ipv6_export = plistlib.dumps({'RoutingPreferences.v2': ipv6_blob, 'unrelated': {'keep': b'bytes'}})
    ipv6_source.write_bytes(ipv6_export)
    inspected = run('inspect', ipv6_source)
    records = [json.loads(line) for line in inspected.stdout.splitlines() if line.startswith('{')]
    rule_records = [r for r in records if 'ruleNumber' in r]
    raw = json.loads(ipv6_blob)
    assert [r['ruleNumber'] for r in rule_records] == [2, 4, 3, 5]
    for record in rule_records:
        original_rule = raw['rules'][record['ruleNumber'] - 1]
        assert record['id'].lower() == original_rule['id'].lower()
        assert record['originalHost'] == original_rule['matcher']['normalizedHost']
        assert record['browserID'] == original_rule['destinationID']['browserID']
        assert record['mode'] == original_rule['destinationID']['mode']
    scope_records = [r for r in records if 'scopeNumber' in r]
    assert [r['scopeNumber'] for r in scope_records] == [1, 2]
    assert [r['originalHost'] for r in scope_records] == [m['normalizedHost'] for m in raw['scope']['matchers'][:2]]
    ipv6_rejected = directory / 'ipv6-incomplete'
    run('prepare', ipv6_source, '--keep', '4', '--keep-scope', '2', '--output', ipv6_rejected, success=False)
    assert not ipv6_rejected.exists()
    ipv6_prepared = directory / 'ipv6-prepared'
    run('prepare', ipv6_source, '--keep', '4,5', '--keep-scope', '2', '--output', ipv6_prepared)
    assert (ipv6_prepared / 'original-routing.json').read_bytes() == ipv6_blob
    assert (ipv6_prepared / 'original.plist').read_bytes() == ipv6_export
    ipv6_candidate = json.loads((ipv6_prepared / 'candidate-routing.json').read_bytes())
    assert [r['id'][-4:] for r in ipv6_candidate['rules']] == ['0001', '0004', '0005', '0006']
    assert [r['matcher']['normalizedHost'] for r in ipv6_candidate['rules']] == ['untouched.example', '::1', '2001:db8::1', '2001:db8::2']
    assert [r['destinationID'] for r in ipv6_candidate['rules']] == [raw['rules'][i]['destinationID'] for i in [0, 3, 4, 5]]
    assert ipv6_candidate['rules'][0] == raw['rules'][0]
    assert ipv6_candidate['rules'][3] == raw['rules'][5]
    assert ipv6_candidate['rules'][1]['matcher']['futureMatcherField'] == 42
    assert ipv6_candidate['futureSettingsField'] == raw['futureSettingsField']
    assert ipv6_candidate['alwaysShowChooser'] is True
    assert ipv6_candidate['scope']['bypassDestinationID'] == raw['scope']['bypassDestinationID']
    assert ipv6_candidate['scope']['futureScopeField'] == 'preserved'
    assert [m['normalizedHost'] for m in ipv6_candidate['scope']['matchers']] == ['2001:db8::1', 'unrelated.scope.example']
    assert ipv6_candidate['scope']['matchers'][0]['annotation'] == 'keep'
    ipv6_candidate_export = plistlib.loads((ipv6_prepared / 'candidate.plist').read_bytes())
    assert ipv6_candidate_export['RoutingPreferences.v2'] == (ipv6_prepared / 'candidate-routing.json').read_bytes()
    assert ipv6_candidate_export['unrelated'] == {'keep': b'bytes'}
    assert 'No host-normalization repairs' in run('inspect', ipv6_prepared / 'candidate.plist').stdout
    assert ipv6_source.read_bytes() == ipv6_export

    # Scope-only duplicates remain valid application input, but offline repair
    # still requires an explicit Scope choice in either limited mode.
    for kind in ['onlyThese', 'allExceptThese']:
        scope_only = dict(raw, rules=[], scope=dict(raw['scope'], kind=kind))
        scope_blob = json.dumps(scope_only).encode()
        scope_export = plistlib.dumps({'RoutingPreferences.v2': scope_blob, 'unrelated': b'keep'})
        scope_source = directory / f'ipv6-scope-{kind}.plist'
        scope_source.write_bytes(scope_export)
        inspected = run('inspect', scope_source)
        assert 'Rule conflict:' not in inspected.stdout
        assert 'Scope conflict: 2001:db8::1' in inspected.stdout
        rejected = directory / f'ipv6-scope-{kind}-rejected'
        run('prepare', scope_source, '--output', rejected, success=False)
        assert not rejected.exists()
        prepared = directory / f'ipv6-scope-{kind}-prepared'
        run('prepare', scope_source, '--keep-scope', '2', '--output', prepared)
        candidate = json.loads((prepared / 'candidate-routing.json').read_bytes())
        assert candidate['rules'] == []
        assert candidate['scope']['kind'] == kind
        assert candidate['scope']['matchers'] == ipv6_candidate['scope']['matchers']
        assert candidate['scope']['bypassDestinationID'] == raw['scope']['bypassDestinationID']
        assert candidate['alwaysShowChooser'] is True
        assert (prepared / 'original-routing.json').read_bytes() == scope_blob
        assert (prepared / 'original.plist').read_bytes() == scope_export
        assert plistlib.loads((prepared / 'candidate.plist').read_bytes())['unrelated'] == b'keep'
        assert 'No host-normalization repairs' in run('inspect', prepared / 'candidate.plist').stdout
        assert scope_source.read_bytes() == scope_export

print('Routing recovery CLI: standalone build, inspect, explicit choices, backups, candidate, refusal, concurrent EEXIST and IPv6 rule/Scope conflict checks passed.')
PY
