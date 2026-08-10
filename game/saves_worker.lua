-- saves_worker.lua -- background LÖVE thread.
--
-- core.list_saves() shells out (`cmd /c dir`), which is normally a few ms
-- but was measured taking 5.7s while the recompiled game itself was busy on
-- CPU in the background (see launcher-debug.log from that run) -- and any
-- shell-out run on the main thread blocks love.draw()/mousepressed for
-- however long it takes, i.e. the launcher window freezes. Running it here
-- means a slow spell under contention delays when the save list updates,
-- but never freezes the UI itself.
--
-- core.lua has no love.* dependencies by design, so it's safe to require
-- straight into this separate thread state.
local core = require("core")

local requestChannel = love.thread.getChannel("saves_refresh_request")
local resultChannel = love.thread.getChannel("saves_refresh_result")

while true do
    requestChannel:demand() -- blocks here until the main thread asks for one
    while requestChannel:pop() do end -- collapse any requests queued up during a slow pass

    local names = core.list_saves()
    local list = {}
    for _, name in ipairs(names) do
        list[#list + 1] = { name = name, size = core.file_size(core.SAVES_DIR .. name) }
    end
    resultChannel:push(list)
end
