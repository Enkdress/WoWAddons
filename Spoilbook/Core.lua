-- Spoilbook: records Uncommon+ drops per dungeon/raid visit and whether you looted them.

local ADDON_NAME = "Spoilbook"
Spoilbook = Spoilbook or {}
local S = Spoilbook

S.defaults = {
	settings = {
		minQuality = 2, -- 0 Poor,1 Common,2 Uncommon,3 Rare,4 Epic,5 Legendary
		trackDungeons = true,
		trackRaids = true,
		announceWishlist = true,
		minimap = true,
		minimapAngle = 215,
	},
}

S.liveSessionId = nil
S.wasInInstance = false
S.lastBossName = nil
S.lastBossTime = nil
S.pendingEndTimer = nil
S.lastSeenCount = {}
S.listeners = {}
S.alertListeners = {}
S.selfLootPatterns = {}
S.otherLootPatterns = {}

-- ===== pub/sub so the UI can refresh without polling =====

function S:OnUpdate(fn)
	table.insert(S.listeners, fn)
end

function S:FireUpdate()
	for _, fn in ipairs(S.listeners) do
		pcall(fn)
	end
end

function S:OnWishlistAlert(fn)
	table.insert(S.alertListeners, fn)
end

function S:FireWishlistAlert(itemLink, looted)
	for _, fn in ipairs(S.alertListeners) do
		pcall(fn, itemLink, looted)
	end
end

-- ===== setup =====

function S:Init()
	SpoilbookDB = SpoilbookDB or {}
	SpoilbookDB.settings = SpoilbookDB.settings or {}
	for k, v in pairs(S.defaults.settings) do
		if SpoilbookDB.settings[k] == nil then
			SpoilbookDB.settings[k] = v
		end
	end
	SpoilbookDB.sessions = SpoilbookDB.sessions or {}
	SpoilbookDB.wishlist = SpoilbookDB.wishlist or {}
	S.selfLootPatterns = S:BuildPatterns({ LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF, LOOT_ITEM_PUSHED_SELF_MULTIPLE })
	S.otherLootPatterns = S:BuildPatterns({ LOOT_ITEM, LOOT_ITEM_MULTIPLE, LOOT_ITEM_PUSHED, LOOT_ITEM_PUSHED_MULTIPLE })
end

-- Builds locale-safe match patterns from Blizzard's own loot chat format strings
-- (LOOT_ITEM_SELF etc.) instead of hardcoding English text. gsub replaces every
-- %s/%d placeholder, so a format with two placeholders (player name + item) comes
-- out as a two-capture pattern.
local function EscapeForPattern(fmt)
	local out = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
	out = out:gsub("%%%%s", "(.+)")
	out = out:gsub("%%%%d", "(%%d+)")
	return out
end

function S:BuildPatterns(sources)
	local patterns = {}
	for _, fmt in ipairs(sources) do
		if type(fmt) == "string" then
			local ok, pattern = pcall(EscapeForPattern, fmt)
			if ok and pattern then
				table.insert(patterns, pattern)
			end
		end
	end
	return patterns
end

-- Returns itemLink, winnerName (winnerName is nil when the message is our own
-- "You receive loot" line — caller treats that as the local player).
function S:ParseLootMessage(msg)
	for _, pattern in ipairs(S.selfLootPatterns) do
		local link = msg:match(pattern)
		if link then
			return link, nil
		end
	end
	for _, pattern in ipairs(S.otherLootPatterns) do
		local name, link = msg:match(pattern)
		if name and link then
			return link, name
		end
	end
	return nil, nil
end

function S:GetItemCount(itemID)
	if not itemID then
		return 0
	end
	if C_Item and C_Item.GetItemCount then
		return C_Item.GetItemCount(itemID, true)
	elseif GetItemCount then
		return GetItemCount(itemID, true)
	end
	return 0
end

