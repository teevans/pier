#!/usr/bin/env bash
# Symlink the pier script onto your PATH. Run `pier setup` afterwards.
set -euo pipefail

SOURCE="$(cd "$(dirname "$0")" && pwd)/pier"
TARGET="${PIER_INSTALL_TARGET:-/usr/local/bin/pier}"

chmod +x "$SOURCE"

if [ ! -d "$(dirname "$TARGET")" ]; then
  sudo mkdir -p "$(dirname "$TARGET")"
fi

if [ -w "$(dirname "$TARGET")" ]; then
  ln -sf "$SOURCE" "$TARGET"
else
  sudo ln -sf "$SOURCE" "$TARGET"
fi

echo "installed: $TARGET → $SOURCE"
echo
echo "next:  pier setup"
