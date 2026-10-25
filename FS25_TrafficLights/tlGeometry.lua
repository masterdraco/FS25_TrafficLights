-- Krydsgeometri (spec 5.3/5.4). Ren Lua: positioner {x=, z=}, vinkler i radianer, muterer aldrig input.
-- Indkørsel = rettet kant, der krydser cirklen indad; udkørsel = kant, der krydser udad.
-- Konfliktzone = kantstykkerne inde i cirklen med en halv bredde (svingudslag). Stoplinjen for en
-- indkørsel måles kun mod stykker UDEN for dens egen vejkorridor (samme eller modsat retning tæt på
-- dens linje), ellers ville den modsatte vognbane på samme vej skubbe alle stoplinjer ud af krydset.
TLGeometry = {}

local MERGE_ENTRY_M = 3          -- indkørsler med samme retning og entry inden for 3 m er én
local CORRIDOR_LATERAL_M = 6     -- stykker parallelle med indkørslen inden for 6 m er dens egen vej
local CHAIN_EPS = 0.05           -- kantendepunkter, der regnes for samme vejpunkt
local PATH_BACK_M = 100          -- så langt bagud følges indkørslens rute
local SAMPLE_M = 0.5
local INTERNAL_ID = 0
local CORE_MARGIN_M = 2 -- kernen er uafhængig af STOP_MARGIN (review: ellers voksede den på alle kryds)

local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
local function inside(p, center, radius) return dist(p, center) < radius end
local function headingOf(a, b) return math.atan2(b.z - a.z, b.x - a.x) end

local function angleDiff(a, b)
    local d = (a - b) % (2 * math.pi)
    if d > math.pi then d = 2 * math.pi - d end
    return d
end

local function degToRad(deg) return deg * math.pi / 180 end

local function pointSegmentDistance(p, a, b)
    local dx, dz = b.x - a.x, b.z - a.z
    local lengthSq = dx * dx + dz * dz
    if lengthSq == 0 then return dist(p, a) end
    local t = math.max(0, math.min(1, ((p.x - a.x) * dx + (p.z - a.z) * dz) / lengthSq))
    return dist(p, {x = a.x + t * dx, z = a.z + t * dz})
end

-- Punktet hvor stykket a->b skærer cirklen (første skæring i [0,1]), eller nil.
local function circleCrossing(a, b, center, radius)
    local dx, dz = b.x - a.x, b.z - a.z
    local fx, fz = a.x - center.x, a.z - center.z
    local qa = dx * dx + dz * dz
    if qa == 0 then return nil end
    local qb = 2 * (fx * dx + fz * dz)
    local qc = fx * fx + fz * fz - radius * radius
    local disc = qb * qb - 4 * qa * qc
    if disc < 0 then return nil end
    local root = math.sqrt(disc)
    for _, t in ipairs({(-qb - root) / (2 * qa), (-qb + root) / (2 * qa)}) do
        if t >= 0 and t <= 1 then return {x = a.x + t * dx, z = a.z + t * dz} end
    end
    return nil
end

-- Stykket a->b klippet til cirklen, eller nil hvis det ligger helt udenfor.
local function clipToCircle(a, b, center, radius)
    local aIn, bIn = inside(a, center, radius), inside(b, center, radius)
    if aIn and bIn then return {a = a, b = b} end
    if aIn then return {a = a, b = circleCrossing(b, a, center, radius) or b} end
    if bIn then return {a = circleCrossing(a, b, center, radius) or a, b = b} end
    local first = circleCrossing(a, b, center, radius)
    local second = circleCrossing(b, a, center, radius)
    if first ~= nil and second ~= nil then return {a = first, b = second} end
    return nil
end

local function samePoint(p, q) return dist(p, q) <= CHAIN_EPS end

-- Følger kæden bagud fra kanten (forgængere, den mest lige ved forgrening) og returnerer punkterne
-- fra langt ude til kantens slutpunkt.
local function chainBackward(edges, edge, maxLength)
    local points = {edge.b, edge.a}
    local current, length = edge, dist(edge.a, edge.b)
    while length < maxLength do
        local best, bestTurn = nil, nil
        local heading = headingOf(current.a, current.b)
        for _, candidate in ipairs(edges) do
            if candidate ~= current and samePoint(candidate.b, current.a) and not samePoint(candidate.a, current.b) then
                local turn = angleDiff(headingOf(candidate.a, candidate.b), heading)
                if bestTurn == nil or turn < bestTurn then best, bestTurn = candidate, turn end
            end
        end
        if best == nil then break end
        table.insert(points, best.a)
        length = length + dist(best.a, best.b)
        current = best
    end
    local ordered = {}
    for i = #points, 1, -1 do table.insert(ordered, points[i]) end
    return ordered
