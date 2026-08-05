#!/usr/bin/env bash
#
# npu-bench.sh - compare TFLite inference on the Tensor G3 EdgeTPU against the CPU,
#                and prove the TPU actually ran.
#
# The device exposes the TPU as an NNAPI accelerator named `google-edgetpu`, backed by
# the `rio` kernel module and android.hardware.neuralnetworks@service-darwinn-aidl.
# This works on the plain AOSP_on_shiba build - none of it needs GMS.
#
#   adb shell service list | grep -i neural
#     -> android.hardware.neuralnetworks.IDevice/google-edgetpu
#
# Two things make naive numbers wrong, both handled below:
#
#   1. NNAPI falls back to the CPU SILENTLY. Ask for google-edgetpu with a model it
#      cannot take - a float32 graph, for instance - and TFLite still prints
#      "NNAPI delegate created", then logs
#          "Though NNAPI delegate is explicitly applied, the model graph will not
#           be executed by the delegate"
#      and quietly runs XNNPACK on the CPU instead. Measured here: float32 MobileNet
#      v1 "on the TPU" reports 21.1 ms, which is simply its CPU time. Only int8
#      quantized graphs reach this accelerator. This script greps for that line and
#      flags the run rather than reporting a CPU number as a TPU number.
#
#   2. The only real proof is the hardware counter. /sys/devices/platform/1a000000.rio/
#      exposes inference_count (three space-separated fields; sum them). Its delta must
#      match the iteration count that benchmark_model reports. Verified: delta 1463 vs
#      480+983=1463 reported. Every NNAPI run below is checked this way, so a fallback
#      cannot masquerade as acceleration.
#
# Reference numbers, MobileNet v1 224 int8, this device:
#      CPU 1 thread (XNNPACK)   33.8 ms
#      NNAPI nnapi-reference   153.9 ms      (software reference, not a real backend)
#      NNAPI google-edgetpu      1.00 ms     ~34x, but see the init cost
#
# Watch the init column: compiling MobileNet for the TPU costs ~1.1-2.1 s, one time per
# process. It dwarfs any single inference, so it decides whether offloading is worth it
# for short-lived work.
#
set -uo pipefail

ASSET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tflite"
REMOTE_DIR=/data/local/tmp/npubench
RIO=/sys/devices/platform/1a000000.rio
ACCEL=google-edgetpu

MODELS=""
RUNS=50
MAX_SECS=10
CPU_THREADS="1 8"
DO_REF=0
DO_PUSH=1
AFFINITY=all

# Which cores the benchmark process itself may run on. This matters even for the TPU:
# the accelerator is identical either way, but the CPU-side delegate dispatch is not.
# Measured, MobileNet v1 int8 on google-edgetpu: little 1.509 ms, mid 0.985, big 0.933
# - 62% slower fed from an A510 than from the X3.
declare -A AFF_MASK=([little]=0f [mid]=f0 [big]=100 [all]=1ff)

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

  -m FILE    Model to benchmark; repeatable. Default: every *_int8*.tflite and
             *_quant.tflite in ${ASSET_DIR}.
  -r N       Minimum inference iterations per run (default ${RUNS}).
  -t LIST    CPU thread counts to test, space separated (default "${CPU_THREADS}").
  -T SEC     Cap on each measurement phase (default ${MAX_SECS}).
  -a CLUSTER Bind the benchmark process to little|mid|big|all (default ${AFFINITY}).
             Applies to every backend including the TPU - the accelerator does not
             change, but the CPU feeding it does, and on this device that is worth
             62% on MobileNet int8 between the A510s and the X3.
  -s SERIAL  adb serial (otherwise \$ANDROID_SERIAL, otherwise the only device).
  --ref      Also run the nnapi-reference software path. It is ~150x slower than the
             TPU, so it is off by default; useful only to show NNAPI is not magic.
  --no-push  Assume ${REMOTE_DIR} is already populated; skip the adb push.
  -h         This help.

