# dotfiles

My tools and configuration, linked from this repo into their places on the system.

## Install (Windows)

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

The script is idempotent and safe to re-run. It:

1. Ensures mise is installed, installing it with winget (`jdx.mise`) if missing.
   Update mise with `mise self-update`, not `winget upgrade` (which may overwrite
   a newer version with the older one from the winget repository).
2. Creates missing local files (`*.local.*`, git-ignored) from their `*.local.*.example` templates.
3. Links repo entries to their targets. Directories are linked as junctions (no admin needed),
   files as symlinks (requires Developer Mode or admin). An existing target that is not
   already a link to this repo is moved to `<target>.backup-<date>`.

| Repo   | Target           |
|--------|------------------|
| `mise` | `~\.config\mise` |

## mise

- `mise/config.toml` - global tools
- `mise/config.local.toml` - machine-specific settings (`[env]`, e.g. for the WSL tasks);
  git-ignored, created from `config.local.toml.example` if missing
- `mise/tasks/` - file tasks, e.g. `mise run wsl:backup`, `mise run wsl:restore`
- `mise/lib/` - code shared by the tasks (outside `tasks/` so mise doesn't treat it as a task)

`.ps1` tasks must start with `#!powershell -NoProfile -ExecutionPolicy Bypass -File`
(otherwise mise runs them with `pwsh`) and must be ASCII-only
(Windows PowerShell 5.1 reads BOM-less files as ANSI).

### WSL tasks

| Task          | Description |
|---------------|-------------|
| `wsl:backup`  | Exports the distros in `WSL_BACKUP_DISTROS` to `WSL_BACKUP_DIR\<distro>\` as `.tar.gz`, keeping `WSL_BACKUP_KEEP` copies. Stops Docker Desktop and WSL for a consistent snapshot and restarts Docker afterwards (`-Live` skips this). |
| `wsl:restore` | Verifies the newest backup (or `-Previous` / `-File <path>`), then replaces the distro with it. Installs into the distro's current location, or `WSL_DISTRO_DIR\<distro>` for a new one. Asks for confirmation (`-Force` skips it). |

Settings come from `mise/config.local.toml`; task arguments override them,
e.g. `mise run wsl:backup -- -Keep 3`.
