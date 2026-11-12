-- Rebuff: watches the buffs you pick and shows the next one that is missing
-- or about to run out, on you or on someone in your party. One hotkey casts
-- it.
--
-- The button that casts is secure: what it casts, on whom, and the key that
-- presses it can only be set outside combat. In combat, and while dead or
-- mounted, the game itself hides the button and gives the key back (see
-- SAFETY). Nothing is ever restored from before: once out of combat the
-- buffs are looked at afresh.
--
-- A buff counts as missing only when the unit's buffs could be read and it
-- was not among them. Whatever cannot be told (combat, a battleground that
-- hides auras, an API that fails) raises no alert, so the hotkey is never
-- taken on a guess.

local _, ns = ...;

local QUESTION_MARK = 134400;
local PORTRAIT = "Interface\\Icons\\Spell_Holy_WordFortitude";
local MAX_BUFFS = 12;
local DEFAULT_KEY = "MOUSEWHEELDOWN";
local DEFAULT_WARN = 60;
local DEFAULT_SIZE = 40;
-- Seconds between looks while nothing happens. Two things come with no event:
-- a buff's time crossing the warning line, and a party member walking into
-- range.
local TICK = 1;
-- Seconds an event waits before the look it causes, so that a burst of them
-- costs one
local SETTLE = 0.1;
-- Seconds a cast that was just pressed waits behind the others that are due.
-- Without it one cast that keeps failing would be offered forever.
local RETRY = 5;
local PRESS_GAP = 0.3;
local SOUND_GAP = 10;
-- The most buffs asked for on one unit
local AURA_LIMIT = 255;
-- The alarm clock's beep, for where the sound kit does not name it
local ALARM = 12867;

-- The single-target and the group version of one buff, by spell id of any
-- rank. Either one on a unit satisfies the other. Ids, so that the names come
-- out in the client's language.
local PAIRS = {
	{ 1243, 21562 },  -- Power Word: Fortitude, Prayer of Fortitude
	{ 14752, 27681 }, -- Divine Spirit, Prayer of Spirit
	{ 976, 27683 },   -- Shadow Protection, Prayer of Shadow Protection
	{ 1459, 23028 },  -- Arcane Intellect, Arcane Brilliance
	{ 1126, 21849 },  -- Mark of the Wild, Gift of the Wild
	{ 20217, 25898 }, -- Blessing of Kings and its Greater Blessing
	{ 19740, 25782 }, -- Blessing of Might
	{ 19742, 25894 }, -- Blessing of Wisdom
};

local SELF = { "player" };

-- Newer clients moved these into namespaces
local GetSpellName = C_Spell and C_Spell.GetSpellName or function(spell) return (GetSpellInfo(spell)); end;
local GetSpellTexture = C_Spell and C_Spell.GetSpellTexture or GetSpellTexture;

-- The game hides the button and frees the key by itself: Lua may not in combat.
local SAFETY = [[
	if newstate == "blocked" then
		self:ClearBindings();
		self:Hide();
	end
]];
local SAFETY_STATES = "[combat][@player,dead][mounted] blocked; ready";

local db;
local button;
-- Spell name -> name of the other version of the same buff (see PAIRS)
local partner = {};
-- What the button offers now, and in words why it offers that or nothing
local current, reason = nil, "not looked yet";
-- The key the button holds now
local bound;
-- "Spell:unit" -> when it was last pressed
local tried = {};
local lastPress, lastSound = 0, -SOUND_GAP;
local wasCastable = false;
local dirty, sinceLook = true, 0;
local buttonFailed, lookFailed, presentFailed, bindFailed = false, false, false, false;
local Refresh;

local function Print(text)
	print("|cffffd100Rebuff:|r " .. text);
end

-- Whether a value is one the game hands out but forbids looking at.
local function Secret(value)
	return issecretvalue ~= nil and issecretvalue(value) == true;
end

local function Clock(seconds)
	seconds = math.max(0, math.floor(seconds + 0.5));
	if seconds >= 60 then
		return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60);
	end
	return seconds .. "s";
end

-- A key the way the action bars write it: s-Q, WhD.
local function ShortKey(key)
	return (key:gsub("MOUSEWHEELDOWN", "WhD"):gsub("MOUSEWHEELUP", "WhU"):gsub("BUTTON", "M")
		:gsub("NUMPAD", "N"):gsub("SHIFT%-", "s-"):gsub("CTRL%-", "c-"):gsub("ALT%-", "a-"));
