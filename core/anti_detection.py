# core/anti_detection.py
import random
import time
import hashlib
import json
from datetime import datetime
from typing import List, Dict, Optional
import os

class AntiDetection:
    """
    Модуль защиты от обнаружения
    Реализует различные методы маскировки ботов под реальных игроков
    """
    
    def __init__(self):
        # Паттерны поведения реальных игроков
        self.human_behavior_patterns = self._load_behavior_patterns()
        
        # Список User-Agent для ротации
        self.user_agents = self._load_user_agents()
        
        # Тайминги для рандомизации
        self.action_timings = []
        
        # Статистика для обнаружения аномалий
        self.action_history = []
        
    def _load_behavior_patterns(self) -> Dict:
        """
        Загрузка паттернов поведения реальных игроков
        """
        return {
            'mouse_movement': {
                'speed_variance': (0.5, 2.0),  # Вариация скорости мыши
                'curvature': (0.1, 0.5),       # Кривизна траектории
                'overshoot': 0.3,               # Вероятность промаха
            },
            'keyboard': {
                'typo_chance': 0.05,            # Шанс опечатки
                'backspace_chance': 0.1,         # Шанс исправления
                'pause_between_keys': (0.05, 0.3) # Пауза между нажатиями
            },
            'gameplay': {
                'idle_time': (30, 300),          # Время бездействия (сек)
                'mission_switch': (60, 600),      # Время между сменой миссий
                'biome_change': (120, 900)        # Время между сменой биомов
            },
            'session': {
                'max_session': 7200,              # Макс длина сессии (2 часа)
                'break_between': (300, 3600),      # Перерыв между сессиями
                'login_time_variance': (10, 60)    # Вариация времени входа
            }
        }
    
    def _load_user_agents(self) -> List[str]:
        """
        Загрузка списка User-Agent для браузера
        """
        return [
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 Edg/119.0.0.0",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15",
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        ]
    
    def randomize_mouse_path(self, start_x: int, start_y: int, end_x: int, end_y: int) -> List[tuple]:
        """
        Генерация случайной траектории движения мыши (имитация человека)
        
        Args:
            start_x, start_y: начальные координаты
            end_x, end_y: конечные координаты
            
        Returns:
            Список точек траектории
        """
        points = []
        
        # Количество точек в траектории
        steps = random.randint(15, 30)
        
        for i in range(steps + 1):
            t = i / steps
            
            # Безье или простая интерполяция с шумом
            x = start_x + (end_x - start_x) * t
            y = start_y + (end_y - start_y) * t
            
            # Добавляем случайное отклонение (человеческий фактор)
            if 0.2 < t < 0.8:
                noise_x = random.randint(-15, 15)
                noise_y = random.randint(-15, 15)
                x += noise_x
                y += noise_y
            
            points.append((int(x), int(y)))
        
        return points
    
    def human_delay(self, action_type: str = "default") -> float:
        """
        Генерация задержки, имитирующей человека
        
        Args:
            action_type: тип действия (click, type, move и т.д.)
            
        Returns:
            Время задержки в секундах
        """
        delays = {
            'click': (0.1, 0.4),
            'type': (0.05, 0.25),
            'move': (0.3, 0.8),
            'think': (0.5, 3.0),
            'reaction': (0.2, 0.8),
            'default': (0.1, 0.5)
        }
        
        min_d, max_d = delays.get(action_type, delays['default'])
        
        # Используем нормальное распределение для более естественных задержек
        delay = random.gauss((min_d + max_d) / 2, (max_d - min_d) / 4)
        
        # Ограничиваем диапазон
        delay = max(min_d, min(max_d, delay))
        
        return delay
    
    def should_take_break(self, session_duration: int) -> bool:
        """
        Определение, нужно ли сделать перерыв
        
        Args:
            session_duration: длительность текущей сессии в секундах
            
        Returns:
            True если пора сделать перерыв
        """
        max_session = self.human_behavior_patterns['session']['max_session']
        
        if session_duration > max_session:
            return True
        
        # Случайные перерывы (как у людей)
        if random.random() < 0.1:  # 10% шанс на перерыв
            return True
        
        return False
    
    def get_break_duration(self) -> int:
        """
        Получение длительности перерыва
        
        Returns:
            Длительность перерыва в секундах
        """
        min_break, max_break = self.human_behavior_patterns['session']['break_between']
        return random.randint(min_break, max_break)
    
    def randomize_keyboard_input(self, text: str) -> str:
        """
        Имитация ввода текста с возможными опечатками
        
        Args:
            text: исходный текст
            
        Returns:
            Текст с имитацией опечаток
        """
        if random.random() > self.human_behavior_patterns['keyboard']['typo_chance']:
            return text
        
        # Простая опечатка: замена символа
        if len(text) > 2:
            pos = random.randint(0, len(text) - 1)
            chars = 'abcdefghijklmnopqrstuvwxyz'
            wrong_char = random.choice(chars)
            text = text[:pos] + wrong_char + text[pos+1:]
        
        return text
    
    def add_action_to_history(self, action: str):
        """
        Добавление действия в историю для анализа паттернов
        
        Args:
            action: совершенное действие
        """
        self.action_history.append({
            'action': action,
            'time': time.time()
        })
        
        # Ограничиваем историю
        if len(self.action_history) > 100:
            self.action_history = self.action_history[-100:]
    
    def is_pattern_suspicious(self) -> bool:
        """
        Проверка, не выглядит ли поведение подозрительным
        
        Returns:
            True если поведение слишком подозрительное
        """
        if len(self.action_history) < 10:
            return False
        
        # Проверка на слишком регулярные действия
        recent = self.action_history[-10:]
        
        # Вычисляем интервалы между действиями
        intervals = []
        for i in range(1, len(recent)):
            intervals.append(recent[i]['time'] - recent[i-1]['time'])
        
        if not intervals:
            return False
        
        # Если интервалы слишком одинаковые - подозрительно
        avg_interval = sum(intervals) / len(intervals)
        variance = sum((i - avg_interval) ** 2 for i in intervals) / len(intervals)
        
        # Маленькая дисперсия = слишком регулярно
        if variance < 0.1:
            return True
        
        return False
    
    def generate_human_fingerprint(self) -> Dict:
        """
        Генерация случайного цифрового отпечатка (для браузера)
        
        Returns:
            Словарь с параметрами fingerprint
        """
        return {
            'screen_resolution': random.choice([
                (1920, 1080),
                (1366, 768),
                (1536, 864),
                (1440, 900),
                (2560, 1440)
            ]),
            'color_depth': random.choice([24, 32]),
            'timezone': random.choice([
                'America/New_York',
                'Europe/London',
                'Asia/Tokyo',
                'Australia/Sydney',
                'Europe/Moscow'
            ]),
            'language': random.choice(['en-US', 'ru-RU', 'de-DE', 'fr-FR', 'ja-JP']),
            'platform': random.choice(['Win32', 'MacIntel', 'Linux x86_64']),
            'cookies_enabled': True,
            'do_not_track': random.choice([0, 1]),
            'user_agent': random.choice(self.user_agents)
        }
    
    def generate_device_id(self) -> str:
        """
        Генерация уникального ID устройства
        
        Returns:
            Строка с ID устройства
        """
        # Генерируем случайный идентификатор
        random_data = f"{random.random()}{time.time()}{random.randint(1, 1000000)}"
        return hashlib.md5(random_data.encode()).hexdigest()
    
    def get_random_play_time(self) -> Dict:
        """
        Генерация случайного времени игры (как у реального игрока)
        
        Returns:
            Словарь с временем начала и длительностью
        """
        # Люди чаще играют вечером и в выходные
        current_hour = datetime.now().hour
        
        # Коэффициенты вероятности игры в разное время
        hour_probability = {
            0: 0.3, 1: 0.2, 2: 0.1, 3: 0.05, 4: 0.05, 5: 0.1,
            6: 0.2, 7: 0.3, 8: 0.4, 9: 0.5, 10: 0.6, 11: 0.6,
            12: 0.7, 13: 0.7, 14: 0.7, 15: 0.8, 16: 0.8, 17: 0.9,
            18: 0.9, 19: 1.0, 20: 1.0, 21: 1.0, 22: 0.9, 23: 0.6
        }
        
        prob = hour_probability.get(current_hour, 0.5)
        
        # Если вероятность太低, можем отложить запуск
        if random.random() > prob:
            # Запускаем позже
            delay_hours = random.randint(1, 6)
            return {
                'should_start': False,
                'delay_hours': delay_hours
            }
        
        # Длительность сессии
        duration = random.randint(30, 180)  # 30-180 минут
        
        return {
            'should_start': True,
            'duration_minutes': duration
        }


