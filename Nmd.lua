--[[
  Nmd — Symbols fill 5 hex vertices from 30° (CW or CCW toggle); fixed 1shield at top. Round masked ring panel.
  Mythic from 180s pull time (phase 4): 3 runes in a horizontal line below center (always LTR). With the control panel enabled in settings, the rune row stays visible for the whole phase (including between memory windows). Same 20s clear after the last rune.
  Raid: visible line "[Nmd]".."1".."5" via SendChatMessage (RAID, or INSTANCE_CHAT when in an LFG/instance group) and matching CHAT_MSG_* handlers — addon channel is unreliable in encounter.
  Not in raid: PARTY / GUILD via RegisterAddonMessagePrefix + CHAT_MSG_ADDON (payload "1".."5").
  Separate control panel (always movable): five slot buttons (same SYMBOL_TEXTURES as the ring), Direction (CW/CCW), Reset. Optional /nmd s <1-5>.
  No idle reset; after the last icon for the current phase, display clears after 20s.
]]

NmdDB = NmdDB or {}

local RING_RADIUS = 80
local ICON_SIZE = 40
local FRAME_PADDING = 5
local HEX_VERTEX_COUNT = 6
local HEX_STEP_DEG = 360 / HEX_VERTEX_COUNT -- 60; regular hexagon
-- User convention: 0° = top. Top vertex shows TOP_SHIELD_TEXTURE.
-- CW starts at the next CW vertex; CCW starts at the opposite end of the sequence.
local TOP_MATH_DEG = 90
local MAX_RING_ICONS = HEX_VERTEX_COUNT - 1
local ICON_ANGLE_CW_START_DEG = TOP_MATH_DEG - HEX_STEP_DEG
local ICON_ANGLE_CCW_START_DEG = ICON_ANGLE_CW_START_DEG - (MAX_RING_ICONS - 1) * HEX_STEP_DEG
local ICON_ANGLE_STEP_DEG = HEX_STEP_DEG
local FULL_RING_CLEAR_AFTER_SEC = 20

local PANEL_SLOT_BTN = 40
local PANEL_MODE_BTN = 40
local PANEL_GAP = 5
local PANEL_PADDING = 5
local PANEL_BTN_BORDER = 1
local PANEL_BTN_PADDING = 5
local PANEL_TIMER_H = 18
local PANEL_TIMER_W = 52

-- Letter keys = texture paths; index 1..5 maps to INIT_MACRO_TOKENS. Paths: no extension; WoW loads .blp/.tga.
-- Photoshop: Save a Copy, Targa, 32 bpp, Compression None. Alpha should match the logo (not a separate circle).
local SYMBOL_TEXTURES = {
    T = "Interface\\AddOns\\Nmd\\Icons\\1T",
    X = "Interface\\AddOns\\Nmd\\Icons\\1X",
    O = "Interface\\AddOns\\Nmd\\Icons\\1O",
    V = "Interface\\AddOns\\Nmd\\Icons\\1V",
    D = "Interface\\AddOns\\Nmd\\Icons\\1D",
}

local FALLBACK_TEXTURE = "Interface\\Icons\\INV_Misc_QuestionMark"
local TOP_SHIELD_TEXTURE = "Interface\\AddOns\\Nmd\\Icons\\1shield"
local MODE_TEXTURES = {
    CW = "Interface\\AddOns\\Nmd\\Icons\\CW",
    CCW = "Interface\\AddOns\\Nmd\\Icons\\CCW",
}

-- Order matches hex fill; index 1..5 is sent on the wire and maps to SYMBOL_TEXTURES keys.
local INIT_MACRO_TOKENS = { "T", "X", "O", "V", "D" }

-- Addon channel (no chat bubble / log spam); prefix max 16 chars. Used outside raid (party/guild).
local COMM_PREFIX = "Nmd"
-- Incoming CHAT_MSG_ADDON distribution (arg3); ignore WHISPER, CHANNEL, etc.
local COMM_ACCEPT_DISTRIB = { RAID = true, PARTY = true, GUILD = true }
-- In-raid wire format (visible once in raid chat); matches encounter-safe path vs SendAddonMessage.
local RAID_SYMBOL_CHAT_PREFIX = "[Nmd]"

local seq = {}
local fullRingClearTimer = nil
local combatStartTime = nil
local combatTimerElapsed = 0
local combatTimerAccum = 0
local combatTimerText = nil
local combatTimelineActive = false
local activeInterfaceMode = nil
local displaySurfaceVisible = false
local activeVisibilitySignature = nil
local nmdSettingsRegistered = false
local lastPhase4LineLayout = false

local INTERFACE_MODE_HIDDEN = "hidden"
local INTERFACE_MODE_TIMER_ONLY = "timer_only"
local INTERFACE_MODE_MEMORY = "memory"

