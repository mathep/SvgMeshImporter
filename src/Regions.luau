-- Applies an SVG fill rule to a shape's outlines, producing polygons with holes.
-- Assumes outlines do not cross each other (true for nearly all exported artwork).

local Regions = {}

export type Ring = { { number } }
export type Polygon = { outer: Ring, holes: { Ring } }

function Regions.signedArea(ring: Ring): number
	local sum = 0
	local n = #ring
	for k = 1, n do
		local p, q = ring[k], ring[k % n + 1]
		sum += p[1] * q[2] - q[1] * p[2]
	end
	return sum / 2
end

local function pointInRing(x: number, y: number, ring: Ring): boolean
	local inside = false
	local n = #ring
	local j = n
	for k = 1, n do
		local xi, yi = ring[k][1], ring[k][2]
		local xj, yj = ring[j][1], ring[j][2]
		if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then
			inside = not inside
		end
		j = k
	end
	return inside
end

-- Majority vote over a few sample vertices, so a vertex that touches the other ring can't flip the answer.
local function ringInside(inner: Ring, outer: Ring): boolean
	local n = #inner
	local stride = math.max(1, n // 5)
	local votes, total = 0, 0
	for k = 1, n, stride do
		total += 1
		if pointInRing(inner[k][1], inner[k][2], outer) then
			votes += 1
		end
		if total >= 5 then
			break
		end
	end
	return votes * 2 > total
end

local function bounds(ring: Ring): { number }
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ring do
		minX, maxX = math.min(minX, p[1]), math.max(maxX, p[1])
		minY, maxY = math.min(minY, p[2]), math.max(maxY, p[2])
	end
	return { minX, minY, maxX, maxY }
end

function Regions.resolve(rings: { Ring }, fillRule: string): { Polygon }
	local info = {}
	for k, ring in rings do
		info[k] = { ring = ring, area = Regions.signedArea(ring), box = bounds(ring), containers = {} }
	end

	for k, a in info do
		for j, b in info do
			if j ~= k
				and math.abs(b.area) > math.abs(a.area)
				and a.box[1] >= b.box[1] and a.box[2] >= b.box[2] and a.box[3] <= b.box[3] and a.box[4] <= b.box[4]
				and ringInside(a.ring, b.ring)
			then
				table.insert(a.containers, j)
			end
		end
	end

	local outers, holes = {}, {}
	for k, a in info do
		local filledOutside, filledInside
		if fillRule == "evenodd" then
			local depth = #a.containers
			filledOutside = depth % 2 == 1
			filledInside = (depth + 1) % 2 == 1
		else
			local winding = 0
			for _, j in a.containers do
				winding += if info[j].area > 0 then 1 else -1
			end
			filledOutside = winding ~= 0
			filledInside = winding + (if a.area > 0 then 1 else -1) ~= 0
		end
		if filledInside and not filledOutside then
			table.insert(outers, k)
		elseif filledOutside and not filledInside then
			table.insert(holes, k)
		end
	end

	local polygons: { Polygon } = {}
	local byOuter = {}
	for _, k in outers do
		local polygon = { outer = info[k].ring, holes = {} }
		byOuter[k] = polygon
		table.insert(polygons, polygon)
	end
	for _, h in holes do
		-- A hole belongs to the smallest filled outline around it.
		local best, bestArea = nil, math.huge
		for _, j in info[h].containers do
			if byOuter[j] and math.abs(info[j].area) < bestArea then
				best, bestArea = j, math.abs(info[j].area)
			end
		end
		if best then
			table.insert(byOuter[best].holes, info[h].ring)
		end
	end
	return polygons
end

return Regions
