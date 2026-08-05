#!/usr/bin/env bash
#
# bench-all.sh - run the CPU, GPU and NPU benchmarks as one job and produce a single
#                cross-unit report.
#
# Why a runner rather than three commands in a row:
#
#   * They must not overlap. cpu-bench.sh pins every cpufreq policy to `performance`
#     and gpu-bench.sh pins the Mali clock; either one distorts the other's numbers,
#     and the GPU/NPU results also move with how fast the CPU can feed them. Stages run
#     strictly in sequence.
#
#   * Heat accumulates across stages. Idle here is 32-34 C and a stage peaks around
#     43 C, so a benchmark run straight after another starts hot and reads slow. Each
#     stage waits for every relevant thermal zone to fall back under --cool first.
#
#   * All the preflight checks happen once, up front. Discovering that adbd is not root
#     or that the TPU service is missing five minutes into a run is pure waste.
#
#   * If a stage dies without restoring the CPU governors or the GPU clock policy, the
#     device is left pinned. Each script restores its own state on EXIT/INT/TERM, but
#     the runner verifies the final state anyway and says so loudly if it is wrong.
#
# Logs and a summary land in --out (default ~/bench/results/<timestamp>/).
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MALI=/sys/devices/platform/1f000000.mali

UNITS="cpu,gpu,npu"
OUT_DIR=""
QUICK=0
SWEEP=0
COOL_C=38
COOL_MAX=120
AFFINITY=""
PIN_GOV=""
ZONES="BIG MID LITTLE G3D TPU"

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

  -u LIST    Units to run, comma separated: cpu,gpu,npu (default all, in that order).
  -o DIR     Output directory (default ~/bench/results/<timestamp>).
  -q         Quick mode - fewer iterations everywhere. Noisier; for smoke tests.
  -s SERIAL  adb serial (otherwise \$ANDROID_SERIAL, otherwise the only device).
  -a CLUSTER Bind the GPU and NPU benchmark processes to little|mid|big|all. The CPU
             stage always covers all three clusters regardless. Worth 62% on the TPU
             between the A510s and the X3, so it is not just a CPU-stage concern.
  -g GOV     Governor for the CPU stage (default performance). 'powersave' parks each
             cluster at its floor - 324/402/500 MHz - for a low-power figure.
  --sweep    Pass --sweep to gpu-bench.sh (all 13 DVFS steps; much longer).
  --cool C   Wait for every thermal zone to drop below C before each stage
             (default ${COOL_C}; idle on this device is 32-34, a stage peaks near 43).
  --cool-max S  Give up waiting after S seconds and run anyway (default ${COOL_MAX}).
  -h         This help.

Examples:
  ${0##*/}                 # full run, all three units
  ${0##*/} -q -u cpu,npu   # quick smoke test, skip the GPU
  ${0##*/} --sweep         # include the GPU DVFS scaling curve
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-u) UNITS="$2"; shift 2 ;;
	-o) OUT_DIR="$2"; shift 2 ;;
	-q) QUICK=1; shift ;;
	-s) export ANDROID_SERIAL="$2"; shift 2 ;;
	-a) AFFINITY="$2"; shift 2 ;;
	-g) PIN_GOV="$2"; shift 2 ;;
	--sweep) SWEEP=1; shift ;;
	--cool) COOL_C="$2"; shift 2 ;;
	--cool-max) COOL_MAX="$2"; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[[ -n "$OUT_DIR" ]] || OUT_DIR="$HERE/results/$(date +%Y%m%d-%H%M%S)"

ash() { adb shell "$@"; }
die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------- preflight

say "preflight"

for s in cpu-bench.sh gpu-bench.sh npu-bench.sh; do
	[[ -x "$HERE/$s" ]] || die "$HERE/$s missing or not executable"
done

adb get-state >/dev/null 2>&1 || die "no device (adb get-state failed)"
adb root >/dev/null 2>&1
adb wait-for-device
[[ "$(ash id -u | tr -d '\r')" == "0" ]] || die "adbd is not root; 'adb root' was refused"

