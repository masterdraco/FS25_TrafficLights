-- Efterspørgsel og belægning for ét kryds (spec 5.4/5.12). Ren Lua, muterer aldrig input.
-- Kontrakt med adapterne (tlAutoDrive/tlCourseplay/tlTraffic):
--   snapshot.pos    = køretøjets FRONT (stoplinjen gælder fronten)
--   snapshot.route  = kommende rutepunkter KUN mens køretøjet aktivt kører mod et mål; et køretøj, der
--                     læsser/aflæsser eller holder parkeret, har route = nil og skaber ingen efterspørgsel
--   snapshot.speed  = m/s
--   snapshot.length = samlet længde inkl. anhængere i m (valgfri; DEFAULT_LENGTH ellers)
TLDemand = {}

local ROUTE_HIT_M = 3            -- ruten "passerer stoplinjen", når den kommer inden for 3 m
local ROUTE_HIT_ANGLE = math.pi / 4
local QUEUE_GAP_M = 10           -- afstand til køretøjet foran, der stadig er "kø" (plus dets længde)
local DEFAULT_LENGTH = 20        -- m, traktor + vogn, når adapteren ikke kender længden
local LANE_M = 3
local TRAFFIC_BRAKE = 3            -- m/s², kortets biler bremser mindst så hårdt
local TRAFFIC_BRAKE_MARGIN_M = 5

local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end

local function copyTable(t)
    local copy = {}
    for key, value in pairs(t) do copy[key] = value end
    return copy
end

local function lengthOf(snapshot) return snapshot.length or DEFAULT_LENGTH end
local function isMoving(snapshot) return (snapshot.speed or 0) > TLConfig.MOVING_SPEED end

-- Hvor langt før stoplinjen et køretøj holdes: mindst HOLD_DISTANCE, men et hurtigt køretøj skal holdes,
-- mens det endnu kan nå at bremse (in-game 25/10: traktorer i fart rullede over linjen og regnedes så som
-- "inde i krydset"). Står den tidligt, rykker den frem og holdes igen ved linjen.
local function holdReach(snapshot)
    local speed = snapshot.speed or 0
    return math.max(TLConfig.HOLD_DISTANCE, speed * speed / (2 * TLConfig.HOLD_BRAKE) + TLConfig.HOLD_BRAKE_MARGIN)
end

local function routePoints(snapshot)
    local points = {snapshot.pos}
    for _, point in ipairs(snapshot.route or {}) do table.insert(points, point) end
    return points
end

local function nearPolyline(points, p, tolerance)
    for i = 1, #points - 1 do
        if TLGeometry.pointSegmentDistance(p, points[i], points[i + 1]) <= tolerance then return true end
    end
    return false
end

-- Afstand langs ruten til det sted, hvor den passerer target i retning heading, eller nil.
local function routeHit(points, target, heading)
    local walked = 0
    for i = 1, #points - 1 do
        local a, b = points[i], points[i + 1]
        local length = dist(a, b)
        if length > 0 then
            local segHeading = math.atan2(b.z - a.z, b.x - a.x)
            if TLGeometry.pointSegmentDistance(target, a, b) <= ROUTE_HIT_M
                and TLGeometry.angleDiff(segHeading, heading) <= ROUTE_HIT_ANGLE then
                local t = math.max(0, math.min(1, ((target.x - a.x) * (b.x - a.x) + (target.z - a.z) * (b.z - a.z)) / (length * length)))
                return walked + t * length
            end
        end
        walked = walked + length
    end
    return nil
end

-- Ligger p på ruten inden for maxLength fra fronten?
local function onRouteWithin(points, p, maxLength)
    local walked = 0
    for i = 1, #points - 1 do
        if TLGeometry.pointSegmentDistance(p, points[i], points[i + 1]) <= LANE_M then return true end
        walked = walked + dist(points[i], points[i + 1])
        if walked >= maxLength then break end
    end
    return false
end

local function regularApproaches(intersection)
    local list = {}
    for _, approach in ipairs(intersection.approaches or {}) do
        if not approach.internal and approach.stopLine ~= nil then table.insert(list, approach) end
    end
    return list
