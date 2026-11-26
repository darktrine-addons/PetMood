-- PetMood: hunter pet happiness indicator for WoW Forever (icon + LibDataBroker feed).
local ADDON = ...

-- Hunters only: on other classes nothing is created (no icon, broker feed, events or slash command)
if select(2, UnitClass("player")) ~= "HUNTER" then return end

local MOODS = {
	[1] = {label = "Unhappy", color = "ff4040", rgb = {1, 0.2, 0.2},  atlas = "UI-PetMad",       coords = {0.375, 0.5625, 0, 0.359375}},
	[2] = {label = "Content", color = "ffd040", rgb = {1, 0.8, 0.2},  atlas = "UI-PetNeutral",   coords = {0.1875, 0.375, 0, 0.359375}},
	[3] = {label = "Happy",   color = "40ff40", rgb = {0.3, 1, 0.3},  atlas = "UI-PetHappiness", coords = {0, 0.1875, 0, 0.359375}},
}
local ALERT_TEXT = {
	[1] = "Your pet is |cffff4040Unhappy|r - feed it now!",
	[2] = "Your pet is only |cffffd040Content|r - feed it soon.",
}
local REMINDER_TEXT = "Feed your pet before the pull - it is only %s."
local CLASSIC_FILE = "Interface\\PetPaperDollFrame\\UI-PetHappiness"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local FEED_PET_SPELL_ID = 6991
local FEED_EFFECT_SPELL_ID = 1539 -- "Feed Pet Effect" (classic id); also matched by name, the id found is remembered
local FULL_VALUE_LEVELS = 10      -- food within this many levels below the pet is assumed to give full happiness
local LOW_FOOD = 10               -- food count shown in red at or below this
local XP_WINDOW = 900             -- seconds of XP gains used for the time-to-level estimate
local REMINDER_COOLDOWN = 60      -- seconds between pre-pull reminders
local DEFAULTS = {locked = false, alert = true, sound = true, hideHappy = false, glow = true, reminder = true}

BINDING_HEADER_PETMOOD = "PetMood"
_G["BINDING_NAME_CLICK PetMoodFrame:LeftButton"] = "Feed pet"

local db
local state = {}          -- last query result, shared by icon, broker and diag
local food                -- best food in the bags: {bag, slot, itemID, link}; nil when none
local foodCount = 0       -- all items in the bags the pet eats
local lastMood            -- baseline for drop detection; nil until the first reading of the current pet
local pendingAlert        -- mood level of a drop that happened in combat, announced once combat ends
local secureDirty         -- the secure icon's visibility/attributes changed in combat, applied once combat ends
local feeding             -- active Feed Pet effect on the pet: {expires, duration}; nil when not eating
local lastReminder = 0

local function chat(msg) print("|cff80c0ffPetMood|r: " .. msg) end
local function onOff(v) return v and "|cff40ff40on|r" or "|cffff4040off|r" end
local function isSecret(v) return issecretvalue and v ~= nil and issecretvalue(v) end

local function atlasExists(name)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function happinessAPI()
	if C_PetInfo and C_PetInfo.GetPetHappiness then return C_PetInfo.GetPetHappiness, "C_PetInfo.GetPetHappiness" end
	if GetPetHappiness then return GetPetHappiness, "GetPetHappiness" end
end

local function query()
	wipe(state)
	state.hasPet = UnitExists("pet")
	local hasUI, isHunterPet = HasPetUI()
	state.hasUI, state.isHunterPet = hasUI, isHunterPet
	local fn, name = happinessAPI()
	state.api = name or "none"
	if not fn then state.err = "no happiness API"; return end
	local ok, h, dmg, loyalty = pcall(fn)
	if not ok then state.err = tostring(h); return end
	if isSecret(h) then state.err = "secret value"; return end
	state.raw = h
	state.mood = MOODS[h]
	state.damage, state.loyalty = dmg, loyalty
end

local function needsFood() return state.mood and state.raw < 3 end

local function formatDuration(sec)
	if sec < 60 then return "<1m" end
	local h, m = math.floor(sec / 3600), math.floor(sec % 3600 / 60)
	return h > 0 and ("%dh %dm"):format(h, m) or ("%dm"):format(m)
end

