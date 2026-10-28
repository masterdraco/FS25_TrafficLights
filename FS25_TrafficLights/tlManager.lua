-- Én samlet takt for alle lyskurve (spec 5.10): AD- og CP-køretøjer hentes én gang pr. takt og fordeles
-- til lyskurvene; hver lyskurv kører efterspørgsel -> lysfaser -> hold. Kun på serveren.
TLManager = {}
TLManager.lights = {}
TLManager.holdLookup = {}     -- AD-køretøj -> true, når det skal holde for rødt (læses af AD-hooket)
TLManager.tickState = {}      -- pr. lyskurv: running (takt i gang) og retryAt (pause efter en fejl)
local TICK_FAIL_PAUSE_MS = 10000
TLManager.debugDraw = TLConfig.DEBUG
TLManager.sinceTickMs = 0
TLManager.hookInstalled = false

local LOG_PREFIX = "[TrafficLights] "

TLManager.visualLights = {}   -- lyskurve med lamper at opdatere (også på MP-klienter)

function TLManager.registerVisual(placeable)
    TLManager.visualLights[placeable] = true
end

function TLManager.unregisterVisual(placeable)
    TLManager.visualLights[placeable] = nil
end

function TLManager.register(placeable)
    TLManager.lights[placeable] = true
end

function TLManager.unregister(placeable)
    TLManager.lights[placeable] = nil
end

function TLManager.shouldHoldAD(vehicle)
    return TLManager.holdLookup[vehicle] == true
end

function TLManager.otherLights(placeable)
    local list = {}
    for light in pairs(TLManager.lights) do
        if light ~= placeable then table.insert(list, light) end
    end
    return list
end

local function tick(nowMs)
    local adSnapshots = TLAutoDrive.snapshots()
    -- CP's egen kørsel og spillets AI-kørsel (hjælpere, CP's vejtur) behandles ens: rute + hold pr. kind
    -- samme køretøj må kun optræde én gang (ved et opgaveskift kan CP og spillets AI overlappe — review)
    local cpSnapshots = TLCourseplay.snapshots()
    local seen = {}
    for _, snapshot in ipairs(cpSnapshots) do seen[snapshot.key] = true end
    for _, snapshot in ipairs(TLAIDrive.snapshots()) do
        if not seen[snapshot.key] then table.insert(cpSnapshots, snapshot) end
    end
    -- Fejlsikring uden pcall (ModHub tillader det ikke): intet hold må overleve en fejlende takt (ellers
    -- holdes AD-køretøjer for evigt — review), så tabellen tømmes FØR takten. En lyskurv, hvis takt kastede
    -- en Lua-fejl, står med running = true næste gang: den slippes (trafikspor åbnes) og holder pause,
    -- så de øvrige lyskurve kører videre. Fejlen selv står i log.txt.
    TLManager.holdLookup = {}
    local holdLookup = {}
    for light in pairs(TLManager.lights) do
        local run = TLManager.tickState[light] or {}
        TLManager.tickState[light] = run
        if run.running then
            run.running = false
            run.retryAt = nowMs + TICK_FAIL_PAUSE_MS
            Logging.warning("%straffic light tick failed (see the error above); released, retrying in %d s",
                LOG_PREFIX, TICK_FAIL_PAUSE_MS / 1000)
            light:releaseTrafficLight()
        end
        if run.retryAt == nil or nowMs >= run.retryAt then
            run.retryAt = nil
            local lightHolds = {}
            run.running = true
            light:runTrafficLightTick(adSnapshots, cpSnapshots, nowMs, lightHolds)
            run.running = false
            for vehicle in pairs(lightHolds) do holdLookup[vehicle] = true end
        end
    end
    TLManager.holdLookup = holdLookup
end

function TLManager:update(dt)
    -- lamperne (også blinkende gult) opdateres hver frame, på alle maskiner med skærm
    for light in pairs(TLManager.visualLights) do
        local spec = light:getTrafficLightSpec()
        if spec ~= nil and spec.visualHeads ~= nil then TLVisuals.update(spec, g_time) end
    end
    if g_server == nil then return end
    if not TLManager.hookInstalled then
        TLManager.hookInstalled = TLAutoDrive.installHoldHook(TLManager.shouldHoldAD)
    end
    if not TLAIDrive.hookInstalled and TLAIDrive.installHoldHook() then
        Logging.info("[TrafficLights] hold for base-game AI driving installed")
    end
    TLManager.sinceTickMs = TLManager.sinceTickMs + dt
    if TLManager.sinceTickMs >= TLConfig.TICK_MS then
        TLManager.sinceTickMs = 0
        if TLLoop ~= nil then TLLoop.update() end -- tools/tlLoop.lua (testværktøj, ikke i udgivelsen)
        tick(g_time)
    end
