# Fedora 宿主机集成测试

本文档记录无法在嵌套开发容器内运行的测试。在目标 Fedora 宿主机上以 rootless Podman
执行。测试后在相关小节记录日期、Podman 版本、架构和结果。

## 开发镜像与初始 Nix 卷

状态：镜像构建、空卷初始化、profile 安装、重复启动、认证、挂载行为和正常启动下的
更新器稳定性已验证。

这些步骤验证初始 `Containerfile`、digest 钉死的基础镜像、`/nix` named volume 复制行为
和两个 CLI profile 的真实安装。它们使用临时 Home 状态根，但使用固定的开发卷
`secli-nix-v1`。

### 前置条件

在 Fedora 宿主机的 secli 仓库中运行：

```bash
cd /data/projects/hinnyuu/secli
podman --version
podman info --format '{{.Host.Security.Rootless}}'
getenforce
git status --short --branch
```

预期：

- Podman 至少 `5.8.4`。
- rootless 值为 `true`。
- SELinux 最好为 `Enforcing`。
- 工作区只包含预期的未提交 Containerfile 阶段变更。

检查固定测试卷是否已存在：

```bash
podman volume exists secli-nix-v1; printf 'volume-exists=%s\n' "$?"
```

退出码 `0` 表示已存在。若其他 secli 部署正在使用该卷，不要删除。仅在本次初始测试中、
确认其中没有需要的缓存或 profile 后才删除：

```bash
podman volume rm secli-nix-v1
```

若卷不存在，Podman 报告未找到；继续。

### 构建

```bash
podman build \
  --build-arg SECLI_VERSION="$(<VERSION)" \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  --tag localhost/secli:dev \
  --file Containerfile \
  .
```

预期：使用 digest 钉死的 `nixos/nix:2.35.1` 基底，git 和 ripgrep 经钉死的 nixpkgs
commit 安装，构建全程不使用系统包管理器。

检查镜像：

```bash
podman image inspect localhost/secli:dev \
  --format 'entrypoint={{json .Config.Entrypoint}} version={{index .Labels "org.opencontainers.image.version"}}'
podman run --rm --entrypoint /nix/var/nix/profiles/secli-base/bin/git \
  localhost/secli:dev --version
podman run --rm --entrypoint /nix/var/nix/profiles/secli-base/bin/rg \
  localhost/secli:dev --version
```

预期：

- entrypoint 为 `["/entrypoint.sh"]`；
- 已发布镜像的版本为 `v0.2.1`；
- git 和 ripgrep 正常输出版本。

### 空卷与真实 CLI profile

```bash
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-host-test-state
./secli.sh init all
./secli.sh opencode -- --version
./secli.sh qoder-cli-cn -- --version
```

首次使用的预期：

- Podman 从镜像的 `/nix` 树创建并初始化 `secli-nix-v1`。
- OpenCode 安装进 `secli-opencode` profile，报告 `1.18.18`。
- Qoder CN 安装进 `secli-qoder-cli-cn` profile，报告 `1.1.25`。
- 两条命令成功退出，固定容器在每次运行后被移除。

不启动 CLI 检查产出的 profile 和 stamp：

```bash
podman run --rm \
  --entrypoint /nix/var/nix/profiles/default/bin/bash \
  --volume secli-nix-v1:/nix:rw \
  localhost/secli:dev \
  -c 'set -eu; ls -l /nix/var/nix/profiles/per-user/root/secli-*; cat /nix/var/lib/secli/opencode.stamp; cat /nix/var/lib/secli/qoder-cli-cn.stamp'
```

预期：两个 profile 链接存在，两个 stamp 包含同一个钉死的 llm-agents.nix commit，
分别带 `#opencode` 和 `#qoder-cli-cn` 输出。

第二次运行各版本命令：

```bash
./secli.sh opencode -- --version
./secli.sh qoder-cli-cn -- --version
```

预期：两次运行都不输出 profile 对账信息；都复用已安装的 profile。

### 清理

保存好诊断失败所需的全部输出后：

```bash
unset SECLI_IMAGE SECLI_STATE_DIR
rm -rf /tmp/secli-host-test-state
podman volume rm secli-nix-v1
podman image rm localhost/secli:dev
```

清理只移除测试 Home 数据、可重建的 Nix 卷和本地开发镜像。不要删除其他 secli 部署
正在使用的卷。

### 结果

宿主机测试后在此记录结果：

