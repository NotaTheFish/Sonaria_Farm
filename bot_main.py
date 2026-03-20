"""
Точка входа Telegram-контроллера (Railway / локально).

Запуск из корня репозитория:
  python bot_main.py
"""

import asyncio

from farm.controller.bot import main


if __name__ == "__main__":
    asyncio.run(main())
