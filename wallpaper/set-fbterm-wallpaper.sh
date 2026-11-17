#!/usr/bin/env bash
# set-fbterm-wallpaper.sh - change the FbTerm background image.
#
#   set-fbterm-wallpaper.sh <image> [--restart]
#
# It copies the image over ~/.local/share/fbterm-background/wallpaper.png
# (the old one is kept as wallpaper.png.bak). FbTerm only reads that file
# when it starts, so a running FbTerm keeps the old background until it
# restarts. With --restart (or answering yes when asked) the running
# FbTerm is closed and you land back at the login prompt; log in again
# and the new image is there. Closing FbTerm ends your session in it,
# same as typing exit.
set -u

DATA="$HOME/.local/share/fbterm-background"
DEST="$DATA/wallpaper.png"
BACKUP="$DATA/wallpaper.png.bak"
LAUNCHER="$HOME/.local/bin/fbterm-background"

usage() {
    cat <<'EOF'
Usage: set-fbterm-wallpaper.sh <image> [--restart]

Copies <image> as the new FbTerm background. PNG is used as is;
JPG, WebP, GIF and BMP are converted to PNG first (needs ImageMagick,
ffmpeg or python3-PIL on the system).
The previous background is saved as wallpaper.png.bak next to it.

  --restart   If FbTerm is running, close it so the change shows.
              This ends the session inside FbTerm (like exit) and
              returns you to the login prompt. Without this flag the
              script asks first when run interactively inside FbTerm.
  -h, --help  This help.
EOF
}

fail() { echo "set-fbterm-wallpaper: $*" >&2; exit 1; }

SRC=""
DO_RESTART=0
ASK_RESTART=1
for arg in "$@"; do
    case "$arg" in
        --restart) DO_RESTART=1 ;;
        --no-restart) ASK_RESTART=0 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "set-fbterm-wallpaper: unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *)
            [ -z "$SRC" ] || { echo "set-fbterm-wallpaper: too many arguments" >&2; usage >&2; exit 2; }
            SRC="$arg" ;;
    esac
done

[ -n "$SRC" ] || { usage >&2; exit 2; }
# Running as root is fine from a root shell: it changes root's own
# background. But "sudo ..." from a normal user almost always means
# that user wanted their own background changed, not root's.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    fail "you ran this with sudo from user '$SUDO_USER', so it would change root's background, not yours. Run it without sudo, or from a root shell if root's background is really what you want to change."
fi
[ -f "$SRC" ] || fail "image not found: $SRC"
[ -r "$SRC" ] || fail "image is not readable: $SRC"
[ -d "$DATA" ] || fail "$DATA does not exist. Run setup-fbterm-background.sh first."

# --- Get a PNG into a temp file -------------------------------------------
TMP="$(mktemp --suffix=.png "$DATA/.wallpaper-new.XXXXXX")" || fail "could not create a temp file in $DATA"
trap 'rm -f "$TMP"' EXIT

# First bytes of the file, to tell the format apart.
magic="$(head -c 12 "$SRC" | od -An -tx1 | tr -d ' \n')"

is_png=0
case "$magic" in
    89504e47*) is_png=1 ;;
esac

if [ "$is_png" -eq 1 ]; then
    cp -- "$SRC" "$TMP" || fail "could not copy $SRC"
else
    # idump only reads PNG, GIF and BMP, and the installed file must be
    # named wallpaper.png, so anything else becomes PNG here.
    converted=0
    if command -v magick >/dev/null 2>&1; then
        magick -- "$SRC" "$TMP" >/dev/null 2>&1 && converted=1
    elif command -v convert >/dev/null 2>&1; then
        convert -- "$SRC" "$TMP" >/dev/null 2>&1 && converted=1
    elif command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -y -v error -i "$SRC" -frames:v 1 "$TMP" >/dev/null 2>&1 && converted=1
    elif python3 -c 'import PIL' >/dev/null 2>&1; then
        python3 - "$SRC" "$TMP" <<'EOF_PY' >/dev/null 2>&1 && converted=1
import sys
from PIL import Image
Image.open(sys.argv[1]).convert("RGBA").save(sys.argv[2], "PNG")
EOF_PY
    fi
    [ "$converted" -eq 1 ] || fail "could not convert $SRC to PNG. Install a converter, e.g.: sudo apt-get install -y imagemagick (or pass a PNG image)."
fi

# Only replace the current image with something that really is a PNG.
new_magic="$(head -c 4 "$TMP" | od -An -tx1 | tr -d ' \n')"
[ "$new_magic" = "89504e47" ] || fail "the result is not a PNG; the old background was left untouched."
[ -s "$TMP" ] || fail "the resulting image is empty; the old background was left untouched."

# --- Swap it in -------------------------------------------------------------
if [ -f "$DEST" ]; then
    cp -a -- "$DEST" "$BACKUP" || fail "could not write the backup $BACKUP"
fi
chmod 0644 "$TMP"
mv -- "$TMP" "$DEST" || fail "could not install the new background as $DEST"
trap - EXIT

echo "Background changed: $DEST"
[ -f "$BACKUP" ] && echo "Previous background kept as: $BACKUP"

# --- Refresh ------------------------------------------------------------------
# FbTerm captured the framebuffer when it started; it cannot pick up
# the new file on the fly, so "refresh" means restarting FbTerm.
if [ -z "${FBTERM_BACKGROUND_ACTIVE:-}" ]; then
    echo "FbTerm is not running here; the new background shows at the next login."
    if [ "$DO_RESTART" -eq 1 ]; then
        case "$(tty 2>/dev/null || true)" in
            /dev/tty[0-9]*)
                [ -x "$LAUNCHER" ] || fail "launcher not found: $LAUNCHER"
                echo "Starting FbTerm now..."
                exec "$LAUNCHER" ;;
            *)
                echo "Not on a physical TTY, so FbTerm cannot be started from here." ;;
        esac
    fi
    exit 0
fi

# We are inside a running FbTerm.
if [ "$DO_RESTART" -ne 1 ] && [ "$ASK_RESTART" -eq 1 ] && [ -t 0 ]; then
    printf 'Restart FbTerm now to see it? This ends this session. [y/N] '
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) DO_RESTART=1 ;;
        *) echo "Ok, not restarting. The new background shows next time FbTerm starts."; exit 0 ;;
    esac
fi

if [ "$DO_RESTART" -ne 1 ]; then
    echo "FbTerm is still showing the old background. It picks up the new"
    echo "one when it restarts (exit and log in again), or run:"
    echo "  $0 \"$SRC\" --restart"
    exit 0
fi

# Find the FbTerm process above us and close it from a detached helper,
# so this script can finish and print first. SIGKILL fallback in case
# SIGTERM is ignored.
pid="$$"
fbterm_pid=""
while [ "$pid" -gt 1 ] 2>/dev/null; do
    comm="$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')"
    case "$comm" in
        fbterm|fbterm-patched) fbterm_pid="$pid"; break ;;
    esac
    ppid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')"
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    pid="$ppid"
done

[ -n "$fbterm_pid" ] || fail "could not find the running FbTerm process; exit manually to see the new background."

echo "Closing FbTerm (pid $fbterm_pid) in 3 seconds; log in again to see the new background."
setsid sh -c 'sleep 3; kill -TERM "$1" 2>/dev/null; sleep 2; kill -KILL "$1" 2>/dev/null' _ "$fbterm_pid" >/dev/null 2>&1 < /dev/null &
exit 0
