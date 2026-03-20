import json
import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import and_, select, update, text

from farm.database import AsyncSessionMaker
from farm.models import Account, Task, TaskLog, TaskStatus, Worker


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


async def ensure_worker(
    *,
    worker_id: str | None,
    role: str,
    account_id: str | None,
    hostname: str | None = None,
) -> str:
    if worker_id is None:
        worker_id = str(uuid.uuid4())

    async with AsyncSessionMaker() as session:
        existing = await session.scalar(select(Worker).where(Worker.id == worker_id))
        if existing:
            existing.role = role
            existing.account_id = account_id
            existing.hostname = hostname
        else:
            session.add(
                Worker(
                    id=worker_id,
                    role=role,
                    account_id=account_id,
                    hostname=hostname,
                )
            )
        await session.commit()

    return worker_id


async def heartbeat_worker(
    *,
    worker_id: str,
    last_error: str | None = None,
) -> None:
    async with AsyncSessionMaker() as session:
        await session.execute(
            update(Worker)
            .where(Worker.id == worker_id)
            .values(
                heartbeat_at=_now_utc(),
                last_seen_at=_now_utc(),
                last_error=last_error,
            )
        )
        await session.commit()


async def renew_running_tasks_lease(
    *,
    worker_id: str,
    lease_seconds: int = 90,
) -> None:
    async with AsyncSessionMaker() as session:
        lease_literal = f"interval '{int(lease_seconds)} seconds'"
        await session.execute(
            update(Task)
            .where(Task.status == TaskStatus.RUNNING.value, Task.worker_id == worker_id)
            .values(
                lease_expires_at=text(f"now() + {lease_literal}"),
                updated_at=_now_utc(),
            )
        )
        await session.commit()


async def create_task(
    *,
    task_type: str,
    priority: int,
    account_id: str | None = None,
    payload: dict[str, Any] | None = None,
) -> str:
    task_id = str(uuid.uuid4())
    serialized = json.dumps(payload) if payload is not None else None
    async with AsyncSessionMaker() as session:
        session.add(
            Task(
                id=task_id,
                task_type=task_type,
                status=TaskStatus.PENDING.value,
                priority=priority,
                account_id=account_id,
                worker_id=None,
                cancel_requested=False,
                lease_expires_at=None,
                payload=serialized,
            )
        )
        await session.commit()
    return task_id


async def append_task_log(
    *,
    task_id: str,
    message: str,
    level: str = "info",
    worker_id: str | None = None,
) -> None:
    async with AsyncSessionMaker() as session:
        session.add(
            TaskLog(
                task_id=task_id,
                worker_id=worker_id,
                level=level,
                message=message,
            )
        )
        await session.commit()


async def request_cancel_tasks(
    *,
    task_type: str | None = None,
    account_id: str | None = None,
    only_pending: bool = False,
) -> int:
    where = []
    if task_type is not None:
        where.append(Task.task_type == task_type)
    if account_id is not None:
        where.append(Task.account_id == account_id)

    async with AsyncSessionMaker() as session:
        q = select(Task.id, Task.status).where(and_(*where)) if where else select(Task.id, Task.status)
        ids = [(row[0], row[1]) for row in (await session.execute(q)).all()]

        pending_ids = [tid for tid, st in ids if st == TaskStatus.PENDING.value]
        running_ids = [tid for tid, st in ids if st == TaskStatus.RUNNING.value]

        if only_pending:
            if pending_ids:
                await session.execute(
                    update(Task)
                    .where(Task.id.in_(pending_ids))
                    .values(status=TaskStatus.CANCELLED.value, cancelled_at=_now_utc(), updated_at=_now_utc())
                )
        else:
            if pending_ids:
                await session.execute(
                    update(Task)
                    .where(Task.id.in_(pending_ids))
                    .values(status=TaskStatus.CANCELLED.value, cancelled_at=_now_utc(), updated_at=_now_utc())
                )
            if running_ids:
                await session.execute(
                    update(Task)
                    .where(Task.id.in_(running_ids))
                    .values(cancel_requested=True, updated_at=_now_utc())
                )

        await session.commit()

    return len(ids)


