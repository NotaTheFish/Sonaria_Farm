-- universal_sonaria_bot.lua
-- Универсальный скрипт для Creatures of Sonaria
-- Параметры передаются через инжектор: {...} = JSON-строка с конфигурацией

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local VirtualInputManager = game:GetService("VirtualInputManager")

-- ========== ПАРСИНГ ПАРАМЕТРОВ ==========
local args = {...}
local params = {}

if #args > 0 then
    local success, decoded = pcall(function()
        return HttpService:JSONDecode(args[1])
    end)
    if success then
        params = decoded
    else
        print("ERROR: Failed to decode params: " .. tostring(decoded))
        return
    end
else
    print("ERROR: No arguments provided")
    return
end

-- ========== КОНФИГУРАЦИЯ ИЗ ПАРАМЕТРОВ ==========
local ROLE = params.role or "farmer"  -- "farmer" или "storage"
local COMMAND = params.command or params.mode or "farm"  -- farm, transfer, sell, inventory, suicide
local ACCOUNT_ID = params.account_id or "unknown"
local ACCOUNT_LOGIN = params.account_login or "unknown"
local ACCOUNT_PASSWORD = params.account_password or nil

-- Параметры фарма
local TARGET_DP = params.target_dp or params.death_points_target or 600
local STOP_FLAG_PATH = params.stop_flag_path or nil

-- Параметры трейда/передачи
local TARGET_STORAGE_LOGIN = params.target_storage_login or nil
local TARGET_STORAGE_ACCOUNT_ID = params.target_storage_account_id or nil
local BATCH_SIZE = params.batch_size or 150
local COOLDOWN_SECONDS = params.cooldown_seconds or 70
local STORAGE_GIVES = params.storage_gives or 1  -- грибы за трейд
local TOKEN_KINDS = params.token_kinds or {
    "Revive Token",
    "Max Growth Token", 
    "Partial Growth Token",
    "Random Trial Creature Token",
    "Appearance Change Token",
    "Death Gacha Token"
}

-- Параметры продажи
local RANGES = params.ranges or {}
local PRIORITY_TOKENS = params.priority_tokens or {}
local FALLBACK_MODE = params.fallback_mode or params.fallback_non_priority_mode or "sell_all_when_priority_empty"

-- Параметры инвентаря
local ALLOWED_FARMER_NAMES = params.allowed_farmer_names or {}  -- для склада - кого принимать

-- Пути для файлового моста (если используется)
local RESPONSE_FILE = params.response_file or nil
local REQUEST_FILE = params.request_file or nil

-- ========== УТИЛИТЫ ==========

local function log(msg)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    print("[" .. timestamp .. "] [" .. ROLE .. "] [" .. COMMAND .. "] " .. msg)
end

local function writeResponse(data)
    local response = HttpService:JSONEncode(data)
    log("Response: " .. response)
    
    -- Если указан файл ответа - пишем туда (для файлового моста)
    if RESPONSE_FILE and type(writefile) == "function" then
        local success, err = pcall(function()
            writefile(RESPONSE_FILE, response)
        end)
        if not success then
            log("ERROR writing response file: " .. tostring(err))
        end
    end
    
    -- Также выводим в stdout для инжектора
    print("SONARIA_RESPONSE:" .. response)
    return response
end

local function stopFlagExists()
    if STOP_FLAG_PATH and type(isfile) == "function" then
        local success, exists = pcall(isfile, STOP_FLAG_PATH)
        if success and exists then
            log("Stop flag detected at: " .. STOP_FLAG_PATH)
            return true
        end
    end
    return false
end

local function wait(seconds)
    local start = tick()
    while tick() - start < seconds do
        if stopFlagExists() then
            return false  -- Прервано
        end
        RunService.Heartbeat:Wait()
    end
    return true
end

-- ========== ИГРОВЫЕ ФУНКЦИИ ==========

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")

