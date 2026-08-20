#!/bin/bash
set -x

source $HOME/.cargo/env
source $(dirname "$0")/test-util.sh

export BUILD_TARGET=${BUILD_TARGET-x86_64-unknown-linux-gnu}

# Clean up leftover temp dirs from previous test runs
rm -rf /tmp/ch[A-Za-z]*

WORKLOADS_DIR="$HOME/workloads"
mkdir -p "$WORKLOADS_DIR"

process_common_args "$@"

# Print machine specs and disk usage
echo "=== Machine Specs ==="
echo "Hostname: $(hostname)"
echo "CPU Model: $(grep -m1 'model name' /proc/cpuinfo | awk -F: '{print $2}' | xargs)"
echo "CPU Cores: $(nproc)"
echo "Total Memory: $(free -h | awk '/^Mem:/{print $2}')"
echo "Kernel: $(uname -r)"
echo "Architecture: $(uname -m)"
echo ""
echo "=== Disk Usage ==="
df -h / /tmp $HOME 2>/dev/null | sort -u
echo ""

# For now these values are default for kvm
features=""

if [ "$hypervisor" = "mshv" ] ;  then
    features="--no-default-features --features mshv"
fi

cp scripts/sha1sums-x86_64 $WORKLOADS_DIR

require_offline_workloads \
    hypervisor-fw \
    CLOUDHV.fd \
    bionic-server-cloudimg-amd64.qcow2 \
    focal-server-cloudimg-amd64-custom-20210609-0.qcow2 \
    jammy-server-cloudimg-amd64-custom-20220329-0.qcow2 \
    alpine-minirootfs-x86_64.tar.gz \
    vmlinux \
    virtiofsd || exit 1

FW="$WORKLOADS_DIR/hypervisor-fw"
if [ ! -f "$FW" ] && [ -z "${WORKLOADS_BASE_URL:-}" ]; then
    FW_URL=$(curl --fail --silent https://api.github.com/repos/cloud-hypervisor/rust-hypervisor-firmware/releases/latest | grep "browser_download_url" | grep -o 'https://.*[^ "]' | grep '/hypervisor-fw$')
fi
acquire_workload "hypervisor-fw" "${FW_URL:-}" || exit 1

OVMF_FW="$WORKLOADS_DIR/CLOUDHV.fd"
if [ ! -f "$OVMF_FW" ] && [ -z "${WORKLOADS_BASE_URL:-}" ]; then
    OVMF_FW_URL=$(curl --fail --silent https://api.github.com/repos/cloud-hypervisor/edk2/releases/latest | grep "browser_download_url" | grep -o 'https://.*[^ "]' | grep '/CLOUDHV.fd$')
fi
acquire_workload "CLOUDHV.fd" "${OVMF_FW_URL:-}" || exit 1

BIONIC_OS_IMAGE_NAME="bionic-server-cloudimg-amd64.qcow2"
BIONIC_OS_IMAGE_URL="https://github.com/lisongqian/CubeSandbox/releases/download/ci/$BIONIC_OS_IMAGE_NAME.zip"
BIONIC_OS_IMAGE="$WORKLOADS_DIR/$BIONIC_OS_IMAGE_NAME"
acquire_workload "$BIONIC_OS_IMAGE_NAME" "$BIONIC_OS_IMAGE_URL" || exit 1

BIONIC_OS_RAW_IMAGE_NAME="bionic-server-cloudimg-amd64.raw"
BIONIC_OS_RAW_IMAGE="$WORKLOADS_DIR/$BIONIC_OS_RAW_IMAGE_NAME"
if [ ! -f "$BIONIC_OS_RAW_IMAGE" ]; then
    pushd $WORKLOADS_DIR
    time qemu-img convert -p -f qcow2 -O raw $BIONIC_OS_IMAGE_NAME $BIONIC_OS_RAW_IMAGE_NAME || exit 1
    popd
fi


FOCAL_OS_IMAGE_NAME="focal-server-cloudimg-amd64-custom-20210609-0.qcow2"
FOCAL_OS_IMAGE_URL="https://github.com/lisongqian/CubeSandbox/releases/download/ci/$FOCAL_OS_IMAGE_NAME.zip"
FOCAL_OS_IMAGE="$WORKLOADS_DIR/$FOCAL_OS_IMAGE_NAME"
acquire_workload "$FOCAL_OS_IMAGE_NAME" "$FOCAL_OS_IMAGE_URL" || exit 1

FOCAL_OS_RAW_IMAGE_NAME="focal-server-cloudimg-amd64-custom-20210609-0.raw"
FOCAL_OS_RAW_IMAGE="$WORKLOADS_DIR/$FOCAL_OS_RAW_IMAGE_NAME"
if [ ! -f "$FOCAL_OS_RAW_IMAGE" ]; then
    pushd $WORKLOADS_DIR
    time qemu-img convert -p -f qcow2 -O raw $FOCAL_OS_IMAGE_NAME $FOCAL_OS_RAW_IMAGE_NAME || exit 1
    popd
fi

JAMMY_OS_IMAGE_NAME="jammy-server-cloudimg-amd64-custom-20220329-0.qcow2"
JAMMY_OS_IMAGE_URL="https://github.com/lisongqian/CubeSandbox/releases/download/ci/$JAMMY_OS_IMAGE_NAME.zip"
JAMMY_OS_IMAGE="$WORKLOADS_DIR/$JAMMY_OS_IMAGE_NAME"
acquire_workload "$JAMMY_OS_IMAGE_NAME" "$JAMMY_OS_IMAGE_URL" || exit 1

JAMMY_OS_RAW_IMAGE_NAME="jammy-server-cloudimg-amd64-custom-20220329-0.raw"
JAMMY_OS_RAW_IMAGE="$WORKLOADS_DIR/$JAMMY_OS_RAW_IMAGE_NAME"
if [ ! -f "$JAMMY_OS_RAW_IMAGE" ]; then
    pushd $WORKLOADS_DIR
    time qemu-img convert -p -f qcow2 -O raw $JAMMY_OS_IMAGE_NAME $JAMMY_OS_RAW_IMAGE_NAME || exit 1
    popd
fi

ALPINE_MINIROOTFS_URL="http://dl-cdn.alpinelinux.org/alpine/v3.11/releases/x86_64/alpine-minirootfs-3.11.3-x86_64.tar.gz"
ALPINE_MINIROOTFS_TARBALL="$WORKLOADS_DIR/alpine-minirootfs-x86_64.tar.gz"
acquire_workload "alpine-minirootfs-x86_64.tar.gz" "$ALPINE_MINIROOTFS_URL" || exit 1
load_custom_x86_artifacts || exit 1
case ",$CUSTOM_X86_ARTIFACTS," in
*,alpine-minirootfs-x86_64.tar.gz,*) ;;
*)
    (
        cd "$WORKLOADS_DIR" || exit 1
        grep ' alpine-minirootfs-x86_64.tar.gz$' "$OLDPWD/scripts/sha1sums-x86_64" | sha1sum --check
    ) || {
        echo "sha1sum validation of Alpine minirootfs failed, remove the invalid image to fix the issue."
        exit 1
    }
    ;;
