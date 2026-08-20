#!/bin/bash
set -x

source $HOME/.cargo/env
source $(dirname "$0")/test-util.sh

export BUILD_TARGET=${BUILD_TARGET-x86_64-unknown-linux-gnu}

WORKLOADS_DIR="$HOME/workloads"
mkdir -p "$WORKLOADS_DIR"

process_common_args "$@"

# For now these values are default for kvm
features=""

if [ "$hypervisor" = "mshv" ] ;  then
    features="--no-default-features --features mshv"
fi

cp scripts/sha1sums-x86_64 $WORKLOADS_DIR

require_offline_workloads \
    focal-server-cloudimg-amd64-custom-20210609-0.qcow2 \
    vmlinux || exit 1

FOCAL_OS_IMAGE_NAME="focal-server-cloudimg-amd64-custom-20210609-0.qcow2"
FOCAL_OS_IMAGE_URL="https://cloud-hypervisor.azureedge.net/$FOCAL_OS_IMAGE_NAME"
FOCAL_OS_IMAGE="$WORKLOADS_DIR/$FOCAL_OS_IMAGE_NAME"
acquire_workload "$FOCAL_OS_IMAGE_NAME" "$FOCAL_OS_IMAGE_URL" || exit 1

FOCAL_OS_RAW_IMAGE_NAME="focal-server-cloudimg-amd64-custom-20210609-0.raw"
FOCAL_OS_RAW_IMAGE="$WORKLOADS_DIR/$FOCAL_OS_RAW_IMAGE_NAME"
if [ ! -f "$FOCAL_OS_RAW_IMAGE" ]; then
    pushd $WORKLOADS_DIR
    time qemu-img convert -p -f qcow2 -O raw $FOCAL_OS_IMAGE_NAME $FOCAL_OS_RAW_IMAGE_NAME || exit 1
    popd
fi

load_custom_x86_artifacts || exit 1
case ",$CUSTOM_X86_ARTIFACTS," in
*,focal-server-cloudimg-amd64-custom-20210609-0.qcow2,*) ;;
*)
    pushd "$WORKLOADS_DIR" || exit 1
    grep focal sha1sums-x86_64 | sha1sum --check || {
        echo "sha1sum validation of images failed, remove invalid images to fix the issue."
        exit 1
    }
    popd || exit 1
    ;;
esac

VMLINUX_IMAGE="$WORKLOADS_DIR/vmlinux"
acquire_workload "vmlinux" "https://github.com/lisongqian/CubeSandbox/releases/download/vmlinux/vmlinux" || exit 1

BUILD_TARGET="$(uname -m)-unknown-linux-${CH_LIBC}"
CFLAGS=""
TARGET_CC=""
if [[ "${BUILD_TARGET}" == "x86_64-unknown-linux-musl" ]]; then
    TARGET_CC="musl-gcc"
    CFLAGS="-I /usr/include/x86_64-linux-musl/ -idirafter /usr/include/"
fi

cargo build --all --release $features --target $BUILD_TARGET
strip target/$BUILD_TARGET/release/cube-hypervisor
strip target/$BUILD_TARGET/release/vhost_user_net
strip target/$BUILD_TARGET/release/ch-remote

# Use locally-built cube-hypervisor as the "old release" binary for live
# upgrade tests. Upstream cloud-hypervisor-static v26 lacks PVM CPUID
# support and cannot boot the PVM guest kernel. Both source and
# destination use the same binary, so the cross-version upgrade path
# is not exercised on PVM.
CH_RELEASE_NAME="cloud-hypervisor-static"
cp -f target/$BUILD_TARGET/release/cube-hypervisor "$WORKLOADS_DIR"/"$CH_RELEASE_NAME" || exit 1
chmod +x "$WORKLOADS_DIR"/"$CH_RELEASE_NAME"

if [ "$prepare_offline" = "true" ]; then
    cargo test $features --no-run --target $BUILD_TARGET
    exit 0
fi

# Test ovs-dpdk relies on hugepages
echo 6144 | sudo tee /proc/sys/vm/nr_hugepages
sudo chmod a+rwX /dev/hugepages

export RUST_BACKTRACE=1
parallel_test_args=()
if [ -n "$test_threads" ]; then
    parallel_test_args=(--test-threads="$test_threads")
    echo "Running live migration parallel tests with $test_threads threads"
fi
time cargo test $features "live_migration_parallel::$test_filter" -- "${parallel_test_args[@]}" ${test_binary_args[*]}
RES=$?

# Run some tests in sequence since the result could be affected by other tests
# running in parallel.
if [ $RES -eq 0 ]; then
    export RUST_BACKTRACE=1
    time cargo test $features "live_migration_sequential::$test_filter" -- --test-threads=1 ${test_binary_args[*]}
    RES=$?
fi

exit $RES
