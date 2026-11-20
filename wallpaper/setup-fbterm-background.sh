#!/usr/bin/env bash
# setup-fbterm-background.sh - wallpaper + classic 8x16 font + fastfetch
# on Debian TTYs (FbTerm, no X11). English version.
#
# Phases, in order:
#   1 core      packages (fbterm, fastfetch), wallpaper, idump viewer,
#               Default8x16 font, ~/.fbtermrc, launcher, profile block
#   2 patched   builds fbterm-compat.patch into /usr/local/bin/
#               fbterm-patched (xterm colours/OSC, alternate screen);
#               stock /usr/bin/fbterm is not touched
#   3 terminfo  fbterm-256color entry in ~/.terminfo and /etc/terminfo
#               (the system copy is what root finds under sudo;
#               smcup announced only when the patched binary exists)
# Then everything is verified; any failure exits non-zero.
# --uninstall removes phases 3, 2, 1 in that order and verifies.
# APT packages are never removed by this script.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FONT_NAME="Default8x16"   # bundled classic 8x16 bitmap font
FONT_SIZE=16              # FbTerm font size (~/.fbtermrc)
FONT_WIDTH=8              # forced classic console cell width
FONT_HEIGHT=16            # forced classic console cell height
BACKGROUND_MODE="cover"   # cover = fill the real display, cropping
                          # fit   = original image, complete and centered
BACKGROUND_BRIGHTNESS=35   # percent: 100 = original, lower = darker
# ------------------------------------------------------------------------------

DEST_BIN="$HOME/.local/bin/fbterm-background"
DEST_IDUMP="$HOME/.local/bin/idump"
DEST_DATA="$HOME/.local/share/fbterm-background"
DEST_CONFIG_DIR="$HOME/.config/fbterm-background"
DEST_FONT_DIR="$HOME/.local/share/fonts/fbterm-background"
DEST_FONTCONFIG_DIR="$HOME/.config/fontconfig/conf.d"
DEST_FONTCONFIG_FILE="$DEST_FONTCONFIG_DIR/70-fbterm-background-bitmap.conf"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

MARK_BEGIN='# >>> fbterm-background (TTY) >>>'
MARK_END='# <<< fbterm-background (TTY) <<<'
SOURCE_BEGIN='# >>> fbterm-background profile-source >>>'
SOURCE_END='# <<< fbterm-background profile-source <<<'
LEGACY_BEGIN='# >>> fbterm-fondo (TTY) >>>'
LEGACY_END='# <<< fbterm-fondo (TTY) <<<'

PROFILE_CANDIDATES=("$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile")
FISH_CONFIG="$HOME/.config/fish/config.fish"
FISH_MARK_BEGIN='# >>> fbterm-background fish (TTY) >>>'
FISH_MARK_END='# <<< fbterm-background fish (TTY) <<<'

# Patched FbTerm (build phase) and terminfo phase.
PATCH_FILE="$SCRIPT_DIR/fbterm-compat.patch"
POOL_URL="https://deb.debian.org/debian/pool/main/f/fbterm"
DEST_PATCHED="/usr/local/bin/fbterm-patched"
TI_FILE="$SCRIPT_DIR/fbterm-256color.ti"
TERMINFO_DIR="$HOME/.terminfo"
TERMINFO_COMPILED="$TERMINFO_DIR/f/fbterm-256color"
TERMINFO_SYS_DIR="/etc/terminfo"
TERMINFO_SYS_COMPILED="$TERMINFO_SYS_DIR/f/fbterm-256color"

USE_APT=1
ALLOW_ROOT=0
SKIP_PATCHED=0
REBUILD_IDUMP=0
UNINSTALL=0
SEEN_FLAGS=""

usage() {
    cat <<'EOF'
Usage:
  setup-fbterm-background.sh [--no-apt] [--allow-root] [--no-patched]
                             [--rebuild-idump]
  setup-fbterm-background.sh --uninstall

Options:
  --no-apt        Do not install APT packages; only warn about missing
                  ones (also skips build dependencies).
  --allow-root    Allow running as root (installs into root's home).
  --no-patched    Skip compiling the patched FbTerm (stock binary only;
                  fastfetch keeps the Perl filter, no alternate screen).
  --rebuild-idump Rebuild the bundled idump viewer from source first
                  (only needed on non-x86_64 machines).
  --uninstall     Remove everything (terminfo, patched binary, core).
  -h, --help      Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --no-apt) USE_APT=0; SEEN_FLAGS="$SEEN_FLAGS --no-apt" ;;
        --allow-root) ALLOW_ROOT=1; SEEN_FLAGS="$SEEN_FLAGS --allow-root" ;;
        --no-patched) SKIP_PATCHED=1; SEEN_FLAGS="$SEEN_FLAGS --no-patched" ;;
        --rebuild-idump) REBUILD_IDUMP=1; SEEN_FLAGS="$SEEN_FLAGS --rebuild-idump" ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *) echo "Unexpected argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$UNINSTALL" -eq 1 ] && [ -n "$SEEN_FLAGS" ]; then
    echo "Error: --uninstall cannot be combined with:$SEEN_FLAGS" >&2
    exit 2
fi

# Running as root would install everything into root's home directory,
# leaving the real user with nothing. Refuse unless explicitly allowed.
if [ "$(id -u)" -eq 0 ] && [ "$ALLOW_ROOT" -ne 1 ] && [ "$UNINSTALL" -ne 1 ]; then
    echo "Error: do not run this as root; it would install into root's" >&2
    echo "home directory. Run it as your normal user (sudo is used" >&2
    echo "internally where needed), or pass --allow-root." >&2
    exit 1
fi

# sudo prefix for the phases that need it (empty when already root).
SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

# setcap/getcap live in /usr/sbin, which many user PATHs lack.
SETCAP="$(command -v setcap || true)"; [ -n "$SETCAP" ] || SETCAP=/usr/sbin/setcap
GETCAP="$(command -v getcap || true)"; [ -n "$GETCAP" ] || GETCAP=/usr/sbin/getcap

# Remove a marker-delimited block from a profile file.
# Safety rule: the range is deleted ONLY if a begin marker exists and an
# end marker exists AFTER it. A missing or out-of-order end marker means
# the file is left completely untouched (return code 3) instead of
# deleting everything from the begin marker to the end of the file.
# Returns: 0 = removed or nothing to remove, 3 = malformed block.
remove_block() {
    local file="$1" begin="$2" end="$3"
    [ -f "$file" ] || return 0
    local begin_line end_line
    begin_line="$(grep -n -m 1 -F -- "$begin" "$file" | cut -d: -f1 || true)"
    [ -n "$begin_line" ] || return 0
    end_line="$(awk -v b="$begin" -v e="$end" '
        $0 == b { seen = 1; next }
        seen && $0 == e { print NR; exit }
    ' "$file")"
    if [ -z "$end_line" ]; then
        echo "Warning: malformed block in $file: begin marker at line" >&2
        echo "$begin_line has no end marker after it. The file was NOT" >&2
        echo "modified. Fix or remove that block manually, then retry." >&2
        return 3
    fi
    cp -a "$file" "$file.bak-fbterm-background"
    sed -i "${begin_line},${end_line}d" "$file"
    echo "Block removed from $file (backup: $file.bak-fbterm-background)"
}

# Remove every block owned by this installer (current and legacy) from a
# single file. Returns 3 if any block in the file is malformed.
clean_profile_file() {
    local file="$1" rc=0
    remove_block "$file" "$MARK_BEGIN" "$MARK_END" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    remove_block "$file" "$SOURCE_BEGIN" "$SOURCE_END" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    remove_block "$file" "$LEGACY_BEGIN" "$LEGACY_END" || rc=$?
    return "$rc"
}


