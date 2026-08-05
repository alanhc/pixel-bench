#!/usr/bin/env bash
#
# cpu-bench.sh - per-cluster CPU microbenchmark for Pixel 8 (shiba) via simpleperf PMU counters.
#
# Pins every cpufreq policy to the `performance` governor, runs a workload bound to each
# cluster in turn, and reports IPC / effective clock / miss rates from the ARMv8 PMU.
# The original governors are always restored, including on Ctrl-C or an early failure.
#
# Cluster layout on shiba (Tensor G3):
#   little  cpu0-3  Cortex-A510  0xd46  1.704 GHz  policy0
#   mid     cpu4-7  Cortex-A715  0xd4d  2.367 GHz  policy4
#   big     cpu8    Cortex-X3    0xd4e  2.914 GHz  policy8
#
# Two measured facts drive the design, both verified on this device:
#
#   1. task-clock must be in every event list. simpleperf divides by wall-clock time
#      when it is absent, so a workload that ever sleeps reports a nonsense clock
#      (hello_test read as 0.75 GHz that way; with task-clock it reads correctly).
#
#   2. At most THREE hardware events per run. A fourth silently triggers counter
#      multiplexing, and simpleperf does not scale the counts back up: task-clock is
#      a software event that keeps running while the hardware counters are rotated
#      out, so every rate computed against it is quietly deflated. Measured on cpu8
#      with the governor pinned and the core verified at 2.914 GHz via
#      scaling_cur_freq:
#           3 hw events -> 2.916 GHz    (correct)
#           4 hw events -> 2.073 GHz    (-29%)
#           5 hw events -> 1.679 GHz    (-42%)
#           6 hw events -> 1.355 GHz    (-54%)
#      Hence the counters are collected in several passes of three, each repeating
#      cpu-cycles so the passes can be cross-checked against each other.
#
#   3. The generic event aliases are NOT portable across these three cores, and they
#      fail silently. `branch-instructions` resolves to raw-br-immed-retired, which
#      `simpleperf list raw` reports as "supported on cpu 0-7" - on the X3 it yields
#      either 0 or a garbage 1.7M against a true count of 14M. `L1-dcache-load-misses`
#      resolves to raw-l1d-cache-refill-rd, supported only on cpu 0-3,8, so the A715
#      cluster is wrong too. This script therefore uses raw ARM event names that
#      `simpleperf list raw` confirms on cpu 0-8. The cross-check: the branch count
#      must come out nearly identical on all three clusters, since it is the same
#      instruction stream. It now does (~14M everywhere).
#
#      Before adding an event with -e, check its support mask:
#          adb shell simpleperf list raw | grep <event>
#
set -uo pipefail

WORKLOAD=""
REPEATS=3
COOLDOWN=3
SELECT="little,mid,big"
EXTRA_EVENTS=""
DO_L3=0
DO_PIN=1
PIN_GOV=performance
BENCH_MB=64
REMOTE_DIR=/data/local/tmp/cpubench
FALLBACK_GOV=sched_pixel

# Each pass is task-clock plus at most three hardware events. cpu-cycles rides along
# in every pass as a consistency check; the passes must agree on the clock.
# Every hardware event here is confirmed supported on cpu 0-8 - see note 3 above.
PASS_CORE="task-clock,cpu-cycles,instructions"
PASS_BRANCH="task-clock,cpu-cycles,raw-br-retired,raw-br-mis-pred-retired"
PASS_L1="task-clock,cpu-cycles,raw-l1d-cache,raw-l1d-cache-refill"
L3_EVENTS="arm_dsu_0/l3d_cache/,arm_dsu_0/l3d_cache_refill/"

# name:affinity-mask:cpufreq-policy:representative-cpu
CLUSTERS=("little:0f:0:0" "mid:f0:4:4" "big:100:8:8")

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

  -w CMD     Device-side workload to measure. Default: sha256sum over a ${BENCH_MB}MB
             file in ${REMOTE_DIR} (generated on first run, then page-cache warm).
  -r N       Repeats per cluster (default ${REPEATS}).
  -c LIST    Clusters to measure, comma separated: little,mid,big (default all).
  -k SEC     Cooldown between runs (default ${COOLDOWN}). Raise it if the thermal
             delta warning keeps firing.
  -e LIST    Run one extra pass with these events and print the raw counts. Keep it
             to three hardware events or the numbers will be deflated; task-clock is
             added automatically. Useful for raw ARM event codes, e.g.
             -e stalled-cycles-backend,stalled-cycles-frontend
  -s SERIAL  adb serial (otherwise \$ANDROID_SERIAL, otherwise the only device).
  -g GOV     Governor to pin for the measurement (default ${PIN_GOV}). The other
             useful value is 'powersave', which parks each cluster at its floor -
             324 MHz on the A510s, 402 on the A715s, 500 on the X3 - for a low-power
             figure. Anything in scaling_available_governors works.
  --orig GOV Governor to restore at exit, if the saved one looks like leftover state
             from an interrupted run (default ${FALLBACK_GOV}).
  --l3       Add a system-wide DSU pass for shared-L3 traffic. Uncore PMUs cannot be
             opened per-process at all (they fail with EINVAL), so this round counts
             the whole system, not only the workload.
  --no-pin   Leave the governors alone and measure the device as shipped
             (sched_pixel). Useful to see how much DVFS is costing you.
  -h         This help.

