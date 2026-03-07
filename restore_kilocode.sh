#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: restore_kilocode.sh [options]

Restore Codex skills into KiloCode for migration.

Options:
  --archive <path>             Path to Codex backup archive (.tar.gz)
  --target-home <dir>          Target home directory (default: $HOME)
  --skills-dest <dir>          Skills destination directory
                               (default: <target-home>/.agents/skills/codex)
  --skill-lock <path>          Skill lock file path
                               (default: <target-home>/.agents/.skill-lock.json)
  --skip-checksum              Skip SHA256SUMS verification
  --dry-run                    Print planned actions only
  --help                       Show this help

Behavior:
  - Extracts skills from backup archive
  - Excludes skills/.system if present
  - Restores skills into shared agents skills directory
  - Updates .skill-lock.json to register restored skills
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
SKILL_LOCK=""
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
    --skill-lock)
      SKILL_LOCK="${2:-}"
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
  SKILLS_DEST="${TARGET_HOME}/.agents/skills/codex"
fi
if [[ -z "$SKILL_LOCK" ]]; then
  SKILL_LOCK="${TARGET_HOME}/.agents/.skill-lock.json"
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

rm -rf "$EXTRACT_DIR/skills/.system"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EXISTING_SKILLS_BACKUP="${SKILLS_DEST}.pre-restore-${TIMESTAMP}"

echo "KiloCode restore plan:"
echo "- Archive: $ARCHIVE_PATH"
echo "- Skills source: $EXTRACT_DIR/skills"
echo "- Skills destination: $SKILLS_DEST"
echo "- Skill lock file: $SKILL_LOCK"
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

SKILL_NAMES=()
while IFS= read -r skill_dir; do
  if [[ -d "$skill_dir" ]]; then
    skill_name="$(basename "$skill_dir")"
    SKILL_NAMES+=("$skill_name")
  fi
done < <(find "$EXTRACT_DIR/skills" -mindepth 1 -maxdepth 1 -type d)

mkdir -p "$(dirname "$SKILL_LOCK")"
if [[ -f "$SKILL_LOCK" ]]; then
  for skill_name in "${SKILL_NAMES[@]}"; do
    SKILL_MD_PATH="${SKILLS_DEST}/${skill_name}/SKILL.md"
    SKILL_FOLDER_HASH=""
    if [[ -f "$SKILL_MD_PATH" ]]; then
      SKILL_FOLDER_HASH="$(sha256sum "$SKILL_MD_PATH" | awk '{print $1}')"
    fi
    ISO_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    jq --arg n "$skill_name" \
       --arg p "$SKILL_MD_PATH" \
       --arg h "$SKILL_FOLDER_HASH" \
       --arg t "$ISO_TIMESTAMP" '
      .skills = (.skills // {}) |
      .skills[$n] = {
        "source": "codex-backup",
        "sourceType": "backup",
        "sourceUrl": "",
        "skillPath": $p,
        "skillFolderHash": $h,
        "installedAt": $t,
        "updatedAt": $t
      }
    ' "$SKILL_LOCK" > "$TMP_DIR/skill-lock.json"
    mv "$TMP_DIR/skill-lock.json" "$SKILL_LOCK"
  done
else
  SKILL_ENTRIES="{}"
  for skill_name in "${SKILL_NAMES[@]}"; do
    SKILL_MD_PATH="${SKILLS_DEST}/${skill_name}/SKILL.md"
    SKILL_FOLDER_HASH=""
    if [[ -f "$SKILL_MD_PATH" ]]; then
      SKILL_FOLDER_HASH="$(sha256sum "$SKILL_MD_PATH" | awk '{print $1}')"
    fi
    ISO_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    SKILL_ENTRIES="$(echo "$SKILL_ENTRIES" | jq --arg n "$skill_name" \
       --arg p "$SKILL_MD_PATH" \
       --arg h "$SKILL_FOLDER_HASH" \
       --arg t "$ISO_TIMESTAMP" '
      .[$n] = {
        "source": "codex-backup",
        "sourceType": "backup",
        "sourceUrl": "",
        "skillPath": $p,
        "skillFolderHash": $h,
        "installedAt": $t,
        "updatedAt": $t
      }
    ')"
  done
  jq -n --argjson skills "$SKILL_ENTRIES" '{
    "version": 3,
    "skills": $skills,
    "dismissed": {},
    "lastSelectedAgents": ["kilocode"]
  }' > "$SKILL_LOCK"
fi
chmod 600 "$SKILL_LOCK" || true

echo "KiloCode skills restoration complete."
echo "- Restored skills dir: $SKILLS_DEST"
echo "- Updated skill lock: $SKILL_LOCK"
echo "- Restored ${#SKILL_NAMES[@]} skill(s): ${SKILL_NAMES[*]}"
if [[ -d "$EXISTING_SKILLS_BACKUP" ]]; then
  echo "- Previous skills backup: $EXISTING_SKILLS_BACKUP"
fi
