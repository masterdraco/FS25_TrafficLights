-- Kør: luajit tests/test_tlNet.lua   (fra repo-roden)
-- Multiplayer: layout og signaler skrives og læses igen ens. Spillets stream-funktioner erstattes af en kø.

local queue, readPos = {}, 1
local function push(value) table.insert(queue, value) end
local function pop() local value = queue[readPos]; readPos = readPos + 1; return value end
local function reset() queue, readPos = {}, 1 end
streamWriteBool = function(_, v) push(v and true or false); return v end
streamReadBool = function() return pop() end
streamWriteUIntN = function(_, v, bits) assert(v >= 0 and v < 2 ^ bits, "UIntN udenfor område"); push(v) end
streamReadUIntN = function() return pop() end
streamWriteFloat32 = function(_, v) push(v) end
streamReadFloat32 = function() return pop() end

dofile("FS25_TrafficLights/tlNet.lua")

local failures = 0
local function check(name, actual, expected)
    if actual == expected then
        print("OK   " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL %s: forventede %s, fik %s", name, tostring(expected), tostring(actual)))
    end
end

-- N1: master-layout
reset()
local masts = {kind = "masts", masts = {{id = 1, x = 10.5, z = -3, yaw = 1.2}, {id = 4, x = -7, z = 8.25, yaw = -0.5}}}
TLNet.writeLayout(0, masts)
local back = TLNet.readLayout(0)
check("N1 kind", back.kind, "masts")
check("N1 antal", #back.masts, 2)
check("N1 id", back.masts[2].id, 4)
check("N1 position", back.masts[2].x == -7 and back.masts[2].z == 8.25, true)
check("N1 yaw", back.masts[1].yaw, 1.2)
check("N1 hele køen læst", readPos, #queue + 1)

-- N2: wire-layout
reset()
local span = {kind = "span", p1 = {x = 1, z = 2}, p2 = {x = 30, z = 40}, heads = {{id = 2, t = 12.5, yaw = 3.1}}}
TLNet.writeLayout(0, span)
back = TLNet.readLayout(0)
check("N2 kind", back.kind, "span")
check("N2 ender", back.p1.x == 1 and back.p2.z == 40, true)
check("N2 hoved", back.heads[1].id == 2 and back.heads[1].t == 12.5 and back.heads[1].yaw == 3.1, true)

-- N3: intet layout (lyskurven slået fra)
reset()
TLNet.writeLayout(0, nil)
check("N3 nil -> nil", TLNet.readLayout(0), nil)
check("N3 kun én bool", #queue, 1)

-- N7: stoplinjerne til justeringsvisningen følger med layoutet (også frakoblede indkørsler uden mast)
reset()
local withStops = {kind = "masts", masts = {}, stale = 2, stops = {
    {id = 1, x = 4, z = 5, heading = 1.5, enabled = true, adjusted = false, shift = 0},
    {id = 3, x = -2, z = 9, heading = -0.5, enabled = false, adjusted = true, shift = -2.5},
    {id = 4, x = 0, z = 0, heading = 0, enabled = true, adjusted = true, shift = 37.5}}}
TLNet.writeLayout(0, withStops)
back = TLNet.readLayout(0)
check("N7 antal stoplinjer", #back.stops, 3)
check("N7 frakoblet", back.stops[2].enabled, false)
check("N7 justeret", back.stops[2].adjusted, true)
check("N7 shift negativ", back.stops[2].shift, -2.5)
check("N7 shift stor", back.stops[3].shift, 37.5)
check("N7 position og retning", back.stops[1].x == 4 and back.stops[1].heading == 1.5, true)
check("N7 forældede", back.stale, 2)
check("N7 hele køen læst", readPos, #queue + 1)

-- N4: signaler, alle fem slags
reset()
TLNet.writeSignals(0, {[1] = "RED", [2] = "AMBER", [3] = "GREEN", [5] = "FLASHING", [7] = "OFF"})
local signals = TLNet.readSignals(0)
check("N4 RED", signals[1], "RED")
check("N4 AMBER", signals[2], "AMBER")
check("N4 GREEN", signals[3], "GREEN")
check("N4 FLASHING", signals[5], "FLASHING")
check("N4 OFF", signals[7], "OFF")
check("N4 intet ekstra", signals[4], nil)

-- N5: ukendt signal sendes som RED (sikker side), tomme signaler går
reset()
TLNet.writeSignals(0, {[1] = "BLUE"})
check("N5 ukendt -> RED", TLNet.readSignals(0)[1], "RED")
reset()
TLNet.writeSignals(0, {})
check("N5 tom", next(TLNet.readSignals(0)), nil)

-- N6: signalsChanged
check("N6 ens", TLNet.signalsChanged({[1] = "RED"}, {[1] = "RED"}), false)
check("N6 ændret", TLNet.signalsChanged({[1] = "RED"}, {[1] = "GREEN"}), true)
check("N6 ny indkørsel", TLNet.signalsChanged({[1] = "RED"}, {[1] = "RED", [2] = "RED"}), true)
check("N6 fjernet indkørsel", TLNet.signalsChanged({[1] = "RED", [2] = "RED"}, {[1] = "RED"}), true)

print(failures == 0 and "\nALLE TESTS OK" or ("\n" .. failures .. " FEJL"))
os.exit(failures == 0 and 0 or 1)