local function getCurrentDeathPoints()
    local gui = player:FindFirstChild("PlayerGui")
    if not gui then return 0 end
    
    local gameGui = gui:FindFirstChild("GameGUI") or gui:FindFirstChild("MainGui")
    if gameGui then
        -- Ищем различные варианты названий
        local dpLabel = gameGui:FindFirstChild("DeathPoints") 
            or gameGui:FindFirstChild("DP") 
            or gameGui:FindFirstChild("DeathPointsLabel")
        
        if dpLabel and dpLabel:IsA("TextLabel") then
            local text = dpLabel.Text
            local dp = tonumber(text:match("%d+"))
            return dp or 0
        end
    end
    return 0
end

local function getInventory()
    local inventory = {}
    
    -- Пробуем различные способы получения инвентаря
    local success, result = pcall(function()
        -- Вариант 1: через ReplicatedStorage
        local itemsFolder = ReplicatedStorage:FindFirstChild("Items") 
            or ReplicatedStorage:FindFirstChild("Inventory")
            or player:FindFirstChild("Inventory")
        
        if itemsFolder then
            for _, item in pairs(itemsFolder:GetChildren()) do
                local name = item.Name
                inventory[name] = (inventory[name] or 0) + 1
            end
        end
        
        -- Вариант 2: через RemoteFunction
        local getInventoryFunc = ReplicatedStorage:FindFirstChild("GetInventory")
        if getInventoryFunc and getInventoryFunc:IsA("RemoteFunction") then
            local serverInventory = getInventoryFunc:InvokeServer()
            if type(serverInventory) == "table" then
                for name, count in pairs(serverInventory) do
                    inventory[name] = count
                end
            end
        end
        
        return inventory
    end)
    
    if success then
        return result
    else
        log("ERROR getting inventory: " .. tostring(result))
        return {}
    end
end

local function selectCreature(creatureName)
    log("Selecting creature: " .. creatureName)
    
    local success = pcall(function()
        -- Ищем GUI выбора существ
        local gui = player:WaitForChild("PlayerGui")
        local creatureSelect = gui:FindFirstChild("CreatureSelect") 
            or gui:FindFirstChild("SpawnGui")
            or gui:FindFirstChild("CharacterSelect")
        
        if creatureSelect then
            -- Ищем кнопку существа
            for _, btn in pairs(creatureSelect:GetDescendants()) do
                if btn:IsA("TextButton") or btn:IsA("ImageButton") then
                    local btnText = btn.Text or btn.Name
                    if btnText:lower():find(creatureName:lower()) then
                        -- Симулируем клик
                        local pos = btn.AbsolutePosition + (btn.AbsoluteSize / 2)
                        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
                        wait(0.1)
                        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
                        log("Clicked creature button: " .. btn.Name)
                        wait(1)
                        return true
                    end
                end
            end
        end
        
        -- Альтернативный способ: через RemoteEvent
        local spawnEvent = ReplicatedStorage:FindFirstChild("SpawnCreature")
        if spawnEvent then
            spawnEvent:FireServer(creatureName)
            return true
        end
        
        return false
    end)
    
    return success
end

local function doSuicide()
    log("Performing suicide...")
    
    local success = pcall(function()
        -- Способ 1: обнуление здоровья
        if humanoid then
            humanoid.Health = 0
        end
        
        -- Способ 2: телепорт в бездну
        if character and character:FindFirstChild("HumanoidRootPart") then
            character.HumanoidRootPart.CFrame = CFrame.new(0, -1000, 0)
        end
        
        -- Способ 3: через RemoteEvent
        local suicideEvent = ReplicatedStorage:FindFirstChild("Suicide")
        if suicideEvent then
            suicideEvent:FireServer()
        end
    end)
    
    wait(3) -- Ждём респавна
    character = player.Character or player.CharacterAdded:Wait()
    humanoid = character:WaitForChild("Humanoid")
    
    return success
end

