# green-debian

This repository holds my personal Debian 13 "trixie" setup. Each part
works on its own.

| Path | What it is |
| --- | --- |
| `install.sh` | An interactive installer that builds a complete Debian system from a Debian Live session. It does not use the traditional Debian installer. |
| `tux-boot/` | A Plymouth boot splash theme. |
| `wallpaper/` | A background image for the text console (TTY), shown through FbTerm. No X11 is involved. |
| `fastfetch/` | A fastfetch config and text logos. |
| `randfetch/` | Makes fastfetch pick a random logo on every run. Has its own README. |

The idea behind the whole repo: one USB stick with a full, encrypted
Debian on it, which boots on whatever PC is nearby. At boot you get a
penguin splash screen, and at login you get a text console with a
wallpaper and a slow slideshow behind it, no desktop needed. It is a
console setup that tries to look good anyway.

Everything here is made for my own machine and my own VM. Please read the
scripts before you run them on hardware you care about.

---

## Part 1: install.sh

### What it does

`install.sh` is a single Bash script (version 2.2.0). It installs Debian
13.7 "trixie" Stable from scratch.

The normal Debian installer is not used. Instead, the script does the work
itself, step by step:

1. It checks the target disk several times before touching it.
2. It erases the disk and creates a new GPT partition table.
3. It formats an EFI partition and creates a LUKS encrypted container.
4. It bootstraps a minimal Debian system with `debootstrap`.
5. It installs packages, configures the system, and sets up the Limine
   bootloader for both UEFI and BIOS boot.

It is written for one specific setup:

- You boot `debian-live-13.7.0-amd64-standard.iso` in a VM or on a real PC.
- The machine has one single disk: a USB stick that shows up as `/dev/sda`.
- Inside the Live session, you download this script from GitHub and run it.
- There is no second disk, no shared folder, and no help from the host.

The target is fixed to `/dev/sda` on purpose. It cannot be changed in a
question. This removes a whole class of "wrong disk" accidents.

### Why install it this way

The normal Debian installer targets internal disks and hides most of
what it does. Doing the job in a script means knowing exactly what
lands on the stick: the partitions, the encryption, the package list,
the bootloader. Nothing happens behind a wizard.

It is also a good way to learn what an installation really is. Stage
by stage this does by hand what installer programs do quietly, and
each stage can be read in the script before it runs.

### Before you start

Read this part twice.

- **The disk will be completely erased.** There is no undo. If the USB has
  anything you want to keep, copy it somewhere else first.
- Before the wipe, the script shows the disk model, serial, size and bus
  type, and asks you to type a confirmation by hand: `ERASE /dev/sda`.
  Nothing destructive happens before that moment.
- Secure Boot must be turned off. This setup is not signed for Secure Boot,
  and the script refuses to continue if you say it is on.
- You need a network connection in the Live session. Packages, the Limine
  release and (optionally) the ly greeter are downloaded during the install.
- A first run inside a VM is strongly recommended. That is how this was
  developed.

### How to run it

Inside the Debian Live session, run these commands in order:

```sh
# 1. Download the script
curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/TheBigEye/green-debian/main/install.sh

# 2. Read everything it plans to do (changes nothing)
bash /tmp/install.sh --explain | less

# 3. Run the static self-check (changes nothing)
bash /tmp/install.sh --validate

# 4. Do a full rehearsal (shows every command, executes nothing)
bash /tmp/install.sh --dry-run --simulate --yes

# 5. The real installation
sudo bash /tmp/install.sh
```

If the real run fails and you have not rebooted yet, you can continue
where it stopped:

```sh
sudo bash /tmp/install.sh --resume
```

This only works inside the same Live session. The reason is explained in
"How it works" below.

### How the questions work

- Every block of questions is preceded by a short summary, at most 10
  lines, so the question itself never leaves the screen on a small console.
- Type `?` at any normal prompt to open the full explanation for that
  question, paged with `less`.
