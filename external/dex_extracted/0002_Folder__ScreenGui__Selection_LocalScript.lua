local Gui = script.Parent

local IntroFrame = Gui:WaitForChild("IntroFrame")

local SideMenu = Gui:WaitForChild("SideMenu")
local OpenToggleButton = Gui:WaitForChild("Toggle")
local CloseToggleButton = SideMenu:WaitForChild("Toggle")
local OpenScriptEditorButton = SideMenu:WaitForChild("OpenScriptEditor")

local ScriptEditor = Gui:WaitForChild("ScriptEditor")

local SlideOut = SideMenu:WaitForChild("SlideOut")
local SlideFrame = SlideOut:WaitForChild("SlideFrame")
local Slant = SideMenu:WaitForChild("Slant")

local ExplorerButton = SlideFrame:WaitForChild("Explorer")
local SettingsButton = SlideFrame:WaitForChild("Settings")

local SelectionBox = Instance.new("SelectionBox")
SelectionBox.Parent = Gui

local ExplorerPanel = Gui:WaitForChild("ExplorerPanel")
local PropertiesFrame = Gui:WaitForChild("PropertiesFrame")
local SaveMapWindow = Gui:WaitForChild("SaveMapWindow")
local RemoteDebugWindow = Gui:WaitForChild("RemoteDebugWindow")

local SettingsPanel = Gui:WaitForChild("SettingsPanel")
local AboutPanel = Gui:WaitForChild("About")
local SettingsListener = SettingsPanel:WaitForChild("GetSetting")
local SettingTemplate = SettingsPanel:WaitForChild("SettingTemplate")
local SettingList = SettingsPanel:WaitForChild("SettingList")

local SaveMapCopyList = SaveMapWindow:WaitForChild("CopyList")
local SaveMapSettingFrame = SaveMapWindow:WaitForChild("MapSettings")
local SaveMapName = SaveMapWindow:WaitForChild("FileName")
local SaveMapButton = SaveMapWindow:WaitForChild("Save")
local SaveMapCopyTemplate = SaveMapWindow:WaitForChild("Entry")
local SaveMapSettings = {
	CopyWhat = {
		Workspace = true,
		Lighting = true,
		ReplicatedStorage = true,
		ReplicatedFirst = true,
		StarterPack = true,
		StarterGui = true,
		StarterPlayer = true
	},
	SaveScripts = false,
	SaveTerrain = true,
	LightingProperties = true,
	CameraInstances = true
}

--[[
local ClickSelectOption = SettingsPanel:WaitForChild("ClickSelect"):WaitForChild("Change")
local SelectionBoxOption = SettingsPanel:WaitForChild("SelectionBox"):WaitForChild("Change")
local ClearPropsOption = SettingsPanel:WaitForChild("ClearProperties"):WaitForChild("Change")
local SelectUngroupedOption = SettingsPanel:WaitForChild("SelectUngrouped"):WaitForChild("Change")
--]]

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
				_writefile(name..(inst == game and ".rbxlx" or ".rbxmx"),(t_concat(buffer)), name, "Roblox XML Files(*.rbxlx, *.rbxmx)\0 * .rbxlx; *.rbxmx\0All Files\0 * .*\0",(inst == game and ".rbxlx" or ".rbxmx"))
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

local SelectionChanged = ExplorerPanel:WaitForChild("SelectionChanged")
local GetSelection = ExplorerPanel:WaitForChild("GetSelection")
local SetSelection = ExplorerPanel:WaitForChild("SetSelection")

local Player = game:GetService("Players").LocalPlayer
local Mouse = Player:GetMouse()

local CurrentWindow = "_BLANK"
local Windows = {
	Explorer = {
		ExplorerPanel,
		PropertiesFrame
	},
	Settings = {SettingsPanel},
	SaveMap = {SaveMapWindow},
	Remotes = {RemoteDebugWindow},
	About = {AboutPanel},
}

