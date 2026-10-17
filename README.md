# dotfiles

My tools and configuration, linked from this repo into their places on the system.

## Install (Windows)

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

The script is idempotent and safe to re-run. It:

1. Ensures mise is installed, installing it with winget (`jdx.mise`) if missing.
   mise updates itself (`mise self-update`), so the script pins it in winget: `winget upgrade --all`
   skips it instead of overwriting a newer version with the older one from the winget repository.
2. Creates missing local files (`*.local.*`, git-ignored) from their `*.local.*.example` templates.
3. Links repo entries to their targets. Directories are linked as junctions (no admin needed),
   files as symlinks (requires Developer Mode or admin). An existing target that is not
   already a link to this repo is moved to `<target>.backup-<date>`.
4. Runs `mise install` to install the tools from `mise/config.toml` (including `pwsh`).

| Repo   | Target           |
|--------|------------------|
| `mise` | `~\.config\mise` |

## mise

- `mise/config.toml` - global tools
- `mise/config.local.toml` - machine-specific settings (`[env]`, e.g. for the WSL tasks);
  git-ignored, created from `config.local.toml.example` if missing
- `mise/tasks/` - file tasks, e.g. `mise run wsl:backup`, `mise run wsl:restore`
- `mise/lib/` - code shared by the tasks (outside `tasks/` so mise doesn't treat it as a task)

mise runs `.ps1` tasks with `pwsh -NoProfile -File` (PowerShell 7, installed by mise);
tasks declare `#Requires -Version 7.4`. `install.ps1` itself must stay compatible with
Windows PowerShell 5.1, since it runs before `pwsh` is installed.

### Update

| Task            | winget                                               | Installer UI | UAC prompts |
|-----------------|------------------------------------------------------|--------------|-------------|
| `update`        | `winget upgrade --all` in the terminal               | yes          | per app     |
| `update:silent` | `winget upgrade --all --silent` via a scheduled task | no           | none        |

Both update all winget apps, then mise itself (`mise self-update`) and the mise tools (`mise upgrade`).
mise is pinned in winget (see `install.ps1`), so only `mise self-update` updates it.
`-SkipWinget` / `-SkipMise` skip a part. Old tool versions are kept (running tools lock their files);
remove them with `mise prune`.

In `update:silent`, winget runs through the `\dotfiles\winget-upgrade` scheduled task ("run with highest privileges"),
so installers get admin rights without UAC prompts; the task's log is streamed to the terminal.
The task is installed on first use, and again whenever `mise/lib/winget-upgrade-runner.ps1` changes,
via `gsudo` - the only UAC prompt. The runner is copied to `%ProgramData%\dotfiles`, writable only by
admins, and runs under the protected Windows PowerShell 5.1 from System32: a user-writable
interpreter or script would let any process on the account run code elevated.

### winget tasks

| Task             | Description |
|------------------|-------------|
| `winget:install` | Installs missing apps from `winget/<list>.json` (default `dev`, e.g. `-- -List dev`). Installed packages are skipped; `-Upgrade` upgrades them too. |

Lists use the `winget export` format. mise itself is not listed: `install.ps1` installs it,
and `winget upgrade` could downgrade a `mise self-update`d binary.

### WSL tasks

| Task          | Description |
|---------------|-------------|
| `wsl:backup`  | Backs up the distros in `WSL_BACKUP_DISTROS` to `WSL_BACKUP_DIR\<distro>\`, keeping `WSL_BACKUP_KEEP` copies. Stops Docker Desktop and WSL, compresses each distro's `ext4.vhdx` to `.vhdx.zst` and restarts Docker afterwards. `-Live` stops nothing and pipes `wsl --export` through zstd to `.tar.zst` instead. |
| `wsl:restore` | Verifies the newest backup (or `-Previous` / `-File <path>`), then replaces the distro with it. Installs into the distro's current location, or `WSL_DISTRO_DIR\<distro>` for a new one. Asks for confirmation (`-Force` skips it). Restores `.vhdx.zst`, `.tar.zst` and older `.tar.gz` backups. |

Settings come from `mise/config.local.toml`; task arguments override them,
e.g. `mise run wsl:backup -- -Keep 3`.

Both tasks need `zstd` (`Meta.Zstandard` in `winget/dev.json`). zstd uses all cores, and compressing
the disk image avoids packing every file through `wsl --export`: on a 48 GB distro the backup took
4.4 min instead of 43 min with `wsl --export --format tar.gz`, and the file was smaller (20.4 vs 21.4 GB).
Disk images are taken only with WSL stopped, as an image of a running distro could be inconsistent.
A restored image has its free space allocated. The restore enables a sparse `.vhdx` and runs `fstrim` to
release it, but WSL currently refuses sparse mode without `--allow-unsafe` (potential data corruption),
so the restore only prints that command and the `.vhdx` keeps its full size (64 GB for the 48 GB distro).
`WSL_BACKUP_ZSTD` (or `-Zstd`) sets the compression options, default `-3 --long`. Higher levels gain little
on a disk image: `-6 --long` took 6.8 min for 19.8 GB, `-9 --long` 9.3 min for 19.5 GB.
