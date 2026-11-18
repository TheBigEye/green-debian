#!/usr/bin/env bash
# setup-tux-boot.sh - install the tux-boot Plymouth theme with the
# Default8x16 font and no boot-up messages.
#
#   sudo ./setup-tux-boot.sh [--reboot]
#
# What it does:
#   1 installs Default8x16 as a system font (with a fontconfig rule
#     so the bitmap font is not rejected)
#   2 installs an initramfs-tools hook that copies the font into the
#     initramfs, where Plymouth needs it
#   3 copies this theme to /usr/share/plymouth/themes/tux-boot and
#     makes it the default
#   4 regenerates the initramfs (your zz-limine-update hook refreshes
#     Limine from there) and verifies the font is inside
# Safe to re-run. It asks before rebooting unless --reboot is given.
set -u

# plymouth-set-default-theme and update-initramfs live in sbin.
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FONT_SRC="$SCRIPT_DIR/../wallpaper/Default8x16.bdf"
[ -f "$FONT_SRC" ] || FONT_SRC="$SCRIPT_DIR/Default8x16.bdf"
FONT_DST=/usr/share/fonts/Default8x16/Default8x16.bdf
FONTCONFIG_RULE=/etc/fonts/conf.d/60-default8x16.conf
HOOK_SRC="$SCRIPT_DIR/default8x16-plymouth-font.hook"
HOOK_DST=/etc/initramfs-tools/hooks/default8x16-plymouth-font
THEME_DST=/usr/share/plymouth/themes/tux-boot

fail() { echo "setup-tux-boot: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run this as root (sudo ./setup-tux-boot.sh)."
[ -f "$FONT_SRC" ] || fail "font not found: $FONT_SRC (run it from the repo's tux-boot folder)."
[ -f "$SCRIPT_DIR/tux-boot.plymouth" ] || fail "tux-boot.plymouth not found next to this script."
[ -f "$HOOK_SRC" ] || fail "hook not found: $HOOK_SRC"
for cmd in install fc-cache fc-match plymouth-set-default-theme update-initramfs lsinitramfs; do
    command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
done

# 1) Font, system-wide. Debian fontconfig rejects bitmap fonts by
#    default, so an accept rule for this family is needed.
echo "== Installing the Default8x16 font =="
install -Dm644 "$FONT_SRC" "$FONT_DST" || fail "could not install $FONT_DST"
cat > "$FONTCONFIG_RULE" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <selectfont>
    <acceptfont>
      <pattern>
        <patelt name="family"><string>Default8x16</string></patelt>
      </pattern>
    </acceptfont>
  </selectfont>
</fontconfig>
EOF
fc-cache -f >/dev/null 2>&1 || true
fc-match Default8x16 | grep -q "Default8x16" \
    || fail "fontconfig still does not resolve Default8x16 (fc-match says: $(fc-match Default8x16)). Nothing else was changed."
echo "Font OK: $(fc-match Default8x16)"

# 2) The initramfs hook. Its installed name starts with "d" on
#    purpose: hooks run in alphabetical order and it must copy the
#    font before the plymouth hook builds the fontconfig cache.
echo "== Installing the initramfs hook =="
install -Dm755 "$HOOK_SRC" "$HOOK_DST" || fail "could not install $HOOK_DST"

# 3) Theme.
echo "== Installing the tux-boot theme =="
rm -rf "$THEME_DST"
cp -r "$SCRIPT_DIR" "$THEME_DST" || fail "could not copy the theme to $THEME_DST"
# These two live in the repo folder but are not theme files.
rm -f "$THEME_DST/default8x16-plymouth-font.hook" "$THEME_DST/setup-tux-boot.sh"
plymouth-set-default-theme tux-boot || fail "plymouth-set-default-theme failed."

# 4) Regenerate and verify.
echo "== Regenerating the initramfs =="
if ls /boot/initrd.img-* >/dev/null 2>&1; then
    update-initramfs -u -k all || fail "update-initramfs failed; the previous initramfs is still in place."
else
    # Nothing to update: create the running kernel's image.
    update-initramfs -c -k "$(uname -r)" || fail "update-initramfs could not create an initramfs."
fi

echo "== Verifying =="
found=0
for img in /boot/initrd.img-*; do
    [ -f "$img" ] || continue
    if lsinitramfs "$img" 2>/dev/null | grep -qi "default8x16"; then
        echo "  $img: font inside"
        found=1
    else
        echo "  $img: FONT MISSING" >&2
    fi
done
[ "$found" -eq 1 ] || fail "the font is not in any initramfs image; do not reboot into this blindly, check the messages above."
running_img="/boot/initrd.img-$(uname -r)"
if [ -f "$running_img" ] && ! lsinitramfs "$running_img" 2>/dev/null | grep -qi "default8x16"; then
    fail "the running kernel's initramfs ($running_img) does not have the font."
fi
echo "Verification OK."

echo
echo "Done. The LUKS password prompt is not affected: only boot"
echo "messages and the font changed."
if [ "${1:-}" = "--reboot" ]; then
    echo "Rebooting..."
    reboot
elif [ -t 0 ]; then
    printf "Reboot now? [y/N] "
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) reboot ;;
        *) echo "Reboot when you are ready:  reboot" ;;
    esac
else
    echo "Reboot when you are ready:  reboot"
fi