-- ---------------------------------------------------------------- food scan
local retryScan
local function scanFood()
	food, foodCount = nil, 0
	if not (C_PetInfo and C_PetInfo.CanPetEatItem) or not UnitExists("pet") then return end
	local petLevel = UnitLevel("pet") or 0
	local canEat, bestScore, uncached = {}, nil, false
	for bag = 0, NUM_BAG_SLOTS or 4 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local id = info and info.itemID
			if id then
				if canEat[id] == nil then
					local ok, res = pcall(C_PetInfo.CanPetEatItem, id)
					canEat[id] = ok and res == true
				end
				if canEat[id] then
					local stack = info.stackCount or 1
					foodCount = foodCount + stack
					local ilvl = select(4, C_Item.GetItemInfo(id))
					if not ilvl then uncached = true; ilvl = 0 end
					-- Full-value food beats the rest; among full-value food the lowest level wins (save the good stuff),
					-- otherwise the highest level available; smaller stacks first to free bag slots
					local primary = (ilvl >= petLevel - FULL_VALUE_LEVELS) and (10000 - ilvl) or ilvl
					local score = primary * 1000 + (999 - math.min(stack, 999))
					if not bestScore or score > bestScore then
						bestScore = score
						food = {bag = bag, slot = slot, itemID = id, link = info.hyperlink}
					end
				end
			end
		end
	end
	if uncached and not retryScan then                -- item levels arrive a moment after login
		retryScan = true
		C_Timer.After(3, function() retryScan = nil; scanFood() end)
	end
end

-- ---------------------------------------------------------------- pet XP and time to level
local xp = {samples = {}}  -- samples: {t, gained}; last/lastMax: previous reading for the delta

local function resetXP()
	wipe(xp.samples); xp.last, xp.lastMax = nil, nil
end

local function readXP()
	if not GetPetExperience or not UnitExists("pet") then return end
	local cur, max = GetPetExperience()
	if isSecret(cur) or isSecret(max) or type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then return end
	return cur, max
end

local function recordXP()
	local cur, max = readXP()
	if not cur then return end
	if xp.last then
		local gained = cur >= xp.last and (cur - xp.last) or (xp.lastMax - xp.last + cur)   -- level-up wraps
		if gained > 0 then table.insert(xp.samples, {t = GetTime(), gained = gained}) end
	end
	xp.last, xp.lastMax = cur, max
end

-- XP per second over the last XP_WINDOW seconds; nil without recent gains
local function xpRate()
	local now, s = GetTime(), xp.samples
	while s[1] and now - s[1].t > XP_WINDOW do table.remove(s, 1) end
	if not s[1] then return nil end
	local sum = 0
	for _, v in ipairs(s) do sum = sum + v.gained end
	return sum / math.max(now - s[1].t, 60)
end

-- {level, cur, max, pct, capped, rate, ttl}; nil without pet or XP data
local function petXPInfo()
	local cur, max = readXP()
	if not cur then return nil end
	local level = UnitLevel("pet") or 0
	local info = {level = level, cur = cur, max = max, pct = math.floor(cur / max * 100)}
	info.capped = level >= (UnitLevel("player") or 0)   -- a pet can't outlevel its hunter
	info.rate = xpRate()
	if info.rate and info.rate > 0 and not info.capped then info.ttl = (max - cur) / info.rate end
	return info
end

-- ---------------------------------------------------------------- icon (secure button: left click feeds)
local frame = CreateFrame("Button", "PetMoodFrame", UIParent, "SecureActionButtonTemplate")
frame:SetSize(24, 24)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:RegisterForClicks("AnyUp", "AnyDown")     -- mouse acts on release; the key binding follows ActionButtonUseKeyDown
local tex = frame:CreateTexture(nil, "ARTWORK")
tex:SetAllPoints()
local border = frame:CreateTexture(nil, "BACKGROUND")
border:SetPoint("TOPLEFT", -1, 1); border:SetPoint("BOTTOMRIGHT", 1, -1)
border:SetColorTexture(0, 0, 0, 0.6)
frame:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

-- Feeding timer: cooldown swipe over the icon while the Feed Pet effect runs
local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
cooldown:SetAllPoints()
cooldown:SetDrawEdge(false)
cooldown:SetHideCountdownNumbers(true)

-- Food count in the corner, like an item stack count; on its own layer above the swipe and the glow
local overlay = CreateFrame("Frame", nil, frame)
overlay:SetAllPoints()
overlay:SetFrameLevel(cooldown:GetFrameLevel() + 2)
local countText = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
countText:SetPoint("BOTTOMRIGHT", 3, -3)

