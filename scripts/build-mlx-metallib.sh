#!/bin/bash
# Builds MLX's Metal kernels into `mlx.metallib` and puts it next to the SwiftPM binaries.
#
# Why: `swift build` (command-line SwiftPM) cannot compile .metal files, so a binary that links
# HushyModelsMLX (today only murmur-eval) fails at the first GPU op with "Failed to load the
# default metallib". MLX looks for a colocated `mlx.metallib` beside the executable first
# (mlx/backend/metal/device.cpp), so we build it once per mlx-swift version and copy it there.
# The kernel list mirrors mlx-swift's own Xcode project (xcode/MLX.xcodeproj), which is what an
# Xcode build of the package compiles.
#
# Needs Apple's Metal Toolchain (Xcode 26+ ships it as a separate component):
#   xcodebuild -downloadComponent MetalToolchain
#
# Usage: scripts/build-mlx-metallib.sh [debug|release|all]   (default: all existing build dirs)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="$ROOT/.build/checkouts/mlx-swift"
KERNELS="$CHECKOUT/Source/Cmlx/mlx/mlx/backend/metal/kernels"
MLX_SRC="$CHECKOUT/Source/Cmlx/mlx"

if [ ! -d "$KERNELS" ]; then
    echo "mlx-swift checkout not found; run 'swift package resolve' first" >&2
    exit 1
fi
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "Metal Toolchain missing: run 'xcodebuild -downloadComponent MetalToolchain'" >&2
    exit 1
fi

VERSION="$(cd "$CHECKOUT" && git describe --tags --always 2>/dev/null || echo unknown)"
OUT_DIR="$ROOT/.build/mlx-metallib/$VERSION"
LIB="$OUT_DIR/mlx.metallib"

KERNEL_FILES=(
    arange arg_reduce binary binary_two conv copy fence fft fp_quantized fp_quantized_nax gemv
    gemv_masked layer_norm logsumexp quantized quantized_nax random reduce rms_norm rope
    scaled_dot_product_attention scan softmax sort ternary unary
    steel/attn/kernels/steel_attention steel/attn/kernels/steel_attention_nax
    steel/conv/kernels/steel_conv steel/conv/kernels/steel_conv_general
    steel/gemm/kernels/steel_gemm_fused steel/gemm/kernels/steel_gemm_fused_nax
    steel/gemm/kernels/steel_gemm_gather steel/gemm/kernels/steel_gemm_gather_nax
    steel/gemm/kernels/steel_gemm_masked steel/gemm/kernels/steel_gemm_segmented
    steel/gemm/kernels/steel_gemm_splitk steel/gemm/kernels/steel_gemm_splitk_nax
)

if [ ! -f "$LIB" ]; then
    mkdir -p "$OUT_DIR/air"
    echo "Compiling ${#KERNEL_FILES[@]} MLX kernels ($VERSION)…"
    AIRS=()
    for kernel in "${KERNEL_FILES[@]}"; do
        air="$OUT_DIR/air/$(echo "$kernel" | tr '/' '_').air"
        # NAX (Metal 4 tensor) kernels only compile for macOS 26.2+, as in MLX's CMake, which
        # builds them only when the SDK is >= 26.2; MLX only dispatches them on NAX-capable GPUs.
        min_os=15.0
        case "$kernel" in *_nax) min_os=26.2 ;; esac
        xcrun -sdk macosx metal -x metal -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions \
            -mmacosx-version-min="$min_os" -c "$KERNELS/$kernel.metal" -I"$MLX_SRC" -o "$air" \
            2>"$air.log" &
        AIRS+=("$air")
        # Keep at most 8 compilers running.
        while [ "$(jobs -rp | wc -l)" -ge 8 ]; do sleep 0.2; done
    done
    wait
    for air in "${AIRS[@]}"; do
        if [ ! -f "$air" ]; then
            echo "failed to compile $(basename "$air" .air):" >&2
            grep -m5 error "$air.log" >&2 || true
            exit 1
        fi
    done
    xcrun -sdk macosx metallib "${AIRS[@]}" -o "$LIB"
    rm -rf "$OUT_DIR/air"
fi

targets=("${1:-all}")
if [ "${targets[0]}" = "all" ]; then targets=(debug release); fi
for config in "${targets[@]}"; do
    # Copy to the folder SwiftPM really builds into: newer toolchains use .build/out/Products/<Config>,
    # and a stale .build/<config> link from an older toolchain then points somewhere else. Also keep the
    # legacy .build/<config> copy, which gate-cleanup.sh and older scripts read.
    dirs=()
    bin="$(cd "$ROOT" && swift build -c "$config" --show-bin-path 2>/dev/null || true)"
    [ -n "$bin" ] && [ -d "$bin" ] && dirs+=("$bin")
    [ -d "$ROOT/.build/$config" ] && dirs+=("$ROOT/.build/$config")
    # macOS bash 3.2 treats an empty "${dirs[@]}" as unbound under set -u (a fresh checkout has no
    # release folder yet).
    for dir in ${dirs[@]+"${dirs[@]}"}; do
        cp "$LIB" "$dir/mlx.metallib"
        echo "mlx.metallib -> ${dir#"$ROOT/"}/"
    done
done
