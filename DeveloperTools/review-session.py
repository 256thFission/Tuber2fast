#!/usr/bin/env python3
"""Validate and render the human-facing part of a structured review queue."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


INTERNAL_TERMS = (
    "owner token",
    "thread id",
    "feedbackthreadid",
    "sequence cursor",
    "queue state",
    "awaiting-model",
    "event-log",
    "artifact path",
    "planned key",
)
EXACT_ANSWER = re.compile(r"\b(?:answer|reply|send|type)\s+[‘'\"]|\bexact(?:ly)?\b", re.I)
VERDICT = re.compile(r"\bpass(?:/fail| or fail)?\b|\bfirst failure\b", re.I)


class ValidationError(ValueError):
    pass


def load_queue(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def validate(queue: dict) -> None:
    errors: list[str] = []
    if queue.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    if not isinstance(queue.get("title"), str) or not queue["title"].strip():
        errors.append("title must be a non-empty string")
    steps = queue.get("steps")
    if not isinstance(steps, list) or not steps:
        errors.append("steps must be a non-empty list")
        steps = []

    seen: set[str] = set()
    for index, step in enumerate(steps, start=1):
        where = f"step {index}"
        if not isinstance(step, dict):
            errors.append(f"{where} must be an object")
            continue
        step_id = step.get("id")
        if not isinstance(step_id, str) or not step_id.strip():
            errors.append(f"{where}.id must be a non-empty string")
        elif step_id in seen:
            errors.append(f"duplicate step id: {step_id}")
        else:
            seen.add(step_id)
            where = step_id

        for field in ("title", "human_instruction", "human_question"):
            value = step.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{where}.{field} must be a non-empty string")

        for field in ("preconditions", "agent_assertions"):
            value = step.get(field)
            if not isinstance(value, list) or not value or not all(
                isinstance(item, str) and item.strip() for item in value
            ):
                errors.append(f"{where}.{field} must be a non-empty string list")

        human_copy = " ".join(
            str(step.get(field, "")) for field in ("title", "human_instruction", "human_question")
        )
        lowered = human_copy.casefold()
        for term in INTERNAL_TERMS:
            if term in lowered:
                errors.append(f"{where} exposes internal term {term!r}")
        if EXACT_ANSWER.search(human_copy) and VERDICT.search(human_copy):
            errors.append(f"{where} combines an exact-answer instruction with a PASS verdict")

    if errors:
        raise ValidationError("\n".join(errors))


def render(queue: dict, step_id: str) -> str:
    validate(queue)
    for index, step in enumerate(queue["steps"], start=1):
        if step["id"] == step_id:
            return (
                f"Step {index} of {len(queue['steps'])} — {step['title']}\n\n"
                f"{step['human_instruction']}\n\n{step['human_question']}"
            )
    raise ValidationError(f"unknown step id: {step_id}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("queue", type=Path)
    parser.add_argument("--step", help="render one human-facing step")
    args = parser.parse_args()
    try:
        queue = load_queue(args.queue)
        if args.step:
            print(render(queue, args.step))
        else:
            validate(queue)
            print(f"valid: {len(queue['steps'])} steps")
    except (OSError, json.JSONDecodeError, ValidationError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
