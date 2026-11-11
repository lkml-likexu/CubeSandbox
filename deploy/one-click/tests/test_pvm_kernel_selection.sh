#!/usr/bin/env bash
# Tests architecture-aware PVM guest-kernel selection and diagnostics.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONE_CLICK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=../lib/common.sh
source "${ONE_CLICK_DIR}/lib/common.sh"

fail_test() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local got="$1" want="$2" msg="$3"
  [[ "${got}" == "${want}" ]] || fail_test "${msg}: got='${got}' want='${want}'"
}

assert_fails() {
  local msg="$1"
  shift
  if ("$@") >/dev/null 2>&1; then
    fail_test "${msg}: command unexpectedly succeeded"
  fi
}

# Load the installer selector without executing install.sh.
# shellcheck disable=SC1090
source <(awk '
  /^select_installed_kernel_vmlinux\(\)/ {p=1}
  p {print}
  p && /^}/ {exit}
' "${ONE_CLICK_DIR}/install.sh")

declare -f select_installed_kernel_vmlinux >/dev/null \
  || fail_test "failed to load select_installed_kernel_vmlinux"

run_selection() {
  local name="$1" arch="$2" pvm_enabled="$3" with_bm="$4" with_pvm="$5"
  INSTALL_PREFIX="${TMP_DIR}/${name}"
  local kernel_dir="${INSTALL_PREFIX}/cube-kernel-scf"
  mkdir -p "${kernel_dir}"
  [[ "${with_bm}" == "1" ]] && printf 'bm-kernel\n' >"${kernel_dir}/vmlinux-bm"
  [[ "${with_pvm}" == "1" ]] && printf 'pvm-kernel\n' >"${kernel_dir}/vmlinux-pvm"
  CUBE_HOST_ARCH="${arch}" CUBE_PVM_ENABLE="${pvm_enabled}" select_installed_kernel_vmlinux
}

run_selection x86-pvm x86_64 1 1 1
assert_eq "$(readlink "${TMP_DIR}/x86-pvm/cube-kernel-scf/vmlinux")" "vmlinux-pvm" \
  "x86 PVM selects PVM guest kernel"
assert_eq "$(tr -d '[:space:]' <"${TMP_DIR}/x86-pvm/cube-kernel-scf/version")" \
  "sha256:$(file_sha256_hex "${TMP_DIR}/x86-pvm/cube-kernel-scf/vmlinux-pvm")" \
  "x86 PVM marker follows PVM guest kernel"

assert_fails "x86 PVM rejects BM-only package" run_selection x86-bm-only x86_64 1 1 0

for arch in arm64 aarch64; do
  run_selection "${arch}-pvm" "${arch}" 1 1 0
  assert_eq "$(readlink "${TMP_DIR}/${arch}-pvm/cube-kernel-scf/vmlinux")" "vmlinux-bm" \
    "${arch} PVM selects ordinary guest kernel"
  assert_eq "$(tr -d '[:space:]' <"${TMP_DIR}/${arch}-pvm/cube-kernel-scf/version")" \
    "sha256:$(file_sha256_hex "${TMP_DIR}/${arch}-pvm/cube-kernel-scf/vmlinux-bm")" \
    "${arch} PVM marker follows ordinary guest kernel"
  run_selection "${arch}-dual" "${arch}" 1 1 1
  assert_eq "$(readlink "${TMP_DIR}/${arch}-dual/cube-kernel-scf/vmlinux")" "vmlinux-bm" \
    "${arch} PVM ignores separate PVM artifact"
done

run_selection arm64-bm arm64 0 1 1
assert_eq "$(readlink "${TMP_DIR}/arm64-bm/cube-kernel-scf/vmlinux")" "vmlinux-bm" \
  "PVM-disabled arm64 keeps ordinary guest kernel"
assert_fails "arm64 PVM rejects package with no kernel" run_selection arm64-empty arm64 1 0 0

# Load the diagnostic function with reporting and host detection stubbed.
# shellcheck disable=SC1090
source <(awk '
  /^check_cube_kernel\(\)/ {p=1}
  p {print}
  p && /^}/ {exit}
' "${ONE_CLICK_DIR}/scripts/cube-diag/check-procs.sh")

declare -f check_cube_kernel >/dev/null || fail_test "failed to load check_cube_kernel"
section() { :; }
lsmod() { printf 'kvm_pvm 1 0\n'; }
pass() { printf 'PASS:%s:%s\n' "$1" "$2"; }
warn() { printf 'WARN:%s:%s\n' "$1" "$2"; }
fail() { printf 'FAIL:%s:%s\n' "$1" "$2"; }

TOOLBOX_ROOT="${TMP_DIR}/diag"
mkdir -p "${TOOLBOX_ROOT}/cube-kernel-scf"
printf 'bm-kernel\n' >"${TOOLBOX_ROOT}/cube-kernel-scf/vmlinux-bm"
ln -s vmlinux-bm "${TOOLBOX_ROOT}/cube-kernel-scf/vmlinux"
arm_diag="$(CUBE_HOST_ARCH=arm64 check_cube_kernel)"
[[ "${arm_diag}" == *"PASS:cube_kernel_vmlinux_pvm:not required on arm64 PVM hosts"* ]] \
  || fail_test "arm64 PVM diagnostic should accept missing PVM guest kernel"
x86_diag="$(CUBE_HOST_ARCH=x86_64 check_cube_kernel)"
[[ "${x86_diag}" == *"FAIL:cube_kernel_vmlinux_pvm:"* ]] \
  || fail_test "x86 PVM diagnostic should reject missing PVM guest kernel"

echo "PVM kernel selection tests OK"
