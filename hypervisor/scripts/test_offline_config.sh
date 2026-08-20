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

CH_OFFLINE=true
if require_offline_workloads kernel missing >"$TMP_DIR/offline.out" 2>&1; then
    echo "offline preflight unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'Offline workloads missing' "$TMP_DIR/offline.out"
grep -q 'missing' "$TMP_DIR/offline.out"

cat > "$TMP_DIR/bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
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
HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --quick --offline

grep -q '^image inspect ghcr.io/cloud-hypervisor/cloud-hypervisor:20240507-0$' "$DOCKER_LOG"
if grep -q '^pull ' "$DOCKER_LOG"; then
    echo "offline mode attempted to pull a container image" >&2
    exit 1
fi
grep -q -- '--env CH_OFFLINE=true' "$DOCKER_LOG"
grep -q -- '--env CARGO_NET_OFFLINE=true' "$DOCKER_LOG"

: > "$DOCKER_LOG"
CH_TEST_THREADS=3 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --offline
grep -q 'run_integration_tests_x86_64.sh --hypervisor kvm --test-threads 3' "$DOCKER_LOG"

: > "$DOCKER_LOG"
CH_TEST_THREADS=3 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --test-threads 7 --offline
grep -q 'run_integration_tests_x86_64.sh --hypervisor kvm --test-threads 7' "$DOCKER_LOG"

if HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration --test-threads 0 >"$TMP_DIR/threads.out" 2>&1; then
    echo "zero test thread count unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'Test thread count must be a positive integer: 0' "$TMP_DIR/threads.out"

test "$(WORKLOADS_BASE_URL= workload_url kernel https://public.invalid/kernel)" = "https://public.invalid/kernel"
printf '%s\n' unknown-artifact > "$WORKLOADS_DIR/.custom_x86_artifacts"
if load_custom_x86_artifacts >"$TMP_DIR/custom-marker.out" 2>&1; then
    echo "unknown custom artifact marker unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'Unknown custom x86 artifact: unknown-artifact' "$TMP_DIR/custom-marker.out"
rm -f "$WORKLOADS_DIR/.custom_x86_artifacts"

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
if grep -q 'cargo build --all' "$TMP_DIR/arm-offline.out"; then
    echo "aarch64 offline preflight reached the Cargo build" >&2
    exit 1
fi

: > "$DOCKER_LOG"
HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration-live-migration \
    --workloads-base-url 'http://mirror.internal/workloads'
grep -q -- '--env WORKLOADS_BASE_URL=http://mirror.internal/workloads' "$DOCKER_LOG"
grep -q 'run_integration_tests_live_migration.sh' "$DOCKER_LOG"

: > "$DOCKER_LOG"
MOCK_ARCH=aarch64 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" tests --integration-live-migration --offline
grep -q 'run_integration_tests_aarch64.sh --live-migration-only --hypervisor kvm' "$DOCKER_LOG"
grep -q -- '--env CH_OFFLINE=true' "$DOCKER_LOG"
grep -q -- '--env CARGO_NET_OFFLINE=true' "$DOCKER_LOG"

: > "$DOCKER_LOG"
HOME="$TMP_DIR/home" "$SCRIPT_DIR/dev_cli.sh" build-container --apt-mirror 'http://apt.internal'
grep -q -- '--build-arg APT_MIRROR_BASE=http://apt.internal' "$DOCKER_LOG"

if "$SCRIPT_DIR/dev_cli.sh" build-container --apt-mirror 'file:///mirror' >"$TMP_DIR/url.out" 2>&1; then
    echo "invalid APT mirror unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'must be an http(s) URL' "$TMP_DIR/url.out"

: > "$DOCKER_LOG"
mkdir -p "$TMP_DIR/home/workloads"
printf workload > "$TMP_DIR/home/workloads/vmlinux"
cat > "$TMP_DIR/bin/cp" <<'EOF'
#!/bin/bash
[ "$1" = "-a" ] && shift
source="$1"
destination="$2"
if [ "$source" = "$HOME/workloads/." ] || [[ "$source" = "$TEST_TMP_DIR/custom-artifacts/"* ]]; then
    /bin/cp -a "$source" "$destination"
else
    target="$destination/$(basename "$source")"
    mkdir -p "$target"
    printf cache > "$target/placeholder"
