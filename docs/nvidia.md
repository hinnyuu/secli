# NVIDIA

`secli.sh --nvidia` enables NVIDIA CDI passthrough. It does not install drivers, detect GPUs or
accept arbitrary device arguments.

## Host prerequisites

- Fedora host with a working rootless Podman installation `>= 5.8.4`.
- A supported NVIDIA driver installed and working on the host.
- `nvidia-container-toolkit` installed for the host distribution.
- NVIDIA CDI specification generated with `nvidia-ctk cdi generate`.
- The generated CDI device is visible to the rootless Podman user.
- SELinux enabled configuration understood before testing. secli disables the container SELinux
  label for this mode.

Check the host:

```bash
podman --version
nvidia-smi
nvidia-ctk --version
nvidia-ctk cdi list
getenforce
```

If CDI is not present, generate it using the host's toolkit installation:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list
```

The `sudo` above is a Fedora host command for the human administrator. It is not run by secli and
is not applicable inside the development container.

## Expected Podman arguments

With `--nvidia`, the launcher adds exactly:

```text
--security-opt=label=disable
--device=nvidia.com/gpu=all
```

No driver installation or host probing is performed by the launcher.

## Test procedure

Run from a valid project directory with a local image already built:

```bash
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-nvidia-test-state
./secli.sh init opencode
./secli.sh opencode --nvidia -- --help
```

Expected:

- Podman accepts the CDI device.
- The CLI starts and prints its native help.
- `podman inspect` shows the container was created with `label=disable` and the NVIDIA CDI device.
- The container is removed after exit.

For a direct device smoke test independent of secli:

```bash
podman run --rm \
  --security-opt=label=disable \
  --device=nvidia.com/gpu=all \
  localhost/secli:dev \
  --help
```

## Security tradeoff

Disabling SELinux labeling is an intentional security reduction required by the selected CDI path
on the target setup. Do not treat GPU-enabled containers as equivalent to the default SELinux
confined mode. Record the Fedora, driver, toolkit, CDI and Podman versions with every validation.

## Implementation note

The Nix base image is intentionally minimal and its `/usr/share` entry may be a store-backed
symlink. The Containerfile removes that image-local symlink, creates the FHS NVIDIA mount-point
directories including `/usr/share/nvidia`, and leaves driver files to CDI. It does not copy or
install driver files; CDI still supplies them from the Fedora host.

## Result

```text
Date: 2026-08-19
Host: Fedora, amd64, SELinux Enforcing
GPU: NVIDIA GeForce RTX 4060 Laptop GPU
Driver: 610.57.04, CUDA UMD 13.3
Toolkit: NVIDIA Container Toolkit CLI 1.19.1
CDI: passed; GPU index, UUID and `nvidia.com/gpu=all` devices found
Podman: 5.8.4 rootless
secli --nvidia: passed; OpenCode printed complete native help and exited normally
Notes: The first attempt failed because the minimal Nix image used a store-backed `/usr/share`
symlink and CDI could not create `/usr/share/nvidia/nvoptix.bin`. Commit `e61a215` replaces that
image-local symlink with writable FHS mount-point directories. The rebuilt image passed without
errors; no host driver or CDI changes were required.
```
