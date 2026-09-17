# Codexion Tester

A small, focused test harness for building and exercising the `codexion` binary. The tester is implemented as a Bash script that builds the project, runs argument-validation and functional checks, executes stress suites for FIFO/EDF scheduling, and optionally performs Valgrind-based diagnostics.

## Quickstart

1. Ensure you are at the repository root.
2. Make the tester executable (optional but convenient):

```bash
chmod +x tester.sh
```

3. Run the tester:

```bash
./tester.sh
```

Or explicitly via Bash:

```bash
bash tester.sh
```

## Getting Started / Requirements

- POSIX-compatible shell (Bash recommended)
- `make` and a `Makefile` that produces the `codexion` binary at the repository root (e.g., `./codexion`)
- A working C toolchain (`gcc`, `clang`, etc.) as required by the project
- `valgrind` (optional) for memory and threading checks

If the script cannot find `codexion`, run `make re` and verify the `Makefile` produces the binary at the expected path.

## Useful Environment Variables

- `NO_COLOR=1` — disable ANSI color output
- `VERBOSE=1` — enable more verbose logging (subject to script support)

Valgrind runs are autodetected and will be skipped if `valgrind` is not installed.

## Output

On success the script prints a final summary, for example:

```text
Summary: 26 passed, 0 failed, 0 skipped
```

The script exits with `0` when all non-skipped checks pass; a non-zero exit indicates at least one failed check.

## Troubleshooting

- If the build fails, run `make re` manually and inspect compiler output.
- If `codexion` is not produced at the repo root, update your `Makefile` or adjust the script accordingly.
- If Valgrind runs are skipped, install `valgrind` via your distro package manager.

## Files

- [tester.sh](tester.sh) — the test harness script to run checks and diagnostics.

## Contributing

Bug reports and improvements are welcome. When adding new tests or stress scenarios, document intent and keep changes focused.

## License

This repository does not include an explicit license. Add a `LICENSE` file if you intend to publish or share this project.
