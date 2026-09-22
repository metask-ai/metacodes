from app import settings


def test_missing_key_returns_default():
    assert settings.get("nope.nothing", "x") == "x"
