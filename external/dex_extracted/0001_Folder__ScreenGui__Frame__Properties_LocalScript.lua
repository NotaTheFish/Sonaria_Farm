--[[
	
Change log:

09/18
	Fixed checkbox mouseover sprite
	Encapsulated checkbox creation into separate method
	Fixed another checkbox issue

09/15
	Invalid input is ignored instead of setting to default of that data type
	Consolidated control methods and simplified them
	All input goes through ToValue method
	Fixed position of BrickColor palette
	Made DropDown appear above row if it would otherwise exceed the page height
	Cleaned up stylesheets

09/14
	Made properties window scroll when mouse wheel scrolled
	Object/Instance and Color3 data types handled properly
	Multiple BrickColor controls interfering with each other fixed
	Added support for Content data type
	
--]]

wait(0.2)

local Gui = script.Parent.Parent
local PropertiesFrame = Gui:WaitForChild("PropertiesFrame")
local ExplorerFrame = Gui:WaitForChild("ExplorerPanel")
print = ExplorerFrame:WaitForChild("GetPrint"):Invoke()


-- Services
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Functions
function httpGet(url)
	return game:HttpGet(url,true)
end

-- RbxApi Stuff

local apiUrl = "http://anaminus.github.io/rbx/json/api/latest.json"
local maxChunkSize = 100 * 1000
local ApiJson
if script:FindFirstChild("RawApiJson") then
	ApiJson = script.RawApiJson
else
	ApiJson = ""
end

function getLocalApiJson()
	print(ApiJson)
	local usels = false
	local s = pcall(function() if ApiJson.Source ~= "" then usels = true end end)
	if usels then
		return loadstring(ApiJson.Source)()()
	else
		return require(ApiJson)()
	end
end

function getCurrentApiJson()
	local jsonStr = nil
	if readfile and getelysianpath then
		if readfile(getelysianpath().."Xpl0rerApi.txt") then
			print("Api found in folder!")
			jsonStr = readfile(getelysianpath().."Xpl0rerApi.txt")
			return jsonStr
		end
	end
	local success
	if not SetGlobal then
		success = pcall(function()
			jsonStr = httpGet(apiUrl)
			print("Fetched json successfully")
		end)
	end
	if success then
		print("Returning json")
		--print(jsonStr:sub(1,500))
		return jsonStr
	else
		print("Error fetching json: " .. tostring(err))
		print("Falling back to local copy")
		return getLocalApiJson()
	end
end

function splitStringIntoChunks(jsonStr)
	-- Splits up a string into a table with a given size
	local t = {}
	for i = 1, math.ceil(string.len(jsonStr)/maxChunkSize) do
		local str = jsonStr:sub((i-1)*maxChunkSize+1, i*maxChunkSize)
		table.insert(t, str)
	end
	return t
end

local jsonToParse = getCurrentApiJson()
local apiChunks = splitStringIntoChunks(jsonToParse)

function getRbxApi()
--[[
	Api.Classes
	Api.Enums
	Api.GetProperties(className)
	Api.IsEnum(valueType)
--]]

-- Services
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Remotes
--local Remotes = ReplicatedStorage:WaitForChild("OnlineStudio"):WaitForChild("Remotes")
--local GetApiJsonFunction = Remotes:WaitForChild("GetApiJson")

-- Functions
local JsonDecode = function(s) return HttpService:JSONDecode(s) end

local function GetApiRemoteFunction(index)
	if (apiChunks[index]) then 
		return apiChunks[index], #apiChunks
	else
		print("Bad index for GetApiJson")
		return nil
	end
end

local function getApiJson()
	local apiTable = {}
	local firstPage, pageCount = GetApiRemoteFunction(1)
	table.insert(apiTable, firstPage)
	for i = 2, pageCount do
		--print("Fetching API page # " .. tostring(i))
		local result = GetApiRemoteFunction(i)
		table.insert(apiTable, result)
	end
	return table.concat(apiTable)
end

local json = getApiJson()
local apiDump =  JsonDecode(json)

local Classes = {}
local Enums = {}

local function sortAlphabetic(t, property)
	table.sort(t, 
		function(x,y) return x[property] < y[property]
	end)
end

local function isEnum(name)
	return Enums[name] ~= nil
end

local function getProperties(className)
	local class = Classes[className]
	local properties = {}
	
	if not class then return properties end
	
	while class do
		for _,property in pairs(class.Properties) do
			table.insert(properties, property)
		end
		class = Classes[class.Superclass]
	end
	
	sortAlphabetic(properties, "Name")

	return properties
end

for _,item in pairs(apiDump) do
	local itemType = item.type
-- Classes --
	if (itemType == 'Class') then
		Classes[item.Name] = item
		item.Properties = {}
		item.Functions = {}
		item.YieldFunctions = {}
		item.Events = {}
		item.Callbacks = {}
-- Members --
	elseif (itemType == 'Property') then
		table.insert(Classes[item.Class].Properties, item)
	elseif (itemType == 'Function') then
		table.insert(Classes[item.Class].Functions, item)
	elseif (itemType == 'YieldFunction') then
		table.insert(Classes[item.Class].YieldFunctions, item)
	elseif (itemType == 'Event') then
		table.insert(Classes[item.Class].Events, item)
	elseif (itemType == 'Callback') then
		table.insert(Classes[item.Class].Callbacks, item)
-- Enums --
	elseif (itemType == 'Enum') then
		Enums[item.Name] = item
		item.EnumItems = {}
	elseif (itemType == 'EnumItem') then
		Enums[item.Enum].EnumItems[item.Name] = item
	end
end

return {
	Classes = Classes;
	Enums = Enums;
	GetProperties = getProperties;
	IsEnum = isEnum;
}
end

-- Modules
local Permissions = {CanEdit = true}
local RbxApi = getRbxApi()

--[[
	RbxApi.Classes
	RbxApi.Enums
	RbxApi.GetProperties(className)
	RbxApi.IsEnum(valueType)
--]]

-- Styles

local function CreateColor3(r, g, b) return Color3.new(r/255,g/255,b/255) end

local Styles = {
	Font = Enum.Font.Arial;
	Margin = 5;
	Black = CreateColor3(0,0,0);
	White = CreateColor3(255,255,255);
}

local Row = {
	Font = Styles.Font;
	FontSize = Enum.FontSize.Size14;
	TextXAlignment = Enum.TextXAlignment.Left;
	TextColor = Styles.Black;
	TextColorOver = Styles.White;
	TextLockedColor = CreateColor3(120,120,120);
	Height = 24;
	BorderColor = CreateColor3(216,216,216);
	BackgroundColor = Styles.White;
	BackgroundColorAlternate = CreateColor3(246,246,246);
	BackgroundColorMouseover = CreateColor3(211,224,244);
	TitleMarginLeft = 15;
}

local DropDown = {
	Font = Styles.Font;
	FontSize = Enum.FontSize.Size14;
	TextColor = CreateColor3(0,0,0);
	TextColorOver = Styles.White;
	TextXAlignment = Enum.TextXAlignment.Left;
	Height = 16;
	BackColor = Styles.White;
	BackColorOver = CreateColor3(86,125,188);
	BorderColor = CreateColor3(216,216,216);
	BorderSizePixel = 2;
	ArrowColor = CreateColor3(160,160,160);
	ArrowColorOver = Styles.Black;
}

local BrickColors = {
	BoxSize = 13;
	BorderSizePixel = 1;
	BorderColor = CreateColor3(160,160,160);
	FrameColor = CreateColor3(160,160,160);
	Size = 20;
	Padding = 4;
	ColorsPerRow = 8;
	OuterBorder = 1;
	OuterBorderColor = Styles.Black;
}

wait(1)

