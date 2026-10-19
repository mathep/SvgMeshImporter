-- Polygon triangulation with holes: a Luau port of Mapbox's earcut algorithm (ISC license,
-- https://github.com/mapbox/earcut). Vertices are 1-based indices into xs/ys.

local Earcut = {}

type Node = {
	i: number,
	x: number,
	y: number,
	prev: Node,
	next: Node,
	z: number,
	prevZ: Node?,
	nextZ: Node?,
	steiner: boolean,
}

local function newNode(i: number, x: number, y: number): Node
	return { i = i, x = x, y = y, prev = nil :: any, next = nil :: any, z = 0, prevZ = nil, nextZ = nil, steiner = false }
end

local function insertNode(i: number, x: number, y: number, last: Node?): Node
	local p = newNode(i, x, y)
	if not last then
		p.prev = p
		p.next = p
	else
		p.next = last.next
		p.prev = last
		last.next.prev = p
		last.next = p
	end
	return p
end

local function removeNode(p: Node)
	p.next.prev = p.prev
	p.prev.next = p.next
	if p.prevZ then
		(p.prevZ :: Node).nextZ = p.nextZ
	end
	if p.nextZ then
		(p.nextZ :: Node).prevZ = p.prevZ
	end
end

local function area(p: Node, q: Node, r: Node): number
	return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
end

local function equals(a: Node, b: Node): boolean
	return a.x == b.x and a.y == b.y
end

local function sign(n: number): number
	return if n > 0 then 1 elseif n < 0 then -1 else 0
end

local function onSegment(p: Node, q: Node, r: Node): boolean
	return q.x <= math.max(p.x, r.x) and q.x >= math.min(p.x, r.x) and q.y <= math.max(p.y, r.y) and q.y >= math.min(p.y, r.y)
end

local function intersects(p1: Node, q1: Node, p2: Node, q2: Node): boolean
	local o1 = sign(area(p1, q1, p2))
	local o2 = sign(area(p1, q1, q2))
	local o3 = sign(area(p2, q2, p1))
	local o4 = sign(area(p2, q2, q1))
	if o1 ~= o2 and o3 ~= o4 then
		return true
	end
	if o1 == 0 and onSegment(p1, p2, q1) then
		return true
	end
	if o2 == 0 and onSegment(p1, q2, q1) then
		return true
	end
	if o3 == 0 and onSegment(p2, p1, q2) then
		return true
	end
	if o4 == 0 and onSegment(p2, q1, q2) then
		return true
	end
	return false
end

local function pointInTriangle(ax: number, ay: number, bx: number, by: number, cx: number, cy: number, px: number, py: number): boolean
	return (cx - px) * (ay - py) >= (ax - px) * (cy - py)
		and (ax - px) * (by - py) >= (bx - px) * (ay - py)
		and (bx - px) * (cy - py) >= (cx - px) * (by - py)
end

local function intersectsPolygon(a: Node, b: Node): boolean
	local p = a
	repeat
		if p.i ~= a.i and p.next.i ~= a.i and p.i ~= b.i and p.next.i ~= b.i and intersects(p, p.next, a, b) then
			return true
		end
		p = p.next
	until p == a
	return false
end

local function locallyInside(a: Node, b: Node): boolean
	if area(a.prev, a, a.next) < 0 then
		return area(a, b, a.next) >= 0 and area(a, a.prev, b) >= 0
	end
	return area(a, b, a.prev) < 0 or area(a, a.next, b) < 0
end

local function middleInside(a: Node, b: Node): boolean
	local p = a
	local inside = false
	local px, py = (a.x + b.x) / 2, (a.y + b.y) / 2
	repeat
		if ((p.y > py) ~= (p.next.y > py)) and p.next.y ~= p.y and (px < (p.next.x - p.x) * (py - p.y) / (p.next.y - p.y) + p.x) then
			inside = not inside
		end
		p = p.next
	until p == a
	return inside
end

local function isValidDiagonal(a: Node, b: Node): boolean
	return a.next.i ~= b.i
		and a.prev.i ~= b.i
		and not intersectsPolygon(a, b)
		and (
			(locallyInside(a, b) and locallyInside(b, a) and middleInside(a, b) and (area(a.prev, a, b.prev) ~= 0 or area(a, b.prev, b) ~= 0))
			or (equals(a, b) and area(a.prev, a, a.next) > 0 and area(b.prev, b, b.next) > 0)
		)
