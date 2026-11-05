# Gallery

Everything tmd draws, on one page. Scroll with `j` and `k`, and press `t` to repaint it all in the
next palette. The title above isn't text: terminals have one font size, so it's drawn as pixels.

[← Back to the index](quickstart.md)

![tmd](images/hero.svg)

## Images in the document

Images sit in the grid as cells, so they scroll, clip and resize with the text around them. This SVG
is rasterized at exactly the size it's shown.

![The path from Markdown to the terminal](images/pipeline.svg)

A PNG goes to the terminal as it is, without tmd decoding it:

![A gradient](images/gradient.png)

## Every palette

Press `t` to walk through these. Your choice is saved, and `system` keeps your terminal's own colors.

![The eight palettes](images/palettes.svg)

## Terminal output, with its colors

Paste a session into a block marked `ansi` and it keeps its colors. Nothing else gets through: the
window title and screen clear in this block are dropped, and the upload line shows only its final
state, as a progress bar would.

```ansi
[1;36m$ make release[0m
[32m✓[0m compile    [2m412 files[0m
[32m✓[0m test       [2mall passed[0m
[33m![0m lint       [38;5;208m2 warnings[0m in [4msrc/app.zig[0m
[31m✗[0m deploy     [1;31mrefused:[0m [9mfriday[0m [3mmaintenance window[0m
upload  10%
upload  40%
upload  80%
upload 100% [32mdone[0m
]0;a window title you will never see[2J[Hthis line tried to clear your screen

[48;2;0;0;255m [48;2;8;6;250m [48;2;16;12;246m [48;2;24;19;242m [48;2;32;25;238m [48;2;40;31;234m [48;2;48;38;230m [48;2;56;44;226m [48;2;64;50;222m [48;2;72;57;218m [48;2;80;63;214m [48;2;89;69;210m [48;2;97;76;206m [48;2;105;82;202m [48;2;113;88;198m [48;2;121;95;194m [48;2;129;101;190m [48;2;137;107;186m [48;2;145;114;182m [48;2;153;120;178m [48;2;161;126;174m [48;2;170;133;170m [48;2;178;139;165m [48;2;186;146;161m [48;2;194;152;157m [48;2;202;158;153m [48;2;210;165;149m [48;2;218;171;145m [48;2;226;177;141m [48;2;234;184;137m [48;2;242;190;133m [48;2;250;196;129m [48;2;255;196;125m [48;2;255;190;121m [48;2;255;184;117m [48;2;255;177;113m [48;2;255;171;109m [48;2;255;165;105m [48;2;255;158;101m [48;2;255;152;97m [48;2;255;146;93m [48;2;255;139;89m [48;2;255;133;85m [48;2;255;126;80m [48;2;255;120;76m [48;2;255;114;72m [48;2;255;107;68m [48;2;255;101;64m [48;2;255;95;60m [48;2;255;88;56m [48;2;255;82;52m [48;2;255;76;48m [48;2;255;69;44m [48;2;255;63;40m [48;2;255;57;36m [48;2;255;50;32m [48;2;255;44;28m [48;2;255;38;24m [48;2;255;31;20m [48;2;255;25;16m [48;2;255;19;12m [48;2;255;12;8m [48;2;255;6;4m [48;2;255;0;0m [0m
[48;2;0;90;255m [48;2;0;92;253m [48;2;1;94;251m [48;2;1;97;250m [48;2;2;99;248m [48;2;3;101;247m [48;2;3;104;245m [48;2;4;106;244m [48;2;5;109;242m [48;2;5;111;241m [48;2;6;113;239m [48;2;6;116;238m [48;2;7;118;236m [48;2;8;120;235m [48;2;8;123;233m [48;2;9;125;232m [48;2;10;128;230m [48;2;10;130;229m [48;2;11;132;227m [48;2;12;135;226m [48;2;12;137;224m [48;2;13;140;223m [48;2;13;142;221m [48;2;14;144;220m [48;2;15;147;218m [48;2;15;149;217m [48;2;16;151;215m [48;2;17;154;214m [48;2;17;156;212m [48;2;18;159;211m [48;2;19;161;209m [48;2;19;163;208m [48;2;20;166;206m [48;2;20;168;205m [48;2;21;170;203m [48;2;22;173;202m [48;2;22;175;200m [48;2;23;178;199m [48;2;24;180;197m [48;2;24;182;196m [48;2;25;185;194m [48;2;26;187;193m [48;2;26;190;191m [48;2;27;192;190m [48;2;27;194;188m [48;2;28;197;187m [48;2;29;199;185m [48;2;29;201;184m [48;2;30;204;182m [48;2;31;206;181m [48;2;31;209;179m [48;2;32;211;178m [48;2;33;213;176m [48;2;33;216;175m [48;2;34;218;173m [48;2;34;220;172m [48;2;35;223;170m [48;2;36;225;169m [48;2;36;228;167m [48;2;37;230;166m [48;2;38;232;164m [48;2;38;235;163m [48;2;39;237;161m [48;2;40;240;160m [0m
[48;5;16m  [48;5;22m  [48;5;28m  [48;5;34m  [48;5;40m  [48;5;46m  [48;5;52m  [48;5;58m  [48;5;64m  [48;5;70m  [48;5;76m  [48;5;82m  [48;5;88m  [48;5;94m  [48;5;100m  [48;5;106m  [48;5;112m  [48;5;118m  [48;5;124m  [48;5;130m  [48;5;136m  [48;5;142m  [48;5;148m  [48;5;154m  [48;5;160m  [48;5;166m  [48;5;172m  [48;5;178m  [48;5;184m  [48;5;190m  [48;5;196m  [48;5;202m  [0m
```

## Tables that stay straight

Widths come from Ghostty's own tables, so the borders line up around emoji, CJK and joined sequences.

| Thing | Example | Cells | Aligned |
|:---|:---:|---:|:---:|
| Plain text | hello | 5 | ✅ |
| Chinese | 你好世界 | 8 | ✅ |
| Japanese | こんにちは | 10 | ✅ |
| Rocket | 🚀 | 2 | ✅ |
| Joined emoji | 👩‍💻 | 2 | ✅ |
| Flag | 🏳️‍🌈 | 2 | ✅ |
| Accent | café | 4 | ✅ |

Long cells wrap instead of pushing the table off the screen:

| Feature | How it works |
|---|---|
| Row diffing | Each row is built as bytes and hashed, and only the rows that changed are sent, so scrolling a large file writes almost nothing. |
| Safe by default | Control characters are replaced before they reach the terminal, so a hostile file can't move the cursor or touch your clipboard. |

## Text

Plain, **bold**, *italic*, ***both***, ~~struck out~~, `code`, and [a link](https://ghostty.org). Bare
URLs work too: https://github.com/ghostty-org/ghostty.

### A third-level heading

Headings one and two are large. The rest stay as text, in color.

> A quote keeps its bar.
>
> > And so does a quote inside it, with **bold** and `code` still working.

## Lists

1. Numbers keep counting
2. Through items that wrap, with the continuation lined up under the text as you'd expect it to be
3. And nesting:
   - Bullets change shape
     - At each level

- [x] Render Markdown in a terminal
- [x] Show real images
- [x] Make titles large
- [ ] Your next document

## Code

```zig
pub fn main() void {
    std.debug.print("*not italic*, **not bold**\n", .{});
}
```

---

Press `?` for every key, and `Ctrl+W` to close this tab.
