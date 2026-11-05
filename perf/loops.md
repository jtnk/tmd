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

## What it came to

| Scenario, p50 | Before loop 1 | After loop 15 |
|---|--:|--:|
| Resize | 21.4 ms | 16.2 ms |
| First frame | 31.2 ms | 26.6 ms |
| Scroll by line | 0.077 ms | 0.061 ms |
| Scroll by page | 0.153 ms | 0.130 ms |
| Cursor movement | 0.091 ms | 0.049 ms |
| Typing | 0.106 ms | 0.077 ms |

Those are the numbers after the security fixes that followed the loops, which cost resize about 0.3 ms.
Resize started this work at 26.4 ms. Its p99 is 17.7 ms, so it still misses 60 fps.

## What's left

- Layout time is mostly paragraphs and tables: scanning inlines, then splitting into words, then
  wrapping. Only the wrapping depends on the width, so caching the words across a resize would cut
  about a quarter of it, for a lot of memory on a large document.
- `ReleaseFast` gets resize down to 12.5 ms, but costs 225KB.

## Lessons

- In a `ReleaseSmall` profile, time in `OUTLINED_FUNCTION_*` belongs to the caller. Fold it in.
- A profile's share isn't what removing the work would save. `add` looked expensive in loop 5, and
  calling it far less changed nothing, while loop 8 was worth far more than `tableBorder` looked.
- The profile covers every scenario. Timers around the phases of layout found the tables parsing every
  cell twice, which no profile showed.
