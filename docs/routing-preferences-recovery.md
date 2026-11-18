# Recover routing preferences after a host-normalization failure

This procedure is specifically for `RoutingPreferences.v2` rules saved by an older
Eligo version where `example.com。` and `example.com` could be stored separately,
then collide during loading. It also covers historical multiple trailing dots
(such as a saved `example.com..`) and equivalent duplicate Routing Scope entries.
The original bytes are retained when loading fails.
Do not use Reset Settings if you want to keep the configuration.

The repair tool uses the same host normalizer, settings validation and Codable
implementation as Eligo. It lists conflicting and invalid rules with their
original host, rule ID, Installed Browser ID and Normal/Private mode, and reports
invalid or equivalent duplicate Scope entries separately. You must choose exactly
one entry in **each** conflict, and explicitly discard **every** reported invalid
entry or cancel. Invalid hosts are never silently rewritten or stripped of all
their trailing dots. It never chooses the first conflict entry automatically.
Unaffected rules keep their IDs, destinations and order. Scope kind and Bypass
Destination, Always Show Chooser, other JSON fields and other preference keys are
retained. Unrelated structural corruption, invalid modes or missing required
fields stop the repair; this is not a general damaged-JSON editor.

Previously stable hosts such as `a~b.com`, `a+b.com` and `example..com` remain
supported for compatibility. They do not require repair or removal. Unicode IDNs
with valid contextual U+200C/U+200D joiners use the same IDNA conversion as before.

## Prepare an offline candidate

These are instructions for the owner of the affected configuration. Development
tests use a synthetic fixture and isolated preferences; they do not run these
commands on your installed app.

1. Quit Eligo and leave it closed throughout recovery. Use a build containing the
   normalization fix when reopening. In Terminal, from this repository, create a
   private recovery directory and export the preferences. For a custom build,
   replace the bundle identifier below with that build's identifier.

   ```sh
   recovery_dir=$(mktemp -d "$HOME/Desktop/Eligo-routing-recovery.XXXXXX")
   defaults export io.github.xwaynedx.eligo "$recovery_dir/export.plist"
   bash script/repair-routing-preferences.sh inspect "$recovery_dir/export.plist"
   ```

   Inspection only reads the explicitly supplied file. No installed app, browser,
   default URL handler or live preference is changed by the tool.

2. Read each report entry and decide which destination and mode to keep, and
   whether to discard invalid entries. Rule numbers and Scope numbers are
   **separate**, one-based positions in their original arrays, not the report's
   line numbers. Cancel by stopping here. For example, **only if** the report
   contains a single rule conflict, no invalid entries or Scope conflicts, and
   you chose its rule 4:

   ```sh
   bash script/repair-routing-preferences.sh prepare "$recovery_dir/export.plist" \
     --keep 4 --output "$recovery_dir/prepared"
   ```

   For several rule conflicts, pass one selected number per group, e.g. `--keep 4,7`.
   Additional choices, only for entries explicitly shown in the report:

   | Option | Meaning |
   |---|---|
   | `--discard-rules 2` | Explicitly discard invalid rule 2; list every invalid rule. |
   | `--keep-scope 2` | Keep Scope entry 2 from its equivalent-duplicate group; one per group. |
   | `--discard-scope 3` | Explicitly discard invalid Scope entry 3; list every invalid Scope entry. |

   Omit options whose groups are absent. For example, the combined synthetic
   fixture uses `--keep 4 --discard-rules 2 --keep-scope 2 --discard-scope 3`;
   these numbers are not a recommendation for your configuration. Discarding
   entries changes their routing coverage, so review the resulting Scope and
   rules before installation. If you wish to retain an invalid entry, stop and
   keep the backup instead of running `prepare`.

   Missing, extra or ambiguous choices are rejected. The output directory must
   not already exist. On success it contains:

   - `original-routing.json`: the **exact original blob**, before normalization;
   - `original.plist`: the exact input export, including other preferences;
   - `candidate-routing.json`: the selected configuration after complete settings
     decoding, validation and encode/decode equality checks;
   - `candidate.plist`: the original preferences with only the routing blob replaced.

   The input is never overwritten. Cancellation, validation errors and output
   write failures leave it and live preferences unchanged. A failed write may
   leave partial output; retain the backups, do not install that output, and retry
   into a new directory. Existing output and backups are never overwritten.

