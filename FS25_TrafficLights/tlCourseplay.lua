-- Courseplay (spec 5.1/5.7): aktive CP-køretøjer som snapshots og hold for rødt via CP's egen cpHold.
-- CP er valgfri: uden CP findes metoderne ikke på køretøjerne, og alt returnerer tomt.
-- cpHold(ms) udløber af sig selv, så et køretøj aldrig bliver hængende, hvis lyskurven fejler.
-- (Ikke bevist i spillet endnu — krav før udgivelse, spec 5.12.)
TLCourseplay = {}

local ROUTE_POINTS = 30

local function isCpActive(vehicle)
    if vehicle.getIsCpActive == nil or vehicle.getCpDriveStrategy == nil then return false end
    local ok, active = pcall(vehicle.getIsCpActive, vehicle)
    return ok and active == true
end

local function vehicleFront(vehicle)
    local node = vehicle.rootNode
    if node == nil or not entityExists(node) then return nil end
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local half = (vehicle.size ~= nil and vehicle.size.length or 6) / 2
    return {x = x + dx * half, z = z + dz * half}
end

-- De næste kurspunkter fra den aktuelle position. Baglæns kørsel (rev) afbryder ruten: et køretøj, der
-- bakker, krydser ikke en stoplinje fremad.
local function upcomingRoute(strategy)
    local course = strategy.getCurrentCourse ~= nil and strategy:getCurrentCourse() or nil
    local ppc = strategy.ppc
    if course == nil or ppc == nil or ppc.getCurrentWaypointIx == nil then return nil end
    local ix = ppc:getCurrentWaypointIx()
    if ix == nil then return nil end
    local route = {}
    local last = math.min(course:getNumberOfWaypoints(), ix + ROUTE_POINTS - 1)
    for i = ix, last do
        if course.isReverseAt ~= nil and course:isReverseAt(i) then break end
        local x, _, z = course:getWaypointPosition(i)
        if x == nil or z == nil then break end
        table.insert(route, {x = x, z = z})
    end
    return #route > 0 and route or nil
end

function TLCourseplay.snapshots()
    if g_server == nil or g_currentMission == nil or g_currentMission.vehicleSystem == nil then return {} end
    local snapshots = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if isCpActive(vehicle) then
            local ok, snapshot = pcall(function()
                local front = vehicleFront(vehicle)
                local strategy = vehicle:getCpDriveStrategy()
                if front == nil or strategy == nil then return nil end
                local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() / 3.6 or 0
                -- rute kun under transit ud til marken: under markarbejde er kursen markbanen, og en mark tæt
                -- ved et kryds måtte ikke få traktoren holdt (review). Aflæsseren (UnloadCombine) kører på
                -- pathfinder-kurser og tages med, når den kan testes i spillet.
                local inTransit = vehicle.getIsCpDriveToFieldWorkActive ~= nil and vehicle:getIsCpDriveToFieldWorkActive()
                return {key = vehicle, kind = "CP", name = vehicle.getName ~= nil and vehicle:getName() or "CP",
                    pos = front, speed = speed, route = inTransit and upcomingRoute(strategy) or nil}
            end)
            if ok and snapshot ~= nil then table.insert(snapshots, snapshot) end
        end
    end
    return snapshots
end

function TLCourseplay.hold(vehicle)
    if vehicle == nil or vehicle.cpHold == nil then return end
    pcall(vehicle.cpHold, vehicle, TLConfig.CP_HOLD_MS)
end
