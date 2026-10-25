-- Placeable-specialisering for én lyskurv = ét kryds. Bygningen er en styreboks på krydsets hjørne; krydsets
-- midte findes ud fra AD-vejene (TLGeometry.snapCenter). Master/lyshoveder bygges ved stoplinjerne (tlVisuals).
-- Logikken kører kun på serveren, drevet af TLManager (én samlet takt); klienter tegner kun lys.
PlaceableTrafficLight = {}
PlaceableTrafficLight.MOD_NAME = g_currentModName
PlaceableTrafficLight.SPEC_NAME = string.format("%s.trafficLight", g_currentModName)
PlaceableTrafficLight.SPEC = string.format("spec_%s", PlaceableTrafficLight.SPEC_NAME)

local SPEC = PlaceableTrafficLight.SPEC
local LOG_PREFIX = "[TrafficLights] "
local REBUILD_CHECK_MS = 5000
-- justeringer (spec 5.8): handlingerne deles med tlAdjust/TLAdjustEvent
local ADJUST = {RESET = 0, BACK = 1, FORWARD = 2, TOGGLE = 3}
PlaceableTrafficLight.ADJUST = ADJUST
local ADJUST_STEP_M = 0.5
local SHIFT_MIN_M, SHIFT_MAX_M = -15, 40

local function clampShift(shift)
    return math.max(SHIFT_MIN_M, math.min(SHIFT_MAX_M, tonumber(shift) or 0))
end

-- Styreboksen er selve bygningen: den står på krydsets hjørne og kan vælges, sælges og flyttes i
-- byggemenuen (bruger-idé 25/10). Spillets egne elskabe; klonet under rootNode i onLoad, så
-- Placeable:collectPickObjects finder dens kollision.
local CABINETS = {
    EU = {file = "$data/maps/mapEU/textures/props/electricityBoxes.i3d", node = "electricityBox01"},
    US = {file = "$data/maps/mapUS/textures/props/electricalBoxSet.i3d", node = "electricalBox02"},
}

local function findByName(node, name)
    if getName(node) == name then return node end
    for i = 0, getNumOfChildren(node) - 1 do
        local found = findByName(getChildAt(node, i), name)
        if found ~= nil then return found end
    end
    return nil
end

local function loadCabinet(placeable, variant)
    local cabinet = CABINETS[variant] or CABINETS.EU
    local root, requestId = g_i3DManager:loadSharedI3DFile(Utils.getFilename(cabinet.file, nil), false, false)
    if root == nil or root == 0 then
        Logging.warning("%skunne ikke indlæse styreboksen (%s)", LOG_PREFIX, cabinet.file)
        return requestId
    end
    local template = findByName(root, cabinet.node)
    if template == nil then
        Logging.warning("%sstyreboksen %s findes ikke i %s", LOG_PREFIX, cabinet.node, cabinet.file)
    else
        local box = clone(template, false, false, false)
        link(placeable.rootNode, box)
        setTranslation(box, 0, 0, 0)
        setRotation(box, 0, 0, 0)
        -- ingen addToPhysics her: Placeable:finalizePlacement lægger hele rootNode i fysikken, og
        -- forhåndsvisningen under placering må ikke have kollision (review)
    end
    delete(root)
    return requestId
end

function PlaceableTrafficLight.prerequisitesPresent(specializations)
    return true
end

function PlaceableTrafficLight.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "getTrafficLightSpec", PlaceableTrafficLight.getTrafficLightSpec)
    SpecializationUtil.registerFunction(placeableType, "rebuildIntersection", PlaceableTrafficLight.rebuildIntersection)
    SpecializationUtil.registerFunction(placeableType, "publishLayout", PlaceableTrafficLight.publishLayout)
    SpecializationUtil.registerFunction(placeableType, "adjustApproach", PlaceableTrafficLight.adjustApproach)
    SpecializationUtil.registerFunction(placeableType, "runTrafficLightTick", PlaceableTrafficLight.runTrafficLightTick)
    SpecializationUtil.registerFunction(placeableType, "releaseTrafficLight", PlaceableTrafficLight.releaseTrafficLight)
    SpecializationUtil.registerFunction(placeableType, "drawTrafficLightDebug", PlaceableTrafficLight.drawTrafficLightDebug)
end