end

-- A key in full, as the key bindings window names it.
local function KeyText(key)
	if not key then
		return "Not set";
	end
	local ok, text = pcall(GetBindingText, key);
	return ok and type(text) == "string" and text ~= "" and text or key;
end

local function UnitLabel(unit)
	if unit == "player" then
		return "you";
	end
	local name = UnitName(unit);
	return not Secret(name) and name or unit;
end

-- The look -----------------------------------------------------------------

-- Seconds an aura has left and its full length; math.huge for one that does
-- not run out, or whose time cannot be told.
local function TimeLeft(aura, now)
	local duration, expires = aura.duration, aura.expirationTime;
	if Secret(duration) or Secret(expires) or type(duration) ~= "number" or type(expires) ~= "number"
		or duration <= 0 or expires <= 0 then
		return math.huge, math.huge;
	end
	return expires - now, duration;
end

-- A unit's buffs: the time left and the full length of each, by name and by
-- spell id. Nil when they cannot be read.
local function ReadAuras(unit, now)
	local api = C_UnitAuras;
	if not api then
		return nil;
	end
	if C_Secrets and C_Secrets.ShouldAurasBeSecret then
		local ok, hidden = pcall(C_Secrets.ShouldAurasBeSecret);
		if not ok or Secret(hidden) or hidden then
			return nil;
		end
	end

	local list;
	if api.GetUnitAuras then
		local ok, result = pcall(api.GetUnitAuras, unit, "HELPFUL", AURA_LIMIT);
		if ok and not Secret(result) and type(result) == "table" then
			if #result >= AURA_LIMIT then
				-- As many as were asked for: there may be more, unseen
				return nil;
			end
			list = result;
		end
	end
	if not list and api.GetAuraDataByIndex then
		list = {};
		for index = 1, AURA_LIMIT do
			local ok, aura = pcall(api.GetAuraDataByIndex, unit, index, "HELPFUL");
			if not ok or Secret(aura) then
				return nil;
			end
			if not aura then
				break;
			end
			list[index] = aura;
		end
	end
	if not list then
		return nil;
	end

	local found = { left = {}, total = {} };
	local function Note(key, left, total)
		if not found.left[key] or left > found.left[key] then
			found.left[key], found.total[key] = left, total;
		end
	end
	for _, aura in ipairs(list) do
		if Secret(aura) or type(aura) ~= "table" then
			return nil;
		end
		local name, id = aura.name, aura.spellId;
		if Secret(name) or type(name) ~= "string" then
			-- One buff that cannot be named could be the one looked for
			return nil;
		end
		local left, total = TimeLeft(aura, now);
		Note(name, left, total);
		if not Secret(id) and type(id) == "number" then
			Note(id, left, total);
		end
	end
	return found;
end

-- "missing", or "expiring" and the seconds left, or nothing when the buff is
-- up. `found` is what ReadAuras gave for the unit.
local function Due(buff, found)
	local left, total;
	for _, key in ipairs({ buff.name, partner[buff.name] or false, buff.id }) do
		local has = found.left[key];
		if has and (not left or has > left) then
			left, total = has, found.total[key];
		end
	end
	if not left then
		return "missing";
	end
	-- Never more than half its length, or a short buff would always be due
	if left <= math.min(db.warn, total / 2) then
		return "expiring", left;
	end
end

