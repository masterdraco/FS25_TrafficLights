-- Justering af stoplinjer fra en klient (spec 5.8/5.9, Task 11): klient -> server. Serveren ændrer justeringen,
-- bygger krydset om og sender det nye layout til alle (publishLayout).
TLAdjustEvent = {}
local TLAdjustEvent_mt = Class(TLAdjustEvent, Event)

local ID_BITS = 8
local ACTION_BITS = 2

function TLAdjustEvent.emptyNew()
    return Event.new(TLAdjustEvent_mt)
end

function TLAdjustEvent.new(placeable, approachId, action)
    local self = TLAdjustEvent.emptyNew()
    self.placeable = placeable
    self.approachId = approachId
    self.action = action
    return self
end

function TLAdjustEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteUIntN(streamId, self.approachId, ID_BITS)
    streamWriteUIntN(streamId, self.action, ACTION_BITS)
end

function TLAdjustEvent:readStream(streamId, connection)
    self.placeable = NetworkUtil.readNodeObject(streamId)
    self.approachId = streamReadUIntN(streamId, ID_BITS)
    self.action = streamReadUIntN(streamId, ACTION_BITS)
    self:run(connection)
end

function TLAdjustEvent:run(connection)
    if connection:getIsServer() then return end -- kun klient -> server
    if self.placeable ~= nil and self.placeable:getIsSynchronized() and self.placeable.adjustApproach ~= nil then
        self.placeable:adjustApproach(self.approachId, self.action)
    end
end

-- Fra spilleren: på serveren (singleplayer/vært) direkte, ellers som event.
function TLAdjustEvent.send(placeable, approachId, action)
    if g_server ~= nil then
        placeable:adjustApproach(approachId, action)
    else
        g_client:getServerConnection():sendEvent(TLAdjustEvent.new(placeable, approachId, action))
    end
end

InitEventClass(TLAdjustEvent, "TLAdjustEvent")
