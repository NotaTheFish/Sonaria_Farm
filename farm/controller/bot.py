import asyncio
import csv
import html
import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from enum import Enum, auto
from typing import Any, Optional
from io import BytesIO

from aiogram import Bot, Dispatcher, F
from aiogram.filters import BaseFilter, Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import (
    Message,
    KeyboardButton,
    ReplyKeyboardMarkup,
    ReplyKeyboardRemove,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Document,
    CallbackQuery,
    BufferedInputFile,
)
from aiogram.enums import ParseMode
from aiogram import Router
from aiogram.client.default import DefaultBotProperties

from dotenv import load_dotenv

from farm.database import AsyncSessionMaker, ensure_migrations_applied
from farm.inventory_formatting import (
    format_inventory_timestamp,
    format_token_lines_html,
    parse_inventory_json,
    split_telegram_chunks,
)
from farm.models import (
    Account,
    AccountRole,
    AccountStatus,
    ControllerSettings,
    Task,
    TaskStatus,
    TaskType,
    Worker,
)
from sqlalchemy import func, select
from farm.task_queue import create_task, request_cancel_tasks


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


class MainMenuButtons(str, Enum):
    SETTINGS = "Настройка"  # legacy alias
    SECTION_CONTROL = "Управление"
    SECTION_ACCOUNTS = "Аккаунты и проверки"
    SECTION_PARAMS = "Параметры"
    SECTION_TEST = "Тест"
    DEATH_POINTS = "Очки смерти"
    SET_PRICE = "Выставить цену"
    START_FARM = "Запустить фарм"
    STOP_FARM = "Остановить фарм"
    START_SALES = "Запустить продажи"
    STOP_SALES = "Остановить продажи"
    # Универсальный скрипт Kimi (отдельные типы задач; не смешивать с legacy INJECTOR_SCRIPTS_DIR)
    UNIVERSAL_FARM = "Фарм (универсал)"
    UNIVERSAL_TRANSFER = "Перенос (универсал)"
    UNIVERSAL_SELL = "Продажи (универсал)"
    UNIVERSAL_INVENTORY = "Инвентарь (универсал)"
    UNIVERSAL_DEX = "Dex (универсал)"


class TestButtons(str, Enum):
    EAT = "Есть"
    DRINK = "Пить"
    WALK = "Пройти"
    SNIFF = "Нюхать"
    ATTACK = "Атака"
    MUD = "Грязь"
    SURVIVE = "Выжить"
    SHROOMS = "Грибы"
    BACK = "⬅️ Главное меню"


class SettingsButtons(str, Enum):
    INVENTORY = "Инвентарь"
    TO_STORAGE = "На склад"
    ACCOUNTS = "Аккаунты"
    QUEUE_STATUS = "Статус очереди"
    RECHECK_ACCOUNTS = "Перепроверить аккаунты"
    ROLE_RATIO = "Соотношение ролей"
    BACK = "⬅️ Главное меню"


class AccountsCallback(str, Enum):
    ACTIVE = "accounts_active"
    BANNED = "accounts_banned"
    UPLOAD = "accounts_upload"


class AccountUploadState(StatesGroup):
    waiting_for_accounts_file = State()


class ControllerDeathPointsState(StatesGroup):
    waiting_for_death_points = State()


class SetPriceState(StatesGroup):
    waiting_for_ranges = State()
    waiting_for_priorities = State()


class RoleRatioState(StatesGroup):
    waiting_for_ratio = State()


@dataclass
class Config:
    bot_token: str
    admin_id: int


def load_config() -> Config:
    load_dotenv()
    token = os.getenv("TELEGRAM_BOT_TOKEN")
    admin_id_raw = os.getenv("ADMIN_TELEGRAM_ID")

    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is not set")
    if not admin_id_raw:
        raise RuntimeError("ADMIN_TELEGRAM_ID is not set")

    try:
        admin_id = int(admin_id_raw)
    except ValueError:
        raise RuntimeError("ADMIN_TELEGRAM_ID must be an integer")

    return Config(bot_token=token, admin_id=admin_id)

class AdminFilter(BaseFilter):
    def __init__(self, admin_id: int) -> None:
        self.admin_id = admin_id

    async def __call__(self, event: object) -> bool:
        from_user = getattr(event, "from_user", None)
        return bool(from_user and from_user.id == self.admin_id)

def main_menu_kb() -> ReplyKeyboardMarkup:
    buttons = [
        [
            KeyboardButton(text=MainMenuButtons.SECTION_CONTROL.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.SECTION_ACCOUNTS.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.SECTION_PARAMS.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.SECTION_TEST.value),
        ],
    ]
    return ReplyKeyboardMarkup(
        keyboard=buttons,
        resize_keyboard=True,
        input_field_placeholder="Выберите раздел",
    )


def test_kb() -> ReplyKeyboardMarkup:
    buttons = [
        [
            KeyboardButton(text=TestButtons.EAT.value),
            KeyboardButton(text=TestButtons.DRINK.value),
        ],
        [
            KeyboardButton(text=TestButtons.WALK.value),
            KeyboardButton(text=TestButtons.SNIFF.value),
        ],
        [
            KeyboardButton(text=TestButtons.ATTACK.value),
            KeyboardButton(text=TestButtons.MUD.value),
        ],
        [
            KeyboardButton(text=TestButtons.SURVIVE.value),
            KeyboardButton(text=TestButtons.SHROOMS.value),
        ],
        [
            KeyboardButton(text=TestButtons.BACK.value),
        ],
    ]
    return ReplyKeyboardMarkup(
        keyboard=buttons,
        resize_keyboard=True,
        input_field_placeholder="Выберите тест",
    )


def control_kb() -> ReplyKeyboardMarkup:
    buttons = [
        [
            KeyboardButton(text=MainMenuButtons.START_FARM.value),
            KeyboardButton(text=MainMenuButtons.STOP_FARM.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.START_SALES.value),
            KeyboardButton(text=MainMenuButtons.STOP_SALES.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.UNIVERSAL_FARM.value),
            KeyboardButton(text=MainMenuButtons.UNIVERSAL_TRANSFER.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.UNIVERSAL_SELL.value),
            KeyboardButton(text=MainMenuButtons.UNIVERSAL_INVENTORY.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.UNIVERSAL_DEX.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.DEATH_POINTS.value),
            KeyboardButton(text=MainMenuButtons.SET_PRICE.value),
        ],
        [
            KeyboardButton(text=SettingsButtons.BACK.value),
        ],
    ]
    return ReplyKeyboardMarkup(
        keyboard=buttons,
        resize_keyboard=True,
        input_field_placeholder="Управление ботами",
    )


def accounts_checks_kb() -> ReplyKeyboardMarkup:
    buttons = [
        [
            KeyboardButton(text=SettingsButtons.ACCOUNTS.value),
            KeyboardButton(text=SettingsButtons.INVENTORY.value),
        ],
        [
            KeyboardButton(text=SettingsButtons.RECHECK_ACCOUNTS.value),
            KeyboardButton(text=SettingsButtons.QUEUE_STATUS.value),
        ],
        [
            KeyboardButton(text=SettingsButtons.TO_STORAGE.value),
        ],
        [
            KeyboardButton(text=SettingsButtons.BACK.value),
        ],
    ]
    return ReplyKeyboardMarkup(
        keyboard=buttons,
        resize_keyboard=True,
        input_field_placeholder="Аккаунты и проверки",
    )


def params_kb() -> ReplyKeyboardMarkup:
    buttons = [
        [
            KeyboardButton(text=SettingsButtons.ROLE_RATIO.value),
        ],
        [
            KeyboardButton(text=SettingsButtons.BACK.value),
        ],
    ]
    return ReplyKeyboardMarkup(
        keyboard=buttons,
        resize_keyboard=True,
        input_field_placeholder="Параметры системы",
    )


def accounts_inline_kb() -> InlineKeyboardMarkup:
    buttons = [
        [
            InlineKeyboardButton(
                text="Действующие аккаунты",
                callback_data=AccountsCallback.ACTIVE.value,
            ),
        ],
        [
            InlineKeyboardButton(
                text="Забаненные аккаунты",
                callback_data=AccountsCallback.BANNED.value,
            ),
        ],
        [
            InlineKeyboardButton(
                text="Загрузить аккаунты",
                callback_data=AccountsCallback.UPLOAD.value,
            ),
        ],
    ]
    return InlineKeyboardMarkup(inline_keyboard=buttons)


