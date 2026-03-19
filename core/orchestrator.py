# core/orchestrator.py
import asyncio
import sqlite3
import json
import os
import random
import time
from datetime import datetime
from typing import List, Dict, Optional, Tuple
from pathlib import Path

# Загружаем переменные окружения
from dotenv import load_dotenv
load_dotenv()

# Импортируем наши модули
from core.worker import Worker
from core.account_classifier import AccountClassifier
from core.anti_detection import AntiDetection

# Импортируем стратегии
from strategies.flickaflie_farm import FlickaflieFarmer
from strategies.kaluaka_farm import KaluakaFarmer
from strategies.first_time_setup import FirstTimeSetup
from strategies.starter_selector import FirstTimeHandler

# Импортируем утилиты
from utils.screenshot import ScreenshotHelper
from utils.proxy_manager import ProxyManager
from utils.ocr_helper import OCRHelper
from utils.name_generator import NameGenerator

class SonariaFarmOrchestrator:
    """
    ГЛАВНЫЙ ОРКЕСТРАТОР ФЕРМЫ
    Управляет всеми ботами, задачами и аккаунтами
    """
    
    def __init__(self, db_path: str = "data/farm.db", proxy_file: str = None):
        """
        Инициализация оркестратора
        
        Args:
            db_path: путь к файлу базы данных SQLite
            proxy_file: путь к файлу с прокси (опционально)
        """
        # Пути к файлам
        self.db_path = db_path
        self.proxy_file = proxy_file
        
        # Создаем необходимые папки
        os.makedirs("data", exist_ok=True)
        os.makedirs("logs", exist_ok=True)
        os.makedirs("logs/screenshots", exist_ok=True)
        
        # Очередь задач (асинхронная)
        self.task_queue = asyncio.Queue()
        
        # Словарь активных воркеров
        # {worker_id: worker_object}
        self.active_workers = {}
        
        # Статистика
        self.total_tokens_collected = 0
        self.banned_accounts_count = 0
        self.start_time = datetime.now()
        
        # Инициализируем вспомогательные модули
        self.screenshot_helper = ScreenshotHelper()
        self.proxy_manager = ProxyManager(proxy_file) if proxy_file else None
        self.ocr_helper = OCRHelper()
        self.name_generator = NameGenerator()
        self.anti_detection = AntiDetection()
        
        # Классификатор аккаунтов
        self.classifier = AccountClassifier()
        
        # Загружаем настройки из .env
        self.bypass_method = os.getenv("BYPASS_METHOD", "android_emulation")
        self.use_proxy = os.getenv("USE_PROXY", "false").lower() == "true"
        self.auto_start_farm = os.getenv("AUTO_START_FARM", "false").lower() == "true"
        self.max_tokens_per_session = int(os.getenv("MAX_TOKENS_PER_SESSION", "50"))
        
        # Инициализируем базу данных
        self.init_database()
        
        print(f"[ОРКЕСТРАТОР] Инициализирован. БД: {db_path}")
        print(f"[ОРКЕСТРАТОР] Метод обхода Byfron: {self.bypass_method}")
        print(f"[ОРКЕСТРАТОР] Использование прокси: {self.use_proxy}")
    
    def init_database(self):
        """
        Создание всех таблиц в базе данных SQLite
        Вызывается один раз при запуске
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        
        # Таблица аккаунтов
        c.execute('''
            CREATE TABLE IF NOT EXISTS accounts (
                login TEXT PRIMARY KEY,
                password TEXT,
                tier TEXT DEFAULT 'new',
                has_flickaflie BOOLEAN DEFAULT 0,
                death_tokens INTEGER DEFAULT 0,
                status TEXT DEFAULT 'pending',
                last_active TIMESTAMP,
                ban_count INTEGER DEFAULT 0,
                proxy TEXT,
                worker_id TEXT,
                notes TEXT
            )
        ''')
        
        # Таблица для задач
        c.execute('''
            CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_login TEXT,
                task_type TEXT,
                status TEXT,
                created_at TIMESTAMP,
                started_at TIMESTAMP,
                completed_at TIMESTAMP,
                result TEXT,
                worker_id TEXT,
                error TEXT,
                FOREIGN KEY(account_login) REFERENCES accounts(login)
            )
        ''')
        
        # Таблица статистики токенов
        c.execute('''
            CREATE TABLE IF NOT EXISTS token_stats (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_login TEXT,
                tokens_collected INTEGER,
                timestamp TIMESTAMP,
                session_duration INTEGER,
                worker_id INTEGER,
                FOREIGN KEY(account_login) REFERENCES accounts(login)
            )
        ''')
        
        # Таблица банов
        c.execute('''
            CREATE TABLE IF NOT EXISTS bans (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_login TEXT,
                ban_time TIMESTAMP,
                ban_type TEXT,
                worker_id INTEGER,
                FOREIGN KEY(account_login) REFERENCES accounts(login)
            )
        ''')
        
        # Таблица сессий
        c.execute('''
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_login TEXT,
                start_time TIMESTAMP,
                end_time TIMESTAMP,
                tokens_earned INTEGER,
                creature_used TEXT,
                worker_id INTEGER,
                FOREIGN KEY(account_login) REFERENCES accounts(login)
            )
        ''')
        
        conn.commit()
        conn.close()
        
        print("[ОРКЕСТРАТОР] База данных инициализирована")
    
    async def load_accounts_from_file(self, filepath: str):
        """
        Загрузка аккаунтов из текстового файла
        
        Формат файла: каждая строка "логин:пароль"
        Пример: "user123:pass123"
        
        Args:
            filepath: путь к файлу с аккаунтами
        """
        if not os.path.exists(filepath):
            print(f"[ОРКЕСТРАТОР] Файл {filepath} не найден")
            return 0
        
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        
        loaded_count = 0
        for line in lines:
            line = line.strip()
            if not line or ':' not in line:
                continue
                
            try:
                login, password = line.split(':', 1)
                
                # Вставляем или игнорируем, если уже есть
                c.execute('''
                    INSERT OR IGNORE INTO accounts 
                    (login, password, tier, status, death_tokens, ban_count)
                    VALUES (?, ?, 'new', 'pending', 0, 0)
                ''', (login.strip(), password.strip()))
                
                if c.rowcount > 0:
                    loaded_count += 1
            except Exception as e:
                print(f"[ОРКЕСТРАТОР] Ошибка при загрузке строки {line}: {e}")
                continue
        
        conn.commit()
        conn.close()
        
        print(f"[ОРКЕСТРАТОР] Загружено {loaded_count} новых аккаунтов из {filepath}")
        return loaded_count
    
    async def classify_all_accounts(self):
        """
        Запуск классификации всех новых аккаунтов
        Проверяет, есть ли на аккаунте Flickaflie
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        
        # Берем аккаунты со статусом 'pending' или 'new'
        c.execute("SELECT login, password FROM accounts WHERE status IN ('pending', 'new')")
        accounts_to_classify = c.fetchall()
        conn.close()
        
        if not accounts_to_classify:
            print("[ОРКЕСТРАТОР] Нет аккаунтов для классификации")
            return
        
        print(f"[ОРКЕСТРАТОР] Добавлено {len(accounts_to_classify)} аккаунтов в очередь на классификацию")
        
        for login, password in accounts_to_classify:
            await self.task_queue.put({
                'type': 'classify_account',
                'login': login,
                'password': password,
                'created_at': datetime.now().isoformat()
            })
    
    async def start_farming_on_all_ready(self, max_bots: int = 10):
        """
        Запуск фарма на всех готовых аккаунтах
        
        Args:
            max_bots: максимальное количество ботов для запуска
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        
        # Берем аккаунты со статусом 'ready' или 'classified'
        c.execute('''
            SELECT login, password, tier, has_flickaflie 
            FROM accounts 
            WHERE status IN ('ready', 'classified') 
            LIMIT ?
        ''', (max_bots,))
        
        ready_accounts = c.fetchall()
        conn.close()
        
        if not ready_accounts:
            print("[ОРКЕСТРАТОР] Нет готовых аккаунтов для фарма")
            return
        
        print(f"[ОРКЕСТРАТОР] Запускаю фарм на {len(ready_accounts)} аккаунтах")
        
        for login, password, tier, has_flickaflie in ready_accounts:
            await self.task_queue.put({
                'type': 'farm_tokens',
                'login': login,
                'password': password,
                'tier': tier,
                'has_flickaflie': bool(has_flickaflie),
                'created_at': datetime.now().isoformat()
            })
    
    async def worker_loop(self, worker_id: int):
        """
        Основной цикл воркера (бота)
        Запускается в отдельной асинхронной задаче для каждого воркера
        
        Args:
            worker_id: уникальный идентификатор воркера
        """
        print(f"[ВОРКЕР {worker_id}] Запущен")
        
        # Создаем объект воркера
        worker = Worker(
            worker_id=worker_id,
            db_path=self.db_path,
            proxy_manager=self.proxy_manager if self.use_proxy else None,
            bypass_method=self.bypass_method
        )
        
        # Сохраняем воркера в словаре активных
        self.active_workers[worker_id] = worker
        
        # Основной цикл обработки задач
        while True:
            try:
                # Получаем задачу из очереди (ждем, если очередь пуста)
                task = await self.task_queue.get()
                
                print(f"[ВОРКЕР {worker_id}] Получена задача: {task['type']} для {task.get('login', 'unknown')}")
                
                # Обновляем статус в БД
                self._update_account_status(task.get('login'), 'working', worker_id)
                
                # Обрабатываем задачу в зависимости от типа
                if task['type'] == 'classify_account':
                    await self._handle_classify_task(worker, task)
                
                elif task['type'] == 'farm_tokens':
                    await self._handle_farm_task(worker, task)
                
                elif task['type'] == 'check_inventory':
                    await self._handle_inventory_task(worker, task)
                
                elif task['type'] == 'transfer_tokens':
                    await self._handle_transfer_task(worker, task)
                
                else:
                    print(f"[ВОРКЕР {worker_id}] Неизвестный тип задачи: {task['type']}")
                
                # Помечаем задачу как выполненную в очереди
                self.task_queue.task_done()
                
                # Случайная задержка между задачами (анти-паттерн)
                await asyncio.sleep(random.uniform(1, 3))
                
            except asyncio.CancelledError:
                print(f"[ВОРКЕР {worker_id}] Получен сигнал остановки")
                break
            except Exception as e:
                print(f"[ВОРКЕР {worker_id}] Ошибка в цикле: {e}")
                await asyncio.sleep(5)
        
        print(f"[ВОРКЕР {worker_id}] Остановлен")
    
    async def _handle_classify_task(self, worker, task):
        """
        Обработка задачи классификации аккаунта
        Проверяет, есть ли Flickaflie в инвентаре
        """
        login = task['login']
        password = task['password']
        
        # Обновляем статус в БД
        self._update_account_status(login, 'classifying', worker.worker_id)
        
        # Создаем запись о задаче
        task_id = self._create_task_record(login, 'classify')
        
        try:
            # Запускаем Roblox и проверяем инвентарь
            result = await worker.classify_account(login, password)
            
            if result['success']:
                # Обновляем информацию в БД
                conn = sqlite3.connect(self.db_path)
                c = conn.cursor()
                c.execute('''
                    UPDATE accounts 
                    SET tier = ?, has_flickaflie = ?, status = 'ready'
                    WHERE login = ?
                ''', (result['tier'], 1 if result['has_flickaflie'] else 0, login))
                conn.commit()
                conn.close()
                
                # Обновляем запись задачи
                self._complete_task(task_id, {'result': 'classified', 'tier': result['tier']})
                
                print(f"[ВОРКЕР {worker.worker_id}] Аккаунт {login} классифицирован как {result['tier']}")
            else:
                # Ошибка классификации
                self._fail_task(task_id, result.get('error', 'Unknown error'))
                print(f"[ВОРКЕР {worker.worker_id}] Ошибка классификации {login}: {result.get('error')}")
        
        except Exception as e:
            self._fail_task(task_id, str(e))
            print(f"[ВОРКЕР {worker.worker_id}] Исключение при классификации {login}: {e}")
    
    async def _handle_farm_task(self, worker, task):
        """
        Обработка задачи фарма токенов
        """
        login = task['login']
        password = task['password']
        tier = task.get('tier', 'standard')
        has_flickaflie = task.get('has_flickaflie', False)
        
        # Обновляем статус
        self._update_account_status(login, 'farming', worker.worker_id)
        
        # Создаем запись о задаче
        task_id = self._create_task_record(login, 'farm')
        
        # Создаем запись о сессии
        session_id = self._start_session(login, worker.worker_id)
        
        tokens_earned = 0
        start_time = time.time()
        
        try:
            # Выбираем стратегию в зависимости от наличия Flickaflie
            if has_flickaflie:
                # Фарм с Flickaflie (оптимальный)
                farmer = FlickaflieFarmer(worker, login, password)
                print(f"[ВОРКЕР {worker.worker_id}] Запуск Flickaflie фарма на {login}")
            else:
                # Фарм с Kaluaka или другим существом
                farmer = KaluakaFarmer(worker, login, password)
                print(f"[ВОРКЕР {worker.worker_id}] Запуск стандартного фарма на {login}")
            
            # Запускаем фарм
            farm_result = await farmer.farm(
                max_tokens=self.max_tokens_per_session,
                on_token_callback=lambda: self._on_token_collected(login, worker.worker_id)
            )
            
            tokens_earned = farm_result.get('tokens', 0)
            
            # Обновляем статистику
            self.total_tokens_collected += tokens_earned
            
            # Обновляем БД
            conn = sqlite3.connect(self.db_path)
            c = conn.cursor()
            c.execute('''
                UPDATE accounts 
                SET death_tokens = death_tokens + ?, last_active = ?, status = 'ready'
                WHERE login = ?
            ''', (tokens_earned, datetime.now(), login))
            conn.commit()
            conn.close()
            
            # Завершаем сессию
            session_duration = int(time.time() - start_time)
            self._end_session(session_id, tokens_earned, session_duration)
            
            # Завершаем задачу
            self._complete_task(task_id, {
                'tokens': tokens_earned,
                'duration': session_duration,
                'creature': 'flickaflie' if has_flickaflie else 'kaluaka'
            })
            
            print(f"[ВОРКЕР {worker.worker_id}] Фарм на {login} завершен. Получено {tokens_earned} токенов")
            
        except Exception as e:
            self._fail_task(task_id, str(e))
            print(f"[ВОРКЕР {worker.worker_id}] Ошибка фарма на {login}: {e}")
            
            # Проверяем, не бан ли это
            if 'banned' in str(e).lower() or 'terminated' in str(e).lower():
                await self._handle_ban(login, worker.worker_id, 'roblox_ban')
    
    async def _handle_ban(self, login: str, worker_id: int, ban_type: str):
        """
        Обработка бана аккаунта
        
        Args:
            login: логин забаненного аккаунта
            worker_id: ID воркера
            ban_type: тип бана ('roblox_ban' или 'sonaria_ban')
        """
        print(f"[ВОРКЕР {worker_id}] АККАУНТ {login} ЗАБАНЕН! Тип: {ban_type}")
        
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        
        # Увеличиваем счетчик банов и меняем статус
        c.execute('''
            UPDATE accounts 
            SET status = 'banned', ban_count = ban_count + 1
            WHERE login = ?
        ''', (login,))
        
        # Добавляем запись о бане
        c.execute('''
            INSERT INTO bans (account_login, ban_time, ban_type, worker_id)
            VALUES (?, ?, ?, ?)
        ''', (login, datetime.now(), ban_type, worker_id))
        
        conn.commit()
        conn.close()
        
        self.banned_accounts_count += 1
        
        # Если настроено авто-удаление, можно удалить аккаунт
        if os.getenv("AUTO_REMOVE_BANNED", "true").lower() == "true":
            await self._remove_banned_account(login)
    
    async def _remove_banned_account(self, login: str):
        """
        Полное удаление забаненного аккаунта из БД
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        
        # Сохраняем статистику перед удалением
        c.execute("SELECT death_tokens FROM accounts WHERE login = ?", (login,))
        result = c.fetchone()
        tokens_lost = result[0] if result else 0
        
        # Удаляем аккаунт
        c.execute("DELETE FROM accounts WHERE login = ?", (login,))
        
        conn.commit()
        conn.close()
        
        print(f"[ОРКЕСТРАТОР] Аккаунт {login} удален из БД. Потеряно токенов: {tokens_lost}")
    
    def _on_token_collected(self, login: str, worker_id: int):
        """
        Callback при получении каждого токена
        """
        # Можно добавить логику для real-time обновлений
        pass
    
    def _update_account_status(self, login: str, status: str, worker_id: int):
        """
        Обновление статуса аккаунта в БД
        """
        if not login:
            return
            
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute('''
            UPDATE accounts 
            SET status = ?, worker_id = ?, last_active = ?
            WHERE login = ?
        ''', (status, worker_id, datetime.now(), login))
        conn.commit()
        conn.close()
    
    def _create_task_record(self, login: str, task_type: str) -> int:
        """
        Создание записи о задаче в БД
        
        Returns:
            ID созданной задачи
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute('''
            INSERT INTO tasks (account_login, task_type, status, created_at)
            VALUES (?, ?, 'running', ?)
        ''', (login, task_type, datetime.now()))
        task_id = c.lastrowid
        conn.commit()
        conn.close()
        return task_id
    
    def _complete_task(self, task_id: int, result: dict):
        """
        Отметить задачу как выполненную
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute('''
            UPDATE tasks 
            SET status = 'completed', completed_at = ?, result = ?
            WHERE id = ?
        ''', (datetime.now(), json.dumps(result, ensure_ascii=False), task_id))
        conn.commit()
        conn.close()
    
    def _fail_task(self, task_id: int, error: str):
        """
        Отметить задачу как проваленную
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute('''
            UPDATE tasks 
            SET status = 'failed', completed_at = ?, error = ?
            WHERE id = ?
        ''', (datetime.now(), error, task_id))
        conn.commit()
        conn.close()
    
    def _start_session(self, login: str, worker_id: int) -> int:
        """
        Начало сессии фарма
        
        Returns:
            ID сессии
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute('''
            INSERT INTO sessions (account_login, start_time, worker_id, tokens_earned)
            VALUES (?, ?, ?, 0)
        ''', (login, datetime.now(), worker_id))
        session_id = c.lastrowid
        conn.commit()
        conn.close()
        return session_id
    
    def _end_session(self, session_id: int, tokens_earned: int, duration: int):
        """
        Завершение сессии фарма
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute('''
            UPDATE sessions 
            SET end_time = ?, tokens_earned = ?
            WHERE id = ?
        ''', (datetime.now(), tokens_earned, session_id))
        conn.commit()
        conn.close()
        
        # Добавляем в статистику токенов
        c.execute('''
            INSERT INTO token_stats (account_login, tokens_collected, timestamp, session_duration)
            VALUES (?, ?, ?, ?)
        ''', (login, tokens_earned, datetime.now(), duration))
        conn.commit()
        conn.close()
    
    async def get_statistics(self) -> dict:
        """
        Получение полной статистики фермы
        
        Returns:
            Словарь со статистикой
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        
        # Общее количество токенов
        c.execute("SELECT SUM(death_tokens) FROM accounts")
        total_tokens = c.fetchone()[0] or 0
        
        # Количество аккаунтов по статусам
        c.execute("SELECT status, COUNT(*) FROM accounts GROUP BY status")
        status_counts = dict(c.fetchall())
        
        # Аккаунты с Flickaflie
        c.execute("SELECT COUNT(*) FROM accounts WHERE has_flickaflie = 1")
        flickaflie_count = c.fetchone()[0]
        
        # Количество банов
        c.execute("SELECT COUNT(*) FROM bans")
        total_bans = c.fetchone()[0]
        
        # Статистика за последние 24 часа
        c.execute('''
            SELECT SUM(tokens_collected) 
            FROM token_stats 
            WHERE timestamp > datetime('now', '-1 day')
        ''')
        tokens_24h = c.fetchone()[0] or 0
        
        # Среднее время сессии
        c.execute('''
            SELECT AVG(session_duration) 
            FROM token_stats 
            WHERE session_duration > 0
        ''')
        avg_session_duration = c.fetchone()[0] or 0
        
        conn.close()
        
        # Время работы фермы
        uptime = datetime.now() - self.start_time
        uptime_hours = uptime.total_seconds() / 3600
        
        # Оценка эффективности
        tokens_per_hour = total_tokens / uptime_hours if uptime_hours > 0 else 0
        
        return {
            'total_tokens': total_tokens,
            'tokens_last_24h': tokens_24h,
            'total_accounts': sum(status_counts.values()),
            'active_accounts': status_counts.get('ready', 0) + status_counts.get('farming', 0),
            'farming_now': status_counts.get('farming', 0),
            'pending_accounts': status_counts.get('pending', 0) + status_counts.get('new', 0),
            'banned_accounts': status_counts.get('banned', 0),
            'flickaflie_accounts': flickaflie_count,
            'total_bans_ever': total_bans,
            'avg_session_duration_min': round(avg_session_duration / 60, 1),
            'uptime_hours': round(uptime_hours, 1),
            'tokens_per_hour': round(tokens_per_hour, 1),
            'queue_size': self.task_queue.qsize(),
            'active_workers': len(self.active_workers),
            'estimated_value_usd': round(total_tokens * 0.05, 2),  # Если токен стоит $0.05
        }
    
    async def shutdown(self):
        """
        Корректное завершение работы фермы
        """
        print("[ОРКЕСТРАТОР] Завершение работы...")
        
        # Отменяем все задачи воркеров
        for worker_id, worker in self.active_workers.items():
            await worker.stop()
        
        # Ждем завершения всех задач в очереди
        if self.task_queue.qsize() > 0:
            print(f"[ОРКЕСТРАТОР] Ожидание завершения {self.task_queue.qsize()} задач...")
            await self.task_queue.join()
        
        print("[ОРКЕСТРАТОР] Ферма остановлена")
    
    def add_task(self, task: dict):
        """
        Добавление задачи в очередь (синхронная обертка)
        """
        asyncio.create_task(self.task_queue.put(task))