local function doMissionStep()
    log("Doing mission step...")
    
    local success = pcall(function()
        local gui = player:WaitForChild("PlayerGui")
        local gameGui = gui:FindFirstChild("GameGUI") or gui:FindFirstChild("MainGui")
        
        if gameGui then
            -- Ищем кнопку миссий
            local missionsBtn = gameGui:FindFirstChild("MissionsButton") 
                or gameGui:FindFirstChild("MissionButton")
                or gameGui:FindFirstChild("Quests")
            
            if missionsBtn then
                -- Кликаем
                local pos = missionsBtn.AbsolutePosition + (missionsBtn.AbsoluteSize / 2)
                VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
                wait(0.1)
                VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
                wait(1)
                
                -- Ищем кнопку "Начать" или "Следующая"
                local startBtn = gameGui:FindFirstChild("StartMission") 
                    or gameGui:FindFirstChild("NextMission")
                    or gameGui:FindFirstChild("Claim")
                
                if startBtn then
                    pos = startBtn.AbsolutePosition + (startBtn.AbsoluteSize / 2)
                    VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
                    wait(0.1)
                    VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
                    wait(2)
                end
            end
        end
        
        -- Альтернатива: через RemoteEvent
        local missionEvent = ReplicatedStorage:FindFirstChild("DoMission")
        if missionEvent then
            missionEvent:FireServer()
        end
    end)
    
    return success
end

local function findPlayerByName(name)
    for _, p in pairs(Players:GetPlayers()) do
        if p.Name:lower() == name:lower() or 
           (p.DisplayName and p.DisplayName:lower() == name:lower()) then
            return p
        end
    end
    return nil
end

local function sendTrade(targetPlayer, itemsToGive, itemsToReceive)
    log("Sending trade to: " .. targetPlayer.Name)
    
    local success, err = pcall(function()
        -- Ищем TradeService
        local tradeService = ReplicatedStorage:FindFirstChild("TradeService")
            or ReplicatedStorage:FindFirstChild("Trade")
            or ReplicatedStorage:FindFirstChild("Trading")
        
        if tradeService then
            -- Отправляем запрос на трейд
            if tradeService:IsA("RemoteEvent") then
                tradeService:FireServer("request", targetPlayer, itemsToGive)
            elseif tradeService:IsA("RemoteFunction") then
                tradeService:InvokeServer("request", targetPlayer, itemsToGive)
            end
            
            wait(2)
            
            -- Подтверждаем
            if tradeService:IsA("RemoteEvent") then
                tradeService:FireServer("confirm")
            elseif tradeService:IsA("RemoteFunction") then
                tradeService:InvokeServer("confirm")
            end
            
            wait(1)
            return true
        end
        
        -- Альтернативный способ: через PlayerGui
        local gui = player:WaitForChild("PlayerGui")
        local tradeGui = gui:FindFirstChild("TradeGui") or gui:FindFirstChild("Trading")
        
        if tradeGui then
            -- Логика GUI-трейда
            -- ...
            return true
        end
        
        return false
    end)
    
    if not success then
        log("ERROR in sendTrade: " .. tostring(err))
        return false
    end
    
    return true
end

local function openTradeWorld()
    log("Opening trade world...")
    
    local success = pcall(function()
        -- Ищем TeleportService или Portal
        local portal = workspace:FindFirstChild("TradePortal") 
            or workspace:FindFirstChild("TradingPortal")
        
        if portal then
            -- Телепортируемся
            if character and character:FindFirstChild("HumanoidRootPart") then
                character.HumanoidRootPart.CFrame = portal.CFrame + Vector3.new(0, 5, 0)
                wait(2)
            end
        end
        
        -- Альтернатива: через RemoteEvent
        local joinTrade = ReplicatedStorage:FindFirstChild("JoinTradeWorld")
        if joinTrade then
            joinTrade:FireServer()
            wait(5)
        end
    end)
    
    return success
end

local function placeStand()
    log("Placing stand...")
    
    local success = pcall(function()
        local gui = player:WaitForChild("PlayerGui")
        local tradeGui = gui:FindFirstChild("TradeGui") or gui:FindFirstChild("Trading")
        
        if tradeGui then
            local placeBtn = tradeGui:FindFirstChild("PlaceStand") 
                or tradeGui:FindFirstChild("SetupStand")
            
            if placeBtn then
                local pos = placeBtn.AbsolutePosition + (placeBtn.AbsoluteSize / 2)
                VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
                wait(0.1)
                VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
                wait(2)
            end
        end
        
        -- Альтернатива: через Remote
        local placeEvent = ReplicatedStorage:FindFirstChild("PlaceTradingStand")
        if placeEvent then
            placeEvent:FireServer()
            wait(2)
        end
    end)
    
    return success