local MEMORY_WINDOW_DURATION_SEC = 5
local MEMORY_WINDOW_STARTS = { 1, 10, 20 }
-- Mythic phase 4: at/after this pull time, memory uses 3 runes in a line (not on the hex).
local MYTHIC_PHASE4_ELAPSED_SEC = 30
local MYTHIC_PHASE4_RING_ICONS = 3
local LINE_RUNE_SPACING = ICON_SIZE + 10
local MEMORY_WINDOW_FILL_CLOCKWISE = { true, false, true, false }
-- Raid difficulty from GetInstanceInfo(); only Mythic uses alternating memory-window rotation.
local RAID_DIFFICULTY_MYTHIC = 16

local function EnsureDBDefaults()
    if type(NmdDB) ~= "table" then NmdDB = {} end
    if type(NmdDB.frame) ~= "table" then NmdDB.frame = {} end
    if type(NmdDB.panel) ~= "table" then NmdDB.panel = {} end

    if NmdDB.frame.scale == nil then NmdDB.frame.scale = 1.0 end
    if type(NmdDB.frame.point) ~= "string" then NmdDB.frame.point = "CENTER" end
    if type(NmdDB.frame.relPoint) ~= "string" then NmdDB.frame.relPoint = "CENTER" end
    if type(NmdDB.frame.x) ~= "number" then NmdDB.frame.x = 0 end
    if type(NmdDB.frame.y) ~= "number" then NmdDB.frame.y = 0 end

    if NmdDB.panel.scale == nil then NmdDB.panel.scale = 1.0 end
    if type(NmdDB.panel.point) ~= "string" then NmdDB.panel.point = "CENTER" end
    if type(NmdDB.panel.relPoint) ~= "string" then NmdDB.panel.relPoint = "CENTER" end
    if type(NmdDB.panel.x) ~= "number" then NmdDB.panel.x = -220 end
    if type(NmdDB.panel.y) ~= "number" then NmdDB.panel.y = -120 end

    if NmdDB.fillClockwise == nil then NmdDB.fillClockwise = true end

    -- Control panel (rune buttons + timer): off unless enabled in Esc > Options > AddOns (callers only).
    if NmdDB.showControlFrame == nil then NmdDB.showControlFrame = false end
    if NmdDB.debugIsMythic == nil then NmdDB.debugIsMythic = false end
    if NmdDB.debugComms == nil then NmdDB.debugComms = false end
end

local function IsMythic()
    EnsureDBDefaults()
    if NmdDB.debugIsMythic == true then
        return true
    end
    local _, instanceType, difficultyID = GetInstanceInfo()
    if instanceType ~= "raid" then
        return false
    end
    return difficultyID == RAID_DIFFICULTY_MYTHIC
end

local function IsMythicPhase4AtElapsed(seconds)
    if not IsMythic() then
        return false
    end
    return math.max(0, seconds or 0) >= MYTHIC_PHASE4_ELAPSED_SEC
end

local function EffectiveMaxRingIcons()
    if IsMythicPhase4AtElapsed(combatTimerElapsed) then
        return MYTHIC_PHASE4_RING_ICONS
    end
    return MAX_RING_ICONS
end

local function UseLineRuneLayout()
    return IsMythicPhase4AtElapsed(combatTimerElapsed)
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

