-- initial states
local Option = {
	-- can modify object parents in the hierarchy
	Modifiable = false;
	-- can select objects
	Selectable = true;
}

-- MERELY

Option.Modifiable = true

-- END MERELY

-- general size of GUI objects, in pixels
local GUI_SIZE = 16
-- padding between items within each entry
local ENTRY_PADDING = 1
-- padding between each entry
local ENTRY_MARGIN = 1

local explorerPanel = script.Parent
local Input = game:GetService("UserInputService")
local HoldingCtrl = false
local HoldingShift = false

local addObject
local removeObject
local gameChildren = {}

table.insert(gameChildren, game:GetService("Workspace"))
table.insert(gameChildren, game:GetService("Players"))
table.insert(gameChildren, game:GetService("Lighting"))
table.insert(gameChildren, game:GetService("ReplicatedFirst"))
table.insert(gameChildren, game:GetService("ReplicatedStorage"))

pcall(function()
	table.insert(gameChildren, game:GetService("CoreGui"))
end)

table.insert(gameChildren, game:GetService("StarterGui"))
table.insert(gameChildren, game:GetService("StarterPack"))
table.insert(gameChildren, game:GetService("StarterPlayer"))
table.insert(gameChildren, game:GetService("SoundService"))
table.insert(gameChildren, game:GetService("Chat"))
table.insert(gameChildren, game:GetService("LocalizationService"))
table.insert(gameChildren, game:GetService("TestService"))

local childrenGame = {}

childrenGame[game:GetService("Workspace")] = true
childrenGame[game:GetService("Players")] = true
childrenGame[game:GetService("Lighting")] = true
childrenGame[game:GetService("ReplicatedFirst")] = true
childrenGame[game:GetService("ReplicatedStorage")] = true

pcall(function()
	childrenGame[game:GetService("CoreGui")] = true
end)

childrenGame[game:GetService("StarterGui")] = true
childrenGame[game:GetService("StarterPack")] = true
childrenGame[game:GetService("StarterPlayer")] = true
childrenGame[game:GetService("SoundService")] = true
childrenGame[game:GetService("Chat")] = true
childrenGame[game:GetService("LocalizationService")] = true
childrenGame[game:GetService("TestService")] = true

local MuteHiddenItems = true

local DexOutput = Instance.new("Folder")
DexOutput.Name = "Output"
local DexOutputMain = Instance.new("ScreenGui", DexOutput)
DexOutputMain.Name = "Dex Output"

local HiddenEntries = Instance.new("Folder")
local HiddenGame = Instance.new("Folder")
HiddenEntries.Name = "HiddenEntriesParent"
local HiddenEntriesMain = Instance.new("TextButton", HiddenEntries)
Instance.new("Folder", HiddenEntriesMain)

