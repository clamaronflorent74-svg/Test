--!strict
-- ============================================================
--   SolaraSaveInstance
--   Usage dans Solara :
--     local ssi = loadstring(game:HttpGet("URL/saveinstance.luau"))()
--     ssi({ SafeMode = true })
--     ssi({ Mode = "Full", FilePath = "myjeu" })
-- ============================================================

-- ============================================================
-- TYPES
-- ============================================================

type Options = {
	FilePath: string,
	SafeMode: boolean,
	IgnoreDefaultProps: boolean,
	SaveBytecode: boolean,
	DecompileTimeout: number,
	SavePlayers: boolean,
	IsolatePlayers: boolean,
	AlternativeWritefile: boolean,
	IgnoreDefaultPlayerScripts: boolean,
	UseSharedStrings: boolean,
	TreatUnionsAsParts: boolean,
	NilInstances: boolean,
	IgnoreNotArchivable: boolean,
	Mode: string,
	Object: Instance,
	ExtraInstances: {Instance},
	IsModel: boolean,
}

-- ============================================================
-- OPTIONS PAR DÉFAUT
-- ============================================================

local DEFAULT_OPTIONS = {
	FilePath               = "game",
	SafeMode               = false,
	IgnoreDefaultProps     = true,
	SaveBytecode           = false,
	DecompileTimeout       = 10,
	SavePlayers            = false,
	IsolatePlayers         = false,
	AlternativeWritefile   = true,
	IgnoreDefaultPlayerScripts = true,
	UseSharedStrings       = false,
	TreatUnionsAsParts     = false,
	NilInstances           = false,
	IgnoreNotArchivable    = true,
	Mode                   = "Default",
	Object                 = game,
	ExtraInstances         = {},
	IsModel                = false,
}

local ALIASES = {
	timeout                 = "DecompileTimeout",
	FileName                = "FilePath",
	IgnoreDefaultProperties = "IgnoreDefaultProps",
	SaveNonCreatable        = "SaveNotCreatable",
	scriptcache             = "DecompileJobless",
	IgnoreArchivable        = "IgnoreNotArchivable",
}

local function mergeOptions(user: {[string]: any}?): typeof(DEFAULT_OPTIONS)
	local opts = {}
	for k, v in pairs(DEFAULT_OPTIONS) do opts[k] = v end
	if user then
		for alias, canonical in pairs(ALIASES) do
			if user[alias] ~= nil then user[canonical] = user[alias] end
		end
		for k, v in pairs(user) do
			if opts[k] ~= nil then opts[k] = v end
		end
	end
	return opts
end

-- ============================================================
-- DÉTECTION DES API DISPONIBLES (Solara)
-- ============================================================

local HAS_GETHIDDENPROPERTY = false
local HAS_DECOMPILE         = false
local HAS_GETBYTECODE       = false
local HAS_WRITEFILE         = false
local HAS_APPENDFILE        = false

do
	HAS_WRITEFILE  = type(writefile)  == "function"
	HAS_APPENDFILE = type(appendfile) == "function"

	if type(gethiddenproperty) == "function" then
		local ok, result = pcall(gethiddenproperty, workspace, "StreamOutBehavior")
		if ok and typeof(result) == "EnumItem" then
			HAS_GETHIDDENPROPERTY = true
		end
	end

	if type(decompile) == "function" then
		HAS_DECOMPILE = true
	end

	if type(getscriptbytecode) == "function" then
		HAS_GETBYTECODE = true
	end

	print(string.format(
		"[SSI] Executor capabilities: writefile=%s appendfile=%s gethiddenproperty=%s decompile=%s getbytecode=%s",
		tostring(HAS_WRITEFILE), tostring(HAS_APPENDFILE),
		tostring(HAS_GETHIDDENPROPERTY), tostring(HAS_DECOMPILE), tostring(HAS_GETBYTECODE)
	))
end

