-- PetMood: hunter pet happiness indicator for WoW Forever (icon + LibDataBroker feed).
local ADDON = ...

-- Hunters only: on other classes nothing is created (no icon, broker feed, events or slash command)
if select(2, UnitClass("player")) ~= "HUNTER" then return end

local MOODS = {
	[1] = {label = "Unhappy", color = "ff4040", atlas = "UI-PetMad",       coords = {0.375, 0.5625, 0, 0.359375}},
	[2] = {label = "Content", color = "ffd040", atlas = "UI-PetNeutral",   coords = {0.1875, 0.375, 0, 0.359375}},
	[3] = {label = "Happy",   color = "40ff40", atlas = "UI-PetHappiness", coords = {0, 0.1875, 0, 0.359375}},
}
local ALERT_TEXT = {
	[1] = "Your pet is |cffff4040Unhappy|r - feed it now!",
	[2] = "Your pet is only |cffffd040Content|r - feed it soon.",
}
local CLASSIC_FILE = "Interface\\PetPaperDollFrame\\UI-PetHappiness"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local FEED_PET_SPELL_ID = 6991
local FULL_VALUE_LEVELS = 10      -- food within this many levels below the pet is assumed to give full happiness
local DEFAULTS = {locked = false, alert = true, sound = true, hideHappy = false}

BINDING_HEADER_PETMOOD = "PetMood"
_G["BINDING_NAME_CLICK PetMoodFrame:LeftButton"] = "Feed pet"

local db
local state = {}          -- last query result, shared by icon, broker and diag
local food                -- best food in the bags: {bag, slot, itemID, link}; nil when none
local foodCount = 0       -- all items in the bags the pet eats
local lastMood            -- baseline for drop detection; nil until the first reading of the current pet
local pendingAlert        -- mood level of a drop that happened in combat, announced once combat ends
local secureDirty         -- the secure icon's visibility/attributes changed in combat, applied once combat ends

local function chat(msg) print("|cff80c0ffPetMood|r: " .. msg) end
local function onOff(v) return v and "|cff40ff40on|r" or "|cffff4040off|r" end

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
	if issecretvalue and h ~= nil and issecretvalue(h) then state.err = "secret value"; return end
	state.raw = h
	state.mood = MOODS[h]
	state.damage, state.loyalty = dmg, loyalty
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

-- ---------------------------------------------------------------- alerting
local function alert(level, test)
	local text = ALERT_TEXT[level]
	if not text then return end
	if RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
	end
	chat(text .. (test and " (test)" or ""))
	if db.sound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
	if frame:IsShown() then pulses = 0; pulse:Stop(); pulse:Play() end
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
	state.iconMode = applyIcon(tex, state.mood)
	applySecure()             -- before checkDrop, so a hidden-while-Happy icon is back in time for the alert pulse
	checkDrop()
	if not pulse:IsPlaying() then frame:SetAlpha(state.mood and 1 or 0.5) end
	if broker then
		if state.mood then
			broker.text = ("|cff%s%s|r"):format(state.mood.color, state.mood.label)
			broker.icon, broker.iconCoords = CLASSIC_FILE, state.mood.coords
		else
			broker.text = state.hasPet and "?" or "No pet"
			broker.icon, broker.iconCoords = UNKNOWN_ICON, {0.08, 0.92, 0.08, 0.92}
		end
	end
end

local function rescan()
	scanFood()
	refresh()
end

