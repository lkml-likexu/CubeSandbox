# Hypervisor 离线集成测试

本文说明如何配置 Ubuntu APT 镜像、使用内网 workload 制品源，以及准备并恢复完全离线的测试 Bundle。支持以下测试：

```bash
./hypervisor/scripts/dev_cli.sh tests --integration
./hypervisor/scripts/dev_cli.sh tests --integration-live-migration
```

## 前置条件

准备机和测试机均需满足：

- x86_64 或 aarch64 Linux；
- Docker 可用；
- Bundle 必须在与离线测试机相同架构的联网物理机上生成；
- Bundle 构建时的当前 CubeSandbox 工作树会随归档传输，无需在离线机另行检出源码；
- 足够的磁盘空间；
- 执行实际集成测试时可访问 `/dev/kvm`，并允许特权容器、hugepages、KSM、网络及临时挂载相关操作。

建议仅在专用测试机上运行完整集成测试。准备 Bundle 不执行 KVM 测试，也不会配置 KSM 或 hugepages。

## 配置 Ubuntu APT 镜像

构建开发镜像时可指定内部 Ubuntu 镜像：

```bash
./hypervisor/scripts/dev_cli.sh build-container \
  --apt-mirror http://apt.internal
```

镜像根地址下应包含：

```text
http://apt.internal/ubuntu/
http://apt.internal/ubuntu-ports/
```

APT 镜像必须使用 `http://`。开发镜像第一次执行 `apt-get update` 时尚未安装 CA 证书，因此不接受 HTTPS 地址。

## 使用内网 workload 制品源

如果测试机可访问统一的内部 HTTP(S) 制品服务，可直接运行：

```bash
./hypervisor/scripts/dev_cli.sh tests \
  --integration \
  --workloads-base-url http://artifacts.internal/cloud-hypervisor

./hypervisor/scripts/dev_cli.sh tests \
  --integration-live-migration \
  --workloads-base-url http://artifacts.internal/cloud-hypervisor
```

制品服务必须使用平铺目录，下载地址格式为：

```text
<base-url>/<filename>
```

普通 x86_64 integration 至少需要提供：

```text
hypervisor-fw
CLOUDHV.fd
bionic-server-cloudimg-amd64.qcow2
focal-server-cloudimg-amd64-custom-20210609-0.qcow2
jammy-server-cloudimg-amd64-custom-20220329-0.qcow2
alpine-minirootfs-x86_64.tar.gz
vmlinux
virtiofsd
```

x86_64 live migration 使用其中的：

```text
focal-server-cloudimg-amd64-custom-20210609-0.qcow2
vmlinux
```

aarch64 内网制品源应提供可直接下载的输入文件：

```text
bionic-server-cloudimg-arm64.qcow2
focal-server-cloudimg-arm64-custom-20210929-0.qcow2
jammy-server-cloudimg-arm64-custom-20220329-0.qcow2
alpine-minirootfs-aarch64.tar.gz
cloud-hypervisor-static-aarch64
```

ARM 准备过程还会在联网 aarch64 主机上原生构建 Linux、EDK2、virtiofsd 和 SPDK，并将最终产物加入 Bundle。已存在于 `~/workloads` 的文件不会重复下载。`--workloads-base-url` 与 `--offline` 不能同时使用。

也可通过环境变量为 Bundle 准备过程指定制品源：

```bash
WORKLOADS_BASE_URL=http://artifacts.internal/cloud-hypervisor \
  ./hypervisor/scripts/dev_cli.sh --prepare-offline-bundle
```

## 使用本地 x86_64 制品

在 x86_64 Bundle 准备过程中，可以通过以下环境变量覆盖任意默认制品：

| 环境变量 | Bundle 中的文件名 |
|---|---|
| `CH_X86_HYPERVISOR_FW_FILE` | `hypervisor-fw` |
| `CH_X86_CLOUDHV_FD_FILE` | `CLOUDHV.fd` |
| `CH_X86_BIONIC_QCOW2_FILE` | `bionic-server-cloudimg-amd64.qcow2` |
| `CH_X86_FOCAL_QCOW2_FILE` | `focal-server-cloudimg-amd64-custom-20210609-0.qcow2` |
| `CH_X86_JAMMY_QCOW2_FILE` | `jammy-server-cloudimg-amd64-custom-20220329-0.qcow2` |
| `CH_X86_ALPINE_MINIROOTFS_FILE` | `alpine-minirootfs-x86_64.tar.gz` |
| `CH_X86_VMLINUX_FILE` | `vmlinux` |
| `CH_X86_VIRTIOFSD_FILE` | `virtiofsd` |

