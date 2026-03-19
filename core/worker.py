# core/worker.py
import asyncio
import subprocess
import time
import random
import os
import sqlite3
from datetime import datetime
from typing import Optional, Dict, Any
import json

# Импортируем утилиты
from utils.screenshot import ScreenshotHelper
from utils.ocr_helper import OCRHelper
from utils.proxy_manager import ProxyManager

class Worker:
    """
    Базовый класс воркера (бота)
    Отвечает за запуск Roblox, инжект и базовые операции
    """
    
    def __init__(self, worker_id: int, db_path: str, proxy_manager=None, bypass_method: str = "android_emulation"):
        """
        Инициализация воркера
        
        Args:
            worker_id: уникальный ID воркера
            db_path: путь к базе данных
            proxy_manager: менеджер прокси (опционально)
            bypass_method: метод обхода Byfron
        """
        self.worker_id = worker_id
        self.db_path = db_path
        self.proxy_manager = proxy_manager
        self.bypass_method = bypass_method
        
        # Вспомогательные модули
        self.screenshot = ScreenshotHelper()
        self.ocr = OCRHelper()
        
        # Состояние воркера
        self.current_account = None
        self.current_process = None
        self.is_running = False
        self.injection_status = False
        
        # Статистика
        self.tokens_collected = 0
        self.tasks_completed = 0
        self.errors_count = 0
        
        # Создаем папку для логов воркера
        os.makedirs(f"logs/worker_{worker_id}", exist_ok=True)
        
        print(f"[ВОРКЕР {worker_id}] Инициализирован. Метод: {bypass_method}")
    
    async def classify_account(self, login: str, password: str) -> Dict[str, Any]:
        """
        Классификация аккаунта (проверка наличия Flickaflie)
        
        Args:
            login: логин Roblox
            password: пароль Roblox
            
        Returns:
            Словарь с результатом классификации
        """
        print(f"[ВОРКЕР {self.worker_id}] Классификация аккаунта {login}")
        
        result = {
            'success': False,
            'tier': 'standard',
            'has_flickaflie': False,
            'error': None
        }
        
        try:
            # Запускаем Roblox с аккаунтом
            if not await self.launch_roblox(login, password):
                result['error'] = "Failed to launch Roblox"
                return result
            
            # Ждем загрузку игры
            await asyncio.sleep(15)
            
            # Проверяем, не забанен ли аккаунт
            if await self.check_if_banned():
                result['error'] = "Account banned"
                # Логируем бан
                await self._report_ban(login, "roblox_ban")
                return result
            
            # Проверяем, первый ли это вход
            if await self.is_first_login():
                # Первый вход - выбираем Kaluaka
                print(f"[ВОРКЕР {self.worker_id}] Первый вход на {login}, создаем Kaluaka")
                
                # Используем FirstTimeHandler из strategies
                from strategies.starter_selector import FirstTimeHandler
                handler = FirstTimeHandler(str(self.worker_id), self.screenshot)
                
                if await handler.handle_first_login():
                    # После создания Kaluaka, аккаунт становится standard
                    result['tier'] = 'standard'
                    result['has_flickaflie'] = False
                    result['success'] = True
                else:
                    result['error'] = "Failed to create character"
            else:
                # Не первый вход - проверяем инвентарь
                has_flickaflie = await self.check_inventory_for_flickaflie()
                
                result['has_flickaflie'] = has_flickaflie
                result['tier'] = 'flickaflie' if has_flickaflie else 'standard'
                result['success'] = True
            
            # Закрываем Roblox
            await self.close_roblox()
            
        except Exception as e:
            print(f"[ВОРКЕР {self.worker_id}] Ошибка при классификации: {e}")
            result['error'] = str(e)
            self.errors_count += 1
        
        return result
    
    async def launch_roblox(self, login: str, password: str) -> bool:
        """
        Запуск Roblox с указанным аккаунтом
        
        Args:
            login: логин Roblox
            password: пароль Roblox
            
        Returns:
            True если запуск успешен
        """
        print(f"[ВОРКЕР {self.worker_id}] Запуск Roblox для {login}")
        
        try:
            # Выбираем метод запуска в зависимости от настройки
            if self.bypass_method == "android_emulation":
                return await self._launch_android_emulator(login, password)
            elif self.bypass_method == "fluxus":
                return await self._launch_with_fluxus(login, password)
            elif self.bypass_method == "rmminject":
                return await self._launch_with_rmminject(login, password)
            else:
                # Прямой запуск (не рекомендуется, будет бан)
                return await self._launch_direct(login, password)
                
        except Exception as e:
            print(f"[ВОРКЕР {self.worker_id}] Ошибка запуска Roblox: {e}")
            return False
    
    async def _launch_android_emulator(self, login: str, password: str) -> bool:
        """
        Запуск через Android эмулятор (рекомендуемый метод)
        """
        # Здесь будет интеграция с LDPlayer
        # Пока заглушка для тестирования
        
        # Получаем прокси для этого воркера
        proxy = None
        if self.proxy_manager:
            proxy = self.proxy_manager.get_proxy()
        
        # Имитация запуска
        await asyncio.sleep(5)
        
        # В реальности здесь будут команды для LDPlayer:
        # 1. Запуск эмулятора
        # 2. Открытие Roblox
        # 3. Ввод логина/пароля через ADB
        
        self.current_account = login
        return True
    
    async def _launch_with_fluxus(self, login: str, password: str) -> bool:
        """
        Запуск с использованием Fluxus Executor
        """
        fluxus_path = os.getenv("FLUXUS_PATH", "C:/FluxusExecutor/FluxusBootstrap.exe")
        
        if not os.path.exists(fluxus_path):
            print(f"[ВОРКЕР {self.worker_id}] Fluxus не найден по пути: {fluxus_path}")
            return False
        
        # Запускаем Roblox через браузер
        subprocess.run(f"start roblox://placeID=4329801634", shell=True)
        await asyncio.sleep(10)
        
        # Запускаем Fluxus
        self.current_process = subprocess.Popen(
            [fluxus_path],
            shell=True,
            creationflags=subprocess.CREATE_NO_WINDOW
        )
        
        await asyncio.sleep(3)
        
        # Кликаем Inject (нужна автоматизация)
        # Здесь будет код для клика по кнопке Inject
        
        self.current_account = login
        return True
    
    async def _launch_with_rmminject(self, login: str, password: str) -> bool:
        """
        Запуск с ручным внедрением (RMMInject)
        """
        # Требует скомпилированного инжектора
        # Пока заглушка
        return False
    
    async def _launch_direct(self, login: str, password: str) -> bool:
        """
        Прямой запуск через браузер (небезопасно)
        """
        # Используем Roblox Player с параметрами
        # В реальности нужно использовать куки или авто-логин
        
        # Открываем место Sonaria в браузере
        subprocess.run(f"start https://www.roblox.com/games/4329801634", shell=True)
        await asyncio.sleep(5)
        
        # Нажимаем Play (нужна автоматизация)
        
        self.current_account = login
        return True
    
    async def check_if_banned(self) -> bool:
        """
        Проверка, не забанен ли аккаунт
        
        Returns:
            True если аккаунт забанен
        """
        # Делаем скриншот
        screenshot = self.screenshot.capture()
        
        # Ищем признаки бана:
        # 1. Текст "Your account has been terminated"
        # 2. Текст "Account deleted"
        # 3. Текст "Banned"
        
        # Используем OCR для поиска
        text = self.ocr.extract_text_from_image(screenshot)
        
        ban_phrases = [
            "terminated",
            "deleted",
            "banned",
            "account has been",
            "нарушение правил"
        ]
        
        for phrase in ban_phrases:
            if phrase.lower() in text.lower():
                print(f"[ВОРКЕР {self.worker_id}] Обнаружен бан: {phrase}")
                return True
        
        return False
    
    async def is_first_login(self) -> bool:
        """
        Проверка, первый ли это вход в игру
        
        Returns:
            True если это первый вход
        """
        # Признаки первого входа:
        # 1. Экран выбора существа
        # 2. Отсутствие инвентаря
        # 3. Приветственное сообщение
        
        screenshot = self.screenshot.capture()
        text = self.ocr.extract_text_from_image(screenshot)
        
        first_login_phrases = [
            "choose your creature",
            "select your starter",
            "new player",
            "welcome to",
            "выберите существо"
        ]
        
        for phrase in first_login_phrases:
            if phrase.lower() in text.lower():
                return True
        
        return False
    
    async def check_inventory_for_flickaflie(self) -> bool:
        """
        Проверка инвентаря на наличие Flickaflie
        
        Returns:
            True если Flickaflie есть в инвентаре
        """
        # В реальности: открыть инвентарь, найти иконку Flickaflie
        # или прочитать список существ через память
        
        # Пока заглушка с рандомом для тестирования
        await asyncio.sleep(2)
        
        # Для теста: 30% аккаунтов имеют Flickaflie
        return random.random() < 0.3
    
    async def close_roblox(self):
        """
        Закрытие Roblox
        """
        if self.current_process:
            try:
                self.current_process.terminate()
                await asyncio.sleep(2)
            except:
                pass
        
        # Также убиваем процесс RobloxPlayerBeta.exe
        if os.name == 'nt':  # Windows
            subprocess.run("taskkill /f /im RobloxPlayerBeta.exe", shell=True, capture_output=True)
        
        self.current_account = None
        self.injection_status = False
    
    async def inject_script(self, script_content: str) -> bool:
        """
        Внедрение Lua скрипта в процесс Roblox
        
        Args:
            script_content: Lua скрипт для выполнения
            
        Returns:
            True если инжект успешен
        """
        print(f"[ВОРКЕР {self.worker_id}] Инжект скрипта...")
        
        if self.bypass_method == "android_emulation":
            # Для Android: через ADB и Fluxus APK
            return await self._inject_android(script_content)
        elif self.bypass_method == "fluxus":
            # Для Fluxus: через буфер обмена и хоткеи
            return await self._inject_fluxus(script_content)
        else:
            return False
    
    async def _inject_android(self, script_content: str) -> bool:
        """
        Инжект в Android эмулятор
        """
        # Сохраняем скрипт во временный файл
        script_file = f"logs/worker_{self.worker_id}/script_{int(time.time())}.lua"
        with open(script_file, "w", encoding="utf-8") as f:
            f.write(script_content)
        
        # Здесь будут ADB команды для копирования и запуска
        await asyncio.sleep(1)
        
        return True
    
    async def _inject_fluxus(self, script_content: str) -> bool:
        """
        Инжект через Fluxus на Windows
        """
        import pyperclip
        import pyautogui
        
        # Копируем скрипт в буфер обмена
        pyperclip.copy(script_content)
        await asyncio.sleep(0.5)
        
        # Активируем окно Fluxus (нужно найти)
        # Вставляем скрипт
        pyautogui.hotkey('ctrl', 'a')
        pyautogui.hotkey('ctrl', 'v')
        await asyncio.sleep(0.5)
        
        # Нажимаем Execute
        pyautogui.press('f6')
        
        return True
    
    async def get_death_points(self) -> int:
        """
        Получение текущего количества Death Points с экрана
        
        Returns:
            Текущее значение DP или 0 если не удалось прочитать
        """
        # Делаем скриншот области с DP
        screenshot = self.screenshot.capture()
        
        # Вырезаем область где обычно отображаются DP
        # Координаты из .env
        x = int(os.getenv("OCR_REGION_X", "1700"))
        y = int(os.getenv("OCR_REGION_Y", "50"))
        w = int(os.getenv("OCR_REGION_W", "100"))
        h = int(os.getenv("OCR_REGION_H", "30"))
        
        # Вырезаем регион
        dp_region = screenshot.crop((x, y, x + w, y + h))
        
        # Сохраняем для отладки если нужно
        if os.getenv("SAVE_DEBUG_SCREENSHOTS", "false").lower() == "true":
            debug_path = f"logs/screenshots/worker_{self.worker_id}_dp_{int(time.time())}.png"
            dp_region.save(debug_path)
        
        # Читаем текст с помощью OCR
        text = self.ocr.extract_text_from_image(dp_region)
        
        # Извлекаем числа из текста
        import re
        numbers = re.findall(r'\d+', text)
        
        if numbers:
            return int(numbers[0])
        
        return 0
    
    async def suicide_creature(self):
        """
        Самоубийство существа для получения токена
        """
        # Разные способы самоубийства для рандомизации
        methods = [
            self._suicide_jump,
            self._suicide_water,
            self._suicide_attract_predator
        ]
        
        method = random.choice(methods)
        await method()
    
    async def _suicide_jump(self):
        """
        Прыжок с обрыва
        """
        # Нажимаем W + пробел для прыжка вперед
        import pyautogui
        
        pyautogui.keyDown('w')
        pyautogui.keyDown('space')
        await asyncio.sleep(random.uniform(2, 4))
        pyautogui.keyUp('w')
        pyautogui.keyUp('space')
    
    async def _suicide_water(self):
        """
        Утопление в воде
        """
        # Двигаемся к воде
        import pyautogui
        
        pyautogui.keyDown('w')
        await asyncio.sleep(random.uniform(5, 8))
        pyautogui.keyUp('w')
    
    async def _suicide_attract_predator(self):
        """
        Привлечение хищника
        """
        # Используем специальную атаку для привлечения внимания
        import pyautogui
        
        for _ in range(5):
            pyautogui.rightClick()
            await asyncio.sleep(0.5)
    
    async def _report_ban(self, login: str, ban_type: str):
        """
        Отчет о бане в БД
        """
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        
        c.execute('''
            INSERT INTO bans (account_login, ban_time, ban_type, worker_id)
            VALUES (?, ?, ?, ?)
        ''', (login, datetime.now(), ban_type, self.worker_id))
        
        c.execute('''
            UPDATE accounts SET status = 'banned', ban_count = ban_count + 1
            WHERE login = ?
        ''', (login,))
        
        conn.commit()
        conn.close()
    
    async def stop(self):
        """
        Остановка воркера
        """
        self.is_running = False
        await self.close_roblox()
        print(f"[ВОРКЕР {self.worker_id}] Остановлен")
    
    def get_stats(self) -> dict:
        """
        Получение статистики воркера
        """
        return {
            'worker_id': self.worker_id,
            'current_account': self.current_account,
            'tokens_collected': self.tokens_collected,
            'tasks_completed': self.tasks_completed,
            'errors_count': self.errors_count,
            'is_running': self.is_running
        }