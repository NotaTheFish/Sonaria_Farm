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
local VOLCANO_SUICIDE = params.volcano_suicide == true or params.volcano_suicide == "1" or params.volcano_suicide == "true"
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
local TOKEN_REPORT_FILE = params.token_report_file or nil

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

local function writeTokenReport(tokensTable)
    if not TOKEN_REPORT_FILE then return end
    local writer = type(writefile) == "function" and writefile
        or (type(syn) == "table" and type(syn.writefile) == "function" and syn.writefile)
        or nil
    if not writer then return end
    pcall(function()
        local data = HttpService:JSONEncode(tokensTable)
        writer(TOKEN_REPORT_FILE, data)
        log("Token report written to " .. TOKEN_REPORT_FILE)
    end)
end

local _stopFlagLoggedAt = 0
local function stopFlagExists()
    if STOP_FLAG_PATH and type(isfile) == "function" then
        local success, exists = pcall(isfile, STOP_FLAG_PATH)
        if success and exists then
            local now = tick()
            if now - _stopFlagLoggedAt > 10 then
                _stopFlagLoggedAt = now
                log("Stop flag detected at: " .. STOP_FLAG_PATH)
            end
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

local function isCreatureAlive()
    refreshCharacterRefs()
    if not character then return false end
    -- CoS stores health as a Model attribute "Health" (not Humanoid.Health)
    local ok, hp = pcall(function() return character:GetAttribute("Health") end)
    if ok and type(hp) == "number" then
        return hp > 0
    end
    -- Fallback: check Humanoid if available
    if humanoid then
        return humanoid.Health > 0
    end
    -- Character exists but we can't determine health — assume alive
    return true
end

-- DeathStatPoints formula (from game data — ReplicatedStorage/Storage/DeathStatPoints)
local DEATH_STAT_MULTIPLIERS = {
    TimePlayed         = function(v) return math.floor(v / 210) end,
    MissionsCompleted  = function(v) return math.floor(v * 4)   end,
    DistanceTravelled  = function(v) return math.floor(v * 0)   end,
    DisastersSurvived  = function(v) return math.floor(v * 6)   end,
    BiomesVisited      = function(v) return math.floor(v * 0)   end,
    GrowCreatureTeen   = 5,
    GrowCreatureAdult  = 10,
    CreatureKillsT1    = 1,
    CreatureKillsT2    = 2,
    CreatureKillsT3    = 3,
    CreatureKillsT4    = 5,
    CreatureKillsT5    = 8,
}

-- ========== BIOME ATLAS (Main mode, coordinates from rbxlx region volumes) ==========
-- Y values set to safe ground-level estimates; runtime scan supplements static POIs.
local CollectionService = game:GetService("CollectionService")

local BIOME_ATLAS = {
    {name = "Central Rockfaces", zone = "Land", entry = {145, 80, -87},  safe = {145, 80, -87},
     walk = {{200,80,-50},{100,80,-150},{50,80,-50},{200,80,-150},{145,80,-87}}},
    {name = "Desert", zone = "Land", entry = {-1455, 100, 1203}, safe = {-1455, 100, 1203},
     walk = {{-1400,100,1250},{-1500,100,1150},{-1550,100,1300},{-1350,100,1100},{-1455,100,1203}}},
    {name = "Flower Cove", zone = "Land", entry = {500, 60, 2028},  safe = {500, 60, 2028},
     walk = {{550,60,2080},{450,60,1980},{400,60,2080},{550,60,1980},{500,60,2028}}},
    {name = "Jungle", zone = "Land", entry = {2235, 80, -1187}, safe = {2235, 80, -1187},
     walk = {{2300,80,-1130},{2170,80,-1250},{2300,80,-1250},{2170,80,-1130},{2235,80,-1187}}},
    {name = "Mesa", zone = "Land", entry = {-2061, 120, 180},  safe = {-2061, 120, 180},
     walk = {{-2000,120,230},{-2120,120,130},{-2000,120,130},{-2120,120,230},{-2061,120,180}}},
    {name = "Mountains", zone = "Land", entry = {-1550, 150, -802}, safe = {-1550, 150, -802},
     walk = {{-1490,150,-750},{-1610,150,-860},{-1490,150,-860},{-1610,150,-750},{-1550,150,-802}}},
    {name = "Pride Rocks", zone = "Land", entry = {1625, 80, -472},  safe = {1625, 80, -472},
     walk = {{1680,80,-420},{1570,80,-530},{1680,80,-530},{1570,80,-420},{1625,80,-472}}},
    {name = "Redwoods", zone = "Land", entry = {-71, 80, -1446},  safe = {-71, 80, -1446},
     walk = {{-20,80,-1400},{-120,80,-1500},{-20,80,-1500},{-120,80,-1400},{-71,80,-1446}}},
    {name = "Swamp Hill", zone = "Land", entry = {834, 50, -2514}, safe = {834, 50, -2514},
     walk = {{890,50,-2460},{780,50,-2570},{890,50,-2570},{780,50,-2460},{834,50,-2514}}},
    {name = "Tundra", zone = "Land", entry = {-1006, 80, -2012}, safe = {-1006, 80, -2012},
     walk = {{-950,80,-1960},{-1060,80,-2070},{-950,80,-2070},{-1060,80,-1960},{-1006,80,-2012}}},
    {name = "Volcano Island", zone = "Land", entry = {2180, 100, 1430}, safe = {2180, 100, 1430},
     walk = {{2230,100,1480},{2130,100,1380},{2230,100,1380},{2130,100,1480},{2180,100,1430}}},
    {name = "Forgotten Shores", zone = "Land", entry = {-1126, 60, 2915}, safe = {-1126, 60, 2915},
     walk = {{-1070,60,2960},{-1180,60,2860},{-1070,60,2860},{-1180,60,2960},{-1126,60,2915}}},
    {name = "Algae Sandbar", zone = "Sea", entry = {1065, 10, -1437}, safe = {1065, 10, -1437},
     walk = {{1120,10,-1390},{1010,10,-1490},{1120,10,-1490},{1010,10,-1390},{1065,10,-1437}}},
    {name = "Coral Reef", zone = "Sea", entry = {1250, 5, 1103},  safe = {1250, 5, 1103},
     walk = {{1300,5,1150},{1200,5,1050},{1300,5,1050},{1200,5,1150},{1250,5,1103}}},
    {name = "Grassy Shoal", zone = "Sea", entry = {-701, 10, 2108}, safe = {-701, 10, 2108},
     walk = {{-650,10,2160},{-750,10,2060},{-650,10,2060},{-750,10,2160},{-701,10,2108}}},
    {name = "Rocky Drop", zone = "Sea", entry = {1065, 10, 578},   safe = {1065, 10, 578},
     walk = {{1120,10,630},{1010,10,530},{1120,10,530},{1010,10,630},{1065,10,578}}},
    {name = "Seaweed Depths", zone = "Sea", entry = {-110, 5, 993},  safe = {-110, 5, 993},
     walk = {{-60,5,1040},{-160,5,940},{-60,5,940},{-160,5,1040},{-110,5,993}}},
}

-- ==========================================================================
-- STEALTH / ANTI-DETECTION LAYER
-- ==========================================================================
-- Sonaria's server enforces silent rate-limit debounces (rbxlx
-- ~5929915 CheckActionDebounce, ~5944672 mob bite cooldown,
-- ~5952984 meteor 2.5s flag-and-webhook). Spamming faster than the debounce
-- doesn't ban, just gets ignored — but it ALSO leaves obvious bot patterns
-- (perfectly periodic remotes, no idle, instant-teleport-then-fire combos)
-- which can attract player reports and manual moderation.
--
-- This layer enforces:
--   * Min gap between FireServer/InvokeServer per-remote.
--   * Min gap between teleports + jittered settle delay AFTER teleport.
--   * Random "human-like" idle pauses periodically.
--   * Jittered waits to break up perfectly-periodic timings.
--   * Kick / disconnect detection so the bot exits cleanly instead of
--     looping into nothing after the player is removed.
local Stealth = {}

Stealth.config = {
    minRemoteGapSec     = 0.18,       -- minimum seconds between same-remote fires
    minTeleportGapSec   = 0.22,       -- minimum seconds between teleports
    postTeleportJitter  = {0.10, 0.30}, -- delay AFTER each teleport (settle)
    waitJitter          = {0.04, 0.16}, -- added to every Stealth.wait()
    idleEveryMissions   = {7, 13},    -- random N: idle every N missions
    idleDurationSec     = {3.5, 11.0},-- random idle length
    maxTeleportDist     = 6000,       -- studs (above this is suspicious)
}

Stealth.state = {
    lastFireAt        = {},   -- per-remote → tick() of last fire
    lastTeleportAt    = 0,
    teleportsThisMin  = 0,
    teleportMinStart  = 0,
    missionsSinceIdle = 0,
    aborted           = false,
    abortReason       = nil,
    kickListenerSet   = false,
}

local function _randf(lo, hi) return lo + math.random() * (hi - lo) end

function Stealth.jitter(extra)
    extra = extra or 0
    return extra + _randf(Stealth.config.waitJitter[1], Stealth.config.waitJitter[2])
end

