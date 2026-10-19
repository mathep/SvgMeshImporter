-- SVG Mesh Importer: builds extruded MeshParts from an SVG file, then uploads them as Mesh assets
-- so they survive saving and publishing.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local StudioService = game:GetService("StudioService")

local SvgDocument = require(script.SvgDocument)
local MeshBuilder = require(script.MeshBuilder)
local MeshEmitter = require(script.MeshEmitter)

-- Curve tolerance as a fraction of the SVG's size.
local QUALITY = { Low = 0.004, Medium = 0.0015, High = 0.0006, Ultra = 0.00025 }
local QUALITY_ORDER = { "Low", "Medium", "High", "Ultra" }
local COLLISION_ORDER = { "Box", "Hull", "Default", "PreciseConvexDecomposition" }

local ASSET_ATTRIBUTE = "SvgMeshAssetId"
local PENDING_ATTRIBUTE = "SvgMeshPendingAssetId"

local DEFAULTS = {
	width = 10,
	thickness = 0.5,
	layerGap = 0.01,
	quality = "Medium",
	collision = "Hull",
	groupId = "",
}

local config = {}
for key, default in DEFAULTS do
	local saved = plugin:GetSetting("SvgMeshImporter_" .. key)
	config[key] = if typeof(saved) == typeof(default) then saved else default
end

if not table.find(QUALITY_ORDER, config.quality) then
	config.quality = DEFAULTS.quality
end
if not table.find(COLLISION_ORDER, config.collision) then
	config.collision = DEFAULTS.collision
end

local function setConfig(key: string, value: any)
	config[key] = value
	plugin:SetSetting("SvgMeshImporter_" .. key, value)
end

local state = {
	source = nil :: string?,
	fileName = "SVG",
	parsed = nil :: any,
	parsedQuality = nil :: number?,
	model = nil :: Model?,
	busy = false,
}

-- EditableMeshes behind preview parts. Kept alive for the session so undo/redo of a preview
-- still has geometry to show; released once a part points at an uploaded asset.
local editableMeshes: { [MeshPart]: EditableMesh } = {}

---------------------------------------------------------------------------------------------------
-- UI: Granny Tower house style (tinted stud tiles, black outer stroke, white bevel inner stroke,
-- Comic Neue Angular Bold with outlined white text).

local FRAME_TEXTURE = "rbxassetid://2953645289"
local FRAME_TILE = UDim2.fromOffset(40, 40)
local FONT = Font.new("rbxasset://fonts/families/ComicNeueAngular.json", Enum.FontWeight.Bold)
local ICON = "rbxassetid://82464155361999"

local TINTS = {
	page = Color3.fromRGB(70, 74, 92),
	card = Color3.fromRGB(90, 170, 255),
	choose = Color3.fromRGB(255, 200, 35),
	rebuild = Color3.fromRGB(190, 120, 255),
	save = Color3.fromRGB(95, 215, 115),
	cycle = Color3.fromRGB(190, 120, 255),
	input = Color3.fromRGB(28, 30, 38),
	info = Color3.fromRGB(90, 170, 255),
	warning = Color3.fromRGB(255, 200, 35),
	error = Color3.fromRGB(255, 75, 75),
	success = Color3.fromRGB(95, 215, 115),
}

local toolbar = plugin:CreateToolbar("SVG Mesh Importer")
local toggleButton = toolbar:CreateButton("SvgMeshImporterToggle", "Import an SVG file as an extruded mesh", ICON, "SVG Import")
toggleButton.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 320, 560, 280, 360)
local widget = plugin:CreateDockWidgetPluginGui("SvgMeshImporter", widgetInfo)
widget.Title = "SVG Mesh Importer"
widget.Name = "SvgMeshImporter"

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)

local function bevelGradient(tint: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, tint:Lerp(Color3.new(0, 0, 0), 0.45)),
		ColorSequenceKeypoint.new(0.455959, tint),
		ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)),
	})
