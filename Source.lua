--[[
	xD Interface Suite
	A single-file, drop-in Roblox UI library.

	Visual language: "Glass 2026" — frosted acrylic panels, glow accents,
	spring-driven motion, and a component API that is a superset of the
	classic Window -> TabSection -> Tab -> Groupbox -> Component pattern.

	Usage:
		local xD = loadstring(readfile("xD/Source.lua"))()
		local Window = xD:CreateWindow({ Title = "xD", SubTitle = "Glass 2026" })
		...

	No external HTTP dependencies are required at runtime.
]]

local xD = {}
xD.__index = xD

xD.Version = "1.0.0"
xD.Flags = {}
xD.Windows = {}
xD.Theme = nil
xD.ConfigFolder = "xD/Configs"
xD.ThemeFolder = "xD/Themes"
xD.ToggleKey = Enum.KeyCode.RightControl

-- ============================================================
-- SERVICES
-- ============================================================

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")
local GuiService = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- FILESYSTEM SHIMS (executor globals, guarded for editors/tests)
-- ============================================================

local fs = {
	isfolder = (isfolder or function() return false end),
	makefolder = (makefolder or function() end),
	writefile = (writefile or function() end),
	readfile = (readfile or function() return "" end),
	isfile = (isfile or function() return false end),
	listfiles = (listfiles or function() return {} end),
	delfile = (delfile or function() end),
}

-- ============================================================
-- UTILITIES
-- ============================================================

local Utils = {}

function Utils.New(className, props, children)
	local inst = Instance.new(className)
	if props then
		for key, value in pairs(props) do
			if key ~= "Parent" then
				inst[key] = value
			end
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	if props and props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end
local New = Utils.New

function Utils.Round(value, increment)
	increment = increment or 1
	if increment == 0 then return value end
	return math.floor((value / increment) + 0.5) * increment
end

function Utils.Clamp(value, min, max)
	if value < min then return min end
	if value > max then return max end
	return value
end

function Utils.Lerp(a, b, t)
	return a + (b - a) * t
end

function Utils.LerpColor(colorA, colorB, t)
	return Color3.new(
		Utils.Lerp(colorA.R, colorB.R, t),
		Utils.Lerp(colorA.G, colorB.G, t),
		Utils.Lerp(colorA.B, colorB.B, t)
	)
end

function Utils.Shade(color, amount)
	-- amount > 0 lightens, amount < 0 darkens
	local h, s, v = color:ToHSV()
	v = Utils.Clamp(v + amount, 0, 1)
	s = Utils.Clamp(s - amount * 0.15, 0, 1)
	return Color3.fromHSV(h, s, v)
end

function Utils.Tween(instance, info, props)
	if typeof(info) == "number" then
		info = TweenInfo.new(info, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	end
	local tween = TweenService:Create(instance, info, props)
	tween:Play()
	return tween
end

function Utils.FastTween(instance, props, duration)
	return Utils.Tween(instance, TweenInfo.new(duration or 0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
end

-- Critically-damped spring driven by Heartbeat, used for buttery motion
-- (indicator following selected tab, hover pop, drag release, etc).
local Spring = {}
Spring.__index = Spring

function Spring.new(initial, speed, damping)
	local self = setmetatable({}, Spring)
	self.Value = initial
	self.Target = initial
	self.Velocity = 0 * 0
	self.Speed = speed or 16
	self.Damping = damping or 1
	self.Connection = nil
	self.OnStep = nil
	self._isNumber = typeof(initial) == "number"
	return self
end

function Spring:SetTarget(target)
	self.Target = target
	self:_ensureRunning()
end

function Spring:SetImmediate(value)
	self.Value = value
	self.Target = value
	self.Velocity = self._isNumber and 0 or Vector2.new(0, 0)
end

function Spring:_ensureRunning()
	if self.Connection then return end
	self.Connection = RunService.Heartbeat:Connect(function(dt)
		dt = math.min(dt, 1 / 30)
		local displacement = self._isNumber and (self.Target - self.Value) or (self.Target - self.Value)
		local springForce = displacement * (self.Speed * self.Speed)
		local dampingForce = self.Velocity * (2 * self.Damping * self.Speed)
		local accel = springForce - dampingForce
		self.Velocity = self.Velocity + accel * dt
		self.Value = self.Value + self.Velocity * dt

		local atRest
		if self._isNumber then
			atRest = math.abs(self.Target - self.Value) < 0.001 and math.abs(self.Velocity) < 0.001
		else
			atRest = (self.Target - self.Value).Magnitude < 0.001 and self.Velocity.Magnitude < 0.001
		end

		if self.OnStep then
			self.OnStep(self.Value)
		end

		if atRest then
			self.Value = self.Target
			self.Velocity = self._isNumber and 0 or Vector2.new(0, 0)
			if self.OnStep then self.OnStep(self.Value) end
			self.Connection:Disconnect()
			self.Connection = nil
		end
	end)
end

function Spring:Destroy()
	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end
end

Utils.Spring = Spring

-- Draggable: works for both windows (position) and sliders/handles (custom delta callback)
function Utils.MakeDraggable(handle, target, options)
	options = options or {}
	local dragging = false
	local dragStart, startPos

	local function update(input)
		local delta = input.Position - dragStart
		local newPos = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
		if options.OnDrag then
			options.OnDrag(newPos, delta)
		else
			target.Position = newPos
		end
	end

	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = target.Position
			if options.OnStart then options.OnStart() end
			local conn
			conn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					if options.OnEnd then options.OnEnd() end
					conn:Disconnect()
				end
			end)
		end
	end)

	handle.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			update(input)
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			update(input)
		end
	end)
end

-- Ripple / sheen sweep used on button press for a premium tactile feel
function Utils.Ripple(parent, inputPos)
	local absPos = parent.AbsolutePosition
	local absSize = parent.AbsoluteSize
	local relativeX = inputPos and (inputPos.X - absPos.X) or absSize.X / 2
	local relativeY = inputPos and (inputPos.Y - absPos.Y) or absSize.Y / 2

	local circle = New("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.85,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(relativeX, relativeY),
		Size = UDim2.fromOffset(0, 0),
		ZIndex = parent.ZIndex + 5,
		Parent = parent,
	}, {
		New("UICorner", { CornerRadius = UDim.new(1, 0) }),
	})

	local maxDim = math.max(absSize.X, absSize.Y) * 1.8
	Utils.Tween(circle, TweenInfo.new(0.55, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(maxDim, maxDim),
		BackgroundTransparency = 1,
	})
	task.delay(0.55, function()
		circle:Destroy()
	end)
end

xD.Utils = Utils

-- ============================================================
-- ICON KIT (self-contained, no external icon service required)
-- ============================================================
-- `Icon` fields accept either:
--   * "rbxassetid://123..." / a numeric asset id (used directly as an image)
--   * a built-in shape name from IconKit.Shapes (drawn procedurally, no
--     network request, so the library has zero external runtime deps)

local IconKit = {}
IconKit.Shapes = {
	"close", "minimize", "chevron-down", "chevron-right", "check",
	"circle", "square", "dot", "search", "settings", "info", "warning",
	"error", "success", "power", "pin", "grip",
}