-- You and your party. In a raid: you and the others of your own raid group.
local function Units()
	local units = { "player" };
	if IsInRaid and IsInRaid() then
		local mine;
		local groups = {};
		for index = 1, MAX_RAID_MEMBERS or 40 do
			local unit = "raid" .. index;
			if UnitExists(unit) then
				local _, _, group = GetRaidRosterInfo(index);
				if UnitIsUnit(unit, "player") then
					mine = group;
				else
					groups[unit] = group;
				end
			end
		end
		for index = 1, MAX_RAID_MEMBERS or 40 do
			local unit = "raid" .. index;
			if mine and groups[unit] == mine then
				units[#units + 1] = unit;
			end
		end
	else
		for index = 1, 4 do
			if UnitExists("party" .. index) then
				units[#units + 1] = "party" .. index;
			end
		end
	end
	return units;
end

-- Whether someone else is there to be buffed at all. The dead and the
-- offline are passed over until they are back.
local function Around(unit)
	return UnitExists(unit) and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit)
		and UnitCanAssist("player", unit) and true or false;
end

local function SpellRange(spell, unit)
	local ok, result = false, nil;
	if C_Spell and C_Spell.IsSpellInRange then
		ok, result = pcall(C_Spell.IsSpellInRange, spell, unit);
	elseif IsSpellInRange then
		ok, result = pcall(IsSpellInRange, spell, unit);
	end
	if not ok or Secret(result) then
		return nil;
	end
	if result == true or result == 1 then
		return true;
	elseif result == false or result == 0 then
		return false;
	end
end

-- True, false, or nil when the game will not say. Only true is cast on.
local function InRange(buff, unit)
	if UnitIsVisible and not UnitIsVisible(unit) then
		return false;
	end
	local near = SpellRange(buff.name, unit);
	if near == nil then
		near = SpellRange(buff.id, unit);
	end
	if near == nil and UnitInRange then
		local ok, inRange, checked = pcall(UnitInRange, unit);
		if ok and not Secret(inRange) and not Secret(checked) and checked then
			near = inRange and true or false;
		end
	end
	return near;
end

-- Whether the spell can be cast at all. Errs towards yes: a spell wrongly
-- taken for unknown would go unwatched without a word.
local function Known(buff)
	local ok, known = false, nil;
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		ok, known = pcall(C_SpellBook.IsSpellKnown, buff.id);
	elseif IsPlayerSpell then
		ok, known = pcall(IsPlayerSpell, buff.id);
	elseif IsSpellKnown then
		ok, known = pcall(IsSpellKnown, buff.id);
	end
	if not ok or Secret(known) or known == nil or known then
		return true;
	end
	-- The id is one rank; a name only resolves for spells in the spellbook
	local named, name = pcall(GetSpellName, buff.name);
	return named and name ~= nil;
end

-- What one look shares between the buffs it checks.
local function NewScan()
	return { now = GetTime(), auras = {}, units = Units() };
end

-- Everyone a buff is due on, in unit order: a list of { buff, unit, state,
-- left, far, key }. Also how many units could not be read, and how many could.
local function Survey(buff, scan)
	local due, unread, read = {}, 0, 0;
	for _, unit in ipairs(buff.who == "party" and scan.units or SELF) do
		if unit == "player" or Around(unit) then
			local found = scan.auras[unit];
			if found == nil then
				found = ReadAuras(unit, scan.now) or false;
				scan.auras[unit] = found;
			end
			if not found then
				unread = unread + 1;
			else
				read = read + 1;
				local state, left = Due(buff, found);
				if state then
					due[#due + 1] = {
						buff = buff, unit = unit, state = state, left = left,
						far = unit ~= "player" and InRange(buff, unit) ~= true,
						key = buff.name .. ":" .. unit,
					};
				end
			end
		end
	end
	return due, unread, read;
end

-- The cast to offer: the first that is due and in reach, in the order of the
-- list, except that one pressed a moment ago goes behind the rest. With
-- nothing in reach, the first that is due out of range, to be shown only.
local function Next()
	local scan = NewScan();
	local best, bestTried, far;
	for _, buff in ipairs(db.buffs) do
		if Known(buff) then
			for _, entry in ipairs((Survey(buff, scan))) do
				if entry.far then
					far = far or entry;
				else
					local at = tried[entry.key];
					if at and scan.now - at > RETRY then
						at, tried[entry.key] = nil, nil;
					end
					at = at or 0;
					if not best or at < bestTried then
						best, bestTried = entry, at;
					end
				end
			end
		end
	end
	return best or far;
end

local function Describe(entry)
	local text;
	if entry.state == "missing" then
		text = ("%s is missing on %s"):format(entry.buff.name, UnitLabel(entry.unit));
	else
		text = ("%s runs out on %s in %s"):format(entry.buff.name, UnitLabel(entry.unit), Clock(entry.left));
	end
	return entry.far and text .. ", out of range" or text;
end

-- The cast to offer and why, or nothing and why not.
local function Decide()
	if button:GetAttribute("state-safety") == "blocked" or UnitIsDeadOrGhost("player")
		or (IsMounted and IsMounted()) or (UnitOnTaxi and UnitOnTaxi("player")) then
		return nil, "paused while dead or mounted";
	end
	if #db.buffs == 0 then
		return nil, "no buffs are watched";
	end
	local action = Next();
	if not action then
		return nil, "nothing is due";
	end
	return action, Describe(action);
end

-- Decide, with anything that goes wrong in it taken as nothing to offer: the
-- game may hand out values that cannot be looked at, and looking is an error.
local function Look()
	local ok, action, why = pcall(Decide);
	if not ok then
		if not lookFailed then
			lookFailed = true;
			Print("could not check your buffs: " .. tostring(action));
		end
		return nil, "the check failed: " .. tostring(action);
	end
	return action, why;
end

-- The button ---------------------------------------------------------------

-- The plain look: a square icon on black. It stays only where there is no
-- action button to copy the bar look from (see Style).
local function Skin(frame)
	frame.background = frame:CreateTexture(nil, "BACKGROUND");
	frame.background:SetAllPoints();
	frame.background:SetColorTexture(0, 0, 0, 0.85);

	frame.icon = frame:CreateTexture(nil, "ARTWORK");
	frame.icon:SetPoint("TOPLEFT", 1, -1);
	frame.icon:SetPoint("BOTTOMRIGHT", -1, 1);
	frame.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93);

	frame.plainHighlight = frame:CreateTexture(nil, "HIGHLIGHT");
	frame.plainHighlight:SetAllPoints(frame.icon);
	frame.plainHighlight:SetColorTexture(1, 1, 1, 0.25);
	frame.plainHighlight:SetBlendMode("ADD");
