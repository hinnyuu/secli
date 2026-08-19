# secli Qoder CN defaults

This file is a recommended starting point for Qoder CN CLI sessions launched by secli.

- The current project is writable and is the only project directory mounted by secli.
- Explicit datasets are read-only inputs. Do not attempt to modify them.
- Keep the default permission mode and do not use bypass or YOLO permissions.
- Use the project's `flake.nix` and `nix develop` for project tools and dependencies.
- Do not use system package managers, installer scripts, `curl | bash`, or CLI self-updaters.
- Do not store credentials in the shared `/nix` tree.
- Verify generated changes and run the project's own tests before reporting completion.

These are user-editable recommendations, not an enforced policy. The project-level `AGENTS.md`
inside a mounted project remains part of the project's own instructions.