uninstall_core() {
    remove_block "$FISH_CONFIG" "$FISH_MARK_BEGIN" "$FISH_MARK_END" >/dev/null || true
    for f in "${PROFILE_CANDIDATES[@]}"; do
        clean_profile_file "$f" >/dev/null || true
    done
    # Current files.
    rm -f "$DEST_BIN" "$DEST_IDUMP" "$DEST_FONTCONFIG_FILE"
    rm -rf "$HOME/.cache/fbterm-background" "$DEST_CONFIG_DIR" "$DEST_DATA" \
           "$DEST_FONT_DIR"
    # Legacy files from the previous (Spanish) version.
    rm -f "$HOME/.local/bin/fbterm-fondo"
    rm -rf "$HOME/.cache/fbterm-fondo" "$HOME/.config/fbterm-fondo" \
           "$HOME/.local/share/fbterm-fondo"
    # Only remove ~/.fbtermrc if this installer created it.
    if [ -f "$HOME/.fbtermrc" ] \
       && grep -qF '# Created by fbterm-background installer' "$HOME/.fbtermrc"; then
        rm -f "$HOME/.fbtermrc"
        echo "Removed ~/.fbtermrc (created by this installer)."
    fi
}


uninstall_patched() {
    if [ -e "$DEST_PATCHED" ]; then
        $SUDO rm -f "$DEST_PATCHED" || return 1
        echo "Removed $DEST_PATCHED."
    else
        echo "$DEST_PATCHED does not exist; nothing to remove."
    fi
}

ensure_keymap_cap() {
    # Remapping the console keymap (KDSKBENT) needs CAP_SYS_TTY_CONFIG.
    # Without it FbTerm prints "[input] can't change kernel keymap
    # table..." into the first shell at every start; the print happens
    # in the child process with the pty as stdout, so no redirect can
    # catch it. Granting the capability is the fix from the man page
    # (and it makes FbTerm's shortcuts work).
    [ -x "$DEST_PATCHED" ] || return 0
    if [ -x "$GETCAP" ] && "$GETCAP" "$DEST_PATCHED" 2>/dev/null | grep -q 'cap_sys_tty_config'; then
        echo "CAP_SYS_TTY_CONFIG already set on $DEST_PATCHED"
        return 0
    fi
    if [ ! -x "$SETCAP" ] && [ "$USE_APT" -eq 1 ]; then
        echo "Installing libcap2-bin (provides setcap)..."
        $SUDO apt-get install -y --no-install-recommends libcap2-bin || return 1
    fi
    [ -x "$SETCAP" ] || { echo "setcap is not available" >&2; return 1; }
    echo "Setting CAP_SYS_TTY_CONFIG on $DEST_PATCHED..."
    $SUDO "$SETCAP" 'cap_sys_tty_config+ep' "$DEST_PATCHED"
}

build_patched() (
    DEST="$DEST_PATCHED"
    DO_APT=$USE_APT
    # A binary built without libgpm-dev runs fine but has no mouse:
    # configure silently disables GPM when gpm.h is missing. Only
    # skip the build when the installed binary really has mouse
    # support (the GPM build contains the /dev/gpmctl path).
    if [ -x "$DEST" ] && "$DEST" -V 2>/dev/null | grep -q 'FbTerm version 1.7' \
       && grep -a -q '/dev/gpmctl' "$DEST" 2>/dev/null; then
        echo "Patched FbTerm already installed and working: $DEST"
        echo "Skipping the build. To force a rebuild (e.g. after a"
        echo "patch update), remove it first:  sudo rm $DEST"
        exit 0
    fi
    if [ -x "$DEST" ]; then
        echo "Existing $DEST has no GPM mouse support; rebuilding it."
    fi
    fail() { echo "setup (patched fbterm): $*" >&2; exit 1; }
    have_cmd() { command -v "$1" >/dev/null 2>&1; }
    download() { if have_cmd curl; then curl -fsSL "$1"; elif have_cmd wget; then wget -qO- "$1"; else return 1; fi; }
    download_to() { if have_cmd curl; then curl -fsSL -o "$2" "$1"; elif have_cmd wget; then wget -qO "$2" "$1"; else return 1; fi; }
    [ -f "$PATCH_FILE" ] || fail "fbterm-compat.patch not found next to this script (expected: $PATCH_FILE)"

    # --- Build dependencies --------------------------------------------------------
    missing_pkgs=""

    need_pkg_for_cmd() { # need_pkg_for_cmd COMMAND PACKAGE
        have_cmd "$1" || missing_pkgs="$missing_pkgs $2"
    }

    need_pkg_for_cmd g++ g++
    need_pkg_for_cmd make make
    need_pkg_for_cmd pkg-config pkg-config
    need_pkg_for_cmd autoreconf autoconf
    need_pkg_for_cmd automake automake
    need_pkg_for_cmd patch patch
    need_pkg_for_cmd tar tar
    need_pkg_for_cmd xz xz-utils
    need_pkg_for_cmd sha256sum coreutils
    if ! have_cmd curl && ! have_cmd wget; then
        missing_pkgs="$missing_pkgs curl"
    fi

    # pkg-config module -> Debian -dev package (first available name wins)
    pick_dev_pkg() { # pick_dev_pkg MODULE CANDIDATE...
        local module="$1"; shift
        if pkg-config --exists "$module" 2>/dev/null; then
            return 0
        fi
        local cand
        for cand in "$@"; do
            if apt-cache show "$cand" >/dev/null 2>&1; then
                missing_pkgs="$missing_pkgs $cand"
                return 0
            fi
        done
        missing_pkgs="$missing_pkgs $1"
    }

    if have_cmd pkg-config || [ "$DO_APT" -eq 1 ]; then
        pick_dev_pkg fontconfig libfontconfig1-dev libfontconfig-dev
        pick_dev_pkg freetype2 libfreetype-dev libfreetype6-dev
    fi

    # gpm.h (libgpm-dev) decides whether the mouse works inside
    # FbTerm; without it configure quietly builds a mouse-less
    # binary. The runtime also needs the gpm daemon itself.
    if [ ! -f /usr/include/gpm.h ]; then
        missing_pkgs="$missing_pkgs libgpm-dev"
    fi
    [ -x /usr/sbin/gpm ] || have_cmd gpm || missing_pkgs="$missing_pkgs gpm"

    if [ -n "$missing_pkgs" ]; then
        if [ "$DO_APT" -eq 1 ]; then
            echo "Installing build dependencies:$missing_pkgs"
            # shellcheck disable=SC2086
            $SUDO apt-get update || fail "apt-get update failed"
            # shellcheck disable=SC2086
            $SUDO apt-get install -y --no-install-recommends $missing_pkgs \
                || fail "could not install build dependencies"
        else
            fail "missing build tools:$missing_pkgs (rerun without --no-apt, or install them manually)"
        fi
    fi

    # Re-check after any installation.
    for tool in g++ make pkg-config autoreconf automake patch tar xz sha256sum; do
        have_cmd "$tool" || fail "still missing: $tool"
    done
    pkg-config --exists fontconfig || fail "fontconfig development files missing (libfontconfig1-dev)"
    pkg-config --exists freetype2 || fail "FreeType development files missing (libfreetype-dev)"

    # --- Download the Debian source ------------------------------------------------
    WORK_DIR="$(mktemp -d /tmp/fbterm-build.XXXXXX)" || fail "could not create a temp dir"
    trap 'rm -rf "$WORK_DIR"' EXIT

    echo "Looking up the FbTerm 1.7 Debian source in $POOL_URL ..."
    listing="$(download "$POOL_URL/")" || fail "could not download the pool listing from $POOL_URL"
    dsc_name="$(printf '%s\n' "$listing" | grep -oE 'fbterm_1\.7-[0-9]+\.dsc' | sort -Vu | tail -n 1)"
    [ -n "$dsc_name" ] || fail "no fbterm 1.7 source package found in $POOL_URL"
    revision="${dsc_name#fbterm_}"
    revision="${revision%.dsc}"
    orig_name="fbterm_1.7.orig.tar.gz"
    debian_name="fbterm_${revision}.debian.tar.xz"
    echo "Using Debian source revision $revision"

    for f in "$dsc_name" "$orig_name" "$debian_name"; do
        download_to "$POOL_URL/$f" "$WORK_DIR/$f" || fail "download failed: $POOL_URL/$f"
    done

    # Verify SHA-256 against the .dsc. The file also carries a
    # Checksums-Sha1 section (and MD5 in Files:), so only look inside
    # the Checksums-Sha256 section.
    verify_sha256() { # verify_sha256 FILE
        local want got
        want="$(awk -v f="$1" '
            /^Checksums-Sha256:/ { s = 1; next }
            /^[A-Za-z][A-Za-z0-9-]*:/ { s = 0 }
            s && $3 == f { print $1; exit }
        ' "$WORK_DIR/$dsc_name")"
        [ "${#want}" -eq 64 ] || fail "no SHA-256 entry for $1 in $dsc_name"
        got="$(sha256sum "$WORK_DIR/$1" | awk '{ print $1 }')"
        [ "$got" = "$want" ] || fail "SHA-256 mismatch for $1 (corrupted download?)"
    }

    verify_sha256 "$orig_name"
    verify_sha256 "$debian_name"
    echo "SHA-256 verified against $dsc_name."

    # --- Extract and patch ---------------------------------------------------------
    SRC_DIR="$WORK_DIR/fbterm-1.7"
    mkdir -p "$SRC_DIR"
    tar xzf "$WORK_DIR/$orig_name" -C "$SRC_DIR" --strip-components=1 || fail "could not extract $orig_name"
    tar xJf "$WORK_DIR/$debian_name" -C "$SRC_DIR" || fail "could not extract $debian_name"

    if [ -f "$SRC_DIR/debian/patches/series" ]; then
        while IFS= read -r line; do
            case "$line" in
                ''|'#'*) continue ;;
            esac
    patch_name="${line%% *}"
            echo "Applying Debian patch: $patch_name"
            patch -p1 -d "$SRC_DIR" -s < "$SRC_DIR/debian/patches/$patch_name" \
                || fail "Debian patch does not apply: $patch_name"
        done < "$SRC_DIR/debian/patches/series"
    fi

    echo "Applying fbterm-compat.patch"
    patch -p1 -d "$SRC_DIR" -s < "$PATCH_FILE" || fail "fbterm-compat.patch does not apply to Debian source $revision; the parser sources changed upstream. Nothing was installed."

    # --- Build -----------------------------------------------------------------------
    echo "Building (autoreconf + configure + make)..."
    (
        cd "$SRC_DIR" || exit 1
        autoreconf -fi >/dev/null 2>&1 || exit 1
        ./configure --enable-gpm >"$WORK_DIR/configure.log" 2>&1 || { cat "$WORK_DIR/configure.log"; exit 1; }
        make -j"$(nproc 2>/dev/null || echo 2)" >"$WORK_DIR/make.log" 2>&1 || { tail -n 30 "$WORK_DIR/make.log"; exit 1; }
    ) || fail "build failed (see messages above)"

    [ -x "$SRC_DIR/src/fbterm" ] || fail "build finished but src/fbterm is missing"
    grep -a -q '/dev/gpmctl' "$SRC_DIR/src/fbterm" \
        || fail "the built fbterm has no GPM mouse support (is libgpm-dev installed?)"

    # --- Install ----------------------------------------------------------------------
    echo "Installing $DEST"
    $SUDO install -m 0755 "$SRC_DIR/src/fbterm" "$DEST" || fail "could not install $DEST"

    version_out="$("$DEST" -V 2>/dev/null || true)"
    case "$version_out" in
        *"FbTerm version 1.7"*) echo "Smoke test OK: $version_out" ;;
        *) echo "Warning: '$DEST -V' printed: $version_out" >&2 ;;
    esac
    if ldd "$DEST" 2>/dev/null | grep -q "not found"; then
        echo "Warning: $DEST has unresolved shared libraries:" >&2
        ldd "$DEST" | grep "not found" >&2
    fi
)

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