-- Wait `secs` plus a small random jitter (so we don't have perfectly periodic timings).
function Stealth.wait(secs)
    task.wait(Stealth.jitter(secs or 0))
end

-- Enforce a minimum interval between consecutive fires of the SAME remote.
function Stealth.fireServer(remote, ...)
    if not remote then return end
    local args = table.pack(...)
    local key = "RE:" .. tostring(remote)
    local last = Stealth.state.lastFireAt[key] or 0
    local gap = tick() - last
    if gap < Stealth.config.minRemoteGapSec then
        task.wait(Stealth.config.minRemoteGapSec - gap)
    end
    pcall(function() remote:FireServer(table.unpack(args, 1, args.n)) end)
    Stealth.state.lastFireAt[key] = tick()
end

function Stealth.invokeServer(remote, ...)
    if not remote then return nil end
    local args = table.pack(...)
    local key = "RF:" .. tostring(remote)
    local last = Stealth.state.lastFireAt[key] or 0
    local gap = tick() - last
    if gap < Stealth.config.minRemoteGapSec then
        task.wait(Stealth.config.minRemoteGapSec - gap)
    end
    local ok, ret = pcall(function()
        return remote:InvokeServer(table.unpack(args, 1, args.n))
    end)
    Stealth.state.lastFireAt[key] = tick()
    if ok then return ret end
    return nil
end

-- Pre-teleport throttle. Caller still does the actual CFrame mutation.
-- After your teleport, call Stealth.afterTeleport() so the bot doesn't
-- immediately fire a remote (server-side anti-cheat-pattern: TP + instant action).
function Stealth.beforeTeleport()
    local now = tick()
    -- Reset per-minute counter every 60s.
    if now - Stealth.state.teleportMinStart >= 60 then
        Stealth.state.teleportMinStart = now
        Stealth.state.teleportsThisMin = 0
    end
    local gap = now - Stealth.state.lastTeleportAt
    if gap < Stealth.config.minTeleportGapSec then
        task.wait(Stealth.config.minTeleportGapSec - gap)
    end
end

function Stealth.afterTeleport()
    Stealth.state.lastTeleportAt = tick()
    Stealth.state.teleportsThisMin = (Stealth.state.teleportsThisMin or 0) + 1
    -- Brief "settling" delay so subsequent remote calls don't look like an
    -- instant TP+act combo (a classic exploit signature).
    local cfg = Stealth.config.postTeleportJitter
    task.wait(_randf(cfg[1], cfg[2]))
end

-- Called between missions in doMissionStep. Periodically inserts a longer
-- pause to break up the otherwise robotic mission-after-mission cadence.
function Stealth.maybeIdleBetweenMissions()
    Stealth.state.missionsSinceIdle = (Stealth.state.missionsSinceIdle or 0) + 1
    local lo, hi = Stealth.config.idleEveryMissions[1], Stealth.config.idleEveryMissions[2]
    local trigger = math.random(lo, hi)
    if Stealth.state.missionsSinceIdle >= trigger then
        Stealth.state.missionsSinceIdle = 0
        local d = _randf(Stealth.config.idleDurationSec[1], Stealth.config.idleDurationSec[2])
        log(string.format("[Stealth] human-like idle pause: %.1fs", d))
        task.wait(d)
    end
end

function Stealth.aborted()    return Stealth.state.aborted end
function Stealth.abortReason() return Stealth.state.abortReason end

-- Kick / disconnect / client-side abort detection.
local function _stealthSetupListeners()
    if Stealth.state.kickListenerSet then return end
    Stealth.state.kickListenerSet = true
    pcall(function()
        local Players = game:GetService("Players")
        Players.PlayerRemoving:Connect(function(p)
            if Players.LocalPlayer and p == Players.LocalPlayer then
                Stealth.state.aborted = true
                Stealth.state.abortReason = "LocalPlayer removed (kick or disconnect)"
                log("[Stealth] " .. Stealth.state.abortReason)
            end
        end)
    end)
    pcall(function()
        game:BindToClose(function()
            Stealth.state.aborted = true
            Stealth.state.abortReason = "BindToClose (game shutdown)"
        end)
    end)
end
_stealthSetupListeners()

-- Survival thresholds
local SURVIVAL_FOOD_CRITICAL = 15
local SURVIVAL_WATER_CRITICAL = 15
local SURVIVAL_HP_CRITICAL = 25

-- ========== MISSION STATE (persistent across doMissionStep calls) ==========
local _missionState = {
    initialized = false,
    currentBiomeIdx = 1,
    currentMissionType = nil,
    lastPositions = {},
    stuckTimer = 0,
    missionStuckTimers = {},
    walkLoopIdx = 1,
    lastSniffTime = 0,
    lastSurvivalCheck = 0,
    lastDistancePos = nil,
    lastDistanceCheckTime = 0,
    distanceAccum = 0,
    biomeEnteredTime = 0,
    missionSwitchCooldown = 0,
    eatDrinkToggle = "food",
    shoomRetryCount = 0,
    attackRetryCount = 0,
    logThrottles = {},
}

local function calcDeathPointsFromStats(deathStatsFolder)
    local total = 0
    for statName, mult in pairs(DEATH_STAT_MULTIPLIERS) do
        local child = deathStatsFolder:FindFirstChild(statName)
        if child then
            local raw = child.Value
            if type(raw) == "number" then
                if type(mult) == "function" then
                    total = total + mult(raw)
                else
                    total = total + raw * mult
                end
            end
        end
    end
    return total
end

local _dpDiagLoggedOnce = false

local function getCurrentDeathPoints()
    local function dpLog(msg)
        log("[DP-diag] " .. msg)
    end

    -- === Step 1: Find the SLOT folder (Instance with DeathStats) ===
    local currentSlot = nil
    local slotSource = "?"

    -- 1a: PlayerGui.Data — canonical data folder on client (PlayerData in wrapper code).
    --     CoS client wrapper sets: PlayerData = PlayerGui:WaitForChild("Data")
    --     Slot folders are: Data.Slot1, Data.Slot2, Data.Slot3, Data.Slots.Slot4+
    --     Use Settings.Slot to identify which slot number is active.
    local slotNumber = nil
    pcall(function()
        local settings = player:FindFirstChild("Settings")
        if not settings then
            if not _dpDiagLoggedOnce then dpLog("1a: no player.Settings") end
            return
        end
        local slotOV = settings:FindFirstChild("Slot")
        if not slotOV then
            if not _dpDiagLoggedOnce then dpLog("1a: no Settings.Slot") end
            return
        end
        local sv = slotOV.Value
        if not sv then
            if not _dpDiagLoggedOnce then dpLog("1a: Settings.Slot.Value is nil") end
            return
        end
        -- sv could be: Instance (replicated slot folder) whose Name is like "Slot1"
        local name = nil
        pcall(function() name = sv.Name end)
        if type(name) == "string" then
            local n = tonumber(name:match("%d+"))
            if n then slotNumber = n end
        end
        if not _dpDiagLoggedOnce then
            dpLog("1a: Settings.Slot.Value type=" .. typeof(sv) .. " name=" .. tostring(name) .. " slotNum=" .. tostring(slotNumber))
        end
    end)

    -- Look up the slot in PlayerGui.Data (has DeathStats, unlike replicated version)
    pcall(function()
        local pg = player:FindFirstChild("PlayerGui")
        if not pg then
            if not _dpDiagLoggedOnce then dpLog("1b: no PlayerGui") end
            return
        end
        local dataFolder = pg:FindFirstChild("Data")
        if not dataFolder then
            if not _dpDiagLoggedOnce then dpLog("1b: no PlayerGui.Data") end
            return
        end
        if not _dpDiagLoggedOnce then
            local slotKids = {}
            for _, c in ipairs(dataFolder:GetChildren()) do
                local hasDino = c:FindFirstChild("Dino") and true or false
                local hasDS = c:FindFirstChild("DeathStats") and true or false
                if hasDino or hasDS then
                    table.insert(slotKids, c.Name .. "(dino=" .. tostring(hasDino) .. ",ds=" .. tostring(hasDS) .. ")")
                end
            end
            dpLog("1b: PlayerGui.Data slot-like children: " .. table.concat(slotKids, ", "))
        end

        -- Try by slot number first
        if slotNumber then
            local slotName = "Slot" .. slotNumber
            local candidate = dataFolder:FindFirstChild(slotName)
            if not candidate then
                local slotsSubfolder = dataFolder:FindFirstChild("Slots")
                if slotsSubfolder then
                    candidate = slotsSubfolder:FindFirstChild(slotName)
                end
            end
            if candidate and candidate:FindFirstChild("DeathStats") then
                currentSlot = candidate
                slotSource = "PlayerGui.Data[" .. slotName .. "]"
                return
            end
        end

        -- Fallback: find by creature name
        local targetLower = DEFAULT_CREATURE:lower()
        for _, slot in ipairs(dataFolder:GetChildren()) do
            local dino = slot:FindFirstChild("Dino")
            if dino and dino:IsA("StringValue") and dino.Value:lower() == targetLower then
                if slot:FindFirstChild("DeathStats") then
                    currentSlot = slot
                    slotSource = "PlayerGui.Data[name=" .. slot.Name .. "]"
                    return
                end
            end
        end
        -- Also check Slots subfolder
        local slotsSubfolder = dataFolder:FindFirstChild("Slots")
        if slotsSubfolder then
            for _, slot in ipairs(slotsSubfolder:GetChildren()) do
                local dino = slot:FindFirstChild("Dino")
                if dino and dino:IsA("StringValue") and dino.Value:lower() == targetLower then
                    if slot:FindFirstChild("DeathStats") then
                        currentSlot = slot
                        slotSource = "PlayerGui.Data.Slots[name=" .. slot.Name .. "]"
                        return
                    end
                end
            end
        end
    end)

    -- 1c: player.Data (alternative location for some CoS versions / Trade Realm)
    if not currentSlot then
        pcall(function()
            local dataFolder = player:FindFirstChild("Data")
            if not dataFolder then return end
            if not _dpDiagLoggedOnce then dpLog("1c: trying player.Data") end
            if slotNumber then
                local slotName = "Slot" .. slotNumber
                local candidate = dataFolder:FindFirstChild(slotName)
                if not candidate then
                    local sf = dataFolder:FindFirstChild("Slots")
                    if sf then candidate = sf:FindFirstChild(slotName) end
                end
                if candidate and candidate:FindFirstChild("DeathStats") then
                    currentSlot = candidate
                    slotSource = "player.Data[" .. slotName .. "]"
                    return
                end
            end
            local targetLower = DEFAULT_CREATURE:lower()
            for _, slot in ipairs(dataFolder:GetChildren()) do
                local dino = slot:FindFirstChild("Dino")
                if dino and dino:IsA("StringValue") and dino.Value:lower() == targetLower then
                    if slot:FindFirstChild("DeathStats") then
                        currentSlot = slot
                        slotSource = "player.Data[" .. slot.Name .. "]"
                        return
                    end
                end
            end
        end)
    end

    -- 1d: Settings.Slot.Value directly (replicated slot — might have DeathStats)
    if not currentSlot then
        pcall(function()
            local settings = player:FindFirstChild("Settings")
            if not settings then return end
            local slotOV = settings:FindFirstChild("Slot")
            if not slotOV then return end
            local sv = slotOV.Value
            if sv and typeof(sv) == "Instance" and sv:FindFirstChild("DeathStats") then
                currentSlot = sv
                slotSource = "Settings.Slot.Value(direct)"
            end
        end)
    end

    if not currentSlot then
        if not _dpDiagLoggedOnce then
            _dpDiagLoggedOnce = true
            dpLog("ALL slot methods failed — returning 0")
        end
        return 0
    end

    -- === Step 2: Compute DP from DeathStats (NO require/Sonar — require() can yield/hang forever) ===
    local dp = nil
    local dpCalcSource = nil

    pcall(function()
        local ds = currentSlot:FindFirstChild("DeathStats")
        if ds then
            dp = calcDeathPointsFromStats(ds)
            dpCalcSource = "manual"
            if not _dpDiagLoggedOnce then
                local items = {}
                for _, c in ipairs(ds:GetChildren()) do
                    table.insert(items, c.Name .. "=" .. tostring(c.Value))
                end
                dpLog("DeathStats contents: " .. table.concat(items, ", "))
            end
        elseif not _dpDiagLoggedOnce then
            dpLog("no DeathStats folder in slot " .. tostring(currentSlot))
        end
    end)

    if not dp then
        dp = 0
        dpCalcSource = "none"
    end

    if not _dpDiagLoggedOnce then
        _dpDiagLoggedOnce = true
        local slotPath = ""
        pcall(function() slotPath = currentSlot:GetFullName() end)
        dpLog("RESULT: slot=" .. slotSource .. " calc=" .. dpCalcSource .. " dp=" .. tostring(dp) .. " path=" .. slotPath)
    end

    return dp
end

local GET_INVENTORY_RF_TIMEOUT = tonumber(params.get_inventory_remote_timeout_seconds) or 3

local function getInventory()
    local inventory = {}

    local success, result = pcall(function()
        -- Вариант 1: через ReplicatedStorage / локальные папки (быстро, без сервера)
        local itemsFolder = ReplicatedStorage:FindFirstChild("Items")
            or ReplicatedStorage:FindFirstChild("Inventory")
            or player:FindFirstChild("Inventory")

        if itemsFolder then
            for _, item in pairs(itemsFolder:GetChildren()) do
                local name = item.Name
                inventory[name] = (inventory[name] or 0) + 1
            end
        end

        -- Вариант 2: RemoteFunction — на перегруженном клиенте может зависнуть навсегда; ограничиваем ожидание.
        local getInventoryFunc = ReplicatedStorage:FindFirstChild("GetInventory")
        if getInventoryFunc and getInventoryFunc:IsA("RemoteFunction") then
            local rf = getInventoryFunc
            local pack = nil
            local done = false
            task.spawn(function()
                local ok, res = pcall(function()
                    return rf:InvokeServer()
                end)
                pack = { ok = ok, res = res }
                done = true
            end)
            local deadline = tick() + GET_INVENTORY_RF_TIMEOUT
            while not done and tick() < deadline do
                task.wait(0.05)
            end
            if not done then
                log(
                    "WARN: GetInventory InvokeServer не ответил за "
                        .. tostring(GET_INVENTORY_RF_TIMEOUT)
                        .. "s — продолжаем с локальными данными"
                )
            elseif pack and pack.ok and type(pack.res) == "table" then
                for name, count in pairs(pack.res) do
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
local PLAY_CLICK_INTERVAL = tonumber(params.play_click_interval_seconds) or 2.5
local PLAY_LOG_INTERVAL = math.max(tonumber(params.play_log_interval_seconds) or 3, 2)
local PLAY_CLICK_MAX_ATTEMPTS = tonumber(params.play_click_max_attempts) or 180
local _playUiLastLogAt = 0
local _playUiLastMsg = ""
local _playUiSuppressed = 0
local _playUiSlotMissLastAt = 0
local _playUiSlotDumpLastAt = 0
-- nil = ещё не было успешного restart; 0 нельзя — иначе tick()<2.5 даёт ложный «кулдаун» и restart не вызывается.
local _deadRestartLastAt = nil
local _deadRestartLogLastAt = nil
local _deadRestartFailLogLastAt = nil
local _promptDumpLastAt = nil
local _selectedCardDumpDone = false
local _playUiVerbose = tostring(params.play_ui_verbose or "0") == "1"
local _playUiImportantByKey = {}
local _slotFoundLoggedOnce = false
local _slotNameClickLastAt = nil

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

    local function isDevConsoleOpen()
        local open = false
        pcall(function()
            local core = game:GetService("CoreGui")
            for _, n in ipairs(core:GetDescendants()) do
                if n:IsA("GuiObject") and n.Visible then
                    local nm = string.lower(tostring(n.Name or ""))
                    if string.find(nm, "devconsole", 1, true) or string.find(nm, "developerconsole", 1, true) then
                        open = true
                        break
                    end
                end
            end
        end)
        return open
    end

    local function guiRectsOverlap(a, b)
        if not a or not b or not a:IsA("GuiObject") or not b:IsA("GuiObject") then
            return false
        end
        local ax, ay = a.AbsolutePosition.X, a.AbsolutePosition.Y
        local aw, ah = a.AbsoluteSize.X, a.AbsoluteSize.Y
        local bx, by = b.AbsolutePosition.X, b.AbsolutePosition.Y
        local bw, bh = b.AbsoluteSize.X, b.AbsoluteSize.Y
        return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
    end

    local function clickGui(gui, label)
        if not gui or not gui:IsA("GuiObject") or not gui.Visible then
            return false
        end
        -- F9 overlay: при открытой консоли Roblox клики не должны уходить в GUI, иначе дёргается вкладка Memory.
        if isDevConsoleOpen() then
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

    local function clickGuiHard(gui, label, ignoreDevConsole)
        if not gui or not gui:IsA("GuiObject") or not gui.Visible then
            return false
        end
        if not ignoreDevConsole and isDevConsoleOpen() then
            return false
        end
        local pos = gui.AbsolutePosition + (gui.AbsoluteSize / 2)
        local inset = GuiService:GetGuiInset()
        local baseX, baseY = pos.X, pos.Y + inset.Y
        local offsets = {
            { 0, 0 },
            { 2, 0 },
            { -2, 0 },
            { 0, 2 },
        }
        local clicked = false
        for _, off in ipairs(offsets) do
            local x = baseX + off[1]
            local y = baseY + off[2]
            VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
            wait(0.05)
            VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
            clicked = true
            wait(0.03)
        end
        playUiLog((label or "GUI hard click") .. ": " .. gui:GetFullName())
        return clicked
    end

    local function pressActionButton(btn, label)
        if not btn or not btn:IsA("GuiButton") or not btn.Visible then
            return false
        end
        -- Не блокируем по F9: иначе Restart/Play не жмутся, пока открыт DevConsole (типичный просмотр логов).
        -- CoS часто держит Restart/Delete с Visible=true, но Active=false — без Active VIM-клики не доходят.
        local prevBtnActive, prevBtnSelectable = nil, nil
        pcall(function()
            prevBtnActive = btn.Active
            prevBtnSelectable = btn.Selectable
            btn.Active = true
            btn.Selectable = true
        end)
        -- В CoS поверх action-кнопок есть UpperLabel с ZIndex выше; они могут быть и потомками, и соседями в ButtonsFrame.
        local disabledOverlays = {}
        for _, q in ipairs(btn:GetDescendants()) do
            if
                (q:IsA("ImageButton") or q:IsA("TextButton") or q:IsA("Frame"))
                and q ~= btn
                and q.Visible
                and (string.lower(tostring(q.Name or "")) == "upperlabel" or tonumber(q.ZIndex) > tonumber(btn.ZIndex))
            then
                local prevActive = q.Active
                local prevSelectable = q.Selectable
                pcall(function()
                    q.Active = false
                    q.Selectable = false
                end)
                table.insert(disabledOverlays, { obj = q, active = prevActive, selectable = prevSelectable })
            end
        end
        local par = btn.Parent
        if par then
            for _, sib in ipairs(par:GetChildren()) do
                if sib ~= btn and sib:IsA("GuiObject") and sib.Visible and guiRectsOverlap(btn, sib) then
                    local nm = string.lower(tostring(sib.Name or ""))
                    if nm == "upperlabel" or tonumber(sib.ZIndex) > tonumber(btn.ZIndex) then
                        local prevActive = sib.Active
                        local prevSelectable = sib.Selectable
                        pcall(function()
                            sib.Active = false
                            sib.Selectable = false
                        end)
                        table.insert(disabledOverlays, { obj = sib, active = prevActive, selectable = prevSelectable })
                    end
                end
            end
        end

        local ok = false
        local function fireConnList(sig)
            if not sig or type(getconnections) ~= "function" then
                return
            end
            local listOk, list = pcall(function()
                return getconnections(sig)
            end)
            if not listOk then
                return
            end
            if not list then
                return
            end
            for _, conn in pairs(list) do
                local fn = nil
                pcall(function()
                    fn = conn and conn.Function
                end)
                if type(fn) ~= "function" and type(conn) == "table" then
                    fn = rawget(conn, "Function")
                end
                if type(fn) == "function" then
                    pcall(fn)
                    ok = true
                end
            end
        end
        -- 1) Обход подписчиков (часто срабатывает надёжнее firesignal для GuiButton)
        pcall(function()
            fireConnList(btn.MouseButton1Click)
        end)
        pcall(function()
            fireConnList(btn.MouseButton1Down)
        end)
        pcall(function()
            fireConnList(btn.Activated)
        end)
        -- 2) Прямые UI-сигналы эксплойта
        pcall(function()
            if type(firesignal) == "function" and btn.MouseButton1Click then
                firesignal(btn.MouseButton1Click)
                ok = true
            end
        end)
        pcall(function()
            if type(firesignal) == "function" and btn.Activated then
                firesignal(btn.Activated)
                ok = true
            end
        end)
        -- 3) Нативная активация GuiButton
        pcall(function()
            btn:Activate()
            ok = true
        end)
        -- 4) VIM (VirtualInputManager) — отправляет events внутри процесса Roblox, без глобальных кликов мыши
        if clickGuiHard(btn, label, true) then
            ok = true
        end

        for _, rec in ipairs(disabledOverlays) do
            pcall(function()
                rec.obj.Active = rec.active
                rec.obj.Selectable = rec.selectable
            end)
        end
        pcall(function()
            btn.Active = prevBtnActive
            btn.Selectable = prevBtnSelectable
        end)
        return ok
    end

    -- Путь из rbxlx: чаще InnerFrame.CreatureFrame.ButtonsFrame; в живом клиенте панель иногда сидит на InnerFrame (сосед CreatureFrame).
    local function findCreatureButtonsFrame(root)
        if not root then
            return nil
        end
        local bf = root:FindFirstChild("ButtonsFrame")
            or root:FindFirstChild("ButtonFrame")
            or root:FindFirstChild("Button")
        if bf then
            return bf
        end
        for _, ch in ipairs(root:GetChildren()) do
            bf = ch:FindFirstChild("ButtonsFrame")
                or ch:FindFirstChild("ButtonFrame")
                or ch:FindFirstChild("Button")
            if bf then
                return bf
            end
        end
        return nil
    end

    -- selectedCard может быть слотом «1», либо уже Instance CreatureFrame (см. findSlotCard).
    local function resolveCreatureFrame(slotCardHint)
        if not slotCardHint then
            return nil
        end
        if slotCardHint.Name == "CreatureFrame" and slotCardHint:IsA("GuiObject") then
            return slotCardHint
        end
        local inner = slotCardHint:FindFirstChild("InnerFrame")
        if inner then
            local cf = inner:FindFirstChild("CreatureFrame")
            if cf and cf:IsA("GuiObject") then
                return cf
            end
        end
        return nil
    end

    local function findButtonsContainerForSlotHint(slotCardHint)
        local creatureFrame = resolveCreatureFrame(slotCardHint)
        local bf = findCreatureButtonsFrame(creatureFrame)
        if bf then
            return bf, creatureFrame
        end
        local par = creatureFrame and creatureFrame.Parent
        if par and par:IsA("GuiObject") then
            bf = findCreatureButtonsFrame(par)
            if bf then
                return bf, creatureFrame
            end
        end
        return nil, creatureFrame
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
                    if node.Visible and node.AbsoluteSize.X > 1 and node.AbsoluteSize.Y > 1 then
                        local txt = string.lower(tostring(node.Text or ""))
                        if containsLower(txt, creatureLower) then
                            return node
                        end
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
                if node.Visible and node.AbsoluteSize.X > 1 and node.AbsoluteSize.Y > 1 then
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
                and d.AbsoluteSize.X > 2
                and d.AbsoluteSize.Y > 2
                and (nm == "playbutton" or tx == "play")
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
        if containsLower(nm, token) or containsLower(tx, token) then
            return true
        end
        for _, q in ipairs(btn:GetDescendants()) do
            if q:IsA("TextLabel") or q:IsA("TextButton") or q:IsA("TextBox") then
                local t = string.lower(tostring(q.Text or ""))
                if containsLower(t, token) then
                    return true
                end
            end
        end
        return false
    end

    local function isStrictPlayButton(btn)
        if not btn or not btn:IsA("GuiButton") then
            return false
        end
        local nm = string.lower(tostring(btn.Name or ""))
        if nm == "playbutton" then
            return true
        end
        if btn:IsA("TextButton") then
            local tx = string.lower(tostring(btn.Text or ""))
            if tx == "play" then
                return true
            end
        end
        for _, q in ipairs(btn:GetDescendants()) do
            if q:IsA("TextLabel") or q:IsA("TextButton") or q:IsA("TextBox") then
                local t = string.lower(tostring(q.Text or ""))
                if t == "play" then
                    return true
                end
            end
        end
        return false
    end

    -- CoS часто держит Play с Visible=true и Active=false (ещё не готово к спавну); кнопка всё равно целевая.
    local function isAncestryVisible(gui)
        local node = gui
        while node and node:IsA("GuiObject") do
            if not node.Visible then
                return false
            end
            node = node.Parent
        end
        return true
    end

    local function actionButtonMatches(btn, token, allowInactive)
        if not btn or not btn:IsA("GuiButton") or not btn.Visible then
            return false
        end
        if not isAncestryVisible(btn) then
            return false
        end
        if btn.AbsoluteSize.X <= 2 or btn.AbsoluteSize.Y <= 2 then
            return false
        end
        if not allowInactive and btn.Active == false then
            return false
        end
        if token == "play" then
            return isStrictPlayButton(btn)
        end
        return buttonHasToken(btn, token)
    end

    local function findButtonsByToken(token)
        local out = {}
        for _, d in ipairs(pg:GetDescendants()) do
            if
                d:IsA("GuiButton")
                and d.Visible
                and isAncestryVisible(d)
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
            if q:IsA("GuiButton") and q.Visible and q.AbsoluteSize.X > 2 and q.AbsoluteSize.Y > 2 and buttonHasToken(q, "restart") then
                return q
            end
        end
        return nil
    end

    local function tryClickRunButtonInPrompt(promptFrame, matchedName)
        local runBtn = promptFrame:FindFirstChild("RunButton", true)
        if not runBtn then
            log("Restart prompt '" .. matchedName .. "' found but no RunButton inside")
            return false
        end

        local clickTarget = nil
        if runBtn:IsA("GuiButton") then
            clickTarget = runBtn
        else
            clickTarget = runBtn:FindFirstChild("UpperLabel")
            if not clickTarget then
                for _, d in ipairs(runBtn:GetDescendants()) do
                    if d:IsA("GuiButton") and d.Visible then
                        clickTarget = d
                        break
                    end
                end
            end
        end

        if clickTarget and clickTarget:IsA("GuiButton") then
            log("Restart prompt '" .. matchedName .. "': clicking " .. tostring(clickTarget.Name))
            pressActionButton(clickTarget, "Restart confirm")
            local ul = clickTarget:FindFirstChild("UpperLabel")
            if ul and ul:IsA("GuiButton") then
                pressActionButton(ul, "Restart confirm (UpperLabel)")
            end
            return true
        end

        log("Restart prompt '" .. matchedName .. "' no clickable RunButton target")
        return false
    end

    local function findCancelButtonInPrompt(promptChild)
        local names = { "CancelButton", "CloseButton", "BackButton", "NoButton", "XButton", "Cancel", "Close" }
        for _, n in ipairs(names) do
            local btn = promptChild:FindFirstChild(n, true)
            if btn and btn:IsA("GuiButton") then
                return btn
            end
        end
        for _, desc in ipairs(promptChild:GetDescendants()) do
            if desc:IsA("GuiButton") and desc.Visible then
                local dnm = string.lower(tostring(desc.Name or ""))
                if string.find(dnm, "cancel", 1, true) or string.find(dnm, "close", 1, true)
                    or string.find(dnm, "back", 1, true) or dnm == "x" then
                    return desc
                end
            end
        end
        return nil
    end

    -- CoS: после клика RestartButton открывается модалка PromptGui > PromptFrame > PromptFrames > RestartCreature(NoMutations).
    -- Внутри: RunButton (ImageButton) → UpperLabel (ImageButton) — подтверждение рестарта.
    local function tryConfirmRestartPrompt()
        -- Путь 1: PromptGui > PromptFrame > PromptFrames (основной путь в CoS)
        local promptFramesContainer = nil
        pcall(function()
            local promptGui = pg:FindFirstChild("PromptGui")
            if promptGui then
                local pf = promptGui:FindFirstChild("PromptFrame")
                if pf then
                    promptFramesContainer = pf:FindFirstChild("PromptFrames") or pf
                end
            end
        end)

        -- Путь 2: NotificationsGui > NotificationFrame (запасной)
        local notifFrameContainer = nil
        pcall(function()
            local notifGui = pg:FindFirstChild("NotificationsGui")
            if notifGui then
                notifFrameContainer = notifGui:FindFirstChild("NotificationFrame")
            end
        end)

        local containers = {}
        if promptFramesContainer then table.insert(containers, { frame = promptFramesContainer, name = "PromptFrames" }) end
        if notifFrameContainer then table.insert(containers, { frame = notifFrameContainer, name = "NotificationFrame" }) end

        local promptNames = { "RestartCreature", "RestartCreatureNoMutations" }

        for _, cont in ipairs(containers) do
            local container = cont.frame

            -- Поиск по точному имени
            for _, pName in ipairs(promptNames) do
                local f = container:FindFirstChild(pName)
                if f and f:IsA("GuiObject") and f.Visible then
                    return tryClickRunButtonInPrompt(f, pName)
                end
            end

            -- Fallback: видимый фрейм с "restart" в имени (исключая revive/purchase/edit/delete)
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("GuiObject") and child.Visible then
                    local nm = string.lower(tostring(child.Name or ""))
                    if string.find(nm, "restart", 1, true)
                        and not string.find(nm, "revive", 1, true) then
                        return tryClickRunButtonInPrompt(child, child.Name)
                    end
                end
            end

            -- Fallback 2: видимый фрейм с RunButton, но ТОЛЬКО если имя НЕ содержит revive/purchase/edit/delete/gifted
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("GuiObject") and child.Visible and child:FindFirstChild("RunButton", true) then
                    local nm = string.lower(tostring(child.Name or ""))
                    if not string.find(nm, "revive", 1, true)
                        and not string.find(nm, "purchase", 1, true)
                        and not string.find(nm, "edit", 1, true)
                        and not string.find(nm, "delete", 1, true)
                        and not string.find(nm, "gifted", 1, true) then
                        return tryClickRunButtonInPrompt(child, child.Name .. "(hasRunBtn)")
                    end
                end
            end

            -- Fallback 3: RestartCreatureNoMutations exists but invisible while ReviveCreature blocks.
            -- Force-hide ReviveCreature, force-show RestartCreatureNoMutations, then click RunButton.
            local reviveChild = nil
            local restartChild = nil
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("GuiObject") then
                    local nm = string.lower(tostring(child.Name or ""))
                    if string.find(nm, "revive", 1, true) and child.Visible then
                        reviveChild = child
                    end
                    if (child.Name == "RestartCreatureNoMutations" or child.Name == "RestartCreature") and not child.Visible then
                        restartChild = child
                    end
                end
            end
            if reviveChild and restartChild then
                log("Force-switching prompt: hiding " .. reviveChild.Name .. ", showing " .. restartChild.Name)
                local cancelBtn = findCancelButtonInPrompt(reviveChild)
                if cancelBtn then
                    pressActionButton(cancelBtn, "Revive prompt force-cancel")
                    wait(0.15)
                end
                pcall(function() reviveChild.Visible = false end)
                pcall(function() restartChild.Visible = true end)
                wait(0.2)
                return tryClickRunButtonInPrompt(restartChild, restartChild.Name .. "(force-shown)")
            end
        end

        -- Диагностика: дамп контейнеров
        if _promptDumpLastAt == nil or (tick() - _promptDumpLastAt) >= 5 then
            _promptDumpLastAt = tick()
            for _, cont in ipairs(containers) do
                local parts = {}
                pcall(function()
                    for _, child in ipairs(cont.frame:GetChildren()) do
                        local vis = "?"
                        pcall(function() vis = tostring(child.Visible) end)
                        table.insert(parts, child.Name .. "(" .. child.ClassName .. ",vis=" .. vis .. ")")
                    end
                end)
                if #parts > 0 then
                    log(cont.name .. " children: " .. table.concat(parts, " | "))
                end
            end
        end
        return false
    end

    local function dismissRevivePrompt()
        local closed = false
        pcall(function()
            local promptGui = pg:FindFirstChild("PromptGui")
            if not promptGui then return end
            local pf = promptGui:FindFirstChild("PromptFrame")
            if not pf then return end
            local container = pf:FindFirstChild("PromptFrames") or pf
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("GuiObject") and child.Visible then
                    local nm = string.lower(tostring(child.Name or ""))
                    if string.find(nm, "revive", 1, true) then
                        log("Closing ReviveCreature prompt")
                        -- Ищем CancelButton: сначала внутри типового фрейма, потом в PromptFrame.
                        local cancelBtn = findCancelButtonInPrompt(child)
                        if not cancelBtn then
                            cancelBtn = findCancelButtonInPrompt(pf)
                        end
                        if cancelBtn then
                            pressActionButton(cancelBtn, "Revive prompt cancel")
                            wait(0.2)
                        end
                        -- Скрываем ТОЛЬКО ReviveCreature (не весь PromptFrame — иначе сломаем стейт игры).
                        pcall(function() child.Visible = false end)
                        closed = true
                        return
                    end
                end
            end
        end)
        return closed
    end

    -- Прямой вызов RestartSlotRemote без Sonar (сканируем ReplicatedStorage напрямую).
    local function tryRestartSlotDirect(slotName)
        local rf = nil
        pcall(function()
            for _, desc in ipairs(ReplicatedStorage:GetDescendants()) do
                if desc.Name == "RestartSlotRemote" and desc:IsA("RemoteFunction") then
                    rf = desc
                    break
                end
            end
        end)
        if not rf then
            log("[restart-direct] RestartSlotRemote not found in ReplicatedStorage")
            return false
        end
        log("[restart-direct] Invoking RestartSlotRemote for slot=" .. tostring(slotName))
        local ok, res = pcall(function()
            return rf:InvokeServer(slotName, false)
        end)
        log("[restart-direct] pcall_ok=" .. tostring(ok) .. " res=" .. tostring(res))
        return ok and res
    end

    -- Определяет имя слота из GUI-карточки (Slot1, Slot2... или "1","2"...).
    local function getSlotNameFromCard(slotCardHint)
        if not slotCardHint then return nil end
        local slotName = nil
        pcall(function()
            local p = slotCardHint
            for _ = 1, 10 do
                if not p or not p.Parent then break end
                local parName = p.Parent and p.Parent.Name or ""
                if parName == "SlotsFrame" or parName == "AllSlotsFrame" then
                    slotName = p.Name
                    break
                end
                p = p.Parent
            end
        end)
        return slotName
    end

    -- Прямой вызов RestartSlotRemote через Sonar — надёжный fallback, не зависит от GUI.
    local function tryRestartSlotViaRemote(targetCreatureName, slotCardHint)
        local sonar = nil
        pcall(function()
            sonar = require(ReplicatedStorage:FindFirstChild("Sonar"))
        end)
        if not sonar then
            return false, "no Sonar"
        end
        local ru = nil
        pcall(function()
            ru = sonar("RemoteUtils")
        end)
        if not ru or type(ru.GetRemoteFunction) ~= "function" then
            return false, "no RemoteUtils"
        end
        local rf = nil
        pcall(function()
            rf = ru.GetRemoteFunction("RestartSlotRemote")
        end)
        if not rf or type(rf.InvokeServer) ~= "function" then
            return false, "no RestartSlotRemote"
        end

        local targetLower = string.lower(targetCreatureName or "")
        local candidates = {}
        local seen = {}

        local function addCandidate(name, source)
            if name and not seen[name] then
                seen[name] = true
                table.insert(candidates, { name = name, source = source })
            end
        end

        -- Способ 1: сканировать _replicationFolder для мёртвого существа по Dino/Health
        if targetLower ~= "" then
            pcall(function()
                local repFolder = ReplicatedStorage:FindFirstChild("_replicationFolder")
                if repFolder then
                    for _, desc in ipairs(repFolder:GetDescendants()) do
                        if desc.Name == "Dino" and desc:IsA("StringValue") then
                            local dinoLower = string.lower(tostring(desc.Value or ""))
                            if dinoLower == targetLower or string.find(dinoLower, targetLower, 1, true) then
                                local parent = desc.Parent
                                if parent then
                                    local health = parent:FindFirstChild("Health")
                                    if health and type(health.Value) == "number" and health.Value <= 0 then
                                        addCandidate(parent.Name, "_replicationFolder")
                                    end
                                end
                            end
                        end
                    end
                end
            end)
        end

        -- Способ 2: данные существ в player.Data / player.PlayerData / ReplicatedStorage.{playerName}
        if targetLower ~= "" and #candidates == 0 then
            local searchRoots = {}
            pcall(function()
                local pd = player:FindFirstChild("Data") or player:FindFirstChild("PlayerData")
                if pd then
                    table.insert(searchRoots, pd)
                end
            end)
            pcall(function()
                local repFolder = ReplicatedStorage:FindFirstChild("_replicationFolder")
                if repFolder then
                    local pf = repFolder:FindFirstChild(player.Name) or repFolder:FindFirstChild(tostring(player.UserId))
                    if pf then
                        table.insert(searchRoots, pf)
                    end
                end
            end)
            for _, root in ipairs(searchRoots) do
                pcall(function()
                    for _, desc in ipairs(root:GetDescendants()) do
                        if desc.Name == "Dino" and desc:IsA("StringValue") then
                            local dinoLower = string.lower(tostring(desc.Value or ""))
                            if dinoLower == targetLower or string.find(dinoLower, targetLower, 1, true) then
                                local parent = desc.Parent
                                if parent then
                                    local health = parent:FindFirstChild("Health")
                                    if health and type(health.Value) == "number" and health.Value <= 0 then
                                        addCandidate(parent.Name, "playerData")
                                    end
                                end
                            end
                        end
                    end
                end)
            end
        end

        -- Способ 3: извлечь номер слота из GUI — SlotsFrame.{N}.InnerFrame.CreatureFrame
        if slotCardHint then
            pcall(function()
                local p = slotCardHint
                for _ = 1, 10 do
                    if not p or not p.Parent then
                        break
                    end
                    local parName = p.Parent and p.Parent.Name or ""
                    if parName == "SlotsFrame" or parName == "AllSlotsFrame" then
                        addCandidate(p.Name, "GUI")
                        break
                    end
                    p = p.Parent
                end
            end)
        end

        if #candidates == 0 then
            return false, "dead slot not found for " .. tostring(targetCreatureName)
        end

        -- Пробуем каждый кандидат пока один не сработает.
        for _, cand in ipairs(candidates) do
            local ok, res = pcall(function()
                return rf:InvokeServer(cand.name, false)
            end)
            log("RestartSlotRemote: slot=" .. tostring(cand.name) .. " source=" .. cand.source .. " pcall_ok=" .. tostring(ok) .. " res=" .. tostring(res))
            if ok and res then
                return true
            end
            wait(0.3)
        end
        return false, "InvokeServer failed for all " .. #candidates .. " candidates"
    end

    local function findActionButtonInCard(slotCardHint, token)
        if not slotCardHint or type(slotCardHint.GetDescendants) ~= "function" then
            return nil
        end
        local allowInactive = token == "restart" or token == "revive" or token == "play"
        local buttonFrame = select(1, findButtonsContainerForSlotHint(slotCardHint))
        if buttonFrame then
            local preferred = nil
            if token == "play" then
                preferred = buttonFrame:FindFirstChild("PlayButton")
            elseif token == "restart" then
                preferred = buttonFrame:FindFirstChild("RestartButton")
            elseif token == "revive" then
                preferred = buttonFrame:FindFirstChild("ReviveButton")
            end
            if preferred and preferred:IsA("GuiButton") and actionButtonMatches(preferred, token, allowInactive) then
                return preferred
            end
            for _, q in ipairs(buttonFrame:GetDescendants()) do
                if q:IsA("GuiButton") and actionButtonMatches(q, token, allowInactive) then
                    return q
                end
            end
            -- Для Play не уходим в глобальные fallback-поиски:
            -- иначе можно схватить чужую кнопку Play из соседнего UI и пропустить restart-ветку.
            if token == "play" then
                return nil
            end
        end

        local candidates = {}
        local function considerRoot(root)
            if not root or type(root.GetDescendants) ~= "function" then
                return
            end
            for _, q in ipairs(root:GetDescendants()) do
                if q:IsA("GuiButton") and actionButtonMatches(q, token, allowInactive) then
                    table.insert(candidates, q)
                end
            end
        end
        considerRoot(slotCardHint)
        if slotCardHint:IsA("GuiObject") and slotCardHint.Parent then
            considerRoot(slotCardHint.Parent)
        end
        if #candidates == 0 then
            return nil
        end
        if #candidates == 1 then
            return candidates[1]
        end
        local center = slotCardHint.AbsolutePosition + (slotCardHint.AbsoluteSize / 2)
        local best = candidates[1]
        local bestDist = math.huge
        for _, btn in ipairs(candidates) do
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

    local function tryCloseDevConsole()
        pcall(function()
            game:GetService("StarterGui"):SetCore("DevConsoleVisible", false)
        end)
    end

    -- Проверяет, является ли кнопка revive-связанной (чтобы НИКОГДА её не нажимать).
    local function isReviveRelated(btn)
        if not btn then return false end
        local nm = string.lower(tostring(btn.Name or ""))
        if string.find(nm, "revive", 1, true) then return true end
        if btn:IsA("TextButton") then
            local tx = string.lower(tostring(btn.Text or ""))
            if string.find(tx, "revive", 1, true) then return true end
        end
        local found = false
        pcall(function()
            for _, q in ipairs(btn:GetDescendants()) do
                if (q:IsA("TextLabel") or q:IsA("TextButton") or q:IsA("TextBox")) then
                    local t = string.lower(tostring(q.Text or ""))
                    if string.find(t, "revive", 1, true) then
                        found = true
                        return
                    end
                end
            end
        end)
        return found
    end

    -- Ищет кнопку Restart в карточке слота — расширенный поиск с диагностикой.
    local function findRestartButtonInCard(slotCardHint)
        if not slotCardHint or type(slotCardHint.GetDescendants) ~= "function" then
            return nil
        end

        -- Сначала пробуем стандартный путь через ButtonsFrame
        local btn = findActionButtonInCard(slotCardHint, "restart")
        if btn and not isReviveRelated(btn) then
            return btn
        end

        -- Расширенный поиск: все GuiButton в карточке и её родителе
        local searchRoots = { slotCardHint }
        pcall(function()
            if slotCardHint.Parent and slotCardHint.Parent:IsA("GuiObject") then
                table.insert(searchRoots, slotCardHint.Parent)
            end
        end)

        local restartCandidates = {}
        local allButtons = {}
        for _, root in ipairs(searchRoots) do
            pcall(function()
                for _, q in ipairs(root:GetDescendants()) do
                    if q:IsA("GuiButton") and q.AbsoluteSize.X > 2 and q.AbsoluteSize.Y > 2 then
                        local qnm = string.lower(tostring(q.Name or ""))
                        local qtx = ""
                        if q:IsA("TextButton") then qtx = string.lower(tostring(q.Text or "")) end
                        local hasRestartText = false
                        for _, d in ipairs(q:GetDescendants()) do
                            if (d:IsA("TextLabel") or d:IsA("TextButton")) then
                                if string.find(string.lower(tostring(d.Text or "")), "restart", 1, true) then
                                    hasRestartText = true
                                    break
                                end
                            end
                        end
                        local isRestart = string.find(qnm, "restart", 1, true)
                            or string.find(qtx, "restart", 1, true)
                            or hasRestartText
                        if isRestart and not isReviveRelated(q) then
                            table.insert(restartCandidates, q)
                        end
                        table.insert(allButtons, {
                            name = q.Name,
                            class = q.ClassName,
                            vis = q.Visible,
                            act = q.Active,
                            text = qtx,
                            hasRestart = isRestart,
                        })
                    end
                end
            end)
        end

        -- Диагностика: дамп всех кнопок в карточке
        if #restartCandidates == 0 and (_deadRestartFailLogLastAt == nil or (tick() - _deadRestartFailLogLastAt) >= 5) then
            _deadRestartFailLogLastAt = tick()
            local parts = {}
            for _, b in ipairs(allButtons) do
                table.insert(parts, b.name .. "(" .. b.class .. ",vis=" .. tostring(b.vis) .. ",act=" .. tostring(b.act) .. ",text=" .. b.text .. ",restart=" .. tostring(b.hasRestart) .. ")")
            end
            log("DEAD restart: all buttons in card (" .. #allButtons .. "): " .. (next(parts) and table.concat(parts, " | ") or "NONE"))
        end

        if #restartCandidates > 0 then
            return restartCandidates[1]
        end
        return nil
    end

    local function tryHandleDeadCreature(slotCardHint, slotSelected)
        if not slotCardHint or type(slotCardHint.GetDescendants) ~= "function" then
            return false
        end
        local now = tick()
        if _deadRestartLastAt ~= nil and (now - _deadRestartLastAt) < 2.5 then
            return true
        end

        log("DEAD restart: entering tryHandleDeadCreature")

        -- Закрываем промпт Revive, если он открылся случайно.
        dismissRevivePrompt()

        -- DevConsole перехватывает VIM-клики — закрываем, если открыта.
        if isDevConsoleOpen() then
            log("DEAD restart: DevConsole is OPEN, closing before click attempt")
            tryCloseDevConsole()
            wait(0.15)
        end

        -- Шаг 1: если модалка подтверждения рестарта уже открыта — жмём RunButton в ней.
        local promptConfirmed = tryConfirmRestartPrompt()
        if promptConfirmed then
            _deadRestartLastAt = now
            log("DEAD creature: restart CONFIRMED (prompt already open)")
            wait(1.5)
            return true
        end

        -- Шаг 2: ищем RestartButton в карточке (расширенный поиск, с защитой от Revive).
        local slotRestart = findRestartButtonInCard(slotCardHint)
        if not slotRestart then
            -- Fallback: попробуем прямой Remote если GUI не работает.
            local slotName = getSlotNameFromCard(slotCardHint)
            if slotName then
                log("DEAD restart: no RestartButton in card, trying direct remote for slot=" .. tostring(slotName))
                local directOk = tryRestartSlotDirect(slotName)
                if directOk then
                    _deadRestartLastAt = now
                    log("DEAD creature: restart via DIRECT REMOTE ok (no GUI button)")
                    wait(1.5)
                    return true
                end
            end
            return false
        end

        -- Финальная проверка: кнопка НЕ Revive
        if isReviveRelated(slotRestart) then
            log("DEAD restart: BLOCKED — found button is Revive-related, refusing to click")
            return false
        end

        local rp = "?"
        pcall(function() rp = slotRestart:GetFullName() end)
        log("DEAD restart: clicking RestartButton " .. tostring(rp)
                .. " vis=" .. tostring(slotRestart.Visible)
                .. " act=" .. tostring(slotRestart.Active))

        pressActionButton(slotRestart, "Dead creature restart (slot)")
        local upperBtn = slotRestart:FindFirstChild("UpperLabel")
        if upperBtn and upperBtn:IsA("GuiButton") then
            pressActionButton(upperBtn, "Dead creature restart (UpperLabel)")
        end

        wait(0.8)

        -- Шаг 3: ждём модалку подтверждения рестарта и жмём RunButton.
        -- Максимум 6 попыток с паузой 0.5с — без спама.
        for attempt = 1, 6 do
            dismissRevivePrompt()
            local confirmed = tryConfirmRestartPrompt()
            if confirmed then
                _deadRestartLastAt = now
                log("DEAD creature: restart CONFIRMED via prompt (attempt " .. attempt .. ")")
                wait(2)
                return true
            end
            -- На 3-й попытке: повторно кликнуть RestartButton (может промпт не открылся).
            if attempt == 3 then
                dismissRevivePrompt()
                wait(0.3)
                pressActionButton(slotRestart, "Dead creature restart (retry)")
                if upperBtn and upperBtn:IsA("GuiButton") then
                    pressActionButton(upperBtn, "Dead creature restart UpperLabel (retry)")
                end
            end
            wait(0.5)
        end

        -- Шаг 4 (fallback): прямой вызов RestartSlotRemote без Sonar
        local slotName = getSlotNameFromCard(slotCardHint)
        if slotName then
            log("DEAD restart: GUI prompt failed, trying direct remote for slot=" .. tostring(slotName))
            local directOk = tryRestartSlotDirect(slotName)
            if directOk then
                _deadRestartLastAt = now
                log("DEAD creature: restart via DIRECT REMOTE ok")
                wait(2)
                return true
            end
        end

        log("DEAD restart: prompt not found after click -> will retry next cycle")
        return false
    end

    local function dumpSelectedCardOnce(slotCardHint)
        if _selectedCardDumpDone or not slotCardHint or type(slotCardHint.GetDescendants) ~= "function" then
            return
        end
        _selectedCardDumpDone = true
        local rootPath = "?"
        pcall(function()
            rootPath = slotCardHint:GetFullName()
        end)
        local bf = select(1, findButtonsContainerForSlotHint(slotCardHint))
        local function btnState(name)
            local b = bf and bf:FindFirstChild(name)
            if b and b:IsA("GuiButton") then
                return tostring(b.ClassName)
                    .. " vis="
                    .. tostring(b.Visible)
                    .. " act="
                    .. tostring(b.Active)
                    .. " z="
                    .. tostring(b.ZIndex)
            end
            return "missing"
        end
        if _playUiVerbose then
            log("[slotdump] selectedCard=" .. tostring(rootPath))
            log("[slotdump] rbx Play=" .. btnState("PlayButton") .. " Restart=" .. btnState("RestartButton"))
            local shown = 0
            local dumpRoots = { slotCardHint }
            if slotCardHint:IsA("GuiObject") and slotCardHint.Parent then
                table.insert(dumpRoots, slotCardHint.Parent)
            end
            for _, dr in ipairs(dumpRoots) do
                for _, q in ipairs(dr:GetDescendants()) do
                    if q:IsA("GuiButton") then
                        local qPath = "?"
                        pcall(function()
                            qPath = q:GetFullName()
                        end)
                        local txt = ""
                        if q:IsA("TextButton") then
                            txt = tostring(q.Text or "")
                        end
                        log(
                            "[slotdump] btn "
                                .. tostring(shown + 1)
                                .. ": class="
                                .. q.ClassName
                                .. " name="
                                .. tostring(q.Name)
                                .. " text="
                                .. tostring(txt)
                                .. " visible="
                                .. tostring(q.Visible)
                                .. " active="
                                .. tostring(q.Active)
                                .. " z="
                                .. tostring(q.ZIndex)
                                .. " path="
                                .. tostring(qPath)
                        )
                        shown = shown + 1
                        if shown >= 12 then
                            break
                        end
                    end
                end
                if shown >= 12 then
                    break
                end
            end
            if shown == 0 then
                log("[slotdump] no GuiButton descendants in selectedCard")
            end
        else
            log(
                "[slotdump] "
                    .. tostring(rootPath)
                    .. " | ButtonsFrame="
                    .. tostring(bf and bf.Name or "nil")
                    .. " | Play="
                    .. btnState("PlayButton")
                    .. " | Restart="
                    .. btnState("RestartButton")
                    .. " (play_ui_verbose=1 для полного дампа)"
            )
        end
    end

    -- ========== ЧИСТЫЙ ПОТОК: найти карточку → Play или Restart → ничего лишнего ==========

    -- Шаг 0: Если экран слотов не виден — ничего не делаем, ждём.
    local slotsFrame = findSlotsFrame()
    if not slotsFrame then
        return false
    end

    -- Шаг 1: Найти карточку с нужным существом.
    if creatureName == "" then
        -- Без имени — fallback: ищем любую Play кнопку (только для общего случая без конкретного существа).
        local candidates = findPlayButtons()
        if #candidates > 0 then
            return pressActionButton(candidates[1], "PlayButton click (fallback)") == true
        end
        return false
    end

    local nameNode = findNameNode(slotsFrame, creatureName)
    if not nameNode then
        nameNode = findNameNodeNearPlayButton(creatureName)
    end
    if not nameNode then
        local now = tick()
        if now - _playUiSlotMissLastAt >= 20 then
            _playUiSlotMissLastAt = now
            log("Слот «" .. tostring(creatureName) .. "» не найден на экране")
        end
        return false
    end

    local slotCard = findSlotCard(nameNode, slotsFrame)
    if not slotCard then
        return false
    end

    -- Проверяем, что карточка содержит имя существа (не пустой слот).
    local hasCreature = false
    pcall(function()
        for _, desc in ipairs(slotCard:GetDescendants()) do
            if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") then
                if containsLower(string.lower(tostring(desc.Text or "")), creatureName) then
                    hasCreature = true
                    return
                end
            end
        end
    end)
    if not hasCreature then
        log("Карточка не содержит «" .. tostring(creatureName) .. "» — пустой слот, пропускаем")
        return false
    end

    if not _slotFoundLoggedOnce then
        _slotFoundLoggedOnce = true
        log("Слот существа найден: " .. tostring(creatureName))
    end

    -- Шаг 2: Кликнуть по имени чтобы ВЫБРАТЬ карточку — максимум раз в 2с.
    -- Без этого клика кнопки Play/Restart неактивны (Active=false) и игра их игнорирует.
    local now = tick()
    if (_slotNameClickLastAt == nil) or (now - _slotNameClickLastAt) >= 2 then
        _slotNameClickLastAt = now
        clickGui(nameNode, "Creature slot select (name)")
        wait(0.4)
    end

    -- Если после клика по карточке появился промпт Revive — закрываем его.
    dismissRevivePrompt()

    dumpSelectedCardOnce(slotCard)

    -- Шаг 3: Если Play виден → кликнуть Play (существо живо).
    local playBtn = findActionButtonInCard(slotCard, "play")
    if playBtn then
        pressActionButton(playBtn, "PlayButton click")
        return true
    end

    -- Шаг 4: Нет Play → существо мертво → Restart.
    local deadOk, deadResult = pcall(tryHandleDeadCreature, slotCard, true)
    if not deadOk then
        log("tryHandleDeadCreature ERROR: " .. tostring(deadResult))
    elseif deadResult == true then
        return true
    end
    return false
end

local function selectCreature(creatureName)
    local success, selected = pcall(function()
        -- ТОЛЬКО SpawnCreature remote — НЕ кликаем по GUI.
        -- Клики по GUI кнопкам могут попасть на Revive/Create в SaveSelectionGui.
        local spawnEvent = ReplicatedStorage:FindFirstChild("SpawnCreature")
        if spawnEvent and spawnEvent:IsA("RemoteEvent") then
            spawnEvent:FireServer(creatureName)
            return true
        end
        return false
    end)
    
    if not success then
        log("selectCreature pcall failed: " .. tostring(selected))
        return false
    end
    return selected == true
end

-- Перезапуск существа через серверный remote — без GUI, без Revive промптов.
-- Вызывается из handlers.farm после Claim & retry! чтобы существо стало живым перед Play.
local function restartCreatureDirectRemote(creatureName)
    local slotName = nil

    -- Способ 1: слот из player.Settings.Slot
    pcall(function()
        local settings = player:FindFirstChild("Settings")
        if settings then
            local slotOV = settings:FindFirstChild("Slot")
            if slotOV and slotOV.Value then
                slotName = slotOV.Value.Name
            end
        end
    end)

    -- Найти RestartSlotRemote в ReplicatedStorage
    local rf = nil
    pcall(function()
        for _, desc in ipairs(ReplicatedStorage:GetDescendants()) do
            if desc.Name == "RestartSlotRemote" and desc:IsA("RemoteFunction") then
                rf = desc
                break
            end
        end
    end)
    if not rf then
        log("[remote-restart] RestartSlotRemote not found")
        return false
    end

    if slotName then
        log("[remote-restart] slot from Settings: " .. tostring(slotName))
        local ok, res = pcall(function() return rf:InvokeServer(slotName, false) end)
        if ok and res then return true end
    end

    -- Способ 2: перебрать слоты Slot1..Slot5
    for i = 1, 5 do
        local tryName = "Slot" .. tostring(i)
        if tryName ~= slotName then
            local ok, res = pcall(function() return rf:InvokeServer(tryName, false) end)
            if ok and res then
                log("[remote-restart] restarted slot " .. tryName)
                return true
            end
        end
    end

    log("[remote-restart] WARN: не удалось перезапустить существо")
    return false
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
            nextAttemptAt = now + PLAY_CLICK_INTERVAL
        end
        RunService.Heartbeat:Wait()
    end
    return false
end

local function doSuicide()
    log("Performing suicide...")
    
    local success = pcall(function()
        refreshCharacterRefs()
        if humanoid then
            pcall(function() humanoid.Health = 0 end)
        end
        if character and character:FindFirstChild("HumanoidRootPart") then
            character.HumanoidRootPart.CFrame = CFrame.new(0, -1000, 0)
        end
        local suicideEvent = ReplicatedStorage:FindFirstChild("Suicide")
        if suicideEvent then
            suicideEvent:FireServer()
        end
    end)
    
    wait(3)
    refreshCharacterRefs()
    return success
end

-- ========== MISSION SYSTEM: Infrastructure ==========

-- Throttled mission log: avoid spamming the same message
local function mlog(msg, throttleKey, intervalSec)
    intervalSec = intervalSec or 10
    if throttleKey then
        local now = tick()
        if _missionState.logThrottles[throttleKey] and now - _missionState.logThrottles[throttleKey] < intervalSec then
            return
        end
        _missionState.logThrottles[throttleKey] = now
    end
    log("[missions] " .. msg)
end

-- ========== MissionReader ==========
local function getSlotDataFolder()
    local slot = nil
    pcall(function()
        local s = player:FindFirstChild("Settings")
        if s then
            local sv = s:FindFirstChild("Slot")
            if sv and sv:IsA("ObjectValue") and sv.Value then
                slot = sv.Value
            end
        end
    end)
    if slot then return slot end
    pcall(function()
        local pg = player:FindFirstChild("PlayerGui")
        if pg then
            local d = pg:FindFirstChild("Data")
            if d then
                for _, ch in ipairs(d:GetChildren()) do
                    if ch.Name:match("^Slot%d") then
                        slot = ch
                        break
                    end
                end
            end
        end
    end)
    return slot
end

-- Reads per-region mission progress from the correct location in replicated data.
--
-- CRITICAL (verified in rbxlx):
--   Runtime path is `PlayerGui.Data.Missions.RegionMissions.<RegionName>.<MissionType>`.
--   `PlayerData` in the client is `PlayerGui:WaitForChild("Data")` (rbxlx ~5929463).
--   Used by the UI at rbxlx ~6015194: `GetClient().PlayerData.Missions:WaitForChild("RegionMissions")`.
--   Each <MissionType> is a `BoolValue` named e.g. "AttackOrHealCreatureOrNPC"; its
--   `.Value` is the "claimed" flag. Child IntValues `Amount` and `TargetAmount` carry
--   progress. HUD's completion check (rbxlx ~6015296):
--     `amount >= target OR bool.Value`.
--
-- Region subfolder name is the raw RawRegionData key ("Central Rockfaces",
-- "Volcano Island", "Swamp Hill", etc.), not the DisplayName.
local function readRegionMissions(regionName)
    local result = {}
    pcall(function()
        local pg = player:FindFirstChild("PlayerGui")
        if not pg then return end
        local data = pg:FindFirstChild("Data")
        if not data then return end
        local missionsFolder = data:FindFirstChild("Missions")
        if not missionsFolder then return end
        local regionMissions = missionsFolder:FindFirstChild("RegionMissions")
        if not regionMissions then return end
        local regionFolder = regionMissions:FindFirstChild(regionName)
        if not regionFolder then return end

        for _, missionChild in ipairs(regionFolder:GetChildren()) do
            local mType = missionChild.Name
            local amountVal = missionChild:FindFirstChild("Amount")
            local targetVal = missionChild:FindFirstChild("TargetAmount")

            local amount = (amountVal and type(amountVal.Value) == "number") and amountVal.Value or 0
            local targetAmount = (targetVal and type(targetVal.Value) == "number") and targetVal.Value or 0

            -- Claim flag lives on the BoolValue itself, NOT as a `Claimed`/`Value` child.
            local claimed = false
            local ok, val = pcall(function() return missionChild.Value end)
            if ok and type(val) == "boolean" then claimed = val end

            local completed = claimed or (targetAmount > 0 and amount >= targetAmount)

            result[mType] = {
                amount       = amount,
                targetAmount = targetAmount,
                completed    = completed,
                claimed      = claimed,
            }
        end
    end)
    return result
end

-- ========== MoveEngine ==========
local function getHRP()
    refreshCharacterRefs()
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function getPosition()
    local hrp = getHRP()
    if hrp then return hrp.Position end
    return nil
end

local function safeTeleport(x, y, z)
    local hrp = getHRP()
    if not hrp then return false end
    if y < -100 then y = 50 end
    -- Suspicious-distance clamp: don't TP further than the configured max in one go.
    -- (Sonaria has no global speed-hack monitor in our rbxlx audit, but extreme
    -- single-frame jumps still look unnatural to spectators.)
    pcall(function()
        local cur = hrp.Position
        local target = Vector3.new(x, y + 5, z)
        if (cur - target).Magnitude > Stealth.config.maxTeleportDist then
            -- Cap distance: hop toward target instead of all the way.
            local dir = (target - cur).Unit
            local capped = cur + dir * Stealth.config.maxTeleportDist
            x, y, z = capped.X, capped.Y - 5, capped.Z
        end
    end)
    Stealth.beforeTeleport()
    for attempt = 1, 3 do
        pcall(function()
            hrp.CFrame = CFrame.new(x, y + 5, z)
        end)
        task.wait(0.5)
        local pos = getPosition()
        if pos and (Vector3.new(x, y + 5, z) - pos).Magnitude < 100 then
            Stealth.afterTeleport()
            return true
        end
        x = x + (attempt * 5)
        z = z + (attempt * 5)
    end
    Stealth.afterTeleport()
    return true
end

local function safeTeleportVec(vec)
    return safeTeleport(vec[1], vec[2], vec[3])
end

local function walkToward(targetX, targetY, targetZ, maxTime)
    maxTime = maxTime or 8
    refreshCharacterRefs()
    if not humanoid then return false end
    local target = Vector3.new(targetX, targetY, targetZ)
    pcall(function() humanoid:MoveTo(target) end)
    local t0 = tick()
    while tick() - t0 < maxTime do
        local pos = getPosition()
        if pos and (Vector3.new(targetX, pos.Y, targetZ) - Vector3.new(pos.X, pos.Y, pos.Z)).Magnitude < 10 then
            return true
        end
        task.wait(0.3)
    end
    pcall(function() humanoid:MoveTo(humanoid.RootPart.Position) end)
    return false
end

local function distanceBetween(pos, vec)
    if not pos then return 9999 end
    return (pos - Vector3.new(vec[1], vec[2], vec[3])).Magnitude
end

-- ========== RuntimeScanner ==========
local function scanForFood(pos, radius)
    radius = radius or 400
    local best, bestDist = nil, radius
    pcall(function()
        local tagged = CollectionService:GetTagged("Food")
        for _, obj in ipairs(tagged) do
            if obj and obj.Parent and (obj:IsA("BasePart") or obj:IsA("Model")) then
                local p = obj:IsA("Model") and (obj.PrimaryPart and obj.PrimaryPart.Position or obj:GetPivot().Position) or obj.Position
                local d = (pos - p).Magnitude
                if d < bestDist then
                    local val = nil
                    pcall(function() val = obj:GetAttribute("Value") end)
                    if val == nil then
                        pcall(function()
                            local vc = obj:FindFirstChild("Value")
                            if vc and vc:IsA("NumberValue") then val = vc.Value end
                        end)
                    end
                    if val == nil or val > 0 then
                        best = obj
                        bestDist = d
                    end
                end
            end
        end
    end)
    return best, bestDist
end

local function scanForWater(pos, radius)
    radius = radius or 600
    local best, bestDist = nil, radius
    pcall(function()
        local tagged = CollectionService:GetTagged("DrinkableWater")
        for _, obj in ipairs(tagged) do
            if obj and obj.Parent then
                local p = obj:IsA("Model") and obj:GetPivot().Position or obj.Position
                local d = (pos - p).Magnitude
                if d < bestDist then
                    best = obj
                    bestDist = d
                end
            end
        end
    end)
    if not best then
        pcall(function()
            local waterNames = {Lake = true, lake = true, Water = true, water = true, Pond = true, pond = true, Oasis = true, MagicalLake = true}
            for _, obj in ipairs(workspace:GetDescendants()) do
                if obj:IsA("BasePart") and obj.Size.Magnitude > 20 then
                    if waterNames[obj.Name] or obj.Name:find("[Ll]ake") or obj.Name:find("[Ww]ater") then
                        local d = (pos - obj.Position).Magnitude
                        if d < bestDist then
                            best = obj
                            bestDist = d
                        end
                    end
                end
            end
        end)
    end
    return best, bestDist
end

local function scanForNPCs(pos, radius)
    radius = radius or 400
    local results = {}
    pcall(function()
        local npcFolder = workspace:FindFirstChild("NPCs")
        if npcFolder then
            for _, obj in ipairs(npcFolder:GetChildren()) do
                if obj:IsA("Model") and obj.PrimaryPart then
                    local d = (pos - obj.PrimaryPart.Position).Magnitude
                    if d < radius then
                        table.insert(results, {model = obj, distance = d, position = obj.PrimaryPart.Position})
                    end
                end
            end
        end
        local tagged = CollectionService:GetTagged("NPC")
        for _, obj in ipairs(tagged) do
            if obj and obj.Parent then
                local p = obj:IsA("Model") and (obj.PrimaryPart and obj.PrimaryPart.Position or obj:GetPivot().Position) or obj.Position
                local d = (pos - p).Magnitude
                if d < radius then
                    local already = false
                    for _, r in ipairs(results) do
                        if r.model == obj then already = true; break end
                    end
                    if not already then
                        table.insert(results, {model = obj, distance = d, position = p})
                    end
                end
            end
        end
    end)
    table.sort(results, function(a, b) return a.distance < b.distance end)
    return results
end

local function scanForMud(pos, radius)
    radius = radius or 400
    local best, bestDist = nil, radius
    pcall(function()
        local tagged = CollectionService:GetTagged("Mud")
        for _, obj in ipairs(tagged) do
            if obj and obj.Parent then
                local p = obj:IsA("Model") and (obj.PrimaryPart and obj.PrimaryPart.Position or obj:GetPivot().Position) or obj.Position
                local d = (pos - p).Magnitude
                if d < bestDist then
                    best = obj
                    bestDist = d
                end
            end
        end
    end)
    return best, bestDist
end

local function scanForShoomPiles(regionName)
    local results = {}
    pcall(function()
        local folder = workspace:FindFirstChild("Interactions")
        if folder then
            local shoomFolder = folder:FindFirstChild("ShoomPiles")
            if shoomFolder then
                for _, obj in ipairs(shoomFolder:GetDescendants()) do
                    if obj:IsA("Model") or obj:IsA("BasePart") then
                        local reg = nil
                        pcall(function() reg = obj:GetAttribute("Region") end)
                        if reg == regionName then
                            local id = nil
                            pcall(function() id = obj:GetAttribute("Id") end)
                            local p = obj:IsA("Model") and (obj.PrimaryPart and obj.PrimaryPart.Position or obj:GetPivot().Position) or obj.Position
                            table.insert(results, {model = obj, region = reg, id = id, position = p})
                        end
                    end
                end
            end
        end
    end)
    return results
end

-- ========== SurvivalGuard ==========
local _maxFoodSeen = 0
local _maxWaterSeen = 0

local function getCreatureStats()
    local stats = {food = 999, water = 999, hp = 100, maxFood = 100, maxWater = 100}
    pcall(function()
        local slot = getSlotDataFolder()
        if slot then
            local foodVal = slot:FindFirstChild("Food")
            if foodVal then stats.food = foodVal.Value or 0 end
            local waterVal = slot:FindFirstChild("Water")
            if waterVal then stats.water = waterVal.Value or 0 end
        end
    end)
    if stats.food ~= 999 and stats.food > _maxFoodSeen then _maxFoodSeen = stats.food end
    if stats.water ~= 999 and stats.water > _maxWaterSeen then _maxWaterSeen = stats.water end
    stats.maxFood = _maxFoodSeen > 0 and _maxFoodSeen or 100
    stats.maxWater = _maxWaterSeen > 0 and _maxWaterSeen or 100
    pcall(function()
        refreshCharacterRefs()
        if character then
            local hp = character:GetAttribute("Health")
            if type(hp) == "number" then stats.hp = hp end
        end
    end)
    return stats
end

-- Read max appetite / thirst for the CURRENT creature directly from CharacterData
-- attributes. Creatures grow over time and their tanks scale up — relying on a
-- historical maxSeen value produces false "full" readings (rbxlx ~5901703:
-- compressed attr keys are "a"=Appetite, "ta"=ThirstAppetite).
local function getCurrentMaxFor(kind)
    local cap = nil
    pcall(function()
        refreshCharacterRefs()
        if not character then return end
        local dataInst = nil
        for _, inst in ipairs(character:GetDescendants()) do
            if inst:HasTag("CharacterData") then dataInst = inst; break end
        end
        if not dataInst then dataInst = character:FindFirstChild("Data") end
        if not dataInst then return end
        local attrKey = (kind == "food") and "a" or "ta"
        local fallback = (kind == "food") and "Appetite" or "ThirstAppetite"
        local v = dataInst:GetAttribute(attrKey) or dataInst:GetAttribute(fallback)
        if type(v) == "number" and v > 0 then cap = v end
    end)
    return cap
end

local function isFull(stats, kind)
    -- Prefer the live CharacterData attribute: it's the exact current max.
    local realMax = getCurrentMaxFor(kind)
    local cur = (kind == "food") and stats.food or stats.water
    if realMax and realMax > 0 then
        return cur >= realMax * 0.95
    end
    -- Fallback: use historical max (old behavior) if attribute is unreadable.
    if cur >= 999 then return true end
    if kind == "food" then
        if _maxFoodSeen > 0 and cur >= _maxFoodSeen * 0.95 then return true end
    else
        if _maxWaterSeen > 0 and cur >= _maxWaterSeen * 0.95 then return true end
    end
    return false
end

local function needsSurvivalAction(stats)
    if stats.hp < SURVIVAL_HP_CRITICAL then return "flee" end
    if stats.food < SURVIVAL_FOOD_CRITICAL and not isFull(stats, "food") then return "food" end
    if stats.water < SURVIVAL_WATER_CRITICAL and not isFull(stats, "water") then return "water" end
    return nil
end

local _remoteCache = {}
local function getRemoteEvent(name)
    if _remoteCache["e:" .. name] then return _remoteCache["e:" .. name] end
    local re = nil
    pcall(function()
        for _, desc in ipairs(ReplicatedStorage:GetDescendants()) do
            if desc.Name == name and desc:IsA("RemoteEvent") then
                re = desc; break
            end
        end
    end)
    if re then _remoteCache["e:" .. name] = re end
    return re
end

local function getRemoteFunction(name)
    if _remoteCache["f:" .. name] then return _remoteCache["f:" .. name] end
    local rf = nil
    pcall(function()
        for _, desc in ipairs(ReplicatedStorage:GetDescendants()) do
            if desc.Name == name and desc:IsA("RemoteFunction") then
                rf = desc; break
            end
        end
    end)
    if rf then _remoteCache["f:" .. name] = rf end
    return rf
end

local function doEatFood(foodObj)
    if not foodObj or not foodObj.Parent then return false end
    local statsBefore = getCreatureStats()
    if isFull(statsBefore, "food") then
        mlog("Already full (food=" .. tostring(statsBefore.food) .. "/" .. tostring(_maxFoodSeen) .. "), skip eat", "full_skip", 15)
        return false
    end
    local fp = foodObj:IsA("Model")
        and (foodObj.PrimaryPart and foodObj.PrimaryPart.Position or foodObj:GetPivot().Position)
        or foodObj.Position
    local hrp = getHRP()
    if not hrp then return false end
    pcall(function() hrp.CFrame = CFrame.new(fp.X, fp.Y + 1, fp.Z) end)
    task.wait(0.3)
    local re = getRemoteEvent("Food")
    if re then
        local prevFood = statsBefore.food
        for i = 1, 6 do
            pcall(function() re:FireServer(foodObj) end)
            task.wait(1.2)
            local s = getCreatureStats()
            if isFull(s, "food") then
                mlog("Ate until full (food=" .. tostring(s.food) .. ")", "eat_done", 10)
                break
            end
            if i > 2 and s.food <= prevFood then
                mlog("Food value unchanged (" .. tostring(s.food) .. "), source empty or full", "eat_no_change", 10)
                break
            end
            prevFood = s.food
        end
        return true
    end
    return false
end

local function doDrinkWater(waterObj)
    if not waterObj or not waterObj.Parent then return false end
    local statsBefore = getCreatureStats()
    if isFull(statsBefore, "water") then
        mlog("Already full water (water=" .. tostring(statsBefore.water) .. "/" .. tostring(_maxWaterSeen) .. "), skip drink", "full_skip_w", 15)
        return false
    end
    local wp = waterObj:IsA("Model") and waterObj:GetPivot().Position or waterObj.Position
    local hrp = getHRP()
    if not hrp then return false end
    pcall(function() hrp.CFrame = CFrame.new(wp.X, wp.Y + 2, wp.Z) end)
    task.wait(0.3)
    local isBuildable = false
    pcall(function() isBuildable = waterObj:HasTag("Buildable") end)
    local reName = isBuildable and "DrinkBuildableWater" or "DrinkRemote"
    local re = getRemoteEvent(reName)
    if re then
        local prevWater = statsBefore.water
        for i = 1, 6 do
            pcall(function() re:FireServer(waterObj) end)
            task.wait(1.5)
            local s = getCreatureStats()
            if isFull(s, "water") then
                mlog("Drank until full (water=" .. tostring(s.water) .. ")", "drink_done", 10)
                break
            end
            if i > 2 and s.water <= prevWater then
                mlog("Water value unchanged (" .. tostring(s.water) .. "), source empty or full", "drink_no_change", 10)
                break
            end
            prevWater = s.water
        end
        return true
    end
    return false
end

local function doEmergencyRefill(need)
    local pos = getPosition()
    if not pos then return false end
    if need == "food" then
        local s = getCreatureStats()
        if isFull(s, "food") then return true end
        local food, dist = scanForFood(pos, 600)
        if food then
            mlog("Refill: eating food at dist=" .. math.floor(dist), "refill_food", 5)
            doEatFood(food)
            return true
        end
    elseif need == "water" then
        local s = getCreatureStats()
        if isFull(s, "water") then return true end
        local water, dist = scanForWater(pos, 800)
        if water then
            mlog("Refill: drinking water at dist=" .. math.floor(dist), "refill_water", 5)
            doDrinkWater(water)
            return true
        end
    elseif need == "flee" then
        local biome = BIOME_ATLAS[_missionState.currentBiomeIdx]
        if biome then
            safeTeleportVec(biome.safe)
            task.wait(2)
        end
        return true
    end
    return false
end

-- ========== Mission Executors ==========

local function execEatFoodDrinkWater()
    local pos = getPosition()
    if not pos then return false end
    local stats = getCreatureStats()
    if isFull(stats, "food") and isFull(stats, "water") then
        mlog("Both food and water full, skip eat/drink mission step", "eat_drink_full", 15)
        return true
    end
    local doWater = stats.water < stats.food
    if isFull(stats, "food") then doWater = true end
    if isFull(stats, "water") then doWater = false end
    if _missionState.eatDrinkToggle == "water" and not isFull(stats, "water") then doWater = true end
    _missionState.eatDrinkToggle = doWater and "food" or "water"

    if doWater then
        local water, dist = scanForWater(pos, 800)
        if water then
            doDrinkWater(water)
            task.wait(1)
            return true
        end
    else
        local food, dist = scanForFood(pos, 600)
        if food then
            doEatFood(food)
            task.wait(1)
            return true
        end
    end
    mlog("No food/water found nearby, moving to biome center", "no_food_water", 30)
    local biome = BIOME_ATLAS[_missionState.currentBiomeIdx]
    if biome then safeTeleportVec(biome.entry) end
    return false
end

local function findNearbyPlayers(pos, radius)
    radius = radius or 400
    local results = {}
    pcall(function()
        local myPlayer = game:GetService("Players").LocalPlayer
        for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
            if p ~= myPlayer and p.Character then
                local hrpOther = p.Character:FindFirstChild("HumanoidRootPart")
                if hrpOther then
                    local d = (pos - hrpOther.Position).Magnitude
                    if d < radius and d > 5 then
                        table.insert(results, {model = p.Character, distance = d, position = hrpOther.Position, name = p.Name})
                    end
                end
            end
        end
    end)
    table.sort(results, function(a, b) return a.distance < b.distance end)
    return results
end

local function execAttackOrHealNPC()
    local pos = getPosition()
    if not pos then return false end
    local safePos = pos

    local npcs = scanForNPCs(pos, 500)
    if #npcs > 0 then
        local target = npcs[1]
        safeTeleport(target.position.X, target.position.Y + 2, target.position.Z)
        task.wait(0.3)
        pcall(function()
            local dmgRemote = getRemoteEvent("MobDamageRemote")
            if dmgRemote then dmgRemote:FireServer({target.model}) end
        end)
        pcall(function()
            local charDmg = getRemoteEvent("CharactersDamageRemote")
            if charDmg then charDmg:FireServer({target.model}) end
        end)
        task.wait(0.5)
        safeTeleport(safePos.X, safePos.Y + 3, safePos.Z)
        task.wait(0.5)
        mlog("Attacked NPC at dist=" .. math.floor(target.distance), "atk_npc", 10)
        return true
    end

    local players = findNearbyPlayers(pos, 500)
    if #players > 0 then
        local target = players[1]
        safeTeleport(target.position.X, target.position.Y + 2, target.position.Z)
        task.wait(0.2)
        pcall(function()
            local charDmg = getRemoteEvent("CharactersDamageRemote")
            if charDmg then charDmg:FireServer({target.model}) end
        end)
        task.wait(0.3)
        safeTeleport(safePos.X, safePos.Y + 3, safePos.Z)
        task.wait(0.5)
        mlog("Attacked player " .. target.name .. " at dist=" .. math.floor(target.distance), "atk_player", 10)
        return true
    end

    _missionState.attackRetryCount = (_missionState.attackRetryCount or 0) + 1
    if _missionState.attackRetryCount > 3 then
        mlog("No NPCs or players found, marking stuck", "no_targets", 30)
        local stuckKey = (_missionState.currentBiomeIdx or 1) .. ":AttackOrHealCreatureOrNPC"
        _missionState.missionStuckTimers[stuckKey] = tick()
        _missionState.attackRetryCount = 0
        return false
    end
    local biome = BIOME_ATLAS[_missionState.currentBiomeIdx]
    if biome and biome.walk and #biome.walk > 0 then
        safeTeleportVec(biome.walk[math.random(1, #biome.walk)])
    end
    return false
end

local function execConcealScent()
    local biome = BIOME_ATLAS[_missionState.currentBiomeIdx]
    if not biome or biome.zone ~= "Land" then return false end
    local pos = getPosition()
    if not pos then return false end
    local mud, dist = scanForMud(pos, 600)
    if not mud then
        mlog("No mud found for ConcealScent", "no_mud", 30)
        return false
    end
    local mp = mud:IsA("Model") and mud:GetPivot().Position or mud.Position
    local hrp = getHRP()
    if not hrp then return false end
    pcall(function() hrp.CFrame = CFrame.new(mp.X, mp.Y + 1, mp.Z) end)
    task.wait(0.5)
    pcall(function()
        local re = getRemoteEvent("Mud")
        if re then
            local root = mud:IsA("Model") and (mud.PrimaryPart or mud:FindFirstChildWhichIsA("BasePart")) or mud
            re:FireServer(root)
        end
    end)
    task.wait(1)
    pcall(function()
        local re = getRemoteEvent("HideScent")
        if re then re:FireServer() end
    end)
    task.wait(2)
    return true
end

local function execSniff()
    local now = tick()
    if now - _missionState.lastSniffTime < 18 then return false end
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.H, false, game)
        task.wait(0.15)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.H, false, game)
    end)
    _missionState.lastSniffTime = now
    task.wait(1)
    return true
end

local function execDistanceTravelled()
    local biome = BIOME_ATLAS[_missionState.currentBiomeIdx]
    if not biome or not biome.walk or #biome.walk == 0 then return false end
    local idx = _missionState.walkLoopIdx
    if idx > #biome.walk then idx = 1 end
    local wp = biome.walk[idx]
    local pos = getPosition()
    if not pos then return false end
    local dist = distanceBetween(pos, wp)
    if dist > 100 then
        safeTeleportVec(wp)
        _missionState.walkLoopIdx = idx + 1
        task.wait(0.5)
        return true
    end
    local arrived = walkToward(wp[1], wp[2], wp[3], 6)
    _missionState.walkLoopIdx = idx + 1
    task.wait(0.3)
    return true
end

local function execShoomPilesCollected()
    local biome = BIOME_ATLAS[_missionState.currentBiomeIdx]
    if not biome then return false end
    local piles = scanForShoomPiles(biome.name)
    if #piles == 0 then
        _missionState.shoomRetryCount = (_missionState.shoomRetryCount or 0) + 1
        if _missionState.shoomRetryCount > 5 then
            mlog("No shoom piles in " .. biome.name .. ", skipping", "no_shoom", 60)
            return false
        end
        return false
    end
    _missionState.shoomRetryCount = 0
    local pile = piles[math.random(1, #piles)]
    local pos = getPosition()
    if pos and pile.position then
        safeTeleport(pile.position.X, pile.position.Y + 3, pile.position.Z)
        task.wait(0.5)
    end
    pcall(function()
        local rf = getRemoteFunction("ShoomPileCollected")
        if rf and pile.region and pile.id then
            rf:InvokeServer(pile.region, pile.id)
        end
    end)
    task.wait(1)
    return true
end

local function execTimePlayed()
    local stats = getCreatureStats()
    local need = needsSurvivalAction(stats)
    if need then
        doEmergencyRefill(need)
    end
    task.wait(1)
    return true
end

-- Mission executor dispatch
local MISSION_EXECUTORS = {
    EatFoodDrinkWater          = execEatFoodDrinkWater,
    AttackOrHealCreatureOrNPC  = execAttackOrHealNPC,
    ConcealScent               = execConcealScent,
    Sniff                      = execSniff,
    DistanceTravelled          = execDistanceTravelled,
    ShoomPilesCollected        = execShoomPilesCollected,
    TimePlayed                 = execTimePlayed,
}

-- ========== MissionPlanner + BiomeRotation + FarmLoop ==========

local function isBiomeComplete(regionName)
    local missions = readRegionMissions(regionName)
    if not next(missions) then return true end
    for mType, m in pairs(missions) do
        if not m.completed then return false end
    end
    return true
end

local function canExecuteMission(mType, mData, zone)
    if mData.completed then return false end
    if mType == "ConcealScent" and zone ~= "Land" then return false end
    if mType == "EatFoodDrinkWater" then
        local stats = getCreatureStats()
        if isFull(stats, "food") and isFull(stats, "water") then return false end
    end
    local stuckKey = (_missionState.currentBiomeIdx or 1) .. ":" .. mType
    local stuckTime = _missionState.missionStuckTimers[stuckKey] or 0
    if tick() - stuckTime < 90 then return false end
    return true
end

local MISSION_PRIORITY = {
    AttackOrHealCreatureOrNPC = 1,
    ConcealScent = 2,
    Sniff = 3,
    ShoomPilesCollected = 4,
    EatFoodDrinkWater = 5,
    DistanceTravelled = 6,
    TimePlayed = 99,
}

local function pickNextMission(regionName, zone)
    local missions = readRegionMissions(regionName)
    local bestType, bestData, bestPrio = nil, nil, 999
    for mType, mData in pairs(missions) do
        if canExecuteMission(mType, mData, zone) then
            local prio = MISSION_PRIORITY[mType] or 50
            if prio < bestPrio then
                bestType = mType
                bestData = mData
                bestPrio = prio
            end
        end
    end
    if bestType then return bestType, bestData end
    return nil, nil
end

local function switchBiome()
    local startIdx = _missionState.currentBiomeIdx
    for i = 1, #BIOME_ATLAS do
        local idx = ((startIdx - 1 + i) % #BIOME_ATLAS) + 1
        local biome = BIOME_ATLAS[idx]
        if not isBiomeComplete(biome.name) then
            _missionState.currentBiomeIdx = idx
            _missionState.walkLoopIdx = 1
            _missionState.shoomRetryCount = 0
            _missionState.attackRetryCount = 0
            _missionState.biomeEnteredTime = tick()
            _missionState.missionStuckTimers = {}
            mlog("Switching to biome: " .. biome.name .. " (" .. biome.zone .. ")", nil)
            safeTeleportVec(biome.entry)
            task.wait(1)
            return true
        end
    end
    mlog("All biomes complete!", nil)
    return false
end

-- AntiStuck detection
local function checkAntiStuck()
    local pos = getPosition()
    if not pos then return false end
    local lastPos = _missionState.lastPositions
    local now = tick()
    if lastPos.pos and (now - (lastPos.time or 0)) > 3 then
        local delta = (pos - lastPos.pos).Magnitude
        if delta < 5 then
            _missionState.stuckTimer = (_missionState.stuckTimer or 0) + (now - (lastPos.time or now))
        else
            _missionState.stuckTimer = 0
        end
        lastPos.pos = pos
        lastPos.time = now
    elseif not lastPos.pos then
        lastPos.pos = pos
        lastPos.time = now
    end
    if _missionState.stuckTimer > 10 then
        mlog("Stuck detected! Recovering...", "stuck", 15)
        _missionState.stuckTimer = 0
        pcall(function()
            refreshCharacterRefs()
            if humanoid then
                humanoid.Jump = true
            end
        end)
        task.wait(0.5)
        local biome = BIOME_ATLAS[_missionState.currentBiomeIdx]
        if biome and biome.walk and #biome.walk > 0 then
            local wp = biome.walk[math.random(1, #biome.walk)]
            safeTeleportVec(wp)
        end
        return true
    end
    return false
end

-- Forward declaration for doMissionStep; real body is defined below,
-- AFTER `handlers` table and all `handlers.test_*` assignments, so that
-- those upvalue references resolve correctly at call time.
local doMissionStep

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

local function findLavaPart()
    -- Try CollectionService tags first
    local ok, parts = pcall(function()
        return game:GetService("CollectionService"):GetTagged("Lava")
    end)
    if ok and parts and #parts > 0 then
        for _, p in ipairs(parts) do
            if p:IsA("BasePart") and p.Size.Magnitude > 5 then
                return p
            end
        end
    end
    -- Search workspace for parts named "Lava"
    local found = nil
    pcall(function()
        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "Lava" and obj.Size.Magnitude > 5 then
                found = obj
                return
            end
        end
    end)
    return found
end

-- Standalone button click helper (top-level, usable from tryClaimDeathRewards etc.)
local function clickButtonTopLevel(btn, label)
    if not btn or not btn:IsA("GuiButton") then return false end
    label = label or "btn"
    local ok = false

    -- Force active
    pcall(function() btn.Active = true; btn.Selectable = true end)

    -- getconnections → fire handlers
    pcall(function()
        if type(getconnections) == "function" then
            for _, sig in ipairs({btn.Activated, btn.MouseButton1Click}) do
                local conns = getconnections(sig)
                if conns then
                    for _, c in pairs(conns) do
                        local fn = nil
                        pcall(function() fn = c and c.Function end)
                        if type(fn) == "function" then pcall(fn); ok = true end
                    end
                end
            end
        end
    end)

    -- firesignal
    pcall(function()
        if type(firesignal) == "function" then
            if btn.Activated then firesignal(btn.Activated); ok = true end
            if btn.MouseButton1Click then firesignal(btn.MouseButton1Click); ok = true end
        end
    end)

    -- Activate()
    pcall(function() btn:Activate(); ok = true end)

    -- VIM click (center of button)
    pcall(function()
        local pos = btn.AbsolutePosition + (btn.AbsoluteSize / 2)
        local inset = GuiService:GetGuiInset()
        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y + inset.Y, 0, true, game, 0)
        wait(0.05)
        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y + inset.Y, 0, false, game, 0)
        ok = true
    end)

    log(label .. ": clicked " .. tostring(btn.Name) .. " ok=" .. tostring(ok))
    return ok
end

-- Death reward tiers (from DeathRewards module in game data)
local DEATH_REWARD_TIERS = {
    { points = 50,   name = "RandomStoredCreatureToken",  display = "Random Trial Creature Token" },
    { points = 100,  name = "ChangeCreatureColorsToken",  display = "Appearance Change Token" },
    { points = 150,  name = "PartialGrowToken",           display = "Partial Growth Token" },
    { points = 350,  name = "FullGrowToken",              display = "Max Growth Token" },
    { points = 750,  name = "CreatureReviveToken",        display = "Revive Token" },
    { points = 1200, name = "DeathGachaToken",            display = "Death Gacha Token" },
}

local function calcEarnedTokens(deathPoints)
    local tokens = {}
    for _, tier in ipairs(DEATH_REWARD_TIERS) do
        if deathPoints >= tier.points then
            tokens[tier.display] = (tokens[tier.display] or 0) + 1
        end
    end
    return tokens
end

local function tryClaimDeathRewards(deathPoints)
    log("Ожидание экрана смерти (DeathGui)...")
    local gui = player:FindFirstChild("PlayerGui")
    if not gui then
        log("WARN: нет PlayerGui для claim")
        return {}
    end

    -- Wait for DeathGui to become visible
    local deathGui = nil
    local containerFrame = nil
    local deadline = tick() + 15
    while tick() < deadline do
        deathGui = gui:FindFirstChild("DeathGui")
        if deathGui then
            containerFrame = deathGui:FindFirstChild("ContainerFrame")
            if containerFrame and containerFrame.Visible then
                log("DeathGui найден и видим")
                break
            end
        end
        wait(0.5)
    end

    if not containerFrame or not containerFrame.Visible then
        log("WARN: DeathGui не появился за 15с, пробуем ClaimDeathRewardsRemote напрямую")
        pcall(function()
            local RemoteUtils = require(ReplicatedStorage:FindFirstChild("Sonar"):FindFirstChild("RemoteUtils"))
            local claimRemote = RemoteUtils.GetRemoteFunction("ClaimDeathRewardsRemote")
            if claimRemote then claimRemote:InvokeServer() end
        end)
        return calcEarnedTokens(deathPoints)
    end

    wait(2)

    -- Click "Claim & retry!" button: ContainerFrame > BottomFrame > ButtonsFrame > Return
    -- CoS uses NewButton:RegisterClick → the handler is on UpperLabel (ImageButton) inside the button.
    local returnBtn = nil
    pcall(function()
        local bottomFrame = containerFrame:FindFirstChild("BottomFrame")
        if not bottomFrame then return end
        local buttonsFrame = bottomFrame:FindFirstChild("ButtonsFrame")
        if not buttonsFrame then return end
        returnBtn = buttonsFrame:FindFirstChild("Return")
    end)

    if returnBtn then
        local upperLabel = returnBtn:FindFirstChild("UpperLabel")
        local clickTarget = (upperLabel and upperLabel:IsA("GuiButton")) and upperLabel or returnBtn

        for attempt = 1, 5 do
            local closed = false
            pcall(function()
                closed = not containerFrame or not containerFrame.Visible
            end)
            if closed then break end

            log("Нажимаем 'Claim & retry!' попытка " .. attempt)
            clickButtonTopLevel(clickTarget, "Claim & retry")
            wait(2)
        end
    else
        log("WARN: кнопка Return не найдена в DeathGui")
    end

    -- Если после 5 кликов DeathGui всё ещё видим — remote fallback
    wait(1)
    local stillVisible = false
    pcall(function()
        stillVisible = containerFrame and containerFrame.Visible
    end)
    if stillVisible then
        log("DeathGui всё ещё видим после кликов, пробуем ClaimDeathRewardsRemote напрямую")
        pcall(function()
            for _, desc in ipairs(ReplicatedStorage:GetDescendants()) do
                if desc.Name == "ClaimDeathRewardsRemote" and desc:IsA("RemoteFunction") then
                    desc:InvokeServer()
                    break
                end
            end
        end)
        wait(2)
    end

    local tokens = calcEarnedTokens(deathPoints)
    local tokenLog = {}
    for k, v in pairs(tokens) do
        table.insert(tokenLog, k .. "=" .. tostring(v))
    end
    log("Награды за смерть (DP=" .. tostring(deathPoints) .. "): " .. (next(tokens) and table.concat(tokenLog, ", ") or "нет"))
    return tokens
end

local function doSuicideVolcano(preSuicideDP)
    log("Суицид в лаве — ищем лаву... (DP перед смертью=" .. tostring(preSuicideDP) .. ")")
    refreshCharacterRefs()
    if not character or not character:FindFirstChild("HumanoidRootPart") then
        log("WARN: нет персонажа для суицида")
        return {}
    end
    local hrp = character.HumanoidRootPart

    -- Try dynamic lava search
    local lavaPart = findLavaPart()
    local targetCFrame
    if lavaPart then
        targetCFrame = lavaPart.CFrame
        log("Лава найдена динамически: " .. lavaPart:GetFullName()
            .. " pos=" .. tostring(math.floor(targetCFrame.X)) .. ","
            .. tostring(math.floor(targetCFrame.Y)) .. ","
            .. tostring(math.floor(targetCFrame.Z)))
    else
        targetCFrame = CFrame.new(VOLCANO_X, VOLCANO_Y, VOLCANO_Z)
        log("Лава не найдена, используем дефолт: " .. tostring(VOLCANO_X) .. "," .. tostring(VOLCANO_Y) .. "," .. tostring(VOLCANO_Z))
    end

    -- Teleport into lava
    pcall(function() hrp.CFrame = targetCFrame end)
    wait(0.5)

    -- Fire LavaSelfDamage remote repeatedly to guarantee death
    local lavaDamageRemote = nil
    pcall(function()
        local RemoteUtils = require(ReplicatedStorage:FindFirstChild("Sonar"):FindFirstChild("RemoteUtils"))
        lavaDamageRemote = RemoteUtils.GetRemoteEvent("LavaSelfDamage")
    end)
    if not lavaDamageRemote then
        pcall(function()
            for _, desc in ipairs(ReplicatedStorage:GetDescendants()) do
                if desc.Name == "LavaSelfDamage" and desc:IsA("RemoteEvent") then
                    lavaDamageRemote = desc
                    break
                end
            end
        end)
    end

    local deathTimeout = tick() + 15
    while tick() < deathTimeout do
        if not isCreatureAlive() then
            log("Суицид в лаве: существо мертво")
            break
        end
        local currentHrp = character and character:FindFirstChild("HumanoidRootPart")
        if currentHrp then
            pcall(function() currentHrp.CFrame = targetCFrame end)
        end
        if lavaDamageRemote then
            pcall(function() lavaDamageRemote:FireServer() end)
        end
        wait(0.3)
    end

    -- Fallback: force kill if still alive after timeout
    if isCreatureAlive() then
        log("WARN: лава не убила за 15с, форсируем")
        pcall(function()
            if humanoid then humanoid.Health = 0 end
        end)
        pcall(function()
            if character and character:FindFirstChild("HumanoidRootPart") then
                character.HumanoidRootPart.CFrame = CFrame.new(0, -500, 0)
            end
        end)
        wait(3)
    end

    -- Claim death rewards (death screen with "Claim & retry!")
    wait(2)
    local earnedTokens = tryClaimDeathRewards(preSuicideDP or 0)

    -- Wait for slot selection screen after claim
    wait(2)
    log("Суицид в лаве: rewards claimed, ожидание слота...")
    return earnedTokens
end

local function ensureDefaultCreatureAfterRespawn()
    log("Перезапуск существа (выбор): " .. DEFAULT_CREATURE)
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

-- Teleport to Trade Realm via the game's RemoteFunction `TeleportToRemote`.
--
-- VERIFIED in rbxlx ~6142777-6142790 (server OnServerInvoke):
--   TeleportToRemote.OnServerInvoke = function(player, mode, ...)
--       if mode == "ToPlaceId"   then return TeleportToPlace(player, ...)
--       elseif mode == "ToPlaceType" then return TeleportToPlaceType(player, ...)
--       elseif mode == "ToPlaceName" then return TeleportToPlaceName(player, ...)
--       elseif mode == "FollowPlayer" then return FollowPlayer(player, ...)
--       end
--   end
--
-- `ToPlaceType "Trade"` resolves to the Trade Realm via GetPlacesByType (rbxlx
-- ~6142679). Direct remote lookup (no `require(Sonar)`) avoids the historical
-- require-deadlock the script hit on first-run; getRemoteFunction caches the
-- instance across calls.
local function tryCoSTeleportToTradeRealm()
    local rf = getRemoteFunction("TeleportToRemote")
    if not rf or type(rf.InvokeServer) ~= "function" then
        return false, "TeleportToRemote RF not found in ReplicatedStorage"
    end

    -- Primary: ToPlaceType "Trade" — lets the server pick the right Trade place
    -- (Main Trade Realm or Test Trade Realm based on PlaceContext).
    local ok, a, b = pcall(function()
        return rf:InvokeServer("ToPlaceType", "Trade", {})
    end)
    if not ok then
        return false, "InvokeServer(ToPlaceType) errored: " .. tostring(a)
    end
    if a == false then
        log("[trade-tp] ToPlaceType returned false, falling back to ToPlaceId=" .. tostring(TRADE_REALM_PLACE_ID))
        ok, a, b = pcall(function()
            return rf:InvokeServer("ToPlaceId", TRADE_REALM_PLACE_ID, {})
        end)
        if not ok then
            return false, "InvokeServer(ToPlaceId) errored: " .. tostring(a)
        end
        if a == false then
            return false, "ToPlaceId rejected: " .. tostring(b)
        end
    end

    -- Teleport request accepted. Wait a few seconds for the place load to begin;
    -- the script context ends when the character is rebuilt in the new place.
    log("[trade-tp] Teleport accepted, waiting for place load...")
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

-- ========== TEST HANDLERS ==========

local function detectCurrentRegion()
    local pos = getPosition()
    if not pos then return "Unknown", nil end
    local bestName, bestDist, bestBiome = "Unknown", 99999, nil
    for idx, biome in ipairs(BIOME_ATLAS) do
        local entry = Vector3.new(biome.entry[1], biome.entry[2], biome.entry[3])
        local d = (pos - entry).Magnitude
        if d < bestDist then
            bestDist = d
            bestName = biome.name
            bestBiome = biome
        end
    end
    return bestName, bestBiome
end

local function getCreatureAppetite()
    local appetite, thirst = nil, nil

    -- 1) Runtime CharacterData on the current character model.
    -- The tag "CharacterData" is attached to a child named "Data" (or similar Configuration/Folder)
    -- whose attributes hold stats under compressed keys: Appetite="a", ThirstAppetite="ta".
    pcall(function()
        refreshCharacterRefs()
        if not character then return end
        local dataInst = nil
        for _, inst in ipairs(character:GetDescendants()) do
            if inst:HasTag("CharacterData") then
                dataInst = inst
                break
            end
        end
        if not dataInst then
            dataInst = character:FindFirstChild("Data")
        end
        if dataInst then
            local a = dataInst:GetAttribute("a") or dataInst:GetAttribute("Appetite")
            local ta = dataInst:GetAttribute("ta") or dataInst:GetAttribute("ThirstAppetite")
            if type(a) == "number" then appetite = a end
            if type(ta) == "number" then thirst = ta end
        end
    end)
    if appetite and thirst then return appetite, thirst end

    -- 2) CharacterData module in ReplicatedStorage (by species key).
    pcall(function()
        local slot = getSlotDataFolder()
        if not slot then return end
        local dino = slot:FindFirstChild("Dino")
        local morph = slot:FindFirstChild("Morph")
        if dino and dino.Value then
            local rs = game:GetService("ReplicatedStorage")
            local charDataMod = nil
            for _, obj in ipairs(rs:GetDescendants()) do
                if obj.Name == "CharacterData" and obj:IsA("ModuleScript") then
                    charDataMod = obj
                    break
                end
            end
            if charDataMod then
                local ok, data = pcall(require, charDataMod)
                if ok and data then
                    local speciesName = dino.Value
                    local morphName = morph and morph.Value or nil
                    local key = morphName and (speciesName .. "_" .. morphName) or speciesName
                    local specData = data[key] or data[speciesName]
                    if specData then
                        -- Appetite can be at top-level or under .Stats
                        appetite = appetite or specData.Appetite
                            or (specData.Stats and specData.Stats.Appetite)
                        -- ThirstAppetite often defaults to Appetite (per client mapping).
                        thirst = thirst or specData.ThirstAppetite
                            or (specData.Stats and specData.Stats.ThirstAppetite)
                            or appetite
                    end
                end
            end
        end
    end)

    -- 3) Last resort: infer from Slot.Food/Water values and a conservative default.
    if not appetite or not thirst then
        local stats = getCreatureStats()
        if not appetite then appetite = math.max(stats.food or 0, _maxFoodSeen, 40) end
        if not thirst then thirst = math.max(stats.water or 0, _maxWaterSeen, appetite or 40) end
    end
    return appetite, thirst
end

-- ========== Test helpers ==========

-- Scan ALL Food-tagged models and return sorted list (nearest first, only with Value > 0).
local function scanAllFood(pos, radius)
    radius = radius or 1200
    local list = {}
    pcall(function()
        local tagged = CollectionService:GetTagged("Food")
        for _, obj in ipairs(tagged) do
            if obj and obj.Parent and (obj:IsA("BasePart") or obj:IsA("Model")) then
                local p = obj:IsA("Model")
                    and (obj.PrimaryPart and obj.PrimaryPart.Position or obj:GetPivot().Position)
                    or obj.Position
                local d = (pos - p).Magnitude
                if d < radius then
                    local val = 1
                    pcall(function()
                        local a = obj:GetAttribute("Value")
                        if type(a) == "number" then val = a end
                    end)
                    if val > 0 then
                        table.insert(list, {obj = obj, dist = d, value = val, pos = p})
                    end
                end
            end
        end
    end)
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

-- Scan ALL DrinkableWater-tagged lake models and return sorted list (nearest first).
-- Prefer the parent Model if the tag is on a part.
local function scanAllLakes(pos, radius)
    radius = radius or 2000
    local list = {}
    local seen = {}
    pcall(function()
        local tagged = CollectionService:GetTagged("DrinkableWater")
        for _, obj in ipairs(tagged) do
            if obj and obj.Parent then
                local model = obj:IsA("Model") and obj or (obj.Parent and obj.Parent:IsA("Model") and obj.Parent or obj)
                if not seen[model] then
                    seen[model] = true
                    local p
                    pcall(function()
                        local v3 = model:GetAttribute("V3")
                        if typeof(v3) == "Vector3" then
                            p = v3
                        end
                    end)
                    if not p then
                        p = model:IsA("Model") and model:GetPivot().Position or model.Position
                    end
                    local d = (pos - p).Magnitude
                    if d < radius then
                        local waterZone
                        pcall(function()
                            if model:IsA("Model") then
                                waterZone = model:FindFirstChild("WaterZone")
                            end
                        end)
                        table.insert(list, {model = model, dist = d, pos = p, waterZone = waterZone})
                    end
                end
            end
        end
    end)
    -- Fallback: look for Models named "Lake" in workspace.Interactions.Lakes
    if #list == 0 then
        pcall(function()
            local inter = workspace:FindFirstChild("Interactions")
            local lakesFolder = inter and inter:FindFirstChild("Lakes")
            if lakesFolder then
                for _, model in ipairs(lakesFolder:GetDescendants()) do
                    if model:IsA("Model") and not seen[model] then
                        seen[model] = true
                        local p
                        pcall(function()
                            local v3 = model:GetAttribute("V3")
                            if typeof(v3) == "Vector3" then p = v3 end
                        end)
                        if not p then
                            p = model:GetPivot().Position
                        end
                        local d = (pos - p).Magnitude
                        if d < radius then
                            local wz = model:FindFirstChild("WaterZone")
                            table.insert(list, {model = model, dist = d, pos = p, waterZone = wz})
                        end
                    end
                end
            end
        end)
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

-- Teleport character to target position facing the target (so proximity GetVisible passes).
local function teleportFacing(targetPos, offsetUp, offsetBack)
    offsetUp = offsetUp or 1
    offsetBack = offsetBack or 0
    local hrp = getHRP()
    if not hrp then return false end
    local p = getPosition()
    if not p then return false end
    -- Put character slightly in front of the target, looking at it.
    -- Simpler: place directly above + face the target.
    local lookDir = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(p.X, 0, p.Z))
    if lookDir.Magnitude < 0.1 then
        lookDir = Vector3.new(0, 0, 1)
    else
        lookDir = lookDir.Unit
    end
    local standPos = Vector3.new(
        targetPos.X - lookDir.X * offsetBack,
        targetPos.Y + offsetUp,
        targetPos.Z - lookDir.Z * offsetBack
    )
    local lookAt = targetPos
    local ok = false
    pcall(function()
        hrp.CFrame = CFrame.lookAt(standPos, lookAt)
        ok = true
    end)
    return ok
