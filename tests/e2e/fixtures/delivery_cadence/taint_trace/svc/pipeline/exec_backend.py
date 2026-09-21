"""The only place that touches the shell."""

import subprocess


def run_command(command):
    """Run a fully assembled command line through the shell."""
    return subprocess.run(command, shell=True, capture_output=True, text=True, check=False)


def run_argv(argv):
    """Run an argument vector without a shell."""
    return subprocess.run(list(argv), capture_output=True, text=True, check=False)