function IconKit.Resolve(icon, size, color, parent)
	local holder = New("Frame", {
		BackgroundTransparency = 1,
		Size = size or UDim2.fromOffset(16, 16),
		Parent = parent,
	})

	if typeof(icon) == "number" or (typeof(icon) == "string" and (icon:match("^rbxassetid://") or icon:match("^%d+$"))) then
		local id = typeof(icon) == "number" and ("rbxassetid://" .. icon) or icon
		New("ImageLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Image = id,
			ImageColor3 = color or Color3.new(1, 1, 1),
			Parent = holder,
		})
		return holder
	end

	color = color or Color3.new(1, 1, 1)

	if icon == "close" then
		for _, rot in ipairs({45, -45}) do
			New("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(1, 0, 0, 2),
				Rotation = rot,
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				Parent = holder,
			}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		end
	elseif icon == "minimize" then
		New("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, 0, 0, 2),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = holder,
		}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	elseif icon == "chevron-down" or icon == "chevron-right" then
		local rotation = icon == "chevron-down" and 45 or -45
		New("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.55, 0.55),
			Rotation = icon == "chevron-down" and 45 or 45,
			BackgroundTransparency = 1,
			Parent = holder,
		}, {
			New("UICorner", {}),
			New("Frame", {
				Size = UDim2.new(1, 0, 0, 2),
				Position = UDim2.fromScale(0, 1),
				AnchorPoint = Vector2.new(0, 1),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			}),
			New("Frame", {
				Size = UDim2.new(0, 2, 1, 0),
				Position = UDim2.fromScale(1, 0),
				AnchorPoint = Vector2.new(1, 0),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			}),
		})
		if icon == "chevron-right" then
			holder.Rotation = -90
		end
	elseif icon == "check" then
		New("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Parent = holder,
		}, {
			New("Frame", {
				Size = UDim2.new(0.5, 0, 0, 2),
				Position = UDim2.fromScale(0.05, 0.55),
				Rotation = 45,
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) }),
			New("Frame", {
				Size = UDim2.new(0.85, 0, 0, 2),
				Position = UDim2.fromScale(0.3, 0.55),
				Rotation = -45,
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) }),
		})
	elseif icon == "grip" then
		for row = 0, 2 do
			for col = 0, 1 do
				New("Frame", {
					Size = UDim2.fromOffset(3, 3),
					Position = UDim2.fromScale(0.3 + col * 0.4, 0.15 + row * 0.35),
					BackgroundColor3 = color,
					BorderSizePixel = 0,
					Parent = holder,
				}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
			end
		end
	elseif icon == "search" then
		New("Frame", {
			Size = UDim2.fromScale(0.6, 0.6),
			Position = UDim2.fromScale(0.05, 0.05),
			BackgroundTransparency = 1,
			Parent = holder,
		}, {
			New("UICorner", { CornerRadius = UDim.new(1, 0) }),
			New("UIStroke", { Color = color, Thickness = 1.5 }),
		})
		New("Frame", {
			Size = UDim2.new(0, 2, 0, 7),
			Position = UDim2.fromScale(0.62, 0.62),
			Rotation = 45,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = holder,
		}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	elseif icon == "pin" then
		New("Frame", {
			Size = UDim2.fromScale(0.5, 0.5),
			Position = UDim2.fromScale(0.25, 0.05),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = holder,
		}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		New("Frame", {
			Size = UDim2.new(0, 2, 0.5, 0),
			Position = UDim2.fromScale(0.5, 0.45),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = holder,
		})
	elseif icon == "power" then
		New("Frame", {
			Size = UDim2.fromScale(0.7, 0.7),
			Position = UDim2.fromScale(0.15, 0.2),
			BackgroundTransparency = 1,
			Parent = holder,
		}, {
			New("UICorner", { CornerRadius = UDim.new(1, 0) }),
			New("UIStroke", { Color = color, Thickness = 1.6 }),
		})
		New("Frame", {
			Size = UDim2.new(0, 2, 0.4, 0),
			Position = UDim2.fromScale(0.5, 0),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = holder,
		})
	elseif icon == "dot" or icon == "circle" then
		New("Frame", {
			Size = icon == "dot" and UDim2.fromScale(0.4, 0.4) or UDim2.fromScale(0.8, 0.8),
			Position = icon == "dot" and UDim2.fromScale(0.3, 0.3) or UDim2.fromScale(0.1, 0.1),
			BackgroundColor3 = color,
			BackgroundTransparency = icon == "circle" and 1 or 0,
			BorderSizePixel = 0,
			Parent = holder,
		}, {
			New("UICorner", { CornerRadius = UDim.new(1, 0) }),
			icon == "circle" and New("UIStroke", { Color = color, Thickness = 1.5 }) or nil,
		})
	elseif icon == "square" then
		New("Frame", {
			Size = UDim2.fromScale(0.8, 0.8),
			Position = UDim2.fromScale(0.1, 0.1),
			BackgroundTransparency = 1,
			Parent = holder,
		}, {
			New("UICorner", { CornerRadius = UDim.new(0, 3) }),
			New("UIStroke", { Color = color, Thickness = 1.5 }),
		})
	elseif icon == "settings" then
		New("Frame", {
			Size = UDim2.fromScale(0.75, 0.75),
			Position = UDim2.fromScale(0.125, 0.125),
			BackgroundTransparency = 1,
			Parent = holder,
		}, {
			New("UICorner", { CornerRadius = UDim.new(1, 0) }),
			New("UIStroke", { Color = color, Thickness = 2 }),
		})
		New("Frame", {
			Size = UDim2.fromScale(0.3, 0.3),
			Position = UDim2.fromScale(0.35, 0.35),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = holder,
		}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	elseif icon == "info" or icon == "warning" or icon == "error" or icon == "success" then
		New("Frame", {
			Size = UDim2.fromScale(0.85, 0.85),
			Position = UDim2.fromScale(0.075, 0.075),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = holder,
		}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		New("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = (icon == "info" and "i") or (icon == "success" and "✓") or "!",
			TextColor3 = Color3.new(0, 0, 0),
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			Parent = holder,
		})
	end

	return holder
end

xD.IconKit = IconKit

-- ============================================================
-- THEME
-- ============================================================

local Themes = {}

Themes.MidnightGlass = {
	Name = "Midnight Glass",
	Accent = Color3.fromRGB(114, 137, 255),
	AccentDim = Color3.fromRGB(84, 100, 200),
	Background = Color3.fromRGB(14, 15, 20),
	Elevated = Color3.fromRGB(20, 21, 28),
	Panel = Color3.fromRGB(26, 27, 36),
	PanelLight = Color3.fromRGB(34, 35, 46),
	Border = Color3.fromRGB(56, 58, 74),
	Text = Color3.fromRGB(235, 236, 242),
	SubText = Color3.fromRGB(150, 152, 168),
	MutedText = Color3.fromRGB(105, 107, 122),
	Success = Color3.fromRGB(94, 214, 148),
	Warning = Color3.fromRGB(240, 185, 90),
	Danger = Color3.fromRGB(235, 96, 110),
}

Themes.NebulaPurple = {
	Name = "Nebula Purple",
	Accent = Color3.fromRGB(168, 110, 255),
	AccentDim = Color3.fromRGB(128, 90, 200),
	Background = Color3.fromRGB(16, 12, 22),
	Elevated = Color3.fromRGB(22, 17, 30),
	Panel = Color3.fromRGB(29, 22, 40),
	PanelLight = Color3.fromRGB(38, 29, 52),
	Border = Color3.fromRGB(64, 50, 84),
	Text = Color3.fromRGB(238, 233, 245),
	SubText = Color3.fromRGB(160, 150, 175),
	MutedText = Color3.fromRGB(112, 104, 128),
	Success = Color3.fromRGB(102, 224, 160),
	Warning = Color3.fromRGB(244, 190, 100),
	Danger = Color3.fromRGB(240, 100, 130),
}

Themes.Solar = {
	Name = "Solar",
	Accent = Color3.fromRGB(255, 158, 68),
	AccentDim = Color3.fromRGB(210, 128, 55),
	Background = Color3.fromRGB(18, 16, 14),
	Elevated = Color3.fromRGB(24, 21, 18),
	Panel = Color3.fromRGB(32, 28, 24),
	PanelLight = Color3.fromRGB(42, 37, 31),
	Border = Color3.fromRGB(68, 60, 50),
	Text = Color3.fromRGB(245, 240, 232),
	SubText = Color3.fromRGB(175, 165, 152),
	MutedText = Color3.fromRGB(120, 112, 100),
	Success = Color3.fromRGB(120, 210, 120),
	Warning = Color3.fromRGB(250, 200, 90),
	Danger = Color3.fromRGB(235, 100, 90),
}

xD.Themes = Themes
xD.Theme = Themes.MidnightGlass

-- Every themable instance registers here as { Instance, PropertyName, ThemeKey, Modifier }
-- so SetTheme can retint everything live without rebuilding the UI.
local ThemeRegistry = {}

function xD:RegisterThemable(instance, property, themeKey, modifier)
	table.insert(ThemeRegistry, {
		Instance = instance,
		Property = property,
		Key = themeKey,
		Modifier = modifier,
	})
	instance[property] = modifier and modifier(self.Theme[themeKey]) or self.Theme[themeKey]
end

function xD:SetTheme(theme)
	if typeof(theme) == "string" then
		theme = Themes[theme] or self.Theme
	end
	self.Theme = theme
	for i = #ThemeRegistry, 1, -1 do
		local entry = ThemeRegistry[i]
		if not entry.Instance or not entry.Instance.Parent then
			table.remove(ThemeRegistry, i)
		else
			local color = theme[entry.Key]
			if color then
				entry.Instance[entry.Property] = entry.Modifier and entry.Modifier(color) or color
			end
		end
	end
end

function xD:SaveTheme(name)
	local ok = pcall(function()
		if not fs.isfolder(self.ThemeFolder) then fs.makefolder(self.ThemeFolder) end
		local data = {}
		for key, value in pairs(self.Theme) do
			if typeof(value) == "Color3" then
				data[key] = { R = value.R, G = value.G, B = value.B }
			else
				data[key] = value
			end
		end
		fs.writefile(self.ThemeFolder .. "/" .. name .. ".json", HttpService:JSONEncode(data))
	end)
	return ok
end

function xD:LoadAutoloadTheme()
	pcall(function()
		local path = self.ThemeFolder .. "/autoload.txt"
		if fs.isfile(path) then
			local name = fs.readfile(path)
			local themePath = self.ThemeFolder .. "/" .. name .. ".json"
			if fs.isfile(themePath) then
				local data = HttpService:JSONDecode(fs.readfile(themePath))
				local theme = {}
				for key, value in pairs(data) do
					if typeof(value) == "table" and value.R then
						theme[key] = Color3.new(value.R, value.G, value.B)
					else
						theme[key] = value
					end
				end
				self:SetTheme(theme)
			end
		end
	end)
end

-- ============================================================
-- GLASS PRIMITIVES (acrylic panels, elevation shadows, glow)
-- ============================================================

local Glass = {}

-- Faux drop shadow using a 9-slice image, scaled by elevation tier.
function Glass.Shadow(parent, elevation)
	elevation = elevation or 1
	local pad = 14 + elevation * 6
	local shadow = New("ImageLabel", {
		Name = "Shadow",
		BackgroundTransparency = 1,
		Image = "rbxassetid://5554236805",
		ImageColor3 = Color3.new(0, 0, 0),
		ImageTransparency = 0.55 - math.min(elevation * 0.03, 0.15),
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(23, 23, 277, 277),
		Size = UDim2.new(1, pad * 2, 1, pad * 2),
		Position = UDim2.new(0, -pad, 0, -pad),
		ZIndex = parent.ZIndex - 1,
		Parent = parent,
	})
	return shadow
end

-- Frosted acrylic panel: tinted background + top-highlight gradient sheen +
-- soft gradient border stroke, approximating glass without real GUI blur.
function Glass.Panel(props)
	props = props or {}
	local corner = props.Corner or UDim.new(0, 12)
	local theme = xD.Theme

	local panel = New("Frame", {
		Name = props.Name or "GlassPanel",
		BackgroundColor3 = props.Color or theme.Panel,
		BackgroundTransparency = props.Transparency or 0.04,
		BorderSizePixel = 0,
		Size = props.Size,
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		ZIndex = props.ZIndex or 1,
		Parent = props.Parent,
	}, {
		New("UICorner", { CornerRadius = corner }),
	})

	local stroke = New("UIStroke", {
		Color = theme.Border,
		Thickness = 1,
		Transparency = 0.35,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = panel,
	})
	New("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.5, theme.Border),
			ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(0.5, 0.9),
			NumberSequenceKeypoint.new(1, 0.55),
		}),
		Rotation = 90,
		Parent = stroke,
	})

	-- top sheen: subtle brightness gradient to fake glass catching light
	local sheen = New("Frame", {
		Name = "Sheen",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = panel.ZIndex + 1,
		Parent = panel,
	}, {
		New("UICorner", { CornerRadius = corner }),
	})
	New("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.92),
			NumberSequenceKeypoint.new(0.35, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Rotation = 90,
		Parent = sheen,
	})
	sheen.BackgroundTransparency = 0
	sheen.BackgroundColor3 = Color3.new(1, 1, 1)

	if props.Elevation then
		Glass.Shadow(panel, props.Elevation)
	end

	xD:RegisterThemable(panel, "BackgroundColor3", props.ColorKey or "Panel")
	xD:RegisterThemable(stroke, "Color", "Border")

	return panel
end

-- Soft glow used behind accent-colored controls (active tab, checked toggle,
-- filled slider) — an ImageLabel radial gradient pulsing gently on interact.
function Glass.Glow(parent, color, size)
	local glow = New("ImageLabel", {
		Name = "Glow",
		BackgroundTransparency = 1,
		Image = "rbxassetid://5028857084",
		ImageColor3 = color or xD.Theme.Accent,
		ImageTransparency = 0.55,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = size or UDim2.new(1, 24, 1, 24),
		ZIndex = parent.ZIndex - 1,
		Parent = parent,
	})
	return glow
end

xD.Glass = Glass

-- ============================================================
-- ROOT GUI CONTAINER (shared by all windows, notifications, dock)
-- ============================================================

local function GetGuiParent()
	local gui = New("ScreenGui", {
		Name = "xD_Interface",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 999,
		IgnoreGuiInset = true,
	})
	local ok = pcall(function()
		gui.Parent = game:GetService("CoreGui")
	end)
	if not ok then
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end
	return gui
end

local RootGui = GetGuiParent()
xD.RootGui = RootGui

-- ============================================================
-- WINDOW
-- ============================================================

local Window = {}
Window.__index = Window

function xD:CreateWindow(config)
	config = config or {}
	local theme = self.Theme

	local self_ = setmetatable({}, Window)
	self_.Title = config.Title or "xD"
	self_.SubTitle = config.SubTitle
	self_.Size = config.Size or UDim2.fromOffset(680, 460)
	self_.MinSize = Vector2.new(520, 360)
	self_.TabSections = {}
	self_.Tabs = {}
	self_.Visible = true
	self_.ToggleKey = config.ToggleKey or self.ToggleKey
	self_.ConfigFolder = config.ConfigFolder or self.ConfigFolder

	local gui = RootGui

	local main = Glass.Panel({
		Name = "Window",
		Size = self_.Size,
		Position = UDim2.new(0.5, -self_.Size.X.Offset / 2, 0.5, -self_.Size.Y.Offset / 2),
		Corner = UDim.new(0, 14),
		Transparency = 0.03,
		Elevation = 6,
		ZIndex = 10,
		Parent = gui,
	})
	main.ClipsDescendants = true
	main.Active = true
	self_.Main = main

	-- Title bar
	local titleBar = New("Frame", {
		Name = "TitleBar",
		BackgroundColor3 = theme.Elevated,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 42),
		ZIndex = 12,
		Parent = main,
	}, {
		New("UICorner", { CornerRadius = UDim.new(0, 14) }),
	})
	New("Frame", { -- squares off the bottom corners of the title bar
		BackgroundColor3 = theme.Elevated,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0, 0, 1, -14),
		ZIndex = 12,
		Parent = titleBar,
	})
	xD:RegisterThemable(titleBar, "BackgroundColor3", "Elevated")

	New("Frame", {
		BackgroundColor3 = theme.Border,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		ZIndex = 13,
		Parent = titleBar,
	})

	if config.IconId then
		IconKit.Resolve(config.IconId, UDim2.fromOffset(20, 20), theme.Accent, titleBar).Position = UDim2.new(0, 14, 0.5, -10)
	end

	local textOffsetX = config.IconId and 44 or 16
	local titleLabel = New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, textOffsetX, 0, config.SubTitle and 4 or 0),
		Size = UDim2.new(1, -140, 0, config.SubTitle and 18 or 42),
		Font = Enum.Font.GothamBold,
		Text = self_.Title,
		TextSize = 15,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 13,
		Parent = titleBar,
	})
	xD:RegisterThemable(titleLabel, "TextColor3", "Text")

	if config.SubTitle then
		local subLabel = New("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, textOffsetX, 0, 21),
			Size = UDim2.new(1, -140, 0, 14),
			Font = Enum.Font.Gotham,
			Text = config.SubTitle,
			TextSize = 11,
			TextColor3 = theme.SubText,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 13,
			Parent = titleBar,
		})
		xD:RegisterThemable(subLabel, "TextColor3", "SubText")
	end

	-- window control buttons (close / minimize)
	local function makeWindowButton(offsetFromRight, iconName, hoverColor, onClick)
		local btn = New("TextButton", {
			BackgroundColor3 = theme.PanelLight,
			BackgroundTransparency = 0.2,
			Size = UDim2.fromOffset(26, 26),
			Position = UDim2.new(1, -offsetFromRight, 0.5, -13),
			Text = "",
			AutoButtonColor = false,
			ZIndex = 13,
			Parent = titleBar,
		}, { New("UICorner", { CornerRadius = UDim.new(0, 8) }) })
		local icon = IconKit.Resolve(iconName, UDim2.fromOffset(11, 11), theme.SubText, btn)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)

		btn.MouseEnter:Connect(function()
			Utils.FastTween(btn, { BackgroundColor3 = hoverColor, BackgroundTransparency = 0 }, 0.15)
		end)
		btn.MouseLeave:Connect(function()
			Utils.FastTween(btn, { BackgroundColor3 = theme.PanelLight, BackgroundTransparency = 0.2 }, 0.15)
		end)
		btn.MouseButton1Click:Connect(onClick)
		return btn
	end

	makeWindowButton(36, "close", theme.Danger, function()
		self_:Destroy()
	end)
	makeWindowButton(66, "minimize", theme.PanelLight, function()
		self_:Toggle()
	end)

	Utils.MakeDraggable(titleBar, main)

	-- resize grip
	local resizeGrip = New("TextButton", {
		Name = "ResizeGrip",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(18, 18),
		Position = UDim2.new(1, -18, 1, -18),
		Text = "",
		AutoButtonColor = false,
		ZIndex = 14,
		Parent = main,
	})
	IconKit.Resolve("grip", UDim2.fromOffset(10, 10), theme.MutedText, resizeGrip).Position = UDim2.fromOffset(4, 4)
	Utils.MakeDraggable(resizeGrip, main, {
		OnDrag = function(_, delta)
			local newX = math.max(self_.MinSize.X, main.Size.X.Offset + delta.X)
			local newY = math.max(self_.MinSize.Y, main.Size.Y.Offset + delta.Y)
			main.Size = UDim2.fromOffset(newX, newY)
		end,
	})

	-- Body: sidebar (tab rail) + content
	local body = New("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -42),
		Position = UDim2.new(0, 0, 0, 42),
		ZIndex = 11,
		Parent = main,
	})

	local sidebar = New("Frame", {
		Name = "Sidebar",
		BackgroundColor3 = theme.Elevated,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 190, 1, 0),
		ZIndex = 11,
		Parent = body,
	})
	self_.Sidebar = sidebar
	xD:RegisterThemable(sidebar, "BackgroundColor3", "Elevated")

	New("Frame", {
		BackgroundColor3 = theme.Border,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 1, 1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		ZIndex = 12,
		Parent = sidebar,
	})

	local sidebarScroll = New("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = theme.Border,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = 11,
		Parent = sidebar,
	})
	New("UIListLayout", {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = sidebarScroll,
	})
	New("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 10),
		Parent = sidebarScroll,
	})
	self_.SidebarScroll = sidebarScroll

	-- animated active-tab indicator (spring-follows the selected tab button)
	local indicator = New("Frame", {
		Name = "Indicator",
		BackgroundColor3 = theme.Accent,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(3, 28),
		Position = UDim2.fromOffset(0, 10),
		ZIndex = 12,
		Parent = sidebar,
	}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	xD:RegisterThemable(indicator, "BackgroundColor3", "Accent")
	self_.Indicator = indicator
	self_.IndicatorSpring = Spring.new(10, 22, 1)
	self_.IndicatorSpring.OnStep = function(v)
		indicator.Position = UDim2.new(0, 0, 0, v)
	end

	local content = New("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -190, 1, 0),
		Position = UDim2.new(0, 190, 0, 0),
		ZIndex = 11,
		Parent = body,
	})
	self_.Content = content

	-- floating dock button (shown while window is hidden)
	local dock = New("TextButton", {
		Name = "Dock",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 24, 0.5, 0),
		Size = UDim2.fromOffset(46, 46),
		BackgroundColor3 = theme.Panel,
		Text = "",
		AutoButtonColor = false,
		Visible = false,
		ZIndex = 20,
		Parent = gui,
	}, {
		New("UICorner", { CornerRadius = UDim.new(1, 0) }),
		New("UIStroke", { Color = theme.Accent, Thickness = 1.5, Transparency = 0.4 }),
	})
	Glass.Shadow(dock, 4)
	local dockIcon = IconKit.Resolve("grip", UDim2.fromOffset(16, 16), theme.Accent, dock)
	dockIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	dockIcon.Position = UDim2.fromScale(0.5, 0.5)
	dock.MouseButton1Click:Connect(function()
		self_:Toggle()
	end)
	Utils.MakeDraggable(dock, dock)
	self_.Dock = dock

	self_.Gui = gui

	-- global keybind toggle
	self_.InputConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == self_.ToggleKey then
			self_:Toggle()
		end
	end)

	table.insert(xD.Windows, self_)
	return self_