function switchWindows(wName,over)
	if CurrentWindow == wName and not over then return end
	
	local count = 0
	
	for i,v in pairs(Windows) do
		count = 0
		if i ~= wName then
			for _,c in pairs(v) do c:TweenPosition(UDim2.new(1, 30, count * 0.5, count * 36), "Out", "Quad", 0.5, true) count = count + 1 end
		end
	end
	
	count = 0
	
	if Windows[wName] then
		for _,c in pairs(Windows[wName]) do c:TweenPosition(UDim2.new(1, -300, count * 0.5, count * 36), "Out", "Quad", 0.5, true) count = count + 1 end
	end
	
	if wName ~= "_BLANK" then
		CurrentWindow = wName
		for i,v in pairs(SlideFrame:GetChildren()) do
			v.BackgroundTransparency = 1
			v.Icon.ImageColor3 = Color3.new(70/255, 70/255, 70/255)
		end
		if SlideFrame:FindFirstChild(wName) then
			SlideFrame[wName].BackgroundTransparency = 0.5
			SlideFrame[wName].Icon.ImageColor3 = Color3.new(0,0,0)
		end
	end
end

function toggleDex(on)
	if on then
		SideMenu:TweenPosition(UDim2.new(1, -330, 0, 0), "Out", "Quad", 0.5, true)
		OpenToggleButton:TweenPosition(UDim2.new(1,0,0,0), "Out", "Quad", 0.5, true)
		switchWindows(CurrentWindow,true)
	else
		SideMenu:TweenPosition(UDim2.new(1, 0, 0, 0), "Out", "Quad", 0.5, true)
		OpenToggleButton:TweenPosition(UDim2.new(1,-40,0,0), "Out", "Quad", 0.5, true)
		switchWindows("_BLANK")
	end
end

local Settings = {
	ClickSelect = false,
	SelBox = false,
	ClearProps = false,
	SelectUngrouped = true,
	SaveInstanceScripts = true
}

function ReturnSetting(set)
	if set == "ClearProps" then
		return Settings.ClearProps
	elseif set == "SelectUngrouped" then
		return Settings.SelectUngrouped
	end
end

OpenToggleButton.MouseButton1Up:connect(function()
	toggleDex(true)
end)

OpenScriptEditorButton.MouseButton1Up:connect(function()
	if OpenScriptEditorButton.Active then
		ScriptEditor.Visible = true
	end
end)

CloseToggleButton.MouseButton1Up:connect(function()
	if CloseToggleButton.Active then
		toggleDex(false)
	end
end)

--[[
OpenToggleButton.MouseButton1Up:connect(function()
	SideMenu:TweenPosition(UDim2.new(1, -330, 0, 0), "Out", "Quad", 0.5, true)
	
	if CurrentWindow == "Explorer" then
		ExplorerPanel:TweenPosition(UDim2.new(1, -300, 0, 0), "Out", "Quad", 0.5, true)
		PropertiesFrame:TweenPosition(UDim2.new(1, -300, 0.5, 36), "Out", "Quad", 0.5, true)
	else
		SettingsPanel:TweenPosition(UDim2.new(1, -300, 0, 0), "Out", "Quad", 0.5, true)
	end
	
	OpenToggleButton:TweenPosition(UDim2.new(1,0,0,0), "Out", "Quad", 0.5, true)
end)

CloseToggleButton.MouseButton1Up:connect(function()
	SideMenu:TweenPosition(UDim2.new(1, 0, 0, 0), "Out", "Quad", 0.5, true)
	
	ExplorerPanel:TweenPosition(UDim2.new(1, 30, 0, 0), "Out", "Quad", 0.5, true)
	PropertiesFrame:TweenPosition(UDim2.new(1, 30, 0.5, 36), "Out", "Quad", 0.5, true)
	SettingsPanel:TweenPosition(UDim2.new(1, 30, 0, 0), "Out", "Quad", 0.5, true)
	
	OpenToggleButton:TweenPosition(UDim2.new(1,-30,0,0), "Out", "Quad", 0.5, true)
end)
--]]

--[[
ExplorerButton.MouseButton1Up:connect(function()
	switchWindows("Explorer")
end)

SettingsButton.MouseButton1Up:connect(function()
	switchWindows("Settings")
end)
--]]

