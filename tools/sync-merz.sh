#!/bin/sh
# Refresh tmd's vendored copy of the merz Mermaid renderer from a merz checkout.
#
#   tools/sync-merz.sh /path/to/merz           # a local clone of github.com/jtnk/merz
#
# What it touches, and the deliberate local deltas:
#   src/merz/{model,parser,layout}.zig  <- copied verbatim (their unit tests run
#                                          under tmd's `zig build test`).
#   src/merz/raster.zig                 <- copied, but the unit-test section is
#                                          dropped: those tests embed merz's own
#                                          font, which tmd supplies at the call
#                                          site instead.
#   vendor/{stb.c,stb_image_write.h,stbtt_decl.h} <- copied verbatim.
#
# It never writes src/merz/merz.zig (tmd's own facade) or vendor/stb_truetype.h:
# tmd shares one stb_truetype (v1.26) with vendor/decoders.c, and merz builds
# against that rather than its own newer copy. After syncing, update the pinned
# commit in src/merz/merz.zig's header and run `zig build test`.
set -eu

MERZ="${1:?usage: tools/sync-merz.sh /path/to/merz-checkout}"
DST="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"

[ -f "$MERZ/src/raster.zig" ] || { echo "not a merz checkout: $MERZ" >&2; exit 1; }

for f in model parser layout; do
    cp "$MERZ/src/$f.zig" "$DST/src/merz/$f.zig"
done

# raster.zig: everything up to (not including) the "---- tests" banner.
awk '/^\/\/ -+ tests$/ { exit } { print }' "$MERZ/src/raster.zig" > "$DST/src/merz/raster.zig"

for f in stb.c stb_image_write.h stbtt_decl.h; do
    cp "$MERZ/vendor/$f" "$DST/vendor/$f"
done

rev="$(git -C "$MERZ" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "synced src/merz and vendor glue from merz $rev"
echo "next: set the pinned commit in src/merz/merz.zig, then run 'zig build test'"
