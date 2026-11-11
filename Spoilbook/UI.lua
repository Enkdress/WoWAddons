-- Spoilbook UI: a two-pane browser (list pane + detail pane), driven by
-- Core.lua's data. Styled like a native Blizzard options window: a left
-- category sidebar, real CheckButtons for settings, and two-line list rows
-- with the standard list-highlight texture instead of ad-hoc text blobs.

local S = Spoilbook

local ui = {
	tab = "inst", -- "inst" | "runs" | "set"
	selInstance = nil,
	selSession = nil,
	placeSub = "loot", -- within a selected place: "loot" (lifetime loot table) | "runs" (that place's run history)
	runsExpanded = {}, -- [placeName] = false once collapsed; absent/true means expanded
	wishExpanded = {}, -- same, for the Wishlist tab's per-place groups
	lootExpanded = {}, -- same, for a place's Loot Table, keyed by "place\0boss"
	dropsExpanded = {}, -- same, for a run's drop list, keyed by "sessionId\0boss"
}

local FRAME_SIZE = { w = 820, h = 540 }
local SIDEBAR_W = 112
local SPLIT_X = 470 -- x-offset (from frame's left edge) where the list pane ends and the detail pane begins

local QUALITY_OPTIONS = { { q = 2, label = "Uncommon+" }, { q = 3, label = "Rare+" }, { q = 4, label = "Epic+" } }

-- GetItemQualityColor() is retail-era API that doesn't exist on this classic-
-- rooted client. ITEM_QUALITY_COLORS is a plain data table present since
-- vanilla Classic, so read r/g/b straight off it instead.
local function Qc(quality)
	local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
	if c and c.r then
		return string.format("%02x%02x%02x", math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
	end
	return "ffffff"
end

-- Row scripts (OnClick/OnEnter/star) run outside Refresh()'s pcall wrapper, so
-- an error in one would otherwise fail completely silently (no chat message,
-- no visible effect) instead of showing up anywhere.
local function Safe(fn)
	if not fn then
		return nil
	end
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			print("|cffff5555Spoilbook UI error|r: " .. tostring(err))
		end
	end
end

local function ColorText(hex, text)
	return "|cff" .. hex .. text .. "|r"
end

local Refresh -- fwd decl

-- ===== frame skeleton =====

local frame = CreateFrame("Frame", "SpoilbookFrame", UIParent, "BackdropTemplate")
frame:SetSize(FRAME_SIZE.w, FRAME_SIZE.h)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:SetClampedToScreen(true)
frame:SetFrameStrata("HIGH")
frame:SetToplevel(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
-- A guaranteed-opaque fill underneath everything else: if the dialog-box art
-- asset below doesn't exist on this client (classic-rooted clients have
-- repeatedly turned out to be missing retail-only paths/APIs), the game world
-- showed through the panel instead of a solid background.
local opaqueBg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
opaqueBg:SetAllPoints()
opaqueBg:SetColorTexture(0.07, 0.06, 0.05, 1)

frame:SetBackdrop({
	bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
	edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32,
	insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:Hide()
tinsert(UISpecialFrames, "SpoilbookFrame")

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -16)
title:SetText("Spoilbook")

local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -4, -4)

local alertBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
alertBar:SetPoint("TOPLEFT", 14, -40)
alertBar:SetPoint("TOPRIGHT", -14, -40)
alertBar:SetHeight(24)
alertBar:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8x8", edgeFile = "Interface/Tooltips/UI-Tooltip-Border", edgeSize = 10 })
alertBar:SetBackdropColor(0.16, 0.12, 0.06, 0.92)
alertBar:Hide()
local alertText = alertBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
alertText:SetPoint("LEFT", 8, 0)
alertText:SetPoint("RIGHT", -8, 0)
alertText:SetJustifyH("LEFT")

-- ===== left sidebar (category list, Blizzard-options style) =====

local sidebar = CreateFrame("Frame", nil, frame)
sidebar:SetWidth(SIDEBAR_W)
sidebar:SetPoint("TOPLEFT", 14, -72)
sidebar:SetPoint("BOTTOMLEFT", 14, 14)

local sidebarDivider = sidebar:CreateTexture(nil, "ARTWORK")
sidebarDivider:SetPoint("TOPRIGHT", 0, 0)
sidebarDivider:SetPoint("BOTTOMRIGHT", 0, 0)
sidebarDivider:SetWidth(1)
sidebarDivider:SetColorTexture(0, 0, 0, 0.6)

local TABS = { { key = "inst", label = "Places" }, { key = "runs", label = "Runs" }, { key = "wish", label = "Wishlist" }, { key = "set", label = "Settings" } }
local navButtons = {}

local function SelectTab(key)
	ui.tab = key
	Refresh()
end

for i, t in ipairs(TABS) do
	local b = CreateFrame("Button", nil, sidebar)
	b:SetHeight(28)
	b:SetPoint("TOPLEFT", 0, -(i - 1) * 30)
	b:SetPoint("TOPRIGHT", 0, -(i - 1) * 30)

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.55, 0.45, 0.18, 0.35)
	bg:Hide()
	b.bg = bg

	local accent = b:CreateTexture(nil, "ARTWORK")
	accent:SetPoint("TOPLEFT", 0, 0)
	accent:SetPoint("BOTTOMLEFT", 0, 0)
	accent:SetWidth(3)
	accent:SetColorTexture(0.89, 0.76, 0.48, 1)
	accent:Hide()
	b.accent = accent

	local label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("LEFT", 12, 0)
	b.label = label
	label:SetText(t.label)

	b:SetHighlightTexture("Interface/Buttons/UI-Listbox-Highlight2", "ADD")
	b:SetScript("OnClick", function() SelectTab(t.key) end)
	navButtons[t.key] = b
end

-- ===== content area (list pane + detail pane) =====

local contentHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
contentHeader:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 16, -24)

-- sub-navigation shown only inside a selected place: lifetime loot table vs.
-- that place's individual runs.
local placeSubBar = CreateFrame("Frame", nil, frame)
placeSubBar:SetHeight(24)
placeSubBar:Hide()

local function MakeSubTabBtn(label, key)
	local b = CreateFrame("Button", nil, placeSubBar, "UIPanelButtonTemplate")
	b:SetSize(100, 22)
	b:SetText(label)
	b:SetScript("OnClick", function()
		ui.placeSub = key
		ui.selSession = nil
		Refresh()
	end)
	return b
end
local lootTabBtn = MakeSubTabBtn("Loot Table", "loot")
lootTabBtn:SetPoint("TOPLEFT", placeSubBar, "TOPLEFT", 0, 0)
local runsTabBtn = MakeSubTabBtn("Runs", "runs")
runsTabBtn:SetPoint("LEFT", lootTabBtn, "RIGHT", 6, 0)

local scroll = CreateFrame("ScrollFrame", "SpoilbookScroll", frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 16, -84)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(1, 1)
scroll:SetScrollChild(content)

local sideHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")

local sidePane = CreateFrame("ScrollFrame", "SpoilbookSidePane", frame, "UIPanelScrollFrameTemplate")
local sideContent = CreateFrame("Frame", nil, sidePane)
sideContent:SetSize(1, 1)
sidePane:SetScrollChild(sideContent)
sidePane:Hide()
sideHeader:Hide()

local sideDivider = frame:CreateTexture(nil, "ARTWORK")
sideDivider:SetWidth(1)
sideDivider:SetColorTexture(0, 0, 0, 0.5)
sideDivider:Hide()

local function SetupLayout()
	scroll:ClearAllPoints()
	scroll:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 16, -56)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", SPLIT_X - 10, 14)

	sideHeader:ClearAllPoints()
	sideHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", SPLIT_X + 10, -72 - 24)
	sideHeader:Show()

	placeSubBar:ClearAllPoints()
	placeSubBar:SetPoint("TOPLEFT", frame, "TOPLEFT", SPLIT_X + 10, -(72 + 56))

	sidePane:ClearAllPoints()
	sidePane:SetPoint("TOPLEFT", frame, "TOPLEFT", SPLIT_X + 10, -(72 + 84))
	sidePane:SetPoint("BOTTOMRIGHT", -30, 14)
	sidePane:Show()

	sideDivider:ClearAllPoints()
	sideDivider:SetPoint("TOP", frame, "TOPLEFT", SPLIT_X, -72)
	sideDivider:SetPoint("BOTTOM", frame, "BOTTOMLEFT", SPLIT_X, 14)
	sideDivider:Show()