terminfo_uninstall() {
    rm -f "$TERMINFO_COMPILED"
    echo "Removed compiled terminfo entry: $TERMINFO_COMPILED"
    if [ -e "$TERMINFO_SYS_COMPILED" ]; then
        $SUDO rm -f "$TERMINFO_SYS_COMPILED"
        echo "Removed system terminfo entry: $TERMINFO_SYS_COMPILED"
    fi
    revert_term_lines
}

terminfo_install() {
    [ -f "$TI_FILE" ] || {
        echo "Error: fbterm-256color.ti is missing next to this script." >&2
        return 1
    }
    command -v tic >/dev/null 2>&1 || {
        echo "Error: tic(1) is missing. Install it with:" >&2
        echo "  sudo apt-get install -y ncurses-bin" >&2
        return 1
    }

    mkdir -p "$TERMINFO_DIR"

    # smcup/rmcup are added only when the patched binary exists:
    # stock fbterm ignores ESC[?1049h and full-screen apps would
    # lose their screen restore. Compiled from a temp copy; the
    # shipped .ti is not modified.
    TI_SOURCE="$TI_FILE"
    ALT_NOTE="alternate screen not announced (stock fbterm)"
    if [ -x /usr/local/bin/fbterm-patched ]; then
        TI_SOURCE="$(mktemp)" || {
            echo "Error: mktemp failed" >&2
            return 1
        }
        awk '{ print } index($0, "fbterm-256color|") == 1 { print "\tsmcup=\\E[?1049h, rmcup=\\E[?1049l," }' \
            "$TI_FILE" > "$TI_SOURCE" || {
            echo "Error: could not prepare the terminfo source" >&2
            rm -f "$TI_SOURCE"
            return 1
        }
        ALT_NOTE="alternate screen announced (smcup) for fbterm-patched"
    fi

    tic -x -o "$TERMINFO_DIR" "$TI_SOURCE" || {
        echo "Error: tic failed to compile $TI_SOURCE" >&2
        [ "$TI_SOURCE" != "$TI_FILE" ] && rm -f "$TI_SOURCE"
        return 1
    }

    # System copy for root: sudo programs look in /root/.terminfo,
    # not in the user's, and failed with "Error opening terminal"
    # when only the user copy existed.
    SYS_OK=1
    $SUDO mkdir -p "$TERMINFO_SYS_DIR" >/dev/null 2>&1 || SYS_OK=0
    [ "$SYS_OK" -eq 1 ] && { $SUDO tic -x -o "$TERMINFO_SYS_DIR" "$TI_SOURCE" || SYS_OK=0; }
    [ "$TI_SOURCE" != "$TI_FILE" ] && rm -f "$TI_SOURCE"
    if [ "$SYS_OK" -eq 1 ]; then
        echo "Compiled system terminfo entry: $TERMINFO_SYS_COMPILED (for root/sudo)"
    else
        echo "Warning: the system terminfo copy could not be" >&2
        echo "installed in $TERMINFO_SYS_DIR; root programs (sudo" >&2
        echo "nano, sudo vim...) will not find fbterm-256color." >&2
    fi
    echo "Compiled terminfo entry: $TERMINFO_COMPILED ($ALT_NOTE)"

    command -v infocmp >/dev/null 2>&1 || {
        echo "Error: infocmp(1) is missing (package ncurses-bin)." >&2
        return 1
    }
    infocmp fbterm-256color >/dev/null 2>&1 || {
        echo "Error: infocmp cannot find the new entry; ncurses is not" >&2
        echo "searching $TERMINFO_DIR. Is HOME set correctly?" >&2
        return 1
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
        echo "Note: no fbterm-background login block was found in your"
        echo "login files, so there was no legacy TERM line to update. The"
        echo "block installed by phase 1 selects fbterm-256color"
        echo "automatically when this entry exists."
    }
}

rebuild_idump() (
    cd "$SCRIPT_DIR" || exit 1
    TAR="$SCRIPT_DIR/idump-0.2.0.tar.gz"
    [ -f "$TAR" ] || { echo "setup: missing $TAR" >&2; exit 1; }
    if ! command -v gcc >/dev/null 2>&1; then
        if [ "$USE_APT" -eq 1 ]; then
            SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
            $SUDO apt-get update && $SUDO apt-get install -y --no-install-recommends gcc libc6-dev || exit 1
        else
            echo "setup: gcc is missing (needed for --rebuild-idump)" >&2; exit 1
        fi
    fi
    TMP="$(mktemp -d)" || exit 1
    trap 'rm -rf "$TMP"' EXIT
    tar -xzf "$TAR" -C "$TMP" || exit 1
    cd "$TMP/idump-0.2.0/static" || exit 1
    gcc -static -Os -s -std=gnu99 -fgnu89-inline ../libnsgif.c ../libnsbmp.c ../lodepng.c idump.c -o "$SCRIPT_DIR/idump" || exit 1
    chmod 0755 "$SCRIPT_DIR/idump"
    echo "Rebuilt viewer: $SCRIPT_DIR/idump"
)

