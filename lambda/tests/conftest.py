import importlib.util
from pathlib import Path

import pytest

LAMBDA_DIR = Path(__file__).resolve().parent.parent


def load_handler(name: str):
    """Import lambda/<name>/handler.py as a fresh module (every Lambda's file is handler.py)."""
    spec = importlib.util.spec_from_file_location(
        f"{name}_handler", LAMBDA_DIR / name / "handler.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeClient:
    """Minimal stand-in for a boto3 client: returns canned responses and records calls."""

    def __init__(self, **responses):
        self.responses = responses
        self.calls = []

    def __getattr__(self, op):
        def call(**kwargs):
            self.calls.append((op, kwargs))
            value = self.responses[op]
            return value(**kwargs) if callable(value) else value

        return call


class FakePaginator:
    def __init__(self, pages):
        self.pages = pages

    def paginate(self, **_kwargs):
        return iter(self.pages)


@pytest.fixture
def fake_clients(monkeypatch):
    """Patch module.client(name) to return FakeClient objects from a dict."""

    def install(module, clients):
        monkeypatch.setattr(module, "client", lambda name: clients[name])
        return clients

    return install
