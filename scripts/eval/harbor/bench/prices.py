"""Model prices from OpenRouter, for runs whose model metacodes has no price for.

metacodes charges a model missing from its built-in table at the Sonnet
fallback rates, far above what most open models cost, and teamwork's budget
ledger and isolated verifier stop on that estimate. A run's model is matched
to the one OpenRouter model whose id, without its `vendor/` prefix, is the
run's request model id (case-insensitive); its price goes to the trial's
config.json as `model_prices`, which metacodes charges first. The catalog is
cached beside workbench.json for a day; when OpenRouter cannot be reached the
cached copy is used, and without one the run keeps metacodes' own estimate.
`"model_prices": "off"` in workbench.json skips the lookup.
"""
from __future__ import annotations

import json
import time
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional

from scripts.eval.harbor.bench.runner import atomic_json

OPENROUTER = "openrouter"
CATALOG_URL = "https://openrouter.ai/api/v1/models"
CACHE_NAME = "openrouter-prices.json"
MAX_AGE_S = 24 * 3600
FIELDS = {"input": "prompt", "output": "completion", "cached_input": "input_cache_read",
          "cache_write": "input_cache_write"}


def fetch(timeout: float = 10.0) -> Dict[str, Dict[str, Any]]:
    request = urllib.request.Request(CATALOG_URL, headers={"User-Agent": "metacodes-bench"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        models = json.load(response).get("data") or []
    return {m["id"]: m.get("pricing") or {} for m in models if isinstance(m, dict) and isinstance(m.get("id"), str)}


def catalog(state_dir: Path, fetcher=None, now=time.time) -> Dict[str, Dict[str, Any]]:
    """OpenRouter's pricing by model id, refreshed at most once a day."""
    path = Path(state_dir) / CACHE_NAME
    try:
        cached = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cached = None
    if isinstance(cached, dict) and now() - cached.get("fetched_at", 0) < MAX_AGE_S:
        return cached.get("models") or {}
    try:
        models = (fetcher or fetch)()
    except (OSError, ValueError):
        return (cached or {}).get("models") or {}
    atomic_json(path, {"fetched_at": now(), "source": CATALOG_URL, "models": models})
    return models


def per_million(value: Any) -> Optional[float]:
    try:
        number = float(value) * 1_000_000
    except (TypeError, ValueError):
        return None
    return round(number, 6) if number >= 0 else None


def price_for(model: str, models: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """The run model's price in USD per million tokens and the OpenRouter id
    it came from, or None when no single OpenRouter model matches."""
    request_id = model.rsplit("/", 1)[-1].lower()
    matches = [i for i in models if i.rsplit("/", 1)[-1].lower() == request_id]
    if len(matches) != 1:
        return None
    pricing = models[matches[0]]
    price = {name: per_million(pricing.get(key)) for name, key in FIELDS.items()}
    if price["input"] is None or price["output"] is None:
        return None
    return {"openrouter_id": matches[0], **{k: v for k, v in price.items() if v is not None}}