end

-- The bar look is copied at run time from a Blizzard action button, piece by
-- piece, instead of naming the art here: that follows whatever this client's
-- bars look like. `source` is that action button, `scale` our size over its.

local function CopyArt(to, from)
	local atlas = from:GetAtlas();
	if atlas then
		to:SetAtlas(atlas);
	else
		to:SetTexture(from:GetTexture());
		to:SetTexCoord(from:GetTexCoord());
	end
end

-- Size and anchors. What was anchored to the source's icon goes on ours,
-- anything else on the frame.
local function CopyPlacement(to, from, source, frame, scale)
	local width, height = from:GetSize();
	local points = from:GetNumPoints();
	to:ClearAllPoints();
	to:SetSize(width * scale, height * scale);
	for i = 1, points do
		local point, relativeTo, relativePoint, x, y = from:GetPoint(i);
		to:SetPoint(point, relativeTo == source.icon and frame.icon or frame, relativePoint, x * scale, y * scale);
	end
	if points == 0 then
		to:SetAllPoints(frame);
	end
end

-- state: "Normal" (the border), "Pushed" or "Highlight"
local function CopyStateTexture(frame, source, state, scale)
	local from = source["Get" .. state .. "Texture"](source);
	local atlas = from and from:GetAtlas();
	local file = from and from:GetTexture();
	if atlas then
		frame["Set" .. state .. "Atlas"](frame, atlas);
	elseif file then
		frame["Set" .. state .. "Texture"](frame, file);
	else
		return;
	end
	local to = frame["Get" .. state .. "Texture"](frame);
	if not atlas then
		to:SetTexCoord(from:GetTexCoord());
	end
	to:SetBlendMode(from:GetBlendMode());
	CopyPlacement(to, from, source, frame, scale);
end

local function Style(frame, source, scale)
	local icon, mask, slot = source.icon, source.IconMask, source.SlotBackground;
	frame.plainHighlight:Hide();
	if icon then
		CopyPlacement(frame.icon, icon, source, frame, scale);
		frame.icon:SetTexCoord(icon:GetTexCoord());
		-- The background goes one sublevel under the icon, whatever layer that
		-- is: within one sublevel the draw order is not ours to choose.
		local layer, sublevel = icon:GetDrawLayer();
		sublevel = math.max(sublevel or 0, -7);
		frame.icon:SetDrawLayer(layer, sublevel);
		frame.background:SetDrawLayer(layer, sublevel - 1);
	end
	if mask then
		if not frame.mask then
			frame.mask = frame:CreateMaskTexture();
			frame.icon:AddMaskTexture(frame.mask);
		end
		CopyArt(frame.mask, mask);
		CopyPlacement(frame.mask, mask, source, frame, scale);
	end
	if slot then
		CopyArt(frame.background, slot);
		CopyPlacement(frame.background, slot, source, frame, scale);
	end
	CopyStateTexture(frame, source, "Normal", scale);
	CopyStateTexture(frame, source, "Pushed", scale);
	CopyStateTexture(frame, source, "Highlight", scale);
end

local styleFailed = false;