- At password prompts, press Enter with nothing typed to open the help.
  This is because `?` is itself a valid password character.
- Every question has a default value. Pressing Enter accepts it.
- Menus are numbered. You type the number, not the value.
- After all the questions, every answer is validated again from scratch.
  Answers loaded from a config file go through the exact same checks.

The whole text of every explanation can be read at any time with
`bash /tmp/install.sh --explain`.

### The disk layout it creates

| Partition | Type | Size | Mounted as | What it holds |
| --- | --- | --- | --- | --- |
| `sda1` | `ef02` BIOS Boot | 1 to 8 MiB (default 2 MiB) | not mounted | Limine stage 2, needed only for BIOS/legacy boot. It is never formatted. |
| `sda2` | `ef00` ESP, FAT32 | 512 MiB, 1 GiB or 2 GiB (default 1 GiB) | `/boot` | Kernel, initramfs and `limine.conf`. It is **not** encrypted, because Limine cannot read LUKS. |
| `sda3` | `8309` LUKS2 | the rest of the disk | `/` | The encrypted root filesystem (ext4 by default, or btrfs) on `/dev/mapper/cryptroot`. |

Two more details:

- `crypttab` and `fstab` use UUIDs, not device names, so the boot does not
  depend on disk order.
- There is no swap partition. Swap is zram, which means compressed swap in
  RAM managed by `systemd-zram-generator`. No unencrypted memory pages are
  ever written to the flash, and the stick wears out more slowly.

### The 15 stages

The install runs in 15 stages. Each finished stage is recorded, which is
what makes `--resume` possible.

1. **Prepare.** Saves a backup in RAM: the first 16 MiB of the disk, the
   old partition table and the old GPT. This can be turned off.
2. **Partition.** Erases the partition table and creates the layout above.
   It also zeroes the first 4096 bytes of `sda1`. A reused stick still has
   the old boot sector there, and Limine refuses to install over a
   recognised filesystem signature. The zeroing is verified byte by byte.
   No `--force` and no `wipefs` are used.
3. **LUKS and filesystems.** First it writes a 1 MiB test block to the ESP
   and forces it to disk. If the host or QEMU is rejecting writes, the
   install stops here with a clear message, instead of `mkfs.fat` dying
   later inside a pile of kernel errors. Then it formats the ESP, creates
   the LUKS2 container (argon2id by default), formats the root filesystem,
   and saves a backup of the LUKS header into RAM.
4. **debootstrap.** Installs a minimal Debian base into the encrypted root.
5. **APT sources.** Writes a deb822 `debian.sources` file with trixie,
   trixie-updates and trixie-security.
6. **Packages.** Installs the base packages plus whatever your answers
   imply (firmware, network manager, audio, and so on). With `GUI=no`,
   this list is guaranteed to contain no X11 packages at all.
7. **Base configuration.** Locale, time zone, keyboard (also copied into
   the initramfs, so the LUKS prompt uses the same layout), hostname, your
   user account, and the three passwords.
8. **crypttab, fstab, initramfs.** Wires up the encrypted boot and rebuilds
   the initramfs.
9. **Limine.** Downloads Limine v12.9.6 from GitHub. It verifies the
   SHA-256 checksum and, unless you turned it off, the GPG signature. Then
   it builds the Limine tool, installs the UEFI boot files, writes
   `limine.conf` with three entries (normal with Plymouth, plain text, and
   an initramfs rescue entry), installs the BIOS boot code if you asked
   for it, and installs the automatic update hook described below.
10. **Plymouth.** Sets the splash theme you picked and rebuilds the
    initramfs.
11. **zram and audio.** Writes the zram configuration. (PipeWire itself is
    just packages from stage 6.)
12. **Greeter.** Sets up `greetd` with tuigreet, or builds `ly` from source
    with Zig, or leaves you with a plain console login. Details below.
