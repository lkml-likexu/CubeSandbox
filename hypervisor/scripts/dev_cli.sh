#!/bin/bash

# Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# Copyright © 2020 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

CLI_NAME="Cloud Hypervisor"

#CTR_IMAGE_TAG="cloudhypervisor/dev"
#CTR_IMAGE_VERSION="20220705-0"
CTR_IMAGE_TAG="ghcr.io/cloud-hypervisor/cloud-hypervisor"
CTR_IMAGE_VERSION="20240507-0"
CTR_IMAGE="${CTR_IMAGE_TAG}:${CTR_IMAGE_VERSION}"

DOCKER_RUNTIME="docker"

# Host paths
CLH_SCRIPTS_DIR=$(cd "$(dirname "$0")" && pwd)
CUBESANDBOX_DIR="${CUBESANDBOX_DIR:-$(cd "${CLH_SCRIPTS_DIR}/../.." && pwd)}"
CH_WORKLOADS_DIR="${CH_WORKLOADS_DIR:-${HOME}/workloads}"
CLH_ROOT_DIR="${CUBESANDBOX_DIR}/hypervisor"
CLH_BUILD_DIR="${CLH_ROOT_DIR}/build"
CLH_CARGO_TARGET="${CLH_BUILD_DIR}/cargo_target"
CLH_DOCKERFILE="${CLH_ROOT_DIR}/resources/Dockerfile"
CLH_CTR_BUILD_DIR="/tmp/cloud-hypervisor/ctr-build"

# Container paths
CTR_CLH_ROOT_DIR="/cloud-hypervisor"
CTR_CLH_CARGO_BUILT_DIR="${CTR_CLH_ROOT_DIR}/build"
CTR_CLH_CARGO_TARGET="${CTR_CLH_CARGO_BUILT_DIR}/cargo_target"
CTR_CH_WORKLOADS_DIR="/root/workloads"

# Container networking option
CTR_CLH_NET="bridge"

APT_MIRROR_BASE="${APT_MIRROR_BASE:-}"
WORKLOADS_BASE_URL="${WORKLOADS_BASE_URL:-}"
CH_OFFLINE="${CH_OFFLINE:-false}"
CH_TEST_THREADS="${CH_TEST_THREADS:-}"
CH_CUSTOM_X86_ARTIFACTS=""
CH_CUSTOM_AARCH64_ARTIFACTS=""

# Cargo paths
# Full path to the cargo registry dir on the host. This appears on the host
# because we want to persist the cargo registry across container invocations.
# Otherwise, any rust crates from crates.io would be downloaded again each time
# we build or test.
CARGO_REGISTRY_DIR="${CLH_BUILD_DIR}/cargo_registry"

# Full path to the cargo git registry on the host. This serves the same purpose
# as CARGO_REGISTRY_DIR, for crates downloaded from GitHub repos instead of
# crates.io.
CARGO_GIT_REGISTRY_DIR="${CLH_BUILD_DIR}/cargo_git_registry"

# Full path to the cargo target dir on the host.
CARGO_TARGET_DIR="${CLH_BUILD_DIR}/cargo_target"

# Send a decorated message to stdout, followed by a new line
#
say() {
    [ -t 1 ] && [ -n "$TERM" ] &&
        echo "$(tput setaf 2)[$CLI_NAME]$(tput sgr0) $*" ||
        echo "[$CLI_NAME] $*"
}

# Send a decorated message to stdout, without a trailing new line
#
say_noln() {
    [ -t 1 ] && [ -n "$TERM" ] &&
        echo -n "$(tput setaf 2)[$CLI_NAME]$(tput sgr0) $*" ||
        echo "[$CLI_NAME] $*"
}

# Send a text message to stderr
#
say_err() {
    [ -t 2 ] && [ -n "$TERM" ] &&
        echo "$(tput setaf 1)[$CLI_NAME] $*$(tput sgr0)" 1>&2 ||
        echo "[$CLI_NAME] $*" 1>&2
}

# Send a warning-highlighted text to stdout
say_warn() {
    [ -t 1 ] && [ -n "$TERM" ] &&
        echo "$(tput setaf 3)[$CLI_NAME] $*$(tput sgr0)" ||
        echo "[$CLI_NAME] $*"
}

# Exit with an error message and (optional) code
# Usage: die [-c <error code>] <error message>
#
die() {
    code=1
    [[ "$1" = "-c" ]] && {
        code="$2"
        shift 2
    }
    say_err "$@"
    exit "$code"
}

# Exit with an error message if the last exit code is not 0
#
ok_or_die() {
    code=$?
    [[ $code -eq 0 ]] || die -c $code "$@"
}

# Make sure the build/ dirs are available. Exit if we can't create them.
# Upon returning from this call, the caller can be certain the build/ dirs exist.
#
ensure_build_dir() {
    validate_host_paths
    for dir in "$CLH_BUILD_DIR" \
        "$CH_WORKLOADS_DIR" \
        "$CLH_CTR_BUILD_DIR" \
        "$CARGO_TARGET_DIR" \
        "$CARGO_REGISTRY_DIR" \
        "$CARGO_GIT_REGISTRY_DIR"; do
        mkdir -p "$dir" || die "Error: cannot create dir $dir"
        [ -x "$dir" ] && [ -w "$dir" ] ||
            {
                say "Wrong permissions for $dir. Attempting to fix them ..."
                chmod +x+w "$dir"
            } ||
            die "Error: wrong permissions for $dir. Should be +x+w"
    done
}

