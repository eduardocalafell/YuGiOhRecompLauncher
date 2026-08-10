-- icons.lua -- tiny procedural vector glyphs, drawn with love.graphics so the
-- launcher needs no image files. Every icon is drawn centred at (cx, cy) with
-- `s` as its half-extent (so it fits in a 2s x 2s box), in the given color.
-- Style: 2px stroke, rounded joins, occasional filled accent -- matching the
-- mockup's "line + filled hybrid, mystical" icon note.

local Icons = {}

local function setup(color, lw)
    love.graphics.setColor(color)
    love.graphics.setLineWidth(lw or 2)
    love.graphics.setLineJoin("bevel")
end

-- Eye of Wedjat-ish "millennium" mark: a stylised eye inside a ring. Used as
-- the app logo and on the PLAY button.
function Icons.eye(cx, cy, s, color)
    setup(color, 2)
    love.graphics.circle("line", cx, cy, s)
    -- almond eye
    love.graphics.push()
    love.graphics.translate(cx, cy)
    local w = s * 0.72
    love.graphics.line(-w, 0, 0, -s * 0.42, w, 0, 0, s * 0.42, -w, 0)
    love.graphics.circle("fill", 0, 0, s * 0.20)
    -- little tail (wedjat)
    love.graphics.line(w * 0.4, s * 0.30, w * 0.9, s * 0.62)
    love.graphics.pop()
end

function Icons.gear(cx, cy, s, color)
    setup(color, 2)
    local teeth = 8
    for i = 1, teeth do
        local a = (i / teeth) * math.pi * 2
        love.graphics.line(cx + math.cos(a) * s * 0.7, cy + math.sin(a) * s * 0.7,
            cx + math.cos(a) * s, cy + math.sin(a) * s)
    end
    love.graphics.circle("line", cx, cy, s * 0.55)
    love.graphics.circle("line", cx, cy, s * 0.18)
end

-- CPU/software chip: rounded square with pins.
function Icons.chip(cx, cy, s, color)
    setup(color, 2)
    love.graphics.rectangle("line", cx - s * 0.6, cy - s * 0.6, s * 1.2, s * 1.2, 2, 2)
    love.graphics.rectangle("line", cx - s * 0.28, cy - s * 0.28, s * 0.56, s * 0.56, 1, 1)
    for i = -1, 1 do
        love.graphics.line(cx + i * s * 0.3, cy - s * 0.6, cx + i * s * 0.3, cy - s * 0.85) -- top pins
        love.graphics.line(cx + i * s * 0.3, cy + s * 0.6, cx + i * s * 0.3, cy + s * 0.85) -- bottom
        love.graphics.line(cx - s * 0.6, cy + i * s * 0.3, cx - s * 0.85, cy + i * s * 0.3) -- left
        love.graphics.line(cx + s * 0.6, cy + i * s * 0.3, cx + s * 0.85, cy + i * s * 0.3) -- right
    end
end