13. **Desktop.** Only runs with `GUI=yes`. Sets up Openbox, your colours and
    font, and the Win+R / Win+Enter shortcuts. With `GUI=no` this stage is
    skipped completely. Not even an empty `/etc/X11` directory is created.
14. **Network and security.** Writes and validates the nftables firewall,
    and enables the services you asked for (AppArmor, NetworkManager,
    SSH, and so on).
15. **Cleanup.** Removes debootstrap leftovers from the installed system,
    saves a final copy of the GPT and the boot configuration into RAM,
    unmounts everything, and closes the LUKS container.

### After the install: kernel updates

You never have to update the bootloader by hand.

Stage 9 installs a small hook called `zz-limine-update` in three places:

- `/etc/kernel/postinst.d/`
- `/etc/kernel/postrm.d/`
- `/etc/initramfs/post-update.d/`

Debian runs these hooks after every kernel install, kernel removal and
initramfs rebuild. The hook finds the newest kernel and initramfs pair in
`/boot` and rewrites the paths inside `limine.conf` to match. If something
is missing it prints a warning and exits quietly, so an `apt upgrade` can
never be broken by it.

The `--refresh-limine` flag still exists, but only as a rescue tool: it
opens the stick from a Live session, fixes the paths and reinstalls the
hook. On a system installed with version 2.1.0 or later, you should not
need it as a routine.

### The main choices

**Greeter (how you log in).**

- `greetd` plus tuigreet is the default. Both are normal Debian packages.
  Nothing is compiled and nothing extra is downloaded. This is the option
  that always works.
- `ly` is a text-mode login screen from upstream. It is not in Debian, so
  the script downloads Zig and compiles it during the install. That needs
  a network connection and about 1 GB of free RAM. On a VM with 2 GB of
  RAM or less the script warns you and offers to switch to greetd instead.
- `console` means no login manager at all. You log in on the TTY and start
  X by hand if you installed it.

**Graphical environment.**

- `GUI=yes` installs minimal Xorg with Openbox, the picom compositor, the
  tint2 bar, the rofi launcher, and xterm or alacritty. It is a light,
  keyboard-driven setup, not a full desktop like GNOME or KDE.
- `GUI=no` installs a console-only system. Zero X11 packages, no
  `/etc/X11`, stage 13 skipped, greeter forced to console. If you only
  want a terminal, this is the clean option.

**Firmware and microcode.** A portable stick gets plugged into different
PCs, so the default firmware profile is `full`: graphics, Wi-Fi and
network firmware for the common vendors, plus both Intel and AMD CPU
microcode. `minimal` covers the basics. `none` is main-only and the
smallest, but some Wi-Fi or GPU hardware will not work until you install
the firmware by hand. Only the `non-free-firmware` component is used.
There is no `non-free`, and no mixing of Stable with Testing, Sid or
backports.

**Encryption.** LUKS2 with argon2id is the default. You can lower or raise
the argon2id memory cost (64 MiB is a sane default for a stick that moves
between PCs) or fall back to pbkdf2. The password minimum length defaults
to 1, which means no minimum. A password shorter than 12 characters only
gets you a warning, never a block. The decision is yours, but a short
LUKS passphrase is much easier to brute-force.

**Passwords are printable ASCII only.** The accepted range is 0x21 to
0x7E: letters, numbers and symbols. No spaces, no accents, no "ñ". This is
not arbitrary. The initramfs asks for the LUKS passphrase before the full
keyboard layout is loaded. A passphrase with accents that you typed
without trouble in the Live session can be impossible to type at boot,
and the system then looks like it "rejects" the correct password. It is
the most common cause of lockouts on encrypted installs.

**Kernel hardening.** Two profiles, `conservative` and `aggressive`, plus
`none`. These are only kernel command line flags written into
`limine.conf` (things like `pti=on` and `init_on_alloc=1`). Debian does
not ship a "hardened kernel" package, so the stock `linux-image-amd64` is
used. The aggressive profile adds `vsyscall=none` and
`mitigations=auto,nosmt`, which can break old binaries and can turn off
hyper-threading. If a boot ever fails because of this, edit the command
line from the Limine menu (the editor is enabled by default).

