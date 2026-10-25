-- Synlige lyskurve (spec 5.2, Task 9). Bygger på spillets egne modeller via $data (ModHub-sikkert) og
-- indlæses UDEN fysik, så masterne har ingen kollision. EU = armmast pr. indkørsel; US = hoveder i en wire.
--   mast:   $data/maps/mapUS/textures/props/trafficLight.i3d (brugerens valg 25/10: amerikansk mast uden skilte).
--           Filen har fire dele på øverste niveau: stander, topstykke og to lyshoveder på en arm langs lokal +x.
--   lamper: $data/maps/mapAS/textures/trafficLights.i3d — rød/gul/grøn glødelamper (glowShader, shader-
--           parameter "lightControl" + en punktlyskilde som barn). De tre farver deler ét omdrejningspunkt;
--           lampernes indbyrdes placering ligger i geometrien (vandret langs lokal z). Den amerikanske mast har
--           ingen lamper, så de sættes ind i hvert lyshoved, drejet lodret (rød øverst).
-- Lampernes placering i hovedet og mastens drejning finjusteres i spillet med tlLamp / tlMastYaw
-- (TLVisuals.tuning) og skrives derefter fast her.
TLVisuals = {}

local MAST_FILE = "$data/maps/mapUS/textures/props/trafficLight.i3d"
local MAST_PARTS = {"trafficLightBase", "trafficLighToptLight", "trafficLight01", "trafficLight02"}
local TOP_LAMP_PART = "trafficLighToptLight"
local MAST_BASE_PART = "trafficLightBase"
local HEAD_PARTS = {trafficLight01 = true, trafficLight02 = true}
local LAMP_FILE = "$data/maps/mapAS/textures/trafficLights.i3d"
-- amerikansk udgave (brugerens ønske 25/10): lyshoveder hængende i en wire diagonalt over krydset mellem to træmaster
local POLE_FILE = "$data/maps/mapUS/textures/props/utilityPoles.i3d"
local WIRE_PART = "utilityPole07"   -- wiren: denne glatte træmasts LOD0 lagt ned og skaleret tynd (02 havde tværarme)
-- masterne til wiren kan skiftes i spillet med tlPole (brugerens ønske 25/10: andre master end elmasten)
local POLE_CHOICES = {
    {file = POLE_FILE, part = "utilityPole01"}, {file = POLE_FILE, part = "utilityPole02"},
    {file = POLE_FILE, part = "utilityPole03"}, {file = POLE_FILE, part = "utilityPole04"},
    {file = POLE_FILE, part = "utilityPole05"}, {file = POLE_FILE, part = "utilityPole06"},
    {file = POLE_FILE, part = "utilityPole07"},
    {file = MAST_FILE, part = "trafficLightBase"},
    {file = "$data/maps/mapUS/textures/props/publicLightSet/publicLigh01.i3d", part = "publicLight01"},
    {file = "$data/maps/mapUS/textures/props/publicLightSet/publicLigh02.i3d", part = "publicLight02"},
    {file = "$data/maps/mapUS/textures/props/publicLightSet/publicLigh03.i3d", part = "publicLight03"},
}
local SPAN_HEAD_PART = "trafficLight01"  -- hovedet med 3 linser
local POLE_CLEAR_M = 4          -- masterne står så langt ud over den fjerneste stoplinje
-- wiren passer kun til samlede kryds: ligger en stoplinje længere ude, får US-krydset master pr. indkørsel
-- (in-game 25/10, Riverbend: 5 spredte indkørsler, én over jernbanen — hovederne hang langt fra linjerne)
local SPAN_MAX_STOP_M = 20
local HEAD_SPACING_M = 1.4      -- mindste afstand mellem hovederne i wiren
local SIDE_OFFSET_M = 3.5       -- masten står så langt til højre for vognbanens midte
local MAST_CLEARANCE_M = 2.5    -- mindste afstand fra en mast til skinner og andre veje i krydset
local RAIL_SAMPLE_M = 2         -- skinnernes spline læses som punkter med denne afstand
local LIGHT_ON = 5.5            -- glowShader-intensitet (materialets egen værdi i mapAS)
local FLASH_PERIOD_MS = 1000
local LOG_PREFIX = "[TrafficLights] "

-- lamper i forhold til hvert lyshoved (tlLamp, m og grader) og ekstra drejning af masten (tlMastYaw); startgæt
-- In-game 25/10 (0.4.0): linserne vendte RIGTIGT mod trafikken, men lamperne sad på bagsiden af hovedet og
-- under det -> lamperne sidder i en holder, der er drejet lampYawDeg om hovedets akse (forsiden), og løftes
-- op ud for armen (midterste linse). headYawDeg drejer hele hovedet (0 = som i modellen).
-- Fundet in-game 25/10 13:28 med tlHeadYaw/tlLamp/tlTopLampYaw; lampScale gør lysskiverne lidt mindre end linserne.
TLVisuals.tuning = {lamp = {0, 0.0, -0.38}, lampRot = {-90, 90, 0}, lampScale = 0.8, mastYawDeg = 0, headYawDeg = 180,
    armScale = 0.75,
    -- EU-mastens højde (1 = original, armen i ca. 4,4 m): in-game 25/10 kunne en traktor dårligt køre under armen
    mastHeight = 1.35,
    lampYawDeg = 180, topLampYawDeg = 270,
    -- wire (US): højde over terræn ved masterne, hovedets ophæng under wiren, wirens tykkelse (skala af mastens
    -- tværsnit), drejning der lægger mastemodellen ned langs wiren, hvor langt ud mod sin indkørsel hvert hoved hænger
    span = {wireY = 6.5, headDrop = 0.6, thickness = 0.12, rotX = 90, headBack = 2.5, poleYaw = 0, pole = 7, hang = {0, -0.14}}}

