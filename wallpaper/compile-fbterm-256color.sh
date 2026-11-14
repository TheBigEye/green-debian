#!/usr/bin/env bash
# compile-fbterm-256color.sh - Compile and apply the "fbterm-256color"
# terminfo entry for the fbterm-background setup. English version.
#
# What "fbterm-256color" really is (researched, see sources below):
#   There is no separate fbterm-256color *program*. FbTerm 1.7 already
#   supports 256 colors, but through its own private escape sequences
#   (ESC [ 1 ; n } foreground, ESC [ 2 ; n } background) instead of
#   the xterm-standard ESC [ 38;5;n / 48;5;n. Its upstream terminfo
#   entry already maps terminfo capabilities to those sequences
#   (setaf/setab, colors#256). "fbterm-256color" is that same entry
#   under a second name - the rename is what the AUR fbterm package
#   does (its maintainer: "To enable 256 color mode properly, do
#   export TERM=fbterm-256color"). The renamed entry is useful
#   because many programs decide "this terminal does 256 colors" from
#   the TERM *name* ending in -256color, and tmux setups expect it.
#
# What this script does:
#   1. Compiles fbterm-256color.ti (shipped next to this script)
#      into ~/.terminfo with tic(1). No root needed.
#   2. Verifies the compiled entry with infocmp(1).
#   3. Applies it to an existing fbterm-background installation:
#      in the login-file block installed by
#      install-fbterm-background.sh, the line that used to read
#      "export TERM=fbterm" now reads "export TERM=fbterm-256color"
#      (backup: <file>.bak-fbterm-256color). Newer installers choose
#      fbterm-256color automatically when the entry exists; then
#      this step reports that nothing had to be changed.
#   --uninstall removes the compiled entry and reverts step 3.
#
# Alternate screen: when /usr/local/bin/fbterm-patched exists at
# compile time, the entry also gets smcup/rmcup (ESC[?1049h/l),
# so vim/less/htop use the patched binary's alternate screen.
# With stock fbterm the capability is deliberately not announced.
#
# It does NOT replace or recompile the fbterm binary: stock FbTerm
# already renders the private 256-color sequences. (The AUR patches
# to the fbterm binary add a configurable palette and a different
# config path, not standard 38;5;n support.)
#
# Sources:
#   - FbTerm 1.7 upstream terminfo: fbterm_1.7.orig.tar.gz,
#     terminfo/fbterm (setaf=\E[1;%p1%d}, colors#256)
#   - AUR "fbterm" package: fbterm.patch renames fbterm ->
#     fbterm-256color; maintainer comment on 256-color usage.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TI_FILE="$SCRIPT_DIR/fbterm-256color.ti"
TERMINFO_DIR="$HOME/.terminfo"
COMPILED="$TERMINFO_DIR/f/fbterm-256color"
LOGIN_FILES=("$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile")

usage() {
    echo "Usage: compile-fbterm-256color.sh [--uninstall]"
}

case "${1:-}" in
    "") ;;
    --uninstall) ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Error: too many arguments" >&2; usage >&2; exit 2
fi

revert_term_lines() {
    local f
    for f in "${LOGIN_FILES[@]}"; do
        [ -f "$f" ] || continue
        grep -qF 'fbterm-background (TTY)' "$f" || continue
        if grep -q 'TERM:-.*export TERM=fbterm-256color' "$f"; then
            cp -a "$f" "$f.bak-fbterm-256color"
            sed -i '/TERM:-/s/export TERM=fbterm-256color/export TERM=fbterm/' "$f"
            echo "Reverted TERM to fbterm in $f (backup: $f.bak-fbterm-256color)"
        fi
    done
}

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$COMPILED"
    echo "Removed compiled terminfo entry: $COMPILED"
    revert_term_lines
    echo "Done. The fbterm binary was never modified."
    exit 0
fi

[ -f "$TI_FILE" ] || {
    echo "Error: fbterm-256color.ti is missing next to this script." >&2
    exit 1
}
command -v tic >/dev/null 2>&1 || {
    echo "Error: tic(1) is missing. Install it with:" >&2
    echo "  sudo apt-get install -y ncurses-bin" >&2
    exit 1
}

mkdir -p "$TERMINFO_DIR"

