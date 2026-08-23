# TRNRun Runner Behavior-Preserving Cleanup Plan

## Purpose

Clean and standardize the `runner` project without changing its observable
functionality. The result should be easier to read and more uniform while
preserving runtime behavior, CLI and JSONL contracts, and platform semantics.
The internal Nim API may change when every repository caller is updated and the
change removes code or gives a procedure a clearer owner.

This is primarily a cleanup task. Behavior-preserving design improvements are
in scope; behavior-changing bug fixes are not and must be recorded separately.

## Guiding principle

Use the smallest behavior-preserving change that improves clarity:

1. Delete noise before adding structure.
2. Reuse the current module boundaries and helpers.
3. Use the installed Nim formatter instead of inventing formatting rules.
4. Prefer descriptive private names over new abstractions.
5. Keep explicit lifecycle and serialization code where ordering matters.
6. Do not touch a file merely so every file appears in the diff.

## Review stance for the future LLM

The project owner identifies as a junior developer and is asking for senior
engineering judgment, not just mechanical formatting. Treat the current code as
a working baseline, not proof that every name, export, procedure boundary, or
module placement is intentional or optimal.

Before preserving or changing a design choice:

- Trace every caller and the real runtime flow.
- Check whether the standard library, Win32 API, or an existing project helper
  already covers the need.
- Ask whether each procedure has one clear purpose and lives with the state it
  owns.
- Remove accidental complexity, unused surface, redundant wrappers, and stale
  comments when evidence supports doing so.
- Make behavior-preserving internal design improvements even when they go beyond
  formatting, provided they are smaller and clearer than the current design.
- Prefer direct, boring code that a junior maintainer can follow over clever
  compression or patterns that require framework knowledge.
- Explain non-obvious design decisions and tradeoffs in the final summary using
  plain language.

Do not assume a suspicious behavior is intentional merely because it exists.
Investigate it and record the finding. If correcting it would change observable
behavior, defer it to a separate task with the expected behavior and required
check clearly stated.

## Current architecture

The main execution flow is:

```text
runner.main
  -> simulate
       -> waitReady
       -> monitor
  -> structured events
       -> event sequencing
       -> stdout and optional JSONL output
```

The current module graph is a reasonable starting point, not an immutable
specification. Prefer cleaning within existing modules, but allow procedures or
types to move between them when caller analysis shows a clearly better owner
and the move reduces total complexity. Do not create new modules without a
concrete responsibility that cannot be expressed cleanly in the existing graph.

## Scope

Primary implementation files:

- `src/events.nim`
- `src/eventsink.nim`
- `src/filedialog.nim`
- `src/job.nim`
- `src/monitor.nim`
- `src/mutex.nim`
- `src/processwait.nim`
- `src/runner.nim`
- `src/settings.nim`
- `src/simulate.nim`
- `src/status.nim`
- `src/wait.nim`

Documentation and supporting files:

- `README.md`
- `runner.nimble`
- `examples/example_trnrun_mass.nim`
- `examples/*.ps1`
- `tests/*.ps1`

Files that should normally remain untouched:

- `config.nims`
- `nimble.lock`
- `scripts/zigcc.bat`
- `examples/dck/*`
- `tests/dck/*`
- Generated `build/` content
- Cache directories such as `.ruff_cache/`

## Non-negotiable behavior contracts

Do not change any of the following.

### Compatibility boundary

The supported external contract is the `trnrun.exe` CLI and its JSONL protocol,
not every identifier marked with Nim's `*` export marker. A repository-wide
search found no Nim callers outside `runner/`; the Python manager consumes the
executable protocol only.

Exported Nim identifiers may therefore be renamed, made private, deleted, have
their signatures simplified, or move between existing modules when all of the
following hold:

- Every repository caller is found and updated in the same change.
- The effective defaults and observable runtime behavior remain unchanged.
- The identifier is not documented as a supported library API.
- The change produces a concrete benefit: deletion, a clearer name, a smaller
  surface, or better ownership.
- `nim check`, the build, and the relevant output comparisons still pass.

