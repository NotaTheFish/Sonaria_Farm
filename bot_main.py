import asyncio
import logging
import os
from dataclasses import dataclass
from enum import Enum, auto
from typing import Optional

from aiogram import Bot, Dispatcher, F
from aiogram.filters import CommandStart
from aiogram.types import (
    Message,
    KeyboardButton,
    ReplyKeyboardMarkup,
    ReplyKeyboardRemove,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Document,
)
from aiogram.enums import ParseMode
from aiogram import Router

from dotenv import load_dotenv


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


def is_admin(message: Message, config: Config) -> bool:
    return message.from_user and message.from_user.id == config.admin_id


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


def admin_only(handler):
    """
    Декоратор для хэндлеров сообщений, чтобы реагировать только на админа.
    Обычным пользователям бот просто игнорирует сообщения.
    """

    async def wrapper(message: Message, *args, **kwargs):
        dp: Dispatcher = kwargs.get("dp")  # not used, kept for compat
        config: Config = kwargs.get("config")
        if not config:
            logger.error("Config is not passed to handler")
            return
        if not is_admin(message, config):
            # Молча игнорируем
            return
        return await handler(message, *args, **kwargs)

    return wrapper


def build_router(config: Config) -> Router:
    router = Router()

    @router.message(CommandStart())
    @admin_only
    async def cmd_start(message: Message, config: Config):
        await message.answer(
            "Привет, админ.\nЭто контроллер ботов для Creatures of Sonaria.",
            reply_markup=main_menu_kb(),
        )

    @router.message(F.text == MainMenuButtons.SETTINGS.value)
    @admin_only
    async def on_settings(message: Message, config: Config):
        await message.answer("Меню настроек.", reply_markup=settings_kb())

    @router.message(F.text == SettingsButtons.BACK.value)
    @admin_only
    async def on_back_to_main(message: Message, config: Config):
        await message.answer("Главное меню.", reply_markup=main_menu_kb())

    @router.message(F.text == SettingsButtons.INVENTORY.value)
    @admin_only
    async def on_inventory(message: Message, config: Config):
        # TODO: подставить реальные данные из хранилища
        text = (
            "Инвентарь (пока заглушка):\n"
            "Фермеры: токены не посчитаны.\n"
            "Склады: токены не посчитаны."
        )
        await message.answer(text)

    @router.message(F.text == SettingsButtons.TO_STORAGE.value)
    @admin_only
    async def on_to_storage(message: Message, config: Config):
        # TODO: создать задания передачи токенов со всех фермеров на склады
        await message.answer(
            "Создаю задачи на перевод токенов на склады (пока заглушка)."
        )

    @router.message(F.text == SettingsButtons.ACCOUNTS.value)
    @admin_only
    async def on_accounts(message: Message, config: Config):
        # TODO: посчитать реальные цифры активных/забаненных
        text = (
            "Аккаунты (заглушка):\n"
            "Действующие: фермеров 0, складов 0.\n"
            "Забаненные: фермеров 0, складов 0."
        )
        await message.answer(text, reply_markup=accounts_inline_kb())

    @router.message(F.text == MainMenuButtons.DEATH_POINTS.value)
    @admin_only
    async def on_death_points(message: Message, config: Config):
        await message.answer(
            "Введите количество очков смерти для цикла фарма "
            "(например 600 или 1200).",
            reply_markup=ReplyKeyboardRemove(),
        )
        # Здесь можно сохранить состояние диалога через FSM/Redis,
        # но пока только текстовое сообщение-заглушка.

    @router.message(F.text == MainMenuButtons.SET_PRICE.value)
    @admin_only
    async def on_set_price(message: Message, config: Config):
        await message.answer(
            "Настройка цены для складов пока не реализована (заглушка)."
        )

    @router.message(F.text == MainMenuButtons.START_FARM.value)
    @admin_only
    async def on_start_farm(message: Message, config: Config):
        # TODO: включить глобальный флаг фарма и раздать задания
        await message.answer("Фарм запущен (пока только логическое состояние).")

    @router.message(F.text == MainMenuButtons.STOP_FARM.value)
    @admin_only
    async def on_stop_farm(message: Message, config: Config):
        # TODO: выключить фарм
        await message.answer("Фарм остановлен (пока только логическое состояние).")

    @router.message(F.text == MainMenuButtons.START_SALES.value)
    @admin_only
    async def on_start_sales(message: Message, config: Config):
        # TODO: включить продажи на складах
        await message.answer("Продажи запущены (пока только логическое состояние).")

    @router.message(F.text == MainMenuButtons.STOP_SALES.value)
    @admin_only
    async def on_stop_sales(message: Message, config: Config):
        # TODO: выключить продажи
        await message.answer("Продажи остановлены (пока только логическое состояние).")

    return router


async def main() -> None:
    config = load_config()
    bot = Bot(token=config.bot_token, parse_mode=ParseMode.HTML)
    dp = Dispatcher()

    router = build_router(config)

    # В aiogram v3 нет глобального контекста, передадим config через middleware
    @dp.update.outer_middleware()
    async def config_middleware(handler, event, data):
        data["config"] = config
        return await handler(event, data)

    dp.include_router(router)

    logger.info("Starting bot")
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())

