-- Turns SVG source text into a flat list of filled shapes: flattened outlines in document
-- coordinates plus a resolved fill color, opacity and fill rule.

local Xml = if script then require(script.Parent.Xml) else require("./Xml")
local Transform = if script then require(script.Parent.Transform) else require("./Transform")
local PathData = if script then require(script.Parent.PathData) else require("./PathData")

local SvgDocument = {}

export type Shape = {
	rings: { { { number } } },
	fillRule: string,
	color: { number },
	alpha: number,
	name: string?,
}

export type Result = {
	shapes: { Shape },
	warnings: { string },
	size: number,
}

local NAMED_COLORS = {
	black = "000000", white = "ffffff", red = "ff0000", green = "008000", lime = "00ff00",
	blue = "0000ff", yellow = "ffff00", cyan = "00ffff", aqua = "00ffff", magenta = "ff00ff",
	fuchsia = "ff00ff", gray = "808080", grey = "808080", silver = "c0c0c0", maroon = "800000",
	olive = "808000", purple = "800080", teal = "008080", navy = "000080", orange = "ffa500",
	pink = "ffc0cb", brown = "a52a2a", gold = "ffd700", indigo = "4b0082", violet = "ee82ee",
	coral = "ff7f50", crimson = "dc143c", salmon = "fa8072", tomato = "ff6347", khaki = "f0e68c",
	beige = "f5f5dc", tan = "d2b48c", chocolate = "d2691e", darkred = "8b0000", darkgreen = "006400",
	darkblue = "00008b", darkgray = "a9a9a9", darkgrey = "a9a9a9", lightgray = "d3d3d3",
	lightgrey = "d3d3d3", lightblue = "add8e6", skyblue = "87ceeb", steelblue = "4682b4",
	royalblue = "4169e1", dodgerblue = "1e90ff", deepskyblue = "00bfff", turquoise = "40e0d0",
	limegreen = "32cd32", forestgreen = "228b22", seagreen = "2e8b57", olivedrab = "6b8e23",
	yellowgreen = "9acd32", orangered = "ff4500", darkorange = "ff8c00", hotpink = "ff69b4",
	deeppink = "ff1493", plum = "dda0dd", orchid = "da70d6", lavender = "e6e6fa",
	slategray = "708090", slategrey = "708090", dimgray = "696969", dimgrey = "696969",
	whitesmoke = "f5f5f5", ivory = "fffff0", firebrick = "b22222", sienna = "a0522d",
	peru = "cd853f", goldenrod = "daa520", midnightblue = "191970", darkviolet = "9400d3",
	rebeccapurple = "663399", lightgreen = "90ee90", darkslategray = "2f4f4f",
	darkslategrey = "2f4f4f", gainsboro = "dcdcdc", snow = "fffafa", mintcream = "f5fffa",
}

-- Elements whose contents never render directly.
local SKIP = {
	defs = true, clipPath = true, mask = true, symbol = true, marker = true, pattern = true,
	linearGradient = true, radialGradient = true, style = true, title = true, desc = true,
	metadata = true, filter = true, foreignObject = true, script = true, namedview = true,
}

local CONTAINERS = { g = true, svg = true, a = true, switch = true }
local SHAPES = { path = true, rect = true, circle = true, ellipse = true, polygon = true, polyline = true }

local INHERITED = {
	"fill", "fill-opacity", "fill-rule", "visibility", "stroke", "stroke-width", "stroke-opacity", "color",
}
local PROPERTIES = {
	"fill", "fill-opacity", "fill-rule", "visibility", "stroke", "stroke-width", "stroke-opacity", "color",
	"opacity", "display",
}

local function trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function firstNumber(s: string?): number?
	if not s then
		return nil
	end
	return Transform.numbers(s)[1]
end

local function parseOpacity(v: string?): number
	if not v then
		return 1
	end
	local pct = v:match("^%s*([%d%.]+)%%")
	if pct then
		return math.clamp((tonumber(pct) or 100) / 100, 0, 1)
	end
	return math.clamp(tonumber(trim(v)) or 1, 0, 1)
end

---------------------------------------------------------------------------------------------------
-- Colors

