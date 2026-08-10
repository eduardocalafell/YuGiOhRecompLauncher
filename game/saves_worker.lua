-- saves_worker.lua -- background LÖVE thread.
--
-- core.list_saves() now enumerates the directory in-process via the Win32
-- FFI (FindFirstFile) -- microseconds, no subprocess -- so this thread is no
-- longer load-bearing the way it was when list_saves shelled out to
-- `cmd /c dir` (once measured at 5.7s under CPU contention, which froze the
-- UI when run on the main thread). It's kept as cheap insurance: enumeration
-- of an unexpectedly huge or network-backed saves\ folder still can't stall
-- love.draw()/mousepressed, because it happens off the main thread.
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