local function NameHiddenEntries()
	if MuteHiddenItems then
		HiddenEntriesMain.Name = "Expand to view (" .. (#game:children() - #gameChildren) .. ") hidden items"
	else
		HiddenEntriesMain.Name = "Collapse to hide (" .. (#game:children() - #gameChildren) .. ") more items"
	end
end

NameHiddenEntries()

print = function(...)
	local Obj = Instance.new("Dialog")
	Obj.Parent = DexOutputMain
	Obj.Name = ""
	for i,v in pairs({...}) do
		Obj.Name = Obj.Name .. tostring(v) .. " "
	end
end

explorerPanel:WaitForChild("GetPrint").OnInvoke = function()
	return print
end

--[[

# Explorer Panel

A GUI panel that displays the game hierarchy.


## Selection Bindables

- `Function GetSelection ( )`

	Returns an array of objects representing the objects currently
	selected in the panel.

- `Function SetSelection ( Objects selection )`

	Sets the objects that are selected in the panel. `selection` is an array
	of objects.

- `Event SelectionChanged ( )`


	Fired after the selection changes.


## Option Bindables

- `Function GetOption ( string optionName )`

	If `optionName` is given, returns the value of that option. Otherwise,
	returns a table of options and their current values.

- `Function SetOption ( string optionName, bool value )`

	Sets `optionName` to `value`.

	Options:

	- Modifiable

		Whether objects can be modified by the panel.

		Note that modifying objects depends on being able to select them. If
		Selectable is false, then Actions will not be available. Reparenting
		is still possible, but only for the dragged object.

	- Selectable

		Whether objects can be selected.

		If Modifiable is false, then left-clicking will perform a drag
		selection.

## Updates

- 2013-09-18
	- Fixed explorer icons to match studio explorer.

- 2013-09-14
	- Added GetOption and SetOption bindables.
		- Option: Modifiable; sets whether objects can be modified by the panel.
		- Option: Selectable; sets whether objects can be selected.
	- Slight modification to left-click selection behavior.
	- Improved layout and scaling.

- 2013-09-13
	- Added drag to reparent objects.
		- Left-click to select/deselect object.
		- Left-click and drag unselected object to reparent single object.
		- Left-click and drag selected object to move reparent entire selection.
		- Right-click while dragging to cancel.

- 2013-09-11
	- Added explorer panel header with actions.
		- Added Cut action.
		- Added Copy action.
		- Added Paste action.
		- Added Delete action.
	- Added drag selection.
		- Left-click: Add to selection on drag.
		- Right-click: Add to or remove from selection on drag.
	- Ensured SelectionChanged fires only when the selection actually changes.
	- Added documentation and change log.
	- Fixed thread issue.

- 2013-09-09
	- Added basic multi-selection.
		- Left-click to set selection.
		- Right-click to add to or remove from selection.
	- Removed "Selection" ObjectValue.
		- Added GetSelection BindableFunction.
		- Added SetSelection BindableFunction.
		- Added SelectionChanged BindableEvent.
	- Changed font to SourceSans.

- 2013-08-31
	- Improved GUI sizing based off of `GUI_SIZE` constant.
	- Automatic font size detection.

- 2013-08-27
	- Initial explorer panel.


## Todo

- Sorting
	- by ExplorerOrder
	- by children
	- by name
- Drag objects to reparent

]]
		

local function dexWriteFile(dest, cont, name, filter, ext)
	if writefileas then
		writefileas(cont, name, filter, ext)
		return true
	elseif writefile then
		writefile(dest, cont)
		return true
	else
		return false
	end	
end

local SaveInstance
local SaveInstance
do
	local function fetchAPI()
	local api
	local s,e = pcall(function()
		local version = game:HttpGet("http://setup.roblox.com/versionQTStudio",true)
		local rawApi = game:HttpGet("http://setup.roblox.com/"..version.."-API-Dump.json",true)
		api = game:GetService("HttpService"):JSONDecode(rawApi)
	end)
	if not s then return end
	local classes,enums = {},{}
	
	for _,class in pairs(api.Classes) do
		local newClass = {}
		newClass.Name = class.Name
		newClass.Superclass = class.Superclass
		newClass.Properties = {}
		newClass.Functions = {}
		newClass.Events = {}
		newClass.Callbacks = {}
		newClass.Tags = {}
		
		if class.Tags then for c,tag in pairs(class.Tags) do newClass.Tags[tag] = true end end
		for __,member in pairs(class.Members) do
			local mType = member.MemberType
			if mType == "Property" then
				local newProp = {}
				newProp.Name = member.Name
				newProp.Class = class.Name
				newProp.ValueType = member.ValueType.Name
				newProp.Category = member.Category
				newProp.Serialization = member.Serialization
				newProp.Tags = {}
				if member.Tags then for c,tag in pairs(member.Tags) do newProp.Tags[tag] = true end end
				table.insert(newClass.Properties,newProp)
			elseif mType == "Function" then
				local newFunc = {}
				newFunc.Name = member.Name
				newFunc.Class = class.Name
				newFunc.Parameters = {}
				newFunc.ReturnType = member.ReturnType.Name
				newFunc.Tags = {}
				for c,param in pairs(member.Parameters) do
					table.insert(newFunc.Parameters,{Name = param.Name, Type = param.Type.Name})
				end
				if member.Tags then for c,tag in pairs(member.Tags) do newFunc.Tags[tag] = true end end
				table.insert(newClass.Functions,newFunc)
			elseif mType == "Event" then
				local newEvent = {}
				newEvent.Name = member.Name
				newEvent.Class = class.Name
				newEvent.Parameters = {}
				newEvent.Tags = {}
				for c,param in pairs(member.Parameters) do
					table.insert(newEvent.Parameters,{Name = param.Name, Type = param.Type.Name})
				end
				if member.Tags then for c,tag in pairs(member.Tags) do newEvent.Tags[tag] = true end end
				table.insert(newClass.Events,newEvent)
			end
		end
		
		classes[class.Name] = newClass
	end
	
	for _,enum in pairs(api.Enums) do
		local newEnum = {}
		newEnum.Name = enum.Name
		newEnum.Items = {}
		newEnum.Tags = {}
		
		if enum.Tags then for c,tag in pairs(enum.Tags) do newEnum.Tags[tag] = true end end
		for __,item in pairs(enum.Items) do
			local newItem = {}
			newItem.Name = item.Name
			newItem.Value = item.Value
			table.insert(newEnum.Items,newItem)
		end
		
		enums[enum.Name] = newEnum
	end
	
	local function getMember(class,member)
		if not classes[class] or not classes[class][member] then return end
	    local result = {}
	
	    local currentClass = classes[class]
	    while currentClass do
	        for _,entry in pairs(currentClass[member]) do
	            table.insert(result,entry)
	        end
	        currentClass = classes[currentClass.Superclass]
	    end
	
	    table.sort(result,function(a,b) return a.Name < b.Name end)
	    return result
	end
	
	return {
		Classes = classes,
		Enums = enums,
		GetMember = getMember
	}
	end
	
	-- Dex Serializer Module
	local function SerializerModule()
	-- Modules
	local Serializer,API
	
	-- Un-init
	local _writefile,_getnilinstances,oldIndex,classes,enums
	
	-- Rest
	local t_ins,t_concat = table.insert,table.concat
	local buffer = {}
	local refCount = 0
	local getChildren = Instance.new("Part").GetChildren
	local toDecompile = {}
	local saveFilter = {}
	local instDir = {}
	
	local elyFuncs = false
	
	local xmlReplace = {
		["'"] = "&apos;",
		["\""] = "&quot;",
		["<"] = "&lt;",
		[">"] = "&gt;",
		["&"] = "&amp;"
	}
	
	local propBypass = {
		["BasePart"] = {
			["Size"] = true,
			["Color"] = true,
		},
		["Part"] = {
			["Shape"] = true
		},
		["Fire"] = {
			["Heat"] = true,
			["Size"] = true,
		},
		["Smoke"] = {
			["Opacity"] = true,
			["RiseVelocity"] = true,
			["Size"] = true,
		},
		["DoubleConstrainedValue"] = {
			["Value"] = true
		},
		["IntConstrainedValue"] = {
			["Value"] = true
		},
		["TrussPart"] = {
			["Style"] = true
		}
	}
	
	local propFilter = {
		["BaseScript"] = {
			["LinkedSource"] = true
		},
		["ModuleScript"] = {
			["LinkedSource"] = true
		},
		["Players"] = {
			["CharacterAutoLoads"] = true
		}
	}
	
	local sProps = setmetatable({},{__index = function(self,class)
		local props = {}
		
		local apiProps = API.GetMember(class,"Properties") or {}
		for i,v in pairs(apiProps) do
			if (v.Serialization.CanSave and not v.Tags.NotScriptable) or (propBypass[v.Class] and propBypass[v.Class][v.Name]) then
				if not propFilter[v.Class] or not propFilter[v.Class][v.Name] then
					local s,e = pcall(function() local exist = instDir[class][v.Name] end)
					if s then table.insert(props,v) end
				end
			end
		end
		
		self[class] = props
		
		return props
	end})
	
	local testInsts = setmetatable({},{__index = function(self,class)
		local s,testInst = pcall(function() return Instance.new(class) end)
		local testInstTable = {}
		
		if testInst then
			for i,v in pairs(sProps[class]) do
				testInstTable[v.Name] = testInst[v.Name]
			end
		end
		
		self[class] = testInstTable
		
		return testInstTable
	end})
	
	local refMt = {__index = function(self,inst)
		if not inst then return "" end
		refCount = refCount + 1
		self[inst] = refCount
		return refCount
	end}
	local refs = setmetatable({},refMt)
	
	local valueHandlers = {
		["bool"] = function(name,val)
			t_ins(buffer,'\n<bool name="'..name..'">'..tostring(val)..'</bool>')
		end,
		["float"] = function(name,val)
			t_ins(buffer,'\n<float name="'..name..'">'..val..'</float>')
		end,
		["int"] = function(name,val)
			t_ins(buffer,'\n<int name="'..name..'">'..val..'</int>')
		end,
		["int64"] = function(name,val)
			t_ins(buffer,'\n<int64 name="'..name..'">'..val..'</int64>')
		end,
		["double"] = function(name,val)
			t_ins(buffer,'\n<double name="'..name..'">'..val..'</double>')
		end,
		["string"] = function(name,val)
			t_ins(buffer,'\n<string name="'..name..'">'..val:gsub("['\"<>&]",xmlReplace)..'</string>')
		end,
		["BrickColor"] = function(name,val)
			t_ins(buffer,'\n<int name="'..name..'">'..val.Number..'</int>')
		end,
		["Vector2"] = function(name,val)
			t_ins(buffer,'\n<Vector2 name="'..name..'">\
	<X>'..val.X..'</X>\
	<Y>'..val.Y..'</Y>\
	</Vector2>')
		end,
		["Vector3"] = function(name,val)
			t_ins(buffer,'\n<Vector3 name="'..name..'">\
	<X>'..val.X..'</X>\
	<Y>'..val.Y..'</Y>\
	<Z>'..val.Z..'</Z>\
	</Vector3>')
		end,
		["CFrame"] = function(name,val)
			t_ins(buffer,('\n<CoordinateFrame name="'..name..[[">
	<X>%f</X>
	<Y>%f</Y>
	<Z>%f</Z>
	<R00>%f</R00>
	<R01>%f</R01>
	<R02>%f</R02>
	<R10>%f</R10>
	<R11>%f</R11>
	<R12>%f</R12>
	<R20>%f</R20>
	<R21>%f</R21>
	<R22>%f</R22>
	</CoordinateFrame>]]):format(val:components()))
		end,
		["Content"] = function(name,val)
			t_ins(buffer,'\n<Content name="'..name..'"><url>'..val:gsub("['\"<>&]",xmlReplace)..'</url></Content>')
		end,
		["UDim"] = function(name,val)
			t_ins(buffer,'\n<UDim name="'..name..'">\
	<S>'..val.Scale..'</S>\
	<O>'..val.Offset..'</O>\
	</UDim>')
		end,
		["UDim2"] = function(name,val)
			local x = val.X
			local y = val.Y
			t_ins(buffer,'\n<UDim2 name="'..name..'">\
	<XS>'..x.Scale..'</XS>\
	<XO>'..x.Offset..'</XO>\
	<YS>'..y.Scale..'</YS>\
	<YO>'..y.Offset..'</YO>\
	</UDim2>')
		end,
		["Color3"] = function(name,val)
			t_ins(buffer,'\n<Color3 name="'..name..'">\
	<R>'..val.r..'</R>\
	<G>'..val.g..'</G>\
	<B>'..val.b..'</B>\
	</Color3>')
		end,
		["NumberRange"] = function(name,val)
			t_ins(buffer,'\n<NumberRange name="'..name..'">'..tostring(val)..'</NumberRange>')
		end,
		["NumberSequence"] = function(name,val)
			t_ins(buffer,'\n<NumberSequence name="'..name..'">'..tostring(val)..'</NumberSequence>')
		end,
		["ColorSequence"] = function(name,val)
			t_ins(buffer,'\n<ColorSequence name="'..name..'">'..tostring(val)..'</ColorSequence>')
		end,
		["Rect"] = function(name,val)
			local min,max = val.Min,val.Max
			t_ins(buffer,'\n<Rect2D name="'..name..'">\
	<min>\
	<X>'..min.X..'</X>\
	<Y>'..min.Y..'</Y>\
	</min>\
	<max>\
	<X>'..max.X..'</X>\
	<Y>'..max.Y..'</Y>\
	</max>\
	</Rect2D>')
		end,
		["Object"] = function(name,val)
			t_ins(buffer,'\n<Ref name="'..name..'">RBX'..refs[val]..'</Ref>')
		end,
		["PhysicalProperties"] = function(name,val)
			if val then
			t_ins(buffer,'\n<PhysicalProperties name="'..name..'">\
	<CustomPhysics>true</CustomPhysics>\
	<Density>'..val.Density..'</Density>\
	<Friction>'..val.Friction..'</Friction>\
	<Elasticity>'..val.Elasticity..'</Elasticity>\
	<FrictionWeight>'..val.FrictionWeight..'</FrictionWeight>\
	<ElasticityWeight>'..val.ElasticityWeight..'</ElasticityWeight>\
	</PhysicalProperties>')
			else
				t_ins(buffer,'\n<PhysicalProperties name="'..name..'">\n<CustomPhysics>false</CustomPhysics>\n</PhysicalProperties>')
			end
		end,
		["Faces"] = function(name,val)
			local faceInt = (val.Front and 32 or 0)
							+(val.Bottom and 16 or 0)
							+(val.Left and 8 or 0)
							+(val.Back and 4 or 0)
							+(val.Top and 2 or 0)
							+(val.Right and 1 or 0)
			t_ins(buffer,'\n<Faces name="'..name..'">\
	<faces>'..faceInt..'</faces>\
	</Faces>')
		end,
		["Axes"] = function(name,val)
			local axisInt = (val.Z and 4 or 0)
							+(val.Y and 2 or 0)
							+(val.X and 1 or 0)
			t_ins(buffer,'\n<Axes name="'..name..'">\
	<axes>'..axisInt..'</axes>\
	</Faces>')
		end,
		["Ray"] = function(name,val)
			local origin = val.Origin
			local direction = val.Direction
			t_ins(buffer,'\n<Ray name="'..name..'">\
	<origin>\
	<X>'..origin.X..'</X>\
	<Y>'..origin.Y..'</Y>\
	<Z>'..origin.Z..'</Z>\
	</origin>\
	<direction>\
	<X>'..direction.X..'</X>\
	<Y>'..direction.Y..'</Y>\
	<Z>'..direction.Z..'</Z>\
	</direction>\
	</Ray>')
		end,
	}
	
	local function getNS(inst,name)
		rfl_setscriptable(inst,name,true)
		local propVal = oldIndex and oldIndex(inst,name) or inst[name]
		rfl_setscriptable(inst,name,false)
		return propVal
	end
	
	local function getBS(inst,name)
		local bs = getbspval(inst,name,true)
		if bs then
			return "<![CDATA["..bs.."]]>"
		else
			return ""
		end
	end
	
	local specialInst = {
		["UnionOperation"] = function(inst)
			if elyFuncs then -- Assume all ely funcs defined
				t_ins(buffer,'\n<Content name="AssetId"><url>'..getNS(inst,"AssetId"):gsub("['\"<>&]",xmlReplace)..'</url></Content>')
				local initialSize = getNS(inst,"InitialSize")
				t_ins(buffer,'\n<Vector3 name="InitialSize">\
	<X>'..initialSize.X..'</X>\
	<Y>'..initialSize.Y..'</Y>\
	<Z>'..initialSize.Z..'</Z>\
	</Vector3>')
				t_ins(buffer,'\n<BinaryString name="ChildData">'..getBS(inst,"ChildData")..'</BinaryString>')
				t_ins(buffer,'\n<BinaryString name="MeshData">'..getBS(inst,"MeshData")..'</BinaryString>')
				t_ins(buffer,'\n<BinaryString name="PhysicsData">'..getBS(inst,"PhysicsData")..'</BinaryString>')
			end
		end,
		["MeshPart"] = function(inst)
			if elyFuncs then -- Assume all ely funcs defined
				local initialSize = getNS(inst,"InitialSize")
				t_ins(buffer,'\n<Vector3 name="InitialSize">\
	<X>'..initialSize.X..'</X>\
	<Y>'..initialSize.Y..'</Y>\
	<Z>'..initialSize.Z..'</Z>\
	</Vector3>')
				t_ins(buffer,'\n<BinaryString name="PhysicsData">'..getBS(inst,"PhysicsData")..'</BinaryString>')
			end
		end,
		["Terrain"] = function(inst)
			if elyFuncs then
				t_ins(buffer,'\n<BinaryString name="MaterialColors">'..getBS(inst,"MaterialColors")..'</BinaryString>')
				t_ins(buffer,'\n<BinaryString name="SmoothGrid">'..getBS(inst,"SmoothGrid")..'</BinaryString>')
			end
		end,
		["TerrainRegion"] = function(inst)
			if elyFuncs then
				t_ins(buffer,'\n<BinaryString name="SmoothGrid">'..getBS(inst,"SmoothGrid")..'</BinaryString>')
			end
		end,
		["BinaryStringValue"] = function(inst)
			if elyFuncs then
				t_ins(buffer,'\n<BinaryString name="Value">'..getBS(inst,"Value")..'</BinaryString>')
			end
		end,
		["Workspace"] = function(inst)
			if elyFuncs then
				t_ins(buffer,'\n<token name="AutoJointsMode">'..getNS(inst,"AutoJointsMode").Value..'</token>')
			end
			t_ins(buffer,'\n<bool name="PGSPhysicsSolverEnabled">'..tostring(inst:PGSIsEnabled())..'</bool>')
			local groupTable = {}
			for i,v in pairs(game:GetService("PhysicsService"):GetCollisionGroups()) do
				t_ins(groupTable,v.name:gsub("['\"<>&]",xmlReplace).."^"..v.id.."^"..v.mask)
			end
			t_ins(buffer,'\n<string name="CollisionGroups">'..t_concat(groupTable,"\\")..'</string>')
		end,
		["Humanoid"] = function(inst)
			t_ins(buffer,'\n<float name="Health_XML">'..inst.Health..'</float>')
		end,
		["Sound"] = function(inst)
			t_ins(buffer,'\n<float name="xmlRead_MaxDistance_3">'..inst.MaxDistance..'</float>')
		end,
		["WeldConstraint"] = function(inst)
			if elyFuncs then
				valueHandlers["CFrame"]("CFrame0",getNS(inst,"CFrame0"))
				valueHandlers["CFrame"]("CFrame1",getNS(inst,"CFrame1"))
			end
			t_ins(buffer,'\n<Ref name="Part0Internal">RBX'..refs[inst.Part0]..'</Ref>')
			t_ins(buffer,'\n<Ref name="Part1Internal">RBX'..refs[inst.Part1]..'</Ref>')
		end,
		["LocalScript"] = function(inst)
			t_ins(buffer,'\n<ProtectedString name="Source">')
			t_ins(buffer,"")
			t_ins(buffer,'</ProtectedString>')
			t_ins(toDecompile,{inst,#buffer-1})
		end,
		["ModuleScript"] = function(inst)
			t_ins(buffer,'\n<ProtectedString name="Source">')
			t_ins(buffer,"")
			t_ins(buffer,'</ProtectedString>')
			t_ins(toDecompile,{inst,#buffer-1})
		end,
	}
	
	local savePlaceBlacklist = {
		["CoreGui"] = true,
		["CorePackages"] = true
	}
	
	local function writeXML(inst)
		if saveFilter[inst] then return end
		
		local class = oldIndex and oldIndex(inst,"ClassName") or inst.ClassName	
		if not instDir[class] then instDir[class] = inst end
		local testInst = testInsts[class]
		
		t_ins(buffer,'\n<Item class="'..class..'" referent="RBX'..refs[inst]..'">\n<Properties>')
		
		for _,prop in pairs(sProps[class]) do
			local propName = prop.Name
			local propVal = oldIndex and oldIndex(inst,propName) or inst[propName]
			if testInst[propName] ~= propVal then
				local valueType = prop.ValueType
				if valueHandlers[valueType] then
					valueHandlers[valueType](propName,propVal)
				elseif enums[valueType] then
					t_ins(buffer,'\n<token name="'..propName..'">'..propVal.Value..'</token>')
				elseif classes[valueType] then
					valueHandlers["Object"](propName,propVal)
				end
			end
		end
		
		if specialInst[class] then
			specialInst[class](inst)
		end
		
		t_ins(buffer,"\n</Properties>")
		
		for i,v in pairs(getChildren(inst)) do
			writeXML(v)
		end
		
		t_ins(buffer,"\n</Item>")
	end
	
	local function resetState()
		buffer = {}
		refs = setmetatable({},refMt)
		refCount = 0
		toDecompile = {}
		saveFilter = {}
		instDir = {}
	end
	
	local defaultSettings = {
		DecompileMode = 0,
		NilInstances = false,
		RemovePlayers = true,
		SavePlayerDescendants = false,
		DecompileTimeout = 10,
		UnluacMaxThreads = 5,
		DecompileIgnore = {}
	}
	
	Serializer = {
		Init = function(data)
			API = data.API
			_writefile = data.WriteFile
			_getnilinstances = data.GetNilInstances
			oldIndex = data.OldIndex
			
			classes = API.Classes
			enums = API.Enums
			
			elyFuncs = getbspval and rfl_setscriptable
			
			Serializer.ResetSettings()
		end,
		
		Settings = {},
		
		ResetSettings = function()
			Serializer.Settings = {}
			for i,v in pairs(defaultSettings) do
				Serializer.Settings[i] = v
			end
		end,
		
		SaveInstance = function(inst,name,sets)
			Serializer.ResetSettings()
			
			for i,v in pairs(sets or {}) do
				Serializer.Settings[i] = v
			end
			
			resetState()
			
			if inst == game and Serializer.Settings.RemovePlayers then
				for i,v in pairs(game:GetService("Players"):GetPlayers()) do
					saveFilter[v.Character] = true
				end
			end
			
			t_ins(buffer,[==[<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">
	<Meta name="ExplicitAutoJoints">true</Meta>
	<External>null</External>
	<External>nil</External>]==])
			
			if inst ~= game then
				if type(inst) == "table" then
					for i,v in pairs(inst) do
						writeXML(v)
					end
				else
					writeXML(inst)
				end
			else
				for i,v in pairs(game:GetChildren()) do
					if not savePlaceBlacklist[v.ClassName] then
						writeXML(v)
					end
				end
			end
			
			if inst == game and Serializer.Settings.NilInstances and _getnilinstances then
				t_ins(buffer,'\n<Item class="Folder" referent="RBX'..refs[Instance.new("Folder")]..'">\
	<Properties>\
	<string name="Name">Nil Instances</string>\
	</Properties>')
				for i,v in pairs(_getnilinstances()) do
					if ((API.Classes[v.ClassName] and not API.Classes[v.ClassName].Tags.Service) or not API.Classes[v.ClassName]) and v ~= game then
						writeXML(v)
					end
				end
				t_ins(buffer,"\n</Item>")
			end
			
			if inst == game and Serializer.Settings.SavePlayerDescendants then
				t_ins(buffer,'\n<Item class="Folder" referent="RBX'..refs[Instance.new("Folder")]..'">\
	<Properties>\
	<string name="Name">Player Descendants</string>\
	</Properties>')
				for i,v in pairs(game:GetService("Players").LocalPlayer:GetChildren()) do
					if v:IsA("PlayerGui") or v:IsA("PlayerScripts") or v:IsA("StarterGear") then
						t_ins(buffer,'\n<Item class="Folder" referent="RBX'..refs[Instance.new("Folder")]..'">\
	<Properties>\
	<string name="Name">'..v.ClassName..'</string>\
	</Properties>')
						for _,c in pairs(v:GetChildren()) do
							writeXML(c)
						end
						t_ins(buffer,"\n</Item>")
					else
						writeXML(v)
					end
				end
				t_ins(buffer,"\n</Item>")
			end
			
			if inst == game then
				t_ins(buffer,'\n<Item class="Script" referent="RBX'..refs[Instance.new("Folder")]..'">\
	<Properties>\
	<string name="Name">Please Read</string>\
	<ProtectedString name="Source">'..[==[--[[
	Thank you for using Dex SaveInstance by Moon. (Calamari edition.)
	
	If you cannot play the game, please try relocating any scripts in StarterPlayer elsewhere.
	]]]==]..'</ProtectedString>\
	</Properties>\
	</Item>')
			end
			
			t_ins(buffer,"\n</roblox>")
			
			if Serializer.Settings.DecompileMode > 0 and decompile then
				if inst == game and #Serializer.Settings.DecompileIgnore > 0 then
					local ignoreServices = {}
					for i,v in pairs(Serializer.Settings.DecompileIgnore) do t_ins(ignoreServices,game:GetService(v)) end
					for i = #toDecompile,1,-1 do
						for _,serv in pairs(ignoreServices) do
							if toDecompile[i][1]:IsDescendantOf(serv) then
								table.remove(toDecompile,i)
								break
							end
						end
					end
				end
				
				if Serializer.Settings.DecompileMode == 1 then
					for i,v in pairs(toDecompile) do
						local decstr = "-- This could not decompile"
						pcall(function()
						    if (false) then
							decstr = tostring(v[1]):gsub("['\"<>&]",xmlReplace)
							else
							decstr = "" 
	                        end
						end)
						buffer[v[2]] = decstr
					end
				elseif Serializer.Settings.DecompileMode == 2 then
					local left = #toDecompile
					local totalScripts = left
					
					local statusGui = Instance.new("ScreenGui")
					local statusText = Instance.new("TextLabel",statusGui)
					statusText.BackgroundTransparency = 1
					statusText.TextColor3 = Color3.new(1,1,1)
					statusText.Position = UDim2.new(0,0,0,0)
					statusText.Size = UDim2.new(1,0,0,36)
					statusText.TextSize = 32
					statusText.Font = Enum.Font.Code
					statusText.Text = left.."/"..totalScripts.." Scripts Left"
					statusGui.Parent = gethui()
				
					local function doDec(scr)
						local thread = coroutine.running()
						local decompiled = false
						
						tostring(scr,"unluac",function(scr,err)
							decompiled = true
							coroutine.resume(thread,scr,err)
						end)
						
						spawn(function()
							wait(Serializer.Settings.DecompileTimeout)
							if decompiled then return end
							coroutine.resume(thread,nil,"timeout")
						end)
						
						return coroutine.yield()
					end
				
					for i = 1,Serializer.Settings.UnluacMaxThreads do
						spawn(function()
							while #toDecompile > 0 do
								local nextScript = table.remove(toDecompile)
								local scr,err = doDec(nextScript[1])
								if scr then
									buffer[nextScript[2]] = scr:gsub("['\"<>&]",xmlReplace)
								else
									buffer[nextScript[2]] = "-- This could not decompile because "..(err or ""):gsub("['\"<>&]",xmlReplace)
								end
								left = left - 1
								statusText.Text = left.."/"..totalScripts.." Scripts Left"
							end
						end)
					end
					while left > 0 do game:GetService("RunService").RenderStepped:wait() end
					statusGui:Destroy()
				end
			end
			
			pcall(function()
				_writefile(name..(".rbxmx"),(t_concat(buffer)), name, "Roblox XML Files(*.rbxlx, *.rbxmx)\0 * .rbxlx; *.rbxmx\0All Files\0 * .*\0",(".rbxmx"))
			end)
			
			resetState()
		end
	}
	
	return Serializer
	end
	
	pcall(function()
		local initialized = false
		local serializer = SerializerModule()
		
		local function init()
		local startup = {
			API = fetchAPI(),
			WriteFile = dexWriteFile,
			GetNilInstances = nil,
			OldIndex = oldindex
		}
		serializer.Init(startup)
		initialized = true
		end
		
		if not initialized then
		init()
		end
		
		SaveInstance = serializer.SaveInstance
		saveinstance = serializer.SaveInstance
	end)
end

local ENTRY_SIZE = GUI_SIZE + ENTRY_PADDING*2
local ENTRY_BOUND = ENTRY_SIZE + ENTRY_MARGIN
local HEADER_SIZE = ENTRY_SIZE*2

local FONT = 'SourceSans'
local FONT_SIZE do
	local size = {8,9,10,11,12,14,18,24,36,48}
	local s
	local n = math.huge
	for i = 1,#size do
		if size[i] <= GUI_SIZE then
			FONT_SIZE = i - 1
		end
	end
end

local GuiColor = {
	Background      = Color3.new(233/255, 233/255, 233/255);
	Border          = Color3.new(149/255, 149/255, 149/255);
	Selected        = Color3.new( 96/255, 140/255, 211/255);
	BorderSelected  = Color3.new( 86/255, 125/255, 188/255);
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

----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
---- Icon map constants

local MAP_ID = 3440403115

-- Indices based on implementation of Icon function.
local ACTION_CUT         	 = 160
local ACTION_COPY        	 = 161
local ACTION_PASTE       	 = 162
local ACTION_DELETE      	 = 163
local ACTION_SORT        	 = 164
local ACTION_CUT_OVER    	 = 174
local ACTION_COPY_OVER   	 = 175
local ACTION_PASTE_OVER  	 = 176
local ACTION_DELETE_OVER	 = 177
local ACTION_SORT_OVER  	 = 178
local ACTION_EDITQUICKACCESS = 190
local ACTION_FREEZE 		 = 188
local ACTION_STARRED 		 = 189
local ACTION_ADDSTAR 		 = 184
local ACTION_ADDSTAR_OVER 	 = 187

local NODE_COLLAPSED      = 165
local NODE_EXPANDED       = 166
local NODE_COLLAPSED_OVER = 179
local NODE_EXPANDED_OVER  = 180

local ExplorerIndex = {
	["Cut"] = ACTION_CUT_OVER;
	["Copy"] = ACTION_COPY_OVER;
	["Duplicate"] = ACTION_COPY_OVER;
	["Delete"] = ACTION_DELETE_OVER;
	["Insert Part"] = 1;
	["Accessory"] = 32;
	["Accoutrement"] = 32;
	["AdService"] = 73;
	["Animation"] = 60;
	["AnimationController"] = 60;
	["AnimationTrack"] = 60;
	["Animator"] = 60;
	["ArcHandles"] = 56;
	["AssetService"] = 72;
	["Attachment"] = 34;
	["Backpack"] = 20;
	["BadgeService"] = 75;
	["BallSocketConstraint"] = 97;
	["NoCollisionConstraint"] = 116;
	["BillboardGui"] = 64;
	["BinaryStringValue"] = 4;
	["BindableEvent"] = 67;
	["BindableFunction"] = 66;
	["BlockMesh"] = 8;
	["BloomEffect"] = 94;
	["BlurEffect"] = 90;
	["BodyAngularVelocity"] = 14;
	["BodyForce"] = 14;
	["BodyGyro"] = 14;
	["BodyPosition"] = 14;
	["BodyThrust"] = 14;
	["BodyVelocity"] = 14;
	["BoolValue"] = 4;
	["BoxHandleAdornment"] = 54;
	["BrickColorValue"] = 4;
	["Camera"] = 5;
	["CFrameValue"] = 4;
	["CharacterMesh"] = 60;
	["Chat"] = 33;
	["ClickDetector"] = 41;
	["CollectionService"] = 30;
	["Color3Value"] = 4;
	["ColorCorrectionEffect"] = 90;
	["ConeHandleAdornment"] = 54;
	["Configuration"] = 58;
	["ContentProvider"] = 72;
	["ContextActionService"] = 41;
	["CoreGui"] = 46;
	["CoreScript"] = 18;
	["CornerWedgePart"] = 1;
	["CustomEvent"] = 4;
	["CustomEventReceiver"] = 4;
	["CylinderHandleAdornment"] = 54;
	["CylinderMesh"] = 8;
	["CylindricalConstraint"] = 107;
	["Debris"] = 30;
	["Decal"] = 7;
	["Dialog"] = 62;
	["DialogChoice"] = 63;
	["DoubleConstrainedValue"] = 4;
	["Explosion"] = 36;
	["FileMesh"] = 8;
	["Fire"] = 61;
	["Flag"] = 38;
	["FlagStand"] = 39;
	["FloorWire"] = 4;
	["Folder"] = 70;
	["ForceField"] = 37;
	["Frame"] = 48;
	["GamePassService"] = 19;
	["Glue"] = 34;
	["GuiButton"] = 52;
	["GuiMain"] = 47;
	["GuiService"] = 47;
	["Handles"] = 53;
	["HapticService"] = 84;
	["Hat"] = 45;
	["HingeConstraint"] = 98;
	["Hint"] = 33;
	["HopperBin"] = 22;
	["HttpService"] = 76;
	["Humanoid"] = 9;
	["ImageButton"] = 52;
	["ImageLabel"] = 49;
	["InsertService"] = 72;
	["IntConstrainedValue"] = 4;
	["IntValue"] = 4;
	["JointInstance"] = 34;
	["JointsService"] = 34;
	["Keyframe"] = 60;
	["KeyframeSequence"] = 60;
	["KeyframeSequenceProvider"] = 60;
	["Lighting"] = 13;
	["LineHandleAdornment"] = 54;
	["LocalScript"] = 18;
	["LogService"] = 87;
	["MarketplaceService"] = 46;
	["Message"] = 33;
	["Model"] = 2;
	["ModuleScript"] = 71;
	["Motor"] = 34;
	["Motor6D"] = 34;
	["MoveToConstraint"] = 93;
	["NegateOperation"] = 78;
	["NetworkClient"] = 16;
	["NetworkReplicator"] = 29;
	["NetworkServer"] = 15;
	["NumberValue"] = 4;
	["ObjectValue"] = 4;
	["Pants"] = 44;
	["ParallelRampPart"] = 1;
	["Part"] = 1;
	["ParticleEmitter"] = 69;
	["PartPairLasso"] = 57;
	["PathfindingService"] = 37;
	["Platform"] = 35;
	["Player"] = 12;
	["PlayerGui"] = 46;
	["Players"] = 21;
	["PlayerScripts"] = 82;
	["PointLight"] = 13;
	["PointsService"] = 83;
	["Pose"] = 60;
	["PrismaticConstraint"] = 99;
	["PrismPart"] = 1;
	["PyramidPart"] = 1;
	["RayValue"] = 4;
	["ReflectionMetadata"] = 86;
	["ReflectionMetadataCallbacks"] = 86;
	["ReflectionMetadataClass"] = 86;
	["ReflectionMetadataClasses"] = 86;
	["ReflectionMetadataEnum"] = 86;
	["ReflectionMetadataEnumItem"] = 86;
	["ReflectionMetadataEnums"] = 86;
	["ReflectionMetadataEvents"] = 86;
	["ReflectionMetadataFunctions"] = 86;
	["ReflectionMetadataMember"] = 86;
	["ReflectionMetadataProperties"] = 86;
	["ReflectionMetadataYieldFunctions"] = 86;
	["RemoteEvent"] = 80;
	["RemoteFunction"] = 79;
	["ReplicatedFirst"] = 72;
	["ReplicatedStorage"] = 72;
	["RightAngleRampPart"] = 1;
	["RocketPropulsion"] = 14;
	["RodConstraint"] = 101;
	["RopeConstraint"] = 100;
	["Rotate"] = 34;
	["RotateP"] = 34;
	["RotateV"] = 34;
	["RunService"] = 66;
	["ScreenGui"] = 47;
	["Script"] = 6;
	["ScrollingFrame"] = 48;
	["Seat"] = 35;
	["Selection"] = 55;
	["SelectionBox"] = 54;
	["SelectionPartLasso"] = 57;
	["SelectionPointLasso"] = 57;
	["SelectionSphere"] = 54;
	["ServerScriptService"] = 0;
	["ServerStorage"] = 74;
	["Shirt"] = 43;
	["ShirtGraphic"] = 40;
	["SkateboardPlatform"] = 35;
	["Sky"] = 28;
	["SlidingBallConstraint"] = 93;
	["Smoke"] = 59;
	["Snap"] = 34;
	["Sound"] = 11;
	["SoundService"] = 31;
	["Sparkles"] = 42;
	["SpawnLocation"] = 25;
	["SpecialMesh"] = 8;
	["SphereHandleAdornment"] = 54;
	["SpotLight"] = 13;
	["SpringConstraint"] = 102;
	["StarterCharacterScripts"] = 82;
	["StarterGear"] = 20;
	["StarterGui"] = 46;
	["StarterPack"] = 20;
	["StarterPlayer"] = 88;
	["StarterPlayerScripts"] = 82;
	["Status"] = 2;
	["StringValue"] = 4;
	["SunRaysEffect"] = 90;
	["SurfaceGui"] = 64;
	["SurfaceLight"] = 13;
	["SurfaceSelection"] = 55;
	["Team"] = 24;
	["Teams"] = 23;
	["TeleportService"] = 81;
	["Terrain"] = 65;
	["TerrainRegion"] = 65;
	["TestService"] = 68;
	["TextBox"] = 51;
	["TextButton"] = 51;
	["TextLabel"] = 50;
	["Texture"] = 10;
	["TextureTrail"] = 4;
	["Tool"] = 17;
	["TouchTransmitter"] = 37;
	["TrussPart"] = 1;
	["UnionOperation"] = 77;
	["MeshPart"] = 77;
	["UserInputService"] = 84;
	["Vector3Value"] = 4;
	["VehicleSeat"] = 35;
	["VelocityMotor"] = 34;
	["WedgePart"] = 1;
	["Weld"] = 34;
	["Workspace"] = 19;
	["WeldConstraint"] = 105;
	["VectorForce"] = 113;
	["UITextSizeConstraint"] = 26;
	["UITableLayout"] = 26;
	["UISizeConstraint"] = 26;
	["UIScale"] = 26;
	["UIPageLayout"] = 26;
	["UIPadding"] = 26;
	["UIListLayout"] = 26;
	["UIGridLayout"] = 26;
	["UIAspectRatioConstraint"] = 26;
	["Trail"] = 26;
	["UITextSizeConstraint"] = 26;
	["LocalizationTable"] = 108;
	["LocalizationService"] = 103;
	["LineForce"] = 112;
	["Beam"] = 108;
	["AngularVelocity"] = 114;
	["AlignPosition"] = 111;
	["AlignOrientation"] = 112;
	["HumanoidDescription"] = 115;
	["TremoloSoundEffect"] = 95;
	["SoundGroup"] = 96;
	["ReverbSoundEffect"] = 95;
	["PitchShiftSoundEffect"] = 95;
	["FlangeSoundEffect"] = 95;
	["EqualizerSoundEffect"] = 95;
	["EchoSoundEffect"] = 95;
	["DistortionSoundEffect"] = 95;
	["CompressorSoundEffect"] = 95;
	["ChorusSoundEffect"] = 95;
	["Torque"] = 114;
}

----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------

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

local barActive = false
local activeOptions = {}

function createDDown(dBut, callback,...)
	if barActive then
		for i,v in pairs(activeOptions) do
			v:Destroy()
		end
		activeOptions = {}
		barActive = false
		return
	else
		barActive = true
	end
	local slots = {...}
	local base = dBut
	for i,v in pairs(slots) do
		local newOption = base:Clone()
		newOption.ZIndex = 5
		newOption.Name = "Option "..tostring(i)
		newOption.Parent = base.Parent.Parent.Parent
		newOption.BackgroundTransparency = 0
		newOption.ZIndex = 2
		table.insert(activeOptions,newOption)
		newOption.Position = UDim2.new(-0.4, dBut.Position.X.Offset, dBut.Position.Y.Scale, dBut.Position.Y.Offset + (#activeOptions * dBut.Size.Y.Offset))
		newOption.Text = slots[i]
		newOption.MouseButton1Down:connect(function()
			dBut.Text = slots[i]
			callback(slots[i])
			for i,v in pairs(activeOptions) do
				v:Destroy()
			end
			activeOptions = {}
			barActive = false
		end)
	end
end

-- Connects a function to an event such that it fires asynchronously
function Connect(event,func)
	return event:connect(function(...)
		local a = {...}
		spawn(function() func(unpack(a)) end)
	end)
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

do
	local ZIndexLock = {}
	-- Sets the ZIndex of an object and its descendants. Objects are locked so
	-- that SetZIndexOnChanged doesn't spawn multiple threads that set the
	-- ZIndex of the same object.
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

	function SetZIndexOnChanged(object)
		return object.Changed:connect(function(p)
			if p == "ZIndex" then
				SetZIndex(object,object.ZIndex)
			end
		end)
	end
end

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

----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
---- ScrollBar
do
	-- AutoButtonColor doesn't always reset properly
	local function ResetButtonColor(button)
		local active = button.Active
		button.Active = not active
		button.Active = active
	end

	local function ArrowGraphic(size,dir,scaled,template)
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


	local function GripGraphic(size,dir,spacing,scaled,template)
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
			Position = horizontal and UDim2.new(0,0,1,-GUI_SIZE) or UDim2.new(1,-GUI_SIZE,0,0);
			Size = horizontal and UDim2.new(1,0,0,GUI_SIZE) or UDim2.new(0,GUI_SIZE,1,0);
			BackgroundTransparency = 1;
			Create('ImageButton',{
				Name = "ScrollDown";
				Position = horizontal and UDim2.new(1,-GUI_SIZE,0,0) or UDim2.new(0,0,1,-GUI_SIZE);
				Size = UDim2.new(0, GUI_SIZE, 0, GUI_SIZE);
				BackgroundColor3 = GuiColor.Button;
				BorderColor3 = GuiColor.Border;
				--BorderSizePixel = 0;
			});
			Create('ImageButton',{
				Name = "ScrollUp";
				Size = UDim2.new(0, GUI_SIZE, 0, GUI_SIZE);
				BackgroundColor3 = GuiColor.Button;
				BorderColor3 = GuiColor.Border;
				--BorderSizePixel = 0;
			});
			Create('ImageButton',{
				Name = "ScrollBar";
				Size = horizontal and UDim2.new(1,-GUI_SIZE*2,1,0) or UDim2.new(1,0,1,-GUI_SIZE*2);
				Position = horizontal and UDim2.new(0,GUI_SIZE,0,0) or UDim2.new(0,0,0,GUI_SIZE);
				AutoButtonColor = false;
				BackgroundColor3 = Color3.new(0.94902, 0.94902, 0.94902);
				BorderColor3 = GuiColor.Border;
				--BorderSizePixel = 0;
				Create('ImageButton',{
					Name = "ScrollThumb";
					AutoButtonColor = false;
					Size = UDim2.new(0, GUI_SIZE, 0, GUI_SIZE);
					BackgroundColor3 = GuiColor.Button;
					BorderColor3 = GuiColor.Border;
					--BorderSizePixel = 0;
				});
			});
		})

		local graphicTemplate = Create('Frame',{
			Name="Graphic";
			BorderSizePixel = 0;
			BackgroundColor3 = GuiColor.Border;
		})
		local graphicSize = GUI_SIZE/2

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
			local size = GUI_SIZE*3/8
			local Decal = GripGraphic(Vector2.new(size,size),horizontal and 'Vertical' or 'Horizontal',2,graphicTemplate)
			Decal.Position = UDim2.new(0.5,-size/2,0.5,-size/2)
			Decal.Parent = ScrollThumbFrame
		end

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
				ScrollThumbFrame.Size = UDim2.new(Class.VisibleSpace/Class.TotalSpace,0,0,GUI_SIZE)
				if ScrollThumbFrame.AbsoluteSize.x < GUI_SIZE then
					ScrollThumbFrame.Size = UDim2.new(0,GUI_SIZE,0,GUI_SIZE)
				end
				local barSize = ScrollBarFrame.AbsoluteSize.x
				ScrollThumbFrame.Position = UDim2.new(Class:GetScrollPercent()*(barSize - ScrollThumbFrame.AbsoluteSize.x)/barSize,0,0,0)
			end
		else
			function UpdateScrollThumb()
				ScrollThumbFrame.Size = UDim2.new(0,GUI_SIZE,Class.VisibleSpace/Class.TotalSpace,0)
				if ScrollThumbFrame.AbsoluteSize.y < GUI_SIZE then
					ScrollThumbFrame.Size = UDim2.new(0,GUI_SIZE,0,GUI_SIZE)
				end
				local barSize = ScrollBarFrame.AbsoluteSize.y
				ScrollThumbFrame.Position = UDim2.new(0,0,Class:GetScrollPercent()*(barSize - ScrollThumbFrame.AbsoluteSize.y)/barSize,0)
			end
		end

		local lastDown
		local lastUp
		local scrollStyle = {BackgroundColor3=GuiColor.Border,BackgroundTransparency=0}
		local scrollStyle_ds = {BackgroundColor3=GuiColor.Border,BackgroundTransparency=0.7}

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

		local MouseDrag = Create('ImageButton',{
			Name = "MouseDrag";
			Position = UDim2.new(-0.25,0,-0.25,0);
			Size = UDim2.new(1.5,0,1.5,0);
			Transparency = 1;
			AutoButtonColor = false;
			Active = true;
			ZIndex = 10;
		})

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
---- Explorer panel

Create(explorerPanel,{
	BackgroundColor3 = GuiColor.Field;
	BorderColor3 = GuiColor.Border;
	Active = true;
})

local SettingsRemote = explorerPanel.Parent:WaitForChild("SettingsPanel"):WaitForChild("GetSetting")
local GetApiRemote = explorerPanel.Parent:WaitForChild("PropertiesFrame"):WaitForChild("GetApi")
local GetAwaitRemote = explorerPanel.Parent:WaitForChild("PropertiesFrame"):WaitForChild("GetAwaiting")
local bindSetAwaiting = explorerPanel.Parent:WaitForChild("PropertiesFrame"):WaitForChild("SetAwaiting")

local SaveInstanceWindow = explorerPanel.Parent:WaitForChild("SaveInstance")
local ConfirmationWindow = explorerPanel.Parent:WaitForChild("Confirmation")
local CautionWindow = explorerPanel.Parent:WaitForChild("Caution")
local TableCautionWindow = explorerPanel.Parent:WaitForChild("TableCaution")

local RemoteWindow = explorerPanel.Parent:WaitForChild("CallRemote")

local ScriptEditor = explorerPanel.Parent:WaitForChild("ScriptEditor")
local ScriptEditorEvent = ScriptEditor:WaitForChild("OpenScript")

local CurrentSaveInstanceWindow
local CurrentRemoteWindow

local lastSelectedNode

local DexStorage
local DexStorageMain
local DexStorageEnabled

if saveinstance then DexStorageEnabled = true end

if DexStorageEnabled then
	DexStorage = Instance.new("Folder")
	DexStorage.Name = "Dex"
	DexStorageMain = Instance.new("Folder",DexStorage)
	DexStorageMain.Name = "DexStorage"
end

local NilStorage
local NilStorageMain
local NilStorageEnabled

if get_nil_instances and IfThisFunctionWasStableEnough then NilStorageEnabled = true end

if NilStorageEnabled then
	NilStorage = Instance.new("Folder")
	NilStorage.Name = "Dex Internal Storage"
	NilStorageMain = Instance.new("Folder",NilStorage)
	NilStorageMain.Name = "Nil Instances"
end

local listFrame = Create('Frame',{
	Name = "List";
	BackgroundTransparency = 1;
	ClipsDescendants = true;
	Position = UDim2.new(0,0,0,HEADER_SIZE);
	Size = UDim2.new(1,-GUI_SIZE,1,-HEADER_SIZE);
	Parent = explorerPanel;
})

local scrollBar = ScrollBar(false)
scrollBar.PageIncrement = 1
Create(scrollBar.GUI,{
	Position = UDim2.new(1,-GUI_SIZE,0,HEADER_SIZE);
	Size = UDim2.new(0,GUI_SIZE,1,-HEADER_SIZE);
	Parent = explorerPanel;
})

local scrollBarH = ScrollBar(true)
scrollBarH.PageIncrement = GUI_SIZE
Create(scrollBarH.GUI,{
	Position = UDim2.new(0,0,1,-GUI_SIZE);
	Size = UDim2.new(1,-GUI_SIZE,0,GUI_SIZE);
	Visible = false;
	Parent = explorerPanel;
})

local headerFrame = Create('Frame',{
	Name = "Header";
	BackgroundColor3 = GuiColor.Background;
	BorderColor3 = GuiColor.Border;
	Position = UDim2.new(0,0,0,0);
	Size = UDim2.new(1,0,0,HEADER_SIZE);
	Parent = explorerPanel;
	Create('TextLabel',{
		Text = "Explorer";
		BackgroundTransparency = 1;
		TextColor3 = GuiColor.Text;
		TextXAlignment = 'Left';
		Font = FONT;
		FontSize = FONT_SIZE;
		Position = UDim2.new(0,4,0,0);
		Size = UDim2.new(1,-4,0.5,0);
	});
})

local explorerFilter = 	Create('TextBox',{
	PlaceholderText = "Filter Workspace";
	PlaceholderColor3 = Color3.new(44/255, 44/255, 44/255);
	Text = "";
	BackgroundTransparency = 0.8;
	TextColor3 = GuiColor.Text;
	TextXAlignment = 'Left';
	Font = FONT;
	FontSize = FONT_SIZE;
	Position = UDim2.new(0,4,0.5,0);
	Size = UDim2.new(1,-8,0.5,-2);
});
explorerFilter.Parent = headerFrame

SetZIndexOnChanged(explorerPanel)

local function CreateColor3(r, g, b) return Color3.new(r/255,g/255,b/255) end

local Styles = {
	Font = Enum.Font.Arial;
	Margin = 5;
	Black = CreateColor3(0,0,0);
	White = CreateColor3(255,255,255);
}

local DropDown = {
	Font = Styles.Font;
	FontSize = Enum.FontSize.Size14;
	TextColor = CreateColor3(0,0,0);
	TextColorOver = Styles.White;
	TextXAlignment = Enum.TextXAlignment.Left;
	Height = 20;
	BackColor = Styles.White;
	BackColorOver = CreateColor3(86,125,188);
	BorderColor = CreateColor3(216,216,216);
	BorderSizePixel = 1;
	ArrowColor = CreateColor3(160,160,160);
	ArrowColorOver = Styles.Black;
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

local currentRightClickMenu
local CurrentInsertObjectWindow
local CurrentFunctionCallerWindow

local RbxApi

function ClassCanCreate(IName)
	local success,err = pcall(function() Instance.new(IName) end)
	if err then
		return false
	else
		return true
	end
end

function GetClasses()
	if RbxApi == nil then return {} end
	local classTable = {}
	for i,v in pairs(RbxApi.Classes) do
		if ClassCanCreate(v.Name) then
			table.insert(classTable,v.Name)
		end
	end
	return classTable
end

local function sortAlphabetic(t, property)
	table.sort(t, 
		function(x,y) return x[property] < y[property]
	end)
end

local function FunctionIsHidden(functionData)
	local tags = functionData["tags"]
	for _,name in pairs(tags) do
		if name == "deprecated"
			or name == "hidden"
			or name == "writeonly" then
			return true
		end
	end
	return false
end

local function GetAllFunctions(className)
	local class = RbxApi.Classes[className]
	local functions = {}
	
	if not class then return functions end
	
	while class do
		if class.Name == "Instance" then break end
		for _,nextFunction in pairs(class.Functions) do
			if not FunctionIsHidden(nextFunction) then
				table.insert(functions, nextFunction)
			end
		end
		class = RbxApi.Classes[class.Superclass]
	end
	
	sortAlphabetic(functions, "Name")

	return functions
end

function GetFunctions()
	if RbxApi == nil then return {} end
	local List = SelectionVar():Get()
	
	if #List == 0 then return end
	
	local MyObject = List[1]
	
	local functionTable = {}
	for i,v in pairs(GetAllFunctions(MyObject.ClassName)) do
		table.insert(functionTable,v)
	end
	return functionTable
end

function CreateInsertObjectMenu(choices, currentChoice, readOnly, onClick)
	local mouse = game:GetService("Players").LocalPlayer:GetMouse()
	local totalSize = explorerPanel.Parent.AbsoluteSize.y
	if #choices == 0 then return end
	
	table.sort(choices, function(a,b) return a < b end)

	local frame = Instance.new("Frame")	
	frame.Name = "InsertObject"
	frame.Size = UDim2.new(0, 200, 1, 0)
	frame.BackgroundTransparency = 1
	frame.Active = true
	
	local menu = nil
	local arrow = nil
	local expanded = false
	local margin = DropDown.BorderSizePixel;
	
	--[[
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
	--]]
	
	local function hideMenu()
		expanded = false
		--showArrow(DropDown.ArrowColor)
		if frame then 
			--frame:Destroy()
			CurrentInsertObjectWindow.Visible = false
		end
	end
	
	local function showMenu()
		expanded = true
		menu = Instance.new("ScrollingFrame")
		menu.Size = UDim2.new(0,200,1,0)
		menu.CanvasSize = UDim2.new(0, 200, 0, #choices * DropDown.Height)
		menu.Position = UDim2.new(0, margin, 0, 0)
		menu.BackgroundTransparency = 0
		menu.BackgroundColor3 = DropDown.BackColor
		menu.BorderColor3 = DropDown.BorderColor
		menu.BorderSizePixel = DropDown.BorderSizePixel
		menu.TopImage = "rbxasset://textures/blackBkg_square.png"
		menu.MidImage = "rbxasset://textures/blackBkg_square.png"
		menu.BottomImage = "rbxasset://textures/blackBkg_square.png"
		menu.Active = true
		menu.ZIndex = 5
		menu.Parent = frame
		
		--local parentFrameHeight = script.Parent.List.Size.Y.Offset
		--local rowHeight = mouse.Y
		--if (rowHeight + menu.Size.Y.Offset) > parentFrameHeight then
		--	menu.Position = UDim2.new(0, margin, 0, -1 * (#choices * DropDown.Height) - margin)
		--end
			
		local function choice(name)
			onClick(name)
			hideMenu()
		end
		
		for i,name in pairs(choices) do
			local option = CreateRightClickMenuItem(name, function()
				choice(name)
			end,1)
			option.Size = UDim2.new(1, 0, 0, 20)
			option.Position = UDim2.new(0, 0, 0, (i - 1) * DropDown.Height)
			option.ZIndex = menu.ZIndex
			option.Parent = menu
		end
	end
	
	showMenu()
	
	return frame
end

function CreateFunctionCallerMenu(choices, currentChoice, readOnly, onClick)
	local mouse = game:GetService("Players").LocalPlayer:GetMouse()
	local totalSize = explorerPanel.Parent.AbsoluteSize.y
	if #choices == 0 then return end
	
	table.sort(choices, function(a,b) return a.Name < b.Name end)

	local frame = Instance.new("Frame")	
	frame.Name = "InsertObject"
	frame.Size = UDim2.new(0, 200, 1, 0)
	frame.BackgroundTransparency = 1
	frame.Active = true
	
	local menu = nil
	local arrow = nil
	local expanded = false
	local margin = DropDown.BorderSizePixel;
	
	local function hideMenu()
		expanded = false
		--showArrow(DropDown.ArrowColor)
		if frame then 
			--frame:Destroy()
			CurrentInsertObjectWindow.Visible = false
		end
	end
	
	local function showMenu()
		expanded = true
		menu = Instance.new("ScrollingFrame")
		menu.Size = UDim2.new(0,300,1,0)
		menu.CanvasSize = UDim2.new(0, 300, 0, #choices * DropDown.Height)
		menu.Position = UDim2.new(0, margin, 0, 0)
		menu.BackgroundTransparency = 0
		menu.BackgroundColor3 = DropDown.BackColor
		menu.BorderColor3 = DropDown.BorderColor
		menu.BorderSizePixel = DropDown.BorderSizePixel
		menu.TopImage = "rbxasset://textures/blackBkg_square.png"
		menu.MidImage = "rbxasset://textures/blackBkg_square.png"
		menu.BottomImage = "rbxasset://textures/blackBkg_square.png"
		menu.Active = true
		menu.ZIndex = 5
		menu.Parent = frame
		
		--local parentFrameHeight = script.Parent.List.Size.Y.Offset
		--local rowHeight = mouse.Y
		--if (rowHeight + menu.Size.Y.Offset) > parentFrameHeight then
		--	menu.Position = UDim2.new(0, margin, 0, -1 * (#choices * DropDown.Height) - margin)
		--end
		
		local function GetParameters(functionData)
			local paraString = ""
			paraString = paraString.."("
			for i,v in pairs(functionData.Arguments) do
				paraString = paraString..v.Type.." "..v.Name
				if i < #functionData.Arguments then
					paraString = paraString..", "
				end
			end
			paraString = paraString..")"
			return paraString
		end
			
		local function choice(name)
			onClick(name)
			hideMenu()
		end
		
		for i,name in pairs(choices) do
			local option = CreateRightClickMenuItem(name.ReturnType.." "..name.Name..GetParameters(name), function()
				choice(name)
			end,2)
			option.Size = UDim2.new(1, 0, 0, 20)
			option.Position = UDim2.new(0, 0, 0, (i - 1) * DropDown.Height)
			option.ZIndex = menu.ZIndex
			option.Parent = menu
		end
	end


	showMenu()

	
	return frame
end

function CreateInsertObject()
	if not CurrentInsertObjectWindow then return end
	CurrentInsertObjectWindow.Visible = true
	if currentRightClickMenu and CurrentInsertObjectWindow.Visible then
		CurrentInsertObjectWindow.Position = UDim2.new(0,currentRightClickMenu.Position.X.Offset-currentRightClickMenu.Size.X.Offset-6,0,0)
	end
	if CurrentInsertObjectWindow.Visible then
		CurrentInsertObjectWindow.Parent = explorerPanel.Parent
	end
end

function CreateFunctionCaller(oh)
	if CurrentFunctionCallerWindow then
		CurrentFunctionCallerWindow:Destroy()
		CurrentFunctionCallerWindow = nil
	end
	CurrentFunctionCallerWindow = CreateFunctionCallerMenu(
		GetFunctions(),
		"",
		false,
		function(option)
			CurrentFunctionCallerWindow:Destroy()
			CurrentFunctionCallerWindow = nil
			local list = SelectionVar():Get()
			for i,v in pairs(list) do
				local rets = {pcall(function() return (v[option.Name](v)) end)}
				table.remove(rets,1)
				pcall(function() print("Function", option.Name, "on", v, ":", unpack(rets)) end)
			end
			
			DestroyRightClick()
		end
	)
	if currentRightClickMenu and CurrentFunctionCallerWindow then
		CurrentFunctionCallerWindow.Position = UDim2.new(0,currentRightClickMenu.Position.X.Offset-currentRightClickMenu.Size.X.Offset*1.5-2,0,0)
	end
	if CurrentFunctionCallerWindow then
		CurrentFunctionCallerWindow.Parent = explorerPanel.Parent
	end
end

function CreateRightClickMenuItem(text, onClick, insObj)
	local button = Instance.new("TextButton")
	button.Font = DropDown.Font
	button.FontSize = DropDown.FontSize
	button.TextColor3 = DropDown.TextColor
	button.BackgroundColor3 = DropDown.BackColor
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.TextTransparency = 1
	button.Active = true
	
	if text then
		local label = Instance.new("TextLabel", button)
		label.Size = UDim2.new(1, 0, 1, 0)
		label.Font = DropDown.Font
		label.FontSize = Enum.FontSize.Size11
		label.TextColor3 = DropDown.TextColor
		label.TextXAlignment = DropDown.TextXAlignment
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.ZIndex = 5

		label.Text = text
		button.Text = text
		

		if insObj == 2 then
			label.FontSize = Enum.FontSize.Size11
			label.Size = UDim2.new(1, -16, 1, 0)
			label.Position = UDim2.new(0, 16, 0, 0)
		else
			if insObj == 1 or ExplorerIndex[text] then
				local newIcon = Icon(nil,ExplorerIndex[text] or 0)
				newIcon.Position = UDim2.new(0,2,0,2)
				newIcon.Size = UDim2.new(0,16,0,16)
				newIcon.IconMap.ZIndex = 5
				newIcon.Parent = button
			end
			
			label.Size = UDim2.new(1, -32, 1, 0)
			label.Position = UDim2.new(0, 32, 0, 0)
		end
		
		
		button.MouseEnter:connect(function()
			button.TextColor3 = DropDown.TextColorOver
			button.BackgroundColor3 = DropDown.BackColorOver
			if not insObj and CurrentInsertObjectWindow then
				if CurrentInsertObjectWindow.Visible == false and button.Text == "Insert Object" then
					CreateInsertObject()
				elseif CurrentInsertObjectWindow.Visible and button.Text ~= "Insert Object" then
					CurrentInsertObjectWindow.Visible = false
				end
			end
			if not insObj then
				if CurrentFunctionCallerWindow and button.Text ~= "Call Function" then
					CurrentFunctionCallerWindow:Destroy()
					CurrentFunctionCallerWindow = nil
				elseif button.Text == "Call Function" then
					CreateFunctionCaller()
				end
			end
		end)
		button.MouseLeave:connect(function()
			button.TextColor3 = DropDown.TextColor
			button.BackgroundColor3 = DropDown.BackColor
		end)
		button.MouseButton1Click:connect(function()
			button.TextColor3 = DropDown.TextColor
			button.BackgroundColor3 = DropDown.BackColor
			onClick(text)
		end)	
	else
		local sep = Instance.new("Frame", button)
		sep.Size = UDim2.new(1, -20, 0, 1)
		sep.Position = UDim2.new(0, 16, 0, 2)
		sep.BackgroundColor3 = DropDown.BorderColor
		sep.BorderSizePixel = 0
		sep.ZIndex = 5
	end
	
	return button
end

function CreateRightClickMenu(choices, currentChoice, readOnly, onClick)
	local mouse = game:GetService("Players").LocalPlayer:GetMouse()

	local frame = Instance.new("TextButton")	
	frame.Name = "DropDown"
	frame.Size = UDim2.new(0, 200, 0, 0)
	frame.AutoButtonColor = false
	frame.Style = Enum.ButtonStyle.RobloxRoundDropdownButton
	frame.Active = false
	
	local menu = nil
	local arrow = nil
	local expanded = false
	local margin = DropDown.BorderSizePixel;
	
	local function hideMenu()
		expanded = false
		if frame then 
			frame:Destroy()
			DestroyRightClick()
		end
	end
	
	local function showMenu()
		expanded = true
		menu = Instance.new("Frame")
		menu.Size = UDim2.new(0, 200, 0, 0)
		
		for i,name in pairs(choices) do
			if name then
				menu.Size = menu.Size + UDim2.new(0, 0, 0, 20)
			else
				menu.Size = menu.Size + UDim2.new(0, 0, 0, 7)
			end		
		end
		
		frame.Size = menu.Size + UDim2.new(0, 0, 0, 6)
		
		menu.Position = UDim2.new(0, -16, 0, -10)
		menu.BackgroundTransparency = 0
		menu.BackgroundColor3 = DropDown.BackColor
		menu.BorderColor3 = DropDown.BorderColor
		menu.BorderSizePixel = DropDown.BorderSizePixel
		menu.Active = true
		menu.ZIndex = 5
		menu.Parent = frame
		
		local function choice(name)
			onClick(name)
			hideMenu()
		end
		
		local previous		
		for i,name in pairs(choices) do
			local option = CreateRightClickMenuItem(name, function()
				choice(name)
			end)
			
			if name then
				option.Size = UDim2.new(1, 0, 0, 20)
			else
				option.Size = UDim2.new(1, 0, 0, 7)
			end
			
			if previous then
				option.Position = UDim2.new(0, 0, 0, previous.Position.Height.Offset + previous.Size.Height.Offset)
			end
			
			option.ZIndex = menu.ZIndex
			option.Parent = menu
			
			previous = option			
		end
	end

	showMenu()
	
	return frame
end

function checkMouseInGui(gui)
	if gui == nil then return false end
	local plrMouse = game:GetService("Players").LocalPlayer:GetMouse()
	local guiPosition = gui.AbsolutePosition
	local guiSize = gui.AbsoluteSize	
	
	if plrMouse.X >= guiPosition.x and plrMouse.X <= guiPosition.x + guiSize.x and plrMouse.Y >= guiPosition.y and plrMouse.Y <= guiPosition.y + guiSize.y then
		return true
	else
		return false
	end
end

local clipboard = {}
local function delete(o)
	o.Parent = nil
end

local getTextWidth do
	local text = Create('TextLabel',{
		Name = "TextWidth";
		TextXAlignment = 'Left';
		TextYAlignment = 'Center';
		Font = FONT;
		FontSize = FONT_SIZE;
		Text = "";
		Position = UDim2.new(0,0,0,0);
		Size = UDim2.new(1,0,1,0);
		Visible = false;
		Parent = explorerPanel;
	})
	function getTextWidth(s)
		text.Text = s
		return text.TextBounds.x
	end
end

local nameScanned = false
-- Holds the game tree converted to a list.
local TreeList = {}
-- Matches objects to their tree node representation.
local NodeLookup = {}

local nodeWidth = 0

local QuickButtons = {}

function filteringWorkspace()
	if explorerFilter.Text ~= "" and explorerFilter.Text ~= "Filter Workspace" then
		return true
	end
	return false
end

function lookForAName(obj,name)
	for i,v in pairs(obj:GetChildren()) do
		if string.find(string.lower(v.Name),string.lower(name)) then nameScanned = true end
		lookForAName(v,name)
	end
end

function scanName(obj)
	nameScanned = false
	if string.find(string.lower(obj.Name),string.lower(explorerFilter.Text)) then
		nameScanned = true
	else
		lookForAName(obj,explorerFilter.Text)
	end
	return nameScanned
end

function updateActions()
	for i,v in pairs(QuickButtons) do
		if v.Cond() then
			v.Toggle(true)
		else
			v.Toggle(false)
		end
	end
end

local updateList,rawUpdateList,updateScroll,rawUpdateSize do
	local function r(t)
		for i = 1,#t do
			if not filteringWorkspace() or scanName(t[i].Object) then
				if t.Object == game then
					if childrenGame[t[i].Object] then
						TreeList[#TreeList+1] = t[i]
		
						local w = (t[i].Depth)*(2+ENTRY_PADDING+GUI_SIZE) + 2 + ENTRY_SIZE + 4 + getTextWidth(t[i].Object.Name) + 4
						if w > nodeWidth then
							nodeWidth = w
						end
						if t[i].Expanded or filteringWorkspace() then
							r(t[i])
						end
					end
				else
					TreeList[#TreeList+1] = t[i]
	
					local w = (t[i].Depth)*(2+ENTRY_PADDING+GUI_SIZE) + 2 + ENTRY_SIZE + 4 + getTextWidth(t[i].Object.Name) + 4
					if w > nodeWidth then
						nodeWidth = w
					end
					if t[i].Expanded or filteringWorkspace() then
						r(t[i])
					end
				end
			end
		end
	end

	function rawUpdateSize()
		scrollBarH.TotalSpace = nodeWidth
		scrollBarH.VisibleSpace = listFrame.AbsoluteSize.x
		scrollBarH:Update()
		local visible = scrollBarH:CanScrollDown() or scrollBarH:CanScrollUp()
		scrollBarH.GUI.Visible = visible

		listFrame.Size = UDim2.new(1,-GUI_SIZE,1,-GUI_SIZE*(visible and 1 or 0) - HEADER_SIZE)

		scrollBar.VisibleSpace = math.ceil(listFrame.AbsoluteSize.y/ENTRY_BOUND)
		scrollBar.GUI.Size = UDim2.new(0,GUI_SIZE,1,-GUI_SIZE*(visible and 1 or 0) - HEADER_SIZE)
		
		scrollBar.TotalSpace = #TreeList+1
		scrollBar:Update()
	end

	function rawUpdateList()
		-- Clear then repopulate the entire list. It appears to be fast enough.
		TreeList = {}
		nodeWidth = 0
		r(NodeLookup[game])
		r(NodeLookup[DexOutput])
		if DexStorageEnabled then
			r(NodeLookup[DexStorage])
		end
		if NilStorageEnabled then
			r(NodeLookup[NilStorage])
		end
		r(NodeLookup[HiddenEntries])
		r(NodeLookup[HiddenGame])
		rawUpdateSize()
		updateActions()
	end

	-- Adding or removing large models will cause many updates to occur. We
	-- can reduce the number of updates by creating a delay, then dropping any
	-- updates that occur during the delay.
	local updatingList = false
	function updateList()
		if updatingList then return end
		updatingList = true
		wait(0.25)
		updatingList = false
		rawUpdateList()
	end

	local updatingScroll = false
	function updateScroll()
		if updatingScroll then return end
		updatingScroll = true
		wait(0.25)
		updatingScroll = false
		scrollBar:Update()
	end
end

local Selection do
	local bindGetSelection = explorerPanel:FindFirstChild("GetSelection")
	if not bindGetSelection then
		bindGetSelection = Create('BindableFunction',{Name = "GetSelection"})
		bindGetSelection.Parent = explorerPanel
	end

	local bindSetSelection = explorerPanel:FindFirstChild("SetSelection")
	if not bindSetSelection then
		bindSetSelection = Create('BindableFunction',{Name = "SetSelection"})
		bindSetSelection.Parent = explorerPanel
	end

	local bindSelectionChanged = explorerPanel:FindFirstChild("SelectionChanged")
	if not bindSelectionChanged then
		bindSelectionChanged = Create('BindableEvent',{Name = "SelectionChanged"})
		bindSelectionChanged.Parent = explorerPanel
	end

	local SelectionList = {}
	local SelectionSet = {}
	local Updates = true
	Selection = {
		Selected = SelectionSet;
		List = SelectionList;
	}

	local function addObject(object)
		-- list update
		local lupdate = false
		-- scroll update
		local supdate = false

		if not SelectionSet[object] then
			local node = NodeLookup[object]
			if node then
				table.insert(SelectionList,object)
				SelectionSet[object] = true
				node.Selected = true

				-- expand all ancestors so that selected node becomes visible
				node = node.Parent
				while node do
					if not node.Expanded then
						node.Expanded = true
						lupdate = true
					end
					node = node.Parent
				end
				supdate = true
			end
		end
		return lupdate,supdate
	end

	Selection.Finding = false
	Selection.Found = {}
	
	function Selection:Set(objects)
		if Selection.Finding then
			Selection.Found = objects	
		end
		
		local lupdate = false
		local supdate = false

		if #SelectionList > 0 then
			for i = 1,#SelectionList do
				local object = SelectionList[i]
				local node = NodeLookup[object]
				if node then
					node.Selected = false
					SelectionSet[object] = nil
				end
			end

			SelectionList = {}
			Selection.List = SelectionList
			supdate = true
		end

		for i = 1,#objects do
			local l,s = addObject(objects[i])
			lupdate = l or lupdate
			supdate = s or supdate
		end

		if lupdate then
			rawUpdateList()
			supdate = true
		elseif supdate then
			scrollBar:Update()
		end

		if supdate then
			bindSelectionChanged:Fire()
			updateActions()
		end
	end

	function Selection:Add(object)
		local l,s = addObject(object)
		if l then
			rawUpdateList()
			if Updates then
				bindSelectionChanged:Fire()
				updateActions()
			end
		elseif s then
			scrollBar:Update()
			if Updates then
				bindSelectionChanged:Fire()
				updateActions()
			end
		end
	end
	
	function Selection:StopUpdates()
		Updates = false
	end
	
	function Selection:ResumeUpdates()
		Updates = true
		bindSelectionChanged:Fire()
		updateActions()
	end

	function Selection:Remove(object,noupdate)
		if SelectionSet[object] then
			local node = NodeLookup[object]
			if node then
				node.Selected = false
				SelectionSet[object] = nil
				for i = 1,#SelectionList do
					if SelectionList[i] == object then
						table.remove(SelectionList,i)
						break
					end
				end

				if not noupdate then
					scrollBar:Update()
				end
				bindSelectionChanged:Fire()
				updateActions()
			end
		end
	end

	function Selection:Get()
		local list = {}
		for i = 1,#SelectionList do
			if SelectionList[i] ~= HiddenEntriesMain and SelectionList[i] ~= DexOutputMain then
				table.insert(list, SelectionList[i])
			end
		end
		return list
	end

	bindSetSelection.OnInvoke = function(...)
		Selection:Set(...)
	end

	bindGetSelection.OnInvoke = function()
		return Selection:Get()
	end
end

function CreateCaution(title,msg)
	local newCaution = CautionWindow
	newCaution.Visible = true
	newCaution.Title.Text = title
	newCaution.MainWindow.Desc.Text = msg
	newCaution.MainWindow.Ok.MouseButton1Up:connect(function()
		newCaution.Visible = false
	end)
end

function CreateTableCaution(title,msg)
	if type(msg) ~= "table" then return CreateCaution(title,tostring(msg)) end
	local newCaution = TableCautionWindow:Clone()
	newCaution.Title.Text = title
	
	local TableList = newCaution.MainWindow.TableResults
	local TableTemplate = newCaution.MainWindow.TableTemplate
	
	for i,v in pairs(msg) do
		local newResult = TableTemplate:Clone()
		newResult.Type.Text = type(v)
		newResult.Value.Text = tostring(v)
		newResult.Position = UDim2.new(0,0,0,#TableList:GetChildren() * 20)
		newResult.Parent = TableList
		TableList.CanvasSize = UDim2.new(0,0,0,#TableList:GetChildren() * 20)
		newResult.Visible = true
	end
	newCaution.Parent = explorerPanel.Parent
	newCaution.Visible = true
	newCaution.MainWindow.Ok.MouseButton1Up:connect(function()
		newCaution:Destroy()
	end)
end

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
	elseif type == "Number" then
		return tonumber(value)
	elseif type == "String" then
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
	elseif type == "Script" then
		local success,err = ypcall(function()
		return loadstring(
			"return "..value
		)()
		end)
		if err then
			return nil
		end
	else
		return nil
	end
end

local function ToPropValue(value,type)
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
	elseif string.sub(value,1,4) == "Enum" then
		local getEnum = value
		while true do
			local x,y = string.find(getEnum,".")
			if y then
				getEnum = string.sub(getEnum,y+1)
			else
				break
			end
		end
		print(getEnum)
		return getEnum
	else
		return nil
	end
end

function PromptRemoteCaller(inst)
	if CurrentRemoteWindow then
		CurrentRemoteWindow:Destroy()
		CurrentRemoteWindow = nil
	end
	CurrentRemoteWindow = RemoteWindow:Clone()
	CurrentRemoteWindow.Parent = explorerPanel.Parent
	CurrentRemoteWindow.Visible = true
	
	local displayValues = false
	
	local ArgumentList = CurrentRemoteWindow.MainWindow.Arguments
	local ArgumentTemplate = CurrentRemoteWindow.MainWindow.ArgumentTemplate
	
	if inst:IsA("RemoteEvent") then
		CurrentRemoteWindow.Title.Text = "Fire Event"
		CurrentRemoteWindow.MainWindow.Ok.Text = "Fire"
		CurrentRemoteWindow.MainWindow.DisplayReturned.Visible = false
		CurrentRemoteWindow.MainWindow.Desc2.Visible = false
	end
	
	local newArgument = ArgumentTemplate:Clone()
	newArgument.Parent = ArgumentList
	newArgument.Visible = true
	newArgument.Type.MouseButton1Down:connect(function()
		createDDown(newArgument.Type,function(choice)
			newArgument.Type.Text = choice
		end,"Script","Number","String","Color3","Vector3","Vector2","UDim2","NumberRange")
	end)
	
	CurrentRemoteWindow.MainWindow.Ok.MouseButton1Up:connect(function()
		if CurrentRemoteWindow and inst.Parent ~= nil then
			local MyArguments = {}
			for i,v in pairs(ArgumentList:GetChildren()) do
				table.insert(MyArguments,ToValue(v.Value.Text,v.Type.Text))
			end
			if inst:IsA("RemoteFunction") then
				if displayValues then
					spawn(function()
						local myResults = inst:InvokeServer(unpack(MyArguments))
						if myResults then
							CreateTableCaution("Remote Caller",myResults)
						else
							CreateCaution("Remote Caller","This remote did not return anything.")
						end
					end)
				else
					spawn(function()
						inst:InvokeServer(unpack(MyArguments))
					end)
				end
			else
				inst:FireServer(unpack(MyArguments))
			end
			CurrentRemoteWindow:Destroy()
			CurrentRemoteWindow = nil
		end
	end)
	
	CurrentRemoteWindow.MainWindow.Add.MouseButton1Up:connect(function()
		if CurrentRemoteWindow then
			local newArgument = ArgumentTemplate:Clone()
			newArgument.Position = UDim2.new(0,0,0,#ArgumentList:GetChildren() * 20)
			newArgument.Parent = ArgumentList
			ArgumentList.CanvasSize = UDim2.new(0,0,0,#ArgumentList:GetChildren() * 20)
			newArgument.Visible = true
			newArgument.Type.MouseButton1Down:connect(function()
				createDDown(newArgument.Type,function(choice)
					newArgument.Type.Text = choice
				end,"Script","Number","String","Color3","Vector3","Vector2","UDim2","NumberRange")
			end)
		end
	end)
	
	CurrentRemoteWindow.MainWindow.Subtract.MouseButton1Up:connect(function()
		if CurrentRemoteWindow then
			if #ArgumentList:GetChildren() > 1 then
				ArgumentList:GetChildren()[#ArgumentList:GetChildren()]:Destroy()
				ArgumentList.CanvasSize = UDim2.new(0,0,0,#ArgumentList:GetChildren() * 20)
			end
		end
	end)
	
	CurrentRemoteWindow.MainWindow.Cancel.MouseButton1Up:connect(function()
		if CurrentRemoteWindow then
			CurrentRemoteWindow:Destroy()
			CurrentRemoteWindow = nil
		end
	end)
	
	CurrentRemoteWindow.MainWindow.DisplayReturned.MouseButton1Up:connect(function()
		if displayValues then
			displayValues = false
			CurrentRemoteWindow.MainWindow.DisplayReturned.enabled.Visible = false
		else
			displayValues = true
			CurrentRemoteWindow.MainWindow.DisplayReturned.enabled.Visible = true
		end
	end)
end

function PromptSaveInstance(inst)
	if CurrentSaveInstanceWindow then
		CurrentSaveInstanceWindow:Destroy()
		CurrentSaveInstanceWindow = nil
		if explorerPanel.Parent:FindFirstChild("SaveInstanceOverwriteCaution") then
			explorerPanel.Parent.SaveInstanceOverwriteCaution:Destroy()
		end
	end
	
	CurrentSaveInstanceWindow = SaveInstanceWindow:Clone()
	CurrentSaveInstanceWindow.Parent = explorerPanel.Parent
	CurrentSaveInstanceWindow.Visible = true
	
	local filename = CurrentSaveInstanceWindow.MainWindow.FileName
	local saveObjects = true
	local overwriteCaution = false
	
	CurrentSaveInstanceWindow.MainWindow.Save.MouseButton1Up:connect(function()
		if readfile then
			if readfile(filename.Text..".rbxmx") then
				if not overwriteCaution then
					overwriteCaution = true
					local newCaution = ConfirmationWindow:Clone()
					newCaution.Name = "SaveInstanceOverwriteCaution"
					newCaution.MainWindow.Desc.Text = "The file, "..filename.Text..".rbxmx, already exists. Overwrite?"
					newCaution.Parent = explorerPanel.Parent
					newCaution.Visible = true
					newCaution.MainWindow.Yes.MouseButton1Up:connect(function()
						ypcall(function()
							SaveInstance(inst,filename.Text..".rbxmx",not saveObjects)
						end)
						overwriteCaution = false
						newCaution:Destroy()
						if CurrentSaveInstanceWindow then
							CurrentSaveInstanceWindow:Destroy()
							CurrentSaveInstanceWindow = nil
						end
					end)
					newCaution.MainWindow.No.MouseButton1Up:connect(function()
						overwriteCaution = false
						newCaution:Destroy()
					end)
				end
			else
				ypcall(function()
					SaveInstance(inst,filename.Text..".rbxmx",not saveObjects)
				end)
				if CurrentSaveInstanceWindow then
					CurrentSaveInstanceWindow:Destroy()
					CurrentSaveInstanceWindow = nil
					if explorerPanel.Parent:FindFirstChild("SaveInstanceOverwriteCaution") then
						explorerPanel.Parent.SaveInstanceOverwriteCaution:Destroy()
					end
				end
			end
		else
			ypcall(function()
				if SaveInstance then
					SaveInstance(inst,filename.Text..".rbxmx",not saveObjects)
				else
					_G.SaveInstance(inst,filename.Text,not saveObjects)
				end
			end)
			if CurrentSaveInstanceWindow then
				CurrentSaveInstanceWindow:Destroy()
				CurrentSaveInstanceWindow = nil
				if explorerPanel.Parent:FindFirstChild("SaveInstanceOverwriteCaution") then
					explorerPanel.Parent.SaveInstanceOverwriteCaution:Destroy()
				end
			end
		end
	end)
	CurrentSaveInstanceWindow.MainWindow.Cancel.MouseButton1Up:connect(function()
		if CurrentSaveInstanceWindow then
			CurrentSaveInstanceWindow:Destroy()
			CurrentSaveInstanceWindow = nil
			if explorerPanel.Parent:FindFirstChild("SaveInstanceOverwriteCaution") then
				explorerPanel.Parent.SaveInstanceOverwriteCaution:Destroy()
			end
		end
	end)
	CurrentSaveInstanceWindow.MainWindow.SaveObjects.MouseButton1Up:connect(function()
		if saveObjects then
			saveObjects = false
			CurrentSaveInstanceWindow.MainWindow.SaveObjects.enabled.Visible = false
		else
			saveObjects = true
			CurrentSaveInstanceWindow.MainWindow.SaveObjects.enabled.Visible = true
		end
	end)
end

function DestroyRightClick()
	if currentRightClickMenu then
		currentRightClickMenu:Destroy()
		currentRightClickMenu = nil
	end
	if CurrentInsertObjectWindow and CurrentInsertObjectWindow.Visible then
		CurrentInsertObjectWindow.Visible = false
	end
end

function rightClickMenu(sObj)
	local mouse = game:GetService("Players").LocalPlayer:GetMouse()
	
	currentRightClickMenu = CreateRightClickMenu(
		{"Cut","Copy","Paste Into","Duplicate","Delete",false,"Group","Ungroup","Select Children",false,"Teleport To","Call Function","Call Remote",false,"Insert Part","Insert Object","Save to File...",false,"View Script"},
		"",
		false,
		function(option)
			if option == "Cut" then
				if not Option.Modifiable then return end
				clipboard = {}
				local list = Selection.List
				local cut = {}
				for i = 1,#list do
					local _, obj = pcall(function() return list[i]:Clone() end)
					if obj then
						table.insert(clipboard,obj)
						table.insert(cut,list[i])
					end
				end
				for i = 1,#cut do
					pcall(delete,cut[i])
				end
				updateActions()
			elseif option == "Copy" then
				if not Option.Modifiable then return end
				clipboard = {}
				local list = Selection.List
				for i = 1,#list do
					local _, obj = pcall(function() return list[i]:Clone() end)
					if obj then
						table.insert(clipboard,obj)
					end
				end
				updateActions()
			elseif option == "Paste Into" then
				if not Option.Modifiable then return end
				local parent = Selection.List[1] or workspace
				for i = 1,#clipboard do
					if (clipboard[i]) then
						pcall(function()
							clipboard[i]:Clone().Parent = parent
						end)
					end
				end
			elseif option == "Duplicate" then
				if not Option.Modifiable then return end
				local list = Selection:Get()
				for i = 1,#list do
					local _, obj = pcall(function() return list[i]:Clone() end)
					if obj then
						obj.Parent = Selection.List[1].Parent or workspace
					end					
				end
			elseif option == "Delete" then
				if not Option.Modifiable then return end
				local list = Selection:Get()
				for i = 1,#list do
					pcall(delete,list[i])
				end
				Selection:Set({})
			elseif option == "Group" then
				if not Option.Modifiable then return end
				local newModel = Instance.new("Model")
				local list = Selection:Get()
				newModel.Parent = Selection.List[1].Parent or workspace
				for i = 1,#list do
					list[i].Parent = newModel
				end
				Selection:Set({})
			elseif option == "Ungroup" then
				if not Option.Modifiable then return end
				local ungrouped = {}
				local list = Selection:Get()
				for i = 1,#list do
					if list[i]:IsA("Model") then
						for i2,v2 in pairs(list[i]:GetChildren()) do
							v2.Parent = list[i].Parent or workspace
							table.insert(ungrouped,v2)
						end		
						pcall(delete,list[i])			
					end
				end
				Selection:Set({})
				if SettingsRemote:Invoke("SelectUngrouped") then
					for i,v in pairs(ungrouped) do
						Selection:Add(v)
					end
				end
			elseif option == "Select Children" then
				if not Option.Modifiable then return end
				local list = Selection:Get()
				Selection:Set({})
				Selection:StopUpdates()
				for i = 1,#list do
					for i2,v2 in pairs(list[i]:GetChildren()) do
						Selection:Add(v2)
					end
				end
				Selection:ResumeUpdates()
			elseif option == "Teleport To" then
				if not Option.Modifiable then return end
				local list = Selection:Get()
				for i = 1,#list do
					if list[i]:IsA("BasePart") then
						pcall(function()
							game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.CFrame = list[i].CFrame
						end)
						break
					end
				end
			elseif option == "Insert Part" then
				if not Option.Modifiable then return end
				local insertedParts = {}
				local list = Selection:Get()
				for i = 1,#list do
					pcall(function()
						local newPart = Instance.new("Part")
						newPart.Parent = list[i]
						newPart.CFrame = CFrame.new(game:GetService("Players").LocalPlayer.Character.Head.Position) + Vector3.new(0,3,0)
						table.insert(insertedParts,newPart)
					end)
				end
			elseif option == "Save to File..." then
				if not Option.Modifiable then return end
				local list = Selection:Get()
				if #list == 1 then
					list[1].Archivable = true
					ypcall(function()SaveInstance(list[1],tostring(list[1]) .. tick())end)
				elseif #list > 1 then
					local newModel = Instance.new("Model")
					newModel.Name = "SavedInstances"
					for i = 1,#list do
						ypcall(function()
							list[i].Archivable = true
							list[i]:Clone().Parent = newModel
						end)
					end
					ypcall(function()SaveInstance(newModel,"SavedInstances" .. tick())end)
				end
			elseif option == "Call Remote" then
				if not Option.Modifiable then return end
				local list = Selection:Get()
				for i = 1,#list do
					if list[i]:IsA("RemoteFunction") or list[i]:IsA("RemoteEvent") then
						PromptRemoteCaller(list[i])
						break
					end
				end
			elseif option == "View Script" then
				if not Option.Modifiable then return end
				local list = Selection:Get()
				for i = 1,#list do
					if list[i]:IsA("LocalScript") or list[i]:IsA("ModuleScript") then
						ScriptEditorEvent:Fire(list[i])
					end
				end
			end
	end)
	currentRightClickMenu.Parent = explorerPanel.Parent
	currentRightClickMenu.Position = UDim2.new(0,mouse.X,0,mouse.Y)
	if currentRightClickMenu.AbsolutePosition.X + currentRightClickMenu.AbsoluteSize.X > explorerPanel.AbsolutePosition.X + explorerPanel.AbsoluteSize.X then
		currentRightClickMenu.Position = UDim2.new(0, explorerPanel.AbsolutePosition.X + explorerPanel.AbsoluteSize.X - currentRightClickMenu.AbsoluteSize.X, 0, mouse.Y)
	end
end

local function cancelReparentDrag()end
local function cancelSelectDrag()end
do
	local listEntries = {}
	local nameConnLookup = {}

	local mouseDrag = Create('ImageButton',{
		Name = "MouseDrag";
		Position = UDim2.new(-0.25,0,-0.25,0);
		Size = UDim2.new(1.5,0,1.5,0);
		Transparency = 1;
		AutoButtonColor = false;
		Active = true;
		ZIndex = 10;
	})
	local function dragSelect(last,add,button)
		local connDrag
		local conUp

		conDrag = mouseDrag.MouseMoved:connect(function(x,y)
			local pos = Vector2.new(x,y) - listFrame.AbsolutePosition
			local size = listFrame.AbsoluteSize
			if pos.x < 0 or pos.x > size.x or pos.y < 0 or pos.y > size.y then return end

			local i = math.ceil(pos.y/ENTRY_BOUND) + scrollBar.ScrollIndex
			-- Mouse may have made a large step, so interpolate between the
			-- last index and the current.
			for n = i<last and i or last, i>last and i or last do
				local node = TreeList[n]
				if node then
					if add then
						Selection:Add(node.Object)
					else
						Selection:Remove(node.Object)
					end
				end
			end
			last = i
		end)

		function cancelSelectDrag()
			mouseDrag.Parent = nil
			conDrag:disconnect()
			conUp:disconnect()
			function cancelSelectDrag()end
		end

		conUp = mouseDrag[button]:connect(cancelSelectDrag)

		mouseDrag.Parent = GetScreen(listFrame)
	end

	local function dragReparent(object,dragGhost,clickPos,ghostOffset)
		local connDrag
		local conUp
		local conUp2

		local parentIndex = nil
		local dragged = false

		local parentHighlight = Create('Frame',{
			Transparency = 1;
			Visible = false;
			Create('Frame',{
				BorderSizePixel = 0;
				BackgroundColor3 = Color3.new(0,0,0);
				BackgroundTransparency = 0.1;
				Position = UDim2.new(0,0,0,0);
				Size = UDim2.new(1,0,0,1);
			});
			Create('Frame',{
				BorderSizePixel = 0;
				BackgroundColor3 = Color3.new(0,0,0);
				BackgroundTransparency = 0.1;
				Position = UDim2.new(1,0,0,0);
				Size = UDim2.new(0,1,1,0);
			});
			Create('Frame',{
				BorderSizePixel = 0;
				BackgroundColor3 = Color3.new(0,0,0);
				BackgroundTransparency = 0.1;
				Position = UDim2.new(0,0,1,0);
				Size = UDim2.new(1,0,0,1);
			});
			Create('Frame',{
				BorderSizePixel = 0;
				BackgroundColor3 = Color3.new(0,0,0);
				BackgroundTransparency = 0.1;
				Position = UDim2.new(0,0,0,0);
				Size = UDim2.new(0,1,1,0);
			});
		})
		SetZIndex(parentHighlight,9)

		conDrag = mouseDrag.MouseMoved:connect(function(x,y)
			local dragPos = Vector2.new(x,y)
			if dragged then
				local pos = dragPos - listFrame.AbsolutePosition
				local size = listFrame.AbsoluteSize

				parentIndex = nil
				parentHighlight.Visible = false
				if pos.x >= 0 and pos.x <= size.x and pos.y >= 0 and pos.y <= size.y + ENTRY_SIZE*2 then
					local i = math.ceil(pos.y/ENTRY_BOUND-2)
					local node = TreeList[i + scrollBar.ScrollIndex]
					if node and node.Object ~= object and not object:IsAncestorOf(node.Object) then
						parentIndex = i
						local entry = listEntries[i]
						if entry then
							parentHighlight.Visible = true
							parentHighlight.Position = UDim2.new(0,1,0,entry.AbsolutePosition.y-listFrame.AbsolutePosition.y)
							parentHighlight.Size = UDim2.new(0,size.x-4,0,entry.AbsoluteSize.y)
						end
					end
				end

				dragGhost.Position = UDim2.new(0,dragPos.x+ghostOffset.x,0,dragPos.y+ghostOffset.y)
			elseif (clickPos-dragPos).magnitude > 8 then
				dragged = true
				SetZIndex(dragGhost,9)
				dragGhost.IndentFrame.Transparency = 0.25
				dragGhost.IndentFrame.EntryText.TextColor3 = GuiColor.TextSelected
				dragGhost.Position = UDim2.new(0,dragPos.x+ghostOffset.x,0,dragPos.y+ghostOffset.y)
				dragGhost.Parent = GetScreen(listFrame)
				parentHighlight.Parent = listFrame
			end
		end)

		function cancelReparentDrag()
			mouseDrag.Parent = nil
			conDrag:disconnect()
			conUp:disconnect()
			conUp2:disconnect()
			dragGhost:Destroy()
			parentHighlight:Destroy()
			function cancelReparentDrag()end
		end

		local wasSelected = Selection.Selected[object]
		if not wasSelected and Option.Selectable then
			Selection:Set({object})
		end

		conUp = mouseDrag.MouseButton1Up:connect(function()
			cancelReparentDrag()
			if dragged then
				if parentIndex then
					local parentNode = TreeList[parentIndex + scrollBar.ScrollIndex]
					if parentNode then
						parentNode.Expanded = true

						local parentObj = parentNode.Object
						local function parent(a,b)
							a.Parent = b
						end
						if Option.Selectable then
							local list = Selection.List
							for i = 1,#list do
								pcall(parent,list[i],parentObj)
							end
						else
							pcall(parent,object,parentObj)
						end
					end
				end
			else
				-- do selection click
				if wasSelected and Option.Selectable then
					Selection:Set({})
				end
			end
		end)
		conUp2 = mouseDrag.MouseButton2Down:connect(function()
			cancelReparentDrag()
		end)

		mouseDrag.Parent = GetScreen(listFrame)
	end

	local entryTemplate = Create('ImageButton',{
		Name = "Entry";
		Transparency = 1;
		AutoButtonColor = false;
		Position = UDim2.new(0,0,0,0);
		Size = UDim2.new(1,0,0,ENTRY_SIZE);
		Create('Frame',{
			Name = "IndentFrame";
			BackgroundTransparency = 1;
			BackgroundColor3 = GuiColor.Selected;
			BorderColor3 = GuiColor.BorderSelected;
			Position = UDim2.new(0,0,0,0);
			Size = UDim2.new(1,0,1,0);
			Create(Icon('ImageButton',0),{
				Name = "Expand";
				AutoButtonColor = false;
				Position = UDim2.new(0,-GUI_SIZE,0.5,-GUI_SIZE/2);
				Size = UDim2.new(0,GUI_SIZE,0,GUI_SIZE);
			});
			Create(Icon(nil,0),{
				Name = "ExplorerIcon";
				Position = UDim2.new(0,2+ENTRY_PADDING,0.5,-GUI_SIZE/2);
				Size = UDim2.new(0,GUI_SIZE,0,GUI_SIZE);
			});
			Create('TextLabel',{
				Name = "EntryText";
				BackgroundTransparency = 1;
				TextColor3 = GuiColor.Text;
				TextXAlignment = 'Left';
				TextYAlignment = 'Center';
				Font = FONT;
				FontSize = FONT_SIZE;
				Text = "";
				Position = UDim2.new(0,2+ENTRY_SIZE+4,0,0);
				Size = UDim2.new(1,-2,1,0);
			});
		});
	})

	function scrollBar.UpdateCallback(self)
		for i = 1,self.VisibleSpace do
			local node = TreeList[i + self.ScrollIndex]
			if node then
				local entry = listEntries[i]
				if not entry then
					entry = Create(entryTemplate:Clone(),{
						Position = UDim2.new(0,2,0,ENTRY_BOUND*(i-1)+2);
						Size = UDim2.new(0,nodeWidth,0,ENTRY_SIZE);
						ZIndex = listFrame.ZIndex;
					})
					listEntries[i] = entry

					local expand = entry.IndentFrame.Expand
						expand.MouseEnter:connect(function()
						local node = TreeList[i + self.ScrollIndex]
						if #node > 0 then
							if node.Object ~= HiddenEntriesMain then
								if node.Expanded then
									Icon(expand,NODE_EXPANDED_OVER)
								else
									Icon(expand,NODE_COLLAPSED_OVER)
								end
							else
								if node.HiddenExpanded then
									Icon(expand,NODE_EXPANDED_OVER)
								else
									Icon(expand,NODE_COLLAPSED_OVER)
								end								
							end
						end
					end)
					expand.MouseLeave:connect(function()
						pcall(function()
							local node = TreeList[i + self.ScrollIndex]
							if node.Object == HiddenEntriesMain then
								if node.HiddenExpanded then
									Icon(expand,NODE_EXPANDED)
								else
									Icon(expand,NODE_COLLAPSED)
								end
								return
							end
							if #node > 0 then
								if node.Expanded then
									Icon(expand,NODE_EXPANDED)
								else
									Icon(expand,NODE_COLLAPSED)
								end
							end
						end)
					end)
					
					local function radd(o,refresh,parent)	
						addObject(o,refresh,parent)					
						local s,children = pcall(function() return o:GetChildren() end, o)
						if s then
							for i = 1,#children do								
								radd(children[i],refresh,o)
							end
						end
					end
					
					expand.MouseButton1Down:connect(function()
						local node = TreeList[i + self.ScrollIndex]
						if #node > 0 then
							if node.Object ~= HiddenEntriesMain then				
								node.Expanded = not node.Expanded
							else	
								if not MuteHiddenItems then
									NodeLookup[HiddenGame] = {
										Object = HiddenGame;
										Parent = nil;
										Index = 0;
										Expanded = true;
									}
								else
									for i,v in pairs(game:GetChildren()) do
										if not childrenGame[v] then
											radd(v, true, HiddenGame)
										end
									end									
								end
								
								MuteHiddenItems = not MuteHiddenItems
								node.HiddenExpanded = not node.HiddenExpanded
							end
							if node.Object == explorerPanel.Parent and node.Expanded then
								CreateCaution("Warning", "Modifying the contents of this Instance could cause erratic or unstable behavior. Proceed with caution.")
							end
							-- use raw update so the list updates instantly
							rawUpdateList()
						end
					end)

					entry.MouseButton1Down:connect(function(x,y)
						local node = TreeList[i + self.ScrollIndex]
						DestroyRightClick()
						if GetAwaitRemote:Invoke() then
							bindSetAwaiting:Fire(node.Object)
							return
						end
						
						if node.Object == HiddenEntriesMain then
							return
						end
						
						if not HoldingShift then
							lastSelectedNode = i + self.ScrollIndex
						end
						
						if HoldingShift and not filteringWorkspace() then
							if lastSelectedNode then
								if i + self.ScrollIndex - lastSelectedNode > 0 then
									Selection:StopUpdates()
									for i2 = 1, i + self.ScrollIndex - lastSelectedNode do
										local newNode = TreeList[lastSelectedNode + i2]
										if newNode then
											Selection:Add(newNode.Object)
										end
									end
									Selection:ResumeUpdates()
								else
									Selection:StopUpdates()
									for i2 = i + self.ScrollIndex - lastSelectedNode, 1 do
										local newNode = TreeList[lastSelectedNode + i2]
										if newNode then
											Selection:Add(newNode.Object)
										end
									end
									Selection:ResumeUpdates()
								end
							end
							return
						end
						
						if HoldingCtrl then
							if Selection.Selected[node.Object] then
								Selection:Remove(node.Object)
							else
								Selection:Add(node.Object)
							end
							return
						end
						if Option.Modifiable then
							local pos = Vector2.new(x,y)
							dragReparent(node.Object,entry:Clone(),pos,entry.AbsolutePosition-pos)
						elseif Option.Selectable then
							if Selection.Selected[node.Object] then
								Selection:Set({})
							else
								Selection:Set({node.Object})
							end
							dragSelect(i+self.ScrollIndex,true,'MouseButton1Up')
						end
					end)

					entry.MouseButton2Down:connect(function()
						if not Option.Selectable then return end
						
						DestroyRightClick()
						
						curSelect = entry
						
						local node = TreeList[i + self.ScrollIndex]
						
						if node.Object == HiddenEntriesMain then
							return
						end
						
						if GetAwaitRemote:Invoke() then
							bindSetAwaiting:Fire(node.Object)
							return
						end
						
						if not Selection.Selected[node.Object] then
							Selection:Set({node.Object})
						end
					end)
					
					
					entry.MouseButton2Up:connect(function()
						if not Option.Selectable then return end
						
						local node = TreeList[i + self.ScrollIndex]
						
						if node.Object == HiddenEntriesMain then
							return
						end
						
						if checkMouseInGui(curSelect) then
							rightClickMenu(node.Object)
						end
					end)

					entry.Parent = listFrame
				end

				entry.Visible = true

				local object = node.Object

				-- update expand icon
				if node.Object ~= HiddenEntriesMain then
					if #node == 0 then
						entry.IndentFrame.Expand.Visible = false
					elseif node.Expanded then
						Icon(entry.IndentFrame.Expand,NODE_EXPANDED)
						entry.IndentFrame.Expand.Visible = true
					else
						Icon(entry.IndentFrame.Expand,NODE_COLLAPSED)
						entry.IndentFrame.Expand.Visible = true
					end
				else
					if node.HiddenExpanded then
						Icon(entry.IndentFrame.Expand,NODE_EXPANDED)
						entry.IndentFrame.Expand.Visible = true
					else
						Icon(entry.IndentFrame.Expand,NODE_COLLAPSED)
						entry.IndentFrame.Expand.Visible = true
					end
				end
				
				-- update explorer icon
				if object ~= HiddenEntriesMain then
					entry.IndentFrame.EntryText.Position = UDim2.new(0,2+ENTRY_SIZE+4,0,0);
					entry.IndentFrame.ExplorerIcon.Visible = true
					Icon(entry.IndentFrame.ExplorerIcon,ExplorerIndex[object.ClassName] or 0)
				else
					entry.IndentFrame.EntryText.Position = UDim2.new(0,0,0,0);
					entry.IndentFrame.ExplorerIcon.Visible = false
				end
				
				-- update indentation
				local w = (node.Depth)*(2+ENTRY_PADDING+GUI_SIZE)
				entry.IndentFrame.Position = UDim2.new(0,w,0,0)
				entry.IndentFrame.Size = UDim2.new(1,-w,1,0)

				-- update hidden entries name
				NameHiddenEntries()
				
				-- update name change detection
				if nameConnLookup[entry] then
					nameConnLookup[entry]:disconnect()
				end
				local text = entry.IndentFrame.EntryText
				text.Text = object.Name
				nameConnLookup[entry] = node.Object.Changed:connect(function(p)
					if p == 'Name' then
						text.Text = object.Name
					end
				end)

				-- update selection
				entry.IndentFrame.Transparency = node.Selected and 0 or 1
				text.TextColor3 = GuiColor[node.Selected and 'TextSelected' or 'Text']

				entry.Size = UDim2.new(0,nodeWidth,0,ENTRY_SIZE)
			elseif listEntries[i] then
				listEntries[i].Visible = false
			end
		end
		for i = self.VisibleSpace+1,self.TotalSpace do
			local entry = listEntries[i]
			if entry then
				listEntries[i] = nil
				entry:Destroy()
			end
		end
	end

	function scrollBarH.UpdateCallback(self)
		for i = 1,scrollBar.VisibleSpace do
			local node = TreeList[i + scrollBar.ScrollIndex]
			if node then
				local entry = listEntries[i]
				if entry then
					entry.Position = UDim2.new(0,2 - scrollBarH.ScrollIndex,0,ENTRY_BOUND*(i-1)+2)
				end
			end
		end
	end

	Connect(listFrame.Changed,function(p)
		if p == 'AbsoluteSize' then
			rawUpdateSize()
		end
	end)

	local wheelAmount = 6
	explorerPanel.MouseWheelForward:connect(function()
		if scrollBar.VisibleSpace - 1 > wheelAmount then
			scrollBar:ScrollTo(scrollBar.ScrollIndex - wheelAmount)
		else
			scrollBar:ScrollTo(scrollBar.ScrollIndex - scrollBar.VisibleSpace)
		end
	end)
	explorerPanel.MouseWheelBackward:connect(function()
		if scrollBar.VisibleSpace - 1 > wheelAmount then
			scrollBar:ScrollTo(scrollBar.ScrollIndex + wheelAmount)
		else
			scrollBar:ScrollTo(scrollBar.ScrollIndex + scrollBar.VisibleSpace)
		end
	end)
end

----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
---- Object detection

-- Inserts `v` into `t` at `i`. Also sets `Index` field in `v`.
local function insert(t,i,v)
	for n = #t,i,-1 do
		local v = t[n]
		v.Index = n+1
		t[n+1] = v
	end
	v.Index = i
	t[i] = v
end

-- Removes `i` from `t`. Also sets `Index` field in removed value.
local function remove(t,i)
	local v = t[i]
	for n = i+1,#t do
		local v = t[n]
		v.Index = n-1
		t[n-1] = v
	end
	t[#t] = nil
	v.Index = 0
	return v
end

-- Returns how deep `o` is in the tree.
local function depth(o)
	local d = -1
	while o do
		o = o.Parent
		d = d + 1
	end
	return d
end


local connLookup = {}

-- Returns whether a node would be present in the tree list
local function nodeIsVisible(node)
	local visible = true
	node = node.Parent
	while node and visible do
		visible = visible and node.Expanded
		node = node.Parent
	end
	return visible
end

-- Removes an object's tree node. Called when the object stops existing in the
-- game tree.
removeObject = function(object)
	local objectNode = NodeLookup[object]
	if not objectNode then
		return
	end

	local visible = nodeIsVisible(objectNode)

	Selection:Remove(object,true)

	local parent = objectNode.Parent
	remove(parent,objectNode.Index)
	NodeLookup[object] = nil
	connLookup[object]:disconnect()
	connLookup[object] = nil

	if visible then
		updateList()
	elseif nodeIsVisible(parent) then
		updateScroll()
	end
end

-- Moves a tree node to a new parent. Called when an existing object's parent
-- changes.
local function moveObject(object,parent)
	local objectNode = NodeLookup[object]
	if not objectNode then
		return
	end

	local parentNode = NodeLookup[parent]
	if not parentNode then
		return
	end

	local visible = nodeIsVisible(objectNode)

	remove(objectNode.Parent,objectNode.Index)
	objectNode.Parent = parentNode

	objectNode.Depth = depth(object)
	local function r(node,d)
		for i = 1,#node do
			node[i].Depth = d
			r(node[i],d+1)
		end
	end
	r(objectNode,objectNode.Depth+1)

	insert(parentNode,#parentNode+1,objectNode)

	if visible or nodeIsVisible(objectNode) then
		updateList()
	elseif nodeIsVisible(objectNode.Parent) then
		updateScroll()
	end
end

-- ScriptContext['/Libraries/LibraryRegistration/LibraryRegistration']
-- This RobloxLocked object lets me index its properties for some reason

local function check(object)
	return object.AncestryChanged
end

-- Creates a new tree node from an object. Called when an object starts
-- existing in the game tree.
addObject = function(object,noupdate,parent)
	if script then
		-- protect against naughty RobloxLocked objects
		local s = pcall(check,object)
		if not s then
			return
		end
	end

	local parentNode 
	
	if parent then
		parentNode = NodeLookup[parent]
	else
		parentNode = NodeLookup[object.Parent]	
	end
	
	if not parentNode then
		return
	end

	local objectNode = {
		Object = object;
		Parent = parentNode;
		Index = 0;
		Expanded = false;
		Selected = false;
		Depth = depth(object);
	}

	connLookup[object] = Connect(object.AncestryChanged,function(c,p)
		if c == object then
			if p == nil then
				removeObject(c)
			else
				moveObject(c,p)
			end
		end
	end)

	NodeLookup[object] = objectNode
	insert(parentNode,#parentNode+1,objectNode)

	if not noupdate then
		if nodeIsVisible(objectNode) then
			updateList()
		elseif nodeIsVisible(objectNode.Parent) then
			updateScroll()
		end
	end
end

local function makeObject(obj,par)
	local newObject = Instance.new(obj.ClassName)
	for i,v in pairs(obj.Properties) do
		ypcall(function()
			local newProp
			newProp = ToPropValue(v.Value,v.Type)
			newObject[v.Name] = newProp
		end)
	end
	newObject.Parent = par
end

local function writeObject(obj)
	local newObject = {ClassName = obj.ClassName, Properties = {}}
	for i,v in pairs(RbxApi.GetProperties(obj.className)) do
		if v["Name"] ~= "Parent" then
			print("thispassed")
			table.insert(newObject.Properties,{Name = v["Name"], Type = v["ValueType"], Value = tostring(obj[v["Name"]])})
		end
	end
	return newObject
end

local function buildDexStorage()
	local localDexStorage
	
	local success,err = ypcall(function()
		localDexStorage = game:GetObjects("rbxasset://DexStorage.rbxm")[1]
	end)
	
	if success and localDexStorage then
		for i,v in pairs(localDexStorage:GetChildren()) do
			ypcall(function()
				v.Parent = DexStorageMain
			end)
		end
	end
	
	updateDexStorageListeners()
	--[[
	local localDexStorage = readfile(getelysianpath().."DexStorage.txt")--game:GetService("CookiesService"):GetCookieValue("DexStorage")
	--local success,err = pcall(function()
		if localDexStorage then
			local objTable = game:GetService("HttpService"):JSONDecode(localDexStorage)
			for i,v in pairs(objTable) do
				makeObject(v,DexStorageMain)
			end
		end
	--end)
	--]]
end

local dexStorageDebounce = false
local dexStorageListeners = {}

local function updateDexStorage()
	if dexStorageDebounce then return end
	dexStorageDebounce = true	
	
	wait()
	
	pcall(function()
		saveinstance("content//DexStorage.rbxm",DexStorageMain)
	end)
	
	updateDexStorageListeners()
	
	dexStorageDebounce = false
	--[[
	local success,err = ypcall(function()
		local objs = {}
		for i,v in pairs(DexStorageMain:GetChildren()) do
			table.insert(objs,writeObject(v))
		end
		writefile(getelysianpath().."DexStorage.txt",game:GetService("HttpService"):JSONEncode(objs))
		--game:GetService("CookiesService"):SetCookieValue("DexStorage",game:GetService("HttpService"):JSONEncode(objs))
	end)
	if err then
		CreateCaution("DexStorage Save Fail!","DexStorage broke! If you see this message, report to Raspberry Pi!")
	end
	print("hi")
	--]]
end

function updateDexStorageListeners()
	for i,v in pairs(dexStorageListeners) do
		v:Disconnect()
	end
	dexStorageListeners = {}
	for i,v in pairs(DexStorageMain:GetChildren()) do
		pcall(function()
			local ev = v.Changed:connect(updateDexStorage)
			table.insert(dexStorageListeners,ev)
		end)
	end
end

do
	local function registerNodeLookup4(o)
		NodeLookup[o] = {
			Object = o;
			Parent = nil;
			Index = 0;
			Expanded = true;
		}
	end
	
	registerNodeLookup4(game)
	
	NodeLookup[DexOutput] = {
		Object = DexOutput;
		Parent = nil;
		Index = 0;
		Expanded = true;
	}
	
	if DexStorageEnabled then
		NodeLookup[DexStorage] = {
			Object = DexStorage;
			Parent = nil;
			Index = 0;
			Expanded = true;
		}
	end
	
	if NilStorageEnabled then
		NodeLookup[NilStorage] = {
			Object = NilStorage;
			Parent = nil;
			Index = 0;
			Expanded = true;
		}
	end

	registerNodeLookup4(HiddenEntries)	
	registerNodeLookup4(HiddenGame)	
	
	Connect(game.DescendantAdded,addObject)
	Connect(game.DescendantRemoving,removeObject)
	
	Connect(DexOutput.DescendantAdded,addObject)
	Connect(DexOutput.DescendantRemoving,removeObject)
	
	if DexStorageEnabled then
		--[[
		if readfile(getelysianpath().."DexStorage.txt") == nil then
			writefile(getelysianpath().."DexStorage.txt","")
		end
		--]]
		
		buildDexStorage()
	
		Connect(DexStorage.DescendantAdded,addObject)
		Connect(DexStorage.DescendantRemoving,removeObject)
	
		Connect(DexStorage.DescendantAdded,updateDexStorage)
		Connect(DexStorage.DescendantRemoving,updateDexStorage)
	end
	
	if NilStorageEnabled then
		Connect(NilStorage.DescendantAdded,addObject)
		Connect(NilStorage.DescendantRemoving,removeObject)		
		
		local currentTable = get_nil_instances()	
		
		spawn(function()
			while wait() do
				if #currentTable ~= #get_nil_instances() then
					currentTable = get_nil_instances()
					--NilStorageMain:ClearAllChildren()
					for i,v in pairs(get_nil_instances()) do
						if v ~= NilStorage and v ~= DexStorage then
							pcall(function()
								v.Parent = NilStorageMain
							end)
							--[[
							local newNil = v
							newNil.Archivable = true
							newNil:Clone().Parent = NilStorageMain
							--]]
						end
					end
				end
			end
		end)
	end

	local function get(o)
		return o:GetChildren()
	end
		
	local function r(o)
		if o == game and MuteHiddenItems then
			for i, v in pairs(gameChildren) do			
				addObject(v,true)
				r(v)
			end
			return	
		end
		
		local s,children = pcall(get,o)
		if s then
			for i = 1,#children do
				addObject(children[i],true)
				r(children[i])
			end
		end
	end
	
	r(game)	
	r(DexOutput)
	if DexStorageEnabled then
		r(DexStorage)
	end
	if NilStorageEnabled then
		r(NilStorage)
	end
	
	r(HiddenEntries)

	scrollBar.VisibleSpace = math.ceil(listFrame.AbsoluteSize.y/ENTRY_BOUND)
	updateList()
end

----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
---- Actions

local actionButtons do
	actionButtons = {}

	local totalActions = 1
	local currentActions = totalActions
	local function makeButton(icon,over,name,vis,cond)
		local buttonEnabled = false
		
		local button = Create(Icon('ImageButton',icon),{
			Name = name .. "Button";
			Visible = Option.Modifiable and Option.Selectable;
			Position = UDim2.new(1, -4 + -(GUI_SIZE+2)*currentActions+2,0.25,-GUI_SIZE/2);
			Size = UDim2.new(0,GUI_SIZE,0,GUI_SIZE);
			Parent = headerFrame;
		})

		local tipText = Create('TextLabel',{
			Name = name .. "Text";
			Text = name;
			Visible = false;
			BackgroundTransparency = 1;
			TextXAlignment = 'Right';
			Font = FONT;
			FontSize = FONT_SIZE;
			Position = UDim2.new(0,0,0,0);
			Size = UDim2.new(1,-(GUI_SIZE+2)*totalActions,1,0);
			Parent = headerFrame;
		})
		
		button.MouseEnter:connect(function()
			if buttonEnabled then
				button.BackgroundTransparency = 0.9
			end
			--Icon(button,over)
			--tipText.Visible = true
		end)
		button.MouseLeave:connect(function()
			button.BackgroundTransparency = 1
			--Icon(button,icon)
			--tipText.Visible = false
		end)

		currentActions = currentActions + 1
		actionButtons[#actionButtons+1] = {Obj = button,Cond = cond}
		QuickButtons[#actionButtons+1] = {Obj = button,Cond = cond, Toggle = function(on)
			if on then
				buttonEnabled = true
				Icon(button,over)
			else
				buttonEnabled = false
				Icon(button,icon)
			end
		end}
		return button
	end

	--local clipboard = {}
	local function delete(o)
		o.Parent = nil
	end
		

	-- DELETE
	makeButton(ACTION_DELETE,ACTION_DELETE_OVER,"Delete",true,function() return #Selection:Get() > 0 end).MouseButton1Click:connect(function()
		if not Option.Modifiable then return end
		local list = Selection:Get()
		for i = 1,#list do
			pcall(delete,list[i])
		end
		Selection:Set({})
	end)
	
	-- PASTE
	makeButton(ACTION_PASTE,ACTION_PASTE_OVER,"Paste",true,function() return #Selection:Get() > 0 and #clipboard > 0 end).MouseButton1Click:connect(function()
		if not Option.Modifiable then return end
		local parent = Selection.List[1] or workspace
		for i = 1,#clipboard do
			clipboard[i]:Clone().Parent = parent
		end
	end)
	
	-- COPY
	makeButton(ACTION_COPY,ACTION_COPY_OVER,"Copy",true,function() return #Selection:Get() > 0 end).MouseButton1Click:connect(function()
		if not Option.Modifiable then return end
		clipboard = {}
		local list = Selection.List
		for i = 1,#list do
			table.insert(clipboard,list[i]:Clone())
		end
		updateActions()
	end)
	
	-- CUT
	makeButton(ACTION_CUT,ACTION_CUT_OVER,"Cut",true,function() return #Selection:Get() > 0 end).MouseButton1Click:connect(function()
		if not Option.Modifiable then return end
		clipboard = {}
		local list = Selection.List
		local cut = {}
		for i = 1,#list do
			local obj = list[i]:Clone()
			if obj then
				table.insert(clipboard,obj)
				table.insert(cut,list[i])
			end
		end
		for i = 1,#cut do
			pcall(delete,cut[i])
		end
		updateActions()
	end)
	
	-- FREEZE


	-- SORT
	-- local actionSort = makeButton(ACTION_SORT,ACTION_SORT_OVER,"Sort")
end

----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
----------------------------------------------------------------
---- Option Bindables

do
	local optionCallback = {
		Modifiable = function(value)
			for i = 1,#actionButtons do
				actionButtons[i].Obj.Visible = value and Option.Selectable
			end
			cancelReparentDrag()
		end;
		Selectable = function(value)
			for i = 1,#actionButtons do
				actionButtons[i].Obj.Visible = value and Option.Modifiable
			end
			cancelSelectDrag()
			Selection:Set({})
		end;
	}

	local bindSetOption = explorerPanel:FindFirstChild("SetOption")
	if not bindSetOption then
		bindSetOption = Create('BindableFunction',{Name = "SetOption"})
		bindSetOption.Parent = explorerPanel
	end

	bindSetOption.OnInvoke = function(optionName,value)
		if optionCallback[optionName] then
			Option[optionName] = value
			optionCallback[optionName](value)
		end
	end

	local bindGetOption = explorerPanel:FindFirstChild("GetOption")
	if not bindGetOption then
		bindGetOption = Create('BindableFunction',{Name = "GetOption"})
		bindGetOption.Parent = explorerPanel
	end

	bindGetOption.OnInvoke = function(optionName)
		if optionName then
			return Option[optionName]
		else
			local options = {}
			for k,v in pairs(Option) do
				options[k] = v
			end
			return options
		end
	end
end

function SelectionVar()
	return Selection
end

Input.InputBegan:connect(function(key)
	if key.KeyCode == Enum.KeyCode.LeftControl then
		HoldingCtrl = true
	end
	if key.KeyCode == Enum.KeyCode.LeftShift then
		HoldingShift = true
	end
end)

Input.InputEnded:connect(function(key)
	if key.KeyCode == Enum.KeyCode.LeftControl then
		HoldingCtrl = false
	end
	if key.KeyCode == Enum.KeyCode.LeftShift then
		HoldingShift = false
	end
end)

while RbxApi == nil do
	RbxApi = GetApiRemote:Invoke()
	wait()
end

explorerFilter.Changed:connect(function(prop)
	if prop == "Text" then		
		Selection.Finding = true
		rawUpdateList()
	end
end)

explorerFilter.FocusLost:connect(function()	
	if explorerFilter.Text == "" then
		if Selection.Found[1] then
			scrollBar:ScrollTo(NodeLookup[Selection.Found[1]].Index)
		end
		
		Selection.Finding = false
		Selection.Found = {}
	end
end)

CurrentInsertObjectWindow = CreateInsertObjectMenu(
	GetClasses(),
	"",
	false,
	function(option)
		CurrentInsertObjectWindow.Visible = false
		local list = SelectionVar():Get()
		for i = 1,#list do
			pcall(function() Instance.new(option,list[i]) end)
		end
		DestroyRightClick()
	end
)