end

local function sellItem(token, price)
    log("Selling " .. token .. " for " .. tostring(price))
    
    local success = pcall(function()
        local gui = player:WaitForChild("PlayerGui")
        local tradeGui = gui:FindFirstChild("TradeGui") or gui:FindFirstChild("Trading")
        
        if tradeGui then
            -- Ищем слот для выставления
            local slots = {}
            for _, child in pairs(tradeGui:GetDescendants()) do
                if child.Name:find("Slot") or child.Name:find("Item") then
                    table.insert(slots, child)
                end
            end
            
            -- Выбираем пустой слот
            for _, slot in pairs(slots) do
                -- Проверяем пустой ли
                -- ...
            end
        end
        
        -- Через Remote
        local sellEvent = ReplicatedStorage:FindFirstChild("SellItem")
        if sellEvent then
            sellEvent:FireServer(token, price)
            return true
        end
        
        return false
    end)
    
    return success
end

-- ========== ОБРАБОТЧИКИ КОМАНД ==========

local handlers = {}

-- ФАРМ (фармер)
handlers.farm = function()
    log("Starting FARM mode")
    
    -- Проверяем, выбрано ли существо
    if not character or not humanoid or humanoid.Health <= 0 then
        log("Character not ready, waiting...")
        character = player.Character or player.CharacterAdded:Wait()
        humanoid = character:WaitForChild("Humanoid")
    end
    
    -- Если первый запуск - выбираем Kaluaka
    -- (проверяем по наличию определённых признаков)
    local isFirstRun = params.is_first_run or params.first_run or false
    
    if isFirstRun then
        log("First run detected, selecting Kaluaka...")
        selectCreature("Kaluaka")
        wait(3)
    end
    
    local startTime = tick()
    local cycles = 0
    
    while true do
        cycles = cycles + 1
        log("Farm cycle #" .. cycles)
        
        -- Проверяем флаг остановки
        if stopFlagExists() then
            log("Stop flag detected, exiting farm loop")
            return {
                ok = true,
                log = "Farm stopped by flag after " .. cycles .. " cycles",
                inventory = getInventory()
            }
        end
        
        -- Проверяем текущие DP
        local currentDP = getCurrentDeathPoints()
        log("Current DP: " .. currentDP .. " / " .. TARGET_DP)
        
        if currentDP >= TARGET_DP then
            log("Target DP reached! Performing suicide...")
            doSuicide()
            
            -- Проверяем, нужно ли продолжать
            if params.stop_after_suicide then
                return {
                    ok = true,
                    log = "Target DP reached, suicide performed, stopping",
                    death_points_current = 0,
                    inventory = getInventory()
                }
            end
            
            wait(2)
        else
            -- Выполняем миссию
            doMissionStep()
            wait(1)
        end
        
        -- Проверяем, жив ли персонаж
        if humanoid.Health <= 0 then
            log("Character died, waiting for respawn...")
            character = player.Character or player.CharacterAdded:Wait()
            humanoid = character:WaitForChild("Humanoid")
            wait(2)
        end
        
        -- Небольшая задержка между циклами
        if not wait(0.5) then
            return {
                ok = true,
                log = "Farm interrupted by stop flag",
                inventory = getInventory()
            }
        end
    end
end

-- СУИЦИД (фармер)
handlers.suicide = function()
    log("Performing SUICIDE command")
    doSuicide()
    
    return {
        ok = true,
        log = "Suicide performed successfully",
        death_points_current = 0,
        inventory = getInventory()
    }
end

-- ИНВЕНТАРЬ (обе роли)
handlers.inventory = function()
    log("Getting INVENTORY")
    
    local inv = getInventory()
    
    -- Фильтруем только нужные токены, если указаны
    local filtered = {}
    if #TOKEN_KINDS > 0 then
        for _, tokenName in ipairs(TOKEN_KINDS) do
            filtered[tokenName] = inv[tokenName] or 0
        end
    else
        filtered = inv
    end
    
    return {
        ok = true,
        log = "Inventory retrieved",
        inventory = filtered,
        full_inventory = inv
    }
end

