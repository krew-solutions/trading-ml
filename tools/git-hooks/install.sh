#!/usr/bin/env bash
# Install repo-tracked git hooks by symlinking them into .git/hooks/.
#
# Run once per fresh clone:
#
#     ./tools/git-hooks/install.sh
#
# Symlinks (rather than copies) so future edits to tools/git-hooks/*
# apply without re-running the installer.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
hooks_src="$repo_root/tools/git-hooks"
hooks_dst="$repo_root/.git/hooks"

for src in "$hooks_src"/*; do
  name=$(basename "$src")
  case "$name" in
    install.sh|README*) continue ;;
  esac
  [ -f "$src" ] || continue
  chmod +x "$src"
  ln -sf "../../tools/git-hooks/$name" "$hooks_dst/$name"
  echo "installed: .git/hooks/$name -> tools/git-hooks/$name"
done
