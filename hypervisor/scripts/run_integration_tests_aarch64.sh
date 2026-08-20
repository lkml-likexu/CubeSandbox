#!/bin/bash
set -x

source "$HOME/.cargo/env"
source "$(dirname "$0")/test-util.sh"
source "$(dirname "$0")/common-aarch64.sh"

WORKLOADS_LOCK="$WORKLOADS_DIR/integration_test.lock"
SPDK_DEPLOY_DIR="$WORKLOADS_DIR/spdk-nvme"
SPDK_INSTALL_DIR="${SPDK_INSTALL_DIR:-/usr/local/bin/spdk-nvme}"

install_spdk_nvme() {
    mkdir -p "$SPDK_INSTALL_DIR"
    cp "$SPDK_DEPLOY_DIR/nvmf_tgt" "$SPDK_INSTALL_DIR/nvmf_tgt"
    cp "$SPDK_DEPLOY_DIR/rpc.py" "$SPDK_INSTALL_DIR/rpc.py"
    rm -rf "$SPDK_INSTALL_DIR/rpc"
    cp -r "$SPDK_DEPLOY_DIR/rpc" "$SPDK_INSTALL_DIR/rpc"
}

build_spdk_nvme() {
    if [ -f "$SPDK_DEPLOY_DIR/nvmf_tgt" ] &&
        [ -f "$SPDK_DEPLOY_DIR/rpc.py" ] &&
        [ -d "$SPDK_DEPLOY_DIR/rpc" ]; then
        return
    fi

    local spdk_dir="$WORKLOADS_DIR/spdk"
    checkout_repo \
        "$spdk_dir" \
        "https://github.com/spdk/spdk.git" \
        master \
        "6301f8915de32baed10dba1eebed556a6749211a"

    if [ ! -f "$spdk_dir/.built" ] ||
        [ ! -f "$spdk_dir/build/bin/nvmf_tgt" ] ||
        [ ! -f "$spdk_dir/scripts/rpc.py" ] ||
        [ ! -d "$spdk_dir/scripts/rpc" ]; then
        pushd "$spdk_dir" || return 1
        git submodule update --init
        apt-get update
        ./scripts/pkgdep.sh
        ./configure --with-vfio-user
        chmod +x /usr/local/lib/python3.8/dist-packages/ninja/data/bin/ninja
        make -j "$(nproc)" || exit 1
        touch .built
        popd || return 1
    fi

    mkdir -p "$SPDK_DEPLOY_DIR"
    rm -rf "$SPDK_DEPLOY_DIR/rpc"
    cp "$spdk_dir/build/bin/nvmf_tgt" "$SPDK_DEPLOY_DIR/nvmf_tgt"
    cp "$spdk_dir/scripts/rpc.py" "$SPDK_DEPLOY_DIR/rpc.py"
    cp -r "$spdk_dir/scripts/rpc" "$SPDK_DEPLOY_DIR/rpc"
}

build_virtiofsd() {
    [ -f "$WORKLOADS_DIR/virtiofsd" ] && return

    local virtiofsd_dir="$WORKLOADS_DIR/virtiofsd_build"
    checkout_repo \
        "$virtiofsd_dir" \
        "https://gitlab.com/virtio-fs/virtiofsd.git" \
        v1.1.0 \
        "220405d7a2606c92636d31992b5cb3036a41047b"

    pushd "$virtiofsd_dir" || return 1
    time cargo build --release
    cp target/release/virtiofsd "$WORKLOADS_DIR/" || return 1
    popd || return 1
}