esac

ALPINE_INITRAMFS_IMAGE="$WORKLOADS_DIR/alpine_initramfs.img"
if [ ! -f "$ALPINE_INITRAMFS_IMAGE" ]; then
    pushd "$WORKLOADS_DIR" || exit 1
    rm -rf alpine-minirootfs
    mkdir alpine-minirootfs || exit 1
    tar --no-same-owner --no-same-permissions -xf "$ALPINE_MINIROOTFS_TARBALL" -C alpine-minirootfs || exit 1
    rm -f alpine-minirootfs/init || exit 1
    cat > alpine-minirootfs/init <<-EOF
		#! /bin/sh
		mount -t devtmpfs dev /dev
		echo \$TEST_STRING > /dev/console
		poweroff -f
	EOF
    chmod +x alpine-minirootfs/init
    cd alpine-minirootfs
    find . -print0 |
        cpio --null --create --verbose --owner root:root --format=newc > "$ALPINE_INITRAMFS_IMAGE"
    popd
fi

CUSTOM_SHA1_EXCLUDES="$CUSTOM_X86_ARTIFACTS"
case ",$CUSTOM_SHA1_EXCLUDES," in
*,bionic-server-cloudimg-amd64.qcow2,*)
    CUSTOM_SHA1_EXCLUDES="$CUSTOM_SHA1_EXCLUDES,bionic-server-cloudimg-amd64.raw"
    ;;
esac
case ",$CUSTOM_SHA1_EXCLUDES," in
*,focal-server-cloudimg-amd64-custom-20210609-0.qcow2,*)
    CUSTOM_SHA1_EXCLUDES="$CUSTOM_SHA1_EXCLUDES,focal-server-cloudimg-amd64-custom-20210609-0.raw"
    ;;
esac
case ",$CUSTOM_SHA1_EXCLUDES," in
*,jammy-server-cloudimg-amd64-custom-20220329-0.qcow2,*)
    CUSTOM_SHA1_EXCLUDES="$CUSTOM_SHA1_EXCLUDES,jammy-server-cloudimg-amd64-custom-20220329-0.raw"
    ;;
esac

SHA1SUMS_FILTERED=$(mktemp)
while read -r checksum filename; do
    case ",$CUSTOM_SHA1_EXCLUDES," in
    *,"$filename",*) ;;
    *) printf '%s  %s\n' "$checksum" "$filename" >> "$SHA1SUMS_FILTERED" ;;
    esac