local bindGetSelection = ExplorerFrame.GetSelection
local bindSelectionChanged = ExplorerFrame.SelectionChanged
local bindGetApi = PropertiesFrame.GetApi
local bindGetAwait = PropertiesFrame.GetAwaiting
local bindSetAwait = PropertiesFrame.SetAwaiting

local ContentUrl = ContentProvider.BaseUrl .. "asset/?id="

local SettingsRemote = Gui:WaitForChild("SettingsPanel"):WaitForChild("GetSetting")

local propertiesSearch = PropertiesFrame.Header.TextBox

local AwaitingObjectValue = false
local AwaitingObjectObj
local AwaitingObjectProp

function searchingProperties()
	if propertiesSearch.Text ~= "" then
		return true
	end
	return false
end

local function GetSelection()
	local selection = bindGetSelection:Invoke()
	if #selection == 0 then
		return nil
	else
		return selection
	end 
end

-- Number

local function Round(number, decimalPlaces)
	return tonumber(string.format("%." .. (decimalPlaces or 0) .. "f", number))
end

-- Strings

local function Split(str, delimiter)
	local start = 1
	local t = {}
	while true do
		local pos = string.find (str, delimiter, start, true)
		if not pos then
			break
		end
		table.insert (t, string.sub (str, start, pos - 1))
		start = pos + string.len (delimiter)
	end
	table.insert (t, string.sub (str, start))
	return t
end

-- Data Type Handling

local function ToString(value, type)
	if type == "float" then
		return tostring(Round(value,2))
	elseif type == "Content" then
		if string.find(value,"/asset") then
			local match = string.find(value, "=") + 1
			local id = string.sub(value, match)
			return id
		else
			return tostring(value)
		end
	elseif type == "Vector2" then
		local x = value.x
		local y = value.y
		return string.format("%g, %g", x,y)
	elseif type == "Vector3" then
		local x = value.x
		local y = value.y
		local z = value.z
		return string.format("%g, %g, %g", x,y,z)
	elseif type == "Color3" then
		local r = value.r
		local g = value.g
		local b = value.b
		return string.format("%d, %d, %d", r*255,g*255,b*255)
	elseif type == "UDim2" then
		local xScale = value.X.Scale
		local xOffset = value.X.Offset
		local yScale = value.Y.Scale
		local yOffset = value.Y.Offset
		return string.format("{%d, %d}, {%d, %d}", xScale, xOffset, yScale, yOffset)
	else
		return tostring(value)
	end
end

local function ToValue(value,type)
	if type == "Vector2" then
		local list = Split(value,",")
		if #list < 2 then return nil end
		local x = tonumber(list[1]) or 0
		local y = tonumber(list[2]) or 0
		return Vector2.new(x,y)
	elseif type == "Vector3" then
		local list = Split(value,",")
		if #list < 3 then return nil end
		local x = tonumber(list[1]) or 0
		local y = tonumber(list[2]) or 0
		local z = tonumber(list[3]) or 0
		return Vector3.new(x,y,z)
	elseif type == "Color3" then
		local list = Split(value,",")
		if #list < 3 then return nil end
		local r = tonumber(list[1]) or 0
		local g = tonumber(list[2]) or 0
		local b = tonumber(list[3]) or 0
		return Color3.new(r/255,g/255, b/255)
	elseif type == "UDim2" then
		local list = Split(string.gsub(string.gsub(value, "{", ""),"}",""),",")
		if #list < 4 then return nil end
		local xScale = tonumber(list[1]) or 0
		local xOffset = tonumber(list[2]) or 0
		local yScale = tonumber(list[3]) or 0
		local yOffset = tonumber(list[4]) or 0
		return UDim2.new(xScale, xOffset, yScale, yOffset)
	elseif type == "Content" then
		if tonumber(value) ~= nil then
			value = ContentUrl .. value
		end
		return value
	elseif type == "float" or type == "int" or type == "double" then
		return tonumber(value)
	elseif type == "string" then
		return value
	elseif type == "NumberRange" then
		local list = Split(value,",")
		if #list == 1 then
			if tonumber(list[1]) == nil then return nil end
			local newVal = tonumber(list[1]) or 0
			return NumberRange.new(newVal)
		end
		if #list < 2 then return nil end
		local x = tonumber(list[1]) or 0
		local y = tonumber(list[2]) or 0
		return NumberRange.new(x,y)
	else
		return nil
	end
end


-- Tables

local function CopyTable(T)
  local t2 = {}
  for k,v in pairs(T) do
    t2[k] = v
  end
  return t2
end

local function SortTable(T)
	table.sort(T, 
		function(x,y) return x.Name < y.Name
	end)
end

-- Spritesheet
local Sprite = {
	Width = 13;
	Height = 13;
}

local Spritesheet = {
	Image = "http://www.roblox.com/asset/?id=128896947";
	Height = 256;
	Width = 256;
}

local Images = {
	"unchecked",
	"checked",
	"unchecked_over",
	"checked_over",
	"unchecked_disabled",
	"checked_disabled"
}

local function SpritePosition(spriteName)
	local x = 0
	local y = 0
	for i,v in pairs(Images) do
		if (v == spriteName) then
			return {x, y}
		end
		x = x + Sprite.Height
		if (x + Sprite.Width) > Spritesheet.Width then
			x = 0
			y = y + Sprite.Height
		end
	end
end

local function GetCheckboxImageName(checked, readOnly, mouseover)
	if checked then
		if readOnly then
			return "checked_disabled"
		elseif mouseover then
			return "checked_over"
		else
			return "checked"
		end
	else
		if readOnly then
			return "unchecked_disabled"
		elseif mouseover then
			return "unchecked_over"
		else
			return "unchecked"
		end
	end
end

local MAP_ID = 418720155

-- Gui Controls --

---- IconMap ----
-- Image size: 256px x 256px
-- Icon size: 16px x 16px
-- Padding between each icon: 2px
-- Padding around image edge: 1px
-- Total icons: 14 x 14 (196)
local Icon do
	local iconMap = 'http://www.roblox.com/asset/?id=' .. MAP_ID
	game:GetService('ContentProvider'):Preload(iconMap)
	local iconDehash do
		-- 14 x 14, 0-based input, 0-based output
		local f=math.floor
		function iconDehash(h)
			return f(h/14%14),f(h%14)
		end
	end

	function Icon(IconFrame,index)
		local row,col = iconDehash(index)
		local mapSize = Vector2.new(256,256)
		local pad,border = 2,1
		local iconSize = 16

		local class = 'Frame'
		if type(IconFrame) == 'string' then
			class = IconFrame
			IconFrame = nil
		end

		if not IconFrame then
			IconFrame = Create(class,{
				Name = "Icon";
				BackgroundTransparency = 1;
				ClipsDescendants = true;
				Create('ImageLabel',{
					Name = "IconMap";
					Active = false;
					BackgroundTransparency = 1;
					Image = iconMap;
					Size = UDim2.new(mapSize.x/iconSize,0,mapSize.y/iconSize,0);
				});
			})
		end

		IconFrame.IconMap.Position = UDim2.new(-col - (pad*(col+1) + border)/iconSize,0,-row - (pad*(row+1) + border)/iconSize,0)
		return IconFrame
	end
end


local function CreateCell()
	local tableCell = Instance.new("Frame")
	tableCell.Size = UDim2.new(0.5, -1, 1, 0)
	tableCell.BackgroundColor3 = Row.BackgroundColor
	tableCell.BorderColor3 = Row.BorderColor
	return tableCell
end
	
local function CreateLabel(readOnly)
	local label = Instance.new("TextLabel")
	label.Font = Row.Font
	label.FontSize = Row.FontSize
	label.TextXAlignment = Row.TextXAlignment
	label.BackgroundTransparency = 1
	
	if readOnly then
		label.TextColor3 = Row.TextLockedColor
	else
		label.TextColor3 = Row.TextColor
	end
	return label
