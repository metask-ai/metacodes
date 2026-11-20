"""Deterministic EM/F1 grader for SearchQA answers.

Runs inside the separate verifier container with the task's spec.json and the
agent's submitted /app/answer.txt (a declared Harbor artifact). Python 3.9+,
stdlib only.

The first non-empty line of answer.txt is the answer; a Jeopardy!-style
"What is ...?" wrapper is removed. Scoring is the SQuAD/MRQA convention:
lowercase, drop punctuation, drop the
articles a/an/the, collapse whitespace; exact match (EM) and token-level F1,
each taken as the maximum over the gold aliases. Jeopardy answers (J! Archive)
put optional text in parentheses ("(Ken) Lay", "Victor Emmanuel (III)", "ado
(in Ecuador)") and mark alternates as "(or X)" or "(X accepted)". The aliases
are the answer as given (parenthetical text kept), the answer with every
parenthetical (or any one) removed, and each marked alternate; an unmarked
parenthetical is never an answer on its own.

Reward 1 iff EM = 1 against some alias. F1 is reported in grade.json but does
not award credit: Jeopardy answers are one to three tokens, where any F1 short
of 1 means a different answer.

Usage:
  qa_grader.py --spec spec.json --answer answer.txt --reward reward.txt [--details grade.json]

spec.json: {"answer": str}
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import string
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

MAX_ANSWER_CHARS = 1000
_ARTICLES = re.compile(r"\b(a|an|the)\b")
_PUNCT = set(string.punctuation)
_QUESTION_FORM = re.compile(r"^(?:what|who|where|when)\s+(?:is|are|was|were)\s+", re.IGNORECASE)


def normalize(text: str) -> str:
    text = text.lower()
    text = "".join(ch for ch in text if ch not in _PUNCT)
    text = _ARTICLES.sub(" ", text)
    return " ".join(text.split())


_PAREN = re.compile(r"\(([^()]*)\)")
_OR_ALTERNATE = re.compile(r"^\s*or\s+(.+?)\s*$", re.IGNORECASE)
_ACCEPTED_ALTERNATE = re.compile(r"^\s*(.+?)\s+(?:is\s+)?(?:also\s+)?accepted\s*$", re.IGNORECASE)


def aliases(answer: str) -> List[str]:
    # The answer as given (normalising drops the parentheses but keeps their
    # text: "(Edgar Allan) Poe" -> "edgar allan poe") and with every
    # parenthetical, or any one of them, left out ("Poe").
    out = [answer, _PAREN.sub(" ", answer)]
    for match in _PAREN.finditer(answer):
        out.append(answer[: match.start()] + " " + answer[match.end() :])
        # J! Archive marks alternates explicitly: "cocoa (or chocolate)",
        # "referred pain (referral accepted)". Any other parenthetical is
        # optional text, never an answer on its own ("(John) Adams" does not
        # accept "John", "Washington (state)" does not accept "state").
        inner = match.group(1)
        alternate = _OR_ALTERNATE.match(inner) or _ACCEPTED_ALTERNATE.match(inner)
        if alternate:
            out.append(alternate.group(1))
    seen: List[str] = []
    for item in out:
        norm = normalize(item)
        if norm and norm not in seen:
            seen.append(norm)
    return seen


def f1(prediction: str, gold: str) -> float:
    pred_tokens = prediction.split()
    gold_tokens = gold.split()
    common = collections.Counter(pred_tokens) & collections.Counter(gold_tokens)
    same = sum(common.values())
    if same == 0:
        return 0.0
    precision = same / len(pred_tokens)
    recall = same / len(gold_tokens)
    return 2 * precision * recall / (precision + recall)


def read_answer(path: Path) -> Optional[str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    lines = [line.strip() for line in text.strip().splitlines() if line.strip()]
    if not lines:
        return None
    # Jeopardy! habit: "What is X?" answers X.
    return _QUESTION_FORM.sub("", lines[0][:MAX_ANSWER_CHARS]).rstrip("?").strip()


def grade(spec_path: Path, answer_path: Path) -> Tuple[int, Dict[str, object]]:
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    golds = aliases(spec["answer"])
    answer = read_answer(answer_path)
    if answer is None:
        return 0, {"error": "no answer was submitted", "aliases": golds}
    prediction = normalize(answer)
    em = 1 if prediction in golds else 0
    best_f1 = max((f1(prediction, gold) for gold in golds), default=0.0)
    return em, {"answer": answer, "normalized": prediction, "aliases": golds, "em": em, "f1": round(best_f1, 4)}


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
        args.details.write_text(json.dumps(details, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print("reward=%d" % reward)
    return 0


if __name__ == "__main__":
    sys.exit(main())
