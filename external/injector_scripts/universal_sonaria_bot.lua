-- universal_sonaria_bot.lua
-- Универсальный скрипт Creatures of Sonaria + контракт с контроллером (JSON в первом аргументе).
-- Параметры задаёт Python (payload задач UNIVERSAL_FARM / UNIVERSAL_TRANSFER / UNIVERSAL_SELL).
-- Dex: положи Dex_roblox.rbxmx в рабочую папку эксплойта или задай dex_asset_path.

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

-- ========== КОНФИГУРАЦИЯ ИЗ ПАРАМЕТРОВ (см. farm.game.script_params) ==========
local ROLE = params.role or "farmer"
local COMMAND = params.command or params.mode or "farm"
local ACCOUNT_ID = params.account_id or "unknown"
local ACCOUNT_LOGIN = params.account_login or "unknown"
local ACCOUNT_PASSWORD = params.account_password or nil

local TARGET_DP = params.target_dp or params.death_points_target or 600
local STOP_FLAG_PATH = params.stop_flag_path or nil

local TARGET_STORAGE_LOGIN = params.target_storage_login
    or params.target_storage_username
    or nil
local TARGET_STORAGE_ACCOUNT_ID = params.target_storage_account_id or nil

local BATCH_SIZE = tonumber(params.batch_size) or 150
local COOLDOWN_SECONDS = tonumber(params.cooldown_seconds) or tonumber(params.post_trade_cooldown_seconds) or 70
local TRADE_RETRY_SECONDS = tonumber(params.trade_retry_seconds) or 10
local TRADE_CONFIRM_POLL_SECONDS = tonumber(params.trade_confirm_poll_seconds) or 2
local STORAGE_GIVES = tonumber(params.storage_gives) or 1

local DEFAULT_TOKEN_ORDER = {
    "Revive Token",
    "Max Growth Token",
    "Partial Growth Token",
    "Appearance Change Token",
    "Random Trial Creature Token",
    "Death Gacha Token",
}
local TOKEN_KINDS = params.transfer_token_priority or params.token_kinds or DEFAULT_TOKEN_ORDER

local FARM_PIPELINE = params.farm_pipeline or "missions_dp_only"
local DEFAULT_CREATURE = params.default_creature_name or "Kaluaka"
local VOLCANO_SUICIDE = params.volcano_suicide == true or params.volcano_suicide == "1"

local FARMER_QUEUE_INDEX = tonumber(params.farmer_queue_index) or 1
local FARMER_QUEUE_TOTAL = tonumber(params.farmer_queue_total) or 1
local QUEUE_STAGGER_SECONDS = tonumber(params.queue_stagger_seconds) or 5

local JOIN_FAIL_BAN_THRESHOLD = tonumber(params.join_fail_ban_threshold) or 10
local BAN_MIN_CREATURE_KINDS = tonumber(params.ban_min_creature_kinds) or 10

local RANGES = params.ranges or {}
local PRIORITY_TOKENS = params.priority_tokens or {}
local FALLBACK_MODE = params.fallback_mode or params.fallback_non_priority_mode or "sell_all_when_priority_empty"
local SELL_IDLE_ROTATE = tonumber(params.sell_idle_rotate_seconds) or 3600
local ANTI_AFK_INTERVAL = tonumber(params.anti_afk_interval_seconds) or 300
local SELL_PHASE_SWITCH_AFTER = tonumber(params.sell_priority_phase_switch_after) or 4

local BOUND_FARMERS = params.bound_farmers or {}
local TRADE_SESSION_MODE = params.trade_session_mode or "overload"

local RESPONSE_FILE = params.response_file or nil
local REQUEST_FILE = params.request_file or nil

-- Счётчики (антиспам трейд / эвристика бана)
local joinOrTradeFailStreak = 0

-- ========== УТИЛИТЫ ==========

local function log(msg)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    print("[" .. timestamp .. "] [" .. ROLE .. "] [" .. COMMAND .. "] " .. msg)
end

local function writeResponse(data)
    local response = HttpService:JSONEncode(data)
    log("Response: " .. response)
    
    -- Если указан файл ответа - пишем туда (для файлового моста)
    if RESPONSE_FILE then
        local writer = nil
        if type(writefile) == "function" then
            writer = writefile
        elseif type(syn) == "table" and type(syn.writefile) == "function" then
            writer = syn.writefile
        end
        if type(writer) == "function" then
            local success, err = pcall(function()
                writer(RESPONSE_FILE, response)
            end)
            if not success then
                log("ERROR writing response file: " .. tostring(err))
            end
        else
            log("WARN: response_file задан, но нет writefile/syn.writefile (IPC в injector.exe может не получить ответ)")
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
            return false
        end
        RunService.Heartbeat:Wait()
    end
    return true
end

