#!/usr/bin/env python3
"""A performance review of tmd, written by a small model on top of facts it can't get wrong.

The split is the point. This script runs the benchmark, takes medians, compares against the baseline
and decides pass or fail. The model only reads those results and suggests what they mean, and every
finding has to cite facts by id. The report prints the real values next to each finding, and rejects
findings that cite a fact that doesn't exist or a number that isn't in the data.

    perf/review.py --dry-run          # benchmark and report, without calling a model
    perf/review.py                    # the same, with the model's analysis
    perf/review.py --save-baseline    # make this run the baseline to compare against

Build first with `zig build --release=small`. Calling a model needs `pip install anthropic`, and
credentials from ANTHROPIC_API_KEY or `ant auth login`.
"""
import argparse
import json
import platform
import re
import statistics
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import List, Literal

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "zig-out/bin/tmd"
BASELINE = ROOT / "perf/baseline.json"
REPORTS = ROOT / "perf/reports"
DOCS = {"large": ROOT / "testdata/perf/large.md", "huge": ROOT / "testdata/perf/huge.md"}

MODEL = "claude-haiku-5-5"
BUDGET_MS = 16.7  # 60 fps

# A change counts as a regression only past both limits. Frames take a fraction of a millisecond, so
# a percentage alone would flag noise.
REGRESSION_PCT = 20.0
REGRESSION_MS = 0.05
BYTES_PCT = 10.0
SIZE_PCT = 2.0

SYSTEM = """You review performance results for tmd, a terminal Markdown viewer written in Zig.

You are given measured facts, each with an id, and notes on how the program works. The pass or fail
verdict has already been decided. Your job is to explain what the results mean and what to look at
next.

Rules:
- Every finding must cite the ids of the facts it rests on, in `evidence`.
- Use only numbers that appear in the facts. Don't calculate new ones. If a comparison matters, cite
  both facts and describe the direction in words.
- `likely_cause` is a hypothesis. Word it as one, and base it on the notes.
- Report at most five findings, most important first. Fewer is better. If nothing needs attention,
  return an empty list.
- Don't report a scenario merely for being fast."""


def scenario_key(name):
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


def run_bench(path):
    # Exit 1 only means a scenario missed 60 fps, which is a result, not a failure.
    out = subprocess.run([str(BINARY), "--bench", str(path), "--json"], capture_output=True, text=True, cwd=ROOT)
    if not out.stdout.strip():
        sys.exit(f"benchmark produced no output: {out.stderr.strip()}")
    return json.loads(out.stdout)


def collect(runs):
    """Median metrics over several benchmark passes, plus how much p99 moved between them."""
    facts = {}
    for doc, path in DOCS.items():
        passes = [run_bench(path) for _ in range(runs)]
        facts[f"{doc}.bytes"] = passes[0]["bytes"]
        facts[f"{doc}.rows"] = passes[0]["rows"]
        facts[f"{doc}.first_frame_ms"] = round(statistics.median(p["first_frame_ms"] for p in passes), 3)
        for i, s in enumerate(passes[0]["scenarios"]):
            key = f"{doc}.{scenario_key(s['name'])}"
            same = [p["scenarios"][i] for p in passes]
            for metric in ("p50_ms", "p95_ms", "p99_ms", "max_ms", "bytes_per_frame", "best_fps"):
                facts[f"{key}.{metric}"] = statistics.median(x[metric] for x in same)
            p99s = [x["p99_ms"] for x in same]
            facts[f"{key}.p99_spread_ms"] = round(max(p99s) - min(p99s), 3)
    facts["binary.bytes"] = BINARY.stat().st_size
    return facts


def machine():
    return f"{platform.system()} {platform.machine()}"