local function hexColor(h: string): (number?, number?, number?, number?)
	if #h == 3 or #h == 4 then
		local a = if #h == 4 then h:sub(4, 4) else "f"
		local function ch(c)
			return (tonumber(c .. c, 16) :: number) / 255
		end
		return ch(h:sub(1, 1)), ch(h:sub(2, 2)), ch(h:sub(3, 3)), ch(a)
	elseif #h == 6 or #h == 8 then
		local function ch(k)
			return (tonumber(h:sub(k, k + 1), 16) :: number) / 255
		end
		return ch(1), ch(3), ch(5), if #h == 8 then ch(7) else 1
	end
	return nil
end

local function channel(v: string, max: number): number?
	local pct = v:match("^([%d%.%-]+)%%$")
	if pct then
		local n = tonumber(pct)
		return n and math.clamp(n / 100, 0, 1)
	end
	local n = tonumber(v)
	return n and math.clamp(n / max, 0, 1)
end

local function hslToRgb(h: number, s: number, l: number): (number, number, number)
	h = (h % 360) / 360
	if s == 0 then
		return l, l, l
	end
	local q = if l < 0.5 then l * (1 + s) else l + s - l * s
	local p = 2 * l - q
	local function hue(t)
		t %= 1
		if t < 1 / 6 then
			return p + (q - p) * 6 * t
		elseif t < 1 / 2 then
			return q
		elseif t < 2 / 3 then
			return p + (q - p) * (2 / 3 - t) * 6
		end
		return p
	end
	return hue(h + 1 / 3), hue(h), hue(h - 1 / 3)
end

-- Returns r, g, b, a in 0..1, or nil for "none" or anything unparseable.
local function parseColor(s: string): (number?, number?, number?, number?)
	s = trim(s):lower()
	local hex = s:match("^#(%x+)$")
	if hex then
		return hexColor(hex)
	end
	local fn, args = s:match("^(%a+)%s*%((.-)%)$")
	if fn then
		local parts = {}
		for p in args:gsub("/", " "):gmatch("[^%s,]+") do
			table.insert(parts, p)
		end
		if #parts < 3 then
			return nil
		end
		local a = if parts[4] then channel(parts[4], 1) else 1
		if fn == "rgb" or fn == "rgba" then
			local r, g, b = channel(parts[1], 255), channel(parts[2], 255), channel(parts[3], 255)
			if r and g and b and a then
				return r, g, b, a
			end
		elseif fn == "hsl" or fn == "hsla" then
			local h = tonumber((parts[1]:gsub("deg$", "")))
			local sat, light = channel(parts[2], 100), channel(parts[3], 100)
			if h and sat and light and a then
				local r, g, b = hslToRgb(h, sat, light)
				return r, g, b, a
			end
		end
		return nil
	end
	local named = NAMED_COLORS[s]
	if named then
		return hexColor(named)
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- CSS (<style> blocks with simple selectors, plus inline style attributes)

local function parseDeclarations(s: string): { [string]: string }
	local out = {}
	for decl in s:gmatch("[^;]+") do
		local k, v = decl:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
		if k and v then
			out[k:lower()] = (v:gsub("%s*!important$", ""))
		end
	end
	return out
end

type Selector = { tag: string?, id: string?, classes: { string }, spec: number }
type Rule = { selector: Selector, decls: { [string]: string }, spec: number, order: number }

local function compileSelector(sel: string): Selector?
	if sel == "" or sel:find("[%s>+~%[:]") then
		return nil -- combinators, attribute selectors and pseudo-classes are not supported
	end
	local tag = sel:match("^([%a][%w%-]*)")
	if sel:sub(1, 1) == "*" then
		tag = nil
	end
	local id = sel:match("#([%w%-_]+)")
	local classes = {}
	for c in sel:gmatch("%.([%w%-_]+)") do
		table.insert(classes, c)
	end
	local spec = (if id then 100 else 0) + #classes * 10 + (if tag then 1 else 0)
	return { tag = tag, id = id, classes = classes, spec = spec }
end