-- Gives a frame of ours, `size` wide, the look of the stock action buttons,
-- unless it already has it. A failure is reported once and leaves the frame
-- usable, if not pretty.
local function StyleAsSlot(frame, size)
	local source = _G.MultiBarBottomLeftButton1 or _G.ActionButton1;
	if not source then
		return;
	end
	local border = source:GetNormalTexture();
	-- The border art, which the client can swap after login
	local look = border and (border:GetAtlas() or border:GetTexture());
	local scale = size / source:GetWidth();
	if frame.styleSource == source and frame.styleScale == scale and frame.styleLook == look then
		return;
	end
	frame.styleSource, frame.styleScale, frame.styleLook = source, scale, look;
	local ok, problem = pcall(Style, frame, source, scale);
	if not ok and not styleFailed then
		styleFailed = true;
		Print("could not copy the action bar look: " .. tostring(problem));
	end
end

local function ShowButtonTooltip(self)
	local action = self.action;
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
	if action then
		GameTooltip:AddLine(action.buff.name);
		if action.state == "missing" then
			GameTooltip:AddLine("Missing on " .. UnitLabel(action.unit) .. ".", 1, 1, 1);
		else
			GameTooltip:AddLine(("Runs out on %s in %s."):format(UnitLabel(action.unit), Clock(action.left)), 1, 1, 1);
		end
		if action.far then
			GameTooltip:AddLine("Out of range.", 1, 0.3, 0.3);
		elseif db.key then
			GameTooltip:AddLine(KeyText(db.key) .. " or a click casts it.", 1, 1, 1);
		else
			GameTooltip:AddLine("A click casts it.", 1, 1, 1);
		end
		GameTooltip:AddLine("Alt-drag to move. Right-click for options.", 0.5, 0.5, 0.5);
	else
		GameTooltip:AddLine("Rebuff");
		GameTooltip:AddLine("The next buff to cast shows here.", 1, 1, 1);
		GameTooltip:AddLine("Drag to move.", 0.5, 0.5, 0.5);
	end
	GameTooltip:Show();
end

local function PlaceButton()
	button:ClearAllPoints();
	button:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y);
end

local function CreateButton()
	local frame = CreateFrame("Button", "RebuffButton", UIParent, "SecureActionButtonTemplate,SecureHandlerStateTemplate");
	frame:Hide();
	frame:SetFrameStrata("MEDIUM");
	frame:SetClampedToScreen(true);
	frame:SetMovable(true);
	frame:RegisterForDrag("LeftButton");
	-- Both edges: which one casts is the game's choice, by the next attribute
	frame:RegisterForClicks("AnyDown", "AnyUp");
	frame:SetAttribute("useOnKeyDown", true);
	-- The unit named is the unit cast on, whatever the self-cast key or the
	-- mouse is over
	frame:SetAttribute("checkselfcast", false);
	frame:SetAttribute("checkfocuscast", false);
	frame:SetAttribute("checkmouseovercast", false);

	Skin(frame);
	frame.time = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal");
	frame.time:SetPoint("BOTTOMRIGHT", -3, 3);
	frame.hotkey = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray");
	frame.hotkey:SetPoint("TOPRIGHT", -3, -4);
	frame.who = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	frame.who:SetPoint("TOP", frame, "BOTTOM", 0, -3);

	frame:SetScript("OnDragStart", function(self)
		-- The stand-in shown while the options are open casts nothing, so it
		-- needs no Alt to tell a drag from a press
		if (self.placeholder or IsAltKeyDown()) and not InCombatLockdown() then
			self:StartMoving();
		end
	end);
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing();
		if not InCombatLockdown() then
			db.point, _, db.relativePoint, db.x, db.y = self:GetPoint();
			PlaceButton();
		end
	end);
	frame:SetScript("OnEnter", ShowButtonTooltip);
	frame:SetScript("OnLeave", GameTooltip_Hide);
	frame:SetScript("PostClick", function(self, mouseButton, down)
		if mouseButton == "RightButton" then
			if not down and ns.ToggleWindow then
				ns.ToggleWindow();
			end
			return;
		end
		-- A press arrives as two clicks, down and up: count it once
		local action, now = current, GetTime();
		if action and not action.far and now - lastPress > PRESS_GAP then
			lastPress = now;
			tried[action.key] = now;
			dirty = true;
		end
	end);
	frame:HookScript("OnAttributeChanged", function(_, name, value)
		if name ~= "state-safety" then
			return;
		end
		if value == "blocked" then
			-- The game has hidden the button and cleared the key
			bound, current, wasCastable = nil, nil, false;
		end
		dirty = true;
	end);

	frame:SetAttribute("_onstate-safety", SAFETY);
	RegisterStateDriver(frame, "safety", SAFETY_STATES);
	button = frame;
	PlaceButton();
