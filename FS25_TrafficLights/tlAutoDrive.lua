-- AutoDrive: netværk omkring krydset, AD-køretøjer som snapshots og hold for rødt (spec 5.1/5.3/5.7).
-- AD er valgfri: uden AD returnerer alt tomt og intet logges som fejl.
-- Hold: wrapper om ADCollisionDetectionModule.hasDetectedObstable returnerer true i stopzonen og
-- sætter ALDRIG self.detectedObstable (ADSmartPickup's ADHeadOn læser feltet og bakker efter 60 s).
TLAutoDrive = {}

local G = getfenv(0)
local ROUTE_POINTS = 30
G.TrafficLights = G.TrafficLights or {}
G.TrafficLights.shouldHoldAD = nil -- en hold-funktion fra en tidligere indlæsning må ikke leve videre (review)
local LOG_PREFIX = "[TrafficLights] "

-- Rene hjælpere (testes i tests/test_tlAutoDrive.lua) ---------------------------------------------

-- De næste højst max rutepunkter fra index (inklusive), som {x, z}.
function TLAutoDrive.routeFromWayPoints(wayPoints, index, max)
    local route = {}
    if wayPoints == nil or index == nil then return route end
    for i = math.max(1, index), math.min(#wayPoints, index + max - 1) do
        local wp = wayPoints[i]
        if wp ~= nil and wp.x ~= nil and wp.z ~= nil then table.insert(route, {x = wp.x, z = wp.z}) end
    end
    return route
end

-- Rettede kanter (a -> b for hvert out-id), hvor mindst ét endepunkt ligger inden for reach af center.
-- wps er AD's vejpunkt-tabel indekseret med id.
function TLAutoDrive.edgesFromWayPoints(wps, center, reach)
    local edges = {}
    local reachSq = reach * reach
    local function near(wp) return (wp.x - center.x) ^ 2 + (wp.z - center.z) ^ 2 <= reachSq end
    for _, wp in pairs(wps or {}) do
        if type(wp) == "table" and wp.x ~= nil and wp.z ~= nil then
            for _, outId in ipairs(wp.out or {}) do
                local target = wps[outId]
                if target ~= nil and target.x ~= nil and (near(wp) or near(target)) then
                    table.insert(edges, {a = {x = wp.x, z = wp.z}, b = {x = target.x, z = target.z}})
                end
            end
        end
    end
    return edges
end

-- Spil-delen ------------------------------------------------------------------------------------

local function adEnv()
    local env = G.FS25_AutoDrive
    if env ~= nil and env.ADGraphManager ~= nil and env.AutoDrive ~= nil then return env end
    return nil
end

function TLAutoDrive.isAvailable()
    return adEnv() ~= nil
end

function TLAutoDrive.edgesNear(center, radius)
    local env = adEnv()
    if env == nil then return {} end
    if env.ADGraphManager == nil or env.ADGraphManager.getWayPoints == nil then return {} end
    local wps = env.ADGraphManager:getWayPoints()
    return TLAutoDrive.edgesFromWayPoints(wps, center, radius + TLConfig.DEMAND_DISTANCE)
end

-- Ændringsindikator (tal): 0 = intet netværk endnu; ellers 1 + antal markChanges siden hooket kom på.
-- AD kalder markChanges ved hver redigering og ved indlæsning (GraphManager.lua: setWayPoints m.fl.).
local changeCounter = 0

local function installChangeCounter(env)
    local manager = env.ADGraphManager
    if rawget(manager, "__trafficLightsMarkChanges") ~= nil then return end
    rawset(manager, "__trafficLightsMarkChanges", manager.markChanges)
    manager.markChanges = function(self, ...)
        changeCounter = changeCounter + 1
        return manager.__trafficLightsMarkChanges(self, ...)
    end
end

function TLAutoDrive.networkVersion()
    local env = adEnv()
    if env == nil then return 0 end
    installChangeCounter(env)
    local wps = env.ADGraphManager.wayPoints
    if wps == nil or #wps == 0 then return 0 end
    return changeCounter + 1
end

local function vehicleFront(vehicle)
    -- AD's egen frontNode tager højde for lengthOffset og knækstyring (AD Specialization.lua)
    local frontNode = vehicle.ad ~= nil and vehicle.ad.frontNode or nil
    if frontNode ~= nil and entityExists(frontNode) then
        local x, _, z = getWorldTranslation(frontNode)
        return {x = x, z = z}
    end
    local node = vehicle.rootNode or (vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node)
    if node == nil or not entityExists(node) then return nil end
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local half = (vehicle.size ~= nil and vehicle.size.length or 6) / 2
    return {x = x + dx * half, z = z + dz * half}
end

local function trainLength(env, vehicle)
    if env.AutoDrive.getTractorTrainLength == nil then return nil end
    local length = env.AutoDrive.getTractorTrainLength(vehicle, true, false)
    if type(length) == "number" and length > 0 then return length end
    return nil
end

local function isDrivingRoute(ad)
    if ad == nil or ad.stateModule == nil or not ad.stateModule:isActive() then return false end
    local dpm = ad.drivePathModule
    if dpm == nil or dpm.wayPoints == nil then return false end
    return not (dpm.isTargetReached ~= nil and dpm:isTargetReached())
end

-- Snapshot for hvert AD-køretøj. route kun mens det aktivt kører mod et mål (tlDemand-kontrakten).
local function isCourseplayDriving(vehicle)
    if vehicle.getIsCpActive == nil then return false end
    return vehicle:getIsCpActive() == true
end

local function isGameAINavigating(vehicle)
    local spec = vehicle.spec_aiDrivable
    return spec ~= nil and spec.isRunning == true and not spec.useManualDriving
end

function TLAutoDrive.snapshots()
    local env = adEnv()
    if g_server == nil or env == nil then return {} end
    local snapshots = {}
    for _, vehicle in pairs(env.AutoDrive.getAllVehicles()) do
        local ad = vehicle.ad
        -- anhængere har også .ad (uden stateModule); CP-kørende køretøjer kommer fra tlCourseplay (review),
        -- og køretøjer på spillets AI-navigation fra tlAIDrive (samme nøgle to gange ville blande sporingen)
        if ad ~= nil and ad.stateModule ~= nil and not isCourseplayDriving(vehicle) and not isGameAINavigating(vehicle) then
            local front = vehicleFront(vehicle)
            if front ~= nil then
                local route = nil
                if isDrivingRoute(ad) then
                    local wayPoints, index = ad.drivePathModule:getWayPoints()
                    route = TLAutoDrive.routeFromWayPoints(wayPoints, index, ROUTE_POINTS)
                end
                local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() / 3.6 or 0
                table.insert(snapshots, {key = vehicle, kind = "AD", name = vehicle.getName ~= nil and vehicle:getName() or "AD",
                    pos = front, speed = speed, route = route, length = trainLength(env, vehicle)})
            end
        end
    end
    return snapshots
end

-- Holdet: shouldHold(vehicle) -> bool. Installeres én gang pr. spilsession (flag i spillets globale tabel
-- overlever en genindlæsning af modden uden genstart).
TLAutoDrive.shouldHold = nil

function TLAutoDrive.installHoldHook(shouldHold)
    TLAutoDrive.shouldHold = shouldHold
    local env = adEnv()
    local module = env ~= nil and env.ADCollisionDetectionModule or nil
    if module == nil or module.hasDetectedObstable == nil then return false end
    if rawget(module, "__trafficLightsOriginal") == nil then
        rawset(module, "__trafficLightsOriginal", module.hasDetectedObstable)
        module.hasDetectedObstable = function(self, dt)
            local blocked = module.__trafficLightsOriginal(self, dt)
            if blocked then return blocked end
            local hook = G.TrafficLights ~= nil and G.TrafficLights.shouldHoldAD or nil
            if hook ~= nil then
                if hook(self.vehicle) then return true end
            end
            return blocked
        end
        Logging.info("%sAutoDrive hold installed", LOG_PREFIX)
    end
    -- AD's vejpunkt-regel (detectAdTrafficOnRoute) lader et køretøj vente på et andet, hvis ruterne fletter
    -- (fælles vejpunkt). En bil, der holder for rødt ved stoplinjen, har sine næste vejpunkter inde i
    -- krydset, så bilen inde i krydset ventede på den — og den holdende på et tomt kryds (lås in-game 25/10).
    -- Reglen ophæves KUN når den, der ventes på, holdes af lyskurven; ellers gælder AD's regel uændret.
    if module.detectAdTrafficOnRoute ~= nil and rawget(module, "__trafficLightsTrafficOriginal") == nil then
        rawset(module, "__trafficLightsTrafficOriginal", module.detectAdTrafficOnRoute)
        module.detectAdTrafficOnRoute = function(self, ...)
            local waiting = module.__trafficLightsTrafficOriginal(self, ...)
            if waiting and self.trafficVehicle ~= nil then
                local hook = G.TrafficLights ~= nil and G.TrafficLights.shouldHoldAD or nil
                if hook ~= nil then
                    if hook(self.trafficVehicle) then
                        self.trafficVehicle = nil -- andre må ikke tro, at vi selv venter (review)
                        return false
                    end
                end
            end
            return waiting
        end
    end
    G.TrafficLights = G.TrafficLights or {}
    G.TrafficLights.shouldHoldAD = shouldHold
    return true
end

-- Offentlig API for andre mods (fx ADSmartPickup's ADHeadOn): holder lyskurven dette køretøj?
function TLAutoDrive.uninstall()
    TLAutoDrive.shouldHold = nil
    G.TrafficLights.shouldHoldAD = nil
end

G.TrafficLights.isHolding = function(vehicle)
    local hook = G.TrafficLights.shouldHoldAD
    if hook == nil or vehicle == nil then return false end
    return hook(vehicle) == true
end