end

function Window:Toggle()
	self.Visible = not self.Visible
	if self.Visible then
		self.Dock.Visible = false
		self.Main.Visible = true
		self.Main.Size = UDim2.fromOffset(self.Main.Size.X.Offset * 0.94, self.Main.Size.Y.Offset * 0.94)
		Utils.Tween(self.Main, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = self.Size,
		})
	else
		Utils.Tween(self.Main, TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
			Size = UDim2.fromOffset(self.Main.Size.X.Offset * 0.9, self.Main.Size.Y.Offset * 0.9),
		})
		task.delay(0.16, function()
			if not self.Visible then
				self.Main.Visible = false
				self.Dock.Visible = true
			end
		end)
	end
end

function Window:Show() if not self.Visible then self:Toggle() end end
function Window:Hide() if self.Visible then self:Toggle() end end

function Window:CreateWatermark(config)
	config = config or {}
	local theme = xD.Theme
	local wm = Glass.Panel({
		Name = "Watermark",
		Size = UDim2.fromOffset(220, 30),
		Position = UDim2.fromOffset(16, 16),
		Corner = UDim.new(0, 8),
		Transparency = 0.15,
		ZIndex = 30,
		Parent = self.Gui,
	})
	local label = New("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = config.Text or self.Title,
		ZIndex = 31,
		Parent = wm,
	})
	xD:RegisterThemable(label, "TextColor3", "Text")

	local watermark = {}
	function watermark:SetText(text) label.Text = text end
	function watermark:Destroy() wm:Destroy() end
	return watermark
