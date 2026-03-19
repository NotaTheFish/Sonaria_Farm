import asyncio
import logging
import os
from dataclasses import dataclass
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

from db import AsyncSessionMaker, init_db
from models import Account, AccountRole, AccountStatus, ControllerSettings
from sqlalchemy import func, select


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
    BACK = "Назад"


class AccountsCallback(str, Enum):
    ACTIVE = "accounts_active"
    BANNED = "accounts_banned"
    UPLOAD = "accounts_upload"


class AccountUploadState(StatesGroup):
    waiting_for_accounts_file = State()


class ControllerDeathPointsState(StatesGroup):
    waiting_for_death_points = State()


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

    @router.message(F.text == SettingsButtons.TO_STORAGE.value, AdminFilter(config.admin_id))
    async def on_to_storage(message: Message):
        # TODO: создать задания передачи токенов со всех фермеров на склады
        await message.answer(
            "Создаю задачи на перевод токенов на склады (пока заглушка)."
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
            "Пришли файл `.txt` со строками формата `LOGIN:PASSWORD`.\n"
            "Бот распределит 70% аккаунтов на `FARMER` и 30% на `STORAGE`."
        )
        await state.set_state(AccountUploadState.waiting_for_accounts_file)
        await callback.answer()

    @router.message(F.document, AccountUploadState.waiting_for_accounts_file, AdminFilter(config.admin_id))
    async def on_accounts_file(message: Message, state: FSMContext):
        if not message.document or not message.document.file_name:
            await message.answer("Не вижу имя файла. Пришли `.txt` файл.")
            return

        file_name = message.document.file_name
        if not file_name.lower().endswith(".txt"):
            await message.answer("Нужен именно файл `.txt`. Попробуй ещё раз.")
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
        farmers_count = int(total * 0.7)  # округление вниз
        storages_count = total - farmers_count

        inserted = 0
        updated = 0

        async with AsyncSessionMaker() as session:
            for idx, (login, password) in enumerate(unique):
                role = AccountRole.FARMER.value if idx < farmers_count else AccountRole.STORAGE.value

                existing = await session.scalar(select(Account).where(Account.login == login))
                if existing:
                    updated += 1
                    existing.password = password
                    existing.role = role
                    if existing.status != AccountStatus.BANNED.value:
                        existing.status = AccountStatus.ACTIVE.value
                    continue

                session.add(
                    Account(
                        login=login,
                        password=password,
                        role=role,
                        status=AccountStatus.ACTIVE.value,
                    )
                )
                inserted += 1

            await session.commit()

        # Обновим счетчики, чтобы показать адекватный результат
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

        await message.answer(
            "Загрузка аккаунтов завершена.\n"
            f"Всего строк: {total}\n"
            f"FARMER (70%): {farmers_count}\n"
            f"STORAGE (30%): {storages_count}\n\n"
            f"Добавлено: {inserted}\n"
            f"Обновлено: {updated}\n\n"
            "Текущие счетчики:\n"
            f"Действующие: фермеров {farmers_active}, складов {storages_active}\n"
            f"Забаненные: фермеров {farmers_banned}, складов {storages_banned}"
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
    async def on_set_price(message: Message):
        await message.answer(
            "Настройка цены для складов пока не реализована (заглушка)."
        )

    @router.message(F.text == MainMenuButtons.START_FARM.value, AdminFilter(config.admin_id))
    async def on_start_farm(message: Message):
        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
                    farming_enabled=True,
                    sales_enabled=False,
                )
                session.add(settings)
            else:
                settings.farming_enabled = True
            await session.commit()

        await message.answer("Фарм включен.")

    @router.message(F.text == MainMenuButtons.STOP_FARM.value, AdminFilter(config.admin_id))
    async def on_stop_farm(message: Message):
        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
                    farming_enabled=False,
                    sales_enabled=False,
                )
                session.add(settings)
            else:
                settings.farming_enabled = False
            await session.commit()

        await message.answer("Фарм выключен.")

    @router.message(F.text == MainMenuButtons.START_SALES.value, AdminFilter(config.admin_id))
    async def on_start_sales(message: Message):
        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
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
        async with AsyncSessionMaker() as session:
            settings = await session.scalar(
                select(ControllerSettings).where(ControllerSettings.id == 1)
            )
            if not settings:
                settings = ControllerSettings(
                    id=1,
                    death_points_target=600,
                    farming_enabled=False,
                    sales_enabled=False,
                )
                session.add(settings)
            else:
                settings.sales_enabled = False
            await session.commit()

        await message.answer("Продажи выключены.")

    return router


async def main() -> None:
    config = load_config()
    bot = Bot(
        token=config.bot_token,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )
    dp = Dispatcher(storage=MemoryStorage())

    router = build_router(config)

    await init_db()

    dp.include_router(router)

    logger.info("Starting bot")
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())

