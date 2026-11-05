# Images and terminal output

[← Back to the index](quickstart.md)

A PNG, sent to the terminal undecoded:

![Gradient](images/gradient.png)

An SVG, rasterized to fit:

![Diagram](images/diagram.svg)

A small BMP stays small:

![Small](images/small.bmp)

A missing file shows its alt text:

![This image is missing](images/nope.png)

An image in running text ![inline](images/small.bmp) stays as text.

## Terminal output

A fenced block marked `ansi` keeps its colors. Anything else in it, such as cursor movement or a
window title, is dropped, and a carriage return restarts the line the way a progress bar does.

```ansi
[1;32m✓[0m build [2m(1.2s)[0m
[1;31m✗[0m test [38;5;208mwarning[0m: [4munderlined[0m
downloading  10%downloading  50%downloading 100%
]0;a window title[2Jstill here
```
