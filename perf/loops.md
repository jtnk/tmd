# Performance loops

What was tried to make tmd faster, kept or not, so nobody has to try the dead ends again. Each loop was
one change, checked against the build before it: all tests, rendered output compared byte for byte, and
the benchmark's deterministic numbers. Timings are the 2MB document at 120 x 40, on Apple silicon.

Early loops were timed one binary after another, and that noise hid real changes of under a millisecond.
From loop 3 on, the two binaries alternate and the difference is taken pair by pair. Use `perf/review.py`
to catch regressions, but alternate binaries to judge a small change.

| Loop | Change | Result | Kept |
|--:|---|---|---|
| | Measure a heading's width once, and cache it across layouts | Resize 26.2 to 22.6 ms | Yes |
| | Skip bytes the inline scanner has no case for, with a table | Resize 22.6 to 19.3 ms | Yes |
| 1 | Reserve rows and spans from the last layout's size | No change | No |
| 2 | Build heading image keys without the formatter | No change | No |
| 3 | ASCII code lines that fit skip `width.next` | Resize -0.49 ms | Yes |
| 4 | Table-driven word scan, and one reserve per piece in `atomize` | Resize -1.78 ms | Yes |
| 5 | Add plain text to the row in runs, not word by word | No change | No |
| 6 | Parse table cells once, not once to measure and again to draw | Resize -0.57 ms | Yes |
| 7 | Lay out over the old layout, keeping its memory | Resize -0.82 ms | Yes |
| 8 | Build a table's borders once, and copy dashes in bulk | Resize -1.61 ms, first frame -2.0 ms | Yes |
| 9 | Skip the scanner for text with no Markdown in it | Resize +0.29 ms | No |
| 10 | Loop 2 again, under alternating timing | -0.03 ms | No |
| 11 | One pass to split lines, with a cheap check for references | Resize -0.13 ms | Yes |
| 12 | Write color sequences by hand, not with `bufPrint` | Page scroll -14% | Yes |
| 13 | Printable ASCII first in the editor's `cell` | Cursor -29%, typing -13% | Yes |
| 14 | Keep mid-word `h` and `w` in the scanner's skip loop | Resize +0.19 ms | No |
| 15 | Write row addresses by hand | No change | No |
| 16 | `-p` writes in 64KB blocks, not a row at a time | `-p` on 2MB 105 to 83 ms | Yes |
| 17 | Decode only as much of a cluster as the answer needs | Scroll by line -57%, jump -64%, toggle -61%, `-p` 73 to 40 ms | Yes |
| 18 | Reject most words before looking for a URL | Resize -0.78 ms, first frame -0.9 ms | Yes |
| 19 | Check for a table's delimiter row before searching for `\|` | No change | No |
| 20 | Keep what doesn't depend on the width, and replay it on a resize | Resize 15.8 to 7.4 ms, memory +18MB | Yes |
| 21 | A single space before a word is a flag, not an atom | Resize -0.19 ms, memory -4MB | Yes |
| 22 | Add unlinked text to the row in runs | Resize -0.32 ms | Yes |
| 23 | A table of bytes that can't start a block | No change | No |
| 24 | Keep tables as drawn, for when they fit | Resize +0.35 ms | No |
| 25 | A tight loop for words that simply follow the last one | Resize -0.65 ms | Yes |
| 26 | Allocate a table's cell lines once, not once a row | Resize -0.09 ms | Yes |
| 27 | Look for `\r`, not `\r\n`, in every file opened | First frame -5.2 ms | Yes |
| 28 | Index lines with the vectorized search | First frame about -1 ms | Yes |
| 29 | One glyph lookup a character when measuring a heading | First frame -0.5 ms | Yes |
| 30 | Find scrolls in the editor by comparing row hashes | Cursor 12,066 to 997 bytes a frame, typing -26% | Yes |
| 31 | Reserve rows and spans before the first layout | No change, memory +3MB | No |
| 32 | Remember kerning between ASCII characters | First frame about -1 ms | Yes |
| 33 | Build layout for speed, and everything else for size | Resize -19%, first frame -1.7 ms, file -3KB | Yes |

