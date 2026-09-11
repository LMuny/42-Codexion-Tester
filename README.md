# Codexion Tester

A small, focused test harness for exercising and validating a Codexion project binary. The tester is implemented as a Bash script that builds the project, exercises common and stress scenarios (FIFO and EDF scheduling), and optionally runs Valgrind/Helgrind checks for memory and threading issues.

## Overview

- Builds the project using `make re` and looks for the `codexion` binary at the repository root.
- Runs argument-validation checks, functional smoke runs, and a set of stress tests for FIFO and EDF modes.
- Optionally runs Valgrind Memcheck and Helgrind when Valgrind is available.
- Emits a concise summary counting passed, failed, and skipped checks.

## Features

- Build verification and required-flag checks (expects `-pthread` in the build)
- Argument validation (rejects invalid combinations)
- Functional smoke and representative scenario runs
- Stress-run suites for FIFO and EDF scheduling
- Optional Valgrind Memcheck and Helgrind runs for memory and synchronization diagnostics
- Colorized output by default, with `NO_COLOR` to force plain text

## Requirements

- A POSIX-compatible shell (Bash recommended)
- `make` and a working `Makefile` that produces `codexion` at the repository root
- `gcc`/toolchain as required by the project
- `valgrind` (optional, recommended for deeper diagnostics)

## Quickstart

From the repository root, run:

```bash
./tester.sh
```

Or explicitly with Bash:

```bash
bash tester.sh
```

To disable ANSI colors and get plain text output:

```bash
NO_COLOR=1 ./tester.sh
```

To run Valgrind checks when available (Valgrind is autodetected; no extra args required):

```bash
./tester.sh
```

The tester will automatically skip Valgrind/Helgrind runs if `valgrind` is not installed.

## Usage / Options

The script is designed to be run as-is. It respects the following environment variables for quick adjustments:

- `NO_COLOR=1` — disable ANSI color output
- `VERBOSE=1` — enable more verbose logging (subject to script support)

For advanced use, inspect `tester.sh` to see additional flags or editable timeouts.

## Output

On success the script prints a final summary, for example:

```text
Summary: 26 passed, 0 failed, 0 skipped
```

The script exits with a zero status when all non-skipped checks pass. A non-zero exit code indicates at least one failed check.

## Troubleshooting

- If the build fails, run `make re` manually and inspect the compiler output.
- If `codexion` is not produced at the repo root, ensure the `Makefile` target produces `./codexion` or adjust the script accordingly.
- If Valgrind runs are skipped, install `valgrind` (package name may vary per distro).

## Contributing

Bug reports and small improvements are welcome. If you change test cases or add new stress scenarios, please keep them small and well-documented.

## Files

- `tester.sh` — the test harness script you run to execute the checks and diagnostics.

## License

This repository does not include an explicit license. Add one if you plan to share this project publicly.
