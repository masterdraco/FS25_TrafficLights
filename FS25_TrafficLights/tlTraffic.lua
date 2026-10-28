-- Kortets trafik (spec 5.1/5.7): spærring pr. kørespor og registrering af trafikbiler.
-- Bevist in-game 25/10 (spike): find(tsId, x,y,z, dx,dy,dz, maxDist) -> (splineId, splineTime);
-- set(tsId, splineId, splineTime, bool). Spærring virker pr. kørespor; splineTime skal genbruges EKSAKT.
-- Motorfunktionerne kan ikke findes med pairs(getfenv(0)) — de slås op ved navn.
-- setBlocked/releaseAll returnerer NYE lane-tabeller: kalderen skal gemme dem (ellers ude af sync med motoren).
-- Alt her kører kun på serveren.
TLTraffic = {}

local G = getfenv(0)
local LANE_SEARCH_M = 5
local CAR_FRONT_M = 2.5          -- trafikbilens front foran dens midtpunkt
local SAME_CAR_M = 2.5           -- flere kollisionsdele af samme bil slås sammen
local POSITION_TTL_MS = 5000
local LOG_PREFIX = "[TrafficLights] "

-- Registrering af trafikbiler med overlapSphere(CollisionFlag.TRAFFIC_VEHICLE) BEVIST in-game 25/10 12:09
-- (testbanen: tlTrafficScan fandt en bil ved stoplinjen). Uden registrering bruges fast rydningstid.
TLTraffic.detectionProven = true
local lastPositions = {}           -- objectId -> {x, z, timeMs}

function TLTraffic.systemId()
    local ts = g_currentMission ~= nil and g_currentMission.trafficSystem or nil
    return ts ~= nil and ts.trafficSystemId or nil
end

local function engine(name)
    local fn = G[name]
    return type(fn) == "function" and fn or nil
end

function TLTraffic.isAvailable()
    return g_server ~= nil and TLTraffic.systemId() ~= nil and engine("findTrafficSystemBlockingPositionInformation") ~= nil
        and engine("setTrafficSystemBlockingPositionState") ~= nil
end

local function findRaw(x, y, z, heading)
    local find = engine("findTrafficSystemBlockingPositionInformation")
    return find(TLTraffic.systemId(), x, y, z, math.cos(heading), 0, math.sin(heading), LANE_SEARCH_M)
end

local DIRECTION_PROBE_M = 3

-- Søger trafiksporet midt i vognbanen ved pos for trafik, der kører i retning heading. Motoren finder det
-- NÆRMESTE spor uanset retning (spike 25/10), så retningen sikres ved et punkt længere BAGUD (fremad ender
-- sporene typisk ved krydset — review): samme spor og mindre splineTime = samme kørselsretning.
-- ANTAGELSE (bevises med tlTrafficTest): splineTime vokser i trafikkens kørselsretning. y = terrænhøjde, hvis nil.
function TLTraffic.findLane(pos, heading, y)
    if not TLTraffic.isAvailable() then return nil end
    if y == nil and g_terrainNode ~= nil then y = getTerrainHeightAtWorldPos(g_terrainNode, pos.x, 0, pos.z) end
    local splineId, splineTime = findRaw(pos.x, y or 0, pos.z, heading)
    -- spor 0 = intet trafikspor her (fx en gårdspladsvej): ingen spærring, og ingen afvisnings-log
    if splineId == nil or splineId == 0 or splineTime == nil then return nil end
    local behindId, behindTime = findRaw(pos.x - math.cos(heading) * DIRECTION_PROBE_M, y or 0,
        pos.z - math.sin(heading) * DIRECTION_PROBE_M, heading)
    -- samme spor: positionen skal være mindre bagud. Andet spor: sporet kan skifte stykke lige bag
    -- stoplinjen (in-game 25/10: bagud t=0,93 på det forrige stykke, her t=0,06 på det nye) — det er samme
    -- retning, når det forrige stykke slutter bagud og det nye starter her; den modsatte vognbane giver omvendt.
    local sameDirection = behindTime ~= nil and ((behindId == splineId and behindTime < splineTime)
        or (behindId ~= splineId and behindTime > 0.5 and splineTime < 0.5))
    if not sameDirection then
        if TLConfig.DEBUG then
            Logging.info("%sspor ved (%.1f, %.1f) afvist: spor %s t=%.6f, 3 m bagud spor %s t=%s", LOG_PREFIX, pos.x, pos.z,
                tostring(splineId), splineTime, tostring(behindId), tostring(behindTime))
        end
        return nil
    end
    return {splineId = splineId, splineTime = splineTime, blocked = false}
end

-- Idempotent: kalder kun motoren, når tilstanden faktisk ændres. Returnerer en ny lane-tabel.
function TLTraffic.setBlocked(lane, blocked)
    if lane == nil or lane.splineId == nil or lane.blocked == blocked then return lane end
    local set = engine("setTrafficSystemBlockingPositionState")
    local tsId = TLTraffic.systemId()
    if set == nil or tsId == nil then return lane end
    set(tsId, lane.splineId, lane.splineTime, blocked)
    -- alle felter bevares (kind = "TRAFFIC" m.fl.): in-game 25/10 mistede sporet sit kind efter første
    -- spærring, blev aldrig genkendt igen og forblev spærret for evigt
    local copy = {}
    for key, value in pairs(lane) do copy[key] = value end
    copy.blocked = blocked
    return copy
end

function TLTraffic.releaseAll(lanes)
    local released = {}
    for i, lane in ipairs(lanes or {}) do released[i] = TLTraffic.setBlocked(lane, false) end
    return released
