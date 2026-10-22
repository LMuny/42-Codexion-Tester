# Codexion Tester

This repository contains a Bash-based validation harness for a Codexion project binary. The script builds the project, checks argument handling, exercises valid and invalid runs, tests scheduler behavior, and optionally runs `valgrind`/`helgrind` checks when those tools are available.

## What the tester does

The script performs the following checks:

- Builds the project with `make re`
- Verifies the Makefile includes the required `-pthread` flag
- Ensures the build produces `codexion` in the project root
- Rejects invalid argument combinations and malformed scheduler names (a crash, signal, or timeout does not count as a rejection)
- Accepts valid runs for the supported schedulers
- Validates every simulation log line: exact format, non-decreasing timestamps, valid coder ids, and no output after a burnout
- Checks each coder's cycle: two dongles taken, then compiling, debugging, refactoring, in that order
- Checks dongle sharing: neighbouring coders in the ring never compile at the same time, and a dongle is not reused before its cooldown ends
- Checks that a burnout is logged within 10 ms of its deadline, and that no coder goes past its deadline without a burnout being logged
- Runs simulation cases for the selected scheduler and EDF, checking that each one exits with status 0 within 10 s and either finishes with every coder reaching the required compiles or ends in the expected burnout
- Runs scheduling-policy cases whose outcome depends on the scheduler (see below)
- Runs optional Valgrind Memcheck and Helgrind checks for memory and thread-safety issues
- Prints a final summary with pass/fail/skip counts

## Supported usage

Copy `tester.sh` into the root of your Codexion project (next to its `Makefile`) and run it from there:

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

## Output

Results are grouped into six numbered sections: Build, Argument validation, Execution, Simulations, Scheduling policy, and Valgrind. Each check prints `✓` (pass), `✗` (fail) or `○` (skip). A failed check is followed by indented details: the reason, the arguments or command used, and the first lines of the program's output. The run ends with the pass/fail/skip counts, the elapsed time, and a list of every failed check.

When every check passes, a pixel-art cat drawn with Unicode block characters dances for about three seconds before the final verdict. Terminals without 256 colors or UTF-8, and runs with `NO_COLOR` set, get an ASCII cat instead. Set `NO_ANIMATION=1` to skip it.

Colors, the progress spinner and the animation are turned off automatically when output is not a terminal (for example when piped to a file). Outside a UTF-8 locale the symbols fall back to ASCII (`+`, `x`, `-`).

## Requirements

- Bash 3.2 or newer (the script uses Bash features and is not POSIX `sh`)
- `make`
- A working `Makefile` that produces `./codexion` in the project root
- A C/C++ toolchain such as `gcc`
- `timeout` (GNU coreutils; `gtimeout` on macOS) is recommended; without it a slower shell fallback is used
- `valgrind` is optional but recommended for deeper diagnostics

Note: the tester runs `make re` at the start and `make clean` when it exits, so object files from your own build are removed.

## Expected behavior

The tester exits with status code `0` when all non-skipped checks pass. It exits with a non-zero status if any required checks fail.

A typical successful summary looks like this:

```text
  47 passed · 0 failed · 0 skipped   6s

  ✓ All checks passed
```

The default run has 47 checks and a `-lifo` run has 46 (the check that `lifo` is rejected only runs in default mode).

## Notes on the scheduler checks

The harness supports the following scheduler values:

- `fifo`
- `lifo` (via `./tester.sh -lifo`)
- `edf`

It explicitly rejects malformed scheduler strings, uppercase variants, and invalid combinations such as missing or extra arguments. In default mode it also checks that `lifo` is rejected, since LIFO belongs to a separate build tested with `-lifo`.

Expected outcomes per scheduler:

- **FIFO and EDF** must keep every coder alive in all the regular simulation cases.
- **LIFO** serves the most recent request first, so it may starve a coder under contention. In the regular cases a LIFO run may either finish or burn out, but the log must still be valid and any burnout must be on time.

The *Scheduling policy* section runs cases where the policy decides the result:

| Case | Arguments | FIFO / EDF | LIFO |
| --- | --- | --- | --- |
| Waiting coder vs. re-request during cooldown | `2 150 10 1 1 5 50` | survive | burnout |
| Cooldown shorter than idle time | `2 300 10 30 30 3 20` | survive | survive |
| Uncontended dongles | `4 400 20 50 50 3 0` | survive | survive |

In the first case, coder A compiles from 0 to 10 ms and requests the dongles again at 12 ms, while coder B has been waiting since 0 ms. The dongles cool down until 60 ms. FIFO and EDF then serve B, while LIFO keeps serving A, so B burns out at 150 ms. A LIFO build that survives this case is not applying LIFO order.

The log does not show when a coder requests a dongle, so the exact serving order is not checked directly; these outcome-based cases are used instead.

## Valgrind support

If `valgrind` is installed, the tester automatically runs:

- Memcheck on a three-coder simulation (`3 400 20 20 20 2 0`)
- Helgrind on the same simulation, so threads actually contend for shared dongles

Helgrind runs with one suppression. On a timeout, glibc's `pthread_cond_timedwait` can call `pthread_cond_signal` internally before it locks the mutex again, and Helgrind then reports "associated lock is not held by calling thread" against the program. That happens at random in correct programs that wait with short timeouts. The suppression only matches that call when it comes from glibc's own wait code (`__pthread_cond_wait_common`); a signal or broadcast without the lock in your own code is still reported. To reproduce a Helgrind failure by hand, save this as `helgrind.supp` and add `--suppressions=helgrind.supp`:

```
{
   glibc-condvar-timedwait-internal-signal
   Helgrind:Misc
   fun:pthread_cond_signal_WRK
   fun:pthread_cond_signal@*
   fun:__pthread_cond_wait_common
}
```

Memcheck runs with `--errors-for-leak-kinds=all`, so "still reachable" memory counts as a failure, not just definite leaks. If the tool is not installed, the script reports the check as skipped instead of failing.

## Assumptions

The log checks rely on these rules. If your program fails a check because of one of them, look at the log before assuming the program is wrong:

- Timestamps never go backwards. A program that reads the clock before locking its print mutex can print lines out of order by 1 ms and fail this check.
- A burnout must be logged within 10 ms of its deadline, and no coder may be more than 10 ms past its deadline without a burnout being logged. The tolerance is `BURNOUT_TOLERANCE_MS` at the top of `tester.sh`; a heavily loaded machine can exceed it.
- The program exits with status 0, including after a burnout.
- Coders sit in a ring with one dongle per coder: coder i shares a dongle with coders i−1 and i+1, and coder N shares one with coder 1.
- A dongle in cooldown is unavailable, and coders waiting for it stay queued until the cooldown ends.
- LIFO means the most recent dongle request is served first.

## Troubleshooting

- If the build fails, run `make re` manually and inspect the compiler output.
- If `codexion` is not produced, ensure your Makefile targets `./codexion` at the project root.
- If Valgrind checks are skipped, install `valgrind` for your Linux distribution.
- If a test fails, read the indented details under it; they show the reason, the arguments, and the start of the program's output.
- If burnout or deadline checks fail only occasionally, re-run on an idle machine before changing your code (see Assumptions).

## Files

- `tester.sh` — the main validation script
- `README.md` — project usage and behavior documentation

## License

This repository does not currently include a license file. If you plan to distribute it publicly, add an appropriate open-source license.
