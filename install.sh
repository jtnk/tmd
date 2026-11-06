#!/bin/sh
# Installs tmd from its GitHub releases, with no need for root:
#
#   curl -fsSL https://raw.githubusercontent.com/jtnk/tmd/main/install.sh | sh
#
# TMD_INSTALL_DIR says where to put it, instead of ~/.local/bin.
# TMD_VERSION asks for a release, such as v0.2.0, instead of the latest.
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
        *) echo "$dir isn't on your PATH yet, so add it to your shell's config." ;;
    esac
}

main