-- GetItemInfo/GetItemInfoInstant's non-namespaced globals are deprecated (moved
-- to C_Item in 10.2.6) and this client appears to have already dropped the
-- fallback entirely, so always prefer C_Item and only use the global if it
-- still exists at all.
function S:ItemInfo(item)
	if C_Item and C_Item.GetItemInfo then
		return C_Item.GetItemInfo(item)
	elseif GetItemInfo then
		return GetItemInfo(item)
	end
	return nil
end

function S:ItemInfoInstant(item)
	if C_Item and C_Item.GetItemInfoInstant then
		return C_Item.GetItemInfoInstant(item)
	elseif GetItemInfoInstant then
		return GetItemInfoInstant(item)
	end
	return nil
end

-- A recent patch reportedly inserted an extra return value into GetItemInfo's
-- list, so reading "the 10th value" for the icon is no longer reliable.
-- C_Item.GetItemIconByID is a dedicated, unambiguous call for just the icon.
function S:ItemIcon(itemLink)
	if not itemLink then
		return nil
	end
	local itemID = S:ItemInfoInstant(itemLink)
	if itemID and C_Item and C_Item.GetItemIconByID then
		local icon = C_Item.GetItemIconByID(itemID)
		if icon then
			return icon
		end
	end
	if itemID and GetItemIcon then
		local icon = GetItemIcon(itemID)
		if icon then
			return icon
		end
	end
	-- last resort: positional read, kept only as a fallback of a fallback
	local info = { S:ItemInfo(itemLink) }
	return info[10]
end

-- ===== session lifecycle =====

function S:GetLiveSessionData()
	if not S.liveSessionId then
		return nil
	end
	for _, sess in ipairs(SpoilbookDB.sessions) do
		if sess.id == S.liveSessionId then
			return sess
		end
	end
	return nil
end

function S:FindLiveSessionByInstanceID(instanceID)
	for _, sess in ipairs(SpoilbookDB.sessions) do
		if sess.live and sess.instanceID == instanceID then
			return sess
		end
	end
	return nil
end

function S:StartSession(name, instanceType, instanceID)
	-- defensive: a session that never saw LEAVING_WORLD (disconnect, crash) stays "live"
	for _, sess in ipairs(SpoilbookDB.sessions) do
		if sess.live then
			sess.live = false
			sess.endTime = time()
		end
	end
	local id = "s" .. time() .. "-" .. math.random(1000, 9999)
	local session = {
		id = id,
		instanceName = name,
		instanceType = instanceType,
		instanceID = instanceID,
		startTime = time(),
		endTime = nil,
		live = true,
		drops = {},
	}
	table.insert(SpoilbookDB.sessions, 1, session)
	S.liveSessionId = id
	S:FireUpdate()
end

function S:EndLiveSession()
	local live = S:GetLiveSessionData()
	if live then
		if #live.drops == 0 then
			-- a bare in-and-out (wrong instance, corridor peek, disconnect) isn't a run worth keeping
			for i, sess in ipairs(SpoilbookDB.sessions) do
				if sess.id == live.id then
					table.remove(SpoilbookDB.sessions, i)
					break
				end
			end
		else
			live.live = false
			live.endTime = time()
		end
	end
	S.liveSessionId = nil
	S:FireUpdate()
end

function S:DeleteSession(id)
	for i, sess in ipairs(SpoilbookDB.sessions) do
		if sess.id == id then
			table.remove(SpoilbookDB.sessions, i)
			break
		end
	end
	if S.liveSessionId == id then
		S.liveSessionId = nil
	end
	S:FireUpdate()
end

-- How long a run stays "live" after you leave the instance before it's actually
-- finalized. Releasing to a graveyard on death often teleports you outside the
-- instance, which would otherwise look identical to deliberately leaving; this
-- window gives you time to corpse-run back in without losing/ending the run.
local LEAVE_GRACE_PERIOD = 120

function S:CancelPendingEnd()
	if S.pendingEndTimer then
		S.pendingEndTimer:Cancel()
		S.pendingEndTimer = nil
	end
end

function S:ScheduleEndLiveSession()
	S:CancelPendingEnd()
	local sessionId = S.liveSessionId
	if not sessionId then
		return
	end
	S.pendingEndTimer = C_Timer.NewTimer(LEAVE_GRACE_PERIOD, function()
		S.pendingEndTimer = nil
		if S.liveSessionId == sessionId then
			S:EndLiveSession()
		end
	end)