-- Alle togbaners skinner som segmenter {a, b}, læst én gang pr. savegame (skinnerne flytter sig ikke);
-- nulstilles i releaseAssets, derfor erklæret her over den (review).
local railSegments = nil
local assets = nil              -- {parts = {name -> node}, red, amber, green, roots, requests, ok}

local function findByName(node, name)
    if getName(node) == name then return node end
    for i = 0, getNumOfChildren(node) - 1 do
        local found = findByName(getChildAt(node, i), name)
        if found ~= nil then return found end
    end
    return nil
end

-- Første glødelampe (Shape) under en farvegruppe som "road01_A_RED".
local function firstShapeUnder(root, groupName)
    local group = findByName(root, groupName)
    if group == nil or getNumOfChildren(group) == 0 then return nil end
    return getChildAt(group, 0)
end

-- Indlæser en ekstra i3d-fil én gang (delt cache) og returnerer dens rod, eller nil.
local function loadOptionalFile(a, file)
    if a.files[file] ~= nil then return a.files[file] or nil end
    local root, request = g_i3DManager:loadSharedI3DFile(Utils.getFilename(file, nil), false, false)
    table.insert(a.requests, request)
    if root == nil or root == 0 then
        a.files[file] = false -- forsøges ikke igen
        return nil
    end
    table.insert(a.roots, root)
    a.files[file] = root
    return root
end

-- Vælger masten til wiren (POLE_CHOICES-indeks); a.pole/a.poleShape bliver nil, hvis den ikke findes.
local function selectPole(a, index)
    local choice = POLE_CHOICES[index]
    local root = choice ~= nil and loadOptionalFile(a, choice.file) or nil
    a.pole = root ~= nil and findByName(root, choice.part) or nil
    a.poleShape = a.pole ~= nil and findByName(a.pole, "LOD0") or nil
    if a.poleShape == nil then
        Logging.warning("%smasten nr. %s til wiren findes ikke - bruger armmasten", LOG_PREFIX, tostring(index))
    end
end

local function loadAssets()
    if assets ~= nil then return assets.ok and assets or nil end
    assets = {ok = false, requests = {}, roots = {}, parts = {}}
    if g_i3DManager == nil then return nil end
    local mastRoot, mastRequest = g_i3DManager:loadSharedI3DFile(Utils.getFilename(MAST_FILE, nil), false, false)
    local lampRoot, lampRequest = g_i3DManager:loadSharedI3DFile(Utils.getFilename(LAMP_FILE, nil), false, false)
    table.insert(assets.requests, mastRequest)
    table.insert(assets.requests, lampRequest)
    if mastRoot ~= nil and mastRoot ~= 0 then table.insert(assets.roots, mastRoot) end
    if lampRoot ~= nil and lampRoot ~= 0 then table.insert(assets.roots, lampRoot) end
    if mastRoot == nil or mastRoot == 0 or lampRoot == nil or lampRoot == 0 then
        Logging.warning("%skunne ikke indlæse spillets lyskurve-modeller - lysene vises ikke", LOG_PREFIX)
        return nil
    end
    local allParts = true
    for _, name in ipairs(MAST_PARTS) do
        assets.parts[name] = findByName(mastRoot, name)
        allParts = allParts and assets.parts[name] ~= nil
    end
    assets.red = firstShapeUnder(lampRoot, "road01_A_RED")
    assets.amber = firstShapeUnder(lampRoot, "road01_A_AMBER")
    assets.green = firstShapeUnder(lampRoot, "road01_A_GREEN")
    assets.ok = allParts and assets.red ~= nil and assets.amber ~= nil and assets.green ~= nil
    -- wire og master er valgfri: mangler de, får den amerikanske udgave også armmasten
    assets.files = {[MAST_FILE] = mastRoot}
    local wireRoot = loadOptionalFile(assets, POLE_FILE)
    local wirePole = wireRoot ~= nil and findByName(wireRoot, WIRE_PART) or nil
    assets.wireShape = wirePole ~= nil and findByName(wirePole, "LOD0") or nil
    selectPole(assets, TLVisuals.tuning.span.pole)
    if not assets.ok then
        Logging.warning("%slyskurve-modellerne havde ikke de forventede noder - lysene vises ikke", LOG_PREFIX)
        return nil
    end
    return assets
end

function TLVisuals.releaseAssets()
    railSegments = nil
    if assets == nil then return end
    for _, root in ipairs(assets.roots or {}) do
        if entityExists(root) then delete(root) end
    end
    for _, request in ipairs(assets.requests or {}) do
        if request ~= nil then g_i3DManager:releaseSharedI3DFile(request) end
    end
    assets = nil
