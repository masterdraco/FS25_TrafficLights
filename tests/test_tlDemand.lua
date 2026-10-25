-- Kør: luajit tests/test_tlDemand.lua   (fra repo-roden)
-- Efterspørgsel/belægning på testkrydset fra test_tlGeometry (radius 25, stoplinjer 7,5 m fra midten):
--   1 = fra øst (vest­gående, z=+2), 2 = fra nord (sydgående, x=-2), 3 = fra vest (østgående, z=-2),
--   4 = fra syd (nordgående, x=+2), 0 = intern.

dofile("FS25_TrafficLights/tlConfig.lua")
TLConfig.STOP_MARGIN = 2 -- testenes faste positioner bygger på 2 m
dofile("FS25_TrafficLights/tlGeometry.lua")
dofile("FS25_TrafficLights/tlDemand.lua")

local failures = 0
local function check(name, actual, expected)
    if actual == expected then
        print("OK   " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL %s: forventede %s, fik %s", name, tostring(expected), tostring(actual)))
    end
end

local function line(fromX, fromZ, toX, toZ, step, list)
    local points = {}
    local n = math.floor(math.sqrt((toX - fromX) ^ 2 + (toZ - fromZ) ^ 2) / step)
    for i = 0, n do
        local t = i / n
        table.insert(points, {x = fromX + t * (toX - fromX), z = fromZ + t * (toZ - fromZ)})
    end
    for i = 1, #points - 1 do table.insert(list, {a = points[i], b = points[i + 1]}) end
    return list
end

local CENTER, RADIUS = {x = 0, z = 0}, 25
local edges = {}
line(-100, -2, 100, -2, 10, edges)
line(100, 2, -100, 2, 10, edges)
line(2, -100, 2, 100, 10, edges)
line(-2, 100, -2, -100, 10, edges)
local approaches, exits = TLGeometry.findApproaches(CENTER, RADIUS, edges)
local intersection = {center = CENTER, radius = RADIUS, exits = exits}
intersection.zone = TLGeometry.conflictZone(intersection, edges)
for _, approach in ipairs(approaches) do
    if not approach.internal then approach.stopLine = TLGeometry.placeStopLine(approach, intersection.zone) end
end
intersection.approaches = approaches
intersection.core = TLGeometry.conflictCore(intersection.zone)

-- rute ligeud mod øst fra x til +60 på z=-2
local function eastRoute(x)
    local route = {}
    for px = x + 5, 60, 5 do table.insert(route, {x = px, z = -2}) end
    return route
end

local function eastCar(key, x, speed, route)
    return {key = key, kind = "AD", name = key, pos = {x = x, z = -2}, speed = speed or 5, route = route or eastRoute(x)}
end

local function inHold(holdList, key)
    for _, item in ipairs(holdList) do if item.key == key then return item end end
    return nil
end

local NOW = 100000

-- D1: 40 m før stoplinje 3 giver efterspørgsel
local input, tracking, hold = TLDemand.collect({eastCar("a", -47.5)}, intersection, {}, NOW)
check("D1 efterspørgsel på 3", input.approaches[3].demand, true)
check("D1 firstWaitMs = nu", input.approaches[3].firstWaitMs, NOW)
check("D1 ingen efterspørgsel på 1", input.approaches[1].demand, false)

-- D2: 80 m før -> intet
input = TLDemand.collect({eastCar("a", -87.5)}, intersection, {}, NOW)
check("D2 for langt væk", input.approaches[3].demand, false)

-- D3: holdes kun inden for HOLD_DISTANCE før linjen
input, tracking, hold = TLDemand.collect({eastCar("a", -12.5)}, intersection, {}, NOW)
check("D3 5 m før holdes", inHold(hold, "a") ~= nil and inHold(hold, "a").approachId, 3)
input, tracking, hold = TLDemand.collect({eastCar("a", -22.5)}, intersection, {}, NOW)
check("D3 15 m før holdes ikke", inHold(hold, "a"), nil)
-- D3b: i fart (50 km/t) holdes den, mens den kan nå at bremse; langt ude endnu ikke
input, tracking, hold = TLDemand.collect({eastCar("f", -37.5, 14)}, intersection, {}, NOW)
check("D3b 30 m før i fart holdes", inHold(hold, "f") ~= nil, true)
input, tracking, hold = TLDemand.collect({eastCar("f", -57.5, 14)}, intersection, {}, NOW)
check("D3b 50 m før i fart holdes ikke", inHold(hold, "f"), nil)

-- D4: fronten 0,2 m over linjen -> inde i krydset, talt én gang, aldrig holdt
input, tracking = TLDemand.collect({eastCar("a", -9)}, intersection, {}, NOW)
input, tracking, hold = TLDemand.collect({eastCar("a", -7.3)}, intersection, tracking, NOW + 250)
check("D4 entered", tracking.a.entered, true)
check("D4 talt", input.crossed[3], 1)
check("D4 ikke holdt", inHold(hold, "a"), nil)
input, tracking = TLDemand.collect({eastCar("a", -4)}, intersection, tracking, NOW + 500)
check("D4 tælles kun én gang", input.crossed[3], nil)
check("D4 optager zonen", input.zoneOccupied, true)

-- D4b: springer 5 m over linjen i én takt (høj fart) -> stadig entered og talt
input, tracking = TLDemand.collect({eastCar("b", -9, 20)}, intersection, {}, NOW)
input, tracking = TLDemand.collect({eastCar("b", -2.5, 20)}, intersection, tracking, NOW + 250)
check("D4b entered trods spring", tracking.b ~= nil and tracking.b.entered, true)
check("D4b talt", input.crossed[3], 1)

-- D5: parkeret vogn midt i krydset (ingen rute, holder stille) optager ikke zonen
input = TLDemand.collect({{key = "p", kind = "AD", pos = {x = 0, z = 0}, speed = 0, route = nil}}, intersection, {}, NOW)
check("D5 parkeret tæller ikke", input.zoneOccupied, false)

-- D6: ruten ændres, så den ikke længere går gennem krydset -> ud af køen
input, tracking = TLDemand.collect({eastCar("a", -20, 0)}, intersection, {}, NOW)
check("D6 venter først", input.approaches[3].demand, true)
local away = {{x = -20, z = -20}, {x = -20, z = -60}}
input, tracking = TLDemand.collect({eastCar("a", -20, 0, away)}, intersection, tracking, NOW + 250)
check("D6 fjernet fra tracking", tracking.a, nil)
check("D6 ingen efterspørgsel", input.approaches[3].demand, false)

-- D7: fastkørt i zonen uden kø foran -> stuck-tid; med en bil 5 m foran -> 0
local stuckTracking = {s = {approachId = 3, entered = true, firstSeenMs = NOW - 70000, stillSinceMs = NOW - 61000}}
input = TLDemand.collect({eastCar("s", 0, 0)}, intersection, stuckTracking, NOW)
check("D7 fastkørt", input.zoneStuckMs >= TLConfig.STUCK_MS, true)
input = TLDemand.collect({eastCar("s", 0, 0), {key = "q", kind = "AD", pos = {x = 5, z = -2}, speed = 2, route = nil}},
    intersection, stuckTracking, NOW)
check("D7 kø foran (kører) er ikke fastkørt", input.zoneStuckMs, 0)
input = TLDemand.collect({eastCar("s", 0, 0), {key = "q", kind = "AD", pos = {x = 5, z = -2}, speed = 0, route = nil}},
    intersection, stuckTracking, NOW)
check("D7 parkeret foran er ikke kø (sikkerhedsventil virker)", input.zoneStuckMs >= TLConfig.STUCK_MS, true)
input = TLDemand.collect({eastCar("s", 0, 0), {key = "q", kind = "AD", pos = {x = 25, z = -2}, speed = 2, length = 18, route = nil}},
    intersection, stuckTracking, NOW)
check("D7 langt køretøj foran (front 25 m væk) er kø", input.zoneStuckMs, 0)

-- D8: en stillestående bil 6 m ude ad udkørslen -> ingen plads for indkørsel 3
local exitPointX = math.sqrt(RADIUS ^ 2 - 4)
input = TLDemand.collect({eastCar("a", -20, 0), {key = "x", kind = "AD", pos = {x = exitPointX + 6, z = -2}, speed = 0, route = nil}},
    intersection, {}, NOW)
check("D8 ingen plads i udkørslen", input.exitRoom[3], false)
input = TLDemand.collect({eastCar("a", -20, 0), {key = "x", kind = "AD", pos = {x = exitPointX + 20, z = -2}, speed = 0, route = nil}},
    intersection, {}, NOW)
check("D8 plads når køen er længere ude", input.exitRoom[3], nil)

-- D9: kortets trafik 4 m før stoplinje 2 (sydgående)
input = TLDemand.collect({{key = "t", kind = "TRAFFIC", pos = {x = -2, z = 7.5 + 4}, speed = 0}}, intersection, {}, NOW)
check("D9 trafik giver efterspørgsel på 2", input.approaches[2].demand, true)
input = TLDemand.collect({{key = "t", kind = "TRAFFIC", pos = {x = -2, z = 7.5 + 40}, speed = 10}}, intersection, {}, NOW)
check("D9b trafik 40 m før giver efterspørgsel (grønt før den bremser)", input.approaches[2].demand, true)
input = TLDemand.collect({{key = "t", kind = "TRAFFIC", pos = {x = -2, z = 7.5 + 70}, speed = 10}}, intersection, {}, NOW)
check("D9c trafik 70 m før giver ingen efterspørgsel", input.approaches[2].demand, false)
input = TLDemand.collect({{key = "t", kind = "TRAFFIC", pos = {x = -2, z = 7.5 + 20}, speed = 10, heading = math.pi / 2}}, intersection, {}, NOW)
check("D9d trafik der kører væk fra krydset giver ingen efterspørgsel", input.approaches[2].demand, false)
input = TLDemand.collect({{key = "t", kind = "TRAFFIC", pos = {x = -2, z = 7.5 + 20}, speed = 10, heading = -math.pi / 2}}, intersection, {}, NOW)
check("D9e trafik der kører ind mod krydset giver efterspørgsel", input.approaches[2].demand, true)

-- D10: input muteres ikke
local snapshot = eastCar("a", -12.5)
local routeCount = #snapshot.route
local oldTracking = {a = {approachId = 3, entered = false, firstSeenMs = 5}}
TLDemand.collect({snapshot}, intersection, oldTracking, NOW)
check("D10 rute uændret", #snapshot.route, routeCount)
check("D10 tracking uændret", oldTracking.a.firstSeenMs, 5)
check("D10 tracking uden lastPos", oldTracking.a.lastPos, nil)

-- D11 (in-game 25/10): en bil, modden første gang ser INDE i krydset, holdes aldrig — den er kørt ind
-- (biler i kø ud ad udkørslen blev holdt som "interne" og låste krydset)
local inner = {key = "i", kind = "AD", pos = {x = 1, z = 1}, speed = 0, route = {{x = 1, z = 10}, {x = 1, z = 30}}}
input, tracking, hold = TLDemand.collect({inner}, intersection, {}, NOW)
check("D11 står stille inde: følges ikke endnu (re-review)", tracking.i, nil)
check("D11 står stille inde: optager ikke", input.zoneOccupied, false)
inner.speed = 2
input, tracking, hold = TLDemand.collect({inner}, intersection, tracking, NOW + 250)
check("D11 inde: kørt ind", tracking.i ~= nil and tracking.i.entered, true)
check("D11 inde: holdes ikke", inHold(hold, "i"), nil)
check("D11 inde: ingen efterspørgsel", input.approaches[0].demand, false)
check("D11 inde: optager krydset", input.zoneOccupied, true)
local exitQueue = {key = "x", kind = "AD", pos = {x = 15, z = -2}, speed = 1, route = eastRoute(15)}
input, tracking, hold = TLDemand.collect({exitQueue}, intersection, {}, NOW)
check("D11 kø ud ad udkørslen holdes ikke", inHold(hold, "x"), nil)

-- R1 (review CRITICAL): bil kører over linjen og stopper ved sit mål i zonen -> låser ikke krydset
input, tracking = TLDemand.collect({eastCar("m", -9)}, intersection, {}, NOW)
input, tracking = TLDemand.collect({eastCar("m", -6)}, intersection, tracking, NOW + 250)
check("R1 entered", tracking.m.entered, true)
input, tracking = TLDemand.collect({{key = "m", kind = "AD", pos = {x = -1, z = -2}, speed = 0, route = nil}}, intersection, tracking, NOW + 500)
check("R1 ved mål: ikke længere trafik", tracking.m, nil)
check("R1 zonen fri", input.zoneOccupied, false)
input = TLDemand.collect({{key = "m", kind = "AD", pos = {x = -1, z = -2}, speed = 0, route = nil}}, intersection, tracking, NOW + 75000)
check("R1 ingen sikkerhedsventil", input.zoneStuckMs, 0)

-- R2 (review HIGH): køer på begge indkørsler af samme vej giver ikke falsk "ingen plads i udkørslen"
local westRoute = {}
for px = 22.5, -60, -5 do table.insert(westRoute, {x = px, z = 2}) end
local q = {
    eastCar("e1", -12, 0), eastCar("e2", -30, 0),
    {key = "w1", kind = "AD", pos = {x = 12, z = 2}, speed = 0, route = westRoute},
    {key = "w2", kind = "AD", pos = {x = 30, z = 2}, speed = 0, route = westRoute},
}
input = TLDemand.collect(q, intersection, {}, NOW)
check("R2 plads mod øst", input.exitRoom[3], nil)
check("R2 plads mod vest", input.exitRoom[1], nil)

-- R3 (review HIGH): vogntog er stadig i krydset, til fronten er en køretøjslængde ude af zonen
local trackingT = {v = {approachId = 3, entered = true, firstSeenMs = NOW, stillSinceMs = nil}}
local zoneEdgeX = 2 + TLConfig.SWEEP_HALF_WIDTH
input, tracking = TLDemand.collect({{key = "v", kind = "AD", pos = {x = zoneEdgeX + 10, z = -2}, speed = 2, length = 18, route = eastRoute(zoneEdgeX + 10)}}, intersection, trackingT, NOW)
check("R3 anhænger stadig i krydset", input.zoneOccupied, true)
input, tracking = TLDemand.collect({{key = "v", kind = "AD", pos = {x = zoneEdgeX + 20, z = -2}, speed = 2, length = 18, route = eastRoute(zoneEdgeX + 20)}}, intersection, trackingT, NOW)
check("R3 helt ude", input.zoneOccupied, false)

-- R4 (review MEDIUM): bil inde i cirklen, hvis rute ikke rører zonen, får ingen intern efterspørgsel
local yard = {key = "y", kind = "AD", pos = {x = 15, z = 15}, speed = 0, route = {{x = 18, z = 18}, {x = 22, z = 22}}}
input, tracking, hold = TLDemand.collect({yard}, intersection, {}, NOW)
check("R4 ingen intern efterspørgsel", input.approaches[0].demand, false)
check("R4 ikke holdt", inHold(hold, "y"), nil)

-- R5: en bil, der allerede ruller inde i krydset ved første observation, holdes ikke
local rolling = {key = "r", kind = "AD", pos = {x = 1, z = 1}, speed = 3, route = {{x = 1, z = 10}, {x = 1, z = 30}}}
input, tracking, hold = TLDemand.collect({rolling}, intersection, {}, NOW)
check("R5 ruller inde: holdes ikke", inHold(hold, "r"), nil)

-- R6: en bil, der nærmer sig sin egen stoplinje gennem cirklens yderkant, optager ikke krydset
input = TLDemand.collect({eastCar("n", -20, 8)}, intersection, {}, NOW)
check("R6 tilkørende bil optager ikke krydset", input.zoneOccupied, false)

-- R7b (re-review): en ufulgt bil med rute, der har holdt længere end STUCK_MS foran, er ikke længere kø
local trackingQ = {s = {approachId = 3, entered = true, firstSeenMs = NOW - 80000, stillSinceMs = NOW - 70000},
    __still = {q2 = NOW - 61000}}
local queued2 = {key = "q2", kind = "AD", pos = {x = 35, z = -2}, speed = 0, route = eastRoute(35)}
input = TLDemand.collect({{key = "s", kind = "AD", pos = {x = 10, z = -2}, speed = 0, length = 18, route = eastRoute(10)}, queued2},
    intersection, trackingQ, NOW)
check("R7b langvarigt stillestående foran: sikkerhedsventil", input.zoneStuckMs >= TLConfig.STUCK_MS, true)

-- R7 (re-review HIGH): stillestående kø med aktiv rute i udkørslen er kø, ikke fastkørt
local trackingS = {s = {approachId = 3, entered = true, firstSeenMs = NOW - 80000, stillSinceMs = NOW - 70000}}
local queued = {key = "q", kind = "AD", pos = {x = 35, z = -2}, speed = 0, route = eastRoute(35)}
input = TLDemand.collect({{key = "s", kind = "AD", pos = {x = 10, z = -2}, speed = 0, length = 18, route = eastRoute(10)}, queued},
    intersection, trackingS, NOW)
check("R7 kø med rute foran er ikke fastkørt", input.zoneStuckMs, 0)

-- R8 (re-review MEDIUM): frakoblet indkørsel holder ingen og giver ingen efterspørgsel
local savedEnabled = approaches[3].enabled
approaches[3].enabled = false
input, tracking, hold = TLDemand.collect({eastCar("d", -12)}, intersection, {}, NOW)
check("R8 frakoblet: ingen efterspørgsel", input.approaches[3].demand, false)
check("R8 frakoblet: ikke holdt", inHold(hold, "d"), nil)
approaches[3].enabled = savedEnabled

-- R9 (re-review MEDIUM): en bil, der holder i udkørslen og vender ud ad den, blokerer, selv om dens rute
-- senere går tilbage gennem krydset
local loopRoute = {{x = exitPointX + 10, z = -2}, {x = exitPointX + 10, z = 2}, {x = 20, z = 2}, {x = 5, z = 2}}
input = TLDemand.collect({eastCar("a", -20, 0), {key = "l", kind = "AD", pos = {x = exitPointX + 6, z = -2}, speed = 0, route = loopRoute}},
    intersection, {}, NOW)
check("R9 udadvendt holdende bil blokerer udkørslen", input.exitRoom[3], false)

-- K2 (in-game 25/10): Courseplay i markarbejde (ingen rute) tæller aldrig som trafik i krydset
input = TLDemand.collect({{key = "cp", kind = "CP", pos = {x = 0, z = -2}, speed = 3, route = nil}}, intersection, {}, NOW)
check("K2 CP i markarbejde optager ikke", input.zoneOccupied, false)
-- K3: kortets trafik i krydsningskernen tæller, ude i cirklens kant ikke
input = TLDemand.collect({{key = "t1", kind = "TRAFFIC", pos = {x = 0, z = -2}, speed = 8}}, intersection, {}, NOW)
check("K3 trafik midt i krydset optager", input.zoneOccupied, true)
check("K3 navngivet i occupiedBy", #input.occupiedBy, 1)
input = TLDemand.collect({{key = "t2", kind = "TRAFFIC", pos = {x = 24, z = -2}, speed = 8}}, intersection, {}, NOW)
check("K3 trafik i cirklens kant optager ikke", input.zoneOccupied, false)

-- T1 (review): en af kortets biler, der kører over sin stoplinje, tæller i grænsen på 4
input, tracking = TLDemand.collect({{key = "c", kind = "TRAFFIC", pos = {x = -2, z = 9}, speed = 8, heading = -math.pi / 2}}, intersection, {}, NOW)
input, tracking = TLDemand.collect({{key = "c", kind = "TRAFFIC", pos = {x = -2, z = 5}, speed = 8, heading = -math.pi / 2}}, intersection, tracking, NOW + 250)
check("T1 trafik over stoplinjen talt", input.crossed[2], 1)
-- T2: en af kortets biler inden for bremselængde er forpligtet — kun hvis indkørslen har et trafikspor
input = TLDemand.collect({{key = "c", kind = "TRAFFIC", pos = {x = -2, z = 7.5 + 12}, speed = 12, heading = -math.pi / 2}}, intersection, {}, NOW)
check("T2 uden trafikspor: ikke forpligtet", input.trafficCommitted[2], nil)
local south2 = nil
for _, a in ipairs(approaches) do if a.id == 2 then south2 = a end end
local savedLanes = south2.lanes
south2.lanes = {{kind = "AD"}, {kind = "TRAFFIC", splineId = 5, splineTime = 0.5}}
input = TLDemand.collect({{key = "c", kind = "TRAFFIC", pos = {x = -2, z = 7.5 + 12}, speed = 12, heading = -math.pi / 2}}, intersection, {}, NOW)
check("T2 forpligtet (12 m/s, 12 m før)", input.trafficCommitted[2], true)
input = TLDemand.collect({{key = "c", kind = "TRAFFIC", pos = {x = -2, z = 7.5 + 50}, speed = 12, heading = -math.pi / 2}}, intersection, {}, NOW)
check("T2 ikke forpligtet 50 m før", input.trafficCommitted[2], nil)
south2.lanes = savedLanes
-- T4 (in-game 25/10): en af kortets biler, der holder for rødt VED sin stoplinje (fronten i kernen), optager ikke
input = TLDemand.collect({{key = "w", kind = "TRAFFIC", pos = {x = -2, z = 7.6}, speed = 0, heading = -math.pi / 2}}, intersection, {}, NOW)
check("T4 ventende ved stoplinjen optager ikke", input.zoneOccupied, false)
check("T4 men giver efterspørgsel", input.approaches[2].demand, true)

-- T3: en af kortets biler, der holder stille i kernen, optager (højst STUCK_MS)
input, tracking = TLDemand.collect({{key = "s1", kind = "TRAFFIC", pos = {x = 0, z = -2}, speed = 0}}, intersection, {}, NOW)
check("T3 holdende trafik i kernen optager", input.zoneOccupied, true)
input = TLDemand.collect({{key = "s1", kind = "TRAFFIC", pos = {x = 0, z = -2}, speed = 0}}, intersection, {__still = {s1 = NOW - 61000}}, NOW)
check("T3 efter STUCK_MS optager den ikke længere", input.zoneOccupied, false)

-- forsvundet køretøj (solgt) fjernes
input, tracking = TLDemand.collect({eastCar("a", -20, 0)}, intersection, {}, NOW)
input, tracking = TLDemand.collect({}, intersection, tracking, NOW + 250)
check("forsvundet køretøj fjernet", tracking.a, nil)
check("forsvundet giver ingen efterspørgsel", input.approaches[3].demand, false)

-- først til mølle bevares mellem takter
input, tracking = TLDemand.collect({eastCar("a", -30, 0)}, intersection, {}, NOW)
input, tracking = TLDemand.collect({eastCar("a", -29, 1)}, intersection, tracking, NOW + 5000)
check("firstWaitMs bevares", input.approaches[3].firstWaitMs, NOW)

print(failures == 0 and "\nALLE TESTS OK" or ("\n" .. failures .. " FEJL"))
os.exit(failures == 0 and 0 or 1)
