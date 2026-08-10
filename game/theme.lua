-- theme.lua -- design tokens + stateless draw helpers for the ygo-recomp
-- launcher. Everything here is procedural (no external image assets), so the
-- launcher stays a single self-contained LÖVE project while still hitting the
-- "arcane gold / obsidian" art direction from the design guide.
--
-- Fonts are NOT created here (they need love.graphics, created once in
-- main.lua's love.load and passed in where needed). This module is pure
-- tokens + drawing functions that take explicit args, so it can't get into a
-- half-initialised state.

local Theme = {}

-- ------------------------------------------------------------ color tokens
-- (straight from the design guide's Theme.colors, 0..1 floats)
Theme.color = {
    obsidian  = { 0.043, 0.055, 0.078 },   -- #0B0E14  darkest bg
    midnight  = { 0.078, 0.102, 0.169 },   -- #141A2B  panel base
    indigo    = { 0.122, 0.141, 0.251 },   -- #1F2440  raised panel / active fill
    violet    = { 0.482, 0.361, 1.000 },   -- #7B5CFF  primary accent / energy
    gold      = { 0.847, 0.706, 0.388 },   -- #DBB463  arcane gold / titles / frames
    cyan      = { 0.286, 0.843, 1.000 },   -- #49D7FF  info
    success   = { 0.180, 0.800, 0.443 },   -- #2ECC71  ok / configured
    warn      = { 0.90,  0.72,  0.30  },   -- amber
    danger    = { 0.85,  0.32,  0.36  },   -- red
    text      = { 0.900, 0.920, 0.950 },   -- primary text
    textMuted = { 0.643, 0.675, 0.722 },   -- #A4ACB8 secondary
    border    = { 0.165, 0.196, 0.282 },   -- #2A3248 hairline borders
}

Theme.spacing = { xs = 8, sm = 16, md = 24, lg = 32, xl = 48, xxl = 64 }
Theme.radius  = { small = 5, medium = 8, large = 12 }

-- rgba() -> a color table with an alpha override, without mutating the token.
function Theme.rgba(c, a)
    return { c[1], c[2], c[3], a or 1 }
end

-- ---------------------------------------------------------------- helpers

-- A soft "bloom" behind a rounded rect: several translucent, progressively
-- larger rounded rectangles of `color`. Cheap fake glow, no shader needed.
function Theme.glow(x, y, w, h, r, color, strength, layers)
    layers = layers or 6
    strength = strength or 0.5
    for i = layers, 1, -1 do
        local spread = i * 3
        local a = (strength / layers) * (layers - i + 1) * 0.5
        love.graphics.setColor(color[1], color[2], color[3], a)
        love.graphics.rectangle("fill", x - spread, y - spread,
            w + spread * 2, h + spread * 2, r + spread, r + spread)
    end
end

-- Glass-matte panel: fill + hairline border, optional inner top highlight.
function Theme.panel(x, y, w, h, opts)
    opts = opts or {}
    local r = opts.radius or Theme.radius.large
    local fill = opts.fill or Theme.color.midnight
    local fillA = opts.fillAlpha or 0.85
    love.graphics.setColor(fill[1], fill[2], fill[3], fillA)
    love.graphics.rectangle("fill", x, y, w, h, r, r)
    -- subtle top inner highlight so panels read as slightly lit from above
    if opts.highlight ~= false then
        love.graphics.setColor(1, 1, 1, 0.025)
        love.graphics.rectangle("fill", x, y, w, h * 0.5, r, r)
    end
    local bc = opts.border or Theme.color.border
    love.graphics.setColor(bc[1], bc[2], bc[3], opts.borderAlpha or 1)
    love.graphics.setLineWidth(opts.borderWidth or 1)
    love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, r, r)
end

-- Filled rounded rect in a flat color (with optional alpha).
function Theme.fillRect(x, y, w, h, r, color, a)
    love.graphics.setColor(color[1], color[2], color[3], a or 1)
    love.graphics.rectangle("fill", x, y, w, h, r or 0, r or 0)
end

function Theme.strokeRect(x, y, w, h, r, color, a, lw)
    love.graphics.setColor(color[1], color[2], color[3], a or 1)
    love.graphics.setLineWidth(lw or 1)
    love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, r or 0, r or 0)
end

-- A decorative small diamond (used as section-title flourishes in the mockup).
function Theme.diamond(cx, cy, size, color, a)
    love.graphics.setColor(color[1], color[2], color[3], a or 1)
    love.graphics.polygon("fill", cx, cy - size, cx + size, cy, cx, cy + size, cx - size, cy)
end

-- Draw a thin arcane circle (concentric rings + radial ticks + a rotated inner
-- square) centred at cx,cy. Used very faintly as a background ornament.
function Theme.arcaneCircle(cx, cy, radius, color, a, t)
    t = t or 0
    love.graphics.push()
    love.graphics.translate(cx, cy)
    love.graphics.setColor(color[1], color[2], color[3], a)
    love.graphics.setLineWidth(1.5)
    love.graphics.circle("line", 0, 0, radius)
    love.graphics.circle("line", 0, 0, radius * 0.82)
    love.graphics.circle("line", 0, 0, radius * 0.55)
    -- radial ticks
    local ticks = 24
    for i = 1, ticks do
        local ang = (i / ticks) * math.pi * 2 + t * 0.05
        local r1, r2 = radius * 0.82, radius
        love.graphics.line(math.cos(ang) * r1, math.sin(ang) * r1,
            math.cos(ang) * r2, math.sin(ang) * r2)
    end
    -- two counter-rotated squares (a faux "seal")
    for _, rot in ipairs({ t * 0.1, -t * 0.1 + math.pi / 4 }) do
        love.graphics.push()
        love.graphics.rotate(rot)
        local s = radius * 0.55
        love.graphics.rectangle("line", -s, -s, s * 2, s * 2)
        love.graphics.pop()
    end
    love.graphics.pop()
end

-- Vertical two-stop gradient fill via a 1x2 image stretched over the rect.
-- Cached per (top,bottom) key so we don't rebuild images every frame.
local gradientCache = {}
local function gradientImage(top, bottom)
    local key = table.concat(top, ",") .. "|" .. table.concat(bottom, ",")
    local img = gradientCache[key]
    if not img then
        local data = love.image.newImageData(1, 2)
        data:setPixel(0, 0, top[1], top[2], top[3], 1)
        data:setPixel(0, 1, bottom[1], bottom[2], bottom[3], 1)
        img = love.graphics.newImage(data)
        img:setFilter("linear", "linear")
        gradientCache[key] = img
    end
    return img
end

function Theme.gradientRect(x, y, w, h, top, bottom)
    local img = gradientImage(top, bottom)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, x, y, 0, w / img:getWidth(), h / img:getHeight())
end

return Theme
