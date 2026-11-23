#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="${ROOT_DIR}/Resources/SharedSupport"

if [ -d "${TARGET_DIR}/.git" ]; then
  echo "Updating rime-ice in ${TARGET_DIR}..."
  git -C "${TARGET_DIR}" pull --ff-only
else
  echo "Cloning rime-ice into ${TARGET_DIR}..."
  rm -rf "${TARGET_DIR}"
  git clone --depth 1 https://github.com/iDvel/rime-ice.git "${TARGET_DIR}"
fi

echo "rime-ice ready at ${TARGET_DIR}"