end

-- Følger kæden fremad (efterfølgere, den mest lige) fra kantens startpunkt.
local function chainForward(edges, edge, maxLength)
    local points = {edge.a, edge.b}
    local current, length = edge, dist(edge.a, edge.b)
    while length < maxLength do
        local best, bestTurn = nil, nil
        local heading = headingOf(current.a, current.b)
        for _, candidate in ipairs(edges) do
            if candidate ~= current and samePoint(candidate.a, current.b) and not samePoint(candidate.b, current.a) then
                local turn = angleDiff(headingOf(candidate.a, candidate.b), heading)
                if bestTurn == nil or turn < bestTurn then best, bestTurn = candidate, turn end
            end
        end
        if best == nil then break end
        table.insert(points, best.b)
        length = length + dist(best.a, best.b)
        current = best
    end
    return points
end

local function sortedByBearing(list, center, pointKey)
    table.sort(list, function(p, q)
        local bp = headingOf(center, p[pointKey]) % (2 * math.pi)
        local bq = headingOf(center, q[pointKey]) % (2 * math.pi)
        if bp == bq then return p.heading < q.heading end
        return bp < bq
    end)
    for i, item in ipairs(list) do item.id = i end
    return list
end

local function alreadyMerged(list, heading, point, pointKey)
    local tolerance = degToRad(TLConfig.OVERRIDE_ANGLE_DEG)
    for _, item in ipairs(list) do
        if angleDiff(item.heading, heading) <= tolerance and dist(item[pointKey], point) <= MERGE_ENTRY_M then
            return true
        end
    end
    return false
end

-- Hver AD-vognbane, der krydser cirklen indad, er sin egen indkørsel med egen stoplinje — også når den
-- kommer ind 1 m eller mere ved siden af en anden i samme retning (et højresvingsspor). Kæder oven i
-- hinanden (< SAME_LANE_M) er samme vognbane.
local SAME_LANE_M = 0.5 -- to AD-kæder, der kommer ind så tæt i samme retning, er samme vognbane

local function addApproach(approaches, edges, edge, entry, innerEnd, center, radius)
    local heading = headingOf(edge.a, edge.b)
    -- AD har ofte to kæder oven i hinanden (ligeud + sving, der først deler sig i krydset): det er én
    -- vognbane og én stoplinje (in-game 25/10: to lys oven i hinanden, der skiftedes til at have grønt)
    local tolerance = degToRad(TLConfig.OVERRIDE_ANGLE_DEG)
    for _, existing in ipairs(approaches) do
        if angleDiff(existing.heading, heading) <= tolerance and dist(existing.entry, entry) < SAME_LANE_M then return end
    end
    local back = chainBackward(edges, edge, PATH_BACK_M)
    local path = {}
    for i = 1, #back - 1 do table.insert(path, back[i]) end
    table.insert(path, entry)
    if innerEnd ~= nil then
        table.insert(path, innerEnd) -- lang kant tværs over cirklen
    else
        local forward = chainForward(edges, edge, radius)
        for i = 2, #forward do
            if inside(forward[i], center, radius) then table.insert(path, forward[i]) end
        end
    end
    table.insert(approaches, {heading = heading, entry = entry, path = path, lanes = {{kind = "AD"}},
        enabled = true, internal = false})
end

local function addExit(exits, edges, edge, exitPoint)
    local heading = headingOf(edge.a, edge.b)
    if alreadyMerged(exits, heading, exitPoint, "exitPoint") then return end
    local forward = chainForward(edges, edge, PATH_BACK_M)
    local path = {exitPoint}
    for i = 2, #forward do table.insert(path, forward[i]) end
    table.insert(exits, {heading = heading, exitPoint = exitPoint, path = path})
end

