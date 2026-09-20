"""Export manifests (data only)."""


def build(entries):
    return {"count": len(entries), "entries": sorted(entries)}
