#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: restore_opencode.sh [options]

Restore Codex skills into OpenCode for migration.

Options:
  --archive <path>             Path to Codex backup archive (.tar.gz)
  --target-home <dir>          Target home directory (default: $HOME)
  --skills-dest <dir>          OpenCode skills destination
                               (default: <target-home>/.config/opencode/skills/codex)
  --opencode-config <path>     OpenCode config JSON path
                               (default: <target-home>/.config/opencode/opencode.json)
  --skip-checksum              Skip SHA256SUMS verification
  --dry-run                    Print planned actions only
  --help                       Show this help

Behavior:
  - Extracts skills from backup archive
  - Excludes skills/.system if present
  - Restores skills into OpenCode skills directory
  - Adds skills path to opencode.json under skills.paths
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
SKILLS_DEST=""
OPENCODE_CONFIG=""
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
    --skills-dest)
      SKILLS_DEST="${2:-}"
      shift 2
      ;;
    --opencode-config)
      OPENCODE_CONFIG="${2:-}"
      shift 2
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

if [[ -z "$SKILLS_DEST" ]]; then
  SKILLS_DEST="${TARGET_HOME}/.config/opencode/skills/codex"
fi
if [[ -z "$OPENCODE_CONFIG" ]]; then
  OPENCODE_CONFIG="${TARGET_HOME}/.config/opencode/opencode.json"
fi

require_cmd tar
require_cmd rsync
require_cmd sha256sum
require_cmd jq
require_cmd awk
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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"

tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

if [[ ! -d "$EXTRACT_DIR/skills" ]]; then
  echo "Error: archive does not contain a top-level skills/ directory." >&2
  echo "This script expects a backup generated from backup_codex.sh portable/full profile." >&2
  exit 1
fi

# Enforce user preference: never migrate .system skills.
rm -rf "$EXTRACT_DIR/skills/.system"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EXISTING_SKILLS_BACKUP="${SKILLS_DEST}.pre-restore-${TIMESTAMP}"

echo "OpenCode restore plan:"
echo "- Archive: $ARCHIVE_PATH"
echo "- Skills source: $EXTRACT_DIR/skills"
echo "- Skills destination: $SKILLS_DEST"
echo "- OpenCode config: $OPENCODE_CONFIG"
if [[ -d "$SKILLS_DEST" ]]; then
  echo "- Existing skills destination will be moved to: $EXISTING_SKILLS_BACKUP"
fi

echo "- Skills to restore:"
find "$EXTRACT_DIR/skills" -mindepth 1 -maxdepth 2 | sed "s#^${EXTRACT_DIR}/#  - #"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry-run complete. No changes made."
  exit 0
fi

mkdir -p "$(dirname "$SKILLS_DEST")"
if [[ -d "$SKILLS_DEST" ]]; then
  mv "$SKILLS_DEST" "$EXISTING_SKILLS_BACKUP"
fi
mkdir -p "$SKILLS_DEST"
rsync -a "$EXTRACT_DIR/skills/" "$SKILLS_DEST/"

mkdir -p "$(dirname "$OPENCODE_CONFIG")"
if [[ -f "$OPENCODE_CONFIG" ]]; then
  jq --arg p "$SKILLS_DEST" '
    .skills = (.skills // {})
    | .skills.paths = (((.skills.paths // []) + [$p]) | unique)
  ' "$OPENCODE_CONFIG" > "$TMP_DIR/opencode.json"
else
  jq -n --arg p "$SKILLS_DEST" '{
    "$schema": "https://opencode.ai/config.json",
    "skills": {"paths": [$p]}
  }' > "$TMP_DIR/opencode.json"
fi
mv "$TMP_DIR/opencode.json" "$OPENCODE_CONFIG"
chmod 600 "$OPENCODE_CONFIG" || true

echo "OpenCode skills restoration complete."
echo "- Restored skills dir: $SKILLS_DEST"
echo "- Updated config: $OPENCODE_CONFIG"
if [[ -d "$EXISTING_SKILLS_BACKUP" ]]; then
  echo "- Previous skills backup: $EXISTING_SKILLS_BACKUP"
fi