# Make sure we're using the latest dev container, by just pulling it.
ensure_latest_ctr() {
    if [ "$CH_OFFLINE" = "true" ]; then
        $DOCKER_RUNTIME image inspect "$CTR_IMAGE" >/dev/null 2>&1 ||
            die "Development image $CTR_IMAGE is not available locally. Load or build it before using --offline."
    elif [ "$CTR_IMAGE_VERSION" = "local" ]; then
        build_container
    else
        $DOCKER_RUNTIME pull "$CTR_IMAGE"

        if [ $? -ne 0 ]; then
            build_container
        fi

        ok_or_die "Error pulling/building container image. Aborting."
    fi
}

# Fix main directory permissions after a container ran as root.
# Since the container ran as root, any files it creates will be owned by root.
# This fixes that by recursively changing the ownership of /cloud-hypervisor to the
# current user.
#
fix_dir_perms() {
    # Yes, running Docker to get elevated privileges, just to chown some files
    # is a dirty hack.
    $DOCKER_RUNTIME run \
        --workdir "$CTR_CLH_ROOT_DIR" \
        --rm \
        --volume /dev:/dev \
        --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
        "$CTR_IMAGE" \
        chown -R "$(id -u):$(id -g)" "$CTR_CLH_ROOT_DIR"

    return "$1"
}
# Process exported volumes argument, separate the volumes and make docker compatible
# Sample input: --volumes /a:/a#/b:/b
# Sample output: --volume /a:/a --volume /b:/b
#
validate_url() {
    local name="$1"
    local value="$2"

    case "$value" in
    http://* | https://*) ;;
    *) die "$name must be an http(s) URL: $value" ;;
    esac
    case "$value" in
    *['$`";!&|\']*) die "$name contains unsafe characters: $value" ;;
    esac
}

