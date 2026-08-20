# Qoder CLI CN

## 来源

仓库 manifest 使用以下钉死的 flake ref：

```text
github:numtide/llm-agents.nix/c4c6673c4c1ceb69d845fa665a714e1273d0acac#qoder-cli-cn
```

在该 commit 检查该包，报告如下：

- 包版本：`1.1.25`
- 主程序：`qoderclicn`
- 支持的目标平台：`x86_64-linux`、`aarch64-linux`、`aarch64-darwin`
- Linux 来源：`https://static.qoder.com.cn/qoder-cli-cn/releases/1.1.25/`
- 来源属性：二进制原生代码
- 更新清单：`https://static.qoder.com.cn/qoder-cli-cn/channels/manifest.json`

该包是中国大陆服务渠道，与国际版 Qoder CLI 包分离。secli 不在基础镜像中分发该
unfree 二进制；容器将其安装进 Qoder 专用 profile。

## Home 与认证

该 CLI 的完整 Home 从 `state/qoder-cli-cn/home/` 挂载到 `/root`。Qoder CN 的用户配置
目录是 `/root/.qoder-cn`。官方文档说明交互式登录可通过 `/login` 完成，无头环境会输出
一个 URL 供浏览器手动完成。Personal Access Token 可通过 `QODERCN_PERSONAL_ACCESS_TOKEN`
提供；secli 不持久化或注入该变量。

Qoder CN 配置目录还包含会话、日志、插件和其他原生运行时状态。完整 Home 挂载无需枚举
产品特定路径即可保留这些内容。

## 模板

`templates/qoder-cli-cn/` 镜像 `/root` 内的以下路径：

```text
.qoder-cn/settings.json
.qoder-cn/AGENTS.md
```

settings 模板：

- 将 `general.enableAutoUpdate` 设为 `false`；
- 保持默认权限模式；
- 将 `security.disableYoloMode` 设为 `true`。

Qoder 文档将 `~/.qoder-cn/AGENTS.md` 认定为原生用户级记忆文件。`RUNTIME_ENV` 为空，
因为原生文件位置已在挂载的 Home 内，无需系统提示词路径覆盖。`init` 仅在目标文件缺失
时复制模板。用户可以编辑或替换这两个文件。

## 更新

Qoder CN 的官方安装文档说明自动更新默认启用，并记录了 `update` 命令和基于安装器的
升级。模板关闭原生自动更新器。这是推荐设置，不是硬性容器策略：`/nix` 保持可写，因为
项目和 CLI 子进程必须能使用 Nix。

secli profile 保持权威。entrypoint 启动 profile 的绝对 `qoderclicn` 路径，绝不启动
下载到 `/root` 的二进制。当该 manifest pin 变化时，只对账 Qoder profile，并在安装
成功后更新其 stamp。

## 验证状态

在 manifest commit 处已验证：

- Nix 包在 `x86_64-linux` 上构建成功。
- `qoderclicn --version` 报告 `1.1.25`。
- `qoderclicn --help` 在临时配置目录下运行。
- 临时运行创建了 Qoder 运行时日志文件，但没有认证状态。
- Fedora rootless Podman 在专用 Home 中保留 Qoder 认证和会话。
- Qoder 在 `.qoder-cn/entry/`、`.qoder-cn/.bin/` 和 `.qodersec/` 下创建原生 Home
  entry/运行时文件；secli 仍启动 Nix profile 的绝对路径可执行文件。
- 项目、数据集、SELinux、端口和 NVIDIA 挂载行为通过宿主机矩阵。

Fedora 发布验证（新初始化的 Home）确认：

- 仓库模板在首次启动前被逐字节复制；
- Qoder `/settings` 显示 `Enable Auto Update false` 和默认权限模式；
- 重复正常 TUI 启动后 `settings.json` 中 `general.enableAutoUpdate: false` 和
  `security.disableYoloMode: true` 保持不变；
- Qoder 可能把认证、安全扫描和受信任目录数据合并进同一 settings 文件，同时保留模板
  字段；
- `.qoder-cn/entry/` 和 `.qoder-cn/.bin/` 作为原生首次运行状态创建，之后正常启动间
  保持字节稳定；
- PID 1 解析到 Nix store 的 `qoder-cli-cn-1.1.25` 二进制，其命令行使用专用的
  `secli-qoder-cli-cn` profile。

一个旧测试 Home 在当前模板之前初始化，因此使用了 Qoder 的默认自动更新值。`init` 正确
拒绝覆盖该已存在的 settings 文件。模板更新不迁移已有 Home；用户必须人工比较并合并
推荐设置。

## 自动更新器测试

不要运行 `qoderclicn update`；本测试只检查正常启动。从项目目录验证解析后的原生
设置：

```bash
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-auth-state
/data/projects/hinnyuu/secli/secli.sh qoder-cli-cn -- \
  config get general.enableAutoUpdate
/data/projects/hinnyuu/secli/secli.sh qoder-cli-cn -- \
  config get security.disableYoloMode
```

预期值：`false` 和 `true`。

在一次正常交互会话前后快照 Qoder 的原生 entry/运行时候选：

```bash
home="$SECLI_STATE_DIR/qoder-cli-cn/home"
find "$home/.qoder-cn/entry" "$home/.qoder-cn/.bin" -type f \
  -exec sha256sum {} + 2>/dev/null | sort > /tmp/secli-qoder-bin.before
/data/projects/hinnyuu/secli/secli.sh qoder-cli-cn
find "$home/.qoder-cn/entry" "$home/.qoder-cn/.bin" -type f \
  -exec sha256sum {} + 2>/dev/null | sort > /tmp/secli-qoder-bin.after
diff -u /tmp/secli-qoder-bin.before /tmp/secli-qoder-bin.after
```

预期：正常启动不会用更新的 CLI 替换这些候选。Qoder 的其他会话、日志、模型和缓存文件
可能变化。Qoder 运行期间，从另一终端检查 PID 1：

```bash
podman exec secli /bin/sh -c \
  'readlink -f /proc/1/exe; tr "\0" " " </proc/1/cmdline; printf "\n"'
```

预期：可执行文件和命令行使用 Nix store/profile，不引用 `.qoder-cn/entry` 或
`.qoder-cn/.bin`。Nix wrapper 可能使 `/proc/1/exe` 解析为 Bash，但 cmdline 包含
profile wrapper。记录结果后只删除两个临时快照文件。

结果：在最终 `v0.1.0` 发布测试中于 Fedora amd64 通过。Qoder 的 `config get` 子命令在
`1.1.25` 中只暴露 `vpc_endpoint`；改用 `/settings` 和持久化 JSON 验证 general 与
security 设置。