变量值必须是可读普通文件的绝对路径。可以只设置需要覆盖的项：

```bash
CH_X86_HYPERVISOR_FW_FILE=/srv/artifacts/hypervisor-fw \
CH_X86_CLOUDHV_FD_FILE=/srv/artifacts/CLOUDHV.fd \
CH_X86_VMLINUX_FILE=/srv/artifacts/vmlinux \
  ./hypervisor/scripts/dev_cli.sh --prepare-offline-bundle
```

本地文件优先于 `CH_WORKLOADS_DIR` 中的旧文件、内网制品源和公网下载。替换 qcow2 或 Alpine minirootfs 时，准备流程会删除并重新生成相应 raw/initramfs。

自定义文件允许与仓库内置 SHA-1 不同；只有明确覆盖的输入及其派生文件跳过旧 SHA-1。最终实际内容仍包含在 Bundle 的 `SHA256SUMS` 中。自定义文件属于可信执行输入，SHA-256 只能验证 Bundle 创建后的传输完整性，不能证明制品来源可信。

## 使用本地 aarch64 制品

在原生 aarch64 主机准备 Bundle 时支持以下覆盖：

| 环境变量 | Bundle 中的文件名 |
|---|---|
| `CH_BIONIC_ARM64_QCOW2_FILE` | `bionic-server-cloudimg-arm64.qcow2` |
| `CH_FOCAL_ARM64_QCOW2_FILE` | `focal-server-cloudimg-arm64-custom-20210929-0.qcow2` |
| `CH_JAMMY_ARM64_QCOW2_FILE` | `jammy-server-cloudimg-arm64-custom-20220329-0.qcow2` |
| `CH_ALPINE_ARM64_MINIROOTFS_FILE` | `alpine-minirootfs-aarch64.tar.gz` |
| `CH_CLOUD_HYPERVISOR_STATIC_ARM64_FILE` | `cloud-hypervisor-static-aarch64` |

例如：

```bash
CH_BIONIC_ARM64_QCOW2_FILE=/srv/artifacts/bionic-server-cloudimg-arm64.qcow2 \
CH_FOCAL_ARM64_QCOW2_FILE=/srv/artifacts/focal-server-cloudimg-arm64-custom-20210929-0.qcow2 \
CH_CLOUD_HYPERVISOR_STATIC_ARM64_FILE=/srv/artifacts/cloud-hypervisor-static-aarch64 \
  ./hypervisor/scripts/dev_cli.sh --prepare-offline-bundle
```

替换 qcow2 会重新生成对应 raw，替换 Focal qcow2 还会重新生成 update-kernel raw；替换 Alpine minirootfs 会重新生成 initramfs。与 x86_64 相同，只有显式覆盖项跳过仓库旧 SHA-1，Bundle 内实际字节仍由 `SHA256SUMS` 覆盖。

## 自定义源码和 workloads 目录

宿主机路径可通过绝对路径环境变量配置：

```bash
CUBESANDBOX_DIR=/srv/CubeSandbox
CH_WORKLOADS_DIR=/srv/cloud-hypervisor-workloads
```

`CUBESANDBOX_DIR` 默认为当前 `dev_cli.sh` 所在的 CubeSandbox 根目录；`CH_WORKLOADS_DIR` 默认为 `$HOME/workloads`。这些变量适用于 Bundle 准备和测试执行，容器内仍分别挂载到 `/cloud-hypervisor` 与 `/root/workloads`。

## 配置开发容器 OCI 镜像

默认使用 `ghcr.io/cloud-hypervisor/cloud-hypervisor:20240507-0`。可通过环境变量指定内部 Registry 或其他兼容镜像：

```bash
export CH_DEV_IMAGE=registry.internal/cloud-hypervisor/dev:20240507-0
```

该变量适用于容器构建、测试和 Bundle 准备。显式传入 `--local` 时使用仓库默认的 `ghcr.io/cloud-hypervisor/cloud-hypervisor:local`，优先于该变量。Bundle 只在 `MANIFEST` 中记录镜像引用，不包含镜像 tar；运行离线测试前，必须通过内部 Registry 或独立介质使同一镜像在测试机本地可用。

