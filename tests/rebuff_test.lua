-- Runs the addon's plain Lua against a stand-in for the WoW API: which buff
-- is found due and on whom, what the cast button is told, when the hotkey is
-- held and given back, and the options window. It cannot cover what only the
-- game does: the cast itself, the key press reaching the button, the game
-- hiding the button in combat, and how things look.
--
-- From the repository root:  tests/run.sh   (Lua 5.1)
--
-- One script, several scenarios chosen by environment variable:
--   (none)       the full walk-through
--   INDEX=1      a client without the batch aura call: read one by one
--   HIDDEN=1     a place where the game keeps all auras secret
--   LEGACY=1     a client with the old global spell calls only
--   REFUSE=a,b   frame templates the client refuses to create

local now, combat, cursor = 1000, false, nil
local mods = { shift = false, ctrl = false, alt = false }
local mounted = false
local INDEX, HIDDEN, LEGACY = os.getenv("INDEX"), os.getenv("HIDDEN"), os.getenv("LEGACY")
local REFUSE = {}
for template in (os.getenv("REFUSE") or ""):gmatch("[^,]+") do REFUSE[template] = true end

-- Widgets: every method exists and does nothing, except the ones named here.
local function widget(kind, name, template)
  local w = { _kind = kind, _name = name, _attr = {}, _scripts = {}, _shown = true, _points = {} }
  local secure = template and template:find("Secure") ~= nil
  local function guard() assert(not (secure and combat), "protected call in combat") end
  local methods = {
    SetAttribute = function(s, a, v) guard(); s._attr[a] = v end,
    GetAttribute = function(s, a) return s._attr[a] end,
    SetScript = function(s, n, fn) s._scripts[n] = fn end,
    HookScript = function(s, n, fn) s._scripts[n] = fn end,
    Show = function(s) guard(); local was = s._shown; s._shown = true; if not was and s._scripts.OnShow then s._scripts.OnShow(s) end end,
    Hide = function(s) guard(); local was = s._shown; s._shown = false; if was and s._scripts.OnHide then s._scripts.OnHide(s) end end,
    SetShown = function(s, v) assert(type(v) == "boolean", "SetShown needs a boolean"); if v then s:Show() else s:Hide() end end,
    IsShown = function(s) return s._shown end,
    CreateTexture = function() return widget("Texture") end,
    CreateFontString = function() return widget("FontString") end,
    CreateMaskTexture = function() return widget("Mask") end,
    AddMaskTexture = function(s, m) s._mask = m end,
    SetPoint = function(s, ...) guard(); s._points[#s._points + 1] = { ... } end,
    ClearAllPoints = function(s) guard(); s._points = {} end,
    SetAllPoints = function(s, r) s._points = { { "ALL", r } } end,
    GetPoint = function(s, i) local p = s._points[i or 1]; if p then return unpack(p, 1, 5) end end,
    GetNumPoints = function(s) return #s._points end,
    SetSize = function(s, w2, h) guard(); assert(w2 >= 0 and h >= 0, "bad size"); s._w, s._h = w2, h end,
    GetSize = function(s) return s._w or 45, s._h or 45 end,
    GetWidth = function(s) return s._w or 45 end,
    GetAtlas = function(s) return s._atlas end,
    SetAtlas = function(s, a) s._atlas = a end,
    GetTexture = function(s) return s._tex end,
    SetTexture = function(s, t) s._tex = t end,
    GetTexCoord = function() return 0, 0, 0, 1, 1, 0, 1, 1 end,
    GetDrawLayer = function(s) return s._layer or "ARTWORK", s._sub or 0 end,
    SetDrawLayer = function(s, l, sub) s._layer, s._sub = l, sub end,
    GetBlendMode = function(s) return s._blend or "BLEND" end,
    SetDesaturated = function(s, v) assert(type(v) == "boolean", "SetDesaturated needs a boolean"); s._gray = v end,
    GetFrameLevel = function() return 1 end,
    GetStringWidth = function() return 40 end,
    GetParent = function(s) return s._parent end,
    GetName = function(s) return s._name end,
    SetText = function(s, t) assert(type(t) == "string", "SetText needs a string"); s._text = t end,
    SetChecked = function(s, v) assert(type(v) == "boolean", "SetChecked needs a boolean"); s._checked = v end,
    GetChecked = function(s) return s._checked end,
    SetEnabled = function(s, v) assert(type(v) == "boolean", "SetEnabled needs a boolean"); s._enabled = v end,
    EnableKeyboard = function(s, v) assert(type(v) == "boolean"); s._keyboard = v end,
    EnableMouseWheel = function(s, v) assert(type(v) == "boolean"); s._wheel = v end,
    LockHighlight = function(s) s._locked = true end,
    UnlockHighlight = function(s) s._locked = false end,
  }
  return setmetatable(w, { __index = function(_, k)
    if type(k) ~= "string" or not k:match("^%u") then return nil end
    -- Parts only some window templates have
    if k == "CloseButton" or k == "TitleContainer" or k == "TitleText" or k == "PortraitContainer" or k == "IconMask" or k == "SlotBackground" then return nil end
    if methods[k] then return methods[k] end
    local state = k:match("^Set(%a+)Atlas$")
    if state then return function(s, a) s["_st" .. state] = s["_st" .. state] or widget("Texture"); s["_st" .. state]._atlas = a end end
    state = k:match("^Get(%a+)Texture$")
    if state then return function(s) return s["_st" .. state] end end
    return function() end
  end })
end

local frames = {}
function CreateFrame(kind, name, parent, template)
  if template and REFUSE[template] then error("Couldn't find inherited node: " .. template) end
  local f = widget(kind, name, template)
  f._parent, f._template = parent, template
  if template == "ButtonFrameTemplate" then
    rawset(f, "CloseButton", widget("Button"))
    local title = widget("Frame"); rawset(title, "TitleText", widget("FontString")); rawset(f, "TitleContainer", title)
    local portrait = widget("Frame"); portrait.portrait = widget("Texture"); portrait.portrait._parent = portrait
    rawset(f, "PortraitContainer", portrait)
  end
  frames[#frames + 1] = f
  if name then _G[name] = f end
  return f
end
UIParent = widget("Frame", "UIParent"); GameTooltip = widget("GameTooltip"); function GameTooltip_Hide() end

-- An action button to copy the look from
local bar = CreateFrame("Button", "ActionButton1")
bar.icon = widget("Texture"); bar.icon._points = { { "TOPLEFT", bar, "TOPLEFT", 0, 0 } }
bar._stNormal = widget("Texture"); bar._stNormal._atlas = "IconFrame"; bar._stNormal._points = { { "TOPLEFT", bar, "TOPLEFT", 0, 0 } }

function GetTime() return now end
function InCombatLockdown() return combat end
function GetCursorInfo() if cursor then return unpack(cursor) end end
function ClearCursor() cursor = nil end
function IsShiftKeyDown() return mods.shift end
function IsControlKeyDown() return mods.ctrl end
function IsAltKeyDown() return mods.alt end
function IsMounted() return mounted end
function UnitOnTaxi() return false end
strlower, strupper, tinsert = string.lower, string.upper, table.insert
SlashCmdList, UISpecialFrames = {}, {}
local sounds = 0
SOUNDKIT = { ALARM_CLOCK_WARNING_3 = 1, IG_MAINMENU_OPTION_CHECKBOX_ON = 2, IG_CHARACTER_INFO_OPEN = 3, IG_CHARACTER_INFO_CLOSE = 4 }
function PlaySound(id) if id == 1 then sounds = sounds + 1 end end
function GetBindingText(key) return "<" .. key .. ">" end

-- Spells. Some ids from the pairs table get their real names.
local NAMES = { [588] = "Inner Fire", [15473] = "Shadowform", [1243] = "Power Word: Fortitude", [21562] = "Prayer of Fortitude", [7] = "Short Buff" }
local HELPFUL = { [1243] = true, [21562] = true }
local unknown = {}
local function spellName(spell)
  if type(spell) == "string" then for id, name in pairs(NAMES) do if name == spell and not unknown[id] then return spell end end return nil end
  return NAMES[spell]
end
-- unit -> true/false, what the spell range call says; nil for no answer
local range, partyRange = {}, {}
local rangeCalls = 0
local function spellRange(_, unit) rangeCalls = rangeCalls + 1; return range[unit] end
if LEGACY then
  function GetSpellInfo(spell) return spellName(spell) end
  function GetSpellTexture(spell) return 9000 end
  function IsSpellInRange(spell, unit) local r = spellRange(spell, unit); if r ~= nil then return r and 1 or 0 end end
  function IsHelpfulSpell(name) for id, n in pairs(NAMES) do if n == name then return HELPFUL[id] end end end
  function IsPlayerSpell(id) return not unknown[id] end
else
  C_Spell = { GetSpellName = spellName, GetSpellTexture = function() return 9000, 1 end, IsSpellInRange = spellRange,
    IsSpellHelpful = function(id) return HELPFUL[id] or false end }
  C_SpellBook = { IsSpellKnown = function(id) return not unknown[id] end }
end
function UnitInRange(unit) local r = partyRange[unit]; if r ~= nil then return r, true end return false, false end

-- Units and their buffs
local units = { player = { name = "Me" } }
local raid = false
function UnitExists(unit) return units[unit] ~= nil end
function UnitName(unit) return units[unit] and units[unit].name end
function UnitIsConnected(unit) return not units[unit].offline end
function UnitIsDeadOrGhost(unit) return units[unit].dead or false end
function UnitCanAssist(_, unit) return not units[unit].hostile end
function UnitIsVisible(unit) return not units[unit].unseen end
function UnitIsUnit(a, b) return units[a] ~= nil and units[a] == units[b] end
function IsInRaid() return raid end
function GetRaidRosterInfo(index) local u = units["raid" .. index]; return u and u.name, 0, u and u.group end
-- A unit's buffs: name -> { duration, expirationTime }
local SECRET = {}
function issecretvalue(v) return v == SECRET end
local function auraList(unit)
  local list = {}
  for name, timing in pairs(units[unit].buffs or {}) do
    list[#list + 1] = { name = units[unit].secret and SECRET or name, spellId = 1, duration = timing[1], expirationTime = timing[2] }
  end
  return list
end
C_UnitAuras = { GetAuraDataByIndex = function(unit, index, filter) assert(filter == "HELPFUL"); return auraList(unit)[index] end }
if not INDEX then C_UnitAuras.GetUnitAuras = function(unit, filter, limit) assert(filter == "HELPFUL" and limit == 255); return auraList(unit) end end
if HIDDEN then C_Secrets = { ShouldAurasBeSecret = function() return true end } end

-- The key
local keys = {}
function ClearOverrideBindings(owner) assert(not combat, "protected call in combat"); keys = {} end
function SetOverrideBindingClick(owner, priority, key, target, mouse)
  assert(not combat, "protected call in combat"); assert(priority == true and target == "RebuffButton" and mouse == "LeftButton")
  if key == "BROKEN" then error("no such key") end
  keys[key] = true
end
local driver
function RegisterStateDriver(frame, state, conditions) driver = { frame = frame, state = state, conditions = conditions } end

local printed = {}
local realprint = print
print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
local function said(text) for _, line in ipairs(printed) do if line:find(text, 1, true) then return true end end return false end

-- Load the addon
local NS = {}
local first = #frames + 1
assert(loadfile("Rebuff.lua"))("Rebuff", NS)
assert(loadfile("Window.lua"))("Rebuff", NS)
local events = frames[first]
local function fire(event, ...) events._scripts.OnEvent(events, event, ...) end
local function tick(seconds) now = now + (seconds or 1); events._scripts.OnUpdate(events, seconds or 1) end
local function give(unit, name, duration, left) units[unit].buffs = units[unit].buffs or {}; units[unit].buffs[name] = { duration, duration > 0 and now + left or 0 } end
local function take(unit, name) units[unit].buffs[name] = nil end
local function drop(id, position) cursor = { "spell", 3, "spell", id }; return NS.AddFromCursor(position) end

fire("PLAYER_LOGIN")
local db, button = RebuffDB, RebuffButton
assert(db.key == "MOUSEWHEELDOWN" and db.warn == 60 and db.sound == true and db.size == 40 and #db.buffs == 0)
assert(said("type /rebuff") and button and not button._shown and next(keys) == nil, "starts hidden, key not held")
assert(button._attr.useOnKeyDown == true and button._attr.checkselfcast == false and button._attr["_onstate-safety"]:find("ClearBindings"))
assert(driver.frame == button and driver.state == "safety" and driver.conditions:find("combat") and driver.conditions:find("mounted"))
assert(button._template == "SecureActionButtonTemplate,SecureHandlerStateTemplate")

-- A self buff that is missing
local inner = drop(588)
assert(inner and inner.who == "self" and cursor == nil and #db.buffs == 1)
if HIDDEN then
  -- Nothing can be read, so nothing is due and the key stays free
  assert(not button._shown and next(keys) == nil and button._attr["*type1"] == nil)
  drop(1243); units.party1 = { name = "Ann" }; range.party1 = true; tick()
  assert(not button._shown and next(keys) == nil)
  assert(NS.Status(inner) == "Cannot be read")
  realprint("ok"); return
end
assert(button._shown and button._attr["*type1"] == "spell" and button._attr.spell == "Inner Fire" and button._attr.unit == "player")
assert(keys.MOUSEWHEELDOWN and sounds == 1 and button.time._text == "" and button.who._text == "" and button.hotkey._text == "WhD")
assert(button.icon._tex == 9000 and button.icon._gray == false and button._w == 40 and button._stNormal._atlas == "IconFrame", "styled as a bar slot")
assert(drop(588) == inner and #db.buffs == 1, "the same spell twice is one buff")

-- Up: hidden, key given back
give("player", "Inner Fire", 600, 500); fire("UNIT_AURA", "player"); tick(0.2)
assert(not button._shown and next(keys) == nil and button._attr["*type1"] == nil and button._attr.spell == nil)
-- An event for someone not watched causes no look
local before = rangeCalls; fire("UNIT_AURA", "nameplate3"); fire("UNIT_AURA", SECRET)
-- Crossing the warning line comes with no event: the tick finds it
for _ = 1, 439 do tick() end; assert(not button._shown, "61 seconds left is not yet due")
tick(3); assert(button._shown and button.time._text:match("^%d+s$") and keys.MOUSEWHEELDOWN, "under a minute left is due")
assert(sounds == 2 and NS.Status(inner):find("left$"))
-- A buff with no duration never runs out
take("player", "Inner Fire"); give("player", "Inner Fire", 0, 0); tick(); assert(not button._shown)
-- A short buff is due at half its length, not at the warning time
db.buffs[1] = { id = 7, name = "Short Buff", who = "self" }; take("player", "Inner Fire")
give("player", "Short Buff", 100, 55); tick(); assert(not button._shown, "55 of 100 seconds is not due")
tick(6); assert(button._shown, "49 of 100 seconds is due")
-- Only once it is gone
NS.SetWarn(0); assert(not button._shown); take("player", "Short Buff"); tick(); assert(button._shown)
NS.SetWarn(60); db.buffs[1] = inner; give("player", "Inner Fire", 600, 500); tick(); assert(not button._shown)

-- A party buff: the first of the party that misses it and is in range
local fort = drop(1243)
assert(fort.who == "party" and #db.buffs == 2)
assert(button._attr.unit == "player" and button._attr.spell == "Power Word: Fortitude", "alone, the party is you")
give("player", "Power Word: Fortitude", 1800, 1700)
units.party1 = { name = "Ann" }; units.party2 = { name = "Bob" }; units.party3 = { name = "Cy" }; units.party4 = { name = "Di", dead = true }
give("party1", "Power Word: Fortitude", 1800, 1700)
range.party1, range.party2, range.party3, range.party4 = true, true, false, true
fire("GROUP_ROSTER_UPDATE"); tick(0.2)
assert(button._attr.unit == "party2" and button.who._text == "Bob" and keys.MOUSEWHEELDOWN and button.icon._gray == false)
assert(NS.Status(fort) == "Missing on Bob +1")
-- The group version counts
give("party2", "Prayer of Fortitude", 3600, 3500); tick()
-- Only someone out of range is left: shown, grey, not cast, key free
assert(button._shown and button.action.unit == "party3" and button.action.far and button.icon._gray == true)
assert(button._attr["*type1"] == nil and button._attr.unit == nil and next(keys) == nil and button.hotkey._text == "")
-- No answer on range from the spell falls back on the party range, and no answer at all is not cast on
range.party3 = nil; partyRange.party3 = true; tick(); assert(button._attr.unit == "party3" and keys.MOUSEWHEELDOWN)
partyRange.party3 = nil; tick(); assert(button._attr.unit == nil and button.action.far, "range unknown is not cast on")
units.party3.unseen = true; range.party3 = true; tick(); assert(button.action.far, "not visible is out of range")
units.party3.unseen = nil
-- The dead, the offline and the hostile are passed over
units.party4.dead = nil; units.party4.offline = true; tick(); assert(button.action.unit == "party3")
units.party4.offline = nil; units.party4.hostile = true; tick(); assert(button.action.unit == "party3")
units.party4.hostile = nil; tick(); assert(button.action.unit == "party3" and NS.Status(fort) == "Missing on Cy +1")
-- Someone whose buffs cannot be read is not taken for missing them
give("party3", "Power Word: Fortitude", 1800, 1700); units.party4.secret = true; give("party4", "Something", 10, 5); tick()
assert(not button._shown and next(keys) == nil and NS.Status(fort) == "Up")
units.party4.secret = nil

-- A press moves on to the next one due, and comes back
take("party3", "Power Word: Fortitude"); tick()
assert(button._attr.unit == "party3")
local post = button._scripts.PostClick
post(button, "LeftButton", true); post(button, "LeftButton", false); tick(0.2)
assert(button._attr.unit == "party4", "the one just pressed waits behind the other")
tick(0.5); post(button, "LeftButton", true); post(button, "LeftButton", false); tick(0.2)
assert(button._attr.unit == "party3", "both pressed: the one pressed longest ago")
give("party3", "Power Word: Fortitude", 1800, 1800); tick(); assert(button._attr.unit == "party4")
give("party4", "Power Word: Fortitude", 1800, 1800); tick(); assert(not button._shown)
-- List order decides between buffs
take("player", "Inner Fire"); take("party1", "Power Word: Fortitude"); tick(6)
assert(button._attr.spell == "Inner Fire" and button._attr.unit == "player")
give("player", "Inner Fire", 600, 600); tick(); assert(button._attr.spell == "Power Word: Fortitude" and button._attr.unit == "party1")
-- A spell no longer known is passed over
unknown[1243] = true; tick(); assert(not button._shown and NS.Status(fort) == "Not learned"); unknown[1243] = nil

-- Combat: nothing protected is touched; the game's own hiding is followed
tick(); assert(button._shown and keys.MOUSEWHEELDOWN)
fire("PLAYER_REGEN_DISABLED"); combat = true
button._shown = false; keys = {}; button._attr["state-safety"] = "blocked"; button._scripts.OnAttributeChanged(button, "state-safety", "blocked")
fire("UNIT_AURA", "player"); tick(); tick(); assert(NS.Status(fort) == "In combat")
NS.SetWho(fort, "self"); NS.SetWarn(30); NS.SetKey("f"); assert(fort.who == "self" and db.warn == 30 and db.key == "F", "settings are taken in combat")
NS.SetWho(fort, "party"); NS.SetWarn(60)
combat = false; button._attr["state-safety"] = "ready"; button._scripts.OnAttributeChanged(button, "state-safety", "ready"); fire("PLAYER_REGEN_ENABLED")
assert(button._shown and keys.F and not keys.MOUSEWHEELDOWN and button._attr.unit == "party1" and button.hotkey._text == "F")
-- Mounted: nothing is offered
mounted = true; fire("PLAYER_MOUNT_DISPLAY_CHANGED"); tick(0.2); assert(not button._shown and next(keys) == nil)
mounted = false; fire("PLAYER_MOUNT_DISPLAY_CHANGED"); tick(0.2); assert(button._shown and keys.F)

-- The key
SlashCmdList.REBUFF("key shift-q"); assert(db.key == "SHIFT-Q" and keys["SHIFT-Q"] and not keys.F and button.hotkey._text == "s-Q")
SlashCmdList.REBUFF("key none"); assert(db.key == false and next(keys) == nil and button._shown and button._attr.unit == "party1", "no key: still shown and clickable")
SlashCmdList.REBUFF("key broken"); assert(next(keys) == nil and said("could not take the key") and button._shown)
SlashCmdList.REBUFF("key mousewheeldown"); assert(keys.MOUSEWHEELDOWN)
printed = {}; SlashCmdList.REBUFF("status")
assert(said("Power Word: Fortitude is missing on Ann") and said("held by Rebuff now") and said("casts Power Word: Fortitude on party1") and said("Inner Fire (self): up"))
SlashCmdList.REBUFF("size 300"); assert(db.size == 80 and button._w == 80); SlashCmdList.REBUFF("size 40")
SlashCmdList.REBUFF("sound off"); assert(db.sound == false); SlashCmdList.REBUFF("sound on")
printed = {}; SlashCmdList.REBUFF("nonsense"); assert(said("/rebuff status"))
-- Saved position
button._points = { { "TOPLEFT", UIParent, "TOPLEFT", 12, -34 } }; button._scripts.OnDragStop(button)
assert(db.point == "TOPLEFT" and db.x == 12 and db.y == -34)
SlashCmdList.REBUFF("reset"); assert(db.point == "CENTER" and button._points[1][5] == -120)

-- A raid: your own group only
raid = true; units.party1, units.party2, units.party3, units.party4 = nil, nil, nil, nil
units.raid1 = { name = "Eve", group = 2 }; units.raid2 = units.player; units.player.group = 1; units.raid3 = { name = "Fay", group = 1 }
range.raid1, range.raid3 = true, true
fire("GROUP_ROSTER_UPDATE"); tick(0.2); assert(button._attr.unit == "raid3" and button.who._text == "Fay")
give("raid3", "Power Word: Fortitude", 1800, 1800); tick(); assert(not button._shown, "the other raid group is not yours to buff")
raid = false; units.raid1, units.raid2, units.raid3 = nil, nil, nil; tick()

-- The options window
local refused = REFUSE.UICheckButtonTemplate or REFUSE.UIPanelButtonTemplate
printed = {}; SlashCmdList.REBUFF("")
if refused then
  assert(said("could not build the options window") and said("/rebuff status") and not NS.WindowShown())
  SlashCmdList.REBUFF(""); assert(not said("could not fill"))
  realprint("ok"); return
end
local window = RebuffWindow
assert(window and window._shown and NS.WindowShown() and UISpecialFrames[1] == "RebuffWindow" and not said("could not"))
assert(button._shown and button.placeholder and button.who._text == "Rebuff" and button._attr["*type1"] == nil and next(keys) == nil, "a stand-in to drag while the window is open")
local slots, detail = window.slots, window.detail
assert(#slots == 12 and slots[1].buff == inner and slots[2].buff == fort and slots[3].buff == nil and slots[1]._locked and not slots[2]._locked)
assert(detail._shown and detail.name._text == "Inner Fire" and detail.status._text == "Up" and detail.who.self._checked and not detail.who.party._checked)
assert(window.warnings[60]._checked and not window.warnings[0]._checked and window.key._text == "<MOUSEWHEELDOWN>" and window.sound._checked)
-- Select, and change who it is kept on
slots[2]._scripts.OnClick(slots[2], "LeftButton"); assert(detail.name._text == "Power Word: Fortitude" and detail.who.party._checked and slots[2]._locked)
detail.who.self._scripts.OnClick(detail.who.self); assert(fort.who == "self" and detail.who.self._checked and detail.note._text:find("alone"))
detail.who.party._scripts.OnClick(detail.who.party); assert(fort.who == "party")
window.warnings[120]._scripts.OnClick(window.warnings[120]); assert(db.warn == 120 and window.warnings[120]._checked and not window.warnings[60]._checked)
window.warnings[60]._scripts.OnClick(window.warnings[60])
window.sound._checked = false; window.sound._scripts.OnClick(window.sound); assert(db.sound == false)
window.sound._checked = true; window.sound._scripts.OnClick(window.sound); assert(db.sound == true)
-- The hotkey button
local key = window.key
key._scripts.OnClick(key, "LeftButton"); assert(key._keyboard and key._wheel and key._text == "Press a key...")
key._scripts.OnKeyDown(key, "LSHIFT"); assert(key._keyboard, "a modifier alone is not a key")
mods.shift = true; key._scripts.OnKeyDown(key, "E"); mods.shift = false
assert(db.key == "SHIFT-E" and not key._keyboard and key._text == "<SHIFT-E>")
key._scripts.OnClick(key, "LeftButton"); key._scripts.OnKeyDown(key, "ESCAPE"); assert(db.key == "SHIFT-E" and not key._keyboard, "Escape keeps the key")
key._scripts.OnClick(key, "LeftButton"); key._scripts.OnClick(key, "Button4"); assert(db.key == "BUTTON4")
key._scripts.OnClick(key, "RightButton"); assert(db.key == false and key._text == "Not set")
key._scripts.OnClick(key, "LeftButton"); key._scripts.OnMouseWheel(key, -1); assert(db.key == "MOUSEWHEELDOWN" and not key._wheel)
-- Drop on a slot puts it before that one; something that is no spell is refused
local shadow = (function() cursor = { "spell", 9, "spell", 15473 }; slots[1]._scripts.OnReceiveDrag(slots[1]); return db.buffs[1] end)()
assert(shadow.name == "Shadowform" and db.buffs[2] == inner and db.buffs[3] == fort and detail.name._text == "Shadowform" and cursor == nil)
assert(not button.placeholder and button._attr.spell == "Shadowform" and keys.MOUSEWHEELDOWN, "with something due the real button is back")
cursor = { "item", 5 }; printed = {}; slots[5]._scripts.OnClick(slots[5], "LeftButton"); assert(#db.buffs == 3 and said("only spells") and cursor)
cursor = nil
-- Remove
mods.shift = true; slots[2]._scripts.OnClick(slots[2], "RightButton"); mods.shift = false
assert(#db.buffs == 2 and db.buffs[2] == fort and slots[3].buff == nil)
window.remove._scripts.OnClick(window.remove); assert(#db.buffs == 1 and db.buffs[1] == fort and detail.name._text == "Power Word: Fortitude")
window.remove._scripts.OnClick(window.remove); assert(#db.buffs == 0 and not detail._shown and window.empty._shown and window.remove._enabled == false)
assert(button.placeholder and next(keys) == nil)
for id in pairs({ [588] = true, [15473] = true, [1243] = true, [21562] = true, [7] = true }) do drop(id) end
assert(#db.buffs == 5)
-- Right-click on the button toggles the window, once per click
post(button, "RightButton", true); assert(window._shown); post(button, "RightButton", false); assert(not window._shown)
db.buffs = {}; RebuffDB.buffs = db.buffs; NS.Refresh(); assert(not button._shown, "window closed and nothing due: no button")
assert(not said("could not"))
realprint("ok")