Assets live in ${ASSET_DIR}; run ./fetch-assets.sh to download them.

Examples:
  ${0##*/}                                        # int8 models, CPU 1/8 threads vs TPU
  ${0##*/} -m ${ASSET_DIR}/mobilenet_v1_1.0_224.tflite
                                                  # float32: demonstrates the silent
                                                  # CPU fallback described above
EOF
}

MODEL_LIST=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	-m) MODEL_LIST+=("$2"); shift 2 ;;
	-r) RUNS="$2"; shift 2 ;;
	-t) CPU_THREADS="$2"; shift 2 ;;
	-T) MAX_SECS="$2"; shift 2 ;;
	-a) AFFINITY="$2"; shift 2 ;;
	-s) export ANDROID_SERIAL="$2"; shift 2 ;;
	--ref) DO_REF=1; shift ;;
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

# Capture first, match second. Piping adb straight into `grep -q` is a race: grep exits
# on the first match, adb takes SIGPIPE, and pipefail then reports the whole pipeline as
# failed - intermittently, depending on who finishes writing first.
SERVICES=$(ash "service list" 2>/dev/null | tr -d '\r')
grep -q "IDevice/$ACCEL" <<<"$SERVICES" ||
	die "NNAPI accelerator '$ACCEL' is not registered; is android.hardware.neuralnetworks@service-darwinn-aidl running?"

ash "test -e $RIO/inference_count" ||
	die "$RIO/inference_count missing; is the 'rio' module loaded? (lsmod | grep rio)"

# ------------------------------------------------------------------ model list

