function love.conf(t)
    t.identity = "ygo-recomp-launcher"
    t.version = "11.5"
    t.console = false -- love.exe stays windowed/silent; use lovec.exe for a debug console

    t.window.title = "ygo-recomp Launcher"
    t.window.width = 1120
    t.window.height = 860
    t.window.minwidth = 1000
    t.window.minheight = 740
    t.window.resizable = true
    t.window.vsync = 1

    t.modules.joystick = false
    t.modules.physics = false
    t.modules.video = false
end