function PlaceableTrafficLight.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTrafficLight)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableTrafficLight)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableTrafficLight)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", PlaceableTrafficLight)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", PlaceableTrafficLight)
    SpecializationUtil.registerEventListener(placeableType, "onReadUpdateStream", PlaceableTrafficLight)
    SpecializationUtil.registerEventListener(placeableType, "onWriteUpdateStream", PlaceableTrafficLight)
end

function PlaceableTrafficLight.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TrafficLight")
    schema:register(XMLValueType.STRING, basePath .. ".trafficLight#variant", "Udgave: EU (mast ved hver stoplinje) eller US (lys over midten)", "EU")
    schema:setXMLSpecializationType()
end

function PlaceableTrafficLight.registerSavegameXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TrafficLight")
    schema:register(XMLValueType.FLOAT, basePath .. "#radius", "Krydsets radius (m)")
    local override = basePath .. ".override(?)"
    schema:register(XMLValueType.FLOAT, override .. "#heading", "Indkørslens retning (rad)")
    schema:register(XMLValueType.FLOAT, override .. "#stopX", "Den automatiske stoplinjes x")
    schema:register(XMLValueType.FLOAT, override .. "#stopZ", "Den automatiske stoplinjes z")
    schema:register(XMLValueType.FLOAT, override .. "#shift", "Stoplinjen flyttet (m, + = længere ud)", 0)
    schema:register(XMLValueType.BOOL, override .. "#enabled", "Indkørslen har lys", true)
    schema:setXMLSpecializationType()
end

function PlaceableTrafficLight:getTrafficLightSpec()
    return self[SPEC]
end

local function modVersion()
    local mod = g_modManager ~= nil and g_modManager:getModByName(PlaceableTrafficLight.MOD_NAME) or nil
    return mod ~= nil and mod.version or "?"
end

function PlaceableTrafficLight:onLoad(savegame)
    local spec = self[SPEC]
    if spec == nil then
        Logging.error("%sspecialiseringen 'trafficLight' mangler i modDesc", LOG_PREFIX)
        return
    end
    spec.variant = self.xmlFile:getValue("placeable.trafficLight#variant", "EU")
    spec.radius = TLConfig.RADIUS_DEFAULT
    spec.intersection = nil
    spec.networkVersion = -1
    spec.lastRebuildCheckMs = -math.huge
    spec.state = TLController.initialState()
    spec.tracking = {}
    spec.overrides = {}
    spec.signals = {}
    spec.clearMs = nil
    spec.disabledReason = nil
    spec.visualHeads = {}
    spec.layout = nil
    spec.sentSignals = {}
    -- multiplayer: layout (master/wire) og signaler sendes hver for sig, når de ændrer sig
    spec.layoutDirtyFlag = self:getNextDirtyFlag()
    spec.signalDirtyFlag = self:getNextDirtyFlag()
    spec.center = nil
    spec.cabinetRequestId = loadCabinet(self, spec.variant)
    Logging.info("%sv%s lyskurv indlæst (%s)", LOG_PREFIX, modVersion(), spec.variant)
end

function PlaceableTrafficLight:onFinalizePlacement()
    if self.isServer then TLManager.register(self) end
    if self.isClient then TLManager.registerVisual(self) end
end

function PlaceableTrafficLight:onDelete()
    TLManager.unregister(self)
    TLManager.unregisterVisual(self)
    self:releaseTrafficLight()
    local spec = self[SPEC]
    if spec ~= nil then
        TLVisuals.destroy(spec)
        if spec.cabinetRequestId ~= nil then
            g_i3DManager:releaseSharedI3DFile(spec.cabinetRequestId)
            spec.cabinetRequestId = nil
        end
    end
end

-- modDesc-tekster slås op med modmiljøet, som spillet selv gør (Placeable.lua: hasText(key, customEnvironment))
local function textOr(key, fallback, env)
    if g_i18n ~= nil and g_i18n:hasText(key, env) then return g_i18n:getText(key, env) end
    return fallback
end