fi
EOF
chmod +x "$TMP_DIR/bin/cp"
(
    cd "$TMP_DIR"
    HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
        "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle
)
BUNDLE=$(find "$TMP_DIR" -maxdepth 1 -name 'cloud-hypervisor-offline-*-x86_64.tar.gz' -print -quit)
test -n "$BUNDLE"
grep -q 'run_integration_tests_x86_64.sh --hypervisor kvm --prepare-offline' "$DOCKER_LOG"
grep -q 'run_integration_tests_live_migration.sh --hypervisor kvm --prepare-offline' "$DOCKER_LOG"
grep -q '^save -o .*/docker/cloud-hypervisor-dev-image.tar ghcr.io/cloud-hypervisor/cloud-hypervisor:20240507-0$' "$DOCKER_LOG"
tar -tzf "$BUNDLE" > "$TMP_DIR/bundle.list"
grep -q '^./MANIFEST$' "$TMP_DIR/bundle.list"
grep -q '^./SHA256SUMS$' "$TMP_DIR/bundle.list"
grep -q '^./docker/cloud-hypervisor-dev-image.tar$' "$TMP_DIR/bundle.list"
grep -q '^./workloads/vmlinux$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/hypervisor/scripts/dev_cli.sh$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/hypervisor/build/cargo_registry/placeholder$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/hypervisor/build/cargo_git_registry/placeholder$' "$TMP_DIR/bundle.list"
grep -q '^./CubeSandbox/hypervisor/build/cargo_target/placeholder$' "$TMP_DIR/bundle.list"
if grep -q '^./CubeSandbox/.git/' "$TMP_DIR/bundle.list"; then
    echo "bundle unexpectedly contains Git metadata" >&2
    exit 1
fi
if grep -q '\.dev_cli\.log\.txt$' "$TMP_DIR/bundle.list"; then
    echo "bundle unexpectedly contains a dev CLI log" >&2
    exit 1
fi
tar -xOf "$BUNDLE" ./MANIFEST | grep -q '^source_commit='
tar -xOf "$BUNDLE" ./MANIFEST | grep -q '^source_dirty=true$'
mkdir "$TMP_DIR/extracted"
tar -xzf "$BUNDLE" -C "$TMP_DIR/extracted"
(cd "$TMP_DIR/extracted" && sha256sum --check SHA256SUMS >/dev/null)
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
CUSTOM_BUNDLE=$(find "$CUSTOM_BUNDLE_OUTPUT" -name 'cloud-hypervisor-offline-*-x86_64.tar.gz' -print -quit)
test -n "$CUSTOM_BUNDLE"
test "$(tar -xOf "$CUSTOM_BUNDLE" ./workloads/hypervisor-fw)" = 'custom-hypervisor-fw'
test "$(tar -xOf "$CUSTOM_BUNDLE" ./workloads/vmlinux)" = 'custom-vmlinux'
tar -xOf "$CUSTOM_BUNDLE" ./MANIFEST | grep -q '^custom_x86_artifacts=hypervisor-fw,CLOUDHV.fd,bionic-server-cloudimg-amd64.qcow2,focal-server-cloudimg-amd64-custom-20210609-0.qcow2,jammy-server-cloudimg-amd64-custom-20220329-0.qcow2,alpine-minirootfs-x86_64.tar.gz,vmlinux,virtiofsd$'
test ! -f "$TMP_DIR/home/workloads/bionic-server-cloudimg-amd64.raw"
test ! -f "$TMP_DIR/home/workloads/focal-server-cloudimg-amd64-custom-20210609-0.raw"
test ! -f "$TMP_DIR/home/workloads/jammy-server-cloudimg-amd64-custom-20220329-0.raw"
test ! -f "$TMP_DIR/home/workloads/alpine_initramfs.img"

if HOME="$TMP_DIR/home" CH_X86_VMLINUX_FILE=relative DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
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
    MOCK_ARCH=aarch64 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
        "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle
)
ARM_BUNDLE=$(find "$TMP_DIR" -maxdepth 1 -name 'cloud-hypervisor-offline-*-aarch64.tar.gz' -print -quit)
test -n "$ARM_BUNDLE"
grep -q 'run_integration_tests_aarch64.sh --hypervisor kvm --prepare-offline' "$DOCKER_LOG"
if grep -q 'run_integration_tests_live_migration.sh .*--prepare-offline' "$DOCKER_LOG"; then
    echo "aarch64 bundle invoked the x86 live migration preparation script" >&2
    exit 1
fi
tar -xOf "$ARM_BUNDLE" ./MANIFEST | grep -q '^architecture=aarch64$'