DEVICE=$(ash getprop ro.product.device | tr -d '\r')
BUILD=$(ash getprop ro.build.display.id | tr -d '\r')
KERNEL=$(ash uname -r | tr -d '\r')
echo "device : $DEVICE  ($BUILD, kernel $KERNEL)"

fail=0
check() { # check <label> <shell-test-on-device>
	if ash "$2" >/dev/null 2>&1; then
		printf '  ok    %s\n' "$1"
	else
		printf '  FAIL  %s\n' "$1"
		fail=1
	fi
}

[[ ",$UNITS," == *",cpu,"* ]] && {
	check "simpleperf present" "command -v simpleperf"
	check "cpufreq policies writable" "test -w /sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
	check "perf_event_paranoid <= 1" "test \$(cat /proc/sys/kernel/perf_event_paranoid) -le 1"
}
[[ ",$UNITS," == *",gpu,"* ]] && {
	check "mali sysfs" "test -d $MALI"
	check "mali clock pinnable" "test -w $MALI/scaling_max_freq -a -w $MALI/power_policy"
	check "OpenCL library" "test -e /vendor/lib64/libOpenCL.so"
}
[[ ",$UNITS," == *",npu,"* ]] && {
	check "rio inference counter" "test -e /sys/devices/platform/1a000000.rio/inference_count"
	SERVICES=$(ash "service list" 2>/dev/null | tr -d '\r')
	if grep -q "IDevice/google-edgetpu" <<<"$SERVICES"; then
		printf '  ok    NNAPI google-edgetpu registered\n'
	else
		printf '  FAIL  NNAPI google-edgetpu registered\n'
		fail=1
	fi
}
[[ ",$UNITS," == *",gpu,"* || ",$UNITS," == *",npu,"* ]] && {
	if [[ -f "$HERE/tflite/benchmark_model" ]]; then
		printf '  ok    tflite assets\n'
	else
		printf '  FAIL  tflite assets (see npu-bench.sh --help to fetch)\n'
		fail=1
	fi
}
[[ $fail -eq 0 ]] || die "preflight failed; nothing was run"

mkdir -p "$OUT_DIR" || die "cannot create $OUT_DIR"
echo "output : $OUT_DIR"

# -------------------------------------------------------------- thermal gate

zone_temps() {
	ash 'for z in /sys/class/thermal/thermal_zone*/; do
	       echo "$(cat $z/type 2>/dev/null) $(cat $z/temp 2>/dev/null)"
	     done' | tr -d '\r'
}

hottest() { # -> "NAME TEMP_C" among $ZONES
	zone_temps | awk -v want="$ZONES" '
		BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
		keep[$1] && $2+0 > hot { hot = $2+0; name = $1 }
		END { printf "%s %.1f", name, hot/1000 }'
}

wait_cool() {
	local t0=$SECONDS now name temp
	while :; do
		read -r name temp <<<"$(hottest)"
		if awk -v t="$temp" -v c="$COOL_C" 'BEGIN{ exit !(t <= c) }'; then
			printf '  thermal ok (%s %.1fC <= %dC)\n' "$name" "$temp" "$COOL_C"
			return 0
		fi
		now=$((SECONDS - t0))
		if [[ $now -ge $COOL_MAX ]]; then
			printf '  !! still %.1fC on %s after %ds; running anyway - later stages may read slow\n' \
				"$temp" "$name" "$now"
			return 1
		fi
		printf '  cooling: %s %.1fC > %dC (%ds/%ds)\r' "$name" "$temp" "$COOL_C" "$now" "$COOL_MAX"
		command sleep 5
	done
}

# ------------------------------------------------------------------- stages

declare -A STAGE_SECS STAGE_RC
STAGE_ORDER=()