local function parseStylesheet(text: string): { Rule }
	text = text:gsub("/%*.-%*/", "")
	local rules: { Rule } = {}
	local i = 1
	while true do
		local open = text:find("{", i, true)
		if not open then
			break
		end
		local selectorText = trim(text:sub(i, open - 1))
		local depth, j = 1, open + 1
		while j <= #text and depth > 0 do
			local c = text:sub(j, j)
			if c == "{" then
				depth += 1
			elseif c == "}" then
				depth -= 1
			end
			j += 1
		end
		if selectorText:sub(1, 1) ~= "@" then
			local decls = parseDeclarations(text:sub(open + 1, j - 2))
			for sel in selectorText:gmatch("[^,]+") do
				local compiled = compileSelector(trim(sel))
				if compiled then
					table.insert(rules, { selector = compiled, decls = decls, spec = compiled.spec, order = #rules + 1 })
				end
			end
		end
		i = j
	end
	table.sort(rules, function(a, b)
		if a.spec ~= b.spec then
			return a.spec < b.spec
		end
		return a.order < b.order
	end)
	return rules
end

local function selectorMatches(sel: Selector, node: Xml.Node): boolean
	if sel.tag and sel.tag ~= node.tag then
		return false
	end
	if sel.id and sel.id ~= node.attrs.id then
		return false
	end
	if #sel.classes > 0 then
		local have = {}
		for c in (node.attrs.class or ""):gmatch("%S+") do
			have[c] = true
		end
		for _, c in sel.classes do
			if not have[c] then
				return false
			end
		end
	end
	return true
end

---------------------------------------------------------------------------------------------------
-- Basic shapes as path data

local function fmt(...: number): string
	local parts = {}
	for k, v in { ... } do
		parts[k] = string.format("%.10g", v)
	end
	return table.concat(parts, " ")
end

local function shapeToPathData(node: Xml.Node): string?
	local a = node.attrs
	local tag = node.tag
	if tag == "path" then
		return a.d
	elseif tag == "rect" then
		local x, y = firstNumber(a.x) or 0, firstNumber(a.y) or 0
		local w, h = firstNumber(a.width) or 0, firstNumber(a.height) or 0
		if w <= 0 or h <= 0 then
			return nil
		end
		local rx, ry = firstNumber(a.rx), firstNumber(a.ry)
		rx = rx or ry or 0
		ry = ry or rx or 0
		rx = math.clamp(rx :: number, 0, w / 2)
		ry = math.clamp(ry :: number, 0, h / 2)
		if rx <= 0 or ry <= 0 then
			return "M" .. fmt(x, y) .. " H" .. fmt(x + w) .. " V" .. fmt(y + h) .. " H" .. fmt(x) .. " Z"
		end
		local corner = " A" .. fmt(rx, ry) .. " 0 0 1 "
		return "M"
			.. fmt(x + rx, y)
			.. " H" .. fmt(x + w - rx)
			.. corner .. fmt(x + w, y + ry)
			.. " V" .. fmt(y + h - ry)
			.. corner .. fmt(x + w - rx, y + h)
			.. " H" .. fmt(x + rx)
			.. corner .. fmt(x, y + h - ry)
			.. " V" .. fmt(y + ry)
			.. corner .. fmt(x + rx, y)
			.. " Z"
	elseif tag == "circle" or tag == "ellipse" then
		local cx, cy = firstNumber(a.cx) or 0, firstNumber(a.cy) or 0
		local rx, ry
		if tag == "circle" then
			rx = firstNumber(a.r) or 0
			ry = rx
		else
			rx, ry = firstNumber(a.rx), firstNumber(a.ry)
			rx = rx or ry or 0
			ry = ry or rx or 0
		end
		if rx <= 0 or ry <= 0 then
			return nil
		end
		local half = " A" .. fmt(rx, ry) .. " 0 1 0 "
		return "M" .. fmt(cx - rx, cy) .. half .. fmt(cx + rx, cy) .. half .. fmt(cx - rx, cy) .. " Z"
	elseif tag == "polygon" or tag == "polyline" then
		local v = Transform.numbers(a.points or "")
		if #v < 6 then
			return nil
		end
		local parts = { "M" .. fmt(v[1], v[2]) }
		for k = 3, #v - 1, 2 do
			table.insert(parts, "L" .. fmt(v[k], v[k + 1]))
		end
		table.insert(parts, "Z")
		return table.concat(parts, " ")
	end
	return nil
end

---------------------------------------------------------------------------------------------------

-- quality: curve tolerance as a fraction of the document's size (smaller = smoother).
function SvgDocument.load(source: string, quality: number, sizeOverride: number?): Result
	local docRoot = Xml.parse(source)
	local svg = Xml.findFirst(docRoot, "svg")
	if not svg then
		error("This file has no <svg> element.", 0)
	end

	local warningCounts: { [string]: number } = {}
	local warningOrder: { string } = {}
	local function warn(message: string)
		if not warningCounts[message] then
			table.insert(warningOrder, message)
			warningCounts[message] = 0
		end
		warningCounts[message] += 1
	end

	-- Index ids and gather every <style> block.
	local byId: { [string]: Xml.Node } = {}
	local cssText = {}
	Xml.walk(svg, function(node)
		if node.attrs.id then
			byId[node.attrs.id] = node
		end
		if node.tag == "style" then
			table.insert(cssText, node.text)
		end
	end)
	local rules = parseStylesheet(table.concat(cssText, "\n"))

	-- Document size, used to pick a curve tolerance.
	local size = sizeOverride
	if not size then
		local vb = Transform.numbers(svg.attrs.viewBox or "")
		if #vb >= 4 and vb[3] > 0 and vb[4] > 0 then
			size = math.max(vb[3], vb[4])
		else
			local w, h = firstNumber(svg.attrs.width), firstNumber(svg.attrs.height)
			if w and h and w > 0 and h > 0 then
				size = math.max(w, h)
			end
		end
	end
	if not size then
		-- No declared size: do a coarse pass to measure the drawing, then reparse.
		local coarse = SvgDocument.load(source, 1, 1000)
		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		for _, shape in coarse.shapes do
			for _, ring in shape.rings do
				for _, p in ring do
					minX, maxX = math.min(minX, p[1]), math.max(maxX, p[1])
					minY, maxY = math.min(minY, p[2]), math.max(maxY, p[2])
				end
			end
		end
		size = if maxX > minX then math.max(maxX - minX, maxY - minY) else 100
	end
	local baseTol = (size :: number) * quality

	local function computeStyle(node: Xml.Node, parent: { [string]: string }): { [string]: string }
		local style = {}
		for _, k in INHERITED do
			style[k] = parent[k]
		end
		for _, k in PROPERTIES do
			local v = node.attrs[k]
			if v then
				style[k] = trim(v)
			end
		end
		for _, rule in rules do
			if selectorMatches(rule.selector, node) then
				for k, v in rule.decls do
					style[k] = v
				end
			end
		end
		if node.attrs.style then
			for k, v in parseDeclarations(node.attrs.style) do
				style[k] = v
			end
		end
		for k, v in style do
			if v == "inherit" then
				style[k] = parent[k]
			end
		end
		return style
	end

	local function gradientColor(id: string): (number?, number?, number?, number?)
		local node = byId[id]
		local hops = 0
		while node and hops < 8 do
			if node.tag ~= "linearGradient" and node.tag ~= "radialGradient" then
				return nil
			end
			local stops = {}
			for _, child in node.children do
				if child.tag == "stop" then
					table.insert(stops, child)
				end
			end
			if #stops > 0 then
				local r, g, b, a, count = 0, 0, 0, 0, 0
				for _, stop in stops do
					local st = computeStyle(stop, {})
					local sr, sg, sb, sa = parseColor(st["stop-color"] or stop.attrs["stop-color"] or "black")
					if sr then
						r += sr :: number
						g += sg :: number
						b += sb :: number
						a += (sa :: number) * parseOpacity(st["stop-opacity"] or stop.attrs["stop-opacity"])
						count += 1
					end
				end
				if count == 0 then
					return nil
				end
				return r / count, g / count, b / count, a / count
			end
			local href = node.attrs.href or node.attrs["xlink:href"]
			node = href and byId[href:match("^#(.+)") or ""]
			hops += 1
		end
		return nil
	end

	-- Returns r, g, b, a for a fill value, or nil when nothing should be drawn.
	local function resolvePaint(value: string, style: { [string]: string }): (number?, number?, number?, number?)
		value = trim(value)
		local lower = value:lower()
		if lower == "none" or lower == "transparent" then
			return nil
		end
		if lower:sub(1, 4) == "url(" then
			local id = value:match("^url%(%s*['\"]?#([^'\"%)%s]+)")
			if id then
				local r, g, b, a = gradientColor(id)
				if r then
					warn("Gradients were flattened to their average color.")
					return r, g, b, a
				end
			end
			local fallback = value:match("%)%s*(.+)$")
			if fallback then
				return resolvePaint(fallback, style)
			end
			warn("Some fills use patterns or unknown paint servers; they were drawn black.")
			return 0, 0, 0, 1
		end
		if lower == "currentcolor" then
			local r, g, b, a = parseColor(style.color or "black")
			if r then
				return r, g, b, a
			end
			return 0, 0, 0, 1
		end
		local r, g, b, a = parseColor(value)
		if not r then
			warn(("Unrecognized color %q was drawn black."):format(value))
			return 0, 0, 0, 1
		end
		return r, g, b, a
	end

	local shapes: { Shape } = {}

	local function emitShape(node: Xml.Node, matrix: Transform.Matrix, style: { [string]: string }, opacity: number)
		if style.visibility == "hidden" or style.visibility == "collapse" then
			return
		end
		local stroke = style.stroke
		if stroke and trim(stroke) ~= "none" and (firstNumber(style["stroke-width"]) or 1) > 0 then
			warn("Strokes (outlines) are skipped. Use Outline Stroke / Stroke to Path in your editor to keep them.")
		end
		local r, g, b, a = resolvePaint(style.fill or "black", style)
		if not r then
			return
		end
		local alpha = (a :: number) * parseOpacity(style["fill-opacity"]) * opacity
		if alpha <= 0.001 then
			return
		end
		local d = shapeToPathData(node)
		if not d then
			return
		end
		local tol = baseTol / Transform.scaleFactor(matrix)
		local subpaths, err = PathData.parse(d, tol)
		if err then
			warn("Some path data was malformed; shapes were kept up to the error (" .. err .. ").")
		end
		if #subpaths == 0 then
			return
		end
		for _, sub in subpaths do
			for k, p in sub do
				local x, y = Transform.apply(matrix, p[1], p[2])
				sub[k] = { x, y }
			end
		end
		table.insert(shapes, {
			rings = subpaths,
			fillRule = if trim(style["fill-rule"] or ""):lower() == "evenodd" then "evenodd" else "nonzero",
			color = { r :: number, g :: number, b :: number },
			alpha = alpha,
			name = node.attrs.id,
		})
	end

	local function walk(node: Xml.Node, matrix: Transform.Matrix, parentStyle: { [string]: string }, opacity: number, depth: number)
		local tag = node.tag
		if SKIP[tag] or depth > 64 then
			return
		end
		local style = computeStyle(node, parentStyle)
		if style.display and trim(style.display) == "none" then
			return
		end
		local m = matrix
		if tag == "svg" and node ~= svg then
			m = Transform.multiply(m, Transform.translate(firstNumber(node.attrs.x) or 0, firstNumber(node.attrs.y) or 0))
		end
		if node.attrs.transform then
			m = Transform.multiply(m, Transform.parse(node.attrs.transform))
		end
		local op = opacity * parseOpacity(style.opacity)

		if CONTAINERS[tag] then
			for _, child in node.children do
				walk(child, m, style, op, depth + 1)
			end
		elseif tag == "use" then
			local href = node.attrs.href or node.attrs["xlink:href"]
			local target = href and byId[href:match("^#(.+)") or ""]
			if target then
				local um = Transform.multiply(m, Transform.translate(firstNumber(node.attrs.x) or 0, firstNumber(node.attrs.y) or 0))
				if target.tag == "symbol" then
					local symbolStyle = computeStyle(target, style)
					if target.attrs.transform then
						um = Transform.multiply(um, Transform.parse(target.attrs.transform))
					end
					for _, child in target.children do
						walk(child, um, symbolStyle, op, depth + 1)
					end
				else
					walk(target, um, style, op, depth + 1)
				end
			end
		elseif SHAPES[tag] then
			emitShape(node, m, style, op)
		elseif tag == "text" then
			warn("Text is skipped. Convert text to paths (Create Outlines / Object to Path) before exporting.")
		elseif tag == "image" then
			warn("Embedded images are skipped.")
		end
	end

	walk(svg, Transform.identity(), {}, 1, 0)

	local warnings = {}
	for _, message in warningOrder do
		local count = warningCounts[message]
		table.insert(warnings, if count > 1 then ("%s (x%d)"):format(message, count) else message)
	end

	return { shapes = shapes, warnings = warnings, size = size :: number }
end

SvgDocument.parseColor = parseColor

return SvgDocument