end

local function SetAttribute(name, value)
	if button:GetAttribute(name) ~= value then
		button:SetAttribute(name, value);
	end
end

-- Gives the button the key, or with nil takes it away again. The key is held
-- only while there is something to cast: the rest of the time it does what
-- it always did.
local function Bind(key)
	if bound == key then
		return;
	end
	ClearOverrideBindings(button);
	bound = nil;
	if key then
		local ok, problem = pcall(SetOverrideBindingClick, button, true, key, "RebuffButton", "LeftButton");
		if ok then
			bound = key;
		elseif not bindFailed then
			bindFailed = true;
			Print(("could not take the key %s: %s"):format(key, tostring(problem)));
		end
	end
end

-- Brings the button in line with the cast to offer. Not in combat.
local function Present(action, why)
	local castable = action ~= nil and not action.far;
	local placeholder = action == nil and ns.WindowShown ~= nil and ns.WindowShown();
	if castable then
		-- By name: the highest rank known
		SetAttribute("spell", action.buff.name);
		SetAttribute("unit", action.unit);
		-- With the wildcard the press also counts with Shift, Ctrl or Alt
		-- held, which a key such as SHIFT-Q always has
		SetAttribute("*type1", "spell");
	else
		SetAttribute("*type1", nil);
		SetAttribute("spell", nil);
		SetAttribute("unit", nil);
	end
	Bind(castable and db.key or nil);

	button.action, button.placeholder = action, placeholder;
	if action or placeholder then
		local icon = action and (GetSpellTexture(action.buff.id) or GetSpellTexture(action.buff.name));
		button:SetSize(db.size, db.size);
		StyleAsSlot(button, db.size);
		button.icon:SetTexture(placeholder and PORTRAIT or icon or QUESTION_MARK);
		button.icon:SetDesaturated(not castable);
		button.time:SetText(action and action.left and Clock(action.left) or "");
		button.hotkey:SetText(castable and bound and ShortKey(bound) or "");
		if placeholder then
			button.who:SetText("Rebuff");
		else
			button.who:SetText(action.unit ~= "player" and UnitLabel(action.unit) or "");
		end
		if castable then
			button.who:SetTextColor(1, 1, 1);
		else
			button.who:SetTextColor(0.6, 0.6, 0.6);
		end
		button:Show();
	else
		button:Hide();
	end

	if castable and not wasCastable and db.sound and GetTime() - lastSound >= SOUND_GAP then
		PlaySound(SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3 or ALARM);
		lastSound = GetTime();
	end
	wasCastable = castable;
	current, reason = action, why;
end

-- Looks at the buffs and updates the button. In combat it only notes that
-- nothing can be told.
Refresh = function()
	dirty, sinceLook = false, 0;
	if not db then
		return;
	end
	if InCombatLockdown() then
		current, reason, wasCastable = nil, "in combat", false;
	else
		if not button and not buttonFailed then
			local ok, problem = pcall(CreateButton);
			if not ok then
				buttonFailed, button = true, nil;
				Print("could not make the cast button: " .. tostring(problem));
			end
		end
		if button then
			local ok, problem = pcall(Present, Look());
			if not ok then
				current, reason = nil, "the button could not be updated: " .. tostring(problem);
				if not presentFailed then
					presentFailed = true;
					Print(reason);
				end
			end
		else
			current, reason = nil, "the cast button could not be made";
		end
	end
	if ns.UpdateWindow then
		ns.UpdateWindow();
	end
end

-- Saved data and events ----------------------------------------------------

local function Load()
	local fresh = RebuffDB == nil;
	RebuffDB = RebuffDB or {};
	db = RebuffDB;
	db.buffs = db.buffs or {};
	-- A key that was cleared is kept as false, so that it stays cleared
	if db.key == nil then
		db.key = DEFAULT_KEY;
	end
	if db.sound == nil then
		db.sound = true;
	end
	db.warn = db.warn or DEFAULT_WARN;
	db.size = db.size or DEFAULT_SIZE;
	if not (db.point and db.relativePoint and db.x and db.y) then
		db.point, db.relativePoint, db.x, db.y = "CENTER", "CENTER", 0, -120;
	end

	for _, pair in ipairs(PAIRS) do
		local single, group = GetSpellName(pair[1]), GetSpellName(pair[2]);
		if single and group then
			partner[single], partner[group] = group, single;
		end
	end

	if fresh then
		Print("type /rebuff and drop the buffs you want kept up onto the window.");
	end
	Refresh();
