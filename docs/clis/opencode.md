# OpenCode

## 来源

仓库 manifest 使用以下钉死的 flake ref：

```text
github:numtide/llm-agents.nix/c4c6673c4c1ceb69d845fa665a714e1273d0acac#opencode
```

在该 commit 检查该包，报告如下：

- 包版本：`1.18.18`
- 主程序：`opencode`
- 支持的目标平台：`x86_64-linux`、`aarch64-linux`、`aarch64-darwin`
- Linux 来源：`github.com/anomalyco/opencode` 的官方 OpenCode 发布归档
- 来源属性：二进制原生代码

该 Nix 包用 Nix 的 `fzf` 和 `ripgrep` 包装二进制。secli 不在基础镜像中分发 OpenCode
二进制；容器将该包安装进其专用 profile。

## Home 与认证

该 CLI 的完整 Home 从 `state/opencode/home/` 挂载到 `/root`。OpenCode 的提供商凭据
存放在 `/root/.local/share/opencode/auth.json` 下。Home 还保留会话、缓存和用户配置。
认证通过 OpenCode 的原生 `/connect` 流程或提供商特定环境变量完成。

## 模板

`templates/opencode/` 镜像 `/root` 内的以下路径：

```text
.config/opencode/opencode.jsonc
.config/opencode/AGENTS.md
```

模板关闭 OpenCode 的原生自动更新和会话分享，并将读/列表/搜索操作设为 allow，同时让
有副作用的操作保持在原生审批边界。`init` 仅在目标文件不存在时复制。用户可以编辑或
替换这两个文件。

OpenCode 还会从挂载的项目中发现项目级 `AGENTS.md` 文件。secli 不替换项目的指令文件，
也不将其设为只读。

## 更新

OpenCode 文档将 `autoupdate: false` 作为原生自动更新设置。模板将其设为 false。secli
profile 保持权威：entrypoint 启动 profile 的绝对 `opencode` 路径，绝不启动下载到
`/root` 的二进制。

当该 manifest pin 变化时，下次启动只对账 OpenCode profile，并在安装成功后更新其
stamp。安装失败返回非零，不会静默启动旧 generation。

## 验证状态

在 manifest commit 处已验证：

- Nix 包在 `x86_64-linux` 上构建成功。
- `opencode --version` 报告 `1.18.18`。
- `opencode --help` 在临时 Home 中运行且不创建文件。
- Fedora rootless Podman 启动 profile，并在 OpenCode Home 中保留认证和会话。
- 项目、数据集、SELinux、端口和 NVIDIA 挂载行为通过宿主机矩阵。

Fedora 发布验证（新初始化的 Home）确认：

- 仓库模板在首次启动前被逐字节复制；
- 解析后的配置包含 `autoupdate: false` 和 `share: disabled`；
- 正常启动后配置保持不变；
- 正常交互启动不在 `.cache/opencode/bin` 下新增或更改更新器二进制候选；
- PID 1 解析到 Nix store 的 `opencode-1.18.18` wrapper，其命令行使用专用的
  `secli-opencode` profile。

一个旧测试 Home 包含当前模板之前创建的仅含 schema 的配置。`init` 未覆盖它，符合绝不
覆盖契约。模板更新不迁移已有 Home；用户必须人工比较并合并新推荐设置。

## 自动更新器测试

不要运行 `opencode upgrade`；本测试只检查正常启动。从项目目录使用已包含测试登录的
同一状态根：

```bash
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-auth-state
/data/projects/hinnyuu/secli/secli.sh opencode -- debug config \
  | grep -E '"(autoupdate|share)"'
```

预期解析值为 `autoupdate: false` 和 `share: disabled`。

在一次正常交互会话前后快照更新器管理的二进制候选：

```bash
home="$SECLI_STATE_DIR/opencode/home"
find "$home/.cache/opencode/bin" -type f -exec sha256sum {} + 2>/dev/null \
  | sort > /tmp/secli-opencode-bin.before
/data/projects/hinnyuu/secli/secli.sh opencode
find "$home/.cache/opencode/bin" -type f -exec sha256sum {} + 2>/dev/null \
  | sort > /tmp/secli-opencode-bin.after
diff -u /tmp/secli-opencode-bin.before /tmp/secli-opencode-bin.after
```

预期：没有新增或变更的更新器二进制。Home 中其他位置的会话/数据库/缓存变化属于正常。
OpenCode 运行期间，从另一终端检查 PID 1：

```bash
podman exec secli /bin/sh -c \
  'readlink -f /proc/1/exe; tr "\0" " " </proc/1/cmdline; printf "\n"'
```

预期：可执行文件和命令行使用 Nix store/profile，不引用 `/root` 下的 OpenCode 二进制。
Nix wrapper 可能使 `/proc/1/exe` 解析为 Bash，但 cmdline 包含 profile wrapper。记录
结果后只删除两个临时快照文件。

结果：在最终 `v0.1.0` 发布测试中于 Fedora amd64 通过。
