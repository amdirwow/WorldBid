
local ADDON_NAME = ...
local WB = CreateFrame("Frame", "WorldBidRoot")
_G.WorldBidRoot = WB

WB.prefix = "WBID"
WB.defaultRaiseGold = 10
WB.accentColor = "ffffcc00"   -- жовтий
WB.leaderColor = "ffff4040"   -- червоний
WB.winnerColor = "ff33ff33"   -- зелений
WB.timerColor  = "ffff9933"   -- помаранчевий
WB.textColor   = "ffffffff"   -- білий
WB.mutedColor  = "ffb8c7d9"   -- світло-сірий
WB.state = {
    active = false,
    auctionState = 0,
    seller = "",
    bidder = "",
    itemLink = "",
    itemName = "",
    entry = 0,
    count = 0,
    bidCopper = 0,
    remainingMs = 0,
    mailWaiting = false,
}

WB.pending = {
    itemLink = nil,
    itemName = nil,
    count = 1,
}

WB.lastPickup = nil
WB.bagWatchElapsed = 0
WB.lastBagVisible = false

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff3030[Аукціон]|r " .. tostring(msg))
end

local function SetVisible(frame, shown)
    if not frame then return end
    if shown then frame:Show() else frame:Hide() end
end

local function Split(str, sep)
    local t = {}
    if str == nil then
        return t
    end

    sep = sep or "\t"
    local current = ""

    local i = 1
    local len = string.len(str)
    while i <= len do
        local ch = string.sub(str, i, i)
        if ch == sep then
            t[#t + 1] = current
            current = ""
        else
            current = current .. ch
        end
        i = i + 1
    end

    t[#t + 1] = current
    return t
end

local function CopperToText(copper)
    copper = tonumber(copper) or 0
    local g = math.floor(copper / 10000)
    return string.format("%dг", g)
end

local function MsToCountdownText(ms)
    ms = tonumber(ms) or 0
    if ms < 0 then
        ms = 0
    end

    local total = math.ceil(ms / 1000)
    local m = math.floor(total / 60)
    local s = total % 60
    return string.format("%d:%02d", m, s)
end

local function EnsureDB()
    if type(WorldBidDB) ~= "table" then
        WorldBidDB = {}
    end
    if type(WorldBidDB.point) ~= "table" then
        WorldBidDB.point = {"CENTER", "UIParent", "CENTER", -260, 0}
    end
end

function WB:SendAddonCommand(payload)
    local playerName = UnitName("player")
    if not playerName or playerName == "" then
        Print("Не вдалося визначити ім'я персонажа для відправки addon-команди.")
        return false
    end

    if not SendAddonMessage then
        Print("Клієнт не підтримує SendAddonMessage.")
        return false
    end

    SendAddonMessage(self.prefix, tostring(payload or ""), "WHISPER", playerName)
    return true
end

function WB:SendSell(itemLink, count, priceGold)
    return self:SendAddonCommand(string.format("SELL	%s	%d	%d", tostring(itemLink or ""), tonumber(count) or 1, math.floor(tonumber(priceGold) or 0)))
end

function WB:SendBidRaise(deltaGold)
    return self:SendAddonCommand(string.format("BID	RAISE	%d", math.floor(tonumber(deltaGold) or 0)))
end

function WB:SendBidAbsolute(totalGold)
    return self:SendAddonCommand(string.format("BID	ABS	%d", math.floor(tonumber(totalGold) or 0)))
end

function WB:SendSimpleCommand(name)
    return self:SendAddonCommand(tostring(name or ""))
end

function WB:ResetPending()
    self.pending.itemLink = nil
    self.pending.itemName = nil
    self.pending.count = 1
    self.lastPickup = nil
end

function WB:ClearAuction()
    self.state.active = false
    self.state.auctionState = 0
    self.state.seller = ""
    self.state.bidder = ""
    self.state.itemLink = ""
    self.state.itemName = ""
    self.state.entry = 0
    self.state.count = 0
    self.state.bidCopper = 0
    self.state.remainingMs = 0
    self.state.mailWaiting = false
    self:ResetPending()
    self:UpdateUI()
end

function WB:IsPlayerSeller()
    local name = UnitName("player")
    return self.state.seller ~= "" and self.state.seller == name
end

function WB:IsPlayerHighBidder()
    local name = UnitName("player")
    return self.state.bidder ~= "" and self.state.bidder == name
end



function WB:SetAuctionState(data)
    self.state.active = true
    self.state.auctionState = tonumber(data.auctionState) or 0
    self.state.seller = tostring(data.seller or "")
    self.state.bidder = tostring(data.bidder or "")
    self.state.itemLink = tostring(data.itemLink or "")
    self.state.itemName = tostring(data.itemName or "")
    self.state.entry = tonumber(data.entry) or 0
    self.state.count = tonumber(data.count) or 0
    self.state.bidCopper = tonumber(data.bidCopper) or 0
    self.state.remainingMs = tonumber(data.remainingMs) or 0

    self.pending.itemLink = nil
    self.pending.itemName = nil
    self.pending.count = 1

    self:UpdateUI()
end

function WB:GuessCurrentStackCount(itemLink)
    if self.lastPickup and self.lastPickup.link == itemLink and self.lastPickup.count and self.lastPickup.count > 0 then
        return self.lastPickup.count
    end

    local bagCount = NUM_BAG_SLOTS or 4
    for bag = 0, bagCount do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link == itemLink then
                    local _, count = GetContainerItemInfo(bag, slot)
                    if count and count > 0 then
                        return count
                    end
                end
            end
        end
    end

    return 1
end

function WB:ShowPricePrompt(itemLink)
    if not self.promptFrame then return end
    self.pending.itemLink = itemLink
    self.pending.itemName = GetItemInfo(itemLink) or itemLink or ""
    self.pending.count = self:GuessCurrentStackCount(itemLink)

    self.promptFrame.countBox:SetText(tostring(self.pending.count or 1))
    self.promptFrame.priceBox:SetText("1")
    self.promptFrame:Show()
    self.promptFrame.priceBox:SetFocus()
    self.promptFrame.priceBox:HighlightText()
end

function WB:HandleDroppedCursorItem()
    if not CursorHasItem() then
        return
    end

    local infoType, itemID, itemLink = GetCursorInfo()
    if infoType ~= "item" or not itemLink then
        ClearCursor()
        return
    end

    ClearCursor()
    self:ShowPricePrompt(itemLink)
end

function WB:HandleAddonPayload(payload)
    local parts = Split(payload, "\t")
    local kind = parts[1]

    if kind == "STATE" then
        self:SetAuctionState({
            auctionState = tonumber(parts[3] or "0") or 0,
            seller = tostring(parts[4] or ""),
            bidder = tostring(parts[5] or ""),
            entry = tonumber(parts[6] or "0") or 0,
            count = tonumber(parts[7] or "0") or 0,
            bidCopper = tonumber(parts[8] or "0") or 0,
            itemName = tostring(parts[9] or ""),
            itemLink = tostring(parts[10] or ""),
            remainingMs = tonumber(parts[11] or "0") or 0,
        })
    elseif kind == "CLEAR" then
        self:ClearAuction()
        self:ResetPending()
        self:UpdateUI()
    elseif kind == "MAIL" and parts[2] == "NEW" then
        self.state.mailWaiting = true
        self:UpdateUI()
        Print("Вам надійшов новий лист.")
    elseif kind == "PROMPT" and parts[2] == "CONFIRM_OR_DENY" then
        Print("Продавець має вирішити: підтвердити продаж або відхилити продаж.")
        self:UpdateUI()
    elseif kind == "RESULT" and parts[2] == "WON" then
        Print("Ви виграли аукціон.")
        self.state.mailWaiting = true
        self:UpdateUI()
    elseif kind == "RESULT" and parts[2] == "SOLD" then
        Print("Ваш предмет продано.")
        self:ClearAuction()
    end
end

function WB:UpdateSlotButton()
    if not self.frame or not self.frame.slot then return end
    local slot = self.frame.slot
    local icon = slot.icon

    if self.pending.itemLink and not self.state.active then
        local texture = GetItemIcon(self.pending.itemLink)
        if texture then
            icon:SetTexture(texture)
            icon:Show()
        else
            icon:SetTexture(nil)
            icon:Hide()
        end
        slot.count:SetText((self.pending.count and self.pending.count > 1) and tostring(self.pending.count) or "")
        slot.placeholder:Hide()
        return
    end

    if self.state.active and self.state.itemLink and self.state.itemLink ~= "" then
        local texture = GetItemIcon(self.state.itemLink)
        if texture then
            icon:SetTexture(texture)
            icon:Show()
        else
            icon:SetTexture(nil)
            icon:Hide()
        end
        slot.count:SetText((self.state.count and self.state.count > 1) and tostring(self.state.count) or "")
        slot.placeholder:Hide()
        return
    end

    icon:SetTexture(nil)
    icon:Hide()
    slot.count:SetText("")
    slot.placeholder:Show()
end

function WB:UpdateUI()
    if not self.frame then return end

    local accentColor = "|c" .. (self.accentColor or "ffffcc00")
    local leaderColor = "|c" .. (self.leaderColor or "ffff4040")
    local winnerColor = "|c" .. (self.winnerColor or "ff33ff33")
    local timerColor  = "|c" .. (self.timerColor  or "ffff9933")
    local textColor   = "|c" .. (self.textColor   or "ffffffff")
    local mutedColor  = "|c" .. (self.mutedColor  or "ffb8c7d9")

    local active = self.state.active
    local seller = self:IsPlayerSeller()
    local waitingConfirm = (tonumber(self.state.auctionState) or 0) == 2

    if active then
        self.frame.title:SetText(accentColor .. "Аукціон|r")

        local localizedName = nil
        if self.state.itemLink and self.state.itemLink ~= "" then
            localizedName = GetItemInfo(self.state.itemLink)
        end

        local shownName = localizedName or self.state.itemName or "Предмет"
        if shownName == "" then
            shownName = "Предмет"
        end

        local itemText = accentColor .. shownName .. "|r"

        local topLines = {
            textColor .. "Продавець:|r " .. (self.state.seller ~= "" and self.state.seller or "-"),
            textColor .. "Кількість:|r " .. tostring(tonumber(self.state.count) or 0),
        }

        local infoLines = {
            accentColor .. "Поточна:|r " .. accentColor .. CopperToText(self.state.bidCopper or 0) .. "|r",
        }

        if self.state.bidder and self.state.bidder ~= "" then
            if waitingConfirm then
                table.insert(infoLines, winnerColor .. "Переможець:|r " .. winnerColor .. self.state.bidder .. "|r")
            else
                table.insert(infoLines, leaderColor .. "Лідер:|r " .. leaderColor .. self.state.bidder .. "|r")
            end
        end

        if waitingConfirm then
            table.insert(infoLines, timerColor .. "Підтвердження:|r " .. timerColor .. MsToCountdownText(self.state.remainingMs or 0) .. "|r")
        else
            table.insert(infoLines, timerColor .. "Час:|r " .. timerColor .. MsToCountdownText(self.state.remainingMs or 0) .. "|r")
        end

        self.frame.info:SetText(table.concat(infoLines, "\n"))
        self.frame.details:SetText(itemText .. "\n" .. table.concat(topLines, "\n"))
    else
        self.frame.title:SetText(accentColor .. "Аукціон|r")
        self.frame.info:SetText(mutedColor .. "Поточна: -|r\n" ..
                                mutedColor .. "Лідер: -|r\n" ..
                                mutedColor .. "Час: 0:00|r")
        self.frame.details:SetText(mutedColor .. "Перетягни предмет у слот|r\n" ..
                                   mutedColor .. "Продавець: -|r\n" ..
                                   mutedColor .. "Кількість: 0|r")
    end

    SetVisible(self.frame.raiseBtn, false)
    SetVisible(self.frame.raise50Btn, false)
    SetVisible(self.frame.raise100Btn, false)
    SetVisible(self.frame.myBidBtn, false)
    SetVisible(self.frame.cancelBtn, false)
    SetVisible(self.frame.confirmBtn, false)
    SetVisible(self.frame.denyBtn, false)
    SetVisible(self.frame.bidRowLabel, false)
    SetVisible(self.frame.sellerRowLabel, false)

    if active then
        if seller then
            if waitingConfirm then
                self.frame.cancelBtn:SetWidth(80)
                self.frame.cancelBtn:SetText("Відхилити")
                SetVisible(self.frame.cancelBtn, true)

                self.frame.confirmBtn:SetWidth(92)
                self.frame.confirmBtn:SetText("Підтвердити")
                SetVisible(self.frame.confirmBtn, true)
            else
                self.frame.cancelBtn:SetWidth(175)
                self.frame.cancelBtn:SetText("Скасувати аукціон")
                SetVisible(self.frame.cancelBtn, true)
            end
        else
            if not waitingConfirm then
                SetVisible(self.frame.raiseBtn, true)
                SetVisible(self.frame.raise50Btn, true)
                SetVisible(self.frame.raise100Btn, true)
                SetVisible(self.frame.myBidBtn, true)
            end
        end
    else
        if self.pending.itemLink ~= nil then
            self.frame.cancelBtn:SetWidth(100)
            self.frame.cancelBtn:SetText("Скасувати")
            SetVisible(self.frame.cancelBtn, true)
        end
    end

    SetVisible(self.frame.mailGlow, self.state.mailWaiting and true or false)

    self:UpdateSlotButton()
end

function WB:Toggle()
    if not self.frame then return end
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
        self:UpdateUI()
    end
end

function WB:OpenBagFrame()
    if not self.frame then return end
    self.frame:Show()
    self:UpdateUI()
end

function WB:CloseBagFrame()
    if not self.frame then return end
    self.frame:Hide()
end
function WB:IsStandardBagShown()
    local maxFrames = NUM_CONTAINER_FRAMES or 12
    for i = 1, maxFrames do
        local f = _G["ContainerFrame"..i]
        if f and f:IsShown() then
            return true
        end
    end
    return false
end

function WB:IsAdiBagsShown()
    for i = 1, 20 do
        local f = _G["AdiBagsContainer"..i]
        if f and f.IsShown and f:IsShown() then
            return true
        end
    end

    if _G.AdiBags and type(_G.AdiBags) == "table" then
        if _G.AdiBags.containers and type(_G.AdiBags.containers) == "table" then
            for _, frame in pairs(_G.AdiBags.containers) do
                if frame and frame.IsShown and frame:IsShown() then
                    return true
                end
            end
        end
    end

    return false
end

function WB:IsAnyBagUIShown()
    return self:IsStandardBagShown() or self:IsAdiBagsShown()
end
local function RegisterEscapeFrame(frameName)
    if not frameName or type(UISpecialFrames) ~= "table" then return end
    for _, name in ipairs(UISpecialFrames) do
        if name == frameName then
            return
        end
    end
    table.insert(UISpecialFrames, frameName)
end

function WB:CreateFrame()
    local f = CreateFrame("Frame", "WorldBidMainFrame", UIParent)
    self.frame = f
    f:SetWidth(200)
    f:SetHeight(156)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint(1)
        WorldBidDB.point = {point, "UIParent", relPoint, x, y}
    end)

    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.05, 0.05, 0.05, 0.95)

    EnsureDB()
    local p = WorldBidDB.point
    f:SetPoint(p[1], UIParent, p[3], p[4], p[5])
    f:Hide()
    RegisterEscapeFrame("WorldBidMainFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title = title
    title:SetPoint("TOP", 0, -10)
    title:SetText("WorldBid")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.closeButton = close
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

local helpBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
f.helpButton = helpBtn
helpBtn:SetWidth(36)
helpBtn:SetHeight(20)
helpBtn:SetPoint("TOPLEFT", 8, -8)
helpBtn:SetText("HELP")

helpBtn:SetScript("OnClick", function()
    WB:SendSimpleCommand("HELP")
end)

helpBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Довідка WorldBid")
    GameTooltip:AddLine("Показати список доступних команд.", 1, 1, 1)
    GameTooltip:Show()
end)