end

local WATCHED = { "^player$", "^party%d+$", "^raid%d+$" };

local EVENTS = {
	"UNIT_AURA", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
	"PLAYER_REGEN_ENABLED", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
	"PLAYER_MOUNT_DISPLAY_CHANGED", "SPELLS_CHANGED", "UNIT_CONNECTION",
};

local events = CreateFrame("Frame");
events:RegisterEvent("PLAYER_LOGIN");
events:SetScript("OnEvent", function(self, event, unit)
	if event == "PLAYER_LOGIN" then
		Load();
		for _, name in ipairs(EVENTS) do
			-- One this client does not have is no reason to lose the rest
			pcall(self.RegisterEvent, self, name);
		end
	elseif event == "UNIT_AURA" then
		if not Secret(unit) and type(unit) == "string" then
			for _, pattern in ipairs(WATCHED) do
				if unit:find(pattern) then
					dirty = true;
				end
			end
		end
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		Refresh();
	else
		dirty = true;
	end
end);
events:SetScript("OnUpdate", function(_, elapsed)
	sinceLook = sinceLook + elapsed;
	if db and ((dirty and sinceLook >= SETTLE) or sinceLook >= TICK) then
		Refresh();
	end
end);

-- Settings -----------------------------------------------------------------
-- The changes the slash command and the options window make. They are plain
-- saved data, so they are taken in combat too; the button follows after it.

local function FindBuff(name)
	for index, buff in ipairs(db.buffs) do
		if buff.name == name then
			return buff, index;
		end
	end
end

-- Whether a spell is cast on others. A guess to start from; the options
-- window has the choice.
local function GuessWho(id, name)
	local ok, helpful = false, nil;
	if C_Spell and C_Spell.IsSpellHelpful then
		ok, helpful = pcall(C_Spell.IsSpellHelpful, id);
	elseif IsHelpfulSpell then
		ok, helpful = pcall(IsHelpfulSpell, name);
	end
	return ok and not Secret(helpful) and helpful and "party" or "self";
end

