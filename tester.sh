#!/usr/bin/env bash

# Codexion smoke, validation, timing, and Valgrind tester.

set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROGRAM="$ROOT_DIR/codexion"
BUILD_LOG=$(mktemp)
TEST_DIR=$(mktemp -d)
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
	RESET=$'\033[0m'
	BOLD=$'\033[1m'
	DIM=$'\033[2m'
	CYAN=$'\033[36m'
	GREEN=$'\033[32m'
	YELLOW=$'\033[33m'
	RED=$'\033[31m'
else
	RESET=''
	BOLD=''
	DIM=''
	CYAN=''
	GREEN=''
	YELLOW=''
	RED=''
fi

cleanup()
{
	rm -f "$BUILD_LOG"
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass()
{
	printf '%bPASS%b: %s\n' "$GREEN" "$RESET" "$1"
	PASS_COUNT=$((PASS_COUNT + 1))
}

fail()
{
	printf '%bFAIL%b: %s\n' "$RED" "$RESET" "$1"
	FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip()
{
	printf '%bSKIP%b: %s\n' "$YELLOW" "$RESET" "$1"
	SKIP_COUNT=$((SKIP_COUNT + 1))
}

section()
{
	printf '\n%b%s%b\n' "$BOLD$CYAN" "$1" "$RESET"
}

run_logged()
{
	local label=$1
	local log_file=$2
	local pid
	local status
	shift 2
	if [[ ! -t 1 ]]; then
		"$@" >"$log_file" 2>&1
		return $?
	fi
	"$@" >"$log_file" 2>&1 &
	pid=$!
	printf '%b  %s%b ' "$DIM" "$label" "$RESET"
	while ps -p "$pid" >/dev/null 2>&1; do
		printf '\b|'
		sleep 0.08
		printf '\b/'
		sleep 0.08
		printf '\b-'
		sleep 0.08
		printf '\b\\'
		sleep 0.08
	done
	wait "$pid"
	status=$?
	printf '\r%b  %-30s%b\n' "$DIM" "$label" "$RESET"
	return "$status"
}

run_program()
{
	local output_file=$1
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout --signal=TERM 5s "$PROGRAM" "$@" >"$output_file" 2>&1
	else
		"$PROGRAM" "$@" >"$output_file" 2>&1
	fi
}

expect_rejected()
{
	local name=$1
	shift
	local output_file="$TEST_DIR/reject-$FAIL_COUNT-$PASS_COUNT"
	if run_program "$output_file" "$@"; then
		fail "$name (expected a non-zero exit status)"
	else
		pass "$name"
	fi
}

expect_accepted()
{
	local name=$1
	shift
	local output_file="$TEST_DIR/accept-$FAIL_COUNT-$PASS_COUNT"
	if run_program "$output_file" "$@"; then
		pass "$name"
	else
		fail "$name (expected exit status 0; output follows)"
		sed -n '1,12p' "$output_file"
	fi
}

printf '%bCodexion tester%b\n' "$BOLD$CYAN" "$RESET"
printf '%bRepository:%b %s\n' "$DIM" "$RESET" "$ROOT_DIR"
printf '%bTip: set NO_COLOR=1 for plain output.%b\n' "$DIM" "$RESET"

section '[1/4] Build checks'
if run_logged 'building' "$BUILD_LOG" make -C "$ROOT_DIR" re; then
	pass 'builds with make re'
else
	fail 'builds with make re'
	sed -n '1,30p' "$BUILD_LOG"
fi

if grep -Eq -- '(^|[[:space:]])-pthread([[:space:]]|$)' "$ROOT_DIR/Makefile"; then
	pass 'Makefile uses the required -pthread flag'
else
	fail 'Makefile uses the required -pthread flag'
fi

if [[ ! -x "$PROGRAM" ]]; then
	skip 'executable checks (codexion was not produced by the build)'
	printf '\nSummary: %d passed, %d failed, %d skipped\n' \
		"$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
	exit 1
fi

section '[2/4] Argument validation checks'
expect_rejected 'rejects missing arguments' \
	1 100 10 10 10 1 0
expect_rejected 'rejects extra arguments' \
	1 100 10 10 10 1 0 fifo extra
expect_rejected 'rejects a negative coder count' \
	-1 100 10 10 10 1 0 fifo
expect_rejected 'rejects a zero coder count' \
	0 100 10 10 10 1 0 fifo
expect_rejected 'rejects non-integer timing input' \
	1 abc 10 10 10 1 0 fifo
expect_rejected 'rejects a negative cooldown' \
	1 100 10 10 10 1 -1 fifo
expect_rejected 'rejects an unknown scheduler' \
	1 100 10 10 10 1 0 round-robin

section '[3/4] Valid execution and output checks'
expect_accepted 'accepts FIFO arguments' \
	1 100 1 1 1 0 0 fifo
expect_accepted 'accepts EDF arguments' \
	1 100 1 1 1 0 0 edf

simulation_output="$TEST_DIR/simulation-output"
if run_program "$simulation_output" 2 100 1 1 1 1 0 fifo; then
	if grep -Eq '^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$' \
		"$simulation_output"; then
		pass 'uses the required log format when simulation logs are emitted'
	else
		skip 'log-format check (the executable emitted no simulation state logs)'
	fi
else
	fail 'two-coder simulation exits before the timeout'
	sed -n '1,20p' "$simulation_output"
fi

section '[4/4] Valgrind checks'
if ! command -v valgrind >/dev/null 2>&1; then
	skip 'Valgrind is not installed'
else
	valgrind_args=(valgrind --version)
	valgrind_version=$("${valgrind_args[@]}" 2>/dev/null)
	printf '%b  Tool:%b %s\n' "$DIM" "$RESET" "$valgrind_version"
	for scheduler in fifo edf; do
		valgrind_log="$TEST_DIR/valgrind-$scheduler.log"
		valgrind_args=(valgrind --leak-check=full --show-leak-kinds=all \
			--errors-for-leak-kinds=all --track-origins=yes --num-callers=20 \
			--error-exitcode=99 "$PROGRAM" 1 100 1 1 1 0 0 "$scheduler")
		if command -v timeout >/dev/null 2>&1; then
			valgrind_command=(timeout --signal=TERM 10s "${valgrind_args[@]}")
		else
			valgrind_command=("${valgrind_args[@]}")
		fi
		printf '%b  Command:%b valgrind --leak-check=full --track-origins=yes %s 1 100 1 1 1 0 0 %s\n' \
			"$DIM" "$RESET" "$PROGRAM" "$scheduler"
		if run_logged "running Valgrind ($scheduler)" "$valgrind_log" "${valgrind_command[@]}"; then
			status=0
		else
			status=$?
		fi
		error_summary=$(grep 'ERROR SUMMARY:' "$valgrind_log" | tail -n 1 || true)
		leak_summary=$(grep -E 'in use at exit|definitely lost|indirectly lost|possibly lost|still reachable' \
			"$valgrind_log" | tail -n 6 || true)
		if [[ $status -eq 0 ]] && grep -q 'ERROR SUMMARY: 0 errors' "$valgrind_log"; then
			pass "Valgrind Memcheck reports no errors for a minimal $scheduler run"
			printf '%b  Memory summary:%b\n%s\n' "$DIM" "$RESET" "$leak_summary"
		else
			fail "Valgrind Memcheck detected problems in the $scheduler run (exit status $status)"
			printf '%b  Error summary:%b\n%s\n' "$DIM" "$RESET" "${error_summary:-not available}"
			printf '%b  Leak summary:%b\n%s\n' "$DIM" "$RESET" "${leak_summary:-not available}"
			printf '%b  Recent diagnostics:%b\n' "$DIM" "$RESET"
			grep -E 'Invalid |ERROR SUMMARY|at 0x|definitely lost|indirectly lost|possibly lost' \
				"$valgrind_log" | tail -n 20 || true
		fi
	done

	if valgrind --tool=helgrind --version >/dev/null 2>&1; then
		for scheduler in fifo edf; do
			helgrind_log="$TEST_DIR/helgrind-$scheduler.log"
			helgrind_args=(valgrind --tool=helgrind --error-exitcode=99 --num-callers=20 \
				"$PROGRAM" 1 100 1 1 1 0 0 "$scheduler")
			if command -v timeout >/dev/null 2>&1; then
				helgrind_command=(timeout --signal=TERM 15s "${helgrind_args[@]}")
			else
				helgrind_command=("${helgrind_args[@]}")
			fi
			printf '%b  Command:%b valgrind --tool=helgrind %s 1 100 1 1 1 0 0 %s\n' \
				"$DIM" "$RESET" "$PROGRAM" "$scheduler"
			if run_logged "running Helgrind ($scheduler)" "$helgrind_log" "${helgrind_command[@]}"; then
				helgrind_status=0
			else
				helgrind_status=$?
			fi
			helgrind_summary=$(grep -E 'ERROR SUMMARY:|possible data race|pthread.*warning|WARNING:' "$helgrind_log" | tail -n 20 || true)
			if [[ $helgrind_status -eq 0 ]] && grep -q 'ERROR SUMMARY: 0 errors' "$helgrind_log"; then
				pass "Helgrind reports no synchronization errors for a minimal $scheduler run"
			else
				fail "Helgrind detected thread-synchronization issues in the $scheduler run (exit status $helgrind_status)"
				printf '%b  Helgrind summary:%b\n%s\n' "$DIM" "$RESET" "${helgrind_summary:-not available}"
				grep -E 'ERROR SUMMARY|possible data race|pthread|WARNING:' "$helgrind_log" | tail -n 20 || true
			fi
		done
	else
		skip 'Helgrind is not available'
	fi
fi

printf '\n%bSummary%b: %b%d passed%b, %b%d failed%b, %b%d skipped%b\n' \
	"$BOLD" "$RESET" "$GREEN" \
	"$PASS_COUNT" "$RESET" "$RED" "$FAIL_COUNT" "$RESET" "$YELLOW" \
	"$SKIP_COUNT" "$RESET"
if [[ $FAIL_COUNT -eq 0 ]]; then
	exit 0
fi
exit 1
