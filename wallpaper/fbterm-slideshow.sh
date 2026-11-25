#!/usr/bin/env bash
# fbterm-slideshow - rotate the FbTerm background through a gallery.
#
# Started by the fbterm-background launcher inside a session. Every
# FBTERM_SLIDESHOW_INTERVAL seconds it renders the next gallery
# image with fbrender and drops the result where the patched
# FbTerm watches for it (FBTERM_SLIDESHOW_FILE); FbTerm then fades
# the background to the new image. Only the background changes:
# the text on the terminal is never touched.
#
# Settings live in ~/.config/fbterm-background/config and are
# re-read while running, so edits apply without logging in again.
set -u

DATA="$HOME/.local/share/fbterm-background"
CONFIG_FILE="$HOME/.config/fbterm-background/config"
RENDER_BIN="$HOME/.local/bin/fbrender"
DROP="$DATA/next.fbg"
STATE="$DATA/slideshow.state"
NEXT_REQUEST="$DATA/slideshow.next"
LOG="$HOME/.cache/fbterm-background/slideshow.log"

mkdir -p "$HOME/.cache/fbterm-background"
log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG" 2>/dev/null || true; }

# Defaults; the config file overrides them (see read_config).
ENABLED=on
INTERVAL=60
ORDER=sequence
TRANSITION=crossfade
DURATION=800
REMEMBER=on
MODE=cover
BRIGHTNESS=35
GALLERY="$DATA/gallery"
SIZE_OVERRIDE=""

read_config() {
    ENABLED=on; INTERVAL=60; ORDER=sequence; TRANSITION=crossfade
    DURATION=800; REMEMBER=on; MODE=cover; BRIGHTNESS=35
    GALLERY="$DATA/gallery"; SIZE_OVERRIDE=""
    [ -f "$CONFIG_FILE" ] || return 0
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"; val="${line#*=}"
        case "$key" in
            FBTERM_MODE) case "$val" in cover|fit) MODE="$val" ;; esac ;;
            FBTERM_BRIGHTNESS) case "$val" in [0-9]|[0-9][0-9]|100) BRIGHTNESS="$val" ;; esac ;;
            FBTERM_SLIDESHOW) case "$val" in on|off) ENABLED="$val" ;; esac ;;
            FBTERM_SLIDESHOW_INTERVAL) case "$val" in *[!0-9]*|'') ;; *) [ "$val" -ge 5 ] && [ "$val" -le 86400 ] && INTERVAL="$val" ;; esac ;;
            FBTERM_SLIDESHOW_ORDER) case "$val" in sequence|random) ORDER="$val" ;; esac ;;
            FBTERM_SLIDESHOW_TRANSITION) case "$val" in none|crossfade|black|white|random) TRANSITION="$val" ;; esac ;;
            FBTERM_SLIDESHOW_DURATION_MS) case "$val" in *[!0-9]*|'') ;; *) [ "$val" -le 10000 ] && DURATION="$val" ;; esac ;;
            FBTERM_SLIDESHOW_REMEMBER) case "$val" in on|off) REMEMBER="$val" ;; esac ;;
            FBTERM_SLIDESHOW_SIZE) case "$val" in [0-9]*x[0-9]*) SIZE_OVERRIDE="$val" ;; esac ;;
            FBTERM_GALLERY_DIR) case "$val" in /*) GALLERY="$val" ;; esac ;;
        esac
    done < "$CONFIG_FILE"
}

# Framebuffer size ("1920x1080") for the renderer.
fb_size() {
    if [ -n "$SIZE_OVERRIDE" ]; then
        printf '%s' "$SIZE_OVERRIDE"
        return 0
    fi
    local fb="fb0" dev="${FRAMEBUFFER:-/dev/fb0}"
    case "$dev" in */*) fb="${dev##*/}" ;; esac
    case "$fb" in fb[0-9]*) ;; *) fb="fb0" ;; esac
    local vs="/sys/class/graphics/$fb/virtual_size" wh=""
    [ -r "$vs" ] && wh="$(tr ',' 'x' < "$vs" | tr -d '[:space:]')"
    case "$wh" in [0-9]*x[0-9]*) printf '%s' "$wh"; return 0 ;; esac
    return 1
}

