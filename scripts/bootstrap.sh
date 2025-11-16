#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"
if ! command -v git >/dev/null 2>&1; then
  echo "[bootstrap] git not found" >&2
  exit 1
fi
if ! command -v git-lfs >/dev/null 2>&1; then
  echo "[bootstrap] git-lfs not found" >&2
  echo "Install Git LFS: https://git-lfs.github.com/" >&2
  exit 1
fi
if git config --get --bool lfs.fetchrecentalways >/dev/null 2>&1; then
  git lfs install --local
else
  git lfs install --local
fi
git submodule update --init --recursive
git lfs pull
if [ -d "Sources/ZenzCoreMLBackend/zenz-CoreML" ]; then
  (cd Sources/ZenzCoreMLBackend/zenz-CoreML && git lfs pull)
fi
echo "[bootstrap] Done"
