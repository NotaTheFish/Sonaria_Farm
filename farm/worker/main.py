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
from typing import Any

from dotenv import load_dotenv

from sqlalchemy import select

from farm.database import AsyncSessionMaker, ensure_migrations_applied
from farm.game.adapter import GameAdapter, get_game_adapter, load_account_or_raise
from farm.models import Account, AccountStatus, TaskType
from farm.task_queue import (
    acquire_instance_for_worker,
    append_task_log,
    claim_next_task,
    ensure_worker,
    heartbeat_instance,
    heartbeat_worker,
    is_task_cancel_requested,
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

        if task.task_type == TaskType.STOP_FARM.value:
            await append_task_log(
                task_id=task.id,
                worker_id=worker_id,
                message="Stop-farm task received.",
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

    adapter = get_game_adapter()

    role = os.getenv("WORKER_ROLE", "farmer")
    account_id = os.getenv("WORKER_ACCOUNT_ID")
    worker_id = os.getenv("WORKER_ID")
    hostname = socket.gethostname()
    instance_name = os.getenv("WORKER_INSTANCE_NAME", f"{hostname}-instance-1")

    worker_id = await ensure_worker(
        worker_id=worker_id,
        role=role,
        account_id=account_id,
        hostname=hostname,
    )
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
