"""Model prices from OpenRouter, for runs whose model metacodes has no price for.

metacodes charges a model missing from its built-in table at the Sonnet
fallback rates, far above what most open models cost, and teamwork's budget
ledger and isolated verifier stop on that estimate. A run's model is matched
to the one OpenRouter model whose id, without its `vendor/` prefix, is the
run's request model id (case-insensitive; a request id with its own
namespace must equal the OpenRouter id); its price goes to the trial's
config.json as `model_prices`, which metacodes charges first. The catalog is
cached beside workbench.json for a day; when OpenRouter cannot be reached the
cached copy is used, and without one the run keeps metacodes' own estimate.
`"model_prices": "off"` in workbench.json skips the lookup.
"""
from __future__ import annotations

import http.client
import json
import re
import time
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, Optional

from scripts.eval.harbor.bench.runner import atomic_json
from scripts.eval.harbor.command import split_model

OPENROUTER = "openrouter"
BASETEN = "baseten"
RECORDED = "recorded"
AUTO = "auto"
SCHEDULES = (
    {"id": OPENROUTER, "label": "OpenRouter 报价"},
    {"id": BASETEN, "label": "Baseten 挂牌价"},
    {"id": RECORDED, "label": "运行记录原价"},
)
LEADERBOARD_SCHEDULES = (
    {"id": AUTO, "label": "跟随榜单口径"},
    *SCHEDULES,
)
SCHEDULE_LABELS = {entry["id"]: entry["label"] for entry in LEADERBOARD_SCHEDULES}
CATALOG_URL = "https://openrouter.ai/api/v1/models"
CACHE_NAME = "openrouter-prices.json"
MAX_AGE_S = 24 * 3600
FIELDS = {"input": "prompt", "output": "completion", "cached_input": "input_cache_read",
          "cache_write": "input_cache_write"}
VERSION_SEP = re.compile(r"(?<=\d)-(?=(?:0|[1-9]\d?)(?=-|:|$))")
DATE_SUFFIX = re.compile(r"(?:[-@]20\d{6}|-20\d{2}-\d{2}-\d{2})$")
BASETEN_MODELS: Dict[str, Dict[str, float]] = {
    "deepseek-ai/deepseek-v4.1-flash-1017": {"input": 0.30, "output": 1.20, "cached_input": 0.007},
    "deepseek-ai/deepseek-v4.1-flash-1017-fast": {"input": 0.60, "output": 2.40, "cached_input": 0.014},
    "deepseek-ai/deepseek-v4.1-flash": {"input": 0.30, "output": 1.20, "cached_input": 0.007},
    "deepseek-ai/deepseek-v4-pro-0813": {"input": 1.32, "output": 3.96, "cached_input": 0.132},
    "deepseek-ai/deepseek-v4-flash-0731": {"input": 0.13, "output": 0.26, "cached_input": 0.028},
    "zai-org/glm-5.3": {"input": 1.40, "output": 4.40, "cached_input": 0.14},
    "zai-org/glm-5.3-fast": {"input": 2.10, "output": 6.60, "cached_input": 0.21},
    "zai-org/glm-5.3-flash": {"input": 0.15, "output": 0.50, "cached_input": 0.03},
    "moonshotai/kimi-k3": {"input": 3.00, "output": 15.00, "cached_input": 0.30},
    "moonshotai/kimi-k3.1-pro": {"input": 2.00, "output": 10.00, "cached_input": 0.20},
    "meta-models/muse-spark-open": {"input": 1.25, "output": 4.25, "cached_input": 0.15},
    "openai/gpt-oss-120b": {"input": 0.10, "output": 0.50},
    "nvidia/nemotron-3.5-super-vl": {"input": 0.20, "output": 0.50, "cached_input": 0.04},
}


def parse_schedule(value: Optional[str], *, allow_auto: bool = False) -> str:
    default = AUTO if allow_auto else OPENROUTER
    if not isinstance(value, str):
        return default
    cleaned = value.strip().lower()
    allowed = {entry["id"] for entry in (LEADERBOARD_SCHEDULES if allow_auto else SCHEDULES)}
    return cleaned if cleaned in allowed else default


def cached_catalog(state_dir: Path) -> Dict[str, Dict[str, Any]]:
    path = Path(state_dir) / CACHE_NAME
    try:
        cached = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return cached.get("models") or {} if isinstance(cached, dict) else {}


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
    except (OSError, ValueError, http.client.HTTPException):
        return (cached or {}).get("models") or {}
    atomic_json(path, {"fetched_at": now(), "source": CATALOG_URL, "models": models})
    return models


def per_million(value: Any) -> Optional[float]:
    try:
        number = float(value) * 1_000_000
    except (TypeError, ValueError):
        return None
    return round(number, 6) if number >= 0 else None


def _normalize_version(slug: str) -> str:
    previous = None
    current = slug
    while current != previous:
        previous = current
        current = VERSION_SEP.sub(".", current)
    return current


