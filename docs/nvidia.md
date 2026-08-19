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

The Nix base image is intentionally minimal and does not provide the usual FHS directories used
as CDI mount targets. The Containerfile creates the NVIDIA mount-point directories, including
`/usr/share/nvidia`, before runtime. It does not copy or install driver files; CDI still supplies
those files from the Fedora host.

## Result

```text
Date: pending
Host: pending
Driver: pending
Toolkit: pending
CDI: pending
Podman: pending
secli --nvidia: pending
Notes: pending
```
