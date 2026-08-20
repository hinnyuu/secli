# NVIDIA

`secli.sh --nvidia` 启用 NVIDIA CDI 透传。它不安装驱动、不探测 GPU、不接受任意设备
参数。

## 宿主机前置条件

- Fedora 宿主机，rootless Podman `>= 5.8.4` 正常工作。
- 已安装受支持的 NVIDIA 驱动且工作正常。
- 已为该发行版安装 `nvidia-container-toolkit`。
- 已用 `nvidia-ctk cdi generate` 生成 NVIDIA CDI 规范。
- 生成的 CDI 设备对 rootless Podman 用户可见。
- 测试前理解 SELinux 启用配置。secli 在该模式下关闭容器的 SELinux 标签。

检查宿主机：

```bash
podman --version
nvidia-smi
nvidia-ctk --version
nvidia-ctk cdi list
getenforce
```

若 CDI 不存在，按宿主机 toolkit 安装方式生成：

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list
```

上面的 `sudo` 是 Fedora 宿主机上由人类管理员执行的命令。它不由 secli 运行，也不
适用于开发容器内。

## 预期 Podman 参数

使用 `--nvidia` 时，启动器仅追加：

```text
--security-opt=label=disable
--device=nvidia.com/gpu=all
```

启动器不做任何驱动安装或宿主机探测。

## 测试流程

在合法项目目录中、本地镜像已构建的前提下运行：

```bash
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-nvidia-test-state
./secli.sh init opencode
./secli.sh opencode --nvidia -- --help
```

预期：

- Podman 接受 CDI 设备。
- CLI 启动并输出其原生帮助。
- `podman inspect` 显示容器以 `label=disable` 和 NVIDIA CDI 设备创建。
- 容器在退出后被移除。

独立于 secli 的直接设备冒烟测试：

```bash
podman run --rm \
  --security-opt=label=disable \
  --device=nvidia.com/gpu=all \
  localhost/secli:dev \
  --help
```

## 安全让步

关闭 SELinux 标签是所选 CDI 路径在目标环境下的有意安全让步。不要把启用 GPU 的容器
等同于默认 SELinux 限制模式。每次验证都记录 Fedora、驱动、toolkit、CDI 和 Podman
版本。

## 实现说明

Nix 基础镜像刻意最小化，其 `/usr/share` 可能是 store 后端的符号链接。Containerfile
移除该镜像内符号链接，创建 FHS NVIDIA 挂载点目录（包括 `/usr/share/nvidia`），驱动
文件交给 CDI。它不复制或安装驱动文件；CDI 仍从 Fedora 宿主机提供驱动。

## 结果

```text
日期：2026-08-19
宿主机：Fedora，amd64，SELinux Enforcing
GPU：NVIDIA GeForce RTX 4060 Laptop GPU
驱动：610.57.04，CUDA UMD 13.3
Toolkit：NVIDIA Container Toolkit CLI 1.19.1
CDI：通过；找到 GPU 索引、UUID 和 `nvidia.com/gpu=all` 设备
Podman：5.8.4 rootless
secli --nvidia：通过；OpenCode 输出完整原生帮助并正常退出
备注：首次尝试失败，因为最小化 Nix 镜像使用 store 后端的 `/usr/share` 符号链接，
CDI 无法创建 `/usr/share/nvidia/nvoptix.bin`。提交 `e61a215` 将该镜像内符号链接替换
为可写 FHS 挂载点目录。重建后的镜像无错误通过；宿主机驱动和 CDI 无需任何变更。
```