-- Glow while the pet needs food, coloured by mood
local glow = frame:CreateTexture(nil, "OVERLAY")
glow:SetPoint("TOPLEFT", -6, 6); glow:SetPoint("BOTTOMRIGHT", 6, -6)
if atlasExists("bags-glow-white") then glow:SetAtlas("bags-glow-white") else glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border") end
glow:SetBlendMode("ADD")
glow:Hide()
local glowAnim = glow:CreateAnimationGroup()
glowAnim:SetLooping("BOUNCE")
local glowFade = glowAnim:CreateAnimation("Alpha")
glowFade:SetFromAlpha(1); glowFade:SetToAlpha(0.3); glowFade:SetDuration(0.8)

-- Pulse on alert: three fades of the icon
local pulse = frame:CreateAnimationGroup()
pulse:SetLooping("BOUNCE")
local fade = pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(1); fade:SetToAlpha(0.15); fade:SetDuration(0.35)
local pulses = 0
pulse:SetScript("OnLoop", function(self)
	pulses = pulses + 1
	if pulses >= 6 then self:Stop() end
end)
pulse:SetScript("OnStop", function() frame:SetAlpha(state.mood and 1 or 0.5) end)

local function applyIcon(texture, mood)
	if not mood then
		texture:SetTexture(UNKNOWN_ICON); texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		return "unknown"
	end
	if atlasExists(mood.atlas) then
		texture:SetTexCoord(0, 1, 0, 1); texture:SetAtlas(mood.atlas)
		return "atlas " .. mood.atlas
	end
	texture:SetTexture(CLASSIC_FILE); texture:SetTexCoord(unpack(mood.coords))
	return "file " .. CLASSIC_FILE
end

local function applyDecorations()
	if state.hasPet then
		countText:SetText(foodCount)
		if foodCount <= LOW_FOOD then countText:SetTextColor(1, 0.25, 0.25) else countText:SetTextColor(1, 1, 1) end
	else
		countText:SetText("")
	end
	if db.glow and needsFood() and not feeding then
		glow:SetVertexColor(unpack(state.mood.rgb))
		glow:Show()
		if not glowAnim:IsPlaying() then glowAnim:Play() end
	else
		glowAnim:Stop(); glow:Hide()
	end
end

-- Visibility and click action of the secure icon; protected in combat, so deferred until it ends
local function applySecure()
	if InCombatLockdown() then secureDirty = true; return end
	secureDirty = nil
	-- Unlocked: always shown for placing. Locked: only with a hunter pet, and optionally only when it needs food
	local needed = state.hasPet and state.isHunterPet and not (db.hideHappy and state.mood and state.raw == 3)
	frame:SetShown(needed or not db.locked)
	if db.locked and food then
		frame:SetAttribute("type1", "spell")
		frame:SetAttribute("spell1", C_Spell.GetSpellName(FEED_PET_SPELL_ID) or FEED_PET_SPELL_ID)
		frame:SetAttribute("target-bag", food.bag)
		frame:SetAttribute("target-slot", food.slot)
	else
		frame:SetAttribute("type1", nil)
	end
end

-- ---------------------------------------------------------------- feeding timer
local function isFeedEffect(aura)
	if isSecret(aura.spellId) or isSecret(aura.name) then return false end
	if aura.spellId == (db.feedEffectID or FEED_EFFECT_SPELL_ID) then return true end
	local feedName = C_Spell.GetSpellName(FEED_PET_SPELL_ID)
	if feedName and type(aura.name) == "string" and aura.name:find(feedName, 1, true) then
		db.feedEffectID = aura.spellId                  -- remember the id this client uses
		return true
	end
	return false
end

local function scanFeeding()
	feeding = nil
	if UnitExists("pet") and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "pet", i, "HELPFUL")
			if not ok or not aura then break end
			if isFeedEffect(aura) and not isSecret(aura.expirationTime) and not isSecret(aura.duration)
			   and (aura.expirationTime or 0) > 0 then
				feeding = {expires = aura.expirationTime, duration = aura.duration}
				break
			end
		end
	end
	if feeding then cooldown:SetCooldown(feeding.expires - feeding.duration, feeding.duration) else cooldown:Clear() end
end

-- ---------------------------------------------------------------- alerting
local function announce(text, test)
	if RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
	end
	chat(text .. (test and " (test)" or ""))
	if db.sound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
	if frame:IsShown() then pulses = 0; pulse:Stop(); pulse:Play() end