-- Beskeder på skærmen når krydset går i blinkende gult (og påmindelser), og når det kører igen.
-- Kun på serveren (værten ser dem); MP-klienter får dem med Task 10.
local function notifyOutOfOrder(placeable, spec, previousPhase, nowMs)
    if g_currentMission == nil or g_currentMission.addIngameNotification == nil then return end
    local phase = spec.state.phase
    local name = placeable:getName() or "?"
    if phase == "OUT_OF_ORDER" then
        if previousPhase == "OUT_OF_ORDER" and nowMs - (spec.lastAlertMs or -math.huge) < TLConfig.ALERT_REPEAT_MS then return end
        spec.lastAlertMs = nowMs
        local center = spec.center or {x = 0, z = 0}
        local farmlandId = g_farmlandManager ~= nil and g_farmlandManager:getFarmlandIdAtWorldPosition(center.x, center.z) or 0
        local env = placeable.customEnvironment
        local text
        if farmlandId ~= nil and farmlandId > 0 then
            text = string.format(textOr("tl_alertOutOfOrder", "%s near farmland %d is flashing amber: a vehicle is stuck in the intersection", env),
                name, farmlandId)
        else
            text = string.format(textOr("tl_alertOutOfOrderNoFarmland", "%s is flashing amber: a vehicle is stuck in the intersection", env), name)
        end
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
        local stuckBy = spec.lastInput ~= nil and table.concat(spec.lastInput.occupiedBy or {}, ", ") or "?"
        Logging.info("%sblinker gult (besked vist): %s - i zonen: %s", LOG_PREFIX, text, stuckBy)
    elseif previousPhase == "OUT_OF_ORDER" then
        spec.lastAlertMs = nil
        Logging.info("%s%s kører normalt igen", LOG_PREFIX, name)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(textOr("tl_alertRecovered", "%s is working normally again", placeable.customEnvironment), name))
    end
end

local function placementOf(placeable)
    local x, _, z = getWorldTranslation(placeable.rootNode)
    return {x = x, z = z}
end


local function forEachTrafficLane(intersection, fn)
    for _, approach in ipairs(intersection ~= nil and intersection.approaches or {}) do
        for i, lane in ipairs(approach.lanes or {}) do
            if lane.kind == "TRAFFIC" then approach.lanes[i] = fn(approach, lane) end
        end
    end
end

-- Slipper alle trafikspærringer og nulstiller lyset (ved sletning, genopbygning og ved kortets lukning).
function PlaceableTrafficLight:releaseTrafficLight()
    local spec = self[SPEC]
    if spec == nil then return end
    forEachTrafficLane(spec.intersection, function(_, lane) return TLTraffic.setBlocked(lane, false) end)
    spec.state = TLController.initialState()
    spec.tracking = {}
end

local IDLE_CLEAR_SPEED = 6 -- m/s: en trafikbil, der kører frit gennem et tomt kryds

local CLEAR_CAR_LENGTH = 5 -- m, en af kortets biler
local CLEAR_MARGIN_S = 1.5 -- s, reaktion/acceleration fra stop (review)

-- Rydningstid for kortets trafik, når trafikbiler ikke kan registreres: fra den fjerneste stoplinje
-- gennem krydset og ud på den anden side (2 × stoplinjens afstand til midten + en billængde) / fart.
-- Cirklens radius gav 16,7 s rødt uden grund (in-game 25/10).
local function clearTimeMs(intersection, speed)
    local extent = 0
    for _, approach in ipairs(intersection.approaches or {}) do
        if not approach.internal and approach.stopLine ~= nil and approach.enabled ~= false then
            local stop = approach.stopLine
            extent = math.max(extent, math.sqrt((stop.x - intersection.center.x) ^ 2 + (stop.z - intersection.center.z) ^ 2))
        end
    end
    -- gulv: ingen aktive stoplinjer (kun frakoblede indkørsler med trafikspor) må ikke give ~1 s (review)
    extent = math.max(extent, intersection.radius * 0.5)
    return ((2 * extent + CLEAR_CAR_LENGTH) / speed + CLEAR_MARGIN_S) * 1000
end

