# strategies/flickaflie_farm.py
import asyncio
import random
import time
from typing import Dict, Any, Callable

class FlickaflieFarmer:
    """
    Стратегия фарма с использованием Flickaflie
    Самый эффективный метод благодаря способности Healing Hunter
    """
    
    def __init__(self, worker, login: str, password: str):
        """
        Инициализация фермера для Flickaflie
        
        Args:
            worker: объект воркера
            login: логин Roblox
            password: пароль Roblox
        """
        self.worker = worker
        self.login = login
        self.password = password
        self.tokens_earned = 0
        
        # Скрипт для Flickaflie на Lua
        self.flickaflie_lua_script = self._generate_flickaflie_script()
    
    async def farm(self, max_tokens: int = 50, on_token_callback: Callable = None) -> Dict[str, Any]:
        """
        Основной цикл фарма с Flickaflie
        
        Args:
            max_tokens: максимальное количество токенов за сессию
            on_token_callback: callback при получении каждого токена
            
        Returns:
            Словарь с результатами фарма
        """
        print(f"[FlickaflieFarmer] Начало фарма на {self.login}")
        
        # Запускаем Roblox с аккаунтом
        if not await self.worker.launch_roblox(self.login, self.password):
            return {'success': False, 'error': 'Failed to launch Roblox', 'tokens': 0}
        
        # Ждем загрузку игры
        await asyncio.sleep(15)
        
        # Инжектим Lua скрипт
        if not await self.worker.inject_script(self.flickaflie_lua_script):
            print("[FlickaflieFarmer] Не удалось инжектить скрипт, продолжаем без него")
        
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
                print(f"[FlickaflieFarmer] Текущие DP: {dp}")
                
                # Если DP достаточно для токена
                if dp >= 1200:
                    # Совершаем самоубийство
                    await self.worker.suicide_creature()
                    
                    # Ждем респавн
                    await asyncio.sleep(8)
                    
                    # Увеличиваем счетчик
                    self.tokens_earned += 1
                    print(f"[FlickaflieFarmer] Получен токен #{self.tokens_earned}")
                    
                    if on_token_callback:
                        on_token_callback()
                
                # Выполняем миссии (активная фаза)
                await self._perform_missions()
                
                # Случайная пауза между действиями
                await asyncio.sleep(random.uniform(30, 60))
                
            except Exception as e:
                print(f"[FlickaflieFarmer] Ошибка в цикле: {e}")
                await asyncio.sleep(10)
        
        # Завершаем сессию
        await self.worker.close_roblox()
        
        duration = int(time.time() - start_time)
        
        return {
            'success': True,
            'tokens': self.tokens_earned,
            'duration': duration,
            'tokens_per_hour': round(self.tokens_earned / (duration / 3600), 1)
        }
    
    async def _perform_missions(self):
        """
        Выполнение миссий с использованием способностей Flickaflie
        """
        # Здесь будет Lua код для автоматического выполнения миссий
        # Пока имитация через случайные действия
        
        # Используем Healing Hunter (лечим других игроков вместо атаки)
        await self._heal_players()
        
        # Собираем еду
        await self._gather_food()
        
        # Перемещаемся между биомами
        await self._travel_biomes()
    
    async def _heal_players(self):
        """
        Лечение других игроков (безопасная альтернатива атаке)
        """
        # В реальности: поиск ближайших игроков и применение способности
        await asyncio.sleep(random.uniform(2, 5))
    
    async def _gather_food(self):
        """
        Сбор еды
        """
        await asyncio.sleep(random.uniform(1, 3))
    
    async def _travel_biomes(self):
        """
        Путешествие между биомами для активации миссий
        """
        await asyncio.sleep(random.uniform(3, 7))
    
    def _generate_flickaflie_script(self) -> str:
        """
        Генерация Lua скрипта для Flickaflie
        
        Returns:
            Lua скрипт для инжекта
        """
        return """
        -- Flickaflie Auto-Farm Script for Creatures of Sonaria
        -- Оптимизирован для сбора Death Points
        
        local player = game:GetService("Players").LocalPlayer
        local character = player.Character or player.CharacterAdded:Wait()
        
        -- Основные параметры
        local TARGET_DP = 1200
        local CHECK_INTERVAL = 30
        
        -- Функция для получения текущих DP
        local function getDeathPoints()
            -- Зависит от структуры игры, нужно обновлять
            local dp = 0
            -- Поиск UI элемента с DP
            -- local dpGui = player.PlayerGui:FindFirstChild("DeathPoints")
            -- if dpGui then
            --     dp = tonumber(dpGui.Text) or 0
            -- end
            return dp
        end
        
        -- Функция для выполнения миссий
        local function doMissions()
            -- Автоматическое принятие и выполнение миссий
            -- Используем Healing Hunter для безопасных атак
        end
        
        -- Функция для самоубийства
        local function commitSuicide()
            -- Разные способы
            local methods = {
                function() -- Прыжок
                    character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end,
                function() -- Поиск воды
                    -- Перемещение к воде
                end
            }
            local method = methods[math.random(1, #methods)]
            method()
        end
        
        -- Основной цикл
        while task.wait(CHECK_INTERVAL) do
            local dp = getDeathPoints()
            if dp >= TARGET_DP then
                commitSuicide()
            end
            doMissions()
        end
        """