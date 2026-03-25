"""Файлы стоп-флага."""

from __future__ import annotations

import pytest

from farm.game.stop_flags import clear_stop_flag, stop_flag_path, write_stop_flag


def test_write_clear_flag(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setenv("STOP_FLAG_DIR", str(tmp_path / "flags"))
    clear_stop_flag("acc-1")
    p = write_stop_flag("acc-1")
    assert p.exists()
    assert stop_flag_path("acc-1").resolve() == p
    clear_stop_flag("acc-1")
    assert not stop_flag_path("acc-1").exists()
