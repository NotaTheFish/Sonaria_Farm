"""
Файлы-флаги остановки фарма для Lua (путь передаётся в script_params.stop_flag_path).

Воркер создаёт файл при отмене задачи start_farm; при старте цикла фарма старый флаг удаляется.
"""

from __future__ import annotations

import os
from pathlib import Path

from farm.game import file_bridge as fb

ENV_STOP_FLAG_DIR = "STOP_FLAG_DIR"


def stop_flag_dir() -> Path:
    raw = os.getenv(ENV_STOP_FLAG_DIR, "runtime/stop_flags").strip()
    return fb.resolve_repo_relative(raw)


def stop_flag_path(account_id: str) -> Path:
    d = stop_flag_dir()
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{account_id}.stop"


def clear_stop_flag(account_id: str) -> None:
    try:
        stop_flag_path(account_id).unlink(missing_ok=True)
    except OSError:
        pass


def write_stop_flag(account_id: str) -> Path:
    """Создаёт/обновляет флаг; возвращает абсолютный путь (для логов)."""
    p = stop_flag_path(account_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("1\n", encoding="utf-8")
    return p.resolve()
