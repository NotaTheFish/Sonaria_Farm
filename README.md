# Sonaria Farm — контроллер + очередь + воркеры (Windows)

**Деплой:** бот на Railway, воркер на Windows — см. **[docs/GUIDE_WORKER_WINDOWS_RAILWAY.md](docs/GUIDE_WORKER_WINDOWS_RAILWAY.md)**. Шаблон переменных: **`env.template`** → скопировать в `.env`.

## Структура

| Путь | Назначение |
|------|------------|
| `farm/database.py` | Async SQLAlchemy engine, `ensure_migrations_applied()` |
| `farm/models.py` | ORM: accounts, workers, tasks, task_logs, settings |
| `farm/task_queue.py` | Создание/claim/отмена задач, lease, логи |
| `farm/controller/bot.py` | Telegram-бот (только админ) |
| `farm/worker/main.py` | Polling-воркер |
| `farm/game/adapter.py` | Файловые мосты Windows / `GameAdapter` |
| `scripts/file_bridge_echo.py` | Авто-`response.json` для теста мостов |
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

На Windows можно запускать по щелчку: **`run_bot.bat`**, **`run_worker.bat`** (корень репозитория; ищут `.venv` или `venv`). Переменные берутся из **`.env`** в том же каталоге.

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
   set WORKER_INSTANCE_NAME=pc1-slot-01
   python worker_main.py
   ```

`WORKER_INSTANCE_NAME` должен быть уникальным на каждый параллельный воркер/сессию.
Рекомендуемая модель: 1 воркер = 1 инстанс Roblox = 1 аккаунт в работе.

Если при старте видишь `Instance '...' is busy by another worker` — это старый `worker_id` в БД после закрытия процесса. Варианты: задать в `.env` тот же **`WORKER_ID`**, что у «занявшего» воркера; подождать **`WORKER_STALE_HEARTBEAT_SECONDS`** (по умолчанию 180 с) без heartbeat от старого процесса — тогда новый воркер **перехватит** инстанс; либо поправить строку в таблице `instances` вручную.

## Игровая логика

Реализуй подкласс `GameAdapter` в `farm/game/adapter.py` (или отдельном модуле) и зарегистрируй в `get_game_adapter()`.  
Воркер **не** получает логин/пароль в задаче — только `account_id`; учётные данные читаются из таблицы `accounts` внутри адаптера.

### Login and check (текущая реализация для `GAME_ADAPTER=windows`)

`WindowsGameAdapter.login_and_check()` сейчас работает как мост через файл результата:

- воркер ждёт файл:  
  `LOGIN_CHECK_RESULTS_DIR/<account_id>.json`
- по умолчанию: `runtime/login_check_results/<account_id>.json`
- формат:

```json
{
  "status": "active",
  "reason": "optional text"
}
```

Разрешённые `status`:
- `active`
- `banned`
- `invalid_credentials`
- `checkpoint`
- `disabled`
- `cooldown`

После чтения файла адаптер:
- обновляет `accounts.status` и `accounts.banned_reason`
- удаляет result-файл (одноразовый)

Если файл не появился в таймаут — задача `login_and_check` завершится ошибкой.

**Важно при тестах**

- Файл читается и удаляется **только когда воркер взял из БД задачу** `login_and_check` с `account_id`, совпадающим с именем файла (`<account_id>.json`). Один запущенный воркер без задачи в очереди **ничего не делает** с каталогом результатов.
- Имя файла = **`accounts.id` в PostgreSQL**, не логин.
- По умолчанию каталог резолвится **от корня репозитория** (`runtime/login_check_results`), а не от текущего `cwd`, чтобы путь совпадал независимо от того, откуда запущен `python worker_main.py`.
- На Windows удаление может не сработать, если JSON **открыт в редакторе** с блокировкой файла — закрой вкладку или смотри предупреждение в логах / `task_logs`.

### Farm tick (цикл фарма, `GAME_ADAPTER=windows`)

Каждый вызов `WindowsGameAdapter.farm_tick()` — один шаг через файловый мост:

1. Воркер создаёт запрос: `FARM_TICK_DIR/<task_id>.request.json` (по умолчанию `runtime/farm_tick/`).
2. Внешний процесс читает запрос и пишет ответ: **`FARM_TICK_DIR/<task_id>.response.json`** (каталог по умолчанию: **`…\sonaria_farm\runtime\farm_tick`**, не корень репозитория в Проводнике). Допустимо имя **`<task_id>.resp.json`** — если сократил «response» по привычке.
3. Адаптер читает ответ, при необходимости обновляет статус аккаунта, удаляет оба файла.

При **каждом** новом тике для текущей задачи воркер удаляет из `FARM_TICK_DIR` все `*.request.json` / `*.response.json` с **другим** `task_id` — чтобы не копились хвосты после смены задачи «Запустить фарм» или падения прошлого цикла.

Если после сбоя остался «лишний» `response` для **той же** задачи (не удалился из‑за блокировки файла), включи в `.env` **`FARM_TICK_CLEAN_ON_START=1`** — при следующем запуске воркера каталог моста обнулится (один воркер на эту папку).

**request.json** (пример):

```json
{
  "task_id": "uuid-задачи-start_farm",
  "account_id": "uuid-аккаунта",
  "worker_id": "worker-1",
  "death_points_target": 600,
  "tick_seq": 1
}
```

**response.json** — успех:

```json
{
  "ok": true,
  "log": "optional текст в task_logs",
  "death_points_current": 123,
  "account_status": null,
  "reason": null
}
```

Опционально `account_status` / `reason` — как у `login_and_check` (если статус не `active`, воркер на следующей итерации остановит фарм).

**response.json** — ошибка:

```json
{
  "ok": false,
  "error": "описание ошибки"
}
```

Переменные окружения: `FARM_TICK_DIR`, `FARM_TICK_TIMEOUT_SECONDS`, `FARM_TICK_POLL_SECONDS`.

**Windows / Блокнот:** если создаёшь ответ как **новый текстовый файл**, вставляешь JSON и **переименовываешь** в `…response.json`, содержимое часто остаётся в **UTF-16** (так пишет Notepad). Воркер теперь пробует и UTF-8, и UTF-16. Надёжнее: **«Сохранить как» → UTF-8** или сразу создавай файл в Cursor/VS Code с кодировкой UTF-8.

Если при переименовании осталось скрытое **`.txt`** (`…response.json.txt`) — такой файл тоже принимается.

В Проводнике полезно включить **«Расширения имён файлов»**, чтобы видеть полное имя.

Если ответ не подхватывается: смотри **консоль воркера** — раз в `FARM_TICK_DIAGNOSTIC_SECONDS` (по умолчанию 15 с) пишется **полный путь** ожидаемого файла и список имён в `FARM_TICK_DIR` с этим `task_id`. Частая ошибка — положить JSON в **другую копию** репозитория (другой диск/папка), чем та, откуда запущен `worker_main.py`.

### Transfer → склад и выставление цен (`GAME_ADAPTER=windows`)

Один обмен на задачу (без цикла, как один `farm_tick`):

| Задача бота | Каталог (по умолчанию) | `request.json` содержит |
|-------------|------------------------|-------------------------|
| `transfer_to_storage` | `runtime/transfer_bridge/` | `bridge`, `task_id`, `worker_id`, `farmer_account_id`, `payload` (как в боте) |
| `set_sell_price` | `runtime/sell_bridge/` | `bridge`, `task_id`, `worker_id`, `storage_account_id`, `payload` |

**response.json** (как у farm_tick):

```json
{ "ok": true, "log": "optional", "account_status": null, "reason": null }
```

или `{ "ok": false, "error": "..." }`.

Переменные: `TRANSFER_BRIDGE_DIR`, `TRANSFER_BRIDGE_TIMEOUT_SECONDS`, `SELL_BRIDGE_DIR`, `SELL_BRIDGE_*` (по умолчанию те же таймауты, что у `FARM_TICK_*`).

### Скрипт авто-ответа (тест очереди)

Из корня репозитория:

```bash
python scripts/file_bridge_echo.py
```

Следит за `runtime/farm_tick`, `transfer_bridge`, `sell_bridge` и на каждый новый `*.request.json` пишет `*.response.json` с `"ok": true`. **Не запускай** одновременно с ручной отладкой фарма, если не хочешь мгновенных тиков.

## Старые наброски

Каталоги `core/`, `strategies/`, `telegram_bot/`, `bypass_methods/`, `utils/` и `main.py` удалены как устаревшие (SQLite-оркестратор). История — в git, если репозиторий подключён.