end

local function CreateTextButton(readOnly, onClick)
	local button = Instance.new("TextButton")
	button.Font = Row.Font
	button.FontSize = Row.FontSize
	button.TextXAlignment = Row.TextXAlignment
	button.BackgroundTransparency = 1
	if readOnly then
		button.TextColor3 = Row.TextLockedColor
	else
		button.TextColor3 = Row.TextColor
		button.MouseButton1Click:connect(function()
			onClick()
		end)
	end
	return button
end

local function CreateObject(readOnly)
	local button = Instance.new("TextButton")
	button.Font = Row.Font
	button.FontSize = Row.FontSize
	button.TextXAlignment = Row.TextXAlignment
	button.BackgroundTransparency = 1
	if readOnly then
		button.TextColor3 = Row.TextLockedColor
	else
		button.TextColor3 = Row.TextColor
	end
	local cancel = Create(Icon('ImageButton',177),{
		Name = "Cancel";
		Visible = false;
		Position = UDim2.new(1,-20,0,0);
		Size = UDim2.new(0,20,0,20);
		Parent = button;
	})
	return button
end

local function CreateTextBox(readOnly)
	if readOnly then
		local box = CreateLabel(readOnly)
		return box
	else
		local box = Instance.new("TextBox")
		if not SettingsRemote:Invoke("ClearProps") then
			box.ClearTextOnFocus = false
		end
		box.Font = Row.Font
		box.FontSize = Row.FontSize
		box.TextXAlignment = Row.TextXAlignment
		box.BackgroundTransparency = 1
		box.TextColor3 = Row.TextColor
		return box
	end
end

local function CreateDropDownItem(text, onClick)
	local button = Instance.new("TextButton")
	button.Font = DropDown.Font
	button.FontSize = DropDown.FontSize
	button.TextColor3 = DropDown.TextColor
	button.TextXAlignment = DropDown.TextXAlignment
	button.BackgroundColor3 = DropDown.BackColor
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Active = true
	button.Text = text
	
	button.MouseEnter:connect(function()
		button.TextColor3 = DropDown.TextColorOver
		button.BackgroundColor3 = DropDown.BackColorOver
	end)
	button.MouseLeave:connect(function()
		button.TextColor3 = DropDown.TextColor
		button.BackgroundColor3 = DropDown.BackColor
	end)
	button.MouseButton1Click:connect(function()
		onClick(text)
	end)	
	return button
end