run_stage() { # run_stage <name> <logfile> <command...>
	local name="$1" log="$2"
	shift 2
	STAGE_ORDER+=("$name")
	say "$name"
	wait_cool
	local t0=$SECONDS
	"$@" >"$log" 2>&1
	local rc=$?
	STAGE_SECS[$name]=$((SECONDS - t0))
	STAGE_RC[$name]=$rc
	if [[ $rc -ne 0 ]]; then
		echo "  !! exited $rc - see $log"
		tail -3 "$log" | sed 's/^/     /'
	else
		printf '  done in %ds -> %s\n' "${STAGE_SECS[$name]}" "$log"
	fi
}

if [[ $QUICK -eq 1 ]]; then
	CPU_ARGS=(-r 2 -k 2); GPU_ARGS=(-r 15 -T 5); NPU_ARGS=(-r 20 -T 6)
else
	CPU_ARGS=(-r 3 -k 3); GPU_ARGS=(-r 20 -T 8); NPU_ARGS=(-r 50 -T 10)
fi
[[ $SWEEP -eq 1 ]] && GPU_ARGS+=(--sweep)
[[ -n "$AFFINITY" ]] && { GPU_ARGS+=(-a "$AFFINITY"); NPU_ARGS+=(-a "$AFFINITY"); }
[[ -n "$PIN_GOV" ]] && CPU_ARGS+=(-g "$PIN_GOV")

[[ ",$UNITS," == *",cpu,"* ]] && run_stage cpu "$OUT_DIR/cpu.log" "$HERE/cpu-bench.sh" "${CPU_ARGS[@]}"
[[ ",$UNITS," == *",gpu,"* ]] && run_stage gpu "$OUT_DIR/gpu.log" "$HERE/gpu-bench.sh" "${GPU_ARGS[@]}"
[[ ",$UNITS," == *",npu,"* ]] && run_stage npu "$OUT_DIR/npu.log" "$HERE/npu-bench.sh" "${NPU_ARGS[@]}"

# ----------------------------------------------------- post-run state check

say "device state"

state_bad=0
govs=$(ash 'for p in /sys/devices/system/cpu/cpufreq/policy*/; do cat $p/scaling_governor; done' | tr -d '\r' | sort -u | tr '\n' ' ')
if grep -q performance <<<"$govs"; then
	echo "  !! CPU governors still on performance: $govs"
	echo "     a stage died before restoring. Fix with:"
	echo "     adb shell 'for p in /sys/devices/system/cpu/cpufreq/policy*/; do echo sched_pixel > \$p/scaling_governor; done'"
	state_bad=1
else
	echo "  ok    cpu governors: $govs"
fi

if ash "test -d $MALI" >/dev/null 2>&1; then
	pol=$(ash "cat $MALI/power_policy" | tr -d '\r' | sed -n 's/.*\[\(.*\)\].*/\1/p')
	gmin=$(ash "cat $MALI/scaling_min_freq" | tr -d '\r')
	if [[ "$pol" == "always_on" || "$gmin" != "150000" ]]; then
		echo "  !! GPU still pinned: policy=$pol min=$gmin"
		echo "     Fix with: adb shell 'echo 150000 > $MALI/scaling_min_freq; echo adaptive > $MALI/power_policy'"
		state_bad=1
	else
		echo "  ok    gpu policy=$pol min=$gmin"
	fi
fi

# ------------------------------------------------------------------ summary

