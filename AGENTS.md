# AGENTS.md

Personal Windows dotfiles. `install.ps1` links repo entries into place; `mise/` is linked as a
junction to `~\.config\mise`, so editing files there edits the live config.

## Layout

- `install.ps1` - bootstrap: installs mise (winget), pins it, creates `*.local.*` from `*.example`, links, `mise install`
- `mise/config.toml` - global tools and settings; `mise/config.local.toml` - machine-specific `[env]` (git-ignored)
- `mise/tasks/` - file tasks (`update`, `update:silent`, `winget:install`, `backup`, `restore`, `wsl:backup`, `wsl:restore`, `docker:backup`, `docker:restore`)
- `mise/lib/` - code shared by tasks (outside `tasks/` so mise doesn't list it); the docker tasks reuse `wsl-common.ps1`
- `winget/*.json` - app lists in `winget export` format

## Conventions

- Tasks are PowerShell 7 (`#Requires -Version 7.4`), run by mise with `pwsh -NoProfile -File`.
- `install.ps1` and `mise/lib/winget-upgrade-runner.ps1` must stay Windows PowerShell 5.1 compatible and ASCII-only.
- English for comments, messages and docs. Errors print `ERROR: ...` and exit 1.
- Keep scripts idempotent; never overwrite user data without a backup.
- Machine-specific values go in `config.local.toml` (plus its `.example`), not in tracked files.
- The silent winget runner executes elevated: it must not use cmdlets or user-writable paths.
- Update `README.md` when adding or changing tasks.

## Verifying changes

There are no tests. Parse scripts with `[System.Management.Automation.Language.Parser]::ParseFile`,
check `mise tasks ls`, and exercise early-failure paths (e.g. `mise run wsl:backup -- -BackupDir Q:\x`).
Don't run tasks that change the system (updates, WSL backup/restore) without asking.

## Git

Conventional Commits with short bodies; commit and push only when asked.