-- DEX (отладка)
-- Требует executor API: getcustomasset + getobjects
handlers.dex = function()
    log("Loading DEX GUI")

    local assetPath = params.dex_asset_path or params.dex_model_path or "Dex_roblox.rbxm"
    local dexUrl = params.dex_url or params.dex_loader_url or nil

    -- Fallback for executors like JJSploit: load dex from URL.
    if type(getcustomasset) ~= "function" or type(getobjects) ~= "function" then
        dexUrl = dexUrl or "https://cdn.wearedevs.net/scripts/Dex Explorer V2.txt"
        if type(loadstring) ~= "function" then
            return { ok = false, error = "No getcustomasset/getobjects and no loadstring available" }
        end
        local okHttp, body = pcall(function()
            return game:HttpGet(dexUrl, true)
        end)
        if not okHttp or type(body) ~= "string" or #body < 10 then
            return { ok = false, error = "HttpGet failed for dexUrl: " .. tostring(dexUrl) }
        end
        local fn, err = loadstring(body)
        if not fn then
            return { ok = false, error = "loadstring failed: " .. tostring(err) }
        end
        local okRun, runErr = pcall(fn)
        if not okRun then
            return { ok = false, error = "Dex loader crashed: " .. tostring(runErr) }
        end
        return {
            ok = true,
            log = "Dex loaded via URL: " .. tostring(dexUrl),
            inventory = getInventory()
        }
    end

    local okAsset, assetId = pcall(getcustomasset, assetPath)
    if not okAsset then
        return { ok = false, error = "getcustomasset failed: " .. tostring(assetId) }
    end

    local okObj, objects = pcall(getobjects, assetId)
    if not okObj or type(objects) ~= "table" or #objects == 0 then
        return { ok = false, error = "getobjects failed or returned empty" }
    end

    local gui = objects[1]
    local parentOk = false

    -- Prefer CoreGui, fallback to PlayerGui
    if typeof(game) == "Instance" then
        local coreGui = game:GetService("CoreGui")
        if coreGui then
            pcall(function()
                gui.Parent = coreGui
                parentOk = true
            end)
        end
        if not parentOk then
            local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
            if pg then
                pcall(function()
                    gui.Parent = pg
                    parentOk = true
                end)
            end
        end
    end

    if not parentOk then
        return { ok = false, error = "Could not parent Dex GUI (CoreGui/PlayerGui)" }
    end

    return {
        ok = true,
        log = "Dex injected from " .. tostring(assetPath),
        inventory = getInventory()
    }
end

-- ПЕРЕДАЧА НА СКЛАД (фармер)
handlers.transfer = function()
    log("Starting TRANSFER to storage")
    
    if not TARGET_STORAGE_LOGIN then
        return {
            ok = false,
            error = "No target_storage_login provided"
        }
    end
    
    -- Находим склад
    local storage = findPlayerByName(TARGET_STORAGE_LOGIN)
    if not storage then
        return {
            ok = false,
            error = "Storage player not found: " .. TARGET_STORAGE_LOGIN
        }
    end
    
    -- Получаем инвентарь
    local inventory = getInventory()
    
    -- Формируем список токенов для передачи
    local itemsToTransfer = {}
    local totalItems = 0
    
    for _, tokenName in ipairs(TOKEN_KINDS) do
        local count = inventory[tokenName] or 0
        if count > 0 then
            itemsToTransfer[tokenName] = count
            totalItems = totalItems + count
        end
    end
    
    if totalItems == 0 then
        return {
            ok = true,
            log = "No items to transfer",
            inventory = inventory
        }
    end
    
    log("Found " .. totalItems .. " items to transfer")
    
    -- Передаём пачками
    local transferred = 0
    for tokenName, count in pairs(itemsToTransfer) do
        local remaining = count
        
        while remaining > 0 do
            local batch = math.min(BATCH_SIZE, remaining)
            
            log("Transferring " .. batch .. "x " .. tokenName)
            
            local success = sendTrade(storage, {
                {token = tokenName, amount = batch}
            }, {
                {token = "Mushroom", amount = STORAGE_GIVES}  -- Получаем грибы взамен
            })
            
            if success then
                transferred = transferred + batch
                remaining = remaining - batch
                inventory[tokenName] = (inventory[tokenName] or 0) - batch
                
                -- Кулдаун между трейдами
                if remaining > 0 or next(itemsToTransfer, tokenName) then
                    log("Cooldown: " .. COOLDOWN_SECONDS .. "s")
                    wait(COOLDOWN_SECONDS)
                end
            else
                return {
                    ok = false,
                    error = "Trade failed for " .. tokenName,
                    inventory = getInventory()
                }
            end
        end
    end
    
    return {
        ok = true,
        log = "Transferred " .. transferred .. " items to " .. TARGET_STORAGE_LOGIN,
        inventory = getInventory()
    }
