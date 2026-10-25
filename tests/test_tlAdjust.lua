-- Kør: luajit tests/test_tlAdjust.lua   (fra repo-roden)
-- Justeringsvisningens rene dele: nærmeste lyskryds, valg af indkørsel og statuslinjen.

dofile("FS25_TrafficLights/tlAdjust.lua")

local failures = 0
local function check(name, actual, expected)
    if actual == expected then
        print("OK   " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL %s: forventede %s, fik %s", name, tostring(expected), tostring(actual)))
    end
end

local lightA = {stops = {{id = 1, x = 0, z = 0}, {id = 2, x = 10, z = 0}}}
local lightB = {stops = {{id = 1, x = 100, z = 0}}}
local lights = {{key = "A", layout = lightA}, {key = "B", layout = lightB}}

-- A1: nærmeste lyskryds inden for rækkevidde, målt til nærmeste stoplinje
check("A1 nærmest A", TLAdjust.nearestLight(lights, 12, 3, 30), "A")
check("A1 nærmest B", TLAdjust.nearestLight(lights, 95, 0, 30), "B")
check("A1 udenfor rækkevidde", TLAdjust.nearestLight(lights, 50, 50, 30), nil)
check("A1 lyskryds uden layout springes over", TLAdjust.nearestLight({{key = "C", layout = nil}}, 0, 0, 30), nil)

-- A2: valgmuligheder: indkørslerne sorteret efter id, plus "forældede", når der er nogen
local entries = TLAdjust.entries({stops = {{id = 3}, {id = 1}}, stale = 0})
check("A2 sorteret", entries[1].id == 1 and entries[2].id == 3, true)
check("A2 ingen forældede", #entries, 2)
entries = TLAdjust.entries({stops = {{id = 1}}, stale = 2})
check("A2 forældede som sidste valg", #entries == 2 and entries[2].stale == true and entries[2].id == 0, true)
check("A2 tomt layout", #TLAdjust.entries(nil), 0)

-- A3: næste valg går rundt
check("A3 næste", TLAdjust.nextIndex(1, 3), 2)
check("A3 rundt", TLAdjust.nextIndex(3, 3), 1)
check("A3 tom liste", TLAdjust.nextIndex(1, 0), 1)

-- A4: statuslinjen (tekster sendes ind, så testen ikke kræver spillets i18n)
local texts = {approach = "Indkørsel %d", shifted = "flyttet %+.1f m", off = "intet lys", stale = "%d forældede justeringer - nulstil sletter dem"}
check("A4 uden justering", TLAdjust.statusLine({id = 2, enabled = true, shift = 0}, texts), "Indkørsel 2")
check("A4 flyttet", TLAdjust.statusLine({id = 2, enabled = true, shift = 1.5}, texts), "Indkørsel 2 - flyttet +1.5 m")
check("A4 frakoblet", TLAdjust.statusLine({id = 4, enabled = false, shift = -2}, texts), "Indkørsel 4 - flyttet -2.0 m - intet lys")
check("A4 forældede", TLAdjust.statusLine({id = 0, stale = true, count = 2}, texts), "2 forældede justeringer - nulstil sletter dem")

print(failures == 0 and "\nALLE TESTS OK" or ("\n" .. failures .. " FEJL"))
os.exit(failures == 0 and 0 or 1)