3. Review the candidate before replacing anything. Compare the kept rule IDs,
   destinations/modes and order with the report, and check Scope and Always Show
   Chooser. You can stop here without changing any preferences.

   ```sh
   python3 -m json.tool "$recovery_dir/prepared/candidate-routing.json"
   ```

## Install only the reviewed candidate

This is a separate, explicit owner action that writes live preferences. The
offline tool does not perform it. Keep Eligo closed. First export again and check
that nothing changed since the source snapshot (plist byte formatting is ignored):

```sh
defaults export io.github.xwaynedx.eligo "$recovery_dir/current.plist"
python3 - "$recovery_dir/export.plist" "$recovery_dir/current.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as a, open(sys.argv[2], 'rb') as b:
    if plistlib.load(a) != plistlib.load(b):
        sys.exit('Preferences changed: stop and prepare a new export/candidate.')
print('Source snapshot still matches.')
PY
```

**Stop if either command fails or the snapshots differ.** After confirming the
match and reviewing the candidate, install it and export again for verification:

```sh
defaults import io.github.xwaynedx.eligo "$recovery_dir/prepared/candidate.plist"
defaults export io.github.xwaynedx.eligo "$recovery_dir/installed.plist"
python3 - "$recovery_dir/prepared/candidate.plist" "$recovery_dir/installed.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as a, open(sys.argv[2], 'rb') as b:
    if plistlib.load(a) != plistlib.load(b):
        sys.exit('Verification failed: keep Eligo closed and restore the backup.')
print('Installed preferences match the validated candidate.')
PY
```

If import or verification fails, keep Eligo closed. The original blob and full
export still exist; restore with the command below, then export again and compare
against `original.plist` using the same comparison above. An OS preference write
failure is not a successful recovery, and the offline tool cannot guarantee that
the OS accepted an import or rollback.

```sh
defaults import io.github.xwaynedx.eligo "$recovery_dir/prepared/original.plist"
```

After successful candidate verification, reopen the fixed Eligo build. Confirm
the rules, modes, Scope and Always Show Chooser, then edit/save a rule to confirm
that the configuration is writable. Keep the backups until satisfied. No Reset
is required.

## Regression fixture

`Tests/EligoTests/Fixtures/host-normalization-v2.json` preserves the legacy
host-normalization behavior using the `RoutingSettings` encoder. Its five inputs
in order were `untouched.example`,
`example.com。`, `middle.example`, `example.com`, `example.com` (last one includes
subdomains). IDs end in `0001` through `0005`; rule 4 opens Chrome Private and the
others open Safari Normal. Scope contains `example.com。` including subdomains,
with Safari Normal as Bypass Destination; Always Show Chooser is enabled.
The old encoder produces distinct `example.com.` / `example.com` exact rules,
and loading the payload fails with `duplicateRuleMatcher`.

Two additional fixtures were generated with that same old implementation:

- `host-legacy-compatible-v2.json`: `a~b.com`, `a+b.com`, `example..com`,
  `نامه‌ای.ir` and `क्‍ष.com`. The old encoder/decoder successfully round-tripped
  it. Regression tests load it in the new store and continue editing/saving.
- `host-legacy-invalid-v2.json`: rules include the old output of
  `example.com%2e%2e`, a trailing-dot rule collision, and an unaffected `a~b.com`.
  Scope contains equivalent duplicates and the old output of
  `broken-scope.example%2e%2e`. Tests require explicit rule and Scope choices before
  validating the candidate and loading it into isolated editable preferences.

CI runs `bash script/test-routing-recovery.sh`: it compiles the standalone CLI
through its owner-facing wrapper, exercises reports, explicit choices, backups,
candidate generation, invalid choices, existing output and concurrent directory
creation using only temporary synthetic exports.
