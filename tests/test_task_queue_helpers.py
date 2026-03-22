"""Нормализация env для воркера (без PostgreSQL)."""

from __future__ import annotations

import pytest

pytest.importorskip("sqlalchemy")

from farm import task_queue as tq


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (None, None),
        ("", None),
        ("   ", None),
        ("  acc-id  ", "acc-id"),
    ],
)
def test_nullable_fk_account_id(raw: str | None, expected: str | None) -> None:
    assert tq._nullable_fk_account_id(raw) == expected


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (None, None),
        ("", None),
        ("\t", None),
        (" wid-1 ", "wid-1"),
    ],
)
def test_nullable_worker_id(raw: str | None, expected: str | None) -> None:
    assert tq._nullable_worker_id(raw) == expected
