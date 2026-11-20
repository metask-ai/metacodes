"""Dataset adapters for `harbor-local` Bench suites.

One module per suite, registered in ``scripts.eval.harbor.suites.ADAPTER_SUITES``;
the interface (``SUITE``, ``prepare(dest) -> Path``, optional ``check(ctx)``
and ``tasks(dataset)``) is specified in that module's docstring and in
doc/BENCH_WORKBENCH.md.
"""
