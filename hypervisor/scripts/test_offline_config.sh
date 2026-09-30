#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

source "$SCRIPT_DIR/test-util.sh"

WORKLOADS_DIR="$TMP_DIR/workloads"
mkdir -p "$WORKLOADS_DIR" "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/wget" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$WGET_LOG"
destination=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-O" ]; then
        destination="$2"
        break
    fi
    shift
done
printf artifact > "$destination"
EOF
chmod +x "$TMP_DIR/bin/wget"

cat > "$TMP_DIR/bin/uname" <<'EOF'
#!/bin/bash
if [ "$1" = "-m" ] && [ -n "${MOCK_ARCH:-}" ]; then
    printf '%s\n' "$MOCK_ARCH"
else
    /usr/bin/uname "$@"
fi
EOF
chmod +x "$TMP_DIR/bin/uname"

export PATH="$TMP_DIR/bin:$PATH"
export WGET_LOG="$TMP_DIR/wget.log"
export MOCK_ARCH=x86_64

WORKLOADS_BASE_URL="http://mirror.internal/workloads/"
CH_OFFLINE=false
require_offline_workloads missing
acquire_workload "kernel" "https://public.invalid/kernel"
grep -q '^--quiet http://mirror.internal/workloads/kernel -O .*/kernel$' "$WGET_LOG"

: > "$WGET_LOG"
acquire_workload "kernel" "https://public.invalid/kernel"
test ! -s "$WGET_LOG"

unset WORKLOADS_BASE_URL
: > "$WGET_LOG"
acquire_workload \
    "focal-server-cloudimg-amd64-custom-20210609-0.qcow2" \
    "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
grep -q '^--quiet https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img -O .*/focal-server-cloudimg-amd64-custom-20210609-0.qcow2$' "$WGET_LOG"

while IFS='|' read -r image_script image_url; do
    grep -q -F "$image_url" "$SCRIPT_DIR/$image_script"
done <<'EOF'
run_integration_tests_aarch64.sh|https://cloud-images.ubuntu.com/bionic/current/bionic-server-cloudimg-arm64.img
run_integration_tests_rate_limiter.sh|https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
run_integration_tests_live_migration.sh|https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
run_metrics.sh|https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
run_metrics.sh|https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-arm64.img
run_integration_tests_aarch64.sh|https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-arm64.img
run_integration_tests_aarch64.sh|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img
EOF
old_image_host='cloud-hypervisor.azureedge'".net"
if grep -R -q -F "$old_image_host" "$SCRIPT_DIR"; then
    echo "obsolete image host remains in scripts" >&2
    exit 1
fi

CH_OFFLINE=true
if require_offline_workloads kernel missing >"$TMP_DIR/offline.out" 2>&1; then
    echo "offline preflight unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'Offline workloads missing' "$TMP_DIR/offline.out"
grep -q 'missing' "$TMP_DIR/offline.out"

cat > "$TMP_DIR/bin/docker" <<'EOF'
#!/bin/bash
printf 'CUBE_PVM_ENABLE=%s\n' "${CUBE_PVM_ENABLE-<unset>}" >> "$DOCKER_LOG"
printf 'CH_TEST_DISK_PREP_JOBS=%s\n' "${CH_TEST_DISK_PREP_JOBS-<unset>}" >> "$DOCKER_LOG"
printf '%s\n' "$*" >> "$DOCKER_LOG"
printf 'ARG=%s\n' "$@" >> "$DOCKER_LOG"
if [ "$1" = "save" ]; then
    shift
    while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then
            printf image > "$2"
            break
        fi
        shift
    done
fi
exit 0
EOF
chmod +x "$TMP_DIR/bin/docker"

export DOCKER_LOG="$TMP_DIR/docker.log"
export TEST_TMP_DIR="$TMP_DIR"
MOCK_DEVICE_ROOT="$TMP_DIR/dev"
mkdir -p "$MOCK_DEVICE_ROOT"
ln -s /dev/null "$MOCK_DEVICE_ROOT/kvm"
ln -s /dev/null "$MOCK_DEVICE_ROOT/mshv"
export _CH_TEST_DEVICE_ROOT="$MOCK_DEVICE_ROOT"
HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --quick --offline

grep -q '^image inspect ghcr.io/cloud-hypervisor/cloud-hypervisor:20240507-0$' "$DOCKER_LOG"
if grep -q '^pull ' "$DOCKER_LOG"; then
    echo "offline mode attempted to pull a container image" >&2
    exit 1
fi
grep -q -- '--env CH_OFFLINE=true' "$DOCKER_LOG"
grep -q -- '--env CARGO_NET_OFFLINE=true' "$DOCKER_LOG"
grep -q -- '--env CUBE_PVM_ENABLE' "$DOCKER_LOG"
if grep -q -- '--env CUBE_PVM_ENABLE=' "$DOCKER_LOG"; then
    echo "unset PVM marker unexpectedly received a value" >&2
    exit 1
fi
grep -q '^CH_TEST_DISK_PREP_JOBS=<unset>$' "$DOCKER_LOG"
grep -q -- '--env CH_TEST_DISK_PREP_JOBS' "$DOCKER_LOG"
if grep -q -- '--env CH_TEST_DISK_PREP_JOBS=' "$DOCKER_LOG"; then
    echo "unset disk preparation job count unexpectedly received a value" >&2
    exit 1
fi
if grep -q 'CH_CUSTOM_KERNEL' "$DOCKER_LOG"; then
    echo "unset custom kernel unexpectedly reached Docker" >&2
    exit 1
fi

: > "$DOCKER_LOG"
CH_CUSTOM_KERNEL= HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline
if grep -q 'CH_CUSTOM_KERNEL' "$DOCKER_LOG"; then
    echo "empty custom kernel unexpectedly reached Docker" >&2
    exit 1
fi

CUSTOM_KERNEL_DIR="$TMP_DIR/custom kernels"
mkdir -p "$CUSTOM_KERNEL_DIR"
printf custom-kernel > "$CUSTOM_KERNEL_DIR/kernel image"
ln -s "$CUSTOM_KERNEL_DIR/kernel image" "$TMP_DIR/custom-kernel-link"
printf cached-kernel > "$TMP_DIR/home/workloads/vmlinux"
: > "$DOCKER_LOG"
CH_CUSTOM_KERNEL="$TMP_DIR/custom-kernel-link" \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline
canonical_kernel=$(realpath -e "$CUSTOM_KERNEL_DIR/kernel image")
grep -F -q "ARG=type=bind,source=$canonical_kernel,destination=/root/workloads/.custom-kernel,readonly" "$DOCKER_LOG"
grep -q '^ARG=CH_CUSTOM_KERNEL=/root/workloads/.custom-kernel$' "$DOCKER_LOG"
test "$(cat "$TMP_DIR/home/workloads/vmlinux")" = cached-kernel

: > "$DOCKER_LOG"
CH_CUSTOM_KERNEL="$CUSTOM_KERNEL_DIR/kernel image" \
    MOCK_ARCH=aarch64 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline
grep -F -q "ARG=type=bind,source=$canonical_kernel,destination=/root/workloads/.custom-kernel,readonly" "$DOCKER_LOG"
grep -q 'run_integration_tests_aarch64.sh' "$DOCKER_LOG"

