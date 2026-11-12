-- Rebuff's options window, after the game's own macro window: the watched
-- buffs as a grid of slots on top, the selected one's settings under it, and
-- below those the settings that hold for all of them. A buff is added by
-- dropping its spell on the grid.
--
-- It is built on first use, and built and filled under pcall: a template or
-- widget call this client turns out not to have costs the window and never
-- the button.

local _, ns = ...;

local WIDTH, HEIGHT = 338, 512;
local MARGIN = 29;
local INNER = WIDTH - 2 * MARGIN;
local SLOT, SLOT_GAP, COLUMNS = 40, 8, 6;
local CLASS, CLASS_GAP = 24, 6;
local CLASS_ICONS = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes";

local WHO = {
	{ key = "self", label = "Myself", note = "Watched on you alone." },
	{ key = "party", label = "My party", note = "Watched on you and your party; in a raid, on your own group. Pick classes to keep it to those." },
};

local WARNINGS = {
	{ seconds = 30, label = "30 sec" },
	{ seconds = 60, label = "1 min" },
	{ seconds = 120, label = "2 min" },
	{ seconds = 300, label = "5 min" },
	{ seconds = 0, label = "Only once it is gone" },
};

-- Keys that only ever go with another
local MODIFIERS = {
	LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
	LMETA = true, RMETA = true, UNKNOWN = true,
};
local MOUSE = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" };

local window;
-- Set once building or filling the window has failed; /rebuff prints help from then on
local failed = false;
-- The buff whose settings show
local selected;
-- Whether the hotkey button is waiting for a key
local listening = false;
local Update;

local function Sound(name)
	local id = SOUNDKIT and SOUNDKIT[name];
	if id then
		PlaySound(id);
	end
end

-- Starts watching the spell on the cursor and selects it.
local function DropAt(position)
	local buff = ns.AddFromCursor(position);
	if buff then
		selected = buff;
		Update();
	end
end

-- A stock window frame. Which templates exist, and where they keep their
-- title, portrait and close button, differs between clients.
local function CreateWindowFrame()
	local frame;
	for _, template in ipairs({ "ButtonFrameTemplate", "PortraitFrameTemplate", "BasicFrameTemplateWithInset" }) do
		local ok, created = pcall(CreateFrame, "Frame", "RebuffWindow", UIParent, template);
		if ok and created then
			frame = created;
			break;
		end
	end
	if not frame then
		frame = CreateFrame("Frame", "RebuffWindow", UIParent, "BackdropTemplate");
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		});
	end
	frame:Hide();
	frame:SetSize(WIDTH, HEIGHT);
	frame:SetPoint("CENTER", UIParent, "CENTER", -280, 40);
	frame:SetFrameStrata("HIGH");
	frame:SetToplevel(true);
	frame:EnableMouse(true);
	frame:SetMovable(true);
	frame:SetClampedToScreen(true);
	frame:RegisterForDrag("LeftButton");
	frame:SetScript("OnDragStart", frame.StartMoving);
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing);
	-- Escape closes it
	tinsert(UISpecialFrames, "RebuffWindow");

	local close = frame.CloseButton or frame.closeButton
		or (frame.TitleContainer and frame.TitleContainer.CloseButton);
	if not close then
		close = CreateFrame("Button", nil, frame, "UIPanelCloseButton");
		close:SetPoint("TOPRIGHT", -3, -3);
	end
	-- The stock handler closes through the panel manager, which is blocked
	-- in combat; this window is not secure and can simply hide.
	close:SetScript("OnClick", function()
		frame:Hide();
	end);

	local title = frame.TitleText or (frame.TitleContainer and frame.TitleContainer.TitleText);
	if not title then
		title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal");
		title:SetPoint("TOP", 0, -6);
	end
	title:SetText("Rebuff");

	frame.portrait = frame.portrait or (frame.PortraitContainer and frame.PortraitContainer.portrait);
	return frame;
end

-- A square icon in the round portrait. Decoration only, hence its own pcall.
local function DressPortrait(portrait)
	portrait:SetTexture(ns.PORTRAIT);
	portrait:SetTexCoord(0.07, 0.93, 0.07, 0.93);
	local mask = portrait:GetParent():CreateMaskTexture();
	mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE");
	mask:SetAllPoints(portrait);
	portrait:AddMaskTexture(mask);
end

local function ShowSlotTooltip(self)
	local buff = self.buff;
	if not buff then
		return;
	end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
	GameTooltip:AddLine(buff.name);
	GameTooltip:AddLine(ns.Status(buff), 1, 1, 1);
	GameTooltip:AddLine("Shift-right-click to stop watching it.", 0.5, 0.5, 0.5);
	GameTooltip:Show();
end