Examples:
  ${0##*/}                                  # default workload, all three clusters
  ${0##*/} -w /data/local/tmp/hello_test    # measure your own binary
  ${0##*/} -c big -r 10 --l3                # X3 only, ten runs, with L3 traffic
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-w) WORKLOAD="$2"; shift 2 ;;
	-r) REPEATS="$2"; shift 2 ;;
	-c) SELECT="$2"; shift 2 ;;
	-k) COOLDOWN="$2"; shift 2 ;;
	-e) EXTRA_EVENTS="$2"; shift 2 ;;
	-g) PIN_GOV="$2"; shift 2 ;;
	-s) export ANDROID_SERIAL="$2"; shift 2 ;;
	--orig) FALLBACK_GOV="$2"; shift 2 ;;
	--l3) DO_L3=1; shift ;;
	--no-pin) DO_PIN=0; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

ash() { adb shell "$@"; }
die() { echo "error: $*" >&2; exit 1; }

# "% of peak" is only a fault signal when we asked for the top clock. Under powersave
# the clock is supposed to sit near the floor, so the warning would fire on every row.
CHECK_PEAK=0
[[ $DO_PIN -eq 1 && "$PIN_GOV" == "performance" ]] && CHECK_PEAK=1

# ---------------------------------------------------------------- device setup

adb get-state >/dev/null 2>&1 || die "no device (adb get-state failed)"
adb root >/dev/null 2>&1
adb wait-for-device
[[ "$(ash id -u | tr -d '\r')" == "0" ]] || die "adbd is not root; 'adb root' was refused"
ash command -v simpleperf >/dev/null || die "simpleperf not found on device"

PARANOID=$(ash cat /proc/sys/kernel/perf_event_paranoid | tr -d '\r')
[[ "$PARANOID" -le 1 ]] || die "perf_event_paranoid=$PARANOID blocks PMU access"

# ------------------------------------------------------- governor save/restore

POLICIES=$(ash 'ls /sys/devices/system/cpu/cpufreq/' | tr -d '\r' | tr '\n' ' ')
declare -A ORIG_GOV
RESTORE_NEEDED=0

restore_governors() {
	[[ $RESTORE_NEEDED -eq 1 ]] || return 0
	RESTORE_NEEDED=0
	echo
	echo "restoring governors..."
	local p
	for p in "${!ORIG_GOV[@]}"; do
		ash "echo ${ORIG_GOV[$p]} > /sys/devices/system/cpu/cpufreq/$p/scaling_governor" 2>/dev/null
		printf '  %-8s -> %s\n' "$p" "$(ash cat /sys/devices/system/cpu/cpufreq/$p/scaling_governor | tr -d '\r')"
	done
}
trap restore_governors EXIT INT TERM

pin_governors() {
	local p suspect=0
	for p in $POLICIES; do
		ORIG_GOV[$p]=$(ash cat "/sys/devices/system/cpu/cpufreq/$p/scaling_governor" | tr -d '\r')
		[[ "${ORIG_GOV[$p]}" == "$PIN_GOV" ]] && suspect=1
	done

	# A device already sitting in the governor we are about to pin almost always means
	# an earlier run was killed before its restore. Saving that would make the pinning
	# permanent, so fall back to the known default instead.
	if [[ $suspect -eq 1 ]]; then
		echo "warning: found a policy already on '$PIN_GOV' - that is normally"
		echo "         leftover state from an interrupted run, not the device default."
		echo "         will restore to '$FALLBACK_GOV' instead (override with --orig)."
		for p in $POLICIES; do
			[[ "${ORIG_GOV[$p]}" == "$PIN_GOV" ]] && ORIG_GOV[$p]="$FALLBACK_GOV"
		done
	fi

	RESTORE_NEEDED=1
	for p in $POLICIES; do
		ash "echo $PIN_GOV > /sys/devices/system/cpu/cpufreq/$p/scaling_governor" 2>/dev/null
	done
	printf 'governors pinned to %s (will restore:' "$PIN_GOV"
	for p in $POLICIES; do printf ' %s=%s' "$p" "${ORIG_GOV[$p]}"; done
	printf ')\n'
}