Remember that Nim has no package-private visibility: a symbol used by another
`runner` module still needs `*`. Remove an export marker only when the symbol is
used solely inside its defining module or is deleted/moved with all callers.

Do not add compatibility aliases or wrappers for hypothetical consumers. If an
actual external Nim consumer is identified, preserve or deliberately version
that specific API instead.

Private identifiers should be renamed, moved, or deleted whenever that makes
the code smaller or clearer. Moving code is allowed between existing modules,
but only when responsibility becomes clearer and total import/code complexity
decreases; do not create new modules merely to rearrange code.

### CLI contract

Preserve:

- Option names and accepted forms.
- Positional deck-file handling.
- Default values.
- File-picker behavior.
- Help and version behavior.
- Exit codes.
- Error handling, diagnostic wording, and stdout/stderr destinations unless a
  wording correction is explicitly approved.

### Event and JSONL contract

Preserve exactly:

- Event kinds and enum wire values.
- JSON keys, including spellings such as `unitID`, `typeID`, `elapsed`, and
  `eta`.
- JSON field insertion order.
- Optional-field omission.
- Numeric rounding and precision.
- Timestamp formatting.
- Sequence numbering and its starting value.
- stdout flushing.
- JSONL output naming and truncation behavior.
- Best-effort file-write failure behavior.

Do not replace the explicit event serializers with generic serialization.

### Runtime contract

Preserve:

- Validation timing and exception types.
- Launch mutex behavior and scope.
- Job-object behavior.
- Process ownership and termination behavior.
- Readiness-stage order and shared deadline behavior.
- Polling order and intervals.
- Timeout, stall, cancellation, and fatal-result behavior.
- Status-event order.
- Sidecar cleanup timing.
- Log and TMP parsing behavior.

### Platform contract

- Preserve Win32 declaration names, layouts, calling conventions, constants,
  and error handling.
- Do not change `Local\TRNRun_LaunchMutex` to a global mutex.
- Do not move Windows modules into a platform subdirectory. The whole runner is
  Windows-specific, so that directory would add no useful distinction.

## Formatting and documentation conventions

Use the installed `nimpretty` tool as the formatting baseline. Preview its
output before applying it broadly and review all resulting changes. Do not
accept formatting that obscures deliberate Win32 declarations or produces
unnecessary whole-file churn.

Use these conventions across Nim files:

1. A concise module documentation header.
2. Platform guard, when needed.
3. Imports in their existing semantic order.
4. Types and constants.
5. Private helpers.
6. Public API.
7. Optional direct-run example.

Additional rules:

- Do not reorder imports only for appearance. Nim module initialization can be
  observable, especially around `mutex.nim`.
- Use short section headings only in files large enough to need them.
- Remove oversized divider banners.
- Keep concise one-line guards when they remain readable.
- Wrap long signatures, diagnostics, and comments consistently.
- Public documentation should explain contracts and non-obvious behavior, not
  restate the signature.
- Private comments should explain why, constraints, or edge cases rather than
  narrating the code.
- Preserve load-bearing comments about PID reuse, locking, process ownership,
  error boundaries, and thread safety.
- Avoid NumPy-style `Parameters`/`Returns` sections when the signature and a
  short Nim doc comment already communicate the same information.

## Module and procedure decisions

### `src/events.nim`

Purpose: define structured simulation events and their wire serialization.

Tasks:

- Normalize the module header, blank lines, and wrapping.
- Keep `formatEventTimestamp` and its thread-local cache unchanged; its
  thread-safety and `gcsafe` behavior are non-obvious and intentional.
- Keep all `%` overloads explicit.
- Keep `toJson` as the named boundary between typed events and JSON. Its
  one-line implementation is intentional and clearer at call sites than the
  `%event` operator.
- Remove the export marker from `EventTimestampFormat` unless a repository
  caller needs it.

Do not:

- Generate serializers generically.
- Rename enums or event fields.
- Change timestamp precision or timezone behavior.
- Change JSON insertion order or optional-field handling.

