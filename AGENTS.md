# secli 项目级 AGENTS.md

> 本文件是本项目对所有 LLM 协作者的唯一权威实现规格。
> 开始任何工作前必须完整阅读本文件；README 面向用户，本文件优先描述内部契约、
> 安全边界和已定案的技术选择。除非明确说明，所有路径均相对仓库根目录，脚本和
> 文档不得硬编码仓库的绝对路径。

---

## 1. 当前状态

本仓库目前处于**架构定案、正在实现**阶段。README 中的命令描述目标接口；在对应脚本、
镜像和首发 manifest 完成前，尚未完成的命令仍不能运行。

实现阶段必须先创建 `flake.nix` 与 `flake.lock`，并通过 `nix develop` 进入开发环境；
`flake.lock` 属于必须提交的交付文件。当前允许初始化本地 Git 仓库、创建本地分支和提交，
提交信息使用 Conventional Commits。

当前环境不配置 Git remote，不执行 `git remote add`、push、PR、Release 或其他 GitHub
操作。需要提交到 GitHub 时，由用户在宿主机执行相应命令。

---

## 2. 项目定位

**secli**（Secure Enhanced CLI）是
[hinnyuu/opencode](https://github.com/hinnyuu/opencode) 工作流的泛化：使用
Fedora 宿主机上的 rootless Podman 与容器内 Nix，为多个 AI coding CLI 提供统一、
可重建的安全运行环境。首批目标是 opencode 与 qoder-cli-cn，未来可增加 Codex、
Gemini CLI 等。

核心目标：

1. **保护宿主机**：AI CLI 只直接接触显式挂载的项目、数据集和当前 CLI Home。
2. **CLI 原生策略**：每个 CLI 使用自己的权限、配置和行为规则格式，不做跨 CLI
   权限语义抽象。
3. **Nix-only**：容器内软件的唯一安装路径是 Nix；禁止系统包管理器、官方安装脚本、
   `curl | bash` 和 CLI 自更新器成为软件版本来源。
4. **状态可重建**：用户状态与 Nix 软件缓存分离；容器可随时删除并重建。
5. **扩展简单**：在通用契约范围内，新增 CLI 只增加 manifest、Home 镜像模板和文档，
   不修改启动器或 entrypoint。

本项目不试图防御当前 AI CLI 读取用户显式挂载的项目内容。容器内进程以 root 运行，
但 rootless Podman 将容器 root 映射为宿主机普通用户；容器隔离缩小宿主机上的影响
范围，不应被描述成完美沙箱。

---

## 3. 环境事实与硬约束

- 开发环境本身位于隔离容器中：root 用户、无 sudo、无嵌套 Docker/Podman daemon。
- 所有项目级运行时和开发工具由项目 `flake.nix` 提供；禁止 apt、dnf、yum、apk、
  pacman 或 `nix-env` 全局安装项目工具。
- 开发命令统一经 `nix develop` 执行。
- 目标宿主机是 Fedora、rootless Podman >= 5.8.4，推荐启用 SELinux。
- 完整 Podman 集成测试无法在当前开发容器运行，必须输出可复现的 Fedora 宿主机测试
  步骤，由用户人工执行并反馈结果。
- 容器内 AI CLI 只能通过 `nix profile add <pinned-flake-ref>` 安装。
- 本项目不在镜像中分发 AI CLI，避免 unfree 二进制再分发问题。
- 实现 manifest 前允许并要求对公开上游做只读网络研究，包括读取源码、包定义和官方
  文档，以及下载或构建已固定的 Nix 包；不得上传项目数据、索取凭据或在当前容器登录
  GitHub/GHCR。

---

## 4. 总体架构

secli 分为四个职责边界。

### 4.1 宿主机控制面：`secli.sh`

`secli.sh` 是唯一用户入口，负责：

- 从自身路径推导仓库/部署根目录；
- 解析 secli 参数，并在 `--` 后原样保留 CLI 参数；
- 查找并校验 CLI manifest；
- 解析和校验当前项目、数据集、端口、GPU 等挂载参数；
- 创建当前 CLI 的宿主机 Home，设置权限；
- 选择与仓库版本匹配的不可变镜像标签；
- 组装并执行 `podman run`。

### 4.2 静态运行镜像

镜像名为 `ghcr.io/hinnyuu/secli`，由 `Containerfile` 定义并由 CI 构建。镜像包含：

- 固定 digest 的 Nix 基础镜像；
- 启用 `nix-command` 与 flakes；
- 经 Nix 安装的基础 git 与 ripgrep；
- `entrypoint.sh`。

镜像不得包含任何 AI CLI、manifest、用户模板或用户状态。CLI pin 更新不应触发镜像
重建。

### 4.3 容器数据面：`entrypoint.sh`

entrypoint 负责：

1. 初始化空 Home 中运行所需的基础目录，但不隐式复制推荐模板；
2. 根据 `SECLI_CLI` 加载并再次校验 manifest；
3. 导出 manifest 声明的 `RUNTIME_ENV`，使最终 CLI 及其子进程继承；
4. 在共享 `/nix` 中对当前 CLI 的独立 Nix profile 和 stamp 做幂等对账；
5. 将该 profile 的 `bin` 放在 PATH 最前；
6. `exec` CLI，使其接管信号、TTY 和退出码。

由于 `/root` 被当前 CLI 的宿主机 Home 完整覆盖，entrypoint 不得依赖镜像内预置的
`/root/.nix-profile`、channels 或其他 root dotfiles。基础 Nix 命令必须可从共享 `/nix`
中的默认 profile 或其他不依赖 `/root` 的固定路径启动。

### 4.4 两类持久状态

用户状态与软件状态严格分开：

| 状态 | 宿主机/卷位置 | 容器位置 | 可否重建 |
|---|---|---|---|
| 当前 CLI Home | `state/<cli>/home/` | `/root` | 否，含认证和会话 |
| Nix store/profile/cache | named volume `secli-nix-v<N>` | `/nix` | 是，可重新下载/构建 |

每个 CLI 持久化整个 `/root`，不枚举原生状态路径，不创建状态软链接。这样既覆盖不遵循
XDG 的 CLI，又让不同 CLI 无法看到彼此的认证状态。

---

## 5. Manifest 契约

### 5.1 文件位置和查找顺序

- 仓库支持列表：`manifest/<cli>.conf`。
- 用户私有定义：`manifest.local/<cli>.conf`，目录加入 `.gitignore`。
- 查找顺序：`manifest.local` 优先于 `manifest`，同名文件完整覆盖仓库定义。
- 容器内分别挂载到 `/opt/secli/manifest.local` 与 `/opt/secli/manifest`。
- `init` 和 `list` 是保留字，不能作为 CLI id。

Manifest 是 Bash 可 source 文件。仓库 manifest 与用户私有 manifest 都属于受信任代码；
source 它们等价于执行其中的 shell 代码。不要把 manifest 描述成可安全加载的不可信数据。

### 5.2 字段

```bash
# manifest/opencode.conf
CLI_ID=opencode
BIN=opencode
INSTALL_REF="github:numtide/llm-agents.nix/c4c6673c4c1ceb69d845fa665a714e1273d0acac#opencode"
RUNTIME_ENV=()
```

```bash
# manifest/qoder-cli-cn.conf
CLI_ID=qoder-cli-cn
BIN=qoderclicn
INSTALL_REF="github:numtide/llm-agents.nix/c4c6673c4c1ceb69d845fa665a714e1273d0acac#qoder-cli-cn"
RUNTIME_ENV=()
```

字段契约：

- `CLI_ID`：必须与文件名去掉 `.conf` 后完全相同。
- `BIN`：Nix 包的 `meta.mainProgram` 所指向的可执行文件名，可与 `CLI_ID` 不同。
- `INSTALL_REF`：完整 flake ref，必须钉死不可变的完整 commit，不得跟随 branch。
- `RUNTIME_ENV`：可选 Bash 数组，每项严格为 `NAME=value`；entrypoint 在执行 CLI 前导出。
  它描述本次进程的原生启动环境，只影响 CLI 及其子进程，不污染宿主机 shell；它不保存
  认证信息，也不属于 Nix profile。

加载后必须验证：

- CLI id 符合 `[a-z0-9][a-z0-9._-]*`，且不是保留字；
- `BIN` 是不含 `/` 的单个命令名；
- `INSTALL_REF` 非空且使用不可变 commit；
- 环境变量名符合 shell 标识符规则；
- 不允许字段通过路径穿越影响其他 CLI profile 或 Home。

两个首发 CLI 使用同一个 numtide/llm-agents.nix commit。当前已确认的 pin 为
`c4c6673c4c1ceb69d845fa665a714e1273d0acac`；OpenCode 包版本为 `1.18.18`，Qoder CN 包版本
为 `1.1.25`。Qoder CN 包的 `BIN` 是 `qoderclicn`。

### 5.3 扩展一个 CLI

在通用契约内新增 CLI 需要：

1. `manifest/<cli>.conf`；
2. `templates/<cli>/` Home 镜像；
3. `docs/clis/<cli>.md`，记录来源、版本、认证、原生配置、环境变量、更新行为和实测结果。

如果某 CLI 无法用 `BIN + INSTALL_REF + RUNTIME_ENV + Home` 表达，先记录真实限制，再讨论
扩展 manifest 契约；不要在启动器中按 CLI id 添加隐式特例。

---

## 6. Home 与模板

### 6.1 每 CLI 完整 Home

默认状态根是 `<BASE_DIR>/state`，其中：

```text
state/
├── opencode/home/       -> 启动 opencode 时挂到 /root
└── qoder-cli-cn/home/   -> 启动 Qoder 时挂到 /root
```

- `BASE_DIR` 必须由 `BASH_SOURCE[0]` 推导，仓库可移动。
- `SECLI_STATE_DIR` 可整体覆盖默认状态根。
- 状态根、CLI 目录和 Home 至少使用权限 `0700`。
- `state/` 必须加入 `.gitignore`，不得进入 Nix 产物或镜像。
- 不再使用共享 `secli-home` named volume。
- 不再维护 `STATE_DIRS`、`ensure_links`、状态 basename 映射或自动迁移逻辑。

### 6.2 模板镜像 Home

`templates/<cli>/` 的内容直接镜像 `/root` 下的相对路径。例如：

```text
templates/
├── opencode/
│   └── .config/opencode/
│       ├── opencode.jsonc
│       └── AGENTS.md
└── qoder-cli-cn/
    └── .qoder-cn/
        ├── settings.json
        └── AGENTS.md
```

`secli.sh init <cli|all>` 将对应模板树复制到 `state/<cli>/home/`：

- 只由显式 `init` 执行；普通启动不隐式初始化；
- 复制包括 dotfiles；
- 创建缺失父目录；
- 绝不覆盖已有文件；
- 已存在文件逐项提示 skipped，新文件逐项提示 created；
- 模板只是推荐起点，初始化后由用户自行管理。

行为规则按 CLI 原生路径分别保存，不强求单一共享 `templates/AGENTS.md`。内容可以相似，但
每个 CLI 模板应能独立演进，以适配其原生机制。

---

## 7. Nix profile 与版本对账

### 7.1 独立 profile，共享 store

每个 CLI 使用位于共享 `/nix` 中的唯一 profile：

```text
/nix/var/nix/profiles/per-user/root/secli-opencode
/nix/var/nix/profiles/per-user/root/secli-qoder-cli-cn
```

stamp 位于：

```text
/nix/var/lib/secli/opencode.stamp
/nix/var/lib/secli/qoder-cli-cn.stamp
```

profile 是可重建的软件安装状态，不放入 CLI Home。这样 Nix GC 始终能看到所有 CLI 的
profile，切换 `/root` 时也不会改变 GC root 的含义。

### 7.2 对账算法

对选定 CLI：

1. `<profile>/bin/<BIN>` 存在且 stamp 内容等于当前 `INSTALL_REF`：noop。
2. 二进制缺失或 stamp 不一致：记录旧 stamp，并确认当前 generation 的旧二进制是否
   可用。
3. 使用 `nix profile remove --all --profile <profile>` 创建内容为空的新 current
   generation；不得删除历史 generation，不得在安装成功前执行 `wipe-history`。
4. 使用 `nix --accept-flake-config profile add --profile <profile> "$INSTALL_REF"` 安装固定
   flake ref，避免受信任上游 flake 的配置提示阻塞非交互启动。
5. 安装成功且 `<profile>/bin/<BIN>` 可执行后，使用同目录临时文件加原子 rename 更新
   stamp。
6. 安装失败时保留旧 stamp；如果旧 generation 已确认可用，则尝试
   `nix profile rollback --profile <profile>`，并验证旧二进制恢复。
7. 无论回滚是否成功，本次启动都必须非零退出，不得静默运行与当前 manifest 不一致的
   旧 CLI，也不得启动未知或半安装状态的 CLI；下次启动重新尝试对账。
8. 不解析任何 CLI 的 `--version` 输出。

这里的“清空 profile”只表示清空 current generation，不表示删除 profile 目录或历史
generation。若 profile 首次安装或旧二进制本来就不可用，失败时可能没有可回滚对象；
这时仍保留 stamp 并非零退出。

启动 CLI 时使用 profile 中的绝对路径，或将 `<profile>/bin` 放在 PATH 最前后再解析
`BIN`。不得优先运行 CLI 自己下载到 `/root/.local/bin` 等位置的副本。

### 7.3 `/nix` 卷兼容 epoch

named volume 使用独立于项目版本的兼容 epoch：

```text
secli-nix-v1
secli-nix-v2
```

项目/镜像版本（如 `v0.1.0`）表示一次软件发布；Nix volume epoch（如 `v1`）只表示
持久 `/nix` 是否与镜像的基础 Nix 闭包、profile 布局和启动路径兼容。多个项目版本可
共享同一 epoch。

以下变化必须评估并通常提升 epoch：

- 基础 Nix 镜像 digest 或 Nix 主版本变化；
- 镜像中启动所需的 `/nix/store` 路径变化，旧卷未必包含它们；
- Nix 数据库、profile 或初始化布局不兼容；
- 从旧卷启动可能在 entrypoint 执行前失败。

Podman named volume 默认在首次挂载时把镜像目标目录内容复制到空卷。旧卷挂到新镜像时
不会再次复制，因此不得假设镜像升级会更新现有 `/nix`。提升 epoch 会创建并初始化新卷；
旧卷由用户确认后手动删除。

删除 `secli-nix-v<N>` 是安全恢复手段：会丢失 store、profiles、stamps 和构建缓存，但
不会删除各 CLI Home 或项目代码。下次启动重新安装 CLI，项目 flake 按 lock 重建。

---

## 8. 启动接口与参数契约

```text
secli.sh <cli> [secli 选项] [-- CLI 原生参数...]
secli.sh init <cli|all>
secli.sh list
secli.sh -h|--help
```

secli 选项：

- `--dataset <path>`：可重复，按同一绝对路径只读挂载。
- `-p|--port <spec>`：端口映射，见下文。
- `--nvidia`：启用 NVIDIA CDI。
- `-h|--help`：显示 secli 全局或当前 CLI 的包装器帮助。

参数规则：

- 第一个位置参数是 manifest 中存在的 CLI id，或保留子命令 `init`/`list`。
- `--` 终止 secli 解析，其后参数逐项原样传给 CLI。
- `--` 前的未知选项立即报错，不猜测、不隐式透传。
- CLI 自己的帮助使用 `secli.sh <cli> -- --help`。
- Qoder 的原生 `-p` 表示 prompt，而 secli 的 `-p` 表示端口；端口错误必须提示将 CLI
  原生参数置于 `--` 之后。

### 8.1 端口

只支持两种明确格式：

```text
-p 4096                    -> 127.0.0.1:4096:4096
-p 0.0.0.0:8080:4096      -> 0.0.0.0:8080:4096
```

即 `PORT` 或 `HOST_IPV4:HOST_PORT:CONTAINER_PORT`。默认只监听 loopback；对外暴露必须
显式写 `0.0.0.0`。v1 不支持省略字段、端口范围或 IPv6。所有端口必须是 1..65535。

### 8.2 当前项目与数据集

- 真正启动 CLI 时，调用者的当前工作目录就是项目目录；v1 不提供 `--project` 或其他
  显式项目路径参数。
- `secli.sh` 自身可以部署在任意位置，部署根只通过 `BASH_SOURCE[0]` 推导，不影响项目
  目录的选择。
- 当前工作目录必须先做物理路径规范化，再执行前缀白名单校验；校验失败立即拒绝启动，
  不猜测替代目录，也不自动扩大白名单。
- 默认允许 `/data/projects`、`/data/test`、`/data/dataset`。
- `SECLI_ALLOWED_PREFIXES` 以冒号分隔并整体覆盖默认值。
- 前缀匹配必须尊重路径边界，`/data/projects-evil` 不属于 `/data/projects`。
- 当前项目以同一绝对路径 `rw,z` 挂载，并作为容器工作目录。
- 数据集必须存在且规范化，以同一绝对路径 `ro,z` 挂载。
- `init`、`list` 和 secli 包装器 help 不启动 CLI，因此可以在白名单外执行，不得要求项目
  路径校验。CLI 原生 help `secli.sh <cli> -- --help` 会启动容器，仍按正常启动校验项目。

### 8.3 容器生命周期与终端

- 容器名固定为 `secli`，v1 全局只允许一个实例，不支持不同 CLI 并发。
- 使用 `--rm`，容器本身无状态。
- stdin 保持连接；仅当调用环境是 TTY 时分配 TTY，保证非交互命令可用于脚本。
- entrypoint 最终使用 `exec`，退出码和信号必须透明传递。
- 网络固定为 `slirp4netns:port_handler=slirp4netns`，不要改回已知有端口问题的 pasta。

---

## 9. 挂载拓扑与 SELinux

| 宿主机/卷 | 容器目标 | 属性 | 说明 |
|---|---|---|---|
| `state/<cli>/home` | `/root` | `rw,Z` | 当前 CLI 独占认证和状态 |
| `secli-nix-v<N>` | `/nix` | `rw` | 共享、可重建 Nix store |
| `manifest/` | `/opt/secli/manifest` | `ro,z` | 共享部署文件 |
| `manifest.local/`（若存在） | `/opt/secli/manifest.local` | `ro,z` | 私有覆盖 |
| `templates/` | `/opt/secli/templates` | `ro,z` | init/诊断可见 |
| 当前项目 | 同一绝对路径 | `rw,z` | CLI 工作区 |
| 数据集，每项 | 同一绝对路径 | `ro,z` | 显式只读输入 |

共享部署路径使用 `:z`，当前 CLI 独占 Home 使用 `:Z`。固定容器名已经禁止并发，但标签
选择仍应表达真实共享关系。`/root` 必须保持普通 bind mount，不使用 overlayfs，以便未来
增加逐文件只读硬化。

---

## 10. CLI 原生安全策略与自更新

- 每个 CLI 使用自己的原生配置格式；模板不承诺等价权限语义。
- 推荐配置由 `init` 写入且可由用户修改，不作为不可覆盖的强制策略。
- v1 不实现 `--ro-policy` 或 `--ro-agents`。
- 文档必须明确：项目目录对 CLI 可写，数据集只读，Home 只属于当前 CLI，`/nix` 在
  CLI 间共享但不应包含认证凭据。

`/nix` 必须可写，因为 CLI 在工作过程中需要运行 `nix develop`、构建 flake 或安装 Nix
管理的软件。不能通过只读 `/nix` 阻止 CLI 自更新。

自更新防线：

1. 在 CLI 原生模板中关闭 auto-update；opencode 使用 `autoupdate: false`。
2. Qoder 模板使用 `general.enableAutoUpdate: false` 和
   `security.disableYoloMode: true`；这两个字段已在 Qoder CN `1.1.25` 官方文档中确认。
3. 始终从 secli 专用 profile 启动，不优先使用 CLI 下载到 Home 的副本。
4. 每次启动按 `INSTALL_REF` 与 profile/stamp 对账。
5. 在 CLI 档案中记录其更新器是否仍下载文件、创建 shim 或修改 PATH，并在 Fedora
   宿主机验证。

Nix store 文件通常不可由普通更新器原位替换，但容器内 CLI 以 root 运行，不能把文件
权限当作强安全边界；原生禁用配置与 profile 对账才是主要机制。

---

## 11. NVIDIA

`secli.sh --nvidia` 仅增加：

```text
--security-opt=label=disable
--device=nvidia.com/gpu=all
```

使用 CDI，不自行探测或安装驱动。`docs/nvidia.md` 必须记录 Fedora 宿主机前置条件：
NVIDIA 驱动、nvidia-container-toolkit、`nvidia-ctk cdi generate`、Podman 版本，以及
关闭 SELinux label 隔离的安全让步。未来可以泛化设备透传，但 v1 不增加通用任意参数
透传。

---

## 12. 镜像、版本与发布

### 12.1 两个交付物

用户部署由两个配套交付物组成：

1. Git 仓库：`secli.sh`、manifest、templates、docs；
2. GHCR 镜像：Nix 基底与 entrypoint。

主要部署方式保持为 `git clone` 加 `podman pull`，不要求宿主机安装 Nix。

### 12.2 版本绑定

- 仓库使用 `VERSION` 保存版本。首次实现写入 `v0.1.0-dev`；首次正式发布前改为
  `v0.1.0`。
- Git tag、GitHub Release 与镜像不可变标签必须一致。
- `secli.sh` 默认使用 `ghcr.io/hinnyuu/secli:<VERSION>`。
- `SECLI_IMAGE` 允许显式覆盖完整镜像引用。
- `latest`/`stable` 可以作为便利别名，但启动器不得默认依赖移动标签。
- 镜像应写入 OCI source、revision、version 等 labels。

开发阶段 `secli.sh` 不隐式执行 `podman pull`；镜像不存在时直接报错，由用户手动 pull
或通过 `SECLI_IMAGE` 指向本地开发镜像。开发版本不承诺存在同名远程镜像。Tag/release
workflow 必须拒绝包含 `-dev` 的 `VERSION`，并验证它与 Git tag 一致。workflow 构建成功
并推送镜像后才创建/公布 Release。manifest schema、启动器与 entrypoint 的不兼容变化
必须随仓库/镜像版本一起发布。

### 12.3 Containerfile 是镜像唯一构建来源

当前定案：保留标准 `Containerfile`，v1 由 GitHub Actions 构建并推送 GHCR。
不要同时维护 dockerTools 镜像定义，避免两套构建来源漂移。

Gitea Actions 只是未来迁移目标，v1 不创建或维护第二套 workflow。构建逻辑应尽量留在
Containerfile 和普通 shell 脚本中，减少不必要的 GitHub 专有逻辑，但不承诺当前支持
Gitea。

开发容器无法运行嵌套 Podman，因此：

- 在这里完成 Containerfile 静态检查、shell 测试和文档；
- 镜像构建由 CI 或用户 Fedora 宿主机完成；
- CI 使用 GitHub `GITHUB_TOKEN` 与 `packages: write` 推送；
- 当前 LLM 容器没有 GHCR/GitHub 凭据，不得尝试推送。

---

## 13. Flake 职责

实现开始时必须增加：

```text
devShells.default
packages.default
checks
```

- `devShells.default`：ShellCheck、Bats、shfmt、actionlint，以及测试所需的 jq 等开发工具。
- `packages.default`：可执行的宿主机 secli 部署包，包含运行所需脚本和只读资源；用于
  `nix build` 后执行 `./result/bin/secli --help` 冒烟测试。
- Nix package wrapper 在未显式设置 `SECLI_STATE_DIR` 时使用 `$XDG_STATE_HOME/secli`，并
  回退到 `$HOME/.local/state/secli`，不得尝试写入只读 Nix store。Git clone 部署仍默认使用
  仓库内 `state/`。
- `checks`：shellcheck、格式、Bats、manifest 契约与模板布局检查。

生产镜像仍由 Containerfile 构建。Flake 的宿主机包是额外的可复现验证/安装方式，不能
改变 `git clone` 作为主要部署模型。`flake.lock` 必须提交。

---

## 14. 目标仓库布局

```text
secli/
├── AGENTS.md
├── README.md
├── LICENSE
├── VERSION
├── flake.nix
├── flake.lock
├── secli.sh
├── entrypoint.sh
├── Containerfile
├── manifest/
│   ├── opencode.conf
│   └── qoder-cli-cn.conf
├── manifest.local/                 # gitignore，用户私有
├── templates/
│   ├── opencode/                   # 目录内容直接镜像 /root
│   └── qoder-cli-cn/
├── state/                          # gitignore，用户认证与状态
├── tests/
│   ├── secli.bats
│   ├── entrypoint.bats
│   └── fixtures/
├── docs/
│   ├── security.md
│   ├── nvidia.md
│   ├── testing-host.md
│   └── clis/
│       ├── opencode.md
│       └── qoder-cli-cn.md
└── .github/workflows/
    ├── ci.yml
    └── release-image.yml
```

---

## 15. 测试要求

测试规模随风险增长，但以下内容是 v1 最低要求。

### 15.1 开发容器内自动测试

- ShellCheck 与 shfmt 检查 `secli.sh`、`entrypoint.sh` 和测试辅助脚本。
- Bats 使用 mock `podman` 验证参数数组，禁止通过字符串拼接执行命令。
- 参数边界：未知选项、`--` 透传、Qoder `-p` 冲突、help。
- 端口：默认 loopback、显式 `0.0.0.0`、非法地址和范围。
- 路径：物理路径、白名单边界、空格、数据集只读、多数据集。
- manifest：覆盖顺序、保留字、字段验证、数组环境变量。
- init：复制 dotfiles、创建父目录、绝不覆盖、`all`。
- entrypoint：profile/stamp 四种组合、安装失败、回滚、PATH 优先级。
- 命令参数必须用 Bash 数组保存，测试包含空格、引号和以 `-` 开头的 CLI 参数。

当前宿主机启动器和 entrypoint 的自动测试共覆盖 22 个场景；新增 manifest 字段或启动参数
时必须同步扩展 Bats 覆盖。

### 15.2 Fedora 宿主机人工集成测试

任何涉及 Podman、SELinux、named volume copy、NVIDIA、登录或真实 AI CLI 的变更，LLM
都必须在完成工作时提供逐条可复制的宿主机测试流程、预期输出和清理命令，不能只写
“请测试”。至少验证：

- 空 `secli-nix-v<N>` 首次复制并可启动；
- 删除 Nix 卷后 CLI 自动重装，Home 认证仍在；
- 切换 opencode/Qoder 时 Home 隔离；
- 固定容器名拒绝并发；
- SELinux `:z`/`:Z` 挂载可读写性；
- loopback 与显式全网卡端口绑定；
- Qoder 无浏览器登录体验、持久化和自更新关闭行为；
- NVIDIA CDI 路径（有条件时）。

测试结论写入对应 `docs/clis/*.md` 或 `docs/testing-host.md`，不要只留在对话中。

---

## 16. 实现准则

- Bash 脚本启用严格模式，并以数组构造 Podman/Nix/CLI 参数。
- 不用 `eval` 解析用户参数，不用未加引号的字符串重组命令。
- 对结构化内容使用 jq 或相应解析器，不用 sed/grep 修改 JSON。
- 错误信息指出失败值、契约和修复方式，但不打印 token、认证内容或完整敏感环境。
- 日志输出到 stdout/stderr，不写仓库或镜像内日志文件。
- 重要状态更新使用临时文件加原子 rename。
- 只实现真实需要的抽象；不得恢复软链接状态迁移或共享 Home 兼容层。
- 不引入任意 Podman 参数透传，因为它会绕过安全挂载和隔离决策。

---

## 17. Git 与远程操作

宿主机 GitHub 身份：

- `user.name`: `RyougiShiki-214`
- `user.email`: `53418317+RyougiShiki-214@users.noreply.github.com`

LLM 容器没有 GitHub/GHCR 凭据：

- push、PR、Issue、Release、仓库设置和 registry 推送由宿主机或 CI 完成；
- 不得在容器内写入或索要凭据；
- 本地 Git 初始化、分支、暂存和提交可以在容器内执行，不配置用户级 Git 身份或 remote；
  向 GitHub 提交时由用户在宿主机执行具体命令。

提交使用 Conventional Commits，分支使用 `<type>/<kebab-desc>`。多步实现走 feature 分支。
提交前展示 `git status` 和 `git diff`，逐路径暂存，不使用 `git add -A`。禁止 force push、
amend（除非用户明确要求）、破坏性 reset 和修改他人无关变更。

当前项目允许在本地 Git 仓库中按 Conventional Commits 创建分支和提交，但不配置远程仓库
或执行 GitHub 操作。

### 17.1 提交前同步门禁

每次提交前必须检查 `AGENTS.md`、`README.md`、相关 `docs/`、`.gitignore`、`VERSION` 与
`flake.lock`。这是一项检查义务，不要求无关提交制造文档改动；只要实现、用户接口、安全
边界、验证状态、依赖或运行时文件布局发生变化，就必须在同一提交中同步对应文件。

最低检查规则：

1. 架构、manifest、状态、挂载、安全或发布契约变化时更新 `AGENTS.md`；
2. 用户命令、部署、错误行为、版本或项目状态变化时更新 `README.md`；
3. Fedora、CLI、NVIDIA 或安全验证结论写入对应 `docs/`，不得只留在对话中；
4. 新增认证、缓存、构建产物、用户覆盖或运行时目录时检查 `.gitignore`；
5. 依赖输入变化时检查 `flake.lock`，发布阶段检查 `VERSION`、tag 与镜像标签；
6. 提交前运行文档一致性 check，并搜索 `待验证`、`pending`、`计划中`、`尚未实现`、完整
   commit 占位符和 `-dev`，逐项确认仍为真实状态。

每个里程碑结束、PR 创建前和 release 前还必须执行一次全量文档审查。可机器验证的占位符、
版本格式、LICENSE、测试数量和已知过期文本由 `tests/check-docs.sh` 与 Flake check 强制检查；
安全描述、宿主机实测和架构语义仍由提交者人工审查。

---

## 18. 路线图与开放验证项

已定案：

- [x] 每 CLI 完整 Home，取消软链接状态架构
- [x] 固定单容器名，v1 禁止并发
- [x] 共享部署路径 `:z`，独占 Home `:Z`
- [x] manifest 可选 `RUNTIME_ENV`
- [x] 每 CLI 独立 profile 位于共享 `/nix`
- [x] loopback 默认端口与显式外部绑定
- [x] Containerfile + CI 构建 GHCR 镜像
- [x] 仓库版本绑定不可变镜像标签
- [x] `/nix` volume 使用独立兼容 epoch

待实现：

- [x] `flake.nix`、`flake.lock`、基础 checks
- [x] `secli.sh` 与单元测试
- [x] `entrypoint.sh` 与 profile/stamp 对账测试
- [x] Containerfile
- [x] opencode 与 qoder-cli-cn manifest
- [x] 两套 Home 镜像模板
- [x] CLI 档案初稿、安全和 NVIDIA 文档；基础 SELinux/NVIDIA 宿主机测试、挂载/端口矩阵
  和真实认证已完成，更新器行为仍待完成
- [x] CI 与 tag release workflow；Actions 固定 commit，PR CI 构建 amd64 镜像
- [x] LICENSE
- [x] VERSION

### 推荐实现阶段

除非用户明确要求一次完成完整 v1，否则只实施用户指定的阶段。完整 v1 按以下可独立
验证的里程碑推进：

1. Flake、目录骨架和静态检查；
2. `secli.sh`、mock Podman 和 Bats 测试；
3. `entrypoint.sh`、manifest 加载和 profile/stamp 对账测试；
4. manifest、Home 模板、`VERSION`、`.gitignore`；
5. Containerfile 及静态验证；
6. 用户文档、Fedora 测试手册和 GitHub Actions；
7. 全量 `nix flake check`、`nix build`、shell 测试，以及由用户执行的 Fedora 宿主机
   集成测试。

阶段间不得用未验证占位实现掩盖失败。本地 Git 初始化和提交属于 build 阶段的正常工作；
远程仓库及 GitHub 操作由用户在宿主机完成。

必须通过实践确认：

- Qoder CN 原生更新器在模板设置生效后的实际行为；
- opencode/Qoder 在 Nix profile 安装形态下是否创建替代二进制或 shim；
- Fedora Podman 对 `/nix` 空 named volume 的 copy 行为和 epoch 升级流程；
- arm64 镜像的 Fedora 宿主机验证和 CI runner 方案。

v0.1 首发镜像只发布 `linux/amd64`。Flake 和 Nix CLI 包保留 `aarch64-linux` 输出，但 arm64
镜像不属于首发承诺，需完成对应 Fedora 宿主机验证和 CI runner 方案后再启用。

已验证：Fedora 宿主机上的镜像构建、空 `secli-nix-v1` 初始化、两个首发 profile 安装、
OpenCode `1.18.18`、Qoder CN `1.1.25`、第二次启动 noop、固定 flake 配置的非交互安装、
基础 SELinux 挂载、NVIDIA CDI、项目/数据集读写边界、两个 CLI 的认证和 Home 持久化、
loopback 与显式全网卡端口绑定。结果详见 `docs/testing-host.md` 和 `docs/nvidia.md`。

这些是测试阶段的开放事实，不是重新讨论已定案架构的理由。发现新事实时，先记录证据，
再最小化调整契约和本文档。