-- Serveren: nyt layout (nil = ingen lys) bygges lokalt, hvis der er en skærm, og sendes til klienterne.
-- Signalerne startes forfra (gamle indkørsels-id'er må ikke hænge ved — review); næste takt sætter dem.
function PlaceableTrafficLight:publishLayout()
    local placeable, spec = self, self[SPEC]
    local ok, layout = pcall(TLVisuals.computeLayout, spec)
    if not ok then
        Logging.warning("%skunne ikke beregne lysene: %s", LOG_PREFIX, tostring(layout))
        layout = nil
    end
    spec.layout = layout
    if placeable.isClient then
        local built, err = pcall(TLVisuals.buildLayout, spec, layout)
        if not built then Logging.warning("%skunne ikke bygge lysene: %s", LOG_PREFIX, tostring(err)) end
    end
    spec.signals = {}
    spec.sentSignals = {}
    placeable:raiseDirtyFlags(spec.layoutDirtyFlag)
    placeable:raiseDirtyFlags(spec.signalDirtyFlag)
end

function PlaceableTrafficLight:rebuildIntersection()
    local spec = self[SPEC]
    self:releaseTrafficLight()
    local placement = placementOf(self)
    local center, snapped = TLGeometry.snapCenter(placement, spec.radius, TLAutoDrive.edgesNear(placement, spec.radius))
    spec.placement = placement
    -- kun når resultatet ændrer sig: en slået-fra lyskurv prøver igen hvert REBUILD_CHECK_MS (in-game 25/10: støj)
    local snapLog = string.format("styreboks ved (%.0f, %.0f) -> krydsets midte (%.0f, %.0f)%s", placement.x, placement.z,
        center.x, center.z, snapped and "" or " (ingen krydsning fundet)")
    if TLConfig.DEBUG and snapLog ~= spec.lastSnapLog then Logging.info("%s%s", LOG_PREFIX, snapLog) end
    spec.lastSnapLog = snapLog
    -- intet AD-kryds ved boksen: byg intet (in-game 25/10: med boksen som midte hang lysene ude på en
    -- gårdsplads). Ingen midte, så den heller ikke kan slå en nabo fra som overlap.
    if not snapped then
        spec.center = nil
        spec.intersection = nil
        spec.staleOverrides = {} -- intet kryds: ingen indeks at slette ud fra (review M1)
        self:publishLayout()
        if spec.disabledReason ~= "noJunction" then
            spec.disabledReason = "noJunction"
            spec.noJunctionNotified = false
            Logging.warning("%sintet AutoDrive-kryds ved styreboksen (%.0f, %.0f) - lyskurven er slået fra", LOG_PREFIX,
                placement.x, placement.z)
        end
        -- skærmbeskeden først, når AD's net er indlæst (ellers en falsk besked ved indlæsning af savegamet),
        -- og kun én gang (review: et eget flag, så den også kommer, hvis AD indlæses efter første forsøg)
        if not spec.noJunctionNotified and TLAutoDrive.networkVersion() > 0
            and g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
            spec.noJunctionNotified = true
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, string.format(textOr("tl_alertNoJunction",
                "%s: no AutoDrive junction found here - place the control box closer to the junction", self.customEnvironment),
                self:getName() or "?"))
        end
        return
    end
    spec.center = center

    for _, other in ipairs(TLManager.otherLights(self)) do
        local otherSpec = other[SPEC]
        -- kun mod en lyskurv, hvis midte er fundet (ellers sammenlignes med dens boks på hjørnet — review)
        -- en lyskurv, der selv er slået fra pga. overlap, spærrer ikke (ellers slår to hinanden fra — review)
        if otherSpec ~= nil and otherSpec.center ~= nil and otherSpec.disabledReason ~= "overlap"
            and TLGeometry.circlesOverlap(center, spec.radius, otherSpec.center, otherSpec.radius) then
            spec.intersection = nil
            spec.staleOverrides = {}
            self:publishLayout()
            if spec.disabledReason ~= "overlap" then
                Logging.warning("%slyskurven overlapper en anden lyskurv - den er slået fra; flyt den længere væk", LOG_PREFIX)
            end
            spec.disabledReason = "overlap"
            return
        end
    end
    spec.disabledReason = nil

    local edges = TLAutoDrive.edgesNear(center, spec.radius)
    local approaches, exits = TLGeometry.findApproaches(center, spec.radius, edges)
    local intersection = {center = center, radius = spec.radius, exits = exits}
    intersection.zone = TLGeometry.conflictZone(intersection, edges)
    intersection.core = TLGeometry.conflictCore(intersection.zone)

    -- først stoplinjer for alle (mergeLane laver kopier: en senere stoplinje ville ikke komme med)
    local withLights, trafficLanes = 0, 0
    -- skinner nær krydset: ingen stoplinje (eller kø bag den) på en jernbaneoverkørsel
    local rails = TLVisuals.railSegmentsNear(center, spec.radius + TLGeometry.RAIL_QUEUE_M + 10)
    for _, approach in ipairs(approaches) do
        if not approach.internal then
            approach.stopLine = TLGeometry.placeStopLine(approach, intersection.zone, rails)
            -- ingen konflikt med andre veje: intet lys (spec 5.12, "rødt uden grund")
            approach.enabled = approach.stopLine.conflict
        end
    end
    -- AD-spor, der løber sammen før stoplinjen, er én vognbane: ét lys (in-game 25/10)
    approaches = TLGeometry.mergeSharedStopLines(approaches)
    -- spillerens justeringer (spec 5.8); dem uden indkørsel er forældede, men gemmes stadig
    approaches, spec.staleOverrides = TLGeometry.applyOverrides(approaches, spec.overrides)
    for _, approach in ipairs(approaches) do
        if not approach.internal and approach.enabled then withLights = withLights + 1 end
    end
    local result = approaches
    for _, approach in ipairs(approaches) do
        if not approach.internal then
            local lane = TLTraffic.findLane(approach.stopLine, approach.heading)
            if lane ~= nil then
                result = TLGeometry.mergeLane(result, {splineId = lane.splineId, splineTime = lane.splineTime,
                    pos = {x = approach.stopLine.x, z = approach.stopLine.z}, heading = approach.heading})
                trafficLanes = trafficLanes + 1
            end
        end
    end
    intersection.approaches = result
    spec.intersection = intersection
    spec.clearMs = trafficLanes > 0 and clearTimeMs(intersection, TLConfig.CLEAR_SPEED) or nil
    spec.idleClearMs = trafficLanes > 0 and clearTimeMs(intersection, IDLE_CLEAR_SPEED) or nil
    spec.networkVersion = TLAutoDrive.networkVersion()
    spec.state = TLController.initialState()
    spec.tracking = {}

    self:publishLayout()

    if #approaches == 0 then
        Logging.info("%singen veje fundet ved (%.0f, %.0f) - tilføj stoplinjer i justeringsvisningen", LOG_PREFIX, center.x, center.z)
    else
        Logging.info("%skryds ved (%.0f, %.0f): %d indkørsler med lys, %d trafikspor", LOG_PREFIX, center.x, center.z, withLights, trafficLanes)
    end