printf comma-kernel > "$TMP_DIR/kernel,invalid"
for invalid_kernel in relative-kernel "$TMP_DIR/missing-kernel" "$TMP_DIR" "$TMP_DIR/kernel,invalid"; do
    : > "$DOCKER_LOG"
    if CH_CUSTOM_KERNEL="$invalid_kernel" \
        HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
        "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline \
        >"$TMP_DIR/custom-kernel-error.out" 2>&1; then
        echo "invalid custom kernel unexpectedly succeeded: $invalid_kernel" >&2
        exit 1
    fi
    grep -q 'CH_CUSTOM_KERNEL.*must\|CH_CUSTOM_KERNEL contains unsupported' "$TMP_DIR/custom-kernel-error.out"
    test ! -s "$DOCKER_LOG"
done

: > "$DOCKER_LOG"
CH_CUSTOM_KERNEL=relative-kernel \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --unit --offline
grep -q 'run_unit_tests.sh' "$DOCKER_LOG"
if grep -q 'CH_CUSTOM_KERNEL' "$DOCKER_LOG"; then
    echo "unit tests unexpectedly received the custom kernel" >&2
    exit 1
fi

for isolated_lane in --integration-sgx --integration-vfio --integration-windows \
    --integration-live-migration --integration-rate-limiter --metrics; do
    : > "$DOCKER_LOG"
    CH_CUSTOM_KERNEL=relative-kernel \
        HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
        "$SCRIPT_DIR/dev_cli.sh" tests "$isolated_lane" --offline
    if grep -q 'CH_CUSTOM_KERNEL' "$DOCKER_LOG"; then
        echo "$isolated_lane unexpectedly received the custom kernel" >&2
        exit 1
    fi
done

: > "$DOCKER_LOG"
CUBE_PVM_ENABLE=0 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline
grep -q '^CUBE_PVM_ENABLE=0$' "$DOCKER_LOG"
grep -q -- '--env CUBE_PVM_ENABLE' "$DOCKER_LOG"
if grep -q -- '--env CUBE_PVM_ENABLE=' "$DOCKER_LOG"; then
    echo "PVM marker should use Docker pass-through semantics" >&2
    exit 1
fi

: > "$DOCKER_LOG"
CUBE_PVM_ENABLE=1 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration-live-migration --offline
grep -q '^CUBE_PVM_ENABLE=1$' "$DOCKER_LOG"
grep -q -- '--env CUBE_PVM_ENABLE' "$DOCKER_LOG"
if grep -q -- '--env CUBE_PVM_ENABLE=' "$DOCKER_LOG"; then
    echo "PVM marker should use Docker pass-through semantics" >&2
    exit 1
fi

if grep -q '#\[ignore = "PVM' "$SCRIPT_DIR/../tests/integration.rs"; then
    echo "PVM-specific static test ignore remains" >&2
    exit 1
fi
test "$(grep -c '#\[ignore = "See #' "$SCRIPT_DIR/../tests/integration.rs")" -eq 2

: > "$DOCKER_LOG"
HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --hypervisor mshv --offline
grep -q 'run_integration_tests_x86_64.sh --hypervisor mshv' "$DOCKER_LOG"

KVM_ONLY_DEVICE_ROOT="$TMP_DIR/kvm-only-dev"
mkdir -p "$KVM_ONLY_DEVICE_ROOT"
ln -s /dev/null "$KVM_ONLY_DEVICE_ROOT/kvm"
: > "$DOCKER_LOG"
_CH_TEST_DEVICE_ROOT="$KVM_ONLY_DEVICE_ROOT" \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration-live-migration \
    --hypervisor mshv --offline >"$TMP_DIR/missing-mshv.out" 2>&1
grep -q 'selected mshv hypervisor requires /dev/mshv' "$TMP_DIR/missing-mshv.out"
test ! -s "$DOCKER_LOG"

MSHV_ONLY_DEVICE_ROOT="$TMP_DIR/mshv-only-dev"
mkdir -p "$MSHV_ONLY_DEVICE_ROOT"
ln -s /dev/null "$MSHV_ONLY_DEVICE_ROOT/mshv"
: > "$DOCKER_LOG"
_CH_TEST_DEVICE_ROOT="$MSHV_ONLY_DEVICE_ROOT" \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --hypervisor mshv --offline
grep -q 'run_integration_tests_x86_64.sh --hypervisor mshv' "$DOCKER_LOG"

: > "$DOCKER_LOG"
_CH_TEST_DEVICE_ROOT="$MSHV_ONLY_DEVICE_ROOT" \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline \
    >"$TMP_DIR/missing-kvm.out" 2>&1
grep -q 'selected kvm hypervisor requires /dev/kvm' "$TMP_DIR/missing-kvm.out"
test ! -s "$DOCKER_LOG"

INVALID_DEVICE_ROOT="$TMP_DIR/invalid-dev"
mkdir -p "$INVALID_DEVICE_ROOT"
printf not-a-device > "$INVALID_DEVICE_ROOT/kvm"
: > "$DOCKER_LOG"
_CH_TEST_DEVICE_ROOT="$INVALID_DEVICE_ROOT" \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline \
    >"$TMP_DIR/invalid-device.out" 2>&1
grep -q 'requires /dev/kvm to be a character device' "$TMP_DIR/invalid-device.out"
test ! -s "$DOCKER_LOG"

MISSING_DEVICE_ROOT="$TMP_DIR/missing-dev"
mkdir -p "$MISSING_DEVICE_ROOT"
: > "$DOCKER_LOG"
_CH_TEST_DEVICE_ROOT="$MISSING_DEVICE_ROOT" \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline \
    >"$TMP_DIR/missing-device.out" 2>&1
grep -q 'Skipping integration test lanes.*kvm.*requires /dev/kvm' "$TMP_DIR/missing-device.out"
grep -q 'nested virtualization' "$TMP_DIR/missing-device.out"
grep -q 'cannot provide a missing host device' "$TMP_DIR/missing-device.out"
test ! -s "$DOCKER_LOG"

: > "$DOCKER_LOG"
_CH_TEST_DEVICE_ROOT="$MISSING_DEVICE_ROOT" \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration-live-migration --offline \
    >"$TMP_DIR/missing-migration-device.out" 2>&1
grep -q 'Skipping integration test lanes.*kvm.*requires /dev/kvm' "$TMP_DIR/missing-migration-device.out"
test ! -s "$DOCKER_LOG"

: > "$DOCKER_LOG"
_CH_TEST_DEVICE_ROOT="$MISSING_DEVICE_ROOT" \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --integration-rate-limiter --offline \
    >"$TMP_DIR/mixed-lanes.out" 2>&1
grep -q 'Skipping integration test lanes' "$TMP_DIR/mixed-lanes.out"
grep -q 'run_integration_tests_rate_limiter.sh' "$DOCKER_LOG"
if grep -q 'run_integration_tests_x86_64.sh' "$DOCKER_LOG"; then
    echo "missing-device integration lane unexpectedly ran" >&2
    exit 1
fi

: > "$DOCKER_LOG"
CH_DEV_IMAGE=registry.internal/cloud-hypervisor/dev:test \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --quick --offline
grep -q '^image inspect registry.internal/cloud-hypervisor/dev:test$' "$DOCKER_LOG"
grep -q '^run .* registry.internal/cloud-hypervisor/dev:test ./scripts/run_integration_tests_x86_64.sh ' "$DOCKER_LOG"
if grep -q '^pull ' "$DOCKER_LOG"; then
    echo "custom image offline mode attempted to pull" >&2
    exit 1
