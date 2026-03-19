# main.py
import asyncio
import os
import sys
import signal
from datetime import datetime
from dotenv import load_dotenv

# Загружаем переменные окружения
load_dotenv()

# Импортируем наши модули
from core.orchestrator import SonariaFarmOrchestrator
from core.anti_detection import AntiDetection
from utils.proxy_manager import ProxyManager

# Telegram бот (опционально)
try:
    from telegram_bot.bot import FarmTelegramBot
    TELEGRAM_AVAILABLE = True
except ImportError:
    TELEGRAM_AVAILABLE = False
    print("[Main] Telegram бот не будет доступен (aiogram не установлен)")

class FarmApplication:
    """
    Главный класс приложения
    Запускает и управляет всей фермой
    """
    
    def __init__(self):
        self.orchestrator = None
        self.telegram_bot = None
        self.tasks = []
        self.running = True
        
        # Настройка обработчиков сигналов
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        print("""
╔══════════════════════════════════════════╗
║     SONARIA FARM BOT - ФЕРМА ТОКЕНОВ    ║
║         Версия 1.0 - 2026               ║
╚══════════════════════════════════════════╝
        """)
    
    def signal_handler(self, sig, frame):
        """Обработка сигналов остановки"""
        print("\n[Main] Получен сигнал остановки...")
        self.running = False
    
    async def startup(self):
        """Запуск всех компонентов системы"""
        print("[Main] Запуск фермы...")
        
        # Проверяем наличие необходимых папок
        os.makedirs("data", exist_ok=True)
        os.makedirs("logs", exist_ok=True)
        os.makedirs("logs/screenshots", exist_ok=True)
        
        # Загружаем конфигурацию
        worker_count = int(os.getenv("WORKER_COUNT", "5"))
        db_path = os.getenv("DB_PATH", "data/farm.db")
        proxy_file = os.getenv("PROXY_FILE", "data/proxies.txt")
        
        # Проверяем наличие прокси
        if not os.path.exists(proxy_file):
            print(f"[Main] Файл прокси {proxy_file} не найден. Создаю пустой файл.")
            with open(proxy_file, 'w') as f:
                f.write("# Добавьте прокси в формате ip:port\n")
        
        # Создаем оркестратор
        print(f"[Main] Инициализация оркестратора...")
        self.orchestrator = SonariaFarmOrchestrator(
            db_path=db_path,
            proxy_file=proxy_file if os.path.exists(proxy_file) else None
        )
        
        # Проверяем наличие аккаунтов
        accounts_file = "data/accounts.txt"
        if os.path.exists(accounts_file):
            print(f"[Main] Найден файл с аккаунтами, загружаю...")
            count = await self.orchestrator.load_accounts_from_file(accounts_file)
            print(f"[Main] Загружено {count} аккаунтов")
        else:
            print(f"[Main] Файл {accounts_file} не найден. Создайте его с аккаунтами.")
            with open(accounts_file, 'w') as f:
                f.write("# Добавьте аккаунты в формате login:password\n")
        
        # Запускаем воркеров
        print(f"[Main] Запуск {worker_count} воркеров...")
        for i in range(worker_count):
            task = asyncio.create_task(self.orchestrator.worker_loop(i))
            self.tasks.append(task)
        
        print(f"[Main] Запущено {len(self.tasks)} воркеров")
        
        # Запускаем Telegram бота если есть токен
        telegram_token = os.getenv("TELEGRAM_BOT_TOKEN")
        if telegram_token and TELEGRAM_AVAILABLE:
            print("[Main] Запуск Telegram бота...")
            
            # Разрешенные пользователи (можно указать в .env)
            allowed_users = []
            allowed_users_str = os.getenv("TELEGRAM_ALLOWED_USERS", "")
            if allowed_users_str:
                allowed_users = [int(x.strip()) for x in allowed_users_str.split(',')]
            
            self.telegram_bot = FarmTelegramBot(
                token=telegram_token,
                orchestrator=self.orchestrator,
                allowed_users=allowed_users
            )
            
            # Запускаем бота в отдельной задаче
            bot_task = asyncio.create_task(self.telegram_bot.run())
            self.tasks.append(bot_task)
            
            print("[Main] Telegram бот запущен")
        else:
            if not telegram_token:
                print("[Main] TELEGRAM_BOT_TOKEN не задан в .env")
            if not TELEGRAM_AVAILABLE:
                print("[Main] aiogram не установлен: pip install aiogram==2.25.1")
        
        # Автоматический старт фарма если настроено
        if os.getenv("AUTO_START_FARM", "false").lower() == "true":
            auto_bots = int(os.getenv("AUTO_START_BOTS", "3"))
            print(f"[Main] Автоматический запуск {auto_bots} ботов...")
            await self.orchestrator.start_farming_on_all_ready(max_bots=auto_bots)
    
    async def status_reporter(self):
        """
        Периодический вывод статуса в консоль
        """
        while self.running:
            await asyncio.sleep(60)  # Каждую минуту
            
            try:
                stats = await self.orchestrator.get_statistics()
                
                # Очищаем экран
                os.system('cls' if os.name == 'nt' else 'clear')
                
                # Выводим статус
                print(f"""
╔══════════════════════════════════════════════════════════╗
║  SONARIA FARM - СТАТУС [ {datetime.now().strftime('%H:%M:%S')} ]              ║
╠══════════════════════════════════════════════════════════╣
║  Токенов:          {stats['total_tokens']:>10}                           ║
║  За 24ч:           {stats['tokens_last_24h']:>10}                           ║
║  Токенов/час:      {stats['tokens_per_hour']:>10}                           ║
║  Прибыль:          ${stats['estimated_value_usd']:>9}                           ║
╠══════════════════════════════════════════════════════════╣
║  Аккаунты:                                             ║
║    • Всего:        {stats['total_accounts']:>10}                           ║
║    • Активных:     {stats['active_accounts']:>10}                           ║
║    • В работе:     {stats['farming_now']:>10}                           ║
║    • Ожидает:      {stats['pending_accounts']:>10}                           ║
║    • Забанено:     {stats['banned_accounts']:>10}                           ║
║    • С Flickaflie: {stats['flickaflie_accounts']:>10}                           ║
╠══════════════════════════════════════════════════════════╣
║  Система:                                               ║
║    • Воркеров:     {stats['active_workers']:>10}                           ║
║    • Очередь:      {stats['queue_size']:>10}                           ║
║    • Uptime:       {stats['uptime_hours']:>10.1f} ч                          ║
╚══════════════════════════════════════════════════════════╝
                """)
                
                # Проверяем milestone для уведомления
                if self.telegram_bot and stats['total_tokens'] % 100 == 0:
                    await self.telegram_bot.notify_token_milestone(stats['total_tokens'])
                    
            except Exception as e:
                print(f"[Main] Ошибка в статус репортере: {e}")
    
    async def shutdown(self):
        """Корректное завершение работы"""
        print("\n[Main] Завершение работы...")
        
        # Останавливаем оркестратор
        if self.orchestrator:
            await self.orchestrator.shutdown()
        
        # Останавливаем Telegram бота
        if self.telegram_bot:
            self.telegram_bot.stop()
        
        # Отменяем все задачи
        for task in self.tasks:
            task.cancel()
        
        # Ждем завершения задач
        if self.tasks:
            await asyncio.gather(*self.tasks, return_exceptions=True)
        
        print("[Main] Ферма остановлена")
    
    async def run(self):
        """Главный цикл приложения"""
        try:
            # Запускаем все компоненты
            await self.startup()
            
            # Запускаем статус репортер
            reporter_task = asyncio.create_task(self.status_reporter())
            self.tasks.append(reporter_task)
            
            print("[Main] Ферма успешно запущена!")
            print("[Main] Нажмите Ctrl+C для остановки")
            
            # Держим приложение запущенным
            while self.running:
                await asyncio.sleep(1)
            
        except KeyboardInterrupt:
            print("\n[Main] Получен сигнал остановки")
        except Exception as e:
            print(f"[Main] Критическая ошибка: {e}")
            import traceback
            traceback.print_exc()
        finally:
            await self.shutdown()

def main():
    """Точка входа"""
    # Создаем и запускаем приложение
    app = FarmApplication()
    
    # Запускаем асинхронный цикл
    try:
        asyncio.run(app.run())
    except KeyboardInterrupt:
        print("\n[Main] Программа остановлена пользователем")
    except Exception as e:
        print(f"[Main] Необработанная ошибка: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()