end

local function nearby(snapshots, center, reach, into)
    local reachSq = reach * reach
    for _, snapshot in ipairs(snapshots) do
        if (snapshot.pos.x - center.x) ^ 2 + (snapshot.pos.z - center.z) ^ 2 <= reachSq then table.insert(into, snapshot) end
    end
    return into
end

local function anyEnabledTraffic(intersection)
    for _, approach in ipairs(intersection.approaches) do
        if approach.enabled ~= false then
            for _, lane in ipairs(approach.lanes or {}) do
                if lane.kind == "TRAFFIC" then return true end
            end
        end
    end
    return false
end

local function approachHasTraffic(intersection, approachId)
    if approachId == nil then return false end
    for _, approach in ipairs(intersection.approaches) do
        if approach.id == approachId then
            for _, lane in ipairs(approach.lanes or {}) do
                if lane.kind == "TRAFFIC" then return true end
            end
        end
    end
    return false
end

-- Én takt (kun server): efterspørgsel -> lysfaser -> hold og spærringer. holdLookup udfyldes med de
-- AD-køretøjer, der skal holde for rødt.
function PlaceableTrafficLight:runTrafficLightTick(adSnapshots, cpSnapshots, nowMs, holdLookup)
    local spec = self[SPEC]
    if spec == nil then return end
    -- også en slået-fra lyskurv (overlap) prøver kun igen hvert REBUILD_CHECK_MS (review: ellers fuld
    -- AD-scanning 4 gange i sekundet)
    if nowMs - spec.lastRebuildCheckMs >= REBUILD_CHECK_MS then
        spec.lastRebuildCheckMs = nowMs
        local placement = placementOf(self)
        local moved = spec.placement == nil or math.abs(placement.x - spec.placement.x) > 0.5
            or math.abs(placement.z - spec.placement.z) > 0.5
        if spec.intersection == nil or moved or spec.networkVersion ~= TLAutoDrive.networkVersion() then
            self:rebuildIntersection()
        end
    end
    local intersection = spec.intersection
    if intersection == nil then return end

    local reach = intersection.radius + TLConfig.DEMAND_DISTANCE
    local snapshots = nearby(adSnapshots, intersection.center, reach, {})
    nearby(cpSnapshots, intersection.center, reach, snapshots)
    if TLTraffic.canDetectCars() then
        for _, car in ipairs(TLTraffic.carSnapshots(intersection.center, intersection.radius + TLConfig.DEMAND_DISTANCE, nowMs)) do
            table.insert(snapshots, car)
        end
    end

    local input, tracking, holdList = TLDemand.collect(snapshots, intersection, spec.tracking, nowMs)
    local canDetect = TLTraffic.canDetectCars()
    -- fast rydningstid kun efter en grøn fase, hvor kortets trafik kørte (ellers rødt uden grund — review)
    local previous = spec.state
    local trafficPhase = (previous.phase == "AMBER" and approachHasTraffic(intersection, previous.greenId))
        or (previous.phase == "CLEARING" and approachHasTraffic(intersection, spec.clearingAfterId))
    if not canDetect and trafficPhase then input.trafficClearMs = spec.clearMs end
    -- uden registrering kører kortets trafik frit i tomgang: første grønt venter en kort rydning (review)
    local idleClearing = not canDetect and anyEnabledTraffic(intersection)
    input.idleNeedsClearing = idleClearing
    if idleClearing and previous.phase == "CLEARING" and spec.clearingAfterId == "IDLE" then
        input.trafficClearMs = spec.idleClearMs
    end
    if TLConfig.DEBUG then
        -- fejlsøgning: hvem kørte over linjen uden lov (kortets biler i tomgang kører frit og tælles ikke)
        -- gult på egen indkørsel og kortets biler, der ikke kunne nå at stoppe, er lovlige (review)
        local committedBefore = spec.lastInput ~= nil and spec.lastInput.trafficCommitted or {}
        for approachId in pairs(input.crossed or {}) do
            local amberOwn = previous.phase == "AMBER" and approachId == previous.greenId
            if previous.phase ~= "IDLE" and not amberOwn and not committedBefore[approachId]
                and not (input.trafficCommitted or {})[approachId] and not TLController.mayPass(previous, approachId) then
                Logging.info("[TrafficLights] OVER FOR RØDT: indkørsel %s i kryds ved (%.0f, %.0f), fase %s",
                    tostring(approachId), intersection.center.x, intersection.center.z, tostring(previous.phase))
            end
        end
    end
    spec.tracking = tracking
    spec.lastInput = input
    spec.lastHoldList = holdList
    spec.state = TLController.update(previous, input, nowMs, TLConfig)
    if previous.phase == "AMBER" and spec.state.phase == "CLEARING" then spec.clearingAfterId = previous.greenId end
    if previous.phase == "IDLE" and spec.state.phase == "CLEARING" then spec.clearingAfterId = "IDLE" end
    -- en fejl i beskeden må ikke slippe holdene i denne takt (review)
    local notified, notifyError = pcall(notifyOutOfOrder, self, spec, previous.phase, nowMs)
    if not notified then Logging.warning("%sbesked fejlede: %s", LOG_PREFIX, tostring(notifyError)) end

    for _, item in ipairs(holdList) do
        if not TLController.mayPass(spec.state, item.approachId) then
            if item.kind == "AD" then holdLookup[item.key] = true
            elseif item.kind == "CP" then TLCourseplay.hold(item.key)
            elseif item.kind == "AI" then TLAIDrive.hold(item.key) end
        end
    end
    -- Kortets trafik spærres kun, mens krydset er i brug (ikke i tomgang): uden registrering skaber den
    -- ingen efterspørgsel og holdt for evigt (review CRITICAL), og med registrering må en forkert antaget
    -- kørselsretning aldrig kunne holde den fast. I tomgang kører den frit; zonen ses som optaget, når den
    -- er derinde, så næste grønt venter.
    local inUse = spec.state.phase ~= "IDLE"
    forEachTrafficLane(intersection, function(approach, lane)
        local block = approach.enabled ~= false and not TLController.mayPass(spec.state, approach.id) and inUse
        return TLTraffic.setBlocked(lane, block)
    end)

    -- Kortets trafik kører frit i tomgang (spærres aldrig dér): vis grønt (ellers så det ud, som om
    -- bilerne kørte over for rødt — in-game 25/10)
    for _, approach in ipairs(intersection.approaches) do
        if not approach.internal then
            local signal = approach.enabled and TLController.signalFor(spec.state, approach.id) or "OFF"
            if approach.enabled and spec.state.phase == "IDLE" and approachHasTraffic(intersection, approach.id) then
                signal = "GREEN"
            end
            spec.signals[approach.id] = signal
        end
    end
    if TLNet.signalsChanged(spec.sentSignals, spec.signals) then
        local copy = {}
        for id, signal in pairs(spec.signals) do copy[id] = signal end
        spec.sentSignals = copy
        self:raiseDirtyFlags(spec.signalDirtyFlag)
    end
