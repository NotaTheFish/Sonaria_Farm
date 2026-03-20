"""
Точки расширения для Windows / Roblox.

Реализация живёт в `farm.game.adapter`: заглушка по умолчанию и место для твоего кода.
"""

from farm.game.adapter import GameAdapter, WindowsGameAdapter, get_game_adapter

__all__ = ["GameAdapter", "WindowsGameAdapter", "get_game_adapter"]