end

handlers.test_eat = function()
    log("[test_eat] === FOOD TEST START ===")

    -- If user is already in-world we can skip the slot UI entirely.
    refreshCharacterRefs()
    if not character then
        log("[test_eat] Not in world — attempting to enter...")
        if not tryEnterWorldFromSlotUi(30, DEFAULT_CREATURE) then
            return {ok = false, error = "Could not enter world"}
        end
    else
        log("[test_eat] Already in world")
    end

    local regionName, biome = detectCurrentRegion()
    log("[test_eat] Current region: " .. tostring(regionName))

    local appetite, thirstAppetite = getCreatureAppetite()
    log("[test_eat] Creature Appetite=" .. tostring(appetite) .. " ThirstAppetite=" .. tostring(thirstAppetite))

    local stats0 = getCreatureStats()
    local hungerPct0 = appetite and appetite > 0 and math.floor(stats0.food / appetite * 100) or -1
    log("[test_eat] Initial hunger: " .. tostring(stats0.food) .. "/" .. tostring(appetite) .. " (" .. tostring(hungerPct0) .. "%)")

    local foodRemote = getRemoteEvent("Food")
    if not foodRemote then
        log("[test_eat] ERROR: 'Food' RemoteEvent not found.")
        return {ok = false, error = "Food RemoteEvent not found"}
    end

    if not appetite or appetite <= 0 then
        log("[test_eat] WARN: appetite unknown, will keep eating until 8 cycles pass with no change.")
    end

    local maxCycles = 40
    local triedSources = {}
    local cyclesNoProgress = 0
    local lastFood = stats0.food

    -- Read initial EatFoodDrinkWater mission progress so we can use it as the
    -- primary exit signal. Firing Food:FireServer while full might still
    -- consume food.Value AND tick the mission (server-side gating for the
    -- regular Food remote isn't visible in our rbxlx audit — we let the server
    -- decide by trying, and detect via progress).
    local initialMissionAmount = 0
    local initialMissionTarget = 0
    do
        local m = (readRegionMissions(regionName or "") or {}).EatFoodDrinkWater
        if m then
            initialMissionAmount = m.amount or 0
            initialMissionTarget = m.targetAmount or 0
            if m.completed then
                log("[test_eat] EatFoodDrinkWater mission already complete — exiting")
                return {ok = true, log = "test_eat: mission already complete"}
            end
        end
    end
    local lastMissionAmount = initialMissionAmount

    for cycle = 1, maxCycles do
        if stopFlagExists() then
            log("[test_eat] STOPPED by flag at cycle " .. cycle)
            break
        end
        local stats = getCreatureStats()
        local hungerPct = appetite and appetite > 0 and math.floor(stats.food / appetite * 100) or -1

        -- Refresh region each cycle — if we drifted into a neighbour biome we
        -- want to read THAT region's mission, not the one we started in.
        regionName = detectCurrentRegion()

        -- PRIMARY EXIT: mission complete.
        do
            local m = (readRegionMissions(regionName or "") or {}).EatFoodDrinkWater
            if m and (m.completed or (m.targetAmount or 0) > 0
                     and (m.amount or 0) >= m.targetAmount)
            then
                log(string.format("[test_eat] Mission complete: %d/%d — exiting",
                    m.amount or 0, m.targetAmount or 0))
                break
            end
        end

        -- BELLY-FULL EXIT: the server silently refuses when Food.Value >= Appetite
        -- (the Food remote's OnServerEvent isn't in the rbxlx dump, but DrinkBuildableWater
        -- at ~5932126 explicitly gates on `Full`, and the observed behaviour for Food is
        -- identical — src.Value doesn't decrement and mission doesn't tick). Rather than
        -- burn cycles hopping between food sources, bail out so the dispatcher defers this
        -- mission for 60s (its built-in EatFoodDrinkWater defer window) while hunger drains.
        if appetite and appetite > 0 and stats.food >= appetite * 0.95 then
            log(string.format("[test_eat] Belly full (%s/%s) — server won't accept more bites, deferring mission",
                tostring(stats.food), tostring(appetite)))
            break
        end

        local pos = getPosition()
        if not pos then
            log("[test_eat] No position — waiting")
            task.wait(1)
        else
            -- Restricted to ~800 studs so we don't drift out of the current biome
            -- (was 1500 — that could pull us into a neighbouring region).
            local list = scanAllFood(pos, 800)
            log("[test_eat] Cycle " .. cycle .. " food=" .. tostring(stats.food) .. "/" .. tostring(appetite)
                .. " (" .. tostring(hungerPct) .. "%), found " .. #list .. " food sources in 1500 studs")

            -- Pick nearest that we haven't marked depleted and still has Value > 0.
            local target = nil
            for _, info in ipairs(list) do
                if not triedSources[info.obj] then
                    target = info
                    break
                end
            end
            -- If all tried, reset and retry (in case they refilled).
            if not target and #list > 0 then
                log("[test_eat] All sources tried this round — resetting attempt list")
                triedSources = {}
                target = list[1]
            end

            if not target then
                log("[test_eat] No food found within 1500 studs — moving to biome entry and retrying")
                if biome then safeTeleportVec(biome.entry) end
                task.wait(2)
            else
                local foodModel = target.obj
                local foodName = "?"
                pcall(function() foodName = foodModel:GetAttribute("FoodDataName") or foodModel.Name end)
                log(string.format("[test_eat] TP to '%s' value=%s dist=%d",
                    tostring(foodName), tostring(target.value), math.floor(target.dist)))

                -- Teleport facing the food (for proximity `GetVisible` dot-product check).
                teleportFacing(target.pos, 1, 0)
                task.wait(0.35)

                -- Eat loop: fire Food:FireServer(model) repeatedly. Exit when:
                --   (a) mission completes,
                --   (b) source depletes (fv <= 0),
                --   (c) nothing changes for 3 bites (source or server refused).
                -- Crucially we do NOT stop on "belly full" — the mission tracks
                -- units consumed, not stat gain.
                local lastFV = nil
                local localNoChange = 0
                local biteFoodInitial = getCreatureStats().food
                pcall(function() lastFV = foodModel:GetAttribute("Value") end)

                for bite = 1, 14 do
                    if stopFlagExists() then break end
                    Stealth.fireServer(foodRemote, foodModel)
                    Stealth.wait(1.55)
                    local s = getCreatureStats()
                    local fv = -1
                    pcall(function()
                        local a = foodModel:GetAttribute("Value")
                        if type(a) == "number" then fv = a end
                    end)
                    local mNow = (readRegionMissions(regionName or "") or {}).EatFoodDrinkWater
                    local mAmt = mNow and mNow.amount or lastMissionAmount
                    local mTgt = mNow and mNow.targetAmount or initialMissionTarget
                    log(string.format("[test_eat]   bite %d: food=%s/%s  src=%s  mission=%d/%d",
                        bite, tostring(s.food), tostring(appetite), tostring(fv), mAmt, mTgt))

                    -- EXIT: mission complete.
                    if mNow and (mNow.completed
                        or (mTgt > 0 and mAmt >= mTgt)) then
                        log("[test_eat] Mission complete via eating — done")
                        return {ok = true, log = "test_eat: mission completed"}
                    end

                    -- EXIT: source empty.
                    if type(fv) == "number" and fv <= 0 then
                        log("[test_eat] Source depleted after bite " .. bite)
                        triedSources[foodModel] = true
                        break
                    end

                    -- Track change across BOTH stat AND source Value AND mission
                    -- so we can detect "nothing is happening" robustly.
                    local madeProgress = false
                    if s.food > biteFoodInitial then madeProgress = true end
                    if lastFV and type(fv) == "number" and fv < lastFV then madeProgress = true end
                    if mAmt > lastMissionAmount then madeProgress = true end

                    if madeProgress then
                        localNoChange = 0
                        biteFoodInitial = s.food
                        lastFV = fv
                        lastMissionAmount = mAmt
                    else
                        localNoChange = localNoChange + 1
                        if localNoChange >= 3 then
                            log("[test_eat] No change after 3 bites — source dead or server refused, skipping")
                            triedSources[foodModel] = true
                            break
                        end
                    end
                end
            end
        end

        -- Global no-progress detection: use MISSION amount as the signal,
        -- not stat.food (which may stay capped at appetite).
        local mNow = (readRegionMissions(regionName or "") or {}).EatFoodDrinkWater
        local mAmt = mNow and mNow.amount or lastMissionAmount
        if mAmt <= lastMissionAmount then
            cyclesNoProgress = cyclesNoProgress + 1
            if cyclesNoProgress >= 6 then
                log("[test_eat] Mission progress stalled for 6 cycles — aborting")
                break
            end
        else
            cyclesNoProgress = 0
        end
        lastMissionAmount = mAmt
        lastFood = getCreatureStats().food
    end

    local stats = getCreatureStats()
    local hungerPct = appetite and appetite > 0 and math.floor(stats.food / appetite * 100) or -1
    log("[test_eat] === DONE === food=" .. tostring(stats.food) .. "/" .. tostring(appetite)
        .. " (" .. tostring(hungerPct) .. "%)")
    return {ok = true, log = string.format("test_eat finished: food=%s/%s (%s%%)",
        tostring(stats.food), tostring(appetite), tostring(hungerPct))}
end

handlers.test_drink = function()
    log("[test_drink] === WATER TEST START ===")

    refreshCharacterRefs()
    if not character then
        log("[test_drink] Not in world — attempting to enter...")
        if not tryEnterWorldFromSlotUi(30, DEFAULT_CREATURE) then
            return {ok = false, error = "Could not enter world"}
        end
    else
        log("[test_drink] Already in world")
    end

    local regionName, biome = detectCurrentRegion()
    log("[test_drink] Current region: " .. tostring(regionName))

    local appetite, thirstAppetite = getCreatureAppetite()
    log("[test_drink] Creature ThirstAppetite=" .. tostring(thirstAppetite) .. " (Appetite=" .. tostring(appetite) .. ")")

    local stats0 = getCreatureStats()
    local thirstPct0 = thirstAppetite and thirstAppetite > 0
        and math.floor(stats0.water / thirstAppetite * 100) or -1
    log("[test_drink] Initial thirst: " .. tostring(stats0.water) .. "/" .. tostring(thirstAppetite)
        .. " (" .. tostring(thirstPct0) .. "%)")

    local drinkRemote = getRemoteEvent("DrinkRemote")
    local drinkBuildable = getRemoteEvent("DrinkBuildableWater")
    if not drinkRemote then
        log("[test_drink] ERROR: 'DrinkRemote' not found.")
        return {ok = false, error = "DrinkRemote not found"}
    end

    local maxCycles = 40
    local triedLakes = {}
    local cyclesNoProgress = 0
    local lastWater = stats0.water

    -- Read initial EatFoodDrinkWater mission state. Mission is the primary
    -- exit signal; we no longer stop on "full thirst".
    -- NOTE: rbxlx ~5932126 confirms DrinkBuildableWater server-side refuses
    -- when full (returns "Full"), but DrinkRemote (regular lakes) handler is
    -- not in the dump, so we attempt and detect via mission progress.
    local initialMissionAmount = 0
    local initialMissionTarget = 0
    do
        local m = (readRegionMissions(regionName or "") or {}).EatFoodDrinkWater
        if m then
            initialMissionAmount = m.amount or 0
            initialMissionTarget = m.targetAmount or 0
            if m.completed then
                log("[test_drink] EatFoodDrinkWater mission already complete — exiting")
                return {ok = true, log = "test_drink: mission already complete"}
            end
        end
    end
    local lastMissionAmount = initialMissionAmount

    for cycle = 1, maxCycles do
        if stopFlagExists() then
            log("[test_drink] STOPPED by flag at cycle " .. cycle)
            break
        end
        local stats = getCreatureStats()
        local thirstPct = thirstAppetite and thirstAppetite > 0
            and math.floor(stats.water / thirstAppetite * 100) or -1

        -- Refresh region each cycle — if we drifted into a neighbour biome we
        -- want to read THAT region's mission, not the one we started in.
        regionName = detectCurrentRegion()

        -- THIRST-FULL EXIT: server-side `DrinkBuildableWater` explicitly refuses
        -- when Water.Value >= ThirstAppetite (rbxlx ~5932126). Regular lakes
        -- (`DrinkRemote`) behave the same way empirically. Bail out immediately
        -- so the dispatcher defers the mission for 60s.
        if thirstAppetite and thirstAppetite > 0 and stats.water >= thirstAppetite * 0.95 then
            log(string.format("[test_drink] Thirst full (%s/%s) — server won't accept more sips, deferring mission",
                tostring(stats.water), tostring(thirstAppetite)))
            break
        end

        -- PRIMARY EXIT: mission complete.
        do
            local m = (readRegionMissions(regionName or "") or {}).EatFoodDrinkWater
            if m and (m.completed or (m.targetAmount or 0) > 0
                     and (m.amount or 0) >= m.targetAmount)
            then
                log(string.format("[test_drink] Mission complete: %d/%d — exiting",
                    m.amount or 0, m.targetAmount or 0))
                break
            end
        end

        local pos = getPosition()
        if not pos then
            log("[test_drink] No position — waiting")
            task.wait(1)
        else
            -- Restrict to 1200 studs so we stay within the current biome
            -- (was 2500 — could pull us into neighbouring regions).
            local lakes = scanAllLakes(pos, 1200)
            log("[test_drink] Cycle " .. cycle .. " water=" .. tostring(stats.water) .. "/" .. tostring(thirstAppetite)
                .. " (" .. tostring(thirstPct) .. "%), found " .. #lakes .. " lakes in 1200 studs")

            local target = nil
            for _, info in ipairs(lakes) do
                if not triedLakes[info.model] then
                    target = info
                    break
                end
            end
            if not target and #lakes > 0 then
                log("[test_drink] All lakes tried — resetting list")
                triedLakes = {}
                target = lakes[1]
            end

            if not target then
                log("[test_drink] No lake found within 2500 studs — moving to biome entry")
                if biome then safeTeleportVec(biome.entry) end
                task.wait(2)
            else
                local lakeModel = target.model
                local lakeName = lakeModel.Name or "Lake"
                local isBuildable = false
                pcall(function()
                    isBuildable = lakeModel:HasTag("Buildable") or
                        (lakeModel:IsA("Model") and lakeModel:FindFirstAncestorOfClass("Model") and
                         lakeModel:FindFirstAncestorOfClass("Model"):HasTag("Buildable")) or false
                end)

                -- Determine a good stand position: on the SHORE just outside the WaterZone,
                -- facing toward the water surface. The server's DrinkRemote handler and the
                -- client's proximity prompt require a clear line from the character's front
                -- onto the water surface (see DrinkableWater.cast in the game client).
                local stand = target.pos
                local faceTarget = target.pos
                if target.waterZone and target.waterZone:IsA("BasePart") then
                    local wz = target.waterZone
                    local wzPos = wz.Position
                    local wzSize = wz.Size
                    faceTarget = wzPos

                    -- Direction from WaterZone center back to the character (on XZ plane).
                    -- This gives us the nearest shore direction relative to where the bot is.
                    local myPos = pos
                    local outDir = Vector3.new(myPos.X - wzPos.X, 0, myPos.Z - wzPos.Z)
                    if outDir.Magnitude < 0.1 then
                        -- Character already in water center — pick an arbitrary direction (+X).
                        outDir = Vector3.new(1, 0, 0)
                    else
                        outDir = outDir.Unit
                    end

                    -- Step out just past the edge of the WaterZone's bounding box in XZ.
                    -- half-extent along outDir (project wz half-size onto outDir):
                    local halfX = wzSize.X * 0.5
                    local halfZ = wzSize.Z * 0.5
                    -- distance from center to its edge in the outDir direction (AABB approx):
                    local edgeDist = math.abs(outDir.X) * halfX + math.abs(outDir.Z) * halfZ
                    local shoreOffset = edgeDist + 4  -- small margin onto the shore

                    local shoreX = wzPos.X + outDir.X * shoreOffset
                    local shoreZ = wzPos.Z + outDir.Z * shoreOffset
                    -- Start a few studs above the water surface; gravity will drop onto terrain.
                    local shoreY = wzPos.Y + (wzSize.Y * 0.5) + 6
                    -- Try to snap to terrain with a raycast down from well above the surface.
                    pcall(function()
                        local rp = RaycastParams.new()
                        rp.FilterType = Enum.RaycastFilterType.Exclude
                        rp.FilterDescendantsInstances = {character, wz}
                        local origin = Vector3.new(shoreX, shoreY + 40, shoreZ)
                        local dir = Vector3.new(0, -120, 0)
                        local hit = workspace:Raycast(origin, dir, rp)
                        if hit and hit.Position then
                            -- Stand just above the hit so the character is grounded on the shore.
                            shoreY = hit.Position.Y + 3
                        end
                    end)
                    stand = Vector3.new(shoreX, shoreY, shoreZ)
                end
                log(string.format("[test_drink] TP to shore of '%s' buildable=%s dist=%d shore=(%.1f,%.1f,%.1f)",
                    tostring(lakeName), tostring(isBuildable), math.floor(target.dist),
                    stand.X, stand.Y, stand.Z))

                local hrp = getHRP()
                if hrp then
                    -- Face toward the water surface.
                    pcall(function()
                        hrp.CFrame = CFrame.lookAt(stand, Vector3.new(faceTarget.X, stand.Y, faceTarget.Z))
                    end)
                end
                task.wait(0.5)

                local re = isBuildable and drinkBuildable or drinkRemote
                if not re then
                    log("[test_drink] Required remote missing (buildable=" .. tostring(isBuildable) .. "), skip lake")
                    triedLakes[lakeModel] = true
                else
                    -- Drink loop: NO "full" early exit. We watch mission progress,
                    -- water stat, and 3-in-a-row no-change to bail cleanly.
                    local prevWater = getCreatureStats().water
                    local localNoChange = 0
                    for sip = 1, 14 do
                        if stopFlagExists() then break end
                        -- Per client code, the argument is the lake model itself (buildable sends the part).
                        Stealth.fireServer(re, lakeModel)
                        Stealth.wait(1.55)
                        local s = getCreatureStats()
                        local mNow = (readRegionMissions(regionName or "") or {}).EatFoodDrinkWater
                        local mAmt = mNow and mNow.amount or lastMissionAmount
                        local mTgt = mNow and mNow.targetAmount or initialMissionTarget
                        log(string.format("[test_drink]   sip %d: water=%s/%s  mission=%d/%d",
                            sip, tostring(s.water), tostring(thirstAppetite), mAmt, mTgt))

                        -- EXIT: mission complete.
                        if mNow and (mNow.completed
                            or (mTgt > 0 and mAmt >= mTgt)) then
                            log("[test_drink] Mission complete via drinking — done")
                            return {ok = true, log = "test_drink: mission completed"}
                        end

                        local progressed = false
                        if s.water > prevWater then progressed = true end
                        if mAmt > lastMissionAmount then progressed = true end

                        if progressed then
                            localNoChange = 0
                            lastMissionAmount = mAmt
                        else
                            localNoChange = localNoChange + 1
                            if localNoChange >= 3 then
                                log("[test_drink] No change after 3 sips — lake dead or server refused, skipping")
                                triedLakes[lakeModel] = true
                                break
                            end
                        end
                        prevWater = s.water
                    end
                end
            end
        end

        -- Global no-progress detection — use MISSION as the signal.
        local mNow = (readRegionMissions(regionName or "") or {}).EatFoodDrinkWater
        local mAmt = mNow and mNow.amount or lastMissionAmount
        if mAmt <= lastMissionAmount then
            cyclesNoProgress = cyclesNoProgress + 1
            if cyclesNoProgress >= 6 then
                log("[test_drink] Mission progress stalled for 6 cycles — aborting")
                break
            end
        else
            cyclesNoProgress = 0
        end
        lastMissionAmount = mAmt
        lastWater = getCreatureStats().water
    end

    local stats = getCreatureStats()
    local thirstPct = thirstAppetite and thirstAppetite > 0
        and math.floor(stats.water / thirstAppetite * 100) or -1
    log("[test_drink] === DONE === water=" .. tostring(stats.water) .. "/" .. tostring(thirstAppetite)
        .. " (" .. tostring(thirstPct) .. "%)")
    return {ok = true, log = string.format("test_drink finished: water=%s/%s (%s%%)",
        tostring(stats.water), tostring(thirstAppetite), tostring(thirstPct))}
end

do -- == test_walk scope ==
-- Read DistanceTravelled mission progress for current region.
-- Catalog target is 2500 studs (rbxlx ~5452149).
local function getDistanceProgress()
    local amount, target, completed = 0, 0, false
    pcall(function()
        local regionName = detectCurrentRegion()
        if not regionName then return end
        local missions = readRegionMissions(regionName)
        local m = missions and missions.DistanceTravelled
        if m then
            amount = m.amount or 0
            target = m.targetAmount or 0
            completed = m.completed or false
        end
    end)
    return amount, target, completed
end

-- Read creature Stamina from CharacterData.
-- Confirmed in rbxlx ~5901703: compressed attribute key is "st" (Stamina),
-- not "s" — and "tp" is TimePlayed, "is" is IsSprinting, "a"/"ta" are Appetite/ThirstAppetite.
local function getStamina()
    local stamina = 100
    pcall(function()
        refreshCharacterRefs()
        if not character then return end
        local dataInst = nil
        for _, inst in ipairs(character:GetDescendants()) do
            if inst:HasTag("CharacterData") then dataInst = inst; break end
        end
        if not dataInst then
            dataInst = character:FindFirstChild("Data")
        end
        if dataInst then
            local s = dataInst:GetAttribute("st") or dataInst:GetAttribute("Stamina")
            if type(s) == "number" then stamina = s end
        end
    end)
    return stamina
end

handlers.test_walk = function()
    log("[test_walk] === WALK TEST START ===")

    refreshCharacterRefs()
    if not character then
        log("[test_walk] Not in world — attempting to enter...")
        if not tryEnterWorldFromSlotUi(30, DEFAULT_CREATURE) then
            return {ok = false, error = "Could not enter world"}
        end
    else
        log("[test_walk] Already in world")
    end

    local regionName, biome = detectCurrentRegion()
    log("[test_walk] Current region: " .. tostring(regionName))

    if not biome then
        log("[test_walk] ERROR: unknown biome")
        return {ok = false, error = "unknown biome"}
    end

    local amount0, target0, completed0 = getDistanceProgress()
    log(string.format("[test_walk] Initial mission: %d/%d (completed=%s)",
        amount0, target0, tostring(completed0)))

    if completed0 then
        log("[test_walk] Mission already completed in this region")
        return {ok = true, log = "test_walk: already complete"}
    end

    -- If the region's daily 3 missions don't include DistanceTravelled, target will be 0.
    -- Don't waste time walking — report and exit cleanly.
    if target0 == 0 then
        log("[test_walk] DistanceTravelled mission is not active in '" .. tostring(regionName)
            .. "' (daily pool rotated). Try another biome.")
        return {ok = true, log = "test_walk: mission not active in " .. tostring(regionName)}
    end

    -- Teleport to the known-safe entry point first.
    log(string.format("[test_walk] TP to biome safe point (%d,%d,%d)",
        biome.safe[1], biome.safe[2], biome.safe[3]))
    safeTeleportVec(biome.safe)
    task.wait(1.0)

    -- Two anchor points: current position A and a point ~140 studs away.
    -- We'll bounce between them using Humanoid:MoveTo, which also engages running
    -- if we hold LeftShift (Sprint action in the game's controls).
    local A = getPosition()
    if not A then return {ok = false, error = "no position after tp"} end
    -- Offset direction: use the entry-to-walk[1] vector if available, else +X.
    local dirX, dirZ = 1, 0
    if biome.walk and #biome.walk > 0 then
        local wp = biome.walk[1]
        local dx = wp[1] - A.X
        local dz = wp[3] - A.Z
        local mag = math.sqrt(dx*dx + dz*dz)
        if mag > 1 then
            dirX = dx / mag
            dirZ = dz / mag
        end
    end
    local LEG = 140
    local B = Vector3.new(A.X + dirX * LEG, A.Y, A.Z + dirZ * LEG)
    log(string.format("[test_walk] Anchors A=(%.1f,%.1f,%.1f) B=(%.1f,%.1f,%.1f) leg=%d",
        A.X, A.Y, A.Z, B.X, B.Y, B.Z, LEG))

    -- Start holding LeftShift (Sprint is hold-to-sprint on desktop: rbxlx ~6016856).
    local function holdShift() pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
    end) end
    local function releaseShift() pcall(function()
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
    end) end

    holdShift()

    local goTo = B  -- toggle between A and B
    local legsWalked = 0
    local maxSeconds = 600  -- hard ceiling: 10 min
    local startTime = tick()
    local lastProgressCheck = 0
    local sprinting = true

    while tick() - startTime < maxSeconds do
        if stopFlagExists() then
            log("[test_walk] STOPPED by flag")
            break
        end

        -- Every 3s: progress / stamina check.
        if tick() - lastProgressCheck > 3 then
            lastProgressCheck = tick()
            local amt, tgt, comp = getDistanceProgress()
            local stamina = getStamina()
            log(string.format("[test_walk] progress=%d/%d  stamina=%d  sprinting=%s  legs=%d",
                amt, tgt, stamina, tostring(sprinting), legsWalked))
            if comp then
                log("[test_walk] Mission completed!")
                break
            end
            -- Stamina management: if drained, release shift; if refilled > 40, hold again.
            if sprinting and stamina <= 5 then
                releaseShift()
                sprinting = false
                log("[test_walk] Out of stamina — switching to walk")
            elseif (not sprinting) and stamina >= 40 then
                holdShift()
                sprinting = true
                log("[test_walk] Stamina recovered — resuming sprint")
            end
        end

        -- Issue MoveTo and wait until we arrive or timeout.
        refreshCharacterRefs()
        if not humanoid then
            log("[test_walk] Humanoid temporarily nil — waiting and refreshing")
            task.wait(1.0)
            refreshCharacterRefs()
            if not humanoid then
                log("[test_walk] Humanoid still nil — retrying TP to safe and character refresh")
                safeTeleportVec(biome.safe)
                task.wait(1.5)
                refreshCharacterRefs()
                if not humanoid then
                    log("[test_walk] Humanoid unrecoverable — aborting")
                    break
                end
            end
        end
        pcall(function() humanoid:MoveTo(goTo) end)

        local legStart = tick()
        local legTimeout = 12
        local arrived = false
        while tick() - legStart < legTimeout do
            if stopFlagExists() then break end
            local p = getPosition()
            if p then
                local dx = p.X - goTo.X
                local dz = p.Z - goTo.Z
                if math.sqrt(dx*dx + dz*dz) < 8 then
                    arrived = true
                    break
                end
            end
            task.wait(0.3)
        end

        if stopFlagExists() then break end

        legsWalked = legsWalked + 1
        if not arrived then
            -- Stuck — nudge via teleport back to safe point, recompute anchors.
            log("[test_walk] Stuck mid-leg — re-teleporting to safe point")
            safeTeleportVec(biome.safe)
            task.wait(0.8)
            A = getPosition() or A
            B = Vector3.new(A.X + dirX * LEG, A.Y, A.Z + dirZ * LEG)
            goTo = B
        else
            -- Flip direction.
            goTo = (goTo == B) and A or B
        end
    end

    releaseShift()

    local finalAmt, finalTgt = getDistanceProgress()
    log(string.format("[test_walk] === DONE === legs=%d  mission=%d/%d  elapsed=%ds",
        legsWalked, finalAmt, finalTgt, math.floor(tick() - startTime)))
    return {
        ok = finalAmt > amount0,
        log = string.format("test_walk: legs=%d mission=%d/%d", legsWalked, finalAmt, finalTgt)
    }
end
end -- == /test_walk scope ==

do -- == test_sniff scope ==
-- Read Sniff mission progress for current region.
-- In-game RegionMissions catalog: Sniff requires 5 per region (see rbxlx line ~5452153).
local function getSniffProgress()
    local amount, target, completed = 0, 0, false
    pcall(function()
        local regionName = detectCurrentRegion()
        if not regionName then return end
        local missions = readRegionMissions(regionName)
        local m = missions and missions.Sniff
        if m then
            amount = m.amount or 0
            target = m.targetAmount or 0
            completed = m.completed or false
        end
    end)
    return amount, target, completed
end

handlers.test_sniff = function()
    log("[test_sniff] === SNIFF TEST START ===")

    refreshCharacterRefs()
    if not character then
        log("[test_sniff] Not in world — attempting to enter...")
        if not tryEnterWorldFromSlotUi(30, DEFAULT_CREATURE) then
            return {ok = false, error = "Could not enter world"}
        end
    else
        log("[test_sniff] Already in world")
    end

    local regionName, _biome = detectCurrentRegion()
    log("[test_sniff] Current region: " .. tostring(regionName))

    -- SetMissionRemote:FireServer(1) — "1" is the index of "Sniff" in Constants.MissionTypes
    -- (see rbxlx lines ~5901452 and ~5945059: IncrementClientMission → ConvertMissionType).
    local setMissionRemote = getRemoteEvent("SetMissionRemote")
    if not setMissionRemote then
        log("[test_sniff] WARN: SetMissionRemote not found — only VIM H path will work")
    end

    local amount0, target0 = getSniffProgress()
    log(string.format("[test_sniff] Initial Sniff mission: %d/%d", amount0, target0))

    -- Game client cooldown: Constants.SniffCooldown = 15s (see rbxlx line 5901109).
    -- SniffAbilityCooldown may override it temporarily (tutorial sets 8).
    local SNIFF_COOLDOWN = 15
    local MAX_ATTEMPTS = 15
    local successful = 0
    local lastSniffAt = 0

    for attempt = 1, MAX_ATTEMPTS do
        if stopFlagExists() then
            log("[test_sniff] STOPPED by flag")
            break
        end

        -- If on client cooldown, wait — but recheck stop flag every 1s.
        local since = tick() - lastSniffAt
        if lastSniffAt > 0 and since < SNIFF_COOLDOWN then
            local remaining = SNIFF_COOLDOWN - since
            log(string.format("[test_sniff] On cooldown — waiting %.1fs", remaining))
            local waitUntil = tick() + remaining
            while tick() < waitUntil do
                if stopFlagExists() then break end
                task.wait(1)
            end
            if stopFlagExists() then break end
        end

        local amountBefore = select(1, getSniffProgress())
        log(string.format("[test_sniff] Attempt %d/%d  mission=%d/%d",
            attempt, MAX_ATTEMPTS, amountBefore, target0))

        -- Trigger via VirtualInputManager 'H' — goes through the full client
        -- Controls.Sniff → Sniff module pipeline (cooldown check, VFX, mission fire).
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.H, false, game)
            task.wait(0.15)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.H, false, game)
        end)

        -- Also fire the mission remote directly as a backup in case the H keybind
        -- was consumed by a UI capture. This mirrors the final server call of Sniff().
        if setMissionRemote then
            pcall(function()
                setMissionRemote:FireServer(1)  -- 1 == index of "Sniff" in MissionTypes
            end)
        end
        lastSniffAt = tick()

        -- Server needs a moment to update the region mission counter.
        task.wait(2.5)

        local amountAfter = select(1, getSniffProgress())
        if amountAfter > amountBefore then
            successful = successful + 1
            log(string.format("[test_sniff] OK — mission advanced %d → %d  (sniff #%d)",
                amountBefore, amountAfter, successful))
            if target0 > 0 and amountAfter >= target0 then
                log("[test_sniff] Mission fully completed!")
                break
            end
        else
            log("[test_sniff] No progress — likely cooldown is still active, will wait and retry")
        end
    end

    local finalAmount, finalTarget = getSniffProgress()
    log(string.format("[test_sniff] === DONE === successful_sniffs=%d  mission=%d/%d",
        successful, finalAmount, finalTarget))
    return {
        ok = successful > 0,
        log = string.format("test_sniff: %d sniffs, mission=%d/%d",
            successful, finalAmount, finalTarget)
    }
