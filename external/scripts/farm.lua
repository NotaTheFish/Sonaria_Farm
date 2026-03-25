-- farm.lua
-- Параметры передаются через файл: runtime/farm_params_<account_id>.json
-- Структура параметров: { target_dp, stop_flag_path, account_login, account_password, ... }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")

-- ========== ФУНКЦИИ ДЛЯ РАБОТЫ С ФАЙЛАМИ (через HTTP-запросы или внешний API) ==========
-- Roblox не имеет доступа к файловой системе. Поэтому нам нужен sidecar,
-- который будет читать/писать файлы от имени скрипта. Проще всего:
-- 1. Инжектор при запуске скрипта передаёт ему путь к request.json через аргумент.
-- 2. Скрипт делает HTTP-запрос к локальному серверу (например, на localhost:8080),
--    который уже работает с файлами.
--
-- Но для простоты теста можно использовать следующий подход: скрипт пишет ответ в
-- ReplicatedStorage (или в локальное хранилище), а sidecar забирает оттуда.
-- Однако это ненадёжно.
--
-- Вместо этого предлагаю: инжектор при запуске farm.lua передаёт аргументы (JSON),
-- и скрипт работает с ними напрямую, без файлов. Тогда параметры (target_dp и т.д.)
-- будут встроены в скрипт через инжектор. Это проще и быстрее.
--
-- Здесь я приведу вариант с получением параметров из аргумента инжектора.
-- Предполагается, что инжектор вызывает farm.lua с одним аргументом — JSON-строкой.
-- Если инжектор этого не делает, нужно использовать файловый IPC через sidecar.

local args = {...}
local params = {}
if #args > 0 then
    params = HttpService:JSONDecode(args[1])
else
    -- fallback: читаем из файла через sidecar (требуется дополнительный код)
    print("farm.lua: no arguments, exiting")
    return
end

local targetDP = params.target_dp
local stopFlagPath = params.stop_flag_path  -- путь к файлу, по наличию которого скрипт завершается
local accountLogin = params.account_login
local accountPassword = params.account_password

-- ========== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ==========

local function getCurrentDeathPoints()
    -- Ищем элемент GUI, содержащий DP. Обычно это TextLabel в PlayerGui.
    local gui = player.PlayerGui:FindFirstChild("GameGUI")
    if gui then
        local dpLabel = gui:FindFirstChild("DeathPoints")
        if dpLabel and dpLabel:IsA("TextLabel") then
            local text = dpLabel.Text
            local dp = tonumber(text:match("%d+"))
            return dp or 0
        end
    end
    return 0
end

local function doMissionStep()
    -- Находим кнопку "Миссии" и кликаем.
    local gui = player.PlayerGui:FindFirstChild("GameGUI")
    if gui then
        local missionsButton = gui:FindFirstChild("MissionsButton")
        if missionsButton and missionsButton:IsA("ImageButton") then
            missionsButton:Click()
            wait(1)
            -- Здесь может быть кнопка "Начать миссию" или "Следующая"
            local nextButton = gui:FindFirstChild("NextMissionButton")
            if nextButton then
                nextButton:Click()
                wait(2)
            end
        end
    end
end

local function suicide()
    if humanoid then
        humanoid.Health = 0
        wait(3) -- ждём смерти
        -- Ожидаем появления новой модели персонажа
        player.CharacterAdded:Wait()
        character = player.Character
        humanoid = character:WaitForChild("Humanoid")
    end
end

local function stopFlagExists()
    -- Для популярных executor API (Synapse-подобные):
    if stopFlagPath and type(isfile) == "function" then
        local ok, exists = pcall(isfile, stopFlagPath)
        if ok and exists then
            return true
        end
    end
    -- Fallback: если API нет, остаёмся в бесконечном цикле до внешней остановки процесса.
    return false
end

-- ========== ОСНОВНОЙ ЦИКЛ ==========
print("farm.lua started. Target DP:", targetDP)

-- Если персонаж мёртв, возрождаем
if humanoid.Health <= 0 then
    suicide()
end

-- Выбор существа Kaluaka при первом запуске (если не выбрано)
-- Это можно сделать через покупку в магазине существ.
-- Здесь нужна специфичная логика игры. Допустим, существо выбирается автоматически.

while true do
    local currentDP = getCurrentDeathPoints()
    if currentDP >= targetDP then
        suicide()
        -- После смерти сбросим цель (накопление DP обнулится), но цикл продолжается.
        wait(1)
    else
        doMissionStep()
    end
    if stopFlagExists() then
        break
    end
    wait(1) -- задержка между тиками
end

print("farm.lua stopped")