# ---------------------------------------------------------------------------
# Verification. Each check prints PASS/FAIL/SKIP; counters are global so
# the summary at the end reflects every phase, not just the last one.
V_PASS=0; V_FAIL=0; V_SKIP=0
v_ok()   { V_PASS=$((V_PASS + 1)); echo "  [PASS] $1"; }
v_bad()  { V_FAIL=$((V_FAIL + 1)); echo "  [FAIL] $1"; }
v_skip() { V_SKIP=$((V_SKIP + 1)); echo "  [SKIP] $1"; }

verify_install() {
    echo "Verification:"
    if command -v fbterm >/dev/null 2>&1; then v_ok "fbterm present ($(command -v fbterm))"; else v_bad "fbterm missing (package not installed)"; fi
    if command -v fastfetch >/dev/null 2>&1; then v_ok "fastfetch present"; else v_bad "fastfetch missing (package not installed)"; fi
    if [ "$SKIP_PATCHED" -eq 1 ]; then
        v_skip "patched fbterm (disabled with --no-patched)"
    elif [ -x "$DEST_PATCHED" ] && "$DEST_PATCHED" -V 2>/dev/null | grep -q 'FbTerm version 1.7'; then
        if ldd "$DEST_PATCHED" 2>/dev/null | grep -q 'not found'; then
            v_bad "$DEST_PATCHED has unresolved shared libraries"
        else
            v_ok "patched fbterm installed and runs ($DEST_PATCHED)"
        fi
        if grep -a -q '/dev/gpmctl' "$DEST_PATCHED" 2>/dev/null; then
            v_ok "patched fbterm has GPM mouse support"
        else
            v_bad "patched fbterm was built without GPM (no mouse inside FbTerm; rebuild with libgpm-dev installed)"
        fi
    else
        v_bad "patched fbterm missing or not working ($DEST_PATCHED)"
    fi
    if [ "$SKIP_PATCHED" -eq 1 ]; then
        v_skip "keymap capability (--no-patched)"
    elif [ -x "$GETCAP" ] && "$GETCAP" "$DEST_PATCHED" 2>/dev/null | grep -q 'cap_sys_tty_config'; then
        v_ok "CAP_SYS_TTY_CONFIG set (no '[input]' keymap warning)"
    else
        v_bad "CAP_SYS_TTY_CONFIG missing on $DEST_PATCHED ('[input]' warning will appear)"
    fi
    if [ -x "$DEST_BIN" ]; then v_ok "launcher exists ($DEST_BIN)"; else v_bad "launcher missing ($DEST_BIN)"; fi
    if [ -x "$DEST_IDUMP" ] && "$DEST_IDUMP" -h >/dev/null 2>&1; then v_ok "idump viewer runs"; else v_bad "idump viewer missing or not runnable ($DEST_IDUMP)"; fi
    if [ -f "$DEST_DATA/wallpaper.png" ]; then v_ok "wallpaper installed"; else v_bad "wallpaper missing ($DEST_DATA/wallpaper.png)"; fi
    if command -v fc-match >/dev/null 2>&1; then
        if fc-match Default8x16 2>/dev/null | grep -qi 'Default8x16'; then
            v_ok "fontconfig resolves Default8x16"
        else
            v_bad "fontconfig does NOT resolve Default8x16 (FbTerm will use a vector font)"
        fi
    else
        v_skip "fontconfig resolution (fc-match not installed)"
    fi
    if [ -f "$HOME/.fbtermrc" ] && grep -q '^font-names=Default8x16' "$HOME/.fbtermrc"; then
        v_ok "$HOME/.fbtermrc uses Default8x16"
    elif [ -f "$HOME/.fbtermrc" ] \
         && ! grep -qF '# Created by fbterm-background installer' "$HOME/.fbtermrc"; then
        # The user brought their own ~/.fbtermrc and the installer
        # deliberately kept it; their font choice is not a failure.
        v_skip "$HOME/.fbtermrc is the user's own (font check skipped)"
    else
        v_bad "$HOME/.fbtermrc does not set font-names=Default8x16"
    fi
    local blocks=0 f
    for f in "${PROFILE_CANDIDATES[@]}"; do
        if [ -f "$f" ] && grep -qF "$MARK_BEGIN" "$f"; then blocks=$((blocks + 1)); fi
    done
    if [ "$blocks" -eq 1 ]; then v_ok "login profile block present (exactly one)"; else v_bad "login profile block count is $blocks (expected 1)"; fi
    if [ -f "$FISH_CONFIG" ] && grep -qF "$FISH_MARK_BEGIN" "$FISH_CONFIG"; then
        v_ok "fish login block present (config.fish)"
    else
        v_bad "fish login block missing in $FISH_CONFIG"
    fi
    if command -v infocmp >/dev/null 2>&1 && infocmp fbterm-256color >/dev/null 2>&1; then
        local cols
        cols="$(tput -T fbterm-256color colors 2>/dev/null || echo '?')"
        if [ "$cols" = "256" ]; then v_ok "terminfo fbterm-256color reports 256 colors"; else v_bad "terminfo fbterm-256color reports $cols colors (expected 256)"; fi
        if [ -x "$DEST_PATCHED" ]; then
            if infocmp fbterm-256color | grep -q 'smcup='; then v_ok "terminfo announces alternate screen (smcup)"; else v_bad "terminfo lacks smcup although fbterm-patched exists"; fi
        elif infocmp fbterm-256color | grep -q 'smcup='; then
            v_bad "terminfo announces smcup but fbterm-patched is missing (stock fbterm cannot honour it)"
        else
            v_ok "terminfo correctly silent about smcup (stock fbterm)"
        fi
        if infocmp -x fbterm-256color 2>/dev/null | grep -q 'U8#1'; then
            v_ok "terminfo declares U8 (UTF-8 box drawing)"
        else
            v_bad "terminfo lacks U8#1 (box drawing garbled in UTF-8 locales)"
        fi
        if env -u TERMINFO -u TERMINFO_DIRS HOME=/nonexistent-fbterm-check infocmp fbterm-256color >/dev/null 2>&1; then
            v_ok "terminfo entry also visible to root/sudo (system copy)"
        else
            v_bad "terminfo entry not visible to root/sudo (root programs fail with 'Error opening terminal')"
        fi
    else
        v_bad "terminfo entry fbterm-256color not found by infocmp"
    fi
    echo "Verification: $V_PASS passed, $V_FAIL failed, $V_SKIP skipped."
    [ "$V_FAIL" -eq 0 ]
}

verify_uninstall() {
    echo "Verification (uninstall):"
    local leftovers=0 f
    for f in "${PROFILE_CANDIDATES[@]}"; do
        if [ -f "$f" ] && grep -qF 'fbterm-background' "$f"; then
            echo "  [FAIL] profile block remains in $f"; leftovers=$((leftovers + 1))
        fi
    done
    if [ -f "$FISH_CONFIG" ] && grep -qF "$FISH_MARK_BEGIN" "$FISH_CONFIG"; then
        echo "  [FAIL] fish block remains in $FISH_CONFIG"; leftovers=$((leftovers + 1))
    fi
    [ -e "$DEST_BIN" ] && { echo "  [FAIL] launcher remains: $DEST_BIN"; leftovers=$((leftovers + 1)); }
    [ -e "$DEST_IDUMP" ] && { echo "  [FAIL] viewer remains: $DEST_IDUMP"; leftovers=$((leftovers + 1)); }
    [ -e "$DEST_DATA" ] && { echo "  [FAIL] data dir remains: $DEST_DATA"; leftovers=$((leftovers + 1)); }
    [ -e "$TERMINFO_COMPILED" ] && { echo "  [FAIL] terminfo entry remains: $TERMINFO_COMPILED"; leftovers=$((leftovers + 1)); }
    [ -e "$TERMINFO_SYS_COMPILED" ] && { echo "  [FAIL] system terminfo entry remains: $TERMINFO_SYS_COMPILED"; leftovers=$((leftovers + 1)); }
    [ -e "$DEST_PATCHED" ] && { echo "  [FAIL] patched binary remains: $DEST_PATCHED"; leftovers=$((leftovers + 1)); }
    if [ -f "$HOME/.fbtermrc" ] && grep -qF '# Created by fbterm-background installer' "$HOME/.fbtermrc"; then
        echo "  [FAIL] ~/.fbtermrc created by the installer remains"; leftovers=$((leftovers + 1))
    fi
    if [ "$leftovers" -eq 0 ]; then
        echo "  [PASS] nothing of the setup remains (backups and APT packages kept)"
    fi
    echo "Verification (uninstall): $leftovers leftover(s)."
    [ "$leftovers" -eq 0 ]
}