-- Starts watching the spell on the cursor, before the buff at `position` or
-- at the end. Returns the buff: the new one, or the one it already was.
function ns.AddFromCursor(position)
	local kind, _, _, spellID = GetCursorInfo();
	if kind ~= "spell" or not spellID then
		if kind then
			Print("only spells from your spellbook can be watched.");
		end
		return;
	end
	local name = GetSpellName(spellID);
	if not name then
		return;
	end
	local buff = FindBuff(name);
	if not buff then
		if #db.buffs >= MAX_BUFFS then
			Print(("that is the most buffs Rebuff watches (%d)."):format(MAX_BUFFS));
			return;
		end
		buff = { id = spellID, name = name, who = GuessWho(spellID, name) };
		table.insert(db.buffs, math.min(position or #db.buffs + 1, #db.buffs + 1), buff);
	end
	ClearCursor();
	Refresh();
	return buff;
end

function ns.Remove(buff)
	local _, index = FindBuff(buff.name);
	if index then
		table.remove(db.buffs, index);
		Refresh();
		return true;
	end
end

function ns.SetWho(buff, who)
	if who == "self" or who == "party" then
		buff.who = who;
		Refresh();
		return true;
	end
end

function ns.SetWarn(seconds)
	db.warn = math.min(math.max(seconds, 0), 600);
	Refresh();
end

-- A key as the bindings name it, such as MOUSEWHEELDOWN or SHIFT-Q; nil for none.
function ns.SetKey(key)
	db.key = key and key ~= "" and strupper(key) or false;
	bindFailed = false;
	Refresh();
end

function ns.SetSound(on)
	db.sound = on and true or false;
end

local function SetSize(size)
	db.size = math.min(math.max(size, 20), 80);
	Refresh();
end

local function ResetPosition()
	if InCombatLockdown() then
		Print("the button cannot be moved in combat.");
		return;
	end
	db.point, db.relativePoint, db.x, db.y = "CENTER", "CENTER", 0, -120;
	if button then
		PlaceButton();
	end
end

-- For the options window: where one buff stands, in a few words.
function ns.Status(buff)
	if InCombatLockdown() then
		return "In combat";
	elseif not Known(buff) then
		return "Not learned";
	end
	local ok, due, unread, read = pcall(Survey, buff, NewScan());
	if not ok then
		return "Cannot be checked";
	elseif #due == 0 then
		return (read == 0 and unread > 0) and "Cannot be read" or "Up";
	end
	local first = due[1];
	local text = first.state == "missing" and "Missing" or Clock(first.left) .. " left";
	if first.unit ~= "player" then
		text = text .. " on " .. UnitLabel(first.unit);
	end
	if #due > 1 then
		text = ("%s +%d"):format(text, #due - 1);
	end
	return text;
end

-- What Rebuff sees and does right now, for when it does not do what it should.
local function PrintStatus()
	Print("status");
	print(("  now: %s"):format(reason or "nothing"));
	print(("  hotkey: %s, %s"):format(KeyText(db.key or nil),
		bound and "held by Rebuff now" or "not held now, it does what it always does"));
	if button then
		print(("  button: %s, casts %s on %s"):format(button:IsShown() and "shown" or "hidden",
			tostring(button:GetAttribute("spell")), tostring(button:GetAttribute("unit"))));
	end
	if InCombatLockdown() then
		return;
	end
	local scan = NewScan();
	for _, buff in ipairs(db.buffs) do
		local line;
		if not Known(buff) then
			line = "not learned";
		else
			local ok, due, unread, read = pcall(Survey, buff, scan);
			if not ok then
				line = "check failed: " .. tostring(due);
			else
				local parts = {};
				for _, entry in ipairs(due) do
					parts[#parts + 1] = ("%s on %s%s"):format(
						entry.state == "missing" and "missing" or Clock(entry.left) .. " left",
						UnitLabel(entry.unit), entry.far and " (out of range)" or "");
				end
				line = #parts > 0 and table.concat(parts, ", ") or "up";
				line = ("%s; %d read, %d unreadable"):format(line, read, unread);
			end
		end
		print(("  %s (%s): %s"):format(buff.name, buff.who == "party" and "party" or "self", line));
	end
end

local function PrintHelp()
	Print("/rebuff opens the options. As commands:");
	print("  /rebuff status - what Rebuff sees right now");
	print("  /rebuff key <key> - the hotkey, such as MOUSEWHEELDOWN or SHIFT-Q; none for no key. Now " .. KeyText(db.key or nil));
	print("  /rebuff warn <seconds> - how long before a buff runs out it shows; 0 for only once it is gone. Now " .. db.warn);
	print("  /rebuff sound on|off - a sound when a buff comes due, now " .. (db.sound and "on" or "off"));
	print("  /rebuff size <20-80> - size of the button, now " .. db.size);
	print("  /rebuff reset - put the button back in the middle of the screen");
end

SLASH_REBUFF1 = "/rebuff";
SLASH_REBUFF2 = "/rb";
SlashCmdList.REBUFF = function(message)
	local command, argument = strlower(message or ""):match("^%s*(%S*)%s*(.-)%s*$");
	local number = tonumber(argument);
	if command == "" and ns.ToggleWindow then
		ns.ToggleWindow();
	elseif command == "status" then
		PrintStatus();
	elseif command == "key" and argument ~= "" then
		ns.SetKey(argument ~= "none" and argument or nil);
		Print("the hotkey is now " .. KeyText(db.key or nil) .. ".");
	elseif command == "warn" and number then
		ns.SetWarn(number);
	elseif command == "sound" and (argument == "on" or argument == "off") then
		ns.SetSound(argument == "on");
	elseif command == "size" and number then
		SetSize(number);
	elseif command == "reset" then
		ResetPosition();
	else
		PrintHelp();
	end
end

-- For the options window
ns.MAX_BUFFS = MAX_BUFFS;
ns.PORTRAIT = PORTRAIT;
ns.QUESTION_MARK = QUESTION_MARK;
ns.Print = Print;
ns.PrintHelp = PrintHelp;
ns.Skin = Skin;
ns.StyleAsSlot = StyleAsSlot;
ns.KeyText = KeyText;
ns.Refresh = function()
	Refresh();
end

function ns.Buffs()
	return db.buffs;
end

function ns.Settings()
	return db;
end

function ns.BuffIcon(buff)
	return GetSpellTexture(buff.id) or GetSpellTexture(buff.name) or QUESTION_MARK;
end
