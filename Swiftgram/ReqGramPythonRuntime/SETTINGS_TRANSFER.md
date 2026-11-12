# Optional settings transfer (API 1)

The installed plugin card offers **Export settings** and **Import settings** only
when its manifest declares `"settings_transfer": true`, a valid `settings_schema`,
and at least one schema field with `"transferable": true`. Both declarations
default to disabled. Mark only non-secret portable preferences transferable.
Never mark tokens, credentials, account identifiers, or private content.
The host cannot infer whether user-entered text contains a secret.

`Examples/create_settings_plugin.py` generates a complete Python example with
these declarations. Python continues to read the persisted values through
`json.loads(host_request("settings"))`; no filesystem or transfer permission is
granted to Python. Import does not run code or restart the plugin.

Export creates a JSON document and opens the native share sheet. Only opted-in
fields are included, never opaque storage, logs, accounts, archives or private
settings. Temporary share files are removed when sharing finishes or is cancelled.
The document contains `format: 1`, `plugin_id`, `schema_version`, `fields` (sorted
key/type/options descriptors), and `values`. Labels/defaults are not exported.

Import is selected inside one plugin card using the document picker, then confirmed
by the user. The host reads at most 128 KiB plus one detection byte. It validates
the installed plugin's current opt-in, exact ID, format, schema version and field
descriptors, complete portable key set, types, string bounds and selection options.
Unknown envelope/value keys, missing values, and incompatible schemas are rejected.
No paths in JSON are interpreted. Private fields and opaque storage remain intact.
Validation precedes a single atomic state-file write on the manager storage queue;
failure preserves the previous settings. A success alert returns to the plugin
card; opening Plugin settings shows the persisted values. Restart a running plugin
to re-run `on_enable` with those values.

Foundation regression coverage lives in `SGSimpleSettings/Tests/Plugins/main.swift`:
roundtrip/reopen, private-field exclusion, malformed JSON, wrong ID/schema, unknown
and missing keys, wrong types, invalid selections, opt-in enforcement, injected
write failure with byte-for-byte preservation, and deterministically overlapping
start/stop requests. Existing manager behavior rejects overlapping requests while
Starting/Stopping; these are errors, not queued desired-state changes.
