"""
Параметры для универсальных Lua-скриптов: собираются в объект ``script_params`` внутри JSON моста.

Верхний уровень request (task_id, worker_id, bridge, …) — для маршрутизации и совместимости.
Всё, что должно уйти в один таблицу аргументов Lua, — в ``script_params`` (и дубли ключей
сверху только там, где уже было исторически, например death_points_target).
"""

from __future__ import annotations

import os
from typing import Any

from farm.game.stop_flags import stop_flag_path
from farm.models import Account


def _include_password_in_bridge() -> bool:
    v = os.getenv("SCRIPTS_INCLUDE_PASSWORD_IN_BRIDGE", "1").strip().lower()
    return v not in ("0", "false", "no", "off")


def build_farm_tick_script_params(
    *,
    account: Account,
    death_points_target: int,
    tick_seq: int,
) -> dict[str, Any]:
    flag = stop_flag_path(account.id)
    sp: dict[str, Any] = {
        "target_dp": death_points_target,
        "death_points_target": death_points_target,
        "tick_seq": tick_seq,
        "account_id": account.id,
        "account_login": account.login,
        "role": (getattr(account, "role", None) or "farmer"),
        "stop_flag_path": str(flag.resolve()),
    }
    if _include_password_in_bridge():
        sp["account_password"] = account.password
    return sp


def build_transfer_script_params(
    *,
    farmer: Account,
    payload: dict[str, Any],
    target_storage_login: str | None,
) -> dict[str, Any]:
    sp = dict(payload)
    sp["farmer_account_id"] = farmer.id
    sp["farmer_login"] = farmer.login
    sp["role"] = getattr(farmer, "role", None) or "farmer"
    if target_storage_login is not None:
        sp["target_storage_login"] = target_storage_login
    return sp


def build_sell_script_params(
    *,
    storage: Account,
    payload: dict[str, Any],
) -> dict[str, Any]:
    sp = dict(payload)
    sp["storage_account_id"] = storage.id
    sp["storage_login"] = storage.login
    sp["role"] = getattr(storage, "role", None) or "storage"
    if "fallback_non_priority_mode" in payload:
        sp["fallback_mode"] = payload.get("fallback_non_priority_mode")
    return sp


def build_universal_script_params(
    account: Account,
    command: str,
    extra_params: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """
    Параметры для ``external/injector_scripts/universal_sonaria_bot.lua`` (поле ``command``).

    Общие ключи (часть опциональна, см. комментарии в .lua):

    - role, command, account_id, account_login, account_password?, stop_flag_path
    - target_storage_account_id, target_storage_username (логин Roblox склада для трейда)
    - farmer_queue_index, farmer_queue_total, queue_stagger_seconds — очередь фермеров
    - transfer_token_priority / token_kinds — порядок токенов для передачи на склад
    - batch_size (150), trade_retry_seconds (10), trade_confirm_poll_seconds (2),
      post_trade_cooldown_seconds (70)
    - farm_pipeline: ``missions_dp_only`` | ``missions_dp_then_transfer`` — после цели DP
    - default_creature_name (Kaluaka), volcano_suicide (bool)
    - sell_idle_rotate_seconds (3600), anti_afk_interval_seconds (300)
    - bound_farmers: [{ "id", "login" }, ...] для склада (receive / sell контекст)
    - dex_asset_path — по умолчанию в Lua ``Dex_roblox.rbxmx`` рядом с workspace эксплойта
    """
    base: dict[str, Any] = {
        "role": getattr(account, "role", None) or "farmer",
        "command": command,
        "account_id": account.id,
        "account_login": account.login,
        "account_password": (account.password if _include_password_in_bridge() else None),
        "stop_flag_path": str(stop_flag_path(account.id).resolve()),
    }
    if extra_params:
        base.update(extra_params)
    return base


def build_universal_farm_tick_params(
    *,
    account: Account,
    death_points_target: int,
    task_payload: dict[str, Any] | None,
) -> dict[str, Any]:
    """Слияние payload задачи ``universal_farm`` с целевыми DP для первого инжекта."""
    merged: dict[str, Any] = dict(task_payload or {})
    merged["target_dp"] = death_points_target
    merged["death_points_target"] = death_points_target
    merged.setdefault("tick_seq", 1)
    return build_universal_script_params(account, "farm", extra_params=merged)