**Boot modes.** UEFI x64 and BIOS/legacy can both be installed on the same
stick, and having both is what makes it portable. UEFI IA32 is there for
the rare 32-bit UEFI tablets. Secure Boot must be off.

### Safety checks

Because the script erases a disk, it checks a lot before it writes
anything:

- The disk must be a block device at `/dev/sda`, report `TRAN=usb`, and
  have no mounted partitions.
- Its size must be inside the configured range. The default is 50 to 70
  decimal GB. Note that `lsblk` prints GiB, so a stick shown as "57.7G" is
  about 61.9 decimal GB and fits.
- The HOTPLUG check is adjustable: `allow0` (default, right for QEMU USB
  passthrough), `require1`, or `skip`. The other checks cannot be turned
  off.
- The mirrors are contacted first and must actually serve trixie and
  trixie-security with the right codenames.
- The flushed write probe in stage 3 catches dying USB media and hosts
  that still have the old FAT volume mounted, early and with a readable
  message.
- All answers are revalidated at the end, including answers that came from
  `--config` or `--resume`.
- `--validate` runs a static self-check that greps the script for its own
  design rules (for example: no X11 package may appear in the base list).

### Command line flags

| Flag | What it does |
| --- | --- |
| `--explain` | Prints every explanation and exits. Touches nothing. |
| `--validate` | Runs the static self-check. No questions, no changes. |
| `--dry-run` | Prints every command instead of executing it. |
| `--simulate` | Together with `--dry-run`: skips the real disk, root and network. |
| `--yes` | Accepts every default answer. In a real run, passwords and the `ERASE /dev/sda` confirmation are still asked. |
| `--config FILE` | Loads non-secret preferences from a file (the same base64 key=value format the script saves in RAM). |
| `--resume` | Continues from the last finished stage. Only inside the same Live session. |
| `--refresh-limine` | Rescue mode. Opens the stick, fixes the kernel paths in `limine.conf`, reinstalls the update hook. |
| `--log FILE` | Chooses the log path. It must be under `/tmp`. |
| `--version` | Prints the version. |
| `--help` | Prints the usage. |

Config values are plain English words: `yes` and `no`, and where they
apply `none`, `full`, `minimal`, `both`, `conservative`, `aggressive`,
`keep`, `delete`, `no-backups`, `allow0`, `require1`, `skip` and `console`.

> Note for older versions: in 2.2.0 the whole interface was translated
> from Spanish to English, and the internal values changed with it
> (`si` became `yes`, `ninguno` became `none`, the wipe confirmation
> became `ERASE /dev/sda`, and so on). Config files saved by older
> versions will be rejected by the validation. Answer the questions once
> to generate a new one.

### How it works, and the limits

- Everything temporary lives in `/tmp`. On Debian 13, `/tmp` is tmpfs,
  which is RAM. The log, the stage state, the backups, the downloaded
  tarballs, the Zig toolchain, the build caches and the temporary GPG
  keys all live there.
- Because of that, the installed system contains no trace of the
  installer. The script does not even copy itself into the new system.
- The downside: if you power off or reboot the Live
  session, all of it is gone, including `--resume` state and the LUKS
  header backup. If you want to keep the header backup, copy
  `artifacts/luks-header.img` to another machine before you shut down.
- The one exception is the `scratch/` folder, which is deleted as soon as
  the script exits. That is where keys and password files live.
- There is no promise of zero failure. USB sticks die, hosts reject
  writes, networks drop. The script tries to notice early, stop, and tell
  you the reason in plain words instead of pushing on and leaving a
  half-written disk.
- Plymouth can leave a black screen on some GPUs and under QEMU right
  where the LUKS password should be typed. That is why `limine.conf`
  always has a plain text entry. If the screen is black, reboot and pick
  the text entry.