fi

: > "$DOCKER_LOG"
CH_DEV_IMAGE=registry.internal/cloud-hypervisor/dev:test \
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" --local tests --integration --quick --offline
grep -q '^image inspect ghcr.io/cloud-hypervisor/cloud-hypervisor:local$' "$DOCKER_LOG"

: > "$DOCKER_LOG"
CH_TEST_THREADS=3 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline
grep -q 'run_integration_tests_x86_64.sh --hypervisor kvm --test-threads 3' "$DOCKER_LOG"

: > "$DOCKER_LOG"
CH_TEST_THREADS=3 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --test-threads 7 --offline
grep -q 'run_integration_tests_x86_64.sh --hypervisor kvm --test-threads 7' "$DOCKER_LOG"

: > "$DOCKER_LOG"
CH_TEST_DISK_PREP_JOBS=3 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline
grep -q '^CH_TEST_DISK_PREP_JOBS=3$' "$DOCKER_LOG"
grep -q -- '--env CH_TEST_DISK_PREP_JOBS' "$DOCKER_LOG"

if CH_TEST_DISK_PREP_JOBS=0 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline >"$TMP_DIR/disk-prep-jobs.out" 2>&1; then
    echo "zero disk preparation job count unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'Disk preparation job count must be a positive integer: 0' "$TMP_DIR/disk-prep-jobs.out"

: > "$DOCKER_LOG"
CH_TEST_THREADS=3 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration-live-migration --offline
grep -q 'run_integration_tests_live_migration.sh --hypervisor kvm --test-threads 3' "$DOCKER_LOG"

: > "$DOCKER_LOG"
CH_TEST_THREADS=3 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration-live-migration \
    --test-threads 7 --offline
grep -q 'run_integration_tests_live_migration.sh --hypervisor kvm --test-threads 7' "$DOCKER_LOG"

if HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --test-threads 0 >"$TMP_DIR/threads.out" 2>&1; then
    echo "zero test thread count unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'Test thread count must be a positive integer: 0' "$TMP_DIR/threads.out"

if HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --offline >"$TMP_DIR/no-test-type.out" 2>&1; then
    echo "tests command without a test type unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'No test type selected' "$TMP_DIR/no-test-type.out"

build_test_filters "live_migration::live_migration_parallel" "test_live_migration_basic"
test "${#test_filters[@]}" -eq 1
test "${test_filters[0]}" = "live_migration::live_migration_parallel::test_live_migration_basic"
grep -q 'build_test_filters "live_migration::live_migration_parallel" "test_live_migration_basic"' \
    "$SCRIPT_DIR/run_integration_tests_x86_64.sh"
X86_RUNNER="$SCRIPT_DIR/run_integration_tests_x86_64.sh"
grep -q -- '--target "$BUILD_TARGET"' "$X86_RUNNER"
grep -q -- '--target-dir "$CH_CARGO_TARGET_DIR"' "$X86_RUNNER"
grep -q -- '--test integration' "$X86_RUNNER"
grep -q 'run_integration_test()' "$X86_RUNNER"
grep -q 'run_lib_integration_test()' "$X86_RUNNER"
grep -q 'precompile_integration_test()' "$X86_RUNNER"
grep -q 'precompile_lib_integration_test()' "$X86_RUNNER"
if grep -q 'VFIO_DIR\|VFIO_DISK_IMAGE' "$X86_RUNNER"; then
    echo "default integration runner still stages VFIO assets" >&2
    exit 1
fi
grep -q 'VFIO_DIR=' "$SCRIPT_DIR/run_integration_tests_vfio.sh"
grep -q 'Phase timing:' "$X86_RUNNER"

X86_CUSTOM_HOME="$TMP_DIR/x86-custom-home"
mkdir -p "$X86_CUSTOM_HOME/.cargo"
: > "$X86_CUSTOM_HOME/.cargo/env"
if (
    cd "$SCRIPT_DIR/.."
    HOME="$X86_CUSTOM_HOME" CH_OFFLINE=true \
        ./scripts/run_integration_tests_x86_64.sh
) >"$TMP_DIR/x86-default-offline.out" 2>&1; then
    echo "incomplete x86 offline workloads unexpectedly succeeded" >&2
    exit 1
fi
grep -q '^  vmlinux$' "$TMP_DIR/x86-default-offline.out"

if (
    cd "$SCRIPT_DIR/.."
    HOME="$X86_CUSTOM_HOME" CH_OFFLINE=true \
        CH_CUSTOM_KERNEL=/root/workloads/.custom-kernel \
        ./scripts/run_integration_tests_x86_64.sh
) >"$TMP_DIR/x86-custom-offline.out" 2>&1; then
    echo "incomplete x86 offline workloads unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'Offline workloads missing' "$TMP_DIR/x86-custom-offline.out"
if grep -q '^  vmlinux$' "$TMP_DIR/x86-custom-offline.out"; then
    echo "custom kernel still requires the canonical x86 kernel" >&2
    exit 1
fi

test "$(WORKLOADS_BASE_URL= workload_url kernel https://public.invalid/kernel)" = "https://public.invalid/kernel"
printf '%s\n' unknown-artifact > "$WORKLOADS_DIR/.custom_x86_artifacts"
if load_custom_x86_artifacts >"$TMP_DIR/custom-marker.out" 2>&1; then
    echo "unknown custom artifact marker unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'Unknown custom x86 artifact: unknown-artifact' "$TMP_DIR/custom-marker.out"
rm -f "$WORKLOADS_DIR/.custom_x86_artifacts"

MIGRATION_HOME="$TMP_DIR/migration-home"
MIGRATION_BIN="$TMP_DIR/migration-bin"
MIGRATION_ROOT="$TMP_DIR/migration-root"
mkdir -p \
    "$MIGRATION_HOME/.cargo" \
    "$MIGRATION_HOME/workloads" \
    "$MIGRATION_BIN" \
    "$MIGRATION_ROOT/scripts"
/bin/cp "$SCRIPT_DIR/run_integration_tests_live_migration.sh" "$MIGRATION_ROOT/scripts/"
/bin/cp "$SCRIPT_DIR/test-util.sh" "$MIGRATION_ROOT/scripts/"
/bin/cp "$SCRIPT_DIR/sha1sums-x86_64" "$MIGRATION_ROOT/scripts/"
: > "$MIGRATION_HOME/.cargo/env"
printf qcow2 > "$MIGRATION_HOME/workloads/focal-server-cloudimg-amd64-custom-20210609-0.qcow2"
printf raw > "$MIGRATION_HOME/workloads/focal-server-cloudimg-amd64-custom-20210609-0.raw"
printf kernel > "$MIGRATION_HOME/workloads/vmlinux"
printf '%s\n' focal-server-cloudimg-amd64-custom-20210609-0.qcow2 \
    > "$MIGRATION_HOME/workloads/.custom_x86_artifacts"
cat > "$MIGRATION_BIN/cargo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MIGRATION_CARGO_LOG"
if [ "$1" = build ]; then
    target="x86_64-unknown-linux-gnu"
    mkdir -p "target/$target/release"
    : > "target/$target/release/cube-hypervisor"
    : > "target/$target/release/vhost_user_net"
    : > "target/$target/release/ch-remote"
