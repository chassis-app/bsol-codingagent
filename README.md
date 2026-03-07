# Codex Backup and Restore Scripts

This repository contains scripts to migrate your Codex setup between machines.

## Files
- `backup_codex.sh`: create a backup archive, manifest, and checksums.
- `restore_codex.sh`: verify and restore an archive to another machine.
- `restore_opencode.sh`: restore Codex skills into OpenCode and update `opencode.json`.
- `restore_kilocode.sh`: restore Codex skills into KiloCode and update `.skill-lock.json`.

## Backup

```bash
./backup_codex.sh --profile portable --output ./backups
```

Profiles:
- `portable`: `skills/` (excluding `skills/.system`), `version.json`
- `full`: portable + history/session/state/log/snapshots
- `secrets`: `auth.json` only

Optional encryption:

```bash
./backup_codex.sh --profile portable --output ./backups --encrypt age --age-recipient <RECIPIENT>
./backup_codex.sh --profile portable --output ./backups --encrypt gpg --gpg-recipient <KEY_ID>
```

## Restore

```bash
./restore_codex.sh --archive ./backups/codex-backup-portable-YYYYMMDDTHHMMSSZ.tar.gz
```

If archive contains `auth.json`, you must opt in:

```bash
./restore_codex.sh --archive <ARCHIVE_PATH> --include-secrets
```

Dry run:

```bash
./restore_codex.sh --archive <ARCHIVE_PATH> --dry-run
```

## Restore To OpenCode

Use this when you want your backed-up Codex skills available in OpenCode.

```bash
./restore_opencode.sh --archive ./backups/codex-backup-portable-YYYYMMDDTHHMMSSZ.tar.gz
```

Dry run:

```bash
./restore_opencode.sh --archive <ARCHIVE_PATH> --dry-run
```

What it does:
- Restores `skills/` into `~/.config/opencode/skills/codex`
- Excludes `skills/.system`
- Adds that path to `~/.config/opencode/opencode.json` under `skills.paths`

## Restore To KiloCode

Use this when you want your backed-up Codex skills available in KiloCode.

```bash
./restore_kilocode.sh --archive ./backups/codex-backup-portable-YYYYMMDDTHHMMSSZ.tar.gz
```

Dry run:

```bash
./restore_kilocode.sh --archive <ARCHIVE_PATH> --dry-run
```

What it does:
- Restores `skills/` into `~/.agents/skills/codex`
- Excludes `skills/.system`
- Updates `~/.agents/.skill-lock.json` to register restored skills

Backup requirement notes for migration:
- For migrating custom skills only: no backup scope change is required (portable/full already include `skills/`).
- For migrating OpenCode provider/auth state too, additionally preserve:
  - `~/.config/opencode/opencode.json` (provider/model configuration)
  - `~/.local/share/opencode/auth.json` (credentials; secret)

## Safety Behavior
- Checksums are verified from `*.SHA256SUMS` before restore.
- Existing `~/.codex` is moved to `~/.codex.pre-restore-<timestamp>`.
- Sensitive file permissions are reapplied when present (for example `auth.json`).
