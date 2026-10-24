--!strict
-- Static scan of a Roblox model or place file for backdoor patterns. Run it through
-- scan-model.sh, which finds Lune and checks the arguments:
--   lune run scan-model.luau FILE table|json MAX_LINE
-- It only reads the file: no script in the model is ever run. The patterns and their false
-- positives are described in references/safety.md.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

type Finding = {
	severity: string,
	rule: string,
	script: string,
	class: string,
	line: number?,
	excerpt: string?,
	message: string,
}

type ScriptInfo = {
	path: string,
	class: string,
	enabled: boolean?,
	runContext: string?,
	lines: number,
	bytes: number,
}

local path = process.args[1]
local format = process.args[2] or "table"
local maxLine = tonumber(process.args[3] or "500") or 500
-- CPU seconds the scan may take. Every pattern is linear, so a normal model needs well under a
-- second; a file built to stall scanners stops here instead of hanging.
local budget = tonumber(process.args[4] or "120") or 120
local started = os.clock()

-- Longest call argument read after a "(" (a call that does not close within it is not parsed).
local MAX_ARGUMENT = 2000

local function fail(message: string): never
	stdio.ewrite("error: " .. message .. "\n")
	return process.exit(2)
end

local function checkBudget()
	if os.clock() - started > budget then
		fail(string.format("the scan stopped after %g s of work: %s is too large or built to slow scanners down. Treat it as unsafe.", budget, path))
	end
end

if path == nil or path == "" then
	fail("usage: lune run scan-model.luau FILE [table|json] [MAX_LINE]")
end

-- Read and parse ------------------------------------------------------------------------------

local okRead, contents = pcall(fs.readFile, path)
if not okRead then
	fail("cannot read " .. path)
end

local lower = string.lower(path)
local isPlace = string.sub(lower, -5) == ".rbxl" or string.sub(lower, -6) == ".rbxlx"
local roots: { Instance } = {}
local okParse, parsed = pcall(function()
	if isPlace then
		return { roblox.deserializePlace(contents) }
	end
	return roblox.deserializeModel(contents)
end)
if not okParse then
	local firstLine = string.match(tostring(parsed), "([^\n]*%S)") or "unknown error"
	firstLine = string.gsub(firstLine, "^<LuaError%(%s*", "")
	fail(path .. " is not a readable Roblox model or place file (" .. firstLine .. ")")
end
roots = parsed

-- Helpers -------------------------------------------------------------------------------------

-- Control characters (terminal escapes among them) never reach the output.
local function printable(text: string, limit: number): string
	local s = string.gsub(text, "\t", " ")
	s = string.gsub(s, "%c", "?")
	s = string.match(s, "^%s*(.-)%s*$") or s
	if #s > limit then
		s = string.sub(s, 1, limit - 3) .. "..."
	end
	return s
end

local function quotedName(name: string): string
	return string.format("%q", name)
end