validate_aarch64_images() {
    local custom_excludes="$CUSTOM_AARCH64_ARTIFACTS"
    local checksums_filtered
    checksums_filtered=$(mktemp) || return 1
    while read -r checksum filename; do
        [ -z "$filename" ] && continue
        case "$filename" in
        *.img | *.raw) continue ;;
        esac
        case ",$custom_excludes," in
        *,"$filename",*) ;;
        *) printf '%s  %s\n' "$checksum" "$filename" >> "$checksums_filtered" ;;
        esac
    done < "$WORKLOADS_DIR/sha1sums-aarch64"

    local result=0
    if [ -s "$checksums_filtered" ]; then
        (
            cd "$WORKLOADS_DIR" || exit 1
            sha1sum --check "$checksums_filtered"
        ) || result=$?
    fi
    rm -f "$checksums_filtered"
    if [ $result -ne 0 ]; then
        echo "sha1sum validation of images failed, remove invalid images to fix the issue."
        return 1
    fi
}

require_aarch64_offline_workloads() {
    require_offline_workloads \
        bionic-server-cloudimg-arm64.qcow2 \
        focal-server-cloudimg-arm64-custom-20210929-0.qcow2 \
        jammy-server-cloudimg-arm64-custom-20220329-0.qcow2 \
        alpine-minirootfs-aarch64.tar.gz \
        cloud-hypervisor-static-aarch64 \
        Image \
        Image.gz \
        CLOUDHV_EFI.fd \
        virtiofsd \
        blk.img \
        shared_dir/file1 \
        shared_dir/file3 \
        spdk-nvme/nvmf_tgt \
        spdk-nvme/rpc.py || return 1

    [ -d "$SPDK_DEPLOY_DIR/rpc" ] || {
        echo "Offline workload is missing: $SPDK_DEPLOY_DIR/rpc" >&2
        return 1
    }
}