---

## Part 2: tux-boot (Plymouth theme)

`tux-boot/` is a Plymouth theme. Plymouth is the program that shows the
graphical splash and the disk password prompt while the system boots.

The theme uses the standard `two-step` module: a black background, an
animated Tux logo, a thin progress bar, and the usual password dialog
images for the LUKS prompt. The animation has 81 frames and the
progress bar 51, which is a lot of pictures of a penguin, but the
result is smooth.

The theme asks for the classic 8x16 console font (Default8x16), which
Plymouth does not know by default, so install it with the included
script instead of copying files by hand. It installs the theme, the
font, and an initramfs hook that makes Plymouth find the font at boot:

```sh
cd tux-boot
sudo ./setup-tux-boot.sh
```

Rerunning it is safe. The theme file is `tux-boot.plymouth`; its name
and the folder name match, which is what Plymouth expects. The theme
also sets `SuppressMessages=true`, so the boot log line "cryptsetup:
cryptroot: set up successfully" does not show over the splash. The
LUKS password prompt still shows as usual.

Note: `install.sh` can enable Plymouth during installation, but it
only offers the themes Debian ships (default `spinfinity`). Install
this theme afterwards with the script above.

---

## Part 3: wallpaper (TTY background + patched FbTerm)

This part puts a picture behind your text console. No X11, no Wayland,
no desktop. It works like this:

1. At login on a TTY, the `idump` tool draws the image directly onto the
   framebuffer.
2. FbTerm, a terminal emulator that also works on the framebuffer, starts
   on top of that image.
3. Your shell opens inside FbTerm, over the picture, with the classic
   8x16 console font.
4. You type `exit` to leave, like in any other terminal.

### How to install it

You need the installed Debian system (for example, one made by
`install.sh` with `GUI=no`). Then:

```sh
cd wallpaper
./install.sh
```

The script installs the needed packages, builds the patched FbTerm (see
below), sets up the font and the terminfo entry, and adds a small block
to your Bash or Fish config so the wallpaper session starts automatically
when you log in on a TTY.

To remove everything again:

```sh
./install.sh --uninstall
```

Other flags:

| Flag | What it does |
| --- | --- |
| `--no-apt` | Do not install APT packages; only warn about missing ones. |
| `--no-patched` | Use the stock Debian FbTerm instead of building the patched one. |
| `--rebuild-idump` | Rebuild the bundled `idump` viewer and the `fbrender` slideshow renderer from source. |
| `--allow-root` | Allow running as root (it normally refuses). |

Running the installer again is safe. It skips the parts that are already
done, and it verifies its own work at the end. Uninstall removes
everything it added: the profile blocks in Bash and Fish, the fontconfig
files, and the terminfo entries for both your user and the system.

One thing to know: if the patched FbTerm binary already exists, the
build is skipped. After you change the patch, force a rebuild like this:

```sh
sudo rm /usr/local/bin/fbterm-patched
./install.sh
```

### Why FbTerm

FbTerm 1.7 is from 2010 and upstream has been quiet since. It is
still the only tool that does this job well: a real terminal on the
framebuffer, over a background image, with no X11 in between. So
instead of replacing it, this repo patches it. The patch in
`assets/fbterm-compat.patch` is the maintenance upstream never did,
and the sections below describe what it changes. Stock FbTerm from
Debian works too, just with fewer features.

### Three bugs that cost an afternoon each

- **The black square.** The kernel console kept drawing its block
  cursor while the wallpaper was painted. FbTerm photographed the
  framebuffer a moment later, cursor included, and the square became
  part of the wallpaper forever. The fix is boring: hide the cursor
  before painting, show it again when FbTerm exits.
