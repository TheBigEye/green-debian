# fastfetch with a random logo from ~/.config/fastfetch.
# Sourced from ~/.bashrc by the installer.
fastfetch() {
    local -a logos=()
    local f logo type
    while IFS= read -r f; do
        logos+=("$f")
    done < <(find "$HOME/.config/fastfetch" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | sort)
    if [ "${#logos[@]}" -eq 0 ]; then
        command fastfetch "$@"
        return $?
    fi
    logo="${logos[RANDOM % ${#logos[@]}]}"
    type="file-raw"
    # ASCII logos with $1 markers go as "file"; logos with embedded
    # ANSI escapes (coloured braille) go as "file-raw".
    if ! grep -q "$(printf '\033')" -- "$logo"; then
        if grep -q '^\$1' -- "$logo"; then
            type="file"
        fi
    fi
    command fastfetch --logo "$logo" --logo-type "$type" "$@"
}
