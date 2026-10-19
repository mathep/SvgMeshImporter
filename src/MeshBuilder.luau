-- Turns parsed SVG shapes into extruded triangle meshes (plain tables, no Roblox types),
-- grouped by fill color and split to stay under Roblox's per-mesh limits.
--
-- Model space: the SVG is centered on the origin, readable from the -Z side (the part's Front),
-- with SVG +x going toward the viewer's right and SVG +y going down.

local Earcut = if script then require(script.Parent.Earcut) else require("./Earcut")
local Regions = if script then require(script.Parent.Regions) else require("./Regions")

local MeshBuilder = {}

export type MeshData = {
	name: string,
	color: { number },
	transparency: number,
	positions: { { number } },
	tris: { { number } },
	center: { number },
	size: { number },
}

export type Options = {
	width: number, -- studs across the widest SVG dimension
	thickness: number, -- extrusion depth in studs; 0 gives a flat double-sided plate
	layerGap: number, -- extra depth per stacked layer, so overlapping shapes don't z-fight
	smoothAngle: number?, -- side walls stay smooth across corners sharper than this (degrees)
	maxTriangles: number?,
	maxVertices: number?,
}

export type Result = {
	meshes: { MeshData },
	warnings: { string },
	triangles: number,
	vertices: number,
	width: number,
	height: number,
}

local function reversed(ring: Regions.Ring): Regions.Ring
	local out = table.create(#ring)
	for k = #ring, 1, -1 do
		table.insert(out, ring[k])
	end
	return out
end

local function cleanRing(points: Regions.Ring, eps: number): Regions.Ring
	local out = {}
	for _, p in points do
		local last = out[#out]
		if not last or math.abs(last[1] - p[1]) > eps or math.abs(last[2] - p[2]) > eps then
			table.insert(out, p)
		end
	end
	while #out > 1 and math.abs(out[1][1] - out[#out][1]) <= eps and math.abs(out[1][2] - out[#out][2]) <= eps do
		table.remove(out)
	end
	return out
end

local function ringBounds(ring: Regions.Ring, box: { number })
	for _, p in ring do
		box[1] = math.min(box[1], p[1])
		box[2] = math.min(box[2], p[2])
		box[3] = math.max(box[3], p[1])
		box[4] = math.max(box[4], p[2])
	end
end

type Fragment = { positions: { { number } }, tris: { { number } } }

local function buildFragment(polygon: Regions.Polygon, zFront: number, zBack: number, smoothCos: number): Fragment
	local positions, tris = {}, {}

	local function vertex(x: number, y: number, z: number): number
		table.insert(positions, { x, y, z })
		return #positions
	end

	-- Adds a triangle wound so its face normal agrees with (nx, ny, nz).
	local function triangle(a: number, b: number, c: number, nx: number, ny: number, nz: number)
		local pa, pb, pc = positions[a], positions[b], positions[c]
		local ux, uy, uz = pb[1] - pa[1], pb[2] - pa[2], pb[3] - pa[3]
		local wx, wy, wz = pc[1] - pa[1], pc[2] - pa[2], pc[3] - pa[3]
		local cx = uy * wz - uz * wy
		local cy = uz * wx - ux * wz
		local cz = ux * wy - uy * wx
		if cx * nx + cy * ny + cz * nz < 0 then
			b, c = c, b
		end
		table.insert(tris, { a, b, c })
	end

	-- Outer outline counter-clockwise, holes clockwise: material is always on the left.
	local outer = if Regions.signedArea(polygon.outer) > 0 then polygon.outer else reversed(polygon.outer)
	local rings = { outer }
	for _, hole in polygon.holes do
		table.insert(rings, if Regions.signedArea(hole) < 0 then hole else reversed(hole))
	end

	-- Front and back caps.
	local xs, ys, holeStarts = {}, {}, {}
	for k, ring in rings do
		if k > 1 then
			table.insert(holeStarts, #xs + 1)
		end
		for _, p in ring do
			table.insert(xs, p[1])
			table.insert(ys, p[2])
		end
	end
	local capTris = Earcut.triangulate(xs, ys, holeStarts)
	if #capTris == 0 then
		return { positions = positions, tris = tris }
	end
	local front, back = {}, {}
	for k = 1, #xs do
		front[k] = vertex(xs[k], ys[k], zFront)
		back[k] = vertex(xs[k], ys[k], zBack)
	end
	for t = 1, #capTris, 3 do
		local a, b, c = capTris[t], capTris[t + 1], capTris[t + 2]
		triangle(front[a], front[b], front[c], 0, 0, -1)
		triangle(back[a], back[b], back[c], 0, 0, 1)
	end

	if zBack - zFront <= 1e-6 then
		return { positions = positions, tris = tris }
	end

	-- Side walls. Corners gentler than smoothAngle share vertices so curves shade smoothly;
	-- sharper corners get their own vertices for a crisp edge.
	for _, ring in rings do
		local n = #ring
		local startF, startB, endF, endB = {}, {}, {}, {}
		for k = 1, n do
			local p0, p1, p2 = ring[(k - 2) % n + 1], ring[k], ring[k % n + 1]
			local ax, ay = p1[1] - p0[1], p1[2] - p0[2]
			local bx, by = p2[1] - p1[1], p2[2] - p1[2]
			local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
			local smooth = la > 0 and lb > 0 and (ax * bx + ay * by) / (la * lb) >= smoothCos
			local x, y = p1[1], p1[2]
			startF[k], startB[k] = vertex(x, y, zFront), vertex(x, y, zBack)
			if smooth then
				endF[k], endB[k] = startF[k], startB[k]
			else
				endF[k], endB[k] = vertex(x, y, zFront), vertex(x, y, zBack)
			end
		end
		for k = 1, n do
			local k2 = k % n + 1
			local p, q = ring[k], ring[k2]
			local nx, ny = q[2] - p[2], -(q[1] - p[1]) -- right of the edge = outside the material
			triangle(startF[k], endF[k2], endB[k2], nx, ny, 0)
			triangle(startF[k], endB[k2], startB[k], nx, ny, 0)
		end
	end

	return { positions = positions, tris = tris }
end

function MeshBuilder.build(shapes: { any }, options: Options): Result
	local maxTris = options.maxTriangles or 20000
	local maxVerts = options.maxVertices or 60000
	local smoothCos = math.cos(math.rad(options.smoothAngle or 30))
	local thickness = math.max(0, options.thickness)
	local gap = math.max(0, options.layerGap)
	local warnings = {}

	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, shape in shapes do
		for _, ring in shape.rings do
			for _, p in ring do
				minX, maxX = math.min(minX, p[1]), math.max(maxX, p[1])
				minY, maxY = math.min(minY, p[2]), math.max(maxY, p[2])
			end
		end
	end
	if minX > maxX then
		error("No filled shapes were found in this SVG.", 0)
	end
	local extent = if maxX > minX then maxX - minX else maxY - minY
	if extent <= 0 then
		error("The SVG's shapes have no area.", 0)
	end
	local scale = options.width / extent
	local midX, midY = (minX + maxX) / 2, (minY + maxY) / 2
	local eps = 1e-6 * options.width

	-- Convert to model space and resolve fill rules.
	local prepared = {}
	for _, shape in shapes do
		local rings = {}
		for _, ring in shape.rings do
			local converted = table.create(#ring)
			for k, p in ring do
				converted[k] = { -(p[1] - midX) * scale, -(p[2] - midY) * scale }
			end
			converted = cleanRing(converted, eps)
			if #converted >= 3 and math.abs(Regions.signedArea(converted)) > eps * eps then
				table.insert(rings, converted)
			end
		end
		if #rings > 0 then
			local polygons = Regions.resolve(rings, shape.fillRule)
			if #polygons > 0 then
				local box = { math.huge, math.huge, -math.huge, -math.huge }
				for _, polygon in polygons do
					ringBounds(polygon.outer, box)
				end
				table.insert(prepared, { shape = shape, polygons = polygons, box = box, layer = 0 })
			end
		end
	end

	-- Shapes drawn on top of earlier overlapping shapes sit one layer further out.
	for i, a in prepared do
		for j = 1, i - 1 do
			local b = prepared[j]
			if a.box[1] < b.box[3] and b.box[1] < a.box[3] and a.box[2] < b.box[4] and b.box[2] < a.box[4] then
				a.layer = math.max(a.layer, b.layer + 1)
			end
		end
	end

	local groups, groupOrder = {}, {}
	local skipped = 0
	for _, item in prepared do
		local shape = item.shape
		local r, g, b = shape.color[1], shape.color[2], shape.color[3]
		local hex = string.format("%02X%02X%02X", math.round(r * 255), math.round(g * 255), math.round(b * 255))
		local key = hex .. "_" .. math.round(shape.alpha * 100)
		local group = groups[key]
		if not group then
			group = { hex = hex, color = { r, g, b }, transparency = 1 - shape.alpha, chunks = {} }
			groups[key] = group
			table.insert(groupOrder, group)
		end

		local zFront = -(thickness / 2 + item.layer * gap)
		local zBack = thickness / 2 + item.layer * gap
		for _, polygon in item.polygons do
			local fragment = buildFragment(polygon, zFront, zBack, smoothCos)
			if #fragment.tris == 0 then
				continue
			end
			if #fragment.tris > maxTris or #fragment.positions > maxVerts then
				skipped += 1
				continue
			end
			local chunk = group.chunks[#group.chunks]
			if not chunk or #chunk.tris + #fragment.tris > maxTris or #chunk.positions + #fragment.positions > maxVerts then
				chunk = { positions = {}, tris = {} }
				table.insert(group.chunks, chunk)
			end
			local base = #chunk.positions
			for _, p in fragment.positions do
				table.insert(chunk.positions, p)
			end
			for _, t in fragment.tris do
				table.insert(chunk.tris, { t[1] + base, t[2] + base, t[3] + base })
			end
		end
	end
	if skipped > 0 then
		table.insert(warnings, ("%d shape(s) needed more than %d triangles on their own and were skipped. Lower Curve quality or simplify them."):format(skipped, maxTris))
	end

	-- Center each chunk on its own bounding box; the part gets placed at that center.
	local meshes: { MeshData } = {}
	local totalTris, totalVerts = 0, 0
	for _, group in groupOrder do
		for index, chunk in group.chunks do
			local lo = { math.huge, math.huge, math.huge }
			local hi = { -math.huge, -math.huge, -math.huge }
			for _, p in chunk.positions do
				for axis = 1, 3 do
					lo[axis] = math.min(lo[axis], p[axis])
					hi[axis] = math.max(hi[axis], p[axis])
				end
			end
			local center = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2 }
			local positions = table.create(#chunk.positions)
			for k, p in chunk.positions do
				positions[k] = { p[1] - center[1], p[2] - center[2], p[3] - center[3] }
			end
			table.insert(meshes, {
				name = "Fill_" .. group.hex .. (if #group.chunks > 1 then "_" .. index else ""),
				color = group.color,
				transparency = group.transparency,
				positions = positions,
				tris = chunk.tris,
				center = center,
				size = { hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3] },
			})
			totalTris += #chunk.tris
			totalVerts += #chunk.positions
		end
	end
	if #meshes == 0 then
		error("No filled shapes were found in this SVG.", 0)
	end

	return {
		meshes = meshes,
		warnings = warnings,
		triangles = totalTris,
		vertices = totalVerts,
		width = (maxX - minX) * scale,
		height = (maxY - minY) * scale,
	}
end

return MeshBuilder