end

-- ===== settings panel (real widgets, not list rows) =====

local settingsPanel = CreateFrame("Frame", nil, frame)
settingsPanel:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 16, -56)
settingsPanel:SetPoint("BOTTOMRIGHT", -16, 14)
settingsPanel:Hide()

local qualityLabel = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
qualityLabel:SetPoint("TOPLEFT", 0, 0)
qualityLabel:SetText("Minimum quality recorded")

local qualityButtons = {}
for i, opt in ipairs(QUALITY_OPTIONS) do
	local b = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
	b:SetSize(90, 22)
	b:SetPoint("TOPLEFT", (i - 1) * 96, -22)
	b:SetText(opt.label)
	b:SetScript("OnClick", function()
		S:SetMinQuality(opt.q)
	end)
	qualityButtons[opt.q] = b
end

local function MakeToggle(key, label, anchorY)
	local cb = CreateFrame("CheckButton", nil, settingsPanel, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", 2, anchorY)
	local fs = cb:GetFontString()
	if fs then
		fs:SetText(label)
	else
		local text = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
		text:SetText(label)
	end
	cb:SetScript("OnClick", function(self)
		S:SetToggle(key, self:GetChecked() and true or false)
	end)
	return cb
end

local toggleChecks = {
	trackDungeons = MakeToggle("trackDungeons", "Track dungeons", -64),
	trackRaids = MakeToggle("trackRaids", "Track raids", -94),
	announceWishlist = MakeToggle("announceWishlist", "Wishlist alerts", -124),
	minimap = MakeToggle("minimap", "Minimap button", -154),
}

local resetDivider = settingsPanel:CreateTexture(nil, "ARTWORK")
resetDivider:SetPoint("TOPLEFT", 0, -190)
resetDivider:SetPoint("TOPRIGHT", 0, -190)
resetDivider:SetHeight(1)
resetDivider:SetColorTexture(0, 0, 0, 0.5)

local resetBtn = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
resetBtn:SetSize(170, 22)
resetBtn:SetPoint("TOPLEFT", 0, -202)
resetBtn:SetText("Reset all Spoilbook data")
resetBtn:SetScript("OnClick", function()
	StaticPopup_Show("SPOILBOOK_RESET_CONFIRM")
end)
local resetFs = resetBtn:GetFontString()
if resetFs then
	resetFs:SetTextColor(0.91, 0.54, 0.48)
end

StaticPopupDialogs["SPOILBOOK_RESET_CONFIRM"] = {
	text = "Delete all Spoilbook instances, sessions and your wishlist?",
	button1 = "Delete",
	button2 = "Cancel",
	OnAccept = function() S:ResetData() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

StaticPopupDialogs["SPOILBOOK_DELETE_RUN_CONFIRM"] = {
	text = "Delete this run and its recorded drops?",
	button1 = "Delete",
	button2 = "Cancel",
	OnAccept = function(_, sessionId)
		S:DeleteSession(sessionId)
		ui.selSession = nil
		Refresh()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function RefreshSettingsPanel()
	for q, b in pairs(qualityButtons) do
		local on = SpoilbookDB.settings.minQuality == q
		b:SetEnabled(not on)
	end
	for key, cb in pairs(toggleChecks) do
		cb:SetChecked(SpoilbookDB.settings[key] and true or false)
	end
end

-- ===== generic row-list renderer (two-line rows with a real highlight texture) =====
-- one pool per container, not per logical list — a pool only hides its own
-- leftover rows, so reusing separate pools in the same parent left stale
-- rows from the previous view visible underneath the new ones.
local contentPool, sidePool = {}, {}

local ROW_HEIGHT = 34
local HEADER_HEIGHT = 40

local function RenderRows(parent, pool, items)
	pool.rows = pool.rows or {}
	local y = 0
	for i, item in ipairs(items) do
		local row = pool.rows[i]
		if not row then
			row = CreateFrame("Button", nil, parent)
			row:SetHighlightTexture("Interface/Buttons/UI-Listbox-Highlight2", "ADD")

			local sel = row:CreateTexture(nil, "BACKGROUND")
			sel:SetAllPoints()
			sel:SetColorTexture(0.6, 0.5, 0.2, 0.22)
			row.sel = sel

			local divider = row:CreateTexture(nil, "ARTWORK")
			divider:SetPoint("TOPLEFT", 4, 0)
			divider:SetPoint("TOPRIGHT", -4, 0)
			divider:SetHeight(1)
			divider:SetColorTexture(1, 1, 1, 0.08)
			row.divider = divider

			local icon = row:CreateTexture(nil, "ARTWORK")
			icon:SetSize(28, 28)
			icon:SetPoint("LEFT", 4, 0)
			icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the default item-icon border
			row.icon = icon

			local titleFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			titleFs:SetPoint("TOPLEFT", 38, -4)
			titleFs:SetPoint("RIGHT", -34, 0)
			titleFs:SetJustifyH("LEFT")
			titleFs:SetWordWrap(false)
			row.titleFs = titleFs

			local subFs = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			subFs:SetPoint("TOPLEFT", titleFs, "BOTTOMLEFT", 0, -2)
			subFs:SetPoint("RIGHT", -34, 0)
			subFs:SetJustifyH("LEFT")
			row.subFs = subFs

			local rightFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			rightFs:SetPoint("TOPRIGHT", -34, -4)
			rightFs:SetJustifyH("RIGHT")
			row.rightFs = rightFs

			local starBtn = CreateFrame("Button", nil, row)
			starBtn:SetSize(36, 36)
			starBtn:SetPoint("RIGHT", -2, 0)
			local starFs = starBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			starFs:SetAllPoints()
			starFs:SetJustifyH("CENTER")
			local fontPath = starFs:GetFont()
			starFs:SetFont(fontPath, 28, "OUTLINE")
			starBtn.fs = starFs
			starBtn:SetScript("OnEnter", Safe(function(self)
				GameTooltip:SetOwner(self, "ANCHOR_LEFT")
				GameTooltip:SetText(self.wished and "Remove from wishlist" or "Add to wishlist")
				GameTooltip:Show()
			end))
			starBtn:SetScript("OnLeave", Safe(function()
				GameTooltip:Hide()
			end))
			row.starBtn = starBtn

			pool.rows[i] = row
		end
		local h = item.header and HEADER_HEIGHT or ROW_HEIGHT
		row:SetParent(parent)
		row:SetHeight(h)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -y)
		row:SetPoint("TOPRIGHT", 0, -y)
		row.titleFs:ClearAllPoints()
		if item.header then
			row.titleFs:SetFontObject("GameFontNormal")
			row.titleFs:SetPoint("TOPLEFT", 6, -14)
		else
			row.titleFs:SetFontObject("GameFontHighlight")
			row.titleFs:SetPoint("TOPLEFT", 38, -4)
		end
		row.titleFs:SetPoint("RIGHT", -34, 0)
		row.titleFs:SetText(item.title or "")
		row.subFs:SetText(item.sub or "")
		row.subFs:SetShown(item.sub ~= nil and item.sub ~= "")
		row.rightFs:SetText(item.right or "")
		row.sel:SetShown(not not item.highlighted)
		row.divider:SetShown(not not item.header and i > 1)
		row.icon:SetShown(item.icon ~= nil)
		if item.icon then
			row.icon:SetTexture(item.icon)
		end
		row:SetScript("OnClick", Safe(item.onClick))
		row:EnableMouse(item.onClick ~= nil or item.itemLink ~= nil)
		if item.itemLink then
			row:SetScript("OnEnter", Safe(function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetHyperlink(item.itemLink)
				GameTooltip:Show()
			end))
			row:SetScript("OnLeave", Safe(function()
				GameTooltip:Hide()
			end))
		else
			row:SetScript("OnEnter", nil)
			row:SetScript("OnLeave", nil)
		end
		if item.star ~= nil then
			row.starBtn:Show()
			row.starBtn.wished = item.star
			row.starBtn.fs:SetText(item.star and ColorText("e2c27a", "*") or ColorText("5d5040", "*"))
			row.starBtn:SetScript("OnClick", Safe(item.onStar))
		else
			row.starBtn:Hide()
		end
		row:Show()
		y = y + h
	end
	for i = #items + 1, #pool.rows do
		pool.rows[i]:Hide()
	end
	parent:SetHeight(math.max(y, 1))
	parent:SetWidth(parent:GetParent():GetWidth())
end

-- A collapsible section header row (boss name, place name, etc.) — taller,
-- un-indented, and divided from the group above it so it reads as a section
-- title. Click to fold/unfold the group beneath it. expandTable is keyed by
-- `place` (or whatever grouping key is passed), so each group's open/closed
-- state is tracked independently.
local function AccordionHeader(label, count, noun, expandTable, place)
	local expanded = (expandTable[place] ~= false)
	return {
		title = (expanded and "[-] " or "[+] ") .. label,
		right = string.format("%d %s%s", count, noun, count == 1 and "" or "s"),
		header = true,
		onClick = function()
			expandTable[place] = not expanded
			Refresh()
		end,
	}, expanded
end

-- ===== list builders (format Core.lua data into row items) =====

local function InstanceRows(onSelect)
	local list = S:GetInstanceSummaries()
	local rows = {}
	for _, inst in ipairs(list) do
		local liveTag = inst.live and ColorText("7be07b", "LIVE  ") or ""
		table.insert(rows, {
			title = inst.name,
			sub = string.format("%d run%s", inst.runs, inst.runs == 1 and "" or "s"),
			right = liveTag .. string.format("%d/%d looted", inst.looted, inst.seen),
			highlighted = (inst.name == ui.selInstance),
			onClick = function() onSelect(inst.name) end,
		})
	end
	return rows
end

local function BossItemRows(instanceName)
	local groups = S:GetBossGroups(instanceName)
	local rows = {}
	for _, g in ipairs(groups) do
		local key = instanceName .. "\0" .. g.name -- same boss name can recur across different places
		local header, expanded = AccordionHeader(g.name, #g.items, "item", ui.lootExpanded, key)
		table.insert(rows, header)
		if expanded then
			for _, it in ipairs(g.items) do
				local hex = Qc(it.quality)
				local sub = "Seen " .. it.seen .. "x"
				if it.looted > 0 then
					sub = sub .. "  -  " .. ColorText("7be07b", "looted " .. it.looted .. "x")
				end
				table.insert(rows, {
					title = ColorText(hex, it.itemName),
					sub = sub,
					icon = S:ItemIcon(it.itemLink),
					itemLink = it.itemLink,
					star = S:IsWishlisted(it.itemID),
					onStar = function() S:ToggleWishlist(it.itemID) end,
					onClick = function()
						if it.itemLink then
							print(it.itemLink)
						end
					end,
				})
			end
		end
	end
	return rows
end

-- Runs for one specific place (not a global mixed-together list) — the
-- instance name is already shown in the header above this list, so each row
-- only needs to tell runs apart from each other.
local function ScopedSessionRows(instanceName, onSelect)
	local rows = {}
	for _, sess in ipairs(S:GetSessionsForInstance(instanceName)) do
		local looted = 0
		for _, d in ipairs(sess.drops) do
			if d.looted then looted = looted + 1 end
		end
		local when = date("%b %d, %H:%M", sess.startTime)
		local liveTag = sess.live and ColorText("7be07b", "LIVE  ") or ""
		table.insert(rows, {
			title = when,
			right = liveTag .. string.format("%d/%d looted", looted, #sess.drops),
			highlighted = (sess.id == ui.selSession),
			onClick = function() onSelect(sess.id) end,
		})
	end
	if #rows == 0 then
		table.insert(rows, { title = ColorText("7d715c", "No runs yet.") })
	end
	return rows
end

local function WishlistRows()
	local order, byPlace = {}, {}
	for _, w in ipairs(S:GetWishlistView()) do
		local place = w.instanceName or "Unknown"
		if not byPlace[place] then
			byPlace[place] = {}
			table.insert(order, place)
		end
		table.insert(byPlace[place], w)
	end
	local rows = {}
	for _, place in ipairs(order) do
		local items = byPlace[place]
		local header, expanded = AccordionHeader(place, #items, "item", ui.wishExpanded, place)
		table.insert(rows, header)
		if expanded then
			for _, w in ipairs(items) do
				local hex = Qc(w.quality)
				local status
				if w.looted > 0 then
					status = ColorText("7be07b", "Owned")
				elseif w.seen > 0 then
					status = ColorText("e2c27a", "Seen " .. w.seen .. "x, not looted")
				else
					status = ColorText("7d715c", "Not seen yet")
				end
				table.insert(rows, {
					title = ColorText(hex, w.itemName or "?"),
					sub = w.source,
					right = status,
					icon = S:ItemIcon(w.itemLink),
					itemLink = w.itemLink,
					star = true,
					onStar = function() S:ToggleWishlist(w.itemID) end,
				})
			end
		end
	end
	if #rows == 0 then
		table.insert(rows, { title = ColorText("7d715c", "Star an item from a place's Loot Table to add it here.") })
	end
	return rows
end

-- Global activity feed: every run across every place, newest first.
local function AllSessionRows(onSelect)
	local order, byPlace = {}, {}
	for _, sess in ipairs(SpoilbookDB.sessions) do
		if not byPlace[sess.instanceName] then
			byPlace[sess.instanceName] = {}
			table.insert(order, sess.instanceName)
		end
		table.insert(byPlace[sess.instanceName], sess)
	end
	local rows = {}
	for _, place in ipairs(order) do
		local sessions = byPlace[place]
		local header, expanded = AccordionHeader(place, #sessions, "run", ui.runsExpanded, place)
		table.insert(rows, header)
		if expanded then
			for _, sess in ipairs(sessions) do
				local looted = 0
				for _, d in ipairs(sess.drops) do
					if d.looted then looted = looted + 1 end
				end
				local when = date("%b %d, %H:%M", sess.startTime)
				local liveTag = sess.live and ColorText("7be07b", "LIVE  ") or ""
				table.insert(rows, {
					title = when,
					right = liveTag .. string.format("%d/%d looted", looted, #sess.drops),
					highlighted = (sess.id == ui.selSession),
					onClick = function() onSelect(sess.id) end,
				})
			end
		end
	end
	if #rows == 0 then
		table.insert(rows, { title = ColorText("7d715c", "No runs yet.") })
	end
	return rows
end

local function SessionDetailRows(sessionId)
	local sess = S:GetSession(sessionId)
	if not sess then
		return {}
	end
	local byBoss, order = {}, {}
	for _, d in ipairs(sess.drops) do
		if not byBoss[d.boss] then
			byBoss[d.boss] = {}
			table.insert(order, d.boss)
		end
		table.insert(byBoss[d.boss], d)
	end
	local rows = {}
	if #order == 0 then
		table.insert(rows, { title = ColorText("7d715c", "Waiting for the first drop...") })
	end
	for _, boss in ipairs(order) do
		local key = sessionId .. "\0" .. boss
		local header, expanded = AccordionHeader(boss, #byBoss[boss], "drop", ui.dropsExpanded, key)
		table.insert(rows, header)
		if expanded then
			for _, d in ipairs(byBoss[boss]) do
				local hex = Qc(d.quality)
				local status
				if d.looted then
					status = ColorText("7be07b", "Looted by you")
				elseif d.winner then
					status = ColorText("8fb0d9", "Won by " .. d.winner)
				else
					status = ColorText("7d715c", "Not looted yet")
				end
				table.insert(rows, { title = ColorText(hex, d.itemName), right = status, icon = S:ItemIcon(d.itemLink), itemLink = d.itemLink })
			end
		end
	end
	if not sess.live then
		table.insert(rows, {
			title = ColorText("e88a7a", "Delete this run"),
			onClick = function()
				StaticPopup_Show("SPOILBOOK_DELETE_RUN_CONFIRM", nil, nil, sessionId)
			end,
		})
	end
	return rows
end

-- ===== render =====

local RefreshImpl

function Refresh()
	-- an error partway through would otherwise abort silently: e.g. the header
	-- text for a pane gets set, then the row list for it never renders, with no
	-- visible sign anything went wrong.
	local ok, err = pcall(RefreshImpl)
	if not ok then
		print("|cffff5555Spoilbook UI error|r: " .. tostring(err))
	end
end

function RefreshImpl()
	for key, b in pairs(navButtons) do
		local on = (ui.tab == key)
		b.bg:SetShown(on)
		b.accent:SetShown(on)
		b.label:SetTextColor(on and 0.89 or 0.63, on and 0.76 or 0.58, on and 0.48 or 0.47)
	end

	settingsPanel:Hide()
	scroll:Show()

	if ui.tab == "set" then
		scroll:Hide()
		sidePane:Hide()
		sideHeader:Hide()
		sideDivider:Hide()
		placeSubBar:Hide()
		contentHeader:Show()
		contentHeader:SetText("Settings")
		settingsPanel:Show()
		RefreshSettingsPanel()
		return
	end

	if ui.tab == "wish" then
		sidePane:Hide()
		sideHeader:Hide()
		sideDivider:Hide()
		placeSubBar:Hide()
		contentHeader:Show()
		contentHeader:SetText("Wishlist")
		RenderRows(content, contentPool, WishlistRows())
		return
	end

	contentHeader:Show()
	sidePane:Show()
	sideHeader:Show()
	sideDivider:Show()
	if ui.tab == "inst" then
		contentHeader:SetText("Places")
		local rows = InstanceRows(function(name)
			ui.selInstance = name
			ui.placeSub = "loot"
			ui.selSession = nil
			Refresh()
		end)
		RenderRows(content, contentPool, rows)

		if not ui.selInstance then
			sideHeader:SetText("Select a place")
			placeSubBar:Hide()
			RenderRows(sideContent, sidePool, {})
		else
			placeSubBar:Show()
			lootTabBtn:SetEnabled(ui.placeSub ~= "loot")
			runsTabBtn:SetEnabled(ui.placeSub ~= "runs")
			if ui.selSession then
				local sess = S:GetSession(ui.selSession)
				sideHeader:SetText(sess and sess.instanceName or "Run")
				RenderRows(sideContent, sidePool, SessionDetailRows(ui.selSession))
			elseif ui.placeSub == "runs" then
				sideHeader:SetText(ui.selInstance .. " — Runs")
				RenderRows(sideContent, sidePool, ScopedSessionRows(ui.selInstance, function(id)
					ui.selSession = id
					Refresh()
				end))
			else
				sideHeader:SetText(ui.selInstance .. " — Loot Table")
				RenderRows(sideContent, sidePool, BossItemRows(ui.selInstance))
			end
		end
	else -- runs
		placeSubBar:Hide()
		contentHeader:SetText("Run History")
		local rows = AllSessionRows(function(id)
			ui.selSession = id
			Refresh()
		end)
		RenderRows(content, contentPool, rows)
		local sess = ui.selSession and S:GetSession(ui.selSession)
		sideHeader:SetText(sess and sess.instanceName or "Select a run")
		RenderRows(sideContent, sidePool, sess and SessionDetailRows(ui.selSession) or {})
	end
end

SetupLayout()

S:OnUpdate(function()
	if frame:IsShown() then
		Refresh()
	end
end)

S:OnWishlistAlert(function(itemLink, looted)
	alertText:SetText(string.format("* %s %s", itemLink or "?", looted and "- you looted it." or "- it dropped."))
	alertBar:Show()
	C_Timer.After(6, function() alertBar:Hide() end)
end)

frame:SetScript("OnShow", Refresh)

-- ===== slash command =====

SLASH_SPOILBOOK1 = "/spoilbook"
SlashCmdList["SPOILBOOK"] = function(msg)
	msg = (msg or ""):lower():trim()
	if msg == "test" then
		S:DebugSeedTestData()
		ui.tab = "inst"
		ui.placeSub = "loot"
		ui.selInstance = "Spoilbook Test Dungeon"
		frame:Show()
		Refresh()
		return
	end
	if frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
	end
end

-- ===== minimap button =====

local minimapBtn = CreateFrame("Button", "SpoilbookMinimapButton", Minimap)
minimapBtn:SetSize(31, 31)
minimapBtn:SetFrameStrata("MEDIUM")
minimapBtn:SetFrameLevel(8)
minimapBtn:RegisterForClicks("LeftButtonUp")
minimapBtn:RegisterForDrag("LeftButton")

local mbIcon = minimapBtn:CreateTexture(nil, "BACKGROUND")
mbIcon:SetSize(20, 20)
mbIcon:SetPoint("CENTER", 0, 1)
mbIcon:SetTexture("Interface/Icons/INV_Misc_Book_09")

local mbBorder = minimapBtn:CreateTexture(nil, "OVERLAY")
mbBorder:SetSize(54, 54)
mbBorder:SetPoint("TOPLEFT")
mbBorder:SetTexture("Interface/Minimap/MiniMap-TrackingBorder")

local MINIMAP_RADIUS = 80

local function UpdateMinimapPosition()
	local angle = math.rad(SpoilbookDB.settings.minimapAngle or 215)
	local x = math.cos(angle) * MINIMAP_RADIUS
	local y = math.sin(angle) * MINIMAP_RADIUS
	minimapBtn:ClearAllPoints()
	minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

minimapBtn:SetScript("OnDragStart", function(self)
	self:SetScript("OnUpdate", function()
		local mx, my = Minimap:GetCenter()
		local scale = Minimap:GetEffectiveScale()
		local px, py = GetCursorPosition()
		px, py = px / scale, py / scale
		SpoilbookDB.settings.minimapAngle = math.deg(math.atan2(py - my, px - mx)) % 360
		UpdateMinimapPosition()
	end)
end)
minimapBtn:SetScript("OnDragStop", function(self)
	self:SetScript("OnUpdate", nil)
end)

minimapBtn:SetScript("OnClick", function()
	if frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
	end
end)

minimapBtn:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText("Spoilbook")
	GameTooltip:AddLine("Click to open/close the loot tracker.", 1, 1, 1)
	GameTooltip:Show()
end)
minimapBtn:SetScript("OnLeave", function()
	GameTooltip:Hide()
end)

local function SyncMinimapButton()
	if SpoilbookDB and SpoilbookDB.settings then
		minimapBtn:SetShown(SpoilbookDB.settings.minimap ~= false)
		UpdateMinimapPosition()
	end
end

S:OnUpdate(SyncMinimapButton)

local minimapInit = CreateFrame("Frame")
minimapInit:RegisterEvent("PLAYER_LOGIN")
minimapInit:SetScript("OnEvent", SyncMinimapButton)
