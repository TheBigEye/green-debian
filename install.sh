#!/usr/bin/env bash
# Interactive installer for Debian 13.7 "trixie" Stable onto the VM's only disk.
#
# The real scenario it is written for:
#   - You upload THIS file to GitHub.
#   - You boot debian-live-13.7.0-amd64-standard.iso in your VM.
#   - Inside the live session you download the script with curl/wget and run it.
#   - The VM has ONE single disk: /dev/sda. There is no second disk, no
#     shared folders, no auxiliary images, no host involved in the install.
#
# All temporary work (log, state, backups, tarballs, Zig, caches, GPG keys)
# lives in /tmp, which on trixie is tmpfs in RAM. Therefore:
#   * NOTHING of the installer remains inside the installed system.
#   * EVERYTHING is lost when you power off/reboot the VM.
#   * --resume only works WHILE the live session is still alive.
#
# It does not promise "zero failure": hardware, firmware, network and
# memory can fail. It offers --explain, --validate, --dry-run, --simulate,
# --config, --resume, --refresh-limine, preflight, RAM backups, traps and
# confirmations.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.2.0"
SCRIPT_NAME="$(basename "$0")"

DRY_RUN=0
SIMULATE=0
ACCEPT_DEFAULTS=0
RESUME=0
REFRESH_LIMINE=0
VALIDATE_ONLY=0
EXPLAIN_ONLY=0
LOG_GIVEN=0
INPUT_CONFIG=""

# Directories in RAM. STATE_DIR and ARTIFACT_DIR are kept until poweroff;
# SCRATCH_DIR is deleted in cleanup so no toolchain or keys are left behind.
BASE_DIR="/tmp/debian-live-install"
STATE_DIR="$BASE_DIR/state"
ARTIFACT_DIR="$BASE_DIR/artifacts"
SCRATCH_DIR="$BASE_DIR/scratch"
LOG_FILE="$ARTIFACT_DIR/install.log"
STATE_FILE="$STATE_DIR/stage"
CONFIG_FILE="$STATE_DIR/config"
SCRATCH_DIR_REAL=""
LAST_STAGE=0
MOUNTS=()
HELP_FN=""
HELP_SHOWN=""
HELP_FULL=0
UI_COLOR=0
UI_WIDTH=76
C_RESET=""
C_CYAN=""
C_GREEN=""
C_YELLOW=""
C_RED=""
C_DIM=""

# ---------------------------- utilidades base ----------------------------

log() {
    local msg="$*" dir
    printf '%s\n' "$msg"
    dir="$(dirname "$LOG_FILE")"
    if [[ -d "$dir" && -w "$dir" ]]; then
        printf '%s %s\n' "$(date -Is)" "$msg" >> "$LOG_FILE"
    fi
}

cmd_to_text() {
    local out="" a
    for a in "$@"; do
        printf -v out '%s %q' "$out" "$a"
    done
    printf '%s' "${out# }"
}

# ---------------------------- interface (small console) ----------------------------
# Designed for a low-resolution console (e.g. 80x25 or the small QEMU
# window): short lines, summaries of at most 10 lines per block, the full
# explanation only via ?, colours only if there is a TTY and NO_COLOR is
# not set, and a short animation only on a real terminal.
# Without a TTY (captured output, tests, pipes) everything stays plain
# text, so the log and the output remain byte-for-byte comparable.

ui_init() {
    UI_WIDTH=76
    if [[ -n "${COLUMNS:-}" && "${COLUMNS}" =~ ^[0-9]+$ ]] && (( COLUMNS >= 40 && COLUMNS < UI_WIDTH )); then
        UI_WIDTH="$COLUMNS"
    fi
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
        UI_COLOR=1
        C_RESET=$'\033[0m'
        C_CYAN=$'\033[1;36m'
        C_GREEN=$'\033[1;32m'
        C_YELLOW=$'\033[1;33m'
        C_RED=$'\033[1;31m'
        C_DIM=$'\033[2m'
    else
        UI_COLOR=0
        C_RESET=""
        C_CYAN=""
        C_GREEN=""
        C_YELLOW=""
        C_RED=""
        C_DIM=""
    fi
}

ui_prompt() {
    if (( UI_COLOR )); then
        printf '%s> %s%s' "$C_CYAN" "$*" "$C_RESET"
    else
        printf '> %s' "$*"
    fi
}

ui_rule() {
    local line=""
    printf -v line '%*s' "$UI_WIDTH" ''
    printf '%s%s%s\n' "$C_DIM" "${line// /-}" "$C_RESET"
}

ui_banner() {
    ui_init
    printf '\n'
    ui_rule
    printf '  %sDEBIAN 13 TRIXIE%s  ·  minimal installer\n' "$C_CYAN" "$C_RESET"
    printf '  /dev/sda · LUKS2 · Limine UEFI+BIOS · Openbox or TTY only\n'
    printf '  %sv%s%s  ·  ? = full help  ·  Ctrl+C = cancel\n' "$C_DIM" "$SCRIPT_VERSION" "$C_RESET"
    ui_rule
    ui_animation
}