end

local function setLamp(lamp, on)
    if lamp == nil or not entityExists(lamp) then return end
    setShaderParameter(lamp, "lightControl", on and LIGHT_ON or 0, nil, nil, nil, false)
    for i = 0, getNumOfChildren(lamp) - 1 do
        setVisibility(getChildAt(lamp, i), on) -- punktlyskilden
    end
end

local function placeLamp(lamp)
    local t = TLVisuals.tuning
    setTranslation(lamp, t.lamp[1], t.lamp[2], t.lamp[3])
    setRotation(lamp, math.rad(t.lampRot[1]), math.rad(t.lampRot[2]), math.rad(t.lampRot[3]))
    setScale(lamp, t.lampScale, t.lampScale, t.lampScale)
end

local function cloneLamp(template, holder)
    local lamp = clone(template, false, false, false)
    link(holder, lamp)
    placeLamp(lamp)
    setLamp(lamp, false)
    return lamp
end

function TLVisuals.destroy(spec)
    for _, mast in pairs(spec.visualHeads or {}) do
        if mast.root ~= nil and entityExists(mast.root) then delete(mast.root) end
    end
    spec.visualHeads = {}
    if spec.visualSpan ~= nil and entityExists(spec.visualSpan) then delete(spec.visualSpan) end
    spec.visualSpan = nil
end

local function mastYaw(rightX, rightZ)
    -- mastens lokale +x (armen) peger mod venstre = ind over vognbanen: lokal x efter yaw = (cos, -sin)
    local leftX, leftZ = -rightX, -rightZ
    return math.atan2(-leftZ, leftX) + math.rad(TLVisuals.tuning.mastYawDeg)
end

-- Et lyshoved: drejet om sin egen akse, så linserne vender mod trafikken, med lamperne i en holder
-- (drejer dem om på hovedets forside uden at ændre deres indbyrdes opstilling).
local function fitHead(head, a, mast)
    setRotation(head, 0, math.rad(TLVisuals.tuning.headYawDeg), 0)
    local holder = createTransformGroup("lamps")
    link(head, holder)
    setRotation(holder, 0, math.rad(TLVisuals.tuning.lampYawDeg), 0)
    table.insert(mast.red, cloneLamp(a.red, holder))
    table.insert(mast.amber, cloneLamp(a.amber, holder))
    table.insert(mast.green, cloneLamp(a.green, holder))
end

local function loadRailSegments()
    if railSegments ~= nil then return railSegments end
    local system = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    -- for tidligt (ingen bygninger endnu): prøv igen ved næste bygning i stedet for at gemme en tom liste
    if system == nil or system.placeables == nil or #system.placeables == 0 then return {} end
    local segments = {}
    for _, placeable in ipairs(system.placeables) do
        local spline = placeable.spec_trainSystem ~= nil and placeable.getSpline ~= nil and placeable:getSpline() or nil
        if spline ~= nil and entityExists(spline) then
            -- en fejlende spline må ikke tage lyskurvene med sig: den springes over
            local ok, err = pcall(function()
                local count = math.max(2, math.ceil(getSplineLength(spline) / RAIL_SAMPLE_M))
                local previous = nil
                for i = 0, count do
                    local x, _, z = getSplinePosition(spline, i / count)
                    local point = {x = x, z = z}
                    if previous ~= nil then table.insert(segments, {a = previous, b = point}) end
                    previous = point
                end
            end)
            if not ok then Logging.warning("%skunne ikke læse en togbane: %s", LOG_PREFIX, tostring(err)) end
        end
    end
    railSegments = segments
    return railSegments
end

-- Skinnesegmenter inden for reach af center (også brugt til stoplinjerne i placeableTrafficLight).
function TLVisuals.railSegmentsNear(center, reach)
    local list = {}
    for _, segment in ipairs(loadRailSegments()) do
        if TLGeometry.pointSegmentDistance(center, segment.a, segment.b) <= reach then table.insert(list, segment) end
    end
    return list
end

-- Forhindringer for masterne nær krydset: krydsets egne veje (zonens segmenter) og skinner.
local function mastObstacles(intersection, withZone)
    local list = TLVisuals.railSegmentsNear(intersection.center, intersection.radius + 20)
    if withZone then
        for _, segment in ipairs(intersection.zone ~= nil and intersection.zone.segments or {}) do table.insert(list, segment) end
    end
    return list
end

local function terrainY(x, z)
    return g_terrainNode ~= nil and getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) or 0
end

local function activeApproaches(intersection)
    local list = {}
    for _, approach in ipairs(intersection.approaches or {}) do
        if not approach.internal and approach.enabled and approach.stopLine ~= nil then table.insert(list, approach) end
    end
    return list
end

