#!/bin/bash
#
# Host-side memory attribution helpers for cubebench section 3.3.
# Values are emitted as tab-separated key=value pairs in KiB unless noted.

cube_memory_process_pids() {
	local proc exe
	local names=":${CUBE_BENCH_MEMORY_EXES:-containerd-shim-cube-rs:cube-hypervisor:cloud-hypervisor}:"

	for proc in "${CUBE_BENCH_PROC_ROOT:-/proc}"/[0-9]*; do
		[ -d "$proc" ] || continue
		exe="$(readlink "$proc/exe" 2>/dev/null)" || continue
		exe="${exe##*/}"
		exe="${exe% (deleted)}"
		case "$names" in
		*":${exe}:"*) printf '%s\n' "${proc##*/}" ;;
		esac
	done
}

_cube_memory_meminfo_value() {
	local key="$1"
	awk -v key="${key}:" '$1 == key { print $2; found=1; exit } END { if (!found) print 0 }' \
		"${CUBE_BENCH_PROC_ROOT:-/proc}/meminfo" 2>/dev/null
}

_cube_memory_cgroup_path() {
	local pid="$1" hierarchy controllers path

	while IFS=: read -r hierarchy controllers path; do
		if [ "$hierarchy" = "0" ] && [ -z "$controllers" ]; then
			printf '%s\n' "$path"
			return 0
		fi
	done <"${CUBE_BENCH_PROC_ROOT:-/proc}/${pid}/cgroup" 2>/dev/null
	return 1
}