end
end -- == /test_sniff scope ==

do -- == test_attack scope ==
-- Read AttackOrHealCreatureOrNPC mission progress for current region.
-- Catalog target is 5 per region (rbxlx ~5452157).
local function getAttackProgress()
    local amount, target, completed = 0, 0, false
    pcall(function()
        local regionName = detectCurrentRegion()
        if not regionName then return end
        local missions = readRegionMissions(regionName)
        local m = missions and missions.AttackOrHealCreatureOrNPC
        if m then
            amount = m.amount or 0
            target = m.targetAmount or 0
            completed = m.completed or false
        end
    end)
    return amount, target, completed
end

-- Try to find a creature model's PrimaryPart (or some reasonable BasePart root).
local function resolveHitRoot(model)
    if not model or not model:IsA("Model") then return nil end
    if model.PrimaryPart then return model.PrimaryPart end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp end
    local root = model:FindFirstChild("Root")
    if root and root:IsA("BasePart") then return root end
    return model:FindFirstChildWhichIsA("BasePart")
end

-- Is a model still alive? Checks Humanoid.Health or Health attribute.
local function isModelAlive(model)
    if not model or not model.Parent then return false end
    local hum = model:FindFirstChildWhichIsA("Humanoid")
    if hum then return hum.Health > 0 end
    local h = model:GetAttribute("Health")
    if type(h) == "number" then return h > 0 end
    return true