end

function TLTraffic.canDetectCars()
    return TLTraffic.detectionProven
end

-- Trafikbiler inden for radius om center (kind = "TRAFFIC", route = nil). Fart regnes ud fra sidste scan.
function TLTraffic.carSnapshots(center, radius, nowMs)
    if g_server == nil or overlapSphere == nil or CollisionFlag == nil or CollisionFlag.TRAFFIC_VEHICLE == nil then return {} end
    local found = {}
    local collector = {}
    function collector.onOverlap(_, objectId)
        if objectId ~= nil and objectId ~= 0 and entityExists(objectId) then found[objectId] = true end
        return true
    end
    -- kuglen dækker også lodret (broer, skrænter): radius er altid >= krydsets radius
    local y = g_terrainNode ~= nil and getTerrainHeightAtWorldPos(g_terrainNode, center.x, 0, center.z) or 0
    overlapSphere(center.x, y + 1, center.z, radius, "onOverlap", collector, CollisionFlag.TRAFFIC_VEHICLE, true, true, true, false)

    local cars = {}
    for objectId in pairs(found) do
        local x, _, z = getWorldTranslation(objectId)
        local duplicate = false
        for _, car in ipairs(cars) do
            if (car.x - x) ^ 2 + (car.z - z) ^ 2 <= SAME_CAR_M * SAME_CAR_M then duplicate = true break end
        end
        if not duplicate then table.insert(cars, {id = objectId, x = x, z = z}) end
    end

    local snapshots, seen = {}, {}
    for _, car in ipairs(cars) do
        local dx, _, dz = localDirectionToWorld(car.id, 0, 0, 1)
        local speed = 0
        local last = lastPositions[car.id]
        if last ~= nil and nowMs > last.timeMs then
            speed = math.sqrt((car.x - last.x) ^ 2 + (car.z - last.z) ^ 2) / ((nowMs - last.timeMs) / 1000)
        end
        lastPositions[car.id] = {x = car.x, z = car.z, timeMs = nowMs}
        seen[car.id] = true
        table.insert(snapshots, {key = "traffic:" .. car.id, kind = "TRAFFIC", name = "traffic " .. car.id,
            pos = {x = car.x + dx * CAR_FRONT_M, z = car.z + dz * CAR_FRONT_M}, speed = speed, route = nil, length = 5,
            heading = math.atan2(dz, dx)})
    end
    -- glem biler, der er kørt væk eller despawnet (ellers vokser tabellen i timevis — review)
    for objectId, last in pairs(lastPositions) do
        if not seen[objectId] and nowMs - last.timeMs > POSITION_TTL_MS then lastPositions[objectId] = nil end
    end
    return snapshots
end

-- Konsolkommandoer til beviset i spillet (Task 5). Kun med TLConfig.DEBUG.
local Debug = {}
Debug.testLane = nil

function Debug:scan(radiusText)
    if g_localPlayer == nil then return "ingen spiller" end
    local x, _, z = g_localPlayer:getPosition()
    local radius = tonumber(radiusText) or 30
    local cars = TLTraffic.carSnapshots({x = x, z = z}, radius, g_time or 0)
    for _, car in ipairs(cars) do
        Logging.info("%sscan: %s ved (%.1f, %.1f) retning %.0f grader, %.1f m/s", LOG_PREFIX, car.name, car.pos.x, car.pos.z,
            math.deg(car.heading or 0), car.speed or 0)
    end
    if #cars > 0 then TLTraffic.detectionProven = true end
    return string.format("tlTrafficScan: %d trafikbil(er) inden for %d m (se log.txt)", #cars, radius)
end

function Debug:test()
    if g_localPlayer == nil then return "ingen spiller" end
    local x, _, z = g_localPlayer:getPosition()
    local heading = 0
    if g_localPlayer.getCurrentFacingDirection ~= nil then
        local dx, dz = g_localPlayer:getCurrentFacingDirection()
        if dx ~= nil and dz ~= nil then heading = math.atan2(dz, dx) end
    end
    if Debug.testLane ~= nil then
        TLTraffic.setBlocked(Debug.testLane, false)
        Debug.testLane = nil
        return "tlTrafficTest: spærring sluppet"
    end
    local y = g_terrainNode ~= nil and getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) or 0
    local id1, t1 = findRaw(x, y, z, heading)
    local id2, t2 = findRaw(x - math.cos(heading) * DIRECTION_PROBE_M, y, z - math.sin(heading) * DIRECTION_PROBE_M, heading)
    Logging.info("%stest: retning %.0f grader: spor %s t=%.17g / 3 m bagud: spor %s t=%.17g", LOG_PREFIX,
        math.deg(heading), tostring(id1), t1 or -1, tostring(id2), t2 or -1)
    local lane = TLTraffic.findLane({x = x, z = z}, heading)
    if lane == nil then return "tlTrafficTest: intet trafikspor i din kigge-retning her (se log.txt)" end
    Debug.testLane = TLTraffic.setBlocked(lane, true)
    Logging.info("%stest: spærret spor %s position %.17g", LOG_PREFIX, tostring(lane.splineId), lane.splineTime)
    return "tlTrafficTest: spærret - kør kommandoen igen for at slippe"
end

if TLConfig ~= nil and TLConfig.DEBUG and addConsoleCommand ~= nil then
    addConsoleCommand("tlTrafficScan", "Lyskurve: find trafikbiler omkring dig [radius]", "scan", Debug)
    addConsoleCommand("tlTrafficTest", "Lyskurve: spær/slip trafiksporet hvor du står", "test", Debug)
end
