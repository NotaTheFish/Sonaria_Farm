-- sonaria_farm: embedded task params (see INJECTOR_UNIVERSAL_EMBED_PARAMS)
rawset(_G, '__SONARIA_PARAMS_JSON', [[{"role":"farmer","command":"farm","account_id":"80886f91-c561-426a-a478-37942ad398f2","account_login":"Ezra_Byte201693","account_password":null,"stop_flag_path":"C:\\sonaria_farm\\runtime\\stop_flags\\80886f91-c561-426a-a478-37942ad398f2.stop","death_points_target":600,"loop":true,"batch_size":150,"cooldown_seconds":70,"post_trade_cooldown_seconds":70,"trade_retry_seconds":10,"trade_confirm_poll_seconds":2,"storage_gives":1,"transfer_token_priority":["Revive Token","Max Growth Token","Partial Growth Token","Random Trial Creature Token","Appearance Change Token","Death Gacha Token"],"token_kinds":["Revive Token","Max Growth Token","Partial Growth Token","Random Trial Creature Token","Appearance Change Token","Death Gacha Token"],"transfer_mode":"ROUND_ROBIN_MULTI_TYPE_BATCH","farmer_queue_index":1,"farmer_queue_total":1,"queue_stagger_seconds":5,"default_creature_name":"Kaluaka","volcano_suicide":true,"join_fail_ban_threshold":10,"ban_min_creature_kinds":10,"sell_idle_rotate_seconds":3600,"anti_afk_interval_seconds":300,"sell_priority_phase_switch_after":4,"dex_asset_path":"Dex_roblox.rbxmx","farm_pipeline":"missions_dp_only","target_dp":600,"tick_seq":1}]])
-- universal_sonaria_bot.lua
-- Универсальный скрипт Creatures of Sonaria + контракт с контроллером (JSON в первом аргументе).
-- Параметры задаёт Python (payload задач UNIVERSAL_FARM / UNIVERSAL_TRANSFER / UNIVERSAL_SELL).
-- Dex: положи Dex_roblox.rbxmx в рабочую папку эксплойта или задай dex_asset_path.
-- Снимки плейсов (Remotes/GUI): external/sonaria_data/*.rbxl — бинарные, смотри README там и Studio.

-- До любых GetService: иначе при сбое загрузки сервисов не видно, что чанк вообще выполнился.
print("[universal_sonaria] bootstrap t0 (before GetService)")
warn("[universal_sonaria] bootstrap t0 (warn, before GetService)")

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
print("[universal_sonaria] bootstrap services ok")

-- ========== ПАРСИНГ ПАРАМЕТРОВ ==========
-- Часть инжекторов вызывает чанк как loadstring(src)() **без** JSON в ``...`` — тогда
-- воркер встраивает JSON в начало файла через rawset(_G, "__SONARIA_PARAMS_JSON", ...).
local args = {...}
local params_json = args[1]
if params_json == nil or params_json == "" then
    params_json = rawget(_G, "__SONARIA_PARAMS_JSON")
end

local params = {}
if type(params_json) == "string" and params_json ~= "" then
    local success, decoded = pcall(function()
        return HttpService:JSONDecode(params_json)
    end)
    if success then
        params = decoded
        rawset(_G, "__SONARIA_PARAMS_JSON", nil)
    else
        print("ERROR: Failed to decode params: " .. tostring(decoded))
        return
    end
else
    warn(
        "[universal_sonaria] нет JSON параметров (ни ..., ни _G.__SONARIA_PARAMS_JSON). "
            .. "Обнови воркер: нужен materialize universal script (INJECTOR_UNIVERSAL_EMBED_PARAMS=1) "
            .. "или инжектор с передачей JSON первым аргументом чанка."
    )
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
local VOLCANO_X = tonumber(params.volcano_x) or 1973
local VOLCANO_Y = tonumber(params.volcano_y) or 238
local VOLCANO_Z = tonumber(params.volcano_z) or 1616

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
-- Только токены из priority_tokens (без «все остальные» при пустой фазе).
local SELL_ONLY_PRIORITY = params.sell_only_priority_tokens ~= false

local BOUND_FARMERS = params.bound_farmers or {}
local TRADE_SESSION_MODE = params.trade_session_mode or "overload"

-- Trade Realm (из CoS .rbxlx: live 14119723130, test trade 14217217395)
local TRADE_REALM_PLACE_ID = tonumber(params.trade_realm_place_id) or 14119723130
local TRADE_REALM_PLACE_ID_TEST = tonumber(params.trade_realm_place_id_test) or 14217217395

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
if not player then
    local t0 = tick()
    while not player and tick() - t0 < 30 do
        RunService.Heartbeat:Wait()
        player = Players.LocalPlayer
    end
end
if not player then
    warn("[universal_sonaria] LocalPlayer is nil after 30s; abort")
    return
end
-- Нельзя ждать Character при загрузке модуля: на экране слотов персонажа нет — скрипт зависал
-- до handlers.farm, и клики по Play никогда не выполнялись.
local character = player.Character
local humanoid = character and character:FindFirstChildOfClass("Humanoid")

local function refreshCharacterRefs()
    character = player.Character
    humanoid = character and character:FindFirstChildOfClass("Humanoid")
end

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

-- Anti-spam для экрана слотов: меньше кликов/логов и предсказуемая нагрузка.
local PLAY_CLICK_INTERVAL = tonumber(params.play_click_interval_seconds) or 0.7
local PLAY_LOG_INTERVAL = math.max(tonumber(params.play_log_interval_seconds) or 3, 2)
local PLAY_CLICK_MAX_ATTEMPTS = tonumber(params.play_click_max_attempts) or 180
local _playUiLastLogAt = 0
local _playUiLastMsg = ""
local _playUiSuppressed = 0
local _playUiSlotMissLastAt = 0
local _playUiSlotDumpLastAt = 0
local _playUiVerbose = tostring(params.play_ui_verbose or "0") == "1"
local _playUiImportantByKey = {}
local _slotFoundLoggedOnce = false

local function playUiLog(msg)
    if not _playUiVerbose then
        return
    end
    local now = tick()
    if msg == _playUiLastMsg and now - _playUiLastLogAt < PLAY_LOG_INTERVAL then
        _playUiSuppressed = _playUiSuppressed + 1
        return
    end
    if now - _playUiLastLogAt >= PLAY_LOG_INTERVAL or msg ~= _playUiLastMsg then
        _playUiLastLogAt = now
        if _playUiSuppressed > 0 and _playUiLastMsg ~= "" and msg ~= _playUiLastMsg then
            log(_playUiLastMsg .. " (x" .. tostring(_playUiSuppressed + 1) .. ")")
            _playUiSuppressed = 0
        end
        _playUiLastMsg = msg
        log(msg)
    end
end

-- CoS: экран слотов — CreatureInventoryGui, зелёная кнопка PlayButton (см. .rbxlx).
local function tryClickCreaturePlayButton(creatureName)
    local pg = player:FindFirstChild("PlayerGui")
    if not pg then
        return false
    end
    creatureName = type(creatureName) == "string" and string.lower(creatureName) or ""

    local function playUiImportant(msg)
        local now = tick()
        local key = msg
        local interval = 6
        local lastAt = _playUiImportantByKey[key] or 0
        if now - lastAt >= interval then
            _playUiImportantByKey[key] = now
            log(msg)
        end
    end

    local function clickGui(gui, label)
        if not gui or not gui:IsA("GuiObject") or not gui.Visible then
            return false
        end
        local pos = gui.AbsolutePosition + (gui.AbsoluteSize / 2)
        local inset = GuiService:GetGuiInset()
        local x, y = pos.X, pos.Y + inset.Y
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
        wait(0.08)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
        playUiLog((label or "GUI click") .. ": " .. gui:GetFullName() .. " screen=(" .. tostring(x) .. "," .. tostring(y) .. ")")
        return true
    end

    local function findSlotsFrame()
        local best = nil
        local bestArea = -1
        for _, d in ipairs(pg:GetDescendants()) do
            if
                d:IsA("GuiObject")
                and d.Visible
                and (d.Name == "SlotsFrame" or d.Name == "AllSlotsFrame")
                and d.AbsoluteSize.X > 100
                and d.AbsoluteSize.Y > 100
            then
                local area = d.AbsoluteSize.X * d.AbsoluteSize.Y
                if area > bestArea then
                    bestArea = area
                    best = d
                end
            end
        end
        return best
    end

    local function containsLower(hay, needle)
        return needle ~= "" and hay ~= "" and string.find(hay, needle, 1, true) ~= nil
    end

    local function findNameNode(slotsFrame, creatureLower)
        if creatureLower == "" then
            return nil
        end
        local roots = {}
        if slotsFrame then
            roots[1] = slotsFrame
        else
            roots[1] = pg
        end
        for _, root in ipairs(roots) do
            for _, node in ipairs(root:GetDescendants()) do
                if node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then
                    local txt = string.lower(tostring(node.Text or ""))
                    if containsLower(txt, creatureLower) then
                        return node
                    end
                end
            end
        end
        return nil
    end

    local function findNameNodeNearPlayButton(creatureLower)
        if creatureLower == "" then
            return nil
        end
        for _, node in ipairs(pg:GetDescendants()) do
            if node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then
                local txt = string.lower(tostring(node.Text or ""))
                if containsLower(txt, creatureLower) then
                    local p = node
                    for _ = 1, 16 do
                        if not p then
                            break
                        end
                        if p:IsA("GuiObject") then
                            for _, q in ipairs(p:GetDescendants()) do
                                if q:IsA("GuiButton") and q.Visible and q.Active ~= false then
                                    local nm = string.lower(tostring(q.Name or ""))
                                    if nm == "playbutton" or containsLower(nm, "play") then
                                        return node
                                    end
                                end
                            end
                        end
                        p = p.Parent
                    end
                end
            end
        end
        return nil
    end

    local function findSlotCard(node, slotsFrame)
        local p = node
        for _ = 1, 20 do
            if not p or p == slotsFrame or not p.Parent then
                break
            end
            if p:IsA("GuiObject") and p.Parent == slotsFrame then
                return p
            end
            if p:IsA("GuiObject") and (p.Name == "Default" or p.Name == "CreatureFrame") then
                return p
            end
            p = p.Parent
        end
        return nil
    end

    local function findPlayButtons()
        local out = {}
        for _, d in ipairs(pg:GetDescendants()) do
            local nm = string.lower(tostring(d.Name or ""))
            local tx = ""
            if d:IsA("TextButton") then
                tx = string.lower(tostring(d.Text or ""))
            end
            if
                d:IsA("GuiButton")
                and d.Visible
                and d.Active ~= false
                and d.AbsoluteSize.X > 2
                and d.AbsoluteSize.Y > 2
                and (nm == "playbutton" or containsLower(nm, "play") or tx == "play")
            then
                table.insert(out, d)
            end
        end
        return out
    end

    local function findButtonNearNode(node, buttons)
        if not node then
            return nil
        end
        local center = node.AbsolutePosition + (node.AbsoluteSize / 2)
        local best = nil
        local bestDist = math.huge
        for _, btn in ipairs(buttons) do
            local bcenter = btn.AbsolutePosition + (btn.AbsoluteSize / 2)
            local dx = bcenter.X - center.X
            local dy = bcenter.Y - center.Y
            local dist = (dx * dx) + (dy * dy)
            if dist < bestDist then
                bestDist = dist
                best = btn
            end
        end
        return best
    end

    local function buttonHasToken(btn, token)
        if not btn or not btn:IsA("GuiButton") then
            return false
        end
        local nm = string.lower(tostring(btn.Name or ""))
        local tx = ""
        if btn:IsA("TextButton") then
            tx = string.lower(tostring(btn.Text or ""))
        end
        return containsLower(nm, token) or containsLower(tx, token)
    end

    local function findButtonsByToken(token)
        local out = {}
        for _, d in ipairs(pg:GetDescendants()) do
            if
                d:IsA("GuiButton")
                and d.Visible
                and d.Active ~= false
                and d.AbsoluteSize.X > 2
                and d.AbsoluteSize.Y > 2
                and buttonHasToken(d, token)
            then
                table.insert(out, d)
            end
        end
        return out
    end

    local function findRestartButtonIn(root)
        if not root or type(root.GetDescendants) ~= "function" then
            return nil
        end
        for _, q in ipairs(root:GetDescendants()) do
            if
                q:IsA("GuiButton")
                and q.Visible
                and q.Active ~= false
                and q.AbsoluteSize.X > 2
                and q.AbsoluteSize.Y > 2
                and buttonHasToken(q, "restart")
            then
                return q
            end
        end
        return nil
    end

    local function findConfirmRestartButton(slotRestartButton)
        local all = findButtonsByToken("restart")
        if #all == 0 then
            return nil
        end
        local screenCenter = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize / 2 or Vector2.new(960, 540)
        local best = nil
        local bestScore = -math.huge
        for _, btn in ipairs(all) do
            if btn ~= slotRestartButton then
                local z = tonumber(btn.ZIndex) or 0
                local c = btn.AbsolutePosition + (btn.AbsoluteSize / 2)
                local dx = c.X - screenCenter.X
                local dy = c.Y - screenCenter.Y
                local dist = math.sqrt(dx * dx + dy * dy)
                local score = z * 1000 - dist
                if score > bestScore then
                    bestScore = score
                    best = btn
                end
            end
        end
        return best
    end

    local function tryHandleDeadCreature(nodeHint, slotCardHint)
        -- DEAD-слот: Restart на карточке существа, затем Restart в модалке подтверждения.
        local slotRestart = nil
        if slotCardHint then
            slotRestart = findRestartButtonIn(slotCardHint)
        end
        if not slotRestart and nodeHint and nodeHint.Parent then
            slotRestart = findRestartButtonIn(nodeHint.Parent)
        end
        if not slotRestart and nodeHint then
            local all = findButtonsByToken("restart")
            slotRestart = findButtonNearNode(nodeHint, all)
        end
        if not slotRestart then
            return false
        end

        local clicked = false
        for _ = 1, 3 do
            if clickGui(slotRestart, "Dead creature restart (slot)") then
                clicked = true
                wait(0.12)
            end
        end
        if not clicked then
            return false
        end

        wait(0.25)
        local confirmRestart = findConfirmRestartButton(slotRestart)
        if confirmRestart then
            clickGui(confirmRestart, "Dead creature restart (confirm)")
            wait(0.08)
            clickGui(confirmRestart, "Dead creature restart (confirm2)")
            playUiImportant("DEAD creature: restart confirmed")
            return true
        end
        playUiImportant("DEAD creature: restart clicked (confirm not found)")
        return true
    end

    local selectedNode = nil
    local selectedCard = nil
    if creatureName ~= "" then
        local slotsFrame = findSlotsFrame()
        local nameNode = findNameNode(slotsFrame, creatureName)
        if not nameNode then
            nameNode = findNameNodeNearPlayButton(creatureName)
        end
        if nameNode then
            selectedNode = nameNode
            local slotCard = findSlotCard(nameNode, slotsFrame)
            selectedCard = slotCard
            clickGui(nameNode, "Creature slot select (name)")
            if slotCard then
                wait(0.05)
                clickGui(slotCard, "Creature slot select (card)")
                local inner = slotCard:FindFirstChild("InnerFrame")
                if inner and inner:IsA("GuiObject") then
                    wait(0.05)
                    clickGui(inner, "Creature slot select (inner)")
                end
            end
            if not _slotFoundLoggedOnce then
                _slotFoundLoggedOnce = true
                log("Слот существа найден и выбран: " .. tostring(creatureName))
            end
        else
            local now = tick()
            if now - _playUiSlotMissLastAt >= 20 then
                _playUiSlotMissLastAt = now
                playUiImportant("PlayButton: слот «" .. tostring(creatureName) .. "» не найден")
            end
        end
        wait(0.1)
    end

    for _ = 1, 4 do
        local candidates = findPlayButtons()
        if #candidates > 0 then
            local btn = nil
            if selectedNode then
                btn = findButtonNearNode(selectedNode, candidates)
            end
            if not btn then
                btn = candidates[1]
            end
            return clickGui(btn, "PlayButton click")
        end
        wait(0.08)
    end

    if creatureName ~= "" then
        if tryHandleDeadCreature(selectedNode, selectedCard) then
            return true
        end
    end

    return false
end

local function selectCreature(creatureName)
    -- Не спамим этим в каждом тике: лог только при фактическом клике/ошибке.
    
    local success, selected = pcall(function()
        local spawnEvent = ReplicatedStorage:FindFirstChild("SpawnCreature")
        if spawnEvent and spawnEvent:IsA("RemoteEvent") then
            spawnEvent:FireServer(creatureName)
        end

        local gui = player:WaitForChild("PlayerGui")
        local creatureSelect = gui:FindFirstChild("CreatureInventoryGui")
            or gui:FindFirstChild("CreatureSelect")
            or gui:FindFirstChild("SpawnGui")
            or gui:FindFirstChild("CharacterSelect")
            or gui:FindFirstChild("CreatureSelection")
        
        if creatureSelect then
            for _, btn in pairs(creatureSelect:GetDescendants()) do
                if btn:IsA("TextButton") or btn:IsA("ImageButton") then
                    local btnText = (btn.Text or "") .. btn.Name
                    if string.find(string.lower(btnText), string.lower(creatureName), 1, true) then
                        local pos = btn.AbsolutePosition + (btn.AbsoluteSize / 2)
                        local inset = GuiService:GetGuiInset()
                        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y + inset.Y, 0, true, game, 0)
                        wait(0.1)
                        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y + inset.Y, 0, false, game, 0)
                        playUiLog("Clicked creature UI: " .. btn.Name)
                        wait(0.5)
                        return true
                    end
                end
            end
        end

        return false
    end)
    
    if not success then
        return false
    end
    return selected == true
end

-- Цикл «Play» + выбор слота, пока не появится Character (вход в мир).
local function tryEnterWorldFromSlotUi(maxSeconds, creatureName)
    maxSeconds = maxSeconds or 120
    creatureName = creatureName or DEFAULT_CREATURE
    local t0 = tick()
    local nextAttemptAt = 0
    local attempts = 0
    while tick() - t0 < maxSeconds do
        if stopFlagExists() then
            return false
        end
        refreshCharacterRefs()
        if character then
            log("Персонаж загружен после экрана слотов")
            return true
        end
        local now = tick()
        if now >= nextAttemptAt then
            attempts = attempts + 1
            if attempts > PLAY_CLICK_MAX_ATTEMPTS then
                log("Play loop: слишком много попыток (" .. tostring(attempts) .. "), выходим")
                return false
            end
            tryClickCreaturePlayButton(creatureName)
            selectCreature(creatureName)
            tryClickCreaturePlayButton(creatureName)
            nextAttemptAt = now + PLAY_CLICK_INTERVAL
        end
        RunService.Heartbeat:Wait()
    end
    return false
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

        local gui = player:FindFirstChild("PlayerGui")
        if gui then
            local tGui = tick()
            while tick() - tGui < 25 do
                local tradeGui = gui:FindFirstChild("TradeGui") or gui:FindFirstChild("Trading")
                if tradeGui and (tradeGui:FindFirstChild("ContainerFrame") or tradeGui:FindFirstChild("AcceptButton", true)) then
                    return true
                end
                wait(0.5)
            end
        end

        return false
    end)

    if not success then
        log("ERROR in sendTrade: " .. tostring(err))
        return false
    end

    return true
end

local function tradeOfferOnce(targetPlayer, giveList, receiveList)
    if not sendTrade(targetPlayer, giveList, receiveList) then
        return false
    end
    local rf = select(1, getTradeRemoteForOther(targetPlayer))
    if rf and type(giveList) == "table" and #giveList > 0 then
        tryAddTradeItemsViaRemote(rf, giveList)
    end
    return pollTradeConfirmWindow(45, targetPlayer)
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
    log("Суицид в лаве: " .. tostring(VOLCANO_X) .. "," .. tostring(VOLCANO_Y) .. "," .. tostring(VOLCANO_Z))
    pcall(function()
        if character and character:FindFirstChild("HumanoidRootPart") then
            character.HumanoidRootPart.CFrame = CFrame.new(VOLCANO_X, VOLCANO_Y, VOLCANO_Z)
            wait(1.5)
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
    tryClickCreaturePlayButton(DEFAULT_CREATURE)
    selectCreature(DEFAULT_CREATURE)
    tryClickCreaturePlayButton(DEFAULT_CREATURE)
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

local function requireSonar()
    local mod = ReplicatedStorage:FindFirstChild("Sonar")
    if not mod then
        return nil
    end
    local ok, fn = pcall(function()
        return require(mod)
    end)
    if ok then
        return fn
    end
    return nil
end

local function alreadyInTradeRealm()
    if game.PlaceId == TRADE_REALM_PLACE_ID or game.PlaceId == TRADE_REALM_PLACE_ID_TEST then
        return true
    end
    local sonar = requireSonar()
    if sonar then
        local ok, constants = pcall(function()
            return sonar("Constants")
        end)
        if ok and constants and constants.IsTradeRealm then
            return true
        end
    end
    return false
end

-- По снимкам CoS (.rbxlx): PlaceTeleportService → TeleportToRemote("ToPlaceType","Trade",{}) или ToPlaceId.
local function tryCoSTeleportToTradeRealm()
    local sonar = requireSonar()
    if not sonar then
        return false, "no Sonar module"
    end
    local ru = sonar("RemoteUtils")
    if not ru or type(ru.GetRemoteFunction) ~= "function" then
        return false, "no RemoteUtils"
    end
    local rf = ru.GetRemoteFunction("TeleportToRemote")
    if not rf or type(rf.InvokeServer) ~= "function" then
        return false, "no TeleportToRemote"
    end
    local ok, a, b = pcall(function()
        return rf:InvokeServer("ToPlaceType", "Trade", {})
    end)
    if not ok then
        return false, tostring(a)
    end
    if a == false then
        ok, a, b = pcall(function()
            return rf:InvokeServer("ToPlaceId", TRADE_REALM_PLACE_ID, {})
        end)
        if not ok then
            return false, tostring(a)
        end
        if a == false then
            return false, tostring(b)
        end
    end
    wait(3)
    return true, nil
end

-- CoS: парный TradeRemote «Name1-Name2TradeRemote» + TradeGui (см. .rbxlx)
local function getRemoteUtilsFromSonar()
    local s = requireSonar()
    if not s then
        return nil
    end
    local ok, ru = pcall(function()
        return s("RemoteUtils")
    end)
    if ok then
        return ru
    end
    return nil
end

local function getCoSRemoteEvent(name)
    local ru = getRemoteUtilsFromSonar()
    if not ru or type(ru.GetRemoteEvent) ~= "function" then
        return nil
    end
    local ok, re = pcall(function()
        return ru.GetRemoteEvent(name)
    end)
    if ok and re and typeof(re) == "Instance" then
        return re
    end
    return nil
end

local function getTradeRemoteForPairNames(localName, otherName)
    if not localName or not otherName then
        return nil
    end
    local ru = getRemoteUtilsFromSonar()
    if not ru or type(ru.GetRemoteFunction) ~= "function" then
        return nil
    end
    local variants = {
        localName .. "-" .. otherName .. "TradeRemote",
        otherName .. "-" .. localName .. "TradeRemote",
    }
    for _, nm in ipairs(variants) do
        local ok, rf = pcall(function()
            return ru.GetRemoteFunction(nm)
        end)
        if ok and rf and typeof(rf) == "Instance" then
            return rf, nm
        end
    end
    return nil
end

local function getTradeRemoteForOther(otherPlayer)
    if not otherPlayer then
        return nil
    end
    return getTradeRemoteForPairNames(player.Name, otherPlayer.Name)
end

local function tradeRemoteInvoke(rf, action)
    if not rf then
        return false, "no remote"
    end
    local ok, a = pcall(function()
        return rf:InvokeServer(action)
    end)
    if not ok then
        return false, tostring(a)
    end
    return true, a
end

-- CoS TradeRemote: AddTradeItem с полем Overwrite (см. PlayerGui TradeGui в Trade Realm.rbxlx).
local function tradeAddItemPayloadFromRow(row)
    if type(row) ~= "table" then
        return nil
    end
    local token = row.token
    local amount = tonumber(row.amount) or 1
    if type(token) ~= "string" or token == "" then
        return nil
    end
    amount = math.max(1, math.floor(amount))
    if string.lower(token) == "mushroom" then
        return { ItemType = "Currency", Name = "Mushroom", Amount = amount, Overwrite = true }
    end
    return { ItemType = "Tokens", Name = token, Amount = amount, Overwrite = true }
end

local function tryAddTradeItemsViaRemote(rf, giveRows)
    if not rf or type(giveRows) ~= "table" then
        return false
    end
    local anyOk = false
    for _, row in ipairs(giveRows) do
        local payload = tradeAddItemPayloadFromRow(row)
        if payload then
            local ok, res = pcall(function()
                return rf:InvokeServer("AddTradeItem", payload)
            end)
            log(
                "AddTradeItem "
                    .. tostring(payload.ItemType)
                    .. "/"
                    .. tostring(payload.Name)
                    .. " x"
                    .. tostring(payload.Amount)
                    .. " pcall_ok="
                    .. tostring(ok)
                    .. " res="
                    .. tostring(res)
            )
            if ok and res then
                anyOk = true
            end
            wait(0.35)
        end
    end
    return anyOk
end

local function findTradeGuiRoot()
    local pg = player:FindFirstChild("PlayerGui")
    if not pg then
        return nil
    end
    local tg = pg:FindFirstChild("TradeGui")
    if not tg then
        return nil
    end
    return tg:FindFirstChild("ContainerFrame") or tg
end

local function readOpponentUsernameFromTradeGui(root)
    if not root then
        return nil
    end
    local theirs = root:FindFirstChild("Theirs", true)
    if not theirs then
        return nil
    end
    local tf = theirs:FindFirstChild("TradeFrame", true)
    if not tf then
        return nil
    end
    local disp = tf:FindFirstChild("DisplayNameLabel", true)
    if not disp then
        return nil
    end
    local ul = disp:FindFirstChild("UserNameLabel")
    if ul and ul:IsA("TextLabel") then
        local t = ul.Text
        if type(t) == "string" and #t > 0 and t:sub(1, 1) == "@" then
            return t:sub(2)
        end
        return t
    end
    return nil
end

local function findTradeAcceptButton(root)
    if not root then
        return nil
    end
    return root:FindFirstChild("AcceptButton", true)
end

-- Подтверждение: AcceptTrade через RemoteFunction, когда кнопка видима (CoS TradeGui).
local function pollTradeConfirmWindow(maxSeconds, otherPlayer)
    local t0 = tick()
    maxSeconds = maxSeconds or 60
    local fired = false
    while tick() - t0 < maxSeconds do
        if stopFlagExists() then
            return false
        end
        local guiRoot = findTradeGuiRoot()
        local acceptBtn = findTradeAcceptButton(guiRoot)
        local oppName = readOpponentUsernameFromTradeGui(guiRoot)
        local rf = nil
        if otherPlayer then
            rf = select(1, getTradeRemoteForOther(otherPlayer))
        end
        if not rf and oppName then
            rf = select(1, getTradeRemoteForPairNames(player.Name, oppName))
        end
        if rf and acceptBtn and acceptBtn.Visible and acceptBtn.Active ~= false then
            if not fired then
                fired = true
                local okInv, errInv = tradeRemoteInvoke(rf, "AcceptTrade")
                log("AcceptTrade: ok=" .. tostring(okInv) .. " " .. tostring(errInv or ""))
                wait(0.5)
                if okInv then
                    return true
                end
                fired = false
            end
        else
            fired = false
        end
        wait(TRADE_CONFIRM_POLL_SECONDS)
    end
    return false
end

local function openTradeWorld()
    log("Opening trade world...")

    if alreadyInTradeRealm() then
        log("Уже в Trade Realm (PlaceId=" .. tostring(game.PlaceId) .. ")")
        recordAccessSuccess()
        return true
    end

    local success = pcall(function()
        local okTeleport, errTeleport = tryCoSTeleportToTradeRealm()
        if okTeleport then
            return
        end
        log("CoS TeleportToRemote не сработал: " .. tostring(errTeleport) .. " — fallback портал/GUI")

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

local function playerOwnsMarketStallPart()
    local folder = workspace:FindFirstChild("MarketStalls", true)
    if not folder then
        return false
    end
    for _, inst in ipairs(folder:GetDescendants()) do
        if inst:IsA("BasePart") then
            local o = inst:GetAttribute("Owner")
            if o ~= nil and o ~= "" then
                local n = tonumber(o)
                if n and n == player.UserId then
                    return true
                end
                if tostring(o) == tostring(player.UserId) then
                    return true
                end
            end
        end
    end
    return false
end

local function findUnclaimedMarketStallRoot()
    local folder = workspace:FindFirstChild("MarketStalls", true)
    if not folder then
        return nil
    end
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    local best, bestD = nil, math.huge
    for _, inst in ipairs(folder:GetDescendants()) do
        if inst:IsA("BasePart") then
            local o = inst:GetAttribute("Owner")
            local free = o == nil or o == "" or o == 0
            if free and inst.Name ~= "Effect" then
                if hrp then
                    local d = (inst.Position - hrp.Position).Magnitude
                    if d < bestD then
                        bestD = d
                        best = inst
                    end
                else
                    return inst
                end
            end
        end
    end
    return best
end

-- Trade Realm: RemoteUtils GetRemoteEvent("ClaimStall") / ListStallItem (см. MarketStallGui .rbxlx).
local function tryClaimCoSMarketStall(maxTries)
    if playerOwnsMarketStallPart() then
        log("Market stall: уже есть стойка")
        return true
    end
    local re = getCoSRemoteEvent("ClaimStall")
    if not re then
        log("Market stall: нет Remote ClaimStall (не Trade Realm / нет Sonar)")
        return false
    end
    for t = 1, maxTries or 12 do
        if stopFlagExists() then
            return false
        end
        local root = findUnclaimedMarketStallRoot()
        if root then
            local ok = pcall(function()
                re:FireServer(root)
            end)
            log("ClaimStall FireServer ok=" .. tostring(ok) .. " part=" .. tostring(root))
            wait(1.5)
            if playerOwnsMarketStallPart() then
                return true
            end
        else
            log("Market stall: свободных стоек не найдено (попытка " .. t .. ")")
        end
        wait(0.6)
    end
    return playerOwnsMarketStallPart()
end

local function placeStand()
    log("Стойка Trade Realm (CoS ClaimStall + legacy)...")
    if tryClaimCoSMarketStall(12) then
        return true
    end
    local legacyOk = pcall(function()
        local gui = player:WaitForChild("PlayerGui")
        local tradeGui = gui:FindFirstChild("TradeGui") or gui:FindFirstChild("Trading")
        if tradeGui then
            local placeBtn = tradeGui:FindFirstChild("PlaceStand") or tradeGui:FindFirstChild("SetupStand")
            if placeBtn then
                local pos = placeBtn.AbsolutePosition + (placeBtn.AbsoluteSize / 2)
                VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
                wait(0.1)
                VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
                wait(2)
            end
        end
        local placeEvent = ReplicatedStorage:FindFirstChild("PlaceTradingStand")
        if placeEvent then
            placeEvent:FireServer()
            wait(2)
        end
    end)
    return legacyOk
end

local function sellItem(token, price)
    log("Selling " .. token .. " for " .. tostring(price))
    local reList = getCoSRemoteEvent("ListStallItem")
    if reList then
        local amt = 1
        local ok = pcall(function()
            reList:FireServer(token, amt, price)
        end)
        log("ListStallItem token=" .. tostring(token) .. " price=" .. tostring(price) .. " pcall_ok=" .. tostring(ok))
        if ok then
            wait(0.4)
            return true
        end
    end
    local success = pcall(function()
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
    log("Стартовое существо: " .. DEFAULT_CREATURE)

    if not tryEnterWorldFromSlotUi(120, DEFAULT_CREATURE) then
        refreshCharacterRefs()
        return {
            ok = false,
            error = "Не удалось войти в мир за 120s (нет Character). Проверь слот / кнопку Play или default_creature_name.",
            inventory = getInventory(),
        }
    end
    if not humanoid then
        humanoid = character:WaitForChild("Humanoid", 30)
    end
    if not humanoid then
        return { ok = false, error = "Character без Humanoid", inventory = getInventory() }
    end

    wait(0.5)

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
    log("Приём: whitelist → AddTradeItem (гриб x" .. tostring(STORAGE_GIVES) .. ") → AcceptTrade")
    openTradeWorld()

    local allowed = boundFarmerNameSet()
    local declined = 0
    local accepted = 0
    local iter = 0

    while true do
        iter = iter + 1
        if stopFlagExists() then
            return {
                ok = true,
                log = "receive stopped by flag",
                bound_farmers = BOUND_FARMERS,
                declined = declined,
                accepted = accepted,
            }
        end
        if iter > 100000 then
            return {
                ok = true,
                log = "receive loop safety break",
                bound_farmers = BOUND_FARMERS,
                declined = declined,
                accepted = accepted,
            }
        end

        if not alreadyInTradeRealm() then
            tryCoSTeleportToTradeRealm()
            wait(2)
        end

        local guiRoot = findTradeGuiRoot()
        local uname = readOpponentUsernameFromTradeGui(guiRoot)
        if guiRoot and uname then
            local low = string.lower(tostring(uname))
            local rf = select(1, getTradeRemoteForPairNames(player.Name, uname))
            if not rf then
                wait(TRADE_CONFIRM_POLL_SECONDS)
            elseif not allowed[low] then
                tradeRemoteInvoke(rf, "DeclineTrade")
                log("DeclineTrade: не whitelist @" .. tostring(uname))
                declined = declined + 1
                while findTradeGuiRoot() do
                    if stopFlagExists() then
                        return {
                            ok = true,
                            log = "receive stopped by flag",
                            bound_farmers = BOUND_FARMERS,
                            declined = declined,
                            accepted = accepted,
                        }
                    end
                    wait(0.5)
                end
            else
                local opp = findPlayerByName(uname)
                tryAddTradeItemsViaRemote(rf, { { token = "Mushroom", amount = STORAGE_GIVES } })
                if pollTradeConfirmWindow(120, opp) then
                    accepted = accepted + 1
                    while findTradeGuiRoot() do
                        if stopFlagExists() then
                            return {
                                ok = true,
                                log = "receive stopped by flag",
                                bound_farmers = BOUND_FARMERS,
                                declined = declined,
                                accepted = accepted,
                            }
                        end
                        wait(0.5)
                    end
                    wait(COOLDOWN_SECONDS)
                else
                    wait(TRADE_CONFIRM_POLL_SECONDS)
                end
            end
        else
            wait(TRADE_CONFIRM_POLL_SECONDS)
        end
    end
end

-- ПРОДАЖА (склад): приоритет — первые N токенов из списка контроллера, затем остальные; таймеры idle / anti-afk
handlers.sell = function()
    log("SELL mode trade_session=" .. tostring(TRADE_SESSION_MODE) .. " bound_farmers=" .. tostring(#BOUND_FARMERS))

    openTradeWorld()
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

        if not anySold and FALLBACK_MODE == "sell_all_when_priority_empty" and not SELL_ONLY_PRIORITY then
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