local function segmentClearance(p, segments)
    local best = math.huge
    for _, segment in ipairs(segments or {}) do
        local ax, az, bx, bz = segment.a.x, segment.a.z, segment.b.x, segment.b.z
        local dx, dz = bx - ax, bz - az
        local lengthSq = dx * dx + dz * dz
        local t = lengthSq > 0 and math.max(0, math.min(1, ((p.x - ax) * dx + (p.z - az) * dz) / lengthSq)) or 0
        local cx, cz = ax + t * dx, az + t * dz
        best = math.min(best, math.sqrt((p.x - cx) ^ 2 + (p.z - cz) ^ 2))
    end
    return best
end

-- Diagonalen for wiren: de to modsatte masteplaceringer, der står længst fra alle veje i krydset.
local function spanEnds(intersection, approaches)
    local center = intersection.center
    local extent = 0
    for _, approach in ipairs(approaches) do
        extent = math.max(extent, math.sqrt((approach.stopLine.x - center.x) ^ 2 + (approach.stopLine.z - center.z) ^ 2))
    end
    -- loft: en stoplinje, der faldt tilbage til cirklens kant, må ikke sende masterne ud på vejene udenfor (review)
    extent = math.min(extent + POLE_CLEAR_M, intersection.radius - POLE_CLEAR_M)
    local segments = mastObstacles(intersection, true)
    local best, bestScore = nil, -math.huge
    for deg = 0, 175, 5 do
        local ux, uz = math.cos(math.rad(deg)), math.sin(math.rad(deg))
        local p1 = {x = center.x + ux * extent, z = center.z + uz * extent}
        local p2 = {x = center.x - ux * extent, z = center.z - uz * extent}
        local score = math.min(segmentClearance(p1, segments), segmentClearance(p2, segments))
        if score > bestScore then best, bestScore = {p1, p2}, score end
    end
    return best[1], best[2]
end

-- Hovedernes plads langs wiren: hvert hoved ud for sin indkørsel, projiceret på wiren, mindst HEAD_SPACING_M fra
-- naboen. Returnerer {approach, t (m fra p1)} sorteret langs wiren.
local function headSlots(approaches, center, p1, p2)
    local lx, lz = p2.x - p1.x, p2.z - p1.z
    local length = math.sqrt(lx * lx + lz * lz)
    local ux, uz = lx / length, lz / length
    local back = TLVisuals.tuning.span.headBack
    local slots = {}
    for _, approach in ipairs(approaches) do
        -- over sin egen vognbane, hvor ruten krydser wiren; ellers som før: tilbage fra midten mod indkørslen
        local t = TLGeometry.wireCrossing(p1, p2, approach.path)
        if t == nil then
            local qx = center.x - math.cos(approach.heading) * back
            local qz = center.z - math.sin(approach.heading) * back
            t = (qx - p1.x) * ux + (qz - p1.z) * uz
        end
        table.insert(slots, {approach = approach, t = t})
    end
    table.sort(slots, function(s1, s2) return s1.t < s2.t end)
    for i = 2, #slots do
        slots[i].t = math.max(slots[i].t, slots[i - 1].t + HEAD_SPACING_M)
    end
    return slots, length, ux, uz
end

-- Højden af en models top over dens nulpunkt (mindst 1 m).
local function shapeTop(shape)
    local _, cy, _, radius = getShapeBoundingSphere(shape)
    return math.max(cy + radius, 1)
end

local function placePole(span, a, p, toward)
    local pole = clone(a.pole, false, false, false)
    link(span, pole)
    setTranslation(pole, p.x, terrainY(p.x, p.z), p.z)
    -- tværarmen drejes efter wiren (review); poleYaw finjusteres i spillet
    setRotation(pole, 0, math.atan2(toward.x - p.x, toward.z - p.z) + math.rad(TLVisuals.tuning.span.poleYaw), 0)
    -- masten skaleres i højden, så toppen står lige over wiren
    local height = (TLVisuals.tuning.span.wireY + 0.3) / shapeTop(a.poleShape)
    setScale(pole, 1, height, 1)
end

-- Kassens midte i hovedmodellens egne akser (x, z), målt én gang på en kopi i verdens nulpunkt uden
-- drejning: dér er lokale og verdens akser ens, så målingen ikke afhænger af, hvilket rum
-- getShapeBoundingSphere svarer i (in-game 25/10: stangen ramte wiren på nogle hoveder, men ikke alle).
local function headCenter(a)
    if a.headCenter ~= nil then return a.headCenter end
    a.headCenter = {0, 0}
    local probe = clone(a.parts[SPAN_HEAD_PART], false, false, false)
    link(getRootNode(), probe)
    setTranslation(probe, 0, 0, 0)
    setRotation(probe, 0, 0, 0)
    local shape = findByName(probe, "LOD0")
    if shape ~= nil then
        local cx, _, cz = getShapeBoundingSphere(shape)
        a.headCenter = {cx, cz}
    end
    delete(probe)
    if TLConfig ~= nil and TLConfig.DEBUG then
        Logging.info("%slyshovedets midte i modellen: x %.3f z %.3f", LOG_PREFIX, a.headCenter[1], a.headCenter[2])
    end
    return a.headCenter
end

