# fastfetch random logo

Make `fastfetch` show a random logo on every run. The logos are the
`.txt` files in `~/.config/fastfetch/`.

No new dependencies: just your shell and fastfetch.

## Install

```sh
./install.sh
```

This installs a shell function named `fastfetch` for both shells:

| Shell | What gets installed |
| --- | --- |
| fish | `~/.config/fish/functions/fastfetch.fish` |
| bash | `~/.local/share/fastfetch-random/fastfetch.bash`, plus one marked source line in `~/.bashrc` |

Open a new shell afterwards. Running the installer again updates the
function files; it never adds the bash line twice.

## How it works

1. The function collects every `*.txt` file in `~/.config/fastfetch/`
   and picks one at random.
2. It calls the real fastfetch with `--logo <file>`, so the logo in
   your `config.jsonc` is overridden for that run. Your configured
   modules are still used.
3. The logo type is detected per file: files with embedded ANSI
   escapes (coloured braille art) are passed as `file-raw`, and plain
   ASCII files that use `$1` colour markers are passed as `file`.
   Both kinds can live in the same folder.
4. If the folder has no `.txt` files, fastfetch runs normally.

Note: this only affects runs where the shell function is used, that
is, when you type `fastfetch` yourself. A program that starts the
fastfetch binary directly (for example `timeout 15 fastfetch`) does
not see shell functions and keeps using the logo from `config.jsonc`.

## Uninstall

```sh
./install.sh --uninstall
```

Removes the fish function, the bash function file, and the marked
block from `~/.bashrc` (a backup is kept as
`~/.bashrc.bak-fastfetch-random`).