end

-- ПРОДАЖА (склад)
handlers.sell = function()
    log("Starting SELL mode")
    
    -- Открываем торговый мир
    openTradeWorld()
    
    -- Ставим стойку
    placeStand()
    
    -- Получаем инвентарь
    local inventory = getInventory()
    
    -- Функция для выставления токена
    local function trySellToken(token)
        local count = inventory[token] or 0
        if count <= 0 then return false end
        
        local range = RANGES[token]
        if not range then
            if FALLBACK_MODE == "sell_all_when_priority_empty" then
                -- Пропускаем неприоритетные если режим такой
                return false
            end
            -- Используем дефолтный диапазон
            range = {min = 1000, max = 2000}
        end
        
        local price = math.random(range.min, range.max)
        log("Selling " .. token .. " for " .. price .. " (have " .. count .. ")")
        
        local success = sellItem(token, price)
        if success then
            inventory[token] = count - 1
            return true
        end
        return false
    end
    
    -- Сначала продаём приоритетные
    local sold = 0
    local cycles = 0
    
    while cycles < 1000 do  -- Защита от бесконечного цикла
        cycles = cycles + 1
        
        if stopFlagExists() then
            break
        end
        
        local anySold = false
        
        -- Приоритетные токены
        for _, token in ipairs(PRIORITY_TOKENS) do
            if trySellToken(token) then
                anySold = true
                sold = sold + 1
                wait(0.5)
            end
        end
        
        -- Если приоритетные закончились и режим позволяет - продаём остальное
        if not anySold and FALLBACK_MODE == "sell_all_when_priority_empty" then
            for token, count in pairs(inventory) do
                if count > 0 and not table.find(PRIORITY_TOKENS, token) then
                    if trySellToken(token) then
                        anySold = true
                        sold = sold + 1
                        wait(0.5)
                        break
                    end
                end
            end
        end
        
        -- Если ничего не продали - выходим
        if not anySold then
            log("Nothing more to sell")
            break
        end
        
        wait(1)
    end
    
    return {
        ok = true,
        log = "Sold " .. sold .. " items",
        inventory = getInventory()
    }
end

-- ========== ГЛАВНЫЙ ОБРАБОТЧИК ==========

local function main()
    log("=== UNIVERSAL SONARIA BOT STARTED ===")
    log("Account: " .. ACCOUNT_LOGIN .. " (" .. ACCOUNT_ID .. ")")
    log("Role: " .. ROLE)
    log("Command: " .. COMMAND)
    
    -- Проверяем валидность команды для роли
    local roleCommands = {
        farmer = {farm = true, transfer = true, inventory = true, suicide = true},
        storage = {sell = true, inventory = true, transfer = true}  -- storage может принимать
    }
    
    if ROLE == "storage" and COMMAND == "farm" then
        return writeResponse({
            ok = false,
            error = "Storage cannot farm"
        })
    end
    
    if ROLE == "farmer" and COMMAND == "sell" then
        return writeResponse({
            ok = false,
            error = "Farmer cannot sell (use transfer instead)"
        })
    end
    
    -- Выполняем команду
    local handler = handlers[COMMAND]
    if not handler then
        return writeResponse({
            ok = false,
            error = "Unknown command: " .. COMMAND
        })
    end
    
    local result = handler()
    return writeResponse(result)
end

-- Запускаем
local success, result = pcall(main)

if not success then
    log("FATAL ERROR: " .. tostring(result))
    writeResponse({
        ok = false,
        error = "Fatal error: " .. tostring(result),
        inventory = {}
    })
end