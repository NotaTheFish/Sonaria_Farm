"""
Точки расширения для Windows / Roblox.

Реализация живёт в `farm.game.adapter`: заглушка по умолчанию и место для твоего кода.

Экспорты подгружаются лениво, чтобы `import farm.game.file_bridge` не требовал SQLAlchemy
(удобно для лёгких тестов контракта моста).
"""

from __future__ import annotations

from typing import Any

__all__ = ["GameAdapter", "WindowsGameAdapter", "get_game_adapter"]


def __getattr__(name: str) -> Any:
    if name in __all__:
        from farm.game import adapter

        return getattr(adapter, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