install_core() {
# --- Files shipped next to this script ----------------------------------------
[ -f "$SCRIPT_DIR/wallpaper.png" ] || {
    echo "Error: wallpaper.png is missing next to this script." >&2; exit 1; }
[ -f "$SCRIPT_DIR/idump" ] || {
    echo "Error: the idump binary is missing next to this script." >&2
    echo "If your architecture is not x86_64, build it first: ./setup-fbterm-background.sh --rebuild-idump" >&2
    exit 1; }
[ -f "$SCRIPT_DIR/Default8x16.bdf" ] || {
    echo "Error: Default8x16.bdf is missing next to this script." >&2; exit 1; }

# --- Required packages (Debian trixie, no recommends) --------------------------
PACKAGES=()
command -v fbterm    >/dev/null 2>&1 || PACKAGES+=(fbterm)
command -v fastfetch >/dev/null 2>&1 || PACKAGES+=(fastfetch)

if [ "${#PACKAGES[@]}" -gt 0 ] && [ "$USE_APT" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "Error: missing packages (${PACKAGES[*]}) and sudo is unavailable." >&2
        echo "Install as root: apt-get install -y --no-install-recommends ${PACKAGES[*]}" >&2
        echo "then run this script again with --no-apt." >&2
        exit 1
    fi
    SUDO="sudo"; [ "$(id -u)" -eq 0 ] && SUDO=""
    echo "Installing packages: ${PACKAGES[*]}"
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends "${PACKAGES[@]}"
elif [ "${#PACKAGES[@]}" -gt 0 ]; then
    echo "Warning (--no-apt): missing packages; install: ${PACKAGES[*]}" >&2
fi

# fbterm/idump need read/write access to /dev/fb0 (video group).
if [ -e /dev/fb0 ] && ! id -nG | grep -qw video; then
    if [ "$USE_APT" -eq 1 ] && { [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1; }; then
        SUDO="sudo"; [ "$(id -u)" -eq 0 ] && SUDO=""
        echo "Adding your user to the video group (/dev/fb0 access)..."
        $SUDO usermod -aG video "${USER:-$(id -un)}"
        echo "Note: the new group only takes effect at your NEXT login."
    else
        echo "Warning: add your user to the video group:  sudo usermod -aG video ${USER:-$(id -un)}" >&2
    fi
fi

# --- Copy wallpaper, viewer and source ----------------------------------------
mkdir -p "$DEST_DATA" "$DEST_CONFIG_DIR" "$HOME/.local/bin" \
         "$DEST_FONT_DIR" "$DEST_FONTCONFIG_DIR"
install -m 0644 "$SCRIPT_DIR/wallpaper.png" "$DEST_DATA/wallpaper.png"
# The old pre-cropped 16:9 file is no longer used: idump now fits the
# original image to the actual framebuffer at login.
rm -f "$DEST_DATA/wallpaper-16x9.png"
install -m 0644 "$SCRIPT_DIR/Default8x16.bdf" "$DEST_FONT_DIR/Default8x16.bdf"
cat > "$DEST_FONTCONFIG_FILE" <<EOF_FONTCONFIG
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- fbterm-background: Debian fontconfig rejects bitmap fonts by
     default. Accept only the bundled classic 8x16 console font.
     The explicit <dir> makes discovery independent of the XDG
     font path, so the font is found even with a minimal or
     unusual fontconfig setup. -->
<fontconfig>
  <dir>$DEST_FONT_DIR</dir>
  <selectfont>
    <acceptfont>
      <pattern>
        <patelt name="family"><string>Default8x16</string></patelt>
      </pattern>
    </acceptfont>
  </selectfont>
</fontconfig>
EOF_FONTCONFIG
if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$DEST_FONT_DIR" >/dev/null 2>&1 || true
fi

# Check the font really resolves: if any layer (search path, bitmap
# rejection, stale cache) fails, fontconfig silently uses DejaVu.
FONT_STATUS="not checked (fc-match not available)"
if command -v fc-match >/dev/null 2>&1; then
    if fc-match Default8x16 2>/dev/null | grep -qi 'Default8x16'; then
        FONT_STATUS="ok"
    else
        fc-cache -f >/dev/null 2>&1 || true
        if fc-match Default8x16 2>/dev/null | grep -qi 'Default8x16'; then
            FONT_STATUS="ok (after a full fc-cache rebuild)"
        else
            FONT_STATUS="BROKEN"
        fi
    fi
fi
case "$FONT_STATUS" in
    ok*)
        echo "Font check: Default8x16 resolves correctly ($FONT_STATUS)."
        ;;
    "not checked"*)
        echo "Font check: skipped, fc-match is not installed."
        ;;
    *)
        echo "Font check: WARNING: 'fc-match Default8x16' resolves to" >&2
        echo "  $(fc-match Default8x16 2>/dev/null | head -n 1)" >&2
        echo "instead of the bundled Default8x16.bdf, so FbTerm will fall" >&2
        echo "back to a vector font. Check /etc/fonts/conf.d for bitmap" >&2
        echo "rejection rules overriding $DEST_FONTCONFIG_FILE." >&2
        ;;
esac
install -m 0755 "$SCRIPT_DIR/idump" "$DEST_IDUMP"
# Transparency: the viewer's source code is installed too.
if [ -f "$SCRIPT_DIR/idump-0.2.0.tar.gz" ]; then
    install -m 0644 "$SCRIPT_DIR/idump-0.2.0.tar.gz" "$DEST_DATA/"
fi
# Drop stale caches from previous versions.
rm -rf "$HOME/.cache/fbterm-background" "$HOME/.cache/fbterm-fondo"
echo "Wallpaper and viewer installed in $DEST_DATA and $DEST_IDUMP"

# Make sure the shipped binary actually runs on this architecture.
if ! "$DEST_IDUMP" -h >/dev/null 2>&1; then
    echo "Warning: the included idump binary does not run on this machine" >&2
    echo "(architecture other than x86_64?). Rebuild it with:" >&2
    echo "  sudo apt-get install -y --no-install-recommends gcc libc6-dev" >&2
    echo "  ./setup-fbterm-background.sh --rebuild-idump" >&2
fi

# Persistent settings: created once, NEVER overwritten on reinstall,
# so a mode you chose (e.g. FBTERM_MODE=fit) survives updates.
if [ ! -f "$DEST_CONFIG_DIR/config" ]; then
    cat > "$DEST_CONFIG_DIR/config" <<EOF_CFG
# Persistent background settings.
# cover = fill the display, cropping; fit = whole image, centered.
# FBTERM_BRIGHTNESS is a percentage: 100 is the original image.
FBTERM_MODE=$BACKGROUND_MODE
FBTERM_BRIGHTNESS=$BACKGROUND_BRIGHTNESS
EOF_CFG
    echo "Created $DEST_CONFIG_DIR/config (FBTERM_MODE=$BACKGROUND_MODE)"
else
    echo "Keeping existing $DEST_CONFIG_DIR/config (not overwritten)."
fi

# --- Create the launcher ~/.local/bin/fbterm-background ------------------------
cat > "$DEST_BIN" <<'EOF_LAUNCHER'
#!/usr/bin/env bash
# fbterm-background: paint the wallpaper with idump, open FbTerm over it.
# Usage: fbterm-background [--no-background]
set -u