end

function S:CheckInstanceState()
	local inInstance, instanceType = IsInInstance()
	local trackable = inInstance and ((instanceType == "party") or (instanceType == "raid"))
	if trackable then
		local allowed = (instanceType == "party" and SpoilbookDB.settings.trackDungeons)
			or (instanceType == "raid" and SpoilbookDB.settings.trackRaids)
		if not allowed then
			S.wasInInstance = true
			S.liveSessionId = nil
			return
		end
		local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
		local existing = S:FindLiveSessionByInstanceID(instanceID)
		if existing then
			S.liveSessionId = existing.id
			S:CancelPendingEnd()
		elseif not S.wasInInstance or not S:GetLiveSessionData() then
			S:StartSession(name, instanceType, instanceID)
		end
		S.wasInInstance = true
	else
		if S.wasInInstance then
			S:ScheduleEndLiveSession()
		end
		S.wasInInstance = false
	end
end

-- ===== loot capture =====

function S:OnEncounterEnd(encounterID, encounterName, difficultyID, groupSize, success)
	if success == 1 then
		S.lastBossName = encounterName
		S.lastBossTime = GetTime()
	end
end

local BOSS_ATTRIBUTION_WINDOW = 20 -- seconds after an encounter kill to credit drops to that boss

function S:CurrentBossLabel()
	if S.lastBossName and (GetTime() - (S.lastBossTime or 0)) < BOSS_ATTRIBUTION_WINDOW then
		return S.lastBossName
	end
	return "Trash & Chests"
end

-- Claims (boss, itemID) pairs per live session, in memory only (never saved).
-- This is the single source of truth against double-recording: LOOT_OPENED can
-- fire more than once for the same still-open window, a groupmate-opened
-- corpse additionally fires START_LOOT_ROLL for an item our own slot scan may
-- already have seen, and crucially — a claim is taken *synchronously*, before
-- TryRecordLootSlot's async "item not cached yet" retry branch, so a second
-- scan arriving in that same ~0.3s gap can't race ahead and queue its own
-- duplicate retry for an item that hasn't actually been added to the drop
-- list yet. A claim is released once the drop resolves (looted/won by
-- someone), so a genuinely new later drop of the same item+boss isn't blocked
-- forever.
S.claimedDrops = {}

local function ClaimKey(sessionId, boss, itemID)
	return sessionId .. "\0" .. boss .. "\0" .. itemID
end

function S:ReleaseClaim(sessionId, boss, itemID)
	S.claimedDrops[ClaimKey(sessionId, boss, itemID)] = nil
end

-- GetLootSlotInfo()'s tail fields (currencyID/quality/locked/...) have shifted
-- position across WoW client eras, so trusting them by position is fragile.
-- GetItemInfo() reads quality straight off the item link instead.
function S:TryRecordLootSlot(live, boss, itemLink)
	local itemID = S:ItemInfoInstant(itemLink)
	if not itemID then
		return
	end
	local key = ClaimKey(live.id, boss, itemID)
	if S.claimedDrops[key] then
		return
	end
	S.claimedDrops[key] = true

	local itemName, _, quality = S:ItemInfo(itemLink)
	if quality then
		if quality >= SpoilbookDB.settings.minQuality then
			S:RecordDrop(live, boss, itemLink, itemID, itemName, quality, 1)
		else
			S.claimedDrops[key] = nil -- below threshold, never actually recorded — don't block it forever
		end
		return
	end
	-- item not cached client-side yet; retry once Blizzard has it
	C_Timer.After(0.3, function()
		local n, _, q = S:ItemInfo(itemLink)
		if q and q >= SpoilbookDB.settings.minQuality then
			local liveNow = S:GetLiveSessionData()
			if liveNow then
				S:RecordDrop(liveNow, boss, itemLink, itemID, n, q, 1)
				return
			end
		end
		S.claimedDrops[key] = nil
	end)
end

