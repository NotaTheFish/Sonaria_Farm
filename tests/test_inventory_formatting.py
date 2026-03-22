"""Чистые функции разметки инвентаря (без БД)."""

from __future__ import annotations

import json
from datetime import datetime, timezone

from farm.inventory_formatting import (
    format_inventory_timestamp,
    format_token_lines_html,
    parse_inventory_json,
    split_telegram_chunks,
)


def test_parse_inventory_json_empty() -> None:
    assert parse_inventory_json(None) == {}
    assert parse_inventory_json("") == {}
    assert parse_inventory_json("  ") == {}


def test_parse_inventory_json_valid() -> None:
    raw = json.dumps({"Revive Token": 3})
    assert parse_inventory_json(raw) == {"Revive Token": 3}


def test_parse_inventory_json_invalid() -> None:
    assert parse_inventory_json("not json") == {}


def test_format_token_lines_known_order() -> None:
    order = ["A", "B"]
    html_out = format_token_lines_html({"B": 1, "A": 2, "Extra": "x"}, order)
    assert "A:" in html_out
    assert "B:" in html_out
    assert "Extra:" in html_out


def test_format_inventory_timestamp() -> None:
    assert "нет" in format_inventory_timestamp(None)
    ts = datetime(2026, 1, 15, 12, 30, tzinfo=timezone.utc)
    assert "2026-01-15" in format_inventory_timestamp(ts)


def test_split_telegram_chunks() -> None:
    short = "a\nb"
    assert split_telegram_chunks(short, max_len=100) == [short]
    long = "\n".join(["x" * 40] * 80)
    parts = split_telegram_chunks(long, max_len=200)
    assert len(parts) > 1
    assert all(len(p) <= 200 for p in parts)
