-- Geometry tests, run with: lune run tests/run.luau
local fs = require("@lune/fs")
local process = require("@lune/process")

local SvgDocument = require("../src/SvgDocument")
local MeshBuilder = require("../src/MeshBuilder")
local Regions = require("../src/Regions")
local Earcut = require("../src/Earcut")

local failures = 0
local function check(name: string, ok: boolean, detail: string?)
	if ok then
		print("  ok   " .. name)
	else
		failures += 1
		print("  FAIL " .. name .. (if detail then ("  (" .. detail .. ")") else ""))
	end
end

local function near(a: number, b: number, tol: number): boolean
	return math.abs(a - b) <= tol
end

-- Triangulated area of every filled region in a document, in document units.
local function filledArea(svg: string, quality: number?): (number, number, any)
	local doc = SvgDocument.load(svg, quality or 0.0005)
	local total, expected = 0, 0
	for _, shape in doc.shapes do
		for _, polygon in Regions.resolve(shape.rings, shape.fillRule) do
			local xs, ys, holeStarts = {}, {}, {}
			local rings = { polygon.outer }
			for _, h in polygon.holes do
				table.insert(rings, h)
			end
			expected += math.abs(Regions.signedArea(polygon.outer))
			for k, ring in rings do
				if k > 1 then
					table.insert(holeStarts, #xs + 1)
					expected -= math.abs(Regions.signedArea(ring))
				end
				for _, p in ring do
					table.insert(xs, p[1])
					table.insert(ys, p[2])
				end
			end
			local tris = Earcut.triangulate(xs, ys, holeStarts)
			for t = 1, #tris, 3 do
				local a, b, c = tris[t], tris[t + 1], tris[t + 2]
				total += math.abs((xs[b] - xs[a]) * (ys[c] - ys[a]) - (xs[c] - xs[a]) * (ys[b] - ys[a])) / 2
			end
		end
	end
	return total, expected, doc
end

local function svg(body: string, extra: string?): string
	return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"' .. (extra or "") .. ">" .. body .. "</svg>"
end

print("Shapes and fill rules")
do
	local area = filledArea(svg('<rect x="10" y="10" width="50" height="20"/>'))
	check("rect area", near(area, 1000, 1e-6), tostring(area))

	local hole = '<path fill-rule="evenodd" d="M0 0 H40 V40 H0 Z M10 10 H30 V30 H10 Z"/>'
	area = filledArea(svg(hole))
	check("evenodd square hole", near(area, 1200, 1e-6), tostring(area))

	-- Nonzero: same direction keeps the inner square filled, reversed direction cuts it out.
	area = filledArea(svg('<path d="M0 0 H40 V40 H0 Z M10 10 H30 V30 H10 Z"/>'))
	check("nonzero same direction fills", near(area, 1600, 1e-6), tostring(area))
	area = filledArea(svg('<path d="M0 0 H40 V40 H0 Z M10 10 V30 H30 V10 Z"/>'))
	check("nonzero reversed direction cuts", near(area, 1200, 1e-6), tostring(area))

	area = filledArea(svg('<circle cx="50" cy="50" r="40"/>'))
	check("circle area", near(area, math.pi * 1600, 15), tostring(area))

	area = filledArea(svg('<ellipse cx="50" cy="50" rx="40" ry="20"/>'))
	check("ellipse area", near(area, math.pi * 800, 10), tostring(area))

	area = filledArea(svg('<rect width="40" height="20" rx="5"/>'))
	check("rounded rect area", near(area, 800 - (4 - math.pi) * 25, 1), tostring(area))

	-- Ring donut with an island in the middle (outer > hole > island).
	local donut = '<path fill-rule="evenodd" d="M0 0H90V90H0Z M10 10H80V80H10Z M30 30H60V60H30Z"/>'
	area = filledArea(svg(donut))
	check("nested island", near(area, 8100 - 4900 + 900, 1e-6), tostring(area))

	area = filledArea(svg('<polygon points="0,0 50,0 50,50 25,10 0,50"/>'))
	local _, expected = filledArea(svg('<polygon points="0,0 50,0 50,50 25,10 0,50"/>'))
	check("concave polygon", near(area, expected, 1e-6), ("%g vs %g"):format(area, expected))
end

print("Path commands")
do
	-- Same square written with relative commands, H/V and implicit lineto.
	local area = filledArea(svg('<path d="m10,10 h30 v30 h-30 z"/>'))
	check("relative h/v", near(area, 900, 1e-6), tostring(area))
	area = filledArea(svg('<path d="M10 10 40 10 40 40 10 40Z"/>'))
	check("implicit lineto after M", near(area, 900, 1e-6), tostring(area))
	area = filledArea(svg('<path d="M10-10L40-10 40,20 10,20z"/>'))
	check("packed negatives", near(area, 900, 1e-6), tostring(area))

	-- Circle made from two arcs with packed flags.
	area = filledArea(svg('<path d="M10 50a40 40 0 1 0 80 0a40 40 0 1 0-80 0z"/>'))
	check("arcs with packed flags", near(area, math.pi * 1600, 15), tostring(area))

	-- Quarter circle from a cubic (classic kappa approximation).
	local k = 0.5522847498 * 50
	area = filledArea(svg(("<path d='M0 0 H50 C50 %g %g 50 0 50 Z'/>"):format(k, k)))
	check("cubic curve", near(area, math.pi * 2500 / 4, 3), tostring(area))

	-- Smooth cubic S reflection: a symmetric S-curve closes back to a shape with known area.
	area = filledArea(svg('<path d="M0 0 C0 20 40 20 40 0 S80 -20 80 0 V40 H0 Z"/>'))
	check("S command parses", area > 3000 and area < 3400, tostring(area))

	area = filledArea(svg('<path d="M0 0 Q20 40 40 0 T80 0 V40 H0Z"/>'))
	check("Q/T commands parse", area > 2900 and area < 3500, tostring(area))

	local doc = SvgDocument.load(svg('<path d="M0 0 L10 0 L10 10 Z oops 5 5"/>'), 0.001)
	check("malformed tail keeps earlier shape", #doc.shapes == 1)
end

print("Styles, transforms and references")
do
	local doc = SvgDocument.load(svg([[
		<defs><style>.a{fill:#ED1C24;} .b{fill:none;stroke:#000} #c{fill:rgb(0,128,255)}</style></defs>
		<rect class="a" width="10" height="10"/>
		<rect class="b" width="10" height="10"/>
		<rect id="c" width="10" height="10" fill="red"/>
		<g fill="#0f0" opacity="0.5"><rect width="10" height="10" style="fill-opacity:.5"/></g>
		<rect width="10" height="10" fill="url(#grad)"/>
		<linearGradient id="grad"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
		<text>hello</text>
	]]), 0.001)
	check("class fill", #doc.shapes == 4 and near(doc.shapes[1].color[1], 0xED / 255, 1e-6))
	check("id rule beats attribute", near(doc.shapes[2].color[3], 1, 1e-6) and near(doc.shapes[2].color[2], 128 / 255, 1e-6))
	check("group fill inherited", near(doc.shapes[3].color[2], 1, 1e-6))
	check("opacity multiplies", near(doc.shapes[3].alpha, 0.25, 1e-6), tostring(doc.shapes[3].alpha))
	check("gradient averaged", near(doc.shapes[4].color[1], 0.5, 1e-6))
	local joined = table.concat(doc.warnings, "\n")
	check("stroke warning", joined:find("Strokes") ~= nil)
	check("text warning", joined:find("Text is skipped") ~= nil)

	doc = SvgDocument.load(svg('<g transform="translate(100 0) scale(2)"><rect width="10" height="10"/></g>'), 0.001)
	local xs = {}
	for _, p in doc.shapes[1].rings[1] do
		table.insert(xs, p[1])
	end
	check("transform applied", math.min(table.unpack(xs)) == 100 and math.max(table.unpack(xs)) == 120)

	doc = SvgDocument.load(svg('<defs><path id="p" d="M0 0H10V10H0Z"/></defs><use href="#p" x="5"/><use xlink:href="#p" y="5"/>'), 0.001)
	check("use references", #doc.shapes == 2)

	doc = SvgDocument.load([[<?xml version="1.0"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "x" [ <!ENTITY ns_svg "http://www.w3.org/2000/svg"> ]>
<!-- comment -->
<svg:svg xmlns:svg="&ns_svg;" width="100px" height="50px"><svg:rect width="10" height="10" fill="#abc"/></svg:svg>]], 0.001)
	check("doctype, entities, prefixes", #doc.shapes == 1 and doc.size == 100)

	doc = SvgDocument.load('<svg><rect width="10" height="10" display="none"/><g visibility="hidden"><rect width="5" height="5"/></g><rect width="3" height="3" fill="hsl(120, 100%, 50%)"/></svg>', 0.001)
	check("display none / hidden / hsl", #doc.shapes == 1 and near(doc.shapes[1].color[2], 1, 1e-6))
end

print("Mesh builder")
do
	local doc = SvgDocument.load(svg('<path fill-rule="evenodd" d="M0 0 H40 V40 H0 Z M10 10 H30 V30 H10 Z" fill="#f00"/><rect x="50" width="10" height="40" fill="#00f"/>'), 0.001)
	local built = MeshBuilder.build(doc.shapes, { width = 10, thickness = 1, layerGap = 0.01 })
	check("two color groups", #built.meshes == 2)
	-- Square with hole: 8 cap triangles per side, 4+4 wall quads.
	local red = built.meshes[1]
	check("hole mesh triangle count", #red.tris == 8 * 2 + 8 * 2, tostring(#red.tris))
	check("width scaled", near(built.width, 10, 1e-9), tostring(built.width))
	check("depth is thickness", near(red.size[3], 1, 1e-9), tostring(red.size[3]))

	-- Every wall and cap triangle must face away from the solid: check via divergence theorem (volume > 0).
	local function volume(mesh)
		local v = 0
		for _, t in mesh.tris do
			local a, b, c = mesh.positions[t[1]], mesh.positions[t[2]], mesh.positions[t[3]]
			v += (a[1] * (b[2] * c[3] - b[3] * c[2]) - a[2] * (b[1] * c[3] - b[3] * c[1]) + a[3] * (b[1] * c[2] - b[2] * c[1])) / 6
		end
		return v
	end
	local s = 10 / 60
	-- EditableMesh treats counter-clockwise as front-facing, i.e. outward normals give positive volume.
	check("red mesh is a closed, outward-facing solid", near(volume(red), 1200 * s * s * 1, 1e-6), tostring(volume(red)))
	check("blue mesh volume", near(volume(built.meshes[2]), 400 * s * s, 1e-6), tostring(volume(built.meshes[2])))

	-- Readable from the front (-Z): SVG x=0 (left) should land on +X in model space.
	local blue = built.meshes[2]
	check("svg right side maps to -X", blue.center[1] < 0, tostring(blue.center[1]))

	-- Overlapping shapes stack forward.
	doc = SvgDocument.load(svg('<rect width="50" height="50" fill="#fff"/><rect x="10" y="10" width="10" height="10" fill="#000"/>'), 0.001)
	built = MeshBuilder.build(doc.shapes, { width = 10, thickness = 0.5, layerGap = 0.05 })
	check("top layer sticks out further", built.meshes[2].size[3] > built.meshes[1].size[3])

	-- Chunking under the triangle limit.
	local rects = {}
	for k = 0, 99 do
		table.insert(rects, ('<rect x="%d" y="%d" width="0.5" height="0.5"/>'):format(k % 10, k // 10))
	end
	doc = SvgDocument.load(svg(table.concat(rects)), 0.001)
	built = MeshBuilder.build(doc.shapes, { width = 10, thickness = 0.5, layerGap = 0, maxTriangles = 500 })
	check("splits into chunks", #built.meshes == 3, tostring(#built.meshes))
	for _, m in built.meshes do
		check("chunk under limit " .. m.name, #m.tris <= 500, tostring(#m.tris))
	end

	-- Flat mode: zero thickness gives two caps and no walls.
	doc = SvgDocument.load(svg('<rect width="10" height="10"/>'), 0.001)
	built = MeshBuilder.build(doc.shapes, { width = 10, thickness = 0, layerGap = 0 })
	check("flat plate", #built.meshes[1].tris == 4, tostring(#built.meshes[1].tris))
end

print("Sample files")
do
	local dir = "tests/samples"
	if fs.isDir(dir) then
		for _, name in fs.readDir(dir) do
			if name:match("%.svg$") then
				local source = fs.readFile(dir .. "/" .. name)
				local t0 = os.clock()
				local ok, err = pcall(function()
					local area, expected, doc = filledArea(source, 0.0015)
					local built = MeshBuilder.build(doc.shapes, { width = 10, thickness = 0.5, layerGap = 0.01 })
					local relErr = if expected > 0 then math.abs(area - expected) / expected else 0
					check(
						("%s: %d shapes -> %d parts, %d tris, area err %.4f%%, %.2fs"):format(name, #doc.shapes, #built.meshes, built.triangles, relErr * 100, os.clock() - t0),
						relErr < 0.001
					)
					for _, w in doc.warnings do
						print("         warning: " .. w)
					end
				end)
				if not ok then
					check(name, false, tostring(err))
				end
			end
		end
	end
end

print(if failures == 0 then "\nAll tests passed." else ("\n%d test(s) failed."):format(failures))
process.exit(if failures == 0 then 0 else 1)