end

local function internalApproach(intersection)
    for _, approach in ipairs(intersection.approaches or {}) do
        if approach.internal then return approach end
    end
    return nil
end

local function approachById(intersection, id)
    for _, approach in ipairs(intersection.approaches or {}) do
        if approach.id == id then return approach end
    end
    return nil
end

-- Hvilken indkørsel et køretøj med rute er på vej ind ad (nærmeste stoplinje foran sig).
local function approachForRoute(snapshot, intersection)
    local points = routePoints(snapshot)
    local bestId, bestDistance = nil, nil
    for _, approach in ipairs(regularApproaches(intersection)) do
        local distance = routeHit(points, approach.stopLine, approach.heading)
        if distance ~= nil and distance <= TLConfig.DEMAND_DISTANCE and (bestDistance == nil or distance < bestDistance) then
            bestId, bestDistance = approach.id, distance
        end
    end
    return bestId
end

local function hasTrafficLane(approach)
    for _, lane in ipairs(approach.lanes or {}) do
        if lane.kind == "TRAFFIC" then return true end
    end
    return false
end

local function distanceToPolyline(points, p)
    local best = math.huge
    for i = 1, #points - 1 do best = math.min(best, TLGeometry.pointSegmentDistance(p, points[i], points[i + 1])) end
    return best
end

-- Kortets trafik har ingen rute: indkørslen er den NÆRMESTE sti, den kører ind ad — og helst den, der ejer
-- et trafikspor (to vognbaner i samme retning deler spor; bilen blev talt på den uden spor og holdt for den
-- andens spærring, mens "dens" grønne lys aldrig fik fremdrift — review, in-game 25/10).
local function approachForTraffic(snapshot, intersection)
    local best, bestAlong, bestScore = nil, nil, nil
    for _, approach in ipairs(regularApproaches(intersection)) do
        local along = TLGeometry.alongPath(approach.path, snapshot.pos, approach.stopLine)
        -- helt ud til DEMAND_DISTANCE: en ensom bil skal have grønt, før den skal bremse (som AD). Kun biler,
        -- der kører IND mod krydset: modsat vognbane ligger ~3,5 m fra stien og må ikke give efterspørgsel.
        local sameWay = snapshot.heading == nil or TLGeometry.angleDiff(snapshot.heading, approach.heading) <= ROUTE_HIT_ANGLE
        local d = distanceToPolyline(approach.path, snapshot.pos)
        if sameWay and d <= LANE_M and along ~= nil and along >= 0 and along <= TLConfig.DEMAND_DISTANCE then
            local score = d - (hasTrafficLane(approach) and LANE_M or 0)
            if bestScore == nil or score < bestScore then best, bestAlong, bestScore = approach, along, score end
        end
    end
    if best == nil then return nil end
    return best.id, bestAlong
end

local function signedToStopLine(approach, pos)
    return TLGeometry.alongPath(approach.path, pos, approach.stopLine)
end

local function routeAheadTouchesZone(snapshot, zone)
    local points = routePoints(snapshot)
    local walked = 0
    for i = 1, #points do
        if TLGeometry.pointInZone(zone, points[i]) then return true end
        if i < #points then walked = walked + dist(points[i], points[i + 1]) end
        if walked >= 40 then break end
    end
    return false
end

local function headingOf(snapshot, fallback)
    local nextPoint = (snapshot.route or {})[1]
    if nextPoint ~= nil and dist(nextPoint, snapshot.pos) > 0.1 then
        return math.atan2(nextPoint.z - snapshot.pos.z, nextPoint.x - snapshot.pos.x)
    end
    return fallback
end

-- Et entered-køretøj er stadig "i krydset", indtil fronten er en køretøjslængde fra de andre vejes
-- baner (ellers meldes zonen tom, mens anhængeren stadig er derinde — review). Den egen vej tæller
-- ikke med: ellers skulle bilen køre en længde ud over hele cirklen.
local function stillInCrossing(snapshot, zone, heading)
    local clearance = heading ~= nil and TLGeometry.crossingClearance(zone, snapshot.pos, heading)
        or TLGeometry.zoneClearance(zone, snapshot.pos)
    return clearance < lengthOf(snapshot)