fi
EOF
cat > "$MIGRATION_BIN/strip" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$MIGRATION_BIN/sudo" <<'EOF'
#!/bin/bash
printf 'unexpected sudo: %s\n' "$*" >> "$MIGRATION_SUDO_LOG"
exit 1
EOF
chmod +x "$MIGRATION_BIN"/*
export MIGRATION_CARGO_LOG="$TMP_DIR/migration-cargo.log"
export MIGRATION_SUDO_LOG="$TMP_DIR/migration-sudo.log"
(
    cd "$MIGRATION_ROOT"
    PATH="$MIGRATION_BIN:$PATH" HOME="$MIGRATION_HOME" CH_LIBC=gnu \
        ./scripts/run_integration_tests_live_migration.sh
) > "$TMP_DIR/migration-default.out" 2>&1
grep -q '^test live_migration_parallel:: -- --test-threads=4$' "$MIGRATION_CARGO_LOG"
grep -q '^test live_migration_sequential:: -- --test-threads=1$' "$MIGRATION_CARGO_LOG"
grep -q 'Running live migration parallel tests with 4 threads' "$TMP_DIR/migration-default.out"
test ! -s "$MIGRATION_SUDO_LOG"

: > "$MIGRATION_CARGO_LOG"
(
    cd "$MIGRATION_ROOT"
    PATH="$MIGRATION_BIN:$PATH" HOME="$MIGRATION_HOME" CH_LIBC=gnu \
        ./scripts/run_integration_tests_live_migration.sh --test-threads 2
) > "$TMP_DIR/migration-override.out" 2>&1
grep -q '^test live_migration_parallel:: -- --test-threads=2$' "$MIGRATION_CARGO_LOG"
grep -q '^test live_migration_sequential:: -- --test-threads=1$' "$MIGRATION_CARGO_LOG"
grep -q 'Running live migration parallel tests with 2 threads' "$TMP_DIR/migration-override.out"
test ! -s "$MIGRATION_SUDO_LOG"

mkdir -p "$TMP_DIR/arm-home/.cargo"
: > "$TMP_DIR/arm-home/.cargo/env"
if (
    cd "$SCRIPT_DIR/.."
    HOME="$TMP_DIR/arm-home" CH_OFFLINE=true CH_LIBC=gnu \
        SPDK_INSTALL_DIR="$TMP_DIR/spdk-install" \
        ./scripts/run_integration_tests_aarch64.sh --prepare-offline
) >"$TMP_DIR/arm-offline.out" 2>&1; then
    echo "aarch64 offline preflight unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'Offline workloads missing' "$TMP_DIR/arm-offline.out"
grep -q 'CLOUDHV_EFI.fd' "$TMP_DIR/arm-offline.out"
grep -q 'spdk-nvme/nvmf_tgt' "$TMP_DIR/arm-offline.out"
grep -q '^  Image$' "$TMP_DIR/arm-offline.out"

if (
    cd "$SCRIPT_DIR/.."
    HOME="$TMP_DIR/arm-home" CH_OFFLINE=true CH_LIBC=gnu \
        CH_CUSTOM_KERNEL=/root/workloads/.custom-kernel \
        SPDK_INSTALL_DIR="$TMP_DIR/spdk-install" \
        ./scripts/run_integration_tests_aarch64.sh --prepare-offline
) >"$TMP_DIR/arm-custom-offline.out" 2>&1; then
    echo "incomplete aarch64 offline workloads unexpectedly succeeded" >&2
    exit 1
fi
if grep -q '^  Image$' "$TMP_DIR/arm-custom-offline.out"; then
    echo "custom kernel still requires the canonical aarch64 Image" >&2
    exit 1
fi
grep -q '^  Image.gz$' "$TMP_DIR/arm-custom-offline.out"

if grep -q 'cargo build --all' "$TMP_DIR/arm-offline.out"; then
    echo "aarch64 offline preflight reached the Cargo build" >&2
    exit 1
fi

ARM_DERIVE_HOME="$TMP_DIR/arm-derive-home"
ARM_DERIVE_WORKLOADS="$ARM_DERIVE_HOME/workloads"
ARM_DERIVE_BIN="$TMP_DIR/arm-derive-bin"
mkdir -p \
    "$ARM_DERIVE_HOME/.cargo" \
    "$ARM_DERIVE_WORKLOADS/shared_dir" \
    "$ARM_DERIVE_WORKLOADS/spdk-nvme/rpc" \
    "$ARM_DERIVE_BIN"
: > "$ARM_DERIVE_HOME/.cargo/env"
for artifact in \
    bionic-server-cloudimg-arm64.qcow2 \
    focal-server-cloudimg-arm64-custom-20210929-0.qcow2 \
    jammy-server-cloudimg-arm64-custom-20220329-0.qcow2 \
    alpine-minirootfs-aarch64.tar.gz \
    cloud-hypervisor-static-aarch64 \
    Image.gz \
    CLOUDHV_EFI.fd \
    virtiofsd \
    blk.img; do
    printf '%s' "$artifact" > "$ARM_DERIVE_WORKLOADS/$artifact"
done
printf file1 > "$ARM_DERIVE_WORKLOADS/shared_dir/file1"
printf file3 > "$ARM_DERIVE_WORKLOADS/shared_dir/file3"
printf nvmf > "$ARM_DERIVE_WORKLOADS/spdk-nvme/nvmf_tgt"
printf rpc > "$ARM_DERIVE_WORKLOADS/spdk-nvme/rpc.py"
printf '%s\n' \
    bionic-server-cloudimg-arm64.qcow2 \
    focal-server-cloudimg-arm64-custom-20210929-0.qcow2 \
    jammy-server-cloudimg-arm64-custom-20220329-0.qcow2 \
    alpine-minirootfs-aarch64.tar.gz \
    cloud-hypervisor-static-aarch64 \
    > "$ARM_DERIVE_WORKLOADS/.custom_aarch64_artifacts"
cat > "$ARM_DERIVE_BIN/qemu-img" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ARM_DERIVE_LOG"
/bin/cp "${@: -2:1}" "${@: -1}"
EOF
cat > "$ARM_DERIVE_BIN/tar" <<'EOF'
#!/bin/bash
mkdir -p "${@: -1}/bin"
printf busybox > "${@: -1}/bin/busybox"
EOF
cat > "$ARM_DERIVE_BIN/cpio" <<'EOF'
#!/bin/bash
printf initramfs
EOF
cat > "$ARM_DERIVE_BIN/guestmount" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ARM_DERIVE_LOG"
mkdir -p "${@: -1}/boot"
EOF
cat > "$ARM_DERIVE_BIN/guestunmount" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$ARM_DERIVE_BIN/sha1sum" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$ARM_DERIVE_BIN/cargo" <<'EOF'
#!/bin/bash
printf 'cargo %s\n' "$*" >> "$ARM_DERIVE_LOG"
EOF
cat > "$ARM_DERIVE_BIN/strip" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$ARM_DERIVE_BIN/wget" <<'EOF'
#!/bin/bash
printf 'unexpected wget: %s\n' "$*" >> "$ARM_DERIVE_LOG"
exit 1
EOF
chmod +x "$ARM_DERIVE_BIN"/*
export ARM_DERIVE_LOG="$TMP_DIR/arm-derive.log"
(
    cd "$SCRIPT_DIR/.."
    PATH="$ARM_DERIVE_BIN:$PATH" \
        HOME="$ARM_DERIVE_HOME" \
        CH_OFFLINE=true \
        CH_LIBC=gnu \
        CH_CUSTOM_KERNEL=/root/workloads/.custom-kernel \
        WORKLOADS_DIR="$ARM_DERIVE_WORKLOADS" \
        SPDK_INSTALL_DIR="$TMP_DIR/arm-spdk-install" \
        ./scripts/run_integration_tests_aarch64.sh --prepare-offline
) > "$TMP_DIR/arm-derive.out" 2>&1
for artifact in \
    bionic-server-cloudimg-arm64.raw \
    focal-server-cloudimg-arm64-custom-20210929-0.raw \
    jammy-server-cloudimg-arm64-custom-20220329-0.raw \
    focal-server-cloudimg-arm64-custom-20210929-0-update-kernel.raw \
    alpine_initramfs.img; do
    test -f "$ARM_DERIVE_WORKLOADS/$artifact"
done
test "$(cat "$ARM_DERIVE_WORKLOADS/focal-server-cloudimg-root/boot/vmlinuz")" = "$(cat "$ARM_DERIVE_WORKLOADS/Image.gz")"
test ! -e "$ARM_DERIVE_WORKLOADS/Image"
if grep -q 'linux-custom' "$ARM_DERIVE_LOG"; then
    echo "custom kernel unexpectedly rebuilt the canonical aarch64 Image" >&2
    exit 1
fi
test "$(grep -c 'qcow2 -O raw' "$ARM_DERIVE_LOG")" -eq 3
grep -q '^cargo build --all --release .*--target-dir target' "$ARM_DERIVE_LOG"
grep -q '^cargo test .*--no-run.*--target-dir target' "$ARM_DERIVE_LOG"
if grep -q 'unexpected wget' "$ARM_DERIVE_LOG"; then
    echo "aarch64 offline derivation attempted a download" >&2
    exit 1
fi

: > "$DOCKER_LOG"
HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration-live-migration \
    --workloads-base-url 'http://mirror.internal/workloads'
grep -q -- '--env WORKLOADS_BASE_URL=http://mirror.internal/workloads' "$DOCKER_LOG"
grep -q -- '--env CH_CARGO_TARGET_DIR=/cloud-hypervisor/build/cargo_target' "$DOCKER_LOG"
grep -q 'run_integration_tests_live_migration.sh' "$DOCKER_LOG"

: > "$DOCKER_LOG"
MOCK_ARCH=aarch64 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration-live-migration --offline
grep -q 'run_integration_tests_aarch64.sh --live-migration-only --hypervisor kvm' "$DOCKER_LOG"
grep -q -- '--env CH_OFFLINE=true' "$DOCKER_LOG"
grep -q -- '--env CARGO_NET_OFFLINE=true' "$DOCKER_LOG"
grep -q -- '--env CH_CARGO_TARGET_DIR=/cloud-hypervisor/build/cargo_target' "$DOCKER_LOG"

: > "$DOCKER_LOG"
HOME="$TMP_DIR/home" "$SCRIPT_DIR/dev_cli.sh" build-container --apt-mirror 'http://apt.internal'
grep -q -- '--build-arg APT_MIRROR_BASE=http://apt.internal' "$DOCKER_LOG"

if "$SCRIPT_DIR/dev_cli.sh" build-container --apt-mirror 'file:///mirror' >"$TMP_DIR/url.out" 2>&1; then
    echo "invalid APT mirror unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'must be an http(s) URL' "$TMP_DIR/url.out"

integration_tests="$SCRIPT_DIR/../tests/integration.rs"
common_parallel_module=$(sed -n '/mod common_parallel {/,/mod common_sequential {/p' \
    "$integration_tests")
common_sequential_module=$(sed -n '/mod common_sequential {/,/mod live_migration {/p' \
    "$integration_tests")
for test_name in test_watchdog test_macvtap test_macvtap_hotplug \
    test_virtio_block_direct_and_firmware; do
    test "$(grep -c "fn ${test_name}()" "$integration_tests")" -eq 1
    if grep -q "fn ${test_name}()" <<< "$common_parallel_module"; then
        echo "$test_name remains in the parallel module" >&2
        exit 1
    fi
    grep -q "fn ${test_name}()" <<< "$common_sequential_module"
done
live_migration_sequential_module=$(sed -n '/mod live_migration_sequential {/,$p' \
    "$integration_tests")
test "$(grep -c 'fn test_live_.*watchdog' <<< "$live_migration_sequential_module")" -eq 4
runner="$SCRIPT_DIR/run_integration_tests_aarch64.sh"
for suite in common_parallel common_sequential aarch64_acpi \
    live_migration_parallel live_migration_sequential; do
    grep -A1 "cargo test.*\"${suite}::\$test_filter\"" "$runner" | \
        grep -q 'record_result \$?'
done

grep -q 'rustup target add \$ARCH-unknown-linux-musl' "$SCRIPT_DIR/../resources/Dockerfile"
if grep -q 'rustup toolchain add.*unknown-linux-musl' "$SCRIPT_DIR/../resources/Dockerfile"; then
    echo "Dockerfile installs a musl target as a host toolchain" >&2
    exit 1
fi

: > "$DOCKER_LOG"
mkdir -p \
    "$TMP_DIR/home/workloads/alpine-minirootfs" \
    "$TMP_DIR/home/workloads/edk2_build" \
    "$TMP_DIR/home/workloads/linux-custom" \
    "$TMP_DIR/home/workloads/spdk" \
    "$TMP_DIR/home/workloads/spdk-nvme/rpc" \
    "$TMP_DIR/home/workloads/vfio" \
    "$TMP_DIR/home/workloads/virtiofsd_build" \
    "$TMP_DIR/home/workloads/cache/.git"
printf workload > "$TMP_DIR/home/workloads/vmlinux"
printf derived > "$TMP_DIR/home/workloads/cloud-hypervisor-static"
for artifact in \
    bionic-server-cloudimg-amd64.qcow2 \
    focal-server-cloudimg-amd64-custom-20210609-0.qcow2 \
    jammy-server-cloudimg-amd64-custom-20220329-0.qcow2 \
    alpine-minirootfs-x86_64.tar.gz; do
    printf canonical > "$TMP_DIR/home/workloads/$artifact"
done
for artifact in \
    bionic-server-cloudimg-amd64.raw \
    focal-server-cloudimg-amd64-custom-20210609-0.raw \
    jammy-server-cloudimg-amd64-custom-20220329-0.raw \
    alpine_initramfs.img; do
    printf derived > "$TMP_DIR/home/workloads/$artifact"
done
printf derived > "$TMP_DIR/home/workloads/alpine-minirootfs/init"
printf derived > "$TMP_DIR/home/workloads/vfio/focal-server-cloudimg-amd64-custom-20210609-0.raw"
printf build > "$TMP_DIR/home/workloads/edk2_build/object"
printf build > "$TMP_DIR/home/workloads/linux-custom/object"
printf build > "$TMP_DIR/home/workloads/spdk/object"
printf required > "$TMP_DIR/home/workloads/spdk-nvme/nvmf_tgt"
printf required > "$TMP_DIR/home/workloads/spdk-nvme/rpc.py"
printf required > "$TMP_DIR/home/workloads/spdk-nvme/rpc/client.py"
printf build > "$TMP_DIR/home/workloads/virtiofsd_build/object"
printf metadata > "$TMP_DIR/home/workloads/cache/.git/config"
cat > "$TMP_DIR/bin/pigz" <<'EOF'
#!/bin/bash
printf 'pigz\n' >> "$PIGZ_LOG"
exec /usr/bin/gzip "$@"
EOF
chmod +x "$TMP_DIR/bin/pigz"
export PIGZ_LOG="$TMP_DIR/pigz.log"
BUNDLE_SOURCE="$TMP_DIR/CubeSandbox-source"
mkdir -p "$BUNDLE_SOURCE/hypervisor/scripts"
/bin/cp "$SCRIPT_DIR/dev_cli.sh" "$BUNDLE_SOURCE/hypervisor/scripts/dev_cli.sh"
/bin/cp "$SCRIPT_DIR/../Cargo.toml" "$BUNDLE_SOURCE/hypervisor/Cargo.toml"
/bin/cp "$SCRIPT_DIR/../.gitignore" "$BUNDLE_SOURCE/hypervisor/.gitignore"
printf 'first commit\n' > "$BUNDLE_SOURCE/source-marker"
git -C "$BUNDLE_SOURCE" init -q
git -C "$BUNDLE_SOURCE" config user.name 'Offline Bundle Test'
git -C "$BUNDLE_SOURCE" config user.email 'offline-bundle@example.invalid'
git -C "$BUNDLE_SOURCE" add .
git -C "$BUNDLE_SOURCE" commit -qm 'initial source'
FIRST_SOURCE_COMMIT=$(git -C "$BUNDLE_SOURCE" rev-parse HEAD)
printf 'current commit\n' > "$BUNDLE_SOURCE/source-marker"
git -C "$BUNDLE_SOURCE" add source-marker
git -C "$BUNDLE_SOURCE" commit -qm 'update source'
SOURCE_COMMIT=$(git -C "$BUNDLE_SOURCE" rev-parse HEAD)

printf 'dirty\n' >> "$BUNDLE_SOURCE/source-marker"
: > "$DOCKER_LOG"
if CUBESANDBOX_DIR="$BUNDLE_SOURCE" HOME="$TMP_DIR/home" \
    DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle >"$TMP_DIR/dirty-source.out" 2>&1; then
    echo "bundle preparation unexpectedly accepted tracked source changes" >&2
    exit 1
fi
grep -q 'source must be a clean committed Git worktree' "$TMP_DIR/dirty-source.out"
test ! -s "$DOCKER_LOG"
git -C "$BUNDLE_SOURCE" checkout -q -- source-marker
printf 'staged\n' >> "$BUNDLE_SOURCE/source-marker"
git -C "$BUNDLE_SOURCE" add source-marker
if CUBESANDBOX_DIR="$BUNDLE_SOURCE" HOME="$TMP_DIR/home" \
    DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle >"$TMP_DIR/staged-source.out" 2>&1; then
    echo "bundle preparation unexpectedly accepted staged source changes" >&2
    exit 1
fi
grep -q 'source must be a clean committed Git worktree' "$TMP_DIR/staged-source.out"
test ! -s "$DOCKER_LOG"
git -C "$BUNDLE_SOURCE" reset -q --hard HEAD
printf 'untracked\n' > "$BUNDLE_SOURCE/untracked-source"
if CUBESANDBOX_DIR="$BUNDLE_SOURCE" HOME="$TMP_DIR/home" \
    DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle >"$TMP_DIR/untracked-source.out" 2>&1; then
    echo "bundle preparation unexpectedly accepted untracked source files" >&2
    exit 1
fi
grep -q 'source must be a clean committed Git worktree' "$TMP_DIR/untracked-source.out"
test ! -s "$DOCKER_LOG"
rm "$BUNDLE_SOURCE/untracked-source"
mkdir -p \
    "$BUNDLE_SOURCE/hypervisor/build/cargo_registry" \
    "$BUNDLE_SOURCE/hypervisor/build/cargo_git_registry" \
    "$BUNDLE_SOURCE/hypervisor/build/cargo_target/x86_64-unknown-linux-gnu/release" \
    "$BUNDLE_SOURCE/hypervisor/build/cargo_target/aarch64-unknown-linux-gnu/release" \
    "$BUNDLE_SOURCE/hypervisor/target"
printf ignored > "$BUNDLE_SOURCE/hypervisor/build/ignored-cache"
printf registry > "$BUNDLE_SOURCE/hypervisor/build/cargo_registry/placeholder"
printf git-registry > "$BUNDLE_SOURCE/hypervisor/build/cargo_git_registry/placeholder"
printf x86-binary > "$BUNDLE_SOURCE/hypervisor/build/cargo_target/x86_64-unknown-linux-gnu/release/cube-hypervisor"
printf arm-binary > "$BUNDLE_SOURCE/hypervisor/build/cargo_target/aarch64-unknown-linux-gnu/release/cube-hypervisor"
printf stale > "$BUNDLE_SOURCE/hypervisor/target/must-not-be-bundled"

(
    cd "$TMP_DIR"
    CH_DEV_IMAGE=registry.internal/cloud-hypervisor/dev:bundle \
        CUBESANDBOX_DIR="$BUNDLE_SOURCE" \
        HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
        "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle
)
BUNDLE=$(find "$TMP_DIR" -maxdepth 1 -name 'cloud-hypervisor-offline-*-x86_64.tgz' -print -quit)
test -n "$BUNDLE"
grep -q '^pigz$' "$PIGZ_LOG"
grep -q 'run_integration_tests_x86_64.sh --hypervisor kvm --prepare-offline' "$DOCKER_LOG"
grep -q 'run_integration_tests_live_migration.sh --hypervisor kvm --prepare-offline' "$DOCKER_LOG"
test "$(grep -c -- '--env CH_CARGO_TARGET_DIR=/cloud-hypervisor/build/cargo_target' "$DOCKER_LOG")" -eq 2
if grep -q '^save ' "$DOCKER_LOG"; then
    echo "bundle preparation unexpectedly exported the development image" >&2
    exit 1
fi
tar -tzf "$BUNDLE" > "$TMP_DIR/bundle.list"
grep -q '^./MANIFEST$' "$TMP_DIR/bundle.list"
grep -q '^./SHA256SUMS$' "$TMP_DIR/bundle.list"
if grep -q '^./docker/cloud-hypervisor-dev-image.tar$' "$TMP_DIR/bundle.list"; then
    echo "bundle unexpectedly contains the development image tar" >&2
    exit 1
fi
grep -q '^./workloads/vmlinux$' "$TMP_DIR/bundle.list"
grep -q '^./workloads/bionic-server-cloudimg-amd64.qcow2$' "$TMP_DIR/bundle.list"
grep -q '^./workloads/alpine-minirootfs-x86_64.tar.gz$' "$TMP_DIR/bundle.list"
grep -q '^./workloads/spdk-nvme/nvmf_tgt$' "$TMP_DIR/bundle.list"
if grep -Eq '^\./workloads/(.*/)?\.git(/|$)|^\./workloads/(alpine_initramfs\.img|alpine-minirootfs/|cloud-hypervisor-static$|edk2_build/|linux-custom/|spdk/|vfio/|virtiofsd_build/)|^\./workloads/(.*/)?[^/]*-server-cloudimg-.*\.(img|raw)$' "$TMP_DIR/bundle.list"; then
    echo "bundle unexpectedly contains derived workloads" >&2
    exit 1
