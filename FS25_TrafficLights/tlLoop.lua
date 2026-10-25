-- TESTVÆRKTØJ (kun TLConfig.DEBUG): `tlLoop` i et AD-køretøj sender det frem og tilbage mellem dets
-- første og andet AD-mål med "Kør til" — uden at vente på læs (Påfyld og aflevering holder ved
-- påfyldningsmarkøren uden læsseplads; in-game 25/10). Kør kommandoen igen i køretøjet for at stoppe.
-- Stopper spilleren selv køretøjet væk fra målet, slippes det (genstartes ikke). Tilstand og mål
-- gendannes, når løkken slutter.
TLLoop = {}
TLLoop.vehicles = {}   -- køretøj -> {a, b, nextIsB, wasActive, failures, savedMode, savedFirst}

local G = getfenv(0)
local LOG_PREFIX = "[TrafficLights] "
local ARRIVED_M = 20
local MAX_FAILURES = 3

local function adEnv()
    local env = G.FS25_AutoDrive
    if env ~= nil and env.AutoDrive ~= nil and env.ADGraphManager ~= nil then return env end
    return nil
end

local function controlledVehicle()
    if g_localPlayer == nil or g_localPlayer.getCurrentVehicle == nil then return nil end
    return g_localPlayer:getCurrentVehicle()
end

local function vehicleName(vehicle)
    return vehicle.getName ~= nil and vehicle:getName() or "?"
end

-- Start præcis som AD's HUD: tilstandens start() opretter køreopgaverne (ADSmartPickup-erfaring).
local function driveTo(env, vehicle, markerId)
    local stateModule = vehicle.ad.stateModule
    stateModule:setMode(env.AutoDrive.MODE_DRIVETO)
    stateModule:setFirstMarker(markerId)
    local mode = stateModule:getCurrentMode()
    if mode ~= nil and mode.start ~= nil then
        mode:start(env.AutoDrive.USER_PLAYER or 1)
    else
        vehicle:startAutoDrive()
    end
end

local function nearMarker(env, vehicle, markerId)
    local marker = env.ADGraphManager:getMapMarkerById(markerId)
    local wp = marker ~= nil and env.ADGraphManager:getWayPointById(marker.id) or nil
    local node = vehicle.rootNode
    if wp == nil or node == nil then return false end
    local x, _, z = getWorldTranslation(node)
    return (x - wp.x) ^ 2 + (z - wp.z) ^ 2 <= ARRIVED_M * ARRIVED_M
end

local function release(env, vehicle, loop, reason)
    TLLoop.vehicles[vehicle] = nil
    local stateModule = vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if env ~= nil and stateModule ~= nil and not stateModule:isActive() then
        pcall(function()
            stateModule:setMode(loop.savedMode)
            if loop.savedFirst ~= nil and loop.savedFirst >= 1 then stateModule:setFirstMarker(loop.savedFirst) end
        end)
    end
    Logging.info("%stlLoop: %s sluppet (%s)", LOG_PREFIX, vehicleName(vehicle), reason)
end

function TLLoop:consoleLoop()
    local env = adEnv()
    local vehicle = controlledVehicle()
    if env == nil then return "tlLoop: AutoDrive mangler" end
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil then return "tlLoop: sæt dig i et AD-køretøj først" end
    if TLLoop.vehicles[vehicle] ~= nil then
        release(env, vehicle, TLLoop.vehicles[vehicle], "stoppet med tlLoop")
        return "tlLoop: stoppet for dette køretøj (det kører færdigt til sit mål)"
    end
    local stateModule = vehicle.ad.stateModule
    local a, b = stateModule:getFirstMarkerId(), stateModule:getSecondMarkerId()
    if a == nil or b == nil or a < 1 or b < 1 or a == b then return "tlLoop: vælg to forskellige AD-mål (første og andet) først" end
    local loop = {a = a, b = b, nextIsB = true, wasActive = false, failures = 0,
        savedMode = stateModule:getMode(), savedFirst = a}
    if stateModule:isActive() and vehicle.stopAutoDrive ~= nil then vehicle:stopAutoDrive() end
    TLLoop.vehicles[vehicle] = loop
    Logging.info("%stlLoop: %s kører frem og tilbage mellem mål %s og %s", LOG_PREFIX, vehicleName(vehicle), tostring(a), tostring(b))
    return "tlLoop: kører frem og tilbage - kør tlLoop igen i køretøjet for at stoppe"
end

local function step(env, vehicle, loop)
    local active = vehicle.ad.stateModule:isActive()
    if active then
        loop.wasActive = true
        return
    end
    if loop.wasActive then
        -- var i gang og står nu stille: nået frem, eller stoppet af spilleren?
        local target = loop.nextIsB and loop.a or loop.b -- det mål, det sidst kørte mod
        if not nearMarker(env, vehicle, target) then
            release(env, vehicle, loop, "stoppet væk fra målet")
            return
        end
        loop.wasActive = false
    end
    local target = loop.nextIsB and loop.b or loop.a
    local ok, err = pcall(driveTo, env, vehicle, target)
    if ok and vehicle.ad.stateModule:isActive() then
        loop.nextIsB = not loop.nextIsB
        loop.wasActive = true
        loop.failures = 0
    else
        loop.failures = loop.failures + 1
        if loop.failures >= MAX_FAILURES then
            release(env, vehicle, loop, "kunne ikke starte: " .. tostring(err or "AD gik ikke i gang"))
        end
    end
end

-- Kaldes af TLManager hver takt.
function TLLoop.update()
    local env = adEnv()
    if env == nil or g_server == nil then return end
    for vehicle, loop in pairs(TLLoop.vehicles) do
        if vehicle.isDeleted or vehicle.ad == nil or vehicle.ad.stateModule == nil then
            TLLoop.vehicles[vehicle] = nil
        else
            step(env, vehicle, loop)
        end
    end
end

if TLConfig ~= nil and TLConfig.DEBUG and addConsoleCommand ~= nil then
    addConsoleCommand("tlLoop", "Lyskurve-test: kør AD-køretøjet frem og tilbage mellem dets to mål", "consoleLoop", TLLoop)
end
