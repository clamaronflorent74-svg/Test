-- SolaraHackerTool

local DEFAULT_OPTIONS = {
    FilePath = "game",
    SafeMode = false,
    IgnoreDefaultProps = true,
    SaveBytecode = false,
    DecompileTimeout = 10,
    SavePlayers = false,
    IsolatePlayers = false,
    AlternativeWritefile = true,
    IgnoreDefaultPlayerScripts = true,
    UseSharedStrings = false,
    TreatUnionsAsParts = false,
    NilInstances = false,
    IgnoreNotArchivable = true,
    Mode = "Default",
    Object = game,
    ExtraInstances = {},
    IsModel = false,
}

local ALIASES = {
    timeout = "DecompileTimeout",
    FileName = "FilePath",
    IgnoreDefaultProperties = "IgnoreDefaultProps",
    SaveNonCreatable = "SaveNotCreatable",
    scriptcache = "DecompileJobless",
    IgnoreArchivable = "IgnoreNotArchivable",
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

local HAS_GETHIDDENPROPERTY = false
local HAS_DECOMPILE = false
local HAS_GETBYTECODE = false
local HAS_WRITEFILE = false
local HAS_APPENDFILE = false

do
    HAS_WRITEFILE  = type(writefile) == "function"
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

local function encodeBase64(s: string): string
    local result = {}
    local padding = 0

    for i = 1, #s, 3 do
        local b1 = string.byte(s, i) or 0
        local b2 = string.byte(s, i + 1)
        local b3 = string.byte(s, i + 2)

        if not b2 then padding = 2; b2 = 0; b3 = 0 elseif not b3 then padding = 1; b3 = 0 end

        local n = bit32.bor(
            bit32.lshift(b1, 16),
            bit32.lshift(b2, 8),
            b3
        )

        local c1 = bit32.rshift(n, 18) % 64 + 1
        local c2 = bit32.rshift(n, 12) % 64 + 1
        local c3 = bit32.rshift(n, 6) % 64 + 1
        local c4 = n % 64 + 1

        table.insert(result, B64_CHARS:sub(c1, c1))
        table.insert(result, B64_CHARS:sub(c2, c2))
        table.insert(result, padding >= 2 and "=" or B64_CHARS:sub(c3, c3))
        table.insert(result, padding >= 1 and "=" or B64_CHARS:sub(c4, c4))

        if padding > 0 then break end
    end

    return table.concat(result)
end

local function escapeXml(s: string): string
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

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

local function getReferent(inst: Instance): string
    local referentMap = {}
    local referentCounter = 0
    if not referentMap[inst] then
        referentCounter += 1
        referentMap[inst] = string.format("RBX%08X", referentCounter)
    end
    return referentMap[inst]
end

local function getSharedKey(base64: string): string
    local sharedStringsMap = {}
    local sharedStringsIdx = 0
    if not sharedStringsMap[base64] then
        sharedStringsIdx += 1
        sharedStringsMap[base64] = string.format("%032d", sharedStringsIdx)
    end
    return sharedStringsMap[base64]
end

local function decompileScript(inst: Instance, opts: typeof(DEFAULT_OPTIONS)): string
    local ok, src = pcall(function() return (inst :: any).Source end)
    if ok and type(src) == "string" and #src > 0 then
        return src
    end

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

    if HAS_GETBYTECODE and opts.SaveBytecode then
        local ok3, bc = pcall(getscriptbytecode :: any, inst)
        if ok3 and type(bc) == "string" and #bc > 0 then
            return "-- [Bytecode]\n--[[\n" .. encodeBase64(bc) .. "\n]]"
        end
    end

    return "-- Source unavailable"
end

local function readProp(inst: Instance, propName: string): (boolean, any)
    if HAS_GETHIDDENPROPERTY then
        local ok, val = pcall(gethiddenproperty :: any, inst, propName)
        if ok then return true, val end
    end
    return pcall(function() return (inst :: any)[propName] end)
end

local function serializeInstance(inst: Instance, buf: {string}, opts: typeof(DEFAULT_OPTIONS))
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

    table.insert(buf, string.format('<string name="Name"><![CDATA[%s]]></string>', escapeXml(inst.Name)))

    local props = getAllProps(className)

    for propName, valueType in pairs(props) do
        if propName == "Name" then continue end

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

        if opts.IgnoreDefaultProps then
            if value == false and valueType == "bool" then continue end
            if value == "" and (valueType == "string" or valueType == "String") then continue end
            if value == 0 and (valueType == "int" or valueType == "float" or valueType == "double") then continue end
        end

        local line: string?

        if typeof(value) == "Instance" then
            line = string.format('<Ref name="%s">%s</Ref>', propName, getReferent(value))

        elseif valueType == "BinaryString" and opts.UseSharedStrings then
            local encoded = encodeBase64(tostring(value))
            local key = getSharedKey(encoded)
            line = string.format('<SharedString name="%s">%s</SharedString>', propName, key)

        elseif SER[valueType] then
            local ok2, result = pcall(SER[valueType], propName, value)
            if ok2 then line = result end

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

    local ok, children = pcall(function() return inst:GetChildren() end)
    if ok then
        for _, child in ipairs(children) do
            serializeInstance(child, buf, opts)
        end
    end

    table.insert(buf, '</Item>')
end

local function buildXml(opts: typeof(DEFAULT_OPTIONS)): string
    local buf: {string} = {}

    table.insert(buf, '<!-- Saved by SolaraHackerTool -->')
    table.insert(buf, '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '..
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '..
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">')
    table.insert(buf, '<Meta name="ExplicitAutoJoints">true</Meta>')
    table.insert(buf, '<External></External>')
    table.insert(buf, '<External>null</External>')

    local roots: {Instance} = {}

    if opts.Mode == "Optimized" then
        local SERVICES = {
            "Workspace", "ReplicatedStorage", "ReplicatedFirst",
            "StarterGui", "StarterPack", "StarterPlayer",
            "Teams", "SoundService", "Lighting", "Chat",
            "LocalizationService", "TestService"
        }
        for _, svc in ipairs(SERVICES) do
            local ok, s = pcall(function() return (game :: any):GetService(svc) end)
            if ok and s then table.insert(roots, s) end
        end
    else
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

local function synsaveinstance(param1: any, param2: any?)
    local referentMap = {}
    local referentCounter = 0
    local sharedStringsMap = {}
    local sharedStringsIdx = 0

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

    print("[SSI] === SolaraHackerTool démarré ===")
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

local function getRemoteEventsAndFunctions()
    local remoteObjects = {}
    for _, service in pairs(game:GetService("ReplicatedStorage"):GetChildren()) do
        if service:IsA("RemoteEvent") or service:IsA("RemoteFunction") then
            table.insert(remoteObjects, service)
        end
    end
    return remoteObjects
end

local function modifyGameInstances()
    for _, part in pairs(workspace:GetDescendants()) do
        if part:IsA("Part") then
            part.Transparency = 0.5 -- Example modification: make parts semi-transparent
        end
    end
end

local function accessPlayerData()
    local playerInfo = ""
    for _, player in pairs(game.Players:GetPlayers()) do
        playerInfo = playerInfo .. player.Name .. "\n"
    end
    return playerInfo
end

local function createHackerGui()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "HackerToolGUI"
    screenGui.Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui")

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0.5, 0, 0.8, 0)
    frame.Position = UDim2.new(0.25, 0, 0.1, 0)
    frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    frame.BorderSizePixel = 0
    frame.Parent = screenGui

    local closeButton = Instance.new("TextButton")
    closeButton.Text = "Close"
    closeButton.Size = UDim2.new(0.15, 0, 0.05, 0)
    closeButton.Position = UDim2.new(0.85, -closeButton.Size.X.Offset, 0, 0)
    closeButton.BackgroundColor3 = Color3.fromRGB(150, 50, 50)
    closeButton.BorderSizePixel = 0
    closeButton.Parent = frame

    closeButton.MouseButton1Click:Connect(function()
        screenGui:Destroy()
    end)

    local infoLabel = Instance.new("TextLabel")
    infoLabel.Text = ""
    infoLabel.Size = UDim2.new(1, -20, 1, -closeButton.Size.Y.Offset - 20)
    infoLabel.Position = UDim2.new(0.05, 0, closeButton.Size.Y.Offset + 0.05, 0)
    infoLabel.BackgroundTransparency = 1
    infoLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    infoLabel.TextWrapped = true
    infoLabel.Parent = frame

    return screenGui, infoLabel
end

local function updateGuiInfo(infoLabel: TextLabel, newInfo: string)
    infoLabel.Text = newInfo
end

local hackerTool = {}

function hackerTool.startHacking()
    synsaveinstance({Mode = "Optimized"})
    
    local remoteObjects = getRemoteEventsAndFunctions()
    local playerData = accessPlayerData()

    local infoText = ""
    for _, obj in ipairs(remoteObjects) do
        infoText = infoText .. obj.Name .. "\n"
    end

    infoText = infoText .. "\nPlayers:\n" .. playerData

    local screenGui, infoLabel = createHackerGui()
    updateGuiInfo(infoLabel, infoText)

    print("[HackerTool] Hacking started!")
end

return hackerTool