DATA="$HOME/.local/share/fbterm-background"
IDUMP_BIN="$HOME/.local/bin/idump"
FBDEV="${FRAMEBUFFER:-/dev/fb0}"
NO_BACKGROUND=0

case "${1:-}" in
    "") ;;
    --no-background) NO_BACKGROUND=1 ;;
    -h|--help) echo "Usage: fbterm-background [--no-background]"; exit 0 ;;
    *) echo "fbterm-background: unknown argument: $1" >&2
       echo "Usage: fbterm-background [--no-background]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "fbterm-background: too many arguments" >&2
    echo "Usage: fbterm-background [--no-background]" >&2
    exit 2
fi

# Persistent settings are parsed, NOT sourced: the file is plain
# KEY=VALUE data, never shell code. Only FBTERM_MODE is honoured, and
# only the values "cover" and "fit" are accepted.
MODE="cover"
BRIGHTNESS=35
CONFIG_FILE="$HOME/.config/fbterm-background/config"
if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        # Trim surrounding whitespace.
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        case "$line" in
            FBTERM_MODE=cover|FBTERM_MODE=fit)
                MODE="${line#FBTERM_MODE=}" ;;
            FBTERM_MODE=*)
                echo "fbterm-background: ignoring invalid FBTERM_MODE in $CONFIG_FILE" >&2 ;;
            FBTERM_BRIGHTNESS=[0-9]|FBTERM_BRIGHTNESS=[0-9][0-9]|FBTERM_BRIGHTNESS=100)
                BRIGHTNESS="${line#FBTERM_BRIGHTNESS=}" ;;
            FBTERM_BRIGHTNESS=*)
                echo "fbterm-background: ignoring invalid FBTERM_BRIGHTNESS in $CONFIG_FILE" >&2 ;;
        esac
    done < "$CONFIG_FILE"
fi
# A valid environment variable overrides the config file.
case "${FBTERM_MODE:-}" in
    cover|fit) MODE="$FBTERM_MODE" ;;
    "") ;;
    *) echo "fbterm-background: ignoring invalid FBTERM_MODE in environment" >&2 ;;
esac
case "${FBTERM_BRIGHTNESS:-}" in
    [0-9]|[0-9][0-9]|100) BRIGHTNESS="$FBTERM_BRIGHTNESS" ;;
    "") ;;
    *) echo "fbterm-background: ignoring invalid FBTERM_BRIGHTNESS in environment" >&2 ;;
esac

IMG="$DATA/wallpaper.png"
if [ "$MODE" = "fit" ]; then
    IDUMP_ARGS=(-f -d "$BRIGHTNESS")
else
    IDUMP_ARGS=(-c -d "$BRIGHTNESS")
fi

fail() { echo "fbterm-background: $*" >&2; exit 1; }

# Anti-loop and environment guards: physical TTY only, no X11/Wayland,
# never twice.
[ -z "${FBTERM_BACKGROUND_ACTIVE:-}" ] || fail "you are already inside FbTerm."
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    fail "a graphical session is running; this is for TTYs only."
fi
TTY_ACTUAL="$(tty 2>/dev/null || true)"
case "$TTY_ACTUAL" in
    /dev/tty[0-9]*)
        case "${TTY_ACTUAL#/dev/tty}" in
            *[!0-9]*|'') fail "not a physical TTY ($TTY_ACTUAL). Log in on tty1-tty6 and retry." ;;
        esac
        ;;
    *) fail "not a physical TTY ($TTY_ACTUAL). Log in on tty1-tty6 and retry." ;;
esac

# Prefer the patched FbTerm when installed. Decided at every login,
# so adding/removing it needs no reinstall.
FBTERM_BIN=fbterm
if [ -x /usr/local/bin/fbterm-patched ]; then
    FBTERM_BIN=/usr/local/bin/fbterm-patched
fi

command -v "$FBTERM_BIN" >/dev/null 2>&1 || fail "fbterm is missing: sudo apt-get install --no-install-recommends fbterm"

open_fbterm() {
    export FBTERM_BACKGROUND_ACTIVE=1
    if [ "$1" -eq 1 ]; then
        unset FBTERM_BACKGROUND_IMAGE
    else
        export FBTERM_BACKGROUND_IMAGE=1
    fi
    # fbterm's own stdout/stderr go to a log: anything written to the
    # console before fbterm captures the framebuffer would be baked
    # into the background image. The shell gets a pty, so this is safe.
    LOG_DIR="$HOME/.cache/fbterm-background"
    mkdir -p "$LOG_DIR"
    if [ "$FBTERM_BIN" != fbterm ]; then
        # Tells the login block inside the session that fastfetch
        # needs no output filter: colors and OSC are native there.
        export FBTERM_PATCHED=1
    fi
    # Open the user's login shell (bash, fish...) inside FbTerm.
    SESSION_SHELL="${SHELL:-/bin/bash}"
    [ -x "$SESSION_SHELL" ] || SESSION_SHELL=/bin/bash
    "$FBTERM_BIN" -- "$SESSION_SHELL" -l >"$LOG_DIR/fbterm.log" 2>&1
    FBTERM_STATUS=$?
    [ -n "${MEV_PID:-}" ] && kill "$MEV_PID" 2>/dev/null
    # Re-show the kernel-console cursor (hidden while painting; see
    # below). FbTerm draws its own cursor while it runs.
    printf '\033[?25h'
    if [ "$FBTERM_STATUS" -ne 0 ]; then
        echo "fbterm-background: fbterm exited with status $FBTERM_STATUS; last log lines:" >&2
        tail -n 20 "$LOG_DIR/fbterm.log" >&2 2>/dev/null || true
    fi
    exit "$FBTERM_STATUS"
}

if [ "$NO_BACKGROUND" -eq 1 ]; then
    open_fbterm 1
fi

# From here on the image has to be painted onto the framebuffer.
# A relative FRAMEBUFFER value would depend on the current directory,
# so only absolute paths are accepted.
paint_ok=1
case "$FBDEV" in
    /*) ;;
    *) echo "fbterm-background: FRAMEBUFFER must be an absolute path (got: $FBDEV)" >&2; paint_ok=0 ;;
esac
if [ "$paint_ok" -eq 1 ] \
   && { [ ! -f "$IMG" ] || [ ! -x "$IDUMP_BIN" ] \
        || [ ! -e "$FBDEV" ] || [ ! -r "$FBDEV" ] || [ ! -w "$FBDEV" ]; }; then
    paint_ok=0
fi
if [ "$paint_ok" -ne 1 ]; then
    echo "fbterm-background: cannot paint the background (image, viewer or" >&2
    echo "permissions on $FBDEV). Opening FbTerm without a background." >&2
    echo "Hint: /dev/fb0 access requires the video group." >&2
    sleep 2
    open_fbterm 1
fi

# idump paints and exits without clearing the screen; FbTerm captures
# that framebuffer as its background because FBTERM_BACKGROUND_IMAGE
# is set. timeout protects the login: a hung viewer can never block
# the session for more than 10 seconds.
export FRAMEBUFFER="$FBDEV"
printf '\033[?25l'
# While no gpm client is connected, the daemon draws its own pointer
# with the kernel text selection; on a framebuffer console that
# repaints cells from the (black) text buffer, and FbTerm would then
# capture the trail into the background. Hold a throwaway client
# during the paint so the daemon keeps its pointer off the screen.
# It stays connected while FbTerm runs (FbTerm is the newer client
# and gets the mouse) and is stopped when FbTerm exits.
MEV_PID=
if command -v mev >/dev/null 2>&1; then
    mev >/dev/null 2>&1 &
    MEV_PID=$!
fi
if command -v timeout >/dev/null 2>&1; then
    timeout 10 "$IDUMP_BIN" "${IDUMP_ARGS[@]}" "$IMG" >/dev/null 2>&1
else
    "$IDUMP_BIN" "${IDUMP_ARGS[@]}" "$IMG" >/dev/null 2>&1
fi
IDUMP_STATUS=$?
# The cursor stays hidden: if the kernel console drew its block
# cursor now, FbTerm would capture it into the background image
# (a permanent black square). open_fbterm restores it on exit.
if [ "$IDUMP_STATUS" -ne 0 ]; then
    echo "fbterm-background: idump failed (status $IDUMP_STATUS); opening without a background." >&2
    sleep 2
    open_fbterm 1
fi
open_fbterm 0
EOF_LAUNCHER
chmod 0755 "$DEST_BIN"
echo "Launcher created: $DEST_BIN"

# --- FbTerm configuration -------------------------------------------------------
# A file created by this installer is refreshed on reinstall (this is
# how the classic 8x16 font replaces the old vector "mono" setting).
# A file you created yourself is never overwritten.
if [ ! -f "$HOME/.fbtermrc" ] \
   || grep -qF '# Created by fbterm-background installer' "$HOME/.fbtermrc"; then
    cat > "$HOME/.fbtermrc" <<EOF_FBRC
# Created by fbterm-background installer
# FbTerm configuration (see "man fbterm", options section).
font-names=$FONT_NAME
font-size=$FONT_SIZE
font-width=$FONT_WIDTH
font-height=$FONT_HEIGHT
color-foreground=7
color-background=0
history-lines=5000
text-encodings=
EOF_FBRC
    echo "Configured $HOME/.fbtermrc (classic 8x16 bitmap font)"
else
    echo "$HOME/.fbtermrc already exists and was not created by this installer: not modified."
    echo "For the classic console font, set: font-names=$FONT_NAME, font-size=$FONT_SIZE, font-width=$FONT_WIDTH, font-height=$FONT_HEIGHT"
fi

# A foreign ~/.fbtermrc is never overwritten, but if it names another
# font, say so and give the fix.
if [ -f "$HOME/.fbtermrc" ] && grep -q '^font-names=Default8x16' "$HOME/.fbtermrc"; then
    echo "FbTerm config check: ~/.fbtermrc asks for Default8x16 (ok)."
else
    echo "FbTerm config check: WARNING: ~/.fbtermrc does not set" >&2
    echo "font-names=Default8x16, so FbTerm will use whatever it names" >&2
    echo "instead of the classic console font. One-line fix:" >&2
    echo "  sed -i 's/^font-names=.*/font-names=Default8x16/' ~/.fbtermrc" >&2
    echo "(and make sure it also has font-size=16, font-width=8," >&2
    echo "font-height=16; remove any other font-names line.)" >&2
