# strategies/starter_selector.py
import random
import asyncio
import pyautogui
import cv2
import numpy as np
from typing import Tuple, Optional

class FirstTimeHandler:
    """
    Обработчик первого входа в игру.
    Отвечает за создание персонажа и выбор Kaluaka.
    """
    
    def __init__(self, worker_id: str, screenshot_helper, anti_detection=None):
        """
        Инициализация обработчика
        
        Args:
            worker_id: ID воркера
            screenshot_helper: помощник для скриншотов
            anti_detection: модуль анти-детекта (опционально)
        """
        self.worker_id = worker_id
        self.screenshot = screenshot_helper
        self.anti_detection = anti_detection
        
        # Координаты для выбора Kaluaka - НУЖНО НАСТРОИТЬ!
        # Инструкция по настройке:
        # 1. Запустите игру вручную на новом аккаунте
        # 2. Когда появится экран выбора, наведите мышь на Kaluaka
        # 3. Запишите координаты из pyautogui.position()
        # 4. Подставьте их ниже
        
        # ДЛЯ 1920x1080 (ПРИМЕР - ЗАМЕНИТЕ НА ВАШИ!)
        self.kaluaka_position = (960, 540)  # ЗАМЕНИТЕ НА РЕАЛЬНЫЕ!
        
        # Координаты поля ввода имени
        self.name_field_position = (960, 640)  # ЗАМЕНИТЕ НА РЕАЛЬНЫЕ!
        
        # Координаты кнопки подтверждения
        self.confirm_button_position = (960, 700)  # ЗАМЕНИТЕ НА РЕАЛЬНЫЕ!
        
        # Цветовые диапазоны для поиска (настраиваются)
        self.ui_color_range = {
            'lower': np.array([90, 50, 50]),
            'upper': np.array([110, 255, 255])
        }
        
        self.kaluaka_color_range = {
            'lower': np.array([25, 50, 50]),
            'upper': np.array([35, 255, 255])
        }
        
    async def handle_first_login(self) -> bool:
        """
        Основной метод: обрабатывает первый вход в игру.
        Возвращает True, если создание успешно.
        """
        print(f"[Worker {self.worker_id}] Первый вход, создаем персонажа...")
        
        # 1. Ждем загрузки экрана создания
        if not await self.wait_for_creation_screen(timeout=30):
            print(f"[Worker {self.worker_id}] Не дождались экрана создания")
            return False
        
        # Небольшая пауза для полной загрузки
        await asyncio.sleep(random.uniform(0.5, 1.5))
        
        # 2. Выбираем Kaluaka
        if not await self.select_kaluaka():
            print(f"[Worker {self.worker_id}] Не удалось выбрать Kaluaka")
            return False
        
        # 3. Вводим имя
        if not await self.enter_random_name():
            print(f"[Worker {self.worker_id}] Не удалось ввести имя")
            return False
        
        # 4. Подтверждаем создание
        if not await self.confirm_creation():
            print(f"[Worker {self.worker_id}] Не удалось подтвердить создание")
            return False
        
        print(f"[Worker {self.worker_id}] Персонаж Kaluaka успешно создан!")
        return True
    
    async def wait_for_creation_screen(self, timeout: int = 30) -> bool:
        """
        Ожидание экрана выбора существа.
        
        Args:
            timeout: максимальное время ожидания в секундах
            
        Returns:
            True если экран обнаружен
        """
        start_time = asyncio.get_event_loop().time()
        
        while asyncio.get_event_loop().time() - start_time < timeout:
            # Делаем скриншот
            screen = await self.screenshot.capture_async()
            
            # Проверяем наличие интерфейса создания
            if await self.detect_creation_ui(screen):
                # Добавляем случайную задержку для человечности
                await asyncio.sleep(random.uniform(0.5, 1.5))
                return True
            
            # Ждем перед следующей проверкой
            await asyncio.sleep(1)
        
        return False
    
    async def detect_creation_ui(self, screen_image) -> bool:
        """
        Детектит элементы интерфейса создания персонажа.
        
        Args:
            screen_image: скриншот для анализа
            
        Returns:
            True если интерфейс создания обнаружен
        """
        # Используем анти-детект для рандомизации порога
        threshold = 10000
        if self.anti_detection:
            # Немного варьируем порог
            threshold = int(threshold * random.uniform(0.8, 1.2))
        
        # Преобразуем в формат OpenCV
        img = np.array(screen_image)
        
        # Ищем характерные цвета интерфейса Sonaria
        hsv = cv2.cvtColor(img, cv2.COLOR_RGB2HSV)
        
        mask = cv2.inRange(
            hsv, 
            self.ui_color_range['lower'], 
            self.ui_color_range['upper']
        )
        
        # Если много пикселей интерфейса - значит мы в меню
        ui_pixels = cv2.countNonZero(mask)
        
        return ui_pixels > threshold
    
    async def select_kaluaka(self) -> bool:
        """
        Кликает на Kaluaka в сетке выбора.
        
        Returns:
            True если выбор успешен
        """
        # Находим позицию Kaluaka
        x, y = await self.find_kaluaka_position()
        
        # Двигаем мышь с человеческой траекторией
        if self.anti_detection:
            points = self.anti_detection.randomize_mouse_path(
                pyautogui.position()[0],
                pyautogui.position()[1],
                x, y
            )
            for px, py in points:
                pyautogui.moveTo(px, py, duration=0.01)
                await asyncio.sleep(0.01)
        else:
            await self.human_like_move(x, y)
        
        # Небольшая пауза перед кликом
        await asyncio.sleep(random.uniform(0.1, 0.3))
        
        # Кликаем
        pyautogui.click()
        
        # Ждем реакции игры
        await asyncio.sleep(random.uniform(0.5, 1.0))
        
        return True
    
    async def find_kaluaka_position(self) -> Tuple[int, int]:
        """
        Поиск позиции Kaluaka на экране.
        
        Returns:
            Координаты (x, y) для клика
        """
        # Вариант 1: Используем фиксированные координаты (быстрее)
        screen_width, screen_height = pyautogui.size()
        
        # Проверяем, соответствует ли разрешение настроенному
        if (screen_width, screen_height) == (1920, 1080):
            return self.kaluaka_position
        
        # Вариант 2: Поиск по цвету (медленнее, но универсальнее)
        try:
            screen = await self.screenshot.capture_async()
            img = np.array(screen)
            hsv = cv2.cvtColor(img, cv2.COLOR_RGB2HSV)
            
            mask = cv2.inRange(
                hsv,
                self.kaluaka_color_range['lower'],
                self.kaluaka_color_range['upper']
            )
            
            contours, _ = cv2.findContours(mask, cv2.RETR_TREE, cv2.CHAIN_APPROX_SIMPLE)
            
            if contours:
                # Берем самый большой контур
                largest = max(contours, key=cv2.contourArea)
                x, y, w, h = cv2.boundingRect(largest)
                return (x + w//2, y + h//2)
        except Exception as e:
            print(f"[Worker {self.worker_id}] Ошибка поиска Kaluaka по цвету: {e}")
        
        # Если ничего не сработало - возвращаем центр экрана
        return (screen_width // 2, screen_height // 2)
    
    async def human_like_move(self, x: int, y: int):
        """
        Движение мыши, имитирующее человека.
        
        Args:
            x, y: целевые координаты
        """
        current_x, current_y = pyautogui.position()
        
        # Добавляем кривую Безье или случайные отклонения
        steps = random.randint(15, 25)
        
        for i in range(steps):
            t = i / steps
            
            # Нелинейная интерполяция (ускорение/замедление)
            # В начале быстро, в конце медленно
            eased_t = 1 - (1 - t) ** 3
            
            new_x = int(current_x + (x - current_x) * eased_t)
            new_y = int(current_y + (y - current_y) * eased_t)
            
            # Добавляем небольшой шум
            new_x += random.randint(-5, 5)
            new_y += random.randint(-5, 5)
            
            pyautogui.moveTo(new_x, new_y, duration=0.01)
            
            # Вариация задержки
            await asyncio.sleep(random.uniform(0.008, 0.02))
    
    async def enter_random_name(self) -> bool:
        """
        Ввод случайного имени для существа.
        
        Returns:
            True если имя введено успешно
        """
        # Генерируем имя
        name = self.generate_name()
        print(f"[Worker {self.worker_id}] Генерируем имя: {name}")
        
        # Ждем появления поля ввода
        await asyncio.sleep(random.uniform(0.5, 1.0))
        
        # Находим поле ввода
        name_field_x, name_field_y = await self.find_name_field()
        
        # Двигаемся к полю
        if self.anti_detection:
            points = self.anti_detection.randomize_mouse_path(
                pyautogui.position()[0],
                pyautogui.position()[1],
                name_field_x, name_field_y
            )
            for px, py in points:
                pyautogui.moveTo(px, py, duration=0.01)
                await asyncio.sleep(0.01)
        else:
            await self.human_like_move(name_field_x, name_field_y)
        
        # Кликаем для активации поля
        await asyncio.sleep(random.uniform(0.1, 0.3))
        pyautogui.click()
        
        # Небольшая пауза перед вводом
        await asyncio.sleep(random.uniform(0.2, 0.4))
        
        # Вводим имя с человеческими задержками
        for char in name:
            # Иногда ошибаемся
            if random.random() < 0.05:  # 5% шанс опечатки
                wrong_char = random.choice('abcdefghijklmnopqrstuvwxyz')
                pyautogui.write(wrong_char)
                await asyncio.sleep(random.uniform(0.1, 0.3))
                pyautogui.press('backspace')
                await asyncio.sleep(random.uniform(0.1, 0.2))
            
            # Вводим правильную букву
            pyautogui.write(char)
            
            # Вариация задержки между буквами
            await asyncio.sleep(random.uniform(0.08, 0.2))
        
        # Иногда случайно нажимаем Enter раньше времени
        if random.random() < 0.1:
            await asyncio.sleep(random.uniform(0.3, 0.8))
            pyautogui.press('enter')
            await asyncio.sleep(random.uniform(0.2, 0.4))
            # Возвращаемся к полю ввода
            pyautogui.click(name_field_x, name_field_y)
            await asyncio.sleep(random.uniform(0.2, 0.4))
        
        # Финальная пауза
        await asyncio.sleep(random.uniform(0.5, 1.0))
        
        return True
    
    def generate_name(self) -> str:
        """
        Генерация случайного имени для существа.
        
        Returns:
            Сгенерированное имя
        """
        # Расширенные списки для большей вариативности
        prefixes = [
            'Fluffy', 'Shadow', 'Crystal', 'Blaze', 'Frost', 'Wild', 'Swift', 'Silent',
            'Mighty', 'Brave', 'Clever', 'Noble', 'Royal', 'Golden', 'Silver', 'Emerald',
            'Ruby', 'Sapphire', 'Onyx', 'Storm', 'Thunder', 'Lightning', 'Echo', 'Spirit'
        ]
        
        suffixes = [
            'paw', 'tail', 'wing', 'horn', 'claw', 'fur', 'scale', 'feather',
            'heart', 'soul', 'eye', 'fang', 'whisker', 'hoof', 'mane', 'spine',
            'runner', 'walker', 'hunter', 'gatherer', 'roamer', 'guardian'
        ]
        
        numbers = str(random.randint(10, 9999))
        
        # Разные форматы имен
        patterns = [
            # FluffyPaw123
            lambda: random.choice(prefixes) + random.choice(suffixes) + numbers,
            
            # Fluffy_Paw_123
            lambda: random.choice(prefixes) + '_' + random.choice(suffixes) + '_' + numbers,
            
            # Fluffy123
            lambda: random.choice(prefixes) + numbers,
            
            # Paw123
            lambda: random.choice(suffixes) + numbers,
            
            # Fluffy_Paw
            lambda: random.choice(prefixes) + '_' + random.choice(suffixes),
            
            # Fluffy Paw (с пробелом, если игра поддерживает)
            lambda: random.choice(prefixes) + ' ' + random.choice(suffixes) + numbers,
        ]
        
        return random.choice(patterns)()
    
    async def find_name_field(self) -> Tuple[int, int]:
        """
        Поиск поля ввода имени.
        
        Returns:
            Координаты поля ввода
        """
        # Проверяем разрешение
        screen_width, screen_height = pyautogui.size()
        
        if (screen_width, screen_height) == (1920, 1080):
            return self.name_field_position
        
        # Если разрешение другое, пытаемся найти поле по цвету или тексту
        try:
            screen = await self.screenshot.capture_async()
            img = np.array(screen)
            
            # Ищем белое поле или область с текстом
            # Это сложно сделать универсально, поэтому возвращаем центр с коррекцией
            return (screen_width // 2, screen_height // 2 + 50)
        except:
            return (screen_width // 2, screen_height // 2 + 50)
    
    async def confirm_creation(self) -> bool:
        """
        Нажатие кнопки подтверждения создания.
        
        Returns:
            True если подтверждение успешно
        """
        await asyncio.sleep(random.uniform(0.5, 1.0))
        
        # Получаем координаты кнопки
        screen_width, screen_height = pyautogui.size()
        
        if (screen_width, screen_height) == (1920, 1080):
            confirm_x, confirm_y = self.confirm_button_position
        else:
            # Для других разрешений - примерные координаты
            confirm_x, confirm_y = (screen_width // 2, screen_height // 2 + 150)
        
        # Двигаемся к кнопке
        if self.anti_detection:
            points = self.anti_detection.randomize_mouse_path(
                pyautogui.position()[0],
                pyautogui.position()[1],
                confirm_x, confirm_y
            )
            for px, py in points:
                pyautogui.moveTo(px, py, duration=0.01)
                await asyncio.sleep(0.01)
        else:
            await self.human_like_move(confirm_x, confirm_y)
        
        # Небольшая пауза перед кликом
        await asyncio.sleep(random.uniform(0.2, 0.4))
        
        # Кликаем
        pyautogui.click()
        
        # Ждем завершения создания
        await asyncio.sleep(random.uniform(3.0, 4.0))
        
        # Проверяем, что создание прошло успешно
        # (можно добавить проверку по скриншоту)
        
        return True
    
    async def calibrate_coordinates(self):
        """
        Калибровка координат для текущего разрешения.
        Запускается один раз для настройки.
        """
        print(f"[Worker {self.worker_id}] ЗАПУСК КАЛИБРОВКИ КООРДИНАТ")
        print("1. Через 5 секунд наведите мышь на Kaluaka в сетке выбора")
        print("2. Через 5 секунд наведите мышь на поле ввода имени")
        print("3. Через 5 секунд наведите мышь на кнопку подтверждения")
        
        await asyncio.sleep(5)
        
        # Получаем координаты Kaluaka
        print("Наведите мышь на Kaluaka... (3 секунды)")
        await asyncio.sleep(3)
        kaluaka_pos = pyautogui.position()
        print(f"Kaluaka позиция: {kaluaka_pos}")
        
        # Получаем координаты поля ввода
        print("Наведите мышь на поле ввода имени... (3 секунды)")
        await asyncio.sleep(3)
        name_pos = pyautogui.position()
        print(f"Поле ввода позиция: {name_pos}")
        
        # Получаем координаты кнопки подтверждения
        print("Наведите мышь на кнопку подтверждения... (3 секунды)")
        await asyncio.sleep(3)
        confirm_pos = pyautogui.position()
        print(f"Кнопка подтверждения позиция: {confirm_pos}")
        
        print("\nСКОПИРУЙТЕ ЭТИ КООРДИНАТЫ В ФАЙЛ:")
        print(f"self.kaluaka_position = {kaluaka_pos}")
        print(f"self.name_field_position = {name_pos}")
        print(f"self.confirm_button_position = {confirm_pos}")