def _strip_date(slug: str) -> str:
    return DATE_SUFFIX.sub("", slug)


def _apply_slug(model_id: str, has_namespace: bool, transform: Callable[[str], str]) -> str:
    if has_namespace:
        vendor, sep, slug = model_id.partition("/")
        return vendor + "/" + transform(slug) if sep else transform(model_id)
    return transform(model_id)


def _match_openrouter_id(request_id: str, models: Dict[str, Dict[str, Any]]) -> Optional[str]:
    has_namespace = "/" in request_id
    candidates = [
        (openrouter_id, openrouter_id.lower() if has_namespace else openrouter_id.rsplit("/", 1)[-1].lower())
        for openrouter_id in models
    ]
    passes = (
        (lambda slug: slug, lambda slug: slug),
        (_normalize_version, _normalize_version),
        (lambda slug: _normalize_version(_strip_date(slug)), _normalize_version),
    )
    for request_transform, catalog_transform in passes:
        want = _apply_slug(request_id, has_namespace, request_transform)
        matches = [
            openrouter_id
            for openrouter_id, candidate in candidates
            if _apply_slug(candidate, has_namespace, catalog_transform) == want
        ]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            return None
    return None


def price_for(model: str, models: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """The run model's price in USD per million tokens and the OpenRouter id
    it came from, or None when no single OpenRouter model matches. A request
    model id with its own namespace (`acme/model`) matches that OpenRouter id
    only; a bare one matches the single id ending in `/<model>`. Exact matches
    win; otherwise hyphen/dot version separators (`4-6` vs `4.6`) and a
    trailing release date (`-YYYYMMDD`, `@YYYYMMDD`, `-YYYY-MM-DD`) on the
    request id are normalized."""
    request_id = split_model(model)[1].lower()
    matched = _match_openrouter_id(request_id, models)
    if matched is None:
        return None
    pricing = models[matched]
    price = {name: per_million(pricing.get(key)) for name, key in FIELDS.items()}
    if price["input"] is None or price["output"] is None:
        return None
    return {"openrouter_id": matched, **{k: v for k, v in price.items() if v is not None}}


def baseten_price_for(model: str) -> Optional[Dict[str, Any]]:
    try:
        request_id = split_model(model)[1].lower()
    except ValueError:
        return None
    matched = _match_openrouter_id(request_id, BASETEN_MODELS)
    if matched is None:
        return None
    return {"baseten_id": matched, **BASETEN_MODELS[matched]}


def rate_for(
    model: Optional[str],
    schedule: str,
    openrouter_models: Optional[Dict[str, Dict[str, Any]]] = None,
    recorded_price: Optional[Dict[str, Any]] = None,
) -> Optional[Dict[str, Any]]:
    if not isinstance(model, str) or not model.strip():
        return None
    if schedule == BASETEN:
        found = baseten_price_for(model)
        if not found:
            return None
        return {
            "schedule": BASETEN,
            "model_id": found["baseten_id"],
            **{k: v for k, v in found.items() if k in FIELDS},
        }
    if schedule == OPENROUTER:
        try:
            found = price_for(model, openrouter_models or {})
        except ValueError:
            found = None
        if found:
            return {
                "schedule": OPENROUTER,
                "model_id": found["openrouter_id"],
                **{k: v for k, v in found.items() if k in FIELDS},
            }
        if isinstance(recorded_price, dict) and recorded_price.get("input") is not None and recorded_price.get("output") is not None:
            return {
                "schedule": OPENROUTER,
                "model_id": recorded_price.get("openrouter_id") or model,
                **{k: v for k, v in recorded_price.items() if k in FIELDS and v is not None},
            }
    return None


def compute_cost(
    rate: Optional[Dict[str, Any]],
    input_tokens: Optional[float],
    output_tokens: Optional[float],
    cache_tokens: Optional[float] = None,
    cache_creation_tokens: Optional[float] = None,
) -> Optional[float]:
    if not isinstance(rate, dict) or input_tokens is None or output_tokens is None:
        return None
    if input_tokens < 0 or output_tokens < 0 or (input_tokens == 0 and output_tokens == 0):
        return None
    cache_read = max(0.0, float(cache_tokens or 0.0))
    cache_write = max(0.0, float(cache_creation_tokens or 0.0))
    uncached = max(0.0, float(input_tokens) - cache_read - cache_write)
    input_rate = float(rate["input"])
    output_rate = float(rate["output"])
    cached_rate = float(rate["cached_input"]) if rate.get("cached_input") is not None else input_rate
    write_rate = float(rate["cache_write"]) if rate.get("cache_write") is not None else input_rate
    return (
        uncached * input_rate
        + float(output_tokens) * output_rate
        + cache_read * cached_rate
        + cache_write * write_rate
    ) / 1_000_000.0