end

function Window:Notify(config)
	return xD:Notify(config)
end

function Window:Destroy()
	if self.InputConn then self.InputConn:Disconnect() end
	if self.IndicatorSpring then self.IndicatorSpring:Destroy() end
	self.Main:Destroy()
	self.Dock:Destroy()
	for i, w in ipairs(xD.Windows) do
		if w == self then table.remove(xD.Windows, i) break end
	end
end

xD.Window = Window

-- ============================================================
-- TAB SECTION + TAB
-- ============================================================

local TabSection = {}
TabSection.__index = TabSection

function Window:CreateTabSection(name)
	local theme = xD.Theme
	local section = setmetatable({}, TabSection)
	section.Window = self
	section.Tabs = {}

	if name then
		local header = New("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 22),
			Font = Enum.Font.GothamBold,
			Text = string.upper(name),
			TextSize = 10,
			TextColor3 = theme.MutedText,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 12,
			LayoutOrder = #self.SidebarScroll:GetChildren(),
			Parent = self.SidebarScroll,
		})
		xD:RegisterThemable(header, "TextColor3", "MutedText")
	end

	return section
end

local Tab = {}
Tab.__index = Tab

function TabSection:CreateTab(config, flag)
	config = config or {}
	local theme = xD.Theme
	local window = self.Window

	-- sidebar button
	local btn = New("TextButton", {
		Name = config.Name or "Tab",
		BackgroundColor3 = theme.PanelLight,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 34),
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = #window.SidebarScroll:GetChildren(),
		ZIndex = 12,
		Parent = window.SidebarScroll,
	}, { New("UICorner", { CornerRadius = UDim.new(0, 8) }) })

	if config.Icon then
		local icon = IconKit.Resolve(config.Icon, UDim2.fromOffset(15, 15), theme.SubText, btn)
		icon.Position = UDim2.new(0, 10, 0.5, -8)
	end

	local label = New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, config.Icon and 34 or 12, 0, 0),
		Size = UDim2.new(1, config.Icon and -40 or -20, 1, 0),
		Font = Enum.Font.GothamMedium,
		Text = config.Name or "Tab",
		TextSize = 13,
		TextColor3 = theme.SubText,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 12,
		Parent = btn,
	})

	-- content page
	local page = New("Frame", {
		Name = (config.Name or "Tab") .. "Page",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		Visible = false,
		Parent = window.Content,
	})
	New("UIPadding", {
		PaddingTop = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
		PaddingBottom = UDim.new(0, 14),
		Parent = page,
	})

	local columnsCount = config.Columns or 1
	local columnsRow = New("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		Parent = page,
	})
	New("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = columnsRow,
	})

	local columns = {}
	for i = 1, columnsCount do
		local col = New("ScrollingFrame", {
			Name = "Column" .. i,
			BackgroundTransparency = 1,
			Size = UDim2.new(1 / columnsCount, -(columnsCount - 1) * 6, 1, 0),
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = theme.Border,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			LayoutOrder = i,
			Parent = columnsRow,
		})
		New("UIListLayout", {
			Padding = UDim.new(0, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = col,
		})
		columns[i] = col
	end

	local tab = setmetatable({}, Tab)
	tab.Name = config.Name
	tab.Window = window
	tab.Page = page
	tab.Columns = columns
	tab.Button = btn
	tab.Label = label

	local function selectTab()
		for _, otherTab in ipairs(window.Tabs) do
			otherTab.Page.Visible = false
			Utils.FastTween(otherTab.Label, { TextColor3 = theme.SubText }, 0.15)
			Utils.FastTween(otherTab.Button, { BackgroundTransparency = 1 }, 0.15)
		end
		page.Visible = true
		Utils.FastTween(label, { TextColor3 = theme.Text }, 0.15)
		Utils.FastTween(btn, { BackgroundTransparency = 0.5 }, 0.15)
		local offsetY = btn.AbsolutePosition.Y - window.Sidebar.AbsolutePosition.Y + 3
		window.IndicatorSpring:SetTarget(offsetY)
		window.ActiveTab = tab
	end
	tab.Select = selectTab

	btn.MouseButton1Click:Connect(function()
		Utils.Ripple(btn)
		selectTab()
	end)
	btn.MouseEnter:Connect(function()
		if window.ActiveTab ~= tab then
			Utils.FastTween(btn, { BackgroundTransparency = 0.8 }, 0.12)
		end
	end)
	btn.MouseLeave:Connect(function()
		if window.ActiveTab ~= tab then
			Utils.FastTween(btn, { BackgroundTransparency = 1 }, 0.12)
		end
	end)

	table.insert(window.Tabs, tab)
	table.insert(self.Tabs, tab)

	if #window.Tabs == 1 then
		task.defer(selectTab)
	end

	return tab
end

xD.TabSection = TabSection
xD.Tab = Tab

-- ============================================================
-- COMPONENT HOST (shared component-factory mixin for Groupbox & Section)
-- ============================================================
-- Populated with CreateButton/CreateToggle/etc below; both Groupbox and
-- Section point their metatable __index at this table so a Section behaves
-- exactly like a Groupbox for component creation.

local ComponentHost = {}
ComponentHost.__index = ComponentHost

-- Builds the standard "row" shell (icon + title on the left, control area on
-- the right) used by nearly every component for a consistent, dense layout.
function ComponentHost:_row(config, rightWidth)
	config = config or {}
	local theme = xD.Theme

	local row = New("Frame", {
		Name = (config.Name or "Row") .. "Row",
		BackgroundColor3 = theme.PanelLight,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = self:_nextOrder(),
		Parent = self.Container,
	}, { New("UICorner", { CornerRadius = UDim.new(0, 8) }) })

	local textOffset = 10
	if config.Icon then
		local icon = IconKit.Resolve(config.Icon, UDim2.fromOffset(15, 15), theme.SubText, row)
		icon.Position = UDim2.new(0, 8, 0.5, -8)
		textOffset = 30
	end

	local title = New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, textOffset, 0, 0),
		Size = UDim2.new(1, -textOffset - (rightWidth or 0) - 10, 1, 0),
		Font = Enum.Font.GothamMedium,
		Text = config.Name or "",
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	xD:RegisterThemable(title, "TextColor3", "Text")

	if config.Tooltip then
		local tip = New("TextLabel", {
			BackgroundColor3 = theme.Elevated,
			Visible = false,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 0, 24),
			Position = UDim2.new(0, textOffset, 1, 2),
			Font = Enum.Font.Gotham,
			Text = config.Tooltip,
			TextSize = 11,
			TextColor3 = theme.SubText,
			ZIndex = 50,
			Parent = row,
		}, {
			New("UICorner", { CornerRadius = UDim.new(0, 6) }),
			New("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
		})
		row.MouseEnter:Connect(function() tip.Visible = true end)
		row.MouseLeave:Connect(function() tip.Visible = false end)
	end

	row.MouseEnter:Connect(function()
		Utils.FastTween(row, { BackgroundTransparency = 0.65 }, 0.12)
	end)
	row.MouseLeave:Connect(function()
		Utils.FastTween(row, { BackgroundTransparency = 1 }, 0.12)
	end)

	return row, title
