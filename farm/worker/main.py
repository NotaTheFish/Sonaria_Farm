"""
Точка входа воркера (Windows / сервер Windows).

Запуск из корня репозитория:
  python worker_main.py
или:
  python -m farm.worker.main
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import socket
from datetime import datetime, timezone
from typing import Any

from dotenv import load_dotenv

from sqlalchemy import select

from farm.database import AsyncSessionMaker, ensure_migrations_applied
from farm.game.adapter import GameAdapter, get_game_adapter, load_account_or_raise
from farm.game.check_injector import collect_status
from farm.game.stop_flags import clear_stop_flag, write_stop_flag
from farm.models import Account, AccountStatus, Instance, InstanceStatus, TaskType, Worker
from farm.task_queue import (
    acquire_instance_for_worker,
    append_task_log,
    claim_next_task,
    ensure_worker,
    heartbeat_instance,
    heartbeat_worker,
    is_task_cancel_requested,
    _nullable_fk_account_id,
    _nullable_worker_id,
    request_cancel_tasks,
    mark_task_cancelled,
    mark_task_done,
    mark_task_failed,
    renew_running_tasks_lease,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("farm.worker")

POLL_SECONDS = float(os.getenv("WORKER_POLL_SECONDS", "2.0"))
LEASE_SECONDS = int(os.getenv("WORKER_LEASE_SECONDS", "90"))


def _truthy_env(name: str, default: str = "0") -> bool:
    val = (os.getenv(name, default) or "").strip().lower()
    return val in ("1", "true", "yes", "on")


def _preflight_mode() -> str:
    raw = (os.getenv("WORKER_PREFLIGHT_MODE") or "strict").strip().lower()
    return raw if raw in ("strict", "warn") else "strict"


def _run_worker_preflight_if_enabled() -> None:
    if not _truthy_env("WORKER_PREFLIGHT_CHECK", "0"):
        return
    mode = _preflight_mode()
    status = collect_status()
    logger.info(
        "Preflight: mode=%s backend=%s enabled=%s roblox_pid=%s legacy_ready=%s universal_ready=%s",
        mode,
        status.get("backend"),
        status.get("enabled"),
        status.get("roblox_pid"),
        status.get("legacy_ready"),
        status.get("universal_ready"),
    )
    issues = status.get("issues") or []
    if issues:
        joined = "; ".join(str(x) for x in issues)
        if mode == "warn":
            logger.warning("Worker preflight warnings: %s", joined)
            return
        raise RuntimeError(f"Worker preflight failed: {joined}")


async def _preflight_instance_conflict(*, worker_id: str, instance_name: str) -> None:
    """
    Ранняя диагностика конфликта инстанса до acquire_instance_for_worker.
    Использует ту же stale-логику, что и task_queue.acquire_instance_for_worker.
    """
    async with AsyncSessionMaker() as session:
        instance = await session.scalar(select(Instance).where(Instance.name == instance_name))
        if not instance:
            logger.info("Preflight instance: %s is free (no row in instances).", instance_name)
            return

        if instance.status != InstanceStatus.BUSY.value:
            logger.info(
                "Preflight instance: %s exists with status=%s (not busy).",
                instance_name,
                instance.status,
            )
            return

        if not instance.worker_id or instance.worker_id == worker_id:
            logger.info(
                "Preflight instance: %s is already assigned to current worker_id=%s.",
                instance_name,
                worker_id,
            )
            return

        stale_sec = int(os.getenv("WORKER_STALE_HEARTBEAT_SECONDS", "180"))
        old_worker = await session.scalar(select(Worker).where(Worker.id == instance.worker_id))
        takeover = False
        if old_worker is None:
            reason = "worker row missing"
            takeover = True
        else:
            age = (datetime.now(timezone.utc) - old_worker.heartbeat_at).total_seconds()
            if age > stale_sec:
                reason = f"heartbeat stale {age:.0f}s > {stale_sec}s"
                takeover = True
            else:
                reason = f"heartbeat fresh {age:.0f}s"

        mode = _preflight_mode() if _truthy_env("WORKER_PREFLIGHT_CHECK", "0") else "warn"
        msg = (
            f"Preflight instance conflict: '{instance_name}' busy by worker {instance.worker_id}. "
            f"Set WORKER_ID={instance.worker_id}, stop old process, or wait stale timeout. ({reason})"
        )
        if takeover:
            logger.warning("%s Will attempt takeover on acquire.", msg)
            return
        if mode == "warn":
            logger.warning("%s", msg)
            return
        raise RuntimeError(msg)


def _inactive_account_statuses() -> set[str]:
    return {
        AccountStatus.BANNED.value,
        AccountStatus.INVALID_CREDENTIALS.value,
        AccountStatus.DISABLED.value,
        AccountStatus.CHECKPOINT.value,
        AccountStatus.COOLDOWN.value,
    }


async def _reload_account(account_id: str) -> Account | None:
    async with AsyncSessionMaker() as session:
        return await session.scalar(select(Account).where(Account.id == account_id))


async def _run_farm_loop(
    adapter: GameAdapter,
    task_id: str,
    worker_id: str,
    payload: dict[str, Any],
) -> None:
    death_points_target = int(payload.get("death_points_target", 600))
    account = await load_account_or_raise(task_id)
    account_id = account.id

    await append_task_log(
        task_id=task_id,
        worker_id=worker_id,
        message=f"Farm loop started. death_points_target={death_points_target}",
    )

    clear_stop_flag(account_id)

    while True:
        fresh = await _reload_account(account_id)
        if fresh is not None:
            account = fresh

        await renew_running_tasks_lease(worker_id=worker_id, lease_seconds=LEASE_SECONDS)
        await heartbeat_worker(worker_id=worker_id)

        if await is_task_cancel_requested(task_id=task_id):
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="warning",
                message="Cancel requested. Stopping farm loop.",
            )
            try:
                flag_path = write_stop_flag(account_id)
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    message=f"Stop flag written for Lua: {flag_path}",
                )
            except OSError as exc:
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message=f"Could not write stop flag: {exc}",
                )
            try:
                await adapter.on_start_farm_cancel(task_id=task_id, worker_id=worker_id, account=account)
            except Exception as exc:
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message=f"Adapter cancel hook failed: {exc}",
                )
            # Чтобы stop_farm tasks не копились в pending после отмены start_farm
            await request_cancel_tasks(
                task_type=TaskType.STOP_FARM.value,
                account_id=account_id,
                only_pending=True,
            )
            await mark_task_cancelled(task_id=task_id)
            return

        if account.status in _inactive_account_statuses():
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="error",
                message=f"Account inactive (status={account.status}). Stopping farm.",
            )
            # Убираем pending-задачи, которые могут пытаться использовать этот аккаунт
            await request_cancel_tasks(
                account_id=account_id,
                only_pending=True,
            )
            await mark_task_failed(
                task_id=task_id,
                error=f"account_inactive:{account.status}",
            )
            return

        await adapter.farm_tick(
            task_id=task_id,
            worker_id=worker_id,
            account=account,
            death_points_target=death_points_target,
        )


async def _run_universal_farm_loop(
    adapter: GameAdapter,
    task_id: str,
    worker_id: str,
    payload: dict[str, Any],
) -> None:
    death_points_target = int(payload.get("death_points_target", 600))
    account = await load_account_or_raise(task_id)
    account_id = account.id

    await append_task_log(
        task_id=task_id,
        worker_id=worker_id,
        message=f"Universal farm loop started (Kimi). death_points_target={death_points_target}",
    )

    clear_stop_flag(account_id)

    while True:
        fresh = await _reload_account(account_id)
        if fresh is not None:
            account = fresh

        await renew_running_tasks_lease(worker_id=worker_id, lease_seconds=LEASE_SECONDS)
        await heartbeat_worker(worker_id=worker_id)

        if await is_task_cancel_requested(task_id=task_id):
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="warning",
                message="Cancel requested. Stopping universal farm loop.",
            )
            try:
                flag_path = write_stop_flag(account_id)
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    message=f"Stop flag written for Lua: {flag_path}",
                )
            except OSError as exc:
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message=f"Could not write stop flag: {exc}",
                )
            try:
                await adapter.on_start_farm_cancel(task_id=task_id, worker_id=worker_id, account=account)
            except Exception as exc:
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message=f"Adapter cancel hook failed: {exc}",
                )
            await request_cancel_tasks(
                task_type=TaskType.STOP_FARM.value,
                account_id=account_id,
                only_pending=True,
            )
            await mark_task_cancelled(task_id=task_id)
            return

        if account.status in _inactive_account_statuses():
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="error",
                message=f"Account inactive (status={account.status}). Stopping universal farm.",
            )
            await request_cancel_tasks(
                account_id=account_id,
                only_pending=True,
            )
            await mark_task_failed(
                task_id=task_id,
                error=f"account_inactive:{account.status}",
            )
            return

        await adapter.universal_farm_tick(
            task_id=task_id,
            worker_id=worker_id,
            account=account,
            death_points_target=death_points_target,
        )


async def process_task(adapter: GameAdapter, task, worker_id: str) -> None:
    payload: dict[str, Any] = {}
    if task.payload:
        try:
            payload = json.loads(task.payload)
        except Exception:
            payload = {}

    try:
        if task.task_type == TaskType.LOGIN_AND_CHECK.value:
            account = await load_account_or_raise(task.id)
            await adapter.login_and_check(task_id=task.id, worker_id=worker_id, account=account)
            await mark_task_done(task_id=task.id)
            return

        if task.task_type == TaskType.START_FARM.value:
            await _run_farm_loop(adapter, task.id, worker_id, payload)
            return

        if task.task_type == TaskType.UNIVERSAL_FARM.value:
            await _run_universal_farm_loop(adapter, task.id, worker_id, payload)
            return

        if task.task_type == TaskType.STOP_FARM.value:
            account = await load_account_or_raise(task.id)
            await append_task_log(
                task_id=task.id,
                worker_id=worker_id,
                message="Stop-farm task received.",
            )
            try:
                flag_path = write_stop_flag(account.id)
                await append_task_log(
                    task_id=task.id,
                    worker_id=worker_id,
                    message=f"Stop flag written for Lua: {flag_path}",
                )
            except OSError as exc:
                await append_task_log(
                    task_id=task.id,
                    worker_id=worker_id,
                    level="warning",
                    message=f"Could not write stop flag: {exc}",
                )
            await mark_task_done(task_id=task.id)
            return

        if task.task_type == TaskType.UNIVERSAL_TRANSFER.value:
            farmer = await load_account_or_raise(task.id)
            if farmer.status in _inactive_account_statuses():
                await append_task_log(
                    task_id=task.id,
                    worker_id=worker_id,
                    level="error",
                    message=f"Farmer account inactive status={farmer.status}. Skip universal transfer.",
                )
                await mark_task_failed(
                    task_id=task.id,
                    error=f"account_inactive:{farmer.status}",
                )
                return
            await adapter.universal_transfer(
                task_id=task.id,
                worker_id=worker_id,
                farmer_account=farmer,
                payload=payload,
            )
            await mark_task_done(task_id=task.id)
            return

        if task.task_type == TaskType.UNIVERSAL_SELL.value:
            storage = await load_account_or_raise(task.id)
            if storage.status in _inactive_account_statuses():
                await append_task_log(
                    task_id=task.id,
                    worker_id=worker_id,
                    level="error",
                    message=f"Storage account inactive status={storage.status}. Skip universal sell.",
                )
                await mark_task_failed(
                    task_id=task.id,
                    error=f"account_inactive:{storage.status}",
                )
                return
            await adapter.universal_sell(
                task_id=task.id,
                worker_id=worker_id,
                storage_account=storage,
                payload=payload,
            )
            await mark_task_done(task_id=task.id)
            return

        if task.task_type == TaskType.UNIVERSAL_INVENTORY.value:
            account = await load_account_or_raise(task.id)
            if account.status in _inactive_account_statuses():
                await append_task_log(
                    task_id=task.id,
                    worker_id=worker_id,
                    level="error",
                    message=f"Account inactive status={account.status}. Skip universal inventory.",
                )
                await mark_task_failed(
                    task_id=task.id,
                    error=f"account_inactive:{account.status}",
                )
                return
            await adapter.universal_inventory(
                task_id=task.id,
                worker_id=worker_id,
                account=account,
                payload=payload,
            )
            await mark_task_done(task_id=task.id)
            return

        if task.task_type == TaskType.UNIVERSAL_DEX.value:
            account = await load_account_or_raise(task.id)
            await adapter.universal_dex(
                task_id=task.id,
                worker_id=worker_id,
                account=account,
                payload=payload,
            )
            await mark_task_done(task_id=task.id)
            return

        if task.task_type == TaskType.TRANSFER_TO_STORAGE.value:
            farmer = await load_account_or_raise(task.id)
            if farmer.status in _inactive_account_statuses():
                await append_task_log(
                    task_id=task.id,
                    worker_id=worker_id,
                    level="error",
                    message=f"Farmer account inactive status={farmer.status}. Skip transfer.",
                )
                await mark_task_failed(
                    task_id=task.id,
                    error=f"account_inactive:{farmer.status}",
                )
                return
            await adapter.transfer_to_storage(
                task_id=task.id,
                worker_id=worker_id,
                farmer_account=farmer,
                payload=payload,
            )
            await mark_task_done(task_id=task.id)
            return

        if task.task_type == TaskType.SET_SELL_PRICE.value:
            storage = await load_account_or_raise(task.id)
            if storage.status in _inactive_account_statuses():
                await append_task_log(
                    task_id=task.id,
                    worker_id=worker_id,
                    level="error",
                    message=f"Storage account inactive status={storage.status}. Skip sell-price.",
                )
                await mark_task_failed(
                    task_id=task.id,
                    error=f"account_inactive:{storage.status}",
                )
                return
            await adapter.set_sell_price(
                task_id=task.id,
                worker_id=worker_id,
                storage_account=storage,
                payload=payload,
            )
            await mark_task_done(task_id=task.id)
            return

        raise RuntimeError(f"Unsupported task type: {task.task_type}")
    except Exception as exc:
        await append_task_log(
            task_id=task.id,
            worker_id=worker_id,
            level="error",
            message=f"Task failed: {exc}",
        )
        await mark_task_failed(task_id=task.id, error=str(exc))


async def main() -> None:
    load_dotenv()
    await ensure_migrations_applied()
    _run_worker_preflight_if_enabled()

    adapter = get_game_adapter()

    role = os.getenv("WORKER_ROLE", "farmer")
    account_id = _nullable_fk_account_id(os.getenv("WORKER_ACCOUNT_ID"))
    worker_id = _nullable_worker_id(os.getenv("WORKER_ID"))
    hostname = socket.gethostname()
    instance_name = os.getenv("WORKER_INSTANCE_NAME", f"{hostname}-instance-1")

    worker_id = await ensure_worker(
        worker_id=worker_id,
        role=role,
        account_id=account_id,
        hostname=hostname,
    )
    await _preflight_instance_conflict(worker_id=worker_id, instance_name=instance_name)
    await acquire_instance_for_worker(
        worker_id=worker_id,
        instance_name=instance_name,
        host=hostname,
        account_id=account_id,
    )
    logger.info(
        "Worker started: id=%s role=%s account_id=%s instance=%s adapter=%s",
        worker_id,
        role,
        account_id,
        instance_name,
        os.getenv("GAME_ADAPTER", "stub"),
    )

    while True:
        try:
            await heartbeat_worker(worker_id=worker_id)
            await heartbeat_instance(instance_name=instance_name)
            tasks = await claim_next_task(
                worker_id=worker_id,
                worker_account_id=account_id,
                lease_seconds=LEASE_SECONDS,
                max_tasks=1,
            )
            if not tasks:
                await asyncio.sleep(POLL_SECONDS)
                continue

            for task in tasks:
                await append_task_log(
                    task_id=task.id,
                    worker_id=worker_id,
                    message=f"Claimed task type={task.task_type} account_id={task.account_id}",
                )
                await process_task(adapter, task, worker_id)
        except Exception as exc:
            logger.exception("Worker loop error: %s", exc)
            await heartbeat_worker(worker_id=worker_id, last_error=str(exc))
            await asyncio.sleep(POLL_SECONDS)


if __name__ == "__main__":
    asyncio.run(main())
