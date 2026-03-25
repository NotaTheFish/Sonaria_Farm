-- sell.lua
-- Параметры: ranges, priority_tokens, fallback_mode
local HttpService = game:GetService("HttpService")
local args = {...}
if #args == 0 then
    print(HttpService:JSONEncode({ ok = false, error = "missing injector args" }))
    return
end
local params = HttpService:JSONDecode(args[1])

local ranges = params.ranges          -- token -> {min, max}
local priorityTokens = params.priority_tokens
local fallbackMode = params.fallback_mode

local Players = game:GetService("Players")
local player = Players.LocalPlayer

local function openTradeWorld()
    -- Открыть торговый мир (если не открыт)
    -- Например, через TeleportService
end

local function placeStand()
    -- Поставить стойку в случайном месте (или выбрать пустое место)
    -- Это может требовать взаимодействия с GUI
end

local function getInventory()
    -- Получить инвентарь (как в transfer.lua)
    return {}
end

local function sellItem(token, price)
    -- Выставить предмет на стойку по цене price
    -- Нужно найти RemoteEvent для продажи
end

local function main()
    openTradeWorld()
    wait(5)
    placeStand()

    local inventory = getInventory()
    local slots = 4
    local currentSlot = 1

    local function trySell(token)
        local count = inventory[token] or 0
        if count == 0 then return false end
        local priceRange = ranges[token]
        if not priceRange then
            if fallbackMode == "sell_all_when_priority_empty" then
                -- пропускаем
                return false
            else
                return false
            end
        end
        local price = math.random(priceRange.min, priceRange.max)
        sellItem(token, price)
        inventory[token] = count - 1
        return true
    end

    while true do
        local anySold = false
        -- Сначала выставляем приоритетные токены
        for _, token in ipairs(priorityTokens) do
            if trySell(token) then
                anySold = true
                break
            end
        end
        if not anySold and fallbackMode == "sell_all_when_priority_empty" then
            -- Выставляем любые другие токены
            for token, count in pairs(inventory) do
                if count > 0 and not table.find(priorityTokens, token) then
                    if trySell(token) then
                        anySold = true
                        break
                    end
                end
            end
        end
        if not anySold then
            break -- инвентарь пуст
        end
        wait(5) -- пауза между выставлениями
    end

    -- Возвращаем обновлённый инвентарь
    local response = {
        ok = true,
        log = "Sell loop finished",
        inventory = inventory
    }
    print(HttpService:JSONEncode(response))
end

main()