-- Hovedmodellens nulpunkt ligger ikke midt i kassen, så hovedet flyttes vandret, til ophængsstangen
-- hænger lodret under wiren, uanset hvilken vej det er drejet. Stangen sidder i siden af kassen:
-- span.hang er dens afstand fra kassens midte i hovedets egne akser (tlHang).
local function centerUnderHanger(root, head, a)
    local center, hang = headCenter(a), TLVisuals.tuning.span.hang
    local wx, wy, wz = localDirectionToWorld(head, center[1] + hang[1], 0, center[2] + hang[2])
    local lx, _, lz = worldDirectionToLocal(root, wx, wy, wz)
    setTranslation(head, -lx, 0, -lz)
end

-- Wiren: mastemodellen lagt ned (rotX) og skaleret tynd fra p1 til p2.
local function placeWire(span, a, from, to)
    local s = TLVisuals.tuning.span
    local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    local holder = createTransformGroup("wire")
    link(span, holder)
    setTranslation(holder, from.x, from.y, from.z)
    setDirection(holder, dx / length, dy / length, dz / length, 0, 1, 0)
    local wire = clone(a.wireShape, false, false, false)
    link(holder, wire)
    -- masten har et stykke under nulpunktet (i jorden), så wiren lægges efter modellens midte og hele
    -- længde (kuglens diameter for en slank mast) i stedet for nulpunkt og top - ellers stikker den ud
    -- forbi masten (in-game 25/10)
    local _, cy, _, radius = getShapeBoundingSphere(a.wireShape)
    local scaleY = length / math.max(2 * radius, 0.1)
    local rotX = math.rad(s.rotX)
    -- rotX drejer modellens +y til (0, cos, sin): midten flyttes til wirens midtpunkt
    setTranslation(wire, 0, -math.cos(rotX) * cy * scaleY, length / 2 - math.sin(rotX) * cy * scaleY)
    setRotation(wire, rotX, 0, 0)
    setScale(wire, s.thickness, scaleY, s.thickness)
end

-- Armen er længere end vejen (in-game 25/10: den stak ind over modsat vognbane): standeren skaleres langs
-- armen (lokal +x, masten står i x = 0) og lyshovederne rykkes tilsvarende ind; de beholder deres størrelse.
-- Masten gøres også højere (mastHeight): standeren strækkes lodret, og lyshovederne løftes med; de beholder
-- deres form, så lamperne i dem stadig passer.
local function shapeMastPart(name, part)
    local f, h = TLVisuals.tuning.armScale, TLVisuals.tuning.mastHeight
    if name == MAST_BASE_PART then
        setScale(part, f, h, 1)
    elseif HEAD_PARTS[name] then
        local x, y, z = getTranslation(part)
        setTranslation(part, x * f, y * h, z)
    end
end

-- Gadelampen har sit nulpunkt i mastens fod, og dens stang starter, hvor standeren slutter (lige over armen):
-- den løftes lige så meget, som standerens top flytter sig. Armens højde læses af lyshovedets plads
-- (in-game 25/10: løft efter lampens midte gav et hul i masten under gadelampen).
local function topLampLift(a)
    local _, armY = getTranslation(a.parts.trafficLight01)
    return (TLVisuals.tuning.mastHeight - 1) * armY
end

-- Største afstand fra krydsets midte til en stoplinje med lys.
local function farthestStop(intersection)
    local farthest = 0
    for _, approach in ipairs(activeApproaches(intersection)) do
        local stop = approach.stopLine
        farthest = math.max(farthest, math.sqrt((stop.x - intersection.center.x) ^ 2 + (stop.z - intersection.center.z) ^ 2))
    end
    return farthest
end

local function fitsSpanWire(intersection)
    local farthest = farthestStop(intersection)
    local fits = farthest <= SPAN_MAX_STOP_M
    if TLConfig ~= nil and TLConfig.DEBUG then
        Logging.info("%sUS-kryds ved (%.0f, %.0f): fjerneste stoplinje %.1f m -> %s", LOG_PREFIX, intersection.center.x,
            intersection.center.z, farthest, fits and "wire" or "master pr. indkørsel")
    end
    return fits
end

-- Layout (Task 10): serveren beregner, hvor master/wire/hoveder står (kræver AD-nettet og krydsets geometri);
-- klienterne bygger det samme ud fra layoutet (TLNet sender det). Ingen noder her.
--   {kind = "span", p1, p2, heads = {{id, t, yaw}}}  — US-wire: t = meter fra p1 langs wiren
--   {kind = "masts", masts = {{id, x, z, yaw}}}       — EU og store US-kryds: én armmast pr. indkørsel

local function spanLayout(intersection)
    local approaches = activeApproaches(intersection)
    if #approaches == 0 then return nil end
    local p1, p2 = spanEnds(intersection, approaches)
    local slots, length = headSlots(approaches, intersection.center, p1, p2)
    local heads = {}
    for _, slot in ipairs(slots) do
        local laneHeading = slot.approach.stopLine.heading or slot.approach.heading
        local dx, dz = math.cos(laneHeading), math.sin(laneHeading)
        table.insert(heads, {id = slot.approach.id, t = math.max(0, math.min(length, slot.t)), yaw = mastYaw(-dz, dx)})
    end
    return {kind = "span", p1 = {x = p1.x, z = p1.z}, p2 = {x = p2.x, z = p2.z}, heads = heads}