SELLABLE_TOKENS = [
    "Revive Token",
    "Max Growth Token",
    "Partial Growth Token",
    "Random Trial Creature Token",
    "Appearance Change Token",
    "Death Gacha Token",
]

# Продажи: ровно этот набор (порядок = приоритет), без других токенов.
SELL_PRIORITY_TOKEN_COUNT = len(SELLABLE_TOKENS)


def sell_priority_tokens_valid(priority_tokens: object) -> bool:
    if not isinstance(priority_tokens, list):
        return False
    if len(priority_tokens) != SELL_PRIORITY_TOKEN_COUNT:
        return False
    if len(set(priority_tokens)) != SELL_PRIORITY_TOKEN_COUNT:
        return False
    return set(priority_tokens) == set(SELLABLE_TOKENS)


# Порядок токенов для universal_sonaria_bot (фермер → склад и приоритеты в Lua)
UNIVERSAL_TRANSFER_TOKEN_PRIORITY = list(SELLABLE_TOKENS)


def _universal_farmer_runtime_payload(
    *,
    queue_index: int,
    queue_total: int,
    storage: Account | None,
) -> dict[str, Any]:
    """Поля payload для задач UNIVERSAL_FARM / UNIVERSAL_TRANSFER (читает Lua)."""
    base: dict[str, Any] = {
        "batch_size": 150,
        "cooldown_seconds": 70,
        "post_trade_cooldown_seconds": 70,
        "trade_retry_seconds": 10,
        "trade_confirm_poll_seconds": 2,
        "storage_gives": 1,
        "transfer_token_priority": list(UNIVERSAL_TRANSFER_TOKEN_PRIORITY),
        "token_kinds": list(UNIVERSAL_TRANSFER_TOKEN_PRIORITY),
        "transfer_mode": "ROUND_ROBIN_MULTI_TYPE_BATCH",
        "farmer_queue_index": queue_index,
        "farmer_queue_total": queue_total,
        "queue_stagger_seconds": 5,
        "default_creature_name": "Kaluaka",
        "volcano_suicide": True,
        "join_fail_ban_threshold": 10,
        "ban_min_creature_kinds": 10,
        "sell_idle_rotate_seconds": 3600,
        "anti_afk_interval_seconds": 300,
        "sell_priority_phase_switch_after": 4,
        "dex_asset_path": "Dex_roblox.rbxmx",
    }
    if storage is not None:
        base["target_storage_account_id"] = storage.id
        base["target_storage_username"] = storage.login
        base["farm_pipeline"] = "missions_dp_then_transfer"
    else:
        base["farm_pipeline"] = "missions_dp_only"
    return base


async def get_or_create_settings() -> ControllerSettings:
    async with AsyncSessionMaker() as session:
        settings = await session.scalar(select(ControllerSettings).where(ControllerSettings.id == 1))
        if settings:
            return settings
        settings = ControllerSettings(
            id=1,
            death_points_target=600,
            farmer_ratio_percent=70,
            farming_enabled=False,
            sales_enabled=False,
        )
        session.add(settings)
        await session.commit()
        await session.refresh(settings)
        return settings


async def rebalance_active_account_roles() -> tuple[int, int, int]:
    """
    Распределяет только ACTIVE аккаунты по ролям farmer/storage согласно ratio.
    Возвращает (active_total, farmers_count, storages_count)

    Число фермеров — ``round(total * ratio / 100)`` в [0, total]: при ``int()`` один
    active-аккаунт при ratio=70 давал 0 фермеров (все уходили в storage).
    """
    settings = await get_or_create_settings()
    ratio = max(0, min(100, int(settings.farmer_ratio_percent)))

    async with AsyncSessionMaker() as session:
        active_accounts = (
            await session.scalars(
                select(Account)
                .where(Account.status == AccountStatus.ACTIVE.value)
                .order_by(Account.created_at.asc())
            )
        ).all()

        total = len(active_accounts)
        farmers_count = max(0, min(total, round(total * ratio / 100.0)))
        storages_count = total - farmers_count

        for idx, acc in enumerate(active_accounts):
            acc.role = AccountRole.FARMER.value if idx < farmers_count else AccountRole.STORAGE.value

        await session.commit()

    return total, farmers_count, storages_count


async def enqueue_set_sell_price_for_active_storages(
    ranges: dict[str, dict[str, int]],
    priority_tokens: list[str],
) -> tuple[int, str | None]:
    """
    Создаёт задачи SET_SELL_PRICE для всех активных складов (инжектор / sell.lua).
    Вызывать из «Запустить продажи», а не из мастера «Выставить цену» — там только сохранение в БД.
    Возвращает (число складов, текст ошибки или None).
    """
    await rebalance_active_account_roles()
    async with AsyncSessionMaker() as session:
        storages = (
            await session.scalars(
                select(Account).where(
                    Account.role == AccountRole.STORAGE.value,
                    Account.status == AccountStatus.ACTIVE.value,
                )
            )
        ).all()

    if not storages:
        return 0, "Нет активных аккаунтов-складов."

    for storage in storages:
        await request_cancel_tasks(
            task_type=TaskType.SET_SELL_PRICE.value,
            account_id=storage.id,
            only_pending=False,
        )
        await request_cancel_tasks(
            task_type=TaskType.UNIVERSAL_SELL.value,
            account_id=storage.id,
            only_pending=False,
        )
        await create_task(
            task_type=TaskType.SET_SELL_PRICE.value,
            priority=300,
            account_id=storage.id,
            payload={
                "ranges": ranges,
                "priority_tokens": priority_tokens,
                "fallback_non_priority_mode": "sell_all_when_priority_empty",
            },
        )
    return len(storages), None


async def enqueue_universal_sell_for_active_storages(
    ranges: dict[str, dict[str, int]],
    priority_tokens: list[str],
) -> tuple[int, str | None]:
    """Задачи UNIVERSAL_SELL для активных складов (скрипт Kimi)."""
    await rebalance_active_account_roles()
    async with AsyncSessionMaker() as session:
        storages = (
            await session.scalars(
                select(Account).where(
                    Account.role == AccountRole.STORAGE.value,
                    Account.status == AccountStatus.ACTIVE.value,
                )
            )
        ).all()
        farmers = (
            await session.scalars(
                select(Account).where(
                    Account.role == AccountRole.FARMER.value,
                    Account.status == AccountStatus.ACTIVE.value,
                )
            )
        ).all()

    if not storages:
        return 0, "Нет активных аккаунтов-складов."

    ns = len(storages)
    for si, storage in enumerate(storages):
        bound_farmers = [
            {"id": f.id, "login": f.login}
            for fi, f in enumerate(farmers)
            if fi % ns == si
        ]
        await request_cancel_tasks(
            task_type=TaskType.UNIVERSAL_SELL.value,
            account_id=storage.id,
            only_pending=False,
        )
        await request_cancel_tasks(
            task_type=TaskType.SET_SELL_PRICE.value,
            account_id=storage.id,
            only_pending=False,
        )
        await create_task(
            task_type=TaskType.UNIVERSAL_SELL.value,
            priority=310,
            account_id=storage.id,
            payload={
                "ranges": ranges,
                "priority_tokens": priority_tokens,
                "fallback_non_priority_mode": "sell_all_when_priority_empty",
                "sell_only_priority_tokens": True,
                "bound_farmers": bound_farmers,
                "trade_session_mode": "public_sale",
                "sell_idle_rotate_seconds": 3600,
                "anti_afk_interval_seconds": 300,
                "sell_priority_phase_switch_after": 4,
            },
        )
    return len(storages), None


async def save_sell_price_snapshot(
    ranges: dict[str, dict[str, int]],
    priority_tokens: list[str],
) -> None:
    """Сохраняет последний набор диапазонов и приоритетов для повтора по «Запустить продажи»."""
    ranges_s = json.dumps(ranges, ensure_ascii=False)
    prio_s = json.dumps(priority_tokens, ensure_ascii=False)
    async with AsyncSessionMaker() as session:
        settings = await session.scalar(select(ControllerSettings).where(ControllerSettings.id == 1))
        if not settings:
            settings = ControllerSettings(
                id=1,
                death_points_target=600,
                farmer_ratio_percent=70,
                farming_enabled=False,
                sales_enabled=False,
                sell_ranges_json=ranges_s,
                sell_priority_tokens_json=prio_s,
            )
            session.add(settings)
        else:
            settings.sell_ranges_json = ranges_s
            settings.sell_priority_tokens_json = prio_s
        await session.commit()