### `src/eventsink.nim`

Purpose: sequence events and deliver JSON lines to stdout and optional files.

Tasks:

- Make the module header consistent with the other modules.
- Clarify the `stdoutEventSink` documentation: it always writes and flushes
  stdout and may mirror the same line to an optional `JsonlWriter`.
- Normalize formatting and blank lines.

Keep:

- `sequencedJsonLine` private.
- One independent sequence counter per `sequencedEventSink`.
- The current nil-safe `close` and `write` behavior.
- The policy that event-file failures cannot stop the simulation.

Do not add a generic tee/composite sink abstraction.

### `src/filedialog.nim`

Purpose: provide a native Windows file picker and deck-specific convenience
wrapper.

Tasks:

- Normalize the module documentation and public-procedure comments.
- Reduce duplicated parameter/return prose where the signature is sufficient.
- Keep Win32 names and declaration layout recognizable.

Keep both `openFileDialog` and `openDeckFileDialog`; the convenience wrapper is
justified and avoids repeating the filter definition.

### `src/job.nim`

Purpose: place the process in a kill-on-close Windows Job Object.

Tasks:

- Normalize headings and documentation without removing the process-lifetime
  explanation.
- Keep `initJobGuard` idempotent.
- Delete `jobGuardActive` unless a real caller is identified; the current
  repository does not use it.

Do not combine this module with `mutex.nim`; job lifetime and launch
serialization are separate concerns.

### `src/mutex.nim`

Purpose: serialize TrnEXE launches across runner processes in one Windows logon
session.

Tasks:

- Normalize headings, wrapping, and public documentation.
- Preserve the warning for an abandoned mutex.
- Preserve the release-failure diagnostic.
- Keep `withLaunchLock` explicit and exception-safe.

Keep the raw acquire/release procedures because `withLaunchLock` uses them, but
remove their export markers unless a real cross-module caller is identified.
Only the scoped template currently needs to cross the module boundary.

### `src/processwait.nim`

Purpose: wait for process exit without Nim's timeout-triggered process
termination behavior.

Tasks:

- Make the module header consistent.
- Apply formatting only where useful.

Preserve the detailed PID-reuse/race comment and the `process.running` checks.
They are load-bearing, not redundant fast paths.

### `src/settings.nim`

Purpose: define execution settings, defaults, GUI behavior, and setting-event
conversion.

Tasks:

- Consider renaming private `settingValue` to `wireValue` so its protocol role
  is explicit.
- Normalize comments and formatting.

Keep `flag`, `wantsMinimize`, and `settingEvent` as separate focused mappings.
Do not merge this module into `events.nim`.

### `src/status.nim`

Purpose: provide canonical result-to-status and result-to-exit-code mappings.

This module is already concise and well structured. Limit changes to necessary
formatting or documentation consistency. Keep the exhaustive `case` mappings.

### `src/runner.nim`

Purpose: implement the CLI trust boundary and invoke the simulation engine.

Tasks:

- Rename private `s` in `parseGuiVisibility` to `value`.
- Rename private parser variable `p` to `parser`.
- Remove duplicate blank lines.
- Shorten the oversized `main` documentation to its purpose, return-code
  contract, and exception boundary.
- Reflow long help and diagnostic lines.
- Keep help terminology synchronized with `README.md`.

Keep:

- Explicit option parsing. A table-driven parser would add heterogeneous setter
  machinery for one caller.
- File-picker handling in the CLI.
- The CLI trust-boundary comment and top-level exception handling.
- Existing validation and JSONL setup order.

Do not extract a `parseArguments` helper unless it demonstrably removes more
complexity than it introduces; currently it would require another configuration
or result type for one caller.

### `src/simulate.nim`

Purpose: orchestrate validation, process guarding, launch serialization,
readiness detection, monitoring, termination, event emission, and cleanup.

Tasks:

- Remove the redundant `result = default(Process)` in `launchTrnexe`; every
  successful path returns `startProcess` and every failed path raises.
