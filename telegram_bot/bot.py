# telegram_bot/bot.py
import asyncio
import os
from datetime import datetime
from typing import Optional
import io
import sqlite3

# Telegram bot imports
try:
    from aiogram import Bot, Dispatcher, types
    from aiogram.contrib.middlewares.logging import LoggingMiddleware
    from aiogram.types import ParseMode, InputFile
    from aiogram.utils import executor
    from aiogram.dispatcher import FSMContext
    from aiogram.dispatcher.filters.state import State, StatesGroup
    from aiogram.contrib.fsm_storage.memory import MemoryStorage
except ImportError:
    print("[TelegramBot] aiogram не установлен. Установите: pip install aiogram==2.25.1")
    # Заглушки для импорта
    Bot = None
    Dispatcher = None
    types = None

class FarmTelegramBot:
    """
    Telegram бот для управления фермой
    Позволяет:
    - Загружать аккаунты
    - Смотреть статистику
    - Запускать/останавливать фарм
    - Получать уведомления о банах
    """
    
    # Состояния для FSM
    class States(StatesGroup):
        waiting_for_accounts_file = State()
        waiting_for_proxy_file = State()
        waiting_for_bot_count = State()
    
    def __init__(self, token: str, orchestrator, allowed_users: list = None):
        """
        Инициализация бота
        
        Args:
            token: токен Telegram бота
            orchestrator: объект оркестратора
            allowed_users: список разрешенных user_id (если None - все разрешены)
        """
        self.token = token
        self.orchestrator = orchestrator
        self.allowed_users = allowed_users or []
        
        # Проверяем наличие aiogram
        if Bot is None:
            print("[TelegramBot] CRITICAL: aiogram не установлен. Бот не будет работать.")
            self.available = False
            return
        
        self.available = True
        
        # Инициализация бота
        self.storage = MemoryStorage()
        self.bot = Bot(token=token)
        self.dp = Dispatcher(self.bot, storage=self.storage)
        self.dp.middleware.setup(LoggingMiddleware())
        
        # Регистрация обработчиков
        self._register_handlers()
        
        print("[TelegramBot] Инициализирован")
    
    def _register_handlers(self):
        """Регистрация всех обработчиков команд"""
        
        # Команды
        self.dp.register_message_handler(self.cmd_start, commands=['start'])
        self.dp.register_message_handler(self.cmd_help, commands=['help'])
        self.dp.register_message_handler(self.cmd_status, commands=['status'])
        self.dp.register_message_handler(self.cmd_stats, commands=['stats'])
        self.dp.register_message_handler(self.cmd_upload, commands=['upload'])
        self.dp.register_message_handler(self.cmd_start_farm, commands=['start_farm'])
        self.dp.register_message_handler(self.cmd_stop_farm, commands=['stop_farm'])
        self.dp.register_message_handler(self.cmd_proxy, commands=['proxy'])
        self.dp.register_message_handler(self.cmd_banlist, commands=['banlist'])
        self.dp.register_message_handler(self.cmd_export, commands=['export'])
        
        # Обработчики файлов
        self.dp.register_message_handler(self.handle_accounts_file, 
                                         content_types=types.ContentTypes.DOCUMENT,
                                         state=self.States.waiting_for_accounts_file)
        self.dp.register_message_handler(self.handle_proxy_file,
                                         content_types=types.ContentTypes.DOCUMENT,
                                         state=self.States.waiting_for_proxy_file)
        
        # Callback запросы
        self.dp.register_callback_query_handler(self.cb_start_farm, lambda c: c.data == 'start_farm')
        self.dp.register_callback_query_handler(self.cb_stop_farm, lambda c: c.data == 'stop_farm')
        self.dp.register_callback_query_handler(self.cb_refresh_stats, lambda c: c.data == 'refresh')
    
    async def _check_access(self, user_id: int) -> bool:
        """
        Проверка доступа пользователя
        
        Args:
            user_id: ID пользователя Telegram
            
        Returns:
            True если доступ разрешен
        """
        if not self.allowed_users:
            return True
        return user_id in self.allowed_users
    
    async def _send_unauthorized(self, message: types.Message):
        """Отправка сообщения о неавторизованном доступе"""
        await message.reply("⛔ У вас нет доступа к этому боту.")
    
    # ============== Обработчики команд ==============
    
    async def cmd_start(self, message: types.Message):
        """Обработчик команды /start"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        welcome_text = """
🤖 **Sonaria Farm Bot**

Добро пожаловать! Я бот для управления фермой Creatures of Sonaria.

**Доступные команды:**
/help - список всех команд
/status - статус фермы
/stats - подробная статистика
/upload - загрузить аккаунты
/start_farm - запустить фарм
/stop_farm - остановить фарм
/proxy - управление прокси
/banlist - список забаненных
/export - экспорт статистики

