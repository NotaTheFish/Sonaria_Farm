"""Сборка script_params без БД."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from farm.game import script_params as sp


def _account(**kw: object) -> SimpleNamespace:
    return SimpleNamespace(**kw)


def test_farm_tick_script_params_includes_stop_path(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setenv("STOP_FLAG_DIR", str(tmp_path / "sf"))
    acc = _account(id="aid-1", login="L", password="P")
    d = sp.build_farm_tick_script_params(
        account=acc,  # type: ignore[arg-type]
        death_points_target=900,
        tick_seq=2,
    )
    assert d["target_dp"] == 900
    assert d["tick_seq"] == 2
    assert "stop_flag_path" in d
    assert str(tmp_path / "sf") in d["stop_flag_path"] or "aid-1.stop" in d["stop_flag_path"]


def test_farm_tick_omit_password(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setenv("STOP_FLAG_DIR", str(tmp_path))
    monkeypatch.setenv("SCRIPTS_INCLUDE_PASSWORD_IN_BRIDGE", "0")
    acc = _account(id="a", login="L", password="secret")
    d = sp.build_farm_tick_script_params(
        account=acc,  # type: ignore[arg-type]
        death_points_target=1,
        tick_seq=1,
    )
    assert "account_password" not in d


def test_transfer_script_params() -> None:
    farmer = _account(id="f1", login="farmer1", password="x")
    payload = {"target_storage_account_id": "s1", "batch_size": 10}
    d = sp.build_transfer_script_params(
        farmer=farmer,  # type: ignore[arg-type]
        payload=payload,
        target_storage_login="storage_login",
    )
    assert d["farmer_login"] == "farmer1"
    assert d["target_storage_login"] == "storage_login"


def test_sell_script_params_fallback_alias() -> None:
    st = _account(id="st1", login="stor", password="x")
    payload = {"ranges": {}, "priority_tokens": [], "fallback_non_priority_mode": "sell_all"}
    d = sp.build_sell_script_params(storage=st, payload=payload)  # type: ignore[arg-type]
    assert d["storage_login"] == "stor"
    assert d["fallback_mode"] == "sell_all"


def test_universal_script_params(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setenv("STOP_FLAG_DIR", str(tmp_path))
    monkeypatch.setenv("SCRIPTS_INCLUDE_PASSWORD_IN_BRIDGE", "1")
    acc = _account(id="u1", login="L", password="sec", role="farmer")
    d = sp.build_universal_script_params(
        acc,  # type: ignore[arg-type]
        "farm",
        extra_params={"target_dp": 123},
    )
    assert d["command"] == "farm"
    assert d["target_dp"] == 123
    assert d["account_password"] == "sec"


def test_universal_script_params_no_password(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setenv("STOP_FLAG_DIR", str(tmp_path))
    monkeypatch.setenv("SCRIPTS_INCLUDE_PASSWORD_IN_BRIDGE", "0")
    acc = _account(id="u1", login="L", password="sec", role="storage")
    d = sp.build_universal_script_params(acc, "inventory")  # type: ignore[arg-type]
    assert d["account_password"] is None
