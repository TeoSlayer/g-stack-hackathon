#!/usr/bin/env bash
# Install gstack-ios into Claude Code's skills directory.
#
# Creates symlinks so editing this repo is reflected immediately:
#   ~/.claude/skills/gstack-ios       → <this repo>/gstack-ios
#   ~/.claude/skills/ios-<sub-skill>  → <this repo>/gstack-ios/skills/<sub-skill>
#
# The pack-level symlink registers the gstack-ios entry-point. Each
# sub-skill symlink registers the slash command (/ios-build, /ios-test, etc.)
# so they're discoverable from the prompt without nested path lookups.

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$HOME/.claude/skills"

if [ ! -d "$SKILLS_ROOT" ]; then
  echo "error: $SKILLS_ROOT does not exist."
  echo "is Claude Code installed? It creates ~/.claude on first run."
  exit 1
fi

link_or_skip() {
  local target="$1"
  local source="$2"
  local label="$3"
  if [ -L "$target" ]; then
    rm "$target"
  elif [ -e "$target" ]; then
    echo "skip: $target exists and is not a symlink. Move/delete it first."
    return 1
  fi
  ln -s "$source" "$target"
  echo "✓ $label"
}

link_or_skip "$SKILLS_ROOT/gstack-ios" "$SOURCE_DIR" \
  "linked pack: ~/.claude/skills/gstack-ios"

count=0
for skill_dir in "$SOURCE_DIR"/skills/*/; do
  skill_name="$(basename "$skill_dir")"
  if link_or_skip "$SKILLS_ROOT/$skill_name" "$skill_dir" \
       "linked skill: /$skill_name"; then
    count=$((count + 1))
  fi
done

echo
echo "installed $count sub-skills."
echo "type / in any Claude Code session to see them in the slash-command list."