for i,v in pairs(SlideFrame:GetChildren()) do
	v.MouseButton1Click:connect(function()
		switchWindows(v.Name)
	end)
	
	v.MouseEnter:connect(function()v.BackgroundTransparency = 0.5 end)
	v.MouseLeave:connect(function()if CurrentWindow~=v.Name then v.BackgroundTransparency = 1 end end)
end

--[[
ExplorerButton.MouseButton1Up:connect(function()
	if CurrentWindow ~= "Explorer" then
		CurrentWindow = "Explorer"
		
		ExplorerPanel:TweenPosition(UDim2.new(1, -300, 0, 0), "Out", "Quad", 0.5, true)
		PropertiesFrame:TweenPosition(UDim2.new(1, -300, 0.5, 36), "Out", "Quad", 0.5, true)
		SettingsPanel:TweenPosition(UDim2.new(1, 0, 0, 0), "Out", "Quad", 0.5, true)
	end
end)

SettingsButton.MouseButton1Up:connect(function()
	if CurrentWindow ~= "Settings" then
		CurrentWindow = "Settings"
		
		ExplorerPanel:TweenPosition(UDim2.new(1, 0, 0, 0), "Out", "Quad", 0.5, true)
		PropertiesFrame:TweenPosition(UDim2.new(1, 0, 0.5, 36), "Out", "Quad", 0.5, true)
		SettingsPanel:TweenPosition(UDim2.new(1, -300, 0, 0), "Out", "Quad", 0.5, true)
	end
end)
--]]