# Sorted list of gallery images (PNG only: that is what the
# renderer decodes). Prints one file name (not path) per line.
gallery_list() {
    [ -d "$GALLERY" ] || return 0
    local f
    for f in "$GALLERY"/*.png "$GALLERY"/*.PNG; do
        [ -f "$f" ] && printf '%s\n' "${f##*/}"
    done | LC_ALL=C sort -u
}

current_image() {
    # Where the rotation currently is: the remembered state when
    # remembering is on, else the first image.
    if [ "$REMEMBER" = "on" ] && [ -f "$STATE" ]; then
        local name
        name="$(head -n 1 "$STATE" | tr -d '[:space:]')"
        if [ -n "$name" ] && [ -f "$GALLERY/$name" ]; then
            printf '%s' "$name"
            return 0
        fi
    fi
    gallery_list | head -n 1
}

pick_next() {
    local cur="$1" list=() name idx=-1 i pick
    while IFS= read -r name; do list+=("$name"); done < <(gallery_list)
    local n=${#list[@]}
    [ "$n" -ge 2 ] || return 1
    for i in "${!list[@]}"; do
        [ "${list[$i]}" = "$cur" ] && idx=$i
    done
    if [ "$ORDER" = "random" ]; then
        pick=$((RANDOM % n))
        if [ "${list[$pick]}" = "$cur" ]; then
            pick=$(( (pick + 1) % n ))
        fi
    else
        pick=$(( (idx + 1) % n ))
    fi
    printf '%s' "${list[$pick]}"
}

show_image() {
    # Render $1 and hand it to FbTerm (atomic rename).
    local name="$1" size trans tmp
    size="$(fb_size)" || { log "cannot tell the framebuffer size; skipping"; return 1; }
    trans="$TRANSITION"
    if [ "$trans" = "random" ]; then
        case $((RANDOM % 3)) in
            0) trans=crossfade ;;
            1) trans=black ;;
            *) trans=white ;;
        esac
    fi
    tmp="$DATA/.next.fbg.tmp.$$"
    if "$RENDER_BIN" --size "$size" --mode "$MODE" --brightness "$BRIGHTNESS" \
            --transition "$trans" --duration "$DURATION" \
            "$GALLERY/$name" "$tmp" >> "$LOG" 2>&1; then
        mv -f "$tmp" "$DROP" || return 1
        printf '%s\n' "$name" > "$STATE" || true
        log "background -> $name ($size, $trans)"
        return 0
    fi
    rm -f "$tmp"
    log "render failed for $name"
    return 1
}

main() {
    [ -x "$RENDER_BIN" ] || { log "fbrender missing; slideshow off"; exit 0; }
    local launcher_pid="$PPID" waited cur next
    log "slideshow started (launcher pid $launcher_pid)"
    read_config
    cur="$(current_image)"
    while :; do
        # Die with the launcher if it goes away without killing us.
        [ -d "/proc/$launcher_pid" ] || exit 0

        # Wait one interval, in 1-second steps so config edits
        # (including turning the slideshow off) apply at once, and
        # so a manual "next" request is honoured quickly.
        waited=0
        while [ "$waited" -lt "$INTERVAL" ]; do
            [ -d "/proc/$launcher_pid" ] || exit 0
            if [ -e "$NEXT_REQUEST" ]; then
                rm -f "$NEXT_REQUEST"
                break
            fi
            sleep 1
            waited=$((waited + 1))
            read_config
            [ "$ENABLED" = "on" ] || break
        done

        read_config
        [ "$ENABLED" = "on" ] || { sleep 2; continue; }
        [ -n "$cur" ] || cur="$(current_image)"
        next="$(pick_next "$cur")" || { sleep 5; cur=""; continue; }
        if show_image "$next"; then
            cur="$next"
        else
            sleep 5
        fi
    done
}

main "$@"
