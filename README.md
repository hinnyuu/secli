# secli

Secure Enhanced CLI：使用 Fedora 宿主机上的 rootless Podman 与容器内 Nix，为多个
AI coding CLI 提供统一、隔离、可重建的运行环境。

> **项目状态：架构已定案，正在实现。**
>
> 下文命令描述 v1 接口；在对应的 `secli.sh`、镜像和首发 manifest 完成前，尚未完成的
> 命令还不能运行。

## 为什么需要 secli

AI coding CLI 通常需要读写项目、执行命令、保存登录状态，并可能自行下载更新。直接在
宿主机运行会让 CLI 接触完整的用户环境。secli 将这些能力收敛到一个明确的边界中：

- CLI 在 rootless Podman 容器中运行；
- 只挂载当前项目、用户明确指定的数据集和当前 CLI 的独立 Home；
- 所有容器内软件通过 Nix 安装；
- CLI 版本由钉死 commit 的 manifest 控制；
- 容器无状态，可随时删除；认证和配置与可重建软件缓存分开保存；
- 每个 CLI 使用自己的原生权限与安全设置，不强行统一不同产品的策略语义。

首发目标是：

- [opencode](https://opencode.ai/)
- qoder-cli-cn

架构允许后续增加 Codex、Gemini CLI 等，只要它们能用一个 Nix 安装引用、一个主命令、
可选启动环境变量和独立 Home 表达。

## 安全边界

secli 的目标是缩小宿主机上的影响范围，不是提供完美沙箱。

容器可以：

- 读写当前项目；
- 读取显式挂载的数据集；
- 读写当前 CLI 自己的 `/root`；
- 读写共享 `/nix`，以运行 `nix develop` 和构建项目；
- 访问网络。

容器默认不能看到：

- 宿主机其他项目；
- 未显式挂载的数据集；
- 其他 CLI 的认证、配置和会话 Home；
- 宿主机用户的普通 Home。

容器内进程以 root 运行，但 rootless Podman 将容器 root 映射为宿主机普通用户。当前项目
仍然是可写的，恶意或错误操作能够删除、泄露或破坏项目内容。应继续使用 Git、备份和
CLI 自身的审批策略。

启用 `--nvidia` 时需要关闭该容器的 SELinux label 隔离，这是额外的安全让步。

## 架构概览

secli 由两个配套交付物组成：

```text
Git 仓库                              GHCR 镜像
├── secli.sh                          ghcr.io/hinnyuu/secli:<version>
├── manifest/                         ├── Nix
├── templates/                        ├── git/ripgrep
└── docs/                             └── entrypoint.sh
```

宿主机上的 `secli.sh` 负责参数、路径和挂载；镜像内的 `entrypoint.sh` 负责安装并启动所选
CLI。镜像不包含任何 AI CLI，因此更新 CLI pin 不需要重建基础镜像。

运行时状态分为两类：

```text
state/<cli>/home/  -> /root   # 认证、配置、会话，不可随意删除
secli-nix-v<N>     -> /nix    # store、profiles、缓存，可以重建
```

每个 CLI 拥有完整、独立的 Home。secli 不需要猜测各产品把状态写在 `.config`、`.local`、
`.qoder`、`.codex` 还是其他目录，也不使用状态软链接。

v1 的容器名固定为 `secli`，全局只允许一个实例。切换不同 CLI 没有问题，但不支持同时
运行多个 CLI 容器。

## 目标宿主机

- Fedora Linux
- rootless Podman >= 5.8.4
- SELinux，推荐启用
- NVIDIA 可选，需要宿主机驱动、nvidia-container-toolkit 和 CDI 配置

主要部署方式不要求宿主机安装 Nix。Nix 位于运行镜像内。

## 计划中的安装方式

正式发布后，仓库版本、Git tag 和镜像不可变标签一一对应：

```bash
git clone https://github.com/hinnyuu/secli
cd secli
podman pull ghcr.io/hinnyuu/secli:v0.1.0
```

仓库中的 `VERSION` 决定 `secli.sh` 默认使用的镜像标签。可以显式覆盖：

```bash
SECLI_IMAGE=ghcr.io/hinnyuu/secli:custom ./secli.sh opencode
```

开发阶段 `secli.sh` 不隐式执行 `podman pull`。镜像不存在时直接报错；用户需要手动
执行 `podman pull`，或通过 `SECLI_IMAGE` 指向本地开发镜像。

`latest` 和 `stable` 可以作为方便别名，但 secli 默认不依赖移动标签。

首次实现阶段的 `VERSION` 使用 `v0.1.0-dev`，它不承诺 GHCR 存在同名镜像。正式发布前
改为 `v0.1.0`。开发期在 Fedora 宿主机测试本地镜像时显式覆盖：

```bash
SECLI_IMAGE=localhost/secli:dev ./secli.sh opencode
```

## 计划中的用法

```text
secli.sh <cli> [secli 选项] [-- CLI 原生参数...]
secli.sh init <cli|all>
secli.sh list
secli.sh -h|--help
```

初始化推荐配置：

```bash
./secli.sh init opencode
./secli.sh init qoder-cli-cn
# 或
./secli.sh init all
```

`init` 只创建缺失文件，绝不覆盖已有配置。模板复制到当前 CLI 的独立 Home 后由用户自行
管理；普通启动不会隐式初始化。

启动 CLI：

```bash
./secli.sh opencode
./secli.sh qoder-cli-cn
```

将原生参数放在 `--` 后：

```bash
./secli.sh opencode -- --help
./secli.sh qoder-cli-cn -- -p "检查当前项目"
```

Qoder 自己的 `-p` 表示 prompt，而 secli 的 `-p` 表示端口，因此分隔符不能省略。

### 数据集

数据集按原绝对路径只读挂载，可重复指定：

```bash
./secli.sh opencode \
  --dataset /data/dataset/source-a \
  --dataset /data/dataset/source-b
```

### 端口

单端口写法默认只监听宿主机 loopback：

```bash
./secli.sh opencode -p 4096
# 127.0.0.1:4096 -> container:4096
```

对局域网或公网接口暴露必须显式写出地址、宿主机端口和容器端口：

```bash
./secli.sh opencode -p 0.0.0.0:8080:4096
```

v1 不支持端口范围、省略字段或 IPv6。

### NVIDIA

```bash
./secli.sh opencode --nvidia
```

该选项只增加 NVIDIA CDI 设备和 `label=disable`，不会探测或安装宿主机驱动。

## 项目路径白名单

真正启动 CLI 时，执行 `secli.sh` 的当前工作目录就是项目目录。启动器本身可以部署在
任意位置，并通过自身路径查找 manifest、模板和版本；v1 不提供 `--project` 参数，也不
自动猜测其他项目目录。

当前工作目录经过物理路径规范化后必须位于默认白名单之一：

```text
/data/projects
/data/test
/data/dataset
```

可用冒号分隔的环境变量整体覆盖：

```bash
SECLI_ALLOWED_PREFIXES=/work/projects:/srv/code ./secli.sh opencode
```

匹配尊重路径边界；例如 `/data/projects-evil` 不属于 `/data/projects`。

项目以相同绝对路径挂入容器，并成为容器工作目录。路径校验失败时立即拒绝启动，不自动
扩大白名单。`init`、`list` 和 secli 包装器帮助不启动容器，因此可在白名单外运行；
`./secli.sh opencode -- --help` 会实际启动 CLI，仍需要合法项目目录。

## 状态与备份

默认状态目录位于仓库下：

```text
state/
├── opencode/home/
└── qoder-cli-cn/home/
```

可以整体重定向：

```bash
SECLI_STATE_DIR=/secure/path/secli-state ./secli.sh opencode
```

状态目录权限至少为 `0700`。备份某个 CLI 时，停止 secli 后复制对应的
`state/<cli>/home/` 即可。

Nix 软件状态保存在独立兼容 epoch 的 named volume，例如：

```text
secli-nix-v1
```

它与项目版本不是同一个版本号。多个 secli 发布可以复用 `v1`；只有基础 Nix 闭包或
存储布局不兼容时才升级为 `v2`。

删除 Nix 卷不会删除认证或项目，但会清除 CLI 安装和构建缓存：

```bash
podman volume rm secli-nix-v1
```

下次启动会重新安装当前 CLI，项目依赖按各项目的 `flake.lock` 重新获取或构建。

## CLI 版本与 manifest

每个受支持 CLI 有一个受信任的 Bash manifest：

```bash
CLI_ID=opencode
BIN=opencode
INSTALL_REF="github:numtide/llm-agents.nix/c4c6673c4c1ceb69d845fa665a714e1273d0acac#opencode"
RUNTIME_ENV=()
```

`INSTALL_REF` 必须钉死完整 commit。每个 CLI 使用共享 `/nix` 中自己的 profile；entrypoint
根据安装引用 stamp 做幂等对账，不解析各 CLI 不一致的 `--version` 输出。

`RUNTIME_ENV` 只描述 CLI 进程启动时需要的原生环境。entrypoint 在容器内导出变量后再
执行 CLI，因此变量由 CLI 及其子进程继承，但不会污染宿主机 shell。当前两个首发 CLI
均不需要额外的启动环境变量；它不保存 token，也不属于 Nix profile。

用户可以在被 `.gitignore` 排除的 `manifest.local/` 中提供完整覆盖。manifest 会被 Bash
source，等价于执行代码，只能使用可信内容。

## 更新策略

CLI 更新流程：

```text
仓库更新 manifest pin
-> 下次启动发现 INSTALL_REF stamp 变化
-> 更新该 CLI 的专用 Nix profile
-> 成功后原子更新 stamp
```

更新时只清空专用 profile 的 current generation，不立即删除旧 generation。安装失败会
保留旧 stamp，并在可能时回滚旧 generation；无论回滚是否成功，本次启动都返回失败，
不会静默运行与当前 manifest 不一致的旧 CLI。

entrypoint 对固定的 CLI flake ref 使用 `--accept-flake-config`，避免上游 flake 的合法配置
提示阻塞首次安装或脚本化启动。

基础镜像更新流程：

```text
仓库 VERSION 更新
-> 使用对应不可变镜像标签
-> 必要时提升 secli-nix-v<N> epoch
```

推荐模板会关闭 CLI 原生自动更新。OpenCode 模板还关闭自动分享；Qoder CN 模板启用其
原生 `security.disableYoloMode`。secli 始终优先执行 Nix profile 中的命令，不信任 CLI
自行下载到 Home 中的替代二进制。Qoder CN 的配置字段已按 `1.1.25` 官方文档确认，实际
自更新行为仍需要在 Fedora 宿主机上验证。

## 开发

实现阶段的所有开发工具由项目 Flake 提供：

```bash
nix develop
nix flake check
nix build
./result/bin/secli --help
```

检查包括 ShellCheck、shfmt、actionlint、Bats、manifest 契约和模板布局。当前 Bats 覆盖
宿主机启动器和 entrypoint 的 22 个场景；Podman 参数测试使用 mock，不依赖当前开发容器内
的嵌套 daemon。

生产镜像由 `Containerfile` 定义。v1 只实现 GitHub Actions，并使用 workflow 的
`GITHUB_TOKEN` 推送 GHCR；Gitea Actions 是未来迁移目标，不维护第二套 workflow。当前
LLM 开发容器没有 registry 凭据，不执行推送。

两个首发 manifest 固定到同一个 `numtide/llm-agents.nix` commit。OpenCode `1.18.18` 和
Qoder CN `1.1.25` 的版本、平台、下载来源和 `meta.mainProgram` 已确认并记录在
`docs/clis/`。真实登录、Home 持久化和自更新行为仍需 Fedora 宿主机实测。

完整 Podman、SELinux、named volume copy、真实登录和 NVIDIA 测试必须在 Fedora 宿主机
人工执行。相关改动必须同时提供可复制命令、预期结果和清理步骤，并把结论记录到
`docs/testing-host.md` 或 `docs/clis/*.md`。当前 Containerfile 的首轮宿主机步骤见
[`docs/testing-host.md`](docs/testing-host.md)。

当前已由 Fedora 宿主机验证镜像构建、空 Nix volume 初始化、两个 CLI 的 profile 安装与
版本、第二次启动复用、首次安装无配置授权提示、基础 SELinux 挂载、固定容器名并发拒绝、
NVIDIA CDI、项目/数据集读写边界、两个 CLI 的认证持久化以及 loopback/全网卡端口映射。
自更新行为仍待验证。

## 当前路线图

- [x] 架构与安全边界定案
- [x] 实现规格与用户 README
- [x] Flake 开发环境与基础检查
- [x] 宿主机启动器 `secli.sh` 基础版本
- [x] 容器 `entrypoint.sh` 与 Nix profile 对账基础版本
- [x] Containerfile（静态实现，Fedora/CI 构建待验证）
- [x] CI 与 tag release workflow（静态实现，需 GitHub 仓库验证）
- [x] opencode、qoder-cli-cn manifest 和模板
- [x] 自动测试与 Fedora 宿主机测试手册初稿；基础 NVIDIA、认证和挂载/端口矩阵已验证，
  自更新和 SELinux 深度场景仍待完成
- [ ] 首个版本化发布（许可证文件由 GitHub 创建仓库时提供）

实现按上述顺序拆成可独立验证的阶段；除非明确要求完整 v1，否则不把所有阶段合并成
一次巨大变更。build 阶段允许初始化本地 Git 仓库，并按 Conventional Commits 创建本地
提交；项目不在容器内配置 Git remote，也不执行 GitHub 操作。

更详细的实现契约、测试要求和已知开放验证项见 [AGENTS.md](AGENTS.md)。
