# Гайд: контроллер на Railway, воркер на Windows (CMD)

Схема: **одна PostgreSQL** (обычно плагин на Railway), к ней подключаются и **бот** (Railway), и **воркер** (твой ПК). Очередь задач и аккаунты живут в БД; воркер только забирает задачи и пишет/читает файлы моста в `runtime/`.

---

## 1. Что должно быть готово

| Компонент | Где | Роль |
|-----------|-----|------|
| PostgreSQL | Railway (или внешний хост) | Общая БД |
| `python bot_main.py` | Railway | Telegram-контроллер |
| `python worker_main.py` | Windows, CMD | Исполнение задач + файловый мост |

**Важно:** строка `DATABASE_URL` у бота и у воркера должна указывать **на одну и ту же базу**.

---

## 2. Переменные окружения

### 2.1 Railway (сервис с ботом)

В **Railway → твой сервис → Variables** задай:

| Переменная | Описание |
|------------|----------|
| `TELEGRAM_BOT_TOKEN` | Токен от @BotFather |
| `ADMIN_TELEGRAM_ID` | Твой числовой Telegram ID (только админ) |
| `DATABASE_URL` | URL Postgres (Railway часто даёт `postgresql://...` — **можно оставить как есть**, код сам переведёт в `postgresql+asyncpg://` для async) |

Опционально:

| Переменная | Описание |
|------------|----------|
| `ALEMBIC_EXPECTED_REVISION` | Если хочешь жёстко проверять ревизию миграций при старте бота |

**Команда старта** в Railway (Settings → Deploy → Start Command), если не задана иначе:

```text
python bot_main.py
```

Убедись, что в деплой попадают зависимости (`requirements.txt` / Dockerfile).

### 2.2 Windows (только воркер)

В корне репозитория файл **`.env`** (скопируй из `env.template` в корне проекта и заполни).

Минимум для воркера:

- `DATABASE_URL` — **тот же**, что на Railway (из вкладки Postgres **Connect** / **Public URL**, если подключаешься с ПК).
- `GAME_ADAPTER=windows`

Остальное — из шаблона (`WORKER_ID`, `WORKER_INSTANCE_NAME`, таймауты моста и т.д.).

**Подключение с домашнего ПК к Railway Postgres:** на многих планах нужно включить **публичный доступ** / **TCP proxy** к БД и разрешить подключение с твоего IP (или 0.0.0.0 для теста — осторожно с безопасностью). Если коннект не идёт — смотри документацию Railway по Postgres networking.

---

## 3. Миграции Alembic

Бот и воркер при старте вызывают `ensure_migrations_applied()` — в `alembic_version` должна быть актуальная ревизия.

Удобные варианты:

1. **Один раз с ПК** (в CMD, из корня репозитория, с тем же `DATABASE_URL` в `.env`):

   ```cmd
   cd /d C:\sonaria_farm
   .venv\Scripts\activate.bat
   alembic upgrade head
   ```

2. **В CI / одноразовый job на Railway** с тем же `DATABASE_URL`.

Пока миграции не применены, бот на Railway не поднимется и воркер упадёт на проверке.

---

## 4. Подготовка Windows: venv и CMD

```cmd
cd /d C:\sonaria_farm
python -m venv .venv
.venv\Scripts\activate.bat
python -m pip install -U pip
pip install -r requirements.txt
```

Скопируй `env.template` → `.env`, впиши `DATABASE_URL` (и при желании сгенерируй постоянный `WORKER_ID`).

Запуск воркера **всегда из корня репозитория** (чтобы пути `runtime/login_check_results` и `runtime/farm_tick` совпадали с ожиданиями адаптера):

```cmd
cd /d C:\sonaria_farm
.venv\Scripts\activate.bat
python worker_main.py
```

`python-dotenv` подхватит `.env` сам. Дополнительно в CMD можно задавать переменные перед запуском:

```cmd
set GAME_ADAPTER=windows
python worker_main.py
```

(Значения из **системного окружения CMD** при `load_dotenv()` по умолчанию **не перезаписываются** переменными из `.env` — наоборот: если переменная уже задана в CMD, она важнее. Обычно достаточно только `.env`.)