end

-- Links a with b by splitting the ring in two; returns the new node on b's side.
local function splitPolygon(a: Node, b: Node): Node
	local a2 = newNode(a.i, a.x, a.y)
	local b2 = newNode(b.i, b.x, b.y)
	local an = a.next
	local bp = b.prev
	a.next = b
	b.prev = a
	a2.next = an
	an.prev = a2
	b2.next = a2
	a2.prev = b2
	bp.next = b2
	b2.prev = bp
	return b2
end

local function signedArea(xs: { number }, ys: { number }, s: number, e: number): number
	local sum = 0
	local j = e
	for i = s, e do
		sum += (xs[j] - xs[i]) * (ys[i] + ys[j])
		j = i
	end
	return sum
end

local function linkedList(xs: { number }, ys: { number }, s: number, e: number, clockwise: boolean): Node?
	local last: Node? = nil
	if clockwise == (signedArea(xs, ys, s, e) > 0) then
		for i = s, e do
			last = insertNode(i, xs[i], ys[i], last)
		end
	else
		for i = e, s, -1 do
			last = insertNode(i, xs[i], ys[i], last)
		end
	end
	if last and equals(last, last.next) then
		removeNode(last)
		last = last.next
	end
	return last
end

-- Removes duplicate and collinear points.
local function filterPoints(start: Node?, finish: Node?): Node?
	if not start then
		return start
	end
	local stop = finish or start
	local p = start
	local again
	repeat
		again = false
		if not p.steiner and (equals(p, p.next) or area(p.prev, p, p.next) == 0) then
			removeNode(p)
			p = p.prev
			stop = p
			if p == p.next then
				break
			end
			again = true
		else
			p = p.next
		end
	until not (again or p ~= stop)
	return stop
end

local function zOrder(x: number, y: number, minX: number, minY: number, invSize: number): number
	local ix = math.clamp(math.floor((x - minX) * invSize), 0, 32767)
	local iy = math.clamp(math.floor((y - minY) * invSize), 0, 32767)
	ix = bit32.band(bit32.bor(ix, bit32.lshift(ix, 8)), 0x00FF00FF)
	ix = bit32.band(bit32.bor(ix, bit32.lshift(ix, 4)), 0x0F0F0F0F)
	ix = bit32.band(bit32.bor(ix, bit32.lshift(ix, 2)), 0x33333333)
	ix = bit32.band(bit32.bor(ix, bit32.lshift(ix, 1)), 0x55555555)
	iy = bit32.band(bit32.bor(iy, bit32.lshift(iy, 8)), 0x00FF00FF)
	iy = bit32.band(bit32.bor(iy, bit32.lshift(iy, 4)), 0x0F0F0F0F)
	iy = bit32.band(bit32.bor(iy, bit32.lshift(iy, 2)), 0x33333333)
	iy = bit32.band(bit32.bor(iy, bit32.lshift(iy, 1)), 0x55555555)
	return bit32.bor(ix, bit32.lshift(iy, 1))
end

-- Simon Tatham's linked-list merge sort, on the z-order links.
local function sortLinked(list: Node?)
	local inSize = 1
	local numMerges
	repeat
		local p = list
		list = nil
		local tail: Node? = nil
		numMerges = 0
		while p do
			numMerges += 1
			local q: Node? = p
			local pSize = 0
			for _ = 1, inSize do
				pSize += 1
				q = (q :: Node).nextZ
				if not q then
					break
				end
			end
			local qSize = inSize
			while pSize > 0 or (qSize > 0 and q) do
				local e: Node
				if pSize ~= 0 and (qSize == 0 or not q or (p :: Node).z <= (q :: Node).z) then
					e = p :: Node
					p = e.nextZ
					pSize -= 1
				else
					e = q :: Node
					q = e.nextZ
					qSize -= 1
				end
				if tail then
					tail.nextZ = e
				else
					list = e
				end
				e.prevZ = tail
				tail = e
			end
			p = q
		end
		if tail then
			tail.nextZ = nil
		end
		inSize *= 2
	until numMerges <= 1
end

local function indexCurve(start: Node, minX: number, minY: number, invSize: number)
	local p = start
	repeat
		if p.z == 0 then
			p.z = zOrder(p.x, p.y, minX, minY, invSize)
		end
		p.prevZ = p.prev
		p.nextZ = p.next
		p = p.next
	until p == start
	local tail = p.prevZ :: Node
	tail.nextZ = nil
	p.prevZ = nil
	sortLinked(p)