helpBtn:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

    local slot = CreateFrame("Button", "WorldBidSingleSlot", f)
    f.slot = slot
    slot:SetWidth(42)
    slot:SetHeight(42)
    slot:SetPoint("TOPLEFT", 14, -30)
    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    slot:RegisterForDrag("LeftButton")

    local slotBg = slot:CreateTexture(nil, "BACKGROUND")
    slot.slotBg = slotBg
    slotBg:SetAllPoints(slot)
    slotBg:SetTexture("Interface\\Buttons\\UI-Quickslot2")

    local icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon = icon
    icon:SetPoint("TOPLEFT", 4, -4)
    icon:SetPoint("BOTTOMRIGHT", -4, 4)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:Hide()

    local placeholder = slot:CreateTexture(nil, "OVERLAY")
    slot.placeholder = placeholder
    placeholder:SetPoint("TOPLEFT", 8, -8)
    placeholder:SetPoint("BOTTOMRIGHT", -8, 8)
    placeholder:SetTexture("Interface\\Buttons\\UI-PlusButton-UP")
    placeholder:SetAlpha(0.35)

    local border = slot:CreateTexture(nil, "OVERLAY")
    slot.border = border
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetPoint("CENTER")
    border:SetWidth(70)
    border:SetHeight(70)
    border:Hide()

    local count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    slot.count = count
    count:SetPoint("BOTTOMRIGHT", -3, 4)

    slot:SetScript("OnReceiveDrag", function() WB:HandleDroppedCursorItem() end)
    slot:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            if WB.state.active and WB:IsPlayerSeller() then
                local waitingConfirm = (tonumber(WB.state.auctionState) or 0) == 2
                if waitingConfirm then
                    WB:SendSimpleCommand("DENY")
                else
                    WB:SendSimpleCommand("CANCEL")
                end
            elseif WB.pending.itemLink then
                WB:ResetPending()
                WB:UpdateUI()
            end
        elseif CursorHasItem() then
            WB:HandleDroppedCursorItem()
        end
    end)
    slot:SetScript("OnEnter", function(btn)
        btn.border:Show()
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        if WB.state.active and WB.state.itemLink and WB.state.itemLink ~= "" then
            GameTooltip:SetHyperlink(WB.state.itemLink)
        elseif WB.pending.itemLink then
            GameTooltip:SetHyperlink(WB.pending.itemLink)
        else
            GameTooltip:AddLine("Слот аукціону")
            GameTooltip:AddLine("Перетягни предмет сюди.", 1, 1, 1)
            GameTooltip:AddLine("ПКМ: очистити або скасувати свій аукціон.", 0.8, 0.8, 0.8)
        end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function(btn)
        btn.border:Hide()
        GameTooltip:Hide()
    end)

    local info = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.info = info
    info:SetWidth(136)
    info:SetJustifyH("LEFT")
    info:SetJustifyV("TOP")
    info:SetPoint("TOPLEFT", slot, "TOPRIGHT", 6, -1)
    info:SetText("Поточна: -\nЛідер: -\nЧас: 0:00")

    local details = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.details = details
    details:SetWidth(206)
    details:SetJustifyH("LEFT")
    details:SetJustifyV("TOP")
    details:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 0, -6)
    details:SetText("Перетягни предмет у слот\nПродавець: -\nКількість: 0")

    local mailGlow = f:CreateTexture(nil, "ARTWORK")
    f.mailGlow = mailGlow
    mailGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    mailGlow:SetBlendMode("ADD")
    mailGlow:SetWidth(70)
    mailGlow:SetHeight(70)
    mailGlow:SetPoint("CENTER", slot, "CENTER", 0, 0)
    mailGlow:Hide()

    local sellerRowLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.sellerRowLabel = sellerRowLabel
    sellerRowLabel:SetPoint("BOTTOMLEFT", 18, 48)
    sellerRowLabel:SetText("")
    sellerRowLabel:Hide()

    local bidRowLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.bidRowLabel = bidRowLabel
    bidRowLabel:SetPoint("BOTTOMLEFT", 18, 48)
    bidRowLabel:SetText("")
    bidRowLabel:Hide()

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.cancelBtn = cancelBtn
    cancelBtn:SetWidth(70)
    cancelBtn:SetHeight(22)
    cancelBtn:SetPoint("BOTTOMLEFT", 14, 14)
    cancelBtn:SetText("Скасувати")
    cancelBtn:SetScript("OnClick", function()
        if WB.state.active and WB:IsPlayerSeller() then
            local waitingConfirm = (tonumber(WB.state.auctionState) or 0) == 2
            if waitingConfirm then
                WB:SendSimpleCommand("DENY")
            else
                WB:SendSimpleCommand("CANCEL")
            end
        elseif WB.pending.itemLink then
            WB:ResetPending()
            WB:UpdateUI()
        end
    end)

    local confirmBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.confirmBtn = confirmBtn
    confirmBtn:SetWidth(64)
    confirmBtn:SetHeight(22)
    confirmBtn:SetPoint("LEFT", cancelBtn, "RIGHT", 4, 0)
    confirmBtn:SetText("Підтв.")
    confirmBtn:SetScript("OnClick", function()
        WB:SendSimpleCommand("CONFIRM")
    end)

    local denyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.denyBtn = denyBtn
    denyBtn:SetWidth(1)
    denyBtn:SetHeight(1)
    denyBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -1000, -1000)
    denyBtn:Hide()
    denyBtn:SetScript("OnClick", function() end)

    local raiseBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.raiseBtn = raiseBtn
    raiseBtn:SetWidth(36)
    raiseBtn:SetHeight(22)
    raiseBtn:SetPoint("BOTTOMLEFT", 14, 14)
    raiseBtn:SetText("+10г")
    raiseBtn:SetScript("OnClick", function()
        WB:SendBidRaise(10)
    end)

    local raise50Btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.raise50Btn = raise50Btn
    raise50Btn:SetWidth(36)
    raise50Btn:SetHeight(22)
    raise50Btn:SetPoint("LEFT", raiseBtn, "RIGHT", 4, 0)
    raise50Btn:SetText("+50г")
    raise50Btn:SetScript("OnClick", function()
        WB:SendBidRaise(50)
    end)

    local raise100Btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.raise100Btn = raise100Btn
    raise100Btn:SetWidth(44)
    raise100Btn:SetHeight(22)
    raise100Btn:SetPoint("LEFT", raise50Btn, "RIGHT", 4, 0)
    raise100Btn:SetText("+100г")
    raise100Btn:SetScript("OnClick", function()
        WB:SendBidRaise(100)
    end)

    local myBidBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.myBidBtn = myBidBtn
    myBidBtn:SetWidth(48)
    myBidBtn:SetHeight(22)
    myBidBtn:SetPoint("LEFT", raise100Btn, "RIGHT", 4, 0)
    myBidBtn:SetText("Моя")

    myBidBtn:SetScript("OnClick", function()
        if not StaticPopupDialogs["WORLDBID_MY_BID"] then
            StaticPopupDialogs["WORLDBID_MY_BID"] = {
                text = "Введіть повну суму ставки в голді",
                button1 = "ОК",
                button2 = "Скасувати",
                hasEditBox = 1,
                timeout = 0,
                whileDead = 1,
                hideOnEscape = 1,
                OnAccept = function(dialog)
                    local v = tonumber(dialog.editBox:GetText() or "")
                    if v and v > 0 then
                        WB:SendBidAbsolute(v)
                    end
                end,
                EditBoxOnEnterPressed = function(editBox)
                    local parent = editBox:GetParent()
                    local v = tonumber(editBox:GetText() or "")
                    if v and v > 0 then
                        WB:SendBidAbsolute(v)
                    end
                    parent:Hide()
                end,
            }
        end
        StaticPopup_Show("WORLDBID_MY_BID")
    end)

    self:UpdateUI()
