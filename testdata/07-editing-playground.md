# Editing playground

> Editing is experimental. Open this page with `tmd --experimental-edit`.

[← Back to the index](quickstart.md)

Press **E** to edit this page. Each step says what you should see. Don't save (Ctrl+S) unless you want to
keep the changes; Ctrl+Z undoes everything.

## 1. Live styling

Type `**hello**` on the empty line below. The text turns bold as soon as the closing `**` is typed,
and the asterisks dim.



## 2. Code fences change what comes after

On the empty line below, type three backticks and press Return. Everything after it should turn
into code. Then press Ctrl+Z: it all turns back into prose. Press ⇧Ctrl+Z (redo): code again.



This paragraph is the canary: watch it switch between prose and code.

- So is this list item.

## 3. Formatting shortcuts

Select a word in this sentence and press Ctrl+B (bold), Ctrl+I (italic), ⇧Ctrl+C (inline code), or Ctrl+K (link).
Press the same shortcut again on the same selection to undo the wrapping.

## 4. Tidy (Ctrl+T)

Tidy trims trailing spaces, collapses blank lines and puts blank lines around headings.
## This heading has no blank line above it
Text right under it.



Too many blank lines above this one.

## 5. Back to preview

Press **Esc**. The preview re-renders with your changes and keeps the same text at the top of the
window. The **HUD** (⌥Ctrl+T) shows `preview.render` and `style.edit` in **Recent spans**.

## 6. Typing speed

Hold down a key in this paragraph for a few seconds. The HUD's frame graph should stay well under
the lower red line (16.7ms, 60 fps).

## 7. Big-file typing

Open [the 2MB file](perf/huge.md), press **E**, jump to the middle (drag the scroller), and type.
Each keystroke only restyles the changed line, so it should feel as quick as this small page.
