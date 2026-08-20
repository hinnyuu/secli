# 宿主机配置

宿主机启动器读取可选的配置文件，将用户设置跨 shell 会话持久化。配置文件适用于
git clone 部署。Flake 产出的宿主机包仅用于开发验证，其 `BASE_DIR` 是只读的 Nix store
路径，该场景继续使用环境变量配置。

## 位置与查找

启动器按以下顺序读取第一个适用的路径：

1. `SECLI_CONFIG` 环境变量指向的路径（若已设置）。此处文件缺失属于错误，因为该
   路径是显式指定的。
2. 部署根下的 `config/secli.conf`。文件缺失时保持内置默认值。

将 `config/secli.conf.example` 复制为 `config/secli.conf`，并取消注释需要修改的键。
建议文件权限为 `0600`：值是路径和镜像引用而非凭据，但配置文件属于个人配置。

## 格式

- 每行一条 `SECLI_KEY=value` 赋值。
- 空行与以 `#` 开头的行忽略。
- 键与值两侧的前后空白会被去除。
- 未知键、畸形行与空值会被拒绝，错误信息包含文件路径与行号。
- 同一键的后定义覆盖先定义。
- 不允许多行值与 `+=` 追加语法。这保证格式未来可平滑过渡到 drop-in 目录
  （按文件名排序应用、后文件覆盖前文件）。

文件按受校验数据解析。与 manifest 不同，绝不 source 或执行。

## 优先级

环境变量 > 配置文件 > 内置默认。

## 支持的键

| 键 | 含义 | 内置默认 |
| --- | --- | --- |
| `SECLI_ALLOWED_PROJECT_PREFIXES` | 项目目录白名单，冒号分隔的绝对路径前缀 | `/data/projects` |
| `SECLI_IMAGE` | 宿主机启动器使用的完整镜像引用 | `ghcr.io/hinnyuu/secli:<VERSION>` |
| `SECLI_STATE_DIR` | 存放各 CLI Home 的状态根 | `<部署根>/state` |

校验规则与环境变量行为一致：前缀必须是绝对路径，镜像引用不得包含空白，状态目录
必须是非空路径。容器名与 Nix 卷 epoch 是架构常量，不开放配置。

## 示例

```text
SECLI_ALLOWED_PROJECT_PREFIXES=/data/projects:/tmp
SECLI_IMAGE=localhost/secli:dev
SECLI_STATE_DIR=/secure/path/secli-state
```