# Класс для управления прокси
class ProxyRotator:
    """
    Ротация прокси для каждого бота
    """
    
    def __init__(self, proxy_file: str = None):
        self.proxies = []
        self.current_index = 0
        self.failed_proxies = set()
        
        if proxy_file and os.path.exists(proxy_file):
            self.load_proxies(proxy_file)
    
    def load_proxies(self, filepath: str):
        """
        Загрузка прокси из файла
        
        Формат: одна прокси на строку
        - ip:port
        - ip:port:login:password
        """
        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    self.proxies.append(line)
        
        print(f"[ProxyRotator] Загружено {len(self.proxies)} прокси")
    
    def get_next_proxy(self) -> Optional[str]:
        """
        Получение следующего прокси (round-robin)
        """
        if not self.proxies:
            return None
        
        # Пропускаем упавшие прокси
        attempts = 0
        while attempts < len(self.proxies):
            proxy = self.proxies[self.current_index]
            self.current_index = (self.current_index + 1) % len(self.proxies)
            
            if proxy not in self.failed_proxies:
                return proxy
            
            attempts += 1
        
        # Если все прокси упали, сбрасываем failed и берем первый
        self.failed_proxies.clear()
        return self.proxies[0]
    
    def mark_failed(self, proxy: str):
        """
        Отметить прокси как упавший
        """
        self.failed_proxies.add(proxy)
        print(f"[ProxyRotator] Прокси {proxy} отмечен как упавший")
    
    def parse_proxy(self, proxy_string: str) -> Dict:
        """
        Парсинг строки прокси
        
        Returns:
            Словарь с типом, ip, port, login, password
        """
        parts = proxy_string.split(':')
        
        result = {
            'type': 'http',  # по умолчанию
            'ip': parts[0],
            'port': int(parts[1]) if len(parts) > 1 else None
        }
        
        if len(parts) >= 4:
            result['login'] = parts[2]
            result['password'] = parts[3]
        elif len(parts) >= 3:
            # Возможно login:password объединены
            if '@' in parts[2]:
                auth, rest = parts[2].split('@')
                result['login'], result['password'] = auth.split(':')
                result['ip'] = rest
            else:
                result['login'] = parts[2]
        
        return result