end

function ComponentHost:_nextOrder()
	self._order = (self._order or 0) + 1
	return self._order
end

function ComponentHost:_registerFlag(flag, element)
	if flag then
		xD.Flags[flag] = element
	end
end

-- ============================================================
-- GROUPBOX + SECTION
-- ============================================================

local Groupbox = setmetatable({}, ComponentHost)
Groupbox.__index = Groupbox

function Tab:CreateGroupbox(config)
	config = config or {}
	local theme = xD.Theme
	local column = self.Columns[config.Column or 1] or self.Columns[1]

	local box = setmetatable({}, Groupbox)
	box.Tab = self

	local panel = Glass.Panel({
		Name = (config.Name or "Groupbox") .. "Box",
		Size = UDim2.new(1, 0, 0, 40),
		Corner = UDim.new(0, 10),
		Transparency = 0.25,
		ColorKey = "Panel",
		Parent = column,
	})
	New("UISizeConstraint", { MinSize = Vector2.new(0, 0) , Parent = panel})
	panel.AutomaticSize = Enum.AutomaticSize.Y

	if config.Name then
		New("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 12, 0, 8),
			Size = UDim2.new(1, -24, 0, 16),
			Font = Enum.Font.GothamBold,
			Text = config.Name,
			TextSize = 12,
			TextColor3 = theme.Accent,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = panel,
		})
		xD:RegisterThemable(panel, "BackgroundColor3", "Panel")
	end

	local container = New("Frame", {
		Name = "Container",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -16, 0, 0),
		Position = UDim2.new(0, 8, 0, config.Name and 28 or 8),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = panel,
	})
	New("UIListLayout", {
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = container,
	})
	New("UIPadding", { PaddingBottom = UDim.new(0, 8), Parent = container })

	box.Panel = panel
	box.Container = container

	return box
end

-- Collapsible sub-section inside a Groupbox: same component API, but its
-- container can be expanded/collapsed with a chevron + spring height tween.
local Section = setmetatable({}, ComponentHost)
Section.__index = Section

function ComponentHost:CreateSection(config)
	config = config or {}
	local theme = xD.Theme

	local section = setmetatable({}, Section)
	section.Expanded = config.Expanded ~= false

	local header = New("TextButton", {
		Name = (config.Name or "Section") .. "Header",
		BackgroundColor3 = theme.PanelLight,
		BackgroundTransparency = 0.5,
		Size = UDim2.new(1, 0, 0, 30),
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = self:_nextOrder(),
		Parent = self.Container,
	}, { New("UICorner", { CornerRadius = UDim.new(0, 8) }) })

	New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 10, 0, 0),
		Size = UDim2.new(1, -36, 1, 0),
		Font = Enum.Font.GothamBold,
		Text = config.Name or "Section",
		TextSize = 12,
		TextColor3 = theme.SubText,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = header,
	})

	local chevron = IconKit.Resolve("chevron-right", UDim2.fromOffset(10, 10), theme.SubText, header)
	chevron.AnchorPoint = Vector2.new(1, 0.5)
	chevron.Position = UDim2.new(1, -10, 0.5, 0)

	local body = New("Frame", {
		Name = "SectionBody",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ClipsDescendants = true,
		LayoutOrder = self:_nextOrder(),
		Visible = section.Expanded,
		Parent = self.Container,
	})
	New("UIListLayout", {
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = body,
	})
	New("UIPadding", { PaddingTop = UDim.new(0, 6), Parent = body })

	section.Container = body
	section.Header = header

	header.MouseButton1Click:Connect(function()
		section.Expanded = not section.Expanded
		body.Visible = section.Expanded
		Utils.FastTween(chevron, { Rotation = section.Expanded and 90 or -90 }, 0.2)
	end)

	return section
end

-- ============================================================
-- CORE COMPONENTS: Button, Toggle, Slider, Input, Label, Paragraph, Separator
-- ============================================================

function ComponentHost:CreateButton(config, flag)
	config = config or {}
	local theme = xD.Theme
	local style = config.Style or 2 -- 1 = accent filled, 2 = ghost

	local row, title = self:_row(config, 0)
	row.BackgroundTransparency = style == 1 and 0 or 1
	if style == 1 then
		row.BackgroundColor3 = theme.Accent
		title.TextColor3 = Color3.new(1, 1, 1)
	end

	local hitbox = New("TextButton", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		AutoButtonColor = false,
		Parent = row,
	})

	hitbox.MouseEnter:Connect(function()
		Utils.FastTween(row, { BackgroundTransparency = style == 1 and 0.15 or 0.6 }, 0.12)
	end)
	hitbox.MouseLeave:Connect(function()
		Utils.FastTween(row, { BackgroundTransparency = style == 1 and 0 or 1 }, 0.12)
	end)
	hitbox.MouseButton1Down:Connect(function()
		Utils.FastTween(row, { Size = UDim2.new(1, 0, 0, 32) }, 0.08)
	end)
	hitbox.MouseButton1Up:Connect(function()
		Utils.FastTween(row, { Size = UDim2.new(1, 0, 0, 34) }, 0.08)
	end)

	local element = {}
	function element:SetText(text) title.Text = text end
	hitbox.MouseButton1Click:Connect(function(x, y)
		Utils.Ripple(row, Vector2.new(x, y))
		if config.Callback then config.Callback() end
	end)

	self:_registerFlag(flag, element)
	return element
end

function ComponentHost:CreateToggle(config, flag)
	config = config or {}
	local theme = xD.Theme
	local value = config.CurrentValue or false

	local switchWidth = 38
	local row = self:_row(config, switchWidth)

	local switch = New("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(switchWidth, 20),
		BackgroundColor3 = value and theme.Accent or theme.PanelLight,
		Parent = row,
	}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local knob = New("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = value and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = switch,
	}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local hitbox = New("TextButton", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		Parent = row,
	})

	local element = {}
	element.Value = value

	local function apply(animated)
		local targetPos = element.Value and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
		local targetColor = element.Value and theme.Accent or theme.PanelLight
		if animated then
			Utils.Tween(knob, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = targetPos })
			Utils.FastTween(switch, { BackgroundColor3 = targetColor }, 0.15)
		else
			knob.Position = targetPos
			switch.BackgroundColor3 = targetColor
		end
	end

	function element:Set(newValue)
		element.Value = newValue
		apply(true)
		if config.Callback then config.Callback(element.Value) end
	end

	hitbox.MouseButton1Click:Connect(function()
		element.Value = not element.Value
		apply(true)
		if config.Callback then config.Callback(element.Value) end
	end)

	self:_registerFlag(flag, element)
	return element
end

