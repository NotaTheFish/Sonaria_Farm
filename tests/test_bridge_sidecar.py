"""Скрипт bridge_sidecar: заглушка ответа для farm_tick."""

from __future__ import annotations

import importlib.util
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]


def _load_sidecar():
    spec = importlib.util.spec_from_file_location(
        "bridge_sidecar",
        _ROOT / "scripts" / "bridge_sidecar.py",
    )
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_build_response_farm_tick_includes_death_points() -> None:
    m = _load_sidecar()
    out = m.build_response(
        {
            "task_id": "t1",
            "tick_seq": 3,
            "account_id": "a1",
            "worker_id": "w1",
            "death_points_target": 600,
        }
    )
    assert out.get("ok") is True
    assert "death_points_current" in out


def test_build_response_transfer_shape() -> None:
    m = _load_sidecar()
    out = m.build_response(
        {
            "bridge": "transfer_to_storage",
            "task_id": "t2",
            "payload": {},
        }
    )
    assert out.get("ok") is True
