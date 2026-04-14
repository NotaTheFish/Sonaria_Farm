"""
Снимок инвентаря аккаунта в БД (заполняется из ответов файлового моста WindowsGameAdapter).

В `response.json` опционально передаётся объект `inventory`: словарь имя_токена → число
(или строки — сериализуются через default=str).
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import select, update

from farm.database import AsyncSessionMaker
from farm.models import Account

logger = logging.getLogger("farm.account_inventory")


async def save_account_inventory_snapshot(account_id: str, inventory: dict[str, Any]) -> None:
    """Сохраняет JSON-снимок и время обновления для аккаунта."""
    if not inventory:
        return
    now = datetime.now(timezone.utc)
    try:
        payload = json.dumps(inventory, ensure_ascii=False, default=str)
    except (TypeError, ValueError) as exc:
        logger.warning("inventory snapshot: cannot serialize for account_id=%s: %s", account_id, exc)
        return

    async with AsyncSessionMaker() as session:
        await session.execute(
            update(Account)
            .where(Account.id == account_id)
            .values(
                inventory_json=payload,
                inventory_updated_at=now,
            )
        )
        await session.commit()


async def accumulate_earned_tokens(account_id: str, new_tokens: dict[str, int]) -> None:
    """
    Суммирует новые death-reward токены с ранее сохранёнными в Account.earned_tokens_json.

    new_tokens: {"Random Trial Creature Token": 1, "Appearance Change Token": 1, ...}
    """
    if not new_tokens:
        return
    now = datetime.now(timezone.utc)
    async with AsyncSessionMaker() as session:
        row = await session.execute(
            select(Account.earned_tokens_json).where(Account.id == account_id)
        )
        existing_raw = row.scalar_one_or_none()
        existing: dict[str, int] = {}
        if existing_raw:
            try:
                existing = json.loads(existing_raw)
            except (json.JSONDecodeError, TypeError):
                pass

        for token_name, count in new_tokens.items():
            if not isinstance(count, (int, float)):
                continue
            existing[token_name] = existing.get(token_name, 0) + int(count)

        payload = json.dumps(existing, ensure_ascii=False)
        await session.execute(
            update(Account)
            .where(Account.id == account_id)
            .values(
                earned_tokens_json=payload,
                earned_tokens_updated_at=now,
            )
        )
        await session.commit()
        logger.info("earned_tokens accumulated for account_id=%s: %s", account_id, payload)
