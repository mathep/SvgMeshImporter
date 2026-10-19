-- Roblox side: MeshData -> EditableMesh -> MeshPart, and uploading EditableMeshes as Mesh assets.

local AssetService = game:GetService("AssetService")

local MeshEmitter = {}

local YIELD_EVERY = 4000

function MeshEmitter.createEditableMesh(data): EditableMesh
	local mesh = AssetService:CreateEditableMesh()
	if not mesh then
		error("Roblox ran out of EditableMesh memory.", 0)
	end
	local ids = table.create(#data.positions)
	for i, p in data.positions do
		ids[i] = mesh:AddVertex(Vector3.new(p[1], p[2], p[3]))
		if i % YIELD_EVERY == 0 then
			task.wait()
		end
	end
	for i, t in data.tris do
		mesh:AddTriangle(ids[t[1]], ids[t[2]], ids[t[3]])
		if i % YIELD_EVERY == 0 then
			task.wait()
		end
	end
	return mesh
end

function MeshEmitter.createPart(data, mesh: EditableMesh, collision: Enum.CollisionFidelity): MeshPart
	local part = AssetService:CreateMeshPartAsync(Content.fromObject(mesh), { CollisionFidelity = collision })
	part.Name = data.name
	part.Color = Color3.new(data.color[1], data.color[2], data.color[3])
	part.Transparency = data.transparency
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	return part
end

-- Uploads to the Studio user's account (or a group). Returns the new asset id, or nil and an error.
function MeshEmitter.upload(mesh: EditableMesh, name: string, groupId: number?): (number?, string?)
	local params: { [string]: any } = {
		Name = name,
		Description = "Imported from SVG with SVG Mesh Importer",
	}
	if groupId then
		params.CreatorType = Enum.AssetCreatorType.Group
		params.CreatorId = groupId
	end
	local ok, result, idOrError = pcall(function()
		return AssetService:CreateAssetAsync(mesh, Enum.AssetType.Mesh, params)
	end)
	if not ok then
		return nil, tostring(result)
	end
	if result ~= Enum.CreateAssetResult.Success then
		return nil, tostring(result) .. (if idOrError then ": " .. tostring(idOrError) else "")
	end
	return tonumber(idOrError), nil
end

-- Points an existing part at an uploaded mesh asset. New uploads can take a moment to become
-- loadable, so retry with backoff.
function MeshEmitter.applyAsset(part: MeshPart, assetId: number, collision: Enum.CollisionFidelity): (boolean, string?)
	local lastError
	for attempt = 1, 8 do
		local ok, result = pcall(function()
			return AssetService:CreateMeshPartAsync(Content.fromAssetId(assetId), { CollisionFidelity = collision })
		end)
		if ok then
			part:ApplyMesh(result)
			result:Destroy()
			return true, nil
		end
		lastError = tostring(result)
		task.wait(math.min(2 * attempt, 8))
	end
	return false, lastError
end

return MeshEmitter