end

local function mastsLayout(intersection)
    local obstacles = mastObstacles(intersection, true)
    local masts = {}
    for _, approach in ipairs(intersection.approaches or {}) do
        local stop = approach.stopLine
        if not approach.internal and approach.enabled and stop ~= nil then
            local laneHeading = stop.heading or approach.heading -- vognbanens retning ved linjen
            local dx, dz = math.cos(laneHeading), math.sin(laneHeading)
            local rightX, rightZ = -dz, dx           -- højre side i kørselsretningen (x øst, z syd)
            -- fri plads (ikke på skinner/andre veje); i venstre side peger armen den anden vej ind over vejen
            local spot = TLGeometry.pickMastSpot(stop, laneHeading, SIDE_OFFSET_M, obstacles, MAST_CLEARANCE_M)
            table.insert(masts, {id = approach.id, x = spot.x, z = spot.z,
                yaw = mastYaw(rightX * spot.side, rightZ * spot.side)})
        end
    end
    return {kind = "masts", masts = masts}
end

-- Kun på serveren. EU: én mast pr. indkørsel ved stoplinjen, armen ind over vognbanen. US: hoveder i en
-- wire, når krydset er samlet nok (ellers master; også hvis træmasten ikke kunne indlæses).
-- Stoplinjerne til justeringsvisningen: indkørsler med lys eller med en justering (en indkørsel uden konflikt og
-- uden justering har intet at justere og skjules — ryddeligt UI).
local function stopsLayout(intersection, overrides)
    local stops = {}
    for _, approach in ipairs(intersection.approaches or {}) do
        local stop = approach.stopLine
        if not approach.internal and stop ~= nil and TLGeometry.hasADLane(approach)
            and (stop.conflict or approach.overrideIndex ~= nil) then
            local override = approach.overrideIndex ~= nil and (overrides or {})[approach.overrideIndex] or nil
            table.insert(stops, {id = approach.id, x = stop.x, z = stop.z, heading = stop.heading or approach.heading,
                enabled = approach.enabled ~= false, adjusted = override ~= nil, shift = override ~= nil and override.shift or 0})
        end
    end
    return stops
end

function TLVisuals.computeLayout(spec)
    local a = loadAssets()
    local intersection = spec.intersection
    if a == nil or intersection == nil then return nil end
    local layout
    if spec.variant == "US" and a.poleShape ~= nil and a.wireShape ~= nil and fitsSpanWire(intersection) then
        layout = spanLayout(intersection) or {kind = "masts", masts = {}}
    else
        layout = mastsLayout(intersection)
    end
    layout.stops = stopsLayout(intersection, spec.overrides)
    layout.stale = #(spec.staleOverrides or {})
    return layout
end

-- Amerikansk udgave: to træmaster, en wire og et hængende lyshoved pr. indkørsel ved sit layout-sted.
local function buildSpanWire(spec, a, layout)
    if a.poleShape == nil or a.wireShape == nil then return end
    local s = TLVisuals.tuning.span
    local p1, p2 = layout.p1, layout.p2
    local span = createTransformGroup("trafficLightSpan")
    link(getRootNode(), span)
    spec.visualSpan = span
    placePole(span, a, p1, p2)
    placePole(span, a, p2, p1)
    local from = {x = p1.x, y = terrainY(p1.x, p1.z) + s.wireY, z = p1.z}
    local to = {x = p2.x, y = terrainY(p2.x, p2.z) + s.wireY, z = p2.z}
    placeWire(span, a, from, to)
    local lx, lz = p2.x - p1.x, p2.z - p1.z
    local length = math.max(math.sqrt(lx * lx + lz * lz), 1e-6)
    local ux, uz = lx / length, lz / length
    for _, slot in ipairs(layout.heads) do
        local f = slot.t / length
        local root = createTransformGroup("trafficLightHead")
        link(span, root)
        setTranslation(root, p1.x + ux * slot.t, from.y + (to.y - from.y) * f - s.headDrop, p1.z + uz * slot.t)
        setRotation(root, 0, slot.yaw, 0)
        local mast = {root = root, red = {}, amber = {}, green = {}, signal = nil}
        local head = clone(a.parts[SPAN_HEAD_PART], false, false, false)
        link(root, head)
        setTranslation(head, 0, 0, 0)
        fitHead(head, a, mast)
        centerUnderHanger(root, head, a)
        spec.visualHeads[slot.id] = mast
    end
end

local function buildMasts(spec, a, layout)
    for _, entry in ipairs(layout.masts) do
        local root = createTransformGroup("trafficLightMast")
        link(getRootNode(), root)
        setTranslation(root, entry.x, terrainY(entry.x, entry.z), entry.z)
        setRotation(root, 0, entry.yaw, 0)
        local mast = {root = root, red = {}, amber = {}, green = {}, signal = nil}
        for _, name in ipairs(MAST_PARTS) do
            local part = clone(a.parts[name], false, false, false)
            shapeMastPart(name, part)
            if name == TOP_LAMP_PART then
                -- gadelampen drejes om masten (gruppen sidder i mastens fod), så den kan hænge ud over vejen
                local swivel = createTransformGroup("topLamp")
                link(root, swivel)
                setTranslation(swivel, 0, topLampLift(a), 0)
                setRotation(swivel, 0, math.rad(TLVisuals.tuning.topLampYawDeg), 0)
                link(swivel, part)
            else
                link(root, part)
            end
            if HEAD_PARTS[name] then fitHead(part, a, mast) end
        end
        spec.visualHeads[entry.id] = mast
    end