end

-- Turns an ImageLabel/ImageButton into a tinted stud panel. Returns a function that re-tints it.
local function studFrame(frame: ImageLabel | ImageButton, tint: Color3): (Color3) -> ()
	frame.BackgroundTransparency = 1
	frame.Image = FRAME_TEXTURE
	frame.ScaleType = Enum.ScaleType.Tile
	frame.TileSize = FRAME_TILE
	frame.ImageColor3 = tint

	local outer = Instance.new("UIStroke")
	outer.Name = "Outer"
	outer.Thickness = 4
	outer.Color = Color3.new(0, 0, 0)
	outer.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outer.Parent = frame

	local inner = Instance.new("UIStroke")
	inner.Name = "Inner"
	inner.Thickness = 3
	inner.Color = Color3.new(1, 1, 1)
	inner.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	pcall(function()
		inner.BorderStrokePosition = Enum.BorderStrokePosition.Inner
	end)
	inner.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 270
	gradient.Color = bevelGradient(tint)
	gradient.Parent = inner

	return function(newTint: Color3)
		frame.ImageColor3 = newTint
		gradient.Color = bevelGradient(newTint)
	end
end

local function makeText(parent: Instance, text: string, size: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.FontFace = FONT
	label.TextSize = size or 16
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	label.Parent = parent
	return label
end

local function makeList(parent: Instance, gap: number, pad: number)
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, gap)
	list.Parent = parent
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, pad)
	padding.PaddingBottom = UDim.new(0, pad)
	padding.PaddingLeft = UDim.new(0, pad)
	padding.PaddingRight = UDim.new(0, pad)
	padding.Parent = parent
end

local nextOrder = 0
local function order(): number
	nextOrder += 1
	return nextOrder
end

local function makeButton(parent: Instance, text: string, tint: Color3, height: number?): (ImageButton, TextLabel)
	local button = Instance.new("ImageButton")
	button.AutoButtonColor = false
	button.Size = UDim2.new(1, 0, 0, height or 38)
	button.LayoutOrder = order()
	local setTint = studFrame(button, tint)
	local label = makeText(button, text, 18)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	button.MouseEnter:Connect(function()
		setTint(tint:Lerp(Color3.new(1, 1, 1), 0.15))
	end)
	button.MouseLeave:Connect(function()
		setTint(tint)
	end)
	button.MouseButton1Down:Connect(function()
		setTint(tint:Lerp(Color3.new(0, 0, 0), 0.2))
	end)
	button.MouseButton1Up:Connect(function()
		setTint(tint:Lerp(Color3.new(1, 1, 1), 0.15))
	end)
	button.Parent = parent
	return button, label
end

local function makeCard(parent: Instance, tint: Color3): (ImageLabel, (Color3) -> ())
	local card = Instance.new("ImageLabel")
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.LayoutOrder = order()
	local setTint = studFrame(card, tint)
	makeList(card, 8, 12)
	card.Parent = parent
	return card, setTint
end

-- Page: a dark stud backdrop behind a transparent scrolling column.
local backdrop = Instance.new("ImageLabel")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = TINTS.page
backdrop.Image = FRAME_TEXTURE
backdrop.ScaleType = Enum.ScaleType.Tile
backdrop.TileSize = FRAME_TILE
backdrop.ImageColor3 = TINTS.page
backdrop.BorderSizePixel = 0
backdrop.Parent = widget

local root = Instance.new("ScrollingFrame")
root.Size = UDim2.fromScale(1, 1)
root.BackgroundTransparency = 1
root.BorderSizePixel = 0
root.ScrollBarThickness = 6
root.ScrollBarImageColor3 = Color3.new(0, 0, 0)
root.CanvasSize = UDim2.new()
root.AutomaticCanvasSize = Enum.AutomaticSize.Y
root.ScrollingDirection = Enum.ScrollingDirection.Y
root.Parent = backdrop
makeList(root, 12, 14)

