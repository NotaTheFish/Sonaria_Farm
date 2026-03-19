# core/account_classifier.py
import sqlite3
import asyncio
import random
from datetime import datetime
from typing import Dict, List, Tuple, Optional
from enum import Enum

class AccountTier(Enum):
    """Уровни аккаунтов"""
    NEW = "new"              # Первый вход, нужно создать персонажа
    STANDARD = "standard"     # Есть базовые существа (Kaluaka, Pero и т.д.)
    FLICKAFLIE = "flickaflie" # Есть Flickaflie (оптимальный фарм)
    BANNED = "banned"         # Забанен
    PENDING = "pending"       # Ожидает классификации

class AccountClassifier:
    """
    Классификатор аккаунтов
    Определяет, есть ли на аккаунте Flickaflie и в каком он состоянии
    """
    
    def __init__(self):
        self.classification_stats = {
            'total_processed': 0,
            'flickaflie_found': 0,
            'standard_found': 0,
            'new_accounts': 0,
            'banned_found': 0
        }
    
    async def classify_account(self, worker, login: str, password: str) -> Dict:
        """
        Классификация одного аккаунта
        
        Args:
            worker: объект воркера для выполнения действий
            login: логин Roblox
            password: пароль Roblox
            
        Returns:
            Словарь с результатами классификации
        """
        print(f"[Классификатор] Классификация аккаунта {login}")
        
        result = {
            'login': login,
            'success': False,
            'tier': AccountTier.PENDING.value,
            'has_flickaflie': False,
            'creature_name': None,
            'age_days': 0,
            'level': 0,
            'death_tokens': 0,
            'shooms': 0,
            'notes': [],
            'error': None
        }
        
        try:
            # Запускаем Roblox
            if not await worker.launch_roblox(login, password):
                result['error'] = "Не удалось запустить Roblox"
                return result
            
            # Ждем загрузку
            await asyncio.sleep(10)
            
            # Проверка на бан
            if await worker.check_if_banned():
                result['tier'] = AccountTier.BANNED.value
                result['notes'].append("Аккаунт забанен")
                result['success'] = True
                await worker.close_roblox()
                return result
            
            # Проверка на первый вход
            if await worker.is_first_login():
                result['tier'] = AccountTier.NEW.value
                result['notes'].append("Первый вход, требуется создание персонажа")
                result['success'] = True
                await worker.close_roblox()
                return result
            
            # Проверка инвентаря на наличие Flickaflie
            has_flicka = await self._check_for_flickaflie(worker)
            
            # Получаем информацию об аккаунте
            account_info = await self._get_account_info(worker)
            
            result['has_flickaflie'] = has_flicka
            result['tier'] = AccountTier.FLICKAFLIE.value if has_flicka else AccountTier.STANDARD.value
            result['creature_name'] = account_info.get('current_creature')
            result['level'] = account_info.get('level', 0)
            result['death_tokens'] = account_info.get('death_tokens', 0)
            result['shooms'] = account_info.get('shooms', 0)
            result['success'] = True
            
            # Обновляем статистику
            self.classification_stats['total_processed'] += 1
            if has_flicka:
                self.classification_stats['flickaflie_found'] += 1
            else:
                self.classification_stats['standard_found'] += 1
            
            # Закрываем Roblox
            await worker.close_roblox()
            
            print(f"[Классификатор] Аккаунт {login} классифицирован как {result['tier']}")
            
        except Exception as e:
            print(f"[Классификатор] Ошибка при классификации {login}: {e}")
            result['error'] = str(e)
        
        return result
    
    async def _check_for_flickaflie(self, worker) -> bool:
        """
        Проверка наличия Flickaflie в инвентаре
        
        Несколько методов:
        1. Поиск по иконке/цвету
        2. Поиск по названию в меню существ
        3. Чтение памяти (сложно)
        """
        # Метод 1: Поиск по цвету (Flickaflie имеет характерный желто-зеленый цвет)
        screenshot = worker.screenshot.capture()
        
        # Здесь будет код OpenCV для поиска иконки
        # Пока заглушка с рандомом для тестирования
        
        # В реальности: анализ скриншота инвентаря
        await asyncio.sleep(2)
        
        # Для теста: 30% шанс найти Flickaflie
        return random.random() < 0.3
    
    async def _get_account_info(self, worker) -> Dict:
        """
        Получение дополнительной информации об аккаунте
        """
        info = {
            'current_creature': None,
            'level': 0,
            'death_tokens': 0,
            'shooms': 0
        }
        
        try:
            # Чтение Death Points
            dp = await worker.get_death_points()
            info['death_tokens'] = dp
            
            # Поиск имени текущего существа
            screenshot = worker.screenshot.capture()
            # OCR для чтения имени
            # text = worker.ocr.extract_text_from_image(screenshot)
            
        except Exception as e:
            print(f"[Классификатор] Ошибка получения информации: {e}")
        
        return info
    
    async def batch_classify(self, worker, accounts: List[Tuple[str, str]]) -> List[Dict]:
        """
        Пакетная классификация нескольких аккаунтов
        
        Args:
            worker: объект воркера
            accounts: список кортежей (логин, пароль)
            
        Returns:
            Список результатов классификации
        """
        results = []
        
        for login, password in accounts:
            result = await self.classify_account(worker, login, password)
            results.append(result)
            
            # Пауза между аккаунтами
            await asyncio.sleep(random.uniform(5, 10))
        
        return results
    
    def update_database(self, db_path: str, classification_results: List[Dict]):
        """
        Обновление базы данных результатами классификации
        
        Args:
            db_path: путь к БД
            classification_results: результаты классификации
        """
        conn = sqlite3.connect(db_path)
        c = conn.cursor()
        
        for result in classification_results:
            if not result['success']:
                continue
            
            # Определяем has_flickaflie (0 или 1)
            has_flicka = 1 if result['has_flickaflie'] else 0
            
            # Обновляем запись
            c.execute('''
                UPDATE accounts 
                SET tier = ?, 
                    has_flickaflie = ?, 
                    status = 'ready',
                    last_active = ?,
                    notes = ?
                WHERE login = ?
            ''', (
                result['tier'],
                has_flicka,
                datetime.now(),
                ', '.join(result['notes']),
                result['login']
            ))
        
        conn.commit()
        conn.close()
        
        print(f"[Классификатор] Обновлено {len(classification_results)} записей в БД")
    
    def get_statistics(self) -> Dict:
        """
        Получение статистики классификации
        """
        return self.classification_stats.copy()
    
    def reset_statistics(self):
        """Сброс статистики"""
        self.classification_stats = {
            'total_processed': 0,
            'flickaflie_found': 0,
            'standard_found': 0,
            'new_accounts': 0,
            'banned_found': 0
        }


