-- Parses SVG path data ("d" attribute) and flattens curves and arcs into point lists.
-- Every subpath is returned as a closed polygon outline, since the importer only fills shapes.

local PathData = {}

export type Point = { number }
export type Subpath = { Point }

local COMMANDS = "[MmLlHhVvCcSsQqTtAaZz]"

-- tol: maximum distance (in the path's own units) between a curve and its flattened outline.
function PathData.parse(d: string, tol: number): ({ Subpath }, string?)
	local subpaths: { Subpath } = {}
	local current: Subpath? = nil
	local i, n = 1, #d
	local cx, cy = 0, 0 -- current point
	local sx, sy = 0, 0 -- start of the current subpath
	local ctrlX, ctrlY = 0, 0 -- last control point, for S and T
	local prevCmd = ""

	local function skipSeparators()
		while i <= n do
			local b = string.byte(d, i)
			if b == 32 or b == 9 or b == 10 or b == 13 or b == 44 then
				i += 1
			else
				break
			end
		end
	end

	local function hasNumber(): boolean
		skipSeparators()
		return i <= n and d:sub(i, i):match("[%d%.%+%-]") ~= nil
	end

	local function readNumber(): number
		skipSeparators()
		local s, e = d:find("^[%+%-]?%d*%.?%d+[eE][%+%-]?%d+", i)
		if not s then
			s, e = d:find("^[%+%-]?%d*%.?%d+", i)
		end
		if not s then
			error(("bad number in path data near %q"):format(d:sub(i, i + 12)), 0)
		end
		i = e + 1
		return tonumber(d:sub(s, e)) :: number
	end

	-- Arc flags may be packed without separators ("a1 1 0 00 1 1"), so read one character.
	local function readFlag(): boolean
		skipSeparators()
		local c = d:sub(i, i)
		if c == "0" or c == "1" then
			i += 1
			return c == "1"
		end
		error("bad arc flag in path data", 0)
	end

	local function startSubpath(x: number, y: number)
		current = { { x, y } }
		table.insert(subpaths, current :: Subpath)
		sx, sy = x, y
	end

	local function lineTo(x: number, y: number)
		if not current then
			startSubpath(cx, cy)
		end
		table.insert(current :: Subpath, { x, y })
	end

	local function cubic(x1: number, y1: number, x2: number, y2: number, x: number, y: number)
		local ddx = math.max(math.abs(cx - 2 * x1 + x2), math.abs(x1 - 2 * x2 + x))
		local ddy = math.max(math.abs(cy - 2 * y1 + y2), math.abs(y1 - 2 * y2 + y))
		local dd = math.sqrt(ddx * ddx + ddy * ddy)
		local segments = math.clamp(math.ceil(math.sqrt(6 * dd / (8 * tol))), 1, 256)
		local x0, y0 = cx, cy
		for s = 1, segments do
			local t = s / segments
			local mt = 1 - t
			local a, b, c, e = mt * mt * mt, 3 * mt * mt * t, 3 * mt * t * t, t * t * t
			lineTo(a * x0 + b * x1 + c * x2 + e * x, a * y0 + b * y1 + c * y2 + e * y)
		end
	end

	local function quadratic(x1: number, y1: number, x: number, y: number)
		local ddx, ddy = cx - 2 * x1 + x, cy - 2 * y1 + y
		local dd = math.sqrt(ddx * ddx + ddy * ddy)
		local segments = math.clamp(math.ceil(math.sqrt(2 * dd / (8 * tol))), 1, 256)
		local x0, y0 = cx, cy
		for s = 1, segments do
			local t = s / segments
			local mt = 1 - t
			lineTo(mt * mt * x0 + 2 * mt * t * x1 + t * t * x, mt * mt * y0 + 2 * mt * t * y1 + t * t * y)
		end
	end

	-- Endpoint-to-center conversion from the SVG spec (implementation notes F.6.5).
	local function arc(rx: number, ry: number, phiDeg: number, largeArc: boolean, sweep: boolean, x: number, y: number)
		local x0, y0 = cx, cy
		if x0 == x and y0 == y then
			return
		end
		rx, ry = math.abs(rx), math.abs(ry)
		if rx == 0 or ry == 0 then
			lineTo(x, y)
			return
		end
		local phi = math.rad(phiDeg % 360)
		local cosP, sinP = math.cos(phi), math.sin(phi)
		local hx, hy = (x0 - x) / 2, (y0 - y) / 2
		local x1p = cosP * hx + sinP * hy
		local y1p = -sinP * hx + cosP * hy
		local lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
		if lambda > 1 then
			local s = math.sqrt(lambda)
			rx *= s
			ry *= s
		end
		local num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
		local den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
		local coef = if den > 0 then math.sqrt(math.max(0, num / den)) else 0
		if largeArc == sweep then
			coef = -coef
		end
		local cxp = coef * (rx * y1p / ry)
		local cyp = coef * (-ry * x1p / rx)
		local centerX = cosP * cxp - sinP * cyp + (x0 + x) / 2
		local centerY = sinP * cxp + cosP * cyp + (y0 + y) / 2

		local ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
		local vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
		local theta1 = math.atan2(uy, ux)
		local dTheta = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
		if not sweep and dTheta > 0 then
			dTheta -= 2 * math.pi
		elseif sweep and dTheta < 0 then
			dTheta += 2 * math.pi
		end

		local r = math.max(rx, ry)
		local step = if tol < r then 2 * math.acos(1 - tol / r) else math.pi / 2
		local segments = math.clamp(math.ceil(math.abs(dTheta) / step), 1, 256)
		for s = 1, segments - 1 do
			local t = theta1 + dTheta * s / segments
			local ex, ey = rx * math.cos(t), ry * math.sin(t)
			lineTo(cosP * ex - sinP * ey + centerX, sinP * ex + cosP * ey + centerY)
		end
		lineTo(x, y)
	end

	local ok, err = pcall(function()
		local cmd: string? = nil
		while true do
			skipSeparators()
			if i > n then
				break
			end
			local c = d:sub(i, i)
			if c:match(COMMANDS) then
				cmd = c
				i += 1
			elseif not cmd or not hasNumber() then
				-- Garbage or numbers after Z: stop, keeping what was parsed (as browsers do).
				break
			end

			local command = cmd :: string
			local rel = command:lower() == command
			local C = command:upper()

			if C == "Z" then
				cx, cy = sx, sy
				current = nil
				cmd = nil
			elseif C == "M" then
				local x, y = readNumber(), readNumber()
				if rel then
					x += cx
					y += cy
				end
				startSubpath(x, y)
				cx, cy = x, y
				-- Extra coordinate pairs after a moveto are implicit linetos.
				cmd = if rel then "l" else "L"
			elseif C == "L" then
				local x, y = readNumber(), readNumber()
				if rel then
					x += cx
					y += cy
				end
				lineTo(x, y)
				cx, cy = x, y
			elseif C == "H" then
				local x = readNumber()
				if rel then
					x += cx
				end
				lineTo(x, cy)
				cx = x
			elseif C == "V" then
				local y = readNumber()
				if rel then
					y += cy
				end
				lineTo(cx, y)
				cy = y
			elseif C == "C" then
				local x1, y1, x2, y2, x, y =
					readNumber(), readNumber(), readNumber(), readNumber(), readNumber(), readNumber()
				if rel then
					x1, y1, x2, y2, x, y = x1 + cx, y1 + cy, x2 + cx, y2 + cy, x + cx, y + cy
				end
				cubic(x1, y1, x2, y2, x, y)
				ctrlX, ctrlY = x2, y2
				cx, cy = x, y
			elseif C == "S" then
				local x2, y2, x, y = readNumber(), readNumber(), readNumber(), readNumber()
				if rel then
					x2, y2, x, y = x2 + cx, y2 + cy, x + cx, y + cy
				end
				local x1, y1 = cx, cy
				if prevCmd == "C" or prevCmd == "S" then
					x1, y1 = 2 * cx - ctrlX, 2 * cy - ctrlY
				end
				cubic(x1, y1, x2, y2, x, y)
				ctrlX, ctrlY = x2, y2
				cx, cy = x, y
			elseif C == "Q" then
				local x1, y1, x, y = readNumber(), readNumber(), readNumber(), readNumber()
				if rel then
					x1, y1, x, y = x1 + cx, y1 + cy, x + cx, y + cy
				end
				quadratic(x1, y1, x, y)
				ctrlX, ctrlY = x1, y1
				cx, cy = x, y
			elseif C == "T" then
				local x, y = readNumber(), readNumber()
				if rel then
					x += cx
					y += cy
				end
				local x1, y1 = cx, cy
				if prevCmd == "Q" or prevCmd == "T" then
					x1, y1 = 2 * cx - ctrlX, 2 * cy - ctrlY
				end
				quadratic(x1, y1, x, y)
				ctrlX, ctrlY = x1, y1
				cx, cy = x, y
			elseif C == "A" then
				local rx, ry, rot = readNumber(), readNumber(), readNumber()
				local largeArc, sweep = readFlag(), readFlag()
				local x, y = readNumber(), readNumber()
				if rel then
					x += cx
					y += cy
				end
				arc(rx, ry, rot, largeArc, sweep, x, y)
				cx, cy = x, y
			end
			prevCmd = C
		end
	end)

	local result = {}
	for _, sub in subpaths do
		if #sub >= 3 then
			table.insert(result, sub)
		end
	end
	return result, if ok then nil else tostring(err)
end

return PathData
