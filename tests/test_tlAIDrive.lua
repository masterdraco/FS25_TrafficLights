-- Kør: luajit tests/test_tlAIDrive.lua   (fra repo-roden)
-- Spillets egen AI-kørsel (hjælpere og Courseplays vejtur): lige rute frem og hold via driveAlongCurvature.

dofile("FS25_TrafficLights/tlConfig.lua")
dofile("FS25_TrafficLights/tlAIDrive.lua")

local failures = 0
local function check(name, actual, expected)
    if actual == expected then
        print("OK   " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL %s: forventede %s, fik %s", name, tostring(expected), tostring(actual)))
    end
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- I1: lige rute frem fra fronten i køreretningen
local route = TLAIDrive.straightRoute({x = 10, z = 20}, 1, 0)
check("I1 første punkt et skridt frem", near(route[1].x, 10 + TLAIDrive.ROUTE_STEP_M) and near(route[1].z, 20), true)
check("I1 sidste punkt ROUTE_AHEAD_M frem", near(route[#route].x, 10 + TLAIDrive.ROUTE_AHEAD_M), true)
check("I1 antal punkter", #route, TLAIDrive.ROUTE_AHEAD_M / TLAIDrive.ROUTE_STEP_M)
local diagonal = TLAIDrive.straightRoute({x = 0, z = 0}, 3, 4) -- ikke-normaliseret retning
check("I1 retningen normaliseres", near(diagonal[1].x, 0.6 * TLAIDrive.ROUTE_STEP_M) and near(diagonal[1].z, 0.8 * TLAIDrive.ROUTE_STEP_M), true)
check("I1 nul-retning giver ingen rute", TLAIDrive.straightRoute({x = 0, z = 0}, 0, 0), nil)

-- I2: holdet sætter farten til 0 og nulstiller blokeret-tælleren, så hjælperen ikke meldes "blokeret"
g_time = 1000
local calls = {}
AIVehicleUtil = {driveAlongCurvature = function(vehicle, dt, curvature, maxSpeed, acceleration)
    table.insert(calls, maxSpeed)
end}
check("I2 krogen installeres", TLAIDrive.installHoldHook(), true)
check("I2 krogen installeres kun én gang", TLAIDrive.installHoldHook(), true)
local tractor = {spec_aiDrivable = {stuckTime = 4000}}
AIVehicleUtil.driveAlongCurvature(tractor, 16, 0, 30, 1)
check("I2 uholdt kører med sin fart", calls[1], 30)
TLAIDrive.hold(tractor)
AIVehicleUtil.driveAlongCurvature(tractor, 16, 0, 30, 1)
check("I2 holdt får fart 0", calls[2], 0)
check("I2 holdt nulstiller stuckTime", tractor.spec_aiDrivable.stuckTime, 0)
check("I2 kun ét lag krog (dobbelt installation)", #calls, 2)
local braked = {}
local truck = {spec_aiDrivable = {stuckTime = 3000},
    stopAIDriving = function(self) braked.stopped = true end,
    brake = function(self, pedal) braked.pedal = pedal end}
TLAIDrive.hold(truck)
AIVehicleUtil.driveAlongCurvature(truck, 16, 0, 30, 1)
check("I2 med bremse: spillets kørsel springes over", #calls, 2)
check("I2 med bremse: stopAIDriving", braked.stopped, true)
check("I2 med bremse: fuld bremse", braked.pedal, 1)
check("I2 med bremse: stuckTime nulstillet", truck.spec_aiDrivable.stuckTime, 0)

-- I3: holdet udløber af sig selv (ingen hængende traktor, hvis lyskurven fejler)
g_time = 1000 + TLConfig.AI_HOLD_MS + 1
AIVehicleUtil.driveAlongCurvature(tractor, 16, 0, 30, 1)
check("I3 udløbet hold kører igen", calls[3], 30)
check("I3 udløbet hold er glemt", TLAIDrive.isHeld(tractor), false)

-- I4: andre køretøjer påvirkes ikke
local other = {spec_aiDrivable = {stuckTime = 0}}
TLAIDrive.hold(tractor)
AIVehicleUtil.driveAlongCurvature(other, 16, 0, 25, 1)
check("I4 andet køretøj kører frit", calls[4], 25)

-- I5: uden spillets AI-modul installeres intet, og der kommer ingen fejl
AIVehicleUtil = nil
TLAIDrive.hookInstalled = false
check("I5 ingen AIVehicleUtil -> false", TLAIDrive.installHoldHook(), false)

if failures > 0 then
    print(string.format("%d FEJL", failures))
    os.exit(1)
end
print("ALLE TESTS OK")
