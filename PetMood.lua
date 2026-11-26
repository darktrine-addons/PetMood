-- PetMood: hunter pet happiness indicator for WoW Forever (icon + LibDataBroker feed).
local ADDON = ...

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
local DEFAULTS = {locked = false, alert = true, sound = true}

local db
local state = {}          -- last query result, shared by icon, broker and diag
local lastMood            -- baseline for drop detection; nil until the first reading of the current pet
local pendingAlert        -- mood level of a drop that happened in combat, announced once combat ends

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
	local ok, h, dmg, loyalty = pcall(fn, "pet")
	if not ok then state.err = tostring(h); return end
	if issecretvalue and h ~= nil and issecretvalue(h) then state.err = "secret value"; return end
	state.raw = h
	state.mood = MOODS[h]
	state.damage, state.loyalty = dmg, loyalty
end

-- ---------------------------------------------------------------- icon frame
local frame = CreateFrame("Frame", "PetMoodFrame", UIParent)
frame:SetSize(24, 24)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
local tex = frame:CreateTexture(nil, "ARTWORK")
tex:SetAllPoints()
local border = frame:CreateTexture(nil, "BACKGROUND")
border:SetPoint("TOPLEFT", -1, 1); border:SetPoint("BOTTOMRIGHT", 1, -1)
border:SetColorTexture(0, 0, 0, 0.6)

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
	checkDrop()
	state.iconMode = applyIcon(tex, state.mood)
	frame:SetShown((state.hasPet and state.isHunterPet) or not db.locked)
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

-- ---------------------------------------------------------------- tooltip (never in combat)
local function fillTooltip(tt)
	tt:AddLine("Pet Mood")
	if not state.hasPet then
		tt:AddLine("No pet summoned", 0.7, 0.7, 0.7)
	elseif state.mood then
		tt:AddLine(("|cff%s%s|r"):format(state.mood.color, state.mood.label))
		if type(state.damage) == "number" then tt:AddDoubleLine("Damage", state.damage .. "%", 1, 1, 1, 1, 1, 1) end
		if type(state.loyalty) == "number" then tt:AddDoubleLine("Loyalty rate", tostring(state.loyalty), 1, 1, 1, 1, 1, 1) end
	else
		tt:AddLine("Happiness unavailable: " .. tostring(state.err or ("value " .. tostring(state.raw))), 1, 0.4, 0.4)
	end
	if not db.locked then tt:AddLine("Drag to move, /petmood lock to lock", 0.5, 0.8, 1) end
end

local tooltipOwner
local function showTooltip(owner)
	if InCombatLockdown() then return end
	GameTooltip:SetOwner(owner, "ANCHOR_NONE")
	-- Open towards the middle of the screen, works for top and bottom broker bars alike
	local _, y = owner:GetCenter()
	if y and y > UIParent:GetHeight() / 2 then
		GameTooltip:SetPoint("TOP", owner, "BOTTOM", 0, -4)
	else
		GameTooltip:SetPoint("BOTTOM", owner, "TOP", 0, 4)
	end
	fillTooltip(GameTooltip)
	GameTooltip:Show()
	tooltipOwner = owner
end
local function hideTooltip(owner)
	if GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
	tooltipOwner = nil
end

frame:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local p, _, rp, x, y = self:GetPoint()
	db.point = {p, rp, x, y}
end)
frame:SetScript("OnEnter", showTooltip)
frame:SetScript("OnLeave", hideTooltip)

local function place()
	frame:ClearAllPoints()
	local p = db.point
	if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else frame:SetPoint("CENTER", UIParent, "CENTER", 0, -60) end
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
				OnEnter = showTooltip, OnLeave = hideTooltip,
				OnClick = function() refresh() end})
		end
		for _, ev in ipairs({"UNIT_HAPPINESS", "UNIT_PET", "PET_UI_UPDATE", "PLAYER_ENTERING_WORLD",
		                     "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED"}) do
			pcall(self.RegisterEvent, self, ev)       -- some events may not exist on this client
		end
		C_Timer.NewTicker(2, refresh)                 -- safety net in case happiness events don't fire
		refresh()
		return
	end
	if event == "PLAYER_REGEN_DISABLED" then
		if tooltipOwner then hideTooltip(tooltipOwner) end
		return
	end
	if event == "UNIT_PET" then
		if unit ~= "player" then return end
		lastMood, pendingAlert = nil, nil             -- different pet (or none): new baseline, no alert
	elseif unit and unit ~= "pet" and unit ~= "player" then
		return
	end
	refresh()
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
		refresh()
		local _, class = UnitClass("player")
		chat(("class=%s pet=%s HasPetUI=%s hunterPet=%s"):format(tostring(class), tostring(state.hasPet), tostring(state.hasUI), tostring(state.isHunterPet)))
		chat(("api=%s raw=%s damage=%s loyalty=%s err=%s"):format(state.api, tostring(state.raw), tostring(state.damage), tostring(state.loyalty), tostring(state.err)))
		chat(("atlases: Mad=%s Neutral=%s Happiness=%s | icon=%s"):format(tostring(atlasExists("UI-PetMad")), tostring(atlasExists("UI-PetNeutral")), tostring(atlasExists("UI-PetHappiness")), tostring(state.iconMode)))
		chat(("broker=%s shown=%s locked=%s"):format(broker and "yes" or "no (no LibDataBroker loaded)", tostring(frame:IsShown()), tostring(db.locked)))
	elseif msg == "reset" then
		db.point = nil; place(); chat("position reset")
	elseif msg == "lock" then
		db.locked = not db.locked
		chat(db.locked and "icon locked (hidden without a hunter pet)" or "icon unlocked: drag to move")
		refresh()
	elseif msg == "alert" then
		db.alert = not db.alert; chat("mood drop alert " .. onOff(db.alert))
	elseif msg == "sound" then
		db.sound = not db.sound; chat("alert sound " .. onOff(db.sound))
	elseif msg == "test" then
		alert(2, true)
	else
		chat("commands:")
		chat("  /petmood lock - lock/unlock the icon (unlocked: drag to move)")
		chat(("  /petmood alert - mood drop alert (%s)"):format(onOff(db.alert)))
		chat(("  /petmood sound - alert sound (%s)"):format(onOff(db.sound)))
		chat("  /petmood test - show a test alert")
		chat("  /petmood reset - move the icon back to the screen centre")
		chat("  /petmood diag - print what the client reports")
	end
end
