import os
import shlex
import subprocess
import sys


def main():
    if sys.version_info < (3, 9):
        sys.exit(f"Eval is using {sys.executable}. Put Python >= 3.9 on PATH.")
    try:
        import yaml
        if int(yaml.__version__.split(".")[0]) >= 6:
            return
    except (ImportError, AttributeError, ValueError, OSError):
        pass
    args = [sys.executable, "-m", "pip", "install", "-r", "requirements-dev.txt"]
    command = subprocess.list2cmdline(args) if os.name == "nt" else shlex.join(args)
    sys.exit(f"Eval needs PyYAML >= 6.0 in {sys.executable}. From the repository root run:\n{command}")


if __name__ == "__main__":
    main()