validate_host_paths() {
    case "$CUBESANDBOX_DIR" in
    /*) ;;
    *) die "CUBESANDBOX_DIR must be an absolute path: $CUBESANDBOX_DIR" ;;
    esac
    case "$CH_WORKLOADS_DIR" in
    /*) ;;
    *) die "CH_WORKLOADS_DIR must be an absolute path: $CH_WORKLOADS_DIR" ;;
    esac

    local source_root workloads_root git_root
    source_root=$(realpath -e "$CUBESANDBOX_DIR") ||
        die "CUBESANDBOX_DIR does not exist: $CUBESANDBOX_DIR"
    workloads_root=$(realpath -m "$CH_WORKLOADS_DIR") ||
        die "Cannot resolve CH_WORKLOADS_DIR: $CH_WORKLOADS_DIR"
    case "$workloads_root" in
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
        die "CH_WORKLOADS_DIR must be a dedicated workload directory: $workloads_root"
        ;;
    esac
    git_root=$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null) ||
        die "CUBESANDBOX_DIR must be a Git worktree: $source_root"
    [ "$git_root" = "$source_root" ] ||
        die "CUBESANDBOX_DIR must be the Git worktree root: $source_root"

    CUBESANDBOX_DIR="$source_root"
    CH_WORKLOADS_DIR="$workloads_root"
    CLH_ROOT_DIR="$CUBESANDBOX_DIR/hypervisor"
    CLH_BUILD_DIR="$CLH_ROOT_DIR/build"
    CLH_CARGO_TARGET="$CLH_BUILD_DIR/cargo_target"
    CLH_DOCKERFILE="$CLH_ROOT_DIR/resources/Dockerfile"
    CARGO_REGISTRY_DIR="$CLH_BUILD_DIR/cargo_registry"
    CARGO_GIT_REGISTRY_DIR="$CLH_BUILD_DIR/cargo_git_registry"
    CARGO_TARGET_DIR="$CLH_BUILD_DIR/cargo_target"

    [ -f "$CLH_ROOT_DIR/scripts/dev_cli.sh" ] ||
        die "CUBESANDBOX_DIR does not contain hypervisor/scripts/dev_cli.sh: $CUBESANDBOX_DIR"
    [ -f "$CLH_ROOT_DIR/Cargo.toml" ] ||
        die "CUBESANDBOX_DIR does not contain hypervisor/Cargo.toml: $CUBESANDBOX_DIR"
}

validate_network_options() {
    if [ -n "$APT_MIRROR_BASE" ]; then
        validate_url "APT_MIRROR_BASE" "$APT_MIRROR_BASE"
        [[ "$APT_MIRROR_BASE" = http://* ]] ||
            die "APT_MIRROR_BASE must use http:// because CA certificates are not installed yet."
    fi
    [ -z "$WORKLOADS_BASE_URL" ] || validate_url "WORKLOADS_BASE_URL" "$WORKLOADS_BASE_URL"
    [[ "$CH_OFFLINE" =~ ^(true|false)$ ]] || die "CH_OFFLINE must be true or false."
    if [ "$CH_OFFLINE" = "true" ] && [ -n "$WORKLOADS_BASE_URL" ]; then
        die "--offline cannot be combined with --workloads-base-url."
    fi
}

process_volumes_args() {
    if [ -z "$arg_vols" ]; then
        return
    fi
    exported_volumes=""
    arr_vols=(${arg_vols//#/ })
    for var in "${arr_vols[@]}"; do
        parts=(${var//:/ })
        if [[ ! -e "${parts[0]}" ]]; then
            echo "The volume ${parts[0]} does not exist."
            exit 1
        fi
        exported_volumes="$exported_volumes --volume $var"
    done
}
cmd_help() {
    echo ""
    echo "Cloud Hypervisor $(basename "$0")"
    echo "Usage: $(basename "$0") <command> [<command args>]"
    echo ""
    echo "Available commands:"
    echo ""
    echo "    --prepare-offline-bundle"
    echo "        Download and compile offline test dependencies into a transferable tar.gz."
    echo ""
    echo "    build [--debug|--release] [--libc musl|gnu] [-- [<cargo args>]]"
    echo "        Build the Cloud Hypervisor binaries."
    echo "        --debug               Build the debug binaries. This is the default."
    echo "        --release             Build the release binaries."
    echo "        --libc                Select the C library Cloud Hypervisor will be built against. Default is gnu"
    echo "        --volumes             Hash separated volumes to be exported. Example --volumes /mnt:/mnt#/myvol:/myvol"
    echo "        --hypervisor          Underlying hypervisor. Options kvm, mshv"
    echo ""
    echo "    tests [<test type (see below)>] [--libc musl|gnu] [-- [<test scripts args>] [-- [<test binary args>]]] "
    echo "        Run the Cloud Hypervisor tests."
    echo "        --unit                       Run the unit tests."
    echo "        --integration                Run the integration tests."
    echo "        --integration-sgx            Run the SGX integration tests."
    echo "        --integration-vfio           Run the VFIO integration tests."
    echo "        --integration-windows        Run the Windows guest integration tests."
    echo "        --integration-live-migration Run the live-migration integration tests."
    echo "        --integration-rate-limiter   Run the rate-limiter integration tests."
    echo "        --libc                       Select the C library Cloud Hypervisor will be built against. Default is gnu"
    echo "        --metrics                    Generate performance metrics"
    echo "        --volumes                    Hash separated volumes to be exported. Example --volumes /mnt:/mnt#/myvol:/myvol"
    echo "        --hypervisor                 Underlying hypervisor. Options kvm, mshv"
    echo "        --quick                      Run only core smoke tests (5 priority levels)"
    echo "        --test-threads N             Set concurrency for parallel test suites."
    echo "        --workloads-base-url URL     Fetch missing workloads from a flat internal artifact URL."
    echo "        --offline                    Use only the local container image, workloads, and Cargo cache."
    echo "        --all                        Run all tests."
    echo ""
    echo "    build-container [--apt-mirror URL]"
    echo "        Build the Cloud Hypervisor container."
    echo "        --apt-mirror URL             Ubuntu mirror base containing ubuntu/ and ubuntu-ports/."
    echo ""
    echo "    clean [<cargo args>]]"
    echo "        Remove the Cloud Hypervisor artifacts."
    echo ""
    echo "    shell"
    echo "        Run the development container into an interactive, privileged BASH shell."
    echo "        --volumes             Hash separated volumes to be exported. Example --volumes /mnt:/mnt#/myvol:/myvol"
    echo ""
    echo "    help"
    echo "        Display this help message."
    echo ""
}

cmd_build() {
    build="debug"
    libc="gnu"
    hypervisor="kvm"
    features_build=""
    exported_device="/dev/kvm"
    while [ $# -gt 0 ]; do
        case "$1" in
        "-h" | "--help") {
            cmd_help
            exit 1
        } ;;
        "--debug") { build="debug"; } ;;
        "--release") { build="release"; } ;;
        "--runtime")
	    shift
	    DOCKER_RUNTIME="$1"
	    export DOCKER_RUNTIME
	    ;;
        "--libc")
            shift
            [[ "$1" =~ ^(musl|gnu)$ ]] ||
                die "Invalid libc: $1. Valid options are \"musl\" and \"gnu\"."
            libc="$1"
            ;;
        "--volumes")
            shift
            arg_vols="$1"
            ;;
        "--hypervisor")
            shift
            hypervisor="$1"
            ;;
        "--features")
            shift
            features_build="--features $1"
            ;;
        "--") {
            shift
            break
        } ;;
        *)
            die "Unknown build argument: $1. Please use --help for help."
            ;;
        esac
        shift
    done

    ensure_build_dir
    ensure_latest_ctr

    process_volumes_args
    if [[ ! ("$hypervisor" = "kvm" || "$hypervisor" = "mshv") ]]; then
        die "Hypervisor value must be kvm or mshv"
    fi
    if [[ "$hypervisor" = "mshv" ]]; then
        exported_device="/dev/mshv"
    fi
    target="$(uname -m)-unknown-linux-${libc}"

    cargo_args=("$@")
    [ $build = "release" ] && cargo_args+=("--release")
    cargo_args+=(--target "$target")

    rustflags=""
    target_cc=""
    if [ "$(uname -m)" = "aarch64" ] && [ "$libc" = "musl" ]; then
        rustflags="-C link-arg=-lgcc -C link_arg=-specs -C link_arg=/usr/lib/aarch64-linux-musl/musl-gcc.specs"
        target_cc="musl-gcc"
    fi

    $DOCKER_RUNTIME run \
        --user "$(id -u):$(id -g)" \
        --workdir "$CTR_CLH_ROOT_DIR" \
        --rm \
        --volume $exported_device \
        --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
        --env RUSTFLAGS="$rustflags" \
        --env TARGET_CC="$target_cc" \
        "$CTR_IMAGE" \
        cargo build --all $features_build \
        --target-dir "$CTR_CLH_CARGO_TARGET" \
        "${cargo_args[@]}" && say "Binaries placed under $CLH_CARGO_TARGET/$target/$build"
}

cmd_clean() {
    cargo_args=("$@")

    ensure_build_dir
    ensure_latest_ctr

    $DOCKER_RUNTIME run \
        --user "$(id -u):$(id -g)" \
        --workdir "$CTR_CLH_ROOT_DIR" \
        --rm \
        --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
        "$CTR_IMAGE" \
        cargo clean \
        --target-dir "$CTR_CLH_CARGO_TARGET" \
        "${cargo_args[@]}"
}

cmd_tests() {
    unit=false
    integration=false
    integration_sgx=false
    integration_vfio=false
    integration_windows=false
    integration_live_migration=false
    integration_rate_limiter=false
    metrics=false
    quick=false
    test_threads="$CH_TEST_THREADS"
    libc="gnu"
    arg_vols=""
    hypervisor="kvm"
    exported_device="/dev/kvm"
    while [ $# -gt 0 ]; do
        case "$1" in
        "-h" | "--help") {
            cmd_help
            exit 1
        } ;;
        "--unit") { unit=true; } ;;
        "--integration") { integration=true; } ;;
        "--integration-sgx") { integration_sgx=true; } ;;
        "--integration-vfio") { integration_vfio=true; } ;;
        "--integration-windows") { integration_windows=true; } ;;
        "--integration-live-migration") { integration_live_migration=true; } ;;
        "--integration-rate-limiter") { integration_rate_limiter=true; } ;;
        "--metrics") { metrics=true; } ;;
        "--libc")
            shift
            [[ "$1" =~ ^(musl|gnu)$ ]] ||
                die "Invalid libc: $1. Valid options are \"musl\" and \"gnu\"."
            libc="$1"
            ;;
        "--volumes")
            shift
            arg_vols="$1"
            ;;
        "--hypervisor")
            shift
            hypervisor="$1"
            ;;
        "--quick") { quick=true; } ;;
        "--test-threads")
            shift
            [ -n "${1:-}" ] || die "--test-threads requires a positive integer."
            test_threads="$1"
            ;;
        "--workloads-base-url")
            shift
            [ -n "$1" ] || die "--workloads-base-url requires a URL."
            WORKLOADS_BASE_URL="${1%/}"
            ;;
        "--offline") { CH_OFFLINE=true; } ;;
        "--all") {
            cargo=true
            unit=true
            integration=true
        } ;;
        "--") {
            shift
            break
        } ;;
        *)
            die "Unknown tests argument: $1. Please use --help for help."
            ;;
        esac
        shift
    done
    if [[ ! ("$hypervisor" = "kvm" || "$hypervisor" = "mshv") ]]; then
        die "Hypervisor value must be kvm or mshv"
    fi
    if [ -n "$test_threads" ] && [[ ! "$test_threads" =~ ^[1-9][0-9]*$ ]]; then
        die "Test thread count must be a positive integer: $test_threads"
    fi

    if [[ "$hypervisor" = "mshv" ]]; then
        exported_device="/dev/mshv"
    fi

    if [ -n "$test_threads" ]; then
        set -- '--test-threads' "$test_threads" "$@"
    fi
    if [ "$quick" = true ]; then
        set -- '--hypervisor' "$hypervisor" '--quick' "$@"
    else
        set -- '--hypervisor' "$hypervisor" "$@"
    fi

    validate_network_options
    ensure_build_dir
    ensure_latest_ctr

    process_volumes_args
    target="$(uname -m)-unknown-linux-${libc}"

    if [[ "$unit" = true ]]; then
        say "Running unit tests for $target..."
        $DOCKER_RUNTIME run \
            --workdir "$CTR_CLH_ROOT_DIR" \
            --rm \
            --device $exported_device \
            --device /dev/net/tun \
            --cap-add net_admin \
            --volume /dev:/dev \
            --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
            --env BUILD_TARGET="$target" \
            "$CTR_IMAGE" \
            ./scripts/run_unit_tests.sh "$@" || fix_dir_perms $? || exit $?
    fi

    if [ "$integration" = true ]; then
        say "Running integration tests for $target..."
        $DOCKER_RUNTIME run \
            --workdir "$CTR_CLH_ROOT_DIR" \
            --rm \
            --privileged \
            --security-opt seccomp=unconfined \
            --ipc=host \
            --net="$CTR_CLH_NET" \
            --mount type=tmpfs,destination=/tmp \
            --volume /dev:/dev \
            --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
            --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
            --env USER="root" \
            --env CH_LIBC="${libc}" \
            --env WORKLOADS_BASE_URL="$WORKLOADS_BASE_URL" \
            --env CH_OFFLINE="$CH_OFFLINE" \
            --env CARGO_NET_OFFLINE="$CH_OFFLINE" \
            "$CTR_IMAGE" \
            ./scripts/run_integration_tests_"$(uname -m)".sh "$@" || fix_dir_perms $? || exit $?
    fi

    if [ "$integration_sgx" = true ]; then
        say "Running SGX integration tests for $target..."
        $DOCKER_RUNTIME run \
            --workdir "$CTR_CLH_ROOT_DIR" \
            --rm \
            --privileged \
            --security-opt seccomp=unconfined \
            --ipc=host \
            --net="$CTR_CLH_NET" \
            --mount type=tmpfs,destination=/tmp \
            --volume /dev:/dev \
            --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
            --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
            --env USER="root" \
            --env CH_LIBC="${libc}" \
            "$CTR_IMAGE" \
            ./scripts/run_integration_tests_sgx.sh "$@" || fix_dir_perms $? || exit $?
    fi

    if [ "$integration_vfio" = true ]; then
        say "Running VFIO integration tests for $target..."
        $DOCKER_RUNTIME run \
            --workdir "$CTR_CLH_ROOT_DIR" \
            --rm \
            --privileged \
            --security-opt seccomp=unconfined \
            --ipc=host \
            --net="$CTR_CLH_NET" \
            --mount type=tmpfs,destination=/tmp \
            --volume /dev:/dev \
            --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
            --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
            --env USER="root" \
            --env CH_LIBC="${libc}" \
            "$CTR_IMAGE" \
            ./scripts/run_integration_tests_vfio.sh "$@" || fix_dir_perms $? || exit $?
    fi

    if [ "$integration_windows" = true ]; then
        say "Running Windows integration tests for $target..."
        $DOCKER_RUNTIME run \
            --workdir "$CTR_CLH_ROOT_DIR" \
            --rm \
            --privileged \
            --security-opt seccomp=unconfined \
            --ipc=host \
            --net="$CTR_CLH_NET" \
            --mount type=tmpfs,destination=/tmp \
            --volume /dev:/dev \
            --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
            --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
            --env USER="root" \
            --env CH_LIBC="${libc}" \
            "$CTR_IMAGE" \
            ./scripts/run_integration_tests_windows_"$(uname -m)".sh "$@" || fix_dir_perms $? || exit $?
    fi

    if [ "$integration_live_migration" = true ]; then
        say "Running 'live migration' integration tests for $target..."
        live_migration_script="run_integration_tests_live_migration.sh"
        live_migration_args=("$@")
        if [ "$(uname -m)" = "aarch64" ]; then
            live_migration_script="run_integration_tests_aarch64.sh"
            live_migration_args=(--live-migration-only "$@")
        fi
        $DOCKER_RUNTIME run \
            --workdir "$CTR_CLH_ROOT_DIR" \
            --rm \
            --privileged \
            --security-opt seccomp=unconfined \
            --ipc=host \
            --net="$CTR_CLH_NET" \
            --mount type=tmpfs,destination=/tmp \
            --volume /dev:/dev \
            --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
            --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
            --env USER="root" \
            --env CH_LIBC="${libc}" \
            --env WORKLOADS_BASE_URL="$WORKLOADS_BASE_URL" \
            --env CH_OFFLINE="$CH_OFFLINE" \
            --env CARGO_NET_OFFLINE="$CH_OFFLINE" \
            "$CTR_IMAGE" \
            "./scripts/$live_migration_script" "${live_migration_args[@]}" || fix_dir_perms $? || exit $?
    fi

    if [ "$integration_rate_limiter" = true ]; then
        say "Running 'rate limiter' integration tests for $target..."
        $DOCKER_RUNTIME run \
            --workdir "$CTR_CLH_ROOT_DIR" \
            --rm \
            --privileged \
            --security-opt seccomp=unconfined \
            --ipc=host \
            --net="$CTR_CLH_NET" \
            --mount type=tmpfs,destination=/tmp \
            --volume /dev:/dev \
            --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
            --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
            --env USER="root" \
            --env CH_LIBC="${libc}" \
            "$CTR_IMAGE" \
            ./scripts/run_integration_tests_rate_limiter.sh "$@" || fix_dir_perms $? || exit $?
    fi

    if [ "$metrics" = true ]; then
        say "Generating performance metrics for $target..."
        $DOCKER_RUNTIME run \
            --workdir "$CTR_CLH_ROOT_DIR" \
            --rm \
            --privileged \
            --security-opt seccomp=unconfined \
            --ipc=host \
            --net="$CTR_CLH_NET" \
            --mount type=tmpfs,destination=/tmp \
            --volume /dev:/dev \
            --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
            --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
            --env USER="root" \
            --env CH_LIBC="${libc}" \
            "$CTR_IMAGE" \
            ./scripts/run_metrics.sh "$@" || fix_dir_perms $? || exit $?
    fi

    fix_dir_perms $?
}

build_container() {
    ensure_build_dir

    BUILD_DIR=/tmp/cloud-hypervisor/container/

    mkdir -p $BUILD_DIR
    cp "$CLH_DOCKERFILE" $BUILD_DIR

    [ "$(uname -m)" = "aarch64" ] && TARGETARCH="arm64"
    [ "$(uname -m)" = "x86_64" ] && TARGETARCH="amd64"

    $DOCKER_RUNTIME build \
        --target dev \
        -t $CTR_IMAGE \
        -f $BUILD_DIR/Dockerfile \
        --build-arg TARGETARCH=$TARGETARCH \
        --build-arg APT_MIRROR_BASE="$APT_MIRROR_BASE" \
        $BUILD_DIR
}

cmd_build-container() {
    while [ $# -gt 0 ]; do
        case "$1" in
        "-h" | "--help") {
            cmd_help
            exit 1
        } ;;
        "--apt-mirror")
            shift
            [ -n "$1" ] || die "--apt-mirror requires a URL."
            APT_MIRROR_BASE="${1%/}"
            ;;
        "--") {
            shift
            break
        } ;;
        *)
            die "Unknown build-container argument: $1. Please use --help for help."
            ;;
        esac
        shift
    done

    validate_network_options
    build_container
}

prepare_custom_artifacts() {
    local result_variable="$1"
    local marker="$2"
    shift 2
    local specifications=("$@")
    local specification variable filename derived source

    for specification in "${specifications[@]}"; do
        IFS=: read -r variable filename derived <<< "$specification"
        source="${!variable:-}"
        [ -z "$source" ] && continue
        case "$source" in
        /*) ;;
        *) die "$variable must be an absolute path: $source" ;;
        esac
        if [ ! -f "$source" ] || [ ! -r "$source" ]; then
            die "$variable must reference a readable regular file: $source"
        fi
    done

    local custom_artifacts=""
    for specification in "${specifications[@]}"; do
        IFS=: read -r variable filename derived <<< "$specification"
        source="${!variable:-}"
        [ -z "$source" ] && continue
        local temporary="$CH_WORKLOADS_DIR/.${filename}.tmp.$$"
        cp "$source" "$temporary" || die "Failed to copy custom artifact from $source."
        chmod --reference="$source" "$temporary" || {
            rm -f "$temporary"
            die "Failed to preserve permissions for custom artifact $filename."
        }
        mv "$temporary" "$CH_WORKLOADS_DIR/$filename" || {
            rm -f "$temporary"
            die "Failed to install custom artifact $filename."
        }
        if [ -n "$derived" ]; then
            local derived_file
            local derived_files=()
            IFS=, read -r -a derived_files <<< "$derived"
            for derived_file in "${derived_files[@]}"; do
                rm -f "$CH_WORKLOADS_DIR/$derived_file" ||
                    die "Failed to invalidate derived workload $derived_file."
            done
        fi
        case "$filename" in
        alpine-minirootfs-x86_64.tar.gz | alpine-minirootfs-aarch64.tar.gz)
            rm -rf "$CH_WORKLOADS_DIR/alpine-minirootfs" ||
                die "Failed to invalidate the Alpine extraction directory."
            ;;
        esac
        custom_artifacts="${custom_artifacts:+$custom_artifacts,}$filename"
    done
    printf -v "$result_variable" '%s' "$custom_artifacts"
    printf '%s\n' "$custom_artifacts" > "$CH_WORKLOADS_DIR/$marker" ||
        die "Failed to record custom artifacts."
}

prepare_custom_x86_artifacts() {
    prepare_custom_artifacts CH_CUSTOM_X86_ARTIFACTS .custom_x86_artifacts \
        "CH_X86_HYPERVISOR_FW_FILE:hypervisor-fw:" \
        "CH_X86_CLOUDHV_FD_FILE:CLOUDHV.fd:" \
        "CH_X86_BIONIC_QCOW2_FILE:bionic-server-cloudimg-amd64.qcow2:bionic-server-cloudimg-amd64.raw" \
        "CH_X86_FOCAL_QCOW2_FILE:focal-server-cloudimg-amd64-custom-20210609-0.qcow2:focal-server-cloudimg-amd64-custom-20210609-0.raw" \
        "CH_X86_JAMMY_QCOW2_FILE:jammy-server-cloudimg-amd64-custom-20220329-0.qcow2:jammy-server-cloudimg-amd64-custom-20220329-0.raw" \
        "CH_X86_ALPINE_MINIROOTFS_FILE:alpine-minirootfs-x86_64.tar.gz:alpine_initramfs.img" \
        "CH_X86_VMLINUX_FILE:vmlinux:" \
        "CH_X86_VIRTIOFSD_FILE:virtiofsd:"
}

prepare_custom_aarch64_artifacts() {
    prepare_custom_artifacts CH_CUSTOM_AARCH64_ARTIFACTS .custom_aarch64_artifacts \
        "CH_BIONIC_ARM64_QCOW2_FILE:bionic-server-cloudimg-arm64.qcow2:bionic-server-cloudimg-arm64.raw" \
        "CH_FOCAL_ARM64_QCOW2_FILE:focal-server-cloudimg-arm64-custom-20210929-0.qcow2:focal-server-cloudimg-arm64-custom-20210929-0.raw,focal-server-cloudimg-arm64-custom-20210929-0-update-kernel.raw" \
        "CH_JAMMY_ARM64_QCOW2_FILE:jammy-server-cloudimg-arm64-custom-20220329-0.qcow2:jammy-server-cloudimg-arm64-custom-20220329-0.raw" \
        "CH_ALPINE_ARM64_MINIROOTFS_FILE:alpine-minirootfs-aarch64.tar.gz:alpine_initramfs.img" \
        "CH_CLOUD_HYPERVISOR_STATIC_ARM64_FILE:cloud-hypervisor-static-aarch64:"
}

prune_staged_workloads() {
    local workloads="$OFFLINE_BUNDLE_STAGE/workloads"
    find "$workloads" -name .git -prune -exec rm -rf {} + ||
        die "Failed to remove Git metadata from staged workloads."
    rm -rf \
        "$workloads/alpine_initramfs.img" \
        "$workloads/alpine-minirootfs" ||
        die "Failed to remove derived workloads from the offline bundle."
    find "$workloads" -type f \
        \( -name '*-server-cloudimg-*.img' \
        -o -name '*-server-cloudimg-*.raw' \) \
        -delete || die "Failed to remove duplicate guest image formats."

    if find "$workloads" -name .git -print -quit | grep -q . ||
        find "$workloads" -type f \
            \( -name '*-server-cloudimg-*.img' \
            -o -name '*-server-cloudimg-*.raw' \
            -o -name 'alpine_initramfs.img' \) \
            -print -quit | grep -q . ||
        [ -d "$workloads/alpine-minirootfs" ]; then
        die "Offline bundle workloads contain noncanonical derived files."
    fi
}

cleanup_offline_bundle() {
    [ -z "${OFFLINE_BUNDLE_STAGE:-}" ] || rm -rf "$OFFLINE_BUNDLE_STAGE"
    [ -z "${OFFLINE_BUNDLE_TEMP:-}" ] || rm -f "$OFFLINE_BUNDLE_TEMP"
}

prepare_offline_bundle() {
    local architecture
    architecture=$(uname -m)
    case "$architecture" in
    x86_64 | aarch64) ;;
    *) die "--prepare-offline-bundle supports x86_64 and aarch64 only." ;;
    esac
    [ "$CH_OFFLINE" = "false" ] || die "--prepare-offline-bundle requires network access."

    validate_network_options
    ensure_build_dir
    if [ "$architecture" = "x86_64" ]; then
        prepare_custom_x86_artifacts
    else
        prepare_custom_aarch64_artifacts
    fi
    ensure_latest_ctr

    local prepare_script
    local prepare_scripts=(run_integration_tests_x86_64.sh run_integration_tests_live_migration.sh)
    if [ "$architecture" = "aarch64" ]; then
        prepare_scripts=(run_integration_tests_aarch64.sh)
    fi
    for prepare_script in "${prepare_scripts[@]}"; do
        say "Preparing dependencies with $prepare_script..."
        $DOCKER_RUNTIME run \
            --workdir "$CTR_CLH_ROOT_DIR" \
            --rm \
            --privileged \
            --security-opt seccomp=unconfined \
            --ipc=host \
            --net="$CTR_CLH_NET" \
            --mount type=tmpfs,destination=/tmp \
            --volume /dev:/dev \
            --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" \
            --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
            --env USER="root" \
            --env CH_LIBC="gnu" \
            --env WORKLOADS_BASE_URL="$WORKLOADS_BASE_URL" \
            --env CH_CUSTOM_X86_ARTIFACTS="$CH_CUSTOM_X86_ARTIFACTS" \
            --env CH_CUSTOM_AARCH64_ARTIFACTS="$CH_CUSTOM_AARCH64_ARTIFACTS" \
            "$CTR_IMAGE" \
            "./scripts/$prepare_script" --hypervisor kvm --prepare-offline ||
            die "Failed to prepare offline dependencies with $prepare_script."
    done

    $DOCKER_RUNTIME run \
        --rm \
        --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" \
        --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
        "$CTR_IMAGE" \
        chown -R "$(id -u):$(id -g)" "$CTR_CLH_ROOT_DIR" "$CTR_CH_WORKLOADS_DIR" ||
        die "Failed to restore ownership of prepared offline dependencies."

    local commit short_commit dirty created_at output
    commit=$(git -C "$CLH_ROOT_DIR" rev-parse HEAD)
    short_commit=$(git -C "$CLH_ROOT_DIR" rev-parse --short=12 HEAD)
    dirty=false
    [ -z "$(git -C "$CLH_ROOT_DIR" status --porcelain)" ] || dirty=true
    created_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    output="$PWD/cloud-hypervisor-offline-${short_commit}-${architecture}.tgz"

    OFFLINE_BUNDLE_STAGE=$(mktemp -d)
    OFFLINE_BUNDLE_TEMP="${output}.tmp.$$"
    trap cleanup_offline_bundle EXIT

    mkdir -p \
        "$OFFLINE_BUNDLE_STAGE/docker" \
        "$OFFLINE_BUNDLE_STAGE/workloads" \
        "$OFFLINE_BUNDLE_STAGE/CubeSandbox/hypervisor/build"
    $DOCKER_RUNTIME save -o "$OFFLINE_BUNDLE_STAGE/docker/cloud-hypervisor-dev-image.tar" "$CTR_IMAGE" ||
        die "Failed to export development image $CTR_IMAGE."
    cp -a "$CH_WORKLOADS_DIR/." "$OFFLINE_BUNDLE_STAGE/workloads/" ||
        die "Failed to stage workloads."
    prune_staged_workloads

    local git_source_list="$OFFLINE_BUNDLE_STAGE/git-source-files"
    local source_list="$OFFLINE_BUNDLE_STAGE/source-files"
    local source_archive="$OFFLINE_BUNDLE_STAGE/source.tar"
    git -C "$CUBESANDBOX_DIR" ls-files --cached --others --exclude-standard -z > "$git_source_list" ||
        die "Failed to enumerate CubeSandbox source files."
    while IFS= read -r -d '' source_file; do
        [ -e "$CUBESANDBOX_DIR/$source_file" ] || [ -L "$CUBESANDBOX_DIR/$source_file" ] || continue
        case "$source_file" in
        .git | .git/* | */.git | */.git/* | CubeSandbox | CubeSandbox/* | MANIFEST | SHA256SUMS | workloads | workloads/* | docker/cloud-hypervisor-dev-image.tar | cloud-hypervisor-offline-*.tgz | cloud-hypervisor-offline-*.tgz.tmp.* | */cloud-hypervisor-offline-*.tgz | */cloud-hypervisor-offline-*.tgz.tmp.* | cloud-hypervisor-offline-*.tar.gz | cloud-hypervisor-offline-*.tar.gz.tmp.* | */cloud-hypervisor-offline-*.tar.gz | */cloud-hypervisor-offline-*.tar.gz.tmp.* | *.dev_cli.log.txt | */*.dev_cli.log.txt) continue ;;
        esac
        printf '%s\0' "$source_file"
    done < "$git_source_list" > "$source_list" ||
        die "Failed to filter CubeSandbox source files."
    [ -s "$source_list" ] || die "CubeSandbox source file list is empty."
    tar -C "$CUBESANDBOX_DIR" --null -T "$source_list" -cf "$source_archive" ||
        die "Failed to archive CubeSandbox source files."
    tar -C "$OFFLINE_BUNDLE_STAGE/CubeSandbox" -xf "$source_archive" ||
        die "Failed to stage CubeSandbox source files."
    rm -f "$git_source_list" "$source_list" "$source_archive" ||
        die "Failed to clean temporary source archives."

    local cache_dir
    for cache_dir in cargo_registry cargo_git_registry cargo_target; do
        if [ -d "$CLH_BUILD_DIR/$cache_dir" ]; then
            cp -a "$CLH_BUILD_DIR/$cache_dir" "$OFFLINE_BUNDLE_STAGE/CubeSandbox/hypervisor/build/" ||
                die "Failed to stage $cache_dir."
        fi
    done
    if [ -d "$CLH_ROOT_DIR/target" ]; then
        cp -a "$CLH_ROOT_DIR/target" "$OFFLINE_BUNDLE_STAGE/CubeSandbox/hypervisor/" ||
            die "Failed to stage hypervisor target artifacts."
    fi

    cat > "$OFFLINE_BUNDLE_STAGE/MANIFEST" <<EOF
source_commit=$commit
source_dirty=$dirty
architecture=$architecture
created_at=$created_at
container_image=$CTR_IMAGE
custom_x86_artifacts=$CH_CUSTOM_X86_ARTIFACTS
custom_aarch64_artifacts=$CH_CUSTOM_AARCH64_ARTIFACTS
source_destination=CubeSandbox
workloads_destination=workloads
hypervisor_cache_destination=CubeSandbox/hypervisor/build
hypervisor_target_destination=CubeSandbox/hypervisor/target
EOF

    (
        cd "$OFFLINE_BUNDLE_STAGE" || exit 1
        find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
    ) || die "Failed to generate offline bundle checksums."
    if command -v pigz >/dev/null 2>&1; then
        tar --use-compress-program=pigz -cvpf "$OFFLINE_BUNDLE_TEMP" \
            -C "$OFFLINE_BUNDLE_STAGE" . ||
            die "Failed to create offline bundle archive."
    else
        tar -C "$OFFLINE_BUNDLE_STAGE" -czf "$OFFLINE_BUNDLE_TEMP" . ||
            die "Failed to create offline bundle archive."
    fi
    tar -tzf "$OFFLINE_BUNDLE_TEMP" >/dev/null ||
        die "Failed to verify offline bundle archive."
    mv "$OFFLINE_BUNDLE_TEMP" "$output" ||
        die "Failed to install offline bundle archive."
    OFFLINE_BUNDLE_TEMP=""

    say "Offline bundle created: $output"
    echo "On the offline machine, extract it and run:"
    echo "  docker load -i docker/cloud-hypervisor-dev-image.tar"
    echo "  CUBESANDBOX_DIR=\"\$PWD/CubeSandbox\" CH_WORKLOADS_DIR=\"\$PWD/workloads\" ./CubeSandbox/hypervisor/scripts/dev_cli.sh tests --integration --offline"
    echo "  CUBESANDBOX_DIR=\"\$PWD/CubeSandbox\" CH_WORKLOADS_DIR=\"\$PWD/workloads\" ./CubeSandbox/hypervisor/scripts/dev_cli.sh tests --integration-live-migration --offline"
}

cmd_shell() {
    while [ $# -gt 0 ]; do
        case "$1" in
        "-h" | "--help") {
            cmd_help
            exit 1
        } ;;
        "--volumes")
            shift
            arg_vols="$1"
            ;;
        "--") {
            shift
            break
        } ;;
        *) ;;

        esac
        shift
    done
    ensure_build_dir
    ensure_latest_ctr
    process_volumes_args
    say_warn "Starting a privileged shell prompt as root ..."
    say_warn "WARNING: Your $CLH_ROOT_DIR folder will be bind-mounted in the container under $CTR_CLH_ROOT_DIR"
    $DOCKER_RUNTIME run \
        -ti \
        --workdir "$CTR_CLH_ROOT_DIR" \
        --rm \
        --privileged \
        --security-opt seccomp=unconfined \
        --ipc=host \
        --net="$CTR_CLH_NET" \
        --tmpfs /tmp:exec \
        --volume /dev:/dev \
        --volume "$CLH_ROOT_DIR:$CTR_CLH_ROOT_DIR" $exported_volumes \
        --volume "$CH_WORKLOADS_DIR:$CTR_CH_WORKLOADS_DIR" \
        --env USER="root" \
        --entrypoint bash \
        "$CTR_IMAGE"

    fix_dir_perms $?
}

# Parse main command line args.
#
if [ "${1:-}" = "--prepare-offline-bundle" ]; then
    [ $# -eq 1 ] || die "--prepare-offline-bundle does not accept additional arguments."
    prepare_offline_bundle
    exit $?
fi

while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help) {
        cmd_help
        exit 1
    } ;;
    --local) {
        CTR_IMAGE_VERSION="local"
        CTR_IMAGE="${CTR_IMAGE_TAG}:${CTR_IMAGE_VERSION}"
    } ;;
    -*)
        die "Unknown arg: $1. Please use \`$0 help\` for help."
        ;;
    *)
        break
        ;;
    esac
    shift
done

# $1 is now a command name. Check if it is a valid command and, if so,
# run it.
#
declare -f "cmd_$1" >/dev/null
ok_or_die "Unknown command: $1. Please use \`$0 help\` for help."

cmd=cmd_$1
shift

$cmd "$@"