-- One watched buff in the grid, or a free place for one.
local function CreateSlot(parent, index)
	local slot = CreateFrame("Button", nil, parent);
	local column, row = (index - 1) % COLUMNS, math.floor((index - 1) / COLUMNS);
	slot.position = index;
	slot:SetSize(SLOT, SLOT);
	slot:SetPoint("TOPLEFT", parent, "TOPLEFT", column * (SLOT + SLOT_GAP), -row * (SLOT + SLOT_GAP));
	ns.Skin(slot);

	slot:RegisterForClicks("LeftButtonUp", "RightButtonUp");
	slot:SetScript("OnClick", function(self, mouseButton)
		if GetCursorInfo() then
			DropAt(self.position);
		elseif self.buff and mouseButton == "RightButton" and IsShiftKeyDown() then
			ns.Remove(self.buff);
			Update();
		elseif self.buff then
			selected = self.buff;
			Sound("IG_MAINMENU_OPTION_CHECKBOX_ON");
			Update();
		end
	end);
	slot:SetScript("OnReceiveDrag", function(self)
		DropAt(self.position);
	end);
	slot:SetScript("OnEnter", ShowSlotTooltip);
	slot:SetScript("OnLeave", GameTooltip_Hide);
	return slot;
end

-- The class's icon, from whichever of the client's sets of them is there; a
-- square in the class colour where neither is.
local function SetClassIcon(texture, class)
	local atlas = "classicon-" .. strlower(class);
	local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class];
	local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class];
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
		texture:SetAtlas(atlas);
	elseif coords then
		texture:SetTexture(CLASS_ICONS);
		texture:SetTexCoord(unpack(coords));
	elseif colour then
		texture:SetColorTexture(colour.r, colour.g, colour.b);
	else
		texture:SetColorTexture(0.5, 0.5, 0.5);
	end
end

-- One class of a party buff: lit when the buff is kept on that class.
local function CreateClass(parent, index, class)
	local button = CreateFrame("Button", nil, parent);
	button.class = class;
	button:SetSize(CLASS, CLASS);
	button:SetPoint("LEFT", parent, "LEFT", (index - 1) * (CLASS + CLASS_GAP), 0);
	button.icon = button:CreateTexture(nil, "ARTWORK");
	button.icon:SetAllPoints();
	SetClassIcon(button.icon, class);
	local highlight = button:CreateTexture(nil, "HIGHLIGHT");
	highlight:SetAllPoints();
	highlight:SetColorTexture(1, 1, 1, 0.2);
	highlight:SetBlendMode("ADD");

	button:SetScript("OnClick", function(self)
		Sound("IG_MAINMENU_OPTION_CHECKBOX_ON");
		ns.ToggleClass(selected, self.class);
		Update();
	end);
	button:SetScript("OnEnter", function(self)
		local name = ns.ClassName(self.class);
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
		GameTooltip:AddLine(name);
		if not selected.classes then
			GameTooltip:AddLine("Kept on every class. Click to keep it on this class only.", 1, 1, 1, true);
		elseif selected.classes[self.class] then
			GameTooltip:AddLine("Kept on this class. Click to leave it out.", 1, 1, 1, true);
		else
			GameTooltip:AddLine("Left out. Click to keep it on this class too.", 1, 1, 1, true);
		end
		GameTooltip:Show();
	end);
	button:SetScript("OnLeave", GameTooltip_Hide);
	return button;
end

-- A checkbox with its label beside it. The label is part of the click target.
local function CreateCheck(parent, label, onClick)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate");
	check:SetSize(24, 24);
	local text = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight");
	text:SetPoint("LEFT", check, "RIGHT", 1, 1);
	text:SetText(label);
	check:SetHitRectInsets(0, -(text:GetStringWidth() + 4), 0, 0);
	check:SetScript("OnClick", function(self)
		Sound("IG_MAINMENU_OPTION_CHECKBOX_ON");
		onClick(self);
		-- A radio that was already the choice has just unticked itself
		Update();
	end);
	return check;
end

local function CreateLabel(parent, text, y)
	local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
	label:SetPoint("TOPLEFT", MARGIN, y);
	label:SetText(text);
	return label;
end

local function CreateDivider(parent, y)
	local divider = parent:CreateTexture(nil, "ARTWORK");
	divider:SetColorTexture(1, 1, 1, 0.12);
	divider:SetPoint("TOPLEFT", MARGIN, y);
	divider:SetSize(INNER, 1);
end

-- The hotkey button: a click and it takes the next key, wheel turn or extra
-- mouse button as the hotkey.

local function Listen(button, on)
	listening = on;
	button:EnableKeyboard(on);
	button:EnableMouseWheel(on);
	Update();
end

local function Capture(button, key)
	local prefix = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
		.. (IsShiftKeyDown() and "SHIFT-" or "");
	ns.SetKey(prefix .. key);
	Sound("IG_MAINMENU_OPTION_CHECKBOX_ON");
	Listen(button, false);