function ComponentHost:CreateSlider(config, flag)
	config = config or {}
	local theme = xD.Theme
	local range = config.Range or {0, 100}
	local min, max = range[1], range[2]
	local increment = config.Increment or 1
	local suffix = config.Suffix or ""
	local value = Utils.Clamp(config.CurrentValue or min, min, max)

	local row = New("Frame", {
		Name = (config.Name or "Slider") .. "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = self:_nextOrder(),
		Parent = self.Container,
	})

	local textOffset = 0
	if config.Icon then
		local icon = IconKit.Resolve(config.Icon, UDim2.fromOffset(15, 15), theme.SubText, row)
		icon.Position = UDim2.new(0, 8, 0, 2)
		textOffset = 22
	end

	local title = New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 8 + textOffset, 0, 0),
		Size = UDim2.new(1, -100, 0, 18),
		Font = Enum.Font.GothamMedium,
		Text = config.Name or "",
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	xD:RegisterThemable(title, "TextColor3", "Text")

	local valueLabel = New("TextLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 0),
		Size = UDim2.new(0, 90, 0, 18),
		Font = Enum.Font.GothamBold,
		Text = tostring(value) .. suffix,
		TextSize = 12,
		TextColor3 = theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})
	xD:RegisterThemable(valueLabel, "TextColor3", "Accent")

	local track = New("Frame", {
		Position = UDim2.new(0, 8, 0, 26),
		Size = UDim2.new(1, -16, 0, 6),
		BackgroundColor3 = theme.PanelLight,
		Parent = row,
	}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local fill = New("Frame", {
		Size = UDim2.new((value - min) / (max - min), 0, 1, 0),
		BackgroundColor3 = theme.Accent,
		Parent = track,
	}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	xD:RegisterThemable(fill, "BackgroundColor3", "Accent")

	local knob = New("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new((value - min) / (max - min), 0, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 2,
		Parent = track,
	}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local hitbox = New("TextButton", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, -7, 0, -8),
		Size = UDim2.new(1, 14, 0, 22),
		Text = "",
		Parent = track,
	})

	local element = { Value = value }

	local function applyRatio(ratio, fromUser)
		ratio = Utils.Clamp(ratio, 0, 1)
		local raw = min + (max - min) * ratio
		local stepped = Utils.Round(raw, increment)
		stepped = Utils.Clamp(stepped, min, max)
		element.Value = stepped
		local newRatio = (stepped - min) / (max - min)
		fill.Size = UDim2.new(newRatio, 0, 1, 0)
		knob.Position = UDim2.new(newRatio, 0, 0.5, 0)
		local display = (increment % 1 == 0) and tostring(math.floor(stepped)) or string.format("%.2f", stepped)
		valueLabel.Text = display .. suffix
		if fromUser and config.Callback then
			config.Callback(stepped)
		end
	end

	local dragging = false
	hitbox.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			local ratio = (input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
			applyRatio(ratio, true)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local ratio = (input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
			applyRatio(ratio, true)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	function element:Set(newValue)
		applyRatio((newValue - min) / (max - min), true)
	end

	self:_registerFlag(flag, element)
	return element
end

-- Fast-path wrapper for integer-only sliders (Starlight doesn't offer this
-- as a distinct primitive; ours snaps to whole numbers and shows no decimals).
function ComponentHost:CreateSteppedSlider(config, flag)
	config = config or {}
	config.Increment = math.max(1, math.floor(config.Increment or 1))
	config.CurrentValue = math.floor(config.CurrentValue or config.Range and config.Range[1] or 0)
	return self:CreateSlider(config, flag)
end

function ComponentHost:CreateInput(config, flag)
	config = config or {}
	local theme = xD.Theme

	local row = New("Frame", {
		Name = (config.Name or "Input") .. "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, config.Name and 46 or 30),
		LayoutOrder = self:_nextOrder(),
		Parent = self.Container,
	})

	if config.Name then
		local title = New("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 8, 0, 0),
			Size = UDim2.new(1, -16, 0, 16),
			Font = Enum.Font.GothamMedium,
			Text = config.Name,
			TextSize = 13,
			TextColor3 = theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		xD:RegisterThemable(title, "TextColor3", "Text")
	end

	local box = New("Frame", {
		Position = UDim2.new(0, 8, 0, config.Name and 20 or 0),
		Size = UDim2.new(1, -16, 0, 26),
		BackgroundColor3 = theme.PanelLight,
		Parent = row,
	}, { New("UICorner", { CornerRadius = UDim.new(0, 6) }) })

	if config.Icon then
		IconKit.Resolve(config.Icon, UDim2.fromOffset(13, 13), theme.SubText, box).Position = UDim2.new(0, 8, 0.5, -7)
	end

	local textBox = New("TextBox", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, config.Icon and 28 or 8, 0, 0),
		Size = UDim2.new(1, -(config.Icon and 36 or 16), 1, 0),
		Font = Enum.Font.Gotham,
		Text = config.CurrentValue or "",
		PlaceholderText = config.PlaceholderText or "",
		PlaceholderColor3 = theme.MutedText,
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Parent = box,
	})
	xD:RegisterThemable(textBox, "TextColor3", "Text")

	local stroke = New("UIStroke", { Color = theme.Border, Transparency = 0.5, Parent = box })
	textBox.Focused:Connect(function()
		Utils.FastTween(stroke, { Color = theme.Accent, Transparency = 0 }, 0.15)
	end)
	textBox.FocusLost:Connect(function(enterPressed)
		Utils.FastTween(stroke, { Color = theme.Border, Transparency = 0.5 }, 0.15)
		if config.Callback then config.Callback(textBox.Text, enterPressed) end
	end)

	local element = { Value = config.CurrentValue or "" }
	function element:Set(text) textBox.Text = text end
	function element:Get() return textBox.Text end

	self:_registerFlag(flag, element)
	return element
end

function ComponentHost:CreateLabel(config)
	config = config or {}
	local theme = xD.Theme
	local row = New("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = self:_nextOrder(),
		Parent = self.Container,
	})
	local label = New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 8, 0, 0),
		Size = UDim2.new(1, -16, 1, 0),
		Font = Enum.Font.GothamMedium,
		Text = config.Name or "",
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Parent = row,
	})
	xD:RegisterThemable(label, "TextColor3", "Text")
	local element = {}
	function element:SetText(text) label.Text = text end
	return element
end

function ComponentHost:CreateParagraph(config)
	config = config or {}
	local theme = xD.Theme
	local row = New("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = self:_nextOrder(),
		Parent = self.Container,
	})
	if config.Name then
		New("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 8, 0, 4),
			Size = UDim2.new(1, -16, 0, 16),
			Font = Enum.Font.GothamBold,
			Text = config.Name,
			TextSize = 13,
			TextColor3 = theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
	end
	local content = New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 8, 0, config.Name and 22 or 4),
		Size = UDim2.new(1, -16, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Enum.Font.Gotham,
		Text = config.Content or "",
		TextSize = 12,
		TextColor3 = theme.SubText,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Parent = row,
	})
	New("UIPadding", { PaddingBottom = UDim.new(0, 6), Parent = row })
	xD:RegisterThemable(content, "TextColor3", "SubText")
	local element = {}
	function element:SetText(text) content.Text = text end
	return element
end

function ComponentHost:CreateSeparator()
	local theme = xD.Theme
	local row = New("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 9),
		LayoutOrder = self:_nextOrder(),
		Parent = self.Container,
	})
	local line = New("Frame", {
		BackgroundColor3 = theme.Border,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.new(1, -16, 0, 1),
		Parent = row,
	})
	xD:RegisterThemable(line, "BackgroundColor3", "Border")
	return {}
end

-- ============================================================
-- ADVANCED COMPONENTS: Dropdown (+searchable/multi), Keybind, ColorPicker
-- ============================================================

-- Tracks the currently open popup so opening a new one closes the last.
local OpenPopup = nil
local function ClosePopup()
	if OpenPopup then
		OpenPopup()
		OpenPopup = nil
	end
end

local function BuildDropdown(host, config, flag, searchable)
	config = config or {}
	local theme = xD.Theme
	local items = config.List or config.Items or {}
	local multi = config.Multi == true

	local selected = {}
	if multi then
		for _, v in ipairs(config.CurrentOption or {}) do selected[v] = true end
	else
		selected[config.CurrentOption] = true
	end

	local row, title = host:_row(config, 110)

	local display = New("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(110, 24),
		BackgroundColor3 = theme.PanelLight,
		Parent = row,
	}, { New("UICorner", { CornerRadius = UDim.new(0, 6) }) })

	local displayLabel = New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 8, 0, 0),
		Size = UDim2.new(1, -24, 1, 0),
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = theme.SubText,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = display,
	})

	local chevron = IconKit.Resolve("chevron-down", UDim2.fromOffset(9, 9), theme.SubText, display)
	chevron.AnchorPoint = Vector2.new(1, 0.5)
	chevron.Position = UDim2.new(1, -8, 0.5, 0)

	local hitbox = New("TextButton", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "", Parent = display })

	local element = { Value = multi and config.CurrentOption or config.CurrentOption }

	local function refreshDisplay()
		if multi then
			local names = {}
			for _, item in ipairs(items) do
				if selected[item] then table.insert(names, item) end
			end
			displayLabel.Text = #names > 0 and table.concat(names, ", ") or "None"
			element.Value = names
		else
			local chosen
			for item in pairs(selected) do chosen = item end
			displayLabel.Text = chosen or "Select..."
			element.Value = chosen
		end
	end
	refreshDisplay()

	local popup, popupList
	local isOpen = false

	local function destroyPopup()
		if popup then popup:Destroy() popup = nil end
		isOpen = false
		Utils.FastTween(chevron, { Rotation = 0 }, 0.15)
	end

	local function buildOptionButton(item, container)
		local optBtn = New("TextButton", {
			BackgroundColor3 = theme.PanelLight,
			BackgroundTransparency = selected[item] and 0.2 or 1,
			Size = UDim2.new(1, 0, 0, 26),
			Text = "",
			AutoButtonColor = false,
			Parent = container,
		}, { New("UICorner", { CornerRadius = UDim.new(0, 6) }) })
		New("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 8, 0, 0),
			Size = UDim2.new(1, -16, 1, 0),
			Font = Enum.Font.Gotham,
			Text = tostring(item),
			TextSize = 12,
			TextColor3 = selected[item] and theme.Accent or theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = optBtn,
		})
		optBtn.MouseEnter:Connect(function()
			Utils.FastTween(optBtn, { BackgroundTransparency = 0.5 }, 0.1)
		end)
		optBtn.MouseLeave:Connect(function()
			Utils.FastTween(optBtn, { BackgroundTransparency = selected[item] and 0.2 or 1 }, 0.1)
		end)
		optBtn.MouseButton1Click:Connect(function()
			if multi then
				selected[item] = not selected[item] or nil
				refreshDisplay()
				optBtn.BackgroundTransparency = selected[item] and 0.2 or 1
			else
				selected = { [item] = true }
				refreshDisplay()
				destroyPopup()
			end
			if config.Callback then config.Callback(element.Value) end
		end)
		return optBtn
	end

	local function openPopup()
		ClosePopup()
		isOpen = true
		Utils.FastTween(chevron, { Rotation = 180 }, 0.15)

		local absPos = display.AbsolutePosition
		local absSize = display.AbsoluteSize
		local listHeight = math.min(#items * 28 + (searchable and 34 or 6) + 6, 220)

		popup = Glass.Panel({
			Name = "DropdownPopup",
			Size = UDim2.fromOffset(math.max(absSize.X, 160), listHeight),
			Position = UDim2.fromOffset(absPos.X - math.max(absSize.X, 160) + absSize.X, absPos.Y + absSize.Y + 4),
			Corner = UDim.new(0, 8),
			Transparency = 0.02,
			Elevation = 4,
			ZIndex = 100,
			Parent = xD.RootGui,
		})

		local listContainer = popup
		local searchBox
		if searchable then
			local searchHolder = New("Frame", {
				Size = UDim2.new(1, -12, 0, 26),
				Position = UDim2.new(0, 6, 0, 6),
				BackgroundColor3 = theme.PanelLight,
				ZIndex = 101,
				Parent = popup,
			}, { New("UICorner", { CornerRadius = UDim.new(0, 6) }) })
			searchBox = New("TextBox", {
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 8, 0, 0),
				Size = UDim2.new(1, -16, 1, 0),
				Font = Enum.Font.Gotham,
				PlaceholderText = "Search...",
				PlaceholderColor3 = theme.MutedText,
				Text = "",
				TextSize = 12,
				TextColor3 = theme.Text,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 101,
				Parent = searchHolder,
			})
		end

		popupList = New("ScrollingFrame", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 6, 0, searchable and 36 or 6),
			Size = UDim2.new(1, -12, 1, -(searchable and 42 or 12)),
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ZIndex = 101,
			Parent = popup,
		})
		New("UIListLayout", { Padding = UDim.new(0, 2), Parent = popupList })

		local optionButtons = {}
		for _, item in ipairs(items) do
			optionButtons[item] = buildOptionButton(item, popupList)
		end

		if searchable and searchBox then
			searchBox:GetPropertyChangedSignal("Text"):Connect(function()
				local query = string.lower(searchBox.Text)
				for item, btn in pairs(optionButtons) do
					btn.Visible = query == "" or string.find(string.lower(tostring(item)), query, 1, true) ~= nil
				end
			end)
		end

		OpenPopup = destroyPopup
	end

	hitbox.MouseButton1Click:Connect(function()
		if isOpen then
			destroyPopup()
			OpenPopup = nil
		else
			openPopup()
		end
	end)

	function element:Refresh(newItems)
		items = newItems
	end
	function element:Set(newValue)
		if multi then
			selected = {}
			for _, v in ipairs(newValue) do selected[v] = true end
		else
			selected = { [newValue] = true }
		end
		refreshDisplay()
		if config.Callback then config.Callback(element.Value) end
	end

	host:_registerFlag(flag, element)
	return element