local function tokenKindSet()
    local s = {}
    for _, n in ipairs(TOKEN_KINDS) do
        s[n] = true
    end
    return s
end

local function countNonTokenCreatureKinds(inv)
    local tk = tokenKindSet()
    local kinds = 0
    for name, qty in pairs(inv) do
        if type(qty) == "number" and qty > 0 and not tk[name] then
            local isToken = name:find(" Token$") ~= nil
            if not isToken then
                kinds = kinds + 1
            end
        end
    end
    return kinds
end

local function recordAccessFailure()
    joinOrTradeFailStreak = joinOrTradeFailStreak + 1
end

local function recordAccessSuccess()
    joinOrTradeFailStreak = 0
end

local function banHeuristicResult(inv)
    if joinOrTradeFailStreak < JOIN_FAIL_BAN_THRESHOLD then
        return nil
    end
    if countNonTokenCreatureKinds(inv) >= BAN_MIN_CREATURE_KINDS then
        return {
            ok = false,
            account_status = "banned",
            reason = "join_or_trade_failures_with_diverse_creatures",
            log = "Heuristic ban: failures=" .. tostring(joinOrTradeFailStreak),
            inventory = inv,
        }
    end
    return nil
end

local function farmerQueueStagger()
    local delay = (FARMER_QUEUE_INDEX - 1) * QUEUE_STAGGER_SECONDS
    if delay > 0 then
        log("Очередь фермеров: индекс " .. FARMER_QUEUE_INDEX .. "/" .. FARMER_QUEUE_TOTAL .. ", ожидание " .. delay .. "s")
        wait(delay)
    end
end

-- До BATCH_SIZE каждого типа из TOKEN_KINDS в одном предложении (круг «все виды», не один вид пачкой).
local function buildRoundRobinOffer(inventory)
    local offer = {}
    for _, tokenName in ipairs(TOKEN_KINDS) do
        local have = inventory[tokenName]
        if type(have) == "number" and have > 0 then
            local n = math.min(BATCH_SIZE, have)
            table.insert(offer, { token = tokenName, amount = n })
        end
    end
    return offer
end

local function priorityTokensAllZero(inventory)
    for _, tokenName in ipairs(TOKEN_KINDS) do
        local v = inventory[tokenName]
        if type(v) == "number" and v > 0 then
            return false
        end
    end
    return true
end

local function boundFarmerNameSet()
    local s = {}
    for _, row in ipairs(BOUND_FARMERS) do
        if type(row) == "table" and row.login then
            s[string.lower(tostring(row.login))] = true
        end
    end
    return s
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
        local tradeService = ReplicatedStorage:FindFirstChild("TradeService")
            or ReplicatedStorage:FindFirstChild("Trade")
            or ReplicatedStorage:FindFirstChild("Trading")

        if tradeService then
            if tradeService:IsA("RemoteEvent") then
                tradeService:FireServer("request", targetPlayer, itemsToGive)
            elseif tradeService:IsA("RemoteFunction") then
                tradeService:InvokeServer("request", targetPlayer, itemsToGive)
            end

            wait(2)

            if tradeService:IsA("RemoteEvent") then
                tradeService:FireServer("confirm")
            elseif tradeService:IsA("RemoteFunction") then
                tradeService:InvokeServer("confirm")
            end

            wait(1)
            return true
        end

        local gui = player:WaitForChild("PlayerGui")
        local tradeGui = gui:FindFirstChild("TradeGui") or gui:FindFirstChild("Trading")

        if tradeGui then
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

-- Опрос «подтвердить» (заглушка: дополни под реальный GUI CoS).
local function pollTradeConfirmWindow(maxSeconds)
    local t0 = tick()
    maxSeconds = maxSeconds or 60
    while tick() - t0 < maxSeconds do
        if stopFlagExists() then
            return false
        end
        wait(TRADE_CONFIRM_POLL_SECONDS)
    end
    return true
end

local function tradeOfferOnce(targetPlayer, giveList, receiveList)
    if not sendTrade(targetPlayer, giveList, receiveList) then
        return false
    end
    return pollTradeConfirmWindow(45)
end

local function tradeWithRetries(targetPlayer, giveList, receiveList)
    while true do
        if stopFlagExists() then
            return false, "stopped"
        end
        if tradeOfferOnce(targetPlayer, giveList, receiveList) then
            recordAccessSuccess()
            return true
        end
        recordAccessFailure()
        log("Повтор трейда через " .. TRADE_RETRY_SECONDS .. "s")
        wait(TRADE_RETRY_SECONDS)
    end
end

local function doSuicideVolcano()
    log("Суицид в лаве (координаты — заглушка; замени под свой сервер / биом)")
    pcall(function()
        if character and character:FindFirstChild("HumanoidRootPart") then
            character.HumanoidRootPart.CFrame = CFrame.new(0, 20, 0)
        end
        if humanoid then
            humanoid.Health = 0
        end
    end)
    wait(3)
    character = player.Character or player.CharacterAdded:Wait()
    humanoid = character:WaitForChild("Humanoid")
