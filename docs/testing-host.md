# Fedora host integration testing

This document records tests that cannot run in the nested development container. Run them on the
target Fedora host with rootless Podman. Record the date, Podman version, architecture and result
under the relevant section after testing.

## Development image and initial Nix volume

Status: pending Fedora host verification.

These steps validate the initial `Containerfile`, immutable base-image pin, `/nix` named-volume
copy behavior and real installation of both CLI profiles. They use a temporary Home state root but
the fixed development volume `secli-nix-v1`.

### Preconditions

Run from the secli repository on the Fedora host:

```bash
cd /data/projects/hinnyuu/secli
podman --version
podman info --format '{{.Host.Security.Rootless}}'
getenforce
git status --short --branch
```

Expected:

- Podman is at least `5.8.4`.
- The rootless value is `true`.
- SELinux is preferably `Enforcing`.
- The worktree contains only the expected uncommitted Containerfile-stage changes.

Check whether the fixed test volume already exists:

```bash
podman volume exists secli-nix-v1; printf 'volume-exists=%s\n' "$?"
```

Exit status `0` means it exists. Do not remove it if another secli deployment is using it. For this
initial test, remove it only after confirming it contains no needed cache or profiles:

```bash
podman volume rm secli-nix-v1
```

If the volume does not exist, Podman reports that it was not found; continue.

### Build

```bash
podman build \
  --build-arg SECLI_VERSION="$(<VERSION)" \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  --tag localhost/secli:dev \
  --file Containerfile \
  .
```

Expected: the digest-pinned `nixos/nix:2.35.1` base is used, git and ripgrep are installed through
the pinned nixpkgs commit, and the build completes without a system package manager.

Inspect the image:

```bash
podman image inspect localhost/secli:dev \
  --format 'entrypoint={{json .Config.Entrypoint}} version={{index .Labels "org.opencontainers.image.version"}}'
podman run --rm --entrypoint /nix/var/nix/profiles/secli-base/bin/git \
  localhost/secli:dev --version
podman run --rm --entrypoint /nix/var/nix/profiles/secli-base/bin/rg \
  localhost/secli:dev --version
```

Expected:

- entrypoint is `["/entrypoint.sh"]`;
- image version is `v0.1.0-dev`;
- git and ripgrep print versions successfully.

### Empty volume and real CLI profiles

```bash
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-host-test-state
./secli.sh init all
./secli.sh opencode -- --version
./secli.sh qoder-cli-cn -- --version
```

Expected on first use:

- Podman creates and initializes `secli-nix-v1` from the image's `/nix` tree.
- OpenCode is installed into the `secli-opencode` profile and reports `1.18.18`.
- Qoder CN is installed into the `secli-qoder-cli-cn` profile and reports `1.1.25`.
- Both commands exit successfully and the fixed container is removed after each run.

Inspect the resulting profiles and stamps without starting a CLI:

```bash
podman run --rm \
  --entrypoint /nix/var/nix/profiles/default/bin/bash \
  --volume secli-nix-v1:/nix:rw \
  localhost/secli:dev \
  -c 'set -eu; ls -l /nix/var/nix/profiles/per-user/root/secli-*; cat /nix/var/lib/secli/opencode.stamp; cat /nix/var/lib/secli/qoder-cli-cn.stamp'
```

Expected: both profile links exist and both stamps contain the same fixed llm-agents.nix commit,
with their respective `#opencode` and `#qoder-cli-cn` outputs.

Run each version command a second time:

```bash
./secli.sh opencode -- --version
./secli.sh qoder-cli-cn -- --version
```

Expected: neither run prints a profile reconciliation message; both reuse their installed profile.

### Cleanup

After saving all output needed to diagnose failures:

```bash
unset SECLI_IMAGE SECLI_STATE_DIR
rm -rf /tmp/secli-host-test-state
podman volume rm secli-nix-v1
podman image rm localhost/secli:dev
```

The cleanup removes only test Home data, the rebuildable Nix volume and the local development
image. Do not remove a volume that another secli deployment uses.

### Result

Record the result here after host testing:

```text
Date: pending
Host architecture: pending
Podman version: pending
SELinux mode: pending
Image build: pending
Empty /nix volume initialization: pending
OpenCode profile/version: pending
Qoder CN profile/version: pending
Second-start noop: pending
Notes: pending
```
