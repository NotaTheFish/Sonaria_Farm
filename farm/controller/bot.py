import asyncio
import csv
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from enum import Enum, auto
from typing import Optional
from io import BytesIO

from aiogram import Bot, Dispatcher, F
from aiogram.filters import BaseFilter, CommandStart
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
    InputFile,
)
from aiogram.enums import ParseMode
from aiogram import Router
from aiogram.client.default import DefaultBotProperties

from dotenv import load_dotenv

from farm.database import AsyncSessionMaker, ensure_migrations_applied
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
    SETTINGS = "Настройка"
    DEATH_POINTS = "Очки смерти"
    SET_PRICE = "Выставить цену"
    START_FARM = "Запустить фарм"
    STOP_FARM = "Остановить фарм"
    START_SALES = "Запустить продажи"
    STOP_SALES = "Остановить продажи"


class SettingsButtons(str, Enum):
    INVENTORY = "Инвентарь"
    TO_STORAGE = "На склад"
    ACCOUNTS = "Аккаунты"
    QUEUE_STATUS = "Статус очереди"
    ROLE_RATIO = "Соотношение ролей"
    BACK = "Назад"


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
            KeyboardButton(text=MainMenuButtons.SETTINGS.value),
            KeyboardButton(text=MainMenuButtons.DEATH_POINTS.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.SET_PRICE.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.START_FARM.value),
            KeyboardButton(text=MainMenuButtons.STOP_FARM.value),
        ],
        [
            KeyboardButton(text=MainMenuButtons.START_SALES.value),
            KeyboardButton(text=MainMenuButtons.STOP_SALES.value),
        ],
    ]
    return ReplyKeyboardMarkup(
        keyboard=buttons,
        resize_keyboard=True,
        input_field_placeholder="Выберите действие",
    )