end

local function alert(level, test)
	if ALERT_TEXT[level] then announce(ALERT_TEXT[level], test) end
end

-- Before a pull (ready check, entering a dungeon or raid): remind when the pet isn't Happy
local function remind()
	if not db.reminder or InCombatLockdown() or not needsFood() or feeding then return end
	if GetTime() - lastReminder < REMINDER_COOLDOWN then return end
	lastReminder = GetTime()
	announce(REMINDER_TEXT:format(("|cff%s%s|r"):format(state.mood.color, state.mood.label)))
end

-- Called after every query: alert when the mood level drops; drops in combat wait for combat to end
local function checkDrop()
	local h = state.mood and state.raw
	if not h then
		if not state.hasPet then lastMood, pendingAlert = nil, nil end
		return
	end
	if lastMood and h < lastMood and db.alert then
		if InCombatLockdown() then pendingAlert = h else alert(h) end
	end
	if pendingAlert and h > pendingAlert then pendingAlert = nil end   -- fed before combat ended
	lastMood = h
end

-- ---------------------------------------------------------------- display refresh
local broker
local function refresh()
	query()
	if feeding and GetTime() >= feeding.expires then feeding = nil end
	state.iconMode = applyIcon(tex, state.mood)
	applySecure()             -- before checkDrop, so a hidden-while-Happy icon is back in time for the alert pulse
	applyDecorations()
	checkDrop()
	if not pulse:IsPlaying() then frame:SetAlpha(state.mood and 1 or 0.5) end
	if broker then
		if state.mood then
			local parts = {("|cff%s%s|r"):format(state.mood.color, state.mood.label)}
			table.insert(parts, (foodCount <= LOW_FOOD and "|cffff4040%d|r" or "%d"):format(foodCount))
			local info = petXPInfo()
			if info and not info.capped then table.insert(parts, ("L%d %d%%"):format(info.level, info.pct)) end
			broker.text = table.concat(parts, " · ")
			broker.icon, broker.iconCoords = CLASSIC_FILE, state.mood.coords
		else
			broker.text = state.hasPet and "?" or "No pet"
			broker.icon, broker.iconCoords = UNKNOWN_ICON, {0.08, 0.92, 0.08, 0.92}
		end
	end
end

local function rescan()
	scanFood()
	scanFeeding()
	refresh()
end

-- ---------------------------------------------------------------- tooltip (never in combat)
local function line(tt, left, right, r, g, b)
	tt:AddDoubleLine(left, right, 1, 1, 1, r or 1, g or 1, b or 1)
end

local function fillTooltip(tt, isIcon)
	tt:AddLine("Pet Mood")
	if not state.hasPet then
		tt:AddLine("No pet summoned", 0.7, 0.7, 0.7)
	elseif state.mood then
		tt:AddLine(("|cff%s%s|r"):format(state.mood.color, state.mood.label))
		if feeding then
			local left = math.max(0, math.floor(feeding.expires - GetTime()))
			line(tt, "Eating", left < 60 and ("%ds left"):format(left) or (formatDuration(left) .. " left"), 0.4, 1, 0.4)
		end
		if type(state.damage) == "number" then line(tt, "Damage", state.damage .. "%") end
		local loyaltyName = C_PetInfo and C_PetInfo.GetPetLoyalty and C_PetInfo.GetPetLoyalty()
		if loyaltyName then line(tt, "Loyalty", loyaltyName) end
		if type(state.loyalty) == "number" and state.loyalty ~= 0 then
			tt:AddLine(state.loyalty > 0 and "Gaining loyalty" or "Losing loyalty", state.loyalty > 0 and 0.4 or 1, state.loyalty > 0 and 1 or 0.4, 0.4)
		end
	else
		tt:AddLine("Happiness unavailable: " .. tostring(state.err or ("value " .. tostring(state.raw))), 1, 0.4, 0.4)
	end
	if state.hasPet then
		local info = petXPInfo()
		if info then
			tt:AddLine(" ")
			line(tt, "Level", ("%d (%d%%)"):format(info.level, info.pct))
			if info.capped then
				tt:AddLine("Pet is at your level and gains no more XP", 0.7, 0.7, 0.7)
			else
				line(tt, "XP", ("%s / %s"):format(BreakUpLargeNumbers(info.cur), BreakUpLargeNumbers(info.max)))
				line(tt, "To level", BreakUpLargeNumbers(info.max - info.cur))
				if info.rate then
					line(tt, "XP per hour", BreakUpLargeNumbers(math.floor(info.rate * 3600)))
					line(tt, "Time to level", "~" .. formatDuration(info.ttl))
				else
					line(tt, "Time to level", "no XP gained recently", 0.7, 0.7, 0.7)
				end
			end
		end
		tt:AddLine(" ")
		local diet = C_PetInfo and C_PetInfo.GetPetFoodTypes and C_PetInfo.GetPetFoodTypes()
		if diet and #diet > 0 then line(tt, "Diet", table.concat(diet, ", ")) end
		local low = foodCount <= LOW_FOOD and 0.4 or 1
		line(tt, "Food in bags", tostring(foodCount), 1, low, low)
		if isIcon and db.locked then
			if food then
				tt:AddLine("Click to feed: " .. (food.link or ("item " .. food.itemID)), 0.5, 0.8, 1)
			else
				tt:AddLine("No food your pet eats in your bags", 1, 0.4, 0.4)
			end
		end
	end
	if not db.locked then tt:AddLine("Drag to move, /petmood lock to lock", 0.5, 0.8, 1) end