end

local function isEar(ear: Node): boolean
	local a, b, c = ear.prev, ear, ear.next
	if area(a, b, c) >= 0 then
		return false -- reflex
	end
	local ax, bx, cx, ay, by, cy = a.x, b.x, c.x, a.y, b.y, c.y
	local x0, y0 = math.min(ax, bx, cx), math.min(ay, by, cy)
	local x1, y1 = math.max(ax, bx, cx), math.max(ay, by, cy)
	local p = c.next
	while p ~= a do
		if p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1
			and pointInTriangle(ax, ay, bx, by, cx, cy, p.x, p.y)
			and area(p.prev, p, p.next) >= 0
		then
			return false
		end
		p = p.next
	end
	return true
end

local function isEarHashed(ear: Node, minX: number, minY: number, invSize: number): boolean
	local a, b, c = ear.prev, ear, ear.next
	if area(a, b, c) >= 0 then
		return false
	end
	local ax, bx, cx, ay, by, cy = a.x, b.x, c.x, a.y, b.y, c.y
	local x0, y0 = math.min(ax, bx, cx), math.min(ay, by, cy)
	local x1, y1 = math.max(ax, bx, cx), math.max(ay, by, cy)
	local minZ = zOrder(x0, y0, minX, minY, invSize)
	local maxZ = zOrder(x1, y1, minX, minY, invSize)

	local function blocks(p: Node): boolean
		return p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1 and p ~= a and p ~= c
			and pointInTriangle(ax, ay, bx, by, cx, cy, p.x, p.y)
			and area(p.prev, p, p.next) >= 0
	end

	local p, n = ear.prevZ, ear.nextZ
	while p and p.z >= minZ and n and n.z <= maxZ do
		if blocks(p) then
			return false
		end
		p = p.prevZ
		if blocks(n) then
			return false
		end
		n = n.nextZ
	end
	while p and p.z >= minZ do
		if blocks(p) then
			return false
		end
		p = p.prevZ
	end
	while n and n.z <= maxZ do
		if blocks(n) then
			return false
		end
		n = n.nextZ
	end
	return true
end

local earcutLinked: (Node?, { number }, number, number, number, number) -> ()

local function cureLocalIntersections(start: Node, triangles: { number }): Node?
	local p = start
	repeat
		local a, b = p.prev, p.next.next
		if not equals(a, b) and intersects(a, p, p.next, b) and locallyInside(a, b) and locallyInside(b, a) then
			table.insert(triangles, a.i)
			table.insert(triangles, p.i)
			table.insert(triangles, b.i)
			removeNode(p)
			removeNode(p.next)
			p = b
			start = b
		end
		p = p.next
	until p == start
	return filterPoints(p)
end

local function splitEarcut(start: Node, triangles: { number }, minX: number, minY: number, invSize: number)
	local a = start
	repeat
		local b = a.next.next
		while b ~= a.prev do
			if a.i ~= b.i and isValidDiagonal(a, b) then
				local c = splitPolygon(a, b)
				local fa = filterPoints(a, a.next)
				local fc = filterPoints(c, c.next)
				earcutLinked(fa, triangles, minX, minY, invSize, 0)
				earcutLinked(fc, triangles, minX, minY, invSize, 0)
				return
			end
			b = b.next
		end
		a = a.next
	until a == start
end

earcutLinked = function(ear: Node?, triangles: { number }, minX: number, minY: number, invSize: number, pass: number)
	if not ear then
		return
	end
	local node = ear :: Node
	if pass == 0 and invSize ~= 0 then
		indexCurve(node, minX, minY, invSize)
	end
	local stop = node
	while node.prev ~= node.next do
		local prev, nxt = node.prev, node.next
		local ok = if invSize ~= 0 then isEarHashed(node, minX, minY, invSize) else isEar(node)
		if ok then
			table.insert(triangles, prev.i)
			table.insert(triangles, node.i)
			table.insert(triangles, nxt.i)
			removeNode(node)
			node = nxt.next
			stop = nxt.next
			continue
		end
		node = nxt
		if node == stop then
			if pass == 0 then
				earcutLinked(filterPoints(node), triangles, minX, minY, invSize, 1)
			elseif pass == 1 then
				local filtered = filterPoints(node)
				if filtered then
					earcutLinked(cureLocalIntersections(filtered, triangles), triangles, minX, minY, invSize, 2)
				end
			else
				splitEarcut(node, triangles, minX, minY, invSize)
			end
			break
		end
	end