end

function WB:CreatePromptFrame()
    local p = CreateFrame("Frame", "WorldBidPromptFrame", UIParent)
    self.promptFrame = p
    p:SetWidth(250)
    p:SetHeight(126)
    p:SetPoint("CENTER")
    p:SetFrameStrata("DIALOG")
    p:SetMovable(true)
    p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    p:SetScript("OnDragStop", function(frame) frame:StopMovingOrSizing() end)
    p:Hide()
    RegisterEscapeFrame("WorldBidPromptFrame")

    p:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Параметри аукціону")

    local qtyLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    qtyLabel:SetPoint("TOPLEFT", 24, -42)
    qtyLabel:SetText("Кількість")

    local qtyBox = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    p.countBox = qtyBox
    qtyBox:SetWidth(80)
    qtyBox:SetHeight(20)
    qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 18, 0)
    qtyBox:SetAutoFocus(false)
    qtyBox:SetNumeric(true)
    qtyBox:SetMaxLetters(5)

    local priceLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    priceLabel:SetPoint("TOPLEFT", 24, -70)
    priceLabel:SetText("Старт, г")

    local priceBox = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    p.priceBox = priceBox
    priceBox:SetWidth(80)
    priceBox:SetHeight(20)
    priceBox:SetPoint("LEFT", priceLabel, "RIGHT", 25, 0)
    priceBox:SetAutoFocus(false)
    priceBox:SetNumeric(true)
    priceBox:SetMaxLetters(8)

    local okBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    okBtn:SetWidth(78)
    okBtn:SetHeight(22)
    okBtn:SetPoint("BOTTOMLEFT", 34, 18)
    okBtn:SetText("ОК")
    okBtn:SetScript("OnClick", function()
        local count = tonumber(qtyBox:GetText() or "") or 1
        local price = tonumber(priceBox:GetText() or "") or 0
        if not WB.pending.itemLink then
            Print("Спочатку перетягни предмет.")
            p:Hide()
            return
        end
        if count < 1 then count = 1 end
        if price < 1 then
            Print("Вкажи стартову ціну від 1г.")
            return
        end
        WB.pending.count = count
        WB:SendSell(WB.pending.itemLink, count, price)
        p:Hide()
    end)

    local cancelBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    cancelBtn:SetWidth(78)
    cancelBtn:SetHeight(22)
    cancelBtn:SetPoint("LEFT", okBtn, "RIGHT", 22, 0)
    cancelBtn:SetText("Скасувати")
    cancelBtn:SetScript("OnClick", function()
        p:Hide()
    end)
