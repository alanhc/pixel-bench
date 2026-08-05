#!/usr/bin/env bash
#
# gpu-bench.sh - Mali-G715 benchmark for the Pixel 8, driven through the TFLite GPU
#                delegate, with the clock actually verified rather than assumed.
#
# There is no GPU benchmark binary on an AOSP_on_shiba build - no vulkaninfo, no
# flatland, no Play Store. But the prebuilt TFLite `benchmark_model` already pushed for
# npu-bench.sh carries a GPU delegate (OpenCL via /vendor/lib64/libOpenCL.so), so the
# same models give a real, comparable GPU workload across CPU / GPU / TPU.
#
# The finding that makes this script worth having:
#
#   **The default GPU governor never ramps up for bursty compute.** Left on the stock
#   `adaptive` power policy, MobileNet v1 float32 measures 21.8 ms - indistinguishable
#   from the CPU's 20.3 ms, which invites the wrong conclusion that the Mali is not
#   worth using. Pin the clock to 890 MHz and the same graph runs in 6.99 ms: 3.1x
#   faster, and now 2.9x faster than the CPU.
#
#   The residency counters say exactly why. Sampling time_in_state across an unpinned
#   run: 1204 ms at 150 MHz (the floor), 319 at 302, 162 at 337, 116 at 376, and never
#   once above 376 MHz. Effective clock 208 MHz out of a 890 MHz peak - 23%. Each
#   inference finishes before the governor reacts, so it idles at the bottom of the
#   table the whole time.
#
# Hence every row below reports EFF-MHz, derived from the time_in_state delta over that
# run. It is the GPU counterpart of the CPU script's % of peak: the evidence that the
# clock you asked for is the clock you got. A pinned run that reports a low effective
# frequency means the pin did not take, not that the GPU is slow.
#
#   Mali-G715 7 cores r1p2, 13 DVFS steps 150-890 MHz, at
#   /sys/devices/platform/1f000000.mali. Pinning needs all three of
#   power_policy=always_on, scaling_min_freq and scaling_max_freq; the originals are
#   restored on EXIT/INT/TERM.
#
set -uo pipefail

ASSET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tflite"
REMOTE_DIR=/data/local/tmp/npubench
MALI=/sys/devices/platform/1f000000.mali

RUNS=30
MAX_SECS=10
BACKEND=""
DO_SWEEP=0
DO_CPU=1
DO_PUSH=1
AFFINITY=all

# Which cores the benchmark process may run on. The GPU does the work, but the CPU
# builds and submits the command stream, so the feeding cluster shows up in the result.
declare -A AFF_MASK=([little]=0f [mid]=f0 [big]=100 [all]=1ff)

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

  -m FILE    Model to benchmark; repeatable. Default: the MobileNet v1 float32 and
             int8 pair in ${ASSET_DIR}.
  -r N       Minimum inference iterations per run (default ${RUNS}).
  -T SEC     Cap on each measurement phase (default ${MAX_SECS}).
  -b cl|gl   Force the GPU delegate backend. Default: let TFLite choose (OpenCL here).
  -a CLUSTER Bind the benchmark process to little|mid|big|all (default ${AFFINITY}).
  -s SERIAL  adb serial (otherwise \$ANDROID_SERIAL, otherwise the only device).
  --sweep    Pin the GPU at every DVFS step in turn and print the scaling curve
             instead of the default adaptive-vs-pinned comparison.
  --no-cpu   Skip the CPU baseline row.
  --no-push  Assume ${REMOTE_DIR} is already populated; skip the adb push.
  -h         This help.

Assets are shared with npu-bench.sh; run ./fetch-assets.sh to download them.

Examples:
  ${0##*/}                       # adaptive vs pinned, both models
  ${0##*/} --sweep -r 20         # performance against clock, 13 DVFS steps
EOF
}

MODEL_LIST=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	-m) MODEL_LIST+=("$2"); shift 2 ;;
	-r) RUNS="$2"; shift 2 ;;
	-T) MAX_SECS="$2"; shift 2 ;;
	-b) BACKEND="$2"; shift 2 ;;
	-a) AFFINITY="$2"; shift 2 ;;
	-s) export ANDROID_SERIAL="$2"; shift 2 ;;
	--sweep) DO_SWEEP=1; shift ;;
	--no-cpu) DO_CPU=0; shift ;;
	--no-push) DO_PUSH=0; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

ash() { adb shell "$@"; }
die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- device setup

[[ -n "${AFF_MASK[$AFFINITY]:-}" ]] || die "unknown -a cluster '$AFFINITY' (little|mid|big|all)"

adb get-state >/dev/null 2>&1 || die "no device (adb get-state failed)"
adb root >/dev/null 2>&1
adb wait-for-device
[[ "$(ash id -u | tr -d '\r')" == "0" ]] || die "adbd is not root; 'adb root' was refused"
ash "test -d $MALI" || die "$MALI not found; is this a Tensor G3 device?"

