# Codexion Tester

This repository contains a Bash-based validation harness for a Codexion project binary. The script builds the project, checks argument handling, exercises valid and invalid runs, tests scheduler behavior, and optionally runs `valgrind`/`helgrind` checks when those tools are available.

## What the tester does

The script performs the following checks:

- Builds the project with `make re`
- Verifies the Makefile includes the required `-pthread` flag
- Ensures the compiled binary exists at the repository root as `codexion`
- Rejects invalid argument combinations and malformed scheduler names
- Accepts valid runs for the supported schedulers
- Verifies the expected simulation log format and logical consistency
- Runs stress cases for FIFO and EDF scenarios
- Runs optional Valgrind Memcheck and Helgrind checks for memory and thread-safety issues
- Prints a final summary with pass/fail/skip counts

## Supported usage

From the repository root, run:

```bash
./tester.sh
```

To test the LIFO scheduler mode:

```bash
./tester.sh -lifo
```

To disable ANSI color output:

```bash
NO_COLOR=1 ./tester.sh
```

The script accepts no other runtime arguments. Any extra positional arguments or unsupported scheduler names are rejected.

## Requirements

- Bash or a POSIX-compatible shell
- `make`
- A working `Makefile` that produces `./codexion` in the project root
- A C/C++ toolchain such as `gcc`
- `valgrind` is optional but recommended for deeper diagnostics

## Expected behavior

The tester exits with status code `0` when all non-skipped checks pass. It exits with a non-zero status if any required checks fail.

A typical successful summary looks like this:

```text
Summary: 26 passed, 0 failed, 0 skipped
```

## Notes on the scheduler checks

The harness supports the following scheduler values:

- `fifo`
- `lifo` (via `./tester.sh -lifo`)
- `edf`

It explicitly rejects malformed scheduler strings, uppercase variants, and invalid combinations such as missing or extra arguments.

## Valgrind support

If `valgrind` is installed, the tester automatically runs:

- Memcheck on a minimal valid simulation
- Helgrind on a minimal valid simulation

If the tool is not installed, the script reports the check as skipped instead of failing.

## Troubleshooting

- If the build fails, run `make re` manually and inspect the compiler output.
- If `codexion` is not produced, ensure your Makefile targets `./codexion` at the project root.
- If Valgrind checks are skipped, install `valgrind` for your Linux distribution.
- If a test fails, read the script output carefully; it prints the relevant failing command output and summaries.

## Files

- `tester.sh` — the main validation script
- `README.md` — project usage and behavior documentation

## License

This repository does not currently include a license file. If you plan to distribute it publicly, add an appropriate open-source license.
