from app.core.config import settings
from app.main import cors_options


def test_cors_open_in_debug(monkeypatch):
    monkeypatch.setattr(settings, "debug", True)
    assert cors_options() == {"allow_origins": ["*"], "allow_credentials": False}


def test_cors_restricted_in_production(monkeypatch):
    monkeypatch.setattr(settings, "debug", False)
    monkeypatch.setattr(settings, "cors_origins", ["https://app.example.com"])
    assert cors_options() == {
        "allow_origins": ["https://app.example.com"],
        "allow_credentials": True,
    }