GPUINFO=$(ash "cat $MALI/gpuinfo" | tr -d '\r')
FREQS=$(ash "cat $MALI/available_frequencies" | tr -d '\r')
FMAX=$(awk '{m=0; for(i=1;i<=NF;i++) if($i+0>m) m=$i+0; print m}' <<<"$FREQS")

# ------------------------------------------------------ clock save/restore

ORIG_POLICY="" ORIG_MIN="" ORIG_MAX="" RESTORE_NEEDED=0

restore_gpu() {
	[[ $RESTORE_NEEDED -eq 1 ]] || return 0
	RESTORE_NEEDED=0
	echo
	echo "restoring GPU clock policy..."
	# Order matters: widen the window before handing control back, or the governor is
	# briefly boxed in at the pinned value.
	ash "echo $ORIG_MIN > $MALI/scaling_min_freq" 2>/dev/null
	ash "echo $ORIG_MAX > $MALI/scaling_max_freq" 2>/dev/null
	ash "echo $ORIG_POLICY > $MALI/power_policy" 2>/dev/null
	printf '  policy=%s min=%s max=%s cur=%s\n' \
		"$(ash "cat $MALI/power_policy" | tr -d '\r' | sed -n 's/.*\[\(.*\)\].*/\1/p')" \
		"$(ash "cat $MALI/scaling_min_freq" | tr -d '\r')" \
		"$(ash "cat $MALI/scaling_max_freq" | tr -d '\r')" \
		"$(ash "cat $MALI/cur_freq" | tr -d '\r')"
}
trap restore_gpu EXIT INT TERM

save_gpu_state() {
	ORIG_POLICY=$(ash "cat $MALI/power_policy" | tr -d '\r' | sed -n 's/.*\[\(.*\)\].*/\1/p')
	ORIG_MIN=$(ash "cat $MALI/scaling_min_freq" | tr -d '\r')
	ORIG_MAX=$(ash "cat $MALI/scaling_max_freq" | tr -d '\r')
	[[ -n "$ORIG_POLICY" ]] || ORIG_POLICY=adaptive
	RESTORE_NEEDED=1
}

pin_gpu() { # pin_gpu <khz>
	ash "echo always_on > $MALI/power_policy" 2>/dev/null
	ash "echo $1 > $MALI/scaling_max_freq" 2>/dev/null
	ash "echo $1 > $MALI/scaling_min_freq" 2>/dev/null
}

unpin_gpu() {
	ash "echo $ORIG_MIN > $MALI/scaling_min_freq" 2>/dev/null
	ash "echo $ORIG_MAX > $MALI/scaling_max_freq" 2>/dev/null
	ash "echo $ORIG_POLICY > $MALI/power_policy" 2>/dev/null
}

# --------------------------------------------------------------- residency

# Normalise to "khz ms" with no leading blanks - time_in_state is space-padded, and
# join treats a leading blank as an empty first field, which silently produces no rows.
residency() { ash "cat $MALI/time_in_state" | tr -d '\r' | awk 'NF>=2 {print $1, $2}'; }

# eff_mhz <before> <after> -> "effective_mhz top_freq_khz top_share_pct busy_ms"
eff_mhz() {
	join <(sort -k1,1 <<<"$1") <(sort -k1,1 <<<"$2") 2>/dev/null |
		awk '{ d = $3 - $2; if (d > 0) { s += $1*d; t += d; if (d > bd) { bd = d; bf = $1 } } }
		     END { if (t > 0) printf "%.0f %d %.0f %d", s/t/1000, bf, 100*bd/t, t
		           else        printf "0 0 0 0" }'
}

# --------------------------------------------------------------- model list

