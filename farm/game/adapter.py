"""
Адаптер игры (Windows + Roblox + Creatures of Sonaria).

Здесь не античит и не обходы — только контракты и заглушки.
Твоя реализация: подкласс `GameAdapter` или замена фабрики `get_game_adapter()`.

Воркер получает из БД только `account_id`; логин/пароль читаются внутри адаптера
из `farm.models.Account` (или через переданный объект `account`).
"""

from __future__ import annotations

import asyncio
import json
import os
from abc import ABC, abstractmethod
from typing import Any

from sqlalchemy import update

from farm.database import AsyncSessionMaker
from farm.models import Account, AccountStatus
from farm.task_queue import append_task_log, get_task_account


class GameAdapter(ABC):
    """Контракт для всех игровых операций, вызываемых из воркера."""

    @abstractmethod
    async def login_and_check(self, *, task_id: str, worker_id: str, account: Account) -> None:
        """Проверка аккаунта: выставить корректный Account.status и banned_reason при необходимости."""

    @abstractmethod
    async def farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
    ) -> None:
        """Один шаг фарма (миссии, DP и т.д.). Вызывается в цикле до cancel."""

    @abstractmethod
    async def transfer_to_storage(
        self,
        *,
        task_id: str,
        worker_id: str,
        farmer_account: Account,
        payload: dict[str, Any],
    ) -> None:
        """Передача токенов фермер -> склад по данным payload (target_storage_account_id, batch, cd)."""

    @abstractmethod
    async def set_sell_price(
        self,
        *,
        task_id: str,
        worker_id: str,
        storage_account: Account,
        payload: dict[str, Any],
    ) -> None:
        """Торговый мир: выставить лоты по ranges и priority_tokens."""


class WindowsGameAdapter(GameAdapter):
    """
    Каркас под реальный запуск на Windows + Roblox + Creatures of Sonaria.

    Как подключать:
      1) В .env или переменных окружения: GAME_ADAPTER=windows
      2) Реализуй шаги в методах ниже (сейчас везде NotImplementedError после лога).

    Общий поток (наводки, без деталей клиента):
      - Храни сессию «один аккаунт = один процесс Roblox» в полях экземпляра
        (например self._roblox_pid, self._session_started_at).
      - Логин: взять account.login / account.password из объекта Account (уже из БД).
      - После каждого значимого шага пиши append_task_log(...) — так видно прогресс в task_logs.
      - При бане Roblox / неверном пароле / чекпоинте:
        обнови строку accounts (status + banned_reason) через AsyncSessionMaker + update(Account).
      - При трейдлоке в игре: status=cooldown или disabled + reason в banned_reason.
      - Не блокируй event loop надолго: тяжёлые ожидания выноси в asyncio.to_thread(...)
        или короткие sleep + проверка состояния.

    Полезные ключи в payload (уже задаёт контроллер):
      - start_farm: death_points_target, loop
      - transfer_to_storage: target_storage_account_id, batch_size, cooldown_seconds, ...
      - set_sell_price: ranges, priority_tokens, ...
    """

    async def login_and_check(self, *, task_id: str, worker_id: str, account: Account) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                "[windows] login_and_check: TODO — "
                "1) Запустить Roblox под этим аккаунтом. "
                "2) Проверить экран ошибки (wrong password, banned, verify, etc.). "
                "3) Выставить Account.status (active / banned / invalid_credentials / checkpoint / …) в БД."
            ),
        )
        raise NotImplementedError(
            "WindowsGameAdapter.login_and_check: реализуй вход и классификацию статуса аккаунта."
        )

    async def farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] farm_tick: TODO — один шаг цикла для account_id={account.id}, "
                f"цель DP={death_points_target}. "
                "Идея: открыть миссии / выполнить шаг миссии / проверить DP в UI или через твой канал чтения состояния. "
                "После достижения цели — получить токен и инициировать смерть/рестарт по твоему сценарию."
            ),
        )
        raise NotImplementedError(
            "WindowsGameAdapter.farm_tick: реализуй один игровой тик (Kaluaka / миссии / DP)."
        )

    async def transfer_to_storage(
        self,
        *,
        task_id: str,
        worker_id: str,
        farmer_account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] transfer_to_storage: TODO — фермер={farmer_account.id}, "
                f"payload={json.dumps(payload, ensure_ascii=False)}. "
                "Идея: зайти в трейд-мир, найти сессию с target_storage_account_id (второй клиент или NPC-логика), "
                "передать пачками по batch_size с паузой cooldown_seconds."
            ),
        )
        raise NotImplementedError(
            "WindowsGameAdapter.transfer_to_storage: реализуй трейд фермер → склад."
        )

    async def set_sell_price(
        self,
        *,
        task_id: str,
        worker_id: str,
        storage_account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] set_sell_price: TODO — склад={storage_account.id}, "
                f"keys={list(payload)}. "
                "Идея: торговый мир → поставить прилавок → слоты 4 шт по priority_tokens, "
                "цена random в ranges[token], затем цикл пока лоты не пусты; при 0 приоритетного — выложить неприоритетные."
            ),
        )
        raise NotImplementedError(
            "WindowsGameAdapter.set_sell_price: реализуй выставление лотов на продажу."
        )


class StubGameAdapter(GameAdapter):
    """
    Заглушка для разработки без Roblox.
    В проде на Windows замени на свою реализацию.
    """

    async def login_and_check(self, *, task_id: str, worker_id: str, account: Account) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] login_and_check account_id={account.id}",
        )
        if account.status == AccountStatus.NEW.value:
            async with AsyncSessionMaker() as session:
                await session.execute(
                    update(Account)
                    .where(Account.id == account.id)
                    .values(status=AccountStatus.ACTIVE.value)
                )
                await session.commit()
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] account {account.id} -> active (replace with real check)",
        )

    async def farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[stub] farm_tick account_id={account.id} "
                f"death_points_target={death_points_target}"
            ),
        )
        await asyncio.sleep(1)

    async def transfer_to_storage(
        self,
        *,
        task_id: str,
        worker_id: str,
        farmer_account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] transfer_to_storage farmer={farmer_account.id} payload={json.dumps(payload)}",
        )
        await asyncio.sleep(1)

    async def set_sell_price(
        self,
        *,
        task_id: str,
        worker_id: str,
        storage_account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] set_sell_price storage={storage_account.id} payload keys={list(payload)}",
        )
        await asyncio.sleep(1)


def get_game_adapter() -> GameAdapter:
    """
    - GAME_ADAPTER=stub (по умолчанию) — без Roblox, для проверки очереди.
    - GAME_ADAPTER=windows — каркас `WindowsGameAdapter` (нужно заполнить методы).
    """
    name = (os.getenv("GAME_ADAPTER") or "stub").strip().lower()
    if name == "stub":
        return StubGameAdapter()
    if name == "windows":
        return WindowsGameAdapter()
    raise RuntimeError(
        f"Unknown GAME_ADAPTER={name!r}. "
        "Use stub, windows, or register a new name in farm.game.adapter.get_game_adapter()."
    )


async def load_account_or_raise(task_id: str) -> Account:
    account = await get_task_account(task_id=task_id)
    if not account:
        raise RuntimeError("Task has no account")
    return account