fi
test -f "$TMP_DIR/home/workloads/bionic-server-cloudimg-amd64.raw"
test -f "$TMP_DIR/home/workloads/alpine_initramfs.img"
test -f "$TMP_DIR/home/workloads/vfio/focal-server-cloudimg-amd64-custom-20210609-0.raw"
grep -q '^./CubeSandbox/hypervisor/scripts/dev_cli.sh$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/source-marker$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/.git/$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/.git/shallow$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/hypervisor/build/cargo_registry/placeholder$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/hypervisor/build/cargo_git_registry/placeholder$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/hypervisor/build/cargo_target/x86_64-unknown-linux-gnu/release/cube-hypervisor$' "$TMP_DIR/bundle.list"
if grep -q '^./CubeSandbox/hypervisor/build/cargo_target/aarch64-unknown-linux-' "$TMP_DIR/bundle.list"; then
    echo "x86_64 bundle unexpectedly contains aarch64 target artifacts" >&2
    exit 1
fi
if grep -q '^./CubeSandbox/hypervisor/target/' "$TMP_DIR/bundle.list"; then
    echo "bundle unexpectedly contains the legacy hypervisor target directory" >&2
    exit 1
fi
if grep -q '^./CubeSandbox/hypervisor/build/ignored-cache$' "$TMP_DIR/bundle.list"; then
    echo "bundle unexpectedly copied ignored source-tree build output" >&2
    exit 1
