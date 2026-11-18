"""Deterministic EM/F1 grader for SearchQA answers.

Runs inside the separate verifier container with the task's spec.json and the
agent's submitted /app/answer.txt (a declared Harbor artifact). Python 3.9+,
stdlib only.

The first non-empty line of answer.txt is the answer; a Jeopardy!-style
"What is ...?" wrapper is removed. Scoring is the SQuAD/MRQA convention:
lowercase, drop punctuation, drop the
articles a/an/the, collapse whitespace; exact match (EM) and token-level F1,
each taken as the maximum over the gold aliases. Jeopardy answers carry
alternates in parentheses, so the aliases are the answer as given, the answer
with every parenthetical removed, and each "(or X)" / "(X)" alternative.

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


def aliases(answer: str) -> List[str]:
    out = [answer]
    stripped = re.sub(r"\([^()]*\)", " ", answer)
    out.append(stripped)
    for inner in re.findall(r"\(([^()]*)\)", answer):
        alt = re.sub(r"^\s*or\s+", "", inner, flags=re.IGNORECASE)
        out.append(alt)
        # "(Edgar Allan) Poe": the full name with the parenthetical kept.
        out.append(answer.replace("(" + inner + ")", inner))
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