end

-- Fire a bite through the correct remote per target type.
--
-- CRITICAL (verified in rbxlx):
--   * CharactersDamageRemote resolves each entry via `getCharacterFromModel` which
--     compares arg to `PlayerWrapper.Character` (the MODEL — not HumanoidRootPart).
--     See rbxlx ~5929748 and GetRoot at ~5968509. Passing the HRP silently resolves
--     to nil and the per-target block is skipped → no damage, no mission tick.
--   * MobDamageRemote on the server calls `v_u_15.GetMobFromHitbox(part)` on each
--     entry (rbxlx ~5944688) — it EXPECTS a BasePart hitbox, not a Model.
--
-- So we send the MODEL to Characters and the PART to Mob.
local function fireBite(targetModel, targetHitRoot)
    if targetModel and targetModel:IsA("Model") then
        local re = getRemoteEvent("CharactersDamageRemote")
        if re then Stealth.fireServer(re, {targetModel}) end
    end
    if targetHitRoot and targetHitRoot:IsA("BasePart") then
        local re = getRemoteEvent("MobDamageRemote")
        if re then Stealth.fireServer(re, {targetHitRoot}) end
    end
end

handlers.test_attack = function()
    log("[test_attack] === ATTACK TEST START ===")

    refreshCharacterRefs()
    if not character then
        log("[test_attack] Not in world — attempting to enter...")
        if not tryEnterWorldFromSlotUi(30, DEFAULT_CREATURE) then
            return {ok = false, error = "Could not enter world"}
        end
    else
        log("[test_attack] Already in world")
    end

    local regionName, biome = detectCurrentRegion()
    log("[test_attack] Current region: " .. tostring(regionName))

    if not biome then
        log("[test_attack] ERROR: unknown biome")
        return {ok = false, error = "unknown biome"}
    end

    local amount0, target0, completed0 = getAttackProgress()
    log(string.format("[test_attack] Initial mission: %d/%d (completed=%s)",
        amount0, target0, tostring(completed0)))

    -- Early exit if mission is already done or not present in region's daily pool.
    if completed0 or (target0 > 0 and amount0 >= target0) then
        log("[test_attack] Mission already completed — exiting")
        return {ok = true, log = "test_attack: already complete"}
    end
    if target0 == 0 then
        log("[test_attack] AttackOrHealCreatureOrNPC not active in '"
            .. tostring(regionName) .. "' — exiting")
        return {ok = true, log = "test_attack: mission not active in " .. tostring(regionName)}
    end

    -- Game uses ATTACK_COOLDOWN = 0.8s (rbxlx ~5901184), scaled by TimePlayed/BiteCooldown.
    -- Use 1.1s between bites to be safe with server debounce.
    local BITE_INTERVAL = 1.1
    local MAX_DURATION = 180  -- 3 min hard ceiling
    local startTime = tick()
    local bites = 0
    local triedNPC = {}

    while tick() - startTime < MAX_DURATION do
        if stopFlagExists() then
            log("[test_attack] STOPPED by flag")
            break
        end

        local amt, tgt, comp = getAttackProgress()
        if comp or (tgt > 0 and amt >= tgt) then
            log("[test_attack] Mission completed — stopping")
            break
        end
        if tgt == 0 then
            log("[test_attack] Mission became inactive (target=0) — stopping")
            break
        end

        -- 1) NPCs first.
        local pos = getPosition()
        if not pos then
            task.wait(1)
        else
            local npcs = scanForNPCs(pos, 1500)
            local targetInfo = nil
            for _, n in ipairs(npcs) do
                if n.model and not triedNPC[n.model] and isModelAlive(n.model) then
                    targetInfo = n
                    break
                end
            end

            -- Helper: overlap-TP our HRP onto the target's hitroot, facing the target.
            -- The server doesn't check distance for Characters path, but placing the bot
            -- on top of the target gives correct ownership/network replication and
            -- matches what the legit client Bite() hitbox would touch.
            local function approachAndFace(targetHitRoot, targetPos)
                local hrp = getHRP()
                if not hrp or not targetHitRoot then return false end
                -- Place bot slightly offset (+2 studs UP, 2 behind) then lookAt the target.
                -- Using lookAt guarantees facing; offset prevents getting stuck inside the model.
                local tpos = (targetHitRoot:IsA("BasePart") and targetHitRoot.Position) or targetPos
                local myStand = tpos + Vector3.new(0, 2, 0)
                pcall(function()
                    hrp.CFrame = CFrame.lookAt(myStand, tpos)
                end)
                return true
            end

            if targetInfo then
                local model = targetInfo.model
                local hitRoot = resolveHitRoot(model)
                if not hitRoot then
                    log("[test_attack] NPC has no usable hit root, skipping")
                    triedNPC[model] = true
                else
                    log(string.format("[test_attack] NPC target: %s  dist=%d (stay & bite)",
                        tostring(model.Name), math.floor(targetInfo.distance)))

                    approachAndFace(hitRoot, targetInfo.position)
                    task.wait(0.5)

                    local noProgressBites = 0
                    local amountBefore = select(1, getAttackProgress())
                    for _ = 1, 12 do
                        if stopFlagExists() then break end
                        if not isModelAlive(model) or not hitRoot.Parent then
                            log("[test_attack] NPC died or despawned — moving on")
                            break
                        end
                        -- Re-anchor on top if we drifted (knockback / physics).
                        local myP = getPosition()
                        local tposNow = hitRoot.Position
                        if myP and (myP - tposNow).Magnitude > 8 then
                            approachAndFace(hitRoot, tposNow)
                            task.wait(0.3)
                        end

                        fireBite(model, hitRoot)
                        bites = bites + 1
                        -- Wait AFTER bite for server to process damage + mission tick.
                        task.wait(1.0)

                        local amountNow = select(1, getAttackProgress())
                        if amountNow > amountBefore then
                            log(string.format("[test_attack] NPC bite OK  mission %d → %d (bite #%d)",
                                amountBefore, amountNow, bites))
                            amountBefore = amountNow
                            noProgressBites = 0
                            if tgt > 0 and amountNow >= tgt then break end
                        else
                            noProgressBites = noProgressBites + 1
                            if noProgressBites >= 4 then
                                log("[test_attack] No mission progress from 4 NPC bites — this NPC type may not count; trying another")
                                break
                            end
                        end
                    end
                    triedNPC[model] = true
                end
            else
                -- 2) No NPCs left → try players.
                local players = findNearbyPlayers(pos, 1500)
                if #players == 0 then
                    log("[test_attack] No NPCs or players in range. Teleport to biome entry and retry.")
                    safeTeleportVec(biome.entry)
                    task.wait(2)
                    local pos2 = getPosition()
                    if pos2 then
                        local again = findNearbyPlayers(pos2, 1500)
                        if #again == 0 then
                            local npcsAgain = scanForNPCs(pos2, 1500)
                            local hasFresh = false
                            for _, n in ipairs(npcsAgain) do
                                if not triedNPC[n.model] then hasFresh = true; break end
                            end
                            if not hasFresh then
                                log("[test_attack] No targets available — giving up")
                                break
                            end
                        end
                    end
                else
                    local pl = players[1]
                    local pHRP = pl.model and pl.model:FindFirstChild("HumanoidRootPart")
                    local pHitRoot = pHRP or resolveHitRoot(pl.model) or pl.model
                    log(string.format("[test_attack] Player target: %s dist=%d (STAY & BITE until mission ticks)",
                        pl.name, math.floor(pl.distance)))

                    approachAndFace(pHitRoot, pl.position)
                    task.wait(0.5)

                    -- Bite THIS player until mission progresses or they move far away / die.
                    local amountBefore = select(1, getAttackProgress())
                    local noProgressBites = 0
                    local startedAt = tick()
                    for _ = 1, 10 do
                        if stopFlagExists() then break end
                        -- Is the player still valid and reachable?
                        if not pl.model or not pl.model.Parent then
                            log("[test_attack] Player left / model despawned")
                            break
                        end
                        -- Re-resolve position (player moves constantly).
                        local curHRP = pl.model:FindFirstChild("HumanoidRootPart")
                        if curHRP then
                            pHitRoot = curHRP
                            approachAndFace(pHitRoot, curHRP.Position)
                            task.wait(0.3)
                        end

                        fireBite(pl.model, pHitRoot)
                        bites = bites + 1
                        -- CRITICAL: long wait AFTER bite for server to process.
                        task.wait(1.0)

                        local amountNow = select(1, getAttackProgress())
                        if amountNow > amountBefore then
                            log(string.format("[test_attack] Player bite LANDED  mission %d → %d (bite #%d)",
                                amountBefore, amountNow, bites))
                            amountBefore = amountNow
                            noProgressBites = 0
                            if tgt > 0 and amountNow >= tgt then break end
                            -- Mission progressed! Now retreat a bit before the next bite
                            -- so we don't get killed by the player in a counter-attack.
                            local retreatPos = pl.model:FindFirstChild("HumanoidRootPart")
                            if retreatPos then
                                local hrp = getHRP()
                                local away = retreatPos.Position + Vector3.new(
                                    math.random(-30, 30), 6, math.random(-30, 30))
                                if hrp then
                                    pcall(function() hrp.CFrame = CFrame.new(away) end)
                                end
                                task.wait(0.3)
                            end
                        else
                            noProgressBites = noProgressBites + 1
                            if noProgressBites >= 3 then
                                log("[test_attack] Player bites not ticking mission — moving on")
                                break
                            end
                        end

                        if tick() - startedAt > 20 then
                            log("[test_attack] 20s on this player — rotating")
                            break
                        end
                    end

                    -- Only NOW retreat to safe, after we tried to tick the mission.
                    if (select(1, getAttackProgress())) > amountBefore then
                        log("[test_attack] Mission advanced — retreating to safe")
                    else
                        log("[test_attack] No mission tick on this player — retreating to safe anyway")
                    end
                    safeTeleportVec(biome.safe)
                    task.wait(BITE_INTERVAL)
                end
            end
        end
    end

    local finalAmt, finalTgt, finalComp = getAttackProgress()
    log(string.format("[test_attack] === DONE === bites=%d  mission=%d/%d  completed=%s",
        bites, finalAmt, finalTgt, tostring(finalComp)))
    return {
        ok = finalAmt > amount0,
        log = string.format("test_attack: bites=%d mission=%d/%d", bites, finalAmt, finalTgt)
    }
