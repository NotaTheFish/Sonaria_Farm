# Sonaria Farm — контроллер + очередь + воркеры (Windows)

## Структура

| Путь | Назначение |
|------|------------|
| `farm/database.py` | Async SQLAlchemy engine, `ensure_migrations_applied()` |
| `farm/models.py` | ORM: accounts, workers, tasks, task_logs, settings |
| `farm/task_queue.py` | Создание/claim/отмена задач, lease, логи |
| `farm/controller/bot.py` | Telegram-бот (только админ) |
| `farm/worker/main.py` | Polling-воркер |
| `farm/game/adapter.py` | **Точка расширения**: Roblox / Sonaria (твоя реализация) |
| `alembic/` | Миграции PostgreSQL |

Корневые шимы для удобства деплоя:

- `bot_main.py` → `farm.controller.bot`
- `worker_main.py` → `farm.worker.main`

## Окружение Python (Windows)

Ошибки `ModuleNotFoundError: No module named 'sqlalchemy'` / `'aiogram'` значат, что зависимости не установлены в **том** интерпретаторе, которым ты запускаешь `python`.

Из корня репозитория:

```powershell
cd C:\sonaria_farm
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -U pip
pip install -r requirements.txt
```

Если `pip install -r requirements.txt` падает (права, кэш) — для проверки бота и воркера со stub достаточно:

```powershell
pip install -r requirements-minimal.txt
```

Полный список (OpenCV, pyautogui, tesseract…) нужен, когда будешь дописывать `WindowsGameAdapter` под свой способ управления клиентом.

Проверка:

```powershell
python -c "import sqlalchemy, aiogram; print('ok')"
```

Дальше запускай `python bot_main.py` / `python worker_main.py` **только с активированным venv** (или укажи полный путь: `.\.venv\Scripts\python.exe bot_main.py`).

## Запуск

1. Переменные окружения — см. `config.example.env`
2. Миграции:
   ```bash
   alembic upgrade head
   ```
3. Контроллер:
   ```bash
   python bot_main.py
   ```
4. Воркер (на каждой машине / на аккаунт — по `WORKER_ACCOUNT_ID`):
   ```bash
   set DATABASE_URL=...
   set GAME_ADAPTER=stub
   python worker_main.py
   ```

## Игровая логика

Реализуй подкласс `GameAdapter` в `farm/game/adapter.py` (или отдельном модуле) и зарегистрируй в `get_game_adapter()`.  
Воркер **не** получает логин/пароль в задаче — только `account_id`; учётные данные читаются из таблицы `accounts` внутри адаптера.

## Старые наброски

Каталоги `core/`, `strategies/`, `telegram_bot/`, `bypass_methods/`, `utils/` и `main.py` удалены как устаревшие (SQLite-оркестратор). История — в git, если репозиторий подключён.