if [[ ${#MODEL_LIST[@]} -eq 0 ]]; then
	while IFS= read -r f; do MODEL_LIST+=("$f"); done < <(
		ls "$ASSET_DIR"/*_int8*.tflite "$ASSET_DIR"/*_quant.tflite 2>/dev/null | sort -u
	)
fi
[[ ${#MODEL_LIST[@]} -gt 0 ]] || die "no models found; see --help for the fetch commands"
[[ -x "$ASSET_DIR/benchmark_model" || -f "$ASSET_DIR/benchmark_model" ]] ||
	die "$ASSET_DIR/benchmark_model missing; see --help for the fetch command"

if [[ $DO_PUSH -eq 1 ]]; then
	ash "mkdir -p $REMOTE_DIR"
	adb push "$ASSET_DIR/benchmark_model" "${MODEL_LIST[@]}" "$REMOTE_DIR/" >/dev/null 2>&1 ||
		die "adb push failed"
	ash "chmod 755 $REMOTE_DIR/benchmark_model"
fi

# ------------------------------------------------------------------- helpers

tpu_inferences() { ash "cat $RIO/inference_count" | tr -d '\r' | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s}'; }
tpu_temp() { ash 'for z in /sys/class/thermal/thermal_zone*/; do [ "$(cat $z/type)" = "TPU" ] && cat $z/temp; done' | tr -d '\r' | awk '{printf "%.1f", $1/1000}'; }

# run_backend <remote-model> <label> <extra benchmark_model args...>
# Prints: label init_ms infer_ms delegated tpu_delta note
run_backend() {
	local model="$1" label="$2"
	shift 2
	local before after out

	before=$(tpu_inferences)
	out=$(ash "taskset ${AFF_MASK[$AFFINITY]} $REMOTE_DIR/benchmark_model --graph=$model \
	           --num_runs=$RUNS --warmup_runs=5 --max_secs=$MAX_SECS $*" 2>&1 | tr -d '\r')
	after=$(tpu_inferences)

	local init infer deleg parts note reported
	init=$(sed -n 's/.*Inference timings in us: Init: \([0-9.]*\),.*/\1/p' <<<"$out" | head -1)
	infer=$(sed -n 's/.*Inference (avg): \([0-9.]*\).*/\1/p' <<<"$out" | head -1)
	deleg=$(sed -n 's/.*Replacing \([0-9]*\) out of \([0-9]*\) node(s) with delegate.*/\1\/\2/p' <<<"$out" | head -1)
	parts=$(sed -n 's/.*yielding \([0-9]*\) partitions.*/\1/p' <<<"$out" | head -1)
	reported=$(grep -oE 'count=[0-9]+' <<<"$out" | tail -1 | cut -d= -f2)

	note=""
	# The silent-fallback tell. Without this check a CPU number gets reported as a TPU number.
	grep -q "will not be executed by the delegate" <<<"$out" && note="FELL BACK TO CPU"

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$label" "${init:-0}" "${infer:-0}" "${deleg:-?}" "${parts:-?}" \
		"$((after - before))" "${reported:-0}" "$note"
}

# --------------------------------------------------------------------- run it

echo "=== shiba NPU bench ==="
echo "accelerator : $ACCEL  (fw $(ash cat $RIO/firmware_version 2>/dev/null | tr -d '\r' | head -1))"
echo "iterations  : >= $RUNS per phase, capped at ${MAX_SECS}s"
echo "affinity    : $AFFINITY (taskset ${AFF_MASK[$AFFINITY]})"
echo "TPU temp    : $(tpu_temp)C"
echo

for model in "${MODEL_LIST[@]}"; do
	base=$(basename "$model")
	remote="$REMOTE_DIR/$base"
	echo "--- $base"
	printf '%-16s %10s %11s %9s %12s %6s %10s\n' \
		BACKEND "INIT(ms)" "INFER(ms)" "SPEEDUP" "DELEGATED" "PARTS" "TPU-INF"
	printf '%.0s-' {1..80}; echo

	baseline=""
	{
		for t in $CPU_THREADS; do
			run_backend "$remote" "cpu-${t}thr" "--num_threads=$t"
		done
		[[ $DO_REF -eq 1 ]] && run_backend "$remote" "nnapi-ref" \
			"--use_nnapi=true --nnapi_accelerator_name=nnapi-reference"
		run_backend "$remote" "edgetpu" \
			"--use_nnapi=true --nnapi_accelerator_name=$ACCEL"
	} | while IFS=$'\t' read -r label init infer deleg parts tpudelta reported note; do
		[[ -z "$baseline" ]] && baseline="$infer"

		speed=$(awk -v b="$baseline" -v i="$infer" 'BEGIN{ if (i>0 && b>0) printf "%.1fx", b/i; else printf "-" }')
		awk -v l="$label" -v ini="$init" -v inf="$infer" -v sp="$speed" \
			-v dg="$deleg" -v pt="$parts" -v td="$tpudelta" 'BEGIN {
				printf "%-16s %10.1f %11.3f %9s %12s %6s %10d\n", l, ini/1000, inf/1000, sp, dg, pt, td }'

		if [[ -n "$note" ]]; then
			echo "                 !! $note - NNAPI accepted the delegate then declined the"
			echo "                    graph. This row is a CPU measurement, not a TPU one."
			echo "                    Only int8 quantized graphs run on $ACCEL."
		elif [[ "$label" == "edgetpu" ]]; then
			# The counter is the ground truth; a delegated-node count is not enough.
			if [[ "$tpudelta" -le 0 ]]; then
				echo "                 !! inference_count did not move: nothing ran on the TPU."
			elif [[ "$reported" -gt 0 ]] && awk -v a="$tpudelta" -v b="$reported" \
				'BEGIN{ exit !(a < b*0.9 || a > b*3) }'; then
				echo "                 ?  inference_count delta $tpudelta vs $reported reported"
				echo "                    iterations - partial delegation or another TPU client."
			fi
		fi
	done
	echo "         TPU temp after: $(tpu_temp)C"
	echo
done

cat <<'EOF'
Notes
  SPEEDUP is against the first CPU row of the same model.
  TPU-INF is the hardware inference_count delta across the run - the only evidence
  that survives a silent fallback. It should track the reported iteration count.
  INIT is one-time graph compilation for the accelerator; on the TPU it runs into
  seconds and often decides whether offloading pays off at all.
EOF