ui_animation() {
    (( UI_COLOR )) || return 0
    (( DRY_RUN )) && return 0
    [[ -t 1 ]] || return 0
    # shellcheck disable=SC1003
    local frames=('-' '\' '|' '/') i
    for i in 0 1 2 3 4 5 6 7; do
        printf '\r  %spreparing installer %s%s' "$C_DIM" "${frames[i % 4]}" "$C_RESET"
        sleep 0.06
    done
    printf '\r  %spreparing installer done%s\n' "$C_GREEN" "$C_RESET"
}

ui_progress() {
    local n="${1:-0}" total=15 filled=0 bar="" empty=""
    (( UI_COLOR )) || return 0
    (( n >= 0 && n <= total )) || return 0
    filled=$(( n * 24 / total ))
    printf -v bar '%*s' "$filled" ''
    bar="${bar// /#}"
    printf -v empty '%*s' "$((24 - filled))" ''
    empty="${empty// /-}"
    printf '  %s[%s%s]%s stage %d/%d\n' "$C_GREEN" "$bar" "$empty" "$C_RESET" "$n" "$total"
}

ui_stage_title() {
    local n="$1" title="$2"
    printf '\n'
    ui_rule
    printf '  %s[%02d/15]%s %s\n' "$C_CYAN" "$n" "$C_RESET" "$title"
    ui_rule
}

run() {
    log "+ $(cmd_to_text "$@")"
    if (( DRY_RUN )); then
        return 0
    fi
    "$@"
}

run_in_dir() {
    local dir="$1"
    shift
    log "+ (cd $(cmd_to_text "$dir") && $(cmd_to_text "$@"))"
    if (( DRY_RUN )); then
        return 0
    fi
    ( cd "$dir" && "$@" )
}

die() {
    log "ERROR: $*"
    exit 1
}

fail() {
    local line="$1" orden="$2"
    log "FAILURE at line $line: $orden"
    cleanup
    exit 1
}

cleanup() {
    trap - EXIT ERR
    if (( ! DRY_RUN && ! SIMULATE )); then
        if [[ -n "${M:-}" && "$M" != "/" ]] && findmnt "$M" >/dev/null 2>&1; then
            umount -R "$M" 2>/dev/null || true
        fi
        if [[ -e /dev/mapper/cryptroot ]]; then
            cryptsetup close cryptroot 2>/dev/null || true
        fi
    fi
    # Only the scratch dir is deleted. State and backups survive in RAM
    # to allow --resume within the same live session.
    if [[ -n "$SCRATCH_DIR_REAL" && -d "$SCRATCH_DIR_REAL" ]]; then
        rm -rf -- "$SCRATCH_DIR_REAL" 2>/dev/null || true
    fi
    sync 2>/dev/null || true
}

trap cleanup EXIT
trap 'fail "$LINENO" "$BASH_COMMAND"' ERR

mount_track() {
    local mp="$1"
    shift
    run mount "$@" "$mp"
    MOUNTS+=("$mp")
}

require_cmd() {
    if (( SIMULATE || DRY_RUN )); then
        return 0
    fi
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

require_root() {
    if (( SIMULATE || DRY_RUN )); then
        return 0
    fi
    [[ $EUID -eq 0 ]] || die "Run as root: sudo -i"
}

capture() {
    local var="$1" out
    shift
    if (( DRY_RUN || SIMULATE )); then
        printf -v "$var" '%s' "SIMULADO-$var"
    else
        out="$("$@")"
        printf -v "$var" '%s' "$out"
    fi
}

truncate_file() {
    local file="$1"
    run sh -c ': > "$1"' sh "$file"
}

write_line() {
    local file="$1" line="$2"
    log "write $file: $line"
    run sh -c 'printf "%s\n" "$1" >> "$2"' sh "$line" "$file"
}

write_lines() {
    local file="$1" line
    shift
    truncate_file "$file"
    for line in "$@"; do
        write_line "$file" "$line"
    done
}

verify_sha() {
    local expected="$1" file="$2"
    log "+ sha256sum -c - for $file (expected $expected)"
    if (( DRY_RUN || SIMULATE )); then
        return 0
    fi
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
}

derive_paths() {
    STATE_DIR="$BASE_DIR/state"
    ARTIFACT_DIR="$BASE_DIR/artifacts"
    SCRATCH_DIR="$BASE_DIR/scratch"
    STATE_FILE="$STATE_DIR/stage"
    CONFIG_FILE="$STATE_DIR/config"
    if (( ! LOG_GIVEN )); then
        LOG_FILE="$ARTIFACT_DIR/install.log"
    fi
}

init_dirs() {
    local logdir
    logdir="$(dirname "$LOG_FILE")"
    mkdir -p -- "$logdir" || die "Cannot create the log directory: $logdir"
    if [[ "$logdir" != /tmp ]]; then
        chmod 700 -- "$logdir" 2>/dev/null || true
    fi
    if (( DRY_RUN || SIMULATE )); then
        SCRATCH_DIR_REAL="/tmp/debian-live-install-simulado"
        return 0
    fi
    mkdir -p -- "$STATE_DIR" "$ARTIFACT_DIR"
    chmod 700 "$STATE_DIR" "$ARTIFACT_DIR"
    SCRATCH_DIR_REAL="$(mktemp -d "$SCRATCH_DIR.XXXXXX")"
    chmod 700 "$SCRATCH_DIR_REAL"
}

save_config() {
    local k v tmp
    if (( DRY_RUN || SIMULATE )); then
        return 0
    fi
    mkdir -p "$STATE_DIR"
    tmp="$CONFIG_FILE.tmp"
    : > "$tmp"
    for k in "${CONFIG_KEYS[@]}"; do
        v="$(printf '%s' "${!k}" | base64 -w0)"
        printf '%s=%s\n' "$k" "$v" >> "$tmp"
    done
    mv -f "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

load_config_from() {
    local file="$1" line k v decoded allowed kk
    [[ -r "$file" ]] || die "Cannot read the config: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            continue
        fi
        [[ "$line" == *=* ]] || die "Config line without '=': $line"
        k="${line%%=*}"
        v="${line#*=}"
        [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Malformed config key: $k"
        allowed=0
        for kk in "${CONFIG_KEYS[@]}"; do
            if [[ "$kk" == "$k" ]]; then
                allowed=1
                break
            fi
        done
        (( allowed )) || die "Config key not allowed: $k"
        if [[ -z "$v" ]]; then
            # These keys are legitimately empty: no extra packages, or
            # UUID/ABI not discovered yet in early stages.
            case "$k" in
                EXTRA_PACKAGES_STR|K|LUKS_UUID|ROOT_UUID|BOOT_UUID) ;;
                *) die "Empty value for $k" ;;
            esac
        fi
        if ! decoded="$(printf '%s' "$v" | base64 -d 2>/dev/null)"; then
            die "Invalid base64 value for $k"
        fi
        [[ "$decoded" != *$'\n'* && "$decoded" != *$'\r'* ]] || die "Value with a newline not allowed: $k"
        printf -v "$k" '%s' "$decoded"
    done < "$file"
    parse_extra_packages
    log "Config loaded: $file (no passwords)"
}

mark_stage() {
    LAST_STAGE="$1"
    if (( DRY_RUN || SIMULATE )); then
        return 0
    fi
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$LAST_STAGE" > "$STATE_FILE" || die "Cannot save state to $STATE_FILE"
    save_config
    log "Stage $LAST_STAGE completed"
    ui_progress "$LAST_STAGE"
}

stage_done() {
    local n="$1"
    (( RESUME && n <= LAST_STAGE ))
}

read_state() {
    if [[ -r "$STATE_FILE" ]]; then
        local v
        v="$(tail -n 1 "$STATE_FILE" | tr -cd '0-9')"
        if [[ -n "$v" ]]; then
            LAST_STAGE="$v"
        fi
    fi
}

parse_extra_packages() {
    EXTRA_PACKAGES=()
    local p oldifs
    local -a arr=()
    oldifs="$IFS"
    IFS=' '
    # read -ra avoids the glob expansion that for p in $VAR would have
    read -r -a arr <<< "$EXTRA_PACKAGES_STR"
    IFS="$oldifs"
    for p in "${arr[@]}"; do
        [[ "$p" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "Invalid extra package: $p"
        EXTRA_PACKAGES+=("$p")
    done
}

in_set() {
    local needle="$1" x
    shift
    for x in "$@"; do
        if [[ "$x" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

is_ip() {
    local s="$1"
    if [[ "$s" =~ ^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$ ]]; then
        return 0
    fi
    if [[ "$s" == *:* && "$s" =~ ^[0-9A-Fa-f:]+$ ]]; then
        return 0
    fi
    return 1
}

# Revalidates ALL preferences, whether they come from questions, --config
# or --resume. Without this, a --config could skip the interactive regexes.
validate_preferences() {
    local k v
    log "=== Strict revalidation of preferences ==="
    for k in "${CONFIG_KEYS[@]}"; do
        v="${!k}"
        [[ "$v" != *$'\n'* && "$v" != *$'\r'* && "$v" != *$'\t'* ]] || die "Value with a control character not allowed: $k"
    done
    [[ "$U" == /dev/sda ]] || die "The target must be /dev/sda"
    [[ "$BIOSP" == "${U}1" && "$B" == "${U}2" && "$R" == "${U}3" ]] || die "Wrong derived partitions: $BIOSP / $B / $R"
    [[ "$M" = /* && "$M" != "/" ]] || die "Invalid mount point: $M"
    [[ "$SUITE" == trixie && "$ARCH" == amd64 ]] || die "Only trixie/amd64"
    [[ "$LOG_FILE" == /tmp/* ]] || die "--log must be under /tmp (RAM) to leave no traces"
    [[ "$LOG_FILE" != *..* ]] || die "--log must not contain '..'"
    [[ "$HOSTNAME_DEB" =~ ^[a-z][a-z0-9-]{0,62}$ ]] || die "invalid hostname: $HOSTNAME_DEB"
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: $USERNAME"
    in_set "$USER_SHELL" /bin/bash /bin/zsh /bin/dash || die "invalid shell: $USER_SHELL"
    [[ "$PASS_MIN_LEN" =~ ^[0-9]+$ ]] || die "non-numeric minimum length: $PASS_MIN_LEN"
    (( PASS_MIN_LEN >= 1 && PASS_MIN_LEN <= 4096 )) || die "minimum length out of range: $PASS_MIN_LEN"
    in_set "$LOCALE" en_US.UTF-8 C.UTF-8 es_AR.UTF-8 || die "invalid locale: $LOCALE"
    in_set "$TZ_AREA" America/Argentina/Buenos_Aires UTC Etc/UTC || die "invalid time zone: $TZ_AREA"
    in_set "$KEYMAP" latam es us || die "invalid keyboard layout: $KEYMAP"
    [[ "$MIRROR" == https://* && "$MIRROR" =~ ^[A-Za-z0-9._/:-]+$ ]] || die "invalid mirror: $MIRROR"
    [[ "$SECURITY" == https://* && "$SECURITY" =~ ^[A-Za-z0-9._/:-]+$ ]] || die "invalid security repo: $SECURITY"
    [[ "$COMPONENTS" =~ ^[a-z0-9,+-]+$ ]] || die "invalid components: $COMPONENTS"
    in_set "$ESP_SIZE" 512M 1G 2G || die "invalid ESP: $ESP_SIZE"
    in_set "$BIOS_SIZE" 1M 2M 8M || die "invalid BIOS Boot: $BIOS_SIZE"
    [[ ${#BOOT_LABEL} -le 11 && "$BOOT_LABEL" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid FAT label: $BOOT_LABEL"
    [[ ${#ROOT_LABEL} -le 16 && "$ROOT_LABEL" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid root label: $ROOT_LABEL"
    [[ ${#LUKS_LABEL} -le 32 && "$LUKS_LABEL" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid LUKS label: $LUKS_LABEL"
    in_set "$PBKDF" argon2id pbkdf2 || die "invalid KDF: $PBKDF"
    in_set "$PBKDF_MEM" 65536 131072 262144 524288 || die "invalid PBKDF memory: $PBKDF_MEM"
    in_set "$ROOT_FS" ext4 btrfs || die "invalid rootfs: $ROOT_FS"
    in_set "$KERNEL_HARDENING" conservative aggressive none || die "invalid hardening: $KERNEL_HARDENING"
    in_set "$PLYMOUTH_THEME" spinfinity spinner text details none || die "invalid Plymouth theme: $PLYMOUTH_THEME"
    in_set "$GREETER" greetd ly console || die "invalid greeter: $GREETER"
    in_set "$WM" openbox none || die "invalid WM: $WM"
    in_set "$COMPOSITOR" picom none || die "invalid compositor: $COMPOSITOR"
    in_set "$BAR" tint2 none || die "invalid bar: $BAR"
    in_set "$LAUNCHER" rofi none || die "invalid launcher: $LAUNCHER"
    in_set "$TERMINAL" xterm alacritty both none || die "invalid terminal: $TERMINAL"
    in_set "$FONT_PKG" fonts-jetbrains-mono fonts-dejavu-core xfonts-terminus || die "invalid font: $FONT_PKG"
    in_set "$PIPEWIRE" minimal bluetooth none || die "invalid PipeWire: $PIPEWIRE"
    in_set "$NETWORK" NetworkManager dhcpcd none || die "invalid network: $NETWORK"
    in_set "$FIRMWARE" full minimal none || die "invalid firmware: $FIRMWARE"
    in_set "$MICROCODE" both intel amd none || die "invalid microcode: $MICROCODE"
    in_set "$DATA_POLICY" keep delete "no-backups" || die "invalid data policy: $DATA_POLICY"
    in_set "$HOTPLUG_POLICY" allow0 require1 skip || die "invalid HOTPLUG policy: $HOTPLUG_POLICY"
    in_set "$LIMINE_BIOS_FORCE" yes no || die "LIMINE_BIOS_FORCE must be yes/no: $LIMINE_BIOS_FORCE"
    [[ "$SIZE_MIN_GB" =~ ^[0-9]+$ && "$SIZE_MAX_GB" =~ ^[0-9]+$ ]] || die "non-numeric size range"
    (( SIZE_MIN_GB >= 1 && SIZE_MAX_GB <= 2000 && SIZE_MIN_GB <= SIZE_MAX_GB )) || die "invalid size range: $SIZE_MIN_GB-$SIZE_MAX_GB GB"
    if ! [[ "$CURL_RETRIES" =~ ^[0-9]+$ ]] || (( CURL_RETRIES > 10 )); then
        die "invalid retries: $CURL_RETRIES"
    fi
    if ! [[ "$NETWORK_TIMEOUT" =~ ^[0-9]+$ ]] || (( NETWORK_TIMEOUT < 1 || NETWORK_TIMEOUT > 120 )); then
        die "invalid timeout: $NETWORK_TIMEOUT"
    fi
    in_set "$ZRAM_SIZE" 2048 4096 1024 || die "invalid ZRAM: $ZRAM_SIZE"
    [[ "$BG" =~ ^[0-9A-Fa-f]{6}$ && "$FG" =~ ^[0-9A-Fa-f]{6}$ && "$ACCENT" =~ ^[0-9A-Fa-f]{6}$ ]] || die "invalid hex colour"
    is_ip "$DNS1" || die "invalid primary DNS: $DNS1 (use a literal IP)"
    is_ip "$DNS2" || die "invalid secondary DNS: $DNS2 (use a literal IP)"
    for k in UEFI BIOS_BOOT UEFI_IA32 SECURE_BOOT FIREWALL APPARMOR DOAS AUDITD SSH ZRAM GUI VERIFY_GPG LIMINE_EDITOR PLYMOUTH_FALLBACK CLEAN_TRACES MAKE_HOST_BACKUP; do
        in_set "${!k}" yes no || die "$k must be yes/no: ${!k}"
    done
    [[ "$SECURE_BOOT" == no ]] || die "Secure Boot must be disabled"
    if [[ "$GUI" == no && "$GREETER" != console ]]; then
        die "A graphical greeter needs X11; choose console or enable GUI"
    fi
    if [[ "$GUI" == no ]]; then
        # Hard normalization, whether the config comes from questions,
        # --config or --resume: without X11 no graphical leftover stays
        # in the preferences, and build_packages() will not add it either.
        WM=none
        COMPOSITOR=none
        BAR=none
        LAUNCHER=none
        TERMINAL=none
    fi
    if [[ "$GUI" == yes && "$TERMINAL" == none ]]; then
        die "With GUI=yes you need a graphical terminal (xterm, alacritty or both)"
    fi
    if (( ! DRY_RUN && ! SIMULATE )); then
        [[ -z "$K" || "$K" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid kernel ABI: $K"
        for k in LUKS_UUID ROOT_UUID BOOT_UUID; do
            v="${!k}"
            [[ -z "$v" || "$v" =~ ^[A-Fa-f0-9-]{8,}$ ]] || die "invalid $k: $v"
        done
    fi
    parse_extra_packages
    log "Strict revalidation OK"
}

# ---------------------------- explanations ----------------------------
# Each block is shown BEFORE its corresponding question.
# You can also view them all without running anything: bash install.sh --explain
# Press ? at any prompt to read the block again.

show_help() {
    [[ -n "$HELP_FN" ]] || return 0
    ui_init
    # ? asks for the FULL explanation: it is paged with less if there is
    # a TTY, because on a low-resolution console a whole block falls off
    # the screen. --explain still prints everything unpaged.
    if (( HELP_FULL )); then
        HELP_FULL=0
        printf '\n'
        if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then
            "$HELP_FN" | less -FXR
        else
            "$HELP_FN"
        fi
        printf '\n'
        HELP_SHOWN="$HELP_FN"
        return 0
    fi
    # First time: ONLY a summary that fits on a small screen (at most 10
    # lines of the block + one status line). The full detail, with
    # cost/risk/sources, is one key away (?) and in --explain. That way
    # no information is lost, but the question is not pushed off screen.
    if [[ "$HELP_SHOWN" != "$HELP_FN" ]]; then
        local text="" i
        local -a lines=()
        text="$("$HELP_FN")"
        mapfile -t lines <<< "$text"
        printf '\n'
        ui_rule
        for i in "${!lines[@]}"; do
            (( i < 10 )) || break
            printf '  %s\n' "${lines[i]}"
        done
        printf '  %s[?] full explanation (%d lines) · Enter = default value%s\n' "$C_DIM" "${#lines[@]}" "$C_RESET"
        ui_rule
        HELP_SHOWN="$HELP_FN"
    fi
}

help_all() {
    local f
    for f in \
        help_intro help_target help_disk_checks help_workdir help_identity help_locale \
        help_mirror help_components help_firmware help_microcode \
        help_partitions help_luks help_rootfs help_hardening \
        help_plymouth help_limine help_greeter help_gui help_zram \
        help_pipewire help_network help_security help_bootmodes \
        help_bios_install help_dns help_extras help_cleanup help_confirm; do
        printf '\n'
        "$f"
    done
}

# shellcheck disable=SC2016
help_intro() {
    cat <<'EOF'
=== BEFORE YOU START: what will happen and what will NOT happen ===

You are going to install Debian 13.7 "trixie" Stable WITHOUT the
traditional installer, using debootstrap from this live session. The VM's
only disk is /dev/sda and it will be COMPLETELY ERASED: its partition
table is destroyed, a GPT is created from scratch, an ESP is formatted
as FAT32 and a LUKS encrypted container is created.

What does NOT exist in this design:
  - No second disk, auxiliary image or shared folder.
  - Nothing is read from or written to the host.
  - No file is generated for the host.
  - The script does not copy itself into the installed system.

Interface (designed for a low-resolution console):
  Before each block you will see ONLY a summary of 10 lines at most,
  which fits on a small screen. Press ? at the question to open the
  full explanation paged with less; with --explain everything is printed
  at once. There are colours and a progress bar only if the output is a
  real terminal; with NO_COLOR=1 or captured output everything stays
  plain text. Arch-style: short banner, numbered menus, minimal noise
  and no question without a default value.

Where everything lives during the installation:
  Debian 13's /tmp is tmpfs (RAM). There live the log, the state, the
  backups, tarballs, Zig, caches and temporary GPG keys.
  Honest consequences:
    + Zero traces of the installer in the final system.
    - If you power off or reboot the VM, EVERYTHING is lost, state included.
    - --resume only works while this same live session is still alive.
    - Compiling Ly with Zig needs ~1 GB of free RAM; if your VM has
      little memory, choose greetd instead of ly.

Source: https://www.debian.org/releases/stable/release-notes/issues.en.html#the-temporary-files-directory-tmp-is-now-stored-in-a-tmpfs
Source: https://www.debian.org/releases/
EOF
}

# shellcheck disable=SC2016
help_target() {
    cat <<'EOF'
=== Target disk and mount point ===

The target is FIXED to /dev/sda. No other value is accepted, because the
VM has a single disk and any generic substitution could point at the
wrong place. Before touching anything, model, serial, size, TRAN=usb,
that no partitions are mounted, and a HOTPLUG policy (explained in the
next block) are verified.

Temporary mount point: /mnt/target. It is just a directory of the live
session where the encrypted root is mounted while the system is built.
It is not part of the final system; it is unmounted at the end.

If the preflight fails here, do NOT continue: it means /dev/sda is not
the USB you expected or it is in use.

Recommended: leave /dev/sda and /mnt/target as they are.
EOF
}

# shellcheck disable=SC2016
help_disk_checks() {
    cat <<'EOF'
=== Disk guards: HOTPLUG, TRAN and size ===

These three checks exist so you do NOT accidentally erase the host's
disk. They can now be adjusted because a VM does not behave like a
physical pendrive.

HOTPLUG (lsblk -dn -o HOTPLUG):
  On a real hot-plugged USB it is usually 1. In QEMU, when the disk is
  presented with usb-storage before boot, seeing 0 is normal.
  In YOUR output you see: TRAN=usb  HOTPLUG=0  SIZE 57.7G. Blindly
  requiring 1 blocked the installation even though the disk was right.
  Options:
    allow0   (RECOMMENDED): accepts 0 or 1; warns if it is 0. Meant for VMs.
    require1 : only accepts 1. Useful if you later plug the USB into a
               physical PC and want the classic check.
    skip     : does not look at HOTPLUG. Less safe; only if you know why.
  Whichever the option, TRAN=usb, fixed /dev/sda, visible model/serial/
  size, no mounted partitions and the literal "ERASE /dev/sda"
  confirmation are still required. HOTPLUG was never the only
  anti-host guard.

TRAN (lsblk -dn -o TRAN):
  It must be "usb". It is the most reliable check in this scenario: if
  /dev/sda were a SATA/virtio/NVMe disk of the host, TRAN would not be
  usb and the script would abort. Deliberately not configurable.

SIZE (lsblk -dn -o SIZE -b, in bytes):
  Mind the units: "57.7G" in lsblk is GiB (base 1024), which equals
  ~61,900,000,000 bytes (61.9 decimal GB). The previous guard accepted
  only 58,000,000,000 - 61,000,000,000 bytes and therefore rejected
  your 57.7G disk by barely 900 MB.
  Now a range in decimal GB is asked. Default 50-70 GB, which covers
  both 57.7 GiB (~61.9 GB) and 59,120 MiB (~61.99 GB). If you use
  another USB of a different capacity, adjust the two numbers.

NETWORK:
  curl retries and timeout. With 3 retries and a 15 s connection
  timeout, a mirror that stumbles does not abort at the first try.
  Raise the timeout if your network is slow; lower it to fail fast.

Source: https://manpages.debian.org/trixie/util-linux/lsblk.8.en.html
Source: https://www.qemu.org/docs/master/system/devices/usb.html
Source: https://manpages.debian.org/trixie/curl/curl.1.en.html
EOF
}

# shellcheck disable=SC2016
help_workdir() {
    cat <<'EOF'
=== State, backups and data lifetime ===

The script uses three directories inside /tmp (RAM):

  state/      current stage and NON-secret preferences for --resume.
  artifacts/  log, first 16 MiB of the disk, previous GPT table,
              LUKS header, UUIDs, limine.conf, crypttab, fstab and final GPT.
  scratch/    tarballs, Zig, build caches, GPG keys and temporary
              password files. DELETED when the script exits.

Question: what to do with state/ and artifacts/ when finished.

  keep (recommended): they stay in RAM until you power off the VM. That
      way you can use --resume if something fails, and you can read the
      log with less. They are lost on poweroff anyway; nothing remains
      on the installed disk.
  delete: removed on exit. Cleaner, but --resume will stop working and
      you will lose the LUKS header backup.
  no-backups: neither GPT nor LUKS header is saved. Faster, but if the
      disk gets corrupted there is no recovery.

WARNING: the LUKS header is the only backup copy of the encryption. If
you really want to keep it, copy it BEFORE powering off the VM to
another server with curl/scp. The script does not impose where.

Recommended: "keep". It is free and leaves no traces.
Source: https://manpages.debian.org/trixie/cryptsetup-bin/cryptsetup-luksHeaderBackup.8.en.html
EOF
}

# shellcheck disable=SC2016
help_identity() {
    cat <<'EOF'
=== Hostname, user and passwords ===

Hostname: short name, lowercase, no spaces. It is the machine's name on
the network; it does not affect encryption or booting.

User: created with home in /home and added to the sudo, audio and video
groups. No other interactive user is created.

Shell: bash is the most compatible; zsh adds a package; dash is minimal
and not very comfortable as an interactive shell.

Minimum password length (its own question):
  Default 1 = NO minimum. You can set any number from 1 to 4096 if you
  want to impose one yourself. There is NO "mandatory 12" anymore.
  With 1, anything from a single character to a long passphrase is accepted.
  If you choose fewer than 12 characters the script WARNS on screen, but
  does NOT block you: the decision is yours.

Passwords (user, root and LUKS passphrase):
  - Asked TWICE and never shown.
  - ALL printable ASCII characters (0x21 to 0x7E) are accepted:
    letters, numbers and symbols like ! @ # $ % ^ & * ( ) - _ = + [ ] { }
    ; ' , . < > / ? ~ " \ ` | and even ':' .
  - NOT accepted: spaces, tabs, line breaks, control characters,
    accented letters, eñes, emojis or any non-ASCII UTF-8 byte.
  - '?' and '??' ARE valid passwords. To re-read this help at a password
    prompt press ENTER WITHOUT TYPING ANYTHING (do not use '?', because
    '?' can now be your password). In normal questions '?' is used.
  - Why accents are excluded: the initramfs asks for the LUKS passphrase
    BEFORE loading the full keyboard layout. If you use accents, eñes or
    symbols that differ between the latam and us maps, you will be able
    to type it in the live session but NOT at boot, and the system will
    look like it "does not accept the password". It is the most common
    cause of lockout in encrypted installations.
  - So a short password is not rejected later by PAM, the script uses
    `chpasswd -c YESCRYPT`: it hashes directly with libc instead of going
    through pam_unix "obscure" / pam_pwquality.
  - For the same reason, LUKS uses `--force-password`, which disables
    cryptsetup's password quality check if the build ships it.
  - The passphrase is written to a temporary file WITHOUT a trailing
    newline; `--key-file -` reads stdin and does NOT split on newlines,
    so what you type is exactly the passphrase, with no hidden \n.
  - The LUKS passphrase is NOT saved in the state or the log. If you
    reboot, you will have to type it again for --resume or --refresh-limine.

SECURITY WARNING (non-blocking): a short password is far more
vulnerable to brute force, especially the LUKS passphrase. If you can,
make it long; if not, the script lets you anyway.

Recommended: a long but ASCII LUKS passphrase (e.g. 4 words without
accents separated by hyphens), different from the user password.
Source: https://manpages.debian.org/trixie/passwd/chpasswd.8.en.html
Source: https://manpages.debian.org/trixie/cryptsetup-bin/cryptsetup-luksFormat.8.en.html
Source: https://www.debian.org/doc/manuals/securing-debian-manual/ch04s11.en.html
EOF
}

# shellcheck disable=SC2016
help_locale() {
    cat <<'EOF'
=== Locale, time zone and keyboard ===

Locale: en_US.UTF-8 keeps system messages in English and UTF-8, which is
the most predictable for diagnosing boot errors. C.UTF-8 is even more
minimal (no translated messages or regional formatting).
es_AR.UTF-8 translates messages, but error logs appear in Spanish and
are sometimes harder to search for in official documentation.

Time zone: only affects the displayed time and the logs. Hardware time
is treated as local; on a USB that moves between PCs, UTC is the most
neutral option. America/Argentina/Buenos_Aires is right if you will
always use the USB in Buenos Aires.

Keyboard: latam is the map with eñe and accents in console and X11. It is
also copied into the initramfs with KEYMAP=y so the LUKS passphrase is
typed the same way. Note: an ASCII passphrase is still recommended,
because the map switch inside the initramfs is not identical to a full
session.

Recommended: en_US.UTF-8 + your zone + latam, with an ASCII LUKS passphrase.
Source: https://manpages.debian.org/trixie/locales/locale.gen.5.en.html
Source: https://manpages.debian.org/trixie/keyboard-configuration/keyboard.5.en.html
EOF
}

# shellcheck disable=SC2016
help_mirror() {
    cat <<'EOF'
=== Debian mirror and security mirror ===

It is verified that the mirror serves dists/trixie/Release with
Codename: trixie and that the security mirror serves trixie-security.
No mixing with testing, sid, backports or other branches.

Options verified in prior research:
  mirror.sitsa.com.ar       Buenos Aires. Serves trixie 13.7.
  debian.c3sl.ufpr.br       Brasil. Serves trixie and also trixie-security.
  deb.debian.org            Redirects to the nearest mirror. Generic.

If you choose Brasil, the script automatically uses its debian-security
path; if you choose Buenos Aires or deb.debian.org, it uses
security.debian.org. You can correct the security URL by hand.

Why it matters: debootstrap and apt verify OpenPGP signatures of
Release. An outdated mirror, or one that does not serve security,
breaks the installation or leaves the system without patches.

Recommended: Buenos Aires; Brasil as backup.
Source: https://www.debian.org/mirror/list-full
Source: https://manpages.debian.org/trixie/debootstrap/debootstrap.8.en.html
EOF
}

# shellcheck disable=SC2016
help_components() {
    cat <<'EOF'
=== APT components ===

main                Free software only, no proprietary firmware.
contrib             Free software that depends on something non-free.
non-free-firmware   Proprietary firmware needed by many Wi-Fi cards,
                    GPUs and network cards. In trixie it is a separate
                    component, NOT part of non-free.
non-free            Proprietary software in general. NOT used here.

The firmware profile you choose below rewrites this value:
  full / minimal -> main,contrib,non-free-firmware
  none           -> main

non-free is NOT added: it is not needed to boot and avoids bloat. If you
later need a proprietary driver, you can edit
/etc/apt/sources.list.d/debian.sources in the installed system.

Internal format vs file format:
  In questions, --config and `debootstrap --components` they are written
  COMMA-SEPARATED (main,contrib,non-free-firmware). But debian.sources
  is deb822 and `Components:` demands SPACES, not commas: with commas APT
  tries to find a single component named "main,contrib,non-free-firmware"
  and emits "Skipping acquire of configured file ... component misspelt".
  The script converts commas to spaces when writing the file and deletes
  the one-line /etc/apt/sources.list left by debootstrap, so there are no
  duplicate sources. That way trixie-updates and trixie-security also get
  in, which with the error were left without package indices.

Recommended: let the firmware profile decide; do not type it by hand.
Source: https://www.debian.org/releases/stable/release-notes/index.en.html
Source: https://manpages.debian.org/trixie/apt/sources.list.5.en.html
Source: https://manpages.debian.org/trixie/debootstrap/debootstrap.8.en.html
EOF
}

# shellcheck disable=SC2016
help_firmware() {
    cat <<'EOF'
=== Firmware profile (multi-PC compatibility) ===

 full    : installs firmware-linux-free, firmware-amd-graphics,
           firmware-intel-graphics, firmware-nvidia-graphics,
           firmware-misc-nonfree, firmware-realtek, firmware-iwlwifi,
           firmware-atheros, firmware-brcm80211, firmware-mediatek.
           Maximizes the chance that the USB boots with network and
           graphics on different PCs. Cost: ~200-300 MB more.
 minimal : firmware-linux-free, firmware-realtek, firmware-iwlwifi,
           firmware-misc-nonfree. Covers the most common (Ethernet/Wi-Fi).
 none    : main only. Smaller system, but an Intel/Realtek Wi-Fi or a
           GPU that needs firmware may not work until you install the
           package by hand over a cable.

Note that this does NOT guarantee universal compatibility: some devices
need microcode, kernel modules or drivers that are not in Debian. It is
reasonable coverage, not a promise.

Recommended: "full" on a portable USB that will move between PCs.
Source: https://packages.debian.org/trixie/firmware-misc-nonfree
Source: https://wiki.debian.org/Firmware
EOF
}

# shellcheck disable=SC2016
help_microcode() {
    cat <<'EOF'
=== CPU microcode ===

 intel-microcode : updates microcode of Intel processors.
 amd64-microcode : updates microcode of AMD processors.
 both            : installs both. They are a few KB and each only acts
                   if it detects its CPU. It is the most portable option.
 none            : not installed. The kernel will use the microcode that
                   each PC's BIOS/UEFI already carries.

Microcode is loaded very early in boot and fixes CPU errata and some
mitigations. It does not replace updating the board firmware, but it is
cheap and improves stability.

Recommended: "both" for a USB used on several machines.
Source: https://packages.debian.org/trixie/intel-microcode
Source: https://packages.debian.org/trixie/amd64-microcode
EOF
}

# shellcheck disable=SC2016
help_partitions() {
    cat <<'EOF'
=== ESP size, BIOS Boot and labels ===

Resulting GPT:
  p1  ef02  BIOS Boot     1-8 MiB   -> for Limine on BIOS/legacy.
  p2  ef00  ESP FAT32     512M/1G/2G -> mounted at /boot UNENCRYPTED.
  p3  8309  LUKS          the rest  -> encrypted ext4/btrfs root inside.

Why /boot goes UNENCRYPTED: Limine cannot read LUKS, LVM or ext4 to
find vmlinuz and initrd.img. The kernel, the initramfs and limine.conf
must be on a partition that the firmware and Limine can read before
asking for the passphrase. The initramfs is what opens cryptroot later.

ESP size: the trixie notes ask for AT LEAST 768 MB in /boot with about
300 MB free, because kernel+firmware grew a lot. 512M can be tight if
you choose the full firmware profile and several kernels. 1G is the
balance; 2G is roomy and costs ~1 GB less of root.

BIOS Boot: 2M is enough for Limine's stage on GPT. 8M is extra margin.

Labels: FAT32 allows at most 11 characters; they are validated. The
LUKS label is informational (udev), it does not affect crypttab, which
uses the UUID.

Check tools the script installs INTO THE TARGET SYSTEM:
  e2fsprogs   -> fsck.ext4  (ext4 root and initramfs-tools' fsck hook)
  dosfstools  -> fsck.vfat  (ESP /boot on FAT32)
  btrfs-progs -> fsck.btrfs (only if you choose btrfs as root)
  zstd        -> initramfs compressor; without it, initramfs-tools warns
                 "W: No zstd in /usr/bin:/sbin:/bin, using gzip".
On trixie, initramfs-tools-core depends on
`logsave | e2fsprogs (<< 1.45.3-1~)`; APT may choose logsave and NOT
install e2fsprogs. Then update-initramfs warns:
  W: /sbin/fsck.ext4 doesn't exist, can't install to initramfs
That is why the script asks for e2fsprogs and dosfstools explicitly: the
initramfs can check/repair the root and the system can check /boot.

Recommended: ESP 1G, BIOS Boot 2M, default labels.
Source: https://www.debian.org/releases/stable/release-notes/issues.en.html#ensure-boot-has-enough-free-space
Source: https://github.com/Limine-Bootloader/Limine/blob/trunk/FAQ.md
Source: https://manpages.debian.org/trixie/dosfstools/mkfs.fat.8.en.html
Source: https://sources.debian.org/src/initramfs-tools/0.148.4/hooks/fsck/
Source: https://packages.debian.org/trixie/amd64/e2fsprogs/filelist
Source: https://packages.debian.org/trixie/amd64/dosfstools/filelist
EOF
}

# shellcheck disable=SC2016
help_luks() {
    cat <<'EOF'
=== LUKS2: KDF and Argon2id memory ===

argon2id (recommended): modern KDF, resistant to GPUs/ASICs. It uses
memory and CPU when opening the disk. Memory options:
  65536 KiB  = 64 MiB   -> opens fast on any PC, including VMs with
                           2 GB of RAM. RECOMMENDED for a portable USB.
  131072 KiB = 128 MiB  -> more resistance, somewhat slower opening.
  262144 KiB = 256 MiB  -> can be slow and fail on low-RAM machines.
  524288 KiB = 512 MiB  -> NOT recommended on a USB that will move
                           between PCs: cryptsetup may reduce it, but
                           the benchmark and unlock cost are high.

pbkdf2: old KDF, time/iterations only, no memory cost. It is more
compatible with very old machines and minimal initramfs setups, but it
is much weaker against GPU brute force. Choose it only if you had real
problems with argon2id.

The script uses --type luks2, --label, --key-file - (the passphrase is
passed via stdin from a temporary file in scratch/ with umask 077) and
makes a luksHeaderBackup in RAM. crypttab then uses the UUID, not
/dev/sda3, so disk order cannot break booting. --force-password is
added so the password quality check (pwquality/passwdqc, if the
cryptsetup build ships it) does NOT reject a short passphrase chosen by
the user.

Recommended: argon2id with 65536 KiB.
Source: https://manpages.debian.org/trixie/cryptsetup-bin/cryptsetup-luksFormat.8.en.html
Source: https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html
EOF
}

# shellcheck disable=SC2016
help_rootfs() {
    cat <<'EOF'
=== Encrypted root filesystem ===

ext4 : mature, predictable, very well documented boot and recovery.
       Less memory, fewer surprises with the initramfs. RECOMMENDED.
btrfs: zstd:1 compression, snapshots and checksums. Adds btrfs-progs to
       the initramfs and the system. On a USB it can be useful, but if
       the initramfs does not include the module properly or there are
       power cuts, recovery is trickier. Do not use snapshots without
       knowing how they behave with LUKS.

Both go INSIDE /dev/mapper/cryptroot, never on the ESP. fstab uses the
inner filesystem's UUID, and crypttab uses the LUKS partition UUID.

There is no fixed swap on disk: ZRAM is used (below). That avoids
writing unencrypted memory pages and extends the pendrive's life.

Recommended: ext4.
Source: https://manpages.debian.org/trixie/e2fsprogs/mkfs.ext4.8.en.html
Source: https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html
EOF
}

# shellcheck disable=SC2016
help_hardening() {
    cat <<'EOF'
=== Kernel hardening parameters ===

conservative (RECOMMENDED):
  slab_nomerge, init_on_alloc=1, init_on_free=1,
  page_alloc.shuffle=1, randomize_kstack_offset=1, pti=on, debugfs=off.
  Known mitigations, low risk of breaking programs.

aggressive:
  the above + vsyscall=none + mitigations=auto,nosmt.
  vsyscall=none can BREAK old binaries or an old glibc.
  auto,nosmt can DISABLE SMT/HyperThreading and lose performance.
  Only if you know that no program needs vsyscalls.

none:
  no extra parameters. Maximum compatibility, minimum protection.

These values are written into the cmdline of limine.conf, not into
sysctl, so they apply from the first boot. They are not a "hardened
kernel": Debian does NOT ship a "hardened" kernel as a package; the
official linux-image-amd64 plus these options is used. It is the
closest honest alternative.

Recommended: conservative. If something does not boot, use the text
entry of the Limine menu and edit the cmdline.
Source: https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
Source: https://packages.debian.org/trixie/linux-image-amd64
EOF
}

# shellcheck disable=SC2016
help_plymouth() {
    cat <<'EOF'
=== Plymouth: boot animation ===

Plymouth shows a graphical theme while the initramfs asks for the LUKS
passphrase. It requires `splash` in the cmdline; without it, detailed
text is shown. Themes verified on trixie: spinfinity, spinner, text,
details. "none" installs Plymouth but does NOT put splash in the main
entry.

spinfinity : classic Debian animation. RECOMMENDED.
spinner    : simpler.
text       : text bar, useful if KMS fails.
details    : detailed messages with the theme loaded.

Real risk: on some GPUs or under QEMU, Plymouth can leave the screen
black right when the LUKS passphrase has to be typed. That is why the
script ALWAYS creates a second "text" entry without splash and a third
rescue one. If the screen stays black, reboot and choose "text".

The alternative entry uses plymouth.enable=0, verified in the
init-premount/plymouth script of the trixie package plymouth_24.004.60-5.

Recommended: spinfinity + text entry YES.
Source: https://manpages.debian.org/trixie/plymouth/plymouth.8.en.html
Source: https://packages.debian.org/trixie/plymouth
EOF
}

# shellcheck disable=SC2016
help_limine() {
    cat <<'EOF'
=== Limine: bootloader upstream ===

Quick decision: the kernel is updated ONLY by the zz-limine-update
hook; --refresh-limine remains only as a rescue.

Limine is NOT a Debian package; v12.9.6 is downloaded from GitHub, its
SHA-256 is verified and (by default) the GPG signature with key
05D29860D0A0668AAEFB9D691F3C021BECA23821 in a temporary homedir. Then the
`limine` tool is compiled and they are installed:
  UEFI x64 -> /boot/EFI/BOOT/BOOTX64.EFI
  BIOS     -> /boot/limine-bios.sys + limine bios-install /dev/sda 1
  IA32     -> BOOTIA32.EFI (optional, only 32-bit UEFI machines)

limine.conf uses documented options: timeout, default_entry,
editor_enabled, interface_branding, term_palette/term_background/
term_foreground, protocol: linux, path: boot():/vmlinuz-ABI, cmdline and
module_path: boot():/initrd.img-ABI. The paths are VERSIONED, but you
no longer depend on remembering --refresh-limine:

AUTOMATIC update (v2.1.0): the installed system receives the
zz-limine-update hook (0755) in three places:
  /etc/kernel/postinst.d/       when installing/updating a kernel
  /etc/kernel/postrm.d/         when removing a kernel
  /etc/initramfs/post-update.d/ after creating/updating an initramfs
Debian runs the zz- prefixed bootloader hooks LAST, with $1=ABI and
$2=image path. The hook recomputes the newest vmlinuz-*/initrd.img-*
pair present (it does not trust $1 alone, to also cover removal),
rewrites /boot/limine.conf and its UEFI copy, and if /boot is not
mounted or there is no valid pair it warns and exits with 0 so as not
to break apt. /boot is FAT32 and does not support symlinks useful to
Limine, which is why paths are rewritten instead of linking
unversioned files. --refresh-limine remains ONLY as a rescue from the
live session: system that does not boot, deleted hook, or a USB created
with an older version (a single run makes it automatic).

editor_enabled=yes lets you edit the cmdline in the menu (useful for
recovery). If you disable it, you gain a bit of "hardening" but lose
that quick way out. Secure Boot must be OFF: this configuration is not
enrolled or signed for Secure Boot.

Recommended: verify GPG YES, editor YES, UEFI x64 YES, BIOS YES, IA32 NO.
Fuente: https://github.com/Limine-Bootloader/Limine/releases/tag/v12.9.6
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/CONFIG.md
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/USAGE.md
Fuente: https://kernel-team.pages.debian.net/kernel-handbook/ch-update-hooks.html
Fuente: https://manpages.debian.org/trixie/linux-base/linux-run-hooks.1.en.html
EOF
}

# shellcheck disable=SC2016
help_greeter() {
    cat <<'EOF'
=== Session login manager (greeter) ===

ly (original):
  ncurses TUI from the fairyglade project, v1.5.0 from Codeberg. NOT in
  Debian. It is compiled with Zig 0.17.0 OUTSIDE the target and installed
  with `zig build installexe -Ddest_directory=...`. Really validated:
  compile + ly --validate-config. Cost: downloads ~55 MB of Zig, ~165 KB
  of Ly, Zig Git dependencies and ~1 GB free in /tmp (RAM). It takes a
  few minutes. If the VM has 2 GB of RAM or less, it can fail with
  NoSpaceLeft. It requires network during compilation.

greetd + tuigreet (PACKAGED ALTERNATIVE, more robust):
  greetd 0.10.3-4 and tuigreet 0.9.1-5 are trixie packages. Zero
  toolchain, zero extra downloads, zero RAM risk. It does the same
  thing conceptually: a TUI on a VT that starts the X11 session.
  Config.toml with vt=7 and user _greetd (created by the package).

console:
  No graphical manager: login on a TTY and manual `startx` if there is
  a GUI. Absolute minimum. If you chose GUI=no in the previous question,
  the script already set GREETER=console automatically and you will not
  even see this menu: without X11 there is no possible graphical greeter.

Documentation discrepancy detected: the v1.5.0 tag README says Zig
0.16.x, but build.zig.zon requires 0.17.0. The combination that
ACTUALLY compiles is v1.5.0 + Zig 0.17.0, and it is what this script uses.

Recommended: greetd for the FIRST boot (it boots no matter what). Choose
ly if you want the original and accept the upstream build. If your VM
has little RAM, the script will warn you and ask before continuing.
Fuente: https://codeberg.org/fairyglade/ly/raw/tag/v1.5.0/readme.md
Fuente: https://codeberg.org/fairyglade/ly/raw/tag/v1.5.0/build.zig.zon
Fuente: https://ziglang.org/download/index.json
Fuente: https://packages.debian.org/trixie/greetd
Fuente: https://manpages.debian.org/trixie/greetd/greetd.5.en.html
EOF
}

# shellcheck disable=SC2016
help_gui() {
    cat <<'EOF'
=== Lightweight X11 graphical environment ===

Quick decision: GUI=yes = Xorg + lightweight Openbox. GUI=no = TTY
only, ZERO X11 packages and no /etc/X11 (fixed in v2.1.0).

If GUI=yes, minimal Xorg is installed (xserver-xorg-core, input and
video drivers, libgl1-mesa-dri, xauth, xinit) plus, as you choose:
  WM         openbox (Nightmare theme included in the package) or none.
  Compositor picom (transparency/shadows) or none.
  Bar        tint2 or none.
  Launcher   rofi (drun with Win+r) or none.
  Terminal   xterm, alacritty or both.
  Font       JetBrains Mono, DejaVu Sans Mono or Terminus.
  Colours    background/text/accent in RRGGBB for .Xresources, Openbox
             and Limine's own interface.

It is a VISUAL and functional "hacker" aesthetic: colours, monospace,
shortcuts. NO intrusion, scanning or exploiting tools are installed.
There is no heavy desktop (GNOME/KDE/XFCE), nor telemetry services.

If GUI=no (fixed in v2.1.0, before it installed X11 anyway):
  - The package list does NOT contain xserver-xorg-*, x11-xkb-utils,
    x11-xserver-utils, xauth, xinit, libgl1-mesa-dri, Openbox, picom,
    tint2, rofi, feh, xterm or alacritty, not even as a leftover:
    x11-xkb-utils drags in libx11-6 and other X11 libraries, so it
    lived ONLY inside the GUI=yes branch.
  - No /etc/X11, no .Xresources, no Openbox config is created; stage
    13 is skipped entirely and GREETER stays at console.
  - The CONSOLE keyboard is still managed by console-setup /
    keyboard-configuration, which is not X11.
  - Plymouth (boot framebuffer, not X11), ZRAM, network and audio
    remain, only if you choose them separately. It is the "TTY only"
    option, truly clean, Arch-style without a graphical environment.

Approximate cost of GUI=yes: 150-250 MB and ~40 more packages. On a
59 GB USB it is irrelevant; in the VM's RAM it does matter at install time.

Recommended: GUI=yes with Openbox + picom + tint2 + rofi + xterm.
For a console-only system, or to debug a boot, GUI=no.
Fuente: https://packages.debian.org/trixie/openbox
Fuente: https://packages.debian.org/trixie/tuigreet
Fuente: https://packages.debian.org/trixie/x11-xkb-utils
Fuente: https://packages.debian.org/trixie/x11-xserver-utils
EOF
}

# shellcheck disable=SC2016
help_zram() {
    cat <<'EOF'
=== ZRAM instead of fixed swap ===

systemd-zram-generator creates /dev/zram0 as COMPRESSED swap in RAM.
Configuration: zram-size = min(ram / 2, LIMIT) and swap-priority = 100,
so the kernel prefers it over any other swap.

Advantages on an encrypted USB:
  - No unencrypted swap is written to the pendrive.
  - Less flash wear.
  - No swap partition or resume/hibernation needed (RESUME=none).

Limits: 1024/2048/4096 MiB are zram DEVICE caps, not RAM reserved upfront.
The limit should not exceed the RAM of the smallest PC where you will
use the USB. If you choose 4096 and boot on a 2 GB machine, the
generator adjusts with ram/2, but better not to tempt it.

If ZRAM=no, the system is left WITHOUT swap. Valid if you have plenty
of RAM, but under memory pressure the OOM killer will act sooner.

Recommended: ZRAM=yes with 2048 MiB.
Fuente: https://manpages.debian.org/trixie/systemd-zram-generator/zram-generator.conf.5.en.html
EOF
}

# shellcheck disable=SC2016
help_pipewire() {
    cat <<'EOF'
=== Audio: PipeWire ===

minimal: pipewire, pipewire-pulse, pipewire-alsa, wireplumber.
         Covers output/input and compatibility with apps that speak
         PulseAudio or ALSA. RECOMMENDED.
bluetooth: the above + libspa-0.2-bluetooth, bluez and pulseaudio-utils.
         Adds Bluetooth support and ~30 MB. Only if you will use BT headsets.
none: no audio server. Saves ~15 MB and one service. Programs expecting
         PulseAudio will simply have no sound.

WirePlumber is the session manager; without it, PipeWire starts but
does not manage devices correctly.

Recommended: minimal. Add bluetooth later with apt if you need it.
Fuente: https://wiki.debian.org/PipeWire
Fuente: https://packages.debian.org/trixie/pipewire
EOF
}

# shellcheck disable=SC2016
help_network() {
    cat <<'EOF'
=== Network ===

NetworkManager: manages Ethernet and Wi-Fi, ships nmtui to configure
    from a TTY, and is the most comfortable on a USB that changes PCs.
    Adds network-manager, wpasupplicant and iw. RECOMMENDED for portable.
dhcpcd-base:   basic wired/wireless DHCP only, no applet or nmtui.
    Fewer services and packages. It already comes in the live session,
    but it is installed explicitly into the target.
none:          no manager; you will have to configure
    /etc/network/interfaces or ip by hand. Maximum minimalism, higher
    risk of being left without network after the first boot.

Important: during the INSTALLATION the network is used by the live
session, not the target. This choice affects the installed system. The
preflight checks the live network before starting.

Recommended: NetworkManager. If you want few services, dhcpcd-base.
Fuente: https://packages.debian.org/trixie/network-manager
Fuente: https://packages.debian.org/trixie/dhcpcd-base
EOF
}

# shellcheck disable=SC2016
help_security() {
    cat <<'EOF'
=== Firewall, AppArmor and optional services ===

nftables (YES by default): inet filter rules with drop policy on input
    and forward, loopback accepted, established/related, ICMP/ICMPv6 and
    DHCP/DHCPv6. The syntax is validated with `nft -c -f` INSIDE the
    chroot before enabling the service. Note: it does NOT open any
    incoming port; if you later install SSH and want to reach it from
    another PC, you will have to add a rule. That is intentional: first
    boot, then expose.

    Two details that avoid the "Could not resolve protocol name" error:
    - `netbase` (12 kB) is installed, which provides /etc/protocols. nft
      resolves names like `ipv6-icmp` by reading THAT file INSIDE the
      chroot; without it, debootstrap --variant=minbase does not bring
      it and `nft -c -f` aborts.
    - `meta l4proto icmp` / `meta l4proto ipv6-icmp` is used instead of
      `ip6 nexthdr`: in the inet family, meta l4proto skips the IPv6
      extension headers and does not depend on the Next Header being
      ICMPv6. The nftables wiki explicitly recommends it.
AppArmor (YES): Mandatory Access Control profiles. In Debian it has
    been active since Buster; the service is enabled. Minimal cost.
opendoas (NO): minimal alternative to sudo (the "doas" package is only
    transitional; the real one is opendoas). Installed in addition to
    sudo, with `permit persist :sudo`. It replaces nothing; convenience.
auditd (NO): audit daemon. Useful on servers, generates lots of logs
    and writes constantly: a bad idea on a pendrive.
openssh-server (NO): SSH server. If you enable it, remember nftables
    does NOT open port 22 by default. Enable it only if you know you
    want to administer the USB remotely.

Recommended: nftables YES, AppArmor YES, doas/auditd/ssh NO.
Fuente: https://wiki.nftables.org/wiki-nftables/index.php/Matching_packet_headers
Fuente: https://packages.debian.org/trixie/netbase
Fuente: https://packages.debian.org/trixie/all/netbase/filelist
Fuente: https://manpages.debian.org/trixie/nftables/nft.8.en.html
Fuente: https://wiki.debian.org/AppArmor/HowToUse
Fuente: https://manpages.debian.org/trixie/opendoas/doas.conf.5.en.html
EOF
}

# shellcheck disable=SC2016
help_bootmodes() {
    cat <<'EOF'
=== Boot modes and Secure Boot ===

UEFI x64 (YES): installs BOOTX64.EFI in /boot/EFI/BOOT/. It is the mode
    of almost all modern PCs and of OVMF in QEMU.
BIOS/legacy (YES): creates the BIOS Boot partition ef02 and runs
    `limine bios-install /dev/sda 1`. Allows booting on old machines or
    in QEMU with -machine pc. Costs 2 MiB.
UEFI IA32 (NO): BOOTIA32.EFI for the few tablets/Atom with 32-bit UEFI
    and 64-bit CPU. Enable it only if you know your machine needs it.
Secure Boot (must be NO): this installation is NOT signed for Secure
    Boot. If the firmware has it enabled, Limine will not start. The
    script REFUSES to continue if you answer that it is enabled: turn
    it off in the VM/BIOS setup before continuing.

Having UEFI + BIOS at once is NOT incompatible: they are two different
paths over the same GPT. It is exactly what makes the USB portable.

Recommended: UEFI YES, BIOS YES, IA32 NO, Secure Boot NO.
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/USAGE.md
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/FAQ.md
EOF
}

# shellcheck disable=SC2016
help_bios_install() {
    cat <<'EOF'
=== Limine BIOS: ef02 partition and residual signatures ===

Symptom that may appear in stage 9:

  Installing to GPT. Logical block size of 512 bytes.
  error: The partition selected to install the BIOS boot code to contains
         a recognised filesystem.
         Pass `--force` to override these checks.
  Install failed, undoing work...

Why it happens:
  `sgdisk --zap-all` erases the partition TABLE (MBR/GPT), but does NOT
  erase the DATA that was inside the previous partitions. When reusing
  the USB, the new partition 1 (type ef02, BIOS Boot, starts at LBA 2048
  = 1 MiB) lands right on top of the old boot sector: the strings
  "FAT32" / "FAT" or the ext2/3/4 magic 0xEF53 are still there.

  Limine 12.9.6's code (validate_or_force in limine.c) reads these
  offsets at the START of the chosen partition:
    +3     -> "NTFS"  or "FAT32" (5 bytes)
    +54    -> "FAT"   (3 bytes)
    +82    -> "FAT"   (3 bytes)
    +1080  -> 0xEF53  (ext2/3/4 superblock magic)
  If it finds any, it REFUSES to write stage 2 and suggests --force.
  It is a correct protection: it avoids destroying a real filesystem by
  mistake.

Solution applied by this script (WITHOUT --force):
  1. Zeros in the first 4096 bytes of the ONLY partition Limine BIOS
     inspects: /dev/sda1 (ef02). 4096 comfortably covers the four
     offsets (+3, +54, +82, +1080).
  2. Verification with `cmp` against /dev/zero: if they are not zero,
     the script ABORTS instead of continuing with a half-cleaned disk.

  `wipefs` is NOT run on /dev/sda2 or /dev/sda3. Stage 3 creates a new
  FAT32 with `mkfs.fat` and a new LUKS2 with `luksFormat`, which rewrite
  those headers. Also, `wipefs -a` makes 5-byte writes at offsets like
  +82; with QEMU `cache=none` over a host physical disk that can end in
  "critical target error" / "lost async page write". A single aligned
  4096-byte write avoids that pattern without losing Limine's protection.

  This is done in stage 2 and AGAIN in stage 9 right before
  bios-install, so it also works with --resume.

If "critical target error" or "lost async page write" appears in the
live session, it is NOT a Limine failure: it is the host rejecting the
write. Before continuing, check in the live session:

  lsblk -o NAME,RO,TRAN,HOTPLUG /dev/sda
  blockdev --getro /dev/sda /dev/sda2
  dmesg | tail -50

What --force does:
  According to `limine bios-install --help`, "Force installation even if
  the safety checks fail (DANGEROUS!)". In the code, besides skipping
  the warning, it OVERWRITES the signatures with zeros and can skip
  other partition table checks. Equivalent to our cleanup but without
  verifying and without the other guards. That is why it is NOT used
  by default.

LIMINE_BIOS_FORCE option:
  no (RECOMMENDED): clean and verify; bios-install without --force.
  yes             : clean, verify and ADD --force. Only if it still
                    fails (weird firmware, exotic GPT table) and you
                    know /dev/sda is your USB. It is logged.

The ef02 partition is NOT formatted: it is dedicated exclusively to
Limine's stage 2. Writing zeros there is safe and does not erase system
data, which lives in /boot (FAT32, partition 2) and in LUKS (partition 3).

Fuente: https://github.com/Limine-Bootloader/Limine/blob/v12.9.6/host/limine.c
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/USAGE.md
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/CONFIG.md
Fuente: https://www.qemu.org/docs/master/system/invocation.html
Fuente: https://manpages.debian.org/trixie/dosfstools/mkfs.fat.8.en.html
Fuente: https://manpages.debian.org/trixie/cryptsetup-bin/cryptsetup-luksFormat.8.en.html

Recommended: LIMINE_BIOS_FORCE=no.
EOF
}

# shellcheck disable=SC2016
help_dns() {
    cat <<'EOF'
=== DNS of the installed system ===

An /etc/resolv.conf with two nameservers is written. During the
installation the live session's resolv.conf is used; at the end it is
replaced by these values in the target.

1.1.1.1 / 8.8.8.8 are public and work on almost any network.
If your network uses a local resolver (router, Pi-hole, VPN), enter
its IP here. If you chose NetworkManager, it may also rewrite
resolv.conf when connecting; that is not an error.

It is now validated to be a literal IPv4 or IPv6. Use only literal IPs,
not hostnames: on the first boot there is no guarantee of resolving
names before the network is up.

Recommended: leave the defaults unless you have your own DNS.
EOF
}

# shellcheck disable=SC2016
help_extras() {
    cat <<'EOF'
=== Extra packages and cleanup ===

Extra packages: APT names separated by spaces, e.g.
  vim neofetch tmux git
They are validated with a regular expression: lowercase letters,
numbers and the plus, dot and hyphen signs. They are added to the
SIMULATION and to the installation. If you type a nonexistent name,
`apt-get -s install` will fail BEFORE installing anything, so you will
not break the disk. Leave empty to add nothing.

Trace cleanup (YES): at the end, the following are deleted from the target
  /debootstrap, bootstrap.log, debootstrap.log, /root/.bash_history,
  *.deb in apt/archives, APT lists and the contents of /tmp.
ONLY normal Debian configurations remain. The script, the log, the
state, tarballs, Zig, caches and GPG keys are never copied to the
target: they are in /tmp (RAM) and scratch/ is deleted on exit.

If you set cleanup=NO, you will keep the /debootstrap directory inside
the installed system. That only makes sense to debug the bootstrap.

Recommended: cleanup YES, extra packages empty on the first attempt.
EOF
}

# shellcheck disable=SC2016
help_cleanup() {
    cat <<'EOF'
=== Final confirmation before destroying /dev/sda ===

The next step runs `sgdisk --zap-all /dev/sda`, creates partitions,
mkfs.fat, cryptsetup luksFormat and mkfs inside LUKS. It is IRREVERSIBLE.

Before you type the confirmation the script will already have:
  - verified root, trixie, network, mirrors and tools;
  - shown model, serial, size, TRAN and HOTPLUG of /dev/sda;
  - checked that no partitions are mounted;
  - saved (if you chose keep) the first 16 MiB, the partition dump and
    the previous GPT table in RAM.

You must type EXACTLY:  ERASE /dev/sda

If in doubt, cancel with Ctrl+C. There is no turning back and, since
everything is in RAM, powering off the VM will also leave no copy of
the backups.

Recommended: re-read the `lsblk` printed by the preflight before confirming.
EOF
}

# shellcheck disable=SC2016
help_confirm() {
    help_cleanup
}

# ---------------------------- questions ----------------------------

ask() {
    local var="$1" prompt="$2" default="$3" ans="" allow_empty=0
    [[ -n "$default" ]] || allow_empty=1
    if (( ACCEPT_DEFAULTS )); then
        printf -v "$var" '%s' "$default"
        log "$prompt = $default (default)"
        return 0
    fi
    while true; do
        show_help
        IFS= read -r -p "$(ui_prompt "$prompt [$default] (? full help): ")" ans || die "Input cancelled"
        if [[ "$ans" == "?" ]]; then
            HELP_FULL=1
            HELP_SHOWN=""
            continue
        fi
        ans="${ans:-$default}"
        if (( ! allow_empty )) && [[ -z "$ans" ]]; then
            printf 'Not empty.\n'
            continue
        fi
        printf -v "$var" '%s' "$ans"
        HELP_FN=""
        HELP_SHOWN=""
        return 0
    done
}

ask_yes() {
    local var="$1" prompt="$2" default="$3" ans=""
    if (( ACCEPT_DEFAULTS )); then
        printf -v "$var" '%s' "$default"
        log "$prompt = $default (default)"
        return 0
    fi
    while true; do
        show_help
        IFS= read -r -p "$(ui_prompt "$prompt [y/n, default $default, ? help]: ")" ans || die "Input cancelled"
        if [[ "$ans" == "?" ]]; then
            HELP_FULL=1
            HELP_SHOWN=""
            continue
        fi
        ans="${ans:-$default}"
        case "$ans" in
            y|Y|yes|YES) printf -v "$var" '%s' "yes" ;;
            n|N|no|NO) printf -v "$var" '%s' "no" ;;
            *) printf 'Answer y or n.\n'; continue ;;
        esac
        HELP_FN=""
        HELP_SHOWN=""
        return 0
    done
}

menu() {
    local var="$1" prompt="$2" default_num="$3" ans="" i
    shift 3
    local opts=("$@")
    if (( ACCEPT_DEFAULTS )); then
        printf -v "$var" '%s' "${opts[default_num-1]}"
        log "$prompt = ${opts[default_num-1]} (por defecto)"
        return 0
    fi
    while true; do
        show_help
        printf '  %s%s%s\n' "$C_CYAN" "$prompt" "$C_RESET"
        for i in "${!opts[@]}"; do
            if (( i + 1 == default_num )); then
                printf '  %s%d) %s%s  (default)\n' "$C_GREEN" "$((i+1))" "${opts[i]}" "$C_RESET"
            else
                printf '  %d) %s\n' "$((i+1))" "${opts[i]}"
            fi
        done
        IFS= read -r -p "$(ui_prompt "Choose 1-${#opts[@]} [${default_num}], ? full help: ")" ans || die "Input cancelled"
        if [[ "$ans" == "?" ]]; then
            HELP_FULL=1
            HELP_SHOWN=""
            continue
        fi
        ans="${ans:-$default_num}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
            printf -v "$var" '%s' "${opts[ans-1]}"
            HELP_FN=""
            HELP_SHOWN=""
            return 0
        fi
        printf 'Invalid option.\n'
    done
}

check_secret() {
    local s="$1" min="${PASS_MIN_LEN:-1}" len
    [[ -n "$s" ]] || die "The password must not be empty"
    # Printable ASCII range 0x21..0x7E. "tr -d" is used instead of
    # "grep -q" because tr CONSUMES the whole input: it does not close the
    # pipe early and does not cause curl(23)/SIGPIPE with pipefail.
    # BYTES are COUNTED with wc -c instead of capturing the string: $(...)
    # strips trailing newlines and would let a password with a \n slip in.
    # If any byte remains after deleting !-~, it is a space, tab, newline,
    # control, accent or non-ASCII UTF-8.
    # ':' is allowed because chpasswd -c YESCRYPT takes as the password
    # everything after the first ':' (verified with the resulting hash).
    if (( "$(printf '%s' "$s" | LC_ALL=C tr -d '!-~' | wc -c)" > 0 )); then
        die "Use only printable ASCII characters: no spaces, no accents and no controls"
    fi
    len=${#s}
    if (( len < min )); then
        die "The password has $len characters, but the configured minimum is $min (change it in the minimum length question)"
    fi
    if (( len < 12 )); then
        printf '%sWARNING: %d-character password; it is short and vulnerable to brute force. Not blocked, just a warning.%s\n' "${C_YELLOW:-}" "$len" "${C_RESET:-}" >&2
    fi
}

ask_secret() {
    local var="$1" prompt="$2" a="" b=""
    if (( ACCEPT_DEFAULTS && DRY_RUN )); then
        printf -v "$var" '%s' 'Change-This-Phrase-2026!'
        log "$prompt = (simulation default value, hidden)"
        return 0
    fi
    while true; do
        show_help
        IFS= read -r -s -p "$(ui_prompt "$prompt (empty Enter = full help): ")" a || die "Input cancelled"
        printf '\n'
        # '?' can be a valid password; we use the empty input (which
        # would not be a valid password anyway) as the help trigger.
        if [[ -z "$a" ]]; then
            HELP_FULL=1
            HELP_SHOWN=""
            printf 'Showing the full explanation.\n'
            continue
        fi
        IFS= read -r -s -p "$(ui_prompt "Repeat $prompt: ")" b || die "Input cancelled"
        printf '\n'
        check_secret "$a"
        [[ "$a" == "$b" ]] || { printf 'Does not match.\n'; continue; }
        printf -v "$var" '%s' "$a"
        HELP_FN=""
        HELP_SHOWN=""
        return 0
    done
}

ask_ip() {
    local var="$1" prompt="$2" default="$3" v=""
    ask v "$prompt (literal IPv4 or IPv6)" "$default"
    is_ip "$v" || die "Invalid DNS: $v (use a literal IP)"
    printf -v "$var" '%s' "$v"
}

ask_hex() {
    local var="$1" prompt="$2" default="$3" v=""
    ask v "$prompt (RRGGBB or #RRGGBB)" "$default"
    v="${v#\#}"
    [[ "$v" =~ ^[0-9A-Fa-f]{6}$ ]] || die "Invalid hex colour: $v"
    printf -v "$var" '%s' "$v"
}

ask_label() {
    local var="$1" prompt="$2" default="$3" max="$4" v=""
    ask v "$prompt" "$default"
    [[ ${#v} -le "$max" ]] || die "Label too long (max $max)"
    [[ "$v" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Label with characters not allowed"
    printf -v "$var" '%s' "$v"
}

ask_num() {
    local var="$1" prompt="$2" default="$3" min="$4" max="$5" v=""
    ask v "$prompt" "$default"
    [[ "$v" =~ ^[0-9]+$ ]] || die "Must be a number"
    (( v >= min && v <= max )) || die "Out of range $min-$max"
    printf -v "$var" '%s' "$v"
}

validate_regex() {
    local var="$1" label="$2" re="$3"
    [[ "${!var}" =~ $re ]] || die "invalid $label: ${!var}"
}

confirm_wipe() {
    local ans=""
    if (( DRY_RUN || SIMULATE )); then
        log "Wipe confirmation skipped in simulation"
        return 0
    fi
    HELP_FN=help_confirm
    HELP_SHOWN=""
    show_help
    printf '\n%s=== DANGER ===%s\n%s will be completely erased.\n' "$C_RED" "$C_RESET" "$U"
    lsblk -d -o NAME,MODEL,SERIAL,SIZE,TRAN,HOTPLUG "$U"
    IFS= read -r -p "Type exactly ERASE $U to continue: " ans || die "Cancelled"
    [[ "$ans" == "ERASE $U" ]] || die "Wipe not confirmed"
    HELP_FN=""
    HELP_SHOWN=""
}

# ---------------------------- defaults ----------------------------

set_defaults() {
    U=/dev/sda
    BIOSP=/dev/sda1
    B=/dev/sda2
    R=/dev/sda3
    M=/mnt/target
    SUITE=trixie
    ARCH=amd64
    HOSTNAME_DEB=mini
    USERNAME=user
    USER_SHELL=/bin/bash
    PASS_MIN_LEN=1
    USER_PASS=""
    ROOT_PASS=""
    LUKS_PASS=""
    LOCALE=en_US.UTF-8
    TZ_AREA=America/Argentina/Buenos_Aires
    KEYMAP=latam
    MIRROR=https://mirror.sitsa.com.ar/debian
    SECURITY=https://security.debian.org/debian-security
    COMPONENTS=main,contrib,non-free-firmware
    ESP_SIZE=1G
    BIOS_SIZE=2M
    BOOT_LABEL=BOOTESP
    ROOT_LABEL=ROOTFS
    LUKS_LABEL=CRYPTROOT
    PBKDF=argon2id
    PBKDF_MEM=65536
    ROOT_FS=ext4
    KERNEL_HARDENING=conservative
    PLYMOUTH_THEME=spinfinity
    PLYMOUTH_FALLBACK=yes
    LIMINE_EDITOR=yes
    VERIFY_GPG=yes
    GREETER=greetd
    GUI=yes
    WM=openbox
    COMPOSITOR=picom
    BAR=tint2
    LAUNCHER=rofi
    TERMINAL=xterm
    FONT="JetBrains Mono"
    FONT_PKG=fonts-jetbrains-mono
    BG=0b0f14
    FG=00ff9c
    ACCENT=55ffc8
    ZRAM=yes
    ZRAM_SIZE=2048
    PIPEWIRE=minimal
    NETWORK=NetworkManager
    FIREWALL=yes
    APPARMOR=yes
    DOAS=no
    AUDITD=no
    SSH=no
    FIRMWARE=full
    MICROCODE=both
    UEFI=yes
    BIOS_BOOT=yes
    UEFI_IA32=no
    SECURE_BOOT=no
    DNS1=1.1.1.1
    DNS2=8.8.8.8
    DATA_POLICY=keep
    INTRO_OK=no
    ALLOW_TARGET_MOUNTS=0
    HOTPLUG_POLICY=allow0
    LIMINE_BIOS_FORCE=no
    SIZE_MIN_GB=50
    SIZE_MAX_GB=70
    CURL_RETRIES=3
    NETWORK_TIMEOUT=15
    MAKE_HOST_BACKUP=yes
    CLEAN_TRACES=yes
    EXTRA_PACKAGES_STR=""
    EXTRA_PACKAGES=()
    PKGS=()
    K=""
    LUKS_UUID=""
    ROOT_UUID=""
    BOOT_UUID=""
    LIMINE_VER=12.9.6
    LIMINE_KEY=05D29860D0A0668AAEFB9D691F3C021BECA23821
    LIMINE_SHA=939f670e0831cc940453fd3a0ddfb2b324c0b4e3c5d0e741c190aa0d13df0103
    LY_VER=1.5.0
    ZIG_VER=0.17.0
    ZIG_SHA=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
    LY_SHA=115a7f7fb281803ca7f9e0ddbdf76834a53f7fa6bc702d766d03772ce1976dc3
}

CONFIG_KEYS=(
    U BIOSP B R M SUITE ARCH HOSTNAME_DEB USERNAME USER_SHELL PASS_MIN_LEN LOCALE TZ_AREA KEYMAP
    MIRROR SECURITY COMPONENTS ESP_SIZE BIOS_SIZE BOOT_LABEL ROOT_LABEL LUKS_LABEL
    PBKDF PBKDF_MEM ROOT_FS KERNEL_HARDENING PLYMOUTH_THEME PLYMOUTH_FALLBACK
    LIMINE_EDITOR VERIFY_GPG GREETER GUI WM COMPOSITOR BAR LAUNCHER TERMINAL
    FONT FONT_PKG BG FG ACCENT ZRAM ZRAM_SIZE PIPEWIRE NETWORK FIREWALL APPARMOR
    DOAS AUDITD SSH FIRMWARE MICROCODE UEFI BIOS_BOOT UEFI_IA32 SECURE_BOOT
    DNS1 DNS2 DATA_POLICY HOTPLUG_POLICY LIMINE_BIOS_FORCE SIZE_MIN_GB SIZE_MAX_GB
    CURL_RETRIES NETWORK_TIMEOUT MAKE_HOST_BACKUP CLEAN_TRACES
    EXTRA_PACKAGES_STR K LUKS_UUID ROOT_UUID BOOT_UUID
    LIMINE_VER LIMINE_KEY LIMINE_SHA LY_VER ZIG_VER ZIG_SHA LY_SHA
)

collect_preferences() {
    log "=== Collecting preferences (type ? to re-read the explanation) ==="
    HELP_FN=help_intro;      HELP_SHOWN=""
    ask_yes INTRO_OK "Do you understand that /dev/sda will be erased and that everything temporary lives in RAM?" "yes"
    [[ "$INTRO_OK" == yes ]] || die "Cancelled: the understanding of the wipe was not confirmed"
    HELP_FN=help_target;     HELP_SHOWN=""
    ask U "Target device (must be /dev/sda)" "$U"
    [[ "$U" == /dev/sda ]] || die "This installer is fixed to /dev/sda; bailing out for safety"
    B="${U}2"
    R="${U}3"
    ask M "Temporary mount point of the system" "$M"
    [[ "$M" = /* && "$M" != "/" ]] || die "Invalid mount point: $M"

    HELP_FN=help_disk_checks; HELP_SHOWN=""
    menu HOTPLUG_POLICY "HOTPLUG policy for /dev/sda" 1 "allow0" "require1" "skip"
    ask_num SIZE_MIN_GB "Minimum disk size (decimal GB)" "$SIZE_MIN_GB" 1 2000
    ask_num SIZE_MAX_GB "Maximum disk size (decimal GB)" "$SIZE_MAX_GB" 1 2000
    (( SIZE_MIN_GB <= SIZE_MAX_GB )) || die "The minimum cannot exceed the maximum"
    ask_num CURL_RETRIES "curl retries" "$CURL_RETRIES" 0 10
    ask_num NETWORK_TIMEOUT "curl connection timeout (seconds)" "$NETWORK_TIMEOUT" 1 120

    HELP_FN=help_workdir;    HELP_SHOWN=""
    menu DATA_POLICY "What should I do with state and backups in RAM?" 1 "keep" "delete" "no-backups"
    case "$DATA_POLICY" in
        keep) MAKE_HOST_BACKUP=yes ;;
        delete)    MAKE_HOST_BACKUP=yes ;;
        "no-backups") MAKE_HOST_BACKUP=no ;;
    esac
    if (( ! LOG_GIVEN )); then
        ask LOG_FILE "Log path" "$ARTIFACT_DIR/install.log"
    fi
    derive_paths

    HELP_FN=help_identity;   HELP_SHOWN=""
    ask HOSTNAME_DEB "Hostname" "$HOSTNAME_DEB"
    validate_regex HOSTNAME_DEB "hostname" '^[a-z][a-z0-9-]{0,62}$'
    ask USERNAME "User name" "$USERNAME"
    validate_regex USERNAME "user name" '^[a-z_][a-z0-9_-]{0,31}$'
    menu USER_SHELL "User shell" 1 "/bin/bash" "/bin/zsh" "/bin/dash"
    ask_num PASS_MIN_LEN "Minimum password length (1 = no minimum)" "$PASS_MIN_LEN" 1 4096
    ask_secret USER_PASS "User password"
    ask_secret ROOT_PASS "root password"
    ask_secret LUKS_PASS "LUKS passphrase (ASCII, no accents)"

    HELP_FN=help_locale;     HELP_SHOWN=""
    menu LOCALE "Locale" 1 "en_US.UTF-8" "C.UTF-8" "es_AR.UTF-8"
    menu TZ_AREA "Time zone" 1 "America/Argentina/Buenos_Aires" "UTC" "Etc/UTC"
    menu KEYMAP "Keyboard" 1 "latam" "es" "us"

    HELP_FN=help_mirror;     HELP_SHOWN=""
    menu MIRROR "Debian mirror" 1 \
        "https://mirror.sitsa.com.ar/debian" \
        "https://debian.c3sl.ufpr.br/debian" \
        "https://deb.debian.org/debian"
    case "$MIRROR" in
        *c3sl*) SECURITY="https://debian.c3sl.ufpr.br/debian-security" ;;
        *) SECURITY="https://security.debian.org/debian-security" ;;
    esac
    ask SECURITY "Security mirror" "$SECURITY"
    [[ "$SECURITY" == https://* ]] || die "The security mirror must use HTTPS"

    HELP_FN=help_components; HELP_SHOWN=""
    ask COMPONENTS "APT components (comma-separated)" "$COMPONENTS"
    validate_regex COMPONENTS "components" '^[a-z0-9,+-]+$'

    HELP_FN=help_firmware;   HELP_SHOWN=""
    menu FIRMWARE "Firmware profile" 1 "full" "minimal" "none"
    case "$FIRMWARE" in
        full|minimal) COMPONENTS="main,contrib,non-free-firmware" ;;
        none) COMPONENTS="main" ;;
    esac
    HELP_FN=help_microcode;  HELP_SHOWN=""
    menu MICROCODE "Microcode" 1 "both" "intel" "amd" "none"

    HELP_FN=help_partitions; HELP_SHOWN=""
    menu ESP_SIZE "ESP size" 2 "512M" "1G" "2G"
    menu BIOS_SIZE "BIOS Boot size" 2 "1M" "2M" "8M"
    ask_label BOOT_LABEL "FAT32 label" "$BOOT_LABEL" 11
    ask_label ROOT_LABEL "Root label" "$ROOT_LABEL" 16
    ask_label LUKS_LABEL "LUKS label" "$LUKS_LABEL" 32

    HELP_FN=help_luks;       HELP_SHOWN=""
    menu PBKDF "LUKS KDF" 1 "argon2id" "pbkdf2"
    if [[ "$PBKDF" == argon2id ]]; then
        menu PBKDF_MEM "Argon2id memory (KiB)" 1 "65536" "131072" "262144" "524288"
    fi
    HELP_FN=help_rootfs;     HELP_SHOWN=""
    menu ROOT_FS "Root filesystem" 1 "ext4" "btrfs"

    HELP_FN=help_hardening;  HELP_SHOWN=""
    menu KERNEL_HARDENING "Kernel hardening" 1 "conservative" "aggressive" "none"
    HELP_FN=help_plymouth;   HELP_SHOWN=""
    menu PLYMOUTH_THEME "Plymouth theme" 1 "spinfinity" "spinner" "text" "details" "none"
    ask_yes PLYMOUTH_FALLBACK "Include a boot entry without Plymouth" "yes"

    HELP_FN=help_limine;     HELP_SHOWN=""
    ask_yes LIMINE_EDITOR "Allow the Limine editor" "yes"
    ask_yes VERIFY_GPG "Verify the Limine GPG signature" "yes"

    # First it asks whether there is X11 and THEN the greeter: the
    # other way around, choosing greetd/ly and then GUI=no was a dead end.
    HELP_FN=help_gui;        HELP_SHOWN=""
    # The default is the CURRENT value ($GUI), not a fixed "yes": that
    # way a --config with GUI=no followed by --yes does not re-enable X11.
    ask_yes GUI "Install the X11 graphical environment" "$GUI"
    if [[ "$GUI" == no ]]; then
        GREETER=console
        WM=none
        COMPOSITOR=none
        BAR=none
        LAUNCHER=none
        TERMINAL=none
        log "GUI=no: greeter=console and no graphical component at all"
    else
        HELP_FN=help_greeter;    HELP_SHOWN=""
        local_greeter_default=1
        case "$GREETER" in
            ly) local_greeter_default=2 ;;
            console) local_greeter_default=3 ;;
        esac
        menu GREETER "Session login manager" "$local_greeter_default" "greetd" "ly" "console"
    fi
    if [[ "$GUI" == yes ]]; then
        menu WM "WM" 1 "openbox" "none"
        menu COMPOSITOR "Compositor" 1 "picom" "none"
        menu BAR "Bar" 1 "tint2" "none"
        menu LAUNCHER "Launcher" 1 "rofi" "none"
        menu TERMINAL "Terminal" 1 "xterm" "alacritty" "both"
        menu FONT_PKG "Monospace font" 1 "fonts-jetbrains-mono" "fonts-dejavu-core" "xfonts-terminus"
        case "$FONT_PKG" in
            fonts-jetbrains-mono) FONT="JetBrains Mono" ;;
            fonts-dejavu-core) FONT="DejaVu Sans Mono" ;;
            xfonts-terminus) FONT="Terminus" ;;
        esac
        ask_hex BG "Background colour" "$BG"
        ask_hex FG "Text colour" "$FG"
        ask_hex ACCENT "Accent colour" "$ACCENT"
    fi

    HELP_FN=help_zram;       HELP_SHOWN=""
    ask_yes ZRAM "Use ZRAM" "yes"
    if [[ "$ZRAM" == yes ]]; then
        menu ZRAM_SIZE "Maximum ZRAM size (MiB)" 1 "2048" "4096" "1024"
    fi
    HELP_FN=help_pipewire;   HELP_SHOWN=""
    menu PIPEWIRE "PipeWire" 1 "minimal" "bluetooth" "none"
    HELP_FN=help_network;    HELP_SHOWN=""
    menu NETWORK "Network" 1 "NetworkManager" "dhcpcd" "none"

    HELP_FN=help_security;   HELP_SHOWN=""
    ask_yes FIREWALL "Enable nftables" "yes"
    ask_yes APPARMOR "Install AppArmor" "yes"
    ask_yes DOAS "Install doas in addition to sudo" "no"
    ask_yes AUDITD "Install auditd" "no"
    ask_yes SSH "Install openssh-server" "no"

    HELP_FN=help_bootmodes;  HELP_SHOWN=""
    menu UEFI "UEFI x64 boot" 1 "yes" "no"
    menu BIOS_BOOT "BIOS/Legacy boot" 1 "yes" "no"
    menu UEFI_IA32 "Copy BOOTIA32.EFI" 1 "no" "yes"
    menu SECURE_BOOT "Secure Boot enabled in the firmware" 1 "no" "yes"
    [[ "$SECURE_BOOT" == "no" ]] || die "Secure Boot must be disabled for this portable USB"

    HELP_FN=help_bios_install; HELP_SHOWN=""
    menu LIMINE_BIOS_FORCE "Add --force to limine bios-install?" 1 "no" "yes"

    HELP_FN=help_dns;        HELP_SHOWN=""
    ask_ip DNS1 "Primary DNS" "$DNS1"
    ask_ip DNS2 "Secondary DNS" "$DNS2"

    HELP_FN=help_extras;     HELP_SHOWN=""
    ask EXTRA_PACKAGES_STR "Extra packages separated by spaces (empty = none)" "$EXTRA_PACKAGES_STR"
    parse_extra_packages
    ask_yes CLEAN_TRACES "Clean installer traces in the installed system" "yes"

    confirm_wipe
    HELP_FN=""
    HELP_SHOWN=""
}

# ---------------------------- validation and environment ----------------------------

self_check() {
    log "=== Static self-check ==="
    # shellcheck disable=SC2016
    # The literals with $MIRROR/$SUITE are searched verbatim inside this file.
    local checks=(
        '^set -Eeuo pipefail$'
        'trap cleanup EXIT'
        "trap 'fail"
        'confirm_wipe'
        'download_file "$MIRROR/dists/$SUITE/Release"'
        'cryptsetup luksHeaderBackup'
        'sha256sum -c -'
        'gpg --verify'
        'update-initramfs -u -k all'
        'sfdisk --dump'
        'install_host_deps'
        'check_tmp_space'
        'save_config'
        'load_config_from'
        'ly --validate-config'
        'help_all'
        '--explain'
        '--dry-run'
        '--resume'
        '--refresh-limine'
        '--config'
        '--log'
        'grep -qF -- "$c" "$0"'
        'validate_preferences'
        'PASS_MIN_LEN'
        'chpasswd -c YESCRYPT'
        '--force-password'
        "tr -d '!-~'"
        'run_in_dir'
        'ARTIFACT_DIR'
        'SCRATCH_DIR'
        'STATE_DIR'
        'head_url'
        'download_file'
        'check_release_codename'
        'check_disk_guards'
        'HOTPLUG_POLICY'
        'opendoas'
        'udevadm info --query=property'
        'mounts="$(lsblk -rno MOUNTPOINTS "$U")"'
        '|| true'
        '--retry "$CURL_RETRIES"'
        'EFI/BOOT/limine.conf'
        'clean_partition_start'
        'LIMINE_BIOS_FORCE'
        'dd if=/dev/zero of="$p" bs=4096 count=1 conv=notrunc status=none'
        'cmp -n 4096 -s - /dev/zero'
        'components_deb822="${COMPONENTS//,/ }"'
        'Components: $components_deb822'
        'rm -f "$M/etc/apt/sources.list"'
        'e2fsprogs dosfstools zstd netbase'
        'meta l4proto icmp accept'
        'meta l4proto ipv6-icmp accept'
        'BIOSP=/dev/sda1'
        'install_limine_auto_hook'
        'zz-limine-update'
        '/etc/kernel/postinst.d/zz-limine-update'
        '/etc/kernel/postrm.d/zz-limine-update'
        '/etc/initramfs/post-update.d/zz-limine-update'
        'GUI=no confirmed: no Xorg'
        'conv=fsync status=none'
        'The host is rejecting writes inside'
        'GUI=no: /etc/X11 is not created in the installed system'
        'xserver-xorg-core xserver-xorg-input-all xserver-xorg-video-all xauth xinit x11-xkb-utils x11-xserver-utils libgl1-mesa-dri mesa-utils'
        'ui_banner'
        'ui_progress'
        'HELP_FULL=1'
    )
    local c
    for c in "${checks[@]}"; do
        grep -qF -- "$c" "$0" || die "Missing design check: $c"
    done
    local banned1="REEM""PLAZAR" banned2="/mnt/""backup" banned3="linux""-hardened"
    local banned4="usb""-host" banned5="ev""al" banned6="deb""usb"
    local banned7="media/""respaldo" banned8="WIN""DOWS" banned9="back""up.img"
    local banned10="Get""-Disk" banned11="fat:""ro:" banned12="%""U%"
    local banned13="| grep"" -q" banned14="5800""000000" banned15="no parece ""extraíble"
    local banned16="mount ""base64" banned17="feh ""xsetroot" banned18="PKGS+=(do""as)"
    local banned19="curl -fs""I "
    local banned20="wipe""fs -a \"" banned21="for part in \"\$BIOSP\" \"\$B\" \"\$R\""
    local banned22="Compo""nents: \$COMPONENTS"
    local banned23="ip6 nexthdr ipv6""-icmp"
    local banned24="        x11""-xkb-utils x11-xserver-utils"
    local banned25="curl wget gnupg xz-utils zstd less nano htop pciutils usbutils x11""-"
    grep -qF -- "$banned1" "$0" && die "Forbidden markers remain"
    grep -qF -- "$banned2" "$0" && die "An old backup path remains"
    grep -qF -- "$banned3" "$0" && die "Nonexistent kernel in Debian detected"
    grep -qF -- "$banned4" "$0" && die "Forbidden host device"
    grep -qE -- "(^|[[:space:]])$banned5([[:space:]]|$)" "$0" && die "Forbidden dynamic construction"
    grep -qiF -- "$banned6" "$0" && die "The old project name remains"
    grep -qF -- "$banned7" "$0" && die "An old backup mount point remains"
    grep -qF -- "$banned8" "$0" && die "A reference to the host remains"
    grep -qF -- "$banned9" "$0" && die "An old auxiliary image remains"
    grep -qF -- "$banned10" "$0" && die "A host disk identification remains"
    grep -qF -- "$banned11" "$0" && die "An old shared folder remains"
    grep -qF -- "$banned12" "$0" && die "A host variable remains"
    grep -qF -- "$banned13" "$0" && die "A pipe into a silent grep is back (false negative due to EPIPE)"
    grep -qF -- "$banned14" "$0" && die "The rigid 58-61 GB size range is back"
    grep -qF -- "$banned15" "$0" && die "The rigid HOTPLUG=1 guard is back"
    grep -qF -- "$banned16" "$0" && die "base64 is not an APT package"
    grep -qF -- "$banned17" "$0" && die "xsetroot is not an APT package"
    grep -qF -- "$banned18" "$0" && die "doas is transitional; use opendoas"
    grep -qF -- "$banned19" "$0" && die "A HEAD request without following redirects is back"
    grep -qF -- "$banned20" "$0" && die "wipefs on partitions is back (sub-sector I/O)"
    grep -qF -- "$banned21" "$0" && die "The ESP/LUKS cleanup in stage 2 is back"
    grep -qF -- "$banned22" "$0" && die "Components with commas in deb822 is back"
    grep -qF -- "$banned23" "$0" && die "ip6 nexthdr ipv6""-icmp without netbase is back"
    grep -qF -- "$banned24" "$0" && die "X11 packages are back in the base list (GUI=no would install X11)"
    grep -qF -- "$banned25" "$0" && die "X11 glued to the base package list is back"
    grep -q -- 'run sgdisk --zap-all' "$0" || die "Missing sgdisk traceability"
    grep -q -- 'run cryptsetup luksFormat' "$0" || die "Missing luksFormat traceability"
    grep -q -- 'run mkfs.fat' "$0" || die "Missing mkfs.fat traceability"
    grep -q -- 'CLEAN_TRACES' "$0" || die "Missing trace cleanup"
    # shellcheck disable=SC2016
    # The literal with $BIOSP is searched verbatim inside this file.
    grep -qF -- 'clean_partition_start "$BIOSP"' "$0" || die "Missing the BIOS Boot cleanup before bios-install"
    grep -qF -- 'LIMINE_BIOS_FORCE=yes; adding --force' "$0" || die "Missing the conditional --force branch"
    log "Static self-check OK"
    return 0
}

install_host_deps() {
    log "=== Installing tools in the live session (not in the target system) ==="
    local deps=(
        debootstrap debian-archive-keyring gdisk dosfstools cryptsetup-bin parted
        gnupg curl wget ca-certificates git build-essential pkg-config
        xz-utils zstd coreutils diffutils util-linux mount
    )
    [[ "$ROOT_FS" == btrfs ]] && deps+=(btrfs-progs)
    if [[ "$GREETER" == ly ]]; then
        deps+=(libpam0g-dev libxcb-xkb-dev libxcb1-dev libaudit-dev)
    fi
    if (( DRY_RUN || SIMULATE )); then
        run env DEBIAN_FRONTEND=noninteractive apt-get update
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${deps[@]}"
        return 0
    fi
    require_root
    run env DEBIAN_FRONTEND=noninteractive apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${deps[@]}"
}

check_tmp_space() {
    log "=== Free space in /tmp (tmpfs in RAM) ==="
    if (( DRY_RUN || SIMULATE )); then
        log "RAM check skipped in simulation"
        return 0
    fi
    local avail
    avail="$(df -B1 --output=avail /tmp | tail -n 1 | tr -d ' ')"
    log "Available in /tmp: $avail bytes"
    if [[ "$GREETER" == ly ]] && (( avail < 1200000000 )); then
        printf '\nWARNING: you chose ly, which compiles with Zig and needs ~1 GB free.\n'
        printf 'There is only ~%s MB. It may fail with NoSpaceLeft.\n' "$((avail/1000000))"
        printf 'Recommendation: switch to greetd (Debian package, no toolchain).\n\n'
        local ans
        IFS= read -r -p "Switch to greetd now? [y/n, default y]: " ans || true
        ans="${ans:-y}"
        case "$ans" in
            y|Y|yes|YES) GREETER=greetd; log "Switched to greetd due to low RAM" ;;
            *) log "Keeping ly at the user's own risk" ;;
        esac
    fi
}

# ---------------------------- network and disk guards ----------------------------

head_url() {
    local url="$1" label="$2"
    log "+ check $label: $url"
    if (( DRY_RUN || SIMULATE )); then
        return 0
    fi
    curl -fsSIL --retry "$CURL_RETRIES" --retry-delay 2 \
        --connect-timeout "$NETWORK_TIMEOUT" --max-time "$((NETWORK_TIMEOUT * 8))" \
        -o /dev/null "$url" || die "$label not reachable: $url"
}

download_file() {
    local url="$1" dest="$2" label="$3"
    log "+ download $label: $url -> $dest"
    if (( DRY_RUN || SIMULATE )); then
        return 0
    fi
    curl -fsSL --retry "$CURL_RETRIES" --retry-delay 2 \
        --connect-timeout "$NETWORK_TIMEOUT" --max-time "$((NETWORK_TIMEOUT * 30))" \
        -o "$dest" "$url" || die "Could not download $label: $url"
    [[ -s "$dest" ]] || die "downloaded $label is empty: $url"
}

# NEVER chain curl into a silent grep: that grep closes the pipe as soon
# as it finds the pattern, curl receives EPIPE (error 23) and pipefail
# turns that into a false negative. Download to a file and search inside
# the already-closed file.
check_release_codename() {
    local file="$1" expected="$2" label="$3"
    if (( DRY_RUN || SIMULATE )); then
        log "+ (simulation) check $label contains 'Codename: $expected'"
        return 0
    fi
    grep -qF -- "Codename: $expected" "$file" || die "$label does not contain 'Codename: $expected'"
}

# PURE guards: they receive already-read values, so they can be tested without a disk.
check_disk_guards() {
    local hotplug="$1" tran="$2" size="$3" min max
    log "Disk guards: HOTPLUG=$hotplug TRAN=$tran SIZE=$size bytes"
    case "$HOTPLUG_POLICY" in
        allow0)
            [[ "$hotplug" == "0" || "$hotplug" == "1" ]] || die "HOTPLUG=$hotplug is neither 0 nor 1; check $U"
            if [[ "$hotplug" == "0" ]]; then
                log "WARNING: HOTPLUG=0 (normal with QEMU usb-storage); accepted by HOTPLUG_POLICY=allow0"
            fi
            ;;
        require1)
            [[ "$hotplug" == "1" ]] || die "HOTPLUG=$hotplug; 1 was required. Use HOTPLUG_POLICY=allow0 if you are in QEMU"
            ;;
        skip)
            log "WARNING: HOTPLUG check skipped by user choice"
            ;;
        *)
            die "Invalid HOTPLUG_POLICY: $HOTPLUG_POLICY"
            ;;
    esac
    [[ "$tran" == "usb" ]] || die "TRAN=$tran is not 'usb'; $U does not look like the VM USB"
    min=$(( SIZE_MIN_GB * 1000000000 ))
    max=$(( SIZE_MAX_GB * 1000000000 ))
    if (( size < min || size > max )); then
        die "Size $size bytes outside the range ${SIZE_MIN_GB}-${SIZE_MAX_GB} decimal GB; adjust SIZE_MIN_GB/SIZE_MAX_GB"
    fi
    log "Disk guards OK"
}

preflight() {
    log "=== Preflight ==="
    if (( SIMULATE || DRY_RUN )); then
        log "Device preflight skipped in simulation"
        install_host_deps
        check_tmp_space
        return 0
    fi
    require_root
    grep -q -- '^VERSION_CODENAME=trixie$' /etc/os-release || die "The live session is not Debian 13 trixie"

    download_file "$MIRROR/dists/$SUITE/Release" "$SCRATCH_DIR_REAL/debian-Release" "Release de $SUITE"
    check_release_codename "$SCRATCH_DIR_REAL/debian-Release" trixie "Release de $SUITE"
    download_file "$SECURITY/dists/trixie-security/Release" "$SCRATCH_DIR_REAL/security-Release" "Release de trixie-security"
    check_release_codename "$SCRATCH_DIR_REAL/security-Release" trixie-security "Release de trixie-security"
    head_url "https://github.com/Limine-Bootloader/Limine/releases/download/v${LIMINE_VER}/limine-binary.tar.xz" "Release de Limine"
    if [[ "$GREETER" == ly ]]; then
        head_url "https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz" "Zig"
        head_url "https://codeberg.org/fairyglade/ly/archive/v${LY_VER}.tar.gz" "Ly"
    fi
    install_host_deps
    check_tmp_space

    local c
    for c in bash lsblk blkid udevadm sgdisk partprobe dd cmp mkfs.fat cryptsetup mkfs.ext4 debootstrap chroot curl wget sha256sum base64 tar make gpg git pkg-config apt-get mount umount findmnt systemctl df; do
        require_cmd "$c"
    done
    [[ "$ROOT_FS" == btrfs ]] && require_cmd mkfs.btrfs
    [[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]] || die "debian-archive-keyring is missing"

    test -b "$U" || die "$U is not a block device"
    lsblk -d -o NAME,MODEL,SERIAL,SIZE,TRAN,HOTPLUG "$U"
    # Informational: if udevadm does not expose those keys, grep returns 1
    # and with pipefail + ERR that would abort. "|| true" makes it non-blocking.
    udevadm info --query=property --name="$U" | grep -E -- '^(ID_BUS|ID_MODEL|ID_SERIAL|ID_PATH)=' || true

    local hotplug tran size mounts
    hotplug="$(lsblk -dn -o HOTPLUG "$U")"
    tran="$(lsblk -dn -o TRAN "$U")"
    size="$(lsblk -dn -o SIZE -b "$U")"
    check_disk_guards "$hotplug" "$tran" "$size"
    if (( ALLOW_TARGET_MOUNTS )); then
        log "Mounts of $M and $M/boot allowed by advanced --resume"
    else
        # No pipe: a silent grep would also close the pipe and give a
        # false "there are mounted partitions" due to lsblk's EPIPE.
        mounts="$(lsblk -rno MOUNTPOINTS "$U")"
        if [[ -n "${mounts//[[:space:]]/}" ]]; then
            die "There are mounted partitions on $U; unmount them first"
        fi
    fi
    log "Preflight OK"
}

ensure_target_dirs() {
    run mkdir -p \
        "$M/etc/apt/sources.list.d" \
        "$M/etc/initramfs-tools/conf.d" \
        "$M/etc/systemd" \
        "$M/boot/EFI/BOOT" \
        "$M/dev" "$M/proc" "$M/sys" "$M/run"
    # Without X11 not even the empty /etc/X11 directory is created,
    # and without greetd there is no /etc/greetd: no graphical leftovers.
    if [[ "$GUI" == yes ]]; then
        run mkdir -p "$M/etc/X11/xorg.conf.d"
    fi
    if [[ "$GREETER" == greetd ]]; then
        run mkdir -p "$M/etc/greetd"
    fi
}

ensure_chroot_mounts() {
    if (( DRY_RUN || SIMULATE )); then
        run mount --bind /dev "$M/dev"
        run mount -t devpts devpts "$M/dev/pts"
        run mount -t proc proc "$M/proc"
        run mount -t sysfs sys "$M/sys"
        run mount -t tmpfs tmpfs "$M/run"
        run chmod 1777 "$M/run"
        run cp --dereference /etc/resolv.conf "$M/etc/resolv.conf"
        return 0
    fi
    ensure_target_dirs
    if ! findmnt "$M/dev" >/dev/null; then mount_track "$M/dev" --bind /dev; fi
    run mkdir -p "$M/dev/pts"
    if ! findmnt "$M/dev/pts" >/dev/null; then mount_track "$M/dev/pts" -t devpts devpts; fi
    if ! findmnt "$M/proc" >/dev/null; then mount_track "$M/proc" -t proc proc; fi
    if ! findmnt "$M/sys" >/dev/null; then mount_track "$M/sys" -t sysfs sys; fi
    if ! findmnt "$M/run" >/dev/null; then mount_track "$M/run" -t tmpfs tmpfs; fi
    run chmod 1777 "$M/run"
    if [[ ! -s "$M/etc/resolv.conf" ]]; then
        run cp --dereference /etc/resolv.conf "$M/etc/resolv.conf"
    fi
}

ensure_target_mount() {
    if (( DRY_RUN || SIMULATE )); then
        run cryptsetup open --key-file - "$R" cryptroot
        run mount /dev/mapper/cryptroot "$M"
        run mount "$B" "$M/boot"
        return 0
    fi
    if ! findmnt "$M" >/dev/null; then
        HELP_FN=help_identity; HELP_SHOWN=""
        ask_secret LUKS_PASS "LUKS passphrase to open $R"
        local pf="$SCRATCH_DIR_REAL/luks.pass"
        luks_pass_file "$pf"
        cryptsetup open --key-file - "$R" cryptroot < "$pf"
        mount_track "$M" /dev/mapper/cryptroot
    fi
    run mkdir -p "$M/boot"
    if ! findmnt "$M/boot" >/dev/null; then mount_track "$M/boot" "$B"; fi
}

ensure_resume_mounts() {
    if (( LAST_STAGE >= 15 )); then
        log "Resume: final stage already completed; not remounting"
        return 0
    fi
    if (( LAST_STAGE >= 3 )); then ensure_target_mount; fi
    if (( LAST_STAGE >= 4 )); then ensure_chroot_mounts; fi
}

# ---------------------------- stages ----------------------------

stage_1_prepare() {
    log "=== Stage 1: preparation and RAM backup ==="
    run mkdir -p "$M" "$ARTIFACT_DIR" "$STATE_DIR"
    if [[ "$MAKE_HOST_BACKUP" == yes ]]; then
        run dd if="$U" of="$ARTIFACT_DIR/disk-first-16MiB.img" bs=1M count=16 status=progress
        if (( ! DRY_RUN && ! SIMULATE )); then
            sfdisk --dump "$U" > "$ARTIFACT_DIR/partitions-before.txt" 2>/dev/null || true
            sgdisk --backup="$ARTIFACT_DIR/gpt-before.bin" "$U" 2>/dev/null || true
            chmod 600 "$ARTIFACT_DIR"/disk-first-16MiB.img "$ARTIFACT_DIR"/partitions-before.txt "$ARTIFACT_DIR"/gpt-before.bin 2>/dev/null || true
        else
            run sfdisk --dump "$U"
            run sgdisk --backup="$ARTIFACT_DIR/gpt-before.bin" "$U"
        fi
    fi
    mark_stage 1
}

# Cleans residual filesystem signatures at the START of a partition.
# sgdisk --zap-all erases the GPT table but NOT the data: when reusing
# the USB, the new ef02 (LBA 2048) keeps the previous boot sector and
# Limine 12.9.6 refuses to install stage 2 (validate_or_force in limine.c).
# 4096 bytes cover the offsets +3, +54, +82 and +1080 that it inspects.
clean_partition_start() {
    local p="$1"
    log "=== Cleaning the first 4096 bytes of $p (residual signatures) ==="
    if (( ! DRY_RUN && ! SIMULATE )); then
        test -b "$p" || die "$p does not exist; signatures cannot be cleaned"
    fi
    # ALIGNED 4096-byte write: covers +3, +54, +82 and +1080 of Limine's
    # validate_or_force(). wipefs is not used here: its sub-sector writes
    # (5 bytes at +82) are unnecessary and, with QEMU cache=none over a
    # host block device, can fail with I/O errors.
    run dd if=/dev/zero of="$p" bs=4096 count=1 conv=notrunc status=none
    if (( ! DRY_RUN && ! SIMULATE )); then
        # cmp consumes the whole input: no EPIPE and no false negative.
        if ! dd if="$p" bs=4096 count=1 status=none | cmp -n 4096 -s - /dev/zero; then
            die "The first 4096 bytes of $p are not zero; aborting before installing Limine"
        fi
    fi
    log "First 4096 bytes zeroed and verified on $p"
}

stage_2_partition() {
    log "=== Stage 2: DESTRUCTIVE partitioning ==="
    run sgdisk --zap-all "$U"
    run sgdisk -n "1:1M:+${BIOS_SIZE}" -t 1:ef02 -c 1:BIOSBOOT "$U"
    run sgdisk -n "2:0:+${ESP_SIZE}" -t 2:ef00 -c 2:ESPBOOT "$U"
    run sgdisk -n 3:0:0 -t 3:8309 -c 3:LUKSROOT "$U"
    run partprobe "$U"
    run udevadm settle
    # sgdisk --zap-all does NOT erase data: clean ONLY the start of the
    # BIOS Boot (ef02), which is the only thing Limine inspects. /boot
    # and LUKS are rewritten in stage 3 with mkfs.fat and luksFormat,
    # so there is no need to touch $B or $R here.
    clean_partition_start "$BIOSP"
    if (( ! DRY_RUN && ! SIMULATE )); then
        test -b "$B" || die "$B does not exist"
        test -b "$R" || die "$R does not exist"
        sgdisk -v "$U"
    fi
    mark_stage 2
}

luks_pass_file() {
    local f="$1" old
    old="$(umask)"
    umask 077
    printf '%s' "$LUKS_PASS" > "$f"
    umask "$old"
}

stage_3_luks_mount() {
    log "=== Stage 3: LUKS and mount ==="
    # Write probe WITH FLUSH on the ESP before formatting. If the
    # host/QEMU rejects writes inside /dev/sda2 (e.g. the host with the
    # old FAT32 volume mounted: critical target error already at sector
    # 18432), this detects it right away with an explainable message,
    # instead of letting mkfs.fat die between kernel lines. Writing
    # zeros here is safe: the ESP is formatted right afterwards.
    if ! run dd if=/dev/zero of="$B" bs=1M count=1 conv=fsync status=none; then
        die "The host is rejecting writes inside $B (flush probe). Probable cause: the host has the old FAT32 volume mounted. A removable USB drive does NOT support 'offline' on the host: shut down the VM, remove the drive letter from ALL partitions of that disk, close Explorer and start over. If it still fails, do not reboot: run 'dmesg | grep -i sense | tail' in the live session and keep the Sense Key (Data Protect = protected/mounted; Medium Error = dying USB media)"
    fi
    if ! run mkfs.fat -F32 -n "$BOOT_LABEL" "$B"; then
        die "mkfs.fat could not write to $B: the host/QEMU is rejecting writes (critical target error). Check that no partition of that disk has a drive letter on the host and read the Sense Key with 'dmesg | grep -i sense | tail' before rebooting"
    fi
    local pf="$SCRATCH_DIR_REAL/luks.pass"
    if (( ! DRY_RUN && ! SIMULATE )); then luks_pass_file "$pf"; fi
    if [[ "$PBKDF" == argon2id ]]; then
        if (( DRY_RUN || SIMULATE )); then
            run cryptsetup luksFormat --type luks2 --label "$LUKS_LABEL" --pbkdf argon2id --pbkdf-memory "$PBKDF_MEM" --pbkdf-parallel 1 --iter-time 2000 --force-password --key-file - "$R"
        else
            cryptsetup luksFormat --type luks2 --label "$LUKS_LABEL" --pbkdf argon2id --pbkdf-memory "$PBKDF_MEM" --pbkdf-parallel 1 --iter-time 2000 --force-password --key-file - "$R" < "$pf"
        fi
    else
        if (( DRY_RUN || SIMULATE )); then
            run cryptsetup luksFormat --type luks2 --label "$LUKS_LABEL" --pbkdf pbkdf2 --iter-time 4000 --force-password --key-file - "$R"
        else
            cryptsetup luksFormat --type luks2 --label "$LUKS_LABEL" --pbkdf pbkdf2 --iter-time 4000 --force-password --key-file - "$R" < "$pf"
        fi
    fi
    if (( DRY_RUN || SIMULATE )); then
        run cryptsetup open --key-file - "$R" cryptroot
    else
        cryptsetup open --key-file - "$R" cryptroot < "$pf"
    fi
    if [[ "$ROOT_FS" == ext4 ]]; then
        run mkfs.ext4 -L "$ROOT_LABEL" /dev/mapper/cryptroot
    else
        run mkfs.btrfs -L "$ROOT_LABEL" /dev/mapper/cryptroot
    fi
    mount_track "$M" /dev/mapper/cryptroot
    run mkdir -p "$M/boot"
    mount_track "$M/boot" "$B"
    capture LUKS_UUID blkid -s UUID -o value "$R"
    capture ROOT_UUID blkid -s UUID -o value /dev/mapper/cryptroot
    capture BOOT_UUID blkid -s UUID -o value "$B"
    if (( ! DRY_RUN && ! SIMULATE )); then
        local uuid
        for uuid in "$LUKS_UUID" "$ROOT_UUID" "$BOOT_UUID"; do
            [[ "$uuid" =~ ^[A-Fa-f0-9-]{8,}$ ]] || die "Unexpected UUID: $uuid"
        done
    fi
    if (( ! DRY_RUN && ! SIMULATE )) && [[ "$MAKE_HOST_BACKUP" == yes ]]; then
        cryptsetup luksHeaderBackup "$R" --header-backup-file "$ARTIFACT_DIR/luks-header.img"
        chmod 600 "$ARTIFACT_DIR/luks-header.img"
        printf '%s\n' "LUKS_UUID=$LUKS_UUID" "ROOT_UUID=$ROOT_UUID" "BOOT_UUID=$BOOT_UUID" > "$ARTIFACT_DIR/uuids.txt"
        chmod 600 "$ARTIFACT_DIR/uuids.txt"
    fi
    mark_stage 3
}

stage_4_debootstrap() {
    log "=== Stage 4: debootstrap ==="
    run debootstrap --arch="$ARCH" --variant=minbase --components="$COMPONENTS" --keyring=/usr/share/keyrings/debian-archive-keyring.gpg --force-check-sig "$SUITE" "$M" "$MIRROR"
    ensure_target_dirs
    ensure_chroot_mounts
    mark_stage 4
}

stage_5_sources() {
    log "=== Stage 5: deb822 sources ==="
    ensure_chroot_mounts
    # debootstrap --components uses COMMAS; deb822 Components: uses SPACES.
    local components_deb822="${COMPONENTS//,/ }"
    write_lines "$M/etc/apt/sources.list.d/debian.sources" \
        "Types: deb" \
        "URIs: $MIRROR" \
        "Suites: trixie trixie-updates" \
        "Components: $components_deb822" \
        "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg" \
        "" \
        "Types: deb" \
        "URIs: $SECURITY" \
        "Suites: trixie-security" \
        "Components: $components_deb822" \
        "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
    # debootstrap leaves /etc/apt/sources.list with a line equivalent to
    # "deb ... trixie main contrib non-free-firmware". If kept, APT would
    # see trixie duplicated. The deb822 above is the authoritative one.
    run rm -f "$M/etc/apt/sources.list"
    run chroot "$M" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
    mark_stage 5
}

build_packages() {
    # HARD RULE: no X11 package may be in the base list.
    # x11-xkb-utils depends on libx11-6/libxaw7/libxrandr2/libxt6t64 and
    # x11-xserver-utils on other X11 libraries: they used to be here
    # unconditionally and that is why GUI=no installed X11 anyway.
    # Everything graphical lives ONLY inside the GUI=yes block below.
    PKGS=(
        apt debian-archive-keyring ca-certificates systemd-sysv locales tzdata
        keyboard-configuration console-setup sudo coreutils util-linux
        e2fsprogs dosfstools zstd netbase
        linux-image-amd64 initramfs-tools cryptsetup cryptsetup-initramfs
        systemd-zram-generator plymouth plymouth-themes plymouth-label
        curl wget gnupg xz-utils zstd less nano htop pciutils usbutils
    )
    [[ "$USER_SHELL" == /bin/zsh ]] && PKGS+=(zsh)
    [[ "$ROOT_FS" == btrfs ]] && PKGS+=(btrfs-progs)
    case "$FIRMWARE" in
        full) PKGS+=(firmware-linux-free firmware-amd-graphics firmware-intel-graphics firmware-nvidia-graphics firmware-misc-nonfree firmware-realtek firmware-iwlwifi firmware-atheros firmware-brcm80211 firmware-mediatek) ;;
        minimal) PKGS+=(firmware-linux-free firmware-realtek firmware-iwlwifi firmware-misc-nonfree) ;;
    esac
    case "$MICROCODE" in
        both) PKGS+=(intel-microcode amd64-microcode) ;;
        intel) PKGS+=(intel-microcode) ;;
        amd) PKGS+=(amd64-microcode) ;;
    esac
    case "$PIPEWIRE" in
        minimal) PKGS+=(pipewire pipewire-pulse pipewire-alsa wireplumber) ;;
        bluetooth) PKGS+=(pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth bluez pulseaudio-utils) ;;
    esac
    case "$NETWORK" in
        NetworkManager) PKGS+=(network-manager wpasupplicant iw) ;;
        dhcpcd) PKGS+=(dhcpcd-base wpasupplicant iw) ;;
    esac
    [[ "$FIREWALL" == yes ]] && PKGS+=(nftables)
    [[ "$APPARMOR" == yes ]] && PKGS+=(apparmor)
    [[ "$DOAS" == yes ]] && PKGS+=(opendoas)
    [[ "$AUDITD" == yes ]] && PKGS+=(auditd)
    [[ "$SSH" == yes ]] && PKGS+=(openssh-server)
    [[ "$GREETER" == greetd ]] && PKGS+=(greetd tuigreet)
    [[ "$GREETER" == ly ]] && PKGS+=(libpam0g libxcb1 libxcb-xkb1 libaudit1 brightnessctl)
    if [[ "$GUI" == yes ]]; then
        PKGS+=(xserver-xorg-core xserver-xorg-input-all xserver-xorg-video-all xauth xinit x11-xkb-utils x11-xserver-utils libgl1-mesa-dri mesa-utils "$FONT_PKG")
        [[ "$WM" == openbox ]] && PKGS+=(openbox)
        [[ "$COMPOSITOR" == picom ]] && PKGS+=(picom)
        [[ "$BAR" == tint2 ]] && PKGS+=(tint2)
        [[ "$LAUNCHER" == rofi ]] && PKGS+=(rofi)
        case "$TERMINAL" in xterm|both) PKGS+=(xterm) ;; esac
        case "$TERMINAL" in alacritty|both) PKGS+=(alacritty) ;; esac
        PKGS+=(feh)
    fi
    PKGS+=("${EXTRA_PACKAGES[@]}")
}

stage_6_packages() {
    log "=== Stage 6: packages ==="
    ensure_chroot_mounts
    ensure_target_dirs
    write_lines "$M/etc/kernel-img.conf" 'do_symlinks = No'
    write_lines "$M/etc/initramfs-tools/conf.d/zz-minimal.conf" \
        'MODULES=most' 'BUSYBOX=y' 'KEYMAP=y' 'RESUME=none' 'UMASK=0077'
    build_packages
    if [[ "$GUI" == no ]]; then
        log "GUI=no confirmed: no Xorg, no x11-* packages, no Openbox or graphical terminals"
    fi
    log "Selected packages: ${PKGS[*]}"
    run chroot "$M" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -s install --no-install-recommends "${PKGS[@]}"
    run chroot "$M" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"
    run chroot "$M" apt-get clean
    # shellcheck disable=SC2016
    capture K bash -c 'basename "$(find "$1/boot" -maxdepth 1 -name "vmlinuz-*" | sort | tail -n 1)" | sed "s/^vmlinuz-//"' sh "$M"
    [[ -n "$K" ]] || die "Could not determine the kernel version"
    [[ "$K" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid kernel ABI: $K"
    log "Kernel ABI: $K"
    mark_stage 6
}

set_chpasswd() {
    local user="$1" pass="$2" f="$SCRATCH_DIR_REAL/chpasswd.$$" old
    if (( DRY_RUN || SIMULATE )); then
        log "+ chpasswd for $user (hidden)"
        return 0
    fi
    old="$(umask)"
    umask 077
    printf '%s:%s\n' "$user" "$pass" > "$f"
    umask "$old"
    chroot "$M" /usr/sbin/chpasswd -c YESCRYPT < "$f"
    rm -f -- "$f"
}

stage_7_system_config() {
    log "=== Stage 7: base system ==="
    ensure_chroot_mounts
    write_lines "$M/etc/locale.gen" "$LOCALE UTF-8"
    run chroot "$M" /usr/sbin/locale-gen
    run chroot "$M" /usr/sbin/update-locale LANG="$LOCALE" LC_MESSAGES="$LOCALE"
    run ln -sf "/usr/share/zoneinfo/$TZ_AREA" "$M/etc/localtime"
    write_lines "$M/etc/timezone" "$TZ_AREA"
    write_lines "$M/etc/default/keyboard" \
        'XKBMODEL="pc105"' "XKBLAYOUT=\"$KEYMAP\"" 'XKBVARIANT=""' \
        'XKBOPTIONS="terminate:ctrl_alt_bksp"' 'BACKSPACE="guess"'
    write_lines "$M/etc/default/console-setup" \
        'ACTIVE_CONSOLES="/dev/tty[1-6]"' 'CHARMAP="UTF-8"' 'CODESET="guess"' \
        'FONTFACE="Terminus"' 'FONTSIZE="8x16"' 'VIDEOMODE=""'
    run chroot "$M" /usr/bin/setupcon --save-only
    ensure_target_dirs
    if [[ "$GUI" == yes ]]; then
        write_lines "$M/etc/X11/xorg.conf.d/00-keyboard.conf" \
            'Section "InputClass"' '    Identifier "system-keyboard"' \
            '    MatchIsKeyboard "on"' '    Option "XkbModel" "pc105"' \
            "    Option \"XkbLayout\" \"$KEYMAP\"" 'EndSection'
    else
        log "GUI=no: /etc/X11 is not created in the installed system"
    fi
    write_lines "$M/etc/hostname" "$HOSTNAME_DEB"
    write_lines "$M/etc/hosts" \
        '127.0.0.1 localhost' "127.0.1.1 $HOSTNAME_DEB" \
        '::1 localhost ip6-localhost ip6-loopback'
    run chroot "$M" /usr/sbin/useradd -m -s "$USER_SHELL" -G sudo,audio,video "$USERNAME"
    set_chpasswd "$USERNAME" "$USER_PASS"
    set_chpasswd root "$ROOT_PASS"
    write_lines "$M/etc/resolv.conf" "nameserver $DNS1" "nameserver $DNS2"
    mark_stage 7
}

stage_8_crypt_fstab() {
    log "=== Stage 8: crypttab/fstab/initramfs ==="
    ensure_chroot_mounts
    local root_opts="rw,noatime,errors=remount-ro"
    [[ "$ROOT_FS" == btrfs ]] && root_opts="rw,noatime,compress=zstd:1"
    write_lines "$M/etc/crypttab" "cryptroot UUID=$LUKS_UUID none luks,initramfs,tries=3"
    write_lines "$M/etc/fstab" \
        "UUID=$ROOT_UUID / $ROOT_FS $root_opts 0 1" \
        "UUID=$BOOT_UUID /boot vfat rw,noatime,nodev,nosuid,umask=0077 0 2"
    run chroot "$M" /usr/sbin/update-initramfs -u -k all
    mark_stage 8
}

kernel_cmdline() {
    local base="root=/dev/mapper/cryptroot rootfstype=$ROOT_FS ro" hard=""
    case "$KERNEL_HARDENING" in
        conservative) hard="slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=1 pti=on debugfs=off" ;;
        aggressive) hard="slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=1 pti=on debugfs=off vsyscall=none mitigations=auto,nosmt" ;;
        none) hard="" ;;
    esac
    if [[ "$PLYMOUTH_THEME" == none ]]; then
        printf '%s %s\n' "$base" "$hard"
    else
        printf '%s quiet splash %s\n' "$base" "$hard"
    fi
}

# AUTOMATIC update of limine.conf when the kernel changes.
# Debian runs the /etc/kernel/postinst.d and postrm.d hooks with
# run-parts, with $1=kernel ABI and $2=image path; bootloader hooks
# must be named zz-* to run LAST, and those in
# /etc/initramfs/post-update.d are called after creating/updating/removing
# an initramfs (Debian Kernel Handbook, ch. 8). The hook does NOT trust
# $1: it recomputes the newest vmlinuz-*/initrd.img-* pair PRESENT, so
# it also covers the removal of an old kernel (postrm). If /boot is not
# mounted or there is no valid pair, it warns on stderr and exits 0 so
# as not to break the apt transaction. /boot is FAT32, which does not
# support symlinks useful to Limine: that is why the versioned paths
# are rewritten instead of linking unversioned vmlinuz/initrd.img.
# shellcheck disable=SC2016
install_limine_auto_hook() {
    local hook="$M/etc/kernel/postinst.d/zz-limine-update"
    run mkdir -p "$M/etc/kernel/postinst.d" "$M/etc/kernel/postrm.d" "$M/etc/initramfs/post-update.d"
    write_lines "$hook" \
        '#!/bin/sh' \
        '# zz-limine-update: points limine.conf at the newest kernel present.' \
        '# Run by the Debian kernel/initramfs hooks (zz- = last).' \
        '# If there is no valid vmlinuz/initrd pair, it warns and exits 0: never breaks apt.' \
        'set -u' \
        'CONF=/boot/limine.conf' \
        'EFI_CONF=/boot/EFI/BOOT/limine.conf' \
        'if [ ! -f "$CONF" ]; then echo "zz-limine-update: $CONF does not exist; skipping" >&2; exit 0; fi' \
        'latest=$(for f in /boot/vmlinuz-*; do [ -f "$f" ] || continue; v=${f#/boot/vmlinuz-}; if [ -f "/boot/initrd.img-$v" ]; then echo "$v"; fi; done | sort -V | tail -n 1)' \
        'if [ -z "$latest" ]; then echo "zz-limine-update: no vmlinuz/initrd pair in /boot; skipping" >&2; exit 0; fi' \
        'tmp="/boot/.limine.conf.tmp.$$"' \
        'if ! sed -E "s/vmlinuz-[^[:space:]]+/vmlinuz-$latest/g; s/initrd\.img-[^[:space:]]+/initrd.img-$latest/g" "$CONF" > "$tmp"; then echo "zz-limine-update: sed failed; limine.conf untouched" >&2; rm -f "$tmp"; exit 0; fi' \
        'cat "$tmp" > "$CONF"' \
        'rm -f "$tmp"' \
        'mkdir -p /boot/EFI/BOOT' \
        'cat "$CONF" > "$EFI_CONF"' \
        'echo "zz-limine-update: limine.conf points at kernel $latest" >&2' \
        'exit 0'
    run cp "$hook" "$M/etc/kernel/postrm.d/zz-limine-update"
    run cp "$hook" "$M/etc/initramfs/post-update.d/zz-limine-update"
    run chmod 0755 "$hook" "$M/etc/kernel/postrm.d/zz-limine-update" "$M/etc/initramfs/post-update.d/zz-limine-update"
    log "Automatic Limine: zz-limine-update hook installed in kernel/postinst.d, kernel/postrm.d and initramfs/post-update.d"
}

stage_9_limine() {
    log "=== Stage 9: Limine upstream ==="
    ensure_chroot_mounts
    ensure_target_dirs
    local work="$SCRATCH_DIR_REAL/limine-upstream"
    run mkdir -p "$work"
    run curl -fL --retry "$CURL_RETRIES" --retry-delay 2 --connect-timeout "$NETWORK_TIMEOUT" --max-time "$((NETWORK_TIMEOUT * 30))" -o "$work/limine-binary.tar.xz" "https://github.com/Limine-Bootloader/Limine/releases/download/v${LIMINE_VER}/limine-binary.tar.xz"
    run curl -fL --retry "$CURL_RETRIES" --retry-delay 2 --connect-timeout "$NETWORK_TIMEOUT" --max-time "$((NETWORK_TIMEOUT * 30))" -o "$work/limine-binary.tar.xz.sig" "https://github.com/Limine-Bootloader/Limine/releases/download/v${LIMINE_VER}/limine-binary.tar.xz.sig"
    verify_sha "$LIMINE_SHA" "$work/limine-binary.tar.xz"
    if [[ "$VERIFY_GPG" == yes ]]; then
        run mkdir -m 0700 -p "$work/gnupg"
        run gpg --homedir "$work/gnupg" --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$LIMINE_KEY"
        run gpg --homedir "$work/gnupg" --batch --verify "$work/limine-binary.tar.xz.sig" "$work/limine-binary.tar.xz"
    else
        log "WARNING: Limine GPG signature skipped; only SHA-256 is verified"
    fi
    run tar -xJf "$work/limine-binary.tar.xz" -C "$work"
    run make -C "$work/limine-binary" limine
    [[ "$UEFI" == yes ]] && run install -m 0644 "$work/limine-binary/BOOTX64.EFI" "$M/boot/EFI/BOOT/BOOTX64.EFI"
    [[ "$UEFI_IA32" == yes ]] && run install -m 0644 "$work/limine-binary/BOOTIA32.EFI" "$M/boot/EFI/BOOT/BOOTIA32.EFI"
    [[ "$BIOS_BOOT" == yes ]] && run install -m 0644 "$work/limine-binary/limine-bios.sys" "$M/boot/limine-bios.sys"

    local cmdline fallback_cmd editor="no"
    cmdline="$(kernel_cmdline)"
    fallback_cmd="root=/dev/mapper/cryptroot rootfstype=$ROOT_FS ro plymouth.enable=0"
    [[ "$LIMINE_EDITOR" == yes ]] && editor="yes"
    write_lines "$M/boot/limine.conf" \
        'timeout: 5' 'default_entry: 1' "editor_enabled: $editor" \
        'interface_branding: DEBIAN MINIMAL' \
        'term_palette: 000000;aa0000;00aa00;aa5500;0000aa;aa00aa;00aaaa;aaaaaa' \
        "term_background: ff$BG" "term_foreground: $FG" \
        "term_foreground_bright: $ACCENT" '' \
        '/Debian 13 trixie (Plymouth)' '    protocol: linux' \
        "    path: boot():/vmlinuz-$K" "    cmdline: $cmdline" \
        "    module_path: boot():/initrd.img-$K"
    if [[ "$PLYMOUTH_FALLBACK" == yes ]]; then
        write_line "$M/boot/limine.conf" ''
        write_line "$M/boot/limine.conf" '/Debian 13 trixie (text)'
        write_line "$M/boot/limine.conf" '    protocol: linux'
        write_line "$M/boot/limine.conf" "    path: boot():/vmlinuz-$K"
        write_line "$M/boot/limine.conf" "    cmdline: $fallback_cmd"
        write_line "$M/boot/limine.conf" "    module_path: boot():/initrd.img-$K"
    fi
    write_line "$M/boot/limine.conf" ''
    write_line "$M/boot/limine.conf" '/Initramfs rescue'
    write_line "$M/boot/limine.conf" '    protocol: linux'
    write_line "$M/boot/limine.conf" "    path: boot():/vmlinuz-$K"
    write_line "$M/boot/limine.conf" "    cmdline: root=/dev/mapper/cryptroot rootfstype=$ROOT_FS ro plymouth.enable=0 break=premount"
    write_line "$M/boot/limine.conf" "    module_path: boot():/initrd.img-$K"
    # CONFIG.md: on UEFI the first candidate is <EFI app path>/limine.conf,
    # i.e. /EFI/BOOT/limine.conf. Leaving only /limine.conf works, but it
    # can be shadowed by another candidate on another partition.
    run mkdir -p "$M/boot/EFI/BOOT"
    run cp "$M/boot/limine.conf" "$M/boot/EFI/BOOT/limine.conf"
    install_limine_auto_hook
    run sync
    if [[ "$BIOS_BOOT" == yes ]]; then
        # Once again here: with --resume stage 2 is not repeated.
        clean_partition_start "$BIOSP"
        if [[ "$LIMINE_BIOS_FORCE" == yes ]]; then
            log "WARNING: LIMINE_BIOS_FORCE=yes; adding --force to bios-install"
            run "$work/limine-binary/limine" bios-install "$U" 1 --force
        else
            run "$work/limine-binary/limine" bios-install "$U" 1
        fi
    fi
    mark_stage 9
}

stage_10_plymouth() {
    log "=== Stage 10: Plymouth ==="
    ensure_chroot_mounts
    if [[ "$PLYMOUTH_THEME" != none ]]; then
        run chroot "$M" /usr/sbin/plymouth-set-default-theme -R "$PLYMOUTH_THEME"
        run chroot "$M" /usr/sbin/update-initramfs -u -k all
    else
        log "Plymouth installed but no splash in the main entry"
    fi
    mark_stage 10
}

stage_11_zram_audio() {
    log "=== Stage 11: ZRAM and PipeWire ==="
    ensure_chroot_mounts
    ensure_target_dirs
    if [[ "$ZRAM" == yes ]]; then
        write_lines "$M/etc/systemd/zram-generator.conf" \
            '[zram0]' "zram-size = min(ram / 2, $ZRAM_SIZE)" 'swap-priority = 100'
    else
        run rm -f "$M/etc/systemd/zram-generator.conf"
    fi
    mark_stage 11
}

ensure_zig_resolv_conf() {
    if (( DRY_RUN || SIMULATE )); then
        log "+ check the trailing newline of the live /etc/resolv.conf for Zig ${ZIG_VER}"
        return 0
    fi
    if [[ -f /etc/resolv.conf ]] && [[ -n "$(tail -c 1 /etc/resolv.conf)" ]]; then
        log "Adding a trailing newline to the live /etc/resolv.conf (Zig ${ZIG_VER} requires it)"
        printf '\n' >> /etc/resolv.conf
    fi
}

stage_12_greeter() {
    log "=== Stage 12: greeter ==="
    ensure_chroot_mounts
    ensure_target_dirs
    case "$GREETER" in
        ly)
            local src="$SCRATCH_DIR_REAL/ly-build" zig lysrc cache gcache
            run mkdir -p "$src"
            run curl -fL --retry "$CURL_RETRIES" --retry-delay 2 --connect-timeout "$NETWORK_TIMEOUT" --max-time "$((NETWORK_TIMEOUT * 60))" -o "$src/zig.tar.xz" "https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz"
            run curl -fL --retry "$CURL_RETRIES" --retry-delay 2 --connect-timeout "$NETWORK_TIMEOUT" --max-time "$((NETWORK_TIMEOUT * 30))" -o "$src/ly.tar.gz" "https://codeberg.org/fairyglade/ly/archive/v${LY_VER}.tar.gz"
            verify_sha "$ZIG_SHA" "$src/zig.tar.xz"
            verify_sha "$LY_SHA" "$src/ly.tar.gz"
            run tar -xJf "$src/zig.tar.xz" -C "$src"
            run tar -xzf "$src/ly.tar.gz" -C "$src"
            ensure_zig_resolv_conf
            zig="$src/zig-x86_64-linux-${ZIG_VER}/zig"
            lysrc="$src/ly"
            cache="$src/zig-local-cache"
            gcache="$src/zig-global-cache"
            log "Compiling Ly ${LY_VER} OUTSIDE the target with Zig ${ZIG_VER}"
            run_in_dir "$lysrc" env ZIG_GLOBAL_CACHE_DIR="$gcache" ZIG_LOCAL_CACHE_DIR="$cache" "$zig" build --cache-dir "$cache" -Doptimize=ReleaseSafe
            run_in_dir "$lysrc" env ZIG_GLOBAL_CACHE_DIR="$gcache" ZIG_LOCAL_CACHE_DIR="$cache" "$zig" build installexe -Dinit_system=systemd -Ddest_directory="$M" -Doptimize=ReleaseSafe --cache-dir "$cache"
            run chroot "$M" /usr/bin/ly --validate-config /etc/ly/config.ini
            run systemctl --root="$M" disable getty@tty2.service
            run systemctl --root="$M" enable ly@tty2.service
            log "Ly installed; Zig, tarballs and caches stay only in scratch and are deleted on exit"
            ;;
        greetd)
            write_lines "$M/etc/greetd/config.toml" \
                '[terminal]' 'vt = 7' '' '[default_session]' \
                'command = "tuigreet --time --asterisks --remember --remember-session --user-menu"' \
                'user = "_greetd"'
            run systemctl --root="$M" enable greetd.service
            run systemctl --root="$M" disable getty@tty7.service
            ;;
        console)
            log "No graphical greeter; login via TTY"
            ;;
    esac
    mark_stage 12
}

stage_13_desktop() {
    log "=== Stage 13: desktop ==="
    if [[ "$GUI" != yes ]]; then
        log "GUI=no: desktop stage skipped (no X11)"
        mark_stage 13
        return 0
    fi
    ensure_chroot_mounts
    local home="$M/home/$USERNAME"
    run install -d "$home/.config/openbox" "$home/.config/tint2"
    if [[ "$WM" == openbox ]]; then
        run cp "$M/etc/xdg/openbox/rc.xml" "$home/.config/openbox/rc.xml"
        run sed -i 's|<name>Clearlooks</name>|<name>Nightmare</name>|' "$home/.config/openbox/rc.xml"
        run sed -i "s|<name>sans</name>|<name>${FONT}</name>|g" "$home/.config/openbox/rc.xml"
        run sed -i 's|</keyboard>|  <keybind key="W-r"><action name="Execute"><command>rofi -show drun</command></action></keybind>\n  <keybind key="W-Return"><action name="Execute"><command>xterm</command></action></keybind>\n</keyboard>|' "$home/.config/openbox/rc.xml"
    fi
    write_lines "$home/.Xresources" \
        "XTerm*background: #$BG" "XTerm*foreground: #$FG" \
        "XTerm*cursorColor: #$ACCENT" "XTerm*faceName: $FONT" 'XTerm*faceSize: 10'
    run chroot "$M" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
    mark_stage 13
}

stage_14_security_network() {
    log "=== Stage 14: network and security ==="
    ensure_chroot_mounts
    if [[ "$FIREWALL" == yes ]]; then
        write_lines "$M/etc/nftables.conf" \
            'flush ruleset' '' 'table inet filter {' '    chain input {' \
            '        type filter hook input priority 0; policy drop;' \
            '        iif lo accept' '        ct state established,related accept' \
            '        ct state invalid drop' '        meta l4proto icmp accept' \
            '        meta l4proto ipv6-icmp accept' \
            '        udp sport 67 udp dport 68 accept' \
            '        udp sport 547 udp dport 546 accept' '    }' \
            '    chain forward {' '        type filter hook forward priority 0; policy drop;' '    }' \
            '    chain output {' '        type filter hook output priority 0; policy accept;' '    }' '}'
        run chroot "$M" /usr/sbin/nft -c -f /etc/nftables.conf
        run systemctl --root="$M" enable nftables.service
    fi
    [[ "$NETWORK" == NetworkManager ]] && run systemctl --root="$M" enable NetworkManager.service
    [[ "$APPARMOR" == yes ]] && run systemctl --root="$M" enable apparmor.service
    [[ "$DOAS" == yes ]] && write_lines "$M/etc/doas.conf" 'permit persist :sudo'
    [[ "$SSH" == yes ]] && run systemctl --root="$M" enable ssh.service
    mark_stage 14
}

stage_15_cleanup_finish() {
    log "=== Stage 15: cleanup and close ==="
    ensure_chroot_mounts
    if [[ "$CLEAN_TRACES" == yes ]]; then
        run rm -rf "$M/debootstrap"
        run rm -f "$M/var/log/bootstrap.log" "$M/var/log/debootstrap.log" "$M/root/.bash_history"
        run find "$M/var/cache/apt/archives" -maxdepth 1 -type f -name '*.deb' -delete
        run find "$M/var/lib/apt/lists" -maxdepth 1 -type f -delete
        run find "$M/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
    run chroot "$M" /usr/bin/dpkg --get-selections '*'
    if (( ! DRY_RUN && ! SIMULATE )) && [[ "$MAKE_HOST_BACKUP" == yes ]]; then
        sgdisk --backup="$ARTIFACT_DIR/gpt-final.bin" "$U"
        cp "$M/boot/limine.conf" "$ARTIFACT_DIR/limine.conf"
        cp "$M/etc/crypttab" "$ARTIFACT_DIR/crypttab"
        cp "$M/etc/fstab" "$ARTIFACT_DIR/fstab"
        chmod 600 "$ARTIFACT_DIR/gpt-final.bin" "$ARTIFACT_DIR/limine.conf" "$ARTIFACT_DIR/crypttab" "$ARTIFACT_DIR/fstab"
    fi
    run sync
    run umount -R "$M"
    MOUNTS=()
    run cryptsetup close cryptroot
    mark_stage 15
    if [[ "$DATA_POLICY" == delete ]] && (( ! DRY_RUN && ! SIMULATE )); then
        run rm -rf "$STATE_DIR" "$ARTIFACT_DIR"
        log "State and backups deleted; --resume will no longer work"
    fi
    log "=== Installation finished ==="
    log "This script, logs, tarballs, Zig or caches have not been copied into the installed system."
}

final_summary() {
    log "=== Final summary ==="
    if [[ "$DATA_POLICY" == delete ]]; then
        log "State and backups deleted as you chose; --resume no longer works."
    else
        log "State and backups directory (RAM): $BASE_DIR"
        log "Log: $LOG_FILE"
        log "WARNING: all of the above is LOST when you power off or reboot the VM."
        log "If you want to keep the LUKS header, copy it NOW with curl/scp to another server."
        log "File: $ARTIFACT_DIR/luks-header.img"
    fi
    log "To test booting, reboot the VM from /dev/sda without the ISO."
    log "Test UEFI first and then BIOS/Legacy; both paths are installed."
    log "If the screen stays black with Plymouth, choose the 'text' entry in Limine."
    log "Future kernels: they update THEMSELVES (zz-limine-update hook in the system)."
    log "--refresh-limine remains only as a rescue from the live session, not as a routine."
    log "Your QEMU configuration is still external to this script and has not been reviewed."
}

# ---------------------------- refresh-limine ----------------------------

refresh_limine() {
    log "=== Mode --refresh-limine ==="
    require_root
    if [[ -r "$CONFIG_FILE" ]]; then
        load_config_from "$CONFIG_FILE"
    else
        log "No previous configuration in RAM; defaults will be used and only the paths will be fixed"
    fi
    validate_preferences
    install_host_deps
    if (( DRY_RUN || SIMULATE )); then
        K="SIMULADO-K"
        run cryptsetup open --key-file - "$R" cryptroot
        run mount /dev/mapper/cryptroot "$M"
        run mount "$B" "$M/boot"
        run sed -i "s#vmlinuz-SIMULADO-K#vmlinuz-$K#g" "$M/boot/limine.conf"
        run sed -i "s#initrd.img-SIMULADO-K#initrd.img-$K#g" "$M/boot/limine.conf"
        run cp "$M/boot/limine.conf" "$M/boot/EFI/BOOT/limine.conf"
        install_limine_auto_hook
        run umount -R "$M"
        run cryptsetup close cryptroot
        log "limine.conf updated in simulation; this script was not left in the installed system"
        return 0
    fi
    test -b "$R" || die "$R does not exist"
    HELP_FN=help_identity; HELP_SHOWN=""
    ask_secret LUKS_PASS "LUKS passphrase to open the USB"
    local pf="$SCRATCH_DIR_REAL/luks.pass"
    luks_pass_file "$pf"
    cryptsetup open --key-file - "$R" cryptroot < "$pf"
    mount_track "$M" /dev/mapper/cryptroot
    run mkdir -p "$M/boot"
    mount_track "$M/boot" "$B"
    # shellcheck disable=SC2016
    capture K bash -c 'basename "$(find "$1/boot" -maxdepth 1 -name "vmlinuz-*" | sort | tail -n 1)" | sed "s/^vmlinuz-//"' sh "$M"
    [[ -n "$K" && "$K" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid kernel ABI: $K"
    sed -i -E "s#(path: boot\(\):/)vmlinuz-[^ ]+#\1vmlinuz-$K#; s#(module_path: boot\(\):/)initrd.img-[^ ]+#\1initrd.img-$K#" "$M/boot/limine.conf"
    cp "$M/boot/limine.conf" "$M/boot/EFI/BOOT/limine.conf"
    install_limine_auto_hook
    cp "$M/boot/limine.conf" "$ARTIFACT_DIR/limine.conf" 2>/dev/null || true
    sync
    umount -R "$M"
    MOUNTS=()
    cryptsetup close cryptroot
    log "limine.conf updated; this script was not left in the installed system"
}

# ---------------------------- CLI ----------------------------

usage() {
    cat <<'USO'
Usage: install.sh [OPTIONS]

  --explain               Print ALL explanations and exit. Touches nothing.
                          Ideal: bash install.sh --explain | less
  --validate              Static self-check; no questions, no changes.
  --dry-run               Show every command; executes no changes.
  --simulate              With --dry-run: skips real disk, root and network.
  --yes, --accept-defaults
                          Accept default values; in real mode it STILL asks
                          for passwords and the literal wipe confirmation.
  --config FILE           Load non-secret preferences saved in RAM.
  --resume                Continue from the last saved stage IN THIS SESSION.
  --refresh-limine        Manual RESCUE: opens the USB, fixes kernel paths
                          and installs the automatic zz-limine-update hook.
                          On a v2.1.0+ installation it is NOT needed after
                          a kernel update: the hook does it on its own.
  --log FILE              Log path (by default in artifacts/ under /tmp).
  --version               Show version.
  -h, --help              This help.

At normal questions type ? to re-read their explanation.
At PASSWORD questions, press ENTER without typing anything (? can be
your password). The minimum length is asked and defaults to 1 (no minimum).

Recommended order inside the live session:
  1) Download this same file from the "Raw" URL of your GitHub
     repository with curl or wget and save it as /tmp/install.sh
  2) bash /tmp/install.sh --explain | less
  3) bash /tmp/install.sh --validate
  4) bash /tmp/install.sh --dry-run --simulate --yes
  5) sudo bash /tmp/install.sh
  6) if it fails WITHOUT rebooting: sudo bash /tmp/install.sh --resume

Warning: "zero failure" cannot be guaranteed. All state and backups
live in /tmp (tmpfs/RAM) and are lost when the VM is powered off.
USO
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --explain) EXPLAIN_ONLY=1 ;;
            --validate) VALIDATE_ONLY=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --simulate) SIMULATE=1; DRY_RUN=1 ;;
            --yes|--accept-defaults) ACCEPT_DEFAULTS=1 ;;
            --resume) RESUME=1 ;;
            --refresh-limine) REFRESH_LIMINE=1 ;;
            --config)
                [[ $# -ge 2 ]] || die "--config requires a file"
                shift
                INPUT_CONFIG="$1"
                [[ "$INPUT_CONFIG" != -* ]] || die "--config must not start with '-'"
                ;;
            --log)
                [[ $# -ge 2 ]] || die "--log requires a path"
                shift
                LOG_FILE="$1"
                LOG_GIVEN=1
                [[ "$LOG_FILE" == /tmp/* ]] || die "--log must be an absolute path under /tmp (RAM) to leave no traces"
                [[ "$LOG_FILE" != *..* ]] || die "--log must not contain '..'"
                ;;
            --version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    if (( SIMULATE && ! DRY_RUN )); then die "--simulate requires --dry-run"; fi
    if (( RESUME && REFRESH_LIMINE )); then die "Do not combine --resume and --refresh-limine"; fi
}

main() {
    parse_args "$@"
    set_defaults
    derive_paths
    init_dirs
    ui_init

    if (( EXPLAIN_ONLY )); then
        help_all
        exit 0
    fi
    if (( VALIDATE_ONLY )); then
        self_check
        bash -n "$0"
        log "Validation OK; version $SCRIPT_VERSION"
        exit 0
    fi
    if (( REFRESH_LIMINE )); then
        ui_banner
        refresh_limine
        exit 0
    fi

    ui_banner
    log "=== $SCRIPT_NAME $SCRIPT_VERSION ==="
    log "Date: $(date -Is)"
    if (( DRY_RUN )); then log "SIMULATION MODE: no command with effects will be executed"; fi
    self_check

    if (( RESUME )); then
        [[ -r "$STATE_FILE" ]] || die "No state for --resume: $STATE_FILE (it is lost when the VM reboots)"
        [[ -r "$CONFIG_FILE" ]] || die "No configuration for --resume: $CONFIG_FILE"
        read_state
        load_config_from "$CONFIG_FILE"
        [[ -n "$INPUT_CONFIG" ]] && load_config_from "$INPUT_CONFIG"
        log "Resuming from stage $((LAST_STAGE+1))"
        validate_preferences
        (( LAST_STAGE >= 3 )) && ALLOW_TARGET_MOUNTS=1
        preflight
        ensure_resume_mounts
    else
        [[ -n "$INPUT_CONFIG" ]] && load_config_from "$INPUT_CONFIG"
        collect_preferences
        derive_paths
        validate_preferences
        preflight
        mark_stage 0
    fi

    stage_done 1 || stage_1_prepare
    stage_done 2 || stage_2_partition
    stage_done 3 || stage_3_luks_mount
    stage_done 4 || stage_4_debootstrap
    stage_done 5 || stage_5_sources
    stage_done 6 || stage_6_packages
    stage_done 7 || stage_7_system_config
    stage_done 8 || stage_8_crypt_fstab
    stage_done 9 || stage_9_limine
    stage_done 10 || stage_10_plymouth
    stage_done 11 || stage_11_zram_audio
    stage_done 12 || stage_12_greeter
    stage_done 13 || stage_13_desktop
    stage_done 14 || stage_14_security_network
    stage_done 15 || stage_15_cleanup_finish
    final_summary

    unset LUKS_PASS USER_PASS ROOT_PASS
    log "=== FIN ==="
}

main "$@"