end

function ComponentHost:CreateDropdown(config, flag)
	return BuildDropdown(self, config, flag, false)
end

function ComponentHost:CreateSearchableDropdown(config, flag)
	return BuildDropdown(self, config, flag, true)
end

function ComponentHost:CreateKeybind(config, flag)
	config = config or {}
	local theme = xD.Theme
	local current = config.CurrentKeybind or Enum.KeyCode.Unknown

	local row = self:_row(config, 90)
	local pill = New("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(90, 22),
		BackgroundColor3 = theme.PanelLight,
		Text = "",
		AutoButtonColor = false,
		Parent = row,
	}, { New("UICorner", { CornerRadius = UDim.new(0, 6) }) })

	local label = New("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBold,
		Text = current == Enum.KeyCode.Unknown and "None" or current.Name,
		TextSize = 11,
		TextColor3 = theme.Accent,
		Parent = pill,
	})

	local listening = false
	local element = { Value = current }

	pill.MouseButton1Click:Connect(function()
		listening = true
		label.Text = "..."
		Utils.FastTween(pill, { BackgroundColor3 = theme.Accent }, 0.12)
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if not listening then return end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			listening = false
			element.Value = input.KeyCode
			label.Text = input.KeyCode.Name
			Utils.FastTween(pill, { BackgroundColor3 = theme.PanelLight }, 0.12)
			if config.Callback then config.Callback(input.KeyCode) end
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or listening then return end
		if input.KeyCode == element.Value and element.Value ~= Enum.KeyCode.Unknown and config.OnPress then
			config.OnPress()
		end
	end)

	function element:Set(keycode)
		element.Value = keycode
		label.Text = keycode.Name
	end

	self:_registerFlag(flag, element)
	return element
end

function ComponentHost:CreateColorPicker(config, flag)
	config = config or {}
	local theme = xD.Theme
	local color = config.CurrentColor or Color3.fromRGB(255, 255, 255)
	local hue, sat, val = color:ToHSV()

	local row = self:_row(config, 36)
	local swatch = New("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(36, 20),
		BackgroundColor3 = color,
		Text = "",
		AutoButtonColor = false,
		Parent = row,
	}, {
		New("UICorner", { CornerRadius = UDim.new(0, 6) }),
		New("UIStroke", { Color = theme.Border, Transparency = 0.4 }),
	})

	local element = { Value = color }
	local popup

	local function destroyPopup()
		if popup then popup:Destroy() popup = nil end
	end

	local function updateColor(h, s, v)
		hue, sat, val = h, s, v
		color = Color3.fromHSV(hue, sat, val)
		swatch.BackgroundColor3 = color
		element.Value = color
		if config.Callback then config.Callback(color) end
	end

	local function openPopup()
		ClosePopup()
		local absPos = swatch.AbsolutePosition
		local absSize = swatch.AbsoluteSize

		popup = Glass.Panel({
			Name = "ColorPickerPopup",
			Size = UDim2.fromOffset(200, 190),
			Position = UDim2.fromOffset(absPos.X - 200 + absSize.X, absPos.Y + absSize.Y + 6),
			Corner = UDim.new(0, 10),
			Elevation = 4,
			ZIndex = 100,
			Parent = xD.RootGui,
		})

		-- saturation/value box
		local svBox = New("Frame", {
			Position = UDim2.fromOffset(10, 10),
			Size = UDim2.fromOffset(180, 110),
			BackgroundColor3 = Color3.fromHSV(hue, 1, 1),
			ZIndex = 101,
			Parent = popup,
		}, { New("UICorner", { CornerRadius = UDim.new(0, 6) }) })
		New("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1, 1, 1)),
			Transparency = NumberSequence.new(0, 1),
			Parent = svBox,
		})
		local svBlack = New("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 0,
			BackgroundColor3 = Color3.new(0, 0, 0),
			ZIndex = 101,
			Parent = svBox,
		}, { New("UICorner", { CornerRadius = UDim.new(0, 6) }) })
		New("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1, 1, 1)),
			Transparency = NumberSequence.new(1, 0),
			Parent = svBlack,
		})
		-- svBox itself needs a horizontal white->transparent gradient for saturation
		New("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromHSV(hue, 1, 1)),
			Transparency = NumberSequence.new(0, 0),
			Name = "SatGradient",
			Parent = svBox,
		})

		local svCursor = New("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(10, 10),
			Position = UDim2.fromScale(sat, 1 - val),
			BackgroundTransparency = 1,
			ZIndex = 103,
			Parent = svBox,
		}, {
			New("UICorner", { CornerRadius = UDim.new(1, 0) }),
			New("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }),
		})

		local svHitbox = New("TextButton", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 104, Text = "", Parent = svBox })
		local draggingSV = false
		local function setFromSVInput(pos)
			local relX = Utils.Clamp((pos.X - svBox.AbsolutePosition.X) / svBox.AbsoluteSize.X, 0, 1)
			local relY = Utils.Clamp((pos.Y - svBox.AbsolutePosition.Y) / svBox.AbsoluteSize.Y, 0, 1)
			svCursor.Position = UDim2.fromScale(relX, 1 - relY)
			updateColor(hue, relX, 1 - relY)
		end
		svHitbox.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				draggingSV = true
				setFromSVInput(input.Position)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if draggingSV and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				setFromSVInput(input.Position)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				draggingSV = false
			end
		end)

		-- hue slider
		local hueTrack = New("Frame", {
			Position = UDim2.fromOffset(10, 128),
			Size = UDim2.fromOffset(180, 12),
			ZIndex = 101,
			Parent = popup,
		}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		New("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 1, 1)),
				ColorSequenceKeypoint.new(1/6, Color3.fromHSV(1/6, 1, 1)),
				ColorSequenceKeypoint.new(2/6, Color3.fromHSV(2/6, 1, 1)),
				ColorSequenceKeypoint.new(3/6, Color3.fromHSV(3/6, 1, 1)),
				ColorSequenceKeypoint.new(4/6, Color3.fromHSV(4/6, 1, 1)),
				ColorSequenceKeypoint.new(5/6, Color3.fromHSV(5/6, 1, 1)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(1, 1, 1)),
			}),
			Parent = hueTrack,
		})
		local hueCursor = New("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(hue, 0.5),
			Size = UDim2.fromOffset(6, 16),
			BackgroundColor3 = Color3.new(1, 1, 1),
			ZIndex = 103,
			Parent = hueTrack,
		}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		local hueHitbox = New("TextButton", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), Position = UDim2.fromOffset(0, -5), ZIndex = 104, Text = "", Parent = hueTrack })
		local draggingHue = false
		local function setFromHueInput(pos)
			local relX = Utils.Clamp((pos.X - hueTrack.AbsolutePosition.X) / hueTrack.AbsoluteSize.X, 0, 1)
			hueCursor.Position = UDim2.fromScale(relX, 0.5)
			svBox.BackgroundColor3 = Color3.fromHSV(relX, 1, 1)
			svBox.SatGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromHSV(relX, 1, 1))
			updateColor(relX, sat, val)
		end
		hueHitbox.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				draggingHue = true
				setFromHueInput(input.Position)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if draggingHue and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				setFromHueInput(input.Position)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				draggingHue = false
			end
		end)

		-- hex input
		local hexBox = New("Frame", {
			Position = UDim2.fromOffset(10, 150),
			Size = UDim2.fromOffset(180, 26),
			BackgroundColor3 = theme.PanelLight,
			ZIndex = 101,
			Parent = popup,
		}, { New("UICorner", { CornerRadius = UDim.new(0, 6) }) })
		local hexInput = New("TextBox", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(1, -16, 1, 0),
			Font = Enum.Font.Code,
			Text = string.format("#%02X%02X%02X", color.R * 255, color.G * 255, color.B * 255),
			TextSize = 12,
			TextColor3 = theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 101,
			Parent = hexBox,
		})
		hexInput.FocusLost:Connect(function()
			local ok, newColor = pcall(function() return Color3.fromHex(hexInput.Text) end)
			if ok then
				local h, s, v = newColor:ToHSV()
				hue, sat, val = h, s, v
				svBox.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
				svBox.SatGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromHSV(hue, 1, 1))
				hueCursor.Position = UDim2.fromScale(hue, 0.5)
				svCursor.Position = UDim2.fromScale(sat, 1 - val)
				updateColor(hue, sat, val)
			end
		end)

		OpenPopup = destroyPopup
	end

	swatch.MouseButton1Click:Connect(function()
		if popup then destroyPopup(); OpenPopup = nil else openPopup() end
	end)

	function element:Set(newColor)
		local h, s, v = newColor:ToHSV()
		hue, sat, val = h, s, v
		color = newColor
		swatch.BackgroundColor3 = color
		element.Value = color
		if config.Callback then config.Callback(color) end
	end

	self:_registerFlag(flag, element)
	return element