```text
日期：2026-08-19
宿主机架构：Fedora 宿主机，amd64
Podman 版本：已验证 >= 5.8.4
SELinux 模式：已验证符合预期配置
镜像构建：通过；`nix profile add` 的后续构建在无先前 alias 警告的情况下完成
空 /nix 卷初始化：通过
OpenCode profile/版本：通过，`1.18.18`
Qoder CN profile/版本：通过，`1.1.25`
第二次启动 noop：两个 CLI 均通过
镜像 entrypoint 和 labels：通过；镜像 digest `sha256:23c783aa66d3791c70dc976731cb16bb634ffe0488f0112a65b7bb98215748db`
基础工具：通过；git `2.55.0`，ripgrep `15.2.0`
非交互首次安装：提交 `8bd588a` 之后通过；未出现 flake-config 信任提示
备注：宿主机清理完成。清空全新 profile 时输出的预期警告 "There are no packages in the profile" 非致命。
```

## 挂载与端口矩阵

状态：项目与数据集访问已验证；端口映射已在 Fedora 验证；探针测试后已移除。

这些检查使用一个临时的受信任本地 manifest，运行 Nix 的 Bash 而非 AI CLI。不使用
凭据。在 secli 部署中创建探针资源：

```bash
cd /data/projects/hinnyuu/secli
mkdir -p manifest.local templates/probe
cat >manifest.local/probe.conf <<'EOF'
CLI_ID=probe
BIN=bash
INSTALL_REF="github:NixOS/nixpkgs/ec2d622de0773551768cf98f3fc50cbcc003b9c5#bash"
RUNTIME_ENV=()
EOF
cat >templates/probe/probe.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode=$1
project=$2
dataset=$3
test "$(<"$project/project.txt")" = project
test "$(<"$dataset/data.txt")" = dataset
case $mode in
  read)
    ;;
  project-write)
    printf 'write-ok\n' >"$project/probe-write.txt"
    ;;
  dataset-write)
    printf 'must-fail\n' >"$dataset/probe-write.txt"
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x templates/probe/probe.sh
```

准备独立的项目和数据集目录：

```bash
mkdir -p /tmp/secli-matrix-project /tmp/secli-matrix-dataset
printf 'project\n' >/tmp/secli-matrix-project/project.txt
printf 'dataset\n' >/tmp/secli-matrix-dataset/data.txt
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-matrix-state
./secli.sh init probe
```

验证两个挂载可读且项目可写：

```bash
cd /tmp/secli-matrix-project
SECLI_ALLOWED_PROJECT_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe \
  --dataset /tmp/secli-matrix-dataset \
  -- /root/probe.sh read /tmp/secli-matrix-project /tmp/secli-matrix-dataset
SECLI_ALLOWED_PROJECT_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe \
  --dataset /tmp/secli-matrix-dataset \
  -- /root/probe.sh project-write /tmp/secli-matrix-project /tmp/secli-matrix-dataset
test "$(<probe-write.txt)" = write-ok
```

验证数据集写入被拒绝。该命令必须非零退出且文件不得存在：

```bash
if SECLI_ALLOWED_PROJECT_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe \
  --dataset /tmp/secli-matrix-dataset \
  -- /root/probe.sh dataset-write /tmp/secli-matrix-project /tmp/secli-matrix-dataset; then
  printf 'ERROR: read-only dataset write unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -e /tmp/secli-matrix-dataset/probe-write.txt
```

在容器存活期间验证发布的地址。从同一项目目录运行：

```bash
SECLI_ALLOWED_PROJECT_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe -p 4097 -- -c 'sleep 30' \
  </dev/null >/tmp/secli-port-4097.log 2>&1 &
secli_pid=$!
sleep 2
podman port secli 4097/tcp
kill "$secli_pid" 2>/dev/null || true
wait "$secli_pid" 2>/dev/null || true
```

预期映射：`127.0.0.1:4097`。仅在有意时才重复显式对外暴露：

```bash
SECLI_ALLOWED_PROJECT_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe -p 0.0.0.0:4098:4098 -- -c 'sleep 30' \
  </dev/null >/tmp/secli-port-4098.log 2>&1 &
secli_pid=$!
sleep 2
podman port secli 4098/tcp
kill "$secli_pid" 2>/dev/null || true
wait "$secli_pid" 2>/dev/null || true
```

预期映射：`0.0.0.0:4098`。

2026-08-19 宿主机测试实测：

