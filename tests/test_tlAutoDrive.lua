-- Kør: luajit tests/test_tlAutoDrive.lua   (fra repo-roden)
-- De rene AD-hjælpere; spil-delen af tlAutoDrive bruges ikke her.

getfenv = getfenv -- tlAutoDrive læser getfenv(0) ved indlæsning
dofile("FS25_TrafficLights/tlConfig.lua")
dofile("FS25_TrafficLights/tlAutoDrive.lua")

local failures = 0
local function check(name, actual, expected)
    if actual == expected then
        print("OK   " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL %s: forventede %s, fik %s", name, tostring(expected), tostring(actual)))
    end
end

-- A1: rute fra index med højst max punkter
local path = {}
for i = 1, 50 do path[i] = {id = i, x = i, z = 0} end
local route = TLAutoDrive.routeFromWayPoints(path, 10, 30)
check("A1 starter ved index", route[1].x, 10)
check("A1 højst max punkter", #route, 30)
check("A1 slutter ved listens ende", #TLAutoDrive.routeFromWayPoints(path, 45, 30), 6)
check("A1 nil-sti giver tom rute", #TLAutoDrive.routeFromWayPoints(nil, 1, 30), 0)

-- A2: tovejsforbindelse giver to rettede kanter
local wps = {
    [1] = {id = 1, x = 0, z = 0, out = {2}},
    [2] = {id = 2, x = 5, z = 0, out = {1}},
}
check("A2 to rettede kanter", #TLAutoDrive.edgesFromWayPoints(wps, {x = 0, z = 0}, 50), 2)

-- A3: kanter langt væk filtreres fra
wps[3] = {id = 3, x = 500, z = 0, out = {4}}
wps[4] = {id = 4, x = 505, z = 0, out = {}}
check("A3 fjern kant filtreret", #TLAutoDrive.edgesFromWayPoints(wps, {x = 0, z = 0}, 50), 2)
check("A3 kant med ét endepunkt inden for rækkevidde tages med", #TLAutoDrive.edgesFromWayPoints(
    {[1] = {id = 1, x = 49, z = 0, out = {2}}, [2] = {id = 2, x = 80, z = 0, out = {}}}, {x = 0, z = 0}, 50), 1)

-- A4: manglende out-id ignoreres
local broken = {[1] = {id = 1, x = 0, z = 0, out = {99}}}
check("A4 manglende vejpunkt ignoreres", #TLAutoDrive.edgesFromWayPoints(broken, {x = 0, z = 0}, 50), 0)

-- A5: tomt netværk
check("A5 tomt netværk", #TLAutoDrive.edgesFromWayPoints({}, {x = 0, z = 0}, 50), 0)
check("A5 nil-netværk", #TLAutoDrive.edgesFromWayPoints(nil, {x = 0, z = 0}, 50), 0)

-- uden AD: spil-delen er tavs
check("uden AD: ikke tilgængelig", TLAutoDrive.isAvailable(), false)
check("uden AD: ingen snapshots", #TLAutoDrive.snapshots(), 0)
check("uden AD: isHolding false", TrafficLights.isHolding({}), false)

print(failures == 0 and "\nALLE TESTS OK" or ("\n" .. failures .. " FEJL"))
os.exit(failures == 0 and 0 or 1)
