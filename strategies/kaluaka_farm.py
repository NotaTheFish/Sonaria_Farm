# strategies/kaluaka_farm.py
import asyncio
import random
import time
from typing import Dict, Any, Callable

class KaluakaFarmer:
    """
    Стратегия фарма с использованием Kaluaka (или другого стандартного существа)
    Медленнее, но безопаснее для новых аккаунтов
    """
    
    def __init__(self, worker, login: str, password: str):
        """
        Инициализация фермера для Kaluaka
        
        Args:
            worker: объект воркера
            login: логин Roblox
            password: пароль Roblox
        """
        self.worker = worker
        self.login = login
        self.password = password
        self.tokens_earned = 0
        
        # Скрипт для стандартного существа
        self.standard_lua_script = self._generate_standard_script()
    
    async def farm(self, max_tokens: int = 30, on_token_callback: Callable = None) -> Dict[str, Any]:
        """
        Основной цикл фарма с Kaluaka
        
        Args:
            max_tokens: максимальное количество токенов за сессию (меньше чем у Flickaflie)
            on_token_callback: callback при получении каждого токена
            
        Returns:
            Словарь с результатами фарма
        """
        print(f"[KaluakaFarmer] Начало фарма на {self.login}")
        
        # Запускаем Roblox с аккаунтом
        if not await self.worker.launch_roblox(self.login, self.password):
            return {'success': False, 'error': 'Failed to launch Roblox', 'tokens': 0}
        
        # Ждем загрузку игры
        await asyncio.sleep(15)
        
        # Инжектим Lua скрипт
        await self.worker.inject_script(self.standard_lua_script)
        
        # Основной цикл
        start_time = time.time()
        
        while self.tokens_earned < max_tokens:
            try:
                # Проверяем, не забанен ли аккаунт
                if await self.worker.check_if_banned():
                    await self.worker._report_ban(self.login, "roblox_ban")
                    break
                
                # Получаем текущие Death Points
                dp = await self.worker.get_death_points()
                print(f"[KaluakaFarmer] Текущие DP: {dp}")
                
                # Если DP достаточно для токена
                if dp >= 1200:
                    # Совершаем самоубийство
                    await self.worker.suicide_creature()
                    
                    # Ждем респавн
                    await asyncio.sleep(8)
                    
                    # Увеличиваем счетчик
                    self.tokens_earned += 1
                    print(f"[KaluakaFarmer] Получен токен #{self.tokens_earned}")
                    
                    if on_token_callback:
                        on_token_callback()
                
                # Пассивный фарм (больше ждем, меньше риска)
                await self._passive_farm()
                
                # Более длинные паузы чем у Flickaflie
                await asyncio.sleep(random.uniform(60, 120))
                
            except Exception as e:
                print(f"[KaluakaFarmer] Ошибка в цикле: {e}")
                await asyncio.sleep(15)
        
        # Завершаем сессию
        await self.worker.close_roblox()
        
        duration = int(time.time() - start_time)
        
        return {
            'success': True,
            'tokens': self.tokens_earned,
            'duration': duration,
            'tokens_per_hour': round(self.tokens_earned / (duration / 3600), 1)
        }
    
    async def _passive_farm(self):
        """
        Пассивный фарм - просто выживание и минимальные действия
        """
        # Находим безопасное место
        await self._find_safe_spot()
        
        # Ждем
        await asyncio.sleep(random.uniform(30, 60))
        
        # Едим и пьем при необходимости
        await self._maintain_vitals()
    
    async def _find_safe_spot(self):
        """
        Поиск безопасного места (пещера, гора, укрытие)
        """
        await asyncio.sleep(random.uniform(2, 4))
    
    async def _maintain_vitals(self):
        """
        Поддержание голода и жажды
        """
        await asyncio.sleep(random.uniform(1, 3))
    
    def _generate_standard_script(self) -> str:
        """
        Генерация Lua скрипта для стандартного существа
        
        Returns:
            Lua скрипт для инжекта
        """
        return """
        -- Standard Creature Auto-Farm Script
        -- Безопасный режим для новых аккаунтов
        
        local player = game:GetService("Players").LocalPlayer
        local character = player.Character or player.CharacterAdded:Wait()
        
        local TARGET_DP = 1200
        local CHECK_INTERVAL = 60  -- Реже проверяем
        
        -- Функция для поиска безопасного места
        local function findSafeSpot()
            -- Поиск укрытия
        end
        
        -- Основной цикл
        while task.wait(CHECK_INTERVAL) do
            -- Пассивное ожидание
            findSafeSpot()
        end
        """