end

-- På klienter (og i singleplayer): bygger lysene ud fra et layout (nil = ingen lys).
function TLVisuals.buildLayout(spec, layout)
    TLVisuals.destroy(spec)
    local a = loadAssets()
    if a == nil or layout == nil then return end
    if layout.kind == "span" then
        buildSpanWire(spec, a, layout)
    else
        buildMasts(spec, a, layout)
    end
end

local function setAll(lamps, on)
    for _, lamp in ipairs(lamps) do setLamp(lamp, on) end
end

local function applySignal(mast, signal, nowMs)
    local flashOn = signal == "FLASHING" and (math.floor(nowMs / (FLASH_PERIOD_MS / 2)) % 2 == 0)
    setAll(mast.red, signal == "RED")
    setAll(mast.amber, signal == "AMBER" or flashOn)
    setAll(mast.green, signal == "GREEN")
end

-- Kaldes hver frame på klienten: skifter lamper kun, når signalet eller blinkfasen ændres.
function TLVisuals.update(spec, nowMs)
    for id, mast in pairs(spec.visualHeads or {}) do
        local signal = (spec.signals or {})[id] or "RED"
        local phase = signal == "FLASHING" and (math.floor(nowMs / (FLASH_PERIOD_MS / 2)) % 2) or 0
        if signal ~= mast.signal or phase ~= mast.flashPhase then
            applySignal(mast, signal, nowMs)
            mast.signal = signal
            mast.flashPhase = phase
        end
    end
end

-- Finjustering i spillet (kun TLConfig.DEBUG): flytter lamperne / drejer masterne på alle lyskurve straks.
TLVisuals.rebuildAll = nil -- sættes af TLManager

local Tune = {}

function Tune:lamp(x, y, z, rx, ry, rz)
    local t = TLVisuals.tuning
    if x == nil then
        return string.format("tlLamp %.2f %.2f %.2f %.0f %.0f %.0f", t.lamp[1], t.lamp[2], t.lamp[3], t.lampRot[1], t.lampRot[2], t.lampRot[3])
    end
    t.lamp = {tonumber(x) or t.lamp[1], tonumber(y) or t.lamp[2], tonumber(z) or t.lamp[3]}
    t.lampRot = {tonumber(rx) or t.lampRot[1], tonumber(ry) or t.lampRot[2], tonumber(rz) or t.lampRot[3]}
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlLamp %.2f %.2f %.2f %.0f %.0f %.0f", LOG_PREFIX, t.lamp[1], t.lamp[2], t.lamp[3], t.lampRot[1], t.lampRot[2], t.lampRot[3])
    return "tlLamp: sat - se lamperne"
end

function Tune:yaw(degrees)
    local t = TLVisuals.tuning
    if degrees == nil then return string.format("tlMastYaw %.0f", t.mastYawDeg) end
    t.mastYawDeg = tonumber(degrees) or t.mastYawDeg
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlMastYaw %.0f", LOG_PREFIX, t.mastYawDeg)
    return "tlMastYaw: sat - se masterne"
end

function Tune:lampYaw(degrees)
    local t = TLVisuals.tuning
    if degrees == nil then return string.format("tlLampYaw %.0f", t.lampYawDeg) end
    t.lampYawDeg = tonumber(degrees) or t.lampYawDeg
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlLampYaw %.0f", LOG_PREFIX, t.lampYawDeg)
    return "tlLampYaw: sat - se lamperne"
end

function Tune:lampScale(factor)
    local t = TLVisuals.tuning
    if factor == nil then return string.format("tlLampScale %.2f", t.lampScale) end
    local value = tonumber(factor)
    if value == nil or not (value > 0 and value <= 5) then return "tlLampScale: brug et tal mellem 0 og 5, fx 0.8" end
    t.lampScale = value
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlLampScale %.2f", LOG_PREFIX, t.lampScale)
    return "tlLampScale: sat - se lamperne"
end

function Tune:span(wireY, headDrop, thickness, rotX, headBack, poleYaw)
    local s = TLVisuals.tuning.span
    if wireY == nil then
        return string.format("tlSpan %.2f %.2f %.2f %.0f %.2f %.0f", s.wireY, s.headDrop, s.thickness, s.rotX, s.headBack, s.poleYaw)
    end
    s.poleYaw = tonumber(poleYaw) or s.poleYaw
    s.wireY = tonumber(wireY) or s.wireY
    s.headDrop = tonumber(headDrop) or s.headDrop
    s.thickness = tonumber(thickness) or s.thickness
    s.rotX = tonumber(rotX) or s.rotX
    s.headBack = tonumber(headBack) or s.headBack
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlSpan %.2f %.2f %.2f %.0f %.2f %.0f", LOG_PREFIX, s.wireY, s.headDrop, s.thickness, s.rotX, s.headBack, s.poleYaw)
    return "tlSpan: sat - se wiren"
