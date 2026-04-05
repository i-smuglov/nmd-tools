--[[
  Nmd — Symbols fill 5 hex vertices clockwise from 30°; fixed 1shield at top. Round masked panel.
  Hidden addon traffic only: RAID / PARTY / GUILD, payload a single digit "1".."5" (RegisterAddonMessagePrefix + CHAT_MSG_ADDON).
  Macros: /nmd init → /nmd s <1-5>. Macro *bar* icons come from INIT_MACRO_ICONS (Blizzard paths or file IDs).
  Ring display still uses SYMBOL_TEXTURES. No idle reset; after the 5th icon, display clears after 20s.
]]

NmdDB = NmdDB or {}

local RING_RADIUS = 80
local ICON_SIZE = 40
local FRAME_PADDING = 5
local HEX_VERTEX_COUNT = 6
local HEX_STEP_DEG = 360 / HEX_VERTEX_COUNT -- 60; regular hexagon
-- User convention: 0° = top. Top vertex shows TOP_SHIELD_TEXTURE; symbol icons start at next CW vertex.
local TOP_MATH_DEG = 90
local MAX_RING_ICONS = HEX_VERTEX_COUNT - 1
local ICON_ANGLE_START_DEG = TOP_MATH_DEG - HEX_STEP_DEG -- first vertex clockwise from top (30°)
local ICON_ANGLE_STEP_DEG = HEX_STEP_DEG
local FULL_RING_CLEAR_AFTER_SEC = 20

-- Letter keys = texture paths; index 1..5 maps to INIT_MACRO_TOKENS. Paths: no extension; WoW loads .blp/.tga.
-- Photoshop: Save a Copy, Targa, 32 bpp, Compression None. Alpha should match the logo (not a separate circle).
-- Run tools/normalize_tga_for_wow.py after export: strips TGA 2.0 footer, 24->32 bpp, fixes many green tints.
local SYMBOL_TEXTURES = {
    T = "Interface\\AddOns\\Nmd\\Icons\\1T",
    X = "Interface\\AddOns\\Nmd\\Icons\\1X",
    O = "Interface\\AddOns\\Nmd\\Icons\\1O",
    V = "Interface\\AddOns\\Nmd\\Icons\\1V",
    D = "Interface\\AddOns\\Nmd\\Icons\\1D",
}

local FALLBACK_TEXTURE = "Interface\\Icons\\INV_Misc_QuestionMark"
local TOP_SHIELD_TEXTURE = "Interface\\AddOns\\Nmd\\Icons\\1shield"

-- Order matches hex fill; /nmd init creates or updates one macro per slot (Nmd 1 .. Nmd 5).
local INIT_MACRO_TOKENS = { "T", "X", "O", "V", "D" }

--[[  INIT_MACRO_ICONS — action bar icon for each macro (not the on-screen ring art).
  Use either:
    • A string: Blizzard texture path (same style as Interface\\Icons\\… in the macro picker).
    • A positive number: fileDataID (see below).

  How to get a fileDataID in-game:
    /run print(GetFileIDFromPath("interface/icons/inv_misc_questionmark"))
  Lowercase + forward slashes work. Or pick any icon in the macro UI, then read its path from an
  icon-browser addon that shows IDs (many do).

  Wowhead: open a spell → icon image; the file is often named like inv_*.jpg matching the internal icon name.
]]
local INIT_MACRO_ICONS = {
    4554439, -- T: inv_10_elementalcombinedfoozles_frost
    3565717, -- X (cross): ability_revendreth_demonhunter
    134123, -- O (circle): inv_misc_gem_pearl_04
    1397643, -- V (triangle): inv_jewelcrafting_70_cutgem02_green
    7549139, -- D (diamond): inv_12_profession_jewelcrafting_rare_gem_cut_purple
}

