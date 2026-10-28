-- Fejlsikring i TLManager.tick uden pcall (ModHub): en kastende lyskurv slippes og pauses, de andre kører videre.
-- Simulerer TLManager.tick med en lyskurv, der kaster: den skal slippes og pauses, de andre skal køre videre.
package.path = "FS25_TrafficLights/?.lua;" .. package.path
Logging = {warning = function(...) LOGGED = (LOGGED or 0) + 1 end, info = function() end}
TLConfig = {TICK_MS = 250}
TLAutoDrive = {snapshots = function() return {} end, installHoldHook = function() return true end, uninstall = function() end}
TLCourseplay = {snapshots = function() return {} end}
TLAIDrive = {snapshots = function() return {} end, installHoldHook = function() return false end}
TLVisuals = {update = function() end, releaseAssets = function() end}
g_server = true; g_time = 0
addModEventListener = function() end
dofile("FS25_TrafficLights/tlManager.lua")
local function light(name, throws)
    return {name = name, released = 0, ticks = 0, throws = throws,
        getTrafficLightSpec = function() return nil end,
        releaseTrafficLight = function(self) self.released = self.released + 1 end,
        runTrafficLightTick = function(self, _, _, _, holds)
            self.ticks = self.ticks + 1
            if self.throws then error("boom") end
            holds["veh_" .. self.name] = true
        end}
end
local good, bad = light("good", false), light("bad", true)
TLManager.lights = {[bad] = true, [good] = true}
local function step(ms) g_time = ms; TLManager.sinceTickMs = 1000; local ok = pcall(TLManager.update, TLManager, 0); return ok end
local ok1 = step(1000)
assert(ok1 == false, "første takt skal kaste (fejlen når loggen)")
assert(bad.released == 0 and TLManager.tickState[bad].running == true, "flag står efter fejl")
local ok2 = step(1250)
assert(ok2 == true, "anden takt kører rent: " .. tostring(ok2))
assert(bad.released == 1, "den fejlende slippes: " .. bad.released)
assert(bad.ticks == 1, "den fejlende pauses: " .. bad.ticks)
assert(good.ticks >= 1 and TLManager.holdLookup["veh_good"] == true, "den gode kører videre med hold")
assert(TLManager.holdLookup["veh_bad"] == nil)
step(5000); assert(bad.ticks == 1, "stadig pause")
step(12000); assert(bad.ticks == 2, "prøver igen efter pausen: " .. bad.ticks)
step(12250); assert(bad.released == 2, "slippes igen efter ny fejl")
print("FAILSAFE OK (warnings logget: " .. tostring(LOGGED) .. ")")