end

-- ============================================================
-- NOTIFICATIONS (stacked toasts, bottom-right, spring in/out + progress bar)
-- ============================================================

local NotificationContainer = New("Frame", {
	Name = "Notifications",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -18, 1, -18),
	Size = UDim2.fromOffset(300, 1),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	ZIndex = 200,
	Parent = RootGui,
})
New("UIListLayout", {
	VerticalAlignment = Enum.VerticalAlignment.Bottom,
	HorizontalAlignment = Enum.HorizontalAlignment.Right,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = NotificationContainer,
})

local NotifTypeKey = {
	Info = "Accent",
	Success = "Success",
	Warning = "Warning",
	Error = "Danger",
}
local NotifIcon = {
	Info = "info",
	Success = "success",
	Warning = "warning",
	Error = "error",
}

function xD:Notify(config)
	config = config or {}
	local theme = self.Theme
	local notifType = config.Type or "Info"
	local accentKey = NotifTypeKey[notifType] or "Accent"
	local accent = theme[accentKey]
	local duration = config.Duration or 4

	local toast = Glass.Panel({
		Name = "Toast",
		Size = UDim2.new(1, 0, 0, 0),
		Corner = UDim.new(0, 10),
		Transparency = 0.05,
		Elevation = 3,
		ZIndex = 200,
		Parent = NotificationContainer,
	})
	toast.AutomaticSize = Enum.AutomaticSize.Y
	toast.Position = UDim2.new(1.4, 0, 0, 0)

	New("Frame", {
		Size = UDim2.new(0, 3, 1, 0),
		BackgroundColor3 = accent,
		BorderSizePixel = 0,
		ZIndex = 201,
		Parent = toast,
	}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local iconHolder = IconKit.Resolve(config.Icon or NotifIcon[notifType], UDim2.fromOffset(16, 16), accent, toast)
	iconHolder.Position = UDim2.fromOffset(14, 12)
	iconHolder.ZIndex = 201

	New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(38, 10),
		Size = UDim2.new(1, -54, 0, 16),
		Font = Enum.Font.GothamBold,
		Text = config.Title or "Notification",
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 201,
		Parent = toast,
	})
	New("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(38, 27),
		Size = UDim2.new(1, -54, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Enum.Font.Gotham,
		Text = config.Content or "",
		TextSize = 12,
		TextWrapped = true,
		TextColor3 = theme.SubText,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 201,
		Parent = toast,
	})

	New("UIPadding", { PaddingBottom = UDim.new(0, 14), Parent = toast })

	local progressTrack = New("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -4),
		Size = UDim2.new(1, -16, 0, 2),
		BackgroundColor3 = theme.Border,
		BackgroundTransparency = 0.4,
		ZIndex = 201,
		Parent = toast,
	}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	local progressFill = New("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = accent,
		ZIndex = 202,
		Parent = progressTrack,
	}, { New("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	Utils.Tween(toast, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0, 0, 0, 0),
	})

	if duration > 0 then
		Utils.Tween(progressFill, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
			Size = UDim2.new(0, 0, 1, 0),
		})
		task.delay(duration, function()
			if toast and toast.Parent then
				Utils.Tween(toast, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
					Position = UDim2.new(1.4, 0, 0, 0),
				})
				task.delay(0.25, function()
					if toast then toast:Destroy() end
				end)
			end
		end)
	end

	local handle = {}
	function handle:Dismiss()
		if toast and toast.Parent then toast:Destroy() end
	end
	return handle
end

-- ============================================================
-- CONFIG SYSTEM (per-element flags, matching the "last constructor arg is
-- the save key" convention so scripts written for that pattern port as-is)
-- ============================================================

local function SerializeValue(value)
	if typeof(value) == "Color3" then
		return { __type = "Color3", R = value.R, G = value.G, B = value.B }
	elseif typeof(value) == "EnumItem" then
		return { __type = "Enum", Enum = tostring(value.EnumType), Name = value.Name }
	else
		return value
	end
end

local function DeserializeValue(value)
	if typeof(value) == "table" and value.__type == "Color3" then
		return Color3.new(value.R, value.G, value.B)
	elseif typeof(value) == "table" and value.__type == "Enum" then
		local enumTable = Enum[value.Enum]
		return enumTable and enumTable[value.Name] or Enum.KeyCode.Unknown
	else
		return value
	end
end

function xD:SetConfigFolder(path)
	self.ConfigFolder = path
end

function xD:SaveConfig(name)
	local ok, err = pcall(function()
		if not fs.isfolder(self.ConfigFolder) then fs.makefolder(self.ConfigFolder) end
		local data = {}
		for flag, element in pairs(self.Flags) do
			if element.Value ~= nil then
				data[flag] = SerializeValue(element.Value)
			end
		end
		fs.writefile(self.ConfigFolder .. "/" .. name .. ".json", HttpService:JSONEncode(data))
	end)
	if not ok then
		warn("[xD] Failed to save config '" .. name .. "': " .. tostring(err))
	end
	return ok
end

function xD:LoadConfig(name)
	local ok, err = pcall(function()
		local path = self.ConfigFolder .. "/" .. name .. ".json"
		if not fs.isfile(path) then return end
		local data = HttpService:JSONDecode(fs.readfile(path))
		for flag, rawValue in pairs(data) do
			local element = self.Flags[flag]
			if element and element.Set then
				element:Set(DeserializeValue(rawValue))
			end
		end
	end)
	if not ok then
		warn("[xD] Failed to load config '" .. name .. "': " .. tostring(err))
	end
	return ok
end

function xD:ListConfigs()
	local names = {}
	pcall(function()
		if fs.isfolder(self.ConfigFolder) then
			for _, file in ipairs(fs.listfiles(self.ConfigFolder)) do
				local name = file:match("([^/\\]+)%.json$")
				if name then table.insert(names, name) end
			end
		end
	end)
	return names
end

function xD:SetAutoloadConfig(name)
	pcall(function()
		if not fs.isfolder(self.ConfigFolder) then fs.makefolder(self.ConfigFolder) end
		fs.writefile(self.ConfigFolder .. "/autoload.txt", name)
	end)
end

function xD:LoadAutoloadConfig()
	pcall(function()
		local path = self.ConfigFolder .. "/autoload.txt"
		if fs.isfile(path) then
			self:LoadConfig(fs.readfile(path))
		end
	end)
end

-- Called from Window:Destroy hooks / script teardown so unsaved state has a
-- chance to persist, mirroring the `OnDestroy` convention.
function xD:OnDestroy(callback)
	self._onDestroy = self._onDestroy or {}
	table.insert(self._onDestroy, callback)
end

game:BindToClose(function()
	if xD._onDestroy then
		for _, cb in ipairs(xD._onDestroy) do
			pcall(cb)
		end
	end
end)

xD.Groupbox = Groupbox
xD.Section = Section
xD.ComponentHost = ComponentHost

-- @@INSERT_BEFORE_RETURN@@

return xD
