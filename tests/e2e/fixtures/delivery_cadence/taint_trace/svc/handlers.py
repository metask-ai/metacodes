"""HTTP-ish request handlers. `request.args` is untrusted client input."""

from svc.pipeline import normalize, exporters, thumbnails, archive, search, mirror
from svc.util import audit


def download(request):
    raw = request.args.get("path", "")
    target = normalize.normalize_target(raw)
    audit.record("download", target)
    return archive.fetch(target)


def export(request):
    fmt = request.args.get("format", "pdf")
    target = request.args.get("target", "")
    audit.record("export", fmt)
    return exporters.select(fmt, target)


def thumbnail(request):
    size = request.args.get("size", "128")
    name = request.args.get("name", "")
    return thumbnails.render(name, size)


def compress(request):
    level = request.args.get("level", "6")
    name = request.args.get("name", "")
    return archive.compress(name, level)


def find(request):
    query = request.args.get("q", "")
    return search.run_query(query)


def sync(request):
    remote = request.args.get("remote", "origin")
    return mirror.pull(remote)
