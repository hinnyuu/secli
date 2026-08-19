# OpenCode

## Source

The repository manifest uses the fixed flake reference:

```text
github:numtide/llm-agents.nix/c4c6673c4c1ceb69d845fa665a714e1273d0acac#opencode
```

The package was inspected at that commit and reports:

- package version: `1.18.18`
- main program: `opencode`
- supported target platforms: `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`
- Linux source: official OpenCode release archives from `github.com/anomalyco/opencode`
- source provenance: binary native code

The Nix package wraps the binary with `fzf` and `ripgrep` from Nix. secli does not distribute the
OpenCode binary in its base image; the container installs this package into its dedicated profile.

## Home and authentication

The complete Home for this CLI is mounted at `/root` from `state/opencode/home/`.
OpenCode's provider credentials are stored under `/root/.local/share/opencode/auth.json`. The
Home also retains sessions, caches and user configuration. Authentication is performed through
OpenCode's native `/connect` flow or provider-specific environment variables.

## Template

`templates/opencode/` mirrors these paths inside `/root`:

```text
.config/opencode/opencode.jsonc
.config/opencode/AGENTS.md
```

The template disables OpenCode's native auto-update and session sharing, and sets read/list/search
operations to allow while leaving side-effecting operations at the native approval boundary.
`init` copies it only when the destination file does not exist. Users may edit or replace both
files.

OpenCode also discovers project-level `AGENTS.md` files from the mounted project. secli does not
replace or make the project's instruction file read-only.

## Updates

OpenCode documents `autoupdate: false` as the native auto-update setting. The template sets it to
false. The secli profile remains authoritative: the entrypoint starts the profile's absolute
`opencode` path, never a binary downloaded into `/root`.

When this manifest pin changes, the next start reconciles only the OpenCode profile and updates
its stamp after successful installation. A failed installation returns nonzero and does not start
the old generation silently.

## Verification status

Verified in the development container at the manifest commit:

- Nix package builds successfully on `x86_64-linux`.
- `opencode --version` reports `1.18.18`.
- `opencode --help` runs without creating files in a temporary Home.

Real authentication, SELinux mounts, named-volume behavior and an interactive Fedora Podman run
remain host integration tests.