fi

# --- Startup block in the login profile -----------------------------------------
# Bash reads only the FIRST existing file among ~/.bash_profile,
# ~/.bash_login and ~/.profile. To avoid silently disabling an existing
# ~/.profile (the usual Debian setup), the block goes into whichever of
# those files Bash would actually read, and any block from a previous
# installation is removed from all of them first.
TARGET_PROFILE=""
for f in "${PROFILE_CANDIDATES[@]}"; do
    if [ -f "$f" ]; then TARGET_PROFILE="$f"; break; fi
done
if [ -z "$TARGET_PROFILE" ]; then
    TARGET_PROFILE="$HOME/.bash_profile"
    cat > "$TARGET_PROFILE" <<'EOF_NEWPROFILE'
# ~/.bash_profile
# Bash reads only the first existing login file, so keep the other
# login files effective if they are created later.
if [ -f "$HOME/.bash_login" ]; then
    . "$HOME/.bash_login"
elif [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi
EOF_NEWPROFILE
    echo "Created $TARGET_PROFILE"
fi

for f in "${PROFILE_CANDIDATES[@]}"; do
    rc=0
    clean_profile_file "$f" >/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "Error: $f contains a malformed fbterm-background block and" >&2
        echo "was left untouched. Fix it manually, then run this again." >&2
        exit 1
    fi
done
# Also strip the legacy launcher, in case an old install is present.
rm -f "$HOME/.local/bin/fbterm-fondo"
rm -rf "$HOME/.config/fbterm-fondo" "$HOME/.local/share/fbterm-fondo"

# If the target is ~/.bash_profile or ~/.bash_login, Bash skips the
# remaining login files. Unless the target already sources one of them,
# add a small compatibility block so the skipped file still runs.
case "$TARGET_PROFILE" in
    "$HOME/.profile") ;;
    *)
        if ! grep -Eq '(\.|source)[[:space:]]+.*\.(profile|bash_login)' "$TARGET_PROFILE" \
           && { [ -f "$HOME/.bash_login" ] || [ -f "$HOME/.profile" ]; }; then
            cat >> "$TARGET_PROFILE" <<'EOF_SOURCE'
# >>> fbterm-background profile-source >>>
# Bash reads only the first existing login file; source the one it
# would otherwise skip, so existing settings keep working.
if [ -f "$HOME/.bash_login" ]; then
    . "$HOME/.bash_login"
elif [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi
# <<< fbterm-background profile-source <<<
EOF_SOURCE
        fi
        ;;
esac

cat >> "$TARGET_PROFILE" <<'EOF_PROFILE'
# >>> fbterm-background (TTY) >>>
# Background with FbTerm + fastfetch on physical TTYs only, no X11/Wayland.
# Disable without uninstalling: touch ~/.config/fbterm-background/disabled
if [ -z "${FBTERM_BACKGROUND_ACTIVE:-}" ]; then
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] \
       && [ ! -f "$HOME/.config/fbterm-background/disabled" ]; then
        _fbterm_tty="$(tty 2>/dev/null)"
        _fbterm_num="${_fbterm_tty#/dev/tty}"
        case "$_fbterm_tty" in
            /dev/tty[0-9]*)
                case "$_fbterm_num" in
                    *[!0-9]*|'') ;;
                    *)
                        if "$HOME/.local/bin/fbterm-background"; then
                            exit
                        fi
                        echo "fbterm-background could not start; you are still on the normal TTY." >&2
                        ;;
                esac
                ;;
        esac
        unset _fbterm_tty _fbterm_num
    fi
elif [ -z "${FBTERM_FASTFETCH_DONE:-}" ]; then
    export FBTERM_FASTFETCH_DONE=1
    # Prefer the 256-color terminfo name when it has been compiled
    # (./setup-fbterm-background.sh); stock "fbterm" otherwise. Both
    # describe the same entry: FbTerm renders 256 colors through its
    # private sequences (ESC [ 1;n } / ESC [ 2;n }), which the
    # terminfo setaf/setab already use.
    if [ "${TERM:-}" = "linux" ]; then
        if infocmp fbterm-256color >/dev/null 2>&1; then
            export TERM=fbterm-256color
        else
            export TERM=fbterm
        fi
    fi
    if command -v fastfetch >/dev/null 2>&1; then
        if [ -n "${FBTERM_PATCHED:-}" ]; then
            # Patched FbTerm handles OSC 8 and bright/256 colours
            # itself: run fastfetch unfiltered.
            if command -v timeout >/dev/null 2>&1; then
                timeout 15 fastfetch || true
            else
                fastfetch || true
            fi
        elif command -v perl >/dev/null 2>&1; then
            # Stock FbTerm mangles fastfetch (OSC 8 prints as garbage,
            # bright colours are dropped), so filter its output: strip
            # OSC, map 90-97 -> bold+30-37 and 100-107 -> blink+40-47.
            # Applies to the auto-run and to manual runs in this shell.
            # "--pipe false" keeps colours through the pipe.
            # shellcheck disable=SC2120,SC2119
            fastfetch() {
                local _ffbin
                _ffbin="$(type -P fastfetch)"
                [ -n "$_ffbin" ] || return 127
                if command -v timeout >/dev/null 2>&1; then
                    timeout 15 "$_ffbin" --pipe false "$@" | perl -pe 's/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)//g; s/\x1b\[([0-9;]*)m/ my $p=$1; my @a=split(q{;},$p,-1); my $pre=""; @a=map { if ($_ >= 100 && $_ <= 107) { $pre="5;"; $_ - 60 } elsif ($_ >= 90 && $_ <= 97) { $pre="1;"; $_ - 60 } else { $_ } } @a; "\x1b[" . $pre . join(";", @a) . "m" /ge'
                    return "${PIPESTATUS[0]}"
                fi
                "$_ffbin" --pipe false "$@" | perl -pe 's/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)//g; s/\x1b\[([0-9;]*)m/ my $p=$1; my @a=split(q{;},$p,-1); my $pre=""; @a=map { if ($_ >= 100 && $_ <= 107) { $pre="5;"; $_ - 60 } elsif ($_ >= 90 && $_ <= 97) { $pre="1;"; $_ - 60 } else { $_ } } @a; "\x1b[" . $pre . join(";", @a) . "m" /ge'
                return "${PIPESTATUS[0]}"
            }
            fastfetch || true
        elif command -v timeout >/dev/null 2>&1; then
            timeout 15 fastfetch || true
        else
            fastfetch || true
        fi
    fi
