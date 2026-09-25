#!/bin/zsh
set -euo pipefail

REPO_NAME="notch-shelf"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required. Install with: brew install gh"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Authenticate first: gh auth login"
  exit 1
fi

git init
git add .
git commit -m "feat: bootstrap NotchShelf MVP"
git branch -M main
gh repo create "$REPO_NAME" --public --source=. --remote=origin --push

echo "Created and pushed: $(gh repo view --json url -q .url)"
