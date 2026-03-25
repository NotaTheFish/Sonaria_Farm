local top = script.Parent

local editorGrid = top:WaitForChild("EditorGrid")

local currentSource = ""

local currentEditor = {
	x = 0,
	y = 0
}

local userInput = game:GetService("UserInputService")
local mouse = game:GetService("Players").LocalPlayer:GetMouse()

local topBar = top:WaitForChild("TopBar")
local scriptBar = topBar:WaitForChild("ScriptBar")
local scriptBarLeft = topBar:WaitForChild("ScriptBarLeft")
local scriptBarRight = topBar:WaitForChild("ScriptBarRight")
local clipboardButton = topBar:WaitForChild("Clipboard")

local entryTemplate = topBar:WaitForChild("Entry")

local openEvent = top:WaitForChild("OpenScript")

local closeButton = top:WaitForChild("Close")

local memoryScripts = {}

local editingIndex = 0

-- Scrollbar

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

-- End Scrollbar

local scrollBar = ScrollBar(false)
scrollBar.PageIncrement = 16
Create(scrollBar.GUI,{
	Position = UDim2.new(1,0,0,0);
	Size = UDim2.new(0,ScrollBarWidth,1,0);
	Parent = editorGrid;
})

local scrollBarH = ScrollBar(true)
scrollBarH.PageIncrement = 8
Create(scrollBarH.GUI,{
	Position = UDim2.new(0,0,1,0);
	Size = UDim2.new(1,0,0,ScrollBarWidth);
	Parent = editorGrid;
})

local entries = {}

local grid = {}

local count = 1
local xCount = 1

local lineSpan = 0

for i = 0,490,8 do
	local newRow = {}
	for j = 0,390,16 do
		local cellText = Instance.new("TextLabel",editorGrid)
		cellText.BackgroundTransparency = 1
		cellText.BorderSizePixel = 0
		cellText.Text = ""
		cellText.Position = UDim2.new(0,i,0,j)
		cellText.Size = UDim2.new(0,8,0,16)
		cellText.Font = Enum.Font.SourceSans
		cellText.FontSize = Enum.FontSize.Size18
		table.insert(newRow,cellText)
		xCount = xCount + 1
	end
	table.insert(grid,newRow)
	count = count + 1
	xCount = 1
end

local syntaxHighlightList = {
	{["Keyword"] = "for", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "local", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "if", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "then", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "do", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "while", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "end", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "function", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "string", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "table", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "game", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "workspace", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "return", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "break", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "elseif", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "in", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "pairs", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true},
	{["Keyword"] = "ipairs", ["Color"] = Color3.new(0, 0, 127/255), ["Independent"] = true}
}

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

function AddZeros(num,reach)
	local toConvert = tostring(num)
	while #toConvert < reach do
		toConvert = " "..toConvert
	end
	return toConvert
end