def compare(facts, baseline):
    """The regressions and improvements against a baseline, as (id, old, new, percent) tuples."""
    worse, better = [], []
    for key, new in facts.items():
        old = baseline.get(key)
        if old is None or old == 0 or key.endswith("p99_spread_ms") or key.endswith(".rows"):
            continue
        pct = (new - old) / old * 100
        if key.endswith("_ms"):
            if not (key.endswith(".p99_ms") or key.endswith(".first_frame_ms")):
                continue
            spread = facts.get(key.replace(".p99_ms", ".p99_spread_ms"), 0)
            moved = abs(new - old) > max(REGRESSION_MS, spread) and abs(pct) > REGRESSION_PCT
        elif key.endswith("bytes_per_frame"):
            moved = abs(pct) > BYTES_PCT
        elif key == "binary.bytes":
            moved = abs(pct) > SIZE_PCT
        elif key.endswith("best_fps"):
            # A lower target met is worse, unlike everything else here. A p99 sitting on a target's
            # budget flips between two targets on noise, so the p99 has to have really moved.
            p99 = key.replace(".best_fps", ".p99_ms")
            noise = max(REGRESSION_MS, facts.get(key.replace(".best_fps", ".p99_spread_ms"), 0))
            if new != old and abs(facts.get(p99, 0) - baseline.get(p99, 0)) > noise:
                (worse if new < old else better).append((key, old, new, round(pct, 1)))
            continue
        else:
            continue
        if moved:
            (worse if pct > 0 else better).append((key, old, new, round(pct, 1)))
    return worse, better


def misses(facts):
    return [k for k, v in facts.items() if k.endswith(".p99_ms") and v > BUDGET_MS]


def facts_text(facts, baseline):
    lines = []
    for key, value in facts.items():
        line = f"{key} = {value}"
        if baseline and key in baseline:
            line += f" (baseline {baseline[key]})"
        lines.append(line)
    return "\n".join(lines)


def prompt(facts, baseline, worse, better, miss):
    notes = (ROOT / "perf/notes.md").read_text()
    moved = "\n".join(f"{k}: {old} -> {new}" for k, old, new, _ in worse) or "none"
    gained = "\n".join(f"{k}: {old} -> {new}" for k, old, new, _ in better) or "none"
    return (
        f"<notes>\n{notes}</notes>\n\n<facts>\n{facts_text(facts, baseline)}\n</facts>\n\n"
        f"<regressions>\n{moved}\n</regressions>\n\n<improvements>\n{gained}\n</improvements>\n\n"
        f"<over_60fps_budget>\n{chr(10).join(miss) or 'none'}\n</over_60fps_budget>"
    )


def numbers_in(text):
    return re.findall(r"(?<![\w.])\d+(?:\.\d+)?(?![\w])", text)


def check_finding(finding, facts):
    """Why a finding can't be trusted, or None. Numbers must come from the facts it could cite."""
    if not finding["evidence"]:
        return "cites no facts"
    unknown = [e for e in finding["evidence"] if e not in facts]
    if unknown:
        return f"cites unknown facts: {', '.join(unknown)}"
    known = {str(v) for v in facts.values()} | {f"{float(v):g}" for v in facts.values()}
    # 60 and the other targets appear in the notes as names, not measurements.
    known |= {"60", "1000", "120", "240", "480", "540", "600", "720"}
    prose = " ".join((finding["title"], finding["likely_cause"], finding["next_step"]))
    made_up = [n for n in numbers_in(prose) if n not in known and f"{float(n):g}" not in known]
    if made_up:
        return f"uses numbers not in the data: {', '.join(made_up)}"
    return None


def ask_model(model, user):
    try:
        import anthropic
        from pydantic import BaseModel
    except ImportError:
        sys.exit("calling a model needs `pip install anthropic` (or use --dry-run)")

    class Finding(BaseModel):
        title: str
        severity: Literal["high", "medium", "low"]
        scenario: str
        evidence: List[str]
        likely_cause: str
        next_step: str

    class Review(BaseModel):
        summary: str
        findings: List[Finding]

    client = anthropic.Anthropic()
    try:
        response = client.messages.parse(
            model=model,
            max_tokens=16000,
            system=SYSTEM,
            messages=[{"role": "user", "content": user}],
            output_format=Review,
        )
    except anthropic.AuthenticationError:
        sys.exit("no valid credentials: set ANTHROPIC_API_KEY, or use --dry-run")
    except anthropic.NotFoundError:
        sys.exit(f"unknown model: {model}")
    except anthropic.RateLimitError:
        sys.exit("rate limited: try again shortly")
    except anthropic.APIStatusError as e:
        sys.exit(f"API error {e.status_code}: {e.message}")
    except anthropic.APIConnectionError:
        sys.exit("could not reach the API")

    if response.stop_reason in ("refusal", "max_tokens"):
        sys.exit(f"the model stopped early: {response.stop_reason}")
    return response.parsed_output.model_dump(), response.usage


