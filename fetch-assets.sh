#!/usr/bin/env bash
#
# fetch-assets.sh - download the TFLite benchmark binary and models that gpu-bench.sh
# and npu-bench.sh push to the device. They are redistributable downloads, not part of
# this repository, so tflite/ is gitignored and this script recreates it.
#
set -euo pipefail

DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tflite"
mkdir -p "$DEST"
cd "$DEST"

TF_NIGHTLY=https://storage.googleapis.com/tensorflow-nightly-public/prod/tensorflow/release/lite/tools/nightly/latest
TF_MODELS=https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02
MP_MODELS=https://storage.googleapis.com/mediapipe-models/image_classifier

get() { # get <url> <output>
	if [[ -s "$2" ]]; then
		echo "  have  $2"
	else
		echo "  get   $2"
		curl -fsSL -o "$2" "$1"
	fi
}

echo "fetching into $DEST"

# aarch64 Android PIE binary; carries both the NNAPI and the GPU (OpenCL) delegate.
get "$TF_NIGHTLY/android_aarch64_benchmark_model" benchmark_model
chmod +x benchmark_model

# int8 quantized - the only kind the EdgeTPU will accept - plus the float32 twin, which
# the NPU script uses to demonstrate NNAPI's silent fallback to the CPU.
for m in mobilenet_v1_1.0_224_quant mobilenet_v1_1.0_224; do
	get "$TF_MODELS/$m.tgz" "$m.tgz"
	[[ -s "$m.tflite" ]] || tar xzf "$m.tgz" --wildcards '*.tflite'
done

get "$MP_MODELS/efficientnet_lite0/int8/1/efficientnet_lite0.tflite" efficientnet_lite0_int8.tflite

echo
ls -l "$DEST"/*.tflite benchmark_model
