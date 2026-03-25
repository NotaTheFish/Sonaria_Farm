"""Стабильные строковые значения enum (контракт с воркером и ботом)."""

from __future__ import annotations

import pytest

pytest.importorskip("sqlalchemy")

from farm.models import AccountStatus, TaskStatus, TaskType


def test_task_type_values_match_snake_case() -> None:
    assert TaskType.LOGIN_AND_CHECK.value == "login_and_check"
    assert TaskType.START_FARM.value == "start_farm"
    assert TaskType.STOP_FARM.value == "stop_farm"
    assert TaskType.TRANSFER_TO_STORAGE.value == "transfer_to_storage"
    assert TaskType.SET_SELL_PRICE.value == "set_sell_price"
    assert TaskType.UNIVERSAL_FARM.value == "universal_farm"
    assert TaskType.UNIVERSAL_TRANSFER.value == "universal_transfer"
    assert TaskType.UNIVERSAL_SELL.value == "universal_sell"
    assert TaskType.UNIVERSAL_INVENTORY.value == "universal_inventory"
    assert TaskType.UNIVERSAL_DEX.value == "universal_dex"


def test_task_status_values() -> None:
    for s in TaskStatus:
        assert s.value == s.value.lower()


def test_account_status_active() -> None:
    assert AccountStatus.ACTIVE.value == "active"