end

local function enterEntered(entry, approachId, result, countIt)
    entry.entered = true
    if countIt then result.crossed[approachId] = (result.crossed[approachId] or 0) + 1 end
end

local function trackVehicle(snapshot, previous, intersection, nowMs, result)
    local zone = intersection.zone
    local moving = isMoving(snapshot)
    local entry = previous ~= nil and copyTable(previous) or {firstSeenMs = nowMs, entered = false}
    entry.lastPos = snapshot.pos
    if moving then entry.stillSinceMs = nil
    elseif entry.stillSinceMs == nil then entry.stillSinceMs = nowMs end
    entry.heading = headingOf(snapshot, entry.heading)

    if entry.entered then
        -- holder ved sit mål (læsser/parkerer) i eller tæt på krydset: ikke længere trafik (review CRITICAL)
        if snapshot.route == nil and not moving then return nil end
        if not stillInCrossing(snapshot, zone, entry.heading) then return nil end
        return entry
    end

    if snapshot.route == nil then
        if snapshot.kind ~= "TRAFFIC" then return nil end
        local id, along = approachForTraffic(snapshot, intersection)
        if id == nil then
            -- kørt over sin stoplinje: tæller i grænsen på 4 pr. grønt (ellers ventede AD for evigt bag en
            -- strøm af kortets biler — review)
            local tracked = previous ~= nil and approachById(intersection, previous.approachId) or nil
            if tracked ~= nil then
                local signed = signedToStopLine(tracked, snapshot.pos)
                if signed ~= nil and signed < 0 then result.crossed[tracked.id] = (result.crossed[tracked.id] or 0) + 1 end
            end
            return nil
        end
        entry.approachId = id
        entry.signed = along
        return entry
    end

    local internal = internalApproach(intersection)
    local id = approachForRoute(snapshot, intersection)
    local inside = dist(snapshot.pos, intersection.center) < intersection.radius
    -- Første gang set INDE i krydset med en rute, der går gennem zonen: regnes som kørt ind og holdes
    -- aldrig (spec: en bil i krydset må aldrig stoppes). In-game 25/10: biler i kø ud ad udkørslen inden
    -- for cirklen blev holdt som "interne" og spærrede for bilen i krydset — lås.
    -- Står den stille (fx ved en markør på en gårdsplads), følges den først, når den kører (review).
    if id == nil and previous == nil and inside and routeAheadTouchesZone(snapshot, zone) then
        if not moving then return nil end
        entry.approachId = internal ~= nil and internal.id or TLGeometry.INTERNAL_ID
        entry.entered = true
        return entry
    end
    if id == nil and entry.approachId ~= nil then
        -- sprang over linjen i én takt (høj fart): ruten rammer ikke længere stoplinjen foran sig
        local tracked = approachById(intersection, entry.approachId)
        local signed = tracked ~= nil and signedToStopLine(tracked, snapshot.pos) or nil
        if signed ~= nil and signed < 0 and (TLGeometry.pointInZone(zone, snapshot.pos) or routeAheadTouchesZone(snapshot, zone)) then
            id = entry.approachId
        end
    end
    if id == nil then return nil end -- ruten går ikke (længere) gennem krydset
    entry.approachId = id
    local signed = signedToStopLine(approachById(intersection, id), snapshot.pos)
    if signed ~= nil and signed < 0 then
        enterEntered(entry, id, result, previous ~= nil and not previous.entered)
    end
    entry.signed = signed
    return entry
end