function buildScript(source,xOff,yOff,override)
	local buildingRows = true
	local buildScr = source
	
	local totalLines = 0
	
	--print(xOff,yOff)
	
	if currentSource ~= source then
		currentSource = source
	end

	if override then
		currentSource = source
		entries = {}
		while buildingRows do
			local x,y = string.find(buildScr,"\n")
			if x and y then
				table.insert(entries,string.sub(buildScr,1,y))
				buildScr = string.sub(buildScr,y+1,string.len(buildScr))
			else
				buildingRows = false
				table.insert(entries,buildScr)
			end
		end
	end
	
	totalLines = #entries
	lineSpan = #tostring(totalLines)
	
	if lineSpan == 1 then lineSpan = 2 end
	
	local currentRow = 1
	local currentColumn = 2 + lineSpan
	
	local colorTime = 0
	local colorReplace = nil
	
	local inString = false
	
	local workingEntries = entries
	
	--[[
	for i,v in pairs(entries) do
		table.insert(workingEntries,v)
	end
	
	for i = 1,yOff do
		table.remove(workingEntries,1)
	end
	--]]
	
	local delayance = xOff

	for i = 1,#grid do
		for j = 1,#grid[i] do
			if i <= lineSpan then
				local newNum = AddZeros(yOff + j,lineSpan)
				local newDigit =  string.sub(newNum,i,i)
				if newDigit == " " then
					grid[i][j].Text = ""
				else
					grid[i][j].Text = newDigit
				end
				grid[i][j].BackgroundTransparency = 0
				grid[i][j].BackgroundColor3 = Color3.new(163/255, 162/255, 165/255)
				--grid[i][j].Font = Enum.Font.SourceSansBold
			elseif i == lineSpan + 1 then
				grid[i][j].Text = ""
				grid[i][j].BackgroundTransparency = 0
				grid[i][j].BackgroundColor3 = Color3.new(200/255, 200/255, 200/255)
				--grid[i][j].Font = Enum.Font.SourceSans
			else
				grid[i][j].Text = ""
				grid[i][j].BackgroundTransparency = 1
				--grid[i][j].Font = Enum.Font.SourceSans
			end
		end
	end
	
	while true do
		if currentRow > #workingEntries or currentRow > #grid[1] then break end
		local entry = workingEntries[currentRow+yOff]
		while string.len(entry) > 0 do
			if string.sub(entry,1,1) == "\t" then entry = "    "..string.sub(entry,2) end
			
			if currentColumn > #grid then break end
			
			if delayance == 0 then
				grid[currentColumn][currentRow].Text = string.sub(entry,1,1)
			end
			
			-- Coloring
			
			if not inString then
				for i,v in pairs(syntaxHighlightList) do
					if string.sub(entry,1,string.len(v["Keyword"])) == v["Keyword"] then
						if v["Independent"] then
							local outCheck = string.len(v["Keyword"])+1
							local outEntry = string.sub(entry,outCheck,outCheck)
							if not string.find(outEntry,"%w") then
								colorTime = string.len(v["Keyword"])
								colorReplace = v["Color"]
							end
						else
							colorTime = string.len(v["Keyword"])
							colorReplace = v["Color"]
						end
					end
				end
			end
			
			if string.sub(entry,1,1) == "\"" and string.match(entry,"\".+\"") then
				inString = true
				colorTime = string.len(string.match(entry,"\".+\""))
				colorReplace = Color3.new(170/255, 0, 1)
			end
			
			if colorTime > 0 then
				colorTime = colorTime - 1
				grid[currentColumn][currentRow].TextColor3 = colorReplace
				if colorTime == 0 then inString = false end
			else
				grid[currentColumn][currentRow].TextColor3 = Color3.new(0,0,0)
				inString = false
			end
			
			if delayance == 0 then
				currentColumn = currentColumn + 1
			else
				delayance = delayance - 1
			end
			entry = string.sub(entry,2,string.len(entry))
		end
		currentRow = currentRow + 1
		currentColumn = 2 + lineSpan
		colorTime = 0
		delayance = xOff
		inString = false
	end
end

function scrollBar.UpdateCallback(self)
	scrollBar.TotalSpace = #entries * 16
	scrollBar.VisibleSpace = editorGrid.AbsoluteSize.Y
	buildScript(currentSource,math.floor(scrollBarH.ScrollIndex/8),math.floor(scrollBar.ScrollIndex/16))
end

function scrollBarH.UpdateCallback(self)
	scrollBarH.TotalSpace = (getLongestEntry(entries) + 1 + lineSpan) * 8
	scrollBarH.VisibleSpace = editorGrid.AbsoluteSize.X
	buildScript(currentSource,math.floor(scrollBarH.ScrollIndex/8),math.floor(scrollBar.ScrollIndex/16))
end

function getLongestEntry(tab)
	local longest = 0
	for i,v in pairs(tab) do
		if string.len(v) > longest then
			longest = string.len(v)
		end
	end
	return longest
end

function decompileS(obj)
	local src = decompile(obj)
	return src
end