end
end -- == /test_attack scope ==

do -- == test_mud scope ==
-- Scan ALL Mud-tagged parts and return sorted list (nearest first). The tagged instances are
-- usually BaseParts with a child ParticleEmitter named "Mud" (server does `p35.Mud:Emit`).
local function scanAllMud(pos, radius)
    radius = radius or 2000
    local list = {}
    local seen = {}
    pcall(function()
        local tagged = CollectionService:GetTagged("Mud")
        for _, obj in ipairs(tagged) do
            if obj and obj.Parent and not seen[obj] then
                seen[obj] = true
                local p
                if obj:IsA("BasePart") then
                    p = obj.Position
                elseif obj:IsA("Model") then
                    p = obj:GetPivot().Position
                end
                if p then
                    local d = (pos - p).Magnitude
                    if d < radius then
                        table.insert(list, {obj = obj, dist = d, pos = p})
                    end
                end
            end
        end
    end)
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

-- Read a character ailment attribute by name. Returns the value (or 0 if absent).
local function getAilmentValue(name)
    local v = 0
    pcall(function()
        refreshCharacterRefs()
        if not character then return end
        local ail = character:FindFirstChild("Ailments")
        if ail then
            local a = ail:GetAttribute(name)
            if type(a) == "number" then v = a end
        end
    end)
    return v
