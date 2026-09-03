#!/usr/bin/env python3
"""Mutation testing for Folio.

Line coverage says a line ran; it does not say a test would have noticed if the
line were wrong. This deliberately breaks the source one edit at a time and
re-runs the suite. A mutant that survives is a change no test objects to, which
is a hole in the suite (or dead code).

Off-the-shelf Swift mutation tools drive `xcodebuild` or `swift test`, neither
of which exists on this machine (see Scripts/test.sh), so the harness is here.

Usage:
    Scripts/mutation-test.py [--jobs N] [--limit N] [--file PATH ...]
"""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Scoped to the code the suite actually targets. Mutating the SwiftUI views
# would only report that untested UI is untested, which is already known and
# would drag the score around without saying anything useful.
DEFAULT_TARGETS = [
    "Sources/Folio/Model/Conversion.swift",
    "Sources/Folio/Model/PDFExtractor.swift",
    "Sources/Folio/Model/OffscreenRenderer.swift",
    "Sources/Folio/Support/DocKind.swift",
]

TIMEOUT_SECONDS = 180


# ── Swift scanning ────────────────────────────────────────────────────────────

def code_mask(text: str) -> list[bool]:
    """True at every offset that is real code, False inside strings/comments.

    Mutating a comment produces a mutant no test could ever kill, which would
    silently deflate the score; mutating a string literal mostly produces the
    same. Both are excluded.
    """
    mask = [True] * len(text)
    i, n = 0, len(text)
    depth = 0  # block-comment nesting; Swift allows it

    while i < n:
        if depth:
            if text.startswith("/*", i):
                depth += 1
                mask[i:i + 2] = [False, False]
                i += 2
            elif text.startswith("*/", i):
                depth -= 1
                mask[i:i + 2] = [False, False]
                i += 2
            else:
                mask[i] = False
                i += 1
            continue

        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                mask[i] = False
                i += 1
            continue

        if text.startswith("/*", i):
            depth = 1
            mask[i:i + 2] = [False, False]
            i += 2
            continue

        # Raw strings: #"..."#, ##"..."##, and their multiline forms.
        raw = re.match(r'(#+)("""|")', text[i:])
        if raw:
            hashes, quote = raw.group(1), raw.group(2)
            close = quote + hashes
            end = text.find(close, i + len(hashes) + len(quote))
            end = n if end == -1 else end + len(close)
            for j in range(i, end):
                mask[j] = False
            i = end
            continue

        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end == -1 else end + 3
            for j in range(i, end):
                mask[j] = False
            i = end
            continue

        if text[i] == '"':
            mask[i] = False
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    mask[i] = False
                    i += 1
                if i < n:
                    mask[i] = False
                    i += 1
            if i < n:
                mask[i] = False
                i += 1
            continue

        i += 1

    return mask


# ── Mutation operators ────────────────────────────────────────────────────────

@dataclass
class Mutant:
    path: str
    offset: int
    line: int
    operator: str
    before: str
    after: str
    snippet: str

    @property
    def label(self) -> str:
        return f"{self.path}:{self.line} [{self.operator}] {self.before!r} -> {self.after!r}"


# Operators are surrounded by spaces on purpose: it keeps `a < b` in scope while
# leaving `Set<String>` and `Array<Int>` alone, which would only ever be
# stillborn.
SPACED = {
    " <= ": [" < "], " >= ": [" > "], " < ": [" >= "], " > ": [" <= "],
    " == ": [" != "], " != ": [" == "],
    " && ": [" || "], " || ": [" && "],
    " + ": [" - "], " - ": [" + "], " * ": [" / "], " / ": [" * "],
}

# Off-by-one at a boundary is the classic bug these catch.
RANGES = {"..<": ["..."], "...": ["..<"]}

WORDS = {"true": ["false"], "false": ["true"]}


def find_mutants(path: str) -> list[Mutant]:
    text = (ROOT / path).read_text()
    mask = code_mask(text)
    line_of = []
    line = 1
    for ch in text:
        line_of.append(line)
        if ch == "\n":
            line += 1

    found: list[Mutant] = []

    def add(offset, before, after, operator):
        if not all(mask[offset:offset + len(before)]):
            return
        start = text.rfind("\n", 0, offset) + 1
        end = text.find("\n", offset)
        snippet = text[start:end if end != -1 else len(text)].strip()
        found.append(Mutant(path, offset, line_of[offset], operator, before, after, snippet))

    # Longest first so " <= " is not shadowed by " < ".
    for before in sorted(SPACED, key=len, reverse=True):
        for match in re.finditer(re.escape(before), text):
            if any(m.offset <= match.start() < m.offset + len(m.before) for m in found):
                continue
            for after in SPACED[before]:
                add(match.start(), before, after, "operator")

    for before, afters in RANGES.items():
        for match in re.finditer(re.escape(before), text):
            for after in afters:
                add(match.start(), before, after, "range")

    for before, afters in WORDS.items():
        for match in re.finditer(rf"\b{before}\b", text):
            for after in afters:
                add(match.start(), before, after, "boolean")

    # Numeric literals, skipping the ones that are part of an identifier.
    for match in re.finditer(r"(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])", text):
        literal = match.group(1)
        replacement = "1" if literal.rstrip("0").rstrip(".") in ("", "0") else "0"
        add(match.start(), literal, replacement, "literal")

    return found