function S:OnLootOpened()
	local live = S:GetLiveSessionData()
	if not live then
		return
	end
	local boss = S:CurrentBossLabel()
	local numItems = GetNumLootItems() or 0
	for slot = 1, numItems do
		-- GetLootSlotType()/LOOT_SLOT_ITEM are retail-era API that may not exist
		-- on a classic-rooted client; a real item link always contains "|Hitem:",
		-- which money/currency slots never produce, so that's a safer filter.
		local itemLink = GetLootSlotLink(slot)
		if itemLink and itemLink:find("|Hitem:", 1, true) then
			S:TryRecordLootSlot(live, boss, itemLink)
		end
	end
end

-- If a groupmate — not you — physically opens the corpse, LOOT_OPENED never
-- fires on your client at all; you only get the Need/Greed roll popup, which
-- is this separate event. Without this hook, items you only ever roll on
-- (never personally loot the corpse for) would never get recorded.
function S:OnStartLootRoll(rollID)
	local live = S:GetLiveSessionData()
	if not live or not GetLootRollItemLink then
		return
	end
	local itemLink = GetLootRollItemLink(rollID)
	if not itemLink or not itemLink:find("|Hitem:", 1, true) then
		return
	end
	S:TryRecordLootSlot(live, S:CurrentBossLabel(), itemLink)
end

function S:RecordDrop(session, boss, itemLink, itemID, itemName, quality, count)
	table.insert(session.drops, {
		boss = boss,
		itemID = itemID,
		itemLink = itemLink,
		itemName = itemName,
		quality = quality,
		looted = false,
		winner = nil, -- set once someone (you or another player) actually receives it
		count = count or 1,
		timestamp = time(),
	})
	-- baseline bag count "as of right now" (pre-loot) so ReconcileBagCounts can
	-- later tell whether this specific drop ever landed in your bags, no matter
	-- how long a Need/Greed roll takes to resolve.
	if itemID then
		S.lastSeenCount[itemID] = S:GetItemCount(itemID)
	end
	print("|cff1eff00Spoilbook|r recorded: " .. (itemLink or itemName or "?") .. "  (" .. boss .. ")")
	S:FireUpdate()
	if SpoilbookDB.settings.announceWishlist and itemID and SpoilbookDB.wishlist[itemID] then
		S:FireWishlistAlert(itemLink, false)
	end
end

-- winnerName nil means "you" (that's what a self-loot chat line / bag-count
-- increase tells us); otherwise it's the name parsed from the group-visible
-- "<Player> receives loot: <item>" chat line.
function S:MarkLooted(itemID, winnerName)
	local live = S:GetLiveSessionData()
	if not live or not itemID then
		return
	end
	local isMe = not winnerName
	for i = #live.drops, 1, -1 do
		local d = live.drops[i]
		if d.itemID == itemID and not d.winner then
			d.winner = winnerName or UnitName("player")
			if isMe then
				d.looted = true
			end
			S:ReleaseClaim(live.id, d.boss, itemID)
			print("|cff1eff00Spoilbook|r resolved: " .. (d.itemLink or d.itemName or "?") .. " -> " .. d.winner)
			S:FireUpdate()
			if SpoilbookDB.settings.announceWishlist and SpoilbookDB.wishlist[itemID] then
				S:FireWishlistAlert(d.itemLink, isMe)
			end
			return
		end
	end
end

function S:OnChatMsgLoot(msg)
	local itemLink, winnerName = S:ParseLootMessage(msg)
	if not itemLink then
		return
	end
	local itemID = S:ItemInfoInstant(itemLink)
	S:MarkLooted(itemID, winnerName)
end

