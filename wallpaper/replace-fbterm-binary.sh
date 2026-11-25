#!/bin/bash
# Replace the patched FbTerm binary with a newer build.
#
# Only /usr/local/bin/fbterm-patched is touched. The fbterm package
# and your ~/.fbtermrc are not modified. The old binary is kept as
# fbterm-patched.bak next to it, put it back with --restore.
#
# With no argument the script builds the binary itself from the
# Debian source plus fbterm-compat.patch (same recipe as the setup
# script), then swaps it in. Or pass a binary you built yourself:
#
#   ./replace-fbterm-binary.sh              build and swap
#   ./replace-fbterm-binary.sh ./fbterm     swap this binary in
#   ./replace-fbterm-binary.sh --restore    put the backup back
#   ./replace-fbterm-binary.sh --check      show what is installed

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/fbterm-compat.patch"
POOL_URL="https://deb.debian.org/debian/pool/main/f/fbterm"
DEST="/usr/local/bin/fbterm-patched"
FORCE=0
MODE=""
NEW_BIN=""

usage() {
    sed -n '2,15p' "$0"
    echo "Options: --dest PATH (default $DEST), --force (allow a binary"
    echo "without GPM mouse support)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)   MODE=check ;;
        --restore) MODE=restore ;;
        --dest)    shift; DEST="${1:?--dest needs a path}" ;;
        --force)   FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)         NEW_BIN="$1"; MODE=swap ;;
    esac
    shift
done
[ -n "$MODE" ] || MODE=build

