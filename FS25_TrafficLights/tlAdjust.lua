-- Justering af stoplinjer (spec 5.8, Task 11). Spilleren står ved et lyskryds og trykker Alt+T: stoplinjerne
-- vises med numre, Alt+J vælger indkørsel, Alt+I/K flytter linjen frem/tilbage, Alt+U slår lyset til/fra,
-- Alt+R nulstiller. Tasterne står i spillets egen hjælpeboks (F1); på skærmen kun én statuslinje (ryddeligt UI).
-- Virker også på MP-klienter: alt læses fra layoutet, ændringer sendes som TLAdjustEvent.
TLAdjust = {}

TLAdjust.REACH_M = 30            -- så tæt på en stoplinje skal spilleren stå for at kunne åbne visningen
TLAdjust.CLOSE_M = 60            -- går spilleren længere væk, lukker visningen
local ACTIONS = {"TL_ADJUST", "TL_NEXT", "TL_STOP_FORWARD", "TL_STOP_BACK", "TL_TOGGLE", "TL_RESET"}

TLAdjust.active = nil            -- lyskurven, der justeres
TLAdjust.selected = 1
TLAdjust.events = {}

---------------------------------------------------------------- rene hjælpere (testes i tests/test_tlAdjust.lua)

-- lights = {{key, layout}}; nøglen for lyskrydset med den nærmeste stoplinje inden for reach, ellers nil
function TLAdjust.nearestLight(lights, x, z, reach)
    local bestKey, bestDistance = nil, reach
    for _, light in ipairs(lights) do
        for _, stop in ipairs(light.layout ~= nil and light.layout.stops or {}) do
            local d = math.sqrt((stop.x - x) ^ 2 + (stop.z - z) ^ 2)
            if d <= bestDistance then bestKey, bestDistance = light.key, d end
        end
    end
    return bestKey
end

-- Valgmulighederne: indkørslerne efter id og til sidst "forældede justeringer", hvis der er nogen.
function TLAdjust.entries(layout)
    local entries = {}
    for _, stop in ipairs(layout ~= nil and layout.stops or {}) do table.insert(entries, stop) end
    table.sort(entries, function(a, b) return a.id < b.id end)
    if layout ~= nil and (layout.stale or 0) > 0 then table.insert(entries, {id = 0, stale = true, count = layout.stale}) end
    return entries
end

function TLAdjust.nextIndex(index, count)
    if count <= 0 then return 1 end
    return index % count + 1
end

function TLAdjust.statusLine(entry, texts)
    if entry.stale then return string.format(texts.stale, entry.count or 0) end
    local parts = {string.format(texts.approach, entry.id)}
    if (entry.shift or 0) ~= 0 then table.insert(parts, string.format(texts.shifted, entry.shift)) end
    if entry.enabled == false then table.insert(parts, texts.off) end
    return table.concat(parts, " - ")
end

---------------------------------------------------------------- spillet

local function text(key, fallback)
    if g_i18n ~= nil and g_i18n:hasText(key, TLAdjust.modName) then return g_i18n:getText(key, TLAdjust.modName) end
    return fallback
end

local function playerPosition()
    if g_localPlayer == nil or g_localPlayer.getPosition == nil then return nil end
    local x, _, z = g_localPlayer:getPosition()
    return x, z
end

local function visualLights()
    local list = {}
    for placeable in pairs(TLManager ~= nil and TLManager.visualLights or {}) do
        local spec = placeable.getTrafficLightSpec ~= nil and placeable:getTrafficLightSpec() or nil
        if spec ~= nil then table.insert(list, {key = placeable, layout = spec.layout}) end
    end
    return list
end

local function activeLayout()
    local spec = TLAdjust.active ~= nil and TLAdjust.active:getTrafficLightSpec() or nil
    return spec ~= nil and spec.layout or nil
end

