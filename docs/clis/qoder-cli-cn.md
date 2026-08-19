# Qoder CLI CN

## Source

The repository manifest uses the fixed flake reference:

```text
github:numtide/llm-agents.nix/c4c6673c4c1ceb69d845fa665a714e1273d0acac#qoder-cli-cn
```

The package was inspected at that commit and reports:

- package version: `1.1.25`
- main program: `qoderclicn`
- supported target platforms: `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`
- Linux source: `https://static.qoder.com.cn/qoder-cli-cn/releases/1.1.25/`
- source provenance: binary native code
- update manifest: `https://static.qoder.com.cn/qoder-cli-cn/channels/manifest.json`

The package is the mainland-China service channel and is separate from the international Qoder
CLI package. secli does not distribute this unfree binary in its base image; the container
installs it into the dedicated Qoder profile.

## Home and authentication

The complete Home for this CLI is mounted at `/root` from `state/qoder-cli-cn/home/`.
Qoder CN's user configuration directory is `/root/.qoder-cn`. The official documentation states
that interactive login is available through `/login` and that headless environments print a URL
for manual browser completion. A Personal Access Token can be supplied through
`QODERCN_PERSONAL_ACCESS_TOKEN`; secli does not persist or inject this variable.

The Qoder CN configuration directory also contains sessions, logs, plugins and other native
runtime state. The full Home mount preserves these without needing a list of product-specific
paths.

## Template

`templates/qoder-cli-cn/` mirrors these paths inside `/root`:

```text
.qoder-cn/settings.json
.qoder-cn/AGENTS.md
```

The settings template:

- sets `general.enableAutoUpdate` to `false`;
- leaves the default permission mode in place;
- sets `security.disableYoloMode` to `true`.

The Qoder documentation identifies `~/.qoder-cn/AGENTS.md` as the native user-level memory file.
`RUNTIME_ENV` is empty because the native file location is already inside the mounted Home and no
system-prompt path override is needed. `init` copies the template only when destination files are
missing. Users may edit or replace both files.

## Updates

Qoder CN's official installation documentation says automatic updates are enabled by default and
also documents an `update` command and installer-based upgrades. The template disables the native
automatic updater. This is a recommendation, not a hard container policy: `/nix` remains writable
because projects and CLI subprocesses must be able to use Nix.

The secli profile remains authoritative. The entrypoint starts the profile's absolute
`qoderclicn` path, never a binary downloaded into `/root`. When this manifest pin changes, only the
Qoder profile is reconciled and its stamp is updated after successful installation.

## Verification status

Verified at the manifest commit:

- Nix package builds successfully on `x86_64-linux`.
- `qoderclicn --version` reports `1.1.25`.
- `qoderclicn --help` runs with a temporary configuration directory.
- A temporary run created Qoder runtime log files but no authentication state.
- Fedora rootless Podman preserves Qoder authentication and sessions in the dedicated Home.
- Qoder creates native Home entry/runtime files under `.qoder-cn/entry/`, `.qoder-cn/.bin/` and
  `.qodersec/`; secli still starts the Nix profile's absolute executable.
- Project, dataset, SELinux, port and NVIDIA mount behavior passed the host matrix.

Fedora release-candidate verification with a newly initialized Home confirmed:

- the repository template is copied byte-for-byte before first start;
- Qoder `/settings` shows `Enable Auto Update false` and the default permission mode;
- `general.enableAutoUpdate: false` and `security.disableYoloMode: true` remain in `settings.json`
  after repeated normal TUI starts;
- Qoder may merge authentication, security scan and trusted-directory data into the same settings
  file while preserving template fields;
- `.qoder-cn/entry/` and `.qoder-cn/.bin/` are created as native first-run state, then remain
  byte-stable across subsequent normal starts;
- PID 1 resolves to the Nix store `qoder-cli-cn-1.1.25` binary and its command line uses the
  dedicated `secli-qoder-cli-cn` profile.

An older test Home was initialized before the current template and therefore used Qoder's default
auto-update value. `init` correctly refused to overwrite that existing settings file. Template
updates do not migrate existing Homes; users must compare and merge recommendations manually.

## Automatic-updater test

Do not run `qoderclicn update`; this test checks normal startup only. Verify the resolved native
settings from a project directory:

```bash
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-auth-state
/data/projects/hinnyuu/secli/secli.sh qoder-cli-cn -- \
  config get general.enableAutoUpdate
/data/projects/hinnyuu/secli/secli.sh qoder-cli-cn -- \
  config get security.disableYoloMode
```

Expected values: `false` and `true`.

Snapshot Qoder's native entry/runtime candidates before and after one normal interactive session:

```bash
home="$SECLI_STATE_DIR/qoder-cli-cn/home"
find "$home/.qoder-cn/entry" "$home/.qoder-cn/.bin" -type f \
  -exec sha256sum {} + 2>/dev/null | sort > /tmp/secli-qoder-bin.before
/data/projects/hinnyuu/secli/secli.sh qoder-cli-cn
find "$home/.qoder-cn/entry" "$home/.qoder-cn/.bin" -type f \
  -exec sha256sum {} + 2>/dev/null | sort > /tmp/secli-qoder-bin.after
diff -u /tmp/secli-qoder-bin.before /tmp/secli-qoder-bin.after
```

Expected: normal startup does not replace these candidates with a newer CLI. Other Qoder session,
log, model and cache files may change. While Qoder is running, inspect PID 1 from another terminal:

```bash
podman exec secli /bin/sh -c \
  'readlink -f /proc/1/exe; tr "\0" " " </proc/1/cmdline; printf "\n"'
```

Expected: the executable and command line use the Nix store/profile and do not reference
`.qoder-cn/entry` or `.qoder-cn/.bin`. A Nix wrapper may make `/proc/1/exe` resolve to Bash while
cmdline contains the profile wrapper. Remove only the two temporary snapshot files after recording
the result.

Result: passed on Fedora amd64 during the final `v0.1.0` release-candidate test. Qoder's
`config get` subcommand only exposed `vpc_endpoint` in `1.1.25`; `/settings` and persisted JSON were
used to verify general and security settings.
