# Host configuration

The host launcher reads an optional configuration file that persists user
settings across shell sessions. The configuration file applies to the git
clone deployment. The Nix package produced by the Flake is a development
verification artifact whose `BASE_DIR` is a read-only Nix store path, so
that scenario is configured through environment variables instead.

## Location and lookup

The launcher reads the first applicable path in this order:

1. The path in the `SECLI_CONFIG` environment variable, when set. A
   missing file here is an error, because the path was requested
   explicitly.
2. `config/secli.conf` in the deployment root. A missing file simply
   keeps the built-in defaults.

Copy `config/secli.conf.example` to `config/secli.conf` and uncomment the
keys you want to change. Recommended file permission is `0600`: values are
paths and image references rather than credentials, but the file is
personal configuration.

## Format

- One `SECLI_KEY=value` assignment per line.
- Empty lines and lines starting with `#` are ignored.
- Leading and trailing whitespace around keys and values is trimmed.
- Unknown keys, malformed lines and empty values are rejected with the
  file path and line number.
- Later assignments to the same key override earlier ones.
- No multi-line values and no append (`+=`) syntax. This keeps the format
  compatible with a future drop-in directory in which later files override
  earlier ones.

The file is parsed as validated data. Unlike manifests, it is never
sourced or executed.

## Precedence

Environment variable > configuration file > built-in default.

## Supported keys

| Key | Meaning | Built-in default |
| --- | --- | --- |
| `SECLI_ALLOWED_PREFIXES` | Colon-separated absolute path prefixes for the project directory | `/data/projects:/data/test:/data/dataset` |
| `SECLI_IMAGE` | Full image reference used by the host launcher | `ghcr.io/hinnyuu/secli:<VERSION>` |
| `SECLI_STATE_DIR` | State root holding the per-CLI Homes | `<deployment root>/state` |

Validation matches the environment-variable behavior: prefixes must be
absolute paths, the image reference must not contain whitespace, and the
state directory must be a non-empty path. The container name and the Nix
volume epoch are architectural constants and are not configurable.

## Example

```text
SECLI_ALLOWED_PREFIXES=/data/projects:/data/test
SECLI_IMAGE=localhost/secli:dev
SECLI_STATE_DIR=/secure/path/secli-state
```
