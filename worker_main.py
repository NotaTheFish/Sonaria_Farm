import asyncio
import json
import logging
import os
import socket
from typing import Any

from dotenv import load_dotenv

from models import AccountStatus, TaskType
from task_queue import (
    append_task_log,
    claim_next_task,
    ensure_worker,
    get_task_account,
    heartbeat_worker,
    is_task_cancel_requested,
    mark_task_cancelled,
    mark_task_done,
    mark_task_failed,
    renew_running_tasks_lease,
)


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("worker")


POLL_SECONDS = float(os.getenv("WORKER_POLL_SECONDS", "2.0"))
LEASE_SECONDS = int(os.getenv("WORKER_LEASE_SECONDS", "90"))


async def _simulate_login_and_check(task_id: str, worker_id: str) -> None:
    account = await get_task_account(task_id=task_id)
    if not account:
        raise RuntimeError("Task has no account")

    # Здесь будет реальная логика входа в Roblox и проверки состояния аккаунта.
    # Пока помечаем NEW -> ACTIVE как заглушку.
    await append_task_log(
        task_id=task_id,
        worker_id=worker_id,
        message=f"Checking account status for account_id={account.id}",
    )

    # NOTE: В реальной реализации обновляй статус по результату:
    # active / banned / invalid_credentials / checkpoint / disabled / cooldown
    if account.status == AccountStatus.NEW.value:
        from db import AsyncSessionMaker
        from sqlalchemy import update
        from models import Account

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
        message=f"Account {account.id} marked as active (stub).",
    )


async def _run_farm_loop(task_id: str, worker_id: str, payload: dict[str, Any]) -> None:
    # Бесконечный цикл до ручной остановки.
    # В реальном коде сюда вставляется Roblox automation.
    death_points_target = int(payload.get("death_points_target", 600))
    await append_task_log(
        task_id=task_id,
        worker_id=worker_id,
        message=f"Farm loop started. death_points_target={death_points_target}",
    )

    while True:
        # Регулярно продлеваем lease и heartbeat, чтобы задача не считалась брошенной.
        await renew_running_tasks_lease(worker_id=worker_id, lease_seconds=LEASE_SECONDS)
        await heartbeat_worker(worker_id=worker_id)

        if await is_task_cancel_requested(task_id=task_id):
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="warning",
                message="Cancel requested. Stopping farm loop.",
            )
            await mark_task_cancelled(task_id=task_id)
            return

        # Один "тик" игрового цикла (stub)
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message="Farm tick completed (stub).",
        )
        await asyncio.sleep(5)


async def _run_transfer_to_storage(task_id: str, worker_id: str, payload: dict[str, Any]) -> None:
    await append_task_log(
        task_id=task_id,
        worker_id=worker_id,
        message=f"Transfer started with payload={json.dumps(payload, ensure_ascii=False)}",
    )
    # TODO: Реальная логика transfer в Roblox.
    await asyncio.sleep(2)
    await mark_task_done(task_id=task_id)


async def _run_set_sell_price(task_id: str, worker_id: str, payload: dict[str, Any]) -> None:
    await append_task_log(
        task_id=task_id,
        worker_id=worker_id,
        message=f"Set-sell-price started with payload={json.dumps(payload, ensure_ascii=False)}",
    )
    # TODO: Реальная логика продажи в Roblox.
    await asyncio.sleep(2)
    await mark_task_done(task_id=task_id)


async def _run_stop_farm(task_id: str, worker_id: str) -> None:
    await append_task_log(
        task_id=task_id,
        worker_id=worker_id,
        message="Stop-farm task received.",
    )
    # stop_farm — короткая команда-подтверждение
    await mark_task_done(task_id=task_id)


async def process_task(task, worker_id: str) -> None:
    payload: dict[str, Any] = {}
    if task.payload:
        try:
            payload = json.loads(task.payload)
        except Exception:
            payload = {}

    try:
        if task.task_type == TaskType.LOGIN_AND_CHECK.value:
            await _simulate_login_and_check(task.id, worker_id)
            await mark_task_done(task_id=task.id)
            return

        if task.task_type == TaskType.START_FARM.value:
            await _run_farm_loop(task.id, worker_id, payload)
            return

        if task.task_type == TaskType.STOP_FARM.value:
            await _run_stop_farm(task.id, worker_id)
            return

        if task.task_type == TaskType.TRANSFER_TO_STORAGE.value:
            await _run_transfer_to_storage(task.id, worker_id, payload)
            return

        if task.task_type == TaskType.SET_SELL_PRICE.value:
            await _run_set_sell_price(task.id, worker_id, payload)
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

    role = os.getenv("WORKER_ROLE", "farmer")
    account_id = os.getenv("WORKER_ACCOUNT_ID")
    worker_id = os.getenv("WORKER_ID")
    hostname = socket.gethostname()

    worker_id = await ensure_worker(
        worker_id=worker_id,
        role=role,
        account_id=account_id,
        hostname=hostname,
    )
    logger.info("Worker started: id=%s role=%s account_id=%s", worker_id, role, account_id)

    while True:
        try:
            await heartbeat_worker(worker_id=worker_id)
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
                await process_task(task, worker_id)
        except Exception as exc:
            logger.exception("Worker loop error: %s", exc)
            await heartbeat_worker(worker_id=worker_id, last_error=str(exc))
            await asyncio.sleep(POLL_SECONDS)


if __name__ == "__main__":
    asyncio.run(main())

