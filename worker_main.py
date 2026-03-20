"""
Точка входа воркера (Windows).

Запуск из корня репозитория:
  python worker_main.py
"""

import asyncio

from farm.worker.main import main


if __name__ == "__main__":
    asyncio.run(main())
