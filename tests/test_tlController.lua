-- Kør: luajit tests/test_tlController.lua   (fra repo-roden)
-- Lysfaserne er ren Lua: ingen spil-mocks.

dofile("FS25_TrafficLights/tlConfig.lua")
dofile("FS25_TrafficLights/tlController.lua")

local failures = 0
local function check(name, actual, expected)
    if actual == expected then
        print("OK   " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL %s: forventede %s, fik %s", name, tostring(expected), tostring(actual)))
    end
end

local C = TLConfig

-- input-bygger: waits = { [id] = firstWaitMs }, ids uden ventetid er aktive uden efterspørgsel
local function input(ids, waits, extra)
    local approaches = {}
    for _, id in ipairs(ids) do
        local wait = waits[id]
        approaches[id] = {enabled = true, demand = wait ~= nil, firstWaitMs = wait}
    end
    local result = {approaches = approaches, zoneOccupied = false, zoneStuckMs = 0, crossed = {}, exitRoom = {}}
    for key, value in pairs(extra or {}) do result[key] = value end
    return result
end

local function run(state, inp, now) return TLController.update(state, inp, now, C) end

-- C1: tomt kryds + én efterspørgsel = grønt med det samme
local s = run(TLController.initialState(), input({1, 2, 3}, {[2] = 100}), 100)
check("C1 fase GREEN", s.phase, "GREEN")
check("C1 grønt til 2", s.greenId, 2)
check("C1 signal 2 grønt", TLController.signalFor(s, 2), "GREEN")
check("C1 signal 1 rødt", TLController.signalFor(s, 1), "RED")

-- C2: først til mølle
s = run(TLController.initialState(), input({1, 3}, {[3] = 1000, [1] = 500}), 1000)
check("C2 længst ventende får grønt", s.greenId, 1)

-- C3: grænsen på 4 biler, mens en anden venter
s = run(TLController.initialState(), input({1, 2}, {[1] = 0}), 0)
for i = 1, 4 do
    s = run(s, input({1, 2}, {[1] = 0, [2] = 10}, {crossed = {[1] = 1}}), 100 * i)
end
check("C3 skift til gult efter 4 passager", s.phase, "AMBER")
check("C3 gult signal for 1", TLController.signalFor(s, 1), "AMBER")

-- C4: ingen venter andre steder -> grønt bliver ved
s = run(TLController.initialState(), input({1, 2}, {[1] = 0}), 0)
for i = 1, 10 do
    s = run(s, input({1, 2}, {[1] = 0}, {crossed = {[1] = 1}}), 100 * i)
end
check("C4 grønt bliver ved uden ventende", s.phase, "GREEN")
check("C4 stadig 1", s.greenId, 1)

-- C5: gult -> rydning -> næste grønt først når zonen er tom
s = run(TLController.initialState(), input({1, 2}, {[1] = 0}), 0)
s = run(s, input({1, 2}, {[2] = 10}), 100) -- 1 har ikke længere efterspørgsel, 2 venter
check("C5 gult når grøn mister efterspørgsel og en anden venter", s.phase, "AMBER")
s = run(s, input({1, 2}, {[2] = 10}, {zoneOccupied = true}), 100 + C.AMBER_MS)
check("C5 rydning efter gul-tid", s.phase, "CLEARING")
check("C5 alle røde under rydning", TLController.signalFor(s, 2), "RED")
s = run(s, input({1, 2}, {[2] = 10}, {zoneOccupied = true}), 200 + C.AMBER_MS)
check("C5 venter så længe zonen er optaget", s.phase, "CLEARING")
s = run(s, input({1, 2}, {[2] = 10}), 300 + C.AMBER_MS)
check("C5 grønt til 2 når zonen er tom", s.greenId, 2)
check("C5 fase GREEN", s.phase, "GREEN")

-- C6: fast rydningstid for kortets trafik
s = run(TLController.initialState(), input({1, 2}, {[1] = 0}), 0)
s = run(s, input({1, 2}, {[2] = 10}), 100)
s = run(s, input({1, 2}, {[2] = 10}, {trafficClearMs = 4000}), 100 + C.AMBER_MS)
check("C6 rydning startet", s.phase, "CLEARING")
s = run(s, input({1, 2}, {[2] = 10}, {trafficClearMs = 4000}), 100 + C.AMBER_MS + 3999)
check("C6 intet grønt før rydningstiden", s.phase, "CLEARING")
s = run(s, input({1, 2}, {[2] = 10}, {trafficClearMs = 4000}), 100 + C.AMBER_MS + 4000)
check("C6 grønt efter rydningstiden", s.greenId, 2)

-- C7: sikkerhedsventil
s = run(TLController.initialState(), input({1, 2}, {[1] = 0}), 0)
s = run(s, input({1, 2}, {[1] = 0, [2] = 5}, {zoneOccupied = true, zoneStuckMs = C.STUCK_MS}), 100)
check("C7 ude af drift", s.phase, "OUT_OF_ORDER")
check("C7 blinker", TLController.signalFor(s, 2), "FLASHING")
check("C7 alle må køre", TLController.mayPass(s, 2), true)
s = run(s, input({1, 2}, {[2] = 5}, {zoneOccupied = true, zoneStuckMs = 0}), 200)
check("C7 bliver ude af drift mens zonen er optaget", s.phase, "OUT_OF_ORDER")
s = run(s, input({1, 2}, {}), 300)
check("C7 tilbage til tomgang", s.phase, "IDLE")

-- C8: ingen plads i udkørslen -> en anden indkørsel får grønt
s = run(TLController.initialState(), input({2, 3}, {[2] = 10, [3] = 20}, {exitRoom = {[2] = false}}), 30)
check("C8 springer indkørsel uden plads over", s.greenId, 3)

-- C9: lige ventetid -> laveste id, og kun én grøn
s = run(TLController.initialState(), input({4, 2}, {[4] = 50, [2] = 50}), 60)
check("C9 laveste id vinder", s.greenId, 2)
check("C9 den anden må ikke køre", TLController.mayPass(s, 4), false)

-- C10: ingen indkørsler eller alle slået fra
s = run(TLController.initialState(), {approaches = {}, zoneOccupied = false, zoneStuckMs = 0, crossed = {}, exitRoom = {}}, 0)
check("C10 ingen indkørsler -> tomgang", s.phase, "IDLE")
local off = input({1}, {[1] = 0})
off.approaches[1].enabled = false
s = run(TLController.initialState(), off, 0)
check("C10 frakoblet indkørsel får ikke grønt", s.phase, "IDLE")
check("C10 signal for ukendt indkørsel er rødt", TLController.signalFor(s, 9), "RED")

-- C11: update muterer ikke sit input
local function snapshot(t)
    local parts = {}
    local function walk(value, prefix)
        if type(value) ~= "table" then table.insert(parts, prefix .. "=" .. tostring(value)) return end
        local keys = {}
        for key in pairs(value) do table.insert(keys, tostring(key)) end
        table.sort(keys)
        for _, key in ipairs(keys) do
            walk(value[key] ~= nil and value[key] or value[tonumber(key)], prefix .. "." .. key)
        end
    end
    walk(t, "")
    return table.concat(parts, ";")
end
local before = run(TLController.initialState(), input({1, 2}, {[1] = 0}), 0)
local inp = input({1, 2}, {[1] = 0, [2] = 5}, {crossed = {[1] = 1}})
local beforeText, inputText = snapshot(before), snapshot(inp)
local after = run(before, inp, 100)
check("C11 gammel tilstand uændret", snapshot(before), beforeText)
check("C11 input uændret", snapshot(inp), inputText)
check("C11 ny tilstand er en ny tabel", after ~= before, true)

-- tælleren nulstilles, når ingen længere venter (review)
s = run(TLController.initialState(), input({1, 2}, {[1] = 0}), 0)
for i = 1, 3 do s = run(s, input({1, 2}, {[1] = 0, [2] = 5}, {crossed = {[1] = 1}}), 100 * i) end
s = run(s, input({1, 2}, {[1] = 0}), 400) -- 2 kørte en anden vej
check("tæller nulstilles uden ventende", s.passedWhileWaiting, 0)
s = run(s, input({1, 2}, {[1] = 0, [2] = 500}, {crossed = {[1] = 1}}), 500)
check("ny venteperiode starter forfra", s.phase, "GREEN")

-- C12: tomgang med usynlig kortets trafik: ryd krydset før første grønt
s = run(TLController.initialState(), input({1, 2}, {[1] = 0}, {idleNeedsClearing = true}), 0)
check("C12 tomgang -> rydning", s.phase, "CLEARING")
check("C12 ingen grøn under rydning", TLController.mayPass(s, 1), false)
s = run(s, input({1, 2}, {[1] = 0}, {idleNeedsClearing = true, trafficClearMs = 3000}), 2999)
check("C12 venter rydningstiden", s.phase, "CLEARING")
s = run(s, input({1, 2}, {[1] = 0}, {idleNeedsClearing = true, trafficClearMs = 3000}), 3000)
check("C12 grønt efter rydning", s.greenId, 1)

-- C13 (review): en af kortets biler inden for bremselængde på en anden indkørsel -> intet grønt endnu
s = run(TLController.initialState(), input({1, 2}, {[1] = 0, [2] = 50}, {trafficCommitted = {[2] = true}}), 100)
check("C13 rydning mens forpligtet trafikbil kører igennem", s.phase, "CLEARING")
s = run(s, input({1, 2}, {[1] = 0}), 200)
check("C13 grønt når den er igennem", s.greenId, 1)

-- C14 (review): grønt uden fremdrift i 15 s, mens andre venter -> gult
s = run(TLController.initialState(), input({1, 2}, {[1] = 0}), 0)
s = run(s, input({1, 2}, {[1] = 0, [2] = 10}), 14999)
check("C14 stadig grønt før 15 s", s.phase, "GREEN")
s = run(s, input({1, 2}, {[1] = 0, [2] = 10}), 15000)
check("C14 gult efter 15 s uden fremdrift", s.phase, "AMBER")
-- C15: rydning venter højst 8 s på forpligtet trafik
s = run(TLController.initialState(), input({1, 2}, {[1] = 0, [2] = 50}, {trafficCommitted = {[2] = true}}), 0)
s = run(s, input({1, 2}, {[1] = 0, [2] = 50}, {trafficCommitted = {[2] = true}}), 7999)
check("C15 venter under 8 s", s.phase, "CLEARING")
s = run(s, input({1, 2}, {[1] = 0, [2] = 50}, {trafficCommitted = {[2] = true}}), 8000)
check("C15 grønt efter 8 s trods forpligtet", s.greenId, 1)

-- grøn uden efterspørgsel og uden ventende -> tomgang (alt rødt)
s = run(TLController.initialState(), input({1}, {[1] = 0}), 0)
s = run(s, input({1}, {}), 100)
check("grøn uden trafik går i tomgang", s.phase, "IDLE")
check("tomgang er rødt", TLController.signalFor(s, 1), "RED")

-- passager tæller kun mens en anden venter
s = run(TLController.initialState(), input({1, 2}, {[1] = 0}), 0)
for i = 1, 3 do s = run(s, input({1, 2}, {[1] = 0}, {crossed = {[1] = 1}}), 100 * i) end
s = run(s, input({1, 2}, {[1] = 0, [2] = 400}, {crossed = {[1] = 1}}), 400)
check("passager før nogen ventede tæller ikke", s.phase, "GREEN")
check("første passage mens 2 venter", s.passedWhileWaiting, 1)

print(failures == 0 and "\nALLE TESTS OK" or ("\n" .. failures .. " FEJL"))
os.exit(failures == 0 and 0 or 1)