-- Addon channel (no chat bubble / log spam); prefix max 16 chars.
local COMM_PREFIX = "Nmd"
-- Incoming CHAT_MSG_ADDON distribution (arg3); ignore WHISPER, CHANNEL, etc.
local COMM_ACCEPT_DISTRIB = { RAID = true, PARTY = true, GUILD = true }

local seq = {}
local fullRingClearTimer = nil

local function EnsureDBDefaults()
    if type(NmdDB) ~= "table" then NmdDB = {} end
    if type(NmdDB.frame) ~= "table" then NmdDB.frame = {} end

    if NmdDB.frame.locked == nil then NmdDB.frame.locked = false end
    if NmdDB.frame.scale == nil then NmdDB.frame.scale = 1.0 end
    if type(NmdDB.frame.point) ~= "string" then NmdDB.frame.point = "CENTER" end
    if type(NmdDB.frame.relPoint) ~= "string" then NmdDB.frame.relPoint = "CENTER" end
    if type(NmdDB.frame.x) ~= "number" then NmdDB.frame.x = 0 end
    if type(NmdDB.frame.y) ~= "number" then NmdDB.frame.y = 0 end
end

-- Addon/slash args can be secret strings (12.x): avoid converting them in bulk; copy byte-by-byte.
local issecretvalue = issecretvalue or function() return false end
local MAX_EXTERNAL_STR_LEN = 64

local function SanitizeExternalString(msg)
    if type(msg) ~= "string" then return "" end
    if issecretvalue(msg) then return "" end
    local parts = {}
    for i = 1, MAX_EXTERNAL_STR_LEN do
        local ok, b = pcall(string.byte, msg, i)
        if not ok then return "" end
        if b == nil then break end
        parts[i] = string.char(b)
    end
    return table.concat(parts)
end

local function SymbolIndexFromString(s)
    if type(s) ~= "string" or s == "" then return nil end
    local n = tonumber(string.match(s, "^%s*([1-5])%s*$"))
    return n
end

local halfExtent = RING_RADIUS + (ICON_SIZE / 2) + FRAME_PADDING
local frameSize = halfExtent * 2

local displayFrame = CreateFrame("Frame", "NmdDisplayFrame", UIParent, "BackdropTemplate")
displayFrame:SetSize(frameSize, frameSize)
displayFrame:SetClampedToScreen(true)
displayFrame:SetFrameStrata("MEDIUM")
displayFrame:SetBackdrop(nil)