end

local tooltipOwner
local function showTooltip(owner, isIcon)
	if InCombatLockdown() then return end
	GameTooltip:SetOwner(owner, "ANCHOR_NONE")
	-- Open towards the middle of the screen, works for top and bottom broker bars alike
	local _, y = owner:GetCenter()
	if y and y > UIParent:GetHeight() / 2 then
		GameTooltip:SetPoint("TOP", owner, "BOTTOM", 0, -4)
	else
		GameTooltip:SetPoint("BOTTOM", owner, "TOP", 0, 4)
	end
	fillTooltip(GameTooltip, isIcon)
	GameTooltip:Show()
	tooltipOwner = owner
end
local function hideTooltip(owner)
	if GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
	tooltipOwner = nil
end

frame:SetScript("OnDragStart", function(self) if not db.locked and not InCombatLockdown() then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local p, _, rp, x, y = self:GetPoint()
	db.point = {p, rp, x, y}
end)
frame:SetScript("OnEnter", function(self) showTooltip(self, true) end)
frame:SetScript("OnLeave", hideTooltip)
frame:HookScript("PostClick", function(_, button, down)
	if button ~= "LeftButton" or down or not db.locked then return end
	if InCombatLockdown() then
		chat("can't feed your pet in combat")
	elseif not state.hasPet then
		chat("no pet summoned")
	elseif not food then
		chat("no food your pet eats in your bags")
	end
end)

local function place()
	if InCombatLockdown() then return false end
	frame:ClearAllPoints()
	local p = db.point
	if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else frame:SetPoint("CENTER", UIParent, "CENTER", 0, -60) end
	return true
end

-- ---------------------------------------------------------------- events
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, unit)
	if event == "PLAYER_LOGIN" then
		PetMoodDB = PetMoodDB or {}
		db = PetMoodDB
		for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
		place()
		local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
		if LDB then
			broker = LDB:NewDataObject(ADDON, {type = "data source", label = "Pet", text = "...", icon = UNKNOWN_ICON,
				OnEnter = function(f) showTooltip(f, false) end, OnLeave = hideTooltip,
				OnClick = function() rescan() end})
		end
		for _, ev in ipairs({"UNIT_HAPPINESS", "UNIT_PET", "UNIT_LEVEL", "UNIT_AURA", "UNIT_PET_EXPERIENCE", "PET_UI_UPDATE",
		                     "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "READY_CHECK",
		                     "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED"}) do
			pcall(self.RegisterEvent, self, ev)       -- some events may not exist on this client
		end
		C_Timer.NewTicker(2, refresh)                 -- safety net in case happiness events don't fire
		recordXP()
		rescan()
		return
	end
	if event == "PLAYER_REGEN_DISABLED" then
		if tooltipOwner then hideTooltip(tooltipOwner) end
		return
	end
	if event == "UNIT_PET" then
		if unit ~= "player" then return end
		lastMood, pendingAlert = nil, nil             -- different pet (or none): new baseline, no alert
		resetXP(); recordXP()
		rescan()
		return
	end
	if event == "UNIT_PET_EXPERIENCE" then
		recordXP(); refresh()
		return
	end
	if event == "UNIT_AURA" then
		if unit == "pet" then scanFeeding(); refresh() end
		return
	end
	if event == "UNIT_LEVEL" then
		if unit == "pet" then rescan() end
		return
	end
	if event == "BAG_UPDATE_DELAYED" then
		rescan()
		return
	end
	if event == "PLAYER_ENTERING_WORLD" then
		rescan()
		local inInstance, instanceType = IsInInstance()
		if inInstance and (instanceType == "party" or instanceType == "raid") then remind() end
		return
	end
	if event == "READY_CHECK" then
		refresh(); remind()
		return
	end
	if unit and unit ~= "pet" and unit ~= "player" then return end
	refresh()                                         -- also applies secure changes deferred during combat
	if event == "PLAYER_REGEN_ENABLED" and pendingAlert then
		local level = state.mood and state.raw
		if level and level <= pendingAlert then alert(level) end
		pendingAlert = nil
	end