end

local function CreateKeyButton(parent)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate");
	button:SetSize(170, 22);
	button:RegisterForClicks("AnyUp");
	button:EnableKeyboard(false);
	button:EnableMouseWheel(false);
	button:SetScript("OnClick", function(self, mouseButton)
		if listening then
			if MOUSE[mouseButton] then
				Capture(self, MOUSE[mouseButton]);
			else
				Listen(self, false);
			end
		elseif mouseButton == "RightButton" then
			ns.SetKey(nil);
			Update();
		elseif mouseButton == "LeftButton" then
			Listen(self, true);
		end
	end);
	button:SetScript("OnKeyDown", function(self, key)
		if key == "ESCAPE" then
			Listen(self, false);
		elseif not MODIFIERS[key] then
			Capture(self, key);
		end
	end);
	button:SetScript("OnMouseWheel", function(self, delta)
		Capture(self, delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN");
	end);
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
		GameTooltip:AddLine("Hotkey");
		GameTooltip:AddLine("Casts the buff Rebuff shows. The key is Rebuff's only while a buff is due; the rest of the time it does what it always did.", 1, 1, 1, true);
		GameTooltip:AddLine("Click, then press a key or turn the mouse wheel. Right-click for no key.", 0.5, 0.5, 0.5, true);
		GameTooltip:Show();
	end);
	button:SetScript("OnLeave", GameTooltip_Hide);
	button:SetScript("OnHide", function(self)
		if listening then
			listening = false;
			self:EnableKeyboard(false);
			self:EnableMouseWheel(false);
		end
	end);
	return button;
end

local function Build()
	local frame = CreateWindowFrame();
	if frame.portrait then
		pcall(DressPortrait, frame.portrait);
	end

	-- Everything of ours goes on a layer above the template's own parts: its
	-- inset has a background that would otherwise cover what is drawn on the
	-- frame itself.
	local body = CreateFrame("Frame", nil, frame);
	body:SetAllPoints();
	body:SetFrameLevel(frame:GetFrameLevel() + 5);

	local hintLeft = frame.portrait and 70 or MARGIN;
	local hint = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	hint:SetPoint("TOPLEFT", hintLeft, -30);
	hint:SetWidth(WIDTH - hintLeft - MARGIN);
	hint:SetJustifyH("LEFT");
	hint:SetText("Drop the buffs to keep up here, from your spellbook. When several are due, the first in the grid goes first.");

	local grid = CreateFrame("Button", nil, body);
	grid:SetPoint("TOPLEFT", MARGIN, -72);
	grid:SetSize(INNER, 2 * SLOT + SLOT_GAP);
	-- The gaps between the slots take a drop too
	grid:SetScript("OnClick", function()
		if GetCursorInfo() then
			DropAt();
		end
	end);
	grid:SetScript("OnReceiveDrag", function()
		DropAt();
	end);
	frame.slots = {};
	for index = 1, ns.MAX_BUFFS do
		frame.slots[index] = CreateSlot(grid, index);
	end

	CreateDivider(body, -170);

	frame.empty = body:CreateFontString(nil, "OVERLAY", "GameFontDisable");
	frame.empty:SetPoint("TOP", 0, -204);
	frame.empty:SetText("No buffs yet. Drop a spell on a slot.");

	-- The selected buff's settings
	local detail = CreateFrame("Frame", nil, body);
	detail:SetPoint("TOPLEFT", 0, -178);
	detail:SetSize(WIDTH, 118);
	frame.detail = detail;

	detail.name = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge");
	detail.name:SetPoint("TOPLEFT", MARGIN, 0);
	detail.status = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	detail.status:SetPoint("TOPRIGHT", -MARGIN, -4);

	CreateLabel(detail, "Keep it on", -24);
	detail.who = {};
	for index, who in ipairs(WHO) do
		local radio = CreateCheck(detail, who.label, function()
			ns.SetWho(selected, who.key);
		end);
		radio:SetPoint("TOPLEFT", MARGIN - 4 + (index - 1) * 100, -36);
		detail.who[who.key] = radio;
	end
	detail.note = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	detail.note:SetPoint("TOPLEFT", MARGIN, -62);
	detail.note:SetWidth(INNER);
	detail.note:SetJustifyH("LEFT");
	detail.note:SetJustifyV("TOP");
	detail.note:SetHeight(24);

	-- Which classes of the party; for a buff kept on the party only
	detail.classRow = CreateFrame("Frame", nil, detail);
	detail.classRow:SetPoint("TOPLEFT", MARGIN, -90);
	detail.classRow:SetSize(INNER, CLASS);
	detail.classes = {};
	for index, class in ipairs(ns.CLASSES) do
		detail.classes[index] = CreateClass(detail.classRow, index, class);
	end

	CreateDivider(body, -300);

	-- What holds for every buff
	CreateLabel(body, "Show a buff when it has less than", -310);
	frame.warnings = {};
	for index, warning in ipairs(WARNINGS) do
		local radio = CreateCheck(body, warning.label, function()
			ns.SetWarn(warning.seconds);
		end);
		if index <= 4 then
			radio:SetPoint("TOPLEFT", MARGIN - 4 + (index - 1) * 70, -322);
		else
			radio:SetPoint("TOPLEFT", MARGIN - 4, -344);
		end
		frame.warnings[warning.seconds] = radio;
	end

	CreateLabel(body, "Hotkey", -376);
	frame.key = CreateKeyButton(body);
	frame.key:SetPoint("TOPLEFT", MARGIN - 2, -389);

	frame.sound = CreateCheck(body, "Play a sound when a buff comes due", function(self)
		ns.SetSound(self:GetChecked() and true or false);
	end);
	frame.sound:SetPoint("TOPLEFT", MARGIN - 4, -418);

	local move = body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall");
	move:SetPoint("TOPLEFT", MARGIN, -448);
	move:SetWidth(INNER);
	move:SetJustifyH("LEFT");
	move:SetText("While this window is open the button shows, to be dragged into place.");

	frame.remove = CreateFrame("Button", nil, body, "UIPanelButtonTemplate");
	frame.remove:SetSize(96, 22);
	frame.remove:SetPoint("BOTTOMLEFT", 6, 4);
	frame.remove:SetText("Remove");
	frame.remove:SetScript("OnClick", function()
		if selected then
			ns.Remove(selected);
			Update();
		end
	end);

	-- Showing and hiding go through the button's refresh: it shows a stand-in
	-- of itself while the window is open, and fills the window when done
	frame:SetScript("OnShow", function()
		Sound("IG_CHARACTER_INFO_OPEN");
		ns.Refresh();
	end);
	frame:SetScript("OnHide", function()
		Sound("IG_CHARACTER_INFO_CLOSE");
		ns.Refresh();
	end);
	return frame;
