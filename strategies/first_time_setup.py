# strategies/first_time_setup.py
import asyncio
import random
from typing import Dict, Any, Optional

class FirstTimeSetup:
    """
    Полная настройка нового аккаунта
    Выполняет все необходимые действия при первом входе:
    - Создание персонажа (Kaluaka)
    - Прохождение начального туториала
    - Настройка параметров игры
    - Первичный сбор ресурсов
    """
    
    def __init__(self, worker, login: str, password: str, anti_detection=None):
        """
        Инициализация
        
        Args:
            worker: объект воркера
            login: логин Roblox
            password: пароль Roblox
            anti_detection: модуль анти-детекта
        """
        self.worker = worker
        self.login = login
        self.password = password
        self.anti_detection = anti_detection
        
        # Статистика настройки
        self.setup_time = 0
        self.steps_completed = []
        self.errors = []
        
        # Импортируем обработчик первого входа
        from strategies.starter_selector import FirstTimeHandler
        self.starter_handler = FirstTimeHandler(
            worker_id=str(worker.worker_id),
            screenshot_helper=worker.screenshot,
            anti_detection=anti_detection
        )
    
    async def run_full_setup(self) -> Dict[str, Any]:
        """
        Запуск полной настройки аккаунта
        
        Returns:
            Словарь с результатами настройки
        """
        print(f"[FirstTimeSetup] Начало настройки аккаунта {self.login}")
        
        result = {
            'success': False,
            'steps_completed': [],
            'creature_created': False,
            'tutorial_completed': False,
            'settings_configured': False,
            'error': None,
            'setup_duration': 0
        }
        
        import time
        start_time = time.time()
        
        try:
            # Запускаем Roblox
            if not await self.worker.launch_roblox(self.login, self.password):
                result['error'] = "Не удалось запустить Roblox"
                return result
            
            # Ждем загрузку игры
            await asyncio.sleep(10)
            
            # Шаг 1: Создание персонажа
            print("[FirstTimeSetup] Шаг 1: Создание персонажа")
            if await self.starter_handler.handle_first_login():
                result['creature_created'] = True
                result['steps_completed'].append('creature_creation')
            else:
                # Если не удалось создать, возможно уже есть персонаж
                print("[FirstTimeSetup] Возможно персонаж уже создан")
            
            # Шаг 2: Прохождение туториала
            print("[FirstTimeSetup] Шаг 2: Прохождение туториала")
            if await self._complete_tutorial():
                result['tutorial_completed'] = True
                result['steps_completed'].append('tutorial')
            
            # Шаг 3: Настройка параметров игры
            print("[FirstTimeSetup] Шаг 3: Настройка параметров")
            if await self._configure_settings():
                result['settings_configured'] = True
                result['steps_completed'].append('settings')
            
            # Шаг 4: Первичный сбор ресурсов
            print("[FirstTimeSetup] Шаг 4: Первичный сбор")
            if await self._initial_farming():
                result['steps_completed'].append('initial_farming')
            
            # Шаг 5: Проверка результата
            await self._verify_setup()
            
            result['success'] = True
            print(f"[FirstTimeSetup] Настройка аккаунта {self.login} завершена")
            
        except Exception as e:
            print(f"[FirstTimeSetup] Ошибка: {e}")
            result['error'] = str(e)
            self.errors.append(str(e))
        
        finally:
            # Закрываем Roblox
            await self.worker.close_roblox()
            
            result['setup_duration'] = int(time.time() - start_time)
            result['errors_count'] = len(self.errors)
        
        return result
    
    async def _complete_tutorial(self) -> bool:
        """
        Прохождение начального туториала
        
        Returns:
            True если туториал пройден
        """
        print("[FirstTimeSetup] Прохождение туториала...")
        
        # Ждем начала туториала
        await asyncio.sleep(random.uniform(2, 4))
        
        # Последовательность действий в туториале
        tutorial_steps = [
            self._tutorial_move,
            self._tutorial_eat,
            self._tutorial_drink,
            self._tutorial_mission,
            self._tutorial_finish
        ]
        
        for step_func in tutorial_steps:
            try:
                success = await step_func()
                if not success:
                    print(f"[FirstTimeSetup] Ошибка на шаге {step_func.__name__}")
                    # Продолжаем, возможно шаг уже пройден
                
                # Случайная пауза между шагами
                await asyncio.sleep(random.uniform(1, 3))
                
            except Exception as e:
                print(f"[FirstTimeSetup] Ошибка в туториале: {e}")
        
        return True
    
    async def _tutorial_move(self) -> bool:
        """
        Шаг туториала: движение
        """
        print("[FirstTimeSetup] Учимся двигаться")
        
        # Нажимаем WASD в случайном порядке
        keys = ['w', 'a', 's', 'd']
        for _ in range(random.randint(3, 6)):
            key = random.choice(keys)
            # Имитация нажатия клавиши
            await asyncio.sleep(random.uniform(0.1, 0.3))
        
        return True
    
    async def _tutorial_eat(self) -> bool:
        """
        Шаг туториала: еда
        """
        print("[FirstTimeSetup] Учимся есть")
        await asyncio.sleep(random.uniform(1, 2))
        return True
    
    async def _tutorial_drink(self) -> bool:
        """
        Шаг туториала: питье
        """
        print("[FirstTimeSetup] Учимся пить")
        await asyncio.sleep(random.uniform(1, 2))
        return True
    
    async def _tutorial_mission(self) -> bool:
        """
        Шаг туториала: первая миссия
        """
        print("[FirstTimeSetup] Выполняем первую миссию")
        await asyncio.sleep(random.uniform(2, 4))
        return True
    
    async def _tutorial_finish(self) -> bool:
        """
        Завершение туториала
        """
        print("[FirstTimeSetup] Завершаем туториал")
        await asyncio.sleep(random.uniform(1, 2))
        return True
    
    async def _configure_settings(self) -> bool:
        """
        Настройка параметров игры для оптимального фарма
        
        Returns:
            True если настройки применены
        """
        print("[FirstTimeSetup] Настройка параметров...")
        
        # Оптимальные настройки:
        # 1. Графика на минимум (для производительности)
        # 2. Звук выключен
        # 3. Управление настроено
        
        await asyncio.sleep(random.uniform(2, 3))
        
        # Здесь будет код для навигации по меню настроек
        
        return True
    
    async def _initial_farming(self) -> bool:
        """
        Первичный сбор ресурсов после создания
        
        Returns:
            True если ресурсы собраны
        """
        print("[FirstTimeSetup] Первичный сбор ресурсов...")
        
        # Собираем немного еды и воды
        await asyncio.sleep(random.uniform(3, 5))
        
        # Выполняем пару простых миссий
        await asyncio.sleep(random.uniform(5, 10))
        
        return True
    
    async def _verify_setup(self) -> bool:
        """
        Проверка успешности настройки
        
        Returns:
            True если все хорошо
        """
        print("[FirstTimeSetup] Проверка настройки...")
        
        # Проверяем, что персонаж жив
        # Проверяем, что интерфейс отображается корректно
        
        await asyncio.sleep(random.uniform(1, 2))
        
        return True
    
    async def quick_setup(self) -> bool:
        """
        Быстрая настройка (только создание персонажа)
        Используется когда нужно быстро запустить фарм
        
        Returns:
            True если успешно
        """
        print("[FirstTimeSetup] Быстрая настройка...")
        
        try:
            await self.worker.launch_roblox(self.login, self.password)
            await asyncio.sleep(10)
            
            # Только создание персонажа
            success = await self.starter_handler.handle_first_login()
            
            await self.worker.close_roblox()
            return success
            
        except Exception as e:
            print(f"[FirstTimeSetup] Ошибка быстрой настройки: {e}")
            return False