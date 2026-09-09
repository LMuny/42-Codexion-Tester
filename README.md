# Codexion Tester

This repository contains a Bash-based smoke and validation tester for a Codexion project binary.

The script builds the project, checks argument validation, runs a few representative executions, and optionally runs Valgrind on minimal valid FIFO and EDF invocations to catch memory errors, leaks, and thread-synchronization issues. It is designed as a quick subject-level validation harness for a multithreaded coding-simulation program.

## What it checks

The tester validates the following:

- the project builds successfully with `make re`
- the generated binary is present at the expected path
- the `Makefile` includes the required `-pthread` flag for thread support
- invalid argument combinations are rejected with a non-zero exit status
- valid FIFO and EDF invocations are accepted
- the simulation emits the expected log format when it runs
- separate Valgrind Memcheck runs for FIFO and EDF report no memory errors or leaks when Valgrind is installed
- separate Helgrind runs for FIFO and EDF check for thread-synchronization problems such as data races or locking issues
- the validation is meant to provide subject-level confidence that the program behaves correctly under a small valid execution and without common thread/memory problems

## Requirements

Before running the tester, ensure:

- the project root contains a `Makefile` and the source for the Codexion binary
- the binary is expected to be produced as `codexion` in the project root
- `make` is available
- `pthread` support is enabled in the project build
- `valgrind` is optional, but recommended for the memory and thread checks
- the tester uses Memcheck and Helgrind for both FIFO and EDF validation when the tools are available

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
Summary: 9 passed, 0 failed, 0 skipped
```

A non-zero exit status indicates that at least one check failed.

## Notes

- The script assumes the executable is located at `./codexion` relative to the repository root.
- The verification uses a short timeout for CLI execution and Valgrind checks, so it is intended as a quick validation harness rather than a full test suite.
- If `valgrind` is missing, the script skips that section and continues with the remaining checks.
- The subject-level thread requirement is covered by the project build using `-pthread` and by the Helgrind pass for synchronization validation when available.
