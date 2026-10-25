-- Multiplayer (spec 5.11, Task 10): serveren sender lysenes layout (masternes/wirens placering, beregnet af
-- TLVisuals.computeLayout ud fra AD-nettet) og signalerne; klienten bygger de samme lys uden selv at regne.
TLNet = {}

local ID_BITS = 8
local COUNT_BITS = 8
local SIGNAL_BITS = 3
local SHIFT_BITS = 8            -- justeringen i halve meter, forskudt så negative tal kan sendes
local SHIFT_OFFSET = 64         -- -32 .. +95,5 m (serveren klemmer til langt mindre)
local SIGNALS = {"RED", "AMBER", "GREEN", "FLASHING", "OFF"}
local SIGNAL_CODE = {}
for code, name in ipairs(SIGNALS) do SIGNAL_CODE[name] = code - 1 end

local function writeXZ(streamId, p)
    streamWriteFloat32(streamId, p.x)
    streamWriteFloat32(streamId, p.z)
end

local function readXZ(streamId)
    local x = streamReadFloat32(streamId)
    return {x = x, z = streamReadFloat32(streamId)}
end

-- Stoplinjerne til justeringsvisningen (også frakoblede indkørsler, der ikke har en mast) og antal forældede
-- justeringer.
local function writeStops(streamId, layout)
    local stops = layout.stops or {}
    streamWriteUIntN(streamId, #stops, COUNT_BITS)
    for _, stop in ipairs(stops) do
        streamWriteUIntN(streamId, stop.id, ID_BITS)
        writeXZ(streamId, stop)
        streamWriteFloat32(streamId, stop.heading)
        streamWriteBool(streamId, stop.enabled)
        streamWriteBool(streamId, stop.adjusted)
        local half = math.floor((stop.shift or 0) * 2 + 0.5) + SHIFT_OFFSET
        streamWriteUIntN(streamId, math.max(0, math.min(2 ^ SHIFT_BITS - 1, half)), SHIFT_BITS)
    end
    streamWriteUIntN(streamId, math.min(layout.stale or 0, 2 ^ COUNT_BITS - 1), COUNT_BITS)
end

local function readStops(streamId, layout)
    layout.stops = {}
    for _ = 1, streamReadUIntN(streamId, COUNT_BITS) do
        local id = streamReadUIntN(streamId, ID_BITS)
        local p = readXZ(streamId)
        local heading = streamReadFloat32(streamId)
        local enabled = streamReadBool(streamId)
        local adjusted = streamReadBool(streamId)
        local shift = (streamReadUIntN(streamId, SHIFT_BITS) - SHIFT_OFFSET) / 2
        table.insert(layout.stops, {id = id, x = p.x, z = p.z, heading = heading, enabled = enabled,
            adjusted = adjusted, shift = shift})
    end
    layout.stale = streamReadUIntN(streamId, COUNT_BITS)
    return layout
end

-- layout = nil | {kind = "masts", masts = {{id, x, z, yaw}}} | {kind = "span", p1, p2, heads = {{id, t, yaw}}}
-- plus stops = {{id, x, z, heading, enabled, adjusted, shift}} og stale (antal)
function TLNet.writeLayout(streamId, layout)
    if not streamWriteBool(streamId, layout ~= nil) then return end
    local isSpan = layout.kind == "span"
    streamWriteBool(streamId, isSpan)
    if isSpan then
        writeXZ(streamId, layout.p1)
        writeXZ(streamId, layout.p2)
        streamWriteUIntN(streamId, #layout.heads, COUNT_BITS)
        for _, head in ipairs(layout.heads) do
            streamWriteUIntN(streamId, head.id, ID_BITS)
            streamWriteFloat32(streamId, head.t)
            streamWriteFloat32(streamId, head.yaw)
        end
    else
        streamWriteUIntN(streamId, #layout.masts, COUNT_BITS)
        for _, mast in ipairs(layout.masts) do
            streamWriteUIntN(streamId, mast.id, ID_BITS)
            writeXZ(streamId, mast)
            streamWriteFloat32(streamId, mast.yaw)
        end
    end
    writeStops(streamId, layout)
end

function TLNet.readLayout(streamId)
    if not streamReadBool(streamId) then return nil end
    if streamReadBool(streamId) then
        local layout = {kind = "span", p1 = readXZ(streamId), p2 = readXZ(streamId), heads = {}}
        for _ = 1, streamReadUIntN(streamId, COUNT_BITS) do
            local id = streamReadUIntN(streamId, ID_BITS)
            local t = streamReadFloat32(streamId)
            table.insert(layout.heads, {id = id, t = t, yaw = streamReadFloat32(streamId)})
        end
        return readStops(streamId, layout)
    end
    local layout = {kind = "masts", masts = {}}
    for _ = 1, streamReadUIntN(streamId, COUNT_BITS) do
        local id = streamReadUIntN(streamId, ID_BITS)
        local p = readXZ(streamId)
        table.insert(layout.masts, {id = id, x = p.x, z = p.z, yaw = streamReadFloat32(streamId)})
    end
    return readStops(streamId, layout)
end

-- signals = {[approachId] = "RED"|"AMBER"|"GREEN"|"FLASHING"|"OFF"}; ukendte sendes som RED
function TLNet.writeSignals(streamId, signals)
    local ids = {}
    for id in pairs(signals or {}) do table.insert(ids, id) end
    table.sort(ids)
    streamWriteUIntN(streamId, #ids, COUNT_BITS)
    for _, id in ipairs(ids) do
        streamWriteUIntN(streamId, id, ID_BITS)
        streamWriteUIntN(streamId, SIGNAL_CODE[signals[id]] or SIGNAL_CODE.RED, SIGNAL_BITS)
    end
end

function TLNet.readSignals(streamId)
    local signals = {}
    for _ = 1, streamReadUIntN(streamId, COUNT_BITS) do
        local id = streamReadUIntN(streamId, ID_BITS)
        signals[id] = SIGNALS[streamReadUIntN(streamId, SIGNAL_BITS) + 1] or "RED"
    end
    return signals
end

function TLNet.signalsChanged(old, new)
    for id, signal in pairs(new or {}) do
        if (old or {})[id] ~= signal then return true end
    end
    for id in pairs(old or {}) do
        if (new or {})[id] == nil then return true end
    end
    return false
end