done < scripts/sha1sums-x86_64
RES=0
if [ -s "$SHA1SUMS_FILTERED" ]; then
    (
        cd "$WORKLOADS_DIR" || exit 1
        sha1sum --check "$SHA1SUMS_FILTERED"
    )
    RES=$?
fi
rm -f "$SHA1SUMS_FILTERED"
if [ $RES -ne 0 ]; then
    echo "sha1sum validation of images failed, remove invalid images to fix the issue."
    exit 1
fi

# Build custom kernel based on virtio-pmem and virtio-fs upstream patches
VMLINUX_IMAGE="$WORKLOADS_DIR/vmlinux"
acquire_workload "vmlinux" "https://github.com/lisongqian/CubeSandbox/releases/download/vmlinux/vmlinux" || exit 1

VIRTIOFSD="$WORKLOADS_DIR/virtiofsd"
if [ -n "${WORKLOADS_BASE_URL:-}" ] || [ "${CH_OFFLINE:-false}" = "true" ]; then
    acquire_workload "virtiofsd" "" || exit 1
elif [ ! -f "$VIRTIOFSD" ]; then
    VIRTIOFSD_DIR="virtiofsd_build"
    pushd $WORKLOADS_DIR
    git clone "https://gitlab.com/virtio-fs/virtiofsd.git" $VIRTIOFSD_DIR
    pushd $VIRTIOFSD_DIR
    git checkout v1.1.0
    time cargo build --release
    cp target/release/virtiofsd $VIRTIOFSD || exit 1
    popd
    rm -rf $VIRTIOFSD_DIR
    popd
fi
chmod +x "$FW" "$VIRTIOFSD"


BLK_IMAGE="$WORKLOADS_DIR/blk.img"
MNT_DIR="mount_image"
if [ ! -f "$BLK_IMAGE" ]; then
   pushd $WORKLOADS_DIR
   fallocate -l 16M $BLK_IMAGE
   mkfs.ext4 -j $BLK_IMAGE
   mkdir $MNT_DIR
   sudo mount -t ext4 $BLK_IMAGE $MNT_DIR
   sudo bash -c "echo bar > $MNT_DIR/foo" || exit 1
   sudo umount $BLK_IMAGE
   rm -r $MNT_DIR
   popd
fi

SHARED_DIR="$WORKLOADS_DIR/shared_dir"
if [ ! -d "$SHARED_DIR" ]; then
    mkdir -p $SHARED_DIR
    echo "foo" > "$SHARED_DIR/file1"
    echo "bar" > "$SHARED_DIR/file3" || exit 1
fi

VFIO_DIR="$WORKLOADS_DIR/vfio"
VFIO_DISK_IMAGE="$WORKLOADS_DIR/vfio.img"
rm -rf $VFIO_DIR $VFIO_DISK_IMAGE
mkdir -p $VFIO_DIR
cp $FOCAL_OS_RAW_IMAGE $VFIO_DIR
cp $FW $VFIO_DIR
cp $VMLINUX_IMAGE $VFIO_DIR || exit 1

BUILD_TARGET="$(uname -m)-unknown-linux-${CH_LIBC}"

cargo build --all  --release $features --target $BUILD_TARGET
strip target/$BUILD_TARGET/release/cube-hypervisor
strip target/$BUILD_TARGET/release/vhost_user_net
strip target/$BUILD_TARGET/release/ch-remote

# We always copy a fresh version of our binary for our L2 guest.
cp target/$BUILD_TARGET/release/cube-hypervisor $VFIO_DIR
cp target/$BUILD_TARGET/release/ch-remote $VFIO_DIR

if [ "$prepare_offline" = "true" ]; then
    cargo test $features --no-run --target $BUILD_TARGET
    cargo test $features --features lib_support --no-run --target $BUILD_TARGET
    exit 0
fi

# Enable KSM with some reasonable parameters so that it won't take too long
# for the memory to be merged between two processes.
sudo bash -c "echo 1000000 > /sys/kernel/mm/ksm/pages_to_scan"
sudo bash -c "echo 10 > /sys/kernel/mm/ksm/sleep_millisecs"
sudo bash -c "echo 1 > /sys/kernel/mm/ksm/run"

# Both test_vfio, ovs-dpdk and vDPA tests rely on hugepages
echo 6144 | sudo tee /proc/sys/vm/nr_hugepages
sudo chmod a+rwX /dev/hugepages

# Update max locked memory to 'unlimited' to avoid issues with vDPA
ulimit -l unlimited

export RUST_BACKTRACE=1