end

local function ensureDefaultCreatureAfterRespawn()
    log("Перезапуск существа (выбор): " .. DEFAULT_CREATURE)
    selectCreature(DEFAULT_CREATURE)
    wait(2)
end

local function runFarmerStorageTransfer()
    if not TARGET_STORAGE_LOGIN then
        return { ok = false, error = "Нет target_storage_login / target_storage_username" }
    end

    farmerQueueStagger()

    local invCheck = getInventory()
    local ban = banHeuristicResult(invCheck)
    if ban then
        return ban
    end

    openTradeWorld()

    local rounds = 0
    while true do
        rounds = rounds + 1
        if stopFlagExists() then
            return { ok = true, log = "transfer stopped by flag", inventory = getInventory() }
        end

        local inv = getInventory()
        local ban2 = banHeuristicResult(inv)
        if ban2 then
            return ban2
        end

        if priorityTokensAllZero(inv) then
            return {
                ok = true,
                log = "Приоритетные токены = 0, передача завершена",
                inventory = inv,
                farmer_done = true,
            }
        end

        local offer = buildRoundRobinOffer(inv)
        if #offer == 0 then
            wait(2)
        else
            local storagePlr = findPlayerByName(TARGET_STORAGE_LOGIN)
            if not storagePlr then
                log("Склад не в сессии, ждём...")
                recordAccessFailure()
                wait(TRADE_RETRY_SECONDS)
            else
                local recv = { { token = "Mushroom", amount = STORAGE_GIVES } }
                local okT = tradeWithRetries(storagePlr, offer, recv)
                if okT then
                    log("Кулдаун после успешного трейда: " .. COOLDOWN_SECONDS .. "s")
                    wait(COOLDOWN_SECONDS)
                end
            end
        end

        if rounds > 100000 then
            return { ok = false, error = "transfer safety break", inventory = getInventory() }
        end
    end
end

local function openTradeWorld()
    log("Opening trade world...")
    local success = pcall(function()
        local portal = workspace:FindFirstChild("TradePortal")
            or workspace:FindFirstChild("TradingPortal")

        if portal then
            if character and character:FindFirstChild("HumanoidRootPart") then
                character.HumanoidRootPart.CFrame = portal.CFrame + Vector3.new(0, 5, 0)
                wait(2)
            end
        end

        local joinTrade = ReplicatedStorage:FindFirstChild("JoinTradeWorld")
        if joinTrade then
            joinTrade:FireServer()
            wait(5)
        end
    end)

    if success then
        recordAccessSuccess()
    else
        recordAccessFailure()
    end
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
    log("FARM pipeline=" .. tostring(FARM_PIPELINE) .. " target_dp=" .. tostring(TARGET_DP))

    if not character or not humanoid or humanoid.Health <= 0 then
        character = player.Character or player.CharacterAdded:Wait()
        humanoid = character:WaitForChild("Humanoid")
    end

    log("Стартовое существо: " .. DEFAULT_CREATURE)
    selectCreature(DEFAULT_CREATURE)
    wait(3)

    local cycles = 0
    
    while true do
        cycles = cycles + 1
        log("Farm cycle #" .. cycles)
        
        -- Проверяем флаг остановки
        if stopFlagExists() then
            return {
                ok = true,
                log = "Farm stopped by flag after " .. cycles .. " cycles",
                inventory = getInventory(),
            }
        end

        local invBan = getInventory()
        local b = banHeuristicResult(invBan)
        if b then
            return b
        end

        local currentDP = getCurrentDeathPoints()
        log("DP: " .. currentDP .. " / " .. TARGET_DP)

        if currentDP >= TARGET_DP then
            log("Цель DP достигнута")
            if VOLCANO_SUICIDE then
                doSuicideVolcano()
            else
                doSuicide()
            end

            if FARM_PIPELINE == "missions_dp_then_transfer" and TARGET_STORAGE_LOGIN then
                log("Фаза передачи токенов на склад")
                return runFarmerStorageTransfer()
            end

            if params.stop_after_suicide then
                return {
                    ok = true,
                    log = "DP достигнут, суицид, стоп",
                    death_points_current = 0,
                    inventory = getInventory(),
                }
            end

            wait(2)
        else
            doMissionStep()
            wait(1)
        end

        if humanoid.Health <= 0 then
            log("Респавн — перезапуск существа")
            character = player.Character or player.CharacterAdded:Wait()
            humanoid = character:WaitForChild("Humanoid")
            ensureDefaultCreatureAfterRespawn()
            wait(2)
        end

        if not wait(0.5) then
            return { ok = true, log = "Farm interrupted by stop flag", inventory = getInventory() }
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

    local assetPath = params.dex_asset_path or params.dex_model_path or "Dex_roblox.rbxmx"
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
    log("TRANSFER → склад (ROUND_ROBIN, до " .. BATCH_SIZE .. " на тип за раунд)")
    return runFarmerStorageTransfer()
