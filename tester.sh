#!/usr/bin/env bash

# Codexion smoke, validation, timing, and Valgrind tester.

set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROGRAM="$ROOT_DIR/codexion"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_NAMES=()
SCHEDULER=fifo
SCHEDULER_LABEL=FIFO
SIM_TIMEOUT=10
# Several coders so Helgrind sees real contention on shared dongles.
VALGRIND_ARGS=(3 400 20 20 20 2 0)
BURNOUT_TOLERANCE_MS=10
SECTION_COUNT=6
SECTION_INDEX=0
SECTION_TITLE=''
CURRENT_GROUP=''
INDENT='  '

if [[ ${1:-} == '-lifo' ]]; then
	SCHEDULER=lifo
	SCHEDULER_LABEL=LIFO
elif [[ $# -gt 0 ]]; then
	printf 'Usage: %s [-lifo]\n' "$0" >&2
	exit 2
fi

if [[ -t 1 ]]; then
	IS_TTY=1
else
	IS_TTY=0
fi

if [[ $IS_TTY -eq 1 && -z "${NO_COLOR:-}" ]]; then
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

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*UTF-8* | *utf-8* | *UTF8* | *utf8*)
		OK_MARK='✓'
		FAIL_MARK='✗'
		SKIP_MARK='○'
		RULE_CHAR='─'
		GUTTER='│'
		SEP='·'
		NOTE='♪'
		SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
		;;
	*)
		OK_MARK='+'
		FAIL_MARK='x'
		SKIP_MARK='-'
		RULE_CHAR='-'
		GUTTER='|'
		SEP='-'
		NOTE='~'
		SPIN_FRAMES=('|' '/' '-' '\')
		;;
esac

WIDTH=$(tput cols 2>/dev/null || printf '72')
if [[ ! $WIDTH =~ ^[0-9]+$ || $WIDTH -gt 72 ]]; then
	WIDTH=72
elif [[ $WIDTH -lt 40 ]]; then
	WIDTH=40
fi

if command -v timeout >/dev/null 2>&1; then
	TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
	TIMEOUT_CMD=gtimeout
else
	TIMEOUT_CMD=''
fi

cleanup()
{
	if [[ $IS_TTY -eq 1 ]]; then
		printf '\033[?25h'
	fi
	make -C "$ROOT_DIR" clean >/dev/null 2>&1 || true
	rm -f "$BUILD_LOG"
	rm -rf "$TEST_DIR"
}
BUILD_LOG=$(mktemp)
TEST_DIR=$(mktemp -d)
trap cleanup EXIT

# On a timeout, glibc's pthread_cond_timedwait can call pthread_cond_signal
# itself before it relocks the mutex, and Helgrind blames the caller. Only
# that glibc-internal call is matched; a program's own call is still reported.
HELGRIND_SUPP="$TEST_DIR/helgrind.supp"
cat >"$HELGRIND_SUPP" <<'EOF'
{
   glibc-condvar-timedwait-internal-signal
   Helgrind:Misc
   fun:pthread_cond_signal_WRK
   fun:pthread_cond_signal@*
   fun:__pthread_cond_wait_common
}
EOF

repeat()
{
	local out
	printf -v out '%*s' "$2" ''
	printf '%s' "${out// /$1}"
}

# Prints "label  value" rows under the banner.
info()
{
	printf '  %b%-10s%b %s\n' "$DIM" "$1" "$RESET" "$2"
}

section()
{
	local fill
	SECTION_INDEX=$((SECTION_INDEX + 1))
	SECTION_TITLE=$1
	CURRENT_GROUP=$1
	INDENT='  '
	fill=$((WIDTH - ${#1} - 9))
	printf '\n%b%s%s%b %b%d/%d%b  %b%s%b %b%s%b\n' \
		"$DIM" "$RULE_CHAR" "$RULE_CHAR" "$RESET" \
		"$DIM" "$SECTION_INDEX" "$SECTION_COUNT" "$RESET" \
		"$BOLD$CYAN" "$1" "$RESET" \
		"$DIM" "$(repeat "$RULE_CHAR" "$fill")" "$RESET"
}

subsection()
{
	CURRENT_GROUP="$SECTION_TITLE $SEP $1"
	INDENT='    '
	printf '\n  %b%s%b\n' "$BOLD" "$1" "$RESET"
}

# Usage: pass <name> [note shown dimmed after the name]
pass()
{
	printf '%s%b%s%b %s' "$INDENT" "$GREEN" "$OK_MARK" "$RESET" "$1"
	if [[ -n ${2:-} ]]; then
		printf '  %b%s%b' "$DIM" "$2" "$RESET"
	fi
	printf '\n'
	PASS_COUNT=$((PASS_COUNT + 1))
}

# Usage: fail <name> [reason shown below the name]
fail()
{
	printf '%s%b%s %s%b\n' "$INDENT" "$RED" "$FAIL_MARK" "$1" "$RESET"
	if [[ -n ${2:-} ]]; then
		detail "$2" "$RED"
	fi
	FAIL_COUNT=$((FAIL_COUNT + 1))
	FAILED_NAMES+=("$CURRENT_GROUP $SEP $1")
}

skip()
{
	printf '%s%b%s%b %s' "$INDENT" "$YELLOW" "$SKIP_MARK" "$RESET" "$1"
	if [[ -n ${2:-} ]]; then
		printf '  %b%s%b' "$DIM" "$2" "$RESET"
	fi
	printf '\n'
	SKIP_COUNT=$((SKIP_COUNT + 1))
}

# Usage: detail <text> [color]
detail()
{
	printf '%s  %b%s%b %b%s%b\n' "$INDENT" "$DIM" "$GUTTER" "$RESET" \
		"${2:-}" "$1" "$RESET"
}

detail_lines()
{
	local line
	while IFS= read -r line; do
		detail "$line" "$DIM"
	done
}

# Shows the first lines of a captured output file under a failed check.
show_output()
{
	local file=$1
	local max=$2
	local total
	if [[ ! -s $file ]]; then
		detail '(no output)' "$DIM"
		return
	fi
	head -n "$max" "$file" | detail_lines
	total=$(wc -l <"$file")
	if [[ $total -gt $max ]]; then
		detail "... $((total - max)) more lines" "$DIM"
	fi
}

# Strips the ==PID== prefix from Valgrind output.
strip_valgrind()
{
	sed -e 's/^==[0-9]*== *//'
}

# Usage: valgrind_failure <name> <tool> <status> <log_file> <pattern> <command>
valgrind_failure()
{
	local diagnostics
	if [[ $3 -eq 0 ]]; then
		fail "$1" "$2 printed no ERROR SUMMARY"
	else
		fail "$1" "$2 reported problems ($(describe_status "$3"))"
	fi
	detail "command: $6" "$DIM"
	diagnostics=$(grep -E "$5" "$4" | strip_valgrind | awk '!seen[$0]++' | tail -n 12)
	if [[ -z $diagnostics ]]; then
		diagnostics=$(strip_valgrind <"$4" \
			| grep -Ev '^$|, a .* detector$|^Copyright|^Using Valgrind|^Command:' \
			| tail -n 8)
	fi
	printf '%s\n' "$diagnostics" | detail_lines
}

# Pixel-art sprites for the dancing cat, two pixel rows per terminal row.
# K outline, O grey fur, L light belly, P nose, G eyes, Y music note, "." empty.
CAT_SPRITES=(
	'.....K....K.....
....KOK..KOK....
....KOOKKOOK....
....KOOOOOOK....
KK..KOGOOGOK..KK
KOK.KOOOOOOK.KOK
.KOK.KOOOOK.KOK.
..KOKKKOOKKKOK..
...KOOLLLLOOK...
....KOLLLLOK....
....KOLLLLOK....
....KOOOOOOK....
....KOK..KOK....
....KK....KK....
................
................'
	'................
.....K....K.....
....KOK..KOK....
....KOOKKOOK....
....KOOOOOOK....
....KOGOOGOK....
....KOOOOOOK....
.....KOOOOK.....
....KKOOOOKK....
...KOKLLLLKOK.K.
...KOKLLLLKOKKOK
....KOLLLLOK.KOK
....KOOOOOOKKOK.
....KOK..KOK....
....KK....KK....
................'
	'.....K....K.....
....KOK..KOK....
....KOOKKOOK....
....KOOOOOOK....
KK..KOGOOGOK..KK
KOK.KOOOOOOK.KOK
.KOK.KOOOOK.KOK.
..KOKKKOOKKKOK..
...KOOLLLLOOK...
....KOLLLLOK....
....KOLLLLOK....
....KOOOOOOK....
....KOK..KOK....
....KK....KK....
................
................'
	'................
.....K....K.....
....KOK..KOK....
....KOOKKOOK....
....KOOOOOOK....
....KOGOOGOK....
....KOOOOOOK....
.....KOOOOK.....
....KKOOOOKK....
...KOKLLLLKOK.K.
...KOKLLLLKOKKOK
....KOLLLLOK.KOK
....KOOOOOOKKOK.
....KOK..KOK....
....KK....KK....
................'
)

# Sets REPLY to the 256-color code for a sprite pixel, or empty if blank.
pixel_color()
{
	case $1 in
		K) REPLY=238 ;;
		O) REPLY=245 ;;
		L) REPLY=252 ;;
		P) REPLY=234 ;;
		G) REPLY=38 ;;
		Y) REPLY=220 ;;
		*) REPLY='' ;;
	esac
}