-- OpenGL: a wireframe hexagon (cube-ish).
function Icons.hex(cx, cy, s, color)
    setup(color, 2)
    local pts = {}
    for i = 0, 5 do
        local a = (i / 6) * math.pi * 2 - math.pi / 2
        pts[#pts + 1] = cx + math.cos(a) * s
        pts[#pts + 1] = cy + math.sin(a) * s
    end
    love.graphics.polygon("line", pts)
    love.graphics.line(cx, cy - s, cx, cy + s)
    love.graphics.line(cx - s * 0.86, cy - s * 0.5, cx + s * 0.86, cy + s * 0.5)
    love.graphics.line(cx + s * 0.86, cy - s * 0.5, cx - s * 0.86, cy + s * 0.5)
end

-- Vulkan: a downward chevron/triangle mark.
function Icons.chevron(cx, cy, s, color)
    setup(color, 2)
    love.graphics.polygon("line", cx - s, cy - s * 0.6, cx, cy + s * 0.7, cx + s, cy - s * 0.6)
    love.graphics.polygon("line", cx - s * 0.5, cy - s * 0.75, cx, cy - s * 0.05, cx + s * 0.5, cy - s * 0.75)
end

-- Disc / compass rose used on the disc-image panel.
function Icons.disc(cx, cy, s, color)
    setup(color, 2)
    love.graphics.circle("line", cx, cy, s)
    love.graphics.circle("line", cx, cy, s * 0.18)
    -- compass star
    love.graphics.polygon("line", cx, cy - s * 0.75, cx + s * 0.16, cy - s * 0.16,
        cx + s * 0.75, cy, cx + s * 0.16, cy + s * 0.16, cx, cy + s * 0.75,
        cx - s * 0.16, cy + s * 0.16, cx - s * 0.75, cy, cx - s * 0.16, cy - s * 0.16)
end

-- Memory card glyph for save rows.
function Icons.memcard(cx, cy, s, color)
    setup(color, 2)
    local w, h = s * 1.3, s * 1.6
    love.graphics.rectangle("line", cx - w / 2, cy - h / 2, w, h, 2, 2)
    love.graphics.rectangle("line", cx - w * 0.28, cy - h * 0.34, w * 0.56, h * 0.30, 1, 1)
    love.graphics.line(cx - w * 0.28, cy + h * 0.10, cx + w * 0.28, cy + h * 0.10)
    love.graphics.line(cx - w * 0.28, cy + h * 0.26, cx + w * 0.28, cy + h * 0.26)
end

-- Download / backup arrow into a tray.
function Icons.download(cx, cy, s, color)
    setup(color, 2)
    love.graphics.line(cx, cy - s, cx, cy + s * 0.25)
    love.graphics.line(cx - s * 0.45, cy - s * 0.2, cx, cy + s * 0.25, cx + s * 0.45, cy - s * 0.2)
    love.graphics.line(cx - s * 0.8, cy + s * 0.5, cx - s * 0.8, cy + s * 0.85,
        cx + s * 0.8, cy + s * 0.85, cx + s * 0.8, cy + s * 0.5)
end

function Icons.folder(cx, cy, s, color)
    setup(color, 2)
    love.graphics.line(cx - s, cy - s * 0.5, cx - s * 0.2, cy - s * 0.5,
        cx + s * 0.05, cy - s * 0.8, cx + s, cy - s * 0.8)
    love.graphics.rectangle("line", cx - s, cy - s * 0.5, s * 2, s * 1.25, 2, 2)
end

function Icons.cloud(cx, cy, s, color)
    setup(color, 2)
    love.graphics.circle("line", cx - s * 0.35, cy, s * 0.5)
    love.graphics.circle("line", cx + s * 0.4, cy + s * 0.02, s * 0.42)
    love.graphics.circle("line", cx + s * 0.05, cy - s * 0.28, s * 0.5)
    love.graphics.setColor(0, 0, 0, 0) -- (no-op; kept for readability)
end

function Icons.check(cx, cy, s, color)
    setup(color, 2.5)
    love.graphics.line(cx - s * 0.7, cy, cx - s * 0.15, cy + s * 0.55, cx + s * 0.7, cy - s * 0.6)
end

function Icons.rocket(cx, cy, s, color)
    setup(color, 2)
    -- a small play/launch wedge
    love.graphics.polygon("fill", cx - s * 0.5, cy - s * 0.7, cx - s * 0.5, cy + s * 0.7, cx + s * 0.75, cy)
end

function Icons.bang(cx, cy, s, color)
    setup(color, 2.5)
    love.graphics.line(cx, cy - s * 0.7, cx, cy + s * 0.2)
    love.graphics.circle("fill", cx, cy + s * 0.6, s * 0.14)
end

function Icons.cross(cx, cy, s, color)
    setup(color, 2.5)
    love.graphics.line(cx - s * 0.6, cy - s * 0.6, cx + s * 0.6, cy + s * 0.6)
    love.graphics.line(cx + s * 0.6, cy - s * 0.6, cx - s * 0.6, cy + s * 0.6)
end

function Icons.book(cx, cy, s, color)
    setup(color, 2)
    love.graphics.line(cx, cy - s * 0.8, cx, cy + s * 0.8)
    love.graphics.line(cx, cy - s * 0.8, cx - s * 0.85, cy - s * 0.6, cx - s * 0.85, cy + s * 0.8, cx, cy + s * 0.6)
    love.graphics.line(cx, cy - s * 0.8, cx + s * 0.85, cy - s * 0.6, cx + s * 0.85, cy + s * 0.8, cx, cy + s * 0.6)
end

function Icons.chat(cx, cy, s, color)
    setup(color, 2)
    love.graphics.rectangle("line", cx - s, cy - s * 0.7, s * 2, s * 1.2, 3, 3)
    love.graphics.polygon("fill", cx - s * 0.4, cy + s * 0.5, cx - s * 0.1, cy + s * 0.5, cx - s * 0.5, cy + s * 0.9)
end

-- dispatch by name (used by the activity log + renderer selector)
function Icons.draw(name, cx, cy, s, color)
    local fn = Icons[name]
    if fn then fn(cx, cy, s, color) end
end

return Icons