# -------------------------------------------------------------------- thermals

thermal_line() {
	ash 'for z in /sys/class/thermal/thermal_zone*/; do
	       t=$(cat $z/type 2>/dev/null)
	       case "$t" in BIG|MID|LITTLE|quiet_therm) echo "$t=$(cat $z/temp 2>/dev/null)";; esac
	     done' | tr -d '\r' | awk -F= '{printf "%s=%.1fC ", $1, $2/1000}'
}

# -------------------------------------------------------------------- workload

if [[ -z "$WORKLOAD" ]]; then
	BENCH_FILE="$REMOTE_DIR/bench.bin"
	ash "mkdir -p $REMOTE_DIR"
	if ! ash "test -s $BENCH_FILE"; then
		echo "generating ${BENCH_MB}MB workload file at $BENCH_FILE ..."
		ash "dd if=/dev/urandom of=$BENCH_FILE bs=1M count=$BENCH_MB" >/dev/null 2>&1 ||
			die "could not create $BENCH_FILE"
	fi
	WORKLOAD="toybox sha256sum $BENCH_FILE"
fi

# ------------------------------------------------------------- measurement

# measure <mask> <events> [extra simpleperf args...]
# Emits one `event_name=count` line per counter; task-clock is in milliseconds.
measure() {
	local mask="$1" events="$2"
	shift 2
	ash "simpleperf stat --csv -e $events $* -- taskset $mask $WORKLOAD" 2>&1 |
		tr -d '\r' |
		awk -F, '{ gsub(/\(ms\)/, "", $1) }
		         NF >= 2 && $1 ~ /^[0-9.]+$/ && $2 != "" { print $2 "=" $1 }'
}

# Runs the three passes for one repetition and fills the caller's C[] array.
# task-clock and cpu-cycles appear in every pass; the first one wins.
collect() {
	local mask="$1" k v pass
	local -n out=$2
	out=()
	for pass in "$PASS_CORE" "$PASS_BRANCH" "$PASS_L1"; do
		while IFS== read -r k v; do
			if [[ -n "$k" && -z "${out[$k]:-}" ]]; then out["$k"]=$v; fi
		done < <(measure "$mask" "$pass")
	done
}

fmt() { awk -v a="$1" -v b="$2" -v s="${3:-1}" 'BEGIN { printf "%.3f\n", (b ? s*a/b : 0) }'; }

# --------------------------------------------------------------------- run it

echo "=== shiba CPU bench ==="
echo "workload : $WORKLOAD"
echo "passes   : core[$PASS_CORE]"
echo "           branch[$PASS_BRANCH]"
echo "           l1[$PASS_L1]"
[[ -n "$EXTRA_EVENTS" ]] && echo "           extra[task-clock,$EXTRA_EVENTS]"
echo "repeats  : $REPEATS   cooldown: ${COOLDOWN}s"
echo "thermal  : $(thermal_line)"
echo

if [[ $DO_PIN -eq 1 ]]; then pin_governors; else echo "governors left as-is (--no-pin)"; fi
echo

printf '%-7s %4s %10s %8s %6s %8s %9s %10s\n' \
	CLUSTER RUN "TIME(ms)" "GHz" "IPC" "BR(M)" "BR-MISS%" "L1D-MISS%"
printf '%.0s-' {1..70}; echo