local circleFill = displayFrame:CreateTexture(nil, "BACKGROUND")
circleFill:SetAllPoints()
circleFill:SetColorTexture(0, 0, 0, 0.50)
local circleMask = displayFrame:CreateMaskTexture()
circleMask:SetTexture("Interface/CHARACTERFRAME/TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
circleMask:SetAllPoints(circleFill)
circleFill:AddMaskTexture(circleMask)

local ringContainer = CreateFrame("Frame", nil, displayFrame)
ringContainer:SetSize(frameSize, frameSize)
ringContainer:SetPoint("CENTER", displayFrame, "CENTER", 0, 0)

local topShieldTex = ringContainer:CreateTexture(nil, "ARTWORK")
topShieldTex:SetDrawLayer("ARTWORK", -1)
topShieldTex:SetSize(ICON_SIZE, ICON_SIZE)

local iconTextures = {}
local maxPool = MAX_RING_ICONS

for i = 1, maxPool do
    local t = ringContainer:CreateTexture(nil, "ARTWORK")
    t:SetSize(ICON_SIZE, ICON_SIZE)
    t:Hide()
    iconTextures[i] = t
end

local function TexturePathForToken(token)
    local path = SYMBOL_TEXTURES[token]
    if type(path) == "string" and path ~= "" then
        return path
    end
    return FALLBACK_TEXTURE
end

local function MacroBarIconForSlot(slotIndex)
    local entry = INIT_MACRO_ICONS[slotIndex]
    if type(entry) == "number" and entry > 0 then
        return entry
    end
    if type(entry) == "string" and entry ~= "" then
        if type(GetFileIDFromPath) == "function" then
            local normalized = string.gsub(entry, "\\", "/")
            local ok, fileId = pcall(GetFileIDFromPath, normalized)
            if ok and type(fileId) == "number" and fileId > 0 then
                return fileId
            end
        end
        return entry
    end
    return FALLBACK_TEXTURE
end

local function UpdateTopShield()
    topShieldTex:SetTexture(TOP_SHIELD_TEXTURE)
    topShieldTex:SetTexCoord(0, 1, 0, 1)
    topShieldTex:ClearAllPoints()
    local rad = math.pi / 180
    local angle = TOP_MATH_DEG * rad
    topShieldTex:SetPoint("CENTER", ringContainer, "CENTER", RING_RADIUS * math.cos(angle), RING_RADIUS * math.sin(angle))
    topShieldTex:Show()
end

local function UpdateRing()
    local n = #seq
    local rad = math.pi / 180
    for i = 1, maxPool do
        local tex = iconTextures[i]
        if i > n then
            tex:Hide()
        else
            local token = seq[i]
            tex:SetTexture(TexturePathForToken(token))
            tex:SetTexCoord(0, 1, 0, 1)
            -- Clockwise around hex: subtract 60° per slot (first slot is next CW after top shield).
            local angleDeg = ICON_ANGLE_START_DEG - (i - 1) * ICON_ANGLE_STEP_DEG
            local angle = angleDeg * rad
            local x = RING_RADIUS * math.cos(angle)
            local y = RING_RADIUS * math.sin(angle)
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", ringContainer, "CENTER", x, y)
            tex:Show()
        end
    end
    UpdateTopShield()
    -- Shield always visible; circle + symbol icons only after first token until sequence clears.
    local decorAlpha = (#seq > 0) and 1 or 0
    circleFill:SetAlpha(decorAlpha)
    topShieldTex:SetAlpha(1)
    for j = 1, maxPool do
        local tj = iconTextures[j]
        if tj:IsShown() then
            tj:SetAlpha(decorAlpha)
        end
    end
end

local function ResetSequence()
    if fullRingClearTimer then
        fullRingClearTimer:Cancel()
        fullRingClearTimer = nil
    end
    seq = {}
    UpdateRing()
end

local function NmdPrint(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Nmd:|r " .. tostring(msg))
    end
end

local function InitNmdMacros()
    if InCombatLockdown() then
        NmdPrint("Cannot init macros in combat.")
        return
    end
    local created, updated = 0, 0
    for i in ipairs(INIT_MACRO_TOKENS) do
        local name = "Nmd " .. i
        local icon = MacroBarIconForSlot(i)
        local body = "/nmd s " .. i
        local idx = GetMacroIndexByName(name)
        if idx and idx > 0 then
            EditMacro(idx, name, icon, body)
            updated = updated + 1
        else
            local newIdx = CreateMacro(name, icon, body, false)
            if not newIdx then
                NmdPrint(("Could not create macro %q — general macro slots may be full."):format(name))
                return
            end
            created = created + 1
        end
    end
    NmdPrint(("Macros: %d created, %d updated. Body: /nmd s 1..5 (raid/party/guild addon channel)."):format(created, updated))
end

local function TryAddSymbol(token)
    if type(token) ~= "string" or not SYMBOL_TEXTURES[token] then return end

    EnsureDBDefaults()

    if #seq >= MAX_RING_ICONS then
        return
    end

    seq[#seq + 1] = token
    UpdateRing()

    if #seq == MAX_RING_ICONS then
        if fullRingClearTimer then
            fullRingClearTimer:Cancel()
        end
        fullRingClearTimer = C_Timer.NewTimer(FULL_RING_CLEAR_AFTER_SEC, function()
            fullRingClearTimer = nil
            ResetSequence()
        end)
    end
end

local function SendSymbolAddonMessage(index)
    if type(index) ~= "number" or index < 1 or index > MAX_RING_ICONS then return end
    local payload = tostring(index)
    if IsInRaid() then
        C_ChatInfo.SendAddonMessage(COMM_PREFIX, payload, "RAID")
    elseif IsInGroup() then
        C_ChatInfo.SendAddonMessage(COMM_PREFIX, payload, "PARTY")
    elseif IsInGuild() then
        C_ChatInfo.SendAddonMessage(COMM_PREFIX, payload, "GUILD")
    end
end

local function SendSymbolLocalAndBroadcast(index)
    local token = INIT_MACRO_TOKENS[index]
    if not token then return end
    TryAddSymbol(token)
    SendSymbolAddonMessage(index)
end

local commFrame = CreateFrame("Frame")
commFrame:RegisterEvent("CHAT_MSG_ADDON")
commFrame:SetScript("OnEvent", function(_, event, prefix, message, distribution, sender)
    if event ~= "CHAT_MSG_ADDON" then return end
    if prefix ~= COMM_PREFIX then return end
    if type(distribution) ~= "string" or not COMM_ACCEPT_DISTRIB[string.upper(distribution)] then
        return
    end
    local messageClean = SanitizeExternalString(message)
    local index = SymbolIndexFromString(messageClean)
    if not index then return end
    local token = INIT_MACRO_TOKENS[index]
    if not token then return end

    local myName = UnitName("player")
    if sender and Ambiguate(sender, "short") == Ambiguate(myName, "short") then
        return
    end

    TryAddSymbol(token)
end)

displayFrame:SetMovable(true)
displayFrame:EnableMouse(true)
displayFrame:RegisterForDrag("LeftButton")

displayFrame:SetScript("OnDragStart", function(self)
    if NmdDB and NmdDB.frame and NmdDB.frame.locked then return end
    if InCombatLockdown() then return end
    self:StartMoving()
end)

displayFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint(1)
    if not point then return end
    EnsureDBDefaults()
    NmdDB.frame.point = point
    NmdDB.frame.relPoint = relPoint or point
    NmdDB.frame.x = x or 0
    NmdDB.frame.y = y or 0
end)

local function ApplyFrameSettings()
    EnsureDBDefaults()
    displayFrame:ClearAllPoints()
    displayFrame:SetPoint(NmdDB.frame.point, UIParent, NmdDB.frame.relPoint, NmdDB.frame.x, NmdDB.frame.y)
    displayFrame:SetScale(NmdDB.frame.scale)
    displayFrame:EnableMouse(not NmdDB.frame.locked)
    displayFrame:Show()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event ~= "ADDON_LOADED" then return end
    local addonName = ...
    if addonName ~= "Nmd" then return end
    C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
    ApplyFrameSettings()
    UpdateRing()
end)

SLASH_NMD1 = "/nmd"
SlashCmdList["NMD"] = function(input)
    EnsureDBDefaults()
    local inputClean = SanitizeExternalString(input or "")
    local head, rest = string.match(inputClean, "^%s*(%S+)%s*(.*)$")
    head = string.lower(head or "")
    if head == "s" or head == "sym" then
        local n = SymbolIndexFromString(SanitizeExternalString(rest or ""))
        if n then
            SendSymbolLocalAndBroadcast(n)
        end
        return
    end
    local cmd = head
    if cmd == "lock" or cmd == "" then
        NmdDB.frame.locked = not NmdDB.frame.locked
        displayFrame:EnableMouse(not NmdDB.frame.locked)
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(("Nmd: frame %s. lock | clear | init | s <1-5>"):format(
                NmdDB.frame.locked and "locked" or "unlocked"
            ))
        end
        return
    end
    if cmd == "clear" then
        ResetSequence()
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("Nmd: sequence cleared.")
        end
        return
    end
    if cmd == "init" then
        InitNmdMacros()
        return
    end
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("Nmd: /nmd lock | clear | init | s <1-5>")
    end
end