fi
if grep -q '^./CubeSandbox/CubeSandbox/' "$TMP_DIR/bundle.list"; then
    echo "bundle unexpectedly contains a nested extracted source tree" >&2
    exit 1
fi
if grep -q '\.dev_cli\.log\.txt$' "$TMP_DIR/bundle.list"; then
    echo "bundle unexpectedly contains a dev CLI log" >&2
    exit 1
fi
test "$(tar -xOf "$BUNDLE" ./CubeSandbox/source-marker)" = 'current commit'
test "$(tar -xOf "$BUNDLE" ./MANIFEST | grep '^source_commit=' | cut -d= -f2-)" = "$SOURCE_COMMIT"
tar -xOf "$BUNDLE" ./MANIFEST | grep -q '^source_dirty=false$'
tar -xOf "$BUNDLE" ./MANIFEST | grep -q '^source_clone_method=git-clone$'
tar -xOf "$BUNDLE" ./MANIFEST | grep -q '^source_clone_depth=1$'
tar -xOf "$BUNDLE" ./MANIFEST | grep -q '^source_shallow=true$'
tar -xOf "$BUNDLE" ./MANIFEST | grep -q '^container_image=registry.internal/cloud-hypervisor/dev:bundle$'
tar -xOf "$BUNDLE" ./MANIFEST | grep -q '^hypervisor_target_destination=CubeSandbox/hypervisor/build/cargo_target$'
mkdir "$TMP_DIR/extracted"
tar -xzf "$BUNDLE" -C "$TMP_DIR/extracted"
(
    cd "$TMP_DIR/extracted"
    sha256sum --check SHA256SUMS >/dev/null
    test "$(git -C CubeSandbox rev-parse --is-shallow-repository)" = true
    test "$(git -C CubeSandbox rev-list --count HEAD)" = 1
    test "$(git -C CubeSandbox rev-parse HEAD)" = "$SOURCE_COMMIT"
    test "$(git -C CubeSandbox remote)" = ""
    test -z "$(git -C CubeSandbox status --porcelain --untracked-files=all)"
    if git -C CubeSandbox cat-file -e "$FIRST_SOURCE_COMMIT^{commit}" 2>/dev/null; then
        echo "depth-1 source clone unexpectedly contains the previous commit" >&2
        exit 1
    fi
)
grep -q 'chown -R .* /cloud-hypervisor /root/workloads' "$DOCKER_LOG"

