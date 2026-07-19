#!/usr/bin/env python3
"""Narrow scanner for the reproduction sources and its generated artifacts."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Pattern


FAKE_SENTINEL = "FAKE_SYNTHETIC_DO_NOT_USE_"


@dataclass(frozen=True)
class Rule:
    identifier: str
    pattern: Pattern[str]
    fake_sentinel_allowed: bool = True


SOURCE_RULES = (
    Rule("provider-key", re.compile(r"\bsk-[A-Za-z0-9_-]{16,}")),
    Rule("jwt-literal", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\b")),
    Rule("bearer-literal", re.compile(r"Bearer\s+(?!\[REDACTED\])[A-Za-z0-9._~-]{12,}")),
    Rule("private-key", re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"), fake_sentinel_allowed=False),
)

ARTIFACT_RULES = SOURCE_RULES + (
    Rule("synthetic-canary-leak", re.compile(re.escape(FAKE_SENTINEL)), fake_sentinel_allowed=False),
    Rule("callback-query", re.compile(r"[?&](?:code|state)=[^&\s]+"), fake_sentinel_allowed=False),
    Rule("token-json", re.compile(r'"(?:access_token|refresh_token|id_token)"\s*:'), fake_sentinel_allowed=False),
)


def findings_for_text(text: str, rules: Iterable[Rule]) -> List[str]:
    findings = []
    for rule in rules:
        for line in text.splitlines():
            if rule.pattern.search(line):
                if rule.fake_sentinel_allowed and FAKE_SENTINEL in line:
                    continue
                findings.append(rule.identifier)
                break
    return findings


def _files_under(path: Path) -> Iterable[Path]:
    if path.is_file():
        yield path
        return
    for candidate in sorted(path.rglob("*")):
        if candidate.is_file() and "__pycache__" not in candidate.parts:
            yield candidate


def scan(path: Path, rules: Iterable[Rule]) -> List[str]:
    findings = []
    for candidate in _files_under(path):
        try:
            text = candidate.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for identifier in findings_for_text(text, rules):
            findings.append(f"{candidate}:{identifier}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", action="append", default=[], type=Path)
    parser.add_argument("--artifact", action="append", default=[], type=Path)
    args = parser.parse_args()

    findings = []
    for path in args.source:
        findings.extend(scan(path, SOURCE_RULES))
    for path in args.artifact:
        findings.extend(scan(path, ARTIFACT_RULES))

    if findings:
        print("SECRET_SCAN: FAIL")
        for finding in findings:
            print(f"finding={finding}")
        return 1
    print("SECRET_SCAN: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
