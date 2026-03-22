"""Разбор и разметка снимка инвентаря для Telegram (HTML)."""

from __future__ import annotations

import html
import json
from datetime import datetime, timezone
from typing import Any


def parse_inventory_json(raw: str | None) -> dict[str, Any]:
    if raw is None or not str(raw).strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def format_token_lines_html(inv: dict[str, Any], token_order: list[str]) -> str:
    """Строки токенов: известный порядок, затем прочие ключи."""
    lines: list[str] = []
    for t in token_order:
        v = inv.get(t)
        name = html.escape(t)
        if v is None:
            lines.append(f"  {name}: —")
        else:
            lines.append(f"  {name}: <b>{html.escape(str(v))}</b>")
    extra_keys = sorted(k for k in inv if k not in token_order)
    for k in extra_keys:
        lines.append(f"  {html.escape(str(k))}: <b>{html.escape(str(inv[k]))}</b>")
    return "\n".join(lines)


def split_telegram_chunks(text: str, max_len: int = 3800) -> list[str]:
    """Делит длинный текст по строкам, чтобы уложиться в лимит Telegram (~4096)."""
    if len(text) <= max_len:
        return [text]
    out: list[str] = []
    buf: list[str] = []
    n = 0
    for line in text.split("\n"):
        add = len(line) + (1 if buf else 0)
        if n + add > max_len and buf:
            out.append("\n".join(buf))
            buf = [line]
            n = len(line)
        else:
            buf.append(line)
            n += add
    if buf:
        out.append("\n".join(buf))
    return out


def format_inventory_timestamp(ts: datetime | None) -> str:
    if ts is None:
        return "нет снимка"
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    else:
        ts = ts.astimezone(timezone.utc)
    return ts.strftime("%Y-%m-%d %H:%M UTC")