# Дополнительный класс для авто-апгрейда аккаунтов
class AccountUpgrader:
    """
    Автоматический апгрейд аккаунтов
    Покупка Flickaflie за Shrooms, если накопилось достаточно
    """
    
    def __init__(self, db_path: str):
        self.db_path = db_path
        self.flickaflie_price = 150  # Цена в Shrooms (примерно)
    
    async def upgrade_standard_accounts(self, worker, min_shooms: int = 200):
        """
        Апгрейд стандартных аккаунтов до Flickaflie
        
        Args:
            worker: объект воркера
            min_shooms: минимальное количество Shrooms для покупки
        """
        # Получаем аккаунты с достаточным количеством Shrooms
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        
        # Предполагаем, что у нас есть поле shooms
        # Если нет, нужно добавить
        c.execute('''
            SELECT login, password, shooms 
            FROM accounts 
            WHERE tier = 'standard' AND has_flickaflie = 0 AND shooms >= ?
        ''', (min_shooms,))
        
        candidates = c.fetchall()
        conn.close()
        
        print(f"[Апгрейдер] Найдено {len(candidates)} кандидатов на покупку Flickaflie")
        
        for login, password, shooms in candidates:
            try:
                # Запускаем Roblox
                await worker.launch_roblox(login, password)
                await asyncio.sleep(10)
                
                # Покупаем Flickaflie
                success = await self._buy_flickaflie(worker)
                
                if success:
                    # Обновляем БД
                    conn = sqlite3.connect(self.db_path)
                    c = conn.cursor()
                    c.execute('''
                        UPDATE accounts 
                        SET has_flickaflie = 1, tier = 'flickaflie', shooms = shooms - ?
                        WHERE login = ?
                    ''', (self.flickaflie_price, login))
                    conn.commit()
                    conn.close()
                    
                    print(f"[Апгрейдер] Аккаунт {login} апгрейжден до Flickaflie")
                
                await worker.close_roblox()
                await asyncio.sleep(random.uniform(5, 10))
                
            except Exception as e:
                print(f"[Апгрейдер] Ошибка при апгрейде {login}: {e}")
    
    async def _buy_flickaflie(self, worker) -> bool:
        """
        Покупка Flickaflie в магазине
        """
        # Здесь будет навигация по меню магазина
        # 1. Открыть магазин
        # 2. Найти Flickaflie
        # 3. Нажать купить
        # 4. Подтвердить
        
        await asyncio.sleep(3)
        
        # Для теста: 80%成功率
        return random.random() < 0.8