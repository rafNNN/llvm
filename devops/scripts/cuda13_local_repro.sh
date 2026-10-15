#!/bin/bash
# Run inside the locally built CUDA 13 image, not on the host.
set -euo pipefail

: "${TOOLCHAIN_TAG:?Pinned compiler release is required}"
: "${TOOLCHAIN_SHA256:?Compiler archive checksum is required}"
: "${TOOLCHAIN_SOURCE_SHA:?Matching test source revision is required}"

sources=/workspace/repro-sources
work=/results/work
logs=/results/logs
test_name=bindless_images/vulkan_interop/vulkan_sycl_image_unsampled_timeline_semaphore.cpp
mkdir -p "$HOME" "$work" "$logs"
cd "$work"
exec > >(tee "$logs/container.log") 2>&1

printf 'Compiler: %s\nSource revision: %s\nTest: %s\n' \
  "$TOOLCHAIN_TAG" "$TOOLCHAIN_SOURCE_SHA" "$test_name"
test -f "$sources/sycl/test-e2e/$test_name"
test -f /opt/vulkan/setup-env.sh
test -f /runtimes/oneapi-tbb/env/vars.sh
# Vendor environment scripts are not necessarily nounset-safe.
set +u
# shellcheck disable=SC1091
source /runtimes/oneapi-tbb/env/vars.sh
# shellcheck disable=SC1091
source /opt/vulkan/setup-env.sh
set -u

nvidia-smi
nvcc --version
printf 'NVIDIA_DRIVER_CAPABILITIES=%s\n' "${NVIDIA_DRIVER_CAPABILITIES-<unset>}"
dpkg-query -W > "$logs/packages.tsv"
find /usr/lib/x86_64-linux-gnu -maxdepth 1 \
  \( -name 'libGLX_nvidia.so*' -o -name 'libnvidia-gl*.so*' \) \
  -exec ls -l {} + -exec sha256sum {} + > "$logs/nvidia-libraries.txt"
awk '/nvidia/ {print}' /proc/self/mountinfo > "$logs/nvidia-mounts.txt"

vulkan_status=0
if timeout --kill-after=10s 60s vulkaninfo --summary > "$logs/vulkaninfo.log" 2>&1; then
  if ! grep -Eiq 'vendorID[[:space:]]*=[[:space:]]*0x10de' "$logs/vulkaninfo.log"; then
    echo "Vulkan enumeration did not report an NVIDIA device." | tee -a "$logs/result.txt"
    vulkan_status=1
  fi
else
  vulkan_status=$?
  echo "vulkaninfo failed or timed out (exit $vulkan_status)." | tee -a "$logs/result.txt"
fi
cat "$logs/vulkaninfo.log"
# A Vulkan diagnostic failure is evidence, but still attempt the actual repro.

curl --fail --location --retry 3 \
  "https://github.com/intel/llvm/releases/download/$TOOLCHAIN_TAG/sycl_linux.tar.gz" \
  --output sycl_linux.tar.gz
printf '%s  sycl_linux.tar.gz\n' "$TOOLCHAIN_SHA256" | sha256sum --check
mkdir toolchain
tar -xzf sycl_linux.tar.gz -C toolchain
export PATH="$work/toolchain/bin:$PATH"
export LD_LIBRARY_PATH="$work/toolchain/lib:${LD_LIBRARY_PATH-}"
export CUDA_PATH=/usr/local/cuda

"$work/toolchain/bin/dpclang++" --version
"$work/toolchain/bin/dpsycl-ls" | tee "$logs/sycl-ls.log"
if ! grep -q '^\[cuda:gpu' "$logs/sycl-ls.log"; then
  echo "No SYCL CUDA GPU: tests cannot reproduce the original GPU failure." | tee -a "$logs/result.txt"
  exit 1
fi

cmake -GNinja -S "$sources/sycl/test-e2e" -B "$work/build-e2e" \
  -DCMAKE_CXX_COMPILER="$work/toolchain/bin/dpclang++" \
  -DLLVM_LIT="$sources/llvm/utils/lit/lit.py" \
  -DSYCL_TEST_E2E_TARGETS=cuda:gpu \
  2>&1 | tee "$logs/configure.log"
cp "$work/build-e2e/CMakeCache.txt" "$logs/"

lit=(python3 "$sources/llvm/utils/lit/lit.py"
  -v --no-progress-bar --show-pass --show-unsupported --time-tests -j 1
  --param sycl_devices=cuda:gpu --param sycl_build_targets=nvidia
  --param cxx_flags=--cuda-gpu-arch=sm_75
  --param print_features=True
  --filter "^SYCL :: ${test_name//./\\.}$")

check_result() {
  python3 - "$logs/$1.json" "$test_name" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
tests = result["tests"]
if len(tests) != 1 or not tests[0]["name"].endswith(sys.argv[2]):
    raise SystemExit("ERROR: expected exactly the selected repro test, not zero or unrelated tests")
test = tests[0]
print(f'{test["name"]}: {test["code"]}, {test["elapsed"]:.3f} seconds')
if test["code"] == "TIMEOUT":
    print("Timeout reproduced; this alone does not establish the driver mismatch as its cause.")
elif test["code"] in ("UNSUPPORTED", "SKIPPED", "EXCLUDED"):
    print("ERROR: test did not execute; this is not a successful repro run.")
elif test["code"] != "PASS":
    print("Test failed; inspect the log before attributing it to the original problem.")
sys.exit(0 if test["code"] == "PASS" else 1)
PY
}

run_lit() {
  local phase=$1 mode=$2 limit=$3 status=0
  if timeout --kill-after=15s 900s "${lit[@]}" \
    --param "test-mode=$mode" --timeout "$limit" \
    --output "$logs/$phase.json" "$work/build-e2e" \
    2>&1 | tee "$logs/$phase.log"; then
    echo "$phase: lit exit 0" | tee -a "$logs/result.txt"
  else
    status=$?
    echo "$phase: lit/timeout exit $status" | tee -a "$logs/result.txt"
  fi
  if [[ ! -f "$logs/$phase.json" ]]; then
    echo "$phase: missing lit report; setup or harness failed." | tee -a "$logs/result.txt"
    return 1
  fi
  if ! check_result "$phase" | tee -a "$logs/result.txt"; then
    status=1
  fi
  return "$status"
}

# Separate compilation from execution: the original E2E timeout was 300s in run-only mode.
if ! run_lit build build-only 600; then
  echo "Compilation did not complete successfully; runtime repro was not attempted." | tee -a "$logs/result.txt"
  exit 1
fi

status=$vulkan_status
for attempt in 1 2; do
  if ! run_lit "run-$attempt" run-only 300; then
    status=1
  fi
done
if (( status == 0 )); then
  echo "Both executions passed; the original failure was not reproduced. No fix was applied." \
    | tee -a "$logs/result.txt"
fi
exit "$status"