# The alternate screen (smcup/rmcup, used by vim/less/htop via
# ncurses) is announced only when the patched FbTerm binary is
# installed (see build-fbterm-patched.sh). Stock FbTerm ignores
# ESC[?1049h; announcing the capability to it would leave
# full-screen programs without the screen restore they expect.
# With fbterm-patched present, the entry is compiled from a
# temporary copy with two lines added; the shipped
# fbterm-256color.ti stays unchanged either way. (If you remove
# fbterm-patched later, re-run this script.)
TI_SOURCE="$TI_FILE"
ALT_NOTE="alternate screen not announced (stock fbterm)"
if [ -x /usr/local/bin/fbterm-patched ]; then
    TI_SOURCE="$(mktemp)" || {
        echo "Error: mktemp failed" >&2
        exit 1
    }
    awk '{ print } index($0, "fbterm-256color|") == 1 { print "\tsmcup=\\E[?1049h, rmcup=\\E[?1049l," }' \
        "$TI_FILE" > "$TI_SOURCE" || {
        echo "Error: could not prepare the terminfo source" >&2
        rm -f "$TI_SOURCE"
        exit 1
    }
    ALT_NOTE="alternate screen announced (smcup) for fbterm-patched"
fi

tic -x -o "$TERMINFO_DIR" "$TI_SOURCE" || {
    echo "Error: tic failed to compile $TI_SOURCE" >&2
    [ "$TI_SOURCE" != "$TI_FILE" ] && rm -f "$TI_SOURCE"
    exit 1
}
[ "$TI_SOURCE" != "$TI_FILE" ] && rm -f "$TI_SOURCE"
echo "Compiled terminfo entry: $COMPILED ($ALT_NOTE)"

command -v infocmp >/dev/null 2>&1 || {
    echo "Error: infocmp(1) is missing (package ncurses-bin)." >&2
    exit 1
}
infocmp fbterm-256color >/dev/null 2>&1 || {
    echo "Error: infocmp cannot find the new entry; ncurses is not" >&2
    echo "searching $TERMINFO_DIR. Is HOME set correctly?" >&2
    exit 1
}
COLORS="$(TERMINFO="$TERMINFO_DIR" tput -T fbterm-256color colors 2>/dev/null || echo unknown)"
echo "Verified with infocmp/tput: TERM=fbterm-256color reports $COLORS colors; setaf uses FbTerm private sequences."

applied=0
for f in "${LOGIN_FILES[@]}"; do
    [ -f "$f" ] || continue
    grep -qF 'fbterm-background (TTY)' "$f" || continue
    if grep -q 'TERM:-.*export TERM=fbterm-256color' "$f" \
       || grep -q 'infocmp fbterm-256color' "$f"; then
        echo "$f already uses fbterm-256color."
        applied=1
    elif grep -q 'TERM:-.*export TERM=fbterm$' "$f"; then
        cp -a "$f" "$f.bak-fbterm-256color"
        sed -i '/TERM:-/s/export TERM=fbterm$/export TERM=fbterm-256color/' "$f"
        echo "Applied in $f: TERM=fbterm-256color (backup: $f.bak-fbterm-256color)"
        applied=1
    fi
done
[ "$applied" -eq 1 ] || {
    echo "Note: no fbterm-background login block was found, so TERM was"
    echo "not changed automatically. Either run"
    echo "install-fbterm-background.sh first (new versions pick"
    echo "fbterm-256color automatically), or set it manually inside"
    echo "FbTerm:  export TERM=fbterm-256color"
}

cat <<'EOF'

Done. To use it:
  1) Exit FbTerm ("exit") and log in again on the TTY.
  2) Inside FbTerm, check:  echo $TERM        -> fbterm-256color
  3) Color test (terminfo-driven, uses FbTerm's private sequences):
       for i in 0 1 9 34 82 160 196 208 226 255; do
         tput setaf $i; printf ' %s ' "$i"; tput sgr0
       done; echo
     Each number should appear in its own color.
  4) Alternate screen test (only compiled in when fbterm-patched
     was present): run "vim" (or "less <file>") and quit; your
     shell screen, scrollback position included, must come back
     exactly as it was. Check the capability with:
       infocmp fbterm-256color | grep smcup
EOF