fail() { echo "replace-fbterm-binary: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Root is only needed to write to the destination directory.
SUDO=""
if [ "$(id -u)" -ne 0 ] && [ ! -w "$(dirname "$DEST")" ]; then
    have_cmd sudo || fail "need root to write to $(dirname "$DEST") and sudo is missing"
    SUDO="sudo"
fi

BACKUP="$DEST.bak"

# The GPM build is the only one with a mouse; it contains this path.
has_gpm() { grep -a -q '/dev/gpmctl' "$1" 2>/dev/null; }

# Only builds with the working slideshow watcher contain this.
has_slideshow() { grep -a -q 'FBG1' "$1" 2>/dev/null; }

check_binary() { # check_binary FILE (a candidate to install)
    [ -f "$1" ] || fail "no such file: $1"
    [ -x "$1" ] || fail "not executable: $1"
    "$1" -V 2>/dev/null | grep -q 'FbTerm version 1.7' \
        || fail "$1 does not look like FbTerm 1.7 (no version output)"
    if ldd "$1" 2>/dev/null | grep -q 'not found'; then
        ldd "$1" | grep 'not found' >&2
        fail "$1 has unresolved shared libraries"
    fi
    if ! has_slideshow "$1" && [ "$FORCE" -ne 1 ]; then
        fail "$1 was built without slideshow support (old patch?).
Rebuild with the current fbterm-compat.patch, or use --force to
install it anyway."
    fi
    if ! has_gpm "$1" && [ "$FORCE" -ne 1 ]; then
        fail "$1 was built without GPM: the mouse will not work inside
FbTerm. Install libgpm-dev and rebuild, or use --force to install
it anyway."
    fi
}

swap_in() { # swap_in FILE [no-backup]
    local new="$1"
    check_binary "$new"

    local had_cap=""
    if [ -e "$DEST" ]; then
        if have_cmd getcap && getcap "$DEST" 2>/dev/null | grep -q 'cap_sys_tty_config'; then
            had_cap=1
        fi
        # On --restore the file being installed IS the backup, so
        # do not overwrite it with the current binary first.
        if [ "${2:-}" != "no-backup" ]; then
            $SUDO cp -a "$DEST" "$BACKUP" || fail "could not back up $DEST"
            echo "Backed up the old binary to $BACKUP"
        fi
    fi

    # Copy next to the destination, then rename: a running FbTerm
    # keeps working and the swap is atomic.
    local tmp="$DEST.new.$$"
    $SUDO install -m 0755 "$new" "$tmp" || fail "could not copy $new"
    $SUDO mv -f "$tmp" "$DEST" || fail "could not move $tmp into place"

    # install(1) drops file capabilities; put the keymap one back.
    if [ -n "$had_cap" ]; then
        if have_cmd setcap || [ -x /usr/sbin/setcap ]; then
            $SUDO "$(command -v setcap || echo /usr/sbin/setcap)" \
                'cap_sys_tty_config+ep' "$DEST" \
                && echo "Restored cap_sys_tty_config on $DEST" \
                || echo "Warning: could not restore cap_sys_tty_config; the '[input]' warning may appear." >&2
        else
            echo "Warning: setcap is missing; the '[input]' keymap warning may appear." >&2
        fi
    fi

    "$DEST" -V 2>/dev/null | grep -q 'FbTerm version 1.7' \
        || fail "the new binary does not run; put the old one back with: $0 --restore"
    if has_gpm "$DEST"; then
        echo "New binary installed: $DEST (with GPM mouse support)"
    else
        echo "New binary installed: $DEST (no GPM mouse support)"
    fi
    echo "Your ~/.fbtermrc and the fbterm package were not touched."
    echo "Restart FbTerm to use the new binary; running sessions keep the old one."
}

build_binary() { # prints the path of the built binary
    local tool
    for tool in g++ make pkg-config autoreconf automake patch tar xz curl; do
        have_cmd "$tool" || fail "missing build tool: $tool
Install the build tools with:
  sudo apt-get install -y --no-install-recommends g++ make pkg-config autoconf automake patch xz-utils curl libfontconfig1-dev libfreetype-dev libgpm-dev"
    done
    [ -f /usr/include/gpm.h ] || fail "gpm.h is missing: without libgpm-dev the mouse cannot work inside FbTerm.
  sudo apt-get install -y --no-install-recommends libgpm-dev"
    pkg-config --exists fontconfig || fail "fontconfig development files missing (libfontconfig1-dev)"
    pkg-config --exists freetype2 || fail "FreeType development files missing (libfreetype-dev)"
    [ -f "$PATCH_FILE" ] || fail "fbterm-compat.patch not found next to this script"

    local work
    work="$(mktemp -d /tmp/fbterm-build.XXXXXX)" || fail "mktemp failed"
    trap 'rm -rf "$work"' EXIT

    echo "Looking up the FbTerm 1.7 Debian source..."
    local listing dsc_name revision f
    listing="$(curl -fsSL "$POOL_URL/")" || fail "could not reach $POOL_URL"
    dsc_name="$(printf '%s\n' "$listing" | grep -oE 'fbterm_1\.7-[0-9]+\.dsc' | sort -Vu | tail -n 1)"
    [ -n "$dsc_name" ] || fail "no fbterm 1.7 source package found in $POOL_URL"
    revision="${dsc_name#fbterm_}"
    revision="${revision%.dsc}"
    for f in "$dsc_name" "fbterm_1.7.orig.tar.gz" "fbterm_${revision}.debian.tar.xz"; do
        curl -fsSL -o "$work/$f" "$POOL_URL/$f" || fail "download failed: $f"
    done

    # Verify SHA-256 against the .dsc (only its Checksums-Sha256 part).
    local name want got
    for name in "fbterm_1.7.orig.tar.gz" "fbterm_${revision}.debian.tar.xz"; do
        want="$(awk -v f="$name" '
            /^Checksums-Sha256:/ { s = 1; next }
            /^[A-Za-z][A-Za-z0-9-]*:/ { s = 0 }
            s && $3 == f { print $1; exit }' "$work/$dsc_name")"
        [ "${#want}" -eq 64 ] || fail "no SHA-256 entry for $name in $dsc_name"
        got="$(sha256sum "$work/$name" | awk '{ print $1 }')"
        [ "$got" = "$want" ] || fail "SHA-256 mismatch for $name"
    done
    echo "Source verified against $dsc_name"

    local src="$work/fbterm-1.7"
    mkdir -p "$src"
    tar xzf "$work/fbterm_1.7.orig.tar.gz" -C "$src" --strip-components=1 || fail "could not extract the source"
    tar xJf "$work/fbterm_${revision}.debian.tar.xz" -C "$src" || fail "could not extract the Debian packaging"
    if [ -f "$src/debian/patches/series" ]; then
        local line patch_name
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            patch_name="${line%% *}"
            patch -p1 -d "$src" -s < "$src/debian/patches/$patch_name" \
                || fail "Debian patch does not apply: $patch_name"
        done < "$src/debian/patches/series"
    fi
    echo "Applying fbterm-compat.patch"
    patch -p1 -d "$src" -s < "$PATCH_FILE" \
        || fail "fbterm-compat.patch does not apply to Debian source $revision. Nothing was installed."

    echo "Building (this takes a minute)..."
    (
        cd "$src" || exit 1
        autoreconf -fi >/dev/null 2>&1 || exit 1
        ./configure --enable-gpm >"$work/configure.log" 2>&1 || { cat "$work/configure.log"; exit 1; }
        make -j"$(nproc 2>/dev/null || echo 2)" >"$work/make.log" 2>&1 || { tail -n 30 "$work/make.log"; exit 1; }
    ) || fail "build failed (see messages above)"
    [ -x "$src/src/fbterm" ] || fail "build finished but src/fbterm is missing"
    has_gpm "$src/src/fbterm" || fail "the built binary has no GPM support (is libgpm-dev installed?)"

    BUILT="$src/src/fbterm"
    trap - EXIT
    BUILD_DIR="$work"
}

case "$MODE" in
    check)
        if [ -x "$DEST" ]; then
            echo "$DEST exists"
            "$DEST" -V 2>/dev/null || true
            if has_gpm "$DEST"; then
                echo "GPM mouse support: yes"
            else
                echo "GPM mouse support: NO (built without libgpm-dev; the mouse will not work inside FbTerm)"
            fi
            if have_cmd getcap; then getcap "$DEST" 2>/dev/null || true; fi
        else
            echo "$DEST does not exist"
            exit 1
        fi
        [ -e "$BACKUP" ] && echo "Backup present: $BACKUP"
        ;;
    restore)
        [ -f "$BACKUP" ] || fail "no backup to restore ($BACKUP does not exist)"
        # Restoring a mouse-less backup is allowed on purpose.
        FORCE=1 swap_in "$BACKUP" no-backup
        ;;
    swap)
        swap_in "$NEW_BIN"
        ;;
    build)
        BUILT=""
        BUILD_DIR=""
        build_binary
        swap_in "$BUILT"
        [ -n "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"
        ;;
esac