end

SLASH_WORLDBID1 = "/wbid"
SlashCmdList["WORLDBID"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "" then
        WB:Toggle()
    elseif msg == "show" then
        WB:OpenBagFrame()
    elseif msg == "hide" then
        WB:CloseBagFrame()
    elseif msg == "reset" then
        WorldBidDB.point = {"CENTER", "UIParent", "CENTER", -260, 0}
        if WB.frame then
            WB.frame:ClearAllPoints()
            WB.frame:SetPoint("CENTER", UIParent, "CENTER", -260, 0)
        end
    elseif msg == "cancel" then
        WB:SendSimpleCommand("CANCEL")
    elseif msg == "confirm" then
        WB:SendSimpleCommand("CONFIRM")
    elseif msg == "deny" then
        WB:SendSimpleCommand("DENY")
    elseif msg == "status" then
        WB:SendSimpleCommand("STATUS")
    else
        Print("Команди: /wbid, /wbid show, /wbid hide, /wbid reset, /wbid cancel, /wbid confirm, /wbid deny, /wbid status")
    end
end

hooksecurefunc("PickupContainerItem", function(bag, slot)
    local count = 1
    local link = GetContainerItemLink(bag, slot)
    if link then
        local _, itemCount = GetContainerItemInfo(bag, slot)
        if itemCount and itemCount > 0 then
            count = itemCount
        end
        WB.lastPickup = {
            bag = bag,
            slot = slot,
            count = count,
            link = link,
        }
    end
end)

local function HookBagToggles()
    if OpenBackpack then
        hooksecurefunc("OpenBackpack", function()
            WB:OpenBagFrame()
            WB.lastBagVisible = true
        end)
    end

    if OpenAllBags then
        hooksecurefunc("OpenAllBags", function()
            WB:OpenBagFrame()
            WB.lastBagVisible = true
        end)
    end

    if CloseBackpack then
        hooksecurefunc("CloseBackpack", function()
            WB.lastBagVisible = false
        end)
    end

    if CloseAllBags then
        hooksecurefunc("CloseAllBags", function()
            WB.lastBagVisible = false
        end)
    end
end

WB:SetScript("OnUpdate", function(self, elapsed)
    if self.state and self.state.active and self.state.remainingMs and self.state.remainingMs > 0 then
        local ms = math.floor((elapsed or 0) * 1000)
        if ms > 0 then
            local oldBucket = math.ceil((self.state.remainingMs or 0) / 1000)
            self.state.remainingMs = math.max(0, (self.state.remainingMs or 0) - ms)
            local newBucket = math.ceil((self.state.remainingMs or 0) / 1000)
            if oldBucket ~= newBucket and self.frame and self.frame:IsShown() then
                self:UpdateUI()
            end
        end
    end

    self.bagWatchElapsed = (self.bagWatchElapsed or 0) + (elapsed or 0)
    if self.bagWatchElapsed < 0.15 then
        return
    end
    self.bagWatchElapsed = 0

    local visible = self:IsAnyBagUIShown()

    if visible and not self.lastBagVisible then
        self.lastBagVisible = true
        self:OpenBagFrame()
    elseif not visible and self.lastBagVisible then
        self.lastBagVisible = false
        if not (self.promptFrame and self.promptFrame:IsShown()) then
            self:CloseBagFrame()
        end
    end
end)

WB:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= "WorldBid" then return end
        EnsureDB()
        self:CreateFrame()
        self:CreatePromptFrame()
        HookBagToggles()
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        if prefix == self.prefix then
            self:HandleAddonPayload(message)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        self:CloseBagFrame()
        self:UpdateUI()
    elseif event == "MAIL_INBOX_UPDATE" then
        self.state.mailWaiting = true
        self:UpdateUI()
    end
end)

WB:RegisterEvent("ADDON_LOADED")
WB:RegisterEvent("CHAT_MSG_ADDON")
WB:RegisterEvent("PLAYER_ENTERING_WORLD")
WB:RegisterEvent("MAIL_INBOX_UPDATE")