update_workloads() {
    cp scripts/sha1sums-aarch64 "$WORKLOADS_DIR"
    load_custom_aarch64_artifacts || return 1

    if [ "${CH_OFFLINE:-false}" = "true" ]; then
        require_aarch64_offline_workloads || return 1
        validate_aarch64_images || return 1
        chmod +x \
            "$WORKLOADS_DIR/cloud-hypervisor-static-aarch64" \
            "$WORKLOADS_DIR/virtiofsd" \
            "$SPDK_DEPLOY_DIR/nvmf_tgt" \
            "$SPDK_DEPLOY_DIR/rpc.py"
        install_spdk_nvme
    fi

    local bionic_download_name="bionic-server-cloudimg-arm64.img"
    local bionic_raw_name="bionic-server-cloudimg-arm64.raw"
    local bionic_qcow2_name="bionic-server-cloudimg-arm64.qcow2"
    local focal_raw_name="focal-server-cloudimg-arm64-custom-20210929-0.raw"
    local focal_qcow2_name="focal-server-cloudimg-arm64-custom-20210929-0.qcow2"
    local jammy_raw_name="jammy-server-cloudimg-arm64-custom-20220329-0.raw"
    local jammy_qcow2_name="jammy-server-cloudimg-arm64-custom-20220329-0.qcow2"
    local alpine_name="alpine-minirootfs-aarch64.tar.gz"

    if [ "${CH_OFFLINE:-false}" != "true" ]; then
        if [ ! -f "$WORKLOADS_DIR/$bionic_qcow2_name" ]; then
            if [ -n "${WORKLOADS_BASE_URL:-}" ]; then
                acquire_workload "$bionic_qcow2_name" "" || return 1
            else
                acquire_workload \
                    "$bionic_download_name" \
                    "https://cloud-hypervisor.azureedge.net/$bionic_download_name" || return 1
                time qemu-img convert -p -f qcow2 -O raw \
                    "$WORKLOADS_DIR/$bionic_download_name" \
                    "$WORKLOADS_DIR/$bionic_raw_name" || return 1
                time qemu-img convert -p -f raw -O qcow2 \
                    "$WORKLOADS_DIR/$bionic_raw_name" \
                    "$WORKLOADS_DIR/$bionic_qcow2_name" || return 1
            fi
        fi
        acquire_workload \
            "$focal_qcow2_name" \
            "https://cloud-hypervisor.azureedge.net/$focal_qcow2_name" || return 1
        acquire_workload \
            "$jammy_qcow2_name" \
            "https://cloud-hypervisor.azureedge.net/$jammy_qcow2_name" || return 1
        acquire_workload \
            "$alpine_name" \
            "http://dl-cdn.alpinelinux.org/alpine/v3.11/releases/aarch64/alpine-minirootfs-3.11.3-aarch64.tar.gz" || return 1
    fi

    case ",$CUSTOM_AARCH64_ARTIFACTS," in
    *,alpine-minirootfs-aarch64.tar.gz,*) ;;
    *)
        (
            cd "$WORKLOADS_DIR" || exit 1
            grep ' alpine-minirootfs-aarch64.tar.gz$' sha1sums-aarch64 | sha1sum --check
        ) || return 1
        ;;
    esac

    local image_pair
    for image_pair in \
        "$bionic_qcow2_name:$bionic_raw_name" \
        "$focal_qcow2_name:$focal_raw_name" \
        "$jammy_qcow2_name:$jammy_raw_name"; do
        local qcow2_name=${image_pair%%:*}
        local raw_name=${image_pair#*:}
        if [ ! -f "$WORKLOADS_DIR/$raw_name" ]; then
            time qemu-img convert -p -f qcow2 -O raw \
                "$WORKLOADS_DIR/$qcow2_name" \
                "$WORKLOADS_DIR/$raw_name" || return 1
        fi
    done

    local alpine_initramfs="$WORKLOADS_DIR/alpine_initramfs.img"
    if [ ! -f "$alpine_initramfs" ]; then
        local alpine_root="$WORKLOADS_DIR/alpine-minirootfs"
        rm -rf "$alpine_root"
        mkdir "$alpine_root"
        tar --no-same-owner --no-same-permissions -xf "$WORKLOADS_DIR/$alpine_name" -C "$alpine_root" || return 1
        rm -f "$alpine_root/init" || return 1
        cat > "$alpine_root/init" <<-EOF
			#! /bin/sh
			mount -t devtmpfs dev /dev
			echo \$TEST_STRING > /dev/console
			poweroff -f
		EOF
        chmod +x "$alpine_root/init"
        (
            cd "$alpine_root" || exit 1
            find . -print0 |
                cpio --null --create --verbose --owner root:root --format=newc > "$alpine_initramfs"
        ) || return 1
    fi

    validate_aarch64_images || return 1

    local release_name="cloud-hypervisor-static-aarch64"
    acquire_workload \
        "$release_name" \
        "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v26.0/$release_name" || return 1
    chmod +x "$WORKLOADS_DIR/$release_name"

    if [ ! -f "$WORKLOADS_DIR/Image" ] || [ ! -f "$WORKLOADS_DIR/Image.gz" ]; then
        build_custom_linux || return 1
    fi

    if [ ! -f "$WORKLOADS_DIR/CLOUDHV_EFI.fd" ]; then
        build_edk2 || return 1
    fi

    local updated_focal="$WORKLOADS_DIR/focal-server-cloudimg-arm64-custom-20210929-0-update-kernel.raw"
    if [ ! -f "$updated_focal" ]; then
        cp "$WORKLOADS_DIR/$focal_raw_name" "$updated_focal"
        local focal_root="$WORKLOADS_DIR/focal-server-cloudimg-root"
        mkdir -p "$focal_root"
        guestmount -a "$updated_focal" -m /dev/sda1 "$focal_root" || return 1
        cp "$WORKLOADS_DIR/Image.gz" "$focal_root/boot/vmlinuz"
        guestunmount "$focal_root" || return 1
    fi

    build_virtiofsd || return 1
    chmod +x "$WORKLOADS_DIR/virtiofsd"

    local blk_image="$WORKLOADS_DIR/blk.img"
    if [ ! -f "$blk_image" ]; then
        local mount_dir="$WORKLOADS_DIR/mount_image"
        fallocate -l 16M "$blk_image"
        mkfs.ext4 -j "$blk_image"
        mkdir "$mount_dir"
        sudo mount -t ext4 "$blk_image" "$mount_dir"
        sudo bash -c "echo bar > $mount_dir/foo" || return 1
        sudo umount "$blk_image"
        rm -r "$mount_dir"
    fi

    local shared_dir="$WORKLOADS_DIR/shared_dir"
    mkdir -p "$shared_dir"
    [ -f "$shared_dir/file1" ] || echo "foo" > "$shared_dir/file1"
    [ -f "$shared_dir/file3" ] || echo "bar" > "$shared_dir/file3" || return 1

    build_spdk_nvme || return 1
    chmod +x "$SPDK_DEPLOY_DIR/nvmf_tgt" "$SPDK_DEPLOY_DIR/rpc.py"
    install_spdk_nvme
}