-- approach.path løber fra langt ude, gennem entry og videre ind i cirklen (indre stykke); afstande til
-- stoplinjen måles med TLGeometry.alongPath(path, p, stopLine).
function TLGeometry.findApproaches(center, radius, edges)
    local approaches, exits = {}, {}
    for _, edge in ipairs(edges or {}) do
        local aIn, bIn = inside(edge.a, center, radius), inside(edge.b, center, radius)
        if not aIn and bIn then
            local entry = circleCrossing(edge.a, edge.b, center, radius)
            if entry ~= nil then addApproach(approaches, edges, edge, entry, nil, center, radius) end
        elseif aIn and not bIn then
            local exitPoint = circleCrossing(edge.b, edge.a, center, radius)
            if exitPoint ~= nil then addExit(exits, edges, edge, exitPoint) end
        elseif not aIn and not bIn then
            -- lang kant (AD-editorens lange forbindelser) tværs over hele cirklen: både ind og ud
            local entry = circleCrossing(edge.a, edge.b, center, radius)
            local exitPoint = circleCrossing(edge.b, edge.a, center, radius)
            if entry ~= nil and exitPoint ~= nil and dist(entry, exitPoint) > CHAIN_EPS then
                addApproach(approaches, edges, edge, entry, exitPoint, center, radius)
                addExit(exits, edges, edge, exitPoint)
            end
        end
    end
    sortedByBearing(approaches, center, "entry")
    sortedByBearing(exits, center, "exitPoint")
    if #approaches > 0 then
        -- køretøjer, der starter inde i krydset (gårdsplads), venter på deres tur her (spec 5.12)
        table.insert(approaches, {id = INTERNAL_ID, heading = 0, entry = {x = center.x, z = center.z}, path = {},
            lanes = {}, enabled = true, internal = true})
    end
    return approaches, exits
end

function TLGeometry.conflictZone(intersection, edges)
    local segments = {}
    for _, edge in ipairs(edges or {}) do
        local clipped = clipToCircle(edge.a, edge.b, intersection.center, intersection.radius)
        if clipped ~= nil then table.insert(segments, clipped) end
    end
    return {segments = segments, halfWidth = TLConfig.SWEEP_HALF_WIDTH}
end

local function segmentsIntersect(a, b, c, d)
    local function cross(o, p, q) return (p.x - o.x) * (q.z - o.z) - (p.z - o.z) * (q.x - o.x) end
    local d1, d2 = cross(c, d, a), cross(c, d, b)
    local d3, d4 = cross(a, b, c), cross(a, b, d)
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
end

local function segmentDistance(s, t)
    if segmentsIntersect(s.a, s.b, t.a, t.b) then return 0 end
    return math.min(pointSegmentDistance(s.a, t.a, t.b), pointSegmentDistance(s.b, t.a, t.b),
        pointSegmentDistance(t.a, s.a, s.b), pointSegmentDistance(t.b, s.a, s.b))
end

-- Krydsningskernen: kun de stykker af zonen, der ligger tæt på et stykke i en ANDEN retning (ikke
-- parallel eller modsat). Vejstykker ude i cirklens kant hører ikke med — et køretøj dér (fx en
-- Courseplay-traktor i markkanten) må ikke holde krydset optaget (in-game 25/10).
function TLGeometry.conflictCore(zone)
    local tolerance = degToRad(TLConfig.OVERRIDE_ANGLE_DEG)
    local reach = 2 * zone.halfWidth + CORE_MARGIN_M
    local core = {}
    for _, s in ipairs(zone.segments) do
        local hs = headingOf(s.a, s.b)
        for _, t in ipairs(zone.segments) do
            if t ~= s then
                local ht = headingOf(t.a, t.b)
                local parallel = angleDiff(hs, ht) <= tolerance or angleDiff(hs, ht + math.pi) <= tolerance
                if not parallel and segmentDistance(s, t) <= reach then
                    table.insert(core, s)
                    break
                end
            end
        end
    end
    return {segments = core, halfWidth = zone.halfWidth}
end

-- Afstand fra p til zonens kant (negativ = inde i zonen). excludeFn(segment) springer stykker over.
local function zoneClearance(zone, p, excludeFn)
    local best = math.huge
    for _, segment in ipairs(zone.segments) do
        if excludeFn == nil or not excludeFn(segment) then
            best = math.min(best, pointSegmentDistance(p, segment.a, segment.b) - zone.halfWidth)
        end
    end
    return best
end

function TLGeometry.pointInZone(zone, p)
    return zoneClearance(zone, p, nil) <= 0
end

-- Stykker i indkørslens egen vejkorridor: parallelle (samme/modsat retning) og tæt på dens linje.
local function corridorFilter(approach)
    local tolerance = degToRad(TLConfig.OVERRIDE_ANGLE_DEG)
    local hx, hz = math.cos(approach.heading), math.sin(approach.heading)
    return function(segment)
        local heading = headingOf(segment.a, segment.b)
        local parallel = angleDiff(heading, approach.heading) <= tolerance
            or angleDiff(heading, approach.heading + math.pi) <= tolerance
        if not parallel then return false end
        local mid = {x = (segment.a.x + segment.b.x) / 2, z = (segment.a.z + segment.b.z) / 2}
        local lateral = math.abs((mid.x - approach.entry.x) * hz - (mid.z - approach.entry.z) * hx)
        return lateral <= CORRIDOR_LATERAL_M
    end
end