if [[ ${#MODEL_LIST[@]} -eq 0 ]]; then
	for f in "$ASSET_DIR/mobilenet_v1_1.0_224.tflite" "$ASSET_DIR/mobilenet_v1_1.0_224_quant.tflite"; do
		[[ -f "$f" ]] && MODEL_LIST+=("$f")
	done
fi
[[ ${#MODEL_LIST[@]} -gt 0 ]] || die "no models found; see npu-bench.sh --help for fetch commands"
[[ -f "$ASSET_DIR/benchmark_model" ]] || die "$ASSET_DIR/benchmark_model missing"

if [[ $DO_PUSH -eq 1 ]]; then
	ash "mkdir -p $REMOTE_DIR"
	adb push "$ASSET_DIR/benchmark_model" "${MODEL_LIST[@]}" "$REMOTE_DIR/" >/dev/null 2>&1 ||
		die "adb push failed"
	ash "chmod 755 $REMOTE_DIR/benchmark_model"
fi

# ------------------------------------------------------------------- runner

GPU_ARGS="--use_gpu=true"
[[ -n "$BACKEND" ]] && GPU_ARGS+=" --gpu_backend=$BACKEND"

# run <remote-model> <extra args...> -> "infer_us init_us delegated eff_mhz top top% busy note"
run() {
	local model="$1"
	shift
	local b a out infer init deleg note

	b=$(residency)
	out=$(ash "taskset ${AFF_MASK[$AFFINITY]} $REMOTE_DIR/benchmark_model --graph=$model \
	           --num_runs=$RUNS --warmup_runs=5 --max_secs=$MAX_SECS $*" 2>&1 | tr -d '\r')
	a=$(residency)

	infer=$(sed -n 's/.*Inference (avg): \([0-9.]*\).*/\1/p' <<<"$out" | head -1)
	init=$(sed -n 's/.*Inference timings in us: Init: \([0-9.]*\),.*/\1/p' <<<"$out" | head -1)
	deleg=$(sed -n 's/.*Replacing \([0-9]*\) out of \([0-9]*\) node(s) with delegate.*/\1\/\2/p' <<<"$out" | head -1)

	note=""
	# Same silent-fallback tell as the NNAPI path: the delegate is created, then declines
	# the graph, and TFLite runs the CPU instead without failing.
	grep -q "will not be executed by the delegate" <<<"$out" && note="FELL BACK TO CPU"

	printf '%s %s %s %s %s\n' "${infer:-0}" "${init:-0}" "${deleg:-?}" "$(eff_mhz "$b" "$a")" "$note"
}

# --------------------------------------------------------------------- main

echo "=== shiba GPU bench ==="
echo "gpu     : $GPUINFO"
echo "dvfs    : $(wc -w <<<"$FREQS") steps, $(awk '{print $NF}' <<<"$FREQS")-${FMAX} kHz"
echo "runs    : >= $RUNS per phase, capped at ${MAX_SECS}s"
echo "affinity: $AFFINITY (taskset ${AFF_MASK[$AFFINITY]})"
echo

save_gpu_state
echo "saved GPU state: policy=$ORIG_POLICY min=$ORIG_MIN max=$ORIG_MAX"
echo

for model in "${MODEL_LIST[@]}"; do
	base=$(basename "$model")
	remote="$REMOTE_DIR/$base"
	echo "--- $base"

	if [[ $DO_SWEEP -eq 1 ]]; then
		printf '%10s %11s %9s %9s %9s\n' "PIN(kHz)" "INFER(ms)" "EFF-MHz" "%PINNED" "REL-PEAK"
		printf '%.0s-' {1..53}; echo
		peak_ms=""
		for f in $FREQS; do
			pin_gpu "$f"
			read -r infer init deleg emhz top toppct busy note <<<"$(run "$remote" "$GPU_ARGS")"
			[[ -z "$peak_ms" ]] && peak_ms="$infer"
			awk -v f="$f" -v i="$infer" -v e="$emhz" -v p="$peak_ms" 'BEGIN {
				printf "%10d %11.2f %9d %8.0f%% %8.2fx\n", f, i/1000, e, 100*e*1000/f, (i>0? p/i : 0) }'
		done
		unpin_gpu
	else
		printf '%-14s %11s %10s %9s %9s %12s\n' \
			MODE "INFER(ms)" "INIT(ms)" "SPEEDUP" "EFF-MHz" "TOP-STATE"
		printf '%.0s-' {1..70}; echo

		baseline=""
		emit() { # emit <label> <result-line>
			read -r infer init deleg emhz top toppct busy note <<<"$2"
			[[ -z "$baseline" ]] && baseline="$infer"
			awk -v l="$1" -v i="$infer" -v n="$init" -v b="$baseline" -v e="$emhz" \
				-v tf="$top" -v tp="$toppct" 'BEGIN {
				printf "%-14s %11.2f %10.1f", l, i/1000, n/1000
				if (i > 0 && b > 0) printf " %8.2fx", b/i; else printf " %9s", "-"
				if (e > 0) printf " %9d %9d/%.0f%%\n", e, tf/1000, tp
				else       printf " %9s %12s\n", "-", "(gpu idle)" }'
			if [[ -n "$note" ]]; then
				echo "               !! $note - the delegate was created, then declined the"
				echo "                  graph. This row is a CPU measurement."
			fi
		}

		[[ $DO_CPU -eq 1 ]] && emit "cpu-8thr" "$(run "$remote" "--num_threads=8")"

		unpin_gpu
		emit "gpu-adaptive" "$(run "$remote" "$GPU_ARGS")"

		pin_gpu "$FMAX"
		emit "gpu-pinned" "$(run "$remote" "$GPU_ARGS")"
		unpin_gpu
	fi
	echo
done

echo "Notes"
echo "  EFF-MHz is the clock the GPU actually held, computed from the time_in_state delta"
echo "  over that run - not what was requested."
if [[ $DO_SWEEP -eq 1 ]]; then
	cat <<'EOF'
  %PINNED should read 100% on every row; anything less means the pin did not hold and
  that row's timing belongs to a different clock than its label claims.
  REL-PEAK is against the highest DVFS step. Expect it to fall off well short of the
  clock ratio - once the shaders outrun memory the extra megahertz stop buying time.
EOF
else
	cat <<'EOF'
  TOP-STATE names the single DVFS step the GPU spent most of the run in, with its share.
  A gpu-adaptive row sitting far below peak is the normal case, not a fault: the stock
  governor cannot react inside a single short inference. Compare it against gpu-pinned
  to see what the hardware is actually capable of.
  SPEEDUP is against the first row of the same model.
EOF
fi
