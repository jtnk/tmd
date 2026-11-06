# How tmd spends a frame

Context for reviewing its benchmark. A frame is everything from an input event to the bytes being
ready for the terminal. It does not include the terminal drawing them.

| Scenario | What it exercises | Code |
|---|---|---|
| scroll by line, scroll by page, jump top/bottom | Painting rows, row hashing and the diff. No layout. | `App.paintPreview`, `Screen.flush` |
| resize | Wrapping the document again, at a new width. | `md.relayout`, `Builder.wrap` |
| toggle preview/editor | Mode switches. Layout is reused if the text hasn't changed. | `App.setMode` |
| typing + undo | Buffer edits, line table updates, and live styling of visible lines only. | `Editor.replace`, `Editor.paint` |
| cursor movement | Soft-wrap calculation for the lines around the cursor, and finding the scroll. | `Editor.vertical`, `Editor.wrapLine`, `Screen.detectScroll` |

Things worth knowing:

- Scrolling cost should not grow with document size, because only visible rows are painted. If it
  does, something is scanning the whole document per frame.
- Layout cost grows linearly with document size. It runs once per resize, and on the first frame.
- The first layout does everything. The second of the same text also records whatever doesn't depend
  on the width, in `md.Memo`, and later ones replay that and only wrap, for about a third of the time.
  So the first frame of a resize scenario is its slowest, which shows in `max_ms`, and an edit starts
  this over. Only a document that's resized pays for the memory.
- A large `max_ms` with a small `p99_ms` is usually one layout or image upload, not sustained cost.
- `bytes_per_frame` is terminal output, which matters most over SSH. Scrolling by a line should send
  about one row, because the terminal's own scroll moves the rest. That goes for the editor too, where
  `Screen.detectScroll` works out how far the rows moved. It's a mean, so a rare image upload raises it.
- Headings render as images in this benchmark, so a page scroll also uploads pixels. That raises
  `bytes_per_frame` on scroll-by-page, and is expected.
- The binary size budget is tight: a viewer of about 500KB. Printing floats alone costs 20KB or so,
  which is why times go through `trace.Fixed`. Only `src/layout.zig` and what it imports are built for
  speed, which costs about 6KB and is worth a fifth of a resize. The rest is built for size.
- Resize frames only lay out when the text width changes, and it stops changing at 100 columns, so
  about a quarter of the resize scenario's frames do no layout at all.
- `tmd` keeps its last frames in memory. `F11` writes them out, which is the first thing to ask for
  with a report of a stutter.
- A frame-rate target means tmd's own work fits the budget. What reaches the screen also depends on
  the terminal and the display.