- 项目读写探针通过。
- 数据集读取探针通过，数据集写入以 `Read-only file system` 失败。
- `-p 4097` 发布为 `127.0.0.1:4097`。
- `-p 0.0.0.0:4098:4098` 发布为 `0.0.0.0:4098`。
- 首次尝试继承了交互终端并被 shell 作业控制停止；上述命令现在重定向 stdin/stdout
  以保证后台测试可靠。

清理：

```bash
podman rm -f secli 2>/dev/null || true
rm -f /tmp/secli-port-4097.log /tmp/secli-port-4098.log
rm -rf /data/projects/hinnyuu/secli/manifest.local/probe.conf \
  /data/projects/hinnyuu/secli/templates/probe \
  /tmp/secli-matrix-project /tmp/secli-matrix-dataset /tmp/secli-matrix-state
unset SECLI_IMAGE SECLI_STATE_DIR
```

## CLI 认证持久化

状态：认证持久化、两种端口形式和正常启动下的更新器稳定性已验证。

不要把凭据、token 或登录 URL 粘贴进项目文件、测试日志或 issue 报告。使用专用临时
状态根，一次测试一个 CLI：

```bash
cd /data/projects/tests/test_proj_04
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-auth-state
/data/projects/hinnyuu/secli/secli.sh init opencode
/data/projects/hinnyuu/secli/secli.sh opencode
```

完成 OpenCode 的原生 `/connect` 流程，正常退出，重新启动并验证仍保持认证。对
Qoder CN 重复：

```bash
/data/projects/hinnyuu/secli/secli.sh init qoder-cli-cn
/data/projects/hinnyuu/secli/secli.sh qoder-cli-cn
```

使用 Qoder 的原生 `/login` 流程。在无头容器中它应输出一个 URL，供浏览器手动完成。
不要把 `QODERCN_PERSONAL_ACCESS_TOKEN` 放入 manifest 或模板；secli 不会隐式把宿主机
环境变量转发进容器。

每个 CLI 成功重启后，只检查相对文件名，不检查内容：

```bash
find /tmp/secli-auth-state/opencode/home -maxdepth 4 -type f -printf '%P\n' | sort
find /tmp/secli-auth-state/qoder-cli-cn/home -maxdepth 4 -type f -printf '%P\n' | sort
```

预期：状态保留在对应 CLI 的 Home 中，不出现在另一个 CLI 的 Home 中。仅在确认其登录
状态不再需要后才删除临时状态：

```bash
unset SECLI_IMAGE SECLI_STATE_DIR
rm -rf /tmp/secli-auth-state
```

2026-08-19 宿主机测试实测：

- OpenCode 认证、会话和提供商状态在重启后保留在其 Home 下。
- Qoder CN 认证和会话在重启后保留在其 Home 下。
- Qoder CN 在 `.qoder-cn/.auth/`、`.qoder-cn/.bin/`、`.qoder-cn/entry/`、
  `.qoder-cn/projects/` 和 `.qodersec/` 下创建了原生运行时文件。这些是预期的 Home
  状态，不是 secli 管理的路径。
- 没有凭据被放入 manifest、模板或 `/nix`。

## 宿主机启动器配置文件

状态：白名单覆盖、环境变量优先级、状态根重定向和非法键拒绝已验证。

这些步骤验证 `v0.2.0` 新增的 `config/secli.conf` 宿主机配置文件：查找、对内置
默认值的优先级、环境变量覆盖和非法内容拒绝。使用固定开发镜像和临时状态根，不需要
凭据。

### 前置条件

在已构建 `localhost/secli:dev` 的 Fedora 宿主机上，从 secli 仓库运行：

```bash
cd /data/projects/hinnyuu/secli
podman image exists localhost/secli:dev; printf 'image-exists=%s\n' "$?"
test ! -e config/secli.conf || { printf 'move aside your real config first\n'; exit 1; }
```

### 白名单覆盖与环境变量优先级

写入一个只允许临时项目目录的配置文件：

```bash
mkdir -p /tmp/secli-config-project
printf 'project\n' >/tmp/secli-config-project/project.txt
cat >config/secli.conf <<'EOF'
SECLI_ALLOWED_PROJECT_PREFIXES=/tmp/secli-config-project
SECLI_IMAGE=localhost/secli:dev
SECLI_STATE_DIR=/tmp/secli-config-state
EOF
./secli.sh init opencode
```

预期：`init` 在 `/tmp/secli-config-state` 下创建 OpenCode Home，而不是仓库的
`state/` 目录。

不导出任何变量，从白名单内的项目启动：

