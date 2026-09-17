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
RUN_HELGRIND=0

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

STATUS_COL=78
declare -A CAT_PASS CAT_FAIL CAT_SKIP
CAT_ORDER=()
CURRENT_CATEGORY=""

pass()
{
	printf '%bPASS%b: %s\n' "$GREEN" "$RESET" "$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	CAT_PASS[$CURRENT_CATEGORY]=$(( ${CAT_PASS[$CURRENT_CATEGORY]:-0} + 1 ))
}

fail()
{
	printf '%bFAIL%b: %s\n' "$RED" "$RESET" "$1"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	CAT_FAIL[$CURRENT_CATEGORY]=$(( ${CAT_FAIL[$CURRENT_CATEGORY]:-0} + 1 ))
}

skip()
{
	printf '%bSKIP%b: %s\n' "$YELLOW" "$RESET" "$1"
	SKIP_COUNT=$((SKIP_COUNT + 1))
	CAT_SKIP[$CURRENT_CATEGORY]=$(( ${CAT_SKIP[$CURRENT_CATEGORY]:-0} + 1 ))
}

section_tally()
{
	local cat=$1
	local p=${CAT_PASS[$cat]:-0}
	local f=${CAT_FAIL[$cat]:-0}
	local s=${CAT_SKIP[$cat]:-0}
	local color=$GREEN
	((f > 0)) && color=$RED
	printf '%b  -> %d passed, %d failed, %d skipped%b\n' "$color" "$p" "$f" "$s" "$RESET"
}

