-- Minimal XML parser: enough for SVG files exported by Illustrator, Inkscape, Figma and Affinity.
-- Handles comments, CDATA, processing instructions and DOCTYPEs with internal subsets.

local Xml = {}

export type Node = {
	tag: string,
	attrs: { [string]: string },
	children: { Node },
	text: string,
}

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function decodeEntities(s: string): string
	return (s:gsub("&(#?x?)(%w+);", function(prefix, body)
		local code
		if prefix == "#" then
			code = tonumber(body)
		elseif prefix == "#x" then
			code = tonumber(body, 16)
		elseif prefix == "" then
			return ENTITIES[body]
		end
		if code and code >= 0 and code <= 0x10FFFF then
			return utf8.char(code)
		end
		return nil
	end))
end

-- "svg:path" -> "path"
local function localName(name: string): string
	return name:match(":([^:]+)$") or name
end

function Xml.parse(src: string): Node
	if src:sub(1, 3) == "\239\187\191" then
		src = src:sub(4)
	end

	local root: Node = { tag = "#document", attrs = {}, children = {}, text = "" }
	local stack = { root }
	local pos = 1
	local len = #src

	while pos <= len do
		local top = stack[#stack]
		local lt = src:find("<", pos, true)
		if not lt then
			top.text ..= decodeEntities(src:sub(pos))
			break
		end
		if lt > pos then
			top.text ..= decodeEntities(src:sub(pos, lt - 1))
		end

		if src:sub(lt, lt + 3) == "<!--" then
			local e = src:find("-->", lt + 4, true)
			pos = if e then e + 3 else len + 1
		elseif src:sub(lt, lt + 8) == "<![CDATA[" then
			-- Built from pieces: a literal CDATA terminator breaks the plugin's .rbxmx encoding.
			local e = src:find("]]" .. ">", lt + 9, true)
			top.text ..= src:sub(lt + 9, (e or len + 1) - 1)
			pos = if e then e + 3 else len + 1
		elseif src:sub(lt, lt + 1) == "<?" then
			local e = src:find("?>", lt + 2, true)
			pos = if e then e + 2 else len + 1
		elseif src:sub(lt, lt + 1) == "<!" then
			-- DOCTYPE, possibly with an internal [ ... ] subset (Illustrator uses one for entity namespaces)
			local i = lt + 2
			local depth = 0
			while i <= len do
				local c = src:sub(i, i)
				if c == "[" then
					depth += 1
				elseif c == "]" then
					depth -= 1
				elseif c == ">" and depth <= 0 then
					break
				end
				i += 1
			end
			pos = i + 1
		elseif src:sub(lt, lt + 1) == "</" then
			local e = src:find(">", lt + 2, true) or len
			local name = src:sub(lt + 2, e - 1):match("^%s*([^%s>]+)")
			if name then
				name = localName(name)
				-- Pop back to the matching open tag; tolerates sloppy nesting.
				for i = #stack, 2, -1 do
					if stack[i].tag == name then
						for _ = #stack, i, -1 do
							table.remove(stack)
						end
						break
					end
				end
			end
			pos = e + 1
		else
			local _, nameEnd, name = src:find("^([%w_:%.%-]+)", lt + 1)
			if not name then
				top.text ..= "<"
				pos = lt + 1
			else
				local node: Node = { tag = localName(name), attrs = {}, children = {}, text = "" }
				local i = nameEnd + 1
				local selfClosing = false
				while i <= len do
					local _, wsEnd = src:find("^%s*", i)
					i = wsEnd + 1
					local c = src:sub(i, i)
					if c == "" then
						break
					elseif c == ">" then
						i += 1
						break
					elseif src:sub(i, i + 1) == "/>" then
						selfClosing = true
						i += 2
						break
					end
					local _, attrEnd, attrName = src:find("^([^%s=/>]+)", i)
					if not attrName then
						i += 1
						continue
					end
					i = attrEnd + 1
					local _, eqEnd = src:find("^%s*=%s*", i)
					if eqEnd then
						i = eqEnd + 1
						local quote = src:sub(i, i)
						local value
						if quote == '"' or quote == "'" then
							local close = src:find(quote, i + 1, true) or len + 1
							value = src:sub(i + 1, close - 1)
							i = close + 1
						else
							local _, valueEnd, v = src:find("^([^%s>]*)", i)
							value = v
							i = valueEnd + 1
						end
						node.attrs[attrName] = decodeEntities(value)
					else
						node.attrs[attrName] = ""
					end
				end
				table.insert(top.children, node)
				if not selfClosing then
					table.insert(stack, node)
				end
				pos = i
			end
		end
	end

	return root
end

-- Depth-first search for the first element with the given tag.
function Xml.findFirst(node: Node, tag: string): Node?
	if node.tag == tag then
		return node
	end
	for _, child in node.children do
		local found = Xml.findFirst(child, tag)
		if found then
			return found
		end
	end
	return nil
end

function Xml.walk(node: Node, visit: (Node) -> ())
	visit(node)
	for _, child in node.children do
		Xml.walk(child, visit)
	end
end

return Xml
