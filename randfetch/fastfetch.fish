function fastfetch --description 'fastfetch with a random logo from ~/.config/fastfetch'
    set -l logos (find $HOME/.config/fastfetch -maxdepth 1 -type f -name '*.txt')
    if test (count $logos) -eq 0
        command fastfetch $argv
        return $status
    end
    set -l logo (random choice $logos)
    set -l type file-raw
    # ASCII logos with $1 markers go as "file"; logos with embedded
    # ANSI escapes (coloured braille) go as "file-raw".
    if not grep -q (printf '\033') -- $logo
        if grep -q '^\$1' -- $logo
            set type file
        end
    end
    command fastfetch --logo $logo --logo-type $type $argv
end