section()
{
	if [[ -n "$CURRENT_CATEGORY" ]]; then
		section_tally "$CURRENT_CATEGORY"
	fi
	CURRENT_CATEGORY="$1"
	CAT_ORDER+=("$1")
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
	local timeout_s="${RUN_TIMEOUT_S:-5}"
	if command -v timeout >/dev/null 2>&1; then
		timeout --signal=TERM "${timeout_s}s" "$PROGRAM" "$@" >"$output_file" 2>&1
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

check_log_consistency()
{
	local log_file=$1
	local coder_count=$2
	awk -v coder_count="$coder_count" '
		function fail(msg) {
			print "incoherent log: " msg > "/dev/stderr"
			exit 1
		}
		{
			if ($0 ~ /^[0-9]+ [0-9]+ has taken a dongle$/) {
				taken[$2] = 1
				next
			}
			if ($0 ~ /^[0-9]+ [0-9]+ is compiling$/) {
				if (taken[$2] != 1) {
					fail("coder " $2 " compiles without taking a dongle first")
				}
				taken[$2] = 0
				next
			}
			if ($0 ~ /^[0-9]+ [0-9]+ burned out$/) {
				if (coder_count == 1 && taken[$2] != 1) {
					next
				}
				if (taken[$2] == 1) {
					taken[$2] = 0
					next
				}
			}
		}
		END {
			for (c in taken) {
				if (taken[c] == 1) {
					fail("coder " c " ended with a dongle still held")
				}
			}
		}
	' "$log_file"
}

get_burnout_ms()
{
	# Prints the first "burned out" timestamp (log column 1) for a given coder id.
	local log_file=$1
	local coder_id=$2
	awk -v id="$coder_id" '$2 == id && $3 == "burned" { print $1; exit }' "$log_file"
}

check_no_burnout()
{
	local name=$1
	local log_file=$2
	if grep -Eq '^[0-9]+ [0-9]+ burned out$' "$log_file"; then
		fail "$name (a coder burned out, but none should have)"
		grep -E 'burned out' "$log_file" | sed -n '1,10p'
	else
		pass "$name"
	fi
}

check_at_least_one_burnout()
{
	local name=$1
	local log_file=$2
	if grep -Eq '^[0-9]+ [0-9]+ burned out$' "$log_file"; then
		pass "$name"
	else
		fail "$name (expected at least one coder to burn out)"
	fi
}

check_min_compile_count()
{
	# Verifies every coder compiled at least $min_count times.
	local name=$1
	local log_file=$2
	local coder_count=$3
	local min_count=$4
	awk -v coders="$coder_count" -v min_count="$min_count" '
		$0 ~ /^[0-9]+ [0-9]+ is compiling$/ { counts[$2]++ }
		END {
			for (i = 1; i <= coders; i++) {
				if (counts[i] + 0 < min_count) {
					print "coder " i " compiled " (counts[i] + 0) " time(s), expected at least " min_count
					exit 1
				}
			}
		}
	' "$log_file" >"$TEST_DIR/min-compile-detail" 2>&1
	if [[ $? -eq 0 ]]; then
		pass "$name"
	else
		fail "$name"
		sed -n '1,10p' "$TEST_DIR/min-compile-detail"
	fi
}

check_single_coder_never_compiles()
{
	local name=$1
	local log_file=$2
	if grep -Eq '^[0-9]+ [0-9]+ is compiling$' "$log_file"; then
		fail "$name (a lone coder should never be able to compile)"
	else
		pass "$name"
	fi
}

check_burnout_timing()
{
	# Verifies a coder's burnout timestamp is within tolerance_ms of expected_ms.
	local name=$1
	local log_file=$2
	local coder_id=$3
	local expected_ms=$4
	local tolerance_ms=$5
	local actual_ms
	actual_ms=$(get_burnout_ms "$log_file" "$coder_id")
	if [[ -z "$actual_ms" ]]; then
		fail "$name (no burnout logged for coder $coder_id)"
		return
	fi
	local diff=$((actual_ms - expected_ms))
	if ((diff < 0)); then
		diff=$((-diff))
	fi
	if ((diff <= tolerance_ms)); then
		pass "$name (burned out at ${actual_ms}ms, expected ~${expected_ms}ms)"
	else
		fail "$name (burned out at ${actual_ms}ms, expected ~${expected_ms}ms, diff ${diff}ms > ${tolerance_ms}ms)"
	fi
}

check_refactor_before_dongle()
{
	# Verifies no coder takes a dongle less than refactor_ms after its previous
	# compile finished (best-effort: uses "is refactoring" -> next "has taken a
	# dongle" gap per coder).
	local name=$1
	local log_file=$2
	local refactor_ms=$3
	local tolerance_ms=$4
	awk -v refactor_ms="$refactor_ms" -v tol="$tolerance_ms" '
		$0 ~ /^[0-9]+ [0-9]+ is refactoring$/ { start[$2] = $1; next }
		$0 ~ /^[0-9]+ [0-9]+ has taken a dongle$/ {
			if ($2 in start) {
				gap = $1 - start[$2]
				if (gap + tol < refactor_ms) {
					print "coder " $2 " re-acquired a dongle after only " gap "ms (< " refactor_ms "ms refactor time)"
					exit 1
				}
				delete start[$2]
			}
		}
	' "$log_file" >"$TEST_DIR/refactor-detail" 2>&1
	if [[ $? -eq 0 ]]; then
		pass "$name"
	else
		fail "$name"
		sed -n '1,10p' "$TEST_DIR/refactor-detail"
	fi
}

check_no_interleaved_lines()
{
	# Verifies every line matches the expected single-line log format (i.e. no
	# two messages got interleaved / merged onto one line).
	local name=$1
	local log_file=$2
	if awk '!/^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$/ && NF > 0 { print; bad = 1 } END { exit bad }' "$log_file" >"$TEST_DIR/interleave-detail" 2>&1; then
		pass "$name"
	else
		fail "$name (malformed or interleaved log lines found)"
		sed -n '1,10p' "$TEST_DIR/interleave-detail"
	fi
}

print_final_summary()
{
	printf '\n%bSummary by category%b\n' "$BOLD$CYAN" "$RESET"
	if [[ -n "$CURRENT_CATEGORY" ]]; then
		section_tally "$CURRENT_CATEGORY"
	fi
	local max_len=0
	local cat
	for cat in "${CAT_ORDER[@]}"; do
		((${#cat} > max_len)) && max_len=${#cat}
	done
	for cat in "${CAT_ORDER[@]}"; do
		local p=${CAT_PASS[$cat]:-0}
		local f=${CAT_FAIL[$cat]:-0}
		local s=${CAT_SKIP[$cat]:-0}
		local color=$GREEN
		((f > 0)) && color=$RED
		((f == 0 && p == 0 && s > 0)) && color=$YELLOW
		printf '  %b%-*s%b  %2d passed  %2d failed  %2d skipped\n' \
			"$color" "$max_len" "$cat" "$RESET" "$p" "$f" "$s"
	done

	printf '\n%bOverall%b: %b%d passed%b, %b%d failed%b, %b%d skipped%b\n' \
		"$BOLD" "$RESET" "$GREEN" \
		"$PASS_COUNT" "$RESET" "$RED" "$FAIL_COUNT" "$RESET" "$YELLOW" \
		"$SKIP_COUNT" "$RESET"
}

printf '%bCodexion tester%b\n' "$BOLD$CYAN" "$RESET"
printf '%bRepository:%b %s\n' "$DIM" "$RESET" "$ROOT_DIR"
printf '%bTip: set NO_COLOR=1 for plain output.%b\n' "$DIM" "$RESET"

section '[1/5] Build checks'
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
	print_final_summary
	exit 1
fi

section '[2/5] Argument validation checks'
expect_rejected 'rejects missing arguments' \
	1 100 10 10 10 1 0
expect_rejected 'rejects extra arguments' \
	1 100 10 10 10 1 0 fifo extra
expect_rejected 'rejects a negative coder count' \
	-1 100 10 10 10 1 0 fifo
expect_rejected 'rejects a zero coder count' \
	0 100 10 10 10 1 0 fifo
expect_accepted 'accepts a single coder that burns out' \
	1 5 100 100 100 1 0 fifo
expect_rejected 'rejects non-integer timing input' \
	1 abc 10 10 10 1 0 fifo
expect_rejected 'rejects a negative cooldown' \
	1 100 10 10 10 1 -1 fifo
expect_rejected 'rejects an unknown scheduler' \
	1 100 10 10 10 1 0 round-robin
expect_rejected 'rejects uppercase FIFO' \
	1 100 10 10 10 1 0 FIFO
expect_rejected 'rejects uppercase EDF' \
	1 100 10 10 10 1 0 EDF
expect_rejected 'rejects malformed fifo scheduler input' \
	1 100 10 10 10 1 0 fif0
expect_rejected 'rejects malformed edf scheduler input' \
	1 100 10 10 10 1 0 edff

section '[3/5] Valid execution and output checks'
expect_accepted 'accepts FIFO arguments' \
	1 100 1 1 1 0 0 fifo
expect_accepted 'accepts EDF arguments' \
	1 100 1 1 1 0 0 edf

simulation_output="$TEST_DIR/simulation-output"
if run_program "$simulation_output" 2 100 1 1 1 1 0 fifo; then
	if grep -Eq '^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$' \
		"$simulation_output"; then
		pass 'uses the required log format when simulation logs are emitted'
		if check_log_consistency "$simulation_output" 2 >/dev/null 2>&1; then
			pass 'logs are coherent for a valid two-coder run'
		else
			fail 'logs are incoherent for a valid two-coder run'
			sed -n '1,20p' "$simulation_output"
		fi
	else
		skip 'log-format check (the executable emitted no simulation state logs)'
	fi
else
	fail 'two-coder simulation exits before the timeout'
	sed -n '1,20p' "$simulation_output"
fi

single_coder_log="$TEST_DIR/single-coder-log"
if run_program "$single_coder_log" 1 5 100 100 100 1 0 fifo; then
	if check_log_consistency "$single_coder_log" 1 >/dev/null 2>&1; then
		pass 'single-coder burnout log is coherent'
	else
		fail 'single-coder burnout log is inconsistent'
		sed -n '1,20p' "$single_coder_log"
	fi
else
	fail 'single-coder simulation exits unexpectedly'
	sed -n '1,20p' "$single_coder_log"
fi

stress_cases_fifo=(
	'2 100 1 1 1 1 0 fifo'
	'3 100 1 1 1 1 0 fifo'
	'4 100 1 1 1 1 0 fifo'
	'5 100 1 1 1 1 0 fifo'
	'10 100 1 1 1 1 0 fifo'
	'2 50 5 5 5 1 0 fifo'
	'3 200 10 10 10 1 0 fifo'
	'4 100 100 10 10 10 0 fifo'
	'4 200 50 20 20 2 0 fifo'
	'6 300 20 20 20 2 0 fifo'
)
stress_cases_edf=(
	'2 100 1 1 1 1 0 edf'
	'3 100 1 1 1 1 0 edf'
	'4 100 1 1 1 1 0 edf'
	'5 100 1 1 1 1 0 edf'
	'10 100 1 1 1 1 0 edf'
	'2 50 5 5 5 1 0 edf'
	'3 200 10 10 10 1 0 edf'
	'4 100 100 10 10 10 0 edf'
	'4 200 50 20 20 2 0 edf'
	'6 300 20 20 20 2 0 edf'
)

for scheduler_name in fifo edf; do
	case "$scheduler_name" in
		fifo) cases=("${stress_cases_fifo[@]}") ;;
		edf) cases=("${stress_cases_edf[@]}") ;;
	esac
	stress_ok=0
	stress_failed_cases=()
	stress_first_fail_log=""
	for case_args in "${cases[@]}"; do
		stress_log="$TEST_DIR/stress-$(echo "$case_args" | tr ' ' '-')"
		if command -v timeout >/dev/null 2>&1; then
			timeout --signal=TERM 30s "$PROGRAM" $case_args >"$stress_log" 2>&1
			status=$?
		else
			run_program "$stress_log" $case_args
			status=$?
		fi
		if [[ $status -eq 0 ]]; then
			stress_ok=$((stress_ok + 1))
		else
			stress_failed_cases+=("$case_args")
			[[ -z "$stress_first_fail_log" ]] && stress_first_fail_log="$stress_log"
		fi
	done
	total=${#cases[@]}
	if ((stress_ok == total)); then
		pass "stress ($scheduler_name): $stress_ok/$total cases completed cleanly"
	else
		fail "stress ($scheduler_name): $stress_ok/$total cases completed cleanly"
		printf '%b  Hung or exited early:%b\n' "$DIM" "$RESET"
		printf '    %s\n' "${stress_failed_cases[@]}"
		if [[ -n "$stress_first_fail_log" ]]; then
			printf '%b  Output from first failing case (%s):%b\n' "$DIM" "${stress_failed_cases[0]}" "$RESET"
			sed -n '1,15p' "$stress_first_fail_log"
		fi
	fi
done

section '[4/5] Valgrind checks'
if ! command -v valgrind >/dev/null 2>&1; then
	skip 'Valgrind is not installed'
else
	valgrind_args=(valgrind --version)
	valgrind_version=$("${valgrind_args[@]}" 2>/dev/null)
	printf '%b  Tool:%b %s\n' "$DIM" "$RESET" "$valgrind_version"

	# label:args:timeout_seconds
	# - minimal:   original 1-coder smoke case (barely any concurrency)
	# - contention: several coders actually fighting over dongles/mutexes
	# - cooldown:  exercises the release -> cooldown -> re-acquire path
	memcheck_scenarios=(
		'minimal:1 100 1 1 1 0 0:10'
		'contention:4 300 50 50 50 3 0:20'
		'cooldown:4 300 50 50 50 3 100:20'
	)

	for scenario in "${memcheck_scenarios[@]}"; do
		IFS=':' read -r mc_label mc_args mc_timeout <<<"$scenario"
		for scheduler in fifo edf; do
			valgrind_log="$TEST_DIR/valgrind-$mc_label-$scheduler.log"
			valgrind_args=(valgrind --leak-check=full --show-leak-kinds=all \
				--errors-for-leak-kinds=all --track-origins=yes --num-callers=20 \
				--error-exitcode=99 "$PROGRAM" $mc_args "$scheduler")
			if command -v timeout >/dev/null 2>&1; then
				valgrind_command=(timeout --signal=TERM "${mc_timeout}s" "${valgrind_args[@]}")
			else
				valgrind_command=("${valgrind_args[@]}")
			fi
			if run_logged "running Valgrind ($mc_label, $scheduler)" "$valgrind_log" "${valgrind_command[@]}"; then
				status=0
			else
				status=$?
			fi
			if [[ $status -eq 0 ]] && grep -q 'ERROR SUMMARY: 0 errors' "$valgrind_log"; then
				pass "Valgrind Memcheck reports no errors ($mc_label, $scheduler)"
			else
				fail "Valgrind Memcheck detected problems ($mc_label, $scheduler, exit status $status)"
				printf '%b  Command:%b valgrind --leak-check=full --track-origins=yes %s %s %s\n' \
					"$DIM" "$RESET" "$PROGRAM" "$mc_args" "$scheduler"
				error_summary=$(grep 'ERROR SUMMARY:' "$valgrind_log" | tail -n 1 || true)
				leak_summary=$(grep -E 'in use at exit|definitely lost|indirectly lost|possibly lost|still reachable' \
					"$valgrind_log" | tail -n 6 || true)
				printf '%b  Error summary:%b\n%s\n' "$DIM" "$RESET" "${error_summary:-not available}"
				printf '%b  Leak summary:%b\n%s\n' "$DIM" "$RESET" "${leak_summary:-not available}"
				printf '%b  Recent diagnostics:%b\n' "$DIM" "$RESET"
				grep -E 'Invalid |ERROR SUMMARY|at 0x|definitely lost|indirectly lost|possibly lost' \
					"$valgrind_log" | tail -n 20 || true
			fi
		done
	done

	if [[ "${RUN_HELGRIND:-0}" == "1" ]]; then
		if valgrind --tool=helgrind --version >/dev/null 2>&1; then
			# label:args:timeout_seconds:repeats
			# Races are often intermittent, so contention cases run more than once;
			# the minimal case has almost no shared state and stays a single check.
			helgrind_scenarios=(
				'minimal:1 100 1 1 1 0 0:15:1'
				'contention:4 300 50 50 50 3 0:20:3'
			)

			for scenario in "${helgrind_scenarios[@]}"; do
				IFS=':' read -r hg_label hg_args hg_timeout hg_repeats <<<"$scenario"
				for scheduler in fifo edf; do
					hg_failed_run=0
					hg_last_log=""
					for ((run_index = 1; run_index <= hg_repeats; run_index++)); do
						helgrind_log="$TEST_DIR/helgrind-$hg_label-$scheduler-$run_index.log"
						hg_last_log="$helgrind_log"
						helgrind_args=(valgrind --tool=helgrind --error-exitcode=99 --num-callers=20 \
							"$PROGRAM" $hg_args "$scheduler")
						if command -v timeout >/dev/null 2>&1; then
							helgrind_command=(timeout --signal=TERM "${hg_timeout}s" "${helgrind_args[@]}")
						else
							helgrind_command=("${helgrind_args[@]}")
						fi
						if ((hg_repeats > 1)); then
							run_label="running Helgrind ($hg_label, $scheduler, run $run_index/$hg_repeats)"
						else
							run_label="running Helgrind ($hg_label, $scheduler)"
						fi
						if run_logged "$run_label" "$helgrind_log" "${helgrind_command[@]}"; then
							helgrind_status=0
						else
							helgrind_status=$?
						fi
						if ! { [[ $helgrind_status -eq 0 ]] && grep -q 'ERROR SUMMARY: 0 errors' "$helgrind_log"; }; then
							hg_failed_run=$run_index
							break
						fi
					done
					if [[ $hg_failed_run -eq 0 ]]; then
						if ((hg_repeats > 1)); then
							pass "Helgrind reports no synchronization errors ($hg_label, $scheduler, $hg_repeats runs)"
						else
							pass "Helgrind reports no synchronization errors ($hg_label, $scheduler)"
						fi
					else
						fail "Helgrind detected thread-synchronization issues ($hg_label, $scheduler, run $hg_failed_run/$hg_repeats)"
						printf '%b  Command:%b valgrind --tool=helgrind %s %s %s\n' \
							"$DIM" "$RESET" "$PROGRAM" "$hg_args" "$scheduler"
						helgrind_summary=$(grep -E 'ERROR SUMMARY:|possible data race|pthread.*warning|WARNING:' "$hg_last_log" | tail -n 20 || true)
						printf '%b  Helgrind summary:%b\n%s\n' "$DIM" "$RESET" "${helgrind_summary:-not available}"
						grep -E 'ERROR SUMMARY|possible data race|pthread|WARNING:' "$hg_last_log" | tail -n 20 || true
					fi
				done
			done
		else
			skip 'Helgrind is not available'
		fi
	else
		skip 'Helgrind checks are disabled; set RUN_HELGRIND=1 to enable them'
	fi

fi

# NOTE on ThreadSanitizer (TSan): Helgrind is a reasonable general-purpose
# race detector but is known to both miss some real races and report some
# false positives around custom synchronization patterns. If the Makefile
# can produce a `-fsanitize=thread -g` build of codexion (e.g. `make tsan`),
# it's worth running the contention scenarios above through that binary too
# -- TSan is generally more sensitive and much faster than Helgrind. This
# tester does not build a TSan variant automatically since that requires a
# dedicated Makefile target; add one and re-run this script against it if
# available.


section '[5/5] Codexion subject scenario checks'
TOLERANCE_MS="${TOLERANCE_MS:-10}"
RUN_TIMEOUT_S=10
printf '%b  Tolerance for all timing checks below:%b %sms\n' "$DIM" "$RESET" "$TOLERANCE_MS"

printf '\n%b  -- Easy --%b\n' "$BOLD" "$RESET"

log1="$TEST_DIR/easy-1"
if run_program "$log1" 5 800 200 200 100 7 0 edf; then
	check_no_burnout 'easy/1: no coder burns out (5 800 200 200 100 7 0 edf)' "$log1"
	check_min_compile_count 'easy/1: every coder compiles >= 7 times' "$log1" 5 7
else
	fail 'easy/1: simulation did not exit cleanly (5 800 200 200 100 7 0 edf)'
	sed -n '1,20p' "$log1"
fi

# NOTE: the middle parameters of this test were partially obscured in the
# subject screenshot; verify the exact numbers before relying on this case.
log2="$TEST_DIR/easy-2"
if run_program "$log2" 5 800 200 200 100 5 0 edf; then
	check_no_burnout 'easy/2: no coder burns out (unverified args, see NOTE above)' "$log2"
	check_min_compile_count 'easy/2: every coder compiles >= 5 times' "$log2" 5 5
else
	fail 'easy/2: simulation did not exit cleanly (unverified args)'
	sed -n '1,20p' "$log2"
fi

log3="$TEST_DIR/easy-3"
if run_program "$log3" 5 900 200 200 100 5 0 fifo; then
	check_no_burnout 'easy/3: no coder burns out (5 900 200 200 100 5 0 fifo)' "$log3"
	pass 'easy/3: fifo scheduler accepted and ran to completion'
else
	fail 'easy/3: program did not accept fifo / did not complete (5 900 200 200 100 5 0 fifo)'
	sed -n '1,20p' "$log3"
fi

printf '\n%b  -- Less easy --%b\n' "$BOLD" "$RESET"

log4="$TEST_DIR/less-easy-1"
if run_program "$log4" 1 800 200 200 100 1 0 edf; then
	check_single_coder_never_compiles 'less-easy/1: lone coder never compiles (1 800 200 200 100 1 0 edf)' "$log4"
	check_at_least_one_burnout 'less-easy/1: lone coder burns out' "$log4"
	check_burnout_timing 'less-easy/1: burnout timestamp within tolerance' "$log4" 1 800 "$TOLERANCE_MS"
else
	fail 'less-easy/1: simulation did not exit cleanly (1 800 200 200 100 1 0 edf)'
	sed -n '1,20p' "$log4"
fi

log5="$TEST_DIR/less-easy-2"
if run_program "$log5" 2 310 200 200 100 3 0 edf; then
	check_at_least_one_burnout 'less-easy/2: a coder burns out (2 310 200 200 100 3 0 edf)' "$log5"
	burned_id=$(awk '/^[0-9]+ [0-9]+ burned out$/ { print $2; exit }' "$log5")
	if [[ -n "$burned_id" ]]; then
		check_burnout_timing 'less-easy/2: burnout timestamp within tolerance' "$log5" "$burned_id" 310 "$TOLERANCE_MS"
	fi
else
	fail 'less-easy/2: simulation did not exit cleanly (2 310 200 200 100 3 0 edf)'
	sed -n '1,20p' "$log5"
fi

log6="$TEST_DIR/less-easy-3"
if run_program "$log6" 4 310 200 100 80 5 0 edf; then
	check_at_least_one_burnout 'less-easy/3: at least one coder burns out (4 310 200 100 80 5 0 edf)' "$log6"
	if check_log_consistency "$log6" 4 >/dev/null 2>&1; then
		pass 'less-easy/3: state transitions are coherent, no dongle duplicated'
	else
		fail 'less-easy/3: state transitions incoherent / dongle possibly duplicated'
		sed -n '1,20p' "$log6"
	fi
else
	fail 'less-easy/3: simulation did not exit cleanly (4 310 200 100 80 5 0 edf)'
	sed -n '1,20p' "$log6"
fi

printf '\n%b  -- Medium (still doable) --%b\n' "$BOLD" "$RESET"

# NOTE: the exact cooldown-test arguments were partially obscured in the
# subject screenshot ("... 500 200 200 100 5 100 ..."). Fill in the real
# values here once confirmed; this is a best-effort placeholder.
#
# IMPORTANT LIMITATION: the subject's cooldown test wants proof that a
# *released* dongle isn't re-granted (to anyone) for 100ms. The program's
# log format has no dongle IDs, so there's no way to tell from these logs
# which physical dongle a coder picked up. The check below can only verify
# a weaker property: that each coder itself waits at least ~cooldown ms
# after refactoring before it next acquires a dongle. That does NOT prove
# the released dongle sat out its cooldown before going to a *different*
# coder -- treat a pass here as "no obvious violation for a single coder",
# not as full proof of the cooldown requirement. Verify this one manually.
log7="$TEST_DIR/medium-cooldown"
cooldown_ms=100
if run_program "$log7" 5 1500 200 200 100 5 "$cooldown_ms" fifo; then
	check_no_burnout 'medium/cooldown: no coder burns out (unverified args, see NOTE above)' "$log7"
	check_refactor_before_dongle 'medium/cooldown: per-coder gap before re-acquiring a dongle looks >= cooldown (approximation, see NOTE above)' "$log7" "$cooldown_ms" "$TOLERANCE_MS"
else
	fail 'medium/cooldown: simulation did not exit cleanly (unverified args)'
	sed -n '1,20p' "$log7"
fi

log8a="$TEST_DIR/medium-sched-fifo"
log8b="$TEST_DIR/medium-sched-edf"
status_a=0
status_b=0
run_program "$log8a" 5 900 200 200 100 5 0 fifo || status_a=$?
run_program "$log8b" 5 900 200 200 100 5 0 edf || status_b=$?
if [[ $status_a -eq 0 && $status_b -eq 0 && -s "$log8a" && -s "$log8b" ]]; then
	pass 'medium/scheduler: both fifo and edf runs exit cleanly with output (5 900 200 200 100 5 0 <fifo|edf>)'
	printf '%b  Manual check required:%b under contention, fifo should grant in arrival order and edf should grant by earliest burnout deadline; compare the two logs by hand.\n' "$DIM" "$RESET"
else
	sched_reason=""
	[[ $status_a -ne 0 ]] && sched_reason+="fifo exited $status_a; "
	[[ $status_b -ne 0 ]] && sched_reason+="edf exited $status_b; "
	[[ $status_a -eq 0 && ! -s "$log8a" ]] && sched_reason+="fifo produced no output; "
	[[ $status_b -eq 0 && ! -s "$log8b" ]] && sched_reason+="edf produced no output; "
	fail "medium/scheduler: ${sched_reason%%; }"
	sed -n '1,15p' "$log8a"
	sed -n '1,15p' "$log8b"
fi

# NOTE: the subject line for this test omitted time_to_refactor explicitly
# ("3 1000 200 300 3 0 edf" is 7 tokens, one short of the usual 8); verify
# the real argument list before trusting this case.
log9="$TEST_DIR/medium-refactor"
if run_program "$log9" 3 1000 200 300 300 3 0 edf; then
	check_refactor_before_dongle 'medium/refactor: no coder skips its 300ms refactor before re-acquiring dongles' "$log9" 300 "$TOLERANCE_MS"
else
	fail 'medium/refactor: simulation did not exit cleanly (unverified args)'
	sed -n '1,20p' "$log9"
fi

log10="$TEST_DIR/medium-log-format"
if run_program "$log10" 6 400 50 50 50 3 0 fifo; then
	check_no_interleaved_lines 'medium/log-format: log lines are well-formed and never interleaved under load' "$log10"
else
	fail 'medium/log-format: simulation did not exit cleanly (6 400 50 50 50 3 0 fifo)'
	sed -n '1,20p' "$log10"
fi

print_final_summary
if [[ $FAIL_COUNT -eq 0 ]]; then
	exit 0
fi
exit 1