fi
# <<< fbterm-background (TTY) <<<
EOF_PROFILE
echo "Automatic startup added to $TARGET_PROFILE"

# Fish reads neither ~/.bash_profile nor ~/.profile: without its own
# block, switching the login shell to fish (chsh) would silently
# disable the whole startup. Same logic as the bash block above.
mkdir -p "$(dirname "$FISH_CONFIG")"
rc=0
remove_block "$FISH_CONFIG" "$FISH_MARK_BEGIN" "$FISH_MARK_END" >/dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "Error: $FISH_CONFIG contains a malformed fbterm-background" >&2
    echo "block and was left untouched. Fix it manually, then run" >&2
    echo "this again." >&2
    exit 1
fi
cat >> "$FISH_CONFIG" <<'EOF_FISH'
# >>> fbterm-background fish (TTY) >>>
# Background with FbTerm + fastfetch on physical TTYs only, no X11/Wayland.
# Disable without uninstalling: touch ~/.config/fbterm-background/disabled
if not set -q FBTERM_BACKGROUND_ACTIVE
    if status is-login; and not set -q DISPLAY; and not set -q WAYLAND_DISPLAY; and not test -f "$HOME/.config/fbterm-background/disabled"
        set -l _fbterm_tty (tty 2>/dev/null)
        if string match -qr '^/dev/tty[0-9]+$' -- "$_fbterm_tty"
            if $HOME/.local/bin/fbterm-background
                # End the login shell, like exit in the bash block:
                # a plain exit in config.fish only stops this file.
                exec true
            end
            echo "fbterm-background could not start; you are still on the normal TTY." >&2
        end
    end
else if not set -q FBTERM_FASTFETCH_DONE
    set -gx FBTERM_FASTFETCH_DONE 1
    # Prefer the 256-color terminfo name when it has been compiled
    # (./setup-fbterm-background.sh); stock "fbterm" otherwise.
    if test "$TERM" = linux
        if infocmp fbterm-256color >/dev/null 2>&1
            set -gx TERM fbterm-256color
        else
            set -gx TERM fbterm
        end
    end
    if command -q fastfetch
        if set -q FBTERM_PATCHED
            # Patched FbTerm handles OSC 8 and bright/256 colours
            # itself: run fastfetch unfiltered.
            if command -q timeout
                timeout 15 fastfetch; or true
            else
                fastfetch; or true
            end
        else if command -q perl
            # Stock FbTerm mangles fastfetch, so filter its output
            # (same Perl filter as the bash block). Applies to the
            # auto-run and to manual runs in this shell.
            function fastfetch
                set -l _ffbin (type -P fastfetch)
                test -n "$_ffbin"; or return 127
                if command -q timeout
                    timeout 15 $_ffbin --pipe false $argv | perl -pe 's/\\x1b\\][^\\x07\\x1b]*(?:\\x07|\\x1b\\\\)//g; s/\\x1b\\[([0-9;]*)m/ my $p=$1; my @a=split(q{;},$p,-1); my $pre=""; @a=map { if ($_ >= 100 && $_ <= 107) { $pre="5;"; $_ - 60 } elsif ($_ >= 90 && $_ <= 97) { $pre="1;"; $_ - 60 } else { $_ } } @a; "\\x1b[" . $pre . join(";", @a) . "m" /ge'
                    return $pipestatus[1]
                end
                $_ffbin --pipe false $argv | perl -pe 's/\\x1b\\][^\\x07\\x1b]*(?:\\x07|\\x1b\\\\)//g; s/\\x1b\\[([0-9;]*)m/ my $p=$1; my @a=split(q{;},$p,-1); my $pre=""; @a=map { if ($_ >= 100 && $_ <= 107) { $pre="5;"; $_ - 60 } elsif ($_ >= 90 && $_ <= 97) { $pre="1;"; $_ - 60 } else { $_ } } @a; "\\x1b[" . $pre . join(";", @a) . "m" /ge'
                return $pipestatus[1]
            end
            fastfetch; or true
        else if command -q timeout
            timeout 15 fastfetch; or true
        else
            fastfetch; or true
        end
    end
end
# <<< fbterm-background fish (TTY) <<<
EOF_FISH
echo "Automatic startup added to $FISH_CONFIG (fish)"
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    echo "== Removing terminfo entry =="
    terminfo_uninstall
    echo "== Removing patched FbTerm =="
    uninstall_patched
    echo "== Removing core setup =="
    uninstall_core
    echo
    if verify_uninstall; then
        echo
        echo "Uninstalled. Profile backups (*.bak-fbterm-background) were kept."
        echo "APT packages were not touched; remove them with:"
        echo "  sudo apt-get purge fbterm fastfetch"
        echo "The build dependencies of the patched FbTerm (compiler etc.)"
        echo "were also kept."
        exit 0
    fi
    echo "Uninstall finished but verification found leftovers (above)." >&2
    exit 1
fi

# The patched phase applies this file; check early so we do not install
# half a setup before noticing it is missing.
if [ "$SKIP_PATCHED" -ne 1 ] && [ ! -f "$PATCH_FILE" ]; then
    echo "Error: fbterm-compat.patch is missing next to this script" >&2
    echo "(expected: $PATCH_FILE). Without it the patched FbTerm cannot" >&2
    echo "be built; use --no-patched to install with the stock binary." >&2
    exit 1
fi

if [ "$REBUILD_IDUMP" -eq 1 ]; then
    echo "== Rebuilding the idump viewer from source =="
    if ! rebuild_idump; then
        echo "Error: rebuilding idump failed; aborting." >&2
        exit 1
    fi
fi

echo "== Phase 1/3: core setup (packages, wallpaper, font, launcher) =="
install_core

if [ "$SKIP_PATCHED" -eq 1 ]; then
    echo "== Phase 2/3: patched FbTerm skipped (--no-patched) =="
else
    echo "== Phase 2/3: building patched FbTerm (native xterm sequences) =="
    if build_patched; then
        :
    else
        echo "Warning: the patched FbTerm could not be built/installed." >&2
        echo "Continuing with the stock fbterm: the setup stays functional" >&2
        echo "(fastfetch uses the Perl filter; no alternate screen)." >&2
    fi
fi

if [ "$SKIP_PATCHED" -ne 1 ]; then
    if ! ensure_keymap_cap; then
        echo "Warning: CAP_SYS_TTY_CONFIG could not be set; the '[input]" >&2
        echo "can't change kernel keymap table' message will keep appearing." >&2
    fi
fi

echo "== Phase 3/3: terminfo (fbterm-256color) =="
if ! terminfo_install; then
    echo "Warning: the terminfo phase reported a problem (see above)." >&2
fi

echo
if ! verify_install; then
    echo
    echo "Setup finished WITH PROBLEMS (see [FAIL] lines above)." >&2
    exit 1
fi

cat <<'EOF'

Done. How to use it:
  1) Log out and back in on a TTY (tty1-tty6). You get the wallpaper,
     FbTerm with the classic 8x16 font, and fastfetch once.
  2) Exit FbTerm with "exit" (also ends the login session).
  3) Check inside: echo $TERM (fbterm-256color), and run vim or less:
     on quit, your shell screen is restored (patched binary only).

Notes:
  - Image: ~/.config/fbterm-background/config has FBTERM_MODE=cover|fit
    and FBTERM_BRIGHTNESS=35; preserved across reinstalls.
  - Disable without uninstalling: touch ~/.config/fbterm-background/disabled
  - One-off without background: fbterm-background --no-background
  - Everything is re-runnable: ./setup-fbterm-background.sh
  - Remove everything:   ./setup-fbterm-background.sh --uninstall
EOF
