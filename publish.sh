#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
  cat <<'USAGE'
Usage: publish.sh [options]

Run backup script, push to GitHub, and create a release.

Options:
  --backup <codex|opencode|kilocode>  Backup type to run (default: prompt)
  --dry-run                           Show what would be done without making changes
  --help                              Show this help
USAGE
}

BACKUP_TYPE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      BACKUP_TYPE="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
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

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

require_cmd git
require_cmd gh

if [[ -z "$BACKUP_TYPE" ]]; then
  echo "Select backup type to run:"
  echo "  1) codex"
  echo "  2) opencode (not yet available)"
  echo "  3) kilocode (not yet available)"
  echo ""
  read -rp "Enter choice [1-3]: " choice
  case "$choice" in
    1) BACKUP_TYPE="codex" ;;
    2) BACKUP_TYPE="opencode" ;;
    3) BACKUP_TYPE="kilocode" ;;
    *)
      echo "Error: invalid choice" >&2
      exit 1
      ;;
  esac
fi

BACKUP_SCRIPT="backup_${BACKUP_TYPE}.sh"
if [[ ! -x "$BACKUP_SCRIPT" ]]; then
  echo "Error: backup script not found or not executable: $BACKUP_SCRIPT" >&2
  exit 1
fi

echo "=== Step 1: Running backup script ==="
echo "Running: ./$BACKUP_SCRIPT --profile portable --output \"$SCRIPT_DIR\""
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would run backup script"
  LATEST_ARCHIVE="${BACKUP_TYPE}-backup-portable-20260308T120000Z.tar.gz"
else
  ./"$BACKUP_SCRIPT" --profile portable --output "$SCRIPT_DIR"

  LATEST_ARCHIVE=$(ls -t ${BACKUP_TYPE}-backup-portable-*.tar.gz 2>/dev/null | head -1)
  if [[ -z "$LATEST_ARCHIVE" ]]; then
    echo "Error: No backup archive created" >&2
    exit 1
  fi
  echo ""
  echo "Backup created: $LATEST_ARCHIVE"
fi

BASENAME_TIMESTAMP="${LATEST_ARCHIVE%.tar.gz}"
PORTABLE_ARCHIVE="${BACKUP_TYPE}-backup-portable.tar.gz"
PORTABLE_MANIFEST="${BACKUP_TYPE}-backup-portable.manifest.json"
PORTABLE_SHA256SUMS="${BACKUP_TYPE}-backup-portable.SHA256SUMS"

echo ""
echo "=== Step 2: Preparing release files ==="

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would create portable release files:"
  echo "  - $PORTABLE_ARCHIVE"
  echo "  - $PORTABLE_MANIFEST"
  echo "  - $PORTABLE_SHA256SUMS"
else
  cp "$LATEST_ARCHIVE" "$PORTABLE_ARCHIVE"
  cp "${BASENAME_TIMESTAMP}.manifest.json" "$PORTABLE_MANIFEST"
  sha256sum "$PORTABLE_ARCHIVE" "$PORTABLE_MANIFEST" > "$PORTABLE_SHA256SUMS"
  echo "Created:"
  echo "  - $PORTABLE_ARCHIVE"
  echo "  - $PORTABLE_MANIFEST"
  echo "  - $PORTABLE_SHA256SUMS"
fi

echo ""
echo "=== Step 3: Git status ==="
git status --short

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "[DRY RUN] Would commit changes, push to GitHub, and create release"
  exit 0
fi

echo ""
echo "=== Step 4: Committing changes ==="
git add *.sh README.md .gitignore
git commit -m "Update scripts for release" || echo "No changes to commit"

echo ""
echo "=== Step 5: Pushing to GitHub ==="
git push origin main 2>/dev/null || git push origin master 2>/dev/null || {
  echo "Error: could not push to origin" >&2
  exit 1
}

echo ""
echo "=== Step 6: Creating GitHub release ==="

TODAY=$(date -u +%Y%m%d)
EXISTING_TAGS=$(git tag -l "${TODAY}.*" 2>/dev/null | sort -t. -k2 -n)
SEQUENCE=1

if [[ -n "$EXISTING_TAGS" ]]; then
  LAST_TAG=$(echo "$EXISTING_TAGS" | tail -1)
  LAST_SEQ=$(echo "$LAST_TAG" | cut -d. -f2)
  SEQUENCE=$((LAST_SEQ + 1))
fi

NEW_TAG="${TODAY}.${SEQUENCE}"

echo "Creating release: $NEW_TAG"

RELEASE_NOTES="## Release $NEW_TAG

### Quick Install (Copy & Paste)

**Codex:**
\`\`\`bash
(tmpdir=\$(mktemp -d) && trap 'rm -rf \"\$tmpdir\"' EXIT && cd \"\$tmpdir\" && curl -fsSLO https://github.com/chassis-app/bsol-codingagent/releases/latest/download/codex-backup-portable.tar.gz && curl -fsSLO https://github.com/chassis-app/bsol-codingagent/releases/latest/download/codex-backup-portable.SHA256SUMS && curl -fsSLO https://raw.githubusercontent.com/chassis-app/bsol-codingagent/main/restore_codex.sh && bash restore_codex.sh --archive codex-backup-portable.tar.gz)
\`\`\`

**KiloCode:**
\`\`\`bash
(tmpdir=\$(mktemp -d) && trap 'rm -rf \"\$tmpdir\"' EXIT && cd \"\$tmpdir\" && curl -fsSLO https://github.com/chassis-app/bsol-codingagent/releases/latest/download/codex-backup-portable.tar.gz && curl -fsSLO https://github.com/chassis-app/bsol-codingagent/releases/latest/download/codex-backup-portable.SHA256SUMS && curl -fsSLO https://raw.githubusercontent.com/chassis-app/bsol-codingagent/main/restore_kilocode.sh && bash restore_kilocode.sh --archive codex-backup-portable.tar.gz)
\`\`\`

**OpenCode:**
\`\`\`bash
(tmpdir=\$(mktemp -d) && trap 'rm -rf \"\$tmpdir\"' EXIT && cd \"\$tmpdir\" && curl -fsSLO https://github.com/chassis-app/bsol-codingagent/releases/latest/download/codex-backup-portable.tar.gz && curl -fsSLO https://github.com/chassis-app/bsol-codingagent/releases/latest/download/codex-backup-portable.SHA256SUMS && curl -fsSLO https://raw.githubusercontent.com/chassis-app/bsol-codingagent/main/restore_opencode.sh && bash restore_opencode.sh --archive codex-backup-portable.tar.gz)
\`\`\`

### Included Artifacts
- \`${PORTABLE_ARCHIVE}\` - Portable backup of ${BACKUP_TYPE^} skills
- \`${PORTABLE_SHA256SUMS}\` - Checksums for verification
"

gh release create "$NEW_TAG" \
  --title "$NEW_TAG" \
  --notes "$RELEASE_NOTES" \
  "$PORTABLE_ARCHIVE" \
  "$PORTABLE_SHA256SUMS" \
  "$PORTABLE_MANIFEST"

echo ""
echo "=== Done! ==="
echo "Release: https://github.com/chassis-app/bsol-codingagent/releases/tag/$NEW_TAG"

echo ""
echo "=== Cleaning up backup files ==="
rm -f *.tar.gz *.SHA256SUMS *.manifest.json
echo "Cleaned up backup artifacts"
