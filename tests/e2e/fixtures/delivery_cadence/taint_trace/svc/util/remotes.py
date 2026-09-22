"""Known mirror remotes."""

_REMOTES = {
    "origin": "https://mirror.example.com/assets.git",
    "backup": "https://backup.example.com/assets.git",
}


def resolve(name):
    try:
        return _REMOTES[name]
    except KeyError:
        raise ValueError("unknown remote: %s" % name)
