# Code

[← Back to the index](quickstart.md)

Inline: `let x = 42`, `npm install`, and `` `backticks` inside code ``.

## Swift

```swift
import AppKit

// Markdown inside code stays literal: **not bold**, *not italic*, [not a link](x.md)
final class Example: NSObject {
    let values = [1, 2, 3]
    func total() -> Int { values.reduce(0, +) }
}
```

## Shell

```sh
./build.sh --install
~/Applications/mmd.app/Contents/MacOS/mmd --bench testdata/perf/large.md --runs 3
/usr/bin/log stream --style compact --predicate 'subsystem == "io.github.jtnk.mmd"'
```

## Tilde fence

~~~python
def greet(name: str) -> str:
    # - this is a comment, not a list item
    # > and this is not a quote
    return f"Hello, {name}!"
~~~

## Very long lines

```text
This line is deliberately very long so it wraps inside the code block: 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789
https://example.com/a/very/long/url/that/keeps/going/and/going/without/any/spaces/to/break/on/so/it/has/to/wrap/somewhere/0123456789
```

## Things that look like Markdown inside code

```markdown
# Not a heading
- not a list
| not | a | table |
|---|---|---|
---
> not a quote
```

## Indented fence

   ```
   Fence indented by three spaces still counts.
   ```

## No language

```
plain code block
    with indentation preserved
```

Text after the last code block. If this line looks like code, a fence wasn't closed.
