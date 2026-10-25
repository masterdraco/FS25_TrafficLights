-- Spillets egen AI-kørsel (AIDrivable/AITaskDriveTo): hjælpere og Courseplays vejtur ud til marken.
-- CP kører først til det valgte mål med spillets AI og har dér ingen drive strategy, så cpHold virker ikke
-- (CpAIJob:setupTasks + CpAIWorker:cpHold, set i CP's kilde 25/10). Spillets AI viser ikke sin rute til
-- Lua, så ruten er en lige linje frem fra fronten — nok til at ramme stoplinjen på den lige indkørsel.
-- Hold: krog på AIVehicleUtil.driveAlongCurvature (kaldes hver frame fra AIDrivable:onUpdate), der sætter
-- farten til 0, mens holdet gælder. Holdet udløber af sig selv efter AI_HOLD_MS ligesom cpHold.
-- (Ikke bevist i spillet endnu.)
TLAIDrive = {}

TLAIDrive.ROUTE_STEP_M = 5
TLAIDrive.ROUTE_AHEAD_M = 60     -- = DEMAND_DISTANCE: efterspørgslen skal kunne ses lige så tidligt som AD's
TLAIDrive.hookInstalled = false

local heldUntil = setmetatable({}, {__mode = "k"}) -- køretøj -> g_time, hvor holdet udløber

-- Punkter frem fra front i retningen (dirX, dirZ); nil hvis retningen er nul.
function TLAIDrive.straightRoute(front, dirX, dirZ)
    local length = math.sqrt(dirX * dirX + dirZ * dirZ)
    if length < 1e-6 then return nil end
    local ux, uz = dirX / length, dirZ / length
    local route = {}
    for d = TLAIDrive.ROUTE_STEP_M, TLAIDrive.ROUTE_AHEAD_M, TLAIDrive.ROUTE_STEP_M do
        table.insert(route, {x = front.x + ux * d, z = front.z + uz * d})
    end
    return route
end

function TLAIDrive.hold(vehicle)
    if vehicle ~= nil then heldUntil[vehicle] = g_time + TLConfig.AI_HOLD_MS end
end

function TLAIDrive.isHeld(vehicle)
    local untilMs = heldUntil[vehicle]
    if untilMs == nil then return false end
    if g_time < untilMs then return true end
    heldUntil[vehicle] = nil
    return false
end

-- Sætter krogen én gang; false hvis spillets AI-modul ikke findes.
function TLAIDrive.installHoldHook()
    if TLAIDrive.hookInstalled then return true end
    if AIVehicleUtil == nil or type(AIVehicleUtil.driveAlongCurvature) ~= "function" then return false end
    local original = AIVehicleUtil.driveAlongCurvature
    AIVehicleUtil.driveAlongCurvature = function(vehicle, dt, curvature, maxSpeed, acceleration)
        if TLAIDrive.isHeld(vehicle) then
            -- et rødt lys er ikke en blokering: ellers melder spillet hjælperen "blokeret" efter 5 s
            if vehicle.spec_aiDrivable ~= nil then vehicle.spec_aiDrivable.stuckTime = 0 end
            -- fuld bremse som spillets egen PLANNING-tilstand (AIDrivable:onUpdate); fart 0 alene bremser
            -- kun svagt ved fart (review)
            if vehicle.stopAIDriving ~= nil and vehicle.brake ~= nil then
                vehicle:stopAIDriving()
                vehicle:brake(1)
                return
            end
            maxSpeed = 0
        end
        return original(vehicle, dt, curvature, maxSpeed, acceleration)
    end
    TLAIDrive.hookInstalled = true
    return true
end

-- Kører med spillets AI-navigation lige nu (ikke den manuelle slutmanøvre ved målet).
local function isNavigating(vehicle)
    local spec = vehicle.spec_aiDrivable
    return spec ~= nil and spec.isRunning == true and not spec.useManualDriving
end

local function snapshotOf(vehicle)
    local node = vehicle.rootNode
    if node == nil or not entityExists(node) then return nil end
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local half = (vehicle.size ~= nil and vehicle.size.length or 6) / 2
    local front = {x = x + dx * half, z = z + dz * half}
    -- bakker den, krydser den ikke en stoplinje fremad
    local reversing = vehicle.movingDirection ~= nil and vehicle.movingDirection < 0
    return {key = vehicle, kind = "AI", name = vehicle.getName ~= nil and vehicle:getName() or "AI",
        pos = front, speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() / 3.6 or 0,
        route = not reversing and TLAIDrive.straightRoute(front, dx, dz) or nil}
end

function TLAIDrive.snapshots()
    if g_server == nil or g_currentMission == nil or g_currentMission.vehicleSystem == nil then return {} end
    local snapshots = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if isNavigating(vehicle) then
            local ok, snapshot = pcall(snapshotOf, vehicle)
            if ok and snapshot ~= nil then table.insert(snapshots, snapshot) end
        end
    end
    return snapshots
end
