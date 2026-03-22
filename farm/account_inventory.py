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

from sqlalchemy import update

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