- Rename private constant `Extensions` to `SidecarExtensions`.
- Rename private local `f` in `unlinkFiles` to `sidecarPath`.
- Normalize section headings and wrap long comments and diagnostics.
- Give the `when isMainModule` block a descriptive section heading.

Keep:

- `validateDeck` and `validateTrnexe` as trust-boundary helpers.
- Explicit lifecycle event emission.
- Explicit outcome branches after `monitor`.
- `simulate` as one visible lifecycle orchestrator.
- The direct-run block; removing or moving it changes direct execution of
  `simulate.nim`.

Do not add helpers such as `emitTerminalStatus`, `handleTimeout`, or
`handleStall`. They would hide process ownership and event ordering without
providing reuse.

`unlinkFiles` is used only inside `simulate.nim`; make it private and rename it
to `removeSidecarFiles` or another precise name if the resulting call sites are
clearer. Likewise, remove the export marker from `launchTrnexe` if the final
repository search confirms it has no cross-module caller.

### `src/wait.nim`

Purpose: coordinate readiness detection and GUI minimization for a running
TrnEXE process.

Preferred internal order:

1. Win32 types and declarations.
2. Generic polling primitive.
3. File-based readiness checks.
4. Window discovery.
5. GUI minimization.
6. Public `waitReady` orchestration.

Tasks:

- Remove the two dead commented-out visibility/title checks in `enumCallback`.
- Rename private `cond` locals to `condition`.
- Normalize compact `try`/`except` formatting in `checkLst`.
- Normalize section titles and wrap long documentation.

Keep:

- `poll` private.
- Separate `waitLst`, `waitTmp`, and `waitGui` procedures.
- The `MonoTime()` placeholder and its explanation.
- Separate window callbacks. Combining them would require more configurable
  callback state for no current reuse.
- Shared deadline behavior in `waitReady`.

Do not split window discovery into a new module.

### `src/monitor.nim`

Purpose: parse TRNSYS output, emit runtime events, and determine the final
monitoring result.

Preferred internal order:

1. Internal state types.
2. Progress calculations.
3. Event conversion.
4. Log parsing.
5. TMP parsing.
6. Polling and timeout/stall checks.
7. Public `monitor` entry point.

Tasks:

- Rename unclear private abbreviations where doing so improves readability:
  - `blck` -> `blockLines`
  - `snap` -> `snapshot`
  - `pct` -> `percentage`
  - `elap` -> `elapsedMs`
  - `filepath` -> `path`
- Rename private `clampTimeout` to `clampTimeoutToPollInterval` so its exact
  policy is visible.
- Remove manual spacing used only to align assignments.
- Normalize TMP/log heading capitalization, blank lines, long diagnostics, and
  comments.
- Clarify that `pollLog(emitLogs = false)` drains logs and still detects fatal
  entries without emitting them.
- Preserve concise guard returns where readable.

Keep:

- Separate parsed `SimLog`, `SimConfig`, and `SimProgress` types. They separate
  parser state from wire event types.
- The log parser dispatch table.
- Explicit event-conversion procedures.
- `tick`; it records TMP-before-log polling order and fatal propagation.
- Log offset handling, final draining tick, and current outcome determination.
- `monitor` as one visible runtime-loop orchestrator.

Do not extract `logparser.nim` or `tmpparser.nim`; neither parser has another
caller, and extraction would expose private types or add conversion layers.

## Documentation tasks

### `README.md`

Correct and standardize documentation without changing code behavior.

Tasks:

- Fix introductory grammar and typos, including `treams`.
- Reflow the opening description into readable paragraphs.
- Describe the mutex as scoped to the current Windows logon session, matching
  `Local\TRNRun_LaunchMutex`, rather than machine-wide.
- State the actual requirement from `runner.nimble`: Nim `>= 2.2.10`.
- Use consistent `TrnEXE`, `TRNSYS`, and executable-name capitalization.
- Correct the event schema examples so booleans and numbers are shown as JSON
  values rather than strings.
- Explain that absent optional `LOG` fields are omitted.
- Document the exact timestamp representation: `yyyy-MM-ddTHH:mm:ss`, second
  precision, with no UTC offset.