-- Punkter langs stien med fast afstand, fra stiens start (langt ude) mod krydset.
local function samplePath(path)
    local samples = {}
    for i = 1, #path - 1 do
        local a, b = path[i], path[i + 1]
        local length = dist(a, b)
        local steps = math.max(1, math.ceil(length / SAMPLE_M))
        for step = 0, steps - 1 do
            local t = step / steps
            table.insert(samples, {x = a.x + t * (b.x - a.x), z = a.z + t * (b.z - a.z)})
        end
    end
    if #path > 0 then table.insert(samples, path[#path]) end
    return samples
end

-- Afstand langs stien fra p's projektion til punktet target på stien (positiv = p ligger før target).
local function alongPath(path, p, target)
    local walked, pAt, targetAt = 0, nil, nil
    local pBest, targetBest = math.huge, math.huge
    for i = 1, #path - 1 do
        local a, b = path[i], path[i + 1]
        local length = dist(a, b)
        local dx, dz = b.x - a.x, b.z - a.z
        for _, item in ipairs({{point = p, kind = "p"}, {point = target, kind = "t"}}) do
            local t = length > 0 and math.max(0, math.min(1, ((item.point.x - a.x) * dx + (item.point.z - a.z) * dz) / (length * length))) or 0
            local d = dist(item.point, {x = a.x + t * dx, z = a.z + t * dz})
            if item.kind == "p" and d < pBest then pBest, pAt = d, walked + t * length end
            if item.kind == "t" and d < targetBest then targetBest, targetAt = d, walked + t * length end
        end
        walked = walked + length
    end
    if pAt == nil or targetAt == nil then return nil end
    return targetAt - pAt
end

-- Stoplinjen: søg fra entry og indad til første konflikt; stoplinjen er sidste frie punkt før den.
-- Er allerede entry i konflikt, søges udad fra entry til første frie punkt (aldrig ude fra og ind:
-- en vej, der længere ude passerer tæt forbi zonen, må ikke trække stoplinjen derud — review).
-- conflict = false: indkørslen krydser ingen andres svingområde og behøver ikke lys (spec 5.12).
-- Aldrig holde på jernbanen (in-game 25/10: stoplinjen lå midt i en overkørsel): linjen og køen bag den
-- (RAIL_QUEUE_M, ét vogntog) skal være mindst RAIL_CLEAR_M fra skinnerne, ellers rykkes linjen bagud.
TLGeometry.RAIL_CLEAR_M = 4
TLGeometry.RAIL_QUEUE_M = 20

local function nearRail(p, rails)
    for _, segment in ipairs(rails) do
        if TLGeometry.pointSegmentDistance(p, segment.a, segment.b) < TLGeometry.RAIL_CLEAR_M then return true end
    end
    return false
end

-- Første indeks k <= start, hvor stien fra k og RAIL_QUEUE_M bagud er fri af skinnerne.
local function clearOfRails(samples, start, rails)
    if rails == nil or #rails == 0 then return start end
    local window = math.ceil(TLGeometry.RAIL_QUEUE_M / SAMPLE_M)
    local k = start
    while k >= 1 do
        local blocked = nil
        for i = k, math.max(1, k - window), -1 do
            if nearRail(samples[i], rails) then blocked = i break end
        end
        if blocked == nil then return k end
        k = blocked - 1 -- forbi skinnerne og videre bagud
    end
    return start -- skinnerne følger hele vejen: behold linjen hellere end at sende den ud af kortet
end

