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

Verified at the manifest commit:

- Nix package builds successfully on `x86_64-linux`.
- `opencode --version` reports `1.18.18`.
- `opencode --help` runs without creating files in a temporary Home.
- Fedora rootless Podman starts the profile and preserves authentication and sessions in the
  OpenCode Home.
- Project, dataset, SELinux, port and NVIDIA mount behavior passed the host matrix.

Fedora release-candidate verification with a newly initialized Home confirmed:

- the repository template is copied byte-for-byte before first start;
- resolved config contains `autoupdate: false` and `share: disabled`;
- the config remains unchanged after normal startup;
- normal interactive startup does not add or change updater binary candidates under
  `.cache/opencode/bin`;
- PID 1 resolves to the Nix store `opencode-1.18.18` wrapper and its command line uses the dedicated
  `secli-opencode` profile.

An older test Home contained a schema-only config created before the current template. `init` did
not overwrite it, as required by the no-overwrite contract. Template updates do not migrate an
existing Home; users must compare and merge new recommendations manually.

## Automatic-updater test

Do not run `opencode upgrade`; this test checks normal startup only. From a project directory, use
the same state root that already contains the test login:

```bash
export SECLI_IMAGE=localhost/secli:dev
export SECLI_STATE_DIR=/tmp/secli-auth-state
/data/projects/hinnyuu/secli/secli.sh opencode -- debug config \
  | grep -E '"(autoupdate|share)"'
```

Expected resolved values are `autoupdate: false` and `share: disabled`.

Snapshot any updater-managed binary candidates before and after one normal interactive session:

```bash
home="$SECLI_STATE_DIR/opencode/home"
find "$home/.cache/opencode/bin" -type f -exec sha256sum {} + 2>/dev/null \
  | sort > /tmp/secli-opencode-bin.before
/data/projects/hinnyuu/secli/secli.sh opencode
find "$home/.cache/opencode/bin" -type f -exec sha256sum {} + 2>/dev/null \
  | sort > /tmp/secli-opencode-bin.after
diff -u /tmp/secli-opencode-bin.before /tmp/secli-opencode-bin.after
```

Expected: no new or changed updater binary. Session/database/cache changes elsewhere in Home are
normal. While OpenCode is running, inspect PID 1 from another terminal:

```bash
podman exec secli /bin/sh -c \
  'readlink -f /proc/1/exe; tr "\0" " " </proc/1/cmdline; printf "\n"'
```

Expected: the executable and command line use the Nix store/profile and do not reference an
OpenCode binary under `/root`. A Nix wrapper may make `/proc/1/exe` resolve to Bash while cmdline
contains the profile wrapper. Remove only the two temporary snapshot files after recording the
result.

Result: passed on Fedora amd64 during the final `v0.1.0-dev` release-candidate test.
