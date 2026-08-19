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

Verified in the development container at the manifest commit:

- Nix package builds successfully on `x86_64-linux`.
- `qoderclicn --version` reports `1.1.25`.
- `qoderclicn --help` runs with a temporary configuration directory.
- A temporary run created Qoder runtime log files but no authentication state.

The following require Fedora host testing: browserless login completion, persisted credentials and
sessions, SELinux mounts, named-volume behavior, native updater behavior after settings are loaded,
and the actual `QODERCN_APPEND_SYSTEM_PROMPT` semantics if that environment variable is needed in a
future template.
