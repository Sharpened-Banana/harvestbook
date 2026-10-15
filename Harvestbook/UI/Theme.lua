local ADDON, ns = ...

-- Visual constants shared by the box, companion and module pages (spec §5.1,
-- matching Angler's TackleBox). Only built-in textures and fonts are used.

local Theme = {}
ns.Theme = Theme

local WHITE = "Interface\\Buttons\\WHITE8X8"
Theme.WHITE = WHITE

local function hex(h, a)
  return {
    tonumber(h:sub(1, 2), 16) / 255,
    tonumber(h:sub(3, 4), 16) / 255,
    tonumber(h:sub(5, 6), 16) / 255,
    a or 1,
  }
end

Theme.COLORS = {
  -- Global Constraints values.
  frame = hex("14302B", 0.95),
  content = hex("0E1F1C"),
  gold = hex("FFD100"),
  parchment = hex("D8C9A3"),
  green = hex("33FF33"),
  grey = hex("9D9D9D"),
  red = hex("7A1010"),
  -- Derived shades.
  titleBar = hex("1D4139", 0.95),
  border = hex("8FA89F", 0.6),
  contentBorder = hex("6B5A2A", 0.9),
  parchmentSelected = hex("F0E6C8"),
  parchmentBorder = hex("6E5E3C"),
  sidebarText = hex("3B2A14"),
  redBorder = hex("B8912E"),
  redHover = hex("9A1A1A"),
  barBg = hex("000000", 0.55),
  white = hex("FFFFFF"),
}

Theme.FONTS = { title = "Fonts\\MORPHEUS.TTF", body = "Fonts\\FRIZQT__.TTF" }

Theme.ICONS = {
  session = "Interface\\Icons\\INV_Misc_PocketWatch_01",
  nodelog = "Interface\\Icons\\INV_Misc_Book_09",
  bestspot = "Interface\\Icons\\INV_Misc_Map_01",
  records = "Interface\\Icons\\INV_Misc_Trophy_03",
  goals = "Interface\\Icons\\INV_Misc_Note_01",
  alarms = "Interface\\Icons\\INV_Misc_Bell_01",
  window = "Interface\\Icons\\INV_Misc_Spyglass_03",
  settings = "Interface\\Icons\\Trade_Engineering",
  herb = "Interface\\Icons\\Trade_Herbalism",
  ore = "Interface\\Icons\\Trade_Mining",
  skin = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
}

-- r, g, b, a for a color key (unknown keys fall back to white).
function Theme:Color(key)
  local c = self.COLORS[key] or self.COLORS.white
  return c[1], c[2], c[3], c[4]
end

-- Flat fill + optional 1 px border. Frames not created with BackdropTemplate
-- get the mixin applied on the fly.
function Theme:Backdrop(frame, colorKey, borderColorKey)
  if not frame.SetBackdrop then
    Mixin(frame, BackdropTemplateMixin)
    if frame.OnBackdropSizeChanged then
      frame:HookScript("OnSizeChanged", frame.OnBackdropSizeChanged)
    end
  end
  local bd = { bgFile = WHITE }
  if borderColorKey then
    bd.edgeFile = WHITE
    bd.edgeSize = 1
    bd.insets = { left = 1, right = 1, top = 1, bottom = 1 }
  end
  frame:SetBackdrop(bd)
  frame:SetBackdropColor(self:Color(colorKey or "content"))
  if borderColorKey then
    frame:SetBackdropBorderColor(self:Color(borderColorKey))
  end
end

-- Named font objects (the only globals this file creates).
local function makeFont(name, path, size, colorKey, shadow)
  local f = _G[name] or CreateFont(name)
  f:SetFont(path, size, "")
  f:SetTextColor(Theme:Color(colorKey))
  if shadow then
    f:SetShadowOffset(1, -1)
    f:SetShadowColor(0, 0, 0, 1)
  else
    f:SetShadowOffset(0, 0)
  end
  return f
end

Theme.Font = {
  title = makeFont("HarvestbookFontTitle", Theme.FONTS.title, 24, "gold", true),
  heading = makeFont("HarvestbookFontHeading", Theme.FONTS.title, 16, "gold", true),
  body = makeFont("HarvestbookFontBody", Theme.FONTS.body, 12, "white", true),
  small = makeFont("HarvestbookFontSmall", Theme.FONTS.body, 11, "white", true),
  sidebar = makeFont("HarvestbookFontSidebar", Theme.FONTS.body, 13, "sidebarText", false),
}
