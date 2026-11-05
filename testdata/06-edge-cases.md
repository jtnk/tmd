# Edge cases

[← Back to the index](quickstart.md)

## Unicode

Accents: café, naïve, Ångström, Øresund, Straße, ﬁ ligature.

Emoji: 🚀 ✅ ❌ 🧪 👩‍💻 🏳️‍🌈 👍🏽 (some are multi-codepoint sequences)

Chinese: 你好，世界。这是一个用于测试换行的较长句子，看看中文在窗口变窄时如何换行。

Japanese: こんにちは世界。カタカナ、ひらがな、漢字が混ざった文章です。

Korean: 안녕하세요 세계

Right-to-left: مرحبا بالعالم — שלום עולם

Math-ish: ∑ ∫ √ ∞ ≠ ≤ ≥ → ← ↔ ×

**Bold emoji 🚀** and *italic CJK 你好* and `code 漢字`.

## Unclosed and stray markers

This has an **unclosed bold marker.

This has an *unclosed italic marker.

This has an unclosed `code span.

A lone [bracket and a lone ( parenthesis.

Stars in the middle of words: un*frigging*believable, and snake_case_name.

## Unsupported syntax (should show as plain text, not break anything)

~~Strikethrough~~ isn't styled.

![An image](image.png): the image itself won't show.

Setext heading
==============

Another setext heading
----------------------

<div>Raw HTML</div> is shown as text.

Footnote reference[^1].

[^1]: Footnote text.

## Very long word

Supercalifragilisticexpialidocious_and_then_some_more_characters_without_any_spaces_at_all_0123456789_abcdefghijklmnopqrstuvwxyz

## Whitespace

Line with trailing spaces   
Tabs	between	words	here.



Three blank lines above this one (Tidy, ⇧⌘T in the editor, collapses them to one).

## Rules in every style

---

***

___

- - -

## End of file without a trailing newline
Last line.