-- ---------------------------------------------------------------- tooltip (never in combat)
local function fillTooltip(tt, isIcon)
	tt:AddLine("Pet Mood")
	if not state.hasPet then
		tt:AddLine("No pet summoned", 0.7, 0.7, 0.7)
	elseif state.mood then
		tt:AddLine(("|cff%s%s|r"):format(state.mood.color, state.mood.label))
		if type(state.damage) == "number" then tt:AddDoubleLine("Damage", state.damage .. "%", 1, 1, 1, 1, 1, 1) end
		local loyaltyName = C_PetInfo and C_PetInfo.GetPetLoyalty and C_PetInfo.GetPetLoyalty()
		if loyaltyName then tt:AddDoubleLine("Loyalty", loyaltyName, 1, 1, 1, 1, 1, 1) end
		if type(state.loyalty) == "number" and state.loyalty ~= 0 then
			tt:AddLine(state.loyalty > 0 and "Gaining loyalty" or "Losing loyalty", state.loyalty > 0 and 0.4 or 1, state.loyalty > 0 and 1 or 0.4, 0.4)
		end
	else
		tt:AddLine("Happiness unavailable: " .. tostring(state.err or ("value " .. tostring(state.raw))), 1, 0.4, 0.4)
	end
	if state.hasPet then
		local diet = C_PetInfo and C_PetInfo.GetPetFoodTypes and C_PetInfo.GetPetFoodTypes()
		if diet and #diet > 0 then tt:AddDoubleLine("Diet", table.concat(diet, ", "), 1, 1, 1, 1, 1, 1) end
		local low = foodCount == 0 and 0.4 or 1
		tt:AddDoubleLine("Food in bags", tostring(foodCount), 1, 1, 1, 1, low, low)
		if isIcon and db.locked then
			tt:AddLine(" ")
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
		for _, ev in ipairs({"UNIT_HAPPINESS", "UNIT_PET", "UNIT_LEVEL", "PET_UI_UPDATE", "PLAYER_ENTERING_WORLD",
		                     "BAG_UPDATE_DELAYED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED"}) do
			pcall(self.RegisterEvent, self, ev)       -- some events may not exist on this client
		end
		C_Timer.NewTicker(2, refresh)                 -- safety net in case happiness events don't fire
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
		rescan()
		return
	end
	if event == "UNIT_LEVEL" then
		if unit == "pet" then rescan() end
		return
	end
	if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_ENTERING_WORLD" then
		rescan()
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
SLASH_PETMOOD1 = "/petmood"
SlashCmdList.PETMOOD = function(msg)
	msg = (msg or ""):lower():match("^%s*(%S*)")
	if msg == "diag" then
		rescan()
		local _, class = UnitClass("player")
		chat(("class=%s pet=%s HasPetUI=%s hunterPet=%s"):format(tostring(class), tostring(state.hasPet), tostring(state.hasUI), tostring(state.isHunterPet)))
		chat(("api=%s raw=%s damage=%s loyalty=%s err=%s"):format(state.api, tostring(state.raw), tostring(state.damage), tostring(state.loyalty), tostring(state.err)))
		chat(("atlases: Mad=%s Neutral=%s Happiness=%s | icon=%s"):format(tostring(atlasExists("UI-PetMad")), tostring(atlasExists("UI-PetNeutral")), tostring(atlasExists("UI-PetHappiness")), tostring(state.iconMode)))
		chat(("food: %d in bags, best=%s (bag %s slot %s), feed click=%s"):format(foodCount, food and (food.link or food.itemID) or "none", food and food.bag or "-", food and food.slot or "-", tostring(frame:GetAttribute("type1"))))
		chat(("broker=%s shown=%s locked=%s hideHappy=%s"):format(broker and "yes" or "no (no LibDataBroker loaded)", tostring(frame:IsShown()), tostring(db.locked), tostring(db.hideHappy)))
	elseif msg == "reset" then
		db.point = nil
		chat(place() and "position reset" or "can't move the icon in combat")
	elseif msg == "lock" then
		if InCombatLockdown() then chat("can't lock or unlock in combat"); return end
		db.locked = not db.locked
		chat(db.locked and "icon locked: click to feed, hidden without a hunter pet" or "icon unlocked: drag to move (feeding is off while unlocked)")
		refresh()
	elseif msg == "happy" then
		db.hideHappy = not db.hideHappy
		chat("hide icon while the pet is Happy " .. onOff(db.hideHappy) .. (InCombatLockdown() and " (applies after combat)" or ""))
		refresh()
	elseif msg == "alert" then
		db.alert = not db.alert; chat("mood drop alert " .. onOff(db.alert))
	elseif msg == "sound" then
		db.sound = not db.sound; chat("alert sound " .. onOff(db.sound))
	elseif msg == "test" then
		alert(2, true)
	else
		chat("commands:")
		chat("  /petmood lock - lock/unlock the icon (locked: click to feed; unlocked: drag to move)")
		chat(("  /petmood happy - hide the locked icon while the pet is Happy (%s)"):format(onOff(db.hideHappy)))
		chat(("  /petmood alert - mood drop alert (%s)"):format(onOff(db.alert)))
		chat(("  /petmood sound - alert sound (%s)"):format(onOff(db.sound)))
		chat("  /petmood test - show a test alert")
		chat("  /petmood reset - move the icon back to the screen centre")
		chat("  /petmood diag - print what the client reports")
	end
end