## 在联网机器准备离线 Bundle

在仓库根目录执行：

```bash
CH_DEV_IMAGE=registry.internal/cloud-hypervisor/dev:20240507-0 \
  ./hypervisor/scripts/dev_cli.sh --prepare-offline-bundle
```

该命令会：

1. 获取或确认开发容器镜像；
2. 下载 integration 和 live migration 所需 workloads；
3. 转换磁盘镜像并生成测试辅助文件；
4. 编译 release 二进制及测试二进制，但不执行测试；
5. 收集当前 CubeSandbox 工作树、workloads、Cargo 缓存和编译产物；
6. 记录 OCI 镜像引用，并在当前目录生成与本机架构匹配的归档：

```text
cloud-hypervisor-offline-<short-commit>-x86_64.tgz
cloud-hypervisor-offline-<short-commit>-aarch64.tgz
```

两个 Bundle 需分别生成：

```text
联网 x86_64 物理机  -> x86_64 Bundle  -> 离线 x86_64 物理机
联网 aarch64 物理机 -> aarch64 Bundle -> 离线 aarch64 物理机
```

Bundle 不可跨架构使用，也不支持通过 QEMU 或 buildx 在单台机器上同时生成两个架构的内容。

Bundle 包含：

```text
MANIFEST
SHA256SUMS
workloads/
CubeSandbox/                      # 当前已跟踪及未忽略的未跟踪源码
CubeSandbox/hypervisor/build/cargo_registry/
CubeSandbox/hypervisor/build/cargo_git_registry/
CubeSandbox/hypervisor/build/cargo_target/
CubeSandbox/hypervisor/target/    # 存在时包含
```

Bundle 只保留可传输的规范输入：Alpine 仅保留 `alpine-minirootfs-*.tar.gz`，Bionic、Focal 和 Jammy 仅保留 qcow2。`alpine_initramfs.img`、解压目录、raw/img 镜像、ARM update-kernel raw 及 `vfio/` 副本不会进入 Bundle；离线测试启动时会从 tar.gz/qcow2 在本地重新生成这些运行时文件。raw 文件仍用于测试隔离副本、VFIO 嵌套虚机和 ARM 内核注入，但无需重复传输。

`MANIFEST` 记录源码提交、工作树是否有未提交修改、架构、创建时间、容器镜像、自定义 x86/aarch64 制品名及归档目录。源码通过 Git 的已跟踪文件和未忽略的未跟踪文件清单复制；任何层级的 `.git` 元数据、ignored 构建产物、`*.dev_cli.log.txt` 及旧 Bundle 不会进入归档，所需 Cargo 缓存会单独加入。

记录归档自身的校验值，以便传输后验证：

```bash
ARCH=$(uname -m)
sha256sum cloud-hypervisor-offline-*-${ARCH}.tgz \
  > cloud-hypervisor-offline.sha256
```

将 `.tgz` 和校验文件传输到离线测试机。Bundle 已包含生成时的当前源码工作树。

## 在离线机器恢复 Bundle

以下命令假设 Bundle 位于 `$HOME/offline-bundle/`。源码、workloads 和 Cargo 缓存均已在 Bundle 内。

### 1. 验证并解压归档

```bash
cd "$HOME/offline-bundle"
sha256sum --check cloud-hypervisor-offline.sha256

mkdir extracted
ARCH=$(uname -m)
BUNDLE=$(find . -maxdepth 1 \
  -name "cloud-hypervisor-offline-*-${ARCH}.tgz" \
  -print -quit)
tar -xzf "$BUNDLE" -C extracted
cd extracted
sha256sum --check SHA256SUMS
```

### 2. 检查架构与元数据

```bash
grep -E '^(source_commit|source_dirty|architecture|container_image|custom_(x86|aarch64)_artifacts)=' MANIFEST
test "$(grep '^architecture=' MANIFEST | cut -d= -f2-)" = "$(uname -m)"
```

`CubeSandbox/` 已包含生成 Bundle 时的当前工作树，包括已跟踪文件的未提交修改及未忽略的未跟踪源码。

### 3. 准备开发镜像

从可访问的内部 OCI Registry 拉取 `MANIFEST` 记录的镜像，或通过独立介质导入同名镜像：

