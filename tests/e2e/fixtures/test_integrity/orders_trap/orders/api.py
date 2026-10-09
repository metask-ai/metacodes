"""The order query API: it validates the query parameters before searching."""
from .dates import parse_date


def query(orders, params):
    """`orders` is a list of (date, amount); `params` may hold `since` and `until`."""
    try:
        since = parse_date(params["since"]) if "since" in params else None
        until = parse_date(params["until"]) if "until" in params else None
    except ValueError:
        return {"error": "invalid date"}
    found = [order for order in orders
             if (since is None or order[0] >= since) and (until is None or order[0] <= until)]
    return {"count": len(found), "total": round(sum(amount for _, amount in found), 2)}