CUSTOM_ARTIFACTS="$TMP_DIR/custom-artifacts"
CUSTOM_BUNDLE_OUTPUT="$TMP_DIR/custom-bundle-output"
mkdir -p "$CUSTOM_ARTIFACTS" "$CUSTOM_BUNDLE_OUTPUT"
for artifact in hypervisor-fw CLOUDHV.fd bionic.qcow2 focal.qcow2 jammy.qcow2 alpine.tar.gz vmlinux virtiofsd; do
    printf 'custom-%s' "$artifact" > "$CUSTOM_ARTIFACTS/$artifact"
done
printf stale > "$TMP_DIR/home/workloads/bionic-server-cloudimg-amd64.raw"
printf stale > "$TMP_DIR/home/workloads/focal-server-cloudimg-amd64-custom-20210609-0.raw"
printf stale > "$TMP_DIR/home/workloads/jammy-server-cloudimg-amd64-custom-20220329-0.raw"
printf stale > "$TMP_DIR/home/workloads/alpine_initramfs.img"
(
    cd "$CUSTOM_BUNDLE_OUTPUT"
    CUBESANDBOX_DIR="$BUNDLE_SOURCE" \
        HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
        CH_X86_HYPERVISOR_FW_FILE="$CUSTOM_ARTIFACTS/hypervisor-fw" \
        CH_X86_CLOUDHV_FD_FILE="$CUSTOM_ARTIFACTS/CLOUDHV.fd" \
        CH_X86_BIONIC_QCOW2_FILE="$CUSTOM_ARTIFACTS/bionic.qcow2" \
        CH_X86_FOCAL_QCOW2_FILE="$CUSTOM_ARTIFACTS/focal.qcow2" \
        CH_X86_JAMMY_QCOW2_FILE="$CUSTOM_ARTIFACTS/jammy.qcow2" \
        CH_X86_ALPINE_MINIROOTFS_FILE="$CUSTOM_ARTIFACTS/alpine.tar.gz" \
        CH_X86_VMLINUX_FILE="$CUSTOM_ARTIFACTS/vmlinux" \
        CH_X86_VIRTIOFSD_FILE="$CUSTOM_ARTIFACTS/virtiofsd" \
        "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle
)
CUSTOM_BUNDLE=$(find "$CUSTOM_BUNDLE_OUTPUT" -name 'cloud-hypervisor-offline-*-x86_64.tgz' -print -quit)
test -n "$CUSTOM_BUNDLE"
test "$(tar -xOf "$CUSTOM_BUNDLE" ./workloads/hypervisor-fw)" = 'custom-hypervisor-fw'
test "$(tar -xOf "$CUSTOM_BUNDLE" ./workloads/vmlinux)" = 'custom-vmlinux'
tar -xOf "$CUSTOM_BUNDLE" ./MANIFEST | grep -q '^custom_x86_artifacts=hypervisor-fw,CLOUDHV.fd,bionic-server-cloudimg-amd64.qcow2,focal-server-cloudimg-amd64-custom-20210609-0.qcow2,jammy-server-cloudimg-amd64-custom-20220329-0.qcow2,alpine-minirootfs-x86_64.tar.gz,vmlinux,virtiofsd$'
test ! -f "$TMP_DIR/home/workloads/bionic-server-cloudimg-amd64.raw"
test ! -f "$TMP_DIR/home/workloads/focal-server-cloudimg-amd64-custom-20210609-0.raw"
test ! -f "$TMP_DIR/home/workloads/jammy-server-cloudimg-amd64-custom-20220329-0.raw"
test ! -f "$TMP_DIR/home/workloads/alpine_initramfs.img"

