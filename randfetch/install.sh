#!/usr/bin/env bash
# install.sh - install the random-logo fastfetch function for fish and bash.
#
#   ./install.sh              install (or update) for both shells
#   ./install.sh --uninstall  remove it again
#
# fish:  copies fastfetch.fish to ~/.config/fish/functions/
# bash:  copies fastfetch.bash to ~/.local/share/fastfetch-random/ and
#        adds one marked source line to ~/.bashrc
set -u

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FISH_DEST="$HOME/.config/fish/functions/fastfetch.fish"
BASH_DIR="$HOME/.local/share/fastfetch-random"
BASH_FILE="$BASH_DIR/fastfetch.bash"
BASHRC="$HOME/.bashrc"
MARK_BEGIN='# >>> fastfetch random logo >>>'
MARK_END='# <<< fastfetch random logo <<<'

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$FISH_DEST"
    rm -rf "$BASH_DIR"
    if [ -f "$BASHRC" ] && grep -qF "$MARK_BEGIN" "$BASHRC" && grep -qF "$MARK_END" "$BASHRC"; then
        cp -a "$BASHRC" "$BASHRC.bak-fastfetch-random"
        sed -i "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\.*^$/]/\\&/g')/d" "$BASHRC"
        echo "Removed the block from $BASHRC (backup: $BASHRC.bak-fastfetch-random)"
    fi
    echo "Uninstalled."
    exit 0
fi

# fish
mkdir -p "$(dirname "$FISH_DEST")"
install -m 0644 "$SRC_DIR/fastfetch.fish" "$FISH_DEST"
echo "fish:  $FISH_DEST"

# bash
mkdir -p "$BASH_DIR"
install -m 0644 "$SRC_DIR/fastfetch.bash" "$BASH_FILE"
touch "$BASHRC"
if grep -qF "$MARK_BEGIN" "$BASHRC"; then
    echo "bash:  $BASHRC already loads it (function file updated)"
else
    cat >> "$BASHRC" <<EOF

$MARK_BEGIN
[ -f "$BASH_FILE" ] && . "$BASH_FILE"
$MARK_END
EOF
    echo "bash:  added a source line to $BASHRC"
fi

echo
echo "Done. Open a new shell and run: fastfetch"
echo "Every run picks a random .txt logo from ~/.config/fastfetch/."