-- ============================================================
-- BASE64
-- ============================================================

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function encodeBase64(s: string): string
	local result = {}
	local padding = 0

	for i = 1, #s, 3 do
		local b1 = string.byte(s, i) or 0
		local b2 = string.byte(s, i + 1)
		local b3 = string.byte(s, i + 2)

		if not b2 then padding = 2; b2 = 0; b3 = 0
		elseif not b3 then padding = 1; b3 = 0 end

		local n = bit32.bor(
			bit32.lshift(b1, 16),
			bit32.lshift(b2, 8),
			b3
		)

		local c1 = bit32.rshift(n, 18) % 64 + 1
		local c2 = bit32.rshift(n, 12) % 64 + 1
		local c3 = bit32.rshift(n,  6) % 64 + 1
		local c4 = n % 64 + 1

		table.insert(result, B64_CHARS:sub(c1, c1))
		table.insert(result, B64_CHARS:sub(c2, c2))
		table.insert(result, padding >= 2 and "=" or B64_CHARS:sub(c3, c3))
		table.insert(result, padding >= 1 and "=" or B64_CHARS:sub(c4, c4))

		if padding > 0 then break end
	end

	return table.concat(result)
end

-- ============================================================
-- ESCAPE XML
-- ============================================================

local function escapeXml(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- ============================================================
-- CHARGEMENT API DUMP ROBLOX
-- ============================================================

local ClassProperties: {[string]: {[string]: string}} = {}
local ClassInheritance: {[string]: string} = {}

local function loadApiDump()
	local ok, raw = pcall(function()
		return game:HttpGet(
			"https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/Mini-API-Dump.json",
			true
		)
	end)
	if not ok or not raw then
		warn("[SSI] Impossible de charger l'API Dump. Mode dégradé activé.")
		return
	end

	local decoded
	ok, decoded = pcall(function()
		return game:GetService("HttpService"):JSONDecode(raw)
	end)
	if not ok then
		warn("[SSI] Erreur parsing API Dump : " .. tostring(decoded))
		return
	end

	local PROP_BLACKLIST: {[string]: boolean} = {
		UniqueId = true, HistoryId = true, ScriptGuid = true,
	}

	for _, class in ipairs(decoded.Classes) do
		local cn = class.Name
		ClassProperties[cn] = {}

		if class.Superclass and class.Superclass ~= "<<<ROOT>>>" then
			ClassInheritance[cn] = class.Superclass
		end

		for _, member in ipairs(class.Members) do
			if member.MemberType ~= "Property" then continue end

			local name = member.Name
			if PROP_BLACKLIST[name] then continue end

			local skip = false
			if member.Tags then
				for _, tag in ipairs(member.Tags) do
					if tag == "NotScriptable" and not HAS_GETHIDDENPROPERTY then skip = true end
					if tag == "Deprecated" then skip = true end
					if tag == "ReadOnly" then skip = true end
				end
			end
			if skip then continue end

			local valueType = "string"
			if member.ValueType then
				valueType = member.ValueType.Name
			end

			ClassProperties[cn][name] = valueType
		end
	end

	local count = 0
	for _ in pairs(ClassProperties) do count += 1 end
	print("[SSI] API Dump chargé : " .. count .. " classes")
end

-- Récupère toutes les propriétés d'une classe (héritage inclus)
local function getAllProps(className: string): {[string]: string}
	local result: {[string]: string} = {}
	local current: string? = className
	while current do
		local props = ClassProperties[current]
		if props then
			for k, v in pairs(props) do
				if not result[k] then result[k] = v end
			end
		end
		current = ClassInheritance[current]
	end
	return result
end

-- ============================================================
-- REFERENTS (IDs uniques)
-- ============================================================

local referentMap: {[Instance]: string} = {}
local referentCounter = 0

local function getReferent(inst: Instance): string
	if not referentMap[inst] then
		referentCounter += 1
		referentMap[inst] = string.format("RBX%08X", referentCounter)
	end
	return referentMap[inst]
end

-- ============================================================
-- SHARED STRINGS
-- ============================================================

local sharedStringsMap: {[string]: string} = {}
local sharedStringsIdx = 0

local function getSharedKey(base64: string): string
	if not sharedStringsMap[base64] then
		sharedStringsIdx += 1
		sharedStringsMap[base64] = string.format("%032d", sharedStringsIdx)
	end
	return sharedStringsMap[base64]
end

-- ============================================================
-- SÉRIALISEURS PAR TYPE
-- ============================================================

type Serializer = (name: string, value: any) -> string

local SER: {[string]: Serializer} = {}

SER["string"] = function(n, v)
	return string.format('<string name="%s"><![CDATA[%s]]></string>', n, tostring(v))
end
SER["String"] = SER["string"]

SER["bool"] = function(n, v)
	return string.format('<bool name="%s">%s</bool>', n, v and "true" or "false")
end

SER["int"] = function(n, v)
	return string.format('<int name="%s">%d</int>', n, math.floor(tonumber(v) or 0))
end

SER["int64"] = function(n, v)
	return string.format('<int64 name="%s">%d</int64>', n, math.floor(tonumber(v) or 0))
end

SER["float"] = function(n, v)
	return string.format('<float name="%s">%g</float>', n, tonumber(v) or 0)
end

SER["double"] = function(n, v)
	return string.format('<double name="%s">%g</double>', n, tonumber(v) or 0)
end

SER["Vector2"] = function(n, v)
	return string.format('<Vector2 name="%s"><X>%g</X><Y>%g</Y></Vector2>', n, v.X, v.Y)
end
SER["Vector2int16"] = SER["Vector2"]

SER["Vector3"] = function(n, v)
	return string.format(
		'<Vector3 name="%s"><X>%g</X><Y>%g</Y><Z>%g</Z></Vector3>',
		n, v.X, v.Y, v.Z
	)
end
SER["Vector3int16"] = SER["Vector3"]

SER["CFrame"] = function(n, v)
	local xv, yv, zv = v.XVector, v.YVector, v.ZVector
	local p = v.Position
	return string.format(
		'<CoordinateFrame name="%s">'..
		'<X>%g</X><Y>%g</Y><Z>%g</Z>'..
		'<R00>%g</R00><R01>%g</R01><R02>%g</R02>'..
		'<R10>%g</R10><R11>%g</R11><R12>%g</R12>'..
		'<R20>%g</R20><R21>%g</R21><R22>%g</R22>'..
		'</CoordinateFrame>',
		n,
		p.X, p.Y, p.Z,
		xv.X, xv.Y, xv.Z,
		yv.X, yv.Y, yv.Z,
		zv.X, zv.Y, zv.Z
	)
end

SER["Color3"] = function(n, v)
	local packed = 0xFF000000 +
		bit32.lshift(math.clamp(math.floor(v.R * 255), 0, 255), 16) +
		bit32.lshift(math.clamp(math.floor(v.G * 255), 0, 255), 8) +
		math.clamp(math.floor(v.B * 255), 0, 255)
	return string.format('<Color3 name="%s">%u</Color3>', n, packed)
end
SER["Color3uint8"] = SER["Color3"]

SER["BrickColor"] = function(n, v)
	return string.format('<BrickColor name="%s">%d</BrickColor>', n, v.Number)
end

SER["token"] = function(n, v)
	return string.format('<token name="%s">%d</token>', n, v.Value)
end
SER["EnumItem"] = SER["token"]

SER["UDim"] = function(n, v)
	return string.format('<UDim name="%s"><S>%g</S><O>%d</O></UDim>', n, v.Scale, v.Offset)
end

SER["UDim2"] = function(n, v)
	return string.format(
		'<UDim2 name="%s"><XS>%g</XS><XO>%d</XO><YS>%g</YS><YO>%d</YO></UDim2>',
		n, v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset
	)
end

SER["Rect"] = function(n, v)
	return string.format(
		'<Rect2D name="%s"><min><X>%g</X><Y>%g</Y></min><max><X>%g</X><Y>%g</Y></max></Rect2D>',
		n, v.Min.X, v.Min.Y, v.Max.X, v.Max.Y
	)
end

SER["NumberRange"] = function(n, v)
	return string.format('<NumberRange name="%s">%g %g </NumberRange>', n, v.Min, v.Max)
end

SER["NumberSequence"] = function(n, v)
	local parts = {}
	for _, kp in ipairs(v.Keypoints) do
		table.insert(parts, string.format("%g %g %g ", kp.Time, kp.Value, kp.Envelope))
	end
	return string.format('<NumberSequence name="%s">%s</NumberSequence>', n, table.concat(parts))
end

SER["ColorSequence"] = function(n, v)
	local parts = {}
	for _, kp in ipairs(v.Keypoints) do
		table.insert(parts, string.format("%g %g %g %g 0 ",
			kp.Time, kp.Value.R, kp.Value.G, kp.Value.B))
	end
	return string.format('<ColorSequence name="%s">%s</ColorSequence>', n, table.concat(parts))
end

SER["Faces"] = function(n, v)
	local bits = 0
	if v.Top    then bits += 1  end
	if v.Bottom then bits += 2  end
	if v.Left   then bits += 4  end
	if v.Right  then bits += 8  end
	if v.Front  then bits += 16 end
	if v.Back   then bits += 32 end
	return string.format('<Faces name="%s"><faces>%d</faces></Faces>', n, bits)
end

SER["Axes"] = function(n, v)
	local bits = 0
	if v.X then bits += 1 end
	if v.Y then bits += 2 end
	if v.Z then bits += 4 end
	return string.format('<Axes name="%s"><axes>%d</axes></Axes>', n, bits)
end

SER["PhysicalProperties"] = function(n, v)
	if not v then
		return string.format(
			'<PhysicalProperties name="%s"><CustomPhysics>false</CustomPhysics></PhysicalProperties>', n)
	end
	return string.format(
		'<PhysicalProperties name="%s"><CustomPhysics>true</CustomPhysics>'..
		'<Density>%g</Density><Friction>%g</Friction><Elasticity>%g</Elasticity>'..
		'<FrictionWeight>%g</FrictionWeight><ElasticityWeight>%g</ElasticityWeight>'..
		'</PhysicalProperties>',
		n, v.Density, v.Friction, v.Elasticity, v.FrictionWeight, v.ElasticityWeight
	)
end

SER["BinaryString"] = function(n, v)
	return string.format('<BinaryString name="%s">%s</BinaryString>', n, encodeBase64(tostring(v)))
end

SER["Content"] = function(n, v)
	return string.format('<Content name="%s"><url>%s</url></Content>', n, escapeXml(tostring(v)))
end
SER["ContentId"] = SER["Content"]

SER["Ray"] = function(n, v)
	return string.format(
		'<Ray name="%s"><origin><X>%g</X><Y>%g</Y><Z>%g</Z></origin>'..
		'<direction><X>%g</X><Y>%g</Y><Z>%g</Z></direction></Ray>',
		n,
		v.Origin.X, v.Origin.Y, v.Origin.Z,
		v.Direction.X, v.Direction.Y, v.Direction.Z
	)
end

-- ============================================================
-- DÉCOMPILATION
-- ============================================================

local function decompileScript(inst: Instance, opts: typeof(DEFAULT_OPTIONS)): string
	-- 1. Lecture directe du Source (fonctionne si c'est ton jeu)
	local ok, src = pcall(function() return (inst :: any).Source end)
	if ok and type(src) == "string" and #src > 0 then
		return src
	end

	-- 2. decompile() Solara avec timeout
	if HAS_DECOMPILE then
		local result = "-- Decompile timed out"
		local done = false
		task.spawn(function()
			local ok2, out = pcall(decompile :: any, inst)
			result = (ok2 and type(out) == "string" and #out > 0) and out or "-- Decompile failed"
			done = true
		end)
		local t0 = os.clock()
		while not done and (os.clock() - t0) < opts.DecompileTimeout do
			task.wait(0.05)
		end
		return result
	end

	-- 3. Bytecode brut
	if HAS_GETBYTECODE and opts.SaveBytecode then
		local ok3, bc = pcall(getscriptbytecode :: any, inst)
		if ok3 and type(bc) == "string" and #bc > 0 then
			return "-- [Bytecode]\n--[[\n" .. encodeBase64(bc) .. "\n]]"
		end
	end

	return "-- Source unavailable"
end

-- ============================================================
-- LECTURE DE PROPRIÉTÉ
-- ============================================================

local function readProp(inst: Instance, propName: string): (boolean, any)
	if HAS_GETHIDDENPROPERTY then
		local ok, val = pcall(gethiddenproperty :: any, inst, propName)
		if ok then return true, val end
	end
	return pcall(function() return (inst :: any)[propName] end)
end

-- ============================================================
-- SÉRIALISATION D'UNE INSTANCE
-- ============================================================

local SCRIPT_CLASSES: {[string]: boolean} = {
	Script = true, LocalScript = true, ModuleScript = true,
}

local function serializeInstance(inst: Instance, buf: {string}, opts: typeof(DEFAULT_OPTIONS))
	-- Filtres
	if opts.IgnoreNotArchivable and not inst.Archivable then return end

	if not opts.SavePlayers then
		local ok, isP = pcall(function() return inst:IsA("Player") end)
		if ok and isP then return end
	end

	if opts.IgnoreDefaultPlayerScripts then
		local n = inst.Name
		if n == "PlayerModule" or n == "RbxCharacterSounds" then return end
	end

	local className = inst.ClassName
	if opts.TreatUnionsAsParts and className == "UnionOperation" then
		className = "Part"
	end

	local referent = getReferent(inst)
	table.insert(buf, string.format('<Item class="%s" referent="%s">', className, referent))
	table.insert(buf, '<Properties>')

	-- Name (toujours en premier)
	table.insert(buf, string.format('<string name="Name"><![CDATA[%s]]></string>', escapeXml(inst.Name)))

	-- Toutes les propriétés de la classe
	local props = getAllProps(className)

	for propName, valueType in pairs(props) do
		if propName == "Name" then continue end

		-- Source des scripts : traitement spécial
		if propName == "Source" and SCRIPT_CLASSES[className] then
			local source = decompileScript(inst, opts)
			table.insert(buf, string.format(
				'<ProtectedString name="Source"><![CDATA[%s]]></ProtectedString>',
				source
			))
			continue
		end

		local ok, value = readProp(inst, propName)
		if not ok or value == nil then continue end

		-- Skip valeurs par défaut évidentes
		if opts.IgnoreDefaultProps then
			if value == false and valueType == "bool" then continue end
			if value == "" and (valueType == "string" or valueType == "String") then continue end
			if value == 0 and (valueType == "int" or valueType == "float" or valueType == "double") then continue end
		end

		local line: string?

		-- Référence Instance
		if typeof(value) == "Instance" then
			line = string.format('<Ref name="%s">%s</Ref>', propName, getReferent(value))

		-- SharedString (BinaryString dédupliqué)
		elseif valueType == "BinaryString" and opts.UseSharedStrings then
			local encoded = encodeBase64(tostring(value))
			local key = getSharedKey(encoded)
			line = string.format('<SharedString name="%s">%s</SharedString>', propName, key)

		-- Sérialiseur standard
		elseif SER[valueType] then
			local ok2, result = pcall(SER[valueType], propName, value)
			if ok2 then line = result end

		-- Fallback générique
		else
			local ok3, str = pcall(tostring, value)
			if ok3 then
				line = string.format('<string name="%s"><![CDATA[%s]]></string>', propName, str)
			end
		end

		if line then
			table.insert(buf, line)
		end
	end

	table.insert(buf, '</Properties>')

	-- Enfants
	local ok, children = pcall(function() return inst:GetChildren() end)
	if ok then
		for _, child in ipairs(children) do
			serializeInstance(child, buf, opts)
		end
	end

	table.insert(buf, '</Item>')
end

-- ============================================================
-- CONSTRUCTION XML
-- ============================================================

local function buildXml(opts: typeof(DEFAULT_OPTIONS)): string
	local buf: {string} = {}

	table.insert(buf, '<!-- Saved by SolaraSaveInstance -->')
	table.insert(buf, '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '..
		'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '..
		'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">')
	table.insert(buf, '<Meta name="ExplicitAutoJoints">true</Meta>')
	table.insert(buf, '<External></External>')
	table.insert(buf, '<External>null</External>')

	-- Sélection des racines selon le Mode
	local roots: {Instance} = {}

	if opts.Mode == "Optimized" then
		local SERVICES = {
			"Workspace", "ReplicatedStorage", "ReplicatedFirst",
			"StarterGui", "StarterPack", "StarterPlayer",
			"Teams", "SoundService", "Lighting", "Chat",
		}
		for _, svc in ipairs(SERVICES) do
			local ok, s = pcall(function() return (game :: any):GetService(svc) end)
			if ok and s then table.insert(roots, s) end
		end
	else
		-- Default / Full : game entier
		table.insert(roots, opts.Object)
	end

	for _, extra in ipairs(opts.ExtraInstances) do
		table.insert(roots, extra)
	end

	if opts.IsModel then
		table.insert(buf, '<Item class="Model" referent="MODELROOT">')
		table.insert(buf, '<Properties>')
		table.insert(buf, '<string name="Name"><![CDATA[SavedModel]]></string>')
		table.insert(buf, '</Properties>')
		for _, root in ipairs(roots) do
			serializeInstance(root, buf, opts)
		end
		table.insert(buf, '</Item>')
	else
		for _, root in ipairs(roots) do
			serializeInstance(root, buf, opts)
		end
	end

	-- SharedStrings
	if opts.UseSharedStrings and next(sharedStringsMap) then
		table.insert(buf, '<SharedStrings>')
		for base64, key in pairs(sharedStringsMap) do
			table.insert(buf, string.format('<SharedString md5="%s">%s</SharedString>', key, base64))
		end
		table.insert(buf, '</SharedStrings>')
	end

	table.insert(buf, '</roblox>')

	return table.concat(buf, "\n")
end

-- ============================================================
-- ÉCRITURE FICHIER
-- ============================================================

local function writeFile(path: string, content: string, useSegments: boolean)
	if not HAS_WRITEFILE then
		warn("[SSI] writefile indisponible")
		return
	end

	if not path:match("%.rbxl[x]?$") then
		path = path .. ".rbxlx"
	end

	if useSegments and HAS_APPENDFILE then
		local CHUNK = 4_000_000
		writefile(path, "")
		for i = 1, #content, CHUNK do
			appendfile(path, content:sub(i, math.min(i + CHUNK - 1, #content)))
		end
	else
		writefile(path, content)
	end

	print(string.format("[SSI] ✓ Sauvegardé : %s (%d octets / %.2f MB)",
		path, #content, #content / 1_000_000))
end

-- ============================================================
-- POINT D'ENTRÉE PUBLIC
-- ============================================================

local function synsaveinstance(param1: any, param2: any?)
	-- Reset état global
	referentMap        = {}
	referentCounter    = 0
	sharedStringsMap   = {}
	sharedStringsIdx   = 0

	-- Parse les arguments (multi-signatures)
	local userOpts: {[string]: any} = {}

	if typeof(param1) == "Instance" then
		userOpts = (param2 or {}) :: {[string]: any}
		userOpts.Object = param1
	elseif type(param1) == "table" then
		local isInstList = #param1 > 0
		for _, v in ipairs(param1) do
			if typeof(v) ~= "Instance" then isInstList = false; break end
		end
		if isInstList then
			userOpts = (param2 or {}) :: {[string]: any}
			userOpts.ExtraInstances = param1
			userOpts.IsModel = true
		else
			userOpts = param1
		end
	end

	local opts = mergeOptions(userOpts)

	print("[SSI] === SolaraSaveInstance démarré ===")
	print("[SSI] Chargement API Dump...")
	loadApiDump()

	print("[SSI] Sérialisation...")
	local t0 = os.clock()
	local ok, xml = pcall(buildXml, opts)
	if not ok then
		warn("[SSI] Erreur sérialisation : " .. tostring(xml))
		return
	end

	local elapsed = os.clock() - t0
	print(string.format("[SSI] Terminé en %.2fs — %d octets", elapsed, #xml))

	writeFile(opts.FilePath, xml, opts.AlternativeWritefile)
end

return synsaveinstance