local onSettingsChanged: () -> ()

local function makeRow(parent: Instance, labelText: string): Frame
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 30)
	row.LayoutOrder = order()
	local label = makeText(row, labelText)
	label.Size = UDim2.new(0.55, -6, 1, 0)
	row.Parent = parent
	return row
end

local function makeInput(row: Frame): TextBox
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0.45, 0, 1, 0)
	box.Position = UDim2.fromScale(0.55, 0)
	box.BackgroundColor3 = TINTS.input
	box.ClearTextOnFocus = false
	box.FontFace = FONT
	box.TextSize = 16
	box.TextColor3 = Color3.new(1, 1, 1)
	box.PlaceholderColor3 = Color3.fromRGB(140, 145, 160)
	box.TextXAlignment = Enum.TextXAlignment.Left
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = box
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = box
	local inner = Instance.new("UIPadding")
	inner.PaddingLeft = UDim.new(0, 8)
	inner.Parent = box
	box.Parent = row
	return box
end

local function numberSetting(parent: Instance, labelText: string, key: string, min: number, max: number)
	local box = makeInput(makeRow(parent, labelText))
	box.Text = tostring(config[key])
	box.FocusLost:Connect(function()
		local value = tonumber(box.Text)
		if value and value == value then
			value = math.clamp(value, min, max)
			if value ~= config[key] then
				setConfig(key, value)
				onSettingsChanged()
			end
		end
		box.Text = tostring(config[key])
	end)
end

