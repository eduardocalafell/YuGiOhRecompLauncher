function love.conf(t)
    t.identity = "ygo-recomp-launcher"
    t.version = "11.5"
    t.console = false -- love.exe stays windowed/silent; use lovec.exe for a debug console

    t.window.title = "ygo-recomp Launcher"
    t.window.width = 1000
    t.window.height = 720
    t.window.resizable = false
    t.window.vsync = 1

    t.modules.joystick = false
    t.modules.physics = false
    t.modules.video = false
end