function createSetting(name,interName,defaultOn)
	local newSetting = SettingTemplate:Clone()
	newSetting.Position = UDim2.new(0,0,0,#SettingList:GetChildren() * 60)
	newSetting.SName.Text = name
	
	local function toggle(on)
		if on then
			newSetting.Change.Bar:TweenPosition(UDim2.new(0,32,0,-2),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.25,true)
			newSetting.Change.OnBar:TweenSize(UDim2.new(0,34,0,15),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.25,true)
			newSetting.Status.Text = "On"
			Settings[interName] = true
		else
			newSetting.Change.Bar:TweenPosition(UDim2.new(0,-2,0,-2),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.25,true)
			newSetting.Change.OnBar:TweenSize(UDim2.new(0,0,0,15),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.25,true)
			newSetting.Status.Text = "Off"
			Settings[interName] = false
		end
	end	
	
	newSetting.Change.MouseButton1Click:connect(function()
		toggle(not Settings[interName])
	end)
	
	newSetting.Visible = true
	newSetting.Parent = SettingList
	
	if defaultOn then
		toggle(true)
	end
end

createSetting("Click part to select","ClickSelect",false)
createSetting("Selection Box","SelBox",false)
createSetting("Clear property value on focus","ClearProps",false)
createSetting("Select ungrouped models","SelectUngrouped",true)
createSetting("SaveInstance decompiles scripts","SaveInstanceScripts",true)

--[[
ClickSelectOption.MouseButton1Up:connect(function()
	if Settings.ClickSelect then
		Settings.ClickSelect = false
		ClickSelectOption.Text = "OFF"
	else
		Settings.ClickSelect = true
		ClickSelectOption.Text = "ON"
	end
end)

SelectionBoxOption.MouseButton1Up:connect(function()
	if Settings.SelBox then
		Settings.SelBox = false
		SelectionBox.Adornee = nil
		SelectionBoxOption.Text = "OFF"
	else
		Settings.SelBox = true
		SelectionBoxOption.Text = "ON"
	end
end)

ClearPropsOption.MouseButton1Up:connect(function()
	if Settings.ClearProps then
		Settings.ClearProps = false
		ClearPropsOption.Text = "OFF"
	else
		Settings.ClearProps = true
		ClearPropsOption.Text = "ON"
	end
end)

SelectUngroupedOption.MouseButton1Up:connect(function()
	if Settings.SelectUngrouped then
		Settings.SelectUngrouped = false
		SelectUngroupedOption.Text = "OFF"
	else
		Settings.SelectUngrouped = true
		SelectUngroupedOption.Text = "ON"
	end
end)
--]]

local function getSelection()
	local t = GetSelection:Invoke()
	if t and #t > 0 then
		return t[1]
	else
		return nil
	end
end

Mouse.Button1Down:connect(function()
	if CurrentWindow == "Explorer" and Settings.ClickSelect then
		local target = Mouse.Target
		if target then
			SetSelection:Invoke({target})
		end
	end
end)

SelectionChanged.Event:connect(function()
	if Settings.SelBox then
		local success,err = pcall(function()
			local selection = getSelection()
			SelectionBox.Adornee = selection
		end)
		if err then
			SelectionBox.Adornee = nil
		end
	end
end)

SettingsListener.OnInvoke = ReturnSetting

-- Map Copier

function createMapSetting(obj,interName,defaultOn)
	local function toggle(on)
		if on then
			obj.Change.Bar:TweenPosition(UDim2.new(0,32,0,-2),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.25,true)
			obj.Change.OnBar:TweenSize(UDim2.new(0,34,0,15),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.25,true)
			obj.Status.Text = "On"
			SaveMapSettings[interName] = true
		else
			obj.Change.Bar:TweenPosition(UDim2.new(0,-2,0,-2),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.25,true)
			obj.Change.OnBar:TweenSize(UDim2.new(0,0,0,15),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.25,true)
			obj.Status.Text = "Off"
			SaveMapSettings[interName] = false
		end
	end	
	
	obj.Visible = true
	obj.Parent = SaveMapSettingFrame
	
	if defaultOn then
		toggle(true)
	end
end

function createCopyWhatSetting(serv)
	if SaveMapSettings.CopyWhat[serv] then
		local newSetting = SaveMapCopyTemplate:Clone()
		newSetting.Position = UDim2.new(0,0,0,#SaveMapCopyList:GetChildren() * 22 + 5)
		newSetting.Info.Text = serv
		
		local function toggle(on)
			if on then
				newSetting.Change.enabled.Visible = true
				SaveMapSettings.CopyWhat[serv] = true
			else
				newSetting.Change.enabled.Visible = false
				SaveMapSettings.CopyWhat[serv] = false
			end
		end	
		
		newSetting.Visible = true
		newSetting.Parent = SaveMapCopyList
	end
end

createCopyWhatSetting("Workspace")

SaveMapName.Text = tostring(game.PlaceId).."MapCopy"

SaveMapButton.MouseButton1Click:connect(function()
	if SaveInstance then
		SaveInstance(game,SaveMapName.Text)
		SaveMapButton.Text = "The map has been saved"
		wait(5)
		SaveMapButton.Text = "Save"
	else
		SaveMapButton.Text = "The map could not be saved :("
		wait(5)
		SaveMapButton.Text = "Save"
	end
end)

-- End Copier

wait()

IntroFrame:TweenPosition(UDim2.new(1,-301,0,0),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.5,true)

switchWindows("Explorer")

wait(1)

SideMenu.Visible = true

for i = 0,1,0.1 do
	IntroFrame.BackgroundTransparency = i
	IntroFrame.Main.BackgroundTransparency = i
	IntroFrame.Slant.ImageTransparency = i
	IntroFrame.Title.TextTransparency = i
	IntroFrame.Version.TextTransparency = i
	IntroFrame.Creator.TextTransparency = i
	wait()
end

IntroFrame.Visible = false

SlideFrame:TweenPosition(UDim2.new(0,0,0,0),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.5,true)
OpenScriptEditorButton:TweenPosition(UDim2.new(0,0,0,150),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.5,true)
CloseToggleButton:TweenPosition(UDim2.new(0,0,0,180),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.5,true)
Slant:TweenPosition(UDim2.new(0,0,0,210),Enum.EasingDirection.Out,Enum.EasingStyle.Quart,0.5,true)

wait(0.5)

for i = 1,0,-0.1 do
	OpenScriptEditorButton.Icon.ImageTransparency = i
	CloseToggleButton.TextTransparency = i
	wait()
end

CloseToggleButton.Active = true
CloseToggleButton.AutoButtonColor = true

OpenScriptEditorButton.Active = true
OpenScriptEditorButton.AutoButtonColor = true