end

function Tune:hang(x, z)
    local s = TLVisuals.tuning.span
    if x == nil then return string.format("tlHang %.2f %.2f", s.hang[1], s.hang[2]) end
    s.hang = {tonumber(x) or s.hang[1], tonumber(z) or s.hang[2]}
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlHang %.2f %.2f", LOG_PREFIX, s.hang[1], s.hang[2])
    return "tlHang: sat - se ophænget"
end

function Tune:arm(factor)
    local t = TLVisuals.tuning
    if factor == nil then return string.format("tlArm %.2f", t.armScale) end
    local value = tonumber(factor)
    if value == nil or not (value >= 0.3 and value <= 1.5) then return "tlArm: brug et tal mellem 0.3 og 1.5, fx 0.75" end
    t.armScale = value
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlArm %.2f", LOG_PREFIX, t.armScale)
    return "tlArm: sat - se armene"
end

function Tune:mastHeight(factor)
    local t = TLVisuals.tuning
    if factor == nil then return string.format("tlMastHeight %.2f", t.mastHeight) end
    local value = tonumber(factor)
    if value == nil or not (value >= 0.8 and value <= 2) then return "tlMastHeight: brug et tal mellem 0.8 og 2, fx 1.35" end
    t.mastHeight = value
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlMastHeight %.2f", LOG_PREFIX, t.mastHeight)
    return "tlMastHeight: sat - se masterne"
end

function Tune:pole(index)
    local s = TLVisuals.tuning.span
    local value = tonumber(index)
    if value == nil or POLE_CHOICES[value] == nil then
        local names = {}
        for i, choice in ipairs(POLE_CHOICES) do table.insert(names, string.format("%d=%s", i, choice.part)) end
        return string.format("tlPole %d (vælg 1-%d: %s)", s.pole, #POLE_CHOICES, table.concat(names, ", "))
    end
    s.pole = value
    if assets ~= nil and assets.ok then selectPole(assets, value) end
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlPole %d (%s)", LOG_PREFIX, value, POLE_CHOICES[value].part)
    return string.format("tlPole: %s - se masterne", POLE_CHOICES[value].part)
end

function Tune:topLampYaw(degrees)
    local t = TLVisuals.tuning
    if degrees == nil then return string.format("tlTopLampYaw %.0f", t.topLampYawDeg) end
    t.topLampYawDeg = tonumber(degrees) or t.topLampYawDeg
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlTopLampYaw %.0f", LOG_PREFIX, t.topLampYawDeg)
    return "tlTopLampYaw: sat - se gadelampen"
end

function Tune:headYaw(degrees)
    local t = TLVisuals.tuning
    if degrees == nil then return string.format("tlHeadYaw %.0f", t.headYawDeg) end
    t.headYawDeg = tonumber(degrees) or t.headYawDeg
    if TLVisuals.rebuildAll ~= nil then TLVisuals.rebuildAll() end
    Logging.info("%stuning: tlHeadYaw %.0f", LOG_PREFIX, t.headYawDeg)
    return "tlHeadYaw: sat - se lyshovederne"
end

if TLConfig ~= nil and TLConfig.DEBUG and addConsoleCommand ~= nil then
    addConsoleCommand("tlHeadYaw", "Lyskurve-test: tlHeadYaw grader - drej lyshovederne om sig selv", "headYaw", Tune)
    addConsoleCommand("tlLampYaw", "Lyskurve-test: tlLampYaw grader - drej lamperne om hovedets akse", "lampYaw", Tune)
    addConsoleCommand("tlArm", "Lyskurve-test: tlArm faktor - EU-mastens armlængde (1 = original)", "arm", Tune)
    addConsoleCommand("tlMastHeight", "Lyskurve-test: tlMastHeight faktor - EU-mastens højde (1 = original)", "mastHeight", Tune)
    addConsoleCommand("tlHang", "Lyskurve-test: tlHang x z - ophængsstangens plads i hovedet (m), så den rammer wiren", "hang", Tune)
    addConsoleCommand("tlPole", "Lyskurve-test: tlPole nr - vælg masten til US-wiren (uden tal: vis listen)", "pole", Tune)
    addConsoleCommand("tlSpan", "Lyskurve-test: tlSpan wireHøjde hovedFald tykkelse rotX hovedUd masteDrejning - US-wiren", "span", Tune)
    addConsoleCommand("tlLampScale", "Lyskurve-test: tlLampScale faktor - lysskivernes størrelse (1 = original)", "lampScale", Tune)
    addConsoleCommand("tlTopLampYaw", "Lyskurve-test: tlTopLampYaw grader - drej gadelampen om masten", "topLampYaw", Tune)
    addConsoleCommand("tlLamp", "Lyskurve-test: tlLamp x y z [rx ry rz] - lampernes plads i lyshovedet", "lamp", Tune)
    addConsoleCommand("tlMastYaw", "Lyskurve-test: tlMastYaw grader - ekstra drejning af masterne", "yaw", Tune)
end
