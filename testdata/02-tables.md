# Tables

[← Back to the index](quickstart.md)

## Small table (fits on one line per row)

| Key | Action |
|---|---|
| E | Editor |
| Esc | Preview |
| ⌥⌘T | Performance HUD |

## Long cells that must wrap

| File | What's in it |
|---|---|
| 01-overview.md | Goals, scope, timeline, owners, open questions, decisions made so far, and links to everything else |
| 02-architecture.md | Modules, data flow, storage, caching, failure modes, security review notes, performance budget, tech debt |
| 03-landscape.md | Segmentation, ~30 comparable tools, 2024–26 release history, feature comparison table, strengths and gaps |
| 04-research.md | Interview notes, survey results, usage data, support tickets, recurring themes, conclusions |
| 05-plan.md | 12-week plan: milestones, staffing, risks and mitigations, launch checklist and success metrics |

## Alignment

| Left | Center | Right |
|:-----|:------:|------:|
| a | b | 1.00 |
| longer cell | centered | 22.50 |
| x | y | 1,234.56 |

## Inline formatting inside cells

| Feature | Syntax | Result |
|---|---|---|
| Bold | `**bold**` | **bold** |
| Italic | `*italic*` | *italic* |
| Code | `` `code` `` | `let x = 1` |
| Link | `[text](url)` | [example](https://example.com) |
| Escaped pipe | `a \| b` | a \| b |

## Many columns

| Q | Region | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec | Total |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | North America | 120 | 135 | 150 | 142 | 160 | 171 | 168 | 175 | 181 | 190 | 204 | 220 | 2,016 |
| 2 | Europe | 98 | 101 | 110 | 115 | 119 | 125 | 131 | 128 | 136 | 140 | 149 | 155 | 1,507 |
| 3 | Asia Pacific | 75 | 80 | 92 | 99 | 104 | 112 | 118 | 121 | 130 | 138 | 145 | 160 | 1,374 |

## Long text in a middle column

| Step | Description | Owner |
|---|---|---|
| 1 | Collect every requirement from the stakeholders, including the ones they forgot to mention until the second meeting, and write them down in one place | Alex |
| 2 | Prototype | Sam |
| 3 | Review the prototype with users, note what confuses them, and fix the top three problems before anything else | Jordan |

## Ragged rows (missing and extra cells)

| A | B | C |
|---|---|---|
| only one |
| one | two | three | four (extra, dropped) |
| | empty first cell | |

## Without outer pipes

Name | Value
---- | -----
alpha | 1
beta | 2

## Single column

| Just one column |
|---|
| row 1 |
| row 2 |

A paragraph right after a table, to check spacing.

| Header only |
|---|

Not a table (no delimiter row):

| a | b |
| c | d |