end)

-- ---------------------------------------------------------------- slash
local TOGGLES = {
	happy    = {key = "hideHappy", text = "hide icon while the pet is Happy"},
	alert    = {key = "alert",     text = "mood drop alert"},
	sound    = {key = "sound",     text = "alert sound"},
	glow     = {key = "glow",      text = "glow when the pet needs food"},
	reminder = {key = "reminder",  text = "feed reminder before pulls"},
}

SLASH_PETMOOD1 = "/petmood"
SlashCmdList.PETMOOD = function(msg)
	msg = (msg or ""):lower():match("^%s*(%S*)")
	local toggle = TOGGLES[msg]
	if toggle then
		db[toggle.key] = not db[toggle.key]
		chat(toggle.text .. " " .. onOff(db[toggle.key]))
		refresh()
	elseif msg == "diag" then
		rescan()
		local _, class = UnitClass("player")
		chat(("class=%s pet=%s HasPetUI=%s hunterPet=%s"):format(tostring(class), tostring(state.hasPet), tostring(state.hasUI), tostring(state.isHunterPet)))
		chat(("api=%s raw=%s damage=%s loyalty=%s err=%s"):format(state.api, tostring(state.raw), tostring(state.damage), tostring(state.loyalty), tostring(state.err)))
		chat(("atlases: Mad=%s Neutral=%s Happiness=%s glow=%s | icon=%s"):format(tostring(atlasExists("UI-PetMad")), tostring(atlasExists("UI-PetNeutral")), tostring(atlasExists("UI-PetHappiness")), tostring(atlasExists("bags-glow-white")), tostring(state.iconMode)))
		chat(("food: %d in bags, best=%s (bag %s slot %s), feed click=%s"):format(foodCount, food and (food.link or food.itemID) or "none", food and food.bag or "-", food and food.slot or "-", tostring(frame:GetAttribute("type1"))))
		local info = petXPInfo()
		chat(("xp: %s, samples=%d, feeding=%s, feedEffectID=%s"):format(info and ("L%d %d/%d capped=%s rate=%s"):format(info.level, info.cur, info.max, tostring(info.capped), info.rate and ("%.2f/s"):format(info.rate) or "none") or "none", #xp.samples, feeding and ("%.0fs left"):format(feeding.expires - GetTime()) or "no", tostring(db.feedEffectID or FEED_EFFECT_SPELL_ID)))
		chat(("broker=%s shown=%s locked=%s hideHappy=%s"):format(broker and "yes" or "no (no LibDataBroker loaded)", tostring(frame:IsShown()), tostring(db.locked), tostring(db.hideHappy)))
	elseif msg == "reset" then
		db.point = nil
		chat(place() and "position reset" or "can't move the icon in combat")
	elseif msg == "lock" then
		if InCombatLockdown() then chat("can't lock or unlock in combat"); return end
		db.locked = not db.locked
		chat(db.locked and "icon locked: click to feed, hidden without a hunter pet" or "icon unlocked: drag to move (feeding is off while unlocked)")
		refresh()
	elseif msg == "test" then
		alert(2, true)
	else
		chat("commands:")
		chat("  /petmood lock - lock/unlock the icon (locked: click to feed; unlocked: drag to move)")
		for _, name in ipairs({"happy", "glow", "alert", "sound", "reminder"}) do
			chat(("  /petmood %s - %s (%s)"):format(name, TOGGLES[name].text, onOff(db[TOGGLES[name].key])))
		end
		chat("  /petmood test - show a test alert")
		chat("  /petmood reset - move the icon back to the screen centre")
		chat("  /petmood diag - print what the client reports")
	end
end
