#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cubebench.sh
# shellcheck disable=SC1091
source "${CUBEBENCH_SCRIPT:-${SCRIPT_DIR}/cubebench.sh}"

assert_cpu_config() {
	local name="$1" expected="$2" input="$3" actual
	actual="$(parse_cpu_config <<<"$input")"
	if [ "$actual" != "$expected" ]; then
		printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$name"
}

assert_report_line() {
	local expected="$1" report="$2"
	if ! grep -Fxq "$expected" "$report"; then
		printf 'FAIL: report missing line: %s\nreport:\n' "$expected" >&2
		cat "$report" >&2
		return 1
	fi
}

snapshot=$'process_pss=2048\tcgroup_kernel=1024\tprocess_threads=8'
[ "$(density_snapshot_value "$snapshot" process_pss)" = "2048" ]
[ "$(density_snapshot_value "$snapshot" missing)" = "0" ]
[ "$(density_delta_per_vm 3072 1024 2)" = "1.00" ]
[ "$(density_delta_per_vm 10 2 4 1)" = "2.00" ]
[ "$(density_delta_per_vm 1 2 4)" = "—" ]
printf 'PASS: density memory arithmetic\n'

fixture="$(mktemp -d)"
mkdir -p "$fixture/proc/100" "$fixture/proc/101" \
	"$fixture/cgroup/cube/child"
ln -s /opt/containerd-shim-cube-rs "$fixture/proc/100/exe"
ln -s /opt/containerd-shim-cube-rs "$fixture/proc/101/exe"
printf 'Threads:\t2\n' >"$fixture/proc/100/status"
printf 'Threads:\t3\n' >"$fixture/proc/101/status"
cat >"$fixture/proc/100/smaps_rollup" <<'EOF'
Rss: 128 kB
Pss: 64 kB
Private_Clean: 16 kB
Private_Dirty: 32 kB
Anonymous: 48 kB
EOF
# Deliberately omit PID 101's smaps_rollup to exercise partial-coverage output.
printf '0::/cube\n' >"$fixture/proc/100/cgroup"
printf '0::/cube/child\n' >"$fixture/proc/101/cgroup"
cat >"$fixture/proc/meminfo" <<'EOF'
MemTotal: 1024 kB
MemAvailable: 512 kB
EOF
printf '4096\n' >"$fixture/cgroup/cube/memory.current"
printf 'anon 4096\nkernel 1024\n' >"$fixture/cgroup/cube/memory.stat"
printf '2048\n' >"$fixture/cgroup/cube/child/memory.current"
printf 'anon 2048\nkernel 512\n' >"$fixture/cgroup/cube/child/memory.stat"

fixture_snapshot="$(
	CUBE_BENCH_PROC_ROOT="$fixture/proc" \
		CUBE_BENCH_CGROUP_ROOT="$fixture/cgroup" \
		cube_memory_snapshot
)"
[ "$(density_snapshot_value "$fixture_snapshot" process_count)" = "2" ]
[ "$(density_snapshot_value "$fixture_snapshot" process_smaps_count)" = "1" ]
[ "$(density_snapshot_value "$fixture_snapshot" cgroup_process_count)" = "2" ]
[ "$(density_snapshot_value "$fixture_snapshot" cgroup_count)" = "1" ]
[ "$(density_snapshot_value "$fixture_snapshot" cgroup_stat_count)" = "1" ]
[ "$(density_snapshot_value "$fixture_snapshot" cgroup_current)" = "4" ]
[ "$(density_snapshot_value "$fixture_snapshot" cgroup_anon)" = "4" ]
rm -rf "$fixture"
printf 'PASS: density cgroup dedup and coverage\n'

assert_cpu_config "complete topology" \
	"192 logical CPUs (2 sockets, 48 cores/socket, 2 threads/core)" \
	$'CPU(s):                 192\n  On-line CPU(s) list:  0-191\n    Thread(s) per core: 2\n    Core(s) per socket: 48\n    Socket(s):          2'

assert_cpu_config "singular topology" \
	"1 logical CPU (1 socket, 1 core/socket, 1 thread/core)" \
	$'CPU(s): 1\nSocket(s): 1\nCore(s) per socket: 1\nThread(s) per core: 1'

assert_cpu_config "missing field" "unknown" \
	$'CPU(s): 8\nSocket(s): 1\nCore(s) per socket: 4'

assert_cpu_config "malformed field" "unknown" \
	$'CPU(s): 8\nSocket(s): two\nCore(s) per socket: 4\nThread(s) per core: 2'

assert_cpu_config "zero field" "unknown" \
	$'CPU(s): 8\nSocket(s): 1\nCore(s) per socket: 4\nThread(s) per core: 0'

assert_cpu_config "no lscpu output" "unknown" ""

lscpu() {
	[ "${LC_ALL:-}" = C ] || return 1
	printf '%s\n' \
		'CPU(s): 8' \
		'    Socket(s): 1' \
		'    Core(s) per socket: 4' \
		'    Thread(s) per core: 2' \
		'CPU:' \
		'  Model name: Test CPU' \
		'NUMA:' \
		'  NUMA node(s): 1'
}

get_node_count() {
	printf '1\n'
}

report="$(mktemp)"
trap 'rm -f "$report"' EXIT
# shellcheck disable=SC2034 # Read by print_test_env from the sourced script.
CUBELET_CONF="${report}.missing"
# shellcheck disable=SC2034 # Read by print_test_env from the sourced script.
OUTPUT_MD="$report"
(
	set +e +u +o pipefail
	print_test_env
) >/dev/null

assert_report_line '| CPU Model | Test CPU |' "$report"
assert_report_line '| CPU Config | 8 logical CPUs (1 socket, 4 cores/socket, 2 threads/core) |' "$report"
assert_report_line '| NUMA Nodes | 1 |' "$report"
printf 'PASS: C locale environment report\n'
