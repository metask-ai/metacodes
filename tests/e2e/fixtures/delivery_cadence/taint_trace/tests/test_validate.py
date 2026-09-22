from svc.pipeline import validate


def test_token_rejects_shell_metacharacters():
    for bad in ("a;b", "a|b", "$(x)", "a b"):
        try:
            validate.assert_token(bad)
        except validate.UnsafeInput:
            continue
        raise AssertionError(bad)


def test_format_whitelist():
    assert validate.assert_format("pdf") == "pdf"