end

local function getLeftmost(start: Node): Node
	local p, leftmost = start, start
	repeat
		if p.x < leftmost.x or (p.x == leftmost.x and p.y < leftmost.y) then
			leftmost = p
		end
		p = p.next
	until p == start
	return leftmost
end

local function sectorContainsSector(m: Node, p: Node): boolean
	return area(m.prev, m, p.prev) < 0 and area(p.next, m, m.next) < 0
end

-- David Eberly's algorithm for finding a bridge between a hole and the outer polygon.
local function findHoleBridge(hole: Node, outerNode: Node): Node?
	local p = outerNode
	local hx, hy = hole.x, hole.y
	local qx = -math.huge
	local m: Node? = nil
	repeat
		if hy <= p.y and hy >= p.next.y and p.next.y ~= p.y then
			local x = p.x + (hy - p.y) * (p.next.x - p.x) / (p.next.y - p.y)
			if x <= hx and x > qx then
				qx = x
				m = if p.x < p.next.x then p else p.next
				if x == hx then
					return m
				end
			end
		end
		p = p.next
	until p == outerNode
	if not m then
		return nil
	end

	local best = m :: Node
	local stop = best
	local mx, my = best.x, best.y
	local tanMin = math.huge
	p = best
	repeat
		if hx >= p.x and p.x >= mx and hx ~= p.x
			and pointInTriangle(if hy < my then hx else qx, hy, mx, my, if hy < my then qx else hx, hy, p.x, p.y)
		then
			local tan = math.abs(hy - p.y) / (hx - p.x)
			if locallyInside(p, hole)
				and (tan < tanMin or (tan == tanMin and (p.x > best.x or (p.x == best.x and sectorContainsSector(best, p)))))
			then
				best = p
				tanMin = tan
			end
		end
		p = p.next
	until p == stop
	return best
end

local function eliminateHole(hole: Node, outerNode: Node): Node
	local bridge = findHoleBridge(hole, outerNode)
	if not bridge then
		return outerNode
	end
	local bridgeReverse = splitPolygon(bridge, hole)
	filterPoints(bridgeReverse, bridgeReverse.next)
	return filterPoints(bridge, bridge.next) :: Node
end

local function eliminateHoles(xs: { number }, ys: { number }, holeStarts: { number }, outerNode: Node): Node
	local queue = {}
	for k, s in holeStarts do
		local e = if k < #holeStarts then holeStarts[k + 1] - 1 else #xs
		local list = linkedList(xs, ys, s, e, false)
		if list then
			if list == list.next then
				list.steiner = true
			end
			table.insert(queue, getLeftmost(list))
		end
	end
	table.sort(queue, function(a, b)
		return a.x < b.x
	end)
	for _, hole in queue do
		outerNode = eliminateHole(hole, outerNode)
	end
	return outerNode
end

-- xs/ys: the outer ring followed by each hole ring. holeStarts: index where each hole begins.
-- Returns a flat list of vertex indices, three per triangle.
function Earcut.triangulate(xs: { number }, ys: { number }, holeStarts: { number }?): { number }
	local n = #xs
	local hasHoles = holeStarts ~= nil and #holeStarts > 0
	local outerEnd = if hasHoles then (holeStarts :: { number })[1] - 1 else n
	local triangles = {}
	local outerNode = linkedList(xs, ys, 1, outerEnd, true)
	if not outerNode or outerNode.next == outerNode.prev then
		return triangles
	end
	if hasHoles then
		outerNode = eliminateHoles(xs, ys, holeStarts :: { number }, outerNode)
	end

	local minX, minY, invSize = 0, 0, 0
	if n > 80 then
		minX, minY = xs[1], ys[1]
		local maxX, maxY = minX, minY
		for i = 2, outerEnd do
			local x, y = xs[i], ys[i]
			if x < minX then minX = x end
			if y < minY then minY = y end
			if x > maxX then maxX = x end
			if y > maxY then maxY = y end
		end
		invSize = math.max(maxX - minX, maxY - minY)
		invSize = if invSize ~= 0 then 32767 / invSize else 0
	end

	earcutLinked(outerNode, triangles, minX, minY, invSize, 0)
	return triangles
end

return Earcut
