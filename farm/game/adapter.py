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
import logging
import os
from abc import ABC, abstractmethod
from collections import defaultdict
from pathlib import Path
from typing import Any

logger = logging.getLogger("farm.game.adapter")

# Корень репозитория: farm/game/adapter.py -> parents[2] == <repo>/
_REPO_ROOT = Path(__file__).resolve().parents[2]


def _bridge_dir_from_env(var_name: str, default_relative: str) -> Path:
    """
    Каталог для файлового моста. Относительные пути считаются от корня репозитория,
    а не от текущего cwd процесса (иначе воркер не находит файлы при запуске из другой папки).
    """
    raw = os.getenv(var_name, default_relative)
    p = Path(raw)
    if not p.is_absolute():
        p = _REPO_ROOT / p
    return p

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

    def __init__(self) -> None:
        self.check_results_dir = _bridge_dir_from_env(
            "LOGIN_CHECK_RESULTS_DIR",
            "runtime/login_check_results",
        )
        self.check_timeout_seconds = int(os.getenv("LOGIN_CHECK_TIMEOUT_SECONDS", "180"))
        self.check_poll_seconds = float(os.getenv("LOGIN_CHECK_POLL_SECONDS", "1.0"))
        self.check_results_dir.mkdir(parents=True, exist_ok=True)

        self.farm_tick_dir = _bridge_dir_from_env("FARM_TICK_DIR", "runtime/farm_tick")
        self.farm_tick_timeout_seconds = int(os.getenv("FARM_TICK_TIMEOUT_SECONDS", "120"))
        self.farm_tick_poll_seconds = float(os.getenv("FARM_TICK_POLL_SECONDS", "1.0"))
        self.farm_tick_dir.mkdir(parents=True, exist_ok=True)
        self._farm_tick_seq: dict[str, int] = defaultdict(int)

        logger.info(
            "WindowsGameAdapter paths (absolute): LOGIN_CHECK_RESULTS_DIR=%s FARM_TICK_DIR=%s",
            self.check_results_dir.resolve(),
            self.farm_tick_dir.resolve(),
        )

    @staticmethod
    def _normalize_status(value: str | None) -> str | None:
        if not value:
            return None
        norm = value.strip().lower()
        allowed = {
            AccountStatus.ACTIVE.value,
            AccountStatus.BANNED.value,
            AccountStatus.INVALID_CREDENTIALS.value,
            AccountStatus.CHECKPOINT.value,
            AccountStatus.DISABLED.value,
            AccountStatus.COOLDOWN.value,
        }
        return norm if norm in allowed else None

    async def _set_account_status(
        self,
        *,
        account_id: str,
        status: str,
        reason: str | None = None,
    ) -> None:
        async with AsyncSessionMaker() as session:
            await session.execute(
                update(Account)
                .where(Account.id == account_id)
                .values(
                    status=status,
                    banned_reason=reason,
                )
            )
            await session.commit()

    async def login_and_check(self, *, task_id: str, worker_id: str, account: Account) -> None:
        """
        Рабочий базовый контракт:
        - внешний процесс проверки должен записать JSON-файл результата в LOGIN_CHECK_RESULTS_DIR
        - имя файла: <account_id>.json
        - формат:
            {
              "status": "active|banned|invalid_credentials|checkpoint|disabled|cooldown",
              "reason": "optional text"
            }
        """
        result_path = (self.check_results_dir / f"{account.id}.json").resolve()

        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] login_and_check started for account_id={account.id}. "
                f"Waiting result file (absolute): {result_path}"
            ),
        )

        waited = 0.0
        while waited < self.check_timeout_seconds:
            if result_path.exists():
                break
            await asyncio.sleep(self.check_poll_seconds)
            waited += self.check_poll_seconds

        if not result_path.exists():
            # Ничего не меняем в БД, задача упадет и пойдет в retry/ручную проверку.
            raise RuntimeError(
                "login_and_check result not found. "
                f"Expected file: {result_path} within {self.check_timeout_seconds}s"
            )

        try:
            data = json.loads(result_path.read_text(encoding="utf-8"))
        except Exception as exc:
            raise RuntimeError(f"Invalid login_and_check result JSON: {exc}") from exc
        finally:
            # Одноразовый файл результата (на Windows может не удалиться, если файл открыт в редакторе)
            try:
                result_path.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning(
                    "login_and_check: could not delete result file %s: %s",
                    result_path,
                    exc,
                )
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message=(
                        f"[windows] login_and_check: не удалось удалить файл результата "
                        f"(закройте его в редакторе): {result_path} — {exc}"
                    ),
                )

        status = self._normalize_status(str(data.get("status", "")))
        reason = data.get("reason")

        if not status:
            raise RuntimeError(
                "login_and_check result has unknown status. "
                "Allowed: active,banned,invalid_credentials,checkpoint,disabled,cooldown"
            )

        await self._set_account_status(
            account_id=account.id,
            status=status,
            reason=reason if isinstance(reason, str) else None,
        )

        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] login_and_check done for account_id={account.id}: "
                f"status={status}, reason={reason!r}"
            ),
        )

    async def farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
    ) -> None:
        """
        Один шаг цикла фарма через файловый мост (как login_and_check):

        1) Адаптер пишет: FARM_TICK_DIR/{task_id}.request.json
        2) Внешний процесс (инжектор/скрипт) выполняет шаг и пишет: FARM_TICK_DIR/{task_id}.response.json
        3) Адаптер читает ответ, опционально обновляет статус аккаунта, удаляет response.

        request.json:
          {
            "task_id": "...",
            "account_id": "...",
            "worker_id": "...",
            "death_points_target": 600,
            "tick_seq": 1
          }

        response.json:
          { "ok": true, "log": "optional", "death_points_current": 123,
            "account_status": null, "reason": null }
        или
          { "ok": false, "error": "..." }

        Если задан account_status (как в login_and_check) — обновляется accounts и воркер
        на следующей итерации увидит inactive.
        """
        self._farm_tick_seq[task_id] += 1
        tick_seq = self._farm_tick_seq[task_id]

        request_path = self.farm_tick_dir / f"{task_id}.request.json"
        response_path = self.farm_tick_dir / f"{task_id}.response.json"

        try:
            response_path.unlink(missing_ok=True)
        except Exception:
            pass

        request_payload = {
            "task_id": task_id,
            "account_id": account.id,
            "worker_id": worker_id,
            "death_points_target": death_points_target,
            "tick_seq": tick_seq,
        }
        request_path.write_text(
            json.dumps(request_payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] farm_tick tick_seq={tick_seq} account_id={account.id} "
                f"DP_target={death_points_target}. "
                f"Wrote request: {request_path}, waiting response: {response_path}"
            ),
        )

        waited = 0.0
        while waited < self.farm_tick_timeout_seconds:
            if response_path.exists():
                break
            await asyncio.sleep(self.farm_tick_poll_seconds)
            waited += self.farm_tick_poll_seconds

        if not response_path.exists():
            raise RuntimeError(
                "farm_tick response not found. "
                f"Expected file: {response_path} within {self.farm_tick_timeout_seconds}s"
            )

        try:
            data = json.loads(response_path.read_text(encoding="utf-8"))
        except Exception as exc:
            raise RuntimeError(f"Invalid farm_tick response JSON: {exc}") from exc
        finally:
            try:
                response_path.unlink(missing_ok=True)
            except Exception:
                pass
            try:
                request_path.unlink(missing_ok=True)
            except Exception:
                pass

        if not data.get("ok", False):
            err = data.get("error") or "farm_tick failed"
            raise RuntimeError(str(err))

        acc_status = self._normalize_status(
            str(data["account_status"]) if data.get("account_status") is not None else None
        )
        reason = data.get("reason")
        if acc_status:
            await self._set_account_status(
                account_id=account.id,
                status=acc_status,
                reason=reason if isinstance(reason, str) else None,
            )

        log_msg = data.get("log")
        dp_cur = data.get("death_points_current")
        extra = f" death_points_current={dp_cur}" if dp_cur is not None else ""
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[windows] farm_tick ok tick_seq={tick_seq}{extra}. {log_msg or ''}",
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
