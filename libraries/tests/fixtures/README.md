# Shared TRNRun contract fixtures

These fixtures freeze the Python 0.5.0 behavior used as the compatibility
baseline for other language clients. They are data-only JSON/JSONL so Python,
MATLAB, and future clients can consume the same cases without TRNSYS or bundled
executables.

- `config_contract.json` maps every public configuration field to its default
  and serialized CLI argument, and includes a queue request template.
- `events_contract.json` covers normalized fields for every event kind,
  optional/missing/null values, parser failures, and unroutable stream lines.
- `interleaved_stream.jsonl` is raw merged queue output for two runs, including
  diagnostics, malformed routed events, unknown kinds/IDs, duplicate admission,
  and terminal statuses separated from queue completion.
- `interleaved_expected.json` records the final normalized state after routing
  `interleaved_stream.jsonl` with Python 0.5.0 semantics.
- `state_contract.json` records terminal-status and bounded-log rules. Its log
  stress case is a deterministic generation recipe rather than thousands of
  repeated fixture lines.

Path placeholders in `config_contract.json` are enclosed in braces and must be
resolved to absolute paths by each client before comparison. `@bundled/...`
identifies a client-owned executable by filename rather than prescribing a
language-specific installation layout.

The provisional MATLAB release floor for the port is R2022b. It remains a
planning target until transport and CI compatibility are verified.
