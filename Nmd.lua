--[[
  Nmd — Symbols fill 5 hex vertices from 30° (CW or CCW toggle); fixed 1shield at top. Round masked ring panel.
  Hidden addon traffic only: RAID / PARTY / GUILD, payload a single digit "1".."5" (RegisterAddonMessagePrefix + CHAT_MSG_ADDON).
  Separate control panel (always movable): five slot buttons (same SYMBOL_TEXTURES as the ring), Direction (CW/CCW), Reset. Optional /nmd s <1-5>.
  No idle reset; after the 5th icon, display clears after 20s.
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
local PANEL_DRAG_H = 5
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

-- Addon channel (no chat bubble / log spam); prefix max 16 chars.
local COMM_PREFIX = "Nmd"
-- Incoming CHAT_MSG_ADDON distribution (arg3); ignore WHISPER, CHANNEL, etc.
local COMM_ACCEPT_DISTRIB = { RAID = true, PARTY = true, GUILD = true }

local seq = {}
local fullRingClearTimer = nil
local combatStartTime = nil
local combatTimerElapsed = 0
local combatTimerAccum = 0
local combatTimerText = nil
local combatTimelineActive = false
local activeInterfaceMode = nil
local displaySurfaceVisible = false

local INTERFACE_MODE_HIDDEN = "hidden"
local INTERFACE_MODE_TIMER_ONLY = "timer_only"
local INTERFACE_MODE_MEMORY = "memory"

local MEMORY_WINDOW_DURATION_SEC = 20
local MEMORY_WINDOW_STARTS = { 10, 80 }
local MEMORY_WINDOW_FILL_CLOCKWISE = { true, false, true }
-- Raid difficulty from GetInstanceInfo(); only Mythic uses alternating memory-window rotation.
local RAID_DIFFICULTY_MYTHIC = 16

local function UseMythicMemoryRotationPattern()
    local _, instanceType, difficultyID = GetInstanceInfo()
    if instanceType ~= "raid" then
        return false
    end
    return difficultyID == RAID_DIFFICULTY_MYTHIC
end

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

local topShieldBtn = CreateFrame("Button", nil, ringContainer)
topShieldBtn:SetSize(ICON_SIZE, ICON_SIZE)
topShieldBtn:RegisterForClicks("LeftButtonUp")
local topShieldTex = topShieldBtn:CreateTexture(nil, "ARTWORK")
topShieldTex:SetDrawLayer("ARTWORK", -1)
topShieldTex:SetAllPoints()

local modeCenterTex = ringContainer:CreateTexture(nil, "ARTWORK")
modeCenterTex:SetSize(ICON_SIZE, ICON_SIZE)
modeCenterTex:SetPoint("CENTER", ringContainer, "CENTER", 0, 0)

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

local function UpdateTopShield()
    topShieldTex:SetTexture(TOP_SHIELD_TEXTURE)
    topShieldTex:SetTexCoord(0, 1, 0, 1)
    topShieldBtn:ClearAllPoints()
    local rad = math.pi / 180
    local angle = TOP_MATH_DEG * rad
    topShieldBtn:SetPoint("CENTER", ringContainer, "CENTER", RING_RADIUS * math.cos(angle), RING_RADIUS * math.sin(angle))
end

local function SequenceAngleDeg(index, fillClockwise)
    if fillClockwise then
        return ICON_ANGLE_CW_START_DEG - (index - 1) * ICON_ANGLE_STEP_DEG
    end
    return ICON_ANGLE_CCW_START_DEG + (index - 1) * ICON_ANGLE_STEP_DEG
end

local SetRegionVisibility
local RefreshRingVisibility

local function UpdateRing()
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
            local angleDeg = SequenceAngleDeg(i, fillCw)
            local angle = angleDeg * rad
            local x = RING_RADIUS * math.cos(angle)
            local y = RING_RADIUS * math.sin(angle)
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", ringContainer, "CENTER", x, y)
        end
    end
    UpdateTopShield()
    RefreshRingVisibility()
end

local function ResetSequence()
    if fullRingClearTimer then
        fullRingClearTimer:Cancel()
        fullRingClearTimer = nil
    end
    seq = {}
    UpdateRing()
end

local function FormatCombatTime(seconds)
    local totalSeconds = math.max(0, math.floor(seconds or 0))
    local minutes = math.floor(totalSeconds / 60)
    local secs = totalSeconds % 60
    return string.format("%02d:%02d", minutes, secs)
end

local function UpdateCombatTimerText()
    if not combatTimerText then return end
    combatTimerText:SetText(FormatCombatTime(combatTimerElapsed))
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

local function CombatTimelineWindowIndexAtElapsed(seconds)
    local elapsed = math.max(0, seconds or 0)
    for i = 1, #MEMORY_WINDOW_STARTS do
        local startAt = MEMORY_WINDOW_STARTS[i]
        if elapsed >= startAt and elapsed < (startAt + MEMORY_WINDOW_DURATION_SEC) then
            return i
        end
    end
    return nil
end

local function CombatTimelineModeAtElapsed(seconds)
    if CombatTimelineWindowIndexAtElapsed(seconds) then
        return INTERFACE_MODE_MEMORY
    end
    return INTERFACE_MODE_TIMER_ONLY
end

local function CombatWindowFillDirection(windowIndex)
    if not UseMythicMemoryRotationPattern() then
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
controlFrame:EnableMouse(true)

local buttonRowW = 5 * PANEL_SLOT_BTN + 4 * PANEL_GAP
local rowW = PANEL_TIMER_W + PANEL_GAP + buttonRowW
local controlW = rowW + PANEL_PADDING * 2
local controlTimerOnlyW = PANEL_TIMER_W + PANEL_PADDING * 2
local controlH = PANEL_DRAG_H + PANEL_GAP + PANEL_SLOT_BTN + PANEL_PADDING * 2
local controlTimerOnlyH = PANEL_DRAG_H + PANEL_GAP + PANEL_SLOT_BTN + PANEL_PADDING * 2
controlFrame:SetSize(controlW, controlH)

local dragBar = CreateFrame("Frame", nil, controlFrame)
dragBar:SetHeight(PANEL_DRAG_H)
dragBar:SetPoint("TOPLEFT", controlFrame, "TOPLEFT", PANEL_PADDING, -PANEL_PADDING)
dragBar:SetPoint("TOPRIGHT", controlFrame, "TOPRIGHT", -PANEL_PADDING, -PANEL_PADDING)

local timerDragZone = CreateFrame("Frame", nil, controlFrame)
timerDragZone:SetPoint("TOPLEFT", dragBar, "BOTTOMLEFT", 0, -PANEL_GAP)
timerDragZone:SetSize(PANEL_TIMER_W, PANEL_SLOT_BTN)
timerDragZone:EnableMouse(true)

combatTimerText = controlFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
combatTimerText:SetPoint("CENTER", timerDragZone, "CENTER", 0, 0)
combatTimerText:SetWidth(PANEL_TIMER_W)
combatTimerText:SetHeight(PANEL_TIMER_H)
combatTimerText:SetJustifyH("CENTER")
combatTimerText:SetText("00:00")

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
        UpdateRing()
        return
    end
    NmdDB.fillClockwise = normalized
    RefreshDirectionControls()
    UpdateRing()
end

local buttonRow = CreateFrame("Frame", nil, controlFrame)
buttonRow:SetPoint("LEFT", timerDragZone, "RIGHT", PANEL_GAP, 0)
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

RefreshRingVisibility = function()
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
    RefreshRingVisibility()
end

local function SetControlPanelVisibility(showTimer, showControls)
    local showRoot = showTimer or showControls
    SetRegionVisibility(controlFrame, showRoot)
    SetRegionVisibility(dragBar, showRoot)
    SetRegionVisibility(timerDragZone, showTimer)
    SetRegionVisibility(combatTimerText, showTimer)
    SetRegionVisibility(buttonRow, showControls)
    controlFrame:SetSize(showControls and controlW or controlTimerOnlyW, showControls and controlH or controlTimerOnlyH)
end

local function ApplyInterfaceVisibility(mode)
    local normalized = mode or INTERFACE_MODE_HIDDEN
    if activeInterfaceMode == normalized then return end
    activeInterfaceMode = normalized

    if normalized == INTERFACE_MODE_MEMORY then
        SetControlPanelVisibility(true, true)
        SetDisplayVisibility(true)
        return
    end

    if normalized == INTERFACE_MODE_TIMER_ONLY then
        SetControlPanelVisibility(true, false)
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

controlFrame:SetScript("OnUpdate", function(_, elapsed)
    if not combatTimelineActive or not combatStartTime then return end
    combatTimerAccum = combatTimerAccum + elapsed
    if combatTimerAccum < 0.1 then return end
    combatTimerAccum = 0
    combatTimerElapsed = GetTime() - combatStartTime
    UpdateCombatTimerText()
    RefreshCombatTimelineVisibility()
end)

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

AttachDragBehavior(displayFrame, displayFrame, "frame")
AttachDragBehavior(controlFrame, controlFrame, "panel")
AttachDragBehavior(timerDragZone, controlFrame, "panel")

local function ApplyFrameSettings()
    EnsureDBDefaults()
    displayFrame:ClearAllPoints()
    displayFrame:SetPoint(NmdDB.frame.point, UIParent, NmdDB.frame.relPoint, NmdDB.frame.x, NmdDB.frame.y)
    displayFrame:SetScale(NmdDB.frame.scale)
    displayFrame:EnableMouse(true)

    controlFrame:ClearAllPoints()
    controlFrame:SetPoint(NmdDB.panel.point, UIParent, NmdDB.panel.relPoint, NmdDB.panel.x, NmdDB.panel.y)
    controlFrame:SetScale(NmdDB.panel.scale)
    dragBar:EnableMouse(true)
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
        ApplyFrameSettings()
        UpdateRing()
        if UnitAffectingCombat("player") then
            ResetSequence()
            combatTimelineActive = true
            StartCombatTimer()
            RefreshCombatTimelineVisibility()
        else
            ResetSequence()
            combatTimelineActive = false
            ResetCombatTimer()
            RefreshCombatTimelineVisibility()
        end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        ResetSequence()
        combatTimelineActive = true
        StartCombatTimer()
        RefreshCombatTimelineVisibility()
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        ResetSequence()
        combatTimelineActive = false
        ResetCombatTimer()
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