-- Står der en kø foran (et køretøj, der kører eller kun har holdt kort)? Parkerede køretøjer og
-- køretøjer, der selv har holdt i STUCK_MS, er ikke kø — ellers udløses sikkerhedsventilen aldrig (review).
local function hasQueueAhead(snapshot, snapshots, tracking, stillSince, nowMs)
    local points = routePoints(snapshot)
    for _, other in ipairs(snapshots) do
        if other.key ~= snapshot.key then
            local otherEntry = tracking[other.key]
            -- kø = kører, eller har holdt kortere end STUCK_MS: fulgte køretøjer (to næse mod næse udløser
            -- ventilen) og ufulgte med aktiv rute (fx kø ved en silo længere ude — review; står de længere,
            -- må ventilen også slå til)
            local since = otherEntry ~= nil and otherEntry.stillSinceMs or (other.route ~= nil and stillSince[other.key]) or nil
            local active = isMoving(other) or (since ~= nil and nowMs - since < TLConfig.STUCK_MS)
            if active and onRouteWithin(points, other.pos, QUEUE_GAP_M + lengthOf(other)) then return true end
        end
    end
    return false
end

local function exitForRoute(snapshot, intersection)
    local points = routePoints(snapshot)
    local bestExit, bestDistance = nil, nil
    for _, exit in ipairs(intersection.exits or {}) do
        local distance = routeHit(points, exit.exitPoint, exit.heading)
        if distance ~= nil and (bestDistance == nil or distance < bestDistance) then bestExit, bestDistance = exit, distance end
    end
    return bestExit
end