function openScript(scrObj)
	if scrObj:IsA("LocalScript") then
		scrObj.Archivable = true
		scrObj = scrObj:Clone()
		scrObj.Disabled = true
	end
	
	local scrName = scrObj.Name
	local scrSource = decompileS(scrObj)
	
	table.insert(memoryScripts,{Name = scrName,Source = scrSource})
	
	local newTab = entryTemplate:Clone()
	newTab.Button.Text = scrName
	newTab.Position = UDim2.new(0,#scriptBar:GetChildren() * 100,0,0)
	newTab.Visible = true
	
	newTab.Button.MouseButton1Down:connect(function()
		for i,v in pairs(scriptBar:GetChildren()) do
			if v == newTab then
				editingIndex = i
				buildScript(memoryScripts[i].Source,0,0,true)
				scrollBar:ScrollTo(1)
				scrollBar:Update()
				scrollBarH:ScrollTo(1)
				scrollBarH:Update()
			end
		end
	end)
	
	newTab.Close.MouseButton1Click:connect(function()
		for i,v in pairs(scriptBar:GetChildren()) do
			if v == newTab then
				table.remove(memoryScripts,i)
				if editingIndex == i then
					editingIndex = #memoryScripts
					if editingIndex > 0 then
						buildScript(memoryScripts[#memoryScripts].Source,0,0,true)
					else
						buildScript("",0,0,true)
					end
				end
				
				scrollBar:ScrollTo(1)
				scrollBar:Update()
				scrollBarH:ScrollTo(1)
				scrollBarH:Update()
				
				for i2 = i,#scriptBar:GetChildren() do
					scriptBar:GetChildren()[i2].Position = scriptBar:GetChildren()[i2].Position + UDim2.new(0,-100,0,0)
				end
				if editingIndex > i then
					editingIndex = editingIndex - 1
				end
				newTab:Destroy()
			end
		end
	end)
	
	editingIndex = #memoryScripts
	buildScript(scrSource,0,0,true)
	
	newTab.Parent = scriptBar
end

function updateScriptBar()
	local entryCount = 0
	
	scriptBarLeft.Active = false
	scriptBarLeft.AutoButtonColor = false
	for i,v in pairs(scriptBarLeft["Arrow Graphic"]:GetChildren()) do
		v.BackgroundTransparency = 0.7
	end
	scriptBarRight.Active = false
	scriptBarRight.AutoButtonColor = false
	for i,v in pairs(scriptBarRight["Arrow Graphic"]:GetChildren()) do
		v.BackgroundTransparency = 0.7
	end
	for i,v in pairs(scriptBar:GetChildren()) do
		if v.Position.X.Offset < 0 then
			scriptBarLeft.Active = true
			scriptBarLeft.AutoButtonColor = true
			for i,v in pairs(scriptBarLeft["Arrow Graphic"]:GetChildren()) do
				v.BackgroundTransparency = 0
			end
		elseif v.Position.X.Offset >= 0 then
			entryCount = entryCount + 1
			if entryCount == 5 then
				scriptBarRight.Active = true
				scriptBarRight.AutoButtonColor = true
				for i,v in pairs(scriptBarRight["Arrow Graphic"]:GetChildren()) do
					v.BackgroundTransparency = 0
				end
			end
		end
	end
end

scriptBar.ChildAdded:connect(updateScriptBar)
scriptBar.ChildRemoved:connect(updateScriptBar)

scriptBarLeft.MouseButton1Click:connect(function()
	if scriptBarLeft.Active == false then return end
	for i,v in pairs(scriptBar:GetChildren()) do
		v.Position = v.Position + UDim2.new(0,100,0,0)
	end
	updateScriptBar()
end)

scriptBarRight.MouseButton1Click:connect(function()
	if scriptBarRight.Active == false then return end
	for i,v in pairs(scriptBar:GetChildren()) do
		v.Position = v.Position + UDim2.new(0,-100,0,0)
	end
	updateScriptBar()
end)

mouse.Button1Down:connect(function()
	if checkMouseInGui(editorGrid) then
		--print("LETS EDIT!")
	end
end)

openEvent.Event:connect(function(...)
	top.Visible = true
	local args = {...}
	if #args > 0 then
		openScript(args[1])
	end
end)

clipboardButton.MouseButton1Click:connect(function()
	if Clipboard and Clipboard.set then
		Clipboard.set(currentSource)
	elseif CopyString then
		CopyString(currentSource)
	end
end)

closeButton.MouseButton1Click:connect(function()
	top.Visible = false
end)

--[[
local scr = script.Parent:WaitForChild("Scr")
local scr2 = script.Parent:WaitForChild("Scr2")
local scr3 = script.Parent:WaitForChild("Scr3")
local scr4 = script.Parent:WaitForChild("TOS")
local scr5 = script.Parent:WaitForChild("HW")
--]]

buildScript("",0,0,true)
--[[
openScript(scr)
openScript(scr2)
openScript(scr3)
openScript(scr4)
openScript(scr5)
--]]

scrollBar:Update()
scrollBarH:Update()