- **The mouse trail.** Move the mouse at the login prompt while the
  wallpaper is being painted, and early versions kept a trail of
  black cells across the picture. The mouse server was drawing its
  own pointer over the image, and FbTerm captured that too. Now
  FbTerm takes the mouse before it captures the screen, and the
  launcher holds a helper client while painting.
- **The vanishing mouse.** Restart the `gpm` service while FbTerm
  was running, and the old FbTerm never reconnected. The mouse
  server went back to drawing its pointer over the terminal picture,
  erasing text as it moved. The patched FbTerm now keeps retrying
  until the mouse server returns, then repaints.

### Mouse inside FbTerm

The mouse inside FbTerm goes through GPM, the same mouse server that
draws the pointer on the login console. Two things are needed:

1. The `gpm` package installed and running (you already see its
   pointer on the login console, so this part is done).
2. A patched FbTerm that was built with `libgpm-dev` installed.
   Without that header, FbTerm's build quietly skips the mouse code
   and no mouse ever works inside it. This was the case in older
   builds. The installer now installs `libgpm-dev`, refuses to
   build without the mouse, and rebuilds an old mouse-less binary
   on its own when you run it again.

There is no arrow pointer inside FbTerm. FbTerm never draws
one, and GPM's own pointer belongs to the text console. The mouse still works. You see it as text selection
when you drag over text, and programs that use the mouse (vim with
`set mouse=a`, Midnight Commander, tmux) receive clicks, drags and
the wheel. The patched FbTerm also understands the current mouse
reporting modes (1002, 1003 and the SGR encoding 1006), which
recent vim, Neovim and tmux versions expect.

If you only want the new binary, without running the whole setup
again and without touching your `~/.fbtermrc`, use:

```sh
./scripts/replace-fbterm-binary.sh          # build and swap the binary
./scripts/replace-fbterm-binary.sh --check  # show what is installed now
./scripts/replace-fbterm-binary.sh --restore  # put the previous binary back
```

The old binary is kept as `/usr/local/bin/fbterm-patched.bak`.

### Background slideshow

While FbTerm runs, the background rotates through the gallery.
With the two included images it is a postcard that changes once a
minute; fill the folder with screenshots and it becomes a slow
slideshow behind your work. The images are the PNG files in
`~/.local/share/fbterm-background/gallery`
(the installer copies the repo's `gallery/` folder there; drop
more PNGs into it whenever you like). Every 60 seconds the next image
fades in. Only the background changes. The text on your terminal,
your cursor and your programs are never touched, because the
patched FbTerm blends the two backgrounds underneath the text it
already draws.

Everything about it is tuned in
`~/.config/fbterm-background/config`, and slideshow changes are
picked up while you work, within a second or two:

| Setting | What it does |
| --- | --- |
| `FBTERM_SLIDESHOW` | `on` or `off`: the whole slideshow. |
| `FBTERM_SLIDESHOW_INTERVAL` | Seconds each image stays (5 to 86400). Default 60. |
| `FBTERM_SLIDESHOW_ORDER` | `sequence` (file name order) or `random` (never the same image twice in a row). |
| `FBTERM_SLIDESHOW_TRANSITION` | `crossfade`, `black` (fade via black), `white` (fade via white), `none` (instant), or `random`. |
| `FBTERM_SLIDESHOW_DURATION_MS` | How long a transition takes, 0 to 10000 ms. Default 800. |
| `FBTERM_SLIDESHOW_REMEMBER` | `on`: each login starts on the image the last session ended with. |
| `FBTERM_SLIDESHOW_SIZE` | Render size override like `1920x1080`. Empty means the real framebuffer size. |
| `FBTERM_GALLERY_DIR` | A different gallery folder (absolute path). Empty means the default one above. |

Notes:

- The slideshow needs the patched FbTerm and the `fbrender`
  helper. On an existing install, update both with
  `./scripts/replace-fbterm-binary.sh` (new binary) and a normal run of
  `./install.sh` (renderer, rotator, launcher).
  If `fbrender` is ever missing, build it together with the
  viewer: `./install.sh --rebuild-idump`.
