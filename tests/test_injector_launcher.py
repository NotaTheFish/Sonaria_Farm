"""Конфиг инжектора (без реального subprocess)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from farm.game import injector_launcher as inj


def test_launch_when_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("INJECTOR_LAUNCH_WHEN", raising=False)
    assert inj.injector_launch_when() == "never"


def test_launch_when_valid(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("INJECTOR_LAUNCH_WHEN", "every_farm_tick")
    assert inj.injector_launch_when() == "every_farm_tick"


def test_launch_when_invalid_falls_back(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("INJECTOR_LAUNCH_WHEN", "bogus")
    assert inj.injector_launch_when() == "never"


def test_build_argv_with_temp_exe(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    exe = tmp_path / "tool.exe"
    exe.write_bytes(b"")
    monkeypatch.setenv("INJECTOR_ENABLED", "1")
    monkeypatch.setenv("INJECTOR_PATH", str(exe))
    monkeypatch.delenv("INJECTOR_ARGS_JSON", raising=False)
    argv = inj.build_injector_argv()
    assert argv is not None
    assert argv[0] == str(exe.resolve())
    assert argv[1:] == []


def test_extra_argv_json(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    exe = tmp_path / "x.exe"
    exe.write_bytes(b"")
    monkeypatch.setenv("INJECTOR_PATH", str(exe))
    monkeypatch.setenv("INJECTOR_ARGS_JSON", json.dumps(["--a", "b"]))
    assert inj.injector_extra_argv() == ["--a", "b"]


def test_path_strips_quotes(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    exe = tmp_path / "p.exe"
    exe.write_bytes(b"")
    monkeypatch.setenv("INJECTOR_PATH", f'"{exe}"')
    assert inj.injector_executable() == exe