- Explain that event output replaces the deck extension with `.jsonl`; it does
  not append `.jsonl` after the existing extension.
- Normalize exit-code backticks, table punctuation, and canonical lowercase CLI
  values.
- Keep CLI defaults and terminology synchronized with `writeHelp` and
  `DefaultRunnerSettings`.
- Clarify that cancellation and stall determination require successful TMP
  snapshots, not merely `--watchTmp:true`.

Where documentation and implementation expose a possible bug, do not rewrite
one to silently bless the other. Record the discrepancy for separate behavior
work.

### `runner.nimble`

Keep changes minimal:

- Normalize `TrnEXE` and `Zig` capitalization.
- Rename `# Config` to `# Build configuration` if it improves consistency.
- Do not restructure argument construction or add dependencies.

## Example and manual-test script tasks

Apply a uniform presentation across:

- `examples/example_trnrun_mass.nim`
- `examples/*.ps1`
- `tests/*.ps1`

Tasks:

- Use canonical lowercase CLI enum values such as `auto` and `hidden`.
- Use consistent, descriptive PowerShell variable naming.
- Use one consistent brace and line-wrapping style.
- Remove excessive separator and `no need to edit below` banners.
- Reflow unreadably long commands and conditionals.
- Correct stale comments such as references to the wrong source module.
- Keep explicitly listed CLI options, even when they currently equal defaults;
  examples should not silently change when defaults change later.

Preserve:

- Each script's parameter combinations.
- Sequential versus concurrent execution.
- Process creation and waiting behavior.
- Console output and CSV shape.
- Result and failure counting.
- Standalone script usability.

Do not create a shared PowerShell helper/module. The duplication is smaller and
safer than introducing a sourcing dependency for standalone scripts.

## Structural choices explicitly rejected

Do not perform these changes:

- Move Win32 modules under `src/platform/windows/`.
- Merge `settings.nim` or `status.nim` into `events.nim`.
- Split `monitor.nim` into parser modules.
- Split window handling out of `wait.nim`.
- Move or remove the direct-run block from `simulate.nim`.
- Generate README or CLI help from a new option metadata abstraction.
- Replace explicit CLI parsing with a table-driven system.
- Add generic event serializer or parser frameworks.
- Consolidate PowerShell scripts through shared helper files.
- Reorder imports for appearance.
- Preserve unused export markers or compatibility wrappers solely for
  hypothetical consumers; audit and narrow the internal Nim surface instead.
- Add dependencies, modules, fixtures, or a new test suite.

## Known behavior issues: record, do not fix here

The following issues were found during review. They require focused behavior
changes and tests, so they are outside this cleanup.

### Startup death handling in `simulate`

`waitReady` returns `wrDied` when the process is no longer running, but the
`wrDied` branch currently reports `simFatal` only inside `if process.running`.
That condition will normally be false, allowing execution to continue and
potentially emit `RUNNING`.

Do not change this in the cleanup. Create a separate bug-fix task after tests
can define the intended status and exit-code behavior.

### `minimizeGui` idempotency

`minimizeGui` claims to be idempotent, but it sets `done` only when it actively
minimizes a non-iconic window. If all matching windows are already minimized,
it may poll until timeout and return false.

Do not change this in the cleanup. A later test should define whether an
already-minimized matching window counts as success.

### Partial streaming log writes

The log pipeline stores a byte offset but no incomplete line or block. If
TRNSYS appends part of a line or log block across polling boundaries,
`readNewLines -> splitIntoBlocks -> parseLogBlock` may consume and lose partial
content.

Do not add buffering during cleanup. Reproduce the behavior and add a focused
parser test before changing monitor state.

### Detection timeout policy

When startup detection times out and `killOnTimeout` is false, the current code
continues into monitoring and emits `RUNNING`. This may be intentional process
lifetime policy.

Do not simplify or alter this behavior without a separate product decision and
test.

## Recommended implementation order

Implement in small, reviewable phases.