end

function TLManager:draw()
    if not TLManager.debugDraw then return end
    for light in pairs(TLManager.lights) do light:drawTrafficLightDebug() end
end

function TLManager:deleteMap()
    for light in pairs(TLManager.lights) do
        light:releaseTrafficLight()
    end
    TLManager.lights = {}
    TLManager.visualLights = {}
    TLManager.holdLookup = {}
    TLManager.tickState = {}
    TLManager.hookInstalled = false
    TLAutoDrive.uninstall()
    TLVisuals.releaseAssets()
end

-- tlStatus: hver lyskurvs tilstand i log.txt (fase, efterspørgsel, hvem der optager krydset, hold)
function TLManager:consoleStatus()
    local count = 0
    for light in pairs(TLManager.lights) do
        count = count + 1
        TLManager.logStatus(light)
    end
    return string.format("tlStatus: %d traffic light(s) - see log.txt", count)
end

function TLManager.logStatus(light)
        local spec = light:getTrafficLightSpec()
        if spec == nil or spec.state == nil then return end
        local intersection = spec.intersection
        local state, input = spec.state, spec.lastInput
        Logging.info("%sstatus: intersection at (%.0f, %.0f): phase %s, green %s, %s", LOG_PREFIX,
            intersection and intersection.center.x or 0, intersection and intersection.center.z or 0,
            tostring(state.phase), tostring(state.greenId), spec.disabledReason or "active")
        if input ~= nil then
            local parts = {}
            for id, approach in pairs(input.approaches or {}) do
                table.insert(parts, string.format("%s:%s%s%s", tostring(id), approach.enabled and "on" or "off",
                    approach.demand and ",waiting" or "", (input.exitRoom or {})[id] == false and ",exit full" or ""))
            end
            table.sort(parts)
            Logging.info("%sstatus:   approaches %s", LOG_PREFIX, table.concat(parts, "  "))
            Logging.info("%sstatus:   occupied=%s (%s), stuck %d ms, clearing %s ms", LOG_PREFIX, tostring(input.zoneOccupied),
                table.concat(input.occupiedBy or {}, ", "), input.zoneStuckMs or 0, tostring(input.trafficClearMs))
        end
        for _, approach in ipairs(intersection and intersection.approaches or {}) do
            for _, lane in ipairs(approach.lanes or {}) do
                if lane.kind == "TRAFFIC" then
                    local x, z = nil, nil
                    if getSplinePosition ~= nil then
                        local px, _, pz = getSplinePosition(lane.splineId, lane.splineTime)
                        x, z = px, pz
                    end
                    Logging.info("%sstatus:   traffic lane at approach %s: spline %s t=%.4f at (%s, %s) %s", LOG_PREFIX,
                        tostring(approach.id), tostring(lane.splineId), lane.splineTime or -1,
                        x and string.format("%.1f", x) or "?", z and string.format("%.1f", z) or "?",
                        lane.blocked and "BLOCKED" or "open")
                end
            end
        end
        for _, item in ipairs(spec.lastHoldList or {}) do
            -- kun dem, der faktisk holdes (holdlisten har også dem ved en grøn stoplinje)
            if not TLController.mayPass(state, item.approachId) then Logging.info("%sstatus:   held: %s (%s) at approach %s", LOG_PREFIX,
                item.key ~= nil and item.key.getName ~= nil and item.key:getName() or tostring(item.key), tostring(item.kind), tostring(item.approachId)) end
        end
end

-- tlLamp / tlMastYaw: byg alle synlige lys om med de nye værdier (serveren; klienterne får det nye layout)
TLVisuals.rebuildAll = function()
    for light in pairs(TLManager.lights) do
        local spec = light:getTrafficLightSpec()
        if spec ~= nil and spec.intersection ~= nil then
            light:publishLayout()
        end
    end
end

function TLManager:consoleDebug()
    TLManager.debugDraw = not TLManager.debugDraw
    return "tlDebug: " .. (TLManager.debugDraw and "on" or "off")
end

if addConsoleCommand ~= nil then
    addConsoleCommand("tlDebug", "Traffic Lights: show/hide conflict zone, stop lines and signals", "consoleDebug", TLManager)
    addConsoleCommand("tlStatus", "Traffic Lights: write the state of every traffic light to log.txt", "consoleStatus", TLManager)
end

addModEventListener(TLManager)