-- Text of a call's parenthesised argument starting at the "(" at index `open`, or nil when the
-- parentheses do not close on this line.
local function callArgument(line: string, open: number): string?
	local depth = 0
	for i = open, math.min(#line, open + MAX_ARGUMENT) do
		local c = string.sub(line, i, i)
		if c == "(" then
			depth += 1
		elseif c == ")" then
			depth -= 1
			if depth == 0 then
				return string.sub(line, open + 1, i - 1)
			end
		end
	end
	return nil
end

-- matchAt LINE LITERAL PATTERN: whether PATTERN (anchored, starting with LITERAL) matches at any
-- occurrence of LITERAL, looking at most WINDOW characters ahead. A pattern such as
-- "Prompt%a*Purchase" tried from every position would backtrack over long words.
local WINDOW = 120
local function matchAt(line: string, literal: string, pattern: string): boolean
	local start = 1
	while true do
		local s = string.find(line, literal, start, true)
		if s == nil then
			return false
		end
		if string.find(string.sub(line, s, s + WINDOW), pattern) then
			return true
		end
		start = s + 1
	end
end

local function withoutStrings(text: string): string
	local s = string.gsub(text, '"[^"]*"', '""')
	s = string.gsub(s, "'[^']*'", "''")
	return s
end

local function countMatches(text: string, pattern: string): number
	local n = 0
	for _ in string.gmatch(text, pattern) do
		n += 1
	end
	return n
end

-- Line rules ----------------------------------------------------------------------------------
-- Each returns a message when the line matches, or nil.

type LineRule = { rule: string, severity: string, check: (line: string, context: { [string]: any }) -> string? }

local OBFUSCATORS = { "luraph", "ironbrew", "moonsec", "prometheus obfuscator", "synapse xen" }

local lineRules: { LineRule } = {
	{
		rule = "require-id",
		severity = "high",
		check = function(line)
			local start = 1
			while true do
				local s, e = string.find(line, "%f[%w_]require%s*%(", start)
				if s == nil then
					return nil
				end
				local arg = callArgument(line, e :: number)
				if arg ~= nil then
					local bare = withoutStrings(arg)
					if string.match(arg, "^%s*%(?%s*%d") or string.match(arg, "^%s*tonumber%s*%(") then
						return "require() of an asset id loads code from the Roblox website when the game runs (the classic backdoor loader)"
					end
					if
						string.find(bare, "%.%.")
						or string.find(bare, "[%+%*/%^%%]")
						or string.find(bare, "%f[%w_]string%.")
						or string.find(bare, "%f[%w_]math%.")
						or string.find(bare, "%f[%w_]getfenv")
						or string.find(bare, "%f[%w_]tonumber")
						or string.find(arg, "^%s*[\"']%s*%d+%s*[\"']")
					then
						return "require() of a computed value hides which module (or asset id) it loads"
					end
				end
				start = (e :: number) + 1
			end
		end,
	},
	{
		rule = "require-alias",
		severity = "medium",
		check = function(line)
			if string.find(line, "=%s*require%s*$") or string.find(line, "=%s*require%s*[;,%)]") then
				return "require is stored in a variable, which hides what the script loads"
			end
			return nil
		end,
	},
	{
		rule = "getfenv",
		severity = "high",
		check = function(line)
			if string.find(line, "%f[%w_][gs]etfenv%f[^%w_]") then
				return "getfenv/setfenv rewrites a script's environment; backdoors use it to hide require and loadstring"
			end
			return nil
		end,
	},
	{
		rule = "loadstring",
		severity = "high",
		check = function(line)
			if string.find(line, "%f[%w_]loadstring%f[^%w_]") then
				return "loadstring runs code from a string (only works with LoadStringEnabled, a common backdoor request)"
			end
			return nil
		end,
	},
	{
		rule = "string-char",
		severity = "high",
		check = function(line)
			if countMatches(line, "%.char%s*%(") >= 3 then
				return "several string.char() calls build text from character codes (hidden strings)"
			end
			local start = 1
			while true do
				local _, e = string.find(line, "%.char%s*%(", start)
				if e == nil then
					return nil
				end
				local arg = callArgument(line, e) or string.sub(line, e + 1)
				if countMatches(arg, "%d+") >= 4 or string.find(arg, "unpack") then
					return "string.char() with many character codes builds hidden text"
				end
				start = e + 1
			end
		end,
	},
	{
		rule = "escape-run",
		severity = "high",
		check = function(line)
			local decimal = string.gsub(line, "\\%d%d?%d?", "\1")
			local hex = string.gsub(line, "\\[xX]%x%x", "\1")
			if string.find(decimal, "\1\1\1\1\1\1\1\1", 1, true) or string.find(hex, "\1\1\1\1\1\1\1\1", 1, true) then
				return "a long run of \\ddd or \\xHH escapes hides text from readers"
			end
			return nil
		end,
	},
	{
		rule = "string-reverse",
		severity = "high",
		check = function(line)
			if string.find(line, "%f[%w_]string%.reverse%f[^%w_]") or string.find(line, ":%s*reverse%s*%(") then
				return "string.reverse is a common decoder for hidden asset ids and URLs"
			end
			return nil
		end,
	},
	{
		rule = "obfuscator",
		severity = "high",
		check = function(line)
			local l = string.lower(line)
			for _, marker in OBFUSCATORS do
				if string.find(l, marker, 1, true) then
					return "obfuscator marker '" .. marker .. "': obfuscated code cannot be reviewed"
				end
			end
			if string.find(line, "%f[%w]PSU%f[%W]") then
				return "obfuscator marker 'PSU': obfuscated code cannot be reviewed"
			end
			return nil
		end,
	},
	{
		rule = "http",
		severity = "high",
		check = function(line, context)
			if string.find(line, "HttpGet") or string.find(line, "HttpPost") then
				return "game:HttpGet/HttpPost only exist in exploit tools; this code was not written for a normal game"
			end
			-- game:GetService("HttpService"):GetAsync(...)
			local method = string.match(line, "HttpService[\"']%s*%)%s*[:.]%s*(%a+Async)%s*%(")
			if method == "GetAsync" or method == "PostAsync" or method == "RequestAsync" then
				return "HttpService request to the internet: it can download code or send data out"
			end
			for alias in context.httpAliases do
				if
					string.find(line, alias .. "%s*[:.]%s*GetAsync%s*%(")
					or string.find(line, alias .. "%s*[:.]%s*PostAsync%s*%(")
					or string.find(line, alias .. "%s*[:.]%s*RequestAsync%s*%(")
				then
					return "HttpService request to the internet: it can download code or send data out"
				end
			end
			if context.mentionsHttp and (string.find(line, ":%s*PostAsync%s*%(") or string.find(line, ":%s*RequestAsync%s*%(")) then
				return "HttpService request to the internet: it can download code or send data out"
			end
			if string.find(line, "GetAsync%s*%(%s*[\"']https?://") then
				return "HTTP GET of a web address: it can download code"
			end
			return nil
		end,
	},
	{
		rule = "purchase-prompt",
		severity = "medium",
		check = function(line)
			if matchAt(line, "Prompt", "^Prompt%a*Purchase%s*%(") then
				return "prompts players to buy something: check that the product or game pass is yours"
			end
			return nil
		end,
	},
	{
		rule = "teleport",
		severity = "medium",
		check = function(line)
			if string.find(line, "TeleportService") then
				return "uses TeleportService: check where it sends players"
			end
			return nil
		end,
	},
	{
		rule = "insert-service",
		severity = "medium",
		check = function(line)
			if matchAt(line, "LoadAsset", "^LoadAsset%a*%s*%(") then
				return "InsertService:LoadAsset or AssetService:LoadAssetAsync loads another asset by id while the game runs"
			end
			return nil
		end,
	},
	{
		rule = "script-context",
		severity = "medium",
		check = function(line)
			if string.find(line, "ScriptContext") then
				return "uses ScriptContext, which can watch or hide script errors"
			end
			return nil
		end,
	},
}

local ODD_PARENTS = { "Sound", "Decal", "Texture", "Weld", "Attachment", "Motor6D", "ValueBase" }
local MAX_PER_RULE = 3

-- Scan ----------------------------------------------------------------------------------------

local findings: { Finding } = {}
local scripts: { ScriptInfo } = {}
local instanceCount = 0
local classCounts: { [string]: number } = {}
local sourceBytes = 0

local function add(severity: string, rule: string, inst: Instance, line: number?, excerpt: string?, message: string)
	table.insert(findings, {
		severity = severity,
		rule = rule,
		script = inst:GetFullName(),
		class = inst.ClassName,
		line = line,
		excerpt = if excerpt then printable(excerpt, 120) else nil,
		message = message,
	})
end

local function scanScript(inst: Instance)
	local source: string = (inst :: any).Source or ""
	local info: ScriptInfo = {
		path = inst:GetFullName(),
		class = inst.ClassName,
		lines = 0,
		bytes = #source,
	}
	if inst:IsA("BaseScript") then
		local ok, disabled = pcall(function()
			return (inst :: any).Disabled
		end)
		if ok then
			info.enabled = not disabled
		end
	end
	if inst.ClassName == "Script" then
		local ok, context = pcall(function()
			return (inst :: any).RunContext
		end)
		if ok and context ~= nil then
			info.runContext = context.Name
		end
	end
	sourceBytes += #source
	classCounts[inst.ClassName] = (classCounts[inst.ClassName] or 0) + 1
	local okLinked, linked = pcall(function()
		return (inst :: any).LinkedSource
	end)
	if okLinked and type(linked) == "string" and linked ~= "" then
		add("high", "linked-source", inst, nil, linked, "LinkedSource loads this script's code from another asset (" .. printable(linked, 80) .. ")")
	end

	local httpAliases: { [string]: boolean } = { HttpService = true }
	-- %f[%w_] anchors each try at the start of a word; without it a long word is matched in O(n²).
	for alias in string.gmatch(source, "%f[%w_]([%a_][%w_]*)%s*=%s*game%s*:%s*GetService%s*%(%s*[\"']HttpService[\"']%s*%)") do
		httpAliases[alias] = true
	end
	for alias in string.gmatch(source, "%f[%w_]([%a_][%w_]*)%s*=%s*game%s*%.%s*HttpService") do
		httpAliases[alias] = true
	end
	local context = { httpAliases = httpAliases, mentionsHttp = string.find(source, "HttpService") ~= nil }

	local longLines, firstLong, firstLongLength = 0, 0, 0
	local lineNumber = 0
	-- At most MAX_PER_RULE findings per rule and script; the last one says how many lines it stands for.
	local hits: { [string]: number } = {}
	local lastFinding: { [string]: Finding } = {}
	for _, raw in string.split(source, "\n") do
		lineNumber += 1
		if lineNumber % 500 == 0 then
			checkBudget()
		end
		local line = string.gsub(raw, "\r$", "")
		if #line > maxLine then
			longLines += 1
			if firstLong == 0 then
				firstLong, firstLongLength = lineNumber, #line
			end
		end
		for _, rule in lineRules do
			local message = rule.check(line, context)
			if message ~= nil then
				hits[rule.rule] = (hits[rule.rule] or 0) + 1
				if hits[rule.rule] <= MAX_PER_RULE then
					add(rule.severity, rule.rule, inst, lineNumber, line, message)
					lastFinding[rule.rule] = findings[#findings]
				end
			end
		end
	end
	for rule, n in hits do
		if n > MAX_PER_RULE then
			local f = lastFinding[rule]
			f.message ..= string.format(" (%d more line(s) in this script match)", n - MAX_PER_RULE)
		end
	end
	-- A final newline does not start another line.
	info.lines = if source == "" then 0 elseif string.sub(source, -1) == "\n" then lineNumber - 1 else lineNumber
	if longLines > 0 then
		add(
			"high",
			"long-line",
			inst,
			firstLong,
			nil,
			string.format(
				"%d line(s) longer than %d characters (the first has %d): minified or obfuscated code",
				longLines,
				maxLine,
				firstLongLength
			)
		)
	end

	local parent = inst.Parent
	if parent ~= nil then
		for _, class in ODD_PARENTS do
			if parent:IsA(class) then
				add("medium", "odd-parent", inst, nil, nil, inst.ClassName .. " hidden inside a " .. parent.ClassName .. " (" .. parent:GetFullName() .. ")")
				break
			end
		end
	end
	local name = inst.Name
	if name == "" or string.match(name, "^%s") or string.match(name, "%s$") or string.find(name, "[%c\128-\255]") then
		add("medium", "odd-name", inst, nil, nil, "script name " .. quotedName(name) .. " has leading or trailing spaces, control or non-ASCII characters (often used to look like something harmless)")
	end
	table.insert(scripts, info)
end

local function visit(inst: Instance)
	instanceCount += 1
	checkBudget()
	if inst:IsA("LuaSourceContainer") then
		scanScript(inst)
	end
end

for _, root in roots do
	if root.ClassName ~= "DataModel" then
		visit(root)
	end
	for _, d in root:GetDescendants() do
		visit(d)
	end
end

local counts = { high = 0, medium = 0 }
for _, f in findings do
	counts[f.severity] = (counts[f.severity] or 0) + 1
end
local verdict = if counts.high > 0 then "unsafe" elseif counts.medium > 0 then "review" else "clean"

-- Output --------------------------------------------------------------------------------------

local classList = {}
for class, n in classCounts do
	table.insert(classList, string.format("%d %s", n, class))
end
table.sort(classList)

if format == "json" then
	-- serde writes empty tables as {}; arrays are joined by hand so that they stay arrays.
	local function array(items: { any }): string
		local parts = {}
		for _, item in items do
			table.insert(parts, serde.encode("json", item))
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local head = serde.encode("json", {
		file = path,
		instances = instanceCount,
		sourceBytes = sourceBytes,
		verdict = verdict,
		summary = { scripts = #scripts, high = counts.high, medium = counts.medium },
	})
	print(string.sub(head, 1, -2) .. ',"scripts":' .. array(scripts) .. ',"findings":' .. array(findings) .. "}")
else
	print(
		string.format(
			"%s: %d instances, %d script(s)%s, %d bytes of source",
			path,
			instanceCount,
			#scripts,
			if #classList > 0 then " (" .. table.concat(classList, ", ") .. ")" else "",
			sourceBytes
		)
	)
	if #scripts > 0 then
		print("")
		print(string.format("  %-13s %-8s %-7s %6s %7s  %s", "CLASS", "ENABLED", "RUNS", "LINES", "BYTES", "PATH"))
		for _, s in scripts do
			local enabled = if s.enabled == nil then "-" elseif s.enabled then "yes" else "no"
			print(string.format("  %-13s %-8s %-7s %6d %7d  %s", s.class, enabled, s.runContext or "-", s.lines, s.bytes, printable(s.path, 200)))
		end
	end
	print("")
	if #findings == 0 then
		print("No suspicious patterns found.")
	else
		print(string.format("Findings: %d high, %d medium", counts.high, counts.medium))
		for _, severity in { "high", "medium" } do
			for _, f in findings do
				if f.severity == severity then
					local where = printable(f.script, 120) .. (if f.line then ":" .. f.line else "")
					print(string.format("  %-6s %-15s %s", string.upper(f.severity), f.rule, where))
					print("         " .. f.message)
					if f.excerpt and f.excerpt ~= "" then
						print("         > " .. f.excerpt)
					end
				end
			end
		end
	end
	print("")
	if verdict == "unsafe" then
		print("Verdict: unsafe. Do not play-test or publish this model as it is; delete the flagged scripts (or the model).")
	elseif verdict == "review" then
		print("Verdict: review. Read the flagged scripts before using the model; delete scripts it does not need.")
	elseif #scripts > 0 then
		print("Verdict: clean scan. A scan cannot prove scripts are safe: read them, and delete any the model does not need.")
	else
		print("Verdict: clean. The model has no scripts.")
	end
end

process.exit(if verdict == "clean" then 0 else 1)
