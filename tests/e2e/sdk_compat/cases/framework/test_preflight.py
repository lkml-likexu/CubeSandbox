# Copyright (c) 2026 Tencent Inc.
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import pytest

from framework import preflight

pytestmark = pytest.mark.framework


class _InterpreterSandbox:
    @property
    def _client(self):
        return self.get_transport(self.connection_config, http2=False)


class _InterpreterModule:
    Sandbox = _InterpreterSandbox


class _CompatibleTransport:
    @staticmethod
    def get_transport(config, http2=True):
        return config, http2


class _KwargsTransport:
    @staticmethod
    def get_transport(config, **kwargs):
        return config, kwargs


class _IncompatibleTransport:
    @staticmethod
    def get_transport(config):
        return config


def _modules(core):
    def _load(name):
        if name == "e2b.api.client_sync":
            return core
        if name == "e2b_code_interpreter.code_interpreter_sync":
            return _InterpreterModule
        raise ImportError(name)

    return _load


def test_e2b_interpreter_transport_accepts_http2(monkeypatch) -> None:
    monkeypatch.setattr(
        preflight.importlib,
        "import_module",
        _modules(_CompatibleTransport),
    )
    errors: list[str] = []

    preflight._check_e2b_interpreter_transport(errors)

    assert errors == []


def test_e2b_interpreter_transport_accepts_kwargs(monkeypatch) -> None:
    monkeypatch.setattr(
        preflight.importlib,
        "import_module",
        _modules(_KwargsTransport),
    )
    errors: list[str] = []

    preflight._check_e2b_interpreter_transport(errors)

    assert errors == []


def test_e2b_interpreter_transport_rejects_incompatible_core(monkeypatch) -> None:
    monkeypatch.setattr(
        preflight.importlib,
        "import_module",
        _modules(_IncompatibleTransport),
    )
    errors: list[str] = []

    preflight._check_e2b_interpreter_transport(errors)

    assert len(errors) == 1
    assert "does not accept http2" in errors[0]
    assert "e2b==2.39.1" in errors[0]
