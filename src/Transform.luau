-- 2D affine matrices in SVG order {a, b, c, d, e, f}:
--   x' = a*x + c*y + e
--   y' = b*x + d*y + f

local Transform = {}

export type Matrix = { number }

function Transform.identity(): Matrix
	return { 1, 0, 0, 1, 0, 0 }
end

function Transform.translate(tx: number, ty: number): Matrix
	return { 1, 0, 0, 1, tx, ty }
end

-- Returns m * n (n is applied first).
function Transform.multiply(m: Matrix, n: Matrix): Matrix
	return {
		m[1] * n[1] + m[3] * n[2],
		m[2] * n[1] + m[4] * n[2],
		m[1] * n[3] + m[3] * n[4],
		m[2] * n[3] + m[4] * n[4],
		m[1] * n[5] + m[3] * n[6] + m[5],
		m[2] * n[5] + m[4] * n[6] + m[6],
	}
end

function Transform.apply(m: Matrix, x: number, y: number): (number, number)
	return m[1] * x + m[3] * y + m[5], m[2] * x + m[4] * y + m[6]
end

-- Average linear scale of the matrix, used to keep curve tolerance constant in document space.
function Transform.scaleFactor(m: Matrix): number
	local det = math.abs(m[1] * m[4] - m[2] * m[3])
	return if det > 1e-12 then math.sqrt(det) else 1
end

-- Pulls every number out of a string such as "10,20 -3.5e2.5".
function Transform.numbers(s: string): { number }
	local out = {}
	local i, n = 1, #s
	while i <= n do
		local st, e = s:find("^[%+%-]?%d*%.?%d+[eE][%+%-]?%d+", i)
		if not st then
			st, e = s:find("^[%+%-]?%d*%.?%d+", i)
		end
		if st then
			table.insert(out, tonumber(s:sub(st, e)) :: number)
			i = e + 1
		else
			i += 1
		end
	end
	return out
end

function Transform.parse(s: string): Matrix
	local result = Transform.identity()
	for name, args in s:gmatch("([%a]+)%s*%(([^%)]*)%)") do
		local v = Transform.numbers(args)
		local m
		if name == "matrix" and #v >= 6 then
			m = { v[1], v[2], v[3], v[4], v[5], v[6] }
		elseif name == "translate" and #v >= 1 then
			m = Transform.translate(v[1], v[2] or 0)
		elseif name == "scale" and #v >= 1 then
			m = { v[1], 0, 0, v[2] or v[1], 0, 0 }
		elseif name == "rotate" and #v >= 1 then
			local a = math.rad(v[1])
			local cos, sin = math.cos(a), math.sin(a)
			m = { cos, sin, -sin, cos, 0, 0 }
			if #v >= 3 then
				m = Transform.multiply(
					Transform.translate(v[2], v[3]),
					Transform.multiply(m, Transform.translate(-v[2], -v[3]))
				)
			end
		elseif name == "skewX" and #v >= 1 then
			m = { 1, 0, math.tan(math.rad(v[1])), 1, 0, 0 }
		elseif name == "skewY" and #v >= 1 then
			m = { 1, math.tan(math.rad(v[1])), 0, 1, 0, 0 }
		end
		if m then
			result = Transform.multiply(result, m)
		end
	end
	return result
end

return Transform
