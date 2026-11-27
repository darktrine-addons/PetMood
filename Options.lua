-- PetMood options: Settings → AddOns → PetMood, with an "Excluded food" subpage (drag & drop from the bags).
local ADDON, ns = ...
if not ns.active then return end   -- not a hunter

local category, excludeCategory, excludePanel

ns.OpenOptions = function()
	if category then Settings.OpenToCategory(category:GetID()) end
end

-- ---------------------------------------------------------------- excluded food subpage
local ROW_HEIGHT = 28

local function buildExcludePanel()
	local panel = CreateFrame("Frame")
	panel.OnCommit, panel.OnDefault, panel.OnRefresh = function() end, function() end, function() end

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Excluded food")

	local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	help:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	help:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	help:SetJustifyH("LEFT")
	help:SetText("PetMood never feeds these items to your pet and leaves them out of the food count. "
		.. "Drag an item from your bags onto the box below to add it. "
		.. "In chat, |cffffd100/petmood exclude|r followed by a shift-clicked item does the same.")

	-- Drop box: takes the item on the cursor (drag & drop, or pick up and click)
	local drop = CreateFrame("Button", nil, panel)
	drop:SetSize(40, 40)
	drop:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -14)
	local slot = drop:CreateTexture(nil, "BACKGROUND")
	slot:SetAllPoints()
	slot:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
	slot:SetTexCoord(0.140625, 0.859375, 0.140625, 0.859375)
	local plus = drop:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	plus:SetPoint("CENTER", 0, 1)
	plus:SetText("+")
	drop:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	local dropLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	dropLabel:SetPoint("LEFT", drop, "RIGHT", 10, 0)
	dropLabel:SetText("Drop an item here")

	local function takeCursorItem()
		local kind, itemID = GetCursorInfo()
		if kind ~= "item" or not itemID then return end
		ClearCursor()
		ns.setExcluded(itemID, true)
	end
	drop:SetScript("OnReceiveDrag", takeCursorItem)
	drop:SetScript("OnClick", takeCursorItem)
	drop:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Drop food here")
		GameTooltip:AddLine("Your pet will not be fed this item.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	drop:SetScript("OnLeave", GameTooltip_Hide)

	-- List of excluded items
	local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", drop, "BOTTOMLEFT", 0, -16)
	scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -36, 16)
	local list = CreateFrame("Frame", nil, scroll)
	list:SetSize(1, 1)
	scroll:SetScrollChild(list)
	scroll:SetScript("OnSizeChanged", function(self, w) list:SetWidth(w) end)

	local empty = list:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	empty:SetPoint("TOPLEFT", 4, -4)
	empty:SetText("No excluded items.")

	local rows = {}
	local function getRow(i)
		if rows[i] then return rows[i] end
		local row = CreateFrame("Frame", nil, list)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
		row:SetPoint("RIGHT", list, "RIGHT")
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(22, 22)
		row.icon:SetPoint("LEFT", 4, 0)
		row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
		row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.remove:SetSize(80, 22)
		row.remove:SetPoint("RIGHT", -4, 0)
		row.remove:SetText(REMOVE or "Remove")
		row.remove:SetScript("OnClick", function() ns.setExcluded(row.itemID, false) end)
		row:EnableMouse(true)
		row:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.itemID)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", GameTooltip_Hide)
		rows[i] = row
		return row
	end

	local pendingLoad = {}
	function panel:Rebuild()
		local ids = {}
		for id in pairs(ns.db.exclude) do table.insert(ids, id) end
		local names = {}
		for _, id in ipairs(ids) do
			local name, _, quality = C_Item.GetItemInfo(id)
			if not name and not pendingLoad[id] and Item and Item.CreateFromItemID then
				pendingLoad[id] = true                          -- not cached yet: rebuild once it loads
				Item:CreateFromItemID(id):ContinueOnItemLoad(function()
					pendingLoad[id] = nil
					if panel:IsVisible() then panel:Rebuild() end
				end)
			end
			local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
			names[id] = name and (color and color.hex or "|cffffffff") .. name .. "|r" or ("Item " .. id)
		end
		table.sort(ids, function(a, b) return (C_Item.GetItemInfo(a) or tostring(a)) < (C_Item.GetItemInfo(b) or tostring(b)) end)
		for i, id in ipairs(ids) do
			local row = getRow(i)
			row.itemID = id
			row.icon:SetTexture(C_Item.GetItemIconByID(id))
			row.name:SetText(names[id])
			row:Show()
		end
		for i = #ids + 1, #rows do rows[i]:Hide() end
		empty:SetShown(#ids == 0)
		list:SetHeight(math.max(1, #ids * ROW_HEIGHT))
	end
	panel:SetScript("OnShow", panel.Rebuild)
	return panel
end

ns.OnExclusionsChanged = function()
	if excludePanel and excludePanel:IsVisible() then excludePanel:Rebuild() end
end

-- ---------------------------------------------------------------- main page
function ns.InitOptions()
	if not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
	local db, DEFAULTS = ns.db, ns.DEFAULTS
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("PetMood")

	local function setting(key, varType, label)
		return Settings.RegisterAddOnSetting(category, "PetMood_" .. key, key, db, varType, label, DEFAULTS[key])
	end
	local function checkbox(key, label, tooltip, onChange)
		local s = setting(key, Settings.VarType.Boolean, label)
		Settings.CreateCheckbox(category, s, tooltip)
		s:SetValueChangedCallback(onChange or ns.refresh)
		return s
	end
	local function header(text)
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
	end
	local function button(label, onClick, tooltip)
		layout:AddInitializer(CreateSettingsButtonInitializer("", label, onClick, tooltip, true))
	end

	header("Icon")
	checkbox("showIcon", "Show icon", "Show the pet mood icon on screen.")
	checkbox("locked", "Lock icon", "Locked: the icon stays in place, hides when no hunter pet is out, and a click feeds your pet.\nUnlocked: the icon is always shown and you can drag it.")
	local size = setting("iconSize", Settings.VarType.Number, "Icon size")
	local sizeOptions = Settings.CreateSliderOptions(16, 64, 2)
	sizeOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return ("%d px"):format(v) end)
	Settings.CreateSlider(category, size, sizeOptions, "Size of the icon. Changes made in combat apply when combat ends.")
	size:SetValueChangedCallback(ns.refresh)
	checkbox("showCount", "Show food count", "Show how much food your pet eats you carry, in the corner of the icon.")
	checkbox("glow", "Glow when your pet needs food", "The icon glows yellow (Content) or red (Unhappy).")
	checkbox("hideHappy", "Hide while your pet is Happy", "Only show the icon when there is something to do. The key binding keeps working.")
	button("Reset position", function() ns.chat(ns.place() and "position reset" or "can't move the icon in combat") end,
		"Move the icon back to the centre of the screen.")

	header("Feeding")
	checkbox("clickFeed", "One-click feeding", "Click the locked icon, or press its key binding, to feed your pet.")
	button("Excluded food", function() Settings.OpenToCategory(excludeCategory:GetID()) end,
		"Choose food that PetMood never feeds to your pet.")

	header("Alerts")
	checkbox("alert", "Alert when the mood drops", "Centre-screen warning when your pet goes from Happy to Content or from Content to Unhappy.")
	checkbox("reminder", "Reminder before the pull", "On a ready check, or when you enter a dungeon or raid, remind you if your pet isn't Happy.")
	checkbox("sound", "Play a sound with alerts")
	button("Test alert", ns.testAlert, "Show a test alert.")

	header("Broker")
	checkbox("showBroker", "Show broker display", "Show PetMood in Bazooka, Titan Panel and other LibDataBroker displays.\nTurning it off takes effect after a /reload.",
		function(_, value)
			if value then ns.ensureBroker() else ns.chat("the broker display is removed after a /reload") end
		end)

	excludePanel = buildExcludePanel()
	excludeCategory = Settings.RegisterCanvasLayoutSubcategory(category, excludePanel, "Excluded food")
	Settings.RegisterAddOnCategory(category)
end
