# Параметры для универсальных Lua-скриптов (мост + контроллер)

Цель: **одни и те же** скрипты (`farm.lua`, `transfer.lua`, `sell.lua`), **разное поведение** за счёт JSON, который воркер кладёт в файл запроса моста (или передаёт инжектору — см. ниже).

## Два способа доставки параметров в игру

1. **Файловый мост (как сейчас в `WindowsGameAdapter`)**  
   Воркер пишет `*.request.json`. Твой процесс (watchdog + инжектор) читает файл, передаёт в Roblox **объект `script_params`** (или весь JSON — как удобнее).

2. **Subprocess `injector.exe <PID> <script.lua> <json>`** (из твоей схемы)  
   Тот же JSON можно собрать из полей `request` — по смыслу это должен быть **тот же `script_params`**, плюс при необходимости `task_id` / `bridge`. В репозитории пока реализован в основном путь (1); `INJECTOR_*` запускает отдельный exe отдельно от содержимого request (можно связать в `external/`).

## Структура `*.request.json`

Во всех мостах добавлено поле **`script_params`**: словарь «всё, что нужно Lua». Верхний уровень сохраняет совместимость (`task_id`, `payload`, …).

### `farm_tick` (`bridge`: `farm_tick`)

| Поле верхнего уровня | Назначение |
|----------------------|------------|
| `bridge` | `"farm_tick"` |
| `task_id`, `account_id`, `worker_id` | Маршрутизация |
| `death_points_target`, `tick_seq` | Как раньше |
| **`script_params`** | Таблица для Lua |

**`script_params`** (типовой состав):

- `target_dp`, `death_points_target` — цель DP (дубль имён для удобства Lua).
- `tick_seq` — номер шага.
- `account_id`, `account_login` — аккаунт фермера.
- `account_password` — только если `SCRIPTS_INCLUDE_PASSWORD_IN_BRIDGE=1` (по умолчанию да; для отладки без пароля в файле — `0`).
- `stop_flag_path` — **абсолютный** путь к файлу стопа. Воркер создаёт его при **отмене** `start_farm` или при задаче **`stop_farm`**. При старте цикла фарма старый флаг **удаляется**. Каталог: `STOP_FLAG_DIR` (по умолчанию `runtime/stop_flags`), имя `{account_id}.stop`.

Lua должен периодически проверять наличие этого файла и выходить из цикла (для пошагового моста — один тик = один короткий проход без бесконечного цикла внутри одного инжекта).

### `transfer_to_storage` (`bridge`: `transfer_to_storage`)

- `payload` — как в задаче из бота (batch, cooldown, `target_storage_account_id`, токены, …).
- **`script_params`** — копия/обогащение: добавлены `farmer_login`, `farmer_account_id`, при наличии склада в БД — **`target_storage_login`**.

### `set_sell_price` (`bridge`: `set_sell_price`)

- `payload` — `ranges`, `priority_tokens`, `fallback_non_priority_mode`, …
- **`script_params`** — то же + `storage_login`, `storage_account_id`, плюс алиас **`fallback_mode`** = `fallback_non_priority_mode` для короткого имени в Lua.

## Откуда берутся данные

- **Глобальные** настройки (например целевые DP) попадают в задачу `start_farm` как `payload.death_points_target` (бот уже так создаёт задачи) и дублируются в `script_params` для фарма.
- **Параметры задачи** — JSON в `tasks.payload`; для transfer/sell они лежат в `payload` и повторяются/дополняются в `script_params`.

## Ответ (`response.json`)

Без изменений: `ok`, `error`, `log`, `account_status`, `reason`, опционально `inventory`, `death_points_current` для тика.

## Переменные окружения

См. `env.template`: `STOP_FLAG_DIR`, `SCRIPTS_INCLUDE_PASSWORD_IN_BRIDGE`.

## Универсальный скрипт Kimi (`universal_sonaria_bot.lua`)

Отдельная ветка: типы задач `universal_*` в боте и функция `build_universal_script_params()` в `farm/game/script_params.py`. Параметры уходят в инжектор одной JSON-строкой; ответ в stdout: префикс `SONARIA_RESPONSE:` + JSON (см. `WindowsGameAdapter._run_universal_script`). Это **не** то же самое, что legacy-каталог `INJECTOR_SCRIPTS_DIR` с `farm.lua` / `transfer.lua` / `sell.lua` от DeepSeek — оба режима могут сосуществовать, но для одного аккаунта в один момент времени лучше пользоваться только одним (бот при старте «классики» отменяет универсальные задачи и наоборот).
