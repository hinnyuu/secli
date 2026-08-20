# Fedora host integration testing

This document records tests that cannot run in the nested development container. Run them on the
target Fedora host with rootless Podman. Record the date, Podman version, architecture and result
under the relevant section after testing.

## Development image and initial Nix volume

Status: verified for image build, empty volume initialization, profile installation, repeat
startup, authentication, mount behavior and normal-start updater stability.

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
- image version is `v0.1.0` for the released image;
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
Date: 2026-08-19
Host architecture: Fedora host, amd64
Podman version: verified >= 5.8.4
SELinux mode: verified expected configuration
Image build: passed; the follow-up build with `nix profile add` completed without the previous alias warning
Empty /nix volume initialization: passed
OpenCode profile/version: passed, `1.18.18`
Qoder CN profile/version: passed, `1.1.25`
Second-start noop: passed for both CLIs
Image entrypoint and labels: passed; image digest `sha256:23c783aa66d3791c70dc976731cb16bb634ffe0488f0112a65b7bb98215748db`
Base tools: passed; git `2.55.0`, ripgrep `15.2.0`
Non-interactive first install: passed after commit `8bd588a`; no flake-config trust prompt appeared
Notes: Host cleanup completed. The expected "There are no packages in the profile" warning is emitted while clearing a fresh profile and is non-fatal.
```

## Mount and port matrix

Status: project and dataset access verified; port mapping verified on Fedora; the probe was removed
after testing.

These checks use a temporary trusted local manifest that runs Nix's Bash instead of an AI CLI. It
does not use credentials. Create the probe resources in the secli deployment:

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

Prepare separate project and dataset directories:

```bash
mkdir -p /tmp/secli-matrix-project /tmp/secli-matrix-dataset
printf 'project\n' >/tmp/secli-matrix-project/project.txt
printf 'dataset\n' >/tmp/secli-matrix-dataset/data.txt
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-matrix-state
./secli.sh init probe
```

Verify both mounts are readable and the project is writable:

```bash
cd /tmp/secli-matrix-project
SECLI_ALLOWED_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe \
  --dataset /tmp/secli-matrix-dataset \
  -- /root/probe.sh read /tmp/secli-matrix-project /tmp/secli-matrix-dataset
SECLI_ALLOWED_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe \
  --dataset /tmp/secli-matrix-dataset \
  -- /root/probe.sh project-write /tmp/secli-matrix-project /tmp/secli-matrix-dataset
test "$(<probe-write.txt)" = write-ok
```

Verify the dataset write is rejected. This command must exit nonzero and the file must not exist:

```bash
if SECLI_ALLOWED_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe \
  --dataset /tmp/secli-matrix-dataset \
  -- /root/probe.sh dataset-write /tmp/secli-matrix-project /tmp/secli-matrix-dataset; then
  printf 'ERROR: read-only dataset write unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -e /tmp/secli-matrix-dataset/probe-write.txt
```

Verify the published address while a container is alive. Run this from the same project directory:

```bash
SECLI_ALLOWED_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe -p 4097 -- -c 'sleep 30' \
  </dev/null >/tmp/secli-port-4097.log 2>&1 &
secli_pid=$!
sleep 2
podman port secli 4097/tcp
kill "$secli_pid" 2>/dev/null || true
wait "$secli_pid" 2>/dev/null || true
```

Expected mapping: `127.0.0.1:4097`. Repeat with explicit external exposure only when intended:

```bash
SECLI_ALLOWED_PREFIXES=/tmp/secli-matrix-project \
  /data/projects/hinnyuu/secli/secli.sh probe -p 0.0.0.0:4098:4098 -- -c 'sleep 30' \
  </dev/null >/tmp/secli-port-4098.log 2>&1 &
secli_pid=$!
sleep 2
podman port secli 4098/tcp
kill "$secli_pid" 2>/dev/null || true
wait "$secli_pid" 2>/dev/null || true
```

Expected mapping: `0.0.0.0:4098`.

Observed during the 2026-08-19 host test:

- Project read/write probe passed.
- Dataset read probe passed and dataset write failed with `Read-only file system`.
- `-p 4097` published `127.0.0.1:4097`.
- `-p 0.0.0.0:4098:4098` published `0.0.0.0:4098`.
- The first attempt inherited an interactive terminal and was stopped by shell job control; the
  commands above now redirect stdin/stdout for reliable background testing.

Cleanup:

```bash
podman rm -f secli 2>/dev/null || true
rm -f /tmp/secli-port-4097.log /tmp/secli-port-4098.log
rm -rf /data/projects/hinnyuu/secli/manifest.local/probe.conf \
  /data/projects/hinnyuu/secli/templates/probe \
  /tmp/secli-matrix-project /tmp/secli-matrix-dataset /tmp/secli-matrix-state