**Статус:** 🟢 Ферма запущена
        """
        
        # Создаем клавиатуру
        keyboard = types.InlineKeyboardMarkup(row_width=2)
        keyboard.add(
            types.InlineKeyboardButton("📊 Статус", callback_data="refresh"),
            types.InlineKeyboardButton("▶️ Старт", callback_data="start_farm"),
            types.InlineKeyboardButton("⏹️ Стоп", callback_data="stop_farm"),
            types.InlineKeyboardButton("📈 Статистика", callback_data="stats")
        )
        
        await message.reply(welcome_text, parse_mode=ParseMode.MARKDOWN, reply_markup=keyboard)
    
    async def cmd_help(self, message: types.Message):
        """Обработчик команды /help"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        help_text = """
📚 **Команды бота**

**Основные команды:**
/start - приветствие и меню
/help - это сообщение
/status - текущий статус фермы
/stats - подробная статистика

**Управление аккаунтами:**
/upload - загрузить файл с аккаунтами (login:password)
/banlist - список забаненных аккаунтов
/export - экспорт статистики в CSV

**Управление фермой:**
/start_farm [N] - запустить N ботов (по умолчанию 5)
/stop_farm - остановить всех ботов
/proxy - загрузить файл с прокси

**Форматы файлов:**
Аккаунты: login:password (по одному на строку)
Прокси: ip:port или ip:port:login:pass
        """
        
        await message.reply(help_text, parse_mode=ParseMode.MARKDOWN)
    
    async def cmd_status(self, message: types.Message):
        """Обработчик команды /status"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        # Получаем статистику
        stats = await self.orchestrator.get_statistics()
        
        # Формируем сообщение
        status_text = f"""
📊 **Текущий статус фермы**

**Основные показатели:**
• Всего токенов: `{stats['total_tokens']}`
• За 24 часа: `{stats['tokens_last_24h']}`
• Прибыль: `${stats['estimated_value_usd']}`

**Аккаунты:**
• Всего: `{stats['total_accounts']}`
• Активных: `{stats['active_accounts']}`
• В работе: `{stats['farming_now']}`
• Ожидает: `{stats['pending_accounts']}`
• Забанено: `{stats['banned_accounts']}`

**Flickaflie:**
• Есть Flickaflie: `{stats['flickaflie_accounts']}`

**Система:**
• Воркеров: `{stats['active_workers']}`
• Задач в очереди: `{stats['queue_size']}`
• Время работы: `{stats['uptime_hours']} ч`
• Токенов/час: `{stats['tokens_per_hour']}`

🟢 **Ферма работает**
        """
        
        # Клавиатура
        keyboard = types.InlineKeyboardMarkup()
        keyboard.add(
            types.InlineKeyboardButton("🔄 Обновить", callback_data="refresh"),
            types.InlineKeyboardButton("▶️ Запустить", callback_data="start_farm"),
            types.InlineKeyboardButton("⏹️ Остановить", callback_data="stop_farm")
        )
        
        await message.reply(status_text, parse_mode=ParseMode.MARKDOWN, reply_markup=keyboard)
    
    async def cmd_stats(self, message: types.Message):
        """Обработчик команды /stats - подробная статистика"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        stats = await self.orchestrator.get_statistics()
        
        # Получаем дополнительную статистику из БД
        conn = sqlite3.connect(self.orchestrator.db_path)
        c = conn.cursor()
        
        # Топ аккаунтов по токенам
        c.execute('''
            SELECT login, death_tokens FROM accounts 
            WHERE death_tokens > 0 
            ORDER BY death_tokens DESC LIMIT 5
        ''')
        top_accounts = c.fetchall()
        
        # Последние баны
        c.execute('''
            SELECT account_login, ban_time, ban_type FROM bans 
            ORDER BY ban_time DESC LIMIT 5
        ''')
        recent_bans = c.fetchall()
        
        conn.close()
        
        # Формируем топ аккаунтов
        top_text = ""
        for i, (login, tokens) in enumerate(top_accounts, 1):
            masked_login = login[:4] + '*' * (len(login) - 4) if len(login) > 4 else login
            top_text += f"{i}. {masked_login}: {tokens} токенов\n"
        
        # Формируем список банов
        bans_text = ""
        for login, ban_time, ban_type in recent_bans:
            bans_text += f"• {login} - {ban_type}\n"
        
        detailed_stats = f"""
📈 **Детальная статистика**

**Топ аккаунтов:**
{top_text if top_text else "Нет данных"}

**Последние баны:**
{bans_text if bans_text else "Нет банов"}