def table(facts):
    rows = ["| Document | Scenario | p50 ms | p99 ms | Max ms | Bytes/frame | Best fps |", "|---|---|--:|--:|--:|--:|--:|"]
    for key in facts:
        if key.endswith(".p99_ms"):
            base = key[: -len(".p99_ms")]
            doc, name = base.split(".", 1)
            rows.append(
                f"| {doc} | {name.replace('_', ' ')} | {facts[base + '.p50_ms']:.2f} | {facts[key]:.2f} | "
                f"{facts[base + '.max_ms']:.2f} | {facts[base + '.bytes_per_frame']:.0f} | {facts[base + '.best_fps']:.0f} |"
            )
    return "\n".join(rows)


def changes(items):
    return "\n".join(f"- `{k}`: {old} to {new} ({pct:+.1f}%)" for k, old, new, pct in items)


def report(facts, baseline_doc, worse, better, miss, review, model, usage):
    baseline = baseline_doc["facts"] if baseline_doc else None
    out = [f"# Performance review, {datetime.now():%Y-%m-%d %H:%M}", ""]
    if not baseline:
        verdict = "**No baseline.** Run `perf/review.py --save-baseline` to start comparing."
    elif worse:
        verdict = f"**{len(worse)} regression{'s' if len(worse) != 1 else ''}** against the baseline."
    else:
        verdict = "**No regressions** against the baseline."
    out += [verdict, "", f"Binary: {facts['binary.bytes']:,} bytes. Machine: {machine()}.", ""]
    if baseline_doc and baseline_doc.get("machine") != machine():
        out += [f"> The baseline came from {baseline_doc.get('machine')}, so timings aren't comparable.", ""]
    if miss:
        out += ["Over the 60 fps budget: " + ", ".join(f"`{m}`" for m in miss), ""]
    out += ["## Results", "", table(facts), ""]
    if worse:
        out += ["## Regressions", "", changes(worse), ""]
    if better:
        out += ["## Improvements", "", changes(better), ""]

    if review:
        out += [f"## Analysis by {model}", "", "Numbers below are measured. The explanations are the model's.", "", review["summary"], ""]
        rejected = []
        for f in review["findings"]:
            problem = check_finding(f, facts)
            if problem:
                rejected.append((f["title"], problem))
                continue
            out += [f"### {f['title']}", "", f"Severity: {f['severity']}. Scenario: {f['scenario']}.", ""]
            out += [f"- `{e}` = {facts[e]}" for e in f["evidence"]]
            out += ["", f"**Likely cause:** {f['likely_cause']}", "", f"**Next step:** {f['next_step']}", ""]
        if rejected:
            out += ["### Rejected findings", "", "These failed verification and were left out:", ""]
            out += [f"- {title}: {why}" for title, why in rejected]
            out += [""]
        if usage:
            out += [f"Tokens: {usage.input_tokens} in, {usage.output_tokens} out.", ""]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description="Benchmark tmd and review the results.")
    ap.add_argument("--dry-run", action="store_true", help="no model: write the report, and print the prompt it would get")
    ap.add_argument("--save-baseline", action="store_true", help="save this run as the baseline")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--runs", type=int, default=3, help="benchmark passes to take the median of")
    args = ap.parse_args()

    if not BINARY.exists():
        sys.exit("build first: zig build --release=small")
    if not all(p.exists() for p in DOCS.values()):
        subprocess.run([sys.executable, str(ROOT / "testdata/perf/generate.py")], check=True, cwd=ROOT / "testdata/perf")

    facts = collect(args.runs)
    if args.save_baseline:
        BASELINE.write_text(json.dumps({"machine": machine(), "facts": facts}, indent=1) + "\n")
        print(f"baseline saved: {BASELINE.relative_to(ROOT)}")
        return

    baseline_doc = json.loads(BASELINE.read_text()) if BASELINE.exists() else None
    baseline = baseline_doc["facts"] if baseline_doc else None
    worse, better = compare(facts, baseline) if baseline else ([], [])
    miss = misses(facts)
    user = prompt(facts, baseline, worse, better, miss)

    review = usage = None
    if args.dry_run:
        print(f"{SYSTEM}\n\n{user}\n")
    else:
        review, usage = ask_model(args.model, user)

    REPORTS.mkdir(exist_ok=True)
    path = REPORTS / f"{datetime.now():%Y-%m-%d-%H%M}.md"
    path.write_text(report(facts, baseline_doc, worse, better, miss, review, args.model, usage))
    print(f"report: {path.relative_to(ROOT)}")
    # Regressions fail the run. Known misses that are in the baseline don't.
    sys.exit(1 if worse else 0)


if __name__ == "__main__":
    main()