def build_router(config: Config) -> Router:
    router = Router()

    @router.message(CommandStart(), AdminFilter(config.admin_id))
    async def cmd_start(message: Message):
        await message.answer(
            "Привет. Это центр управления фермой Creatures of Sonaria.\n"
            "Используй /help для краткой карты меню.",
            reply_markup=main_menu_kb(),
        )

    @router.message(Command("help"), AdminFilter(config.admin_id))
    async def cmd_help(message: Message):
        await message.answer(
            "Навигация:\n"
            "• Управление — запуск/остановка фарма и продаж, очки смерти, цены.\n"
            "• Аккаунты и проверки — импорт, выгрузка списков, очередь, перепроверка.\n"
            "• Параметры — соотношение farmer/storage.\n\n"
            "Подсказка: кнопка `⬅️ Главное меню` возвращает в корень.",
            reply_markup=main_menu_kb(),
        )

    @router.message(
        (F.text == MainMenuButtons.SECTION_CONTROL.value) | (F.text == MainMenuButtons.SETTINGS.value),
        AdminFilter(config.admin_id),
    )
    async def on_settings(message: Message):
        await message.answer("Раздел: Управление", reply_markup=control_kb())

    @router.message(F.text == MainMenuButtons.SECTION_ACCOUNTS.value, AdminFilter(config.admin_id))
    async def on_accounts_section(message: Message):
        await message.answer("Раздел: Аккаунты и проверки", reply_markup=accounts_checks_kb())

    @router.message(F.text == MainMenuButtons.SECTION_PARAMS.value, AdminFilter(config.admin_id))
    async def on_params_section(message: Message):
        await message.answer("Раздел: Параметры", reply_markup=params_kb())

    @router.message(F.text == MainMenuButtons.SECTION_TEST.value, AdminFilter(config.admin_id))
    async def on_test_section(message: Message):
        await message.answer("Раздел: Тест функций", reply_markup=test_kb())

    @router.message(
        (F.text == SettingsButtons.BACK.value) | (F.text == TestButtons.BACK.value),
        AdminFilter(config.admin_id),
    )
    async def on_back_to_main(message: Message):
        await message.answer("Главное меню.", reply_markup=main_menu_kb())

    @router.message(F.text == SettingsButtons.INVENTORY.value, AdminFilter(config.admin_id))
    async def on_inventory(message: Message):
        async with AsyncSessionMaker() as session:
            farmers = (
                await session.scalars(
                    select(Account)
                    .where(
                        Account.role == AccountRole.FARMER.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                    .order_by(Account.login.asc())
                )
            ).all()
            storages = (
                await session.scalars(
                    select(Account)
                    .where(
                        Account.role == AccountRole.STORAGE.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                    .order_by(Account.login.asc())
                )
            ).all()

        lines: list[str] = [
            "<b>Инвентарь</b>",
            "",
            "Снимок из поля <code>inventory</code> в JSON-ответе моста "
            "(<code>farm_tick</code>, <code>transfer_to_storage</code>, <code>set_sell_price</code>).",
            "Имена токенов — как в мастере цен (см. список ниже).",
            "",
        ]
        if not farmers and not storages:
            lines.append("<i>Нет active аккаунтов с ролями фермер / склад.</i>")
            full = "\n".join(lines)
            for chunk in split_telegram_chunks(full):
                await message.answer(chunk, parse_mode=ParseMode.HTML, reply_markup=accounts_checks_kb())
            return

        total_earned: dict[str, int] = {}
        lines.append(f"<b>Фермеры</b> (active, {len(farmers)})")
        if not farmers:
            lines.append("<i>нет</i>")
        for a in farmers:
            inv = parse_inventory_json(a.inventory_json)
            earned = parse_inventory_json(getattr(a, "earned_tokens_json", None))
            lines.append("")
            lines.append(f"<code>{html.escape(a.login[:64])}</code>")
            lines.append(
                f"<i>обновлено:</i> {html.escape(format_inventory_timestamp(a.inventory_updated_at))}"
            )
            lines.append(format_token_lines_html(inv, SELLABLE_TOKENS))
            if earned:
                lines.append(f"<i>заработано (death rewards):</i>")
                lines.append(format_token_lines_html(earned, SELLABLE_TOKENS))
                for tk, tv in earned.items():
                    try:
                        total_earned[tk] = total_earned.get(tk, 0) + int(tv)
                    except (ValueError, TypeError):
                        pass

        lines.append("")
        lines.append(f"<b>Склады</b> (active, {len(storages)})")
        if not storages:
            lines.append("<i>нет</i>")
        for a in storages:
            inv = parse_inventory_json(a.inventory_json)
            lines.append("")
            lines.append(f"<code>{html.escape(a.login[:64])}</code>")
            lines.append(
                f"<i>обновлено:</i> {html.escape(format_inventory_timestamp(a.inventory_updated_at))}"
            )
            lines.append(format_token_lines_html(inv, SELLABLE_TOKENS))

        if total_earned:
            lines.append("")
            lines.append("<b>Итого заработано (death rewards, все фермеры):</b>")
            lines.append(format_token_lines_html(total_earned, SELLABLE_TOKENS))

        full = "\n".join(lines)
        chunks = split_telegram_chunks(full)
        for i, chunk in enumerate(chunks):
            prefix = f"<i>продолжение {i + 1}/{len(chunks)}</i>\n\n" if i else ""
            await message.answer(
                prefix + chunk,
                parse_mode=ParseMode.HTML,
                reply_markup=accounts_checks_kb() if i == len(chunks) - 1 else None,
            )

    @router.message(F.text == SettingsButtons.QUEUE_STATUS.value, AdminFilter(config.admin_id))
    async def on_queue_status(message: Message):
        stale_cutoff = datetime.now(timezone.utc) - timedelta(seconds=120)
        async with AsyncSessionMaker() as session:
            pending = int(await session.scalar(select(func.count()).select_from(Task).where(Task.status == TaskStatus.PENDING.value)))
            running = int(await session.scalar(select(func.count()).select_from(Task).where(Task.status == TaskStatus.RUNNING.value)))
            done = int(await session.scalar(select(func.count()).select_from(Task).where(Task.status == TaskStatus.DONE.value)))
            failed = int(await session.scalar(select(func.count()).select_from(Task).where(Task.status == TaskStatus.FAILED.value)))
            cancelled = int(await session.scalar(select(func.count()).select_from(Task).where(Task.status == TaskStatus.CANCELLED.value)))

            login_check_pending = int(
                await session.scalar(
                    select(func.count()).select_from(Task).where(
                        Task.task_type == TaskType.LOGIN_AND_CHECK.value,
                        Task.status == TaskStatus.PENDING.value,
                    )
                )
            )
            farm_running = int(
                await session.scalar(
                    select(func.count()).select_from(Task).where(
                        Task.task_type.in_(
                            (
                                TaskType.START_FARM.value,
                                TaskType.UNIVERSAL_FARM.value,
                            )
                        ),
                        Task.status == TaskStatus.RUNNING.value,
                    )
                )
            )
            transfer_pending = int(
                await session.scalar(
                    select(func.count()).select_from(Task).where(
                        Task.task_type == TaskType.TRANSFER_TO_STORAGE.value,
                        Task.status == TaskStatus.PENDING.value,
                    )
                )
            )
            sell_pending = int(
                await session.scalar(
                    select(func.count()).select_from(Task).where(
                        Task.task_type == TaskType.SET_SELL_PRICE.value,
                        Task.status == TaskStatus.PENDING.value,
                    )
                )
            )

            workers_total = int(await session.scalar(select(func.count()).select_from(Worker)))
            workers_alive = int(
                await session.scalar(
                    select(func.count()).select_from(Worker).where(Worker.heartbeat_at >= stale_cutoff)
                )
            )

        await message.answer(
            "Статус очереди:\n"
            f"pending={pending}, running={running}, done={done}, failed={failed}, cancelled={cancelled}\n\n"
            "По типам:\n"
            f"login_and_check pending={login_check_pending}\n"
            f"start_farm|universal_farm running={farm_running}\n"
            f"transfer_to_storage pending={transfer_pending}\n"
            f"set_sell_price pending={sell_pending}\n\n"
            f"Воркеры: alive={workers_alive}, total={workers_total}",
            reply_markup=accounts_checks_kb(),
        )

    @router.message(F.text == SettingsButtons.RECHECK_ACCOUNTS.value, AdminFilter(config.admin_id))
    async def on_recheck_accounts(message: Message):
        """
        Повторная проверка аккаунтов без переимпорта файла.
        По умолчанию не трогаем banned/disabled, чтобы не перезапускать заведомо исключенные аккаунты.
        """
        eligible_statuses = {
            AccountStatus.NEW.value,
            AccountStatus.ACTIVE.value,
            AccountStatus.INVALID_CREDENTIALS.value,
            AccountStatus.CHECKPOINT.value,
            AccountStatus.COOLDOWN.value,
        }

        async with AsyncSessionMaker() as session:
            accounts = (
                await session.scalars(
                    select(Account).where(Account.status.in_(eligible_statuses))
                )
            ).all()

            candidates = len(accounts)
            created = 0
            skipped_with_existing_job = 0

            for acc in accounts:
                existing_job_count = int(
                    await session.scalar(
                        select(func.count()).select_from(Task).where(
                            Task.account_id == acc.id,
                            Task.task_type == TaskType.LOGIN_AND_CHECK.value,
                            Task.status.in_([TaskStatus.PENDING.value, TaskStatus.RUNNING.value]),
                        )
                    )
                )
                if existing_job_count > 0:
                    skipped_with_existing_job += 1
                    continue

                session.add(
                    Task(
                        task_type=TaskType.LOGIN_AND_CHECK.value,
                        status=TaskStatus.PENDING.value,
                        priority=2000,
                        account_id=acc.id,
                        payload='{"source":"manual_recheck"}',
                        attempts=0,
                        cancel_requested=False,
                    )
                )
                created += 1

            await session.commit()

        await message.answer(
            "Перепроверка аккаунтов поставлена в очередь.\n"
            f"Кандидатов: {candidates}\n"
            f"Создано login_and_check задач: {created}\n"
            f"Пропущено (уже есть pending/running): {skipped_with_existing_job}",
            reply_markup=accounts_checks_kb(),
        )

    @router.message(F.text == SettingsButtons.ROLE_RATIO.value, AdminFilter(config.admin_id))
    async def on_role_ratio(message: Message, state: FSMContext):
        settings = await get_or_create_settings()
        await message.answer(
            "Введи соотношение farmer/storage в формате `70/30` или одним числом `70`.\n"
            f"Текущее значение: {settings.farmer_ratio_percent}/{100-settings.farmer_ratio_percent}",
            reply_markup=params_kb(),
        )
        await state.set_state(RoleRatioState.waiting_for_ratio)

    @router.message(RoleRatioState.waiting_for_ratio, AdminFilter(config.admin_id))
    async def on_role_ratio_value(message: Message, state: FSMContext):
        raw = (message.text or "").strip()
        farmer_ratio: int | None = None

        if "/" in raw:
            left, right = raw.split("/", 1)
            try:
                farmer = int(left.strip())
                storage = int(right.strip())
            except ValueError:
                farmer = -1
                storage = -1
            if farmer >= 0 and storage >= 0 and (farmer + storage) > 0:
                farmer_ratio = int(round((farmer / (farmer + storage)) * 100))
        else:
            try:
                farmer_ratio = int(raw)
            except ValueError:
                farmer_ratio = None

        if farmer_ratio is None or farmer_ratio < 0 or farmer_ratio > 100:
            await message.answer("Неверный формат. Примеры: `70/30` или `70`.", reply_markup=params_kb())
            return

        async with AsyncSessionMaker() as session:
            settings = await session.scalar(select(ControllerSettings).where(ControllerSettings.id == 1))
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
                    farmer_ratio_percent=farmer_ratio,
                    farming_enabled=False,
                    sales_enabled=False,
                )
                session.add(settings)
            else:
                settings.farmer_ratio_percent = farmer_ratio
            await session.commit()

        active_total, farmers_count, storages_count = await rebalance_active_account_roles()
        await message.answer(
            f"Соотношение обновлено: farmer/storage = {farmer_ratio}/{100-farmer_ratio}\n"
            f"Активных аккаунтов: {active_total} -> farmer={farmers_count}, storage={storages_count}",
            reply_markup=params_kb(),
        )
        await state.clear()

    @router.message(F.text == SettingsButtons.TO_STORAGE.value, AdminFilter(config.admin_id))
    async def on_to_storage(message: Message):
        await rebalance_active_account_roles()
        async with AsyncSessionMaker() as session:
            farmers = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.FARMER.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()
            storages = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.STORAGE.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()

        if not farmers:
            await message.answer("Нет активных аккаунтов-фермеров.", reply_markup=accounts_checks_kb())
            return
        if not storages:
            await message.answer("Нет активных аккаунтов-складов.", reply_markup=accounts_checks_kb())
            return

        # Чтобы не было дублей trade-операций, отменяем уже стоящие задачи переноса
        for farmer in farmers:
            await request_cancel_tasks(
                task_type=TaskType.TRANSFER_TO_STORAGE.value,
                account_id=farmer.id,
                only_pending=False,
            )
            await request_cancel_tasks(
                task_type=TaskType.UNIVERSAL_TRANSFER.value,
                account_id=farmer.id,
                only_pending=False,
            )

        created = 0
        for i, farmer in enumerate(farmers):
            storage = storages[i % len(storages)]
            payload = {
                **_universal_farmer_runtime_payload(
                    queue_index=i + 1,
                    queue_total=len(farmers),
                    storage=storage,
                ),
                "transfer_mode": "FULL_BATCH_UNTIL_ZERO",
            }
            await create_task(
                task_type=TaskType.TRANSFER_TO_STORAGE.value,
                priority=500,
                account_id=farmer.id,
                payload=payload,
            )
            created += 1

        await message.answer(
            f"Созданы задачи `На склад`: {created} штук (фермеров={len(farmers)}, складов={len(storages)}).",
            reply_markup=accounts_checks_kb(),
        )

    @router.message(F.text == MainMenuButtons.UNIVERSAL_TRANSFER.value, AdminFilter(config.admin_id))
    async def on_universal_to_storage(message: Message):
        """Перенос через ``universal_sonaria_bot.lua`` (отдельно от файлового/legacy transfer)."""
        await rebalance_active_account_roles()
        async with AsyncSessionMaker() as session:
            farmers = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.FARMER.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()
            storages = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.STORAGE.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()

        if not farmers:
            await message.answer("Нет активных аккаунтов-фермеров.", reply_markup=control_kb())
            return
        if not storages:
            await message.answer("Нет активных аккаунтов-складов.", reply_markup=control_kb())
            return

        for farmer in farmers:
            await request_cancel_tasks(
                task_type=TaskType.TRANSFER_TO_STORAGE.value,
                account_id=farmer.id,
                only_pending=False,
            )
            await request_cancel_tasks(
                task_type=TaskType.UNIVERSAL_TRANSFER.value,
                account_id=farmer.id,
                only_pending=False,
            )

        created = 0
        for i, farmer in enumerate(farmers):
            storage = storages[i % len(storages)]
            payload = {
                **_universal_farmer_runtime_payload(
                    queue_index=i + 1,
                    queue_total=len(farmers),
                    storage=storage,
                ),
                "transfer_mode": "ROUND_ROBIN_MULTI_TYPE_BATCH",
            }
            await create_task(
                task_type=TaskType.UNIVERSAL_TRANSFER.value,
                priority=510,
                account_id=farmer.id,
                payload=payload,
            )
            created += 1

        await message.answer(
            f"Универсальный перенос (Kimi): создано задач = {created}. "
            f"Классическое «На склад» для этих фермеров отменено.",
            reply_markup=control_kb(),
        )

    @router.message(F.text == SettingsButtons.ACCOUNTS.value, AdminFilter(config.admin_id))
    async def on_accounts(message: Message):
        async with AsyncSessionMaker() as session:
            farmers_active = await session.scalar(
                select(func.count()).select_from(Account).where(
                    Account.role == AccountRole.FARMER.value,
                    Account.status == AccountStatus.ACTIVE.value,
                )
            )
            storages_active = await session.scalar(
                select(func.count()).select_from(Account).where(
                    Account.role == AccountRole.STORAGE.value,
                    Account.status == AccountStatus.ACTIVE.value,
                )
            )
            farmers_banned = await session.scalar(
                select(func.count()).select_from(Account).where(
                    Account.role == AccountRole.FARMER.value,
                    Account.status == AccountStatus.BANNED.value,
                )
            )
            storages_banned = await session.scalar(
                select(func.count()).select_from(Account).where(
                    Account.role == AccountRole.STORAGE.value,
                    Account.status == AccountStatus.BANNED.value,
                )
            )

        text = (
            "Аккаунты:\n"
            f"Действующие: фермеров {farmers_active}, складов {storages_active}.\n"
            f"Забаненные: фермеров {farmers_banned}, складов {storages_banned}."
        )
        await message.answer(text, reply_markup=accounts_inline_kb())

    @router.callback_query(
        F.data == AccountsCallback.ACTIVE.value,
        AdminFilter(config.admin_id),
    )
    async def on_accounts_active(callback: CallbackQuery):
        async with AsyncSessionMaker() as session:
            farmers = await session.scalars(
                select(Account).where(
                    Account.role == AccountRole.FARMER.value,
                    Account.status == AccountStatus.ACTIVE.value,
                )
            )
            storages = await session.scalars(
                select(Account).where(
                    Account.role == AccountRole.STORAGE.value,
                    Account.status == AccountStatus.ACTIVE.value,
                )
            )

            farmers_list = list(farmers)
            storages_list = list(storages)

        lines: list[str] = []
        lines.append("FARMERS")
        for acc in farmers_list:
            lines.append(f"{acc.login}:{acc.password}")
        lines.append("")
        lines.append("STORAGES")
        for acc in storages_list:
            lines.append(f"{acc.login}:{acc.password}")

        content = "\n".join(lines).encode("utf-8")
        bio = BytesIO(content)
        bio.name = "active_accounts.txt"

        await callback.message.answer_document(
            BufferedInputFile(bio.getvalue(), filename="active_accounts.txt")
        )
        await callback.answer()

    @router.callback_query(
        F.data == AccountsCallback.BANNED.value,
        AdminFilter(config.admin_id),
    )
    async def on_accounts_banned(callback: CallbackQuery):
        async with AsyncSessionMaker() as session:
            farmers = await session.scalars(
                select(Account).where(
                    Account.role == AccountRole.FARMER.value,
                    Account.status == AccountStatus.BANNED.value,
                )
            )
            storages = await session.scalars(
                select(Account).where(
                    Account.role == AccountRole.STORAGE.value,
                    Account.status == AccountStatus.BANNED.value,
                )
            )

            farmers_list = list(farmers)
            storages_list = list(storages)

        lines: list[str] = []
        lines.append("FARMERS")
        for acc in farmers_list:
            lines.append(f"{acc.login}:{acc.password}")
        lines.append("")
        lines.append("STORAGES")
        for acc in storages_list:
            lines.append(f"{acc.login}:{acc.password}")

        content = "\n".join(lines).encode("utf-8")
        bio = BytesIO(content)
        bio.name = "banned_accounts.txt"

        await callback.message.answer_document(
            BufferedInputFile(bio.getvalue(), filename="banned_accounts.txt")
        )
        await callback.answer()

    @router.callback_query(
        F.data == AccountsCallback.UPLOAD.value,
        AdminFilter(config.admin_id),
    )
    async def on_accounts_upload(callback: CallbackQuery, state: FSMContext):
        await callback.message.answer(
            "Пришли файл `.txt` или `.csv` с аккаунтами.\n"
            "Поддержка строк `LOGIN:PASSWORD` и CSV `login,password`.\n"
            "После импорта аккаунты получат статус `new`, затем создадутся задачи `login_and_check`."
        )
        await state.set_state(AccountUploadState.waiting_for_accounts_file)
        await callback.answer()

    @router.message(F.document, AccountUploadState.waiting_for_accounts_file, AdminFilter(config.admin_id))
    async def on_accounts_file(message: Message, state: FSMContext):
        if not message.document or not message.document.file_name:
            await message.answer("Не вижу имя файла. Пришли `.txt` или `.csv` файл.", reply_markup=accounts_checks_kb())
            return

        file_name = message.document.file_name
        if not (file_name.lower().endswith(".txt") or file_name.lower().endswith(".csv")):
            await message.answer("Нужен файл `.txt` или `.csv`. Попробуй ещё раз.", reply_markup=accounts_checks_kb())
            return

        # Скачиваем файл из Telegram в память
        doc = message.document
        tg_file = await message.bot.get_file(doc.file_id)
        downloaded = await message.bot.download_file(tg_file.file_path)

        try:
            raw = downloaded.getvalue()
        except AttributeError:
            raw = downloaded.read()

        text = raw.decode("utf-8", errors="ignore")
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]

        parsed: list[tuple[str, str]] = []
        if file_name.lower().endswith(".csv"):
            reader = csv.reader(lines)
            for row in reader:
                if len(row) < 2:
                    continue
                login = row[0].strip()
                password = row[1].strip()
                if not login or not password:
                    continue
                if login.lower() == "login" and password.lower() == "password":
                    continue
                parsed.append((login, password))
        else:
            for ln in lines:
                if ":" not in ln:
                    continue
                login, password = ln.split(":", 1)
                login = login.strip()
                password = password.strip()
                if not login or not password:
                    continue
                parsed.append((login, password))

        # Убираем дубликаты логинов, сохраняя порядок
        unique: list[tuple[str, str]] = []
        seen_logins: set[str] = set()
        for login, password in parsed:
            if login in seen_logins:
                continue
            seen_logins.add(login)
            unique.append((login, password))

        if not unique:
            await message.answer("Файл пустой или не удалось распарсить `LOGIN:PASSWORD`.", reply_markup=accounts_checks_kb())
            await state.clear()
            return

        total = len(unique)
        settings = await get_or_create_settings()
        ratio = max(0, min(100, int(settings.farmer_ratio_percent)))
        farmers_count = int(total * ratio / 100)

        inserted = 0
        updated = 0
        check_tasks_created = 0

        async with AsyncSessionMaker() as session:
            imported_account_ids: list[str] = []
            for idx, (login, password) in enumerate(unique):
                role_value = (
                    AccountRole.FARMER.value if idx < farmers_count else AccountRole.STORAGE.value
                )
                existing = await session.scalar(select(Account).where(Account.login == login))
                if existing:
                    updated += 1
                    existing.password = password
                    protected = existing.status in {AccountStatus.BANNED.value, AccountStatus.DISABLED.value}
                    # Не снимаем бан/disabled, чтобы случайно не "разбанить" аккаунт.
                    if not protected:
                        existing.status = AccountStatus.NEW.value
                    existing.role = role_value
                    if not protected:
                        imported_account_ids.append(existing.id)
                    continue

                account = Account(
                    login=login,
                    password=password,
                    role=role_value,
                    status=AccountStatus.NEW.value,
                )
                session.add(account)
                await session.flush()
                imported_account_ids.append(account.id)
                inserted += 1

            await session.commit()

        # После импорта создаем login_and_check задачи по account_id.
        for account_id in imported_account_ids:
            await create_task(
                task_type=TaskType.LOGIN_AND_CHECK.value,
                priority=2000,
                account_id=account_id,
                payload={"source": "import"},
            )
            check_tasks_created += 1

        # Перераспределим активные роли (на случай, если active уже есть)
        active_total, farmers_count, storages_count = await rebalance_active_account_roles()

        async with AsyncSessionMaker() as session:
            status_counts: dict[str, int] = {}
            for status in [
                AccountStatus.NEW.value,
                AccountStatus.ACTIVE.value,
                AccountStatus.BANNED.value,
                AccountStatus.INVALID_CREDENTIALS.value,
                AccountStatus.CHECKPOINT.value,
                AccountStatus.DISABLED.value,
                AccountStatus.COOLDOWN.value,
            ]:
                status_counts[status] = int(
                    await session.scalar(
                        select(func.count()).select_from(Account).where(Account.status == status)
                    )
                )
            ratio = (await get_or_create_settings()).farmer_ratio_percent

        await message.answer(
            "Загрузка аккаунтов завершена.\n"
            f"Всего строк: {total}\n"
            f"Добавлено: {inserted}\n"
            f"Обновлено: {updated}\n"
            f"Создано login_and_check задач: {check_tasks_created}\n\n"
            "Статусы аккаунтов:\n"
            f"new: {status_counts[AccountStatus.NEW.value]}\n"
            f"active: {status_counts[AccountStatus.ACTIVE.value]}\n"
            f"banned: {status_counts[AccountStatus.BANNED.value]}\n"
            f"invalid_credentials: {status_counts[AccountStatus.INVALID_CREDENTIALS.value]}\n"
            f"checkpoint: {status_counts[AccountStatus.CHECKPOINT.value]}\n"
            f"disabled: {status_counts[AccountStatus.DISABLED.value]}\n"
            f"cooldown: {status_counts[AccountStatus.COOLDOWN.value]}\n\n"
            f"Роли среди active (ratio {ratio}%/{100-ratio}%): farmer={farmers_count}, storage={storages_count}",
            reply_markup=accounts_checks_kb(),
        )

        await state.clear()

    @router.message(F.text == MainMenuButtons.DEATH_POINTS.value, AdminFilter(config.admin_id))
    async def on_death_points(message: Message, state: FSMContext):
        await message.answer(
            "Введите количество очков смерти для цикла фарма "
            "(например 600 или 1200).",
            reply_markup=control_kb(),
        )
        await state.set_state(ControllerDeathPointsState.waiting_for_death_points)

    @router.message(
        F.text.regexp(r"^\d+$"),
        ControllerDeathPointsState.waiting_for_death_points,
        AdminFilter(config.admin_id),
    )
    async def on_death_points_value(message: Message, state: FSMContext):
        # Парсим значение и сохраняем в Postgres
        points = int((message.text or "").strip())
        if points <= 0:
            await message.answer("Значение должно быть больше 0.", reply_markup=control_kb())
            return

        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                session.add(
                    ControllerSettings(
                        id=1,
                        death_points_target=points,
                        farming_enabled=False,
                        sales_enabled=False,
                    )
                )
            else:
                settings.death_points_target = points
            await session.commit()

        # Возвращаем reply-клавиатуру в главное меню, чтобы она не пропадала после ввода числа.
        await message.answer(
            f"Ок. Целевые `Очки смерти` установлены на {points}.",
            reply_markup=control_kb(),
        )
        await state.clear()

    @router.message(F.text == MainMenuButtons.SET_PRICE.value, AdminFilter(config.admin_id))
    async def on_set_price(message: Message, state: FSMContext):
        await message.answer(
            "Введи диапазоны цен по строкам в формате:\n"
            "Token=min-max\n\n"
            "Доступные токены:\n"
            "- Revive Token\n"
            "- Max Growth Token\n"
            "- Partial Growth Token\n"
            "- Random Trial Creature Token\n"
            "- Appearance Change Token\n"
            "- Death Gacha Token\n\n"
            "Пример:\n"
            "Revive Token=2200-2400\n"
            "Death Gacha Token=8000-9500",
            reply_markup=control_kb(),
        )
        await state.set_state(SetPriceState.waiting_for_ranges)

    @router.message(SetPriceState.waiting_for_ranges, AdminFilter(config.admin_id))
    async def on_set_price_ranges(message: Message, state: FSMContext):
        raw = (message.text or "").strip()
        if not raw:
            await message.answer("Пустой ввод. Пришли диапазоны в формате Token=min-max.", reply_markup=control_kb())
            return

        ranges: dict[str, dict[str, int]] = {}
        for line in [x.strip() for x in raw.splitlines() if x.strip()]:
            if "=" not in line:
                continue
            token, rng = line.split("=", 1)
            token = token.strip()
            rng = rng.strip()
            if token not in SELLABLE_TOKENS or "-" not in rng:
                continue
            left, right = rng.split("-", 1)
            try:
                mn = int(left.strip())
                mx = int(right.strip())
            except ValueError:
                continue
            if mn <= 0 or mx <= 0 or mn > mx:
                continue
            ranges[token] = {"min": mn, "max": mx}

        if not ranges:
            await message.answer("Не удалось распарсить ни одного диапазона. Попробуй еще раз.", reply_markup=control_kb())
            return

        missing = [t for t in SELLABLE_TOKENS if t not in ranges]
        if missing:
            await message.answer(
                "Нужен диапазон для каждого из 6 токенов. Не задано:\n"
                + "\n".join(f"- {t}" for t in missing),
                reply_markup=control_kb(),
            )
            return

        await state.update_data(price_ranges=ranges)
        await state.set_state(SetPriceState.waiting_for_priorities)
        await message.answer(
            "Теперь пришли все 6 токенов через запятую — порядок = приоритет выставления.\n"
            "Каждый токен из списка выше должен встретиться ровно один раз.\n"
            "Пример (порядок свой):\n"
            "Revive Token, Death Gacha Token, Max Growth Token, Partial Growth Token, "
            "Random Trial Creature Token, Appearance Change Token",
            reply_markup=control_kb(),
        )

    @router.message(SetPriceState.waiting_for_priorities, AdminFilter(config.admin_id))
    async def on_set_price_priorities(message: Message, state: FSMContext):
        raw = (message.text or "").strip()
        parts = [x.strip() for x in raw.split(",") if x.strip()]
        unique: list[str] = []
        for p in parts:
            if p in SELLABLE_TOKENS and p not in unique:
                unique.append(p)

        if not sell_priority_tokens_valid(unique):
            await message.answer(
                f"Нужно перечислить ровно {SELL_PRIORITY_TOKEN_COUNT} разных токена из списка — "
                "каждый из 6 допустимых ровно один раз.",
                reply_markup=control_kb(),
            )
            return

        data = await state.get_data()
        ranges = data.get("price_ranges", {})

        await save_sell_price_snapshot(ranges, unique)
        await message.answer(
            "Цены и приоритеты сохранены в БД.\n"
            "Скрипты и инжектор <b>не</b> запускаются.\n"
            "Когда будешь готов, нажми «Запустить продажи» — тогда воркер создаст задачи "
            "на склады и выполнит выставление лотов.\n\n"
            f"Порядок приоритета: {', '.join(unique)}",
            reply_markup=control_kb(),
        )
        await state.clear()

    @router.message(F.text == MainMenuButtons.START_FARM.value, AdminFilter(config.admin_id))
    async def on_start_farm(message: Message):
        await rebalance_active_account_roles()
        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
                    farmer_ratio_percent=70,
                    farming_enabled=True,
                    sales_enabled=False,
                )
                session.add(settings)
            else:
                settings.farming_enabled = True
            death_points_target = settings.death_points_target
            await session.commit()

        async with AsyncSessionMaker() as session:
            farmers = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.FARMER.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()

        if not farmers:
            await message.answer(
                "Нет аккаунтов с ролью <b>фермер</b> и статусом <b>active</b>.\n"
                "Забаненные, checkpoint, invalid и т.п. сюда не входят.\n"
                "Статус смотри в таблице <b>accounts</b> (колонки <code>role</code>, <code>status</code>) — "
                "это не таблица <code>workers</code> (там привязка воркера к машине, без статуса аккаунта).\n"
                "Поставь фермеру <code>status=active</code> (или прогоняй логин-чек), затем снова «Запустить фарм».\n\n"
                "<i>Привязка WORKER_ACCOUNT_ID в .env только ограничивает воркер одним аккаунтом; "
                "задачи фарма бот создаёт только для active+farmer.</i>\n\n"
                "Убедись, что Telegram-бот и воркер смотрят в <b>одну и ту же</b> базу (одинаковый <code>DATABASE_URL</code>).",
                reply_markup=control_kb(),
            )
            return

        async with AsyncSessionMaker() as session:
            storages = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.STORAGE.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()

        # Убираем дубль-команды (legacy farm.lua не жмёт «Play» на слоте — используем универсальный скрипт).
        for farmer in farmers:
            await request_cancel_tasks(
                task_type=TaskType.START_FARM.value,
                account_id=farmer.id,
                only_pending=False,
            )
            await request_cancel_tasks(
                task_type=TaskType.UNIVERSAL_FARM.value,
                account_id=farmer.id,
                only_pending=False,
            )

        created = 0
        n = len(farmers)
        for i, farmer in enumerate(farmers):
            storage = storages[i % len(storages)] if storages else None
            farm_payload: dict[str, Any] = {
                "death_points_target": death_points_target,
                "loop": True,
                **_universal_farmer_runtime_payload(
                    queue_index=i + 1,
                    queue_total=n,
                    storage=storage,
                ),
            }
            await create_task(
                task_type=TaskType.UNIVERSAL_FARM.value,
                priority=1000,
                account_id=farmer.id,
                payload=farm_payload,
            )
            created += 1

        await message.answer(
            f"Фарм включён: создано задач универсального фарма (Kimi) = {created}. "
            f"Классические задачи <code>start_farm</code> / <code>farm.lua</code> для этих аккаунтов отменены.",
            reply_markup=control_kb(),
        )

    @router.message(F.text == MainMenuButtons.UNIVERSAL_FARM.value, AdminFilter(config.admin_id))
    async def on_universal_start_farm(message: Message):
        """Долгий фарм через ``universal_sonaria_bot.lua`` (Kimi), отдельно от legacy ``farm.lua``."""
        await rebalance_active_account_roles()
        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
                    farmer_ratio_percent=70,
                    farming_enabled=True,
                    sales_enabled=False,
                )
                session.add(settings)
            else:
                settings.farming_enabled = True
            death_points_target = settings.death_points_target
            await session.commit()

        async with AsyncSessionMaker() as session:
            farmers = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.FARMER.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()
            storages = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.STORAGE.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()

        if not farmers:
            await message.answer(
                "Нет активных фермеров для универсального фарма.",
                reply_markup=control_kb(),
            )
            return

        for farmer in farmers:
            await request_cancel_tasks(
                task_type=TaskType.START_FARM.value,
                account_id=farmer.id,
                only_pending=False,
            )
            await request_cancel_tasks(
                task_type=TaskType.UNIVERSAL_FARM.value,
                account_id=farmer.id,
                only_pending=False,
            )

        created = 0
        n = len(farmers)
        for i, farmer in enumerate(farmers):
            storage = storages[i % len(storages)] if storages else None
            farm_payload: dict[str, Any] = {
                "death_points_target": death_points_target,
                "loop": True,
                **_universal_farmer_runtime_payload(
                    queue_index=i + 1,
                    queue_total=n,
                    storage=storage,
                ),
            }
            await create_task(
                task_type=TaskType.UNIVERSAL_FARM.value,
                priority=1000,
                account_id=farmer.id,
                payload=farm_payload,
            )
            created += 1

        await message.answer(
            f"Универсальный фарм (Kimi): создано задач = {created}. "
            f"Классический «Запустить фарм» для этих аккаунтов отменён.",
            reply_markup=control_kb(),
        )

    @router.message(F.text == MainMenuButtons.STOP_FARM.value, AdminFilter(config.admin_id))
    async def on_stop_farm(message: Message):
        await rebalance_active_account_roles()
        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
                    farmer_ratio_percent=70,
                    farming_enabled=False,
                    sales_enabled=False,
                )
                session.add(settings)
            else:
                settings.farming_enabled = False
            await session.commit()

        async with AsyncSessionMaker() as session:
            farmers = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.FARMER.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()

        if not farmers:
            await message.answer(
                "Нет аккаунтов с ролью <b>фермер</b> и статусом <b>active</b> — останавливать нечего.",
                reply_markup=control_kb(),
            )
            return

        # Просим воркеры остановиться: отменяем farming-команды и добавляем explicit stop tasks
        for farmer in farmers:
            await request_cancel_tasks(
                task_type=TaskType.START_FARM.value,
                account_id=farmer.id,
                only_pending=False,
            )
            await request_cancel_tasks(
                task_type=TaskType.UNIVERSAL_FARM.value,
                account_id=farmer.id,
                only_pending=False,
            )
            await create_task(
                task_type=TaskType.STOP_FARM.value,
                priority=10000,
                account_id=farmer.id,
                payload={"loop": False},
            )

        await message.answer(
            f"Фарм выключен: stop-задачи созданы по {len(farmers)} фермерам.",
            reply_markup=control_kb(),
        )

    @router.message(F.text == MainMenuButtons.START_SALES.value, AdminFilter(config.admin_id))
    async def on_start_sales(message: Message):
        await rebalance_active_account_roles()
        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
                    farmer_ratio_percent=70,
                    farming_enabled=False,
                    sales_enabled=True,
                )
                session.add(settings)
            else:
                settings.sales_enabled = True
            await session.commit()

        async with AsyncSessionMaker() as session:
            settings_row = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
        ranges_raw = (settings_row.sell_ranges_json if settings_row else None) or ""
        prio_raw = (settings_row.sell_priority_tokens_json if settings_row else None) or ""

        if not ranges_raw.strip() or not prio_raw.strip():
            await message.answer(
                "Продажи включены.\n\n"
                "Нет сохранённого набора цен: один раз пройди «Выставить цену» "
                f"(диапазоны для всех {SELL_PRIORITY_TOKEN_COUNT} токенов и их порядок-приоритет) — "
                "тогда настройки сохранятся в БД. "
                "После этого снова нажми «Запустить продажи» — появятся задачи на склады.",
                reply_markup=control_kb(),
            )
            return

        try:
            ranges = json.loads(ranges_raw)
            priority_tokens = json.loads(prio_raw)
        except json.JSONDecodeError:
            await message.answer(
                "Продажи включены, но сохранённые настройки цен в БД повреждены. "
                "Пройди «Выставить цену» заново.",
                reply_markup=control_kb(),
            )
            return

        if not isinstance(ranges, dict) or not isinstance(priority_tokens, list):
            await message.answer(
                "Продажи включены, но сохранённые настройки цен имеют неверный формат. "
                "Пройди «Выставить цену» заново.",
                reply_markup=control_kb(),
            )
            return

        if not sell_priority_tokens_valid(priority_tokens):
            await message.answer(
                "Продажи включены, но сохранённые приоритеты устарели или некорректны. "
                "Пройди «Выставить цену» заново.",
                reply_markup=control_kb(),
            )
            return

        count, err = await enqueue_set_sell_price_for_active_storages(ranges, priority_tokens)
        if err:
            await message.answer(f"Продажи включены. {err}", reply_markup=control_kb())
            return

        await message.answer(
            f"Продажи включены. Созданы задачи на склады ({count}): выставление лотов по сохранённым ценам.\n"
            f"Приоритеты: {', '.join(priority_tokens)}",
            reply_markup=control_kb(),
        )

    @router.message(F.text == MainMenuButtons.UNIVERSAL_SELL.value, AdminFilter(config.admin_id))
    async def on_universal_start_sales(message: Message):
        """Продажи через ``universal_sonaria_bot.lua`` (тип задачи ``universal_sell``)."""
        await rebalance_active_account_roles()
        async with AsyncSessionMaker() as session:
            settings_row = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
        ranges_raw = (settings_row.sell_ranges_json if settings_row else None) or ""
        prio_raw = (settings_row.sell_priority_tokens_json if settings_row else None) or ""

        if not ranges_raw.strip() or not prio_raw.strip():
            await message.answer(
                "Сначала один раз пройди «Выставить цену» — без сохранённых диапазонов "
                "универсальные продажи не запускаются.",
                reply_markup=control_kb(),
            )
            return

        try:
            ranges = json.loads(ranges_raw)
            priority_tokens = json.loads(prio_raw)
        except json.JSONDecodeError:
            await message.answer(
                "Сохранённые настройки цен в БД повреждены. Пройди «Выставить цену» заново.",
                reply_markup=control_kb(),
            )
            return

        if not isinstance(ranges, dict) or not isinstance(priority_tokens, list):
            await message.answer("Неверный формат сохранённых цен.", reply_markup=control_kb())
            return

        if not sell_priority_tokens_valid(priority_tokens):
            await message.answer(
                "Приоритеты некорректны. Пройди «Выставить цену» заново.",
                reply_markup=control_kb(),
            )
            return

        count, err = await enqueue_universal_sell_for_active_storages(ranges, priority_tokens)
        if err:
            await message.answer(err, reply_markup=control_kb())
            return

        await message.answer(
            f"Универсальные продажи (Kimi): задачи для {count} складов.\n"
            f"Классические `Выставить цену` для них отменены.\n"
            f"Приоритеты: {', '.join(priority_tokens)}",
            reply_markup=control_kb(),
        )

    @router.message(F.text == MainMenuButtons.UNIVERSAL_INVENTORY.value, AdminFilter(config.admin_id))
    async def on_universal_inventory(message: Message):
        await rebalance_active_account_roles()
        async with AsyncSessionMaker() as session:
            accounts = (
                await session.scalars(
                    select(Account).where(Account.status == AccountStatus.ACTIVE.value)
                )
            ).all()

        if not accounts:
            await message.answer("Нет активных аккаунтов.", reply_markup=control_kb())
            return

        created = 0
        for acc in accounts:
            await create_task(
                task_type=TaskType.UNIVERSAL_INVENTORY.value,
                priority=400,
                account_id=acc.id,
                payload={},
            )
            created += 1

        await message.answer(
            f"Созданы задачи `Инвентарь (универсал)` для {created} активных аккаунтов.",
            reply_markup=control_kb(),
        )

    @router.message(F.text == MainMenuButtons.UNIVERSAL_DEX.value, AdminFilter(config.admin_id))
    async def on_universal_dex(message: Message):
        async with AsyncSessionMaker() as session:
            accounts = (
                await session.scalars(
                    select(Account).where(Account.status == AccountStatus.ACTIVE.value)
                )
            ).all()
        if not accounts:
            await message.answer("Нет активных аккаунтов.", reply_markup=control_kb())
            return

        created = 0
        for acc in accounts:
            await create_task(
                task_type=TaskType.UNIVERSAL_DEX.value,
                priority=200,
                account_id=acc.id,
                payload={},
            )
            created += 1

        await message.answer(
            f"Созданы задачи `Dex (универсал)` для {created} активных аккаунтов.",
            reply_markup=control_kb(),
        )

    @router.message(F.text == MainMenuButtons.STOP_SALES.value, AdminFilter(config.admin_id))
    async def on_stop_sales(message: Message):
        await rebalance_active_account_roles()
        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
                    farmer_ratio_percent=70,
                    farming_enabled=False,
                    sales_enabled=False,
                )
                session.add(settings)
            else:
                settings.sales_enabled = False
            await session.commit()

        async with AsyncSessionMaker() as session:
            storages = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.STORAGE.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()
        for storage in storages:
            await request_cancel_tasks(
                task_type=TaskType.SET_SELL_PRICE.value,
                account_id=storage.id,
                only_pending=False,
            )
            await request_cancel_tasks(
                task_type=TaskType.UNIVERSAL_SELL.value,
                account_id=storage.id,
                only_pending=False,
            )

        await message.answer("Продажи выключены. Текущие задачи продаж остановлены.", reply_markup=control_kb())

    # ── Test function handlers ──────────────────────────────────────────

    _TEST_BUTTON_TO_COMMAND: dict[str, str] = {
        TestButtons.EAT.value: "test_eat",
        TestButtons.DRINK.value: "test_drink",
        TestButtons.WALK.value: "test_walk",
        TestButtons.SNIFF.value: "test_sniff",
        TestButtons.ATTACK.value: "test_attack",
        TestButtons.MUD.value: "test_mud",
        TestButtons.SURVIVE.value: "test_survive",
        TestButtons.SHROOMS.value: "test_shrooms",
    }

    async def _run_test_command(message: Message, test_command: str) -> None:
        async with AsyncSessionMaker() as session:
            farmers = (
                await session.scalars(
                    select(Account).where(
                        Account.role == AccountRole.FARMER.value,
                        Account.status == AccountStatus.ACTIVE.value,
                    )
                )
            ).all()
        if not farmers:
            await message.answer("Нет активных фермеров.", reply_markup=test_kb())
            return
        farmer = farmers[0]

        # Toggle state is tracked by a marker file per (farmer, command).
        # If marker exists → a test is running → write stop flag + remove marker.
        # If marker doesn't exist → start test + create marker.
        import time
        from pathlib import Path as _P
        marker_dir = _P("runtime") / "test_toggle"
        marker_dir.mkdir(parents=True, exist_ok=True)
        marker = marker_dir / f"{farmer.id}__{test_command}.active"

        # Stale marker protection: consider markers older than 10 min as stale (Lua likely died).
        STALE_SEC = 600
        is_active = False
        if marker.exists():
            try:
                age = time.time() - marker.stat().st_mtime
                is_active = age < STALE_SEC
            except OSError:
                is_active = False
            if not is_active:
                try:
                    marker.unlink(missing_ok=True)
                except OSError:
                    pass

        if is_active:
            # Stop the running test.
            from farm.game.stop_flags import write_stop_flag
            await request_cancel_tasks(
                task_type=TaskType.UNIVERSAL_TEST.value,
                account_id=farmer.id,
                only_pending=False,
            )
            try:
                write_stop_flag(farmer.id)
            except OSError as exc:
                logger.warning("Could not write stop flag: %s", exc)
            try:
                marker.unlink(missing_ok=True)
            except OSError:
                pass
            # Clean other markers for this farmer to keep state consistent.
            try:
                for m in marker_dir.glob(f"{farmer.id}__*.active"):
                    m.unlink(missing_ok=True)
            except OSError:
                pass
            await message.answer(
                f"Тест `{test_command}` остановлен для {farmer.login}.",
                reply_markup=test_kb(),
            )
            return

        # Not active → start fresh. Clean stop flag + any stale markers first.
        from farm.game.stop_flags import clear_stop_flag
        try:
            for m in marker_dir.glob(f"{farmer.id}__*.active"):
                m.unlink(missing_ok=True)
        except OSError:
            pass
        await request_cancel_tasks(
            task_type=TaskType.UNIVERSAL_TEST.value,
            account_id=farmer.id,
            only_pending=False,
        )
        clear_stop_flag(farmer.id)
        try:
            marker.write_text("1\n", encoding="utf-8")
        except OSError as exc:
            logger.warning("Could not write test marker: %s", exc)
        await create_task(
            task_type=TaskType.UNIVERSAL_TEST.value,
            priority=2000,
            account_id=farmer.id,
            payload={"test_command": test_command},
        )
        await message.answer(
            f"Тест `{test_command}` запущен для {farmer.login}.",
            reply_markup=test_kb(),
        )

    @router.message(F.text == TestButtons.EAT.value, AdminFilter(config.admin_id))
    async def on_test_eat(message: Message):
        await _run_test_command(message, "test_eat")

    @router.message(F.text == TestButtons.DRINK.value, AdminFilter(config.admin_id))
    async def on_test_drink(message: Message):
        await _run_test_command(message, "test_drink")

    @router.message(F.text == TestButtons.WALK.value, AdminFilter(config.admin_id))
    async def on_test_walk(message: Message):
        await _run_test_command(message, "test_walk")

    @router.message(F.text == TestButtons.SNIFF.value, AdminFilter(config.admin_id))
    async def on_test_sniff(message: Message):
        await _run_test_command(message, "test_sniff")

    @router.message(F.text == TestButtons.ATTACK.value, AdminFilter(config.admin_id))
    async def on_test_attack(message: Message):
        await _run_test_command(message, "test_attack")

    @router.message(F.text == TestButtons.MUD.value, AdminFilter(config.admin_id))
    async def on_test_mud(message: Message):
        await _run_test_command(message, "test_mud")

    @router.message(F.text == TestButtons.SURVIVE.value, AdminFilter(config.admin_id))
    async def on_test_survive(message: Message):
        await _run_test_command(message, "test_survive")

    @router.message(F.text == TestButtons.SHROOMS.value, AdminFilter(config.admin_id))
    async def on_test_shrooms(message: Message):
        await _run_test_command(message, "test_shrooms")

    return router


async def main() -> None:
    config = load_config()
    bot = Bot(
        token=config.bot_token,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )
    dp = Dispatcher(storage=MemoryStorage())

    router = build_router(config)

    await ensure_migrations_applied()

    dp.include_router(router)

    logger.info("Starting bot")
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())