# Sets REPLY to a sprite drawn with half blocks, one line per two pixel rows.
# Usage: render_sprite <sprite> <left padding>
render_sprite()
{
	local esc=$'\033'
	local rows
	local out=''
	local r
	local c
	local top
	local bottom
	IFS=$'\n' read -r -d '' -a rows <<<"$1"
	for ((r = 0; r < ${#rows[@]}; r += 2)); do
		out+=$2
		for ((c = 0; c < ${#rows[r]}; c++)); do
			pixel_color "${rows[r]:c:1}"
			top=$REPLY
			pixel_color "${rows[r + 1]:c:1}"
			bottom=$REPLY
			if [[ -z $top && -z $bottom ]]; then
				out+=' '
			elif [[ -z $bottom ]]; then
				out+="$esc[38;5;${top}m▀$esc[0m"
			elif [[ -z $top ]]; then
				out+="$esc[38;5;${bottom}m▄$esc[0m"
			else
				out+="$esc[38;5;${top};48;5;${bottom}m▀$esc[0m"
			fi
		done
		out+=$'\n'
	done
	REPLY=$out
}

# Plays frames in place. Usage: play_frames <height> <frames...>
play_frames()
{
	local height=$1
	local frame_count
	local line
	local i
	shift
	frame_count=$#
	local frames=("$@")
	printf '\033[?25l'
	for ((i = 0; i < 16; i++)); do
		if [[ $i -gt 0 ]]; then
			printf '\033[%dA' "$height"
		fi
		while IFS= read -r line; do
			printf '\r\033[K%s\n' "$line"
		done <<<"${frames[$((i % frame_count))]%$'\n'}"
		sleep 0.2
	done
	printf '\033[?25h'
}

# A short dancing cat for a fully green run; terminals only. Uses the
# pixel-art cat when the terminal has 256 colors and UTF-8, else ASCII.
dance()
{
	local frames
	local colors
	local i
	local pads=('    ' '     ' '      ' '     ')
	if [[ $IS_TTY -eq 0 || -n ${NO_ANIMATION:-} ]]; then
		return
	fi
	colors=$(tput colors 2>/dev/null || printf '8')
	if [[ $NOTE != '~' && -z ${NO_COLOR:-} && $colors =~ ^[0-9]+$ && $colors -ge 256 ]]; then
		frames=()
		for ((i = 0; i < ${#CAT_SPRITES[@]}; i++)); do
			render_sprite "${CAT_SPRITES[i]}" "${pads[i]}"
			frames+=("$REPLY")
		done
		play_frames 8 "${frames[@]}"
		return
	fi
	dance_ascii
}

# ASCII fallback; in the frames, "N" is replaced with a music note.
dance_ascii()
{
	local ascii_frames
	local i
	ascii_frames=(
'          N
    /\_/\
   ( ^.^ )/
   /|   |
    /   \ '
'   N        N
 \  /\_/\  /
  \( ^o^ )/
     |   |
    /     \ '
'   N
\   /\_/\
 \ ( ^.^ )
    |   |\
    /   \ '
'   N        N
 \  /\_/\  /
  \( ^o^ )/
     |   |
    /     \ '
	)
	for ((i = 0; i < 4; i++)); do
		ascii_frames[i]="      $DIM${ascii_frames[i]//N/$NOTE}$RESET"
		ascii_frames[i]=${ascii_frames[i]//$'\n'/$'\n'"      $DIM"}
	done
	play_frames 5 "${ascii_frames[@]}"
}

print_summary()
{
	local failed_color=$DIM
	local skipped_color=$DIM
	local name
	if [[ $FAIL_COUNT -gt 0 ]]; then
		failed_color=$RED
	fi
	if [[ $SKIP_COUNT -gt 0 ]]; then
		skipped_color=$YELLOW
	fi
	printf '\n%b%s%b\n' "$DIM" "$(repeat "$RULE_CHAR" "$WIDTH")" "$RESET"
	printf '  %b%d passed%b %b%s%b %b%d failed%b %b%s%b %b%d skipped%b   %b%ds%b\n' \
		"$GREEN" "$PASS_COUNT" "$RESET" "$DIM" "$SEP" "$RESET" \
		"$failed_color" "$FAIL_COUNT" "$RESET" "$DIM" "$SEP" "$RESET" \
		"$skipped_color" "$SKIP_COUNT" "$RESET" "$DIM" "$SECONDS" "$RESET"
	if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
		printf '\n  %bFailed checks%b\n' "$BOLD" "$RESET"
		for name in "${FAILED_NAMES[@]}"; do
			printf '    %b%s%b %s\n' "$RED" "$FAIL_MARK" "$RESET" "$name"
		done
		if [[ $FAIL_COUNT -eq 1 ]]; then
			printf '\n  %b%s 1 check failed%b\n\n' "$BOLD$RED" "$FAIL_MARK" "$RESET"
		else
			printf '\n  %b%s %d checks failed%b\n\n' "$BOLD$RED" "$FAIL_MARK" \
				"$FAIL_COUNT" "$RESET"
		fi
	else
		printf '\n'
		dance
		printf '\n  %b%s All checks passed%b\n\n' "$BOLD$GREEN" "$OK_MARK" "$RESET"
	fi
}

# Runs a command with a time limit; returns 124 when the limit is hit.
with_timeout()
{
	local seconds=$1
	local pid
	local watcher
	local status
	shift
	if [[ -n $TIMEOUT_CMD ]]; then
		"$TIMEOUT_CMD" --signal=TERM "${seconds}s" "$@"
		return $?
	fi
	"$@" &
	pid=$!
	(sleep "$seconds"; kill -TERM "$pid" 2>/dev/null) >/dev/null 2>&1 &
	watcher=$!
	wait "$pid"
	status=$?
	if kill "$watcher" 2>/dev/null; then
		return "$status"
	fi
	return 124
}

describe_status()
{
	local status=$1
	if [[ $status -eq 124 ]]; then
		printf 'timed out'
	elif [[ $status -gt 128 ]]; then
		printf 'killed by signal %d' $((status - 128))
	else
		printf 'exit status %d' "$status"
	fi
}

# Runs a command with its output captured, showing a spinner while it runs.
run_logged()
{
	local label=$1
	local log_file=$2
	local pid
	local status
	local frame=0
	shift 2
	if [[ $IS_TTY -eq 0 ]]; then
		"$@" >"$log_file" 2>&1
		return $?
	fi
	"$@" >"$log_file" 2>&1 &
	pid=$!
	printf '\033[?25l'
	while kill -0 "$pid" 2>/dev/null; do
		printf '\r%s%b%s%b %b%s%b' "$INDENT" "$CYAN" "${SPIN_FRAMES[$frame]}" \
			"$RESET" "$DIM" "$label" "$RESET"
		frame=$(((frame + 1) % ${#SPIN_FRAMES[@]}))
		sleep 0.08
	done
	wait "$pid"
	status=$?
	printf '\r\033[K\033[?25h'
	return "$status"
}

run_program()
{
	local output_file=$1
	shift
	with_timeout 5 "$PROGRAM" "$@" >"$output_file" 2>&1
}

expect_rejected()
{
	local name=$1
	local output_file="$TEST_DIR/reject-$FAIL_COUNT-$PASS_COUNT"
	local status
	shift
	run_program "$output_file" "$@"
	status=$?
	# A crash, signal, or timeout is not a clean rejection.
	if [[ $status -ge 1 && $status -lt 124 ]]; then
		pass "$name"
	else
		fail "$name" "expected an error exit, got $(describe_status "$status")"
		detail "args: $*" "$DIM"
		show_output "$output_file" 8
	fi
}

expect_accepted()
{
	local name=$1
	local output_file="$TEST_DIR/accept-$FAIL_COUNT-$PASS_COUNT"
	local status
	shift
	run_program "$output_file" "$@"
	status=$?
	if [[ $status -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit status 0, got $(describe_status "$status")"
		detail "args: $*" "$DIM"
		show_output "$output_file" 8
	fi
}

# Validates a simulation log line by line, then checks the expected outcome.
# Usage: check_log <log_file> <survive|burnout|any> <program arguments...>
# "any" accepts either outcome, but a burnout must still be on time.
#
# Coders sit in a ring and coder i shares one dongle with each neighbour.
# Dongle use is checked from compile start times plus time_to_compile, not
# from the "is debugging" line, because a correct program may release its
# dongles and let a neighbour log first.
check_log()
{
	local log_file=$1
	local expectation=$2
	shift 2
	awk -v coders="$1" -v burnout_ms="$2" -v compile_ms="$3" \
		-v required="${6:-0}" -v cooldown_ms="${7:-0}" \
		-v expectation="$expectation" -v tolerance="$BURNOUT_TOLERANCE_MS" '
		function fail(msg) {
			print msg > "/dev/stderr"
			failed = 1
			exit 1
		}
		# Fails when coder "other" still holds, or is cooling down, a dongle
		# that coder "id" needs to start compiling at ts.
		function check_dongle(other,    free_at) {
			if (!(other in started))
				return
			free_at = last_compile[other] + compile_ms + cooldown_ms
			if (ts < free_at - 1) {
				if (other == id)
					fail("coder " id " compiles again at " ts " ms, its dongles are busy or cooling down until " free_at " ms")
				fail("coder " id " compiles at " ts " ms while coder " other " holds a shared dongle (busy or cooling down until " free_at " ms)")
			}
		}
		BEGIN {
			last_ts = -1
		}
		$0 !~ /^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$/ {
			fail("line " NR " is malformed: " $0)
		}
		{
			ts = $1 + 0
			id = $2 + 0
			if (ts < last_ts)
				fail("timestamp goes backwards at line " NR)
			last_ts = ts
			if (id < 1 || id > coders)
				fail("unknown coder id " id " at line " NR)
			if (burned_id)
				fail("output continues after the burnout at line " NR)
			# Any coder past its deadline should already have burned out.
			for (c = 1; c <= coders; c++) {
				if (c == id && $3 == "burned")
					continue
				if (ts > last_compile[c] + burnout_ms + tolerance)
					fail("coder " c " missed its deadline at " last_compile[c] + burnout_ms " ms, but no burnout was logged by " ts " ms (line " NR ")")
			}
		}
		/has taken a dongle$/ {
			if (phase[id] == "compile" || phase[id] == "debug")
				fail("coder " id " takes a dongle before debugging and refactoring at line " NR)
			phase[id] = "take"
			if (++held[id] > 2)
				fail("coder " id " holds more than two dongles at line " NR)
		}
		/is compiling$/ {
			if (held[id] != 2)
				fail("coder " id " compiles without two dongles at line " NR)
			check_dongle(id)
			check_dongle(id == 1 ? coders : id - 1)
			check_dongle(id == coders ? 1 : id + 1)
			phase[id] = "compile"
			held[id] = 0
			compiles[id]++
			started[id] = 1
			last_compile[id] = ts
		}
		/is debugging$/ {
			if (phase[id] != "compile")
				fail("coder " id " debugs without compiling first at line " NR)
			phase[id] = "debug"
		}
		/is refactoring$/ {
			if (phase[id] != "debug")
				fail("coder " id " refactors without debugging first at line " NR)
			phase[id] = "refactor"
		}
		/burned out$/ {
			burned_id = id
			deadline = last_compile[id] + burnout_ms
			if (ts < deadline - 1 || ts > deadline + tolerance)
				fail("coder " id " burned out at " ts " ms, expected " deadline " ms (+" tolerance ")")
		}
		END {
			if (failed)
				exit 1
			if (expectation == "burnout" && !burned_id)
				fail("expected a burnout, none was logged")
			if (expectation == "survive" && burned_id)
				fail("coder " burned_id " burned out unexpectedly")
			# A run that ends without a burnout must have met the compile goal.
			if (!burned_id)
				for (c = 1; c <= coders; c++)
					if (compiles[c] < required)
						fail("coder " c " compiled " compiles[c] + 0 " of " required " times")
		}
	' "$log_file"
}

# Usage: check_simulation <name> <survive|burnout|any> <program arguments...>
check_simulation()
{
	local name=$1
	local expectation=$2
	shift 2
	local log_file
	local status
	local reason
	log_file="$TEST_DIR/sim-$(printf '%s-' "$@")"
	run_logged "$name" "$log_file" with_timeout "$SIM_TIMEOUT" "$PROGRAM" "$@"
	status=$?
	if [[ $status -ne 0 ]]; then
		fail "$name" "$(describe_status "$status")"
		detail "args: $*" "$DIM"
		show_output "$log_file" 12
		return
	fi
	if reason=$(check_log "$log_file" "$expectation" "$@" 2>&1); then
		pass "$name"
	else
		fail "$name" "$reason"
		detail "args: $*" "$DIM"
		show_output "$log_file" 12
	fi
}

# Usage: run_case_table <scheduler> <cases...>
# Each case is "fifo|lifo|edf|args|label": the expected outcome for each
# scheduler, the program arguments, and an optional label (defaults to args).
run_case_table()
{
	local scheduler=$1
	local case_spec
	local fifo
	local lifo
	local edf
	local args
	local label
	local expectation
	local case_argv
	shift
	for case_spec in "$@"; do
		IFS='|' read -r fifo lifo edf args label <<<"$case_spec"
		case $scheduler in
			fifo) expectation=$fifo ;;
			lifo) expectation=$lifo ;;
			*) expectation=$edf ;;
		esac
		read -r -a case_argv <<<"$args"
		check_simulation "$(printf '%-8s %s' "$expectation" "${label:-$args}")" \
			"$expectation" "${case_argv[@]}" "$scheduler"
	done
}

if command -v valgrind >/dev/null 2>&1; then
	VALGRIND_VERSION=$(valgrind --version 2>/dev/null)
else
	VALGRIND_VERSION=''
fi

printf '\n  %bCodexion Tester%b\n' "$BOLD$CYAN" "$RESET"
printf '  %b%s%b\n' "$DIM" "$(repeat "$RULE_CHAR" 15)" "$RESET"
info 'project' "${ROOT_DIR/#"$HOME"/\~}"
info 'scheduler' "$SCHEDULER $SEP edf"
info 'timeout' "${TIMEOUT_CMD:-shell fallback}"
info 'valgrind' "${VALGRIND_VERSION:-not installed}"

section 'Build'
if run_logged 'running make re' "$BUILD_LOG" make -C "$ROOT_DIR" re; then
	pass 'builds with make re'
else
	fail 'builds with make re' 'make re failed; compiler output follows'
	show_output "$BUILD_LOG" 20
fi

if grep -Eq -- '(^|[[:space:]])-pthread([[:space:]]|$)' "$ROOT_DIR/Makefile"; then
	pass 'Makefile uses the -pthread flag'
else
	fail 'Makefile uses the -pthread flag' 'add -pthread to the compile and link flags'
fi

if [[ ! -x "$PROGRAM" ]]; then
	skip 'remaining checks' 'codexion was not produced by the build'
	print_summary
	exit 1
fi

section 'Argument validation'
expect_rejected 'rejects missing arguments' \
	1 100 10 10 10 1 0
expect_rejected 'rejects extra arguments' \
	1 100 10 10 10 1 0 "$SCHEDULER" extra
expect_rejected 'rejects a negative coder count' \
	-1 100 10 10 10 1 0 "$SCHEDULER"
expect_rejected 'rejects a zero coder count' \
	0 100 10 10 10 1 0 "$SCHEDULER"
expect_rejected 'rejects non-integer timing input' \
	1 abc 10 10 10 1 0 "$SCHEDULER"
expect_rejected 'rejects a negative cooldown' \
	1 100 10 10 10 1 -1 "$SCHEDULER"
expect_rejected 'rejects an unknown scheduler' \
	1 100 10 10 10 1 0 round-robin
expect_rejected "rejects uppercase $SCHEDULER_LABEL" \
	1 100 10 10 10 1 0 "$SCHEDULER_LABEL"
expect_rejected 'rejects uppercase EDF' \
	1 100 10 10 10 1 0 EDF
expect_rejected "rejects malformed $SCHEDULER scheduler input" \
	1 100 10 10 10 1 0 "${SCHEDULER%?}0"
expect_rejected 'rejects malformed edf scheduler input' \
	1 100 10 10 10 1 0 edff
if [[ $SCHEDULER == fifo ]]; then
	expect_rejected 'rejects lifo (use -lifo for the LIFO build)' \
		1 100 10 10 10 1 0 lifo
fi

section 'Execution'
expect_accepted "accepts $SCHEDULER_LABEL arguments" \
	1 100 1 1 1 0 0 "$SCHEDULER"
expect_accepted 'accepts EDF arguments' \
	1 100 1 1 1 0 0 edf
check_simulation "single coder burns out within ${BURNOUT_TOLERANCE_MS} ms" burnout \
	1 5 100 100 100 1 0 "$SCHEDULER"

section 'Simulations'

# Expected outcome per scheduler (fifo|lifo|edf), then the arguments.
# LIFO may starve a coder under contention, so busy cases accept any outcome.
simulation_cases=(
	'survive|any|survive|2 100 1 1 1 1 0'
	'survive|any|survive|3 100 1 1 1 1 0'
	'survive|any|survive|4 100 1 1 1 1 0'
	'survive|any|survive|5 100 1 1 1 1 0'
	'survive|any|survive|10 100 1 1 1 1 0'
	'survive|any|survive|2 50 5 5 5 1 0'
	'survive|any|survive|3 200 10 10 10 1 0'
	'burnout|burnout|burnout|4 100 100 10 10 10 0'
	'survive|any|survive|4 200 50 20 20 2 0'
	'survive|any|survive|6 300 20 20 20 2 0'
)

# Cases where the scheduling policy decides the outcome. In the first one,
# coder A finishes at 10 ms and asks again at 12 ms while coder B has been
# waiting since 0 ms; the dongles cool down until 60 ms. FIFO and EDF serve
# B, while LIFO keeps serving A, so B burns out at 150 ms.
policy_cases=(
	'survive|burnout|survive|2 150 10 1 1 5 50|waiting coder vs. re-request during cooldown'
	'survive|survive|survive|2 300 10 30 30 3 20|cooldown shorter than idle time'
	'survive|survive|survive|4 400 20 50 50 3 0|uncontended dongles'
)

for scheduler in "$SCHEDULER" edf; do
	subsection "$scheduler"
	run_case_table "$scheduler" "${simulation_cases[@]}"
done

section 'Scheduling policy'
for scheduler in "$SCHEDULER" edf; do
	subsection "$scheduler"
	run_case_table "$scheduler" "${policy_cases[@]}"
done

section 'Valgrind'
if [[ -z $VALGRIND_VERSION ]]; then
	skip 'Memcheck and Helgrind' 'valgrind is not installed'
else
	subsection 'Memcheck'
	for scheduler in "$SCHEDULER" edf; do
		valgrind_log="$TEST_DIR/valgrind-$scheduler.log"
		valgrind_cmd=(valgrind --leak-check=full --show-leak-kinds=all \
			--errors-for-leak-kinds=all --track-origins=yes --num-callers=20 \
			--error-exitcode=99 "$PROGRAM" "${VALGRIND_ARGS[@]}" "$scheduler")
		if run_logged "$scheduler" "$valgrind_log" with_timeout 30 "${valgrind_cmd[@]}"; then
			status=0
		else
			status=$?
		fi
		if [[ $status -eq 0 ]] && grep -q 'ERROR SUMMARY: 0 errors' "$valgrind_log"; then
			if grep -q 'All heap blocks were freed' "$valgrind_log"; then
				pass "$scheduler" 'no errors, all heap blocks freed'
			else
				pass "$scheduler" "no errors, $(grep -o 'in use at exit: .*' "$valgrind_log" | head -n 1)"
			fi
		else
			valgrind_failure "$scheduler" Memcheck "$status" "$valgrind_log" \
				'ERROR SUMMARY|Invalid |uninitialised|definitely lost|indirectly lost|possibly lost|still reachable' \
				"valgrind --leak-check=full ./${PROGRAM##*/} ${VALGRIND_ARGS[*]} $scheduler"
		fi
	done

	subsection 'Helgrind'
	if valgrind --tool=helgrind --version >/dev/null 2>&1; then
		for scheduler in "$SCHEDULER" edf; do
			helgrind_log="$TEST_DIR/helgrind-$scheduler.log"
			if run_logged "$scheduler" "$helgrind_log" with_timeout 30 \
				valgrind --tool=helgrind --suppressions="$HELGRIND_SUPP" \
				--error-exitcode=99 --num-callers=20 \
				"$PROGRAM" "${VALGRIND_ARGS[@]}" "$scheduler"; then
				helgrind_status=0
			else
				helgrind_status=$?
			fi
			if [[ $helgrind_status -eq 0 ]] && grep -q 'ERROR SUMMARY: 0 errors' "$helgrind_log"; then
				pass "$scheduler" 'no synchronization errors'
			else
				valgrind_failure "$scheduler" Helgrind "$helgrind_status" "$helgrind_log" \
					'ERROR SUMMARY|Possible data race|lock order|Thread #[0-9]+: |Thread #[0-9]+ (unlocked|was created|is the program)' \
					"valgrind --tool=helgrind ./${PROGRAM##*/} ${VALGRIND_ARGS[*]} $scheduler"
			fi
		done
	else
		skip 'Helgrind' 'tool not available'
	fi
fi

print_summary
if [[ $FAIL_COUNT -eq 0 ]]; then
	exit 0
fi
exit 1