-- Holder et køretøj stille i udkørslen og vender ud ad den? Køretøjer, der vender ind mod krydset, er
-- en kø på modsat vognbane (ved AD's tovejskæder på samme linje — review). Ukendt retning tæller.
local function exitBlocked(exit, snapshots, tracking)
    for _, other in ipairs(snapshots) do
        local otherEntry = tracking[other.key]
        local heading = headingOf(other, otherEntry ~= nil and otherEntry.heading or nil)
        local facingOut = heading == nil or TLGeometry.angleDiff(heading, exit.heading) <= ROUTE_HIT_ANGLE
        if facingOut and not isMoving(other) and nearPolyline(exit.path, other.pos, LANE_M) then
            local along = TLGeometry.alongPath(exit.path, other.pos, exit.exitPoint)
            -- along er negativ efter udkørselspunktet (stien løber udad)
            if along ~= nil and along <= 0 and -along <= TLConfig.EXIT_ROOM then return true end
        end
    end
    return false
end

function TLDemand.collect(snapshots, intersection, tracking, nowMs)
    snapshots = snapshots or {}
    local result = {crossed = {}, exitRoom = {}, trafficCommitted = {}}
    local newTracking, holdList = {}, {}
    local approachesInput = {}
    for _, approach in ipairs(intersection.approaches or {}) do
        approachesInput[approach.id] = {enabled = approach.enabled ~= false, demand = false, firstWaitMs = nil}
    end

    -- hvor længe ufulgte køretøjer med rute har holdt stille (til kø-reglen); gemt under en reserveret nøgle
    local oldStill = (tracking or {}).__still or {}
    local stillSince = {}
    for _, snapshot in ipairs(snapshots) do
        if (snapshot.route ~= nil or snapshot.kind == "TRAFFIC") and not isMoving(snapshot) then
            stillSince[snapshot.key] = oldStill[snapshot.key] or nowMs
        end
    end
    newTracking.__still = stillSince

    local bySnapshot = {}
    for _, snapshot in ipairs(snapshots) do
        local entry = trackVehicle(snapshot, (tracking or {})[snapshot.key], intersection, nowMs, result)
        if entry ~= nil then newTracking[snapshot.key] = entry end
        bySnapshot[snapshot] = entry
    end

    local zoneOccupied, zoneStuckMs = false, 0
    local occupiedBy = {}
    local frontOfQueue = {}
    for _, snapshot in ipairs(snapshots) do
        local entry = bySnapshot[snapshot]
        -- fulgte køretøjer optager krydset, når de er kørt ind over stoplinjen. Køretøjer uden rute
        -- (kortets trafik, spillerens egen kørsel) optager det, når de kører i zonen. AD/CP med en rute,
        -- som lyskurven ikke følger, er på vej ud eller kommer fra en frakoblet indkørsel: tæller ikke.
        -- ukendte køretøjer tæller kun i krydsningskernen, og Courseplay i markarbejde aldrig (in-game 25/10:
        -- en CP-traktor i markkanten holdt krydset optaget, så lyset stod på rødt for evigt)
        local inCore = TLGeometry.pointInZone(intersection.core or intersection.zone, snapshot.pos)
        -- kortets trafik, der holder i kernen efter sin stoplinje (viger, kø ud ad udkørsel), optager også —
        -- højst STUCK_MS (review). KUN uden entry: en bil med entry venter FØR sin stoplinje (in-game 25/10:
        -- forreste bil ved rødt lå i kernen og holdt krydset "optaget" i 60 s — alt rødt)
        local recentlyStill = snapshot.kind == "TRAFFIC" and stillSince[snapshot.key] ~= nil and nowMs - stillSince[snapshot.key] < TLConfig.STUCK_MS
        local untrackedTraffic = entry == nil and snapshot.route == nil and snapshot.kind ~= "CP"
            and inCore and (isMoving(snapshot) or recentlyStill)
        if (entry ~= nil and entry.entered) or untrackedTraffic then
            zoneOccupied = true
            table.insert(occupiedBy, string.format("%s(%s%s)", tostring(snapshot.name or snapshot.key), snapshot.kind or "?",
                entry ~= nil and entry.entered and ",inde" or ",kører"))
        end
        if entry ~= nil and entry.entered then
            if not isMoving(snapshot) and entry.stillSinceMs ~= nil and not hasQueueAhead(snapshot, snapshots, newTracking, stillSince, nowMs) then
                zoneStuckMs = math.max(zoneStuckMs, nowMs - entry.stillSinceMs)
            end
        elseif entry ~= nil and snapshot.kind == "TRAFFIC" and isMoving(snapshot) and entry.signed ~= nil
            and approachById(intersection, entry.approachId) ~= nil and hasTrafficLane(approachById(intersection, entry.approachId))
            and entry.signed <= (snapshot.speed ^ 2) / (2 * TRAFFIC_BRAKE) + TRAFFIC_BRAKE_MARGIN_M
            and approachesInput[entry.approachId] ~= nil and approachesInput[entry.approachId].enabled then
            -- kan ikke nå at stoppe: lyset må ikke give grønt på tværs, før den er igennem (review)
            result.trafficCommitted[entry.approachId] = true
            local approachInput = approachesInput[entry.approachId]
            approachInput.demand = true
            if approachInput.firstWaitMs == nil or entry.firstSeenMs < approachInput.firstWaitMs then
                approachInput.firstWaitMs = entry.firstSeenMs
            end
        elseif entry ~= nil and approachesInput[entry.approachId] ~= nil and approachesInput[entry.approachId].enabled then
            -- frakoblet indkørsel: ingen efterspørgsel og ingen hold (spec 5.8: "holder ingen" — review)
            local approachInput = approachesInput[entry.approachId]
            approachInput.demand = true
            if approachInput.firstWaitMs == nil or entry.firstSeenMs < approachInput.firstWaitMs then
                approachInput.firstWaitMs = entry.firstSeenMs
            end
            local isInternal = entry.approachId == TLGeometry.INTERNAL_ID
            local holdable = isInternal or (entry.signed ~= nil and entry.signed >= 0 and entry.signed <= holdReach(snapshot))
            if holdable and snapshot.kind ~= "TRAFFIC" then
                table.insert(holdList, {key = snapshot.key, approachId = entry.approachId, kind = snapshot.kind})
            end
            local distance = entry.signed or 0
            local front = frontOfQueue[entry.approachId]
            if snapshot.route ~= nil and (front == nil or distance < front.distance) then
                frontOfQueue[entry.approachId] = {snapshot = snapshot, distance = distance}
            end
        end
    end

    for approachId, front in pairs(frontOfQueue) do
        local exit = exitForRoute(front.snapshot, intersection)
        if exit ~= nil and exitBlocked(exit, snapshots, newTracking) then result.exitRoom[approachId] = false end
    end

    result.approaches = approachesInput
    result.zoneOccupied = zoneOccupied
    result.zoneStuckMs = zoneStuckMs
    result.occupiedBy = occupiedBy
    return result, newTracking, holdList
end