```bash
IMAGE=$(grep '^container_image=' MANIFEST | cut -d= -f2-)
docker pull "$IMAGE"
docker image inspect "$IMAGE" >/dev/null
export CH_DEV_IMAGE="$IMAGE"
```

完全隔离环境不能执行 `docker pull`，需要在联网机器另行 `docker save`，传输后执行 `docker load`。镜像归档不属于 Bundle。

## 完全离线运行测试

在 Bundle 解压目录中设置镜像、源码和 workloads：

```bash
export CH_DEV_IMAGE="$(grep '^container_image=' MANIFEST | cut -d= -f2-)"
export CUBESANDBOX_DIR="$PWD/CubeSandbox"
export CH_WORKLOADS_DIR="$PWD/workloads"
```

也可以将这两个目录移动到任意位置，再将变量改为对应绝对路径。

先运行核心 smoke tests，可按机器资源设置并行度：

```bash
./CubeSandbox/hypervisor/scripts/dev_cli.sh tests \
  --integration \
  --quick \
  --test-threads 8 \
  --offline
```

运行全部普通 integration tests：

```bash
./CubeSandbox/hypervisor/scripts/dev_cli.sh tests \
  --integration \
  --test-threads 16 \
  --offline
```

运行 live migration tests：

```bash
./CubeSandbox/hypervisor/scripts/dev_cli.sh tests \
  --integration-live-migration \
  --test-threads 4 \
  --offline
```

也可通过 `CH_TEST_THREADS` 设置默认值；命令行 `--test-threads` 优先。未设置时保持原有默认策略。该值只影响 parallel 和 quick 的可并行分组，sequential、兼容性及 lib-mode 分组始终使用一个线程。

在 aarch64 上，普通 `--integration` 已包含 common、ACPI 和 live migration 测试；`--integration-live-migration` 只运行 ARM 的 parallel 与 sequential live migration 模块。

`--offline` 会强制：

- 仅使用本地开发容器镜像，不执行 pull；
- 仅使用 `CH_WORKLOADS_DIR` 中已有的制品，不回退到公网下载；
- 设置 `CARGO_NET_OFFLINE=true`，禁止 Cargo 联网获取依赖。

## 故障排查

### Development image is not available locally

`CH_DEV_IMAGE` 指定的镜像在本地不存在。通过可访问的 Registry 拉取，或从独立传输的镜像归档导入：

```bash
docker pull "$CH_DEV_IMAGE"
# 或：docker load -i /path/to/cloud-hypervisor-dev-image.tar
```

### Offline workloads missing

`CH_WORKLOADS_DIR` 中缺少测试所需文件。确认它指向 Bundle 解压得到的 `workloads/`，或重新设置绝对路径：

```bash
export CH_WORKLOADS_DIR=/path/to/extracted/workloads
```

不要在 `--offline` 模式下临时指定 workload URL。

### Cargo 离线解析或编译失败

确认 `CUBESANDBOX_DIR` 指向 Bundle 中的源码根目录，并包含：

```text
CubeSandbox/hypervisor/build/cargo_registry
CubeSandbox/hypervisor/build/cargo_git_registry
CubeSandbox/hypervisor/build/cargo_target
CubeSandbox/hypervisor/target
```

依赖或源码发生变化后，应在联网机器重新生成 Bundle。

### 无法访问 KVM

检查设备及权限：

```bash
ls -l /dev/kvm
test -r /dev/kvm && test -w /dev/kvm
```

测试机还需支持 nested virtualization（如测试场景要求），并允许 Docker 启动特权容器。aarch64 Bundle 必须在联网 aarch64 物理机上准备，并在具备 ARM KVM 支持的离线 aarch64 物理机上运行。

### 磁盘空间或 hugepages 不足

Bundle、展开内容、Docker 镜像和测试生成文件会同时占用较大空间。完整测试还会配置 KSM 和 hugepages；请在专用测试机上预留足够内存和磁盘空间。

## 回归验证

修改离线配置逻辑后，可运行聚焦的 Shell 回归测试：

```bash
bash -n hypervisor/scripts/dev_cli.sh \
  hypervisor/scripts/test-util.sh \
  hypervisor/scripts/run_integration_tests_x86_64.sh \
  hypervisor/scripts/run_integration_tests_live_migration.sh \
  hypervisor/scripts/test_offline_config.sh

bash hypervisor/scripts/test_offline_config.sh
git diff --check
```