# Quick mode: run only core smoke tests across 5 priority levels
if [ "$quick_mode" = "true" ]; then
    parallel_threads="${test_threads:-1}"
    echo "=== Quick mode: running core smoke tests with $parallel_threads parallel threads ==="

    # Priority 1: Boot & Lifecycle
    PRIORITY1_TESTS="test_focal_hypervisor_fw|test_direct_kernel_boot|test_multi_cpu|test_power_button|test_api_create_boot|test_api_shutdown|test_api_pause_resume"

    # Priority 2: Core I/O Devices
    PRIORITY2_TESTS="test_virtio_block|test_virtio_net_ctrl_queue|test_native_virtio_fs_hotplug|test_virtio_vsock|test_virtio_console|test_serial_tty"

    # Priority 3: Hotplug
    PRIORITY3_TESTS="test_cpu_hotplug|test_memory_hotplug|test_disk_hotplug|test_net_hotplug"

    # Priority 4: Snapshot & Live Migration
    PRIORITY4_TESTS="test_snapshot_restore_basic|test_live_migration_basic"

    # Priority 5: VMM Instance API (lib mode)
    PRIORITY5_TESTS="test_api_create_boot_and_shutdown|test_api_snapshot_restore"

    # Step 1: Priority 1 - Boot & Lifecycle (parallel)
    echo ""
    echo ">>> [Step 1/5] Priority 1: Boot & Lifecycle"
    build_test_filters "common_parallel" "$PRIORITY1_TESTS"
    time cargo test $features -- --exact --test-threads="$parallel_threads" ${test_binary_args[*]} ${test_filters[*]}
    RES=$?

    # Step 2: Priority 2 - Core I/O Devices (parallel)
    if [ $RES -eq 0 ]; then
        echo ""
        echo ">>> [Step 2/5] Priority 2: Core I/O Devices"
        build_test_filters "common_parallel" "$PRIORITY2_TESTS"
        time cargo test $features -- --exact --test-threads="$parallel_threads" ${test_binary_args[*]} ${test_filters[*]}
        RES=$?
    fi

    # Step 3: Priority 3 - Hotplug (parallel)
    if [ $RES -eq 0 ]; then
        echo ""
        echo ">>> [Step 3/5] Priority 3: Hotplug"
        build_test_filters "common_parallel" "$PRIORITY3_TESTS"
        time cargo test $features -- --exact --test-threads="$parallel_threads" ${test_binary_args[*]} ${test_filters[*]}
        RES=$?
    fi

    # Step 4: Priority 4 - Snapshot & Live Migration (parallel + sequential)
    if [ $RES -eq 0 ]; then
        echo ""
        echo ">>> [Step 4/5] Priority 4: Snapshot & Live Migration"
        time cargo test $features -- --exact --test-threads=1 ${test_binary_args[*]} "common_sequential::test_snapshot_restore_basic"
        RES=$?
    fi
    if [ $RES -eq 0 ]; then
        time cargo test $features -- --exact --test-threads=1 ${test_binary_args[*]} "live_migration::test_live_migration_basic"
        RES=$?
    fi

    # Step 5: Priority 5 - VMM Instance API (lib mode, sequential)
    if [ $RES -eq 0 ]; then
        echo ""
        echo ">>> [Step 5/5] Priority 5: VMM Instance API (lib mode)"
        build_test_filters "vmm_instance" "$PRIORITY5_TESTS"
        time cargo test $features --features lib_support -- --test-threads=1 ${test_binary_args[*]} ${test_filters[*]}
        RES=$?
    fi

    if [ $RES -eq 0 ]; then
        echo ""
        echo "=== Quick mode: all core smoke tests PASSED ==="
    else
        echo ""
        echo "=== Quick mode: some tests FAILED ==="
    fi

    exit $RES
fi

# Full mode: run all tests
parallel_threads="${test_threads:-$(($(nproc)/2))}"
echo "=== Full mode: running all tests with $parallel_threads parallel threads ==="

build_test_filters "common_parallel" "$test_filter"
time cargo test $features -- --test-threads="$parallel_threads" ${test_binary_args[*]} ${test_filters[*]}
RES=$?

if [ $RES -eq 0 ]; then
    build_test_filters "vmm_instance" "$test_filter"
    time cargo test $features --features lib_support -- --test-threads=1 ${test_binary_args[*]} ${test_filters[*]}
    RES=$?
fi

# Run some tests in sequence since the result could be affected by other tests
# running in parallel.
if [ $RES -eq 0 ]; then
    build_test_filters "common_sequential" "$test_filter"
    time cargo test $features -- --test-threads=1 ${test_binary_args[*]} ${test_filters[*]}
    RES=$?
fi

if [ $RES -eq 0 ]; then
    build_test_filters "compatibility" "$test_filter"
    time cargo test $features -- --test-threads=1 ${test_binary_args[*]} ${test_filters[*]}
    RES=$?
fi

exit $RES
