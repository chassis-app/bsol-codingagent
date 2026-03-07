#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: restore_codex.sh [options]

Restore a Codex backup onto this machine.

Options:
  --archive <path>             Path to backup archive (.tar.gz)
  --target-home <dir>          Target home directory (default: $HOME)
  --include-secrets            Allow restoring auth.json if present in archive
  --skip-checksum              Skip SHA256SUMS verification
  --dry-run                    Print actions without applying changes
  --help                       Show this help
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

ARCHIVE_PATH=""
TARGET_HOME="$HOME"
INCLUDE_SECRETS="false"
SKIP_CHECKSUM="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      ARCHIVE_PATH="${2:-}"
      shift 2
      ;;
    --target-home)
      TARGET_HOME="${2:-}"
      shift 2
      ;;
    --include-secrets)
      INCLUDE_SECRETS="true"
      shift
      ;;
    --skip-checksum)
      SKIP_CHECKSUM="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$ARCHIVE_PATH" ]]; then
  echo "Error: --archive is required" >&2
  usage
  exit 1
fi

require_cmd tar
require_cmd sha256sum
require_cmd rsync
require_cmd date

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Error: archive not found: $ARCHIVE_PATH" >&2
  exit 1
fi

ARCHIVE_DIR="$(cd "$(dirname "$ARCHIVE_PATH")" && pwd)"
ARCHIVE_FILE="$(basename "$ARCHIVE_PATH")"
SHA_FILE_CANDIDATE="${ARCHIVE_DIR}/${ARCHIVE_FILE%.tar.gz}.SHA256SUMS"

if [[ "$SKIP_CHECKSUM" != "true" ]]; then
  if [[ ! -f "$SHA_FILE_CANDIDATE" ]]; then
    echo "Error: checksum file not found: $SHA_FILE_CANDIDATE" >&2
    echo "Hint: pass --skip-checksum if you intentionally want to bypass verification." >&2
    exit 1
  fi

  if ! awk -v f="$ARCHIVE_FILE" '$2==f {found=1} END {exit(found?0:1)}' "$SHA_FILE_CANDIDATE"; then
    echo "Error: checksum file does not contain an entry for $ARCHIVE_FILE" >&2
    exit 1
  fi

  (
    cd "$ARCHIVE_DIR"
    awk -v f="$ARCHIVE_FILE" '$2==f' "$(basename "$SHA_FILE_CANDIDATE")" | sha256sum -c -
  )
fi

if tar -tzf "$ARCHIVE_PATH" | grep -qx 'auth.json'; then
  if [[ "$INCLUDE_SECRETS" != "true" ]]; then
    echo "Error: archive contains auth.json; rerun with --include-secrets to allow restoring secrets." >&2
    exit 1
  fi
fi

TARGET_CODEX_DIR="${TARGET_HOME}/.codex"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_OLD_DIR="${TARGET_HOME}/.codex.pre-restore-${TIMESTAMP}"

TMP_DIR="$(mktemp -d)"
EXTRACT_DIR="${TMP_DIR}/extracted"
mkdir -p "$EXTRACT_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

echo "Restore plan:"
echo "- Archive: $ARCHIVE_PATH"
echo "- Target:  $TARGET_CODEX_DIR"
if [[ -d "$TARGET_CODEX_DIR" ]]; then
  echo "- Existing target will be moved to: $BACKUP_OLD_DIR"
else
  echo "- No existing ~/.codex found"
fi

echo "- Files from archive:"
find "$EXTRACT_DIR" -mindepth 1 -maxdepth 3 | sed "s#^${EXTRACT_DIR}/#  - #"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry-run complete. No changes made."
  exit 0
fi

if [[ -d "$TARGET_CODEX_DIR" ]]; then
  mv "$TARGET_CODEX_DIR" "$BACKUP_OLD_DIR"
fi

mkdir -p "$TARGET_CODEX_DIR"
rsync -a "$EXTRACT_DIR/" "$TARGET_CODEX_DIR/"

chmod 700 "$TARGET_CODEX_DIR" || true
if [[ -f "$TARGET_CODEX_DIR/config.toml" ]]; then
  chmod 600 "$TARGET_CODEX_DIR/config.toml"
fi
if [[ -f "$TARGET_CODEX_DIR/auth.json" ]]; then
  chmod 600 "$TARGET_CODEX_DIR/auth.json"
fi

echo "Restore complete: $TARGET_CODEX_DIR"
if [[ -d "$BACKUP_OLD_DIR" ]]; then
  echo "Previous directory backup: $BACKUP_OLD_DIR"
fi