unset SECLI_IMAGE SECLI_STATE_DIR
```

## CLI authentication persistence

Status: authenticated persistence, both port forms and normal-start updater stability verified.

Do not paste credentials, tokens or login URLs into project files, test logs or issue reports.
Test one CLI at a time using a dedicated temporary state root:

```bash
cd /data/projects/tests/test_proj_04
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-auth-state
/data/projects/hinnyuu/secli/secli.sh init opencode
/data/projects/hinnyuu/secli/secli.sh opencode
```

Complete OpenCode's native `/connect` flow, exit normally, restart it and verify it remains
authenticated. Repeat for Qoder CN:

```bash
/data/projects/hinnyuu/secli/secli.sh init qoder-cli-cn
/data/projects/hinnyuu/secli/secli.sh qoder-cli-cn
```

Use Qoder's native `/login` flow. In a headless container it should print a URL for manual browser
completion. Do not put `QODERCN_PERSONAL_ACCESS_TOKEN` in a manifest or template; secli does not
implicitly forward host environment variables into the container.

After each CLI has been restarted successfully, inspect only relative filenames, not contents:

```bash
find /tmp/secli-auth-state/opencode/home -maxdepth 4 -type f -printf '%P\n' | sort
find /tmp/secli-auth-state/qoder-cli-cn/home -maxdepth 4 -type f -printf '%P\n' | sort
```

Expected: state remains in the matching CLI Home and does not appear in the other CLI Home. Remove
the temporary state only after deciding that its login state is no longer needed:

```bash
unset SECLI_IMAGE SECLI_STATE_DIR
rm -rf /tmp/secli-auth-state
```

Observed during the 2026-08-19 host test:

- OpenCode authentication, sessions and provider state persisted after restart under its Home.
- Qoder CN authentication and sessions persisted after restart under its Home.
- Qoder CN created native runtime files under `.qoder-cn/.auth/`, `.qoder-cn/.bin/`,
  `.qoder-cn/entry/`, `.qoder-cn/projects/` and `.qodersec/`. These are expected Home state, not
  secli-managed paths.
- No credentials were placed in manifests, templates or `/nix`.

## Host launcher configuration file

Status: pending host verification.

These steps validate the `config/secli.conf` host configuration file added in `v0.2.0-dev`:
lookup, precedence over built-in defaults, environment-variable override and rejection of
invalid content. They use the fixed development image and a temporary state root, and do not
need credentials.

### Preconditions

Run from the secli repository on the Fedora host with `localhost/secli:dev` already built:

```bash
cd /data/projects/hinnyuu/secli
podman image exists localhost/secli:dev; printf 'image-exists=%s\n' "$?"
test ! -e config/secli.conf || { printf 'move aside your real config first\n'; exit 1; }
```

### Whitelist override and environment precedence

Write a configuration file that whitelists only a temporary project directory:

```bash
mkdir -p /tmp/secli-config-project
printf 'project\n' >/tmp/secli-config-project/project.txt
cat >config/secli.conf <<'EOF'
SECLI_ALLOWED_PREFIXES=/tmp/secli-config-project
SECLI_IMAGE=localhost/secli:dev
SECLI_STATE_DIR=/tmp/secli-config-state
EOF
./secli.sh init opencode
```

Expected: `init` creates the OpenCode Home under `/tmp/secli-config-state`, not under the
repository `state/` directory.

Start from the whitelisted project without exporting any variable:

```bash
cd /tmp/secli-config-project
/data/projects/hinnyuu/secli/secli.sh opencode -- --version
```

Expected: the run succeeds using the configured image and state root.

Confirm the environment variable overrides the configuration file. A project only the
configuration whitelists must be rejected once the environment takes over:

```bash
SECLI_ALLOWED_PREFIXES=/tmp/elsewhere \
  /data/projects/hinnyuu/secli/secli.sh opencode -- --version
```

Expected: nonzero exit; the error names the environment source of the whitelist.

### Invalid content rejection

```bash
printf 'SECLI_BOGUS=1\n' >config/secli.conf
/data/projects/hinnyuu/secli/secli.sh list
```

Expected: nonzero exit; the error reports the file path, line number and supported keys.

### Cleanup

```bash
cd /data/projects/hinnyuu/secli
rm -f config/secli.conf
rm -rf /tmp/secli-config-project /tmp/secli-config-state
```

### Result

Record the result here after host testing:

```text
Date:
Host architecture:
Podman version:
Whitelist override via config:
Environment precedence over config:
State root redirection via config:
Invalid key rejection:
Notes:
```

## Final release verification

Status: passed on Fedora amd64 with a clean CLI state root and a newly created `secli-nix-v1`.

The final `v0.1.0` release was rebuilt from merged `main`. A clean `/tmp/secli-rc-state` was
initialized with `secli.sh init all`; both configuration files matched their repository templates
before first start. First profile installation reported OpenCode `1.18.18` and Qoder CN `1.1.25`,
and repeat version checks were noops.

OpenCode resolved `autoupdate: false` and `share: disabled`, retained its template unchanged, and
did not change updater binary candidates after a normal interactive session. Qoder displayed
`Enable Auto Update false`, retained both updater and YOLO-disable settings after repeated starts,
and kept its native entry/runtime files byte-stable after first-run initialization. Both running
processes resolved to their dedicated Nix store/profile paths rather than Home copies.

All release steps completed without an automatic update, replacement binary or alternate
Home-based startup path.