Stop rather than change code when a proposed cleanup only trades one valid
style for another, adds a helper/module, increases total code or imports, or
cannot explain a concrete readability or ownership improvement.

### Phase 0: Establish and protect the baseline

- Run `git status --short` and preserve all pre-existing user changes.
- Record the baseline `nim check` and build results.
- Capture `--help` and `--version` output when an executable is available.
- Do not mix unrelated existing diagnostics or generated artifacts into the
  cleanup diff.

### Phase 1: Mechanical Nim cleanup

- Preview `nimpretty` output.
- Normalize spacing, wrapping, blank lines, headers, and section comments.
- Avoid import reordering and whole-file churn without benefit.

### Phase 2: Naming, export, and dead-code cleanup

- Apply the private renames listed above.
- Audit every `*` export marker against repository callers.
- Rename, de-export, or delete unsupported internal APIs when that reduces code
  or clarifies ownership.
- Update every affected repository caller in the same change.
- Simplify signatures only when effective defaults and runtime behavior remain
  identical.
- Remove dead commented code and redundant assignments.

### Phase 3: Documentation cleanup

- Shorten redundant Nim API documentation.
- Correct and standardize `README.md`.
- Apply minimal `runner.nimble` wording changes.

### Phase 4: Examples and existing scripts

- Preserve arguments and execution behavior.

### Phase 5: Validation and final diff audit

- Run compile/build checks.
- Compare stable CLI output.
- Review every changed condition, literal, and call order.
- Ensure no deferred behavior issue was accidentally fixed or altered.

## Validation

Do not create a new test suite for this task. Use the smallest existing checks
that detect accidental cleanup regressions.

A baseline check has already passed:

```text
nim check src/runner.nim
SuccessX
```

After each implementation phase, let the user run:

```powershell
nim check src/runner.nim
nim check examples/example_trnrun_mass.nim
nimble zigbuild
git diff --check
```

When a baseline executable is available, compare these outputs before and after
cleanup:

```powershell
build\trnrun.exe --help
build\trnrun.exe --version
```

The help and version output should remain identical unless the only differences
are approved documentation corrections that do not change accepted CLI input.

Existing TRNSYS-dependent scripts may be left for the later test phase if the
required TRNSYS installation or decks are unavailable. Do not claim they passed
unless they were actually run.

## Final diff audit checklist

Before completing the cleanup, verify:

- [ ] No new dependency was added.
- [ ] No file or module was moved.
- [ ] Every renamed, moved, de-exported, or removed Nim symbol was checked
      against the full repository and all callers were updated.
- [ ] Any signature change preserves effective defaults and runtime behavior.
- [ ] No CLI option, accepted value, or exit code changed.
- [ ] No JSON key, value, order, precision, or omission rule changed.
- [ ] No event emission order changed.
- [ ] No process, timeout, stall, kill, lock, or cleanup condition changed.
- [ ] No Win32 declaration or constant changed.
- [ ] No deferred behavior issue was fixed inside the cleanup.
- [ ] Generated files and deck files were not modified.
- [ ] Pre-existing user changes were preserved.
- [ ] Every modified PowerShell script parses without errors.
- [ ] `nim check src/runner.nim` passes.
- [ ] `nim check examples/example_trnrun_mass.nim` passes.
- [ ] `nimble zigbuild` passes, or any inability to run it is documented.
- [ ] `git diff --check` passes.
- [ ] Each changed procedure has one clear purpose and an appropriate owner.
- [ ] Non-obvious design changes are explained in plain language for the
      maintainer.
- [ ] The final diff consists only of approved formatting, naming,
      documentation, and behavior-neutral design improvements.

## Expected outcome

The final project should have:

- The same module structure.
- The same external CLI, JSONL, process, and runtime behavior.
- More consistent formatting and documentation.
- Clearer private names.
- Less redundant commentary and visual noise.
- Explicit, easy-to-audit orchestration and protocol code.
- Straightforward code and explanations suitable for a junior maintainer.
- No unnecessary abstractions, dependencies, or test infrastructure.