function TLGeometry.placeStopLine(approach, zone, rails)
    local need = TLConfig.STOP_MARGIN
    local exclude = corridorFilter(approach)
    local samples = samplePath(approach.path)
    local entryIndex, entryBest = 1, math.huge
    for i, sample in ipairs(samples) do
        local d = dist(sample, approach.entry)
        if d < entryBest then entryIndex, entryBest = i, d end
    end
    local function clear(i) return zoneClearance(zone, samples[i], exclude) >= need end
    local index, conflict = nil, false
    for i = entryIndex, #samples do
        if not clear(i) then
            conflict = true
            if i > entryIndex then index = i - 1 end
            break
        end
    end
    if conflict and index == nil then
        for i = entryIndex - 1, 1, -1 do
            if clear(i) then index = i break end
        end
        -- ingen plads nok nogen steder (lille kryds): indgangen i cirklen — aldrig vejens yderste ende
        -- 100 m ude, hvor ingen holdes (review)
        index = index or entryIndex
    end
    local point, heading = approach.entry, approach.heading
    if index ~= nil then
        index = clearOfRails(samples, index, rails)
        point = samples[index]
        -- vognbanens retning ved linjen (master og lyshoveder vendes efter den; approach.heading er retningen
        -- ved cirklen og kan være skæv, når AD-spor løber sammen — in-game 25/10)
        local a, b = samples[math.max(1, index - 4)], samples[math.min(#samples, index + 4)]
        if dist(a, b) > 0.5 then heading = headingOf(a, b) end
    end
    return {x = point.x, z = point.z, heading = heading, back = alongPath(approach.path, point, approach.entry) or 0,
        conflict = conflict}
end

local function minDistanceToPath(path, p)
    local best = math.huge
    for i = 1, #path - 1 do best = math.min(best, pointSegmentDistance(p, path[i], path[i + 1])) end
    return best
end

-- Spillerens justering (spec 5.8): stoplinjen flyttet shift meter langs indkørslens vej (+ = længere ud,
-- - = frem mod krydset), klemt til vejens ender. Retning og back regnes på det nye sted.
function TLGeometry.shiftStopLine(approach, stopLine, shift)
    local samples = samplePath(approach.path)
    if #samples == 0 then return stopLine end
    local index, best = 1, math.huge
    for i, sample in ipairs(samples) do
        local d = dist(sample, stopLine)
        if d < best then index, best = i, d end
    end
    index = math.max(1, math.min(#samples, index - math.floor(shift / SAMPLE_M + 0.5)))
    local point = samples[index]
    local heading = stopLine.heading or approach.heading
    local a, b = samples[math.max(1, index - 4)], samples[math.min(#samples, index + 4)]
    if dist(a, b) > 0.5 then heading = headingOf(a, b) end
    return {x = point.x, z = point.z, heading = heading, back = alongPath(approach.path, point, approach.entry) or 0,
        conflict = stopLine.conflict}
end

-- Kun indkørsler med en AD-vej kan justeres: dem, der kun er et trafikspor (mergeLane), opstår først efter
-- justeringerne er lagt på, så en justering af dem ville aldrig finde dem igen (review H2).
function TLGeometry.hasADLane(approach)
    for _, lane in ipairs(approach.lanes or {}) do
        if lane.kind == "AD" then return true end
    end
    return false
end

-- Spillerens ene ændring (spec 5.8): ny liste (input ændres ikke). approach = den valgte indkørsel (med
-- overrideIndex, hvis den allerede er justeret) eller nil for "forældede"; action = "back"|"forward"|"toggle"|"reset";
-- limits = {step, min, max}. En ny justering bindes til den automatiske linje (approach.stopLine uden justering).
-- En justering på 0 m og med lys gør intet og fjernes. Forældede (staleIndices) slettes kun med "reset".
function TLGeometry.adjustOverrides(overrides, approach, staleIndices, action, limits)
    local result = {}
    if approach == nil then
        if action ~= "reset" then
            for _, override in ipairs(overrides) do table.insert(result, override) end
            return result
        end
        local stale = {}
        for _, index in ipairs(staleIndices or {}) do stale[index] = true end
        for index, override in ipairs(overrides) do if not stale[index] then table.insert(result, override) end end
        return result
    end
    local index = approach.overrideIndex
    local current = index ~= nil and overrides[index] or nil
    local changed = nil
    if action ~= "reset" then
        changed = current ~= nil and {heading = current.heading, stopPos = current.stopPos, shift = current.shift or 0,
            enabled = current.enabled ~= false}
            or {heading = approach.heading, stopPos = {x = approach.stopLine.x, z = approach.stopLine.z}, shift = 0, enabled = true}
        if action == "back" then changed.shift = math.min(limits.max, changed.shift + limits.step)
        elseif action == "forward" then changed.shift = math.max(limits.min, changed.shift - limits.step)
        elseif action == "toggle" then changed.enabled = not changed.enabled end
        if changed.shift == 0 and changed.enabled then changed = nil end
    end
    for i, override in ipairs(overrides) do
        if i ~= index then table.insert(result, override) elseif changed ~= nil then table.insert(result, changed) end
    end
    if current == nil and changed ~= nil then table.insert(result, changed) end
    return result
end

-- Lægger justeringerne på de automatisk fundne indkørsler (kopier; input ændres ikke). Hver justering finder
-- sin indkørsel ud fra retning og den automatiske linjes plads (matchOverride). Returnerer de nye indkørsler og
-- indeks på justeringer uden indkørsel ("forældet" — AD-nettet er ændret; de gemmes stadig).
function TLGeometry.applyOverrides(approaches, overrides)
    local byId = {}
    local stale = {}
    for index, override in ipairs(overrides or {}) do
        local id = TLGeometry.matchOverride(override, approaches)
        if id ~= nil and byId[id] == nil then byId[id] = index else table.insert(stale, index) end
    end
    local result = {}
    for _, approach in ipairs(approaches) do
        local index = byId[approach.id]
        if index == nil then
            table.insert(result, approach)
        else
            local override = overrides[index]
            local copy = {}
            for key, value in pairs(approach) do copy[key] = value end
            copy.overrideIndex = index
            if (override.shift or 0) ~= 0 then copy.stopLine = TLGeometry.shiftStopLine(approach, approach.stopLine, override.shift) end
            if override.enabled == false then copy.enabled = false end
            table.insert(result, copy)
        end
    end
    return result, stale
end

-- Trafiksporet lægges i den NÆRMESTE indkørsel i samme retning (to vognbaner kan ligge 1-2 m fra
-- hinanden — review), og aldrig to gange (samme splineId). Matcher ingen, bliver det en ny indkørsel.
function TLGeometry.mergeLane(approaches, lane)
    local tolerance = degToRad(TLConfig.OVERRIDE_ANGLE_DEG)
    local bestIndex, bestDistance, maxId = nil, nil, 0
    for i, approach in ipairs(approaches) do
        maxId = math.max(maxId, approach.id or 0)
        for _, existing in ipairs(approach.lanes or {}) do
            if existing.kind == "TRAFFIC" and existing.splineId == lane.splineId then
                -- allerede tilknyttet: uændret liste (kopier, så input ikke muteres)
                local copy = {}
                for j, a in ipairs(approaches) do copy[j] = a end
                return copy
            end
        end
        if not approach.internal and angleDiff(approach.heading, lane.heading) <= tolerance then
            local d = minDistanceToPath(approach.path, lane.pos)
            if d <= MERGE_ENTRY_M and (bestDistance == nil or d < bestDistance) then bestIndex, bestDistance = i, d end
        end
    end
    local result = {}
    for i, approach in ipairs(approaches) do
        if i == bestIndex then
            local copy = {}
            for key, value in pairs(approach) do copy[key] = value end
            local lanes = {}
            for _, existing in ipairs(approach.lanes or {}) do table.insert(lanes, existing) end
            table.insert(lanes, {kind = "TRAFFIC", splineId = lane.splineId, splineTime = lane.splineTime})
            copy.lanes = lanes
            table.insert(result, copy)
        else
            table.insert(result, approach)
        end
    end
    if bestIndex == nil then
        local hx, hz = math.cos(lane.heading), math.sin(lane.heading)
        local start = {x = lane.pos.x - hx * TLConfig.DEMAND_DISTANCE, z = lane.pos.z - hz * TLConfig.DEMAND_DISTANCE}
        -- ny indkørsel kun fra trafiksporet: stoplinjen er søgepunktet (ellers ingen efterspørgsel og
        -- spærret for altid — review)
        table.insert(result, {id = maxId + 1, heading = lane.heading, entry = {x = lane.pos.x, z = lane.pos.z},
            stopLine = {x = lane.pos.x, z = lane.pos.z, back = 0, conflict = true},
            path = {start, {x = lane.pos.x, z = lane.pos.z}},
            lanes = {{kind = "TRAFFIC", splineId = lane.splineId, splineTime = lane.splineTime}},
            enabled = true, internal = false})
    end
    return result
end

-- Den NÆRMESTE indkørsel inden for tolerancerne (to nære vognbaner i samme retning — review).
function TLGeometry.matchOverride(override, approaches)
    local tolerance = degToRad(TLConfig.OVERRIDE_ANGLE_DEG)
    local bestId, bestDistance = nil, nil
    for _, approach in ipairs(approaches) do
        if not approach.internal and approach.stopLine ~= nil and angleDiff(approach.heading, override.heading) <= tolerance then
            local d = dist(approach.stopLine, override.stopPos)
            if d <= TLConfig.OVERRIDE_POS_M and (bestDistance == nil or d < bestDistance) then bestId, bestDistance = approach.id, d end
        end
    end
    return bestId
end

local SNAP_EXTENT_FACTOR = 0.6 -- kæden må højst nå så langt fra den nærmeste krydsning (ikke ind i nabokrydset — review)
local SNAP_CLUSTER_M = 12 -- krydsningspunkter så tæt på det nærmeste hører til samme kryds

-- Skæringspunktet mellem to stykker (endepunkter inklusive), eller nil.
local function segmentCrossing(s, t)
    local rx, rz = s.b.x - s.a.x, s.b.z - s.a.z
    local qx, qz = t.b.x - t.a.x, t.b.z - t.a.z
    local denom = rx * qz - rz * qx
    if math.abs(denom) < 1e-9 then return nil end
    local wx, wz = t.a.x - s.a.x, t.a.z - s.a.z
    local u = (wx * qz - wz * qx) / denom
    local v = (wx * rz - wz * rx) / denom
    if u < 0 or u > 1 or v < 0 or v > 1 then return nil end
    return {x = s.a.x + u * rx, z = s.a.z + u * rz}
end

local function pointKey(p) return string.format("%d:%d", math.floor(p.x * 10 + 0.5), math.floor(p.z * 10 + 0.5)) end

-- Antal forskellige nabopunkter pr. vejpunkt (AD's tovejsforbindelser giver både a->b og b->a).
local function neighbourCounts(segments)
    local neighbours = {}
    local function add(p, q)
        local key = pointKey(p)
        neighbours[key] = neighbours[key] or {}
        neighbours[key][pointKey(q)] = true
    end
    for _, segment in ipairs(segments) do
        add(segment.a, segment.b)
        add(segment.b, segment.a)
    end
    local counts = {}
    for key, set in pairs(neighbours) do
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        counts[key] = n
    end
    return counts
end

local function sharedEndpoint(s, t)
    for _, p in ipairs({s.a, s.b}) do
        for _, q in ipairs({t.a, t.b}) do
            if samePoint(p, q) then return p end
        end
    end
    return nil
end

-- Krydsets rigtige midte ud fra hvor bygningen (styreboksen) står: midten af de AD-krydsninger (vognbaner
-- i forskellig retning, der skærer hinanden), der hænger sammen med den nærmeste. Styreboksen står på
-- hjørnet, ikke i vejen. Et knæk i én vej (fælles punkt med kun 2 naboer) er ikke en krydsning (review).
-- Ingen krydsninger inden for radius: placeringen selv. Returnerer center, fundet.
local function crossingCluster(placement, around, radius, edges)
    local zone = TLGeometry.conflictZone({center = around, radius = radius}, edges)
    local tolerance = degToRad(TLConfig.OVERRIDE_ANGLE_DEG)
    local segments = zone.segments
    local counts = neighbourCounts(segments)
    local points = {}
    for i = 1, #segments do
        local s = segments[i]
        local hs = headingOf(s.a, s.b)
        for j = i + 1, #segments do
            local t = segments[j]
            local ht = headingOf(t.a, t.b)
            local parallel = angleDiff(hs, ht) <= tolerance or angleDiff(hs, ht + math.pi) <= tolerance
            local point = not parallel and segmentCrossing(s, t) or nil
            local shared = point ~= nil and sharedEndpoint(s, t) or nil
            if shared ~= nil and (counts[pointKey(shared)] or 0) < 3 then point = nil end
            if point ~= nil then table.insert(points, point) end
        end
    end
    if #points == 0 then return nil end
    local nearest = 1
    for i, point in ipairs(points) do
        if dist(point, placement) < dist(points[nearest], placement) then nearest = i end
    end
    -- alle krydsninger, der hænger sammen med den nærmeste (kæder af afstande <= SNAP_CLUSTER_M): et bredt
    -- kryds' fjerne hjørner kommer med, så midten ikke trækkes mod boksen (review)
    local inCluster, queue = {[nearest] = true}, {nearest}
    while #queue > 0 do
        local current = table.remove(queue)
        for i, point in ipairs(points) do
            if not inCluster[i] and dist(point, points[current]) <= SNAP_CLUSTER_M
                and dist(point, points[nearest]) <= radius * SNAP_EXTENT_FACTOR then
                inCluster[i] = true
                table.insert(queue, i)
            end
        end
    end
    local sumX, sumZ, count = 0, 0, 0
    for i in pairs(inCluster) do
        sumX, sumZ, count = sumX + points[i].x, sumZ + points[i].z, count + 1
    end
    return {x = sumX / count, z = sumZ / count}
end

local SNAP_PASSES = 3

function TLGeometry.snapCenter(placement, radius, edges)
    -- første søgning i cirklen om boksen; derefter om det fundne kryds, så et bredt kryds' fjerne side
    -- (uden for cirklen om boksen på hjørnet) også kommer med
    local center = crossingCluster(placement, placement, radius, edges)
    if center == nil then return {x = placement.x, z = placement.z}, false end
    for _ = 2, SNAP_PASSES do
        local nextCenter = crossingCluster(placement, center, radius, edges)
        if nextCenter == nil or dist(nextCenter, center) < 0.1 then break end
        center = nextCenter
    end
    return center, true
end

-- Plads til EU-masten ved stoplinjen: højre vejkant (side 1) ved linjen, ellers op til MAST_BACK_M bagud
-- langs indkørslen, ellers venstre vejkant (side -1) på samme måde. Den første plads med mindst clearance
-- til alle forhindringer (skinner, andre veje — segmenter {a, b}) vælges; er alt spærret, den med størst
-- afstand (in-game 25/10: masten stod midt på jernbanen).
local MAST_BACK_M, MAST_BACK_STEP_M = 10, 2

local function obstacleClearance(p, obstacles)
    local best = math.huge
    for _, segment in ipairs(obstacles) do
        best = math.min(best, TLGeometry.pointSegmentDistance(p, segment.a, segment.b))
    end
    return best
end

function TLGeometry.pickMastSpot(stop, heading, sideOffset, obstacles, clearance)
    local dx, dz = math.cos(heading), math.sin(heading)
    local rightX, rightZ = -dz, dx
    local best, bestClearance = nil, -math.huge
    for _, side in ipairs({1, -1}) do
        for back = 0, MAST_BACK_M, MAST_BACK_STEP_M do
            local spot = {x = stop.x - dx * back + rightX * sideOffset * side,
                z = stop.z - dz * back + rightZ * sideOffset * side, side = side}
            local free = obstacleClearance(spot, obstacles)
            if free >= clearance then return spot end
            if free > bestClearance then best, bestClearance = spot, free end
        end
    end
    return best
end

-- US-wiren fra p1 til p2: afstand fra p1 til det sted, hvor ruten (set udefra) første gang krydser wiren,
-- eller nil. Hovedet hænger dér, over sin egen vognbane (in-game 25/10: hoveder over græsset). Ender ruten
-- før wiren (indkørslens rute stopper ved AD's første forgrening), forlænges sidste stykke ligeud.
local WIRE_EXTEND_M = 40

function TLGeometry.wireCrossing(p1, p2, path)
    local wire = {a = p1, b = p2}
    local count = #(path or {})
    for i = 1, count - 1 do
        local hit = segmentCrossing(wire, {a = path[i], b = path[i + 1]})
        if hit ~= nil then return dist(p1, hit) end
    end
    if count < 2 then return nil end
    local last, before = path[count], path[count - 1]
    local length = dist(before, last)
    if length < 1e-6 then return nil end
    local tip = {x = last.x + (last.x - before.x) / length * WIRE_EXTEND_M,
        z = last.z + (last.z - before.z) / length * WIRE_EXTEND_M}
    local hit = segmentCrossing(wire, {a = last, b = tip})
    return hit ~= nil and dist(p1, hit) or nil
end

-- To indkørsler, hvis stoplinjer ender samme sted i samme retning, er én vognbane: AD-sporene løb sammen
-- før linjen (in-game 25/10: spor 3 og 4 viste rødt og grønt på samme sted). Den første beholdes og får lys,
-- hvis bare én af dem havde konflikt. Et højresvingsspor med sin egen linje ved siden af bevares.
local SHARED_STOP_M = 2
-- retningen måles, hvor sporet krydser cirklen; sammenløbende spor kan dér afvige en del, så vinklen skal
-- kun holde modsatrettede baner adskilt (in-game 25/10: 20° var for lidt)
local SHARED_STOP_ANGLE_DEG = 60

function TLGeometry.mergeSharedStopLines(approaches)
    local tolerance = degToRad(SHARED_STOP_ANGLE_DEG)
    local result = {}
    for _, approach in ipairs(approaches) do
        local twin = nil
        if not approach.internal and approach.stopLine ~= nil then
            for _, kept in ipairs(result) do
                if not kept.internal and kept.stopLine ~= nil and angleDiff(kept.heading, approach.heading) <= tolerance
                    and dist(kept.stopLine, approach.stopLine) < SHARED_STOP_M then
                    twin = kept
                    break
                end
            end
        end
        if twin == nil then
            table.insert(result, approach)
        elseif approach.enabled and not twin.enabled then
            -- kopi, så input ikke ændres
            local copy = {}
            for key, value in pairs(twin) do copy[key] = value end
            copy.enabled = true
            for i, kept in ipairs(result) do if kept == twin then result[i] = copy end end
        end
    end
    return result
end

function TLGeometry.circlesOverlap(c1, r1, c2, r2)
    return dist(c1, c2) < r1 + r2
end

TLGeometry.INTERNAL_ID = INTERNAL_ID
TLGeometry.alongPath = alongPath
TLGeometry.zoneClearance = function(zone, p) return zoneClearance(zone, p, nil) end
-- Afstand til zonen uden stykker i køretøjets egen vejkorridor (køreretning heading gennem p): bruges til
-- at afgøre, om et køretøj er ude af krydset, når det kører ud ad sin egen vej.
TLGeometry.crossingClearance = function(zone, p, heading)
    return zoneClearance(zone, p, corridorFilter({heading = heading, entry = p}))
end
TLGeometry.angleDiff = angleDiff
TLGeometry.pointSegmentDistance = pointSegmentDistance