-- Fallback confirmation for yourself specifically, run on every bag change
-- rather than a single timed snapshot: a Need/Greed roll can resolve long
-- after the loot window closed (or the chat line simply isn't one we
-- recognized), so this keeps checking until each drop resolves.
function S:ReconcileBagCounts()
	local live = S:GetLiveSessionData()
	if not live then
		return
	end
	local byItem = {}
	for _, d in ipairs(live.drops) do
		if not d.winner and d.itemID then
			byItem[d.itemID] = byItem[d.itemID] or {}
			table.insert(byItem[d.itemID], d)
		end
	end
	for itemID, drops in pairs(byItem) do
		local current = S:GetItemCount(itemID)
		local baseline = S.lastSeenCount[itemID] or current
		if current > baseline then
			local gained = current - baseline
			local me = UnitName("player")
			for i = 1, math.min(gained, #drops) do
				drops[i].looted = true
				drops[i].winner = me
				S:ReleaseClaim(live.id, drops[i].boss, itemID)
				print("|cff1eff00Spoilbook|r bag-confirmed: " .. (drops[i].itemLink or drops[i].itemName or "?"))
				if SpoilbookDB.settings.announceWishlist and SpoilbookDB.wishlist[itemID] then
					S:FireWishlistAlert(drops[i].itemLink, true)
				end
			end
			S:FireUpdate()
		end
		S.lastSeenCount[itemID] = current
	end
end

-- ===== wishlist / settings =====

function S:IsWishlisted(itemID)
	return itemID and SpoilbookDB.wishlist[itemID] or false
end

function S:ToggleWishlist(itemID)
	if not itemID then
		return
	end
	if SpoilbookDB.wishlist[itemID] then
		SpoilbookDB.wishlist[itemID] = nil
	else
		SpoilbookDB.wishlist[itemID] = true
	end
	S:FireUpdate()
end

function S:SetMinQuality(q)
	SpoilbookDB.settings.minQuality = q
	S:FireUpdate()
end

function S:SetToggle(key, val)
	SpoilbookDB.settings[key] = val
	S:FireUpdate()
end

function S:ResetData()
	SpoilbookDB.sessions = {}
	SpoilbookDB.wishlist = {}
	S.liveSessionId = nil
	S:FireUpdate()
end

-- Seeds a fake live run so the UI (lists, drill-down, wishlist, settings,
-- delete) can be exercised without actually entering a dungeon. Only the real
-- event hooks (instance detection, loot window reading, chat parsing) still
-- need an actual run to test. Triggered via "/spoilbook test".
function S:DebugSeedTestData()
	S:StartSession("Spoilbook Test Dungeon", "party", -math.random(100000, 999999))
	local live = S:GetLiveSessionData()
	if not live then
		return
	end
	local me = UnitName("player")
	local function fake(boss, name, quality, itemID, winner)
		local link = string.format("|cffffffff|Hitem:%d::::::::1:::::|h[%s]|h|r", itemID, name)
		S:RecordDrop(live, boss, link, itemID, name, quality, 1)
		local d = live.drops[#live.drops]
		d.winner = winner
		d.looted = (winner == me)
	end
	-- itemID 6948 (Hearthstone) is a real, stable item so the icon/tooltip
	-- lookup has genuine data to find — the display name/quality below is
	-- still ours, so the hover tooltip will show the real Hearthstone instead,
	-- which is expected: this is only for testing the icon/tooltip plumbing.
	fake("Test Boss Alpha", "Gleaming Test Sword", 3, 6948, me)
	fake("Test Boss Alpha", "Ring of Testing", 2, 6948, "Bobbert")
	fake("Test Boss Alpha", "Cloak of Debugging", 4, 6948, nil)
	fake("Trash & Chests", "Dusty Test Boots", 2, 6948, me)
	S:FireUpdate()
end

-- ===== read-only views for the UI =====

function S:GetInstanceSummaries()
	local order, map = {}, {}
	for _, sess in ipairs(SpoilbookDB.sessions) do
		local key = sess.instanceName
		if not map[key] then
			map[key] = { name = sess.instanceName, instanceType = sess.instanceType, runs = 0, seen = 0, looted = 0, live = false, lastDate = sess.startTime }
			table.insert(order, key)
		end
		local o = map[key]
		o.runs = o.runs + 1
		o.seen = o.seen + #sess.drops
		for _, d in ipairs(sess.drops) do
			if d.looted then
				o.looted = o.looted + 1
			end
		end
		if sess.live then
			o.live = true
		end
		if sess.startTime > o.lastDate then
			o.lastDate = sess.startTime
		end
	end
	local list = {}
	for _, key in ipairs(order) do
		table.insert(list, map[key])
	end
	table.sort(list, function(a, b) return a.lastDate > b.lastDate end)
	return list
end

function S:GetBossGroups(instanceName)
	local bosses, order = {}, {}
	for _, sess in ipairs(SpoilbookDB.sessions) do
		if sess.instanceName == instanceName then
			for _, d in ipairs(sess.drops) do
				if not bosses[d.boss] then
					bosses[d.boss] = {}
					table.insert(order, d.boss)
				end
				local b = bosses[d.boss]
				local key = d.itemID or d.itemName
				if not b[key] then
					b[key] = { itemID = d.itemID, itemLink = d.itemLink, itemName = d.itemName, quality = d.quality, seen = 0, looted = 0 }
				end
				b[key].seen = b[key].seen + 1
				if d.looted then
					b[key].looted = b[key].looted + 1
				end
			end
		end
	end
	local result = {}
	for _, bossName in ipairs(order) do
		local items = {}
		for _, item in pairs(bosses[bossName]) do
			table.insert(items, item)
		end
		table.sort(items, function(a, b) return a.itemName < b.itemName end)
		table.insert(result, { name = bossName, items = items })
	end
	return result
end

function S:GetSessionsForInstance(instanceName)
	local out = {}
	for _, sess in ipairs(SpoilbookDB.sessions) do
		if sess.instanceName == instanceName then
			table.insert(out, sess)
		end
	end
	return out
end

-- One row per wishlisted item, with lifetime seen/looted counts and where it
-- was last seen dropping — pulled from whichever recorded drop first told us
-- its name/quality/link, since wishlisting only ever happens from an
-- already-seen item row.
function S:GetWishlistView()
	local out = {}
	for itemID in pairs(SpoilbookDB.wishlist) do
		local entry = { itemID = itemID, seen = 0, looted = 0 }
		for _, sess in ipairs(SpoilbookDB.sessions) do
			for _, d in ipairs(sess.drops) do
				if d.itemID == itemID then
					entry.seen = entry.seen + 1
					if d.looted then
						entry.looted = entry.looted + 1
					end
					entry.itemLink = entry.itemLink or d.itemLink
					entry.itemName = entry.itemName or d.itemName
					entry.quality = entry.quality or d.quality
					entry.instanceName = entry.instanceName or sess.instanceName
					entry.source = entry.source or (d.boss .. " · " .. sess.instanceName)
				end
			end
		end
		table.insert(out, entry)
	end
	table.sort(out, function(a, b) return (a.itemName or "") < (b.itemName or "") end)
	return out
end

function S:GetSession(id)
	for _, sess in ipairs(SpoilbookDB.sessions) do
		if sess.id == id then
			return sess
		end
	end
	return nil
end

-- ===== event wiring =====

local frame = CreateFrame("Frame", "SpoilbookEventFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("START_LOOT_ROLL")

local function Dispatch(event, ...)
	if event == "ADDON_LOADED" then
		if (...) == ADDON_NAME then
			S:Init()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		S:CheckInstanceState()
	elseif event == "LOOT_OPENED" then
		S:OnLootOpened()
	elseif event == "CHAT_MSG_LOOT" then
		S:OnChatMsgLoot(...)
	elseif event == "ENCOUNTER_END" then
		S:OnEncounterEnd(...)
	elseif event == "BAG_UPDATE_DELAYED" then
		S:ReconcileBagCounts()
	elseif event == "START_LOOT_ROLL" then
		S:OnStartLootRoll(...)
	end
end

frame:SetScript("OnEvent", function(_, event, ...)
	-- a hard error here (e.g. an API that doesn't exist on this client) would
	-- otherwise abort silently and look like "nothing got recorded" with no clue why
	local ok, err = pcall(Dispatch, event, ...)
	if not ok then
		print("|cffff5555Spoilbook error|r (" .. event .. "): " .. tostring(err))
	end
end)