process_common_args "$@"

if [ "$hypervisor" = "mshv" ]; then
    echo "AArch64 is not supported in Microsoft Hypervisor"
    exit 1
fi

features=""

(
    echo "try to lock $WORKLOADS_DIR folder and update"
    flock -x 12 && update_workloads
) 12>"$WORKLOADS_LOCK"
RES=$?
[ $RES -eq 0 ] || exit $RES

BUILD_TARGET="aarch64-unknown-linux-${CH_LIBC}"
if [ "$BUILD_TARGET" = "aarch64-unknown-linux-musl" ]; then
    export TARGET_CC="musl-gcc"
    export RUSTFLAGS="-C link-arg=-lgcc -C link_arg=-specs -C link_arg=/usr/lib/aarch64-linux-musl/musl-gcc.specs"
fi

export RUST_BACKTRACE=1

cargo build --all --release $features --target "$BUILD_TARGET"
strip "target/$BUILD_TARGET/release/cube-hypervisor"
strip "target/$BUILD_TARGET/release/vhost_user_net"
strip "target/$BUILD_TARGET/release/ch-remote"

if [ "$prepare_offline" = "true" ]; then
    cargo test $features --no-run --target "$BUILD_TARGET"
    exit 0
fi

sudo bash -c "echo 1000000 > /sys/kernel/mm/ksm/pages_to_scan"
sudo bash -c "echo 10 > /sys/kernel/mm/ksm/sleep_millisecs"
sudo bash -c "echo 1 > /sys/kernel/mm/ksm/run"

echo 6144 | sudo tee /proc/sys/vm/nr_hugepages
sudo chmod a+rwX /dev/hugepages

parallel_test_args=()
if [ -n "$test_threads" ]; then
    parallel_test_args=(--test-threads="$test_threads")
    echo "Running parallel test suites with $test_threads threads"
fi

if [ "$live_migration_only" != "true" ]; then
    time cargo test $features "common_parallel::$test_filter" --target "$BUILD_TARGET" -- "${parallel_test_args[@]}" "${test_binary_args[@]}"
    RES=$?

    if [ $RES -eq 0 ]; then
        time cargo test $features "common_sequential::$test_filter" --target "$BUILD_TARGET" -- --test-threads=1 "${test_binary_args[@]}"
        RES=$?
    fi

    if [ $RES -eq 0 ]; then
        time cargo test $features "aarch64_acpi::$test_filter" --target "$BUILD_TARGET" -- "${parallel_test_args[@]}" "${test_binary_args[@]}"
        RES=$?
    fi

    [ $RES -eq 0 ] || exit $RES
fi

time cargo test $features "live_migration_parallel::$test_filter" --target "$BUILD_TARGET" -- "${parallel_test_args[@]}" "${test_binary_args[@]}"
RES=$?

if [ $RES -eq 0 ]; then
    time cargo test $features "live_migration_sequential::$test_filter" --target "$BUILD_TARGET" -- --test-threads=1 "${test_binary_args[@]}"
    RES=$?
fi

exit $RES