ARM_CUSTOM_OUTPUT="$TMP_DIR/arm-custom-output"
mkdir -p "$ARM_CUSTOM_OUTPUT"
for artifact in bionic-arm64.img focal-arm64.raw focal-arm64.qcow2 jammy-arm64.raw jammy-arm64.qcow2 alpine-arm64.tar.gz cloud-hypervisor-static-aarch64; do
    printf 'custom-%s' "$artifact" > "$CUSTOM_ARTIFACTS/$artifact"
done
printf stale > "$TMP_DIR/home/workloads/bionic-server-cloudimg-arm64.raw"
printf stale > "$TMP_DIR/home/workloads/bionic-server-cloudimg-arm64.qcow2"
printf stale > "$TMP_DIR/home/workloads/focal-server-cloudimg-arm64-custom-20210929-0-update-kernel.raw"
printf stale > "$TMP_DIR/home/workloads/alpine_initramfs.img"
(
    cd "$ARM_CUSTOM_OUTPUT"
    MOCK_ARCH=aarch64 HOME="$TMP_DIR/home" DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
        CH_BIONIC_ARM64_IMG_FILE="$CUSTOM_ARTIFACTS/bionic-arm64.img" \
        CH_FOCAL_ARM64_RAW_FILE="$CUSTOM_ARTIFACTS/focal-arm64.raw" \
        CH_FOCAL_ARM64_QCOW2_FILE="$CUSTOM_ARTIFACTS/focal-arm64.qcow2" \
        CH_JAMMY_ARM64_RAW_FILE="$CUSTOM_ARTIFACTS/jammy-arm64.raw" \
        CH_JAMMY_ARM64_QCOW2_FILE="$CUSTOM_ARTIFACTS/jammy-arm64.qcow2" \
        CH_ALPINE_ARM64_MINIROOTFS_FILE="$CUSTOM_ARTIFACTS/alpine-arm64.tar.gz" \
        CH_CLOUD_HYPERVISOR_STATIC_ARM64_FILE="$CUSTOM_ARTIFACTS/cloud-hypervisor-static-aarch64" \
        "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle
)
ARM_CUSTOM_BUNDLE=$(find "$ARM_CUSTOM_OUTPUT" -name 'cloud-hypervisor-offline-*-aarch64.tar.gz' -print -quit)
test -n "$ARM_CUSTOM_BUNDLE"
test "$(tar -xOf "$ARM_CUSTOM_BUNDLE" ./workloads/bionic-server-cloudimg-arm64.img)" = 'custom-bionic-arm64.img'
test "$(tar -xOf "$ARM_CUSTOM_BUNDLE" ./workloads/cloud-hypervisor-static-aarch64)" = 'custom-cloud-hypervisor-static-aarch64'
tar -xOf "$ARM_CUSTOM_BUNDLE" ./MANIFEST | grep -q '^custom_aarch64_artifacts=bionic-server-cloudimg-arm64.img,focal-server-cloudimg-arm64-custom-20210929-0.raw,focal-server-cloudimg-arm64-custom-20210929-0.qcow2,jammy-server-cloudimg-arm64-custom-20220329-0.raw,jammy-server-cloudimg-arm64-custom-20220329-0.qcow2,alpine-minirootfs-aarch64.tar.gz,cloud-hypervisor-static-aarch64$'
test ! -f "$TMP_DIR/home/workloads/bionic-server-cloudimg-arm64.raw"
test ! -f "$TMP_DIR/home/workloads/bionic-server-cloudimg-arm64.qcow2"
test ! -f "$TMP_DIR/home/workloads/focal-server-cloudimg-arm64-custom-20210929-0-update-kernel.raw"
test ! -f "$TMP_DIR/home/workloads/alpine_initramfs.img"

if MOCK_ARCH=aarch64 HOME="$TMP_DIR/home" CH_BIONIC_ARM64_IMG_FILE=relative DOCKER_RUNTIME="$TMP_DIR/bin/docker" \
    "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle >"$TMP_DIR/arm-artifact-path.out" 2>&1; then
    echo "relative ARM custom artifact unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'CH_BIONIC_ARM64_IMG_FILE must be an absolute path' "$TMP_DIR/arm-artifact-path.out"

if "$SCRIPT_DIR/dev_cli.sh" --prepare-offline-bundle unexpected >"$TMP_DIR/bundle-args.out" 2>&1; then
    echo "bundle command unexpectedly accepted arguments" >&2
    exit 1
fi
grep -q 'does not accept additional arguments' "$TMP_DIR/bundle-args.out"

echo "offline configuration tests passed"
