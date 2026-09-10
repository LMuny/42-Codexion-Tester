# Codexion Tester

This repository contains a Bash-based smoke, validation, timing, and memory/thread-safety tester for a Codexion project binary.

The script builds the project, checks argument validation, runs representative executions, stresses several FIFO and EDF scenarios, and optionally runs Valgrind Memcheck and Helgrind to detect memory errors, leaks, and synchronization issues.

## What it checks

The tester validates the following:

- the project builds successfully with `make re`
- the generated binary exists at the expected path (`./codexion`)
- the `Makefile` includes the required `-pthread` flag for thread support
- invalid argument combinations are rejected with a non-zero exit status
- valid FIFO and EDF invocations are accepted
- the simulation emits the expected log format when it runs
- multiple stress cases pass for both FIFO and EDF scheduling modes
- separate Valgrind Memcheck runs for FIFO and EDF report no memory errors or leaks when Valgrind is installed
- separate Helgrind runs for FIFO and EDF check for thread-synchronization problems such as data races or locking issues
- the overall harness exits with a summary indicating passed, failed, and skipped checks

## Requirements

Before running the tester, ensure:

- the project root contains a `Makefile` and the source for the Codexion binary
- the binary is produced as `codexion` in the project root
- `make` is available
- `pthread` support is enabled in the build
- `valgrind` is optional but recommended for memory and thread diagnostics
- `helgrind` is used automatically when the Valgrind tool is available

## Usage

From the repository root:

```bash
./tester.sh
```

or:

```bash
bash tester.sh
```

If you want plain text output without ANSI colors:

```bash
NO_COLOR=1 ./tester.sh
```

## Expected behavior

The tester prints a summary like:

```text
Summary: 26 passed, 0 failed, 0 skipped
```

A non-zero exit status indicates that at least one check failed.

## Notes

- The script assumes the executable is located at `./codexion` relative to the repository root.
- The validation uses short timeouts for CLI execution and Valgrind checks, so it is intended as a quick subject-level harness rather than a full test suite.
- If `valgrind` is missing, the Valgrind section is skipped and the remaining checks continue.
- If `helgrind` is not available, that synchronization check is skipped.
- The subject-level thread requirement is covered by the project build using `-pthread` and by the Helgrind pass when available.