def settings_kb() -> ReplyKeyboardMarkup:
    buttons = [
        [
            KeyboardButton(text=SettingsButtons.INVENTORY.value),
            KeyboardButton(text=SettingsButtons.TO_STORAGE.value),
        ],
        [
            KeyboardButton(text=SettingsButtons.ACCOUNTS.value),
            KeyboardButton(text=SettingsButtons.QUEUE_STATUS.value),
        ],
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
        input_field_placeholder="Настройки",
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
        farmers_count = int(total * ratio / 100)
        storages_count = total - farmers_count

        for idx, acc in enumerate(active_accounts):
            acc.role = AccountRole.FARMER.value if idx < farmers_count else AccountRole.STORAGE.value

        await session.commit()

    return total, farmers_count, storages_count


def build_router(config: Config) -> Router:
    router = Router()

    @router.message(CommandStart(), AdminFilter(config.admin_id))
    async def cmd_start(message: Message):
        await message.answer(
            "Привет, админ.\nЭто контроллер ботов для Creatures of Sonaria.",
            reply_markup=main_menu_kb(),
        )

    @router.message(F.text == MainMenuButtons.SETTINGS.value, AdminFilter(config.admin_id))
    async def on_settings(message: Message):
        await message.answer("Меню настроек.", reply_markup=settings_kb())

    @router.message(F.text == SettingsButtons.BACK.value, AdminFilter(config.admin_id))
    async def on_back_to_main(message: Message):
        await message.answer("Главное меню.", reply_markup=main_menu_kb())

    @router.message(F.text == SettingsButtons.INVENTORY.value, AdminFilter(config.admin_id))
    async def on_inventory(message: Message):
        # TODO: подставить реальные данные из хранилища
        text = (
            "Инвентарь (пока заглушка):\n"
            "Фермеры: токены не посчитаны.\n"
            "Склады: токены не посчитаны."
        )
        await message.answer(text)

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
                        Task.task_type == TaskType.START_FARM.value,
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
            f"start_farm running={farm_running}\n"
            f"transfer_to_storage pending={transfer_pending}\n"
            f"set_sell_price pending={sell_pending}\n\n"
            f"Воркеры: alive={workers_alive}, total={workers_total}"
        )

    @router.message(F.text == SettingsButtons.ROLE_RATIO.value, AdminFilter(config.admin_id))
    async def on_role_ratio(message: Message, state: FSMContext):
        settings = await get_or_create_settings()
        await message.answer(
            "Введи соотношение farmer/storage в формате `70/30` или одним числом `70`.\n"
            f"Текущее значение: {settings.farmer_ratio_percent}/{100-settings.farmer_ratio_percent}"
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
            await message.answer("Неверный формат. Примеры: `70/30` или `70`.")
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
            f"Активных аккаунтов: {active_total} -> farmer={farmers_count}, storage={storages_count}"
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
            await message.answer("Нет активных аккаунтов-фермеров.")
            return
        if not storages:
            await message.answer("Нет активных аккаунтов-складов.")
            return

        # Чтобы не было дублей trade-операций, отменяем уже стоящие задачи переноса
        for farmer in farmers:
            await request_cancel_tasks(
                task_type=TaskType.TRANSFER_TO_STORAGE.value,
                account_id=farmer.id,
                only_pending=False,
            )

        created = 0
        for i, farmer in enumerate(farmers):
            storage = storages[i % len(storages)]
            payload = {
                "target_storage_account_id": storage.id,
                "batch_size": 150,
                "cooldown_seconds": 70,
                "storage_gives": 1,  # 1 гриб за trade-батч
                "token_kinds": [
                    "Revive Token",
                    "Max Growth Token",
                    "Partial Growth Token",
                    "Random Trial Creature Token",
                    "Appearance Change Token",
                    "Death Gacha Token",
                ],
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
            f"Созданы задачи `На склад`: {created} штук (фермеров={len(farmers)}, складов={len(storages)})."
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

        await callback.message.answer_document(InputFile(bio))
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

        await callback.message.answer_document(InputFile(bio))
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
            await message.answer("Не вижу имя файла. Пришли `.txt` или `.csv` файл.")
            return

        file_name = message.document.file_name
        if not (file_name.lower().endswith(".txt") or file_name.lower().endswith(".csv")):
            await message.answer("Нужен файл `.txt` или `.csv`. Попробуй ещё раз.")
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
            await message.answer("Файл пустой или не удалось распарсить `LOGIN:PASSWORD`.")
            await state.clear()
            return

        total = len(unique)

        inserted = 0
        updated = 0
        check_tasks_created = 0

        async with AsyncSessionMaker() as session:
            imported_account_ids: list[str] = []
            for login, password in unique:
                existing = await session.scalar(select(Account).where(Account.login == login))
                if existing:
                    updated += 1
                    existing.password = password
                    existing.status = AccountStatus.NEW.value
                    existing.role = None
                    imported_account_ids.append(existing.id)
                    continue

                account = Account(
                    login=login,
                    password=password,
                    role=None,
                    status=AccountStatus.NEW.value,
                )
                session.add(account)
                await session.flush()
                imported_account_ids.append(account.id)
                session.add(
                    account
                )
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
            f"Роли среди active (ratio {ratio}%/{100-ratio}%): farmer={farmers_count}, storage={storages_count}"
        )

        await state.clear()

    @router.message(F.text == MainMenuButtons.DEATH_POINTS.value, AdminFilter(config.admin_id))
    async def on_death_points(message: Message, state: FSMContext):
        await message.answer(
            "Введите количество очков смерти для цикла фарма "
            "(например 600 или 1200).",
            reply_markup=ReplyKeyboardRemove(),
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
            await message.answer("Значение должно быть больше 0.")
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

        await message.answer(f"Ок. Целевые `Очки смерти` установлены на {points}.")
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
            "Death Gacha Token=8000-9500"
        )
        await state.set_state(SetPriceState.waiting_for_ranges)

    @router.message(SetPriceState.waiting_for_ranges, AdminFilter(config.admin_id))
    async def on_set_price_ranges(message: Message, state: FSMContext):
        raw = (message.text or "").strip()
        if not raw:
            await message.answer("Пустой ввод. Пришли диапазоны в формате Token=min-max.")
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
            await message.answer("Не удалось распарсить ни одного диапазона. Попробуй еще раз.")
            return

        await state.update_data(price_ranges=ranges)
        await state.set_state(SetPriceState.waiting_for_priorities)
        await message.answer(
            "Теперь пришли 4 приоритетных токена через запятую.\n"
            "Пример:\n"
            "Revive Token, Death Gacha Token, Max Growth Token, Partial Growth Token"
        )

    @router.message(SetPriceState.waiting_for_priorities, AdminFilter(config.admin_id))
    async def on_set_price_priorities(message: Message, state: FSMContext):
        raw = (message.text or "").strip()
        parts = [x.strip() for x in raw.split(",") if x.strip()]
        unique: list[str] = []
        for p in parts:
            if p in SELLABLE_TOKENS and p not in unique:
                unique.append(p)

        if len(unique) != 4:
            await message.answer("Нужно выбрать ровно 4 уникальных токена из списка.")
            return

        data = await state.get_data()
        ranges = data.get("price_ranges", {})

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
            await message.answer("Нет активных аккаунтов-складов.")
            await state.clear()
            return

        for storage in storages:
            await request_cancel_tasks(
                task_type=TaskType.SET_SELL_PRICE.value,
                account_id=storage.id,
                only_pending=False,
            )
            await create_task(
                task_type=TaskType.SET_SELL_PRICE.value,
                priority=300,
                account_id=storage.id,
                payload={
                    "ranges": ranges,
                    "priority_tokens": unique,
                    "fallback_non_priority_mode": "sell_all_when_priority_empty",
                },
            )

        await message.answer(
            f"Созданы задачи `Выставить цену` для {len(storages)} складов.\n"
            f"Приоритеты: {', '.join(unique)}"
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
            await message.answer("Нет активных аккаунтов-фермеров.")
            return

        # Убираем дубль-команды: отменяем уже существующие start_farm задачи
        for farmer in farmers:
            await request_cancel_tasks(
                task_type=TaskType.START_FARM.value,
                account_id=farmer.id,
                only_pending=False,
            )

        created = 0
        for farmer in farmers:
            await create_task(
                task_type=TaskType.START_FARM.value,
                priority=1000,
                account_id=farmer.id,
                payload={"death_points_target": death_points_target, "loop": True},
            )
            created += 1

        await message.answer(
            f"Фарм включен: создано задач `Запустить фарм` = {created}."
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
            await message.answer("Нет активных аккаунтов-фермеров.")
            return

        # Просим воркеры остановиться: отменяем farming-команды и добавляем explicit stop tasks
        for farmer in farmers:
            await request_cancel_tasks(
                task_type=TaskType.START_FARM.value,
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
            f"Фарм выключен: stop-задачи созданы по {len(farmers)} фермерам."
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

        await message.answer("Продажи включены.")

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

        await message.answer("Продажи выключены. Текущие задачи продаж остановлены.")

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

