-- Kør: luajit tests/test_tlTraffic.lua   (fra repo-roden)
-- tlTraffic med en falsk motor: spærring bevarer sporets felter og kalder kun motoren ved ændring.

local calls = {}
g_server = {}
g_currentMission = {trafficSystem = {trafficSystemId = 7}}
setTrafficSystemBlockingPositionState = function(tsId, splineId, splineTime, blocked)
    table.insert(calls, {tsId, splineId, splineTime, blocked})
end
findTrafficSystemBlockingPositionInformation = function() return 46230, 0.5 end
dofile("FS25_TrafficLights/tlConfig.lua")
TLConfig.DEBUG = false
dofile("FS25_TrafficLights/tlTraffic.lua")

local failures = 0
local function check(name, actual, expected)
    if actual == expected then
        print("OK   " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL %s: forventede %s, fik %s", name, tostring(expected), tostring(actual)))
    end
end

local lane = {kind = "TRAFFIC", splineId = 46230, splineTime = 0.70051497220993042, blocked = false}
local blocked = TLTraffic.setBlocked(lane, true)
check("T1 kind bevaret efter spærring", blocked.kind, "TRAFFIC")
check("T1 spærret", blocked.blocked, true)
check("T1 eksakt splineTime sendt til motoren", calls[1][3], 0.70051497220993042)
check("T1 input uændret", lane.blocked, false)
local again = TLTraffic.setBlocked(blocked, true)
check("T2 ingen ændring -> intet motorkald", #calls, 1)
local opened = TLTraffic.setBlocked(again, false)
check("T3 åbnet", opened.blocked, false)
check("T3 kind bevaret efter åbning", opened.kind, "TRAFFIC")
check("T3 motorkald med false", calls[2][4], false)
local released = TLTraffic.releaseAll({TLTraffic.setBlocked(opened, true)})
check("T4 releaseAll åbner og bevarer kind", released[1].blocked == false and released[1].kind == "TRAFFIC", true)

print(failures == 0 and "\nALLE TESTS OK" or ("\n" .. failures .. " FEJL"))
os.exit(failures == 0 and 0 or 1)
