"""Deterministic final-answer grader for LiveMathBench tasks.

Runs inside the separate verifier container with the task's spec.json and the
agent's submitted /app/answer.txt (a declared Harbor artifact). Python 3.9+,
stdlib only; no LLM judge and no network.

The submitted answer is the last \\boxed{...} in answer.txt, else its last
non-empty line. Both it and the gold answer are normalised (math delimiters,
\\left/\\right, spacing commands, \\text{}, \\dfrac, degree and percent signs,
a leading "x =" when the gold has none). They match when any of these holds:

1. the normalised strings are equal;
2. both evaluate to real numbers within a relative tolerance of 1e-6 (numbers,
   + - * / ^, \\frac, \\sqrt, \\sqrt[n], \\pi, \\cdot, \\times, implicit
   products such as 2\\sqrt{3});
3. both are comma-separated lists of equal length whose items match
   pairwise by rules 1-2: in order for a gold tuple/interval in ( ) or [ ],
   in any order for a set or a bare list;
4. the gold is a choice letter (A-E, or a set such as "AC") and the answer
   names the same letters.

Reward 1 iff they match. This is stricter than the LLM judge the
LiveMathBench authors use (GPassK): an equivalent answer written in a form
these rules cannot reduce (for instance an unsimplified symbolic expression)
scores 0. grade.json records both normal forms so such cases can be audited.

Usage:
  math_grader.py --spec spec.json --answer answer.txt --reward reward.txt [--details grade.json]

spec.json: {"answer": str, "question_type": str}
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional, Tuple

MAX_ANSWER_CHARS = 4000
REL_TOL = 1e-6


def last_boxed(text: str) -> Optional[str]:
    start = text.rfind("\\boxed")
    if start < 0:
        start = text.rfind("\\fbox")
        if start < 0:
            return None
    brace = text.find("{", start)
    if brace < 0:
        return None
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : index]
    return None


def extract(text: str) -> Optional[str]:
    text = text[-MAX_ANSWER_CHARS:]
    boxed = last_boxed(text)
    if boxed is not None:
        return boxed
    lines = [line.strip() for line in text.strip().splitlines() if line.strip()]
    if not lines:
        return None
    line = lines[-1]
    line = re.sub(r"^(final answer|answer)\s*(is)?\s*[:：]?\s*", "", line, flags=re.IGNORECASE)
    return line


def _unwrap_command(text: str, command: str) -> str:
    """\\command{X} -> X for every occurrence (balanced braces)."""
    out = text
    while True:
        index = out.find("\\" + command + "{")
        if index < 0:
            return out
        brace = index + len(command) + 1
        depth = 0
        for end in range(brace, len(out)):
            if out[end] == "{":
                depth += 1
            elif out[end] == "}":
                depth -= 1
                if depth == 0:
                    out = out[:index] + out[brace + 1 : end] + out[end + 1 :]
                    break
        else:
            return out


def normalize(text: str, *, drop_assignment: bool = True) -> str:
    s = text.strip()
    s = s.replace("\\$", "").replace("$", "")
    for delim in ("\\(", "\\)", "\\[", "\\]"):
        s = s.replace(delim, "")
    for command in ("text", "textbf", "mathrm", "mathbf", "mbox", "operatorname", "boxed"):
        s = _unwrap_command(s, command)
    s = s.replace("\\dfrac", "\\frac").replace("\\tfrac", "\\frac")
    s = s.replace("\\displaystyle", "").replace("\\left", "").replace("\\right", "")
    for spacing in ("\\!", "\\,", "\\;", "\\:", "\\quad", "\\qquad", "\\ ", "~"):
        s = s.replace(spacing, "")
    s = re.sub(r"\^\s*\{\s*\\circ\s*\}|\^\s*\\circ|°|\\degree", "", s)
    s = s.replace("\\%", "").replace("%", "")
    s = re.sub(r"\\(?:leqslant|leqq|leq|le)(?![A-Za-z])", r"\\leq", s)
    s = re.sub(r"\\(?:geqslant|geqq|geq|ge)(?![A-Za-z])", r"\\geq", s)
    s = re.sub(r"\s+", "", s)
    s = s.rstrip(".。")
    if drop_assignment:
        match = re.match(r"^[A-Za-z](?:_\{?\w+\}?)?(?:\([A-Za-z]\))?=(.+)$", s)
        if match and "=" not in match.group(1):
            s = match.group(1)
    return s.lower()


# --- numeric evaluation ------------------------------------------------------

_TOKEN = re.compile(r"\d+\.\d*|\.\d+|\d+|\\[A-Za-z]+|[+\-*/^(){}\[\]]")


class _Parser:
    def __init__(self, text: str) -> None:
        cleaned = text.replace("\\cdot", "*").replace("\\times", "*").replace("\\div", "/")
        pos = 0
        self.tokens: List[str] = []
        for match in _TOKEN.finditer(cleaned):
            if cleaned[pos : match.start()].strip():
                raise ValueError("unparsed text")
            self.tokens.append(match.group(0))
            pos = match.end()
        if cleaned[pos:].strip():
            raise ValueError("unparsed text")
        self.index = 0

    def peek(self) -> Optional[str]:
        return self.tokens[self.index] if self.index < len(self.tokens) else None

    def take(self, expected: Optional[str] = None) -> str:
        token = self.peek()
        if token is None or (expected is not None and token != expected):
            raise ValueError("unexpected token")
        self.index += 1
        return token

    def parse(self) -> float:
        value = self.expr()
        if self.peek() is not None:
            raise ValueError("trailing tokens")
        return value

    def expr(self) -> float:
        value = self.term()
        while self.peek() in ("+", "-"):
            if self.take() == "+":
                value += self.term()
            else:
                value -= self.term()
        return value

    def term(self) -> float:
        value = self.unary()
        while True:
            token = self.peek()
            if token == "*":
                self.take()
                value *= self.unary()
            elif token == "/":
                self.take()
                value /= self.unary()
            elif token is not None and (token in ("(", "{") or token[0].isdigit() or token[0] == "." or token.startswith("\\")):
                value *= self.unary()  # implicit product: 2\pi, 3\sqrt{2}, (a)(b)
            else:
                return value

    def unary(self) -> float:
        if self.peek() == "-":
            self.take()
            return -self.unary()
        if self.peek() == "+":
            self.take()
            return self.unary()
        return self.power()

    def power(self) -> float:
        base = self.atom()
        if self.peek() == "^":
            self.take()
            exponent = self.unary() if self.peek() not in ("{", "(") else self.atom()
            return float(base ** exponent)
        return base

    def group(self) -> float:
        opener = self.take()
        closer = {"{": "}", "(": ")", "[": "]"}[opener]
        value = self.expr()
        self.take(closer)
        return value

    def atom(self) -> float:
        token = self.peek()
        if token is None:
            raise ValueError("unexpected end")
        if token in ("{", "("):
            return self.group()
        if token[0].isdigit() or token[0] == ".":
            self.take()
            return float(token)
        if token == "\\frac":
            self.take()
            numerator = self.group()
            denominator = self.group()
            return numerator / denominator
        if token == "\\sqrt":
            self.take()
            degree = 2.0
            if self.peek() == "[":
                degree = self.group()
            radicand = self.group() if self.peek() in ("{", "(") else self.atom()
            if radicand < 0:
                raise ValueError("complex root")
            return radicand ** (1.0 / degree)
        if token == "\\pi":
            self.take()
            return math.pi
        raise ValueError("unsupported token %s" % token)


def evaluate(text: str) -> Optional[float]:
    try:
        value = _Parser(text).parse()
    except (ValueError, ZeroDivisionError, OverflowError, TypeError):
        return None
    if isinstance(value, complex) or math.isnan(value) or math.isinf(value):
        return None
    return value


def _numbers_match(a: float, b: float) -> bool:
    return abs(a - b) <= REL_TOL * max(1.0, abs(b))


def _split_top_level(text: str) -> List[str]:
    parts: List[str] = []
    depth = 0
    current = ""
    for ch in text:
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    parts.append(current)
    return parts


def _strip_brackets(text: str) -> str:
    for opener, closer in (("\\{", "\\}"), ("(", ")"), ("[", "]"), ("{", "}")):
        if text.startswith(opener) and text.endswith(closer):
            inner = text[len(opener) : len(text) - len(closer)]
            if _balanced(inner):
                return inner
    return text


def _balanced(text: str) -> bool:
    depth = 0
    for ch in text:
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def _atom_match(pred: str, gold: str) -> bool:
    if pred == gold:
        return True
    a = evaluate(pred)
    b = evaluate(gold)
    return a is not None and b is not None and _numbers_match(a, b)


_CHOICE = re.compile(r"^\(?([a-e](?:[,、]?[a-e])*)\)?$")


def _choices(text: str) -> Optional[str]:
    match = _CHOICE.match(text)
    if not match:
        return None
    return "".join(sorted(set(re.sub(r"[,、]", "", match.group(1)))))


def equivalent(prediction: str, gold: str) -> bool:
    keep_assignment = "=" in normalize(gold, drop_assignment=False)
    p = normalize(prediction, drop_assignment=not keep_assignment)
    g = normalize(gold, drop_assignment=not keep_assignment)
    if not p:
        return False
    if _atom_match(p, g):
        return True
    gold_choice = _choices(g)
    if gold_choice is not None:
        pred_choice = _choices(re.sub(r"[.:：]$", "", p)) or _choices(p[:1] if p[1:2] in (")", ".", ":") else "")
        return pred_choice == gold_choice
    g_items = [item for item in _split_top_level(_strip_brackets(g))]
    p_items = [item for item in _split_top_level(_strip_brackets(p))]
    if len(g_items) > 1 and len(g_items) == len(p_items):
        if all(_atom_match(a, b) for a, b in zip(p_items, g_items)):
            return True
        if g.startswith(("(", "[")):
            return False  # tuples, points and intervals are ordered
        remaining = list(g_items)
        for item in p_items:
            for index, candidate in enumerate(remaining):
                if _atom_match(item, candidate):
                    del remaining[index]
                    break
            else:
                return False
        return True
    return False


def grade(spec_path: Path, answer_path: Path) -> Tuple[int, Dict[str, object]]:
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    gold = spec["answer"]
    try:
        text = answer_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 0, {"error": "no answer was submitted", "gold": gold}
    answer = extract(text)
    if answer is None:
        return 0, {"error": "the answer file is empty", "gold": gold}
    match = equivalent(answer, gold)
    return (1 if match else 0), {
        "answer": answer,
        "gold": gold,
        "normalized_answer": normalize(answer),
        "normalized_gold": normalize(gold),
        "match": match,
    }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--answer", type=Path, required=True)
    parser.add_argument("--reward", type=Path, required=True)
    parser.add_argument("--details", type=Path)
    args = parser.parse_args(argv)
    reward, details = grade(args.spec, args.answer)
    args.reward.parent.mkdir(parents=True, exist_ok=True)
    args.reward.write_text("%d\n" % reward, encoding="utf-8")
    if args.details:
        args.details.write_text(json.dumps(details, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    print("reward=%d" % reward)
    return 0


if __name__ == "__main__":
    sys.exit(main())