local function currentEntry()
    local entries = TLAdjust.entries(activeLayout())
    if #entries == 0 then return nil end
    TLAdjust.selected = math.max(1, math.min(#entries, TLAdjust.selected))
    return entries[TLAdjust.selected]
end

local function send(action)
    local entry = currentEntry()
    if TLAdjust.active == nil or entry == nil or TLAdjustEvent == nil then return end
    if entry.stale and action ~= PlaceableTrafficLight.ADJUST.RESET then return end
    TLAdjustEvent.send(TLAdjust.active, entry.id, action)
end

function TLAdjust:onAdjust()
    if TLAdjust.active ~= nil then
        TLAdjust.active = nil
        return
    end
    local x, z = playerPosition()
    if x == nil then return end
    TLAdjust.active = TLAdjust.nearestLight(visualLights(), x, z, TLAdjust.REACH_M)
    TLAdjust.selected = 1
end

function TLAdjust:onNext()
    TLAdjust.selected = TLAdjust.nextIndex(TLAdjust.selected, #TLAdjust.entries(activeLayout()))
end
function TLAdjust:onForward() send(PlaceableTrafficLight.ADJUST.FORWARD) end
function TLAdjust:onBack() send(PlaceableTrafficLight.ADJUST.BACK) end
function TLAdjust:onToggle() send(PlaceableTrafficLight.ADJUST.TOGGLE) end
function TLAdjust:onReset() send(PlaceableTrafficLight.ADJUST.RESET) end

local CALLBACKS = {TL_ADJUST = TLAdjust.onAdjust, TL_NEXT = TLAdjust.onNext, TL_STOP_FORWARD = TLAdjust.onForward,
    TL_STOP_BACK = TLAdjust.onBack, TL_TOGGLE = TLAdjust.onToggle, TL_RESET = TLAdjust.onReset}

local shownState = {}            -- event-id -> sidst sat aktiv-tilstand (nulstilles ved ny registrering)

-- Til fods: spillerens globale handlinger registreres igen ved hvert skift ind/ud af køretøjer (samme krog som
-- ADRoutePlanner, bevist i spillet).
local function registerActions(component)
    local player = component ~= nil and component.player or nil
    if player ~= nil and player.isOwner == false then return end
    if g_inputBinding == nil or InputAction == nil then return end
    TLAdjust.events = {}
    shownState = {}
    for _, name in ipairs(ACTIONS) do
        if InputAction[name] ~= nil then
            local _, eventId = g_inputBinding:registerActionEvent(InputAction[name], TLAdjust, CALLBACKS[name], false, true, false, true)
            if eventId ~= nil then
                g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_HIGH)
                g_inputBinding:setActionEventActive(eventId, false)
                TLAdjust.events[name] = eventId
            end
        end
    end
end

function TLAdjust.installInputHook()
    if PlayerInputComponent == nil or PlayerInputComponent.registerGlobalPlayerActionEvents == nil then return end
    PlayerInputComponent.tlRegisterHandler = function(component) registerActions(component) end
    if PlayerInputComponent.tlHooked then return end
    -- kun til fods: et køretøj kalder den også (med sin context), og så ville vores id'er pege på køretøjets
    -- events, mens spillerens stod slukket (review H1)
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerGlobalPlayerActionEvents,
        function(component, contextName)
            local handler = PlayerInputComponent.tlRegisterHandler
            if handler ~= nil and contextName == nil then handler(component) end
        end)
    PlayerInputComponent.tlHooked = true
end

local function setActive(name, active)
    local eventId = TLAdjust.events[name]
    if eventId ~= nil and shownState[eventId] ~= active then
        g_inputBinding:setActionEventActive(eventId, active)
        shownState[eventId] = active
    end
end

-- Hver frame: Alt+T kun nær et lyskryds; resten kun mens visningen er åben. Lukker, hvis lyskurven forsvinder
-- eller spilleren går væk.
function TLAdjust:update(dt)
    if g_inputBinding == nil then return end
    local x, z = playerPosition()
    if TLAdjust.active ~= nil then
        local gone = TLManager == nil or TLManager.visualLights[TLAdjust.active] == nil
        local far = x == nil or TLAdjust.nearestLight({{key = TLAdjust.active, layout = activeLayout()}}, x, z, TLAdjust.CLOSE_M) == nil
        if gone or far then TLAdjust.active = nil end
    end
    local near = x ~= nil and TLAdjust.nearestLight(visualLights(), x, z, TLAdjust.REACH_M) ~= nil
    setActive("TL_ADJUST", TLAdjust.active ~= nil or near)
    for _, name in ipairs(ACTIONS) do
        if name ~= "TL_ADJUST" then setActive(name, TLAdjust.active ~= nil) end
    end
end

local SELECTED, NORMAL, OFF = {1, 1, 0}, {0.3, 0.8, 1}, {0.5, 0.5, 0.5}

local function drawView()
    local entry = currentEntry()
    local layout = activeLayout()
    for _, stop in ipairs(layout ~= nil and layout.stops or {}) do
        local color = (entry ~= nil and stop.id == entry.id) and SELECTED or (stop.enabled and NORMAL or OFF)
        local y = (g_terrainNode ~= nil and getTerrainHeightAtWorldPos(g_terrainNode, stop.x, 0, stop.z) or 0) + 0.3
        local px, pz = -math.sin(stop.heading) * 2.5, math.cos(stop.heading) * 2.5
        DebugUtil.drawDebugLine(stop.x - px, y, stop.z - pz, stop.x + px, y, stop.z + pz, color[1], color[2], color[3])
        Utils.renderTextAtWorldPosition(stop.x, y + 1.2, stop.z, tostring(stop.id), getCorrectTextSize(0.02), 0,
            color[1], color[2], color[3], 1)
    end
    if entry ~= nil then
        local line = TLAdjust.statusLine(entry, {approach = text("tl_adjustApproach", "Approach %d"),
            shifted = text("tl_adjustShifted", "moved %+.1f m"), off = text("tl_adjustOff", "no light"),
            stale = text("tl_adjustStale", "%d outdated adjustments - reset deletes them")})
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(1, 1, 1, 1)
        renderText(0.5, 0.93, getCorrectTextSize(0.016), line)
    end
end

-- Tekststilen nulstilles efter visningen (samme mønster som ADRoutePlanner.drawHud).
function TLAdjust:draw()
    if TLAdjust.active == nil then return end
    setTextBold(false)
    drawView()
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

if g_currentModName ~= nil then
    TLAdjust.modName = g_currentModName
    TLAdjust.installInputHook()
    addModEventListener(TLAdjust)
end
