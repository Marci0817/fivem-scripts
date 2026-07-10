--[[
    fivem-bridge :: bridge/shared.lua
    Loaded on BOTH client and server.

    Detects the active framework once at load and exposes the version.
    This is the only place that decides which framework you are on.
]]

Bridge = Bridge or {}

-- Bump MINOR when you ADD a Bridge.* function. Bump MAJOR only if you ever
-- rename/remove one (which should be never — see README "The contract").
Bridge.Version = '1.0.0'

-- Detection order matters: check the more specific cores first.
Bridge.Framework =
    (GetResourceState('es_extended') == 'started' and 'esx') or
    (GetResourceState('qbx_core')   == 'started' and 'qbox') or
    (GetResourceState('qb-core')    == 'started' and 'qb') or
    'standalone'

function Bridge.GetFramework()
    return Bridge.Framework
end

function Bridge.IsStandalone()
    return Bridge.Framework == 'standalone'
end
