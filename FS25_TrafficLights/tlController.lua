-- Lysfaser for ét kryds (spec 5.5/5.6). Ren Lua: ingen spil-API, muterer aldrig sit input.
-- Faser: IDLE (alt rødt) -> GREEN (én indkørsel) -> AMBER -> CLEARING (vent på tom zone) -> GREEN/IDLE.
-- OUT_OF_ORDER (blinkende gult, alle må køre) når et køretøj har siddet fast i zonen i STUCK_MS.
TLController = {}

function TLController.initialState()
    return {phase = "IDLE", greenId = nil, phaseStartMs = 0, passedWhileWaiting = 0}
end

local function withChanges(state, changes)
    local copy = {}
    for key, value in pairs(state) do copy[key] = value end
    for key, value in pairs(changes) do copy[key] = value end
    return copy
end

local function enter(phase, nowMs, greenId)
    return {phase = phase, greenId = greenId, phaseStartMs = nowMs, passedWhileWaiting = 0, lastProgressMs = nowMs}
end

local GREEN_STALL_MS = 15000      -- grønt uden at nogen kører over linjen, mens andre venter -> gult (review)
local COMMITTED_WAIT_MAX_MS = 8000 -- rydning venter højst så længe på forpligtede trafikbiler (review)

-- Den indkørsel, der skal have grønt næst: længst ventende, der må køre (aktiv, efterspørgsel, plads i
-- udkørslen); lige ventetid -> laveste id. excludeId springes over.
function TLController.nextCandidate(input, excludeId)
    local bestId, bestWait = nil, nil
    for id, approach in pairs(input.approaches or {}) do
        local hasRoom = (input.exitRoom or {})[id] ~= false
        if id ~= excludeId and approach.enabled and approach.demand and hasRoom then
            local wait = approach.firstWaitMs or math.huge
            if bestWait == nil or wait < bestWait or (wait == bestWait and id < bestId) then
                bestId, bestWait = id, wait
            end
        end
    end
    return bestId
end

local function greenHasDemand(input, greenId)
    local approach = greenId ~= nil and (input.approaches or {})[greenId] or nil
    return approach ~= nil and approach.enabled and approach.demand
end

local function updateGreen(state, input, nowMs, config)
    local other = TLController.nextCandidate(input, state.greenId)
    local hasDemand = greenHasDemand(input, state.greenId)
    if other == nil then
        -- ingen venter: tælleren starter forfra, næste gang nogen venter (review: ellers tidligt gult)
        -- og fremdrifts-uret starter forfra, når nogen begynder at vente (review)
        if hasDemand then return withChanges(state, {passedWhileWaiting = 0, lastProgressMs = nowMs}) end
        return enter("IDLE", nowMs, nil)
    end
    local crossedNow = (input.crossed or {})[state.greenId] or 0
    local passed = state.passedWhileWaiting + crossedNow
    local lastProgress = crossedNow > 0 and nowMs or (state.lastProgressMs or state.phaseStartMs)
    -- grønt uden fremdrift (den forreste kører ikke — in-game 25/10: kø foran et grønt lys) må ikke
    -- holde de andre på rødt for evigt
    local stalled = nowMs - lastProgress >= GREEN_STALL_MS
    if passed >= config.MAX_PASS_WHILE_WAITING or not hasDemand or stalled then
        return enter("AMBER", nowMs, state.greenId)
    end
    return withChanges(state, {passedWhileWaiting = passed, lastProgressMs = lastProgress})
end

-- En af kortets biler inden for sin bremselængde på en ANDEN indkørsel end nextId: vent, til den er igennem.
local function committedElsewhere(input, nextId)
    for id in pairs(input.trafficCommitted or {}) do
        if id ~= nextId then return true end
    end
    return false
end

local function updateClearing(state, input, nowMs)
    if input.zoneOccupied then return state end
    if input.trafficClearMs ~= nil and nowMs - state.phaseStartMs < input.trafficClearMs then return state end
    local nextId = TLController.nextCandidate(input, nil)
    if nextId == nil then return enter("IDLE", nowMs, nil) end
    if committedElsewhere(input, nextId) and nowMs - state.phaseStartMs < COMMITTED_WAIT_MAX_MS then return state end
    return enter("GREEN", nowMs, nextId)
end

function TLController.update(state, input, nowMs, config)
    local stuck = (input.zoneStuckMs or 0) >= config.STUCK_MS
    if state.phase == "OUT_OF_ORDER" then
        if not input.zoneOccupied and (input.zoneStuckMs or 0) == 0 then return enter("IDLE", nowMs, nil) end
        return state
    end
    if stuck then return enter("OUT_OF_ORDER", nowMs, nil) end

    if state.phase == "IDLE" then
        if input.zoneOccupied then return state end
        local nextId = TLController.nextCandidate(input, nil)
        if nextId == nil then return state end
        -- forpligtet trafikbil på en anden indkørsel: gå i rydning (spærrer for nye trafikbiler, så en jævn
        -- strøm ikke udsulter den ventende); grønt gives, når de forpligtede er igennem
        if committedElsewhere(input, nextId) then return enter("CLEARING", nowMs, nil) end
        -- kortets trafik kører frit i tomgang og kan ikke ses: ryd krydset før første grønt (review)
        if input.idleNeedsClearing then return enter("CLEARING", nowMs, nil) end
        return enter("GREEN", nowMs, nextId)
    elseif state.phase == "GREEN" then
        return updateGreen(state, input, nowMs, config)
    elseif state.phase == "AMBER" then
        if nowMs - state.phaseStartMs >= config.AMBER_MS then return enter("CLEARING", nowMs, nil) end
        return state
    elseif state.phase == "CLEARING" then
        return updateClearing(state, input, nowMs)
    end
    return state
end

function TLController.signalFor(state, approachId)
    if state.phase == "OUT_OF_ORDER" then return "FLASHING" end
    if state.greenId == approachId then
        if state.phase == "GREEN" then return "GREEN" end
        if state.phase == "AMBER" then return "AMBER" end
    end
    return "RED"
end

function TLController.mayPass(state, approachId)
    if state.phase == "OUT_OF_ORDER" then return true end
    return state.phase == "GREEN" and state.greenId == approachId
end