---

## 5. Тест уже пройденный: `login_and_check`

1. В боте (Railway) создай проверку аккаунта / массовую перепроверку — в БД появится задача `login_and_check` с `account_id`.
2. Воркер пишет в лог абсолютный путь к файлу ожидания:  
   `...\runtime\login_check_results\<account_id>.json`
3. Твой внешний скрипт/инжектор кладёт туда JSON, например:  
   `{"status":"banned","reason":"roblox_platform_ban"}`
4. Воркер читает, обновляет `accounts`, удаляет файл (если не заблокирован редактором).

---

## 6. Следующий тест: `farm_tick` (цикл фарма)

Идея: один вызов `farm_tick` = один обмен через файлы **по `task_id` задачи `start_farm`**.

### 6.1 Условия

- Аккаунт **не** в «мёртвом» статусе (`banned`, `invalid_credentials`, …).
- В боте включены/доступны сценарии старта фарма (как у тебя настроено в меню).
- Воркер с `GAME_ADAPTER=windows` запущен и смог занять инстанс (`WORKER_INSTANCE_NAME`, при необходимости `WORKER_ID` или ожидание `WORKER_STALE_HEARTBEAT_SECONDS`).

### 6.2 Шаги

1. **Старт задачи `start_farm`** для нужного аккаунта из бота.
2. Воркер забирает задачу — в логах появится что-то вроде `Claimed task type=start_farm ...`.
3. Смотри каталог (абсолютный путь в логах при старте адаптера):  
   `C:\sonaria_farm\runtime\farm_tick\`
4. Появится файл **`<task_id>.request.json`** (UUID задачи из БД / из лога `Claimed task`). Внутри: `account_id`, `death_points_target`, `tick_seq`, …
5. Твой процесс читает request, делает шаг в игре, пишет **`<task_id>.response.json`** рядом:

   **Успех:**

   ```json
   {
     "ok": true,
     "log": "шаг выполнен",
     "death_points_current": 100
   }
   ```

   **Ошибка:**

   ```json
   {
     "ok": false,
     "error": "описание"
   }
   ```

   Опционально, как у login check: `account_status`, `reason` — тогда обновится строка аккаунта.

6. Воркер читает ответ, пишет строку в `task_logs`, идёт на **следующий** тик — снова появится новый `request` с увеличенным `tick_seq`.

7. Остановка: отмена задачи / `stop_farm` из бота / неактивный статус аккаунта — см. логи воркера и `task_logs`.

### 6.3 Таймауты

Если ответ не появился за `FARM_TICK_TIMEOUT_SECONDS`, задача `start_farm` упадёт с ошибкой (как задумано). Для отладки можно увеличить в `.env`.

### 6.4 Мини-тест без игры

Чтобы проверить только мост: можно написать маленький скрипт/cycle на ПК, который в цикле ждёт `*.request.json` и сразу пишет `*.response.json` с `"ok": true` — воркер пойдёт по кругу, пока не отменишь фарм (осторожно с бесконечным циклом).

---

## 7. Типичные проблемы

| Симптом | Что проверить |
|---------|----------------|
| `Instance '...' is busy by another worker` | Постоянный `WORKER_ID` в `.env` или подожди `WORKER_STALE_HEARTBEAT_SECONDS` после убитого процесса |
| Воркер не видит JSON | Запуск из `C:\sonaria_farm`, тот же `account_id` в имени файла, что в БД |
| Файл не удаляется | Закрой JSON в редакторе (блокировка на Windows) |
| Нет коннекта к БД с ПК | Публичный URL Postgres на Railway, firewall, верный пароль в `DATABASE_URL` |
| Бот на Railway не стартует | `DATABASE_URL`, миграции, `TELEGRAM_BOT_TOKEN`, `ADMIN_TELEGRAM_ID` |

---

## 8. Файлы в репозитории

- **`env.template`** — скопируй в **`.env`** на машине с воркером (и используй как чеклист переменных для Railway).
- Подробности форматов мостов — в **`README.md`**.