## What it came to

| Scenario, p50 | Before loop 1 | After loop 15 | After loop 33 |
|---|--:|--:|--:|
| Resize | 21.4 ms | 16.2 ms | 5.7 ms |
| First frame | 31.2 ms | 26.6 ms | 20 ms |
| Scroll by line | 0.077 ms | 0.061 ms | 0.029 ms |
| Scroll by page | 0.153 ms | 0.130 ms | 0.112 ms |
| Cursor movement | 0.091 ms | 0.049 ms | 0.037 ms |
| Typing | 0.106 ms | 0.077 ms | 0.065 ms |

Those are the numbers after the security fixes that followed the loops, which cost resize about 0.3 ms.
Resize started this work at 26.4 ms. The last column was measured on a busier machine: loop 15's build
took 18.3 ms for resize there, not 16.2.

Resize now meets 60 fps at p99. With 120 frames, p99 is the second slowest, so it moves a lot with what
else the machine is doing: 8 to 13 ms is usual. The very first resize of a document takes about 20 ms,
because it records what the rest replay, and the next about 9 ms. After that a frame takes 5 to 7 ms.

Outside the benchmark, `-p` on 2MB went from 105 to 41 ms, and on 200KB from 13.9 to 6.8 ms.

## What's left

- Scrolling by page sends 86KB at the median, nearly all of it heading images, uploaded once each as
  raw pixels. Headings are mostly transparent, so `o=z` compression should cut that several times over,
  but it needs a small deflate and checking on real terminals.
- A first layout is 18 ms, against 6 ms for a replay. It's mostly `atomize` and `Scanner.scan`, and the
  branch that ends each word. Finding words 16 bytes at a time might save a millisecond or two.
- The memo costs 14MB on a 2MB document, on top of 47MB, once it has been resized. Nothing is kept
  until then, so `-p` and reading without resizing don't pay for it. `Piece` is most of what's left.
- `fenceAt` reads from the top of the document for every editor frame, about 1.6 µs per 1,000 lines
  above the view. A checkpoint every so many lines would fix it, but they'd have to survive edits.

## Lessons

- In a `ReleaseSmall` profile, time in `OUTLINED_FUNCTION_*` belongs to the caller. Fold it in.
- A profile's share isn't what removing the work would save. `add` looked expensive in loop 5, and
  calling it far less changed nothing, while loop 8 was worth far more than `tableBorder` looked.
- The profile covers every scenario. Timers around the phases of layout found the tables parsing every
  cell twice, which no profile showed.
- A benchmark only measures what it drives. `-p`, file decoding, and bytes in the editor all had far
  bigger wins than anything left in the frame times, and the benchmark showed none of them.
- A mean hides what a median shows. Scrolling's bytes looked high from image uploads, while the editor's
  real waste looked the same. Print percentiles before deciding what's wrong.
- Inlining moves time as well as outlining does: `blocks` looked like a quarter of a resize, loop 23
  found that wasn't parsing, and timers showed it was the `table` and `paragraph` inlined into it.
- Measure a cache's hit rate before building it. Most tables in the benchmark don't fit at their natural
  width, so loop 24 kept tables nothing could reuse.
- What an optimization costs depends on what it's applied to. `ReleaseFast` was 225KB for the whole
  binary and 6KB for the few files that needed it.
- Release builds have no bounds or overflow checks. Run the benchmark on `-Doptimize=ReleaseSafe` before
  trusting a change to how layout indexes things: `hline` was truncating rules past 170 columns for
  this reason, and only a debug test caught it.
- Compare the output of a change, not just its speed: hash every frame the benchmark sends. Then break
  something on purpose, to prove the check can fail.