async def claim_next_task(
    *,
    worker_id: str,
    worker_account_id: str | None = None,
    lease_seconds: int = 90,
    max_tasks: int = 1,
) -> list[Task]:
    limit = max_tasks

    base_sql = """
        WITH cte AS (
          SELECT id
          FROM tasks
          WHERE (
            status = 'pending'
            OR (status = 'running' AND lease_expires_at < now())
          )
    """

    if worker_account_id is None:
        account_clause = ""
        params = {
            "worker_id": worker_id,
            "limit": limit,
            "lease_seconds": lease_seconds,
        }
    else:
        # Важно: сюда мы НЕ передаём NULL-параметры, поэтому asyncpg не сможет
        # «не определить тип параметра».
        account_clause = " AND (account_id IS NULL OR account_id = :account_id) "
        params = {
            "worker_id": worker_id,
            "account_id": worker_account_id,
            "limit": limit,
            "lease_seconds": lease_seconds,
        }

    sql = text(
        base_sql
        + account_clause
        + """
          ORDER BY priority DESC, created_at ASC
          LIMIT :limit
          FOR UPDATE SKIP LOCKED
        )
        UPDATE tasks
        SET status = 'running',
            worker_id = :worker_id,
            started_at = now(),
            lease_expires_at = now() + ((:lease_seconds || ' seconds')::interval),
            updated_at = now(),
            attempts = attempts + 1
        WHERE tasks.id IN (SELECT id FROM cte)
        RETURNING id, task_type, status, priority, account_id, worker_id, cancel_requested,
                  lease_expires_at, attempts, payload, last_error,
                  created_at, updated_at, started_at, finished_at, cancelled_at
        """
    )

    async with AsyncSessionMaker() as session:
        res = await session.execute(sql, params)
        rows = res.fetchall()
        await session.commit()

    claimed: list[Task] = []
    for row in rows:
        claimed.append(
            Task(
                id=row.id,
                task_type=row.task_type,
                status=row.status,
                priority=row.priority,
                account_id=row.account_id,
                worker_id=row.worker_id,
                cancel_requested=row.cancel_requested,
                lease_expires_at=row.lease_expires_at,
                attempts=row.attempts,
                payload=row.payload,
                last_error=row.last_error,
                created_at=row.created_at,
                updated_at=row.updated_at,
                started_at=row.started_at,
                finished_at=row.finished_at,
                cancelled_at=row.cancelled_at,
            )
        )

    return claimed


async def mark_task_done(*, task_id: str) -> None:
    async with AsyncSessionMaker() as session:
        await session.execute(
            update(Task)
            .where(Task.id == task_id)
            .values(
                status=TaskStatus.DONE.value,
                finished_at=_now_utc(),
                lease_expires_at=None,
                updated_at=_now_utc(),
            )
        )
        await session.commit()


async def mark_task_failed(*, task_id: str, error: str) -> None:
    async with AsyncSessionMaker() as session:
        await session.execute(
            update(Task)
            .where(Task.id == task_id)
            .values(
                status=TaskStatus.FAILED.value,
                finished_at=_now_utc(),
                lease_expires_at=None,
                last_error=error,
                updated_at=_now_utc(),
            )
        )
        await session.commit()


async def mark_task_cancelled(*, task_id: str) -> None:
    async with AsyncSessionMaker() as session:
        await session.execute(
            update(Task)
            .where(Task.id == task_id)
            .values(
                status=TaskStatus.CANCELLED.value,
                finished_at=_now_utc(),
                cancelled_at=_now_utc(),
                lease_expires_at=None,
                updated_at=_now_utc(),
            )
        )
        await session.commit()


async def is_task_cancel_requested(*, task_id: str) -> bool:
    async with AsyncSessionMaker() as session:
        row = await session.scalar(select(Task.cancel_requested).where(Task.id == task_id))
        return bool(row)


async def get_task_account(*, task_id: str) -> Account | None:
    async with AsyncSessionMaker() as session:
        task = await session.scalar(select(Task).where(Task.id == task_id))
        if not task or not task.account_id:
            return None
        return await session.scalar(select(Account).where(Account.id == task.account_id))
