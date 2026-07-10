--[[
    fivem-bridge :: bridge/server.lua
    Server-side adapter. Normalizes money / identifier / job across
    ESX, QBCore, Qbox and standalone.

    Your script only ever calls Bridge.* — it never touches a framework object.

    Standalone storage uses oxmysql (table in sql/bridge.sql). To run with zero
    dependencies instead, swap the Bridge._standalone* bodies for the KVP
    variants documented in the README.
]]

local FW = Bridge.Framework

-- Grab the shared/core object once for the framework branches.
local core
if FW == 'esx' then
    core = exports['es_extended']:getSharedObject()
elseif FW == 'qb' then
    core = exports['qb-core']:GetCoreObject()
elseif FW == 'qbox' then
    core = exports.qbx_core:GetCoreObject()
end

-- Internal: resolve a framework player object from a server id.
local function getPlayer(src)
    if FW == 'esx' then return core.GetPlayerFromId(src) end
    if FW == 'qb' or FW == 'qbox' then return core.Functions.GetPlayer(src) end
    return nil
end

-- ESX stores cash under the account name 'money'; everything else uses 'cash'.
local function esxAccount(account)
    return account == 'cash' and 'money' or account
end

--------------------------------------------------------------------------------
-- Standalone persistence (oxmysql). See sql/bridge.sql for the table.
--------------------------------------------------------------------------------

function Bridge._standaloneGetMoney(src)
    local id = GetPlayerIdentifierByType(src, 'license')
    if not id then return 0 end
    local row = MySQL.single.await('SELECT cash FROM bridge_money WHERE identifier = ?', { id })
    return (row and row.cash) or 0
end

function Bridge._standaloneAddMoney(src, amount)
    local id = GetPlayerIdentifierByType(src, 'license')
    if not id then return false end
    MySQL.prepare.await([[
        INSERT INTO bridge_money (identifier, cash) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE cash = cash + ?
    ]], { id, amount, amount })
    return true
end

function Bridge._standaloneRemoveMoney(src, amount)
    local id = GetPlayerIdentifierByType(src, 'license')
    if not id then return false end
    -- Atomic: only deducts if the balance is high enough (no race, no negative).
    local affected = MySQL.update.await(
        'UPDATE bridge_money SET cash = cash - ? WHERE identifier = ? AND cash >= ?',
        { amount, id, amount })
    return affected ~= nil and affected > 0
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- A stable, unique identifier for a player.
---@param src number server id
---@return string|nil
function Bridge.GetIdentifier(src)
    if FW == 'esx' then
        local p = getPlayer(src); return p and p.identifier
    elseif FW == 'qb' or FW == 'qbox' then
        local p = getPlayer(src); return p and p.PlayerData.citizenid
    end
    return GetPlayerIdentifierByType(src, 'license')
end

--- Current balance of an account ('cash' by default).
---@param src number
---@param account? string
---@return number
function Bridge.GetMoney(src, account)
    account = account or 'cash'
    if FW == 'esx' then
        local p = getPlayer(src)
        return (p and p.getAccount(esxAccount(account)).money) or 0
    elseif FW == 'qb' or FW == 'qbox' then
        local p = getPlayer(src)
        return (p and p.PlayerData.money[account]) or 0
    end
    return Bridge._standaloneGetMoney(src)
end

--- Give money. Returns true on success.
---@param src number
---@param amount number positive
---@param account? string
---@return boolean
function Bridge.AddMoney(src, amount, account)
    account = account or 'cash'
    if type(amount) ~= 'number' or amount <= 0 then return false end
    if FW == 'esx' then
        local p = getPlayer(src); if not p then return false end
        p.addAccountMoney(esxAccount(account), amount); return true
    elseif FW == 'qb' or FW == 'qbox' then
        local p = getPlayer(src); if not p then return false end
        return p.Functions.AddMoney(account, amount) and true or false
    end
    return Bridge._standaloneAddMoney(src, amount)
end

--- Take money. Returns true ONLY if the player could afford it (atomic).
---@param src number
---@param amount number positive
---@param account? string
---@return boolean
function Bridge.RemoveMoney(src, amount, account)
    account = account or 'cash'
    if type(amount) ~= 'number' or amount <= 0 then return false end
    if FW == 'esx' then
        local p = getPlayer(src); if not p then return false end
        if p.getAccount(esxAccount(account)).money < amount then return false end
        p.removeAccountMoney(esxAccount(account), amount); return true
    elseif FW == 'qb' or FW == 'qbox' then
        local p = getPlayer(src); if not p then return false end
        return p.Functions.RemoveMoney(account, amount) and true or false
    end
    return Bridge._standaloneRemoveMoney(src, amount)
end

--- Player's job as a normalized table: { name, label, grade }.
---@param src number
---@return { name: string, label: string, grade: number }
function Bridge.GetJob(src)
    if FW == 'esx' then
        local p = getPlayer(src)
        if not p then return { name = 'unemployed', label = 'Unemployed', grade = 0 } end
        local j = p.getJob()
        return { name = j.name, label = j.label, grade = j.grade }
    elseif FW == 'qb' or FW == 'qbox' then
        local p = getPlayer(src)
        if not p then return { name = 'unemployed', label = 'Unemployed', grade = 0 } end
        local j = p.PlayerData.job
        return { name = j.name, label = j.label, grade = j.grade.level }
    end
    return { name = 'unemployed', label = 'Unemployed', grade = 0 }
end

--------------------------------------------------------------------------------
-- Self-test command:  /bridgetest   (prints detected framework + your money)
--------------------------------------------------------------------------------
RegisterCommand('bridgetest', function(src)
    if src == 0 then
        print(('[fivem-bridge] framework=%s version=%s'):format(Bridge.Framework, Bridge.Version))
        return
    end
    local id = Bridge.GetIdentifier(src)
    local money = Bridge.GetMoney(src)
    local job = Bridge.GetJob(src)
    print(('[fivem-bridge] src=%d framework=%s id=%s cash=%d job=%s')
        :format(src, Bridge.Framework, tostring(id), money, job.name))
end, false)