local function cycleSetting(parent: Instance, labelText: string, key: string, options: { string }, rebuild: boolean)
	local row = makeRow(parent, labelText)
	local button, label = makeButton(row, config[key], TINTS.cycle, 30)
	button.Size = UDim2.new(0.45, 0, 1, 0)
	button.Position = UDim2.fromScale(0.55, 0)
	label.TextSize = 16
	button.Activated:Connect(function()
		local index = table.find(options, config[key]) or 0
		setConfig(key, options[index % #options + 1])
		label.Text = config[key]
		if rebuild then
			onSettingsChanged()
		end
	end)
end

-- File
local chooseButton = makeButton(root, "Choose SVG file…", TINTS.choose, 42)

local fileLabel = makeText(root, "No file chosen", 15)
fileLabel.Size = UDim2.new(1, 0, 0, 18)
fileLabel.TextTruncate = Enum.TextTruncate.AtEnd
fileLabel.LayoutOrder = order()

-- Settings
local settingsCard = makeCard(root, TINTS.card)
local settingsHeader = makeText(settingsCard, "Settings", 20)
settingsHeader.Size = UDim2.new(1, 0, 0, 24)
settingsHeader.LayoutOrder = order()
numberSetting(settingsCard, "Width (studs)", "width", 0.05, 2048)
numberSetting(settingsCard, "Thickness (studs)", "thickness", 0, 512)
numberSetting(settingsCard, "Layer gap (studs)", "layerGap", 0, 10)
cycleSetting(settingsCard, "Curve quality", "quality", QUALITY_ORDER, true)
cycleSetting(settingsCard, "Collision", "collision", COLLISION_ORDER, false)

local groupBox = makeInput(makeRow(settingsCard, "Upload to group ID"))
groupBox.PlaceholderText = "optional"
groupBox.Text = config.groupId
groupBox.FocusLost:Connect(function()
	local digits = groupBox.Text:match("^%s*(%d+)%s*$") or ""
	setConfig("groupId", digits)
	groupBox.Text = digits
end)

-- Actions
local rebuildButton = makeButton(root, "Rebuild preview", TINTS.rebuild)
local saveButton = makeButton(root, "Save as mesh assets", TINTS.save, 42)

-- Status
local statusCard, setStatusTint = makeCard(root, TINTS.info)
local status = makeText(statusCard, "", 15)
status.Size = UDim2.new(1, 0, 0, 0)
status.AutomaticSize = Enum.AutomaticSize.Y
status.TextYAlignment = Enum.TextYAlignment.Top

local function setStatus(text: string, kind: string?)
	status.Text = text
	setStatusTint(TINTS[kind or "info"] or TINTS.info)
end

setStatus("Choose an SVG to get started. Filled shapes become parts, one per fill color.")

---------------------------------------------------------------------------------------------------
-- Actions

local function collisionFidelity(): Enum.CollisionFidelity
	return Enum.CollisionFidelity[config.collision]
end

local function isUploaded(part: Instance): boolean
	return part:GetAttribute(ASSET_ATTRIBUTE) ~= nil
end

local function hasPreviewParts(model: Instance): boolean
	for _, d in model:GetDescendants() do
		if d:IsA("MeshPart") and editableMeshes[d] and not isUploaded(d) then
			return true
		end
	end
	return false
end

-- A preview nothing has been uploaded from yet, which is safe to throw away and rebuild.
local function isFreshPreview(model: Instance?): boolean
	if not model or not model.Parent then
		return false
	end
	local any = false
	for _, d in model:GetDescendants() do
		if d:IsA("MeshPart") then
			if isUploaded(d) or d:GetAttribute(PENDING_ATTRIBUTE) or not editableMeshes[d] then
				return false
			end
			any = true
		end
	end
	return any
end

-- In front of the camera, facing it, so the SVG reads correctly.
local function placementCFrame(width: number): CFrame
	local camera = workspace.CurrentCamera
	local look = camera.CFrame.LookVector
	local position = camera.CFrame.Position + look * (width * 1.2 + 4)
	local flat = Vector3.new(look.X, 0, look.Z)
	local toCamera = if flat.Magnitude > 1e-3 then -flat.Unit else Vector3.new(0, 0, 1)
	return CFrame.lookAt(position, position + toCamera)
end

local function formatNumber(n: number): string
	return tostring(math.round(n * 100) / 100)
end

local function rebuild()
	if state.busy then
		return
	end
	if not state.source then
		setStatus("Choose an SVG file first.", "warning")
		return
	end
	state.busy = true
	setStatus("Building…")

	local ok, err = pcall(function()
		local quality = QUALITY[config.quality] or QUALITY.Medium
		if not state.parsed or state.parsedQuality ~= quality then
			state.parsed = SvgDocument.load(state.source :: string, quality)
			state.parsedQuality = quality
		end
		local built = MeshBuilder.build(state.parsed.shapes, {
			width = config.width,
			thickness = config.thickness,
			layerGap = config.layerGap,
		})

		local model = Instance.new("Model")
		model.Name = "SVG_" .. state.fileName
		for index, data in built.meshes do
			setStatus(("Building part %d of %d…"):format(index, #built.meshes))
			local mesh = MeshEmitter.createEditableMesh(data)
			local part = MeshEmitter.createPart(data, mesh, collisionFidelity())
			part.CFrame = CFrame.new(data.center[1], data.center[2], data.center[3])
			part.Parent = model
			editableMeshes[part] = mesh
			task.wait()
		end
		model.WorldPivot = CFrame.identity

		-- Replace the previous preview in place unless it has already been saved.
		local old = state.model
		local pivot
		if isFreshPreview(old) then
			pivot = old:GetPivot()
		else
			pivot = placementCFrame(config.width)
			old = nil
		end
		model:PivotTo(pivot)

		local recording = ChangeHistoryService:TryBeginRecording("Import SVG")
		if old then
			old.Parent = nil
		end
		model.Parent = workspace
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		state.model = model
		Selection:Set({ model })

		local lines = {
			("Preview built: %d part(s), %d triangles, %s × %s studs."):format(
				#built.meshes,
				built.triangles,
				formatNumber(built.width),
				formatNumber(built.height)
			),
			"This preview isn't saved with the place yet. Click Save as mesh assets to make it permanent.",
		}
		local warnings = table.clone(state.parsed.warnings)
		table.move(built.warnings, 1, #built.warnings, #warnings + 1, warnings)
		for _, w in warnings do
			table.insert(lines, "• " .. w)
		end
		setStatus(table.concat(lines, "\n"), if #warnings > 0 then "warning" else nil)
	end)

	state.busy = false
	if not ok then
		setStatus("Couldn't build the mesh: " .. tostring(err), "error")
	end
end

onSettingsChanged = function()
	-- Only live-update while the current preview is unsaved; never touch uploaded parts.
	if state.source and isFreshPreview(state.model) then
		rebuild()
	end
end

local function chooseFile()
	if state.busy then
		return
	end
	local ok, file = pcall(function()
		return StudioService:PromptImportFileAsync({ "svg" })
	end)
	if not ok then
		setStatus("Couldn't open the file: " .. tostring(file), "error")
		return
	end
	if not file then
		return
	end
	state.source = file:GetBinaryContents()
	state.fileName = (file.Name:gsub("%.[sS][vV][gG]$", ""))
	state.parsed = nil
	state.model = nil -- keep any earlier import in the scene; this file gets a new model
	fileLabel.Text = file.Name
	rebuild()
end

local function saveAssets()
	if state.busy then
		return
	end
	-- Save the selected SVG model if it has unsaved parts, otherwise the latest preview.
	local target: Instance? = nil
	for _, selected in Selection:Get() do
		local model = if selected:IsA("Model") then selected else selected:FindFirstAncestorOfClass("Model")
		if model and hasPreviewParts(model) then
			target = model
			break
		end
	end
	if not target and state.model and state.model.Parent and hasPreviewParts(state.model) then
		target = state.model
	end
	if not target then
		setStatus("Nothing to save. Build a preview first (or select an unsaved SVG model).", "warning")
		return
	end

	local parts = {}
	for _, d in (target :: Instance):GetDescendants() do
		if d:IsA("MeshPart") and editableMeshes[d] and not isUploaded(d) then
			table.insert(parts, d)
		end
	end
	table.sort(parts, function(a, b)
		return a.Name < b.Name
	end)

	state.busy = true
	local groupId = tonumber(config.groupId)
	local saved, failures = 0, {}
	local recording = ChangeHistoryService:TryBeginRecording("Save SVG meshes")
	for index, part in parts do
		setStatus(("Uploading mesh %d of %d…"):format(index, #parts))
		local assetId = part:GetAttribute(PENDING_ATTRIBUTE)
		if not assetId then
			local assetName = ((target :: Instance).Name .. "_" .. part.Name):sub(1, 50)
			local id, err = MeshEmitter.upload(editableMeshes[part], assetName, groupId)
			if not id then
				table.insert(failures, part.Name .. ": " .. tostring(err))
				continue
			end
			assetId = id
			part:SetAttribute(PENDING_ATTRIBUTE, id)
		end
		setStatus(("Applying mesh %d of %d (asset %d)…"):format(index, #parts, assetId))
		local applied, err = MeshEmitter.applyAsset(part, assetId, collisionFidelity())
		if applied then
			part:SetAttribute(ASSET_ATTRIBUTE, assetId)
			part:SetAttribute(PENDING_ATTRIBUTE, nil)
			editableMeshes[part] = nil
			saved += 1
		else
			table.insert(failures, ("%s: uploaded as %d but couldn't load it yet (%s)"):format(part.Name, assetId, tostring(err)))
		end
	end
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	state.busy = false

	if #failures == 0 then
		setStatus(("Saved %d mesh asset(s). The model now uses uploaded meshes and will save with the place."):format(saved), "success")
	else
		setStatus(
			("Saved %d of %d. Click Save again to retry the rest:\n• %s"):format(saved, #parts, table.concat(failures, "\n• ")),
			"error"
		)
	end
end

chooseButton.Activated:Connect(chooseFile)
rebuildButton.Activated:Connect(rebuild)
saveButton.Activated:Connect(saveAssets)