SUMMARY="$OUT_DIR/summary.txt"
{
	echo "shiba benchmark summary"
	echo "date    : $(date '+%Y-%m-%d %H:%M:%S')"
	echo "device  : $DEVICE ($BUILD, kernel $KERNEL)"
	echo "units   : $UNITS$([[ $QUICK -eq 1 ]] && echo '  (quick mode)')"
	echo "stages  : $(for k in "${STAGE_ORDER[@]}"; do printf '%s=%ds(rc%d) ' "$k" "${STAGE_SECS[$k]}" "${STAGE_RC[$k]}"; done)"
	echo

	if [[ -s "$OUT_DIR/cpu.log" ]]; then
		echo "CPU  (per cluster, governor pinned)"
		printf '  %-8s %8s %7s %10s\n' CLUSTER GHz IPC "BR-MISS%"
		awk '
			/^(little|mid|big) +[0-9]+ / { br[$1] += $7; n[$1]++ }
			/^(little|mid|big) +avg/     { ghz[$1] = $3; ipc[$1] = $4; order[++k] = $1 }
			END { for (i = 1; i <= k; i++) { c = order[i]
			        printf "  %-8s %8.3f %7.3f %9.2f%%\n", c, ghz[c], ipc[c], n[c] ? br[c]/n[c] : 0 } }
		' "$OUT_DIR/cpu.log"
		echo
	fi

	# Cross-unit view: same model, every backend that measured it.
	# Only hand awk files that exist - a missing one aborts it before it reaches the
	# rest, which silently produced an empty table when a unit was skipped.
	INF_LOGS=()
	for f in "$OUT_DIR/gpu.log" "$OUT_DIR/npu.log"; do [[ -s "$f" ]] && INF_LOGS+=("$f"); done
	if [[ ${#INF_LOGS[@]} -gt 0 ]]; then
		INF_TABLE=$(awk '
			FILENAME ~ /gpu\.log/ {
				if ($1 == "---")                  { m = $2 }
				else if ($1 == "cpu-8thr")        { v[m "\tcpu-8thr"]  = $2 }
				else if ($1 == "gpu-adaptive")    { v[m "\tgpu-stock"] = $2 }
				else if ($1 == "gpu-pinned")      { v[m "\tgpu-890MHz"]= $2 }
				# --sweep writes "<kHz> <ms> ..." rows instead of the labelled ones, so
				# without this the whole GPU stage vanished from the cross-unit table.
				# Frequencies come out descending, so the first row is the top clock.
				else if ($1 ~ /^[0-9]+$/ && NF >= 5 && !(m in swept)) {
					swept[m] = 1; v[m "\tgpu-" int($1/1000) "MHz"] = $2 }
			}
			FILENAME ~ /npu\.log/ {
				if ($1 == "---")                  { m = $2 }
				else if ($1 == "cpu-1thr")        { v[m "\tcpu-1thr"]  = $3 }
				else if ($1 == "cpu-8thr" && !((m "\tcpu-8thr") in v)) { v[m "\tcpu-8thr"] = $3 }
				else if ($1 == "edgetpu")         { v[m "\tedgetpu"]   = $3 }
			}
			END {
				split("cpu-1thr cpu-8thr gpu-stock gpu-890MHz edgetpu", ord, " ")
				# awk iterates keys in unspecified order; keep first-seen order instead
				for (key in v) { split(key, p, "\t")
					if (!(p[1] in seen)) { seen[p[1]] = 1; models[++nm] = p[1] } }
				for (j = 1; j <= nm; j++) { mm = models[j]
					printf "  %s\n", mm
					base = 0
					for (i = 1; i <= 5; i++) { k = mm "\t" ord[i]
						if (k in v) { if (!base) base = v[k]
							printf "    %-12s %9.2f  %6.1fx\n", ord[i], v[k], base/v[k] } }
				}
			}
		' "${INF_LOGS[@]}")
		if [[ -n "$INF_TABLE" ]]; then
			echo "Inference latency by backend (ms, lower is better)"
			echo "$INF_TABLE"
			echo "  (speedup is against the first backend listed for that model)"
			echo
		fi
	fi

	[[ $state_bad -eq 1 ]] && echo "WARNING: device left in a modified state - see above."
	printf 'full logs:'
	for k in "${STAGE_ORDER[@]}"; do printf ' %s' "$OUT_DIR/$k.log"; done
	echo
} | tee "$SUMMARY"

say "summary written to $SUMMARY"
[[ $state_bad -eq 0 ]]