- To jump to the next image right away, run
  `touch ~/.local/share/fbterm-background/slideshow.next`.
- The slideshow pauses on its own when you switch to another
  virtual console and resumes when you come back (the background
  is already the current image when the screen is redrawn).

### Changing the wallpaper

Once the setup is installed, use `set-fbterm-wallpaper.sh`:

```sh
./scripts/set-fbterm-wallpaper.sh ~/Pictures/my-image.jpg
```

Step by step, this is what it does:

1. It copies the image over the installed background file,
   `~/.local/share/fbterm-background/wallpaper.png`. The old background
   is kept next to it as `wallpaper.png.bak`.
2. A PNG image is used as it is. JPG, WebP, GIF and BMP images are
   converted to PNG first. For that, one of these has to be installed:
   ImageMagick, ffmpeg, or python3 with PIL. If none is available, the
   script stops and tells you, and the old background stays in place.
3. With the patched FbTerm running, the session fades to the new
   image right away; no restart is needed. With the stock FbTerm,
   the background is only read when FbTerm starts, so the script
   then asks whether to restart FbTerm now. Restarting ends your
   session inside FbTerm (like typing `exit`) and takes you back
   to the login prompt. Log in again and the new image is there.

To change and restart in one step, without being asked:

```sh
./scripts/set-fbterm-wallpaper.sh ~/Pictures/my-image.jpg --restart
```

If you answer no, nothing happens. The new image shows the next
time FbTerm starts.

### If some colours are hard to read

Dark colours on a black or busy background are a known problem. The
classic example is dark blue text, like the `UUID=` lines when you edit
`/etc/fstab` in vim. Two things fix it here:

1. **The patched FbTerm uses a brightened palette.** The first 16
   terminal colours keep their usual hues but are lighter than the old
   VGA values. Dark blue, dark red and the grey used for comments are
   the ones that change the most. This helps in every program, not
   just vim, because the fix is in the terminal itself. The 256-colour
   range is not changed. To get it, force a rebuild of the patched
   FbTerm (the two commands under "How to install it" above).

2. **The background image can be darkened.** Edit
   `~/.config/fbterm-background/config` and lower `FBTERM_BRIGHTNESS`.
   It is a percentage: 100 is the original image, lower is darker.
   New installs start at 35. Your file is not overwritten when you run
   the installer again, so change it by hand. The change shows the
   next time FbTerm starts.

If text is still hard to read inside vim, also try a colour scheme
made for dark backgrounds, for example with `:colorscheme habamax`
inside vim (put `colorscheme habamax` in `~/.vimrc` to keep it).

### Files in this folder

| File | Purpose |
| --- | --- |
| `install.sh` | The installer and uninstaller. Runs in phases and verifies itself. |
| `gallery/` | The wallpaper images. The installer copies them to `~/.local/share/fbterm-background/gallery`, and the slideshow rotates through them. |
| `scripts/set-fbterm-wallpaper.sh` | Changes the installed background image. See "Changing the wallpaper" above. |
| `scripts/replace-fbterm-binary.sh` | Rebuilds and swaps only the patched FbTerm binary. See "Mouse inside FbTerm" above. |
| `scripts/fbterm-slideshow.sh` | The slideshow rotator. Installed as `~/.local/bin/fbterm-slideshow` and started by the login launcher. |
| `assets/fbterm-compat.patch` | The patch against the Debian `fbterm 1.7-5` sources. The installer downloads those sources, checks them against the Debian checksums, applies this patch, and builds `/usr/local/bin/fbterm-patched`. |
| `assets/fbrender.c` | Source of the slideshow renderer (built into `~/.local/bin/fbrender`): turns a PNG into the raw background file the patched FbTerm fades to. |
| `assets/idump-0.2.0.tar.gz` and `assets/idump.sha256` | The framebuffer viewer source and its checksum. `--rebuild-idump` builds the `idump` viewer and `fbrender` from it into `assets/`; a fresh clone has no binaries yet, and the installer builds them on its own when gcc is present. |
| `assets/Default8x16.bdf` | The classic 8x16 console font, registered through fontconfig. |
| `assets/fbterm-256color.ti` | The terminfo entry for the patched terminal: 256 colours, and `U8#1` so ncurses draws box borders correctly under UTF-8 locales. |

