# Security Model

secli reduces the host-side impact of an AI coding CLI by making the container boundary and every
host mount explicit. It is not a perfect sandbox and must not be described as one.

## Trust assumptions

- The host user trusts the secli repository, its manifests and the selected image.
- Repository and local manifests are trusted Bash source files. Loading a manifest is equivalent to
  executing its contents.
- Rootless Podman, the host kernel and SELinux provide the container boundary.
- The user reviews CLI approvals, project changes and credentials using the CLI's native controls.

## What the container can access

- The current project, mounted read-write at its physical absolute path.
- Datasets explicitly supplied with `--dataset`, mounted read-only at their absolute paths.
- The selected CLI's complete Home at `/root`, including credentials, sessions and caches.
- The shared `/nix` volume, including profiles, stores and build caches.
- The network, which is required for provider access, Nix installation and project workflows.

## What the container normally cannot access

- Other host projects and datasets that were not explicitly mounted.
- Other CLI Homes and their authentication state.
- The host user's ordinary Home directory.
- Host paths outside the explicit mount set.

The container process runs as root inside the container. Rootless Podman maps that root to the host
user's rootless namespace; this limits host privilege but does not make a compromised process
harmless to mounted project data.

## Important limitations

- The current project is writable. A bad or malicious instruction can delete, modify or exfiltrate
  project content.
- `/nix` is writable by design. CLI subprocesses need it for `nix develop`, builds and Nix-managed
  software. Do not put credentials in `/nix`.
- Network access is enabled. Provider requests, web tools and arbitrary CLI network behavior remain
  possible.
- Native CLI permission settings are recommendations from templates. Users can edit them, and
  secli does not translate one CLI's permission model into another's.
- The CLI may still download files into its Home. secli starts the profile's absolute binary, but
  root inside the container means file permissions are not a complete update defense.
- A malicious project can contain prompt injection instructions. secli does not defend against the
  CLI reading the project it was explicitly asked to work on.

## Mount label policy

- Shared deployment trees use `:z`: `manifest/`, `manifest.local/`, `templates/`, project and
  datasets.
- The selected CLI Home uses `:Z` because it is private to the current container.
- `/root` is a normal bind mount, not an overlay mount.
- `--nvidia` adds `--security-opt=label=disable`, which weakens SELinux label isolation for that
  container and should only be used when GPU access is required.

## Recovery and data handling

- Deleting the `secli-nix-v1` volume removes software profiles, stamps and caches, but not project
  data or CLI Homes.
- Removing a CLI Home removes its credentials and sessions. Back it up before cleanup.
- The container itself uses `--rm` and is not a state store.
- Logs go to stdout/stderr. secli does not write credentials or application logs into the repository
  or image.

## User hardening checklist

1. Keep project data under the configured allowed prefixes.
2. Mount datasets explicitly and use the read-only flag for inputs.
3. Keep Git backups before granting an agent write access.
4. Review and customize each CLI's native permissions after `init`.
5. Keep credentials in the CLI Home only; never add them to manifests, templates or `/nix`.
6. Use `--nvidia` only when needed and understand the SELinux tradeoff.
7. Pin deployments to immutable image tags and review repository changes before updating.