**Эффективность:**
• Средняя сессия: `{stats['avg_session_duration_min']} мин`
• Токенов/час: `{stats['tokens_per_hour']}`
• Всего банов: `{stats['total_bans_ever']}`

**Прогноз:**
• За день: `{stats['tokens_per_hour'] * 24:.0f}`
• За неделю: `{stats['tokens_per_hour'] * 24 * 7:.0f}`
• Прибыль/день: `${(stats['tokens_per_hour'] * 24 * 0.05):.2f}`
        """
        
        await message.reply(detailed_stats, parse_mode=ParseMode.MARKDOWN)
    
    async def cmd_upload(self, message: types.Message):
        """Обработчик команды /upload"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        await message.reply("📎 Отправьте файл с аккаунтами в формате login:password (по одному на строку)")
        await self.States.waiting_for_accounts_file.set()
    
    async def cmd_start_farm(self, message: types.Message):
        """Обработчик команды /start_farm"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        # Парсим аргументы
        args = message.get_args()
        bot_count = 5  # По умолчанию
        
        if args and args.isdigit():
            bot_count = int(args)
        
        await message.reply(f"🔄 Запускаю {bot_count} ботов...")
        
        # Запускаем фарм
        await self.orchestrator.start_farming_on_all_ready(max_bots=bot_count)
        
        await message.reply(f"✅ Запущено {bot_count} ботов")
    
    async def cmd_stop_farm(self, message: types.Message):
        """Обработчик команды /stop_farm"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        await message.reply("⏹️ Останавливаю всех ботов...")
        
        # Здесь логика остановки
        # await self.orchestrator.stop_all_farming()
        
        await message.reply("✅ Все боты остановлены")
    
    async def cmd_proxy(self, message: types.Message):
        """Обработчик команды /proxy"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        await message.reply("🌐 Отправьте файл с прокси (ip:port или ip:port:login:pass)")
        await self.States.waiting_for_proxy_file.set()
    
    async def cmd_banlist(self, message: types.Message):
        """Обработчик команды /banlist"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        conn = sqlite3.connect(self.orchestrator.db_path)
        c = conn.cursor()
        
        c.execute('''
            SELECT account_login, ban_time, ban_type, worker_id 
            FROM bans 
            ORDER BY ban_time DESC 
            LIMIT 20
        ''')
        bans = c.fetchall()
        
        conn.close()
        
        if not bans:
            await message.reply("✅ Банов нет!")
            return
        
        ban_text = "🚫 **Последние баны:**\n\n"
        for login, ban_time, ban_type, worker_id in bans:
            ban_text += f"• {login}\n  Время: {ban_time[:16]}\n  Тип: {ban_type}\n\n"
        
        # Разбиваем на части если слишком длинное
        if len(ban_text) > 4000:
            parts = [ban_text[i:i+4000] for i in range(0, len(ban_text), 4000)]
            for part in parts:
                await message.reply(part, parse_mode=ParseMode.MARKDOWN)
        else:
            await message.reply(ban_text, parse_mode=ParseMode.MARKDOWN)
    
    async def cmd_export(self, message: types.Message):
        """Обработчик команды /export - экспорт статистики"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            return
        
        # Создаем CSV
        import csv
        import io
        
        output = io.StringIO()
        writer = csv.writer(output)
        
        # Заголовки
        writer.writerow(['Login', 'Tier', 'Has Flickaflie', 'Death Tokens', 'Status', 'Ban Count', 'Last Active'])
        
        conn = sqlite3.connect(self.orchestrator.db_path)
        c = conn.cursor()
        c.execute('''
            SELECT login, tier, has_flickaflie, death_tokens, status, ban_count, last_active 
            FROM accounts
        ''')
        rows = c.fetchall()
        conn.close()
        
        for row in rows:
            writer.writerow(row)
        
        # Отправляем файл
        csv_bytes = io.BytesIO()
        csv_bytes.write(output.getvalue().encode('utf-8'))
        csv_bytes.seek(0)
        
        await message.reply_document(
            InputFile(csv_bytes, filename=f"farm_export_{datetime.now().strftime('%Y%m%d')}.csv"),
            caption="📊 Экспорт данных фермы"
        )
    
    # ============== Обработчики файлов ==============
    
    async def handle_accounts_file(self, message: types.Message, state: FSMContext):
        """Обработка загруженного файла с аккаунтами"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            await state.finish()
            return
        
        document = message.document
        file_path = f"data/accounts_{message.from_user.id}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
        
        # Скачиваем файл
        await document.download(destination_file=file_path)
        
        await message.reply(f"📥 Файл получен. Загружаю аккаунты...")
        
        # Загружаем в оркестратор
        count = await self.orchestrator.load_accounts_from_file(file_path)
        
        await message.reply(f"✅ Загружено {count} аккаунтов")
        
        # Спрашиваем, запустить ли классификацию
        keyboard = types.InlineKeyboardMarkup()
        keyboard.add(
            types.InlineKeyboardButton("✅ Да", callback_data="classify"),
            types.InlineKeyboardButton("❌ Нет", callback_data="cancel")
        )
        
        await message.reply("Запустить классификацию аккаунтов?", reply_markup=keyboard)
        
        await state.finish()
    
    async def handle_proxy_file(self, message: types.Message, state: FSMContext):
        """Обработка загруженного файла с прокси"""
        if not await self._check_access(message.from_user.id):
            await self._send_unauthorized(message)
            await state.finish()
            return
        
        document = message.document
        file_path = f"data/proxies_{message.from_user.id}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
        
        await document.download(destination_file=file_path)
        
        await message.reply(f"🌐 Файл с прокси сохранен. Загружаю...")
        
        # Загружаем в прокси менеджер
        if self.orchestrator.proxy_manager:
            self.orchestrator.proxy_manager.load_proxies(file_path)
            stats = self.orchestrator.proxy_manager.get_statistics()
            await message.reply(f"✅ Загружено {stats['total']} прокси")
        else:
            await message.reply("❌ Прокси менеджер не инициализирован")
        
        await state.finish()
    
    # ============== Callback обработчики ==============
    
    async def cb_start_farm(self, callback_query: types.CallbackQuery):
        """Callback для кнопки старт"""
        if not await self._check_access(callback_query.from_user.id):
            await callback_query.answer("Нет доступа")
            return
        
        await callback_query.answer("Запускаю фарм...")
        await self.orchestrator.start_farming_on_all_ready(max_bots=5)
        await callback_query.message.edit_text("✅ Фарм запущен на 5 ботах")
    
    async def cb_stop_farm(self, callback_query: types.CallbackQuery):
        """Callback для кнопки стоп"""
        if not await self._check_access(callback_query.from_user.id):
            await callback_query.answer("Нет доступа")
            return
        
        await callback_query.answer("Останавливаю...")
        # await self.orchestrator.stop_all_farming()
        await callback_query.message.edit_text("⏹️ Фарм остановлен")
    
    async def cb_refresh_stats(self, callback_query: types.CallbackQuery):
        """Callback для обновления статистики"""
        if not await self._check_access(callback_query.from_user.id):
            await callback_query.answer("Нет доступа")
            return
        
        await callback_query.answer("Обновляю...")
        
        stats = await self.orchestrator.get_statistics()
        
        status_text = f"""
📊 **Статус фермы** (обновлено)

• Токенов: `{stats['total_tokens']}`
• Активных: `{stats['active_accounts']}`
• Забанено: `{stats['banned_accounts']}`
• Токенов/час: `{stats['tokens_per_hour']}`
        """
        
        keyboard = types.InlineKeyboardMarkup()
        keyboard.add(types.InlineKeyboardButton("🔄 Обновить", callback_data="refresh"))
        
        await callback_query.message.edit_text(status_text, parse_mode=ParseMode.MARKDOWN, reply_markup=keyboard)
    
    # ============== Уведомления ==============
    
    async def notify_ban(self, login: str, ban_type: str):
        """
        Отправка уведомления о бане
        
        Args:
            login: логин забаненного аккаунта
            ban_type: тип бана
        """
        if not self.allowed_users:
            return
        
        message = f"🚫 **Аккаунт забанен**\nЛогин: `{login}`\nТип: {ban_type}\nВремя: {datetime.now().strftime('%H:%M:%S')}"
        
        for user_id in self.allowed_users:
            try:
                await self.bot.send_message(user_id, message, parse_mode=ParseMode.MARKDOWN)
            except:
                pass
    
    async def notify_token_milestone(self, total_tokens: int):
        """
        Уведомление о достижении milestone по токенам
        
        Args:
            total_tokens: общее количество токенов
        """
        if total_tokens % 100 == 0:  # Каждые 100 токенов
            message = f"🎉 **Milestone достигнут!**\nВсего собрано: {total_tokens} токенов"
            
            for user_id in self.allowed_users:
                try:
                    await self.bot.send_message(user_id, message, parse_mode=ParseMode.MARKDOWN)
                except:
                    pass
    
    # ============== Запуск бота ==============
    
    async def run(self):
        """Запуск бота"""
        if not self.available:
            print("[TelegramBot] Бот недоступен (aiogram не установлен)")
            return
        
        print("[TelegramBot] Запуск...")
        
        try:
            # Запускаем polling
            await self.dp.start_polling()
        except Exception as e:
            print(f"[TelegramBot] Ошибка: {e}")
    
    def stop(self):
        """Остановка бота"""
        if self.available:
            try:
                self.dp.stop_polling()
            except:
                pass