```bash
cd /tmp/secli-config-project
/data/projects/hinnyuu/secli/secli.sh opencode -- --version
```

预期：使用配置的镜像和状态根成功运行。

确认环境变量覆盖配置文件。一旦环境变量接管，仅配置文件允许的项目必须被拒绝：

```bash
SECLI_ALLOWED_PROJECT_PREFIXES=/tmp/elsewhere \
  /data/projects/hinnyuu/secli/secli.sh opencode -- --version
```

预期：非零退出；错误信息指出白名单来源为环境变量。

### 非法内容拒绝

```bash
printf 'SECLI_BOGUS=1\n' >config/secli.conf
/data/projects/hinnyuu/secli/secli.sh list
```

预期：非零退出；错误报告文件路径、行号和支持键清单。

### 清理

```bash
cd /data/projects/hinnyuu/secli
rm -f config/secli.conf
rm -rf /tmp/secli-config-project /tmp/secli-config-state
```

### 结果

宿主机测试后在此记录结果：

```text
日期：2026-08-20
宿主机架构：Fedora 宿主机，amd64
Podman 版本：已验证 >= 5.8.4
配置白名单覆盖：通过
环境变量优先于配置：通过
配置状态根重定向：通过
非法键拒绝：通过
备注：宿主机清理完成。测试时键名仍为 SECLI_ALLOWED_PREFIXES；它在同一 v0.2.0
发布周期内更名为 SECLI_ALLOWED_PROJECT_PREFIXES。
```

## v0.2.0 启动器从零验证

状态：完全清理、镜像重建和空卷重启后在 Fedora amd64 通过。

本次运行验证白名单键更名为 `SECLI_ALLOWED_PROJECT_PREFIXES`、默认值收窄为
`/data/projects` 之后的启动器。宿主机先被完全清理：移除 `secli` 容器、
`secli-nix-v1`、`localhost/secli:dev`、仓库的 `state/`、`manifest.local/`、
`config/secli.conf` 和所有 `/tmp/secli-*` 测试目录，然后从合并后的 `main` 重建镜像，
以下每一步都从空卷开始。

2026-08-20 验证：

- 从 Containerfile 重建镜像和空 `secli-nix-v1` 初始化通过。
- OpenCode `1.18.18` 和 Qoder CN `1.1.25` 从干净卷安装成功。
- 内置默认白名单下从 `/data/projects` 启动成功。
- 从 `/tmp` 启动被拒绝，报告的来源为内置默认。
- `config/secli.conf` 配置 `SECLI_ALLOWED_PROJECT_PREFIXES=/data/projects:/tmp` 后
  允许 `/tmp` 项目；旧键名 `SECLI_ALLOWED_PREFIXES` 被作为未知键拒绝。
- 环境变量覆盖了配置文件的白名单。
- 白名单保持 `/data/projects` 时 `/tmp` 下的数据集挂载成功，确认数据集挂载独立于
  项目白名单。

## v0.2.1 模板验证

状态：在 Fedora amd64 上以临时状态根通过。

2026-08-21 验证：

- `secli.sh init all` 成功创建两个全新 CLI Home。
- OpenCode 与 Qoder CLI CN 的 Home `AGENTS.md` 均与仓库模板逐字节一致。
- 两个模板均包含对应 CLI 由运行环境统一提供的规则，以及敏感性不明时询问用户的规则。
- OpenCode `1.18.18` 与 Qoder CN `1.1.25` 均在新 Home 下正常输出版本。
- 临时状态根 `/tmp/secli-v021-template-state` 已清理。

## 最终发布验证

状态：在 Fedora amd64 上以干净 CLI 状态根和新建 `secli-nix-v1` 通过。

最终 `v0.1.0` 发布从合并后的 `main` 重建。干净的 `/tmp/secli-rc-state` 用
`secli.sh init all` 初始化；两个配置文件在首次启动前与仓库模板一致。首次 profile
安装报告 OpenCode `1.18.18` 和 Qoder CN `1.1.25`，重复版本检查为 noop。

OpenCode 解析出 `autoupdate: false` 和 `share: disabled`，模板保持不变，正常交互会话
后未更改更新器二进制候选。Qoder 显示 `Enable Auto Update false`，重复启动后保留更新
关闭和 YOLO 禁用设置，首次运行初始化后原生 entry/运行时文件保持字节稳定。两个运行
进程都解析到各自的 Nix store/profile 路径，而非 Home 副本。

所有发布步骤完成，全程无自动更新、替换二进制或基于 Home 的替代启动路径。