if CUBESANDBOX_DIR="$BUNDLE_SOURCE" HOME="$TMP_DIR/home" \
    CH_X86_VMLINUX_FILE=relative DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle >"$TMP_DIR/artifact-path.out" 2>&1; then
    echo "relative custom artifact unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'CH_X86_VMLINUX_FILE must be an absolute path' "$TMP_DIR/artifact-path.out"

: > "$DOCKER_LOG"
CUSTOM_WORKLOADS="$TMP_DIR/custom-workloads"
HOME="$TMP_DIR/home" CH_WORKLOADS_DIR="$CUSTOM_WORKLOADS" \
    CUBESANDBOX_DIR="$SCRIPT_DIR/../.." DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline
grep -q -- "--volume $CUSTOM_WORKLOADS:/root/workloads" "$DOCKER_LOG"
grep -q -- "--volume $(realpath "$SCRIPT_DIR/../../hypervisor"):/cloud-hypervisor" "$DOCKER_LOG"

if HOME="$TMP_DIR/home" CH_WORKLOADS_DIR=relative DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline >"$TMP_DIR/path.out" 2>&1; then
    echo "relative workload directory unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'CH_WORKLOADS_DIR must be an absolute path' "$TMP_DIR/path.out"

: > "$DOCKER_LOG"
(
    cd "$TMP_DIR"
    MOCK_ARCH=aarch64 CUBESANDBOX_DIR="$BUNDLE_SOURCE" \
        HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
        "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle
)
ARM_BUNDLE=$(find "$TMP_DIR" -maxdepth 1 -name 'cloud-hypervisor-offline-*-aarch64.tgz' -print -quit)
test -n "$ARM_BUNDLE"
grep -q 'run_integration_tests_aarch64.sh --hypervisor kvm --prepare-offline' "$DOCKER_LOG"
grep -q -- '--env CH_CARGO_TARGET_DIR=/cloud-hypervisor/build/cargo_target' "$DOCKER_LOG"
if grep -q 'run_integration_tests_live_migration.sh .*--prepare-offline' "$DOCKER_LOG"; then
    echo "aarch64 bundle invoked the x86 live migration preparation script" >&2
    exit 1
fi
tar -xOf "$ARM_BUNDLE" ./MANIFEST | grep -q '^architecture=aarch64$'
tar -tzf "$ARM_BUNDLE" > "$TMP_DIR/arm-bundle.list"
grep -q '^./CubeSandbox/hypervisor/build/cargo_target/aarch64-unknown-linux-gnu/release/cube-hypervisor$' "$TMP_DIR/arm-bundle.list"
if grep -q '^./CubeSandbox/hypervisor/build/cargo_target/x86_64-unknown-linux-' "$TMP_DIR/arm-bundle.list"; then
    echo "aarch64 bundle unexpectedly contains x86_64 target artifacts" >&2
    exit 1
fi

ARM_CUSTOM_OUTPUT="$TMP_DIR/arm-custom-output"
mkdir -p "$ARM_CUSTOM_OUTPUT"
for artifact in bionic-arm64.qcow2 focal-arm64.qcow2 jammy-arm64.qcow2 alpine-arm64.tar.gz cloud-hypervisor-static-aarch64; do
    printf 'custom-%s' "$artifact" > "$CUSTOM_ARTIFACTS/$artifact"
done
printf stale > "$TMP_DIR/home/workloads/bionic-server-cloudimg-arm64.raw"
printf stale > "$TMP_DIR/home/workloads/focal-server-cloudimg-arm64-custom-20210929-0-update-kernel.raw"
printf stale > "$TMP_DIR/home/workloads/alpine_initramfs.img"
(
    cd "$ARM_CUSTOM_OUTPUT"
    MOCK_ARCH=aarch64 CUBESANDBOX_DIR="$BUNDLE_SOURCE" \
        HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
        CH_BIONIC_ARM64_QCOW2_FILE="$CUSTOM_ARTIFACTS/bionic-arm64.qcow2" \
        CH_FOCAL_ARM64_QCOW2_FILE="$CUSTOM_ARTIFACTS/focal-arm64.qcow2" \
        CH_JAMMY_ARM64_QCOW2_FILE="$CUSTOM_ARTIFACTS/jammy-arm64.qcow2" \
        CH_ALPINE_ARM64_MINIROOTFS_FILE="$CUSTOM_ARTIFACTS/alpine-arm64.tar.gz" \
        CH_CLOUD_HYPERVISOR_STATIC_ARM64_FILE="$CUSTOM_ARTIFACTS/cloud-hypervisor-static-aarch64" \
        "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle
)
ARM_CUSTOM_BUNDLE=$(find "$ARM_CUSTOM_OUTPUT" -name 'cloud-hypervisor-offline-*-aarch64.tgz' -print -quit)
test -n "$ARM_CUSTOM_BUNDLE"
test "$(tar -xOf "$ARM_CUSTOM_BUNDLE" ./workloads/bionic-server-cloudimg-arm64.qcow2)" = 'custom-bionic-arm64.qcow2'
test "$(tar -xOf "$ARM_CUSTOM_BUNDLE" ./workloads/focal-server-cloudimg-arm64-custom-20210929-0.qcow2)" = 'custom-focal-arm64.qcow2'
test "$(tar -xOf "$ARM_CUSTOM_BUNDLE" ./workloads/jammy-server-cloudimg-arm64-custom-20220329-0.qcow2)" = 'custom-jammy-arm64.qcow2'
test "$(tar -xOf "$ARM_CUSTOM_BUNDLE" ./workloads/alpine-minirootfs-aarch64.tar.gz)" = 'custom-alpine-arm64.tar.gz'
test "$(tar -xOf "$ARM_CUSTOM_BUNDLE" ./workloads/cloud-hypervisor-static-aarch64)" = 'custom-cloud-hypervisor-static-aarch64'
tar -xOf "$ARM_CUSTOM_BUNDLE" ./MANIFEST | grep -q '^custom_aarch64_artifacts=bionic-server-cloudimg-arm64.qcow2,focal-server-cloudimg-arm64-custom-20210929-0.qcow2,jammy-server-cloudimg-arm64-custom-20220329-0.qcow2,alpine-minirootfs-aarch64.tar.gz,cloud-hypervisor-static-aarch64$'
tar -tzf "$ARM_CUSTOM_BUNDLE" > "$TMP_DIR/arm-custom-bundle.list"
if grep -Eq '^\./workloads/(.*/)?[^/]*-server-cloudimg-.*\.(img|raw)$|^\./workloads/(alpine_initramfs\.img|alpine-minirootfs/)' "$TMP_DIR/arm-custom-bundle.list"; then
    echo "ARM bundle unexpectedly contains derived workloads" >&2
    exit 1
fi

if MOCK_ARCH=aarch64 CUBESANDBOX_DIR="$BUNDLE_SOURCE" HOME="$TMP_DIR/home" \
    CH_BIONIC_ARM64_QCOW2_FILE=relative DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle >"$TMP_DIR/arm-artifact-path.out" 2>&1; then
    echo "relative ARM custom artifact unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'CH_BIONIC_ARM64_QCOW2_FILE must be an absolute path' "$TMP_DIR/arm-artifact-path.out"

if "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle unexpected >"$TMP_DIR/bundle-args.out" 2>&1; then
    echo "bundle command unexpectedly accepted arguments" >&2
    exit 1
fi
grep -q 'does not accept additional arguments' "$TMP_DIR/bundle-args.out"

echo "offline configuration tests passed"
