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
    quote = subprocess.list2cmdline if os.name == "nt" else shlex.join
    install = ["-m", "pip", "install", "-r", "requirements-dev.txt"]
    activate = r"call .venv\Scripts\activate.bat" if os.name == "nt" else ". .venv/bin/activate"
    shell = "cmd.exe" if os.name == "nt" else "a POSIX shell"
    sys.exit(
        f"Eval needs PyYAML >= 6.0 in {sys.executable}. From the repository root in {shell}, run:\n"
        f"{quote([sys.executable, *install])}\n"
        "If pip is unavailable or the interpreter is externally managed, use a fresh virtual environment:\n"
        f"{quote([sys.executable, '-m', 'venv', '.venv'])}\n"
        f"{activate}\n"
        f"{quote(['python', *install])}\n"
        "zig build gate:pr"
    )


if __name__ == "__main__":
    main()