-- CHAT_MSG_RAID / INSTANCE lines: must parse even when issecretvalue(msg) (retail 12.x); byte copy only.
local function ExternalStringBytes(msg)
    if type(msg) ~= "string" then return "" end
    local parts = {}
    for i = 1, MAX_EXTERNAL_STR_LEN do
        local ok, b = pcall(string.byte, msg, i)
        if not ok then return "" end
        if b == nil then break end
        parts[#parts + 1] = string.char(b)
    end
    return table.concat(parts)
end

local function SymbolIndexFromString(s)
    if type(s) ~= "string" or s == "" then return nil end
    local n = tonumber(string.match(s, "^%s*([1-5])%s*$"))
    return n
end

local function SymbolIndexFromRaidChatLine(s)
    if type(s) ~= "string" or s == "" then return nil end
    local cleaned = ExternalStringBytes(s)
    if cleaned == "" then return nil end
    local plain = cleaned:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local guard = 0
    while plain:find("|H", 1, true) and guard < 24 do
        local nextPlain = plain:gsub("|H.-|h(.-)|h", "%1", 1)
        if nextPlain == plain then
            break
        end
        plain = nextPlain
        guard = guard + 1
    end
    local n = tonumber(string.match(plain, "%[Nmd%]%s*([1-5])"))
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

local NmdRunesFrame = CreateFrame("Frame", "NmdRunesFrame", displayFrame)
NmdRunesFrame:SetSize(frameSize, frameSize)
NmdRunesFrame:SetPoint("CENTER", displayFrame, "CENTER", 0, 0)

local topShieldBtn = CreateFrame("Button", nil, NmdRunesFrame)
topShieldBtn:SetSize(ICON_SIZE, ICON_SIZE)
topShieldBtn:RegisterForClicks("LeftButtonUp")
local topShieldTex = topShieldBtn:CreateTexture(nil, "ARTWORK")
topShieldTex:SetDrawLayer("ARTWORK", -1)
topShieldTex:SetAllPoints()

local modeCenterTex = NmdRunesFrame:CreateTexture(nil, "ARTWORK")
modeCenterTex:SetSize(ICON_SIZE, ICON_SIZE)
modeCenterTex:SetPoint("CENTER", NmdRunesFrame, "CENTER", 0, 0)

local iconTextures = {}
local maxPool = MAX_RING_ICONS

for i = 1, maxPool do
    local t = NmdRunesFrame:CreateTexture(nil, "ARTWORK")
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

local function TexturePathForMode(fillClockwise)
    return fillClockwise and MODE_TEXTURES.CW or MODE_TEXTURES.CCW
end

local function ApplyPanelButtonStyle(button, opts)
    if not button then return end
    opts = opts or {}

    local borderR = opts.borderR or 0.45
    local borderG = opts.borderG or 0.45
    local borderB = opts.borderB or 0.45
    local bg = opts.bg or 0.08
    local padding = opts.padding or PANEL_BTN_PADDING

    button.bg:SetColorTexture(bg, bg, bg, 0.95)
    button.borderTop:SetColorTexture(borderR, borderG, borderB, 1)
    button.borderBottom:SetColorTexture(borderR, borderG, borderB, 1)
    button.borderLeft:SetColorTexture(borderR, borderG, borderB, 1)
    button.borderRight:SetColorTexture(borderR, borderG, borderB, 1)
    button.borderTop:SetHeight(PANEL_BTN_BORDER)
    button.borderBottom:SetHeight(PANEL_BTN_BORDER)
    button.borderLeft:SetWidth(PANEL_BTN_BORDER)
    button.borderRight:SetWidth(PANEL_BTN_BORDER)
    button.icon:ClearAllPoints()
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", padding, -padding)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -padding, padding)
end

local function CreateIconButton(parent, size, texturePath)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(size, size)
    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.borderTop = button:CreateTexture(nil, "BORDER")
    button.borderTop:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button.borderTop:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    button.borderBottom = button:CreateTexture(nil, "BORDER")
    button.borderBottom:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    button.borderBottom:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    button.borderLeft = button:CreateTexture(nil, "BORDER")
    button.borderLeft:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button.borderLeft:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    button.borderRight = button:CreateTexture(nil, "BORDER")
    button.borderRight:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    button.borderRight:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetTexture(texturePath or FALLBACK_TEXTURE)
    button.icon:SetTexCoord(0, 1, 0, 1)
    ApplyPanelButtonStyle(button)
    return button
end

local function UpdateNmdRunesFrameTopShield()
    topShieldTex:SetTexture(TOP_SHIELD_TEXTURE)
    topShieldTex:SetTexCoord(0, 1, 0, 1)
    topShieldBtn:ClearAllPoints()
    local rad = math.pi / 180
    local angle = TOP_MATH_DEG * rad
    topShieldBtn:SetPoint("CENTER", NmdRunesFrame, "CENTER", RING_RADIUS * math.cos(angle), RING_RADIUS * math.sin(angle))
end

local function SequenceAngleDeg(index, fillClockwise)
    if fillClockwise then
        return ICON_ANGLE_CW_START_DEG - (index - 1) * ICON_ANGLE_STEP_DEG
    end
    return ICON_ANGLE_CCW_START_DEG + (index - 1) * ICON_ANGLE_STEP_DEG
end

-- Phase 4 (Mythic): collinear runes below center; always left-to-right (no CW/CCW flip).
local function SequenceLineOffsetXY(index, count)
    local n = count or MYTHIC_PHASE4_RING_ICONS
    local mid = (n + 1) / 2
    local x = (index - mid) * LINE_RUNE_SPACING
    local y = -RING_RADIUS * 0.42
    return x, y
end

local SetRegionVisibility
local RefreshNmdRunesFrameVisibility

local function UpdateNmdRunesFrame()
    EnsureDBDefaults()
    local fillCw = NmdDB.fillClockwise
    local n = #seq
    local rad = math.pi / 180
    modeCenterTex:SetTexture(TexturePathForMode(fillCw))
    modeCenterTex:SetTexCoord(0, 1, 0, 1)
    for i = 1, maxPool do
        local tex = iconTextures[i]
        if i <= n then
            local token = seq[i]
            tex:SetTexture(TexturePathForToken(token))
            tex:SetTexCoord(0, 1, 0, 1)
            local x, y
            if UseLineRuneLayout() then
                x, y = SequenceLineOffsetXY(i, MYTHIC_PHASE4_RING_ICONS)
            else
                local angleDeg = SequenceAngleDeg(i, fillCw)
                local angle = angleDeg * rad
                x = RING_RADIUS * math.cos(angle)
                y = RING_RADIUS * math.sin(angle)
            end
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", NmdRunesFrame, "CENTER", x, y)
        end
    end
    UpdateNmdRunesFrameTopShield()
    RefreshNmdRunesFrameVisibility()
end

local function ResetSequence()
    if fullRingClearTimer then
        fullRingClearTimer:Cancel()
        fullRingClearTimer = nil
    end
    seq = {}
    UpdateNmdRunesFrame()
end

local function CombatTimelineWindowIndexAtElapsed(seconds)
    local elapsed = math.max(0, seconds or 0)
    for i = 1, #MEMORY_WINDOW_STARTS do
        local startAt = MEMORY_WINDOW_STARTS[i]
        if elapsed >= startAt and elapsed < (startAt + MEMORY_WINDOW_DURATION_SEC) then
            return i
        end
    end
    if IsMythic() then
        local startAt = MYTHIC_PHASE4_ELAPSED_SEC
        if elapsed >= startAt and elapsed < (startAt + MEMORY_WINDOW_DURATION_SEC) then
            return #MEMORY_WINDOW_STARTS + 1
        end
    end
    return nil
end

-- Seconds until the next memory window begins (pull-relative). Nil if no later window.
local function SecondsUntilNextMemoryWindowStart(elapsed)
    local e = math.max(0, elapsed or 0)
    local starts = MEMORY_WINDOW_STARTS
    for i = 1, #starts do
        local startAt = starts[i]
        local endAt = startAt + MEMORY_WINDOW_DURATION_SEC
        if e < startAt then
            return startAt - e
        end
        if e < endAt then
            if starts[i + 1] then
                return starts[i + 1] - e
            end
            if IsMythic() and e < MYTHIC_PHASE4_ELAPSED_SEC then
                return MYTHIC_PHASE4_ELAPSED_SEC - e
            end
            return nil
        end
    end
    if IsMythic() then
        local p4 = MYTHIC_PHASE4_ELAPSED_SEC
        local p4End = p4 + MEMORY_WINDOW_DURATION_SEC
        if e < p4 then
            return p4 - e
        end
        if e < p4End then
            return nil
        end
    end
    return nil
end

local function UpdateCombatTimerText()
    if not combatTimerText then return end
    local untilNext = SecondsUntilNextMemoryWindowStart(combatTimerElapsed)
    if untilNext ~= nil then
        combatTimerText:SetText(tostring(math.max(0, math.floor(untilNext))))
    else
        combatTimerText:SetText("--")
    end
end

local function StartCombatTimer()
    combatStartTime = GetTime()
    combatTimerElapsed = 0
    combatTimerAccum = 0
    UpdateCombatTimerText()
end

local function ResetCombatTimer()
    combatStartTime = nil
    combatTimerElapsed = 0
    combatTimerAccum = 0
    UpdateCombatTimerText()
end

local function CombatTimelineModeAtElapsed(seconds)
    if CombatTimelineWindowIndexAtElapsed(seconds) then
        return INTERFACE_MODE_MEMORY
    end
    return INTERFACE_MODE_TIMER_ONLY
end

local function CombatWindowFillDirection(windowIndex)
    if not IsMythic() then
        return true
    end
    -- Phase 4 memory window: line order is fixed LTR; do not rotate to CCW here.
    if windowIndex == #MEMORY_WINDOW_STARTS + 1 then
        return true
    end
    local scheduledDirection = MEMORY_WINDOW_FILL_CLOCKWISE[windowIndex]
    if scheduledDirection ~= nil then
        return scheduledDirection
    end
    return (windowIndex % 2) == 1
end

topShieldBtn:SetScript("OnClick", function()
    ResetSequence()
end)

local function TryAddSymbol(token)
    if type(token) ~= "string" or not SYMBOL_TEXTURES[token] then return end

    EnsureDBDefaults()

    local cap = EffectiveMaxRingIcons()
    if #seq >= cap then
        return
    end

    seq[#seq + 1] = token
    UpdateNmdRunesFrame()

    if #seq == cap then
        if fullRingClearTimer then
            fullRingClearTimer:Cancel()
        end
        fullRingClearTimer = C_Timer.NewTimer(FULL_RING_CLEAR_AFTER_SEC, function()
            fullRingClearTimer = nil
            ResetSequence()
        end)
    end
end

-- When NmdDB.debugComms: chat-only lines (do not call geterrorhandler — BugGrabber treats that as a real error).
local function DebugComms(line)
    EnsureDBDefaults()
    if not NmdDB.debugComms then return end
    print("[Nmd][comm] " .. tostring(line))
end

local function SendSymbolAddonMessage(index)
    local cap = EffectiveMaxRingIcons()
    if type(index) ~= "number" or index < 1 or index > cap then return end
    local payload = tostring(index)
    DebugComms(string.format(
        "send begin: payload=%s inRaid=%s inGroup=%s inGuild=%s combat=%s",
        payload,
        tostring(IsInRaid()),
        tostring(IsInGroup()),
        tostring(IsInGuild()),
        tostring(UnitAffectingCombat("player"))
    ))
    if IsInRaid() then
        local text = RAID_SYMBOL_CHAT_PREFIX .. payload
        local chatType = "RAID"
        if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
            chatType = "INSTANCE_CHAT"
        end
        DebugComms(string.format(
            "send: SendChatMessage %s (textLen=%s)",
            chatType,
            tostring(#text)
        ))
        SendChatMessage(text, chatType, nil)
        DebugComms("send: SendChatMessage returned")
    elseif IsInGroup() then
        local a, b, c, d = C_ChatInfo.SendAddonMessage(COMM_PREFIX, payload, "PARTY")
        DebugComms(string.format(
            "send: SendAddonMessage PARTY returns a=%s b=%s c=%s d=%s",
            tostring(a), tostring(b), tostring(c), tostring(d)
        ))
    elseif IsInGuild() then
        local a, b, c, d = C_ChatInfo.SendAddonMessage(COMM_PREFIX, payload, "GUILD")
        DebugComms(string.format(
            "send: SendAddonMessage GUILD returns a=%s b=%s c=%s d=%s",
            tostring(a), tostring(b), tostring(c), tostring(d)
        ))
    else
        DebugComms("send: skipped (not raid/group/guild)")
    end
end

local function SendSymbolLocalAndBroadcast(index)
    local cap = EffectiveMaxRingIcons()
    if type(index) ~= "number" or index < 1 or index > cap then
        return
    end
    local token = INIT_MACRO_TOKENS[index]
    if not token then return end
    TryAddSymbol(token)
    SendSymbolAddonMessage(index)
end

local function SaveFramePosition(frame, dbKey)
    local point, _, relPoint, x, y = frame:GetPoint(1)
    if not point then return end
    EnsureDBDefaults()
    local dbNode = NmdDB[dbKey]
    if type(dbNode) ~= "table" then return end
    dbNode.point = point
    dbNode.relPoint = relPoint or point
    dbNode.x = x or 0
    dbNode.y = y or 0
end

local function AttachDragBehavior(dragHandle, targetFrame, dbKey)
    targetFrame:SetMovable(true)
    dragHandle:EnableMouse(true)
    dragHandle:RegisterForDrag("LeftButton")

    dragHandle:SetScript("OnDragStart", function()
        targetFrame:StartMoving()
    end)

    dragHandle:SetScript("OnDragStop", function()
        targetFrame:StopMovingOrSizing()
        SaveFramePosition(targetFrame, dbKey)
    end)

    -- Guard against the frame being hidden while a drag is active.
    targetFrame:SetScript("OnHide", function()
        targetFrame:StopMovingOrSizing()
    end)
end

-- Control panel (separate from ring display)
local controlFrame = CreateFrame("Frame", "NmdControlFrame", UIParent, "BackdropTemplate")
controlFrame:SetClampedToScreen(true)
controlFrame:SetFrameStrata("MEDIUM")
controlFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    tile = true,
    tileSize = 32,
})
controlFrame:SetBackdropColor(0, 0, 0, 0.82)

local buttonRowW = 5 * PANEL_SLOT_BTN + 4 * PANEL_GAP
local rowW = PANEL_TIMER_W + PANEL_GAP + buttonRowW
local controlW = rowW + PANEL_PADDING * 2
local controlTimerOnlyW = PANEL_TIMER_W + PANEL_PADDING * 2
local controlH = PANEL_SLOT_BTN + PANEL_PADDING * 2
local controlTimerOnlyH = PANEL_SLOT_BTN + PANEL_PADDING * 2
controlFrame:SetSize(controlW, controlH)

-- Single drag hit layer (below buttons/timer anchor) so StartMoving is not registered twice on the same frame.
local panelDragLayer = CreateFrame("Frame", nil, controlFrame)
panelDragLayer:SetAllPoints()
panelDragLayer:EnableMouse(true)

-- Layout anchor for timer text and icon row; mouse disabled so drags use panelDragLayer underneath.
local timerTextAnchor = CreateFrame("Frame", nil, controlFrame)
timerTextAnchor:SetPoint("TOPLEFT", controlFrame, "TOPLEFT", PANEL_PADDING, -PANEL_PADDING)
timerTextAnchor:SetSize(PANEL_TIMER_W, PANEL_SLOT_BTN)

combatTimerText = controlFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
combatTimerText:SetPoint("CENTER", timerTextAnchor, "CENTER", 0, 0)
combatTimerText:SetWidth(PANEL_TIMER_W)
combatTimerText:SetHeight(PANEL_TIMER_H)
combatTimerText:SetJustifyH("CENTER")
combatTimerText:SetText("--")

local cwBtn
local ccwBtn
local function SetModeButtonActive(button, isActive)
    if not button then return end
    local borderR = isActive and 1 or 0.45
    local borderG = isActive and 0.82 or 0.45
    local borderB = isActive and 0 or 0.45
    ApplyPanelButtonStyle(button, {
        bg = isActive and 0.18 or 0.08,
        borderR = borderR,
        borderG = borderG,
        borderB = borderB,
    })
end

local function RefreshDirectionControls()
    EnsureDBDefaults()
    SetModeButtonActive(cwBtn, NmdDB.fillClockwise)
    SetModeButtonActive(ccwBtn, not NmdDB.fillClockwise)
    modeCenterTex:SetTexture(TexturePathForMode(NmdDB.fillClockwise))
    modeCenterTex:SetTexCoord(0, 1, 0, 1)
end

local function SetFillDirection(fillClockwise)
    EnsureDBDefaults()
    local normalized = not not fillClockwise
    if NmdDB.fillClockwise == normalized then
        RefreshDirectionControls()
        UpdateNmdRunesFrame()
        return
    end
    NmdDB.fillClockwise = normalized
    RefreshDirectionControls()
    UpdateNmdRunesFrame()
end

local buttonRow = CreateFrame("Frame", nil, controlFrame)
buttonRow:SetPoint("LEFT", timerTextAnchor, "RIGHT", PANEL_GAP, 0)
buttonRow:SetSize(buttonRowW, PANEL_SLOT_BTN)

local prev = nil
for i = 1, MAX_RING_ICONS do
    local btn = CreateIconButton(buttonRow, PANEL_SLOT_BTN, TexturePathForToken(INIT_MACRO_TOKENS[i]))
    if prev then
        btn:SetPoint("LEFT", prev, "RIGHT", PANEL_GAP, 0)
    else
        btn:SetPoint("LEFT", buttonRow, "LEFT", 0, 0)
    end
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetScript("OnClick", function()
        SendSymbolLocalAndBroadcast(i)
    end)
    prev = btn
end

-- Rotation arrow buttons temporarily hidden from the panel layout.
--[[
cwBtn = CreateIconButton(buttonRow, PANEL_MODE_BTN, MODE_TEXTURES.CW)
cwBtn:SetPoint("LEFT", prev, "RIGHT", PANEL_GAP, 0)
cwBtn:RegisterForClicks("LeftButtonUp")
cwBtn:SetScript("OnClick", function()
    SetFillDirection(true)
end)

ccwBtn = CreateIconButton(buttonRow, PANEL_MODE_BTN, MODE_TEXTURES.CCW)
ccwBtn:SetPoint("LEFT", cwBtn, "RIGHT", PANEL_GAP, 0)
ccwBtn:RegisterForClicks("LeftButtonUp")
ccwBtn:SetScript("OnClick", function()
    SetFillDirection(false)
end)
]]

SetRegionVisibility = function(region, isVisible)
    if not region then return end
    if isVisible then
        region:Show()
    else
        region:Hide()
    end
end

RefreshNmdRunesFrameVisibility = function()
    SetRegionVisibility(circleFill, displaySurfaceVisible)
    SetRegionVisibility(topShieldBtn, displaySurfaceVisible)
    SetRegionVisibility(modeCenterTex, displaySurfaceVisible)

    for i = 1, maxPool do
        local tex = iconTextures[i]
        SetRegionVisibility(tex, displaySurfaceVisible and i <= #seq)
    end
end

local function SetDisplayVisibility(isVisible)
    displaySurfaceVisible = not not isVisible
    SetRegionVisibility(displayFrame, displaySurfaceVisible)
    RefreshNmdRunesFrameVisibility()
    if not displaySurfaceVisible then
        ResetSequence()
    end
end

local function SetControlPanelVisibility(showTimer, showControls)
    local showRoot = showTimer or showControls
    local newW = showControls and controlW or controlTimerOnlyW
    local newH = showControls and controlH or controlTimerOnlyH
    local prevW, prevH = controlFrame:GetWidth(), controlFrame:GetHeight()
    local sizeChanged = math.abs(prevW - newW) > 0.5 or math.abs(prevH - newH) > 0.5
    local anchorLeft, anchorBottom
    if sizeChanged and controlFrame:GetNumPoints() > 0 then
        anchorLeft, anchorBottom = controlFrame:GetRect()
    end

    SetRegionVisibility(controlFrame, showRoot)
    SetRegionVisibility(panelDragLayer, showRoot)
    SetRegionVisibility(timerTextAnchor, showTimer)
    SetRegionVisibility(combatTimerText, showTimer)
    SetRegionVisibility(buttonRow, showControls)
    controlFrame:SetSize(newW, newH)

    -- Wider memory layout adds icons to the right; pin bottom-left so the timer does not shift.
    if sizeChanged and anchorLeft and anchorBottom then
        local parent = controlFrame:GetParent() or UIParent
        controlFrame:ClearAllPoints()
        controlFrame:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", anchorLeft, anchorBottom)
        SaveFramePosition(controlFrame, "panel")
    end
end

local function ApplyInterfaceVisibility(mode)
    local normalized = mode or INTERFACE_MODE_HIDDEN
    EnsureDBDefaults()
    local allowControl = NmdDB.showControlFrame == true
    local sig = normalized .. ":" .. tostring(allowControl)
    if normalized == INTERFACE_MODE_TIMER_ONLY and allowControl then
        sig = sig .. ":p4row=" .. tostring(IsMythicPhase4AtElapsed(combatTimerElapsed))
    end
    if activeVisibilitySignature == sig then
        return
    end
    activeVisibilitySignature = sig
    activeInterfaceMode = normalized

    if not allowControl then
        SetControlPanelVisibility(false, false)
        if normalized == INTERFACE_MODE_MEMORY then
            SetDisplayVisibility(true)
        else
            SetDisplayVisibility(false)
        end
        return
    end

    if normalized == INTERFACE_MODE_MEMORY then
        SetControlPanelVisibility(true, true)
        SetDisplayVisibility(true)
        return
    end

    if normalized == INTERFACE_MODE_TIMER_ONLY then
        SetControlPanelVisibility(true, IsMythicPhase4AtElapsed(combatTimerElapsed))
        SetDisplayVisibility(false)
        return
    end

    SetControlPanelVisibility(false, false)
    SetDisplayVisibility(false)
end

local function RefreshCombatTimelineVisibility()
    if combatTimelineActive then
        local memoryWindowIndex = CombatTimelineWindowIndexAtElapsed(combatTimerElapsed)
        if memoryWindowIndex then
            local fillClockwise = CombatWindowFillDirection(memoryWindowIndex)
            if NmdDB.fillClockwise ~= fillClockwise then
                SetFillDirection(fillClockwise)
            end
        end
        ApplyInterfaceVisibility(CombatTimelineModeAtElapsed(combatTimerElapsed))
        return
    end
    ApplyInterfaceVisibility(INTERFACE_MODE_HIDDEN)
end

RefreshDirectionControls()
ApplyInterfaceVisibility(INTERFACE_MODE_HIDDEN)

local function RegisterNmdSettings()
    if nmdSettingsRegistered then
        return
    end
    if not Settings or not Settings.RegisterVerticalLayoutCategory then
        return
    end
    nmdSettingsRegistered = true
    EnsureDBDefaults()

    local category, layout = Settings.RegisterVerticalLayoutCategory("Nomad Raid Tools")
    if layout and CreateSettingsListSectionHeaderInitializer then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Midnight falls", nil, nil))
    end

    local variable = "Nmd_ShowControlFrame"
    local setting = Settings.RegisterAddOnSetting(
        category,
        variable,
        "showControlFrame",
        NmdDB,
        Settings.VarType.Boolean,
        "Show ControlFrame",
        Settings.Default.False
    )
    Settings.CreateCheckbox(
        category,
        setting,
        "Shows the movable control panel with rune buttons and the combat timer. Turn on if you will call runes in raid; leave off to hide it and only follow symbols from others."
    )
    Settings.SetOnValueChangedCallback(variable, function()
        activeVisibilitySignature = nil
        RefreshCombatTimelineVisibility()
    end)

    local debugMythicVariable = "Nmd_DebugIsMythic"
    local debugMythicSetting = Settings.RegisterAddOnSetting(
        category,
        debugMythicVariable,
        "debugIsMythic",
        NmdDB,
        Settings.VarType.Boolean,
        "IsMythic [debug]",
        Settings.Default.False
    )
    Settings.CreateCheckbox(
        category,
        debugMythicSetting,
        "Treats the encounter as Mythic for automatic CW/CCW rotation during memory windows, so you can test arrow behavior outside Mythic raid."
    )
    Settings.SetOnValueChangedCallback(debugMythicVariable, function()
        RefreshCombatTimelineVisibility()
        RefreshDirectionControls()
    end)

    local debugCommsVariable = "Nmd_DebugComms"
    local debugCommsSetting = Settings.RegisterAddOnSetting(
        category,
        debugCommsVariable,
        "debugComms",
        NmdDB,
        Settings.VarType.Boolean,
        "Log comms [debug]",
        Settings.Default.False
    )
    Settings.CreateCheckbox(
        category,
        debugCommsSetting,
        "Prints each send/recv on the Nmd wire (raid chat vs addon channel) to chat. Does not use the Lua error handler so BugSack stays clean. Turn off after reproducing; can be chatty."
    )

    Settings.RegisterAddOnCategory(category)
end

controlFrame:SetScript("OnUpdate", function(_, elapsed)
    if not combatTimelineActive or not combatStartTime then return end
    combatTimerAccum = combatTimerAccum + elapsed
    if combatTimerAccum < 0.1 then return end
    combatTimerAccum = 0
    combatTimerElapsed = GetTime() - combatStartTime
    UpdateCombatTimerText()
    local nowLine = UseLineRuneLayout()
    if nowLine ~= lastPhase4LineLayout then
        lastPhase4LineLayout = nowLine
        if displaySurfaceVisible and #seq > 0 then
            UpdateNmdRunesFrame()
        end
    end
    RefreshCombatTimelineVisibility()
end)

local commFrame = CreateFrame("Frame")
commFrame:RegisterEvent("CHAT_MSG_ADDON")
commFrame:RegisterEvent("CHAT_MSG_RAID")
commFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
commFrame:RegisterEvent("CHAT_MSG_INSTANCE_CHAT")
commFrame:RegisterEvent("CHAT_MSG_INSTANCE_CHAT_LEADER")
commFrame:SetScript("OnEvent", function(_, event, ...)
    local index, sender

    if event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, senderArg = ...
        if prefix ~= COMM_PREFIX then
            return
        end
        DebugComms(string.format(
            "recv CHAT_MSG_ADDON Nmd dist=%s sender=%s acceptDist=%s",
            tostring(distribution),
            tostring(senderArg),
            tostring(type(distribution) == "string" and COMM_ACCEPT_DISTRIB[string.upper(distribution)] or false)
        ))
        if type(distribution) ~= "string" or not COMM_ACCEPT_DISTRIB[string.upper(distribution)] then
            DebugComms("recv CHAT_MSG_ADDON ignored (distribution not accepted)")
            return
        end
        local messageClean = SanitizeExternalString(message)
        index = SymbolIndexFromString(messageClean)
        sender = senderArg
        DebugComms(string.format(
            "recv CHAT_MSG_ADDON parsed index=%s msgCleanLen=%s",
            tostring(index),
            tostring(#messageClean)
        ))
    elseif event == "CHAT_MSG_RAID"
        or event == "CHAT_MSG_RAID_LEADER"
        or event == "CHAT_MSG_INSTANCE_CHAT"
        or event == "CHAT_MSG_INSTANCE_CHAT_LEADER" then
        local message, senderArg = ...
        DebugComms(string.format(
            "recv %s sender=%s snippet=%s",
            event,
            tostring(senderArg),
            tostring(type(message) == "string" and ExternalStringBytes(message):sub(1, 96) or "")
        ))
        index = SymbolIndexFromRaidChatLine(message)
        sender = senderArg
        DebugComms("recv raid parsed index=" .. tostring(index))
    else
        return
    end

    if not index then
        DebugComms("recv: ignored (no symbol index)")
        return
    end
    if index > EffectiveMaxRingIcons() then
        DebugComms("recv: ignored (index above current phase cap)")
        return
    end
    local token = INIT_MACRO_TOKENS[index]
    if not token then
        DebugComms("recv: ignored (no token for index)")
        return
    end

    local myName = UnitName("player")
    if sender and Ambiguate(sender, "short") == Ambiguate(myName, "short") then
        DebugComms("recv: ignored (self)")
        return
    end

    DebugComms("recv: applying symbol for index=" .. tostring(index))
    TryAddSymbol(token)
end)

AttachDragBehavior(displayFrame, displayFrame, "frame")
AttachDragBehavior(panelDragLayer, controlFrame, "panel")

local function ApplyFrameSettings()
    EnsureDBDefaults()
    displayFrame:ClearAllPoints()
    displayFrame:SetPoint(NmdDB.frame.point, UIParent, NmdDB.frame.relPoint, NmdDB.frame.x, NmdDB.frame.y)
    displayFrame:SetScale(NmdDB.frame.scale)
    displayFrame:EnableMouse(true)

    controlFrame:ClearAllPoints()
    controlFrame:SetPoint(NmdDB.panel.point, UIParent, NmdDB.panel.relPoint, NmdDB.panel.x, NmdDB.panel.y)
    controlFrame:SetScale(NmdDB.panel.scale)
    RefreshDirectionControls()
    RefreshCombatTimelineVisibility()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= "Nmd" then return end
        C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
        RegisterNmdSettings()
        ApplyFrameSettings()
        UpdateNmdRunesFrame()
        if UnitAffectingCombat("player") then
            ResetSequence()
            lastPhase4LineLayout = false
            combatTimelineActive = true
            StartCombatTimer()
            RefreshCombatTimelineVisibility()
        else
            ResetSequence()
            lastPhase4LineLayout = false
            combatTimelineActive = false
            ResetCombatTimer()
            RefreshCombatTimelineVisibility()
        end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        ResetSequence()
        lastPhase4LineLayout = false
        combatTimelineActive = true
        StartCombatTimer()
        RefreshCombatTimelineVisibility()
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        ResetSequence()
        combatTimelineActive = false
        ResetCombatTimer()
        lastPhase4LineLayout = false
        RefreshCombatTimelineVisibility()
    end
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
    if cmd == "clear" then
        ResetSequence()
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("Nmd: sequence cleared.")
        end
        return
    end
    if cmd == "" then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("Nmd: /nmd clear | s <1-5>")
        end
        return
    end
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("Nmd: /nmd clear | s <1-5>")
    end
end