local function CreateDropDown(choices, currentChoice, readOnly, onClick)
	local frame = Instance.new("Frame")	
	frame.Name = "DropDown"
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundTransparency = 1
	frame.Active = true
	
	local menu = nil
	local arrow = nil
	local expanded = false
	local margin = DropDown.BorderSizePixel;
	
	local button = Instance.new("TextButton")
	button.Font = Row.Font
	button.FontSize = Row.FontSize
	button.TextXAlignment = Row.TextXAlignment
	button.BackgroundTransparency = 1
	button.TextColor3 = Row.TextColor
	if readOnly then
		button.TextColor3 = Row.TextLockedColor
	end
	button.Text = currentChoice
	button.Size = UDim2.new(1, -2 * Styles.Margin, 1, 0)
	button.Position = UDim2.new(0, Styles.Margin, 0, 0)
	button.Parent = frame
	
	local function showArrow(color)
		if arrow then arrow:Destroy() end
		
		local graphicTemplate = Create('Frame',{
			Name="Graphic";
			BorderSizePixel = 0;
			BackgroundColor3 = color;
		})
		local graphicSize = 16/2
		
		arrow = ArrowGraphic(graphicSize,'Down',true,graphicTemplate)
		arrow.Position = UDim2.new(1,-graphicSize * 2,0.5,-graphicSize/2)
		arrow.Parent = frame
	end
	
	local function hideMenu()
		expanded = false
		showArrow(DropDown.ArrowColor)
		if menu then menu:Destroy() end
	end
	
	local function showMenu()
		expanded = true
		menu = Instance.new("Frame")
		menu.Size = UDim2.new(1, -2 * margin, 0, #choices * DropDown.Height)
		menu.Position = UDim2.new(0, margin, 0, Row.Height + margin)
		menu.BackgroundTransparency = 0
		menu.BackgroundColor3 = DropDown.BackColor
		menu.BorderColor3 = DropDown.BorderColor
		menu.BorderSizePixel = DropDown.BorderSizePixel
		menu.Active = true
		menu.ZIndex = 5
		menu.Parent = frame
		
		local parentFrameHeight = menu.Parent.Parent.Parent.Parent.Size.Y.Offset
		local rowHeight = menu.Parent.Parent.Parent.Position.Y.Offset
		if (rowHeight + menu.Size.Y.Offset) > math.max(parentFrameHeight,PropertiesFrame.AbsoluteSize.y) then
			menu.Position = UDim2.new(0, margin, 0, -1 * (#choices * DropDown.Height) - margin)
		end
			
		local function choice(name)
			onClick(name)
			hideMenu()
		end
		
		for i,name in pairs(choices) do
			local option = CreateDropDownItem(name, function()
				choice(name)
			end)
			option.Size = UDim2.new(1, 0, 0, 16)
			option.Position = UDim2.new(0, 0, 0, (i - 1) * DropDown.Height)
			option.ZIndex = menu.ZIndex
			option.Parent = menu
		end
	end
	
	showArrow(DropDown.ArrowColor)
	
	if not readOnly then
		
		button.MouseEnter:connect(function()
			button.TextColor3 = Row.TextColor
			showArrow(DropDown.ArrowColorOver)
		end)
		button.MouseLeave:connect(function()
			button.TextColor3 = Row.TextColor
			if not expanded then
				showArrow(DropDown.ArrowColor)
			end
		end)
		button.MouseButton1Click:connect(function()
			if expanded then
				hideMenu()
			else
				showMenu()
			end
		end)
	end
	
	return frame,button
end

local function CreateBrickColor(readOnly, onClick)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1,0,1,0)
	frame.BackgroundTransparency = 1
	
	local colorPalette = Instance.new("Frame")
	colorPalette.BackgroundTransparency = 0
	colorPalette.SizeConstraint = Enum.SizeConstraint.RelativeXX
	colorPalette.Size = UDim2.new(1, -2 * BrickColors.OuterBorder, 1, -2 * BrickColors.OuterBorder)
	colorPalette.BorderSizePixel = BrickColors.BorderSizePixel
	colorPalette.BorderColor3 = BrickColors.BorderColor
	colorPalette.Position = UDim2.new(0, BrickColors.OuterBorder, 0, BrickColors.OuterBorder + Row.Height)
	colorPalette.ZIndex = 5
	colorPalette.Visible = false
	colorPalette.BorderSizePixel = BrickColors.OuterBorder
	colorPalette.BorderColor3 = BrickColors.OuterBorderColor
	colorPalette.Parent = frame
	
	local function show()
		colorPalette.Visible = true
	end
	
	local function hide()
		colorPalette.Visible = false
	end
	
	local function toggle()
		colorPalette.Visible = not colorPalette.Visible
	end
	
	local colorBox = Instance.new("TextButton", frame)
	colorBox.Position = UDim2.new(0, Styles.Margin, 0, Styles.Margin)
	colorBox.Size = UDim2.new(0, BrickColors.BoxSize, 0, BrickColors.BoxSize)
	colorBox.Text = ""
	colorBox.MouseButton1Click:connect(function()
		if not readOnly then
			toggle()
		end
	end)
	
	if readOnly then
		colorBox.AutoButtonColor = false
	end
	
	local spacingBefore = (Styles.Margin * 2) + BrickColors.BoxSize
	
	local propertyLabel = CreateTextButton(readOnly, function()
		if not readOnly then
			toggle()
		end
	end)
	propertyLabel.Size = UDim2.new(1, (-1 * spacingBefore) - Styles.Margin, 1, 0)
	propertyLabel.Position = UDim2.new(0, spacingBefore, 0, 0)
	propertyLabel.Parent = frame
	
	local size = (1 / BrickColors.ColorsPerRow)
	
	for index = 0, 127 do
		local brickColor = BrickColor.palette(index)
		local color3 = brickColor.Color
		
		local x = size * (index % BrickColors.ColorsPerRow)
		local y = size * math.floor(index / BrickColors.ColorsPerRow)
	
		local brickColorBox = Instance.new("TextButton")
		brickColorBox.Text = ""
		brickColorBox.Size = UDim2.new(size,0,size,0)
		brickColorBox.BackgroundColor3 = color3
		brickColorBox.Position = UDim2.new(x, 0, y, 0)
		brickColorBox.ZIndex = colorPalette.ZIndex
		brickColorBox.Parent = colorPalette
	
		brickColorBox.MouseButton1Click:connect(function()
			hide()
			onClick(brickColor)
		end)
	end
	
	return frame,propertyLabel,colorBox
end

local function CreateColor3Control(readOnly, onClick)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1,0,1,0)
	frame.BackgroundTransparency = 1
	
	local colorBox = Instance.new("TextButton", frame)
	colorBox.Position = UDim2.new(0, Styles.Margin, 0, Styles.Margin)
	colorBox.Size = UDim2.new(0, BrickColors.BoxSize, 0, BrickColors.BoxSize)
	colorBox.Text = ""
	colorBox.AutoButtonColor = false
	
	local spacingBefore = (Styles.Margin * 2) + BrickColors.BoxSize
	local box = CreateTextBox(readOnly)
	box.Size = UDim2.new(1, (-1 * spacingBefore) - Styles.Margin, 1, 0)
	box.Position = UDim2.new(0, spacingBefore, 0, 0)
	box.Parent = frame
	
	return frame,box,colorBox
end

function CreateCheckbox(value, readOnly, onClick)
	local checked = value
	local mouseover = false

	local checkboxFrame = Instance.new("ImageButton")
	checkboxFrame.Size = UDim2.new(0, Sprite.Width, 0, Sprite.Height)
	checkboxFrame.BackgroundTransparency = 1
	checkboxFrame.ClipsDescendants = true
	--checkboxFrame.Position = UDim2.new(0, Styles.Margin, 0, Styles.Margin)

	local spritesheetImage = Instance.new("ImageLabel", checkboxFrame)
	spritesheetImage.Name = "SpritesheetImageLabel"
	spritesheetImage.Size = UDim2.new(0, Spritesheet.Width, 0, Spritesheet.Height)
	spritesheetImage.Image = Spritesheet.Image
	spritesheetImage.BackgroundTransparency = 1
	
	local function updateSprite()
		local spriteName = GetCheckboxImageName(checked, readOnly, mouseover)
		local spritePosition = SpritePosition(spriteName)
		spritesheetImage.Position = UDim2.new(0, -1 * spritePosition[1], 0, -1 * spritePosition[2])
	end
	
	local function setValue(val)
		checked = val
		updateSprite()
	end

	if not readOnly then
		checkboxFrame.MouseEnter:connect(function() mouseover = true updateSprite() end)
		checkboxFrame.MouseLeave:connect(function() mouseover = false updateSprite() end)
		checkboxFrame.MouseButton1Click:connect(function()
			onClick(checked)
		end)
	end
	
	updateSprite()
	
	return checkboxFrame, setValue
end



-- Code for handling controls of various data types --

local Controls = {}

Controls["default"] = function(object, propertyData, readOnly)
	local propertyName = propertyData["Name"]
	local propertyType = propertyData["ValueType"]
	
	local box = CreateTextBox(readOnly)
	box.Size = UDim2.new(1, -2 * Styles.Margin, 1, 0)
	box.Position = UDim2.new(0, Styles.Margin, 0, 0)

	local function update()
		local value = object[propertyName]
		box.Text = ToString(value, propertyType)
	end
	
	if not readOnly then
		box.FocusLost:connect(function(enterPressed)
			Set(object, propertyData, ToValue(box.Text,propertyType))
			update()
		end)
	end
	
	update()
	
	object.Changed:connect(function(property)
		if (property == propertyName) then
			update()
		end
	end)
	
	return box
end

Controls["bool"] = function(object, propertyData, readOnly)
	local propertyName = propertyData["Name"]
	local checked = object[propertyName]
	
	local checkbox, setValue = CreateCheckbox(checked, readOnly, function(value)
		Set(object, propertyData, not checked)
	end)
	checkbox.Position = UDim2.new(0, Styles.Margin, 0, Styles.Margin)
	
	setValue(checked)
	
	local function update()
		checked = object[propertyName]
		setValue(checked)
	end
	
	object.Changed:connect(function(property)
		if (property == propertyName) then
			update()
		end
	end)
	
	if object:IsA("BoolValue") then
		object.Changed:connect(function(val)
			update()
		end)
	end
	
	update()
	
	return checkbox
end

Controls["BrickColor"] = function(object, propertyData, readOnly)
	local propertyName = propertyData["Name"]

	local frame,label,brickColorBox = CreateBrickColor(readOnly, function(brickColor)
		Set(object, propertyData, brickColor)
	end)
	
	local function update()
		local value = object[propertyName]
		brickColorBox.BackgroundColor3 = value.Color
		label.Text = tostring(value)
	end
	
	update()
	
	object.Changed:connect(function(property)
		if (property == propertyName) then
			update()
		end
	end)
	
	return frame
end

Controls["Color3"] = function(object, propertyData, readOnly)
	local propertyName = propertyData["Name"]

	local frame,textBox,colorBox = CreateColor3Control(readOnly)
	
	textBox.FocusLost:connect(function(enterPressed)
		Set(object, propertyData, ToValue(textBox.Text,"Color3"))
		local value = object[propertyName]
		colorBox.BackgroundColor3 = value
		textBox.Text = ToString(value, "Color3")
	end)
			
	local function update()
		local value = object[propertyName]
		colorBox.BackgroundColor3 = value
		textBox.Text = ToString(value, "Color3")
	end
	
	update()
	
	object.Changed:connect(function(property)
		if (property == propertyName) then
			update()
		end
	end)
	
	return frame
end

Controls["Enum"] = function(object, propertyData, readOnly)
	local propertyName = propertyData["Name"]
	local propertyType = propertyData["ValueType"]
	
	local enumName = object[propertyName].Name
	
	local enumNames = {}
	for _,enum in pairs(Enum[tostring(propertyType)]:GetEnumItems()) do
		table.insert(enumNames, enum.Name)
	end
	
	local dropdown, propertyLabel = CreateDropDown(enumNames, enumName, readOnly, function(value)
		Set(object, propertyData, value)
	end)
	--dropdown.Parent = frame
	
	local function update()
		local value = object[propertyName].Name
		propertyLabel.Text = tostring(value)
	end
	
	update()
	
	object.Changed:connect(function(property)
		if (property == propertyName) then
			update()
		end
	end)
	
	return dropdown
end

Controls["Object"] = function(object, propertyData, readOnly)
	local propertyName = propertyData["Name"]
	local propertyType = propertyData["ValueType"]
	
	local box = CreateObject(readOnly,function()end)
	box.Size = UDim2.new(1, -2 * Styles.Margin, 1, 0)
	box.Position = UDim2.new(0, Styles.Margin, 0, 0)

	local function update()
		if AwaitingObjectObj == object then
			if AwaitingObjectValue == true then
				box.Text = "Select an Object"
				return
			end
		end
		local value = object[propertyName]
		box.Text = ToString(value, propertyType)
	end
	
	if not readOnly then
		box.MouseButton1Click:connect(function()
			if AwaitingObjectValue then
				AwaitingObjectValue = false
				update()
				return
			end
			AwaitingObjectValue = true
			AwaitingObjectObj = object
			AwaitingObjectProp = propertyData
			box.Text = "Select an Object"
		end)
		
		box.Cancel.Visible = true
		box.Cancel.MouseButton1Click:connect(function()
			object[propertyName] = nil
		end)
	end
	
	update()
	
	object.Changed:connect(function(property)
		if (property == propertyName) then
			update()
		end
	end)
	
	if object:IsA("ObjectValue") then
		object.Changed:connect(function(val)
			update()
		end)
	end
	
	return box
end

function GetControl(object, propertyData, readOnly)
	local propertyType = propertyData["ValueType"]
	local control = nil
	
	if Controls[propertyType] then
		control = Controls[propertyType](object, propertyData, readOnly)
	elseif RbxApi.IsEnum(propertyType) then
		control = Controls["Enum"](object, propertyData, readOnly)
	elseif RbxApi.Classes[propertyType] then
        control = Controls["Object"](object, propertyData, readOnly)
	else
		control = Controls["default"](object, propertyData, readOnly)
	end
	return control
end
-- Permissions

function CanEditObject(object)
	local player = Players.LocalPlayer
	local character = player.Character
	return Permissions.CanEdit
end

function CanEditProperty(object,propertyData)
	local tags = propertyData["tags"]
	for _,name in pairs(tags) do
		if name == "readonly" then
			return false
		end
	end
	return CanEditObject(object)
end

--RbxApi
local function PropertyIsHidden(propertyData)
	local tags = propertyData["tags"]
	for _,name in pairs(tags) do
		if name == "deprecated"
			or name == "hidden"
			or name == "writeonly" then
			return true
		end
	end
	return false
end

function Set(object, propertyData, value)
	local propertyName = propertyData["Name"]
	local propertyType = propertyData["ValueType"]
	
	if value == nil then return end
	
	for i,v in pairs(GetSelection()) do
		if CanEditProperty(v,propertyData) then
			pcall(function()
				--print("Setting " .. propertyName .. " to " .. tostring(value))
				v[propertyName] = value
			end)
		end
	end
end

function CreateRow(object, propertyData, isAlternateRow)
	local propertyName = propertyData["Name"]
	local propertyType = propertyData["ValueType"]
	local propertyValue = object[propertyName]
	--rowValue, rowValueType, isAlternate
	local backColor = Row.BackgroundColor;
	if (isAlternateRow) then
		backColor = Row.BackgroundColorAlternate
	end
	
	local readOnly = not CanEditProperty(object, propertyData)
	--if propertyType == "Instance" or propertyName == "Parent" then readOnly = true end

	local rowFrame = Instance.new("Frame")
	rowFrame.Size = UDim2.new(1,0,0,Row.Height)
	rowFrame.BackgroundTransparency = 1
	rowFrame.Name = 'Row'

	local propertyLabelFrame = CreateCell()
	propertyLabelFrame.Parent = rowFrame
	propertyLabelFrame.ClipsDescendants = true
	
	local propertyLabel = CreateLabel(readOnly)
	propertyLabel.Text = propertyName
	propertyLabel.Size = UDim2.new(1, -1 * Row.TitleMarginLeft, 1, 0)
	propertyLabel.Position = UDim2.new(0, Row.TitleMarginLeft, 0, 0)
	propertyLabel.Parent = propertyLabelFrame

	local propertyValueFrame = CreateCell()
	propertyValueFrame.Size = UDim2.new(0.5, -1, 1, 0)
	propertyValueFrame.Position = UDim2.new(0.5, 0, 0, 0)
	propertyValueFrame.Parent = rowFrame

	local control = GetControl(object, propertyData, readOnly)
	control.Parent = propertyValueFrame

	rowFrame.MouseEnter:connect(function()
		propertyLabelFrame.BackgroundColor3 = Row.BackgroundColorMouseover
		propertyValueFrame.BackgroundColor3 = Row.BackgroundColorMouseover
	end)
	rowFrame.MouseLeave:connect(function()
		propertyLabelFrame.BackgroundColor3 = backColor
		propertyValueFrame.BackgroundColor3 = backColor
	end)
	
	propertyLabelFrame.BackgroundColor3 = backColor
	propertyValueFrame.BackgroundColor3 = backColor
	
	return rowFrame
end

function ClearPropertiesList()
	for _,instance in pairs(ContentFrame:GetChildren()) do
		instance:Destroy()
	end
end

local selection = Gui:FindFirstChild("Selection", 1)
print(selection)

function displayProperties(props)
	for i,v in pairs(props) do
		pcall(function()
			local a = CreateRow(v.object, v.propertyData, ((numRows % 2) == 0))
			a.Position = UDim2.new(0,0,0,numRows*Row.Height)
			a.Parent = ContentFrame
			numRows = numRows + 1
		end)
	end
end

function checkForDupe(prop,props)
	for i,v in pairs(props) do
		if v.propertyData.Name == prop.Name and v.propertyData.ValueType == prop.ValueType then
			return true
		end
	end
	return false
end

function sortProps(t)
	table.sort(t, 
		function(x,y) return x.propertyData.Name < y.propertyData.Name
	end)
end

function showProperties(obj)
	ClearPropertiesList()
	if obj == nil then return end
	local propHolder = {}
	local foundProps = {}
	numRows = 0
	for _,nextObj in pairs(obj) do
		if not foundProps[nextObj.className] then
			foundProps[nextObj.className] = true
			for i,v in pairs(RbxApi.GetProperties(nextObj.className)) do
				local suc, err = pcall(function()
					if not (PropertyIsHidden(v)) and not checkForDupe(v,propHolder) then
						if string.find(string.lower(v.Name),string.lower(propertiesSearch.Text)) or not searchingProperties() then
							table.insert(propHolder,{propertyData = v, object = nextObj})
						end
					end
				end)
				--[[if not suc then 
					warn("Problem getting the value of property " .. v.Name .. " | " .. err)
				end	--]]
			end
		end
	end
	sortProps(propHolder)
	displayProperties(propHolder)
	ContentFrame.Size = UDim2.new(1, 0, 0, numRows * Row.Height)
	scrollBar.ScrollIndex = 0
	scrollBar.TotalSpace = numRows * Row.Height
	scrollBar.Update()
end

----------------------------------------------------------------
-----------------------SCROLLBAR STUFF--------------------------
----------------------------------------------------------------
----------------------------------------------------------------
local ScrollBarWidth = 16

local ScrollStyles = {
	Background      = Color3.new(233/255, 233/255, 233/255);
	Border          = Color3.new(149/255, 149/255, 149/255);
	Selected        = Color3.new( 63/255, 119/255, 189/255);
	BorderSelected  = Color3.new( 55/255, 106/255, 167/255);
	Text            = Color3.new(  0/255,   0/255,   0/255);
	TextDisabled    = Color3.new(128/255, 128/255, 128/255);
	TextSelected    = Color3.new(255/255, 255/255, 255/255);
	Button          = Color3.new(221/255, 221/255, 221/255);
	ButtonBorder    = Color3.new(149/255, 149/255, 149/255);
	ButtonSelected  = Color3.new(255/255,   0/255,   0/255);
	Field           = Color3.new(255/255, 255/255, 255/255);
	FieldBorder     = Color3.new(191/255, 191/255, 191/255);
	TitleBackground = Color3.new(178/255, 178/255, 178/255);
}
do
	local ZIndexLock = {}
	function SetZIndex(object,z)
		if not ZIndexLock[object] then
			ZIndexLock[object] = true
			if object:IsA'GuiObject' then
				object.ZIndex = z
			end
			local children = object:GetChildren()
			for i = 1,#children do
				SetZIndex(children[i],z)
			end
			ZIndexLock[object] = nil
		end
	end
end
function SetZIndexOnChanged(object)
	return object.Changed:connect(function(p)
		if p == "ZIndex" then
			SetZIndex(object,object.ZIndex)
		end
	end)
end
function Create(ty,data)
	local obj
	if type(ty) == 'string' then
		obj = Instance.new(ty)
	else
		obj = ty
	end
	for k, v in pairs(data) do
		if type(k) == 'number' then
			v.Parent = obj
		else
			obj[k] = v
		end
	end
	return obj
end
-- returns the ascendant ScreenGui of an object
function GetScreen(screen)
	if screen == nil then return nil end
	while not screen:IsA("ScreenGui") do
		screen = screen.Parent
		if screen == nil then return nil end
	end
	return screen
end
-- AutoButtonColor doesn't always reset properly
function ResetButtonColor(button)
	local active = button.Active
	button.Active = not active
	button.Active = active
end

function ArrowGraphic(size,dir,scaled,template)
	local Frame = Create('Frame',{
		Name = "Arrow Graphic";
		BorderSizePixel = 0;
		Size = UDim2.new(0,size,0,size);
		Transparency = 1;
	})
	if not template then
		template = Instance.new("Frame")
		template.BorderSizePixel = 0
	end

	local transform
	if dir == nil or dir == 'Up' then
		function transform(p,s) return p,s end
	elseif dir == 'Down' then
		function transform(p,s) return UDim2.new(0,p.X.Offset,0,size-p.Y.Offset-1),s end
	elseif dir == 'Left' then
		function transform(p,s) return UDim2.new(0,p.Y.Offset,0,p.X.Offset),UDim2.new(0,s.Y.Offset,0,s.X.Offset) end
	elseif dir == 'Right' then
		function transform(p,s) return UDim2.new(0,size-p.Y.Offset-1,0,p.X.Offset),UDim2.new(0,s.Y.Offset,0,s.X.Offset) end
	end

	local scale
	if scaled then
		function scale(p,s) return UDim2.new(p.X.Offset/size,0,p.Y.Offset/size,0),UDim2.new(s.X.Offset/size,0,s.Y.Offset/size,0) end
	else
		function scale(p,s) return p,s end
	end

	local o = math.floor(size/4)
	if size%2 == 0 then
		local n = size/2-1
		for i = 0,n do
			local t = template:Clone()
			local p,s = scale(transform(
				UDim2.new(0,n-i,0,o+i),
				UDim2.new(0,(i+1)*2,0,1)
			))
			t.Position = p
			t.Size = s
			t.Parent = Frame
		end
	else
		local n = (size-1)/2
		for i = 0,n do
			local t = template:Clone()
			local p,s = scale(transform(
				UDim2.new(0,n-i,0,o+i),
				UDim2.new(0,i*2+1,0,1)
			))
			t.Position = p
			t.Size = s
			t.Parent = Frame
		end
	end
	if size%4 > 1 then
		local t = template:Clone()
		local p,s = scale(transform(
			UDim2.new(0,0,0,size-o-1),
			UDim2.new(0,size,0,1)
		))
		t.Position = p
		t.Size = s
		t.Parent = Frame
	end
	return Frame
end

function GripGraphic(size,dir,spacing,scaled,template)
	local Frame = Create('Frame',{
		Name = "Grip Graphic";
		BorderSizePixel = 0;
		Size = UDim2.new(0,size.x,0,size.y);
		Transparency = 1;
	})
	if not template then
		template = Instance.new("Frame")
		template.BorderSizePixel = 0
	end

	spacing = spacing or 2

	local scale
	if scaled then
		function scale(p) return UDim2.new(p.X.Offset/size.x,0,p.Y.Offset/size.y,0) end
	else
		function scale(p) return p end
	end

	if dir == 'Vertical' then
		for i=0,size.x-1,spacing do
			local t = template:Clone()
			t.Size = scale(UDim2.new(0,1,0,size.y))
			t.Position = scale(UDim2.new(0,i,0,0))
			t.Parent = Frame
		end
	elseif dir == nil or dir == 'Horizontal' then
		for i=0,size.y-1,spacing do
			local t = template:Clone()
			t.Size = scale(UDim2.new(0,size.x,0,1))
			t.Position = scale(UDim2.new(0,0,0,i))
			t.Parent = Frame
		end
	end

	return Frame
end

do
	local mt = {
		__index = {
			GetScrollPercent = function(self)
				return self.ScrollIndex/(self.TotalSpace-self.VisibleSpace)
			end;
			CanScrollDown = function(self)
				return self.ScrollIndex + self.VisibleSpace < self.TotalSpace
			end;
			CanScrollUp = function(self)
				return self.ScrollIndex > 0
			end;
			ScrollDown = function(self)
				self.ScrollIndex = self.ScrollIndex + self.PageIncrement
				self:Update()
			end;
			ScrollUp = function(self)
				self.ScrollIndex = self.ScrollIndex - self.PageIncrement
				self:Update()
			end;
			ScrollTo = function(self,index)
				self.ScrollIndex = index
				self:Update()
			end;
			SetScrollPercent = function(self,percent)
				self.ScrollIndex = math.floor((self.TotalSpace - self.VisibleSpace)*percent + 0.5)
				self:Update()
			end;
		};
	}
	mt.__index.CanScrollRight = mt.__index.CanScrollDown
	mt.__index.CanScrollLeft = mt.__index.CanScrollUp
	mt.__index.ScrollLeft = mt.__index.ScrollUp
	mt.__index.ScrollRight = mt.__index.ScrollDown

	function ScrollBar(horizontal)
		-- create row scroll bar
		local ScrollFrame = Create('Frame',{
			Name = "ScrollFrame";
			Position = horizontal and UDim2.new(0,0,1,-ScrollBarWidth) or UDim2.new(1,-ScrollBarWidth,0,0);
			Size = horizontal and UDim2.new(1,0,0,ScrollBarWidth) or UDim2.new(0,ScrollBarWidth,1,0);
			BackgroundTransparency = 1;
			Create('ImageButton',{
				Name = "ScrollDown";
				Position = horizontal and UDim2.new(1,-ScrollBarWidth,0,0) or UDim2.new(0,0,1,-ScrollBarWidth);
				Size = UDim2.new(0, ScrollBarWidth, 0, ScrollBarWidth);
				BackgroundColor3 = ScrollStyles.Button;
				BorderColor3 = ScrollStyles.Border;
				--BorderSizePixel = 0;
			});
			Create('ImageButton',{
				Name = "ScrollUp";
				Size = UDim2.new(0, ScrollBarWidth, 0, ScrollBarWidth);
				BackgroundColor3 = ScrollStyles.Button;
				BorderColor3 = ScrollStyles.Border;
				--BorderSizePixel = 0;
			});
			Create('ImageButton',{
				Name = "ScrollBar";
				Size = horizontal and UDim2.new(1,-ScrollBarWidth*2,1,0) or UDim2.new(1,0,1,-ScrollBarWidth*2);
				Position = horizontal and UDim2.new(0,ScrollBarWidth,0,0) or UDim2.new(0,0,0,ScrollBarWidth);
				AutoButtonColor = false;
				BackgroundColor3 = Color3.new(0.94902, 0.94902, 0.94902);
				BorderColor3 = ScrollStyles.Border;
				--BorderSizePixel = 0;
				Create('ImageButton',{
					Name = "ScrollThumb";
					AutoButtonColor = false;
					Size = UDim2.new(0, ScrollBarWidth, 0, ScrollBarWidth);
					BackgroundColor3 = ScrollStyles.Button;
					BorderColor3 = ScrollStyles.Border;
					--BorderSizePixel = 0;
				});
			});
		})

		local graphicTemplate = Create('Frame',{
			Name="Graphic";
			BorderSizePixel = 0;
			BackgroundColor3 = ScrollStyles.Border;
		})
		local graphicSize = ScrollBarWidth/2

		local ScrollDownFrame = ScrollFrame.ScrollDown
			local ScrollDownGraphic = ArrowGraphic(graphicSize,horizontal and 'Right' or 'Down',true,graphicTemplate)
			ScrollDownGraphic.Position = UDim2.new(0.5,-graphicSize/2,0.5,-graphicSize/2)
			ScrollDownGraphic.Parent = ScrollDownFrame
		local ScrollUpFrame = ScrollFrame.ScrollUp
			local ScrollUpGraphic = ArrowGraphic(graphicSize,horizontal and 'Left' or 'Up',true,graphicTemplate)
			ScrollUpGraphic.Position = UDim2.new(0.5,-graphicSize/2,0.5,-graphicSize/2)
			ScrollUpGraphic.Parent = ScrollUpFrame
		local ScrollBarFrame = ScrollFrame.ScrollBar
		local ScrollThumbFrame = ScrollBarFrame.ScrollThumb
		do
			local size = ScrollBarWidth*3/8
			local Decal = GripGraphic(Vector2.new(size,size),horizontal and 'Vertical' or 'Horizontal',2,graphicTemplate)
			Decal.Position = UDim2.new(0.5,-size/2,0.5,-size/2)
			Decal.Parent = ScrollThumbFrame
		end

		local MouseDrag = Create('ImageButton',{
			Name = "MouseDrag";
			Position = UDim2.new(-0.25,0,-0.25,0);
			Size = UDim2.new(1.5,0,1.5,0);
			Transparency = 1;
			AutoButtonColor = false;
			Active = true;
			ZIndex = 10;
		})

		local Class = setmetatable({
			GUI = ScrollFrame;
			ScrollIndex = 0;
			VisibleSpace = 0;
			TotalSpace = 0;
			PageIncrement = 1;
		},mt)

		local UpdateScrollThumb
		if horizontal then
			function UpdateScrollThumb()
				ScrollThumbFrame.Size = UDim2.new(Class.VisibleSpace/Class.TotalSpace,0,0,ScrollBarWidth)
				if ScrollThumbFrame.AbsoluteSize.x < ScrollBarWidth then
					ScrollThumbFrame.Size = UDim2.new(0,ScrollBarWidth,0,ScrollBarWidth)
				end
				local barSize = ScrollBarFrame.AbsoluteSize.x
				ScrollThumbFrame.Position = UDim2.new(Class:GetScrollPercent()*(barSize - ScrollThumbFrame.AbsoluteSize.x)/barSize,0,0,0)
			end
		else
			function UpdateScrollThumb()
				ScrollThumbFrame.Size = UDim2.new(0,ScrollBarWidth,Class.VisibleSpace/Class.TotalSpace,0)
				if ScrollThumbFrame.AbsoluteSize.y < ScrollBarWidth then
					ScrollThumbFrame.Size = UDim2.new(0,ScrollBarWidth,0,ScrollBarWidth)
				end
				local barSize = ScrollBarFrame.AbsoluteSize.y
				ScrollThumbFrame.Position = UDim2.new(0,0,Class:GetScrollPercent()*(barSize - ScrollThumbFrame.AbsoluteSize.y)/barSize,0)
			end
		end

		local lastDown
		local lastUp
		local scrollStyle = {BackgroundColor3=ScrollStyles.Border,BackgroundTransparency=0}
		local scrollStyle_ds = {BackgroundColor3=ScrollStyles.Border,BackgroundTransparency=0.7}

		local function Update()
			local t = Class.TotalSpace
			local v = Class.VisibleSpace
			local s = Class.ScrollIndex
			if v <= t then
				if s > 0 then
					if s + v > t then
						Class.ScrollIndex = t - v
					end
				else
					Class.ScrollIndex = 0
				end
			else
				Class.ScrollIndex = 0
			end

			if Class.UpdateCallback then
				if Class.UpdateCallback(Class) == false then
					return
				end
			end

			local down = Class:CanScrollDown()
			local up = Class:CanScrollUp()
			if down ~= lastDown then
				lastDown = down
				ScrollDownFrame.Active = down
				ScrollDownFrame.AutoButtonColor = down
				local children = ScrollDownGraphic:GetChildren()
				local style = down and scrollStyle or scrollStyle_ds
				for i = 1,#children do
					Create(children[i],style)
				end
			end
			if up ~= lastUp then
				lastUp = up
				ScrollUpFrame.Active = up
				ScrollUpFrame.AutoButtonColor = up
				local children = ScrollUpGraphic:GetChildren()
				local style = up and scrollStyle or scrollStyle_ds
				for i = 1,#children do
					Create(children[i],style)
				end
			end
			ScrollThumbFrame.Visible = down or up
			UpdateScrollThumb()
		end
		Class.Update = Update

		SetZIndexOnChanged(ScrollFrame)

		local scrollEventID = 0
		ScrollDownFrame.MouseButton1Down:connect(function()
			scrollEventID = tick()
			local current = scrollEventID
			local up_con
			up_con = MouseDrag.MouseButton1Up:connect(function()
				scrollEventID = tick()
				MouseDrag.Parent = nil
				ResetButtonColor(ScrollDownFrame)
				up_con:disconnect(); drag = nil
			end)
			MouseDrag.Parent = GetScreen(ScrollFrame)
			Class:ScrollDown()
			wait(0.2) -- delay before auto scroll
			while scrollEventID == current do
				Class:ScrollDown()
				if not Class:CanScrollDown() then break end
				wait()
			end
		end)

		ScrollDownFrame.MouseButton1Up:connect(function()
			scrollEventID = tick()
		end)

		ScrollUpFrame.MouseButton1Down:connect(function()
			scrollEventID = tick()
			local current = scrollEventID
			local up_con
			up_con = MouseDrag.MouseButton1Up:connect(function()
				scrollEventID = tick()
				MouseDrag.Parent = nil
				ResetButtonColor(ScrollUpFrame)
				up_con:disconnect(); drag = nil
			end)
			MouseDrag.Parent = GetScreen(ScrollFrame)
			Class:ScrollUp()
			wait(0.2)
			while scrollEventID == current do
				Class:ScrollUp()
				if not Class:CanScrollUp() then break end
				wait()
			end
		end)

		ScrollUpFrame.MouseButton1Up:connect(function()
			scrollEventID = tick()
		end)

		if horizontal then
			ScrollBarFrame.MouseButton1Down:connect(function(x,y)
				scrollEventID = tick()
				local current = scrollEventID
				local up_con
				up_con = MouseDrag.MouseButton1Up:connect(function()
					scrollEventID = tick()
					MouseDrag.Parent = nil
					ResetButtonColor(ScrollUpFrame)
					up_con:disconnect(); drag = nil
				end)
				MouseDrag.Parent = GetScreen(ScrollFrame)
				if x > ScrollThumbFrame.AbsolutePosition.x then
					Class:ScrollTo(Class.ScrollIndex + Class.VisibleSpace)
					wait(0.2)
					while scrollEventID == current do
						if x < ScrollThumbFrame.AbsolutePosition.x + ScrollThumbFrame.AbsoluteSize.x then break end
						Class:ScrollTo(Class.ScrollIndex + Class.VisibleSpace)
						wait()
					end
				else
					Class:ScrollTo(Class.ScrollIndex - Class.VisibleSpace)
					wait(0.2)
					while scrollEventID == current do
						if x > ScrollThumbFrame.AbsolutePosition.x then break end
						Class:ScrollTo(Class.ScrollIndex - Class.VisibleSpace)
						wait()
					end
				end
			end)
		else
			ScrollBarFrame.MouseButton1Down:connect(function(x,y)
				scrollEventID = tick()
				local current = scrollEventID
				local up_con
				up_con = MouseDrag.MouseButton1Up:connect(function()
					scrollEventID = tick()
					MouseDrag.Parent = nil
					ResetButtonColor(ScrollUpFrame)
					up_con:disconnect(); drag = nil
				end)
				MouseDrag.Parent = GetScreen(ScrollFrame)
				if y > ScrollThumbFrame.AbsolutePosition.y then
					Class:ScrollTo(Class.ScrollIndex + Class.VisibleSpace)
					wait(0.2)
					while scrollEventID == current do
						if y < ScrollThumbFrame.AbsolutePosition.y + ScrollThumbFrame.AbsoluteSize.y then break end
						Class:ScrollTo(Class.ScrollIndex + Class.VisibleSpace)
						wait()
					end
				else
					Class:ScrollTo(Class.ScrollIndex - Class.VisibleSpace)
					wait(0.2)
					while scrollEventID == current do
						if y > ScrollThumbFrame.AbsolutePosition.y then break end
						Class:ScrollTo(Class.ScrollIndex - Class.VisibleSpace)
						wait()
					end
				end
			end)
		end

		if horizontal then
			ScrollThumbFrame.MouseButton1Down:connect(function(x,y)
				scrollEventID = tick()
				local mouse_offset = x - ScrollThumbFrame.AbsolutePosition.x
				local drag_con
				local up_con
				drag_con = MouseDrag.MouseMoved:connect(function(x,y)
					local bar_abs_pos = ScrollBarFrame.AbsolutePosition.x
					local bar_drag = ScrollBarFrame.AbsoluteSize.x - ScrollThumbFrame.AbsoluteSize.x
					local bar_abs_one = bar_abs_pos + bar_drag
					x = x - mouse_offset
					x = x < bar_abs_pos and bar_abs_pos or x > bar_abs_one and bar_abs_one or x
					x = x - bar_abs_pos
					Class:SetScrollPercent(x/(bar_drag))
				end)
				up_con = MouseDrag.MouseButton1Up:connect(function()
					scrollEventID = tick()
					MouseDrag.Parent = nil
					ResetButtonColor(ScrollThumbFrame)
					drag_con:disconnect(); drag_con = nil
					up_con:disconnect(); drag = nil
				end)
				MouseDrag.Parent = GetScreen(ScrollFrame)
			end)
		else
			ScrollThumbFrame.MouseButton1Down:connect(function(x,y)
				scrollEventID = tick()
				local mouse_offset = y - ScrollThumbFrame.AbsolutePosition.y
				local drag_con
				local up_con
				drag_con = MouseDrag.MouseMoved:connect(function(x,y)
					local bar_abs_pos = ScrollBarFrame.AbsolutePosition.y
					local bar_drag = ScrollBarFrame.AbsoluteSize.y - ScrollThumbFrame.AbsoluteSize.y
					local bar_abs_one = bar_abs_pos + bar_drag
					y = y - mouse_offset
					y = y < bar_abs_pos and bar_abs_pos or y > bar_abs_one and bar_abs_one or y
					y = y - bar_abs_pos
					Class:SetScrollPercent(y/(bar_drag))
				end)
				up_con = MouseDrag.MouseButton1Up:connect(function()
					scrollEventID = tick()
					MouseDrag.Parent = nil
					ResetButtonColor(ScrollThumbFrame)
					drag_con:disconnect(); drag_con = nil
					up_con:disconnect(); drag = nil
				end)
				MouseDrag.Parent = GetScreen(ScrollFrame)
			end)
		end

		function Class:Destroy()
			ScrollFrame:Destroy()
			MouseDrag:Destroy()
			for k in pairs(Class) do
				Class[k] = nil
			end
			setmetatable(Class,nil)
		end

		Update()

		return Class
	end
end

----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(1, -1 * ScrollBarWidth, 1, 0)
MainFrame.Position = UDim2.new(0, 0, 0, 0)
MainFrame.BackgroundTransparency = 1
MainFrame.ClipsDescendants = true
MainFrame.Parent = PropertiesFrame

ContentFrame = Instance.new("Frame")
ContentFrame.Name = "ContentFrame"
ContentFrame.Size = UDim2.new(1, 0, 0, 0)
ContentFrame.BackgroundTransparency = 1
ContentFrame.Parent = MainFrame

scrollBar = ScrollBar(false)
scrollBar.PageIncrement = 1
Create(scrollBar.GUI,{
	Position = UDim2.new(1,-ScrollBarWidth,0,0);
	Size = UDim2.new(0,ScrollBarWidth,1,0);
	Parent = PropertiesFrame;
})

scrollBarH = ScrollBar(true)
scrollBarH.PageIncrement = ScrollBarWidth
Create(scrollBarH.GUI,{
	Position = UDim2.new(0,0,1,-ScrollBarWidth);
	Size = UDim2.new(1,-ScrollBarWidth,0,ScrollBarWidth);
	Visible = false;
	Parent = PropertiesFrame;
})

do
	local listEntries = {}
	local nameConnLookup = {}
	
	function scrollBar.UpdateCallback(self)
		scrollBar.TotalSpace = ContentFrame.AbsoluteSize.Y
		scrollBar.VisibleSpace = MainFrame.AbsoluteSize.Y
		ContentFrame.Position = UDim2.new(ContentFrame.Position.X.Scale,ContentFrame.Position.X.Offset,0,-1*scrollBar.ScrollIndex)
	end

	function scrollBarH.UpdateCallback(self)
		
	end

	MainFrame.Changed:connect(function(p)
		if p == 'AbsoluteSize' then
			scrollBarH.VisibleSpace = math.ceil(MainFrame.AbsoluteSize.x)
			scrollBarH:Update()
			scrollBar.VisibleSpace = math.ceil(MainFrame.AbsoluteSize.y)
			scrollBar:Update()
		end
	end)

	local wheelAmount = Row.Height
	PropertiesFrame.MouseWheelForward:connect(function()
		if scrollBar.VisibleSpace - 1 > wheelAmount then
			scrollBar:ScrollTo(scrollBar.ScrollIndex - wheelAmount)
		else
			scrollBar:ScrollTo(scrollBar.ScrollIndex - scrollBar.VisibleSpace)
		end
	end)
	PropertiesFrame.MouseWheelBackward:connect(function()
		if scrollBar.VisibleSpace - 1 > wheelAmount then
			scrollBar:ScrollTo(scrollBar.ScrollIndex + wheelAmount)
		else
			scrollBar:ScrollTo(scrollBar.ScrollIndex + scrollBar.VisibleSpace)
		end
	end)
end

scrollBar.VisibleSpace = math.ceil(MainFrame.AbsoluteSize.y)
scrollBar:Update()

showProperties(GetSelection())

bindSelectionChanged.Event:connect(function()
	showProperties(GetSelection())
end)

bindSetAwait.Event:connect(function(obj)
	if AwaitingObjectValue then
		AwaitingObjectValue = false
		local mySel = obj
		if mySel then
			pcall(function()
				Set(AwaitingObjectObj, AwaitingObjectProp, mySel)
			end)
		end
	end
end)

propertiesSearch.Changed:connect(function(prop)
	if prop == "Text" then
		showProperties(GetSelection())
	end
end)

bindGetApi.OnInvoke = function()
	return RbxApi
end

bindGetAwait.OnInvoke = function()
	return AwaitingObjectValue
end