end

local function Fill()
	local buffs = ns.Buffs();
	local settings = ns.Settings();
	local present = false;
	for _, buff in ipairs(buffs) do
		present = present or buff == selected;
	end
	if not present then
		selected = buffs[1];
	end

	for index, slot in ipairs(window.slots) do
		local buff = buffs[index];
		ns.StyleAsSlot(slot, SLOT);
		slot.buff = buff;
		slot.icon:SetTexture(buff and ns.BuffIcon(buff) or nil);
		if buff and buff == selected then
			slot:LockHighlight();
		else
			slot:UnlockHighlight();
		end
	end

	local detail = window.detail;
	detail:SetShown(selected ~= nil);
	window.empty:SetShown(selected == nil);
	window.remove:SetEnabled(selected ~= nil);
	if selected then
		detail.name:SetText(selected.name);
		detail.status:SetText(ns.Status(selected));
		for _, who in ipairs(WHO) do
			detail.who[who.key]:SetChecked(selected.who == who.key);
			if selected.who == who.key then
				detail.note:SetText(who.note);
			end
		end
		detail.classRow:SetShown(selected.who == "party");
		for _, class in ipairs(detail.classes) do
			local lit = ns.ClassAllowed(selected, class.class);
			class.icon:SetDesaturated(not lit);
			class:SetAlpha(lit and 1 or 0.4);
		end
	end

	for seconds, radio in pairs(window.warnings) do
		radio:SetChecked(settings.warn == seconds);
	end
	window.key:SetText(listening and "Press a key..." or ns.KeyText(settings.key or nil));
	window.sound:SetChecked(settings.sound and true or false);
end

-- Brings the window in line with the buffs. It runs in the middle of the
-- button's own work (after every look at the buffs), so a failure in here
-- must not get out: it closes the window for good instead.
Update = function()
	if not window then
		return;
	end
	local ok, problem = pcall(Fill);
	if not ok then
		failed = true;
		window:Hide();
		ns.Print("could not fill the options window: " .. tostring(problem));
	end
end

-- Runs after every look at the buffs.
function ns.UpdateWindow()
	if window and not failed and window:IsShown() then
		Update();
	end
end

function ns.WindowShown()
	return window ~= nil and not failed and window:IsShown();
end

function ns.ToggleWindow()
	if not window and not failed then
		local ok, result = pcall(Build);
		if ok then
			window = result;
		else
			failed = true;
			ns.Print("could not build the options window: " .. tostring(result));
		end
	end
	if window and not failed then
		window:SetShown(not window:IsShown());
	end
	-- Not an else: showing the window is what fills it for the first time
	if failed then
		ns.PrintHelp();
	end
end

-- The minimap's addon menu
function Rebuff_OnAddonCompartmentClick()
	ns.ToggleWindow();
end