cube_memory_snapshot() {
	local proc_root="${CUBE_BENCH_PROC_ROOT:-/proc}"
	local cgroup_root="${CUBE_BENCH_CGROUP_ROOT:-/sys/fs/cgroup}"
	local mem_total mem_available
	local process_count=0 smaps_count=0 thread_count=0
	local process_rss=0 process_pss=0 process_private=0 process_anon=0
	local cgroup_process_count=0 cgroup_count=0 cgroup_stat_count=0 cgroup_current=0
	local cgroup_anon=0 cgroup_file=0 cgroup_kernel=0
	local cgroup_kernel_stack=0 cgroup_pagetables=0 cgroup_sec_pagetables=0
	local cgroup_percpu=0 cgroup_sock=0 cgroup_slab=0
	local cgroup_slab_reclaimable=0 cgroup_slab_unreclaimable=0
	local pid threads rss pss private anon cgroup_path cgroup_dir value key
	local -a pids=()
	local -A cgroups=()

	mem_total="$(_cube_memory_meminfo_value MemTotal)"
	mem_available="$(_cube_memory_meminfo_value MemAvailable)"

	while IFS= read -r pid; do
		[ -n "$pid" ] && pids+=("$pid")
	done < <(cube_memory_process_pids)
	process_count="${#pids[@]}"

	for pid in "${pids[@]}"; do
		threads="$(awk '/^Threads:/ { print $2; exit }' "${proc_root}/${pid}/status" 2>/dev/null)"
		thread_count=$((thread_count + ${threads:-0}))

		if [ -r "${proc_root}/${pid}/smaps_rollup" ]; then
			read -r rss pss private anon < <(
				awk '
					/^Rss:/           { rss=$2 }
					/^Pss:/           { pss=$2 }
					/^Private_Clean:/ { private += $2 }
					/^Private_Dirty:/ { private += $2 }
					/^Anonymous:/     { anon=$2 }
					END { print rss+0, pss+0, private+0, anon+0 }
				' "${proc_root}/${pid}/smaps_rollup" 2>/dev/null
			)
			process_rss=$((process_rss + ${rss:-0}))
			process_pss=$((process_pss + ${pss:-0}))
			process_private=$((process_private + ${private:-0}))
			process_anon=$((process_anon + ${anon:-0}))
			smaps_count=$((smaps_count + 1))
		fi

		cgroup_path="$(_cube_memory_cgroup_path "$pid")" || continue
		cgroup_dir="${cgroup_root}${cgroup_path}"
		[ -r "${cgroup_dir}/memory.current" ] || continue
		cgroup_process_count=$((cgroup_process_count + 1))
		cgroups["$cgroup_dir"]=1
	done

	for cgroup_dir in "${!cgroups[@]}"; do
		# memory.current and memory.stat are recursive in cgroup v2. If matching
		# processes occupy both an ancestor and its child, retain only the
		# ancestor or the child's charge would be counted twice.
		local ancestor skip_cgroup=0
		for ancestor in "${!cgroups[@]}"; do
			[ "$ancestor" = "$cgroup_dir" ] && continue
			case "${cgroup_dir}/" in
			"${ancestor}/"*)
				skip_cgroup=1
				break
				;;
			esac
		done
		[ "$skip_cgroup" -eq 1 ] && continue

		value="$(cat "${cgroup_dir}/memory.current" 2>/dev/null)" || continue
		case "$value" in
		'' | *[!0-9]*) continue ;;
		esac
		cgroup_count=$((cgroup_count + 1))
		cgroup_current=$((cgroup_current + value))

		if [ -r "${cgroup_dir}/memory.stat" ]; then
			while read -r key value; do
				case "$key" in
				anon) cgroup_anon=$((cgroup_anon + value)) ;;
				file) cgroup_file=$((cgroup_file + value)) ;;
				kernel) cgroup_kernel=$((cgroup_kernel + value)) ;;
				kernel_stack) cgroup_kernel_stack=$((cgroup_kernel_stack + value)) ;;
				pagetables) cgroup_pagetables=$((cgroup_pagetables + value)) ;;
				sec_pagetables)
					cgroup_sec_pagetables=$((cgroup_sec_pagetables + value))
					;;
				percpu) cgroup_percpu=$((cgroup_percpu + value)) ;;
				sock) cgroup_sock=$((cgroup_sock + value)) ;;
				slab) cgroup_slab=$((cgroup_slab + value)) ;;
				slab_reclaimable)
					cgroup_slab_reclaimable=$((cgroup_slab_reclaimable + value))
					;;
				slab_unreclaimable)
					cgroup_slab_unreclaimable=$((cgroup_slab_unreclaimable + value))
					;;
				esac
			done <"${cgroup_dir}/memory.stat" 2>/dev/null
			cgroup_stat_count=$((cgroup_stat_count + 1))
		fi
	done

	# memory.current and memory.stat use bytes; all other sources above use KiB.
	printf '%s\t' \
		"host_used=$((mem_total - mem_available))" \
		"host_anon=$(_cube_memory_meminfo_value AnonPages)" \
		"host_anon_huge=$(_cube_memory_meminfo_value AnonHugePages)" \
		"host_page_tables=$(_cube_memory_meminfo_value PageTables)" \
		"host_sec_page_tables=$(_cube_memory_meminfo_value SecPageTables)" \
		"host_kernel_stack=$(_cube_memory_meminfo_value KernelStack)" \
		"host_slab=$(_cube_memory_meminfo_value Slab)" \
		"host_sreclaimable=$(_cube_memory_meminfo_value SReclaimable)" \
		"host_sunreclaim=$(_cube_memory_meminfo_value SUnreclaim)" \
		"host_cached=$(_cube_memory_meminfo_value Cached)" \
		"host_shmem=$(_cube_memory_meminfo_value Shmem)" \
		"process_count=${process_count}" \
		"process_smaps_count=${smaps_count}" \
		"process_threads=${thread_count}" \
		"process_rss=${process_rss}" \
		"process_pss=${process_pss}" \
		"process_private=${process_private}" \
		"process_anon=${process_anon}" \
		"cgroup_process_count=${cgroup_process_count}" \
		"cgroup_count=${cgroup_count}" \
		"cgroup_stat_count=${cgroup_stat_count}" \
		"cgroup_current=$((cgroup_current / 1024))" \
		"cgroup_anon=$((cgroup_anon / 1024))" \
		"cgroup_file=$((cgroup_file / 1024))" \
		"cgroup_kernel=$((cgroup_kernel / 1024))" \
		"cgroup_kernel_stack=$((cgroup_kernel_stack / 1024))" \
		"cgroup_pagetables=$((cgroup_pagetables / 1024))" \
		"cgroup_sec_pagetables=$((cgroup_sec_pagetables / 1024))" \
		"cgroup_percpu=$((cgroup_percpu / 1024))" \
		"cgroup_sock=$((cgroup_sock / 1024))" \
		"cgroup_slab=$((cgroup_slab / 1024))" \
		"cgroup_slab_reclaimable=$((cgroup_slab_reclaimable / 1024))"
	printf '%s\n' "cgroup_slab_unreclaimable=$((cgroup_slab_unreclaimable / 1024))"
}
