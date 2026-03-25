-- transfer.lua
-- Параметры: JSON с полями: target_storage_login, batch_size, token_kinds, ...
local HttpService = game:GetService("HttpService")
local args = {...}
if #args == 0 then
    print(HttpService:JSONEncode({ ok = false, error = "missing injector args" }))
    return
end
local params = HttpService:JSONDecode(args[1])

local targetLogin = params.target_storage_login
local batchSize = params.batch_size
local tokenKinds = params.token_kinds

local Players = game:GetService("Players")
local player = Players.LocalPlayer

-- Функция поиска игрока по имени
local function findPlayerByName(name)
    for _, p in pairs(Players:GetPlayers()) do
        if p.Name:lower() == name:lower() then
            return p
        end
    end
    return nil
end

local function sendTrade(targetPlayer, itemsToGive)
    -- Открыть торговое окно (зависит от игры)
    -- Например, вызвать RemoteEvent для отправки запроса на трейд.
    local tradeService = game:GetService("ReplicatedStorage"):FindFirstChild("TradeService")
    if tradeService then
        tradeService:InvokeServer(targetPlayer, itemsToGive)
        wait(2)
        -- Подтверждение
        tradeService:InvokeServer("confirm")
        wait(1)
    end
end

local function getInventoryItems()
    -- Получить список токенов в инвентаре игрока
    -- Это зависит от того, как хранится инвентарь в игре.
    local inventory = {}
    -- Пример: в ReplicatedStorage есть папка Items
    local itemsFolder = game:GetService("ReplicatedStorage"):FindFirstChild("Items")
    if itemsFolder then
        for _, item in pairs(itemsFolder:GetChildren()) do
            if table.find(tokenKinds, item.Name) then
                inventory[item.Name] = inventory[item.Name] or 0
                inventory[item.Name] = inventory[item.Name] + 1
            end
        end
    end
    return inventory
end

local function performTransfer()
    local storage = findPlayerByName(targetLogin)
    if not storage then
        return false, "Storage player not found"
    end

    local inventory = getInventoryItems()
    local anyItems = false
    for token, count in pairs(inventory) do
        if count > 0 then anyItems = true end
    end
    if not anyItems then
        return true, "No items to transfer"
    end

    -- Передаём пачками
    for token, count in pairs(inventory) do
        local sent = 0
        while sent < count do
            local amount = math.min(batchSize, count - sent)
            sendTrade(storage, { {token = token, amount = amount} })
            sent = sent + amount
            wait(70) -- cooldown
        end
    end

    return true, "Transfer completed"
end

local success, message = performTransfer()
-- Формируем ответ (будет записан в response.json)
local response = {
    ok = success,
    log = message,
    inventory = getInventoryItems() -- вернём обновлённый инвентарь
}
print(HttpService:JSONEncode(response))