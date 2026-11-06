#!/bin/sh
# Installs tmd from its GitHub releases, with no need for root:
#
#   curl -fsSL https://raw.githubusercontent.com/jtnk/tmd/main/install.sh | sh
#
# TMD_INSTALL_DIR says where to put it, instead of ~/.local/bin.
# TMD_VERSION asks for a release, such as v0.2.0, instead of the latest.
# TMD_NO_MODIFY_PATH=1 leaves your shell's config alone.
set -eu

repo=jtnk/tmd

fail() {
    echo "tmd: $1" >&2
    exit 1
}

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1" || fail "couldn't download $1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1" || fail "couldn't download $1"
    else
        fail "installing needs curl or wget"
    fi
}

check() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c - >/dev/null
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c - >/dev/null
    else
        fail "installing needs sha256sum or shasum, to check the download"
    fi
}

# Puts dir on the PATH of new terminals. Nothing can change the PATH of the shell that ran this, so
# that takes a command of its own, which this prints.
setup_path() {
    dir=$1
    # In terms of $HOME if it can be, as people share these files between machines.
    case "$dir" in
        "$HOME"/*) shown="\$HOME/${dir#"$HOME"/}" ;;
        *) shown=$dir ;;
    esac
    line="export PATH=\"$shown:\$PATH\""
    rc=""
    shell="${SHELL:-}"
    case "${shell##*/}" in
        zsh) rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
        bash)
            # Terminals on macOS start login shells, which don't read .bashrc.
            if [ "$os" = macos ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi
            ;;
        fish)
            rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/tmd.fish"
            line="fish_add_path \"$shown\""
            ;;
    esac

    if [ -z "$rc" ] || [ -n "${TMD_NO_MODIFY_PATH:-}" ]; then
        printf '%s is not on your PATH. To add it, put this in your shell config:\n\n    %s\n' "$dir" "$line"
        return
    fi
    if ! grep -qsF "$line" "$rc"; then
        mkdir -p "$(dirname "$rc")" 2>/dev/null || true
        if ! (printf '\n# Added by the tmd installer\n%s\n' "$line" >>"$rc") 2>/dev/null; then
            printf "Couldn't change %s. To put tmd on your PATH, add this to it:\n\n    %s\n" "$rc" "$line"
            return
        fi
    fi
    printf 'Added %s to your PATH in %s, for new terminals. To use tmd in this one, run:\n\n    %s\n' "$dir" "$rc" "$line"
}

# Everything happens in here, so that a download cut short can't run half of it.
main() {
    case "$(uname -s)" in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        *) fail "there's no release for $(uname -s): see https://github.com/$repo#build" ;;
    esac
    case "$(uname -m)" in
        x86_64 | amd64) arch=x86_64 ;;
        aarch64 | arm64) arch=aarch64 ;;
        *) fail "there's no release for $(uname -m): see https://github.com/$repo#build" ;;
    esac

    asset="tmd-$arch-$os.tar.gz"
    version="${TMD_VERSION:-}"
    if [ -n "$version" ]; then
        base="https://github.com/$repo/releases/download/$version"
    else
        base="https://github.com/$repo/releases/latest/download"
    fi
    dir="${TMD_INSTALL_DIR:-$HOME/.local/bin}"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    fetch "$base/$asset" "$tmp/$asset"
    fetch "$base/checksums.txt" "$tmp/checksums.txt"

    cd "$tmp"
    grep " $asset\$" checksums.txt >want.txt || fail "checksums.txt doesn't list $asset"
    check <want.txt || fail "$asset doesn't match its checksum, so it wasn't installed"
    tar -xzf "$asset" tmd

    # Into place in one step, as tmd may be running.
    mkdir -p "$dir"
    cp tmd "$dir/.tmd.new"
    chmod 755 "$dir/.tmd.new"
    mv -f "$dir/.tmd.new" "$dir/tmd"

    echo "Installed $("$dir/tmd" --version) to $dir/tmd"
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) setup_path "$dir" ;;
    esac
}

main
