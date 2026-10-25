-- Kør: luajit tests/test_tlGeometry.lua   (fra repo-roden)
-- Krydsgeometri: ren Lua. Testkryds i (0,0), radius 25, højrekørsel, vognbaner 2 m fra vejmidten:
--   øst (+x) på z=-2, vest (-x) på z=+2, nord (+z) på x=+2, syd (-z) på x=-2.

dofile("FS25_TrafficLights/tlConfig.lua")
TLConfig.STOP_MARGIN = 2 -- testenes faste positioner bygger på 2 m
dofile("FS25_TrafficLights/tlGeometry.lua")

local failures = 0
local function check(name, actual, expected)
    if actual == expected then
        print("OK   " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL %s: forventede %s, fik %s", name, tostring(expected), tostring(actual)))
    end
end

local CENTER, RADIUS = {x = 0, z = 0}, 25

-- rettet kæde af kanter gennem punkterne
local function chain(points, list)
    for i = 1, #points - 1 do table.insert(list, {a = points[i], b = points[i + 1]}) end
    return list
end

local function line(fromX, fromZ, toX, toZ, step, list)
    local points = {}
    local length = math.sqrt((toX - fromX) ^ 2 + (toZ - fromZ) ^ 2)
    local n = math.floor(length / step)
    for i = 0, n do
        local t = i / n
        table.insert(points, {x = fromX + t * (toX - fromX), z = fromZ + t * (toZ - fromZ)})
    end
    return chain(points, list)
end

local function crossing(extra)
    local edges = extra or {}
    line(-100, -2, 100, -2, 10, edges)  -- øst
    line(100, 2, -100, 2, 10, edges)    -- vest
    line(2, -100, 2, 100, 10, edges)    -- nord
    line(-2, 100, -2, -100, 10, edges)  -- syd
    return edges
end

local function regular(approaches)
    local list = {}
    for _, approach in ipairs(approaches) do
        if not approach.internal then table.insert(list, approach) end
    end
    return list
end

local function byHeading(approaches, heading)
    for _, approach in ipairs(approaches) do
        if not approach.internal and TLGeometry.angleDiff(approach.heading, heading) < 0.01 then return approach end
    end
    return nil
end

local function zoneDistanceExcludingOwnRoad(zone, p, approach)
    local best = math.huge
    for _, segment in ipairs(zone.segments) do
        local h = math.atan2(segment.b.z - segment.a.z, segment.b.x - segment.a.x)
        local parallel = TLGeometry.angleDiff(h, approach.heading) < 0.35 or TLGeometry.angleDiff(h, approach.heading + math.pi) < 0.35
        if not parallel then
            best = math.min(best, TLGeometry.pointSegmentDistance(p, segment.a, segment.b) - zone.halfWidth)
        end
    end
    return best
end

-- G1: X-kryds -> 4 indkørsler + 4 udkørsler (+ den interne)
local edges = crossing()
local approaches, exits = TLGeometry.findApproaches(CENTER, RADIUS, edges)
check("G1 fire indkørsler", #regular(approaches), 4)
check("G1 fire udkørsler", #exits, 4)
check("G1 id'er er 1..4 + intern 0", approaches[1].id == 1 and approaches[4].id == 4 and approaches[5].id == 0, true)

-- G2: T-kryds (vejen mod syd findes ikke)
local tEdges = {}
line(-100, -2, 100, -2, 10, tEdges)
line(100, 2, -100, 2, 10, tEdges)
line(2, 0, 2, 100, 10, tEdges)      -- nord ud af krydset
line(-2, 100, -2, 0, 10, tEdges)    -- syd ind i krydset
local tApproaches, tExits = TLGeometry.findApproaches(CENTER, RADIUS, tEdges)
check("G2 tre indkørsler", #regular(tApproaches), 3)
check("G2 tre udkørsler", #tExits, 3)

-- G3: to parallelle AD-kanter i samme vognbane slås sammen
local doubled = crossing()
line(-100, -1, 100, -1, 10, doubled)
-- in-game 25/10: en ekstra vognbane i samme retning (fx et højresving) er sin egen indkørsel
check("G3 parallel vognbane er sin egen indkørsel", #regular((TLGeometry.findApproaches(CENTER, RADIUS, doubled))), 5)

-- G3c (in-game 25/10): to AD-kæder oven i hinanden (0,1 m) er samme vognbane = én indkørsel
local stacked = crossing()
line(-100, -1.9, 100, -1.9, 10, stacked)
check("G3c kæder oven i hinanden slås sammen", #regular((TLGeometry.findApproaches(CENTER, RADIUS, stacked))), 4)

-- G3b (review): trafikspor og gemt stoplinje går til den NÆRMESTE af to nære vognbaner, og et spor kun én gang
local doubledApproaches = TLGeometry.findApproaches(CENTER, RADIUS, doubled)
local nearLane = TLGeometry.mergeLane(doubledApproaches, {splineId = 9, splineTime = 0.3, pos = {x = -30, z = -1.1}, heading = 0})
local withLane = nil
for _, a in ipairs(nearLane) do
    for _, l in ipairs(a.lanes or {}) do if l.splineId == 9 then withLane = a end end
end
check("G3b sporet på den nærmeste bane (z=-1)", withLane ~= nil and math.abs(withLane.entry.z + 1) < 0.5, true)
local twice = TLGeometry.mergeLane(nearLane, {splineId = 9, splineTime = 0.3, pos = {x = -30, z = -1.1}, heading = 0})
local count9 = 0
for _, a in ipairs(twice) do for _, l in ipairs(a.lanes or {}) do if l.splineId == 9 then count9 = count9 + 1 end end end
check("G3b samme spor kun én gang", count9, 1)

-- G4: intern indkørsel for ruter, der starter inde i krydset
local internalFound = false
for _, approach in ipairs(approaches) do
    if approach.internal and approach.id == TLGeometry.INTERNAL_ID then internalFound = true end
end
check("G4 intern indkørsel findes", internalFound, true)

-- G5: stoplinjen ligger STOP_MARGIN uden for andres svingområde; et bredere sving skubber den længere ud
local intersection = {center = CENTER, radius = RADIUS}
local zoneA = TLGeometry.conflictZone(intersection, edges)
local south = byHeading(approaches, -math.pi / 2)
local stopA = TLGeometry.placeStopLine(south, zoneA)
check("G5 stoplinje A holder margin", zoneDistanceExcludingOwnRoad(zoneA, stopA, south) >= TLConfig.STOP_MARGIN - 0.01, true)
check("G5 stoplinje A tæt på krydsende vej (z<10)", stopA.z < 10, true)
check("G5c stoplinjen har vognbanens retning", stopA.heading ~= nil and math.abs(stopA.heading - (-math.pi / 2)) < 0.05, true)

local wide = crossing()
line(10, 4, -10, 14, 2, wide) -- bredt sving, der fejer over den sydgående vognbane længere ude
local wideApproaches = TLGeometry.findApproaches(CENTER, RADIUS, wide)
local zoneB = TLGeometry.conflictZone(intersection, wide)
local southB = byHeading(wideApproaches, -math.pi / 2)
local stopB = TLGeometry.placeStopLine(southB, zoneB)
check("G5 bredt sving skubber stoplinjen ud", stopB.back > stopA.back, true)
check("G5 stoplinje B holder margin", zoneDistanceExcludingOwnRoad(zoneB, stopB, southB) >= TLConfig.STOP_MARGIN - 0.01, true)

-- G5b: aldrig holde på jernbanen (in-game 25/10: stoplinjen lå midt i en overkørsel). Den sydgående
-- indkørsel kommer fra +z; "bagud" er større z.
local function railAcross(z) return {{a = {x = -40, z = z}, b = {x = 40, z = z}}} end
local function railDistance(stop, rails) return TLGeometry.pointSegmentDistance(stop, rails[1].a, rails[1].b) end
local onLine = railAcross(stopA.z)
local stopRail = TLGeometry.placeStopLine(south, zoneA, onLine)
check("G5b skinner på linjen: linjen rykker bagud før skinnerne", stopRail.z > stopA.z + TLGeometry.RAIL_CLEAR_M - 0.01, true)
check("G5b skinner på linjen: fri af skinnerne", railDistance(stopRail, onLine) >= TLGeometry.RAIL_CLEAR_M - 0.01, true)
check("G5b back følger med", stopRail.back > stopA.back, true)
local behind = railAcross(stopA.z + 10)
local stopBehind = TLGeometry.placeStopLine(south, zoneA, behind)
check("G5b skinner under køen bag linjen: linjen før skinnerne", stopBehind.z > stopA.z + 10 + TLGeometry.RAIL_CLEAR_M - 0.01, true)
local far = railAcross(stopA.z + TLGeometry.RAIL_QUEUE_M + 15)
local stopFar = TLGeometry.placeStopLine(south, zoneA, far)
check("G5b skinner langt ude: linjen uændret", math.abs(stopFar.z - stopA.z) < 1e-6, true)
check("G5b uden skinner: uændret", math.abs(TLGeometry.placeStopLine(south, zoneA, {}).z - stopA.z) < 1e-6, true)

-- G6: trafikspor i samme vognbane lægges i den eksisterende indkørsel
local east = byHeading(approaches, 0)
local merged = TLGeometry.mergeLane(approaches, {splineId = 46230, splineTime = 0.70051497220993, pos = {x = -30, z = -2}, heading = 0})
check("G6 antal uændret", #merged, #approaches)
local mergedEast = byHeading(merged, 0)
check("G6 trafikspor tilføjet", mergedEast.lanes[#mergedEast.lanes].splineId, 46230)
check("G6 eksakt splineTime bevaret", mergedEast.lanes[#mergedEast.lanes].splineTime, 0.70051497220993)
check("G6 input-indkørsel uændret", #east.lanes, 1)

-- G7: trafikspor i modsat retning bliver en ny indkørsel
local opposite = TLGeometry.mergeLane(approaches, {splineId = 7, splineTime = 0.5, pos = {x = -30, z = -2}, heading = math.pi})
check("G7 ny indkørsel", #opposite, #approaches + 1)
check("G7 ny har eget id", opposite[#opposite].id, 5)
check("G7 ny har stoplinje", opposite[#opposite].stopLine ~= nil and opposite[#opposite].stopLine.x, -30)

-- G8: genkendelse af gemte justeringer
local withStop = {}
for _, approach in ipairs(approaches) do
    local copy = {}
    for key, value in pairs(approach) do copy[key] = value end
    if not copy.internal then copy.stopLine = TLGeometry.placeStopLine(copy, zoneA) end
    table.insert(withStop, copy)
end
local southStop = byHeading(withStop, -math.pi / 2).stopLine
local rad15, rad25 = 15 * math.pi / 180, 25 * math.pi / 180
check("G8 15 grader og 4 m matcher", TLGeometry.matchOverride({heading = -math.pi / 2 + rad15, stopPos = {x = southStop.x, z = southStop.z + 4}}, withStop), south.id)
check("G8 25 grader matcher ikke", TLGeometry.matchOverride({heading = -math.pi / 2 + rad25, stopPos = {x = southStop.x, z = southStop.z}}, withStop), nil)
check("G8 6 m matcher ikke", TLGeometry.matchOverride({heading = -math.pi / 2, stopPos = {x = southStop.x, z = southStop.z + 6}}, withStop), nil)

-- G9: overlappende krydscirkler
check("G9 overlap", TLGeometry.circlesOverlap({x = 0, z = 0}, 25, {x = 49, z = 0}, 25), true)
check("G9 netop ikke overlap", TLGeometry.circlesOverlap({x = 0, z = 0}, 25, {x = 50, z = 0}, 25), false)

-- G10: ingen kanter
local none, noExits = TLGeometry.findApproaches(CENTER, RADIUS, {})
check("G10 ingen indkørsler", #none, 0)
check("G10 ingen udkørsler", #noExits, 0)
check("G10 tom zone", #TLGeometry.conflictZone(intersection, {}).segments, 0)

-- G11: input muteres ikke
local probe = crossing()
local firstA = probe[1].a
local count = #probe
TLGeometry.findApproaches(CENTER, RADIUS, probe)
TLGeometry.conflictZone(intersection, probe)
check("G11 antal kanter uændret", #probe, count)
check("G11 punkt uændret", probe[1].a == firstA and firstA.x == -100 and firstA.z == -2, true)

-- K1: krydsningskernen har kun stykkerne nær den krydsende vej, ikke vejen ude i cirklens kant
local core = TLGeometry.conflictCore(zoneA)
check("K1 kerne er mindre end zonen", #core.segments < #zoneA.segments, true)
check("K1 midten er i kernen", TLGeometry.pointInZone(core, {x = 0, z = -2}), true)
-- testkantene er 10 m lange, så kernen er grov: 24 m ude ligger uden for kernens sidste stykke (til 20 m)
check("K1 vejen 24 m ude er ikke i kernen", TLGeometry.pointInZone(core, {x = 24, z = -2}), false)
check("K1 vejen 24 m ude er i zonen", TLGeometry.pointInZone(zoneA, {x = 24, z = -2}), true)
local onlyRoad = {}
line(-100, -2, 100, -2, 10, onlyRoad)
line(100, 2, -100, 2, 10, onlyRoad)
check("K1 lige vej uden kryds har tom kerne", #TLGeometry.conflictCore(TLGeometry.conflictZone(intersection, onlyRoad)).segments, 0)

-- M1 (review): umulig margin (lille kryds) -> stoplinjen ved mest luft tæt på krydset, ikke 100 m ude
local savedMargin = TLConfig.STOP_MARGIN
TLConfig.STOP_MARGIN = 200
local farStop = TLGeometry.placeStopLine(south, zoneA)
TLConfig.STOP_MARGIN = savedMargin
check("M1 umulig margin giver ikke vejens yderste ende", farStop.z < 80, true)

-- alongPath: signeret afstand langs stien
local path = {{x = 0, z = 0}, {x = 10, z = 0}}
check("alongPath 4 m før target", math.floor(TLGeometry.alongPath(path, {x = 6, z = 1}, {x = 10, z = 0}) + 0.5), 4)
check("alongPath negativ efter target", math.floor(TLGeometry.alongPath(path, {x = 8, z = 0}, {x = 5, z = 0}) + 0.5), -3)

-- R1 (review): en vej, der længere ude passerer tæt forbi zonen, må ikke trække stoplinjen derud
local near = crossing()
line(28, 100, 28, -2, 4, near) -- kommer fra nord langs x=28 tæt forbi øst-vest-vejens indgang ...
line(28, -2, 25.5, -2, 1, near) -- ... og drejer ind i krydset
local nearApproaches = TLGeometry.findApproaches(CENTER, RADIUS, near)
local nearZone = TLGeometry.conflictZone(intersection, near)
local westbound = byHeading(nearApproaches, math.pi)
local westStop = TLGeometry.placeStopLine(westbound, nearZone)
check("R1 stoplinje forbliver tæt på krydset", math.abs(westStop.x) < 15, true)

-- R2 (review): lang AD-kant tværs over hele cirklen giver indkørsel og udkørsel
local longApproaches, longExits = TLGeometry.findApproaches(CENTER, RADIUS, {{a = {x = -30, z = 0}, b = {x = 30, z = 0}}})
check("R2 lang kant giver indkørsel", #regular(longApproaches), 1)
check("R2 lang kant giver udkørsel", #longExits, 1)

-- R3 (review): en indkørsel uden konflikt (ingen krydsende veje) markeres conflict=false
local straight = {}
line(-100, -2, 100, -2, 10, straight)
line(100, 2, -100, 2, 10, straight)
local straightApproaches = TLGeometry.findApproaches(CENTER, RADIUS, straight)
local straightZone = TLGeometry.conflictZone(intersection, straight)
check("R3 lige vej uden kryds: ingen konflikt", TLGeometry.placeStopLine(byHeading(straightApproaches, 0), straightZone).conflict, false)
check("R3 X-kryds: konflikt", TLGeometry.placeStopLine(south, zoneA).conflict, true)

-- S1-S3: styreboksen på hjørnet -> krydsets midte findes ud fra AD-krydsningerne
local function near(p, x, z) return math.abs(p.x - x) < 0.5 and math.abs(p.z - z) < 0.5 end
local snapped, found = TLGeometry.snapCenter({x = 10, z = 8}, RADIUS, crossing())
check("S1 boks på hjørnet: midten fundet", found and near(snapped, 0, 0), true)
local twin = crossing()
line(38, -100, 38, 100, 10, twin)
line(42, 100, 42, -100, 10, twin)
snapped = TLGeometry.snapCenter({x = 30, z = 6}, RADIUS, twin)
check("S2 to kryds: det nærmeste vælges", near(snapped, 40, 0), true)
local straight = {}
line(-100, -2, 100, -2, 10, straight)
line(100, 2, -100, 2, 10, straight)
snapped, found = TLGeometry.snapCenter({x = 5, z = 9}, RADIUS, straight)
check("S3 lige vej: placeringen beholdes", found == false and near(snapped, 5, 9), true)
-- S4: L-sving uden kryds (knæk på 90° i ét vejpunkt) er ikke et kryds
local bend = {}
line(-60, -2, 2, -2, 10, bend)
line(2, -2, 2, 60, 10, bend)
line(-2, 60, -2, 2, 10, bend)
line(-2, 2, -60, 2, 10, bend)
snapped, found = TLGeometry.snapCenter({x = 4, z = -6}, RADIUS, bend)
check("S4 L-sving: ingen krydsning", found, false)
-- S5: boksen 4,5 m fra et sving, krydset 14 m væk -> krydset
local mixed = crossing()
line(-60, -20, -14, -20, 10, mixed)
line(-14, -20, -14, -60, 10, mixed)
snapped = TLGeometry.snapCenter({x = -10, z = -17}, RADIUS, mixed)
check("S5 sving tættere end krydset: krydset vælges", near(snapped, 0, 0), true)
-- S6: bredt kryds (2 vognbaner hver vej, 2 og 5 m fra midten): midten trækkes ikke mod boksen
local wide = {}
for _, offset in ipairs({2, 5}) do
    line(-100, -offset, 100, -offset, 10, wide)
    line(100, offset, -100, offset, 10, wide)
    line(offset, -100, offset, 100, 10, wide)
    line(-offset, 100, -offset, -100, 10, wide)
end
snapped = TLGeometry.snapCenter({x = 12, z = 10}, RADIUS, wide)
check("S6 bredt kryds: midten i midten", near(snapped, 0, 0), true)

-- M: masten ved stoplinjen må ikke stå på skinner eller veje (in-game 25/10: mast midt på jernbanen)
-- indkørsel mod øst (heading 0) med stoplinje i (-10, -2): højre side er +z (x øst, z syd)
local stop, heading, SIDE = {x = -10, z = -2}, 0, 3.5
local spot = TLGeometry.pickMastSpot(stop, heading, SIDE, {}, 2.5)
check("M1 fri plads: højre side ved stoplinjen", near(spot, -10, 1.5) and spot.side == 1, true)
-- skinner på tværs lige ved stoplinjens højre side: masten rykker bagud langs indkørslen
local rail = {{a = {x = -11, z = -20}, b = {x = -9, z = 20}}}
spot = TLGeometry.pickMastSpot(stop, heading, SIDE, rail, 2.5)
check("M2 skinner ved linjen: masten rykker bagud", spot.side == 1 and spot.x < -10 - 2 and math.abs(spot.z - 1.5) < 1e-6, true)
check("M2 fri af skinnerne", TLGeometry.pointSegmentDistance(spot, rail[1].a, rail[1].b) >= 2.5, true)
-- skinner langs hele højre side: masten kommer på venstre side
local alongRight = {{a = {x = -60, z = 1.5}, b = {x = 20, z = 1.5}}}
spot = TLGeometry.pickMastSpot(stop, heading, SIDE, alongRight, 2.5)
check("M3 højre side spærret: venstre side", spot.side == -1 and near(spot, -10, -5.5), true)
-- alt spærret: den plads med størst afstand vælges (aldrig nil)
local everywhere = {{a = {x = -60, z = 1.5}, b = {x = 20, z = 1.5}}, {a = {x = -60, z = -5.5}, b = {x = 20, z = -5.5}}}
spot = TLGeometry.pickMastSpot(stop, heading, SIDE, everywhere, 2.5)
check("M4 alt spærret: giver stadig en plads", spot ~= nil and spot.x ~= nil, true)

-- W: US-wiren — hvert hoved hænger over sin egen vognbane (in-game 25/10: hoveder over græsset)
local wireFrom, wireTo = {x = -20, z = -20}, {x = 20, z = 20}
-- vognbane mod øst på z = -2 krydser diagonalen i (-2, -2): 18*sqrt(2) fra wireFrom
local eastPath = {{x = -60, z = -2}, {x = -10, z = -2}, {x = 10, z = -2}}
local w = TLGeometry.wireCrossing(wireFrom, wireTo, eastPath)
check("W1 krydsning langs wiren", w ~= nil and math.abs(w - 18 * math.sqrt(2)) < 1e-6, true)
check("W2 ingen krydsning -> nil", TLGeometry.wireCrossing(wireFrom, wireTo, {{x = -60, z = 30}, {x = -30, z = 30}}), nil)
-- første krydsning set udefra (ruten svinger tilbage over wiren inde i krydset)
local uturn = {{x = -60, z = -2}, {x = 10, z = -2}, {x = 10, z = 15}, {x = -10, z = 15}}
local first = TLGeometry.wireCrossing(wireFrom, wireTo, uturn)
check("W3 første krydsning udefra", first ~= nil and math.abs(first - 18 * math.sqrt(2)) < 1e-6, true)
check("W4 tom rute -> nil", TLGeometry.wireCrossing(wireFrom, wireTo, {}), nil)
-- ruten ender før wiren (AD-forgrening før krydset, in-game 25/10): den forlænges ligeud fra sidste stykke
local short = {{x = -60, z = -2}, {x = -30, z = -2}}
local extended = TLGeometry.wireCrossing(wireFrom, wireTo, short)
check("W5 kort rute forlænges ligeud", extended ~= nil and math.abs(extended - 18 * math.sqrt(2)) < 1e-6, true)
check("W6 forlængelsen har en grænse", TLGeometry.wireCrossing(wireFrom, wireTo, {{x = -200, z = -2}, {x = -190, z = -2}}), nil)

-- D: to indkørsler med samme stoplinje er samme vognbane (in-game 25/10: spor 3 og 4 i én vognbane, rødt og
-- grønt på samme sted). Højresvingsspor med egen stoplinje bevares.
local function approachAt(id, x, z, heading, enabled)
    return {id = id, heading = heading, entry = {x = x - 10, z = z}, path = {}, lanes = {{kind = "AD"}},
        stopLine = {x = x, z = z, back = 0, conflict = enabled}, enabled = enabled, internal = false}
end
local same = {approachAt(3, -10, -2, 0, true), approachAt(4, -10.8, -1.6, 0.1, false), approachAt(5, 10, 2, math.pi, true),
    {id = TLGeometry.INTERNAL_ID, heading = 0, entry = CENTER, path = {}, lanes = {}, enabled = true, internal = true}}
local merged = TLGeometry.mergeSharedStopLines(same)
check("D1 samme stoplinje: slået sammen", #merged, 3)
check("D1 den første beholdes", merged[1].id, 3)
check("D1 lys hvis bare én af dem havde konflikt", merged[1].enabled, true)
check("D1 input uændret", #same, 4)
local turnLane = {approachAt(3, -10, -2, 0, true), approachAt(4, -12, -5.5, 0, true)}
check("D2 eget højresvingsspor (3,5 m ved siden af) bevares", #TLGeometry.mergeSharedStopLines(turnLane), 2)
-- spor, der kommer ind i cirklen fra lidt forskellige retninger og løber sammen før linjen (in-game 25/10:
-- 0.7.8 slog dem ikke sammen, retningen ved cirklen var > 20° forskellig)
local converging = {approachAt(3, -10, -2, 0, true), approachAt(4, -10.5, -2.3, math.rad(35), true)}
check("D4 sammenløbende spor (35°): slået sammen", #TLGeometry.mergeSharedStopLines(converging), 1)
local opposite = {approachAt(3, 0, 0, 0, true), approachAt(4, 0.5, 0, math.pi, true)}
check("D3 modsat retning slås aldrig sammen", #TLGeometry.mergeSharedStopLines(opposite), 2)

-- J: spillerens justeringer (spec 5.8). Override = {heading, stopPos (den automatiske linje), shift (m, + = længere
-- ud ad vejen), enabled}. Den sydgående indkørsel kommer fra +z: "længere ud" er større z.
local southAuto = TLGeometry.placeStopLine(south, zoneA)
local shifted = TLGeometry.shiftStopLine(south, southAuto, 3)
check("J1 3 m længere ud", math.abs(shifted.z - (southAuto.z + 3)) < 0.3, true)
check("J1 retningen følger med", shifted.heading ~= nil and math.abs(shifted.heading - (-math.pi / 2)) < 0.05, true)
check("J1 back vokser med 3", math.abs(shifted.back - (southAuto.back + 3)) < 0.3, true)
local inward = TLGeometry.shiftStopLine(south, southAuto, -2)
check("J2 2 m frem mod krydset", math.abs(inward.z - (southAuto.z - 2)) < 0.3, true)
local clamped = TLGeometry.shiftStopLine(south, southAuto, 10000)
check("J3 klemmes til vejens yderste ende", clamped ~= nil and clamped.z > southAuto.z, true)

local withAuto = {}
for _, approach in ipairs(approaches) do
    local copy = {}
    for k, v in pairs(approach) do copy[k] = v end
    if not copy.internal then copy.stopLine = TLGeometry.placeStopLine(copy, zoneA); copy.enabled = true end
    table.insert(withAuto, copy)
end
local southId = byHeading(withAuto, -math.pi / 2).id
local overrides = {
    {heading = -math.pi / 2, stopPos = {x = southAuto.x, z = southAuto.z}, shift = 3, enabled = true},
    {heading = 0, stopPos = {x = 500, z = 500}, shift = 0, enabled = false}, -- passer ikke længere: forældet
}
local adjusted, stale = TLGeometry.applyOverrides(withAuto, overrides)
local adjustedSouth = byHeading(adjusted, -math.pi / 2)
check("J4 justeringen flytter linjen", math.abs(adjustedSouth.stopLine.z - (southAuto.z + 3)) < 0.3, true)
check("J4 justeringen husker sin plads", adjustedSouth.overrideIndex, 1)
check("J4 input uændret", math.abs(byHeading(withAuto, -math.pi / 2).stopLine.z - southAuto.z) < 1e-9, true)
check("J5 forældet justering meldes", #stale == 1 and stale[1] == 2, true)
local off = TLGeometry.applyOverrides(withAuto, {{heading = -math.pi / 2, stopPos = {x = southAuto.x, z = southAuto.z}, shift = 0, enabled = false}})
check("J6 slået fra: intet lys", byHeading(off, -math.pi / 2).enabled, false)
check("J6 de andre uændret", #off, #withAuto)
check("J7 id bevares", byHeading(adjusted, -math.pi / 2).id, southId)

-- K: justeringens livsforløb (review M3). adjustOverrides returnerer en NY liste.
local LIMITS = {step = 0.5, min = -15, max = 40}
local autoSouth = {id = 7, heading = -math.pi / 2, stopLine = {x = 2, z = 10}}
local list0 = {}
local list1 = TLGeometry.adjustOverrides(list0, autoSouth, nil, "back", LIMITS)
check("K1 ny justering oprettes", #list1 == 1 and list1[1].shift == 0.5 and list1[1].stopPos.z == 10, true)
check("K1 input uændret", #list0, 0)
local south1 = {id = 7, heading = -math.pi / 2, stopLine = {x = 2, z = 10.5}, overrideIndex = 1}
local list2 = TLGeometry.adjustOverrides(list1, south1, nil, "back", LIMITS)
check("K2 samme justering flyttes videre", #list2 == 1 and list2[1].shift == 1.0, true)
check("K2 bundet til den automatiske linje", list2[1].stopPos.z, 10)
check("K2 forrige liste uændret", list1[1].shift, 0.5)
local list3 = TLGeometry.adjustOverrides(list2, south1, nil, "toggle", LIMITS)
check("K3 slået fra", list3[1].enabled, false)
local list4 = TLGeometry.adjustOverrides(list3, south1, nil, "toggle", LIMITS)
check("K3 slået til igen", list4[1].enabled, true)
local far = list4
for _ = 1, 200 do far = TLGeometry.adjustOverrides(far, south1, nil, "back", LIMITS) end
check("K4 klemt til max", far[1].shift, 40)
local list5 = TLGeometry.adjustOverrides(list4, south1, nil, "reset", LIMITS)
check("K5 nulstil fjerner", #list5, 0)
-- en justering, der står på 0 m og med lys, gør intet og fjernes (review LOW)
local zero = TLGeometry.adjustOverrides(list1, south1, nil, "forward", LIMITS)
check("K6 tilbage på 0 og med lys: fjernet", #zero, 0)
local two = {list2[1], {heading = 0, stopPos = {x = 99, z = 99}, shift = 2, enabled = true}}
local cleaned = TLGeometry.adjustOverrides(two, nil, {2}, "reset", LIMITS)
check("K7 forældede slettes, de andre bliver", #cleaned == 1 and cleaned[1].stopPos.z == 10, true)
check("K7 forældede kun med nulstil", #TLGeometry.adjustOverrides(two, nil, {2}, "back", LIMITS), 2)

print(failures == 0 and "\nALLE TESTS OK" or ("\n" .. failures .. " FEJL"))
os.exit(failures == 0 and 0 or 1)