### What the patched FbTerm changes

Stock FbTerm is old and misses several things that modern terminal
programs expect. The patch adds them:

- **Correct bright colours.** The bright colour sequences (90 to 97 and
  100 to 107) work, as do 256-colour sequences. Truecolor sequences are
  converted down to the nearest 256-colour value.
- **No garbage on screen.** OSC sequences (used for hyperlinks, window
  titles, clipboard data) are swallowed silently instead of leaking
  their bytes into your prompt.
- **A real alternate screen.** Full-screen programs like vim, less and
  ncdu get their own screen, and your shell screen, cursor and scrollback
  are restored when they exit.
- **Unknown sequences are dropped whole.** Private or unknown CSI
  sequences are consumed up to their final byte instead of printing
  their parameters as text.
- **Fish support.** The session is started correctly from both Bash and
  Fish, with your real shell (`$SHELL`) inside FbTerm, and fastfetch runs
  once at login.
- **Bracketed paste, focus events, synchronized updates.** Programs
  that ask for them (vim, fish, nano, tmux) get paste markers around
  pasted text, focus in/out events, and whole frames shown at once
  instead of half-drawn screens (modes 2004, 1004 and 2026).
- **OSC 52.** When a program sets the "clipboard" (vim, tmux), it now
  sets FbTerm's own selection instead of being ignored. Middle-click
  pastes that text.
- **The kitty keyboard protocol.** This is what makes fish 4 fully work.
  When a program asks for it, keys are reported in the modern format:
  Ctrl+I is no longer the same key as Tab, Shift+Enter is no longer
  the same as Enter, and key releases can be reported too. The console
  switches to medium-raw mode only while such a program runs, and
  keys are translated using your real kernel keymap, so your layout
  and dead keys (for example the Spanish tilde key) keep working.
  Programs that never ask, like bash and vim, get the old behaviour
  byte for byte.
- **Alt+keypad composition keeps working.** Hold Alt, type a decimal
  code on the numeric keypad (for example Alt+227 for "ã"), release Alt,
  and the character is inserted. That is the classic console behaviour,
  and it is also reproduced while the kitty protocol is active, where
  the kernel cannot do it for you. The AltGr variant composes a
  hexadecimal code instead. In plain mode it was never broken: there
  the kernel handles it, as always.

One limit of the kitty support: while it is active, braille keys are
not reproduced. They are rare on a normal console.

---

## Part 4: fastfetch and randfetch

`fastfetch/` holds a fastfetch config (`config.jsonc`) and the text
logos it can show. To use it, copy the `.txt` files and the config
into `~/.config/fastfetch/`.

`randfetch/` goes one step further: every fastfetch run shows a
random logo from `~/.config/fastfetch/`. It works with Bash and Fish
and needs nothing beyond fastfetch itself. Install it with
`randfetch/install.sh`; its own README explains the details.

The logos are plain text files with ANSI colour codes inside. Open
one in a text editor and it looks like line noise. In the terminal
it is a carrot.

---

## Repository layout

```
.
├── install.sh      # the Debian installer, run from a Live session
├── tux-boot/       # Plymouth theme and its installer
├── wallpaper/      # TTY wallpaper and patched FbTerm setup
├── fastfetch/      # fastfetch config and text logos
└── randfetch/      # random fastfetch logo on every run
```

## Disclaimer

This is a personal setup, shared as is. The installer erases
`/dev/sda` by design. Test it in a VM first. If something here saves
you an afternoon, it did its job.