# ── Running ───────────────────────────────────────────────────────────────────

def package_env() -> dict:
    env = dict(os.environ)
    if shutil.which("xcrun") and subprocess.run(
        ["xcrun", "--find", "xctest"], capture_output=True
    ).returncode != 0:
        for candidate in sorted(Path("/Applications").glob("Xcode*.app")):
            developer = candidate / "Contents/Developer"
            if developer.is_dir():
                env["DEVELOPER_DIR"] = str(developer)
                break
    # The renderer's assets are read-only here, so every mutant can share the
    # originals instead of copying 4 MB of vendored JavaScript each time.
    env["FOLIO_WEB_ROOT"] = str(ROOT / "Web")
    return env


ENV = None


def run_mutant(mutant) -> tuple[str, str]:
    """Returns (verdict, detail): killed / survived / stillborn / timeout."""
    global ENV
    if ENV is None:
        ENV = package_env()

    work = Path(tempfile.mkdtemp(prefix="folio-mutation-"))
    try:
        shutil.copytree(ROOT / "Sources", work / "Sources")
        shutil.copytree(ROOT / "Tests", work / "Tests")
        shutil.copy2(ROOT / "Package.swift", work / "Package.swift")

        if mutant is not None:
            target = work / mutant.path
            text = target.read_text()
            target.write_text(
                text[:mutant.offset] + mutant.after + text[mutant.offset + len(mutant.before):]
            )

        # Split so a mutant that will not compile is told apart from one the
        # tests caught. A mutant that cannot build is not a valid mutant and
        # must be excluded from the score rather than counted as killed.
        built = subprocess.run(
            ["swift", "build", "--build-tests"],
            cwd=work, capture_output=True, text=True, timeout=TIMEOUT_SECONDS, env=ENV,
        )
        if built.returncode != 0:
            tail = [ln for ln in built.stderr.splitlines() if "error:" in ln]
            return "stillborn", (tail[-1] if tail else "build failed")

        try:
            result = subprocess.run(
                ["swift", "test", "--skip-build"],
                cwd=work, capture_output=True, text=True, timeout=TIMEOUT_SECONDS, env=ENV,
            )
        except subprocess.TimeoutExpired:
            # A mutation that hangs the suite is still one the suite noticed.
            return "timeout", "test run exceeded the time limit"

        return ("survived", "") if result.returncode == 0 else ("killed", "")
    except subprocess.TimeoutExpired:
        return "timeout", "build exceeded the time limit"
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) - 2))
    parser.add_argument("--limit", type=int, default=0, help="sample at most N mutants")
    parser.add_argument("--file", action="append", dest="files", default=None)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--dry-run", action="store_true", help="list mutants and stop")
    args = parser.parse_args()

    targets = args.files or DEFAULT_TARGETS

    if args.dry_run:
        total = 0
        for path in targets:
            found = find_mutants(path)
            total += len(found)
            print(f"{len(found):>5}  {path}")
        print(f"{total:>5}  TOTAL")
        return 0

    print("==> Verifying the suite is green before mutating")
    verdict, detail = run_mutant(None)
    if verdict != "survived":
        print(f"    baseline is not green ({verdict}) {detail}")
        return 2
    print("    baseline OK\n")

    mutants: list[Mutant] = []
    for path in targets:
        mutants.extend(find_mutants(path))

    if args.limit and len(mutants) > args.limit:
        random.Random(args.seed).shuffle(mutants)
        mutants = mutants[:args.limit]
    mutants.sort(key=lambda m: (m.path, m.line))

    print(f"==> {len(mutants)} mutants across {len(targets)} files, {args.jobs} jobs")
    started = time.time()
    results: dict[str, list] = {"killed": [], "survived": [], "stillborn": [], "timeout": []}
    done = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_mutant, m): m for m in mutants}
        for future in concurrent.futures.as_completed(futures):
            mutant = futures[future]
            verdict, _ = future.result()
            results[verdict].append(mutant)
            done += 1
            mark = {"killed": "✓", "survived": "✗", "stillborn": "·", "timeout": "✓"}[verdict]
            print(f"  [{done:>3}/{len(mutants)}] {mark} {mutant.label}")

    killed = len(results["killed"]) + len(results["timeout"])
    survived = len(results["survived"])
    viable = killed + survived
    score = (killed / viable * 100) if viable else 0.0

    print("\n" + "─" * 72)
    print(f"mutants generated : {len(mutants)}")
    print(f"  not viable      : {len(results['stillborn'])}  (did not compile; excluded)")
    print(f"  viable          : {viable}")
    print(f"    killed        : {killed}")
    print(f"    survived      : {survived}")
    print(f"\nMUTATION SCORE    : {score:.1f}%  ({killed}/{viable})")

    if results["survived"]:
        print("\nSurvivors — changes no test objects to:")
        for mutant in sorted(results["survived"], key=lambda m: (m.path, m.line)):
            print(f"  {mutant.label}")
            print(f"      {mutant.snippet[:100]}")

    print(f"\nfinished in {time.time() - started:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
