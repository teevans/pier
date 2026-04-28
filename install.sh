#!/usr/bin/env bash
# Copy the pier script onto your PATH. Run `pier setup` afterwards.
set -euo pipefail

SOURCE="$(cd "$(dirname "$0")" && pwd)/pier"
TARGET="${PIER_INSTALL_TARGET:-/usr/local/bin/pier}"

chmod +x "$SOURCE"

if [ ! -d "$(dirname "$TARGET")" ]; then
  sudo mkdir -p "$(dirname "$TARGET")"
fi

if [ -w "$(dirname "$TARGET")" ]; then
  install -m 0755 "$SOURCE" "$TARGET"
else
  sudo install -m 0755 "$SOURCE" "$TARGET"
fi

echo "installed: $TARGET"

TARGET_DIR="$(dirname "$TARGET")"
case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *)
    ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
    LINE="export PATH=\"$TARGET_DIR:\$PATH\""
    if [ ! -f "$ZSHRC" ] || ! grep -Fqx "$LINE" "$ZSHRC"; then
      printf '\n# added by pier install\n%s\n' "$LINE" >> "$ZSHRC"
      echo "added $TARGET_DIR to PATH in $ZSHRC"
      echo "      run 'source $ZSHRC' or open a new shell to pick it up"
    fi
    ;;
esac

echo
echo "next:  pier setup"
