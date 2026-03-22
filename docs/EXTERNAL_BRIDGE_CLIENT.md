# Внешний клиент файлового моста (инжектор / sidecar)

Этот репозиторий — **оркестратор**: бот, PostgreSQL, воркер, `WindowsGameAdapter`.  
Код, который **управляет клиентом Roblox** (инжекция, скрипты, UI-автоматизация), **не обязан** лежать здесь. Достаточно любого процесса на ПК, который:

1. Смотрит на **те же каталоги**, что и воркер (см. `.env` и `farm/game/file_bridge.py`).
2. Читает `*.request.json`, выполняет действие в игре (или заглушку), пишет парный `*.response.json`.

Связь с игрой — **только через файлы** (IPC). Python-воркер не знает, как именно ты исполняешь шаг внутри процесса игры.

## Режимы путей

| Режим | Переменные | Имена файлов |
|--------|------------|----------------|
| Классика | `FARM_TICK_DIR`, `TRANSFER_BRIDGE_DIR`, `SELL_BRIDGE_DIR` | `{task_id}.request.json` → `{task_id}.response.json` (алиасы `.resp.json`) |
| Общий корень | `FILE_BRIDGE_ROOT` | Подпапки `farm_tick`, `transfer_bridge`, `sell_bridge` |
| Один каталог | `FILE_BRIDGE_UNIFIED_DIR` | `{task_id}.farm_tick.request.json`, `{task_id}.transfer.request.json`, `{task_id}.sell.request.json` |

Приоритет: **`FILE_BRIDGE_UNIFIED_DIR`** перекрывает отдельные `FARM_TICK_*` для трёх мостов.

Воркер и твой клиент должны использовать **один и тот же** `.env` (или те же значения переменных), иначе файлы окажутся в разных папках.

## Жизненный цикл одного обмена

1. Воркер взял задачу (`start_farm`, `transfer_to_storage`, `set_sell_price`).
2. `WindowsGameAdapter` удаляет «чужие» файлы моста с другим `task_id`, пишет **request**.
3. Твой процесс **видит новый** `*.request.json` (которого ещё нет пары `*.response.json` — см. скрипты в `scripts/`).
4. Ты читаешь JSON, делаешь действие в игре.
5. Пишешь **response** с полями из README (`ok`, при ошибке `error`, опционально `log`, `account_status`, … для `farm_tick` ещё `death_points_current`). Опционально **`inventory`**: объект «имя токена → число» — попадёт в БД и в Telegram «Инвентарь».
6. Адаптер читает response, удаляет оба файла, воркер идёт дальше.

Таймауты: `FARM_TICK_TIMEOUT_SECONDS`, `TRANSFER_BRIDGE_*`, `SELL_BRIDGE_*` (см. `config.example.env`).

## Что использовать в этом репо

| Файл | Назначение |
|------|------------|
| `farm/game/file_bridge.py` | Канонические пути, теги `farm_tick` / `transfer` / `sell`, разбор имён |
| `scripts/file_bridge_echo.py` | Минимальный авто-ответ `ok: true` — стресс-тест очереди |
| `scripts/bridge_sidecar.py` | Шаблон sidecar: логирует request, ответ по умолчанию можно отключить |
| `README.md` | Форматы JSON для `farm_tick`, transfer, sell |

## Где держать свой код

- **Отдельный репозиторий или папка рядом** — нормальная схема.
- В этом репозитории создан каталог **`external/`** (см. `external/README.md`): можно класть локальные обёртки, если хочешь один клон на диске. Не коммить секреты и бинарники без необходимости.

## Безопасность и правила платформы

Реализация клиента игры должна соблюдать **ToS Roblox** и законы. Этот проект описывает только **технический** контракт файлового обмена между воркером и внешним процессом.

Целевая схема с изолированными сессиями Windows и инжектором — в **[ARCHITECTURE_WORKER_INJECTOR_ROBLOX.md](ARCHITECTURE_WORKER_INJECTOR_ROBLOX.md)**.