end

-- Read the ConcealScent mission progress for the current region.
local function getConcealScentProgress()
    local amount, target, completed = 0, 0, false
    pcall(function()
        local regionName = detectCurrentRegion()
        if not regionName then return end
        local missions = readRegionMissions(regionName)
        local m = missions and missions.ConcealScent
        if m then
            amount = m.amount or 0
            target = m.targetAmount or 0
            completed = m.completed or false
        end
    end)
    return amount, target, completed
end

handlers.test_mud = function()
    log("[test_mud] === MUD TEST START ===")

    refreshCharacterRefs()
    if not character then
        log("[test_mud] Not in world — attempting to enter...")
        if not tryEnterWorldFromSlotUi(30, DEFAULT_CREATURE) then
            return {ok = false, error = "Could not enter world"}
        end
    else
        log("[test_mud] Already in world")
    end

    local regionName, biome = detectCurrentRegion()
    log("[test_mud] Current region: " .. tostring(regionName))

    -- The game's ConcealScent mission is Land-only; warn but still try.
    if biome and biome.zone and biome.zone ~= "Land" then
        log("[test_mud] WARN: current biome zone is '" .. tostring(biome.zone)
            .. "' — mud mission is Land-only. Continuing anyway for raw test.")
    end

    local mudRemote = getRemoteEvent("Mud")
    if not mudRemote then
        log("[test_mud] ERROR: 'Mud' RemoteEvent not found.")
        return {ok = false, error = "Mud RemoteEvent not found"}
    end
    local hideScentRemote = getRemoteEvent("HideScent")

    local amount0, target0 = getConcealScentProgress()
    log(string.format("[test_mud] Initial ConcealScent mission: %d/%d", amount0, target0))
    log(string.format("[test_mud] Initial ailments: Muddy=%d HideScent=%d",
        getAilmentValue("Muddy"), getAilmentValue("HideScent")))

    local TARGET_ROLLS = 3
    local MUD_ROLL_DURATION = 5  -- seconds; matches game constant
    local successful = 0
    local triedMud = {}

    for roll = 1, 12 do
        if stopFlagExists() then
            log("[test_mud] STOPPED by flag")
            break
        end
        if successful >= TARGET_ROLLS then
            log("[test_mud] Done! Completed " .. successful .. " rolls")
            break
        end

        local pos = getPosition()
        if not pos then
            log("[test_mud] No position — waiting")
            task.wait(1)
        else
            local list = scanAllMud(pos, 2000)
            log(string.format("[test_mud] Roll %d/%d | found %d mud patches within 2000 studs",
                successful + 1, TARGET_ROLLS, #list))

            local target = nil
            for _, info in ipairs(list) do
                if not triedMud[info.obj] then
                    target = info
                    break
                end
            end
            if not target and #list > 0 then
                log("[test_mud] All patches tried — resetting list")
                triedMud = {}
                target = list[1]
            end

            if not target then
                log("[test_mud] No mud found — teleport to biome entry and retry")
                if biome then safeTeleportVec(biome.entry) end
                task.wait(2)
            else
                local mudObj = target.obj
                -- Teleport to the mud patch: slightly above and facing the center.
                local mudPos = target.pos
                log(string.format("[test_mud] TP to mud at (%.1f,%.1f,%.1f) dist=%d",
                    mudPos.X, mudPos.Y, mudPos.Z, math.floor(target.dist)))

                local hrp = getHRP()
                if hrp then
                    pcall(function()
                        -- Stand on top of the mud patch, center of it for Emit particles.
                        hrp.CFrame = CFrame.new(mudPos.X, mudPos.Y + 3, mudPos.Z)
                    end)
                end
                task.wait(0.4)

                -- Verify grounded on mud (best-effort).
                local pos2 = getPosition()
                local onMud = pos2 and ((pos2 - mudPos).Magnitude < 20) or false

                local amountBefore = select(1, getConcealScentProgress())
                local muddyBefore = getAilmentValue("Muddy")
                local hideBefore = getAilmentValue("HideScent")

                -- Wait for full roll duration (game requires MUD_ROLL_DURATION before accepting).
                log(string.format("[test_mud] Rolling for %ds (onMud=%s)...",
                    MUD_ROLL_DURATION, tostring(onMud)))
                local rollStart = tick()
                while tick() - rollStart < MUD_ROLL_DURATION + 0.2 do
                    if stopFlagExists() then break end
                    -- Keep anchored on top while rolling (some games drift the character).
                    local h = getHRP()
                    if h then
                        pcall(function()
                            h.CFrame = CFrame.new(mudPos.X, mudPos.Y + 3, mudPos.Z)
                        end)
                    end
                    task.wait(0.5)
                end
                if stopFlagExists() then break end

                -- Fire the mud remote with the mud root (the tagged instance itself).
                Stealth.fireServer(mudRemote, mudObj)
                log("[test_mud] Mud:FireServer sent")
                task.wait(1.0)
                -- Also send HideScent as the keybind path does (harmless if server ignores).
                if hideScentRemote then
                    Stealth.fireServer(hideScentRemote)
                    log("[test_mud] HideScent:FireServer sent")
                end
                task.wait(1.5)

                local amountAfter = select(1, getConcealScentProgress())
                local muddyAfter = getAilmentValue("Muddy")
                local hideAfter = getAilmentValue("HideScent")
                log(string.format("[test_mud] Post-roll: mission=%d (was %d)  Muddy=%d (was %d)  HideScent=%d (was %d)",
                    amountAfter, amountBefore, muddyAfter, muddyBefore, hideAfter, hideBefore))

                if amountAfter > amountBefore or muddyAfter > muddyBefore or hideAfter > hideBefore then
                    successful = successful + 1
                    log("[test_mud] SUCCESS roll " .. successful .. "/" .. TARGET_ROLLS)
                    -- Small pause before next roll so ailment/particle state settles.
                    task.wait(1.5)
                else
                    log("[test_mud] No effect — marking this mud patch as bad, trying another")
                    triedMud[mudObj] = true
                    task.wait(1)
                end
            end
        end
    end

    local finalAmount, finalTarget = getConcealScentProgress()
    log(string.format("[test_mud] === DONE === successful_rolls=%d/%d  mission=%d/%d",
        successful, TARGET_ROLLS, finalAmount, finalTarget))
    return {
        ok = successful > 0,
        log = string.format("test_mud: %d/%d rolls, mission=%d/%d",
            successful, TARGET_ROLLS, finalAmount, finalTarget)
    }
end
end -- == /test_mud scope ==

do -- == test_survive scope ==
-- Read TimePlayed mission progress for current region.
-- Catalog target is 150 seconds (rbxlx ~5452166).
local function getTimePlayedProgress()
    local amount, target, completed = 0, 0, false
    pcall(function()
        local regionName = detectCurrentRegion()
        if not regionName then return end
        local missions = readRegionMissions(regionName)
        local m = missions and missions.TimePlayed
        if m then
            amount = m.amount or 0
            target = m.targetAmount or 0
            completed = m.completed or false
        end
    end)
    return amount, target, completed
end

handlers.test_survive = function()
    log("[test_survive] === SURVIVE TEST START ===")

    refreshCharacterRefs()
    if not character then
        log("[test_survive] Not in world — attempting to enter...")
        if not tryEnterWorldFromSlotUi(30, DEFAULT_CREATURE) then
            return {ok = false, error = "Could not enter world"}
        end
    else
        log("[test_survive] Already in world")
    end

    local regionName, biome = detectCurrentRegion()
    log("[test_survive] Current region: " .. tostring(regionName))

    if not biome then
        log("[test_survive] ERROR: unknown biome")
        return {ok = false, error = "unknown biome"}
    end

    local amount0, target0, completed0 = getTimePlayedProgress()
    log(string.format("[test_survive] Initial mission: %d/%d (completed=%s)",
        amount0, target0, tostring(completed0)))

    if completed0 then
        log("[test_survive] Mission already completed in this region")
        return {ok = true, log = "test_survive: already complete"}
    end

    -- If the region's daily 3 missions don't include TimePlayed, target will be 0.
    -- Don't waste time — report and exit cleanly.
    if target0 == 0 then
        log("[test_survive] TimePlayed mission is not active in '" .. tostring(regionName)
            .. "' (daily pool rotated). Try another biome.")
        return {ok = true, log = "test_survive: mission not active in " .. tostring(regionName)}
    end

    -- Survive strategy:
    -- 1. Teleport UNDER the safe point — the region-check is XZ only, so we stay in-biome
    --    but most creatures can't reach us for damage.
    -- 2. If HP drops anyway, wiggle XZ slightly so targeted attacks miss.
    -- 3. Primary exit signal is mission `completed` flag, not the wall-clock timer.
    local UNDER_MAP_Y_OFFSET = -55  -- tuned so we're below terrain but far above fallout floor
    local underSafe = {biome.safe[1], biome.safe[2] + UNDER_MAP_Y_OFFSET, biome.safe[3]}
    log(string.format("[test_survive] TP under biome at (%d,%d,%d)",
        underSafe[1], underSafe[2], underSafe[3]))
    safeTeleportVec(underSafe)
    task.wait(1.0)

    -- Hard ceiling — mission target is ~150s but can tick faster in-game when the region
    -- increments every N frames. Keep a generous ceiling and rely on `completed` to exit.
    local hardCeiling = 300
    local startTime = tick()
    local lastLog = 0
    local lastHP = nil
    local wiggles = 0

    while tick() - startTime < hardCeiling do
        if stopFlagExists() then
            log("[test_survive] STOPPED by flag")
            break
        end

        -- Read mission every tick to exit as soon as it's done.
        local amt, tgt, comp = getTimePlayedProgress()
        if comp or (tgt > 0 and amt >= tgt) then
            log(string.format("[test_survive] Mission COMPLETED: %d/%d", amt, tgt))
            break
        end
        -- If the mission disappeared (rolled out of region pool mid-run), exit.
        if tgt == 0 then
            log("[test_survive] Mission no longer active (target==0) — exiting")
            break
        end

        local elapsed = math.floor(tick() - startTime)
        if tick() - lastLog > 5 then
            lastLog = tick()
            local stats = getCreatureStats()
            log(string.format("[test_survive] t=%ds  mission=%d/%d  hp=%s food=%s water=%s  wiggles=%d",
                elapsed, amt, tgt, tostring(stats.hp), tostring(stats.food),
                tostring(stats.water), wiggles))
        end

        -- HP watch: if HP dropped by ≥2, wiggle XZ a bit (stay under map).
        do
            local stats = getCreatureStats()
            local hp = stats.hp
            if type(hp) == "number" then
                if lastHP and hp < lastHP - 2 then
                    wiggles = wiggles + 1
                    local ox = math.random(-45, 45)
                    local oz = math.random(-45, 45)
                    local wigglePos = {biome.safe[1] + ox, biome.safe[2] + UNDER_MAP_Y_OFFSET, biome.safe[3] + oz}
                    log(string.format("[test_survive] Took damage (%d -> %d) — wiggling to (%d,%d,%d)",
                        lastHP, hp, wigglePos[1], wigglePos[2], wigglePos[3]))
                    safeTeleportVec(wigglePos)
                end
                lastHP = hp
            end
        end

        -- Re-anchor if we drifted too far (currents, knockback, fall).
        do
            local p = getPosition()
            if p then
                local dx = p.X - biome.safe[1]
                local dz = p.Z - biome.safe[3]
                if math.sqrt(dx*dx + dz*dz) > 80 or p.Y > biome.safe[2] - 5 then
                    safeTeleportVec(underSafe)
                end
            end
        end

        task.wait(1)
    end

    local finalAmt, finalTgt, finalComp = getTimePlayedProgress()
    local missionMet = finalComp or (finalTgt > 0 and finalAmt >= finalTgt)
    log(string.format("[test_survive] === DONE === mission=%d/%d completed=%s met=%s elapsed=%ds",
        finalAmt, finalTgt, tostring(finalComp), tostring(missionMet),
        math.floor(tick() - startTime)))
    return {
        ok = missionMet,
        log = string.format("test_survive: mission=%d/%d completed=%s",
            finalAmt, finalTgt, tostring(finalComp))
    }
end
end -- == /test_survive scope ==

do -- == test_shrooms scope ==
-- Read ShoomPilesCollected mission progress for current region.
-- Target is 3 per region per day (see rbxlx ~5452170).
local function getShoomProgress()
    local amount, target, completed = 0, 0, false
    pcall(function()
        local regionName = detectCurrentRegion()
        if not regionName then return end
        local missions = readRegionMissions(regionName)
        local m = missions and missions.ShoomPilesCollected
        if m then
            amount = m.amount or 0
            target = m.targetAmount or 0
            completed = m.completed or false
        end
    end)
    return amount, target, completed
end

-- Scan all ShoomPile instances. Try CollectionService first (authoritative) and
-- also sweep workspace.Interactions.ShoomPiles as a fallback. Returns list sorted by distance.
local function scanAllShooms(fromPos, regionFilter)
    local list = {}
    local seen = {}

    local function consume(obj)
        if not obj or not obj.Parent or seen[obj] then return end
        seen[obj] = true
        local region = nil
        local id = nil
        pcall(function()
            region = obj:GetAttribute("Region")
            id = obj:GetAttribute("Id")
        end)
        if regionFilter and region ~= regionFilter then return end

        -- Position: prefer attribute "P", then model pivot / part position.
        local pos = nil
        pcall(function() pos = obj:GetAttribute("P") end)
        if typeof(pos) ~= "Vector3" then
            if obj:IsA("Model") then
                local ok, pivot = pcall(function() return obj:GetPivot().Position end)
                if ok and pivot then pos = pivot end
            elseif obj:IsA("BasePart") then
                pos = obj.Position
            end
        end
        if not pos then return end

        local dist = fromPos and (fromPos - pos).Magnitude or 0
        table.insert(list, {obj = obj, region = region, id = id, pos = pos, dist = dist})
    end

    pcall(function()
        for _, obj in ipairs(CollectionService:GetTagged("ShoomPile")) do
            consume(obj)
        end
    end)
    pcall(function()
        local folder = workspace:FindFirstChild("Interactions")
        if folder then
            local shoomFolder = folder:FindFirstChild("ShoomPiles")
            if shoomFolder then
                for _, obj in ipairs(shoomFolder:GetDescendants()) do
                    if obj:IsA("Model") or obj:IsA("BasePart") then
                        consume(obj)
                    end
                end
            end
        end
    end)

    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

handlers.test_shrooms = function()
    log("[test_shrooms] === SHROOMS TEST START ===")

    refreshCharacterRefs()
    if not character then
        log("[test_shrooms] Not in world — attempting to enter...")
        if not tryEnterWorldFromSlotUi(30, DEFAULT_CREATURE) then
            return {ok = false, error = "Could not enter world"}
        end
    else
        log("[test_shrooms] Already in world")
    end

    local regionName, _biome = detectCurrentRegion()
    log("[test_shrooms] Current region: " .. tostring(regionName))

    -- The pickup is a RemoteFunction (not Event): see rbxlx line ~6015191
    -- local v_u_17 = v10.GetRemoteFunction("ShoomPileCollected")
    -- Invoked as v_u_17:InvokeServer(region:string, id)
    local collectRF = getRemoteFunction("ShoomPileCollected")
    if not collectRF then
        log("[test_shrooms] ERROR: ShoomPileCollected RemoteFunction not found")
        return {ok = false, error = "ShoomPileCollected RemoteFunction missing"}
    end

    local amount0, target0 = getShoomProgress()
    log(string.format("[test_shrooms] Initial mission: %d/%d", amount0, target0))

    local pos = getPosition()
    if not pos then
        log("[test_shrooms] ERROR: no position")
        return {ok = false, error = "no position"}
    end

    -- First look for piles only in the current region.
    local piles = scanAllShooms(pos, regionName)
    log(string.format("[test_shrooms] Found %d piles in region '%s'", #piles, tostring(regionName)))

    if #piles == 0 then
        -- Fallback: scan globally (in case the region attribute is missing/uppercase mismatch).
        piles = scanAllShooms(pos, nil)
        log(string.format("[test_shrooms] Fallback global scan: %d piles total", #piles))
    end

    if #piles == 0 then
        log("[test_shrooms] No shoom piles visible. They may not be spawned in this region right now.")
        return {ok = false, error = "no shoom piles found"}
    end

    -- Game's ShoomPileConstants.MaxDistanceToCollect = 100 studs (see rbxlx line ~5908309).
    local MAX_DIST = 100
    local collected = 0
    local triedPiles = {}

    for attempt = 1, math.max(#piles * 2, 6) do
        if stopFlagExists() then
            log("[test_shrooms] STOPPED by flag")
            break
        end
        if collected >= 3 and target0 > 0 and collected >= target0 then
            log("[test_shrooms] Mission target reached")
            break
        end

        local myPos = getPosition() or pos
        -- Refresh pile list each iteration — after server success, piles are typically
        -- hidden/removed via replicated bool; scanning again keeps the list accurate.
        local fresh = scanAllShooms(myPos, regionName)
        if #fresh == 0 then fresh = scanAllShooms(myPos, nil) end

        local target = nil
        for _, info in ipairs(fresh) do
            if not triedPiles[info.obj] and info.region and info.id then
                target = info
                break
            end
        end

        if not target then
            log("[test_shrooms] No more untried piles")
            break
        end

        -- Teleport: face the pile, close enough to pass CanCollect's distance check.
        local standY = target.pos.Y + 4
        local stand = Vector3.new(target.pos.X, standY, target.pos.Z - 6)
        -- If very far, just plunk us on top of the pile; else approach from slight -Z offset.
        if target.dist > 300 then
            stand = Vector3.new(target.pos.X, target.pos.Y + 4, target.pos.Z - 3)
        end

        log(string.format("[test_shrooms] Target pile region=%s id=%s pos=(%.1f,%.1f,%.1f) dist=%.1f",
            tostring(target.region), tostring(target.id),
            target.pos.X, target.pos.Y, target.pos.Z, target.dist))

        local hrp = getHRP()
        if hrp then
            pcall(function()
                hrp.CFrame = CFrame.lookAt(stand, Vector3.new(target.pos.X, stand.Y, target.pos.Z))
            end)
        end
        task.wait(0.6)

        -- Verify distance after teleport.
        local nowPos = getPosition() or stand
        local distNow = (nowPos - target.pos).Magnitude
        if distNow > MAX_DIST - 5 then
            log(string.format("[test_shrooms] WARN: still %.1f studs from pile (max %d)", distNow, MAX_DIST))
        end

        local amountBefore = select(1, getShoomProgress())

        local ret = Stealth.invokeServer(collectRF, target.region, target.id)
        local ok = ret ~= nil
        if not ok then
            log("[test_shrooms] InvokeServer errored: " .. tostring(ret))
            triedPiles[target.obj] = true
            task.wait(0.5)
        else
            log("[test_shrooms] InvokeServer returned: " .. tostring(ret))
            -- Wait for the server to replicate the mission update and hide the pile.
            task.wait(1.5)
            local amountAfter = select(1, getShoomProgress())
            if amountAfter > amountBefore or ret == true then
                collected = collected + 1
                log(string.format("[test_shrooms] Pile collected! #%d (mission %d → %d)",
                    collected, amountBefore, amountAfter))
                triedPiles[target.obj] = true
            else
                log("[test_shrooms] No progress — marking pile as tried")
                triedPiles[target.obj] = true
                task.wait(0.5)
            end
        end
    end

    local finalAmount, finalTarget = getShoomProgress()
    log(string.format("[test_shrooms] === DONE === collected=%d  mission=%d/%d",
        collected, finalAmount, finalTarget))
    return {
        ok = collected > 0,
        log = string.format("test_shrooms: collected=%d  mission=%d/%d",
            collected, finalAmount, finalTarget)
    }
end
end -- == /test_shrooms scope ==

-- ==========================================================================
-- MISSIONS V2 — delegates to the proven test-button handlers.
--
-- Must be defined AFTER the `handlers` table and all `handlers.test_*`
-- assignments so that internal references resolve correctly (forward-decl
-- `local doMissionStep` was made earlier in the file).
--
-- Priority (per user spec):
--   1. EatFoodDrinkWater          (50 food/water units)
--   2. DistanceTravelled          (2500 studs)
--   3. Sniff                      (5 times)
--   4. ShoomPilesCollected        (3 piles)
--   5. ConcealScent               (3 mud rolls — Land only)
--   6. TimePlayed                 (150 seconds)
--   7. AttackOrHealCreatureOrNPC  (5 bites)
--
-- Mission type names are the real ones from rbxlx ~5452145 (RegionMissions
-- catalog module), confirmed against RawRegionData.
-- ==========================================================================
doMissionStep = function()
    _missionState.deferredUntil = _missionState.deferredUntil or {}
    _missionState.underMapSince = _missionState.underMapSince or 0
    _missionState.runningMission = _missionState.runningMission or nil

    if not _missionState.initialized then
        _missionState.initialized = true
        _missionState.biomeEnteredTime = tick()
        _maxFoodSeen = 0
        _maxWaterSeen = 0
        local b0 = BIOME_ATLAS[_missionState.currentBiomeIdx or 1] or BIOME_ATLAS[1]
        mlog("[MISSIONS-V2] Init, starting biome: " .. (b0 and b0.name or "?"), nil)
        safeTeleportVec(b0.entry)
        task.wait(1.5)
    end

    if stopFlagExists() then return false end
    if Stealth.aborted() then return false end
    if not isCreatureAlive() then return false end

    -- Priority table (1 = highest).
    local PRIO = {
        EatFoodDrinkWater         = 1,
        DistanceTravelled         = 2,
        Sniff                     = 3,
        ShoomPilesCollected       = 4,
        ConcealScent              = 5,
        TimePlayed                = 6,
        AttackOrHealCreatureOrNPC = 7,
    }
    -- Mission type → test handler name (EatFoodDrinkWater is special-cased).
    local HANDLER_NAME = {
        DistanceTravelled         = "test_walk",
        Sniff                     = "test_sniff",
        ShoomPilesCollected       = "test_shrooms",
        ConcealScent              = "test_mud",
        TimePlayed                = "test_survive",
        AttackOrHealCreatureOrNPC = "test_attack",
    }

    local function dkey(biomeName, mType) return biomeName .. "|" .. mType end

    local function isDeferred(biomeName, mType)
        local t = _missionState.deferredUntil[dkey(biomeName, mType)]
        return t and tick() < t
    end

    local function setDeferred(biomeName, mType, seconds, reason)
        _missionState.deferredUntil[dkey(biomeName, mType)] = tick() + seconds
        mlog(string.format("[MISSIONS-V2] Defer %s/%s for %ds (%s)",
            biomeName, mType, seconds, tostring(reason)), nil)
    end

    local function isMissionActive(m)
        if not m then return false end
        if m.completed then return false end
        local tgt = m.targetAmount or 0
        if tgt == 0 then return false end
        if (m.amount or 0) >= tgt then return false end
        return true
    end

    local function missionEligibleInBiome(mType, biome)
        if mType == "ConcealScent" and biome.zone ~= "Land" then return false end
        return PRIO[mType] ~= nil
    end

    local function pickInBiome(biome)
        local missions = readRegionMissions(biome.name)
        if not missions or not next(missions) then return nil end
        local best, bestPrio = nil, 999
        for mType, m in pairs(missions) do
            local p = PRIO[mType]
            if p and isMissionActive(m)
                and missionEligibleInBiome(mType, biome)
                and not isDeferred(biome.name, mType)
                and p < bestPrio
            then
                best = mType
                bestPrio = p
            end
        end
        return best
    end

    local function anyBiomeHasFoodMission()
        for _, b in ipairs(BIOME_ATLAS) do
            local missions = readRegionMissions(b.name)
            if missions and isMissionActive(missions.EatFoodDrinkWater) then
                return true
            end
        end
        return false
    end

    local function findBiomeWithWork()
        local startIdx = (_missionState.currentBiomeIdx or 1)
        for i = 1, #BIOME_ATLAS do
            local idx = ((startIdx - 1 + i) % #BIOME_ATLAS) + 1
            local b = BIOME_ATLAS[idx]
            if pickInBiome(b) then
                return idx, b
            end
        end
        return nil, nil
    end

    -- Run ONE mission to completion via the matching test-handler call.
    -- Uses pre/post mission amounts to decide deferral.
    local function runMissionOnce(mType, biome)
        local regionName = biome.name
        local pre = readRegionMissions(regionName) or {}
        local preM = pre[mType]
        local amountBefore = (preM and preM.amount) or 0
        local targetAmount = (preM and preM.targetAmount) or 0
        mlog(string.format("[MISSIONS-V2] START  %s in %s (%d/%d)",
            mType, regionName, amountBefore, targetAmount), nil)

        _missionState.runningMission = mType

        if mType == "EatFoodDrinkWater" then
            -- Try eat first.
            if handlers.test_eat then
                local ok, err = pcall(handlers.test_eat)
                if not ok then
                    mlog("[MISSIONS-V2] test_eat error: " .. tostring(err), nil)
                end
            end
            if stopFlagExists() then _missionState.runningMission = nil; return end
            -- If still not done, try drink.
            local mid = readRegionMissions(regionName)
            local midM = mid and mid.EatFoodDrinkWater
            local midDone = midM and (midM.completed
                or (midM.amount or 0) >= (midM.targetAmount or 0))
            if not midDone and not stopFlagExists() and handlers.test_drink then
                local ok, err = pcall(handlers.test_drink)
                if not ok then
                    mlog("[MISSIONS-V2] test_drink error: " .. tostring(err), nil)
                end
            end
        else
            local name = HANDLER_NAME[mType]
            local h = name and handlers[name]
            if h then
                local ok, err = pcall(h)
                if not ok then
                    mlog("[MISSIONS-V2] " .. tostring(name) .. " error: " .. tostring(err), nil)
                end
            else
                setDeferred(regionName, mType, 600, "no_handler")
                _missionState.runningMission = nil
                return
            end
        end

        _missionState.runningMission = nil
        if stopFlagExists() then return end
        task.wait(0.5)

        local post = readRegionMissions(regionName) or {}
        local postM = post[mType]
        local amountAfter = (postM and postM.amount) or amountBefore
        local completed = (postM and postM.completed) or false

        if completed
            or (postM and (postM.targetAmount or 0) > 0
                and amountAfter >= postM.targetAmount)
        then
            mlog(string.format("[MISSIONS-V2] DONE   %s in %s (%d/%d)",
                mType, regionName, amountAfter, (postM and postM.targetAmount) or 0), nil)
        elseif amountAfter > amountBefore then
            mlog(string.format("[MISSIONS-V2] PARTIAL %s in %s (%d->%d/%d)",
                mType, regionName, amountBefore, amountAfter,
                (postM and postM.targetAmount) or 0), nil)
        else
            local defer = 120
            if mType == "EatFoodDrinkWater" then defer = 60 end
            if mType == "AttackOrHealCreatureOrNPC" then defer = 180 end
            if mType == "ShoomPilesCollected" then defer = 240 end
            if mType == "Sniff" then defer = 30 end
            setDeferred(regionName, mType, defer, "no_progress")
        end
    end

    -- Hide under the map (XZ-in-biome, Y below terrain) and poll for fresh
    -- missions. Region check is XZ-only, so the current biome keeps ticking.
    local function hideUnderMapAndWait()
        local biome = BIOME_ATLAS[_missionState.currentBiomeIdx or 1] or BIOME_ATLAS[1]
        if (_missionState.underMapSince or 0) == 0 then
            _missionState.underMapSince = tick()
            mlog("[MISSIONS-V2] ALL DONE — hiding under map at " .. biome.name, nil)
        end
        local under = {biome.safe[1], biome.safe[2] - 60, biome.safe[3]}
        safeTeleportVec(under)

        -- Wait 60s with 5s granularity so stop-flag is honored.
        local waited = 0
        while waited < 60 do
            if stopFlagExists() then return end
            if not isCreatureAlive() then return end
            task.wait(5)
            waited = waited + 5
        end

        -- Clear ALL deferrals (they might have refreshed daily) and look again.
        _missionState.deferredUntil = {}
        local idx, b = findBiomeWithWork()
        if idx then
            _missionState.currentBiomeIdx = idx
            _missionState.underMapSince = 0
            mlog("[MISSIONS-V2] Fresh mission at " .. b.name .. " — resuming", nil)
        end
    end

    -- ---- Main step dispatch ----

    local targetBiome = BIOME_ATLAS[_missionState.currentBiomeIdx or 1]
    if not targetBiome then
        _missionState.currentBiomeIdx = 1
        targetBiome = BIOME_ATLAS[1]
    end

    -- Teleport into target biome ONLY when necessary. Test handlers manage their
    -- own positioning (to food / lake / NPC), which routinely puts the bot at the
    -- border of adjacent biomes. Re-TPing to biome.entry every cycle made the bot
    -- thrash between biomes instead of finishing one biome's missions.
    --
    -- Rules:
    --   1. If `currentBiomeIdx` changed since last commit → TP once (explicit rotation).
    --   2. If bot is > 1200 studs from biome.entry → TP (respawn or got flung far).
    --   3. Otherwise: stay put, let the next test handler work locally.
    local regionName = detectCurrentRegion()
    local myPos = getPosition()
    local needTP = false
    local committedIdx = _missionState.committedBiomeIdx
    if committedIdx ~= _missionState.currentBiomeIdx then
        needTP = true  -- explicit biome rotation
    elseif myPos then
        local entry = targetBiome.entry
        local dx = myPos.X - entry[1]
        local dz = myPos.Z - entry[3]
        local distToEntry = math.sqrt(dx*dx + dz*dz)
        if distToEntry > 1200 and regionName ~= targetBiome.name then
            needTP = true  -- drifted far away AND in a different region
        end
    else
        -- No position → character may have just respawned; TP to be safe.
        needTP = true
    end

    if needTP then
        mlog(string.format("[MISSIONS-V2] Entering biome %s (currently: %s)",
            targetBiome.name, tostring(regionName)), nil)
        safeTeleportVec(targetBiome.entry)
        task.wait(1.5)
        regionName = detectCurrentRegion()
        _missionState.committedBiomeIdx = _missionState.currentBiomeIdx

        -- If TP landed us somewhere else AND that biome has pending work,
        -- accept it rather than bouncing.
        if regionName ~= targetBiome.name then
            for idx, b in ipairs(BIOME_ATLAS) do
                if b.name == regionName and pickInBiome(b) then
                    _missionState.currentBiomeIdx = idx
                    _missionState.committedBiomeIdx = idx
                    targetBiome = b
                    mlog("[MISSIONS-V2] TP mismatch — switched to actual biome " .. regionName, nil)
                    break
                end
            end
        end
    else
        -- No TP this cycle; just record commitment so subsequent cycles know.
        _missionState.committedBiomeIdx = _missionState.currentBiomeIdx
    end

    -- Survival: only top up if there's NO food/water mission anywhere,
    -- because otherwise we'd rob ourselves of mission progress in the next biome.
    if not anyBiomeHasFoodMission() then
        local stats = getCreatureStats()
        local need = needsSurvivalAction(stats)
        if need then
            mlog(string.format("[MISSIONS-V2] Survival (no food/water mission): %s hp=%s food=%s water=%s",
                need, tostring(stats.hp), tostring(stats.food), tostring(stats.water)), nil)
            doEmergencyRefill(need)
            return true
        end
    end

    -- Pick highest-priority active & non-deferred mission in current biome.
    local mType = pickInBiome(targetBiome)
    if mType then
        runMissionOnce(mType, targetBiome)
        -- After each completed mission, occasionally insert a longer "human"
        -- idle so the cadence isn't perfectly periodic to onlookers.
        Stealth.maybeIdleBetweenMissions()
        return true
    end

    -- Current biome has no pending work — diagnose & rotate.
    do
        local missions = readRegionMissions(targetBiome.name)
        local summary = {}
        if missions and next(missions) then
            for t, m in pairs(missions) do
                local state = "?"
                if m.completed then state = "done"
                elseif (m.targetAmount or 0) == 0 then state = "inactive"
                elseif isDeferred(targetBiome.name, t) then state = "deferred"
                else state = string.format("%d/%d", m.amount or 0, m.targetAmount or 0) end
                table.insert(summary, t .. "=" .. state)
            end
        else
            table.insert(summary, "(no mission data for this region)")
        end
        mlog("[MISSIONS-V2] No work in " .. targetBiome.name
            .. " | " .. table.concat(summary, ", "), nil)
    end

    local idx, b = findBiomeWithWork()
    if idx then
        _missionState.currentBiomeIdx = idx
        mlog("[MISSIONS-V2] Rotating to biome: " .. b.name, nil)
        return true
    end

    -- Nothing active anywhere → hide under map, wait for refresh.
    hideUnderMapAndWait()
    return true
end

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
    -- CoS uses CharacterData attributes instead of standard Humanoid.Health;
    -- Humanoid may load later or not at all — don't require it.
    pcall(function()
        if character and not humanoid then
            humanoid = character:FindFirstChildOfClass("Humanoid")
        end
    end)

    wait(0.5)

    local cycles = 0
    local totalTokensEarned = {}
    local _lastLoggedDP = -1
    
    while true do
        cycles = cycles + 1
        
        -- Проверяем флаг остановки
        if stopFlagExists() then
            return {
                ok = true,
                log = "Farm stopped by flag after " .. cycles .. " cycles",
                inventory = getInventory(),
                tokens_earned = totalTokensEarned,
            }
        end

        -- Stealth: if the player was kicked / removed while we were running,
        -- exit cleanly instead of looping into a dead character.
        if Stealth.aborted() then
            log("[Stealth] Farm aborted: " .. tostring(Stealth.abortReason()))
            return {
                ok = false,
                error = "Stealth abort: " .. tostring(Stealth.abortReason()),
                inventory = getInventory(),
                tokens_earned = totalTokensEarned,
            }
        end

        local dpOk, currentDP = pcall(getCurrentDeathPoints)
        if not dpOk then
            log("[DP-ERROR] getCurrentDeathPoints crashed: " .. tostring(currentDP))
            currentDP = 0
        end
        currentDP = currentDP or 0
        -- Логируем DP только при изменении или каждые 30 циклов.
        if currentDP ~= _lastLoggedDP or cycles % 30 == 1 then
            log("DP: " .. tostring(currentDP) .. " / " .. TARGET_DP .. "  (cycle " .. cycles .. ")")
            _lastLoggedDP = currentDP
        end

        local invBan = {}
        if joinOrTradeFailStreak >= JOIN_FAIL_BAN_THRESHOLD then
            invBan = getInventory()
        end
        local b = banHeuristicResult(invBan)
        if b then
            b.tokens_earned = totalTokensEarned
            return b
        end

        local justDidSuicide = false
        if currentDP >= TARGET_DP then
            log("Цель DP достигнута (DP=" .. currentDP .. ")")
            justDidSuicide = true
            local earnedTokens = {}
            if VOLCANO_SUICIDE then
                earnedTokens = doSuicideVolcano(currentDP) or {}
            else
                doSuicide()
                earnedTokens = tryClaimDeathRewards(currentDP)
            end

            -- Accumulate tokens across cycles
            for tokenName, count in pairs(earnedTokens) do
                totalTokensEarned[tokenName] = (totalTokensEarned[tokenName] or 0) + count
            end
            writeTokenReport(totalTokensEarned)

            if FARM_PIPELINE == "missions_dp_then_transfer" and TARGET_STORAGE_LOGIN then
                log("Фаза передачи токенов на склад")
                local result = runFarmerStorageTransfer()
                result.tokens_earned = totalTokensEarned
                return result
            end

            if params.stop_after_suicide then
                return {
                    ok = true,
                    log = "DP достигнут, суицид, стоп",
                    death_points_current = 0,
                    inventory = getInventory(),
                    tokens_earned = totalTokensEarned,
                }
            end

            -- Шаг №1 заново: restart существа через remote + вход в мир через Play.
            log("Перезапуск цикла: remote restart + enter world...")
            wait(2)
            pcall(restartCreatureDirectRemote, DEFAULT_CREATURE)
            wait(2)
            if not tryEnterWorldFromSlotUi(120, DEFAULT_CREATURE) then
                return {
                    ok = false,
                    error = "Не удалось повторно войти в мир после суицида",
                    inventory = getInventory(),
                    tokens_earned = totalTokensEarned,
                }
            end
            wait(2)
        else
            -- Wrap in pcall so a single bad step doesn't tear down the farm.
            -- The error is logged; the outer loop re-enters after wait(1).
            local stepOk, stepErr = pcall(doMissionStep)
            if not stepOk then
                log("[FARM] doMissionStep error: " .. tostring(stepErr))
            end
            wait(1)
        end

        -- Handle natural death (not suicide) — claim + шаг №1 заново
        if not justDidSuicide and not isCreatureAlive() then
            log("Существо мертво (не суицид) — claim rewards + перезапуск цикла")
            local naturalDP = getCurrentDeathPoints()
            local naturalTokens = tryClaimDeathRewards(naturalDP)
            for tokenName, count in pairs(naturalTokens) do
                totalTokensEarned[tokenName] = (totalTokensEarned[tokenName] or 0) + count
            end
            writeTokenReport(totalTokensEarned)
            wait(2)
            pcall(restartCreatureDirectRemote, DEFAULT_CREATURE)
            wait(2)
            if not tryEnterWorldFromSlotUi(120, DEFAULT_CREATURE) then
                return {
                    ok = false,
                    error = "Не удалось повторно войти в мир после смерти",
                    inventory = getInventory(),
                    tokens_earned = totalTokensEarned,
                }
            end
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
    log("=== UNIVERSAL SONARIA BOT STARTED === [v47-full-defer-trade-tp]")
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