end

local SIGNAL_COLORS = {RED = {1, 0, 0}, AMBER = {1, 0.6, 0}, GREEN = {0, 1, 0}, FLASHING = {1, 0.6, 0}, OFF = {0.4, 0.4, 0.4}}

function PlaceableTrafficLight:drawTrafficLightDebug()
    local spec = self[SPEC]
    local intersection = spec ~= nil and spec.intersection or nil
    if intersection == nil then return end
    local function y(p) return (g_terrainNode ~= nil and getTerrainHeightAtWorldPos(g_terrainNode, p.x, 0, p.z) or 0) + 0.3 end
    for _, segment in ipairs(intersection.zone.segments) do
        DebugUtil.drawDebugLine(segment.a.x, y(segment.a), segment.a.z, segment.b.x, y(segment.b), segment.b.z, 0.2, 0.4, 1)
    end
    -- trafikspor: lodret streg ved spærrepunktet, rød = spærret, grøn = åben
    for _, approach in ipairs(intersection.approaches) do
        for _, lane in ipairs(approach.lanes or {}) do
            if lane.kind == "TRAFFIC" and lane.splineId ~= nil and getSplinePosition ~= nil then
                local ok, x, ly, z = pcall(getSplinePosition, lane.splineId, lane.splineTime)
                if ok and x ~= nil then
                    local r, g = lane.blocked and 1 or 0, lane.blocked and 0 or 1
                    DebugUtil.drawDebugLine(x, ly, z, x, ly + 4, z, r, g, 0)
                    Utils.renderTextAtWorldPosition(x, ly + 4.3, z, string.format("spor %d", approach.id),
                        getCorrectTextSize(0.012), 0, r, g, 0, 1)
                end
            end
        end
    end
    for _, approach in ipairs(intersection.approaches) do
        local stop = approach.stopLine
        if stop ~= nil then
            local color = SIGNAL_COLORS[spec.signals[approach.id] or "RED"] or SIGNAL_COLORS.RED
            local laneHeading = stop.heading or approach.heading -- vognbanens retning ved linjen, som masterne
            local px, pz = -math.sin(laneHeading) * 2, math.cos(laneHeading) * 2
            DebugUtil.drawDebugLine(stop.x - px, y(stop), stop.z - pz, stop.x + px, y(stop), stop.z + pz, color[1], color[2], color[3])
            Utils.renderTextAtWorldPosition(stop.x, y(stop) + 1.5, stop.z, string.format("%d %s", approach.id, spec.signals[approach.id] or ""),
                getCorrectTextSize(0.015), 0, color[1], color[2], color[3], 1)
        end
    end
end

-- Multiplayer: en ny klient får layout og signaler ved tilslutning; derefter kun ændringer (dirty-flag).
local function applyLayout(spec, layout)
    spec.layout = layout
    local ok, err = pcall(TLVisuals.buildLayout, spec, layout)
    if not ok then Logging.warning("%skunne ikke bygge lysene: %s", LOG_PREFIX, tostring(err)) end
end

function PlaceableTrafficLight:onWriteStream(streamId, connection)
    local spec = self[SPEC]
    TLNet.writeLayout(streamId, spec.layout)
    TLNet.writeSignals(streamId, spec.sentSignals)
end

function PlaceableTrafficLight:onReadStream(streamId, connection)
    local spec = self[SPEC]
    applyLayout(spec, TLNet.readLayout(streamId))
    spec.signals = TLNet.readSignals(streamId)
end

function PlaceableTrafficLight:onWriteUpdateStream(streamId, connection, dirtyMask)
    if connection:getIsServer() then return end -- kun server -> klient
    local spec = self[SPEC]
    if streamWriteBool(streamId, bitAND(dirtyMask, spec.layoutDirtyFlag) ~= 0) then
        TLNet.writeLayout(streamId, spec.layout)
    end
    if streamWriteBool(streamId, bitAND(dirtyMask, spec.signalDirtyFlag) ~= 0) then
        TLNet.writeSignals(streamId, spec.sentSignals)
    end
end

function PlaceableTrafficLight:onReadUpdateStream(streamId, timestamp, connection)
    if not connection:getIsServer() then return end
    local spec = self[SPEC]
    if streamReadBool(streamId) then applyLayout(spec, TLNet.readLayout(streamId)) end
    if streamReadBool(streamId) then spec.signals = TLNet.readSignals(streamId) end
end

function PlaceableTrafficLight:loadFromXMLFile(xmlFile, key)
    local spec = self[SPEC]
    local radius = xmlFile:getValue(key .. "#radius")
    if radius ~= nil then
        spec.radius = math.max(TLConfig.RADIUS_MIN, math.min(TLConfig.RADIUS_MAX, radius))
    end
    spec.overrides = {}
    xmlFile:iterate(key .. ".override", function(_, overrideKey)
        local heading = xmlFile:getValue(overrideKey .. "#heading")
        local x, z = xmlFile:getValue(overrideKey .. "#stopX"), xmlFile:getValue(overrideKey .. "#stopZ")
        if heading ~= nil and x ~= nil and z ~= nil then
            table.insert(spec.overrides, {heading = heading, stopPos = {x = x, z = z},
                shift = clampShift(xmlFile:getValue(overrideKey .. "#shift", 0)), enabled = xmlFile:getValue(overrideKey .. "#enabled", true)})
        end
    end)
end

function PlaceableTrafficLight:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[SPEC]
    xmlFile:setValue(key .. "#radius", spec.radius)
    for i, override in ipairs(spec.overrides or {}) do
        local overrideKey = string.format("%s.override(%d)", key, i - 1)
        xmlFile:setValue(overrideKey .. "#heading", override.heading)
        xmlFile:setValue(overrideKey .. "#stopX", override.stopPos.x)
        xmlFile:setValue(overrideKey .. "#stopZ", override.stopPos.z)
        xmlFile:setValue(overrideKey .. "#shift", override.shift or 0)
        xmlFile:setValue(overrideKey .. "#enabled", override.enabled ~= false)
    end
end

-- Spillerens justering (kun på serveren; klienter sender TLAdjustEvent). action: PlaceableTrafficLight.ADJUST.*;
-- approachId 0 = de forældede justeringer. Selve ændringen er TLGeometry.adjustOverrides (testet).
local ADJUST_NAMES = {[ADJUST.RESET] = "reset", [ADJUST.BACK] = "back", [ADJUST.FORWARD] = "forward", [ADJUST.TOGGLE] = "toggle"}
local ADJUST_LIMITS = {step = ADJUST_STEP_M, min = SHIFT_MIN_M, max = SHIFT_MAX_M}

function PlaceableTrafficLight:adjustApproach(approachId, action)
    local spec = self[SPEC]
    local name = ADJUST_NAMES[action]
    if spec == nil or name == nil or spec.intersection == nil then return end
    local approach = nil
    if approachId ~= 0 then
        for _, candidate in ipairs(spec.intersection.approaches or {}) do
            if candidate.id == approachId and not candidate.internal and candidate.stopLine ~= nil
                and TLGeometry.hasADLane(candidate) then approach = candidate end
        end
        if approach == nil then return end -- ukendt (krydset kan være bygget om imens) eller kun trafikspor
    end
    spec.overrides = TLGeometry.adjustOverrides(spec.overrides, approach, spec.staleOverrides, name, ADJUST_LIMITS)
    self:rebuildIntersection()
end