for entry in "${CLUSTERS[@]}"; do
	IFS=: read -r name mask policy cpu <<<"$entry"
	[[ ",$SELECT," == *",$name,"* ]] || continue

	maxkhz=$(ash cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq" | tr -d '\r')

	# Warm-up: pulls the workload file into page cache and lets the clock settle, so
	# run 1 is not systematically slower than the rest.
	measure "$mask" "$PASS_CORE" >/dev/null

	sum_ipc=0 sum_ghz=0 n=0
	t_before=$(thermal_line)

	for ((i = 1; i <= REPEATS; i++)); do
		declare -A C
		collect "$mask" C

		tc=${C[task-clock]:-0} cyc=${C[cpu-cycles]:-0} ins=${C[instructions]:-0}
		if [[ "$cyc" == "0" || "$tc" == "0" ]]; then
			echo "  !! no counters returned for $name (run $i); giving up on this cluster" >&2
			unset C
			break
		fi

		br=${C[raw-br-retired]:-0} brm=${C[raw-br-mis-pred-retired]:-0}
		l1=${C[raw-l1d-cache]:-0} l1m=${C[raw-l1d-cache-refill]:-0}

		ghz=$(fmt "$cyc" "$(awk -v t="$tc" 'BEGIN{print t*1e6}')")
		ipc=$(fmt "$ins" "$cyc")
		brpct=$(fmt "$brm" "$br" 100)
		l1pct=$(fmt "$l1m" "$l1" 100)
		brm_m=$(awk -v b="$br" 'BEGIN{printf "%.1f", b/1e6}')

		printf '%-7s %4d %10.1f %8s %6s %8s %9s %10s\n' \
			"$name" "$i" "$tc" "$ghz" "$ipc" "$brm_m" "$brpct" "$l1pct"

		# A counter reading exactly zero means the event is not implemented on this
		# core, not that the workload never triggered it. That is how the generic
		# aliases fail (see note 3); catch it for anything passed via -e too.
		zeros=""
		for k in instructions raw-br-retired raw-br-mis-pred-retired raw-l1d-cache raw-l1d-cache-refill; do
			[[ "${C[$k]:-0}" == "0" ]] && zeros+=" $k"
		done
		[[ -n "$zeros" ]] && echo "         !! zero count on$zeros - unsupported on cpu$cpu?" >&2

		sum_ipc=$(awk -v a="$sum_ipc" -v b="$ipc" 'BEGIN{print a+b}')
		sum_ghz=$(awk -v a="$sum_ghz" -v b="$ghz" 'BEGIN{print a+b}')
		n=$((n + 1))
		unset C
		[[ $i -lt $REPEATS ]] && command sleep "$COOLDOWN"
	done

	if [[ $n -gt 0 ]]; then
		awk -v name="$name" -v si="$sum_ipc" -v sg="$sum_ghz" -v n="$n" -v maxkhz="$maxkhz" -v pinned="$CHECK_PEAK" '
		BEGIN {
			ghz = sg/n; cap = maxkhz/1e6; pct = 100*ghz/cap
			printf "%-7s %4s %10s %8.3f %6.3f   (mean of %d, cap %.3f GHz -> %.0f%% of peak)\n",
			  name, "avg", "", ghz, si/n, n, cap, pct
			if (pinned && pct < 90)
				printf "         !! %.0f%% of peak with the governor pinned: expect either thermal\n" \
				       "            throttling or counter multiplexing. Check the thermal deltas\n" \
				       "            below, and keep any -e pass to three hardware events.\n", pct
		}'
	fi

	echo "         thermal before: $t_before"
	echo "         thermal after : $(thermal_line)"
	echo

	command sleep "$COOLDOWN"
done

# ------------------------------------------------------------------ extra pass

if [[ -n "$EXTRA_EVENTS" ]]; then
	echo "=== extra pass: $EXTRA_EVENTS ==="
	for entry in "${CLUSTERS[@]}"; do
		IFS=: read -r name mask policy cpu <<<"$entry"
		[[ ",$SELECT," == *",$name,"* ]] || continue
		printf '%-7s ' "$name"
		measure "$mask" "task-clock,$EXTRA_EVENTS" | tr '\n' ' '
		echo
		command sleep "$COOLDOWN"
	done
	echo
fi

# ----------------------------------------------------------------- shared L3

if [[ $DO_L3 -eq 1 ]]; then
	echo "=== shared L3 (DSU, system-wide) ==="
	echo "uncore PMUs cannot be opened per-process, so these counts include all system"
	echo "activity during the workload, not only the workload itself."
	echo
	printf '%-7s %14s %14s %8s\n' CLUSTER "L3-ACCESS" "L3-REFILL" "MISS%"
	printf '%.0s-' {1..48}; echo
	for entry in "${CLUSTERS[@]}"; do
		IFS=: read -r name mask policy cpu <<<"$entry"
		[[ ",$SELECT," == *",$name,"* ]] || continue
		acc=0 ref=0
		while IFS== read -r k v; do
			case "$k" in
			*l3d_cache_refill*) ref=$v ;;
			*l3d_cache*) acc=$v ;;
			esac
		done < <(measure "$mask" "$L3_EVENTS" "-a")
		awk -v name="$name" -v a="$acc" -v r="$ref" 'BEGIN {
			printf "%-7s %14d %14d %7.2f%%\n", name, a, r, (a ? 100*r/a : 0) }'
		command sleep "$COOLDOWN"
	done
	echo
fi

# restore_governors runs from the EXIT trap