end

handlers.receive = function()
    log("RECEIVE session=" .. tostring(TRADE_SESSION_MODE))
    if ROLE ~= "storage" then
        return { ok = false, error = "receive только для role=storage" }
    end
    log("bound_farmers: " .. HttpService:JSONEncode(BOUND_FARMERS))
    log("TODO: входящий трейд → whitelist → принять → 1 гриб → подтвердить после фермера")
    return {
        ok = true,
        log = "receive stub — допиши TradeGui под CoS",
        bound_farmers = BOUND_FARMERS,
    }
end

-- ПРОДАЖА (склад): приоритет — первые N токенов из списка контроллера, затем остальные; таймеры idle / anti-afk
handlers.sell = function()
    log("SELL mode trade_session=" .. tostring(TRADE_SESSION_MODE) .. " bound_farmers=" .. tostring(#BOUND_FARMERS))

    openTradeWorld()
    log("Случайная стойка: выбери видимый слот в GUI (TODO: placeStand под CoS)")
    placeStand()

    local inventory = getInventory()
    local lastAntiAfk = tick()
    local idleNoSaleStart = nil
    local usePhase2 = false

    local function phase1Exhausted(inv)
        local lim = math.min(SELL_PHASE_SWITCH_AFTER, #PRIORITY_TOKENS)
        for i = 1, lim do
            local t = PRIORITY_TOKENS[i]
            if (inv[t] or 0) > 0 then
                return false
            end
        end
        return lim > 0
    end

    local function prioritySlice(phase2)
        local out = {}
        if not phase2 then
            local lim = math.min(SELL_PHASE_SWITCH_AFTER, #PRIORITY_TOKENS)
            for i = 1, lim do
                table.insert(out, PRIORITY_TOKENS[i])
            end
        else
            for i = SELL_PHASE_SWITCH_AFTER + 1, #PRIORITY_TOKENS do
                table.insert(out, PRIORITY_TOKENS[i])
            end
        end
        return out
    end
    
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
    
    local sold = 0
    local cycles = 0

    while cycles < 10000 do
        cycles = cycles + 1
        if stopFlagExists() then
            break
        end

        inventory = getInventory()
        if phase1Exhausted(inventory) then
            usePhase2 = true
        end

        if tick() - lastAntiAfk >= ANTI_AFK_INTERVAL then
            lastAntiAfk = tick()
            log("anti-afk: лёгкое движение (дополни под CoS)")
        end

        local anySold = false
        local slice = prioritySlice(usePhase2)
        for _, token in ipairs(slice) do
            if trySellToken(token) then
                anySold = true
                sold = sold + 1
                idleNoSaleStart = nil
                wait(0.5)
            end
        end

        if not anySold and FALLBACK_MODE == "sell_all_when_priority_empty" then
            for token, count in pairs(inventory) do
                if count > 0 and not table.find(PRIORITY_TOKENS, token) then
                    if trySellToken(token) then
                        anySold = true
                        sold = sold + 1
                        idleNoSaleStart = nil
                        wait(0.5)
                        break
                    end
                end
            end
        end

        if not anySold then
            if idleNoSaleStart == nil then
                idleNoSaleStart = tick()
            elseif tick() - idleNoSaleStart >= SELL_IDLE_ROTATE then
                log("Нет продаж " .. SELL_IDLE_ROTATE .. "s — смена сервера (TODO: TeleportService)")
                break
            end
            log("Нет продаж в этом цикле, ждём...")
        end

        if not anySold and prioritySlice(false)[1] == nil and prioritySlice(true)[1] == nil then
            log("Список приоритетов пуст в конфиге — выход")
            break
        end

        wait(1)
    end

    return {
        ok = true,
        log = "Sold " .. sold .. " items (sell loop)",
        inventory = getInventory(),
    }
end

-- ========== ГЛАВНЫЙ ОБРАБОТЧИК ==========

local function main()
    log("=== UNIVERSAL SONARIA BOT STARTED ===")
    log("Account: " .. ACCOUNT_LOGIN .. " (" .. ACCOUNT_ID .. ")")
    log("Role: " .. ROLE)
    log("Command: " .. COMMAND)
    
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

    if ROLE == "storage" and COMMAND == "transfer" then
        return writeResponse({
            ok = false,
            error = "Склад не шлёт трейд первым — команда receive"
        })
    end

    if ROLE == "farmer" and COMMAND == "receive" then
        return writeResponse({
            ok = false,
            error = "receive только для склада"
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