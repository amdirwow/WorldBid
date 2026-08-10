
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
WB.announcementsShown = true
WB.announcementsKnown = false
WB.buy = {
    orders = {},
    visibleOrders = {},
    searchResults = {},
    selectedItem = nil,
    listRequest = 0,
    searchRequest = 0,
    page = 1,
    onlyOwned = false,
    onlyMine = false,
    changed = false,
    bagsDirty = false,
    bagRefreshElapsed = 0,
    pendingOrders = {},
}

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
    if WorldBidDB.showMode ~= "bags" and WorldBidDB.showMode ~= "command" then
        WorldBidDB.showMode = "bags"
    end
    if type(WorldBidDB.locked) ~= "boolean" then
        WorldBidDB.locked = false
    end
    if type(WorldBidDB.closeWithBags) ~= "boolean" then
        WorldBidDB.closeWithBags = true
    end
    if type(WorldBidDB.buyOnlyOwned) ~= "boolean" then
        WorldBidDB.buyOnlyOwned = false
    end
    if type(WorldBidDB.buyOnlyMine) ~= "boolean" then
        WorldBidDB.buyOnlyMine = false
    end
    WB.buy.onlyOwned = WorldBidDB.buyOnlyOwned
    WB.buy.onlyMine = WorldBidDB.buyOnlyMine
    if WB.buy.onlyMine then
        WB.buy.onlyOwned = false
        WorldBidDB.buyOnlyOwned = false
    end
end

local function ItemEntryFromLink(link)
    if not link then return 0 end
    return tonumber(string.match(link, "item:(%d+):")) or 0
end

local function ItemQualityHex(quality)
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[tonumber(quality) or 1]
    local hex = color and color.hex or "ffffffff"
    return string.gsub(hex, "^|c", "")
end

local function BuildItemLink(entry, name, quality)
    entry = tonumber(entry) or 0
    if entry <= 0 then return nil end
    local _, cachedLink = GetItemInfo(entry)
    if cachedLink then return cachedLink end
    return string.format("|c%s|Hitem:%d:0:0:0:0:0:0:0:0|h[%s]|h|r", ItemQualityHex(quality), entry, tostring(name or "Предмет"))
end

local function HandleItemModifiedClick(link)
    if not link then return false end
    if IsModifiedClick and (IsModifiedClick("CHATLINK") or IsModifiedClick("DRESSUP")) then
        if HandleModifiedItemClick then
            HandleModifiedItemClick(link)
        elseif IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
            ChatEdit_InsertLink(link)
        elseif DressUpItemLink then
            DressUpItemLink(link)
        end
        return true
    end
    return false
end

function WB:GetBagItemCount(entry)
    entry = tonumber(entry) or 0
    if entry <= 0 then return 0 end

    local total = 0
    local bagCount = NUM_BAG_SLOTS or 4
    for bag = 0, bagCount do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if ItemEntryFromLink(link) == entry then
                local _, count = GetContainerItemInfo(bag, slot)
                total = total + (tonumber(count) or 1)
            end
        end
    end
    return total
end

function WB:RebuildVisibleBuyOrders()
    local visible = {}
    for _, order in ipairs(self.buy.orders or {}) do
        order.have = tonumber(order.serverHave)
        if order.have == nil then
            order.have = self:GetBagItemCount(order.entry)
        end
        local include = true
        if self.buy.onlyMine then
            include = order.isMine
        elseif self.buy.onlyOwned then
            include = order.have > 0
        end
        if include then
            visible[#visible + 1] = order
        end
    end
    self.buy.visibleOrders = visible

    local pageSize = 7
    local maxPage = math.max(1, math.ceil(#visible / pageSize))
    if self.buy.page > maxPage then self.buy.page = maxPage end
    if self.buy.page < 1 then self.buy.page = 1 end
    self:UpdateBuyOrdersUI()
end

function WB:RequestBuyOrders()
    self.buy.listRequest = (self.buy.listRequest or 0) + 1
    self:SendAddonCommand(string.format("BUY\tLIST\t%d", self.buy.listRequest))
end

function WB:SearchBuyItems(query)
    query = tostring(query or "")
    query = string.gsub(query, "[\t\r\n]", " ")
    if string.len(query) < 2 then
        self.buy.searchResults = {}
        self.buy.searchPerformed = false
        self:UpdateBuySearchUI()
        Print("Введіть щонайменше 2 символи для пошуку.")
        return
    end
    self.buy.searchRequest = (self.buy.searchRequest or 0) + 1
    self.buy.searchPerformed = true
    self.buy.searchResults = {}
    self:UpdateBuySearchUI()
    self:SendAddonCommand(string.format("BUY\tSEARCH\t%d\t%s", self.buy.searchRequest, query))
end

function WB:CreateBuyOrder()
    local frame = self.buyFrame
    local selected = self.buy.selectedItem
    if not frame or not selected then
        Print("Спочатку знайдіть і виберіть предмет.")
        return
    end

    local quantity = math.floor(tonumber(frame.quantityBox:GetText() or "") or 0)
    local priceGold = math.floor(tonumber(frame.priceBox:GetText() or "") or 0)
    if quantity < 1 or priceGold < 1 then
        Print("Кількість і ціна за штуку мають бути більші 0.")
        return
    end

    self:SendAddonCommand(string.format("BUY\tCREATE\t%d\t%d\t%d", selected.entry, quantity, priceGold))
end

function WB:FillBuyOrder(order)
    if not order or order.isMine then return end
    local orderId = tostring(order.id or "0")
    if self.buy.pendingOrders[orderId] then return end
    local count = math.min(tonumber(order.have) or 0, tonumber(order.remaining) or 0)
    if count < 1 then
        Print("У сумках немає цього предмета.")
        return
    end
    self.buy.pendingOrders[orderId] = true
    self:UpdateBuyOrdersUI()
    if not self:SendAddonCommand(string.format("BUY\tFILL\t%s\t%d", orderId, count)) then
        self.buy.pendingOrders[orderId] = nil
        self:UpdateBuyOrdersUI()
    end
end

function WB:CancelBuyOrder(order)
    if not order or not order.isMine then return end
    local orderId = tostring(order.id or "0")
    if self.buy.pendingOrders[orderId] then return end
    self.buy.pendingOrders[orderId] = true
    self:UpdateBuyOrdersUI()
    if not self:SendAddonCommand(string.format("BUY\tCANCEL\t%s", orderId)) then
        self.buy.pendingOrders[orderId] = nil
        self:UpdateBuyOrdersUI()
    end
end

function WB:ApplyBuyOrderResult(orderId, remaining, soldCount)
    orderId = tostring(orderId or "0")
    remaining = tonumber(remaining) or 0
    soldCount = tonumber(soldCount) or 0
    self.buy.pendingOrders[orderId] = nil

    for i = #(self.buy.orders or {}), 1, -1 do
        local order = self.buy.orders[i]
        if tostring(order.id) == orderId then
            if remaining <= 0 then
                table.remove(self.buy.orders, i)
            else
                order.remaining = remaining
                order.serverHave = math.max(0, (tonumber(order.serverHave) or 0) - soldCount)
            end
            break
        end
    end

    self:RebuildVisibleBuyOrders()
end

function WB:RequestAnnouncementPreference()
    self.announcementsKnown = false
    self:UpdateSettingsUI()
    if not self:SendAddonCommand("PREFS\tGET") then
        self.announcementsKnown = true
        self:UpdateSettingsUI()
    end
end

function WB:SetAnnouncementsShown(shown)
    local previous = self.announcementsShown
    shown = shown and true or false
    self.announcementsShown = shown
    self.announcementsKnown = false
    self:UpdateSettingsUI()

    local value = shown and "1" or "0"
    if not self:SendAddonCommand("PREFS\tANNOUNCEMENTS\t" .. value) then
        self.announcementsShown = previous
        self.announcementsKnown = true
        self:UpdateSettingsUI()
    end
end

function WB:ShouldFollowBags()
    EnsureDB()
    return WorldBidDB.showMode == "bags"
end

function WB:SetShowMode(mode)
    if mode ~= "bags" and mode ~= "command" then return end
    EnsureDB()
    WorldBidDB.showMode = mode

    local bagsShown = self:IsAnyBagUIShown()
    self.lastBagVisible = bagsShown
    if mode == "bags" and bagsShown then
        self:OpenBagFrame()
    end

    self:UpdateSettingsUI()
end

function WB:SetFrameLocked(locked)
    EnsureDB()
    WorldBidDB.locked = locked and true or false
    if self.frame then
        self.frame:SetMovable(not WorldBidDB.locked)
    end
    self:UpdateSettingsUI()
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

    if kind == "BUY" then
        local subtype = parts[2]
        if subtype == "LIST_BEGIN" and tonumber(parts[3]) == self.buy.listRequest then
            self.buy.orders = {}
        elseif subtype == "LIST_ROW" and tonumber(parts[3]) == self.buy.listRequest then
            local buyerName = tostring(parts[6] or "")
            self.buy.orders[#self.buy.orders + 1] = {
                id = tostring(parts[4] or "0"),
                buyerGuid = tonumber(parts[5] or "0") or 0,
                buyerName = buyerName,
                entry = tonumber(parts[7] or "0") or 0,
                remaining = tonumber(parts[8] or "0") or 0,
                priceCopper = tonumber(parts[9] or "0") or 0,
                serverHave = tonumber(parts[10] or "0") or 0,
                quality = tonumber(parts[11] or "1") or 1,
                name = tostring(parts[12] or "Предмет"),
                isMine = buyerName == (UnitName("player") or ""),
            }
        elseif subtype == "LIST_END" and tonumber(parts[3]) == self.buy.listRequest then
            self.buy.changed = false
            self.buy.bagsDirty = false
            self.buy.bagRefreshElapsed = 0
            self:RebuildVisibleBuyOrders()
        elseif subtype == "SEARCH_BEGIN" and tonumber(parts[3]) == self.buy.searchRequest then
            self.buy.searchResults = {}
            self:UpdateBuySearchUI()
        elseif subtype == "SEARCH_ROW" and tonumber(parts[3]) == self.buy.searchRequest then
            self.buy.searchResults[#self.buy.searchResults + 1] = {
                entry = tonumber(parts[4] or "0") or 0,
                quality = tonumber(parts[5] or "1") or 1,
                name = tostring(parts[6] or "Предмет"),
            }
            self:UpdateBuySearchUI()
        elseif subtype == "SEARCH_END" and tonumber(parts[3]) == self.buy.searchRequest then
            self:UpdateBuySearchUI()
        elseif subtype == "FILL_RESULT" then
            self:ApplyBuyOrderResult(parts[3], parts[5], parts[4])
        elseif subtype == "CANCEL_RESULT" then
            self:ApplyBuyOrderResult(parts[3], 0, 0)
        elseif subtype == "ACTION_ERROR" then
            self.buy.pendingOrders[tostring(parts[3] or "0")] = nil
            self:UpdateBuyOrdersUI()
        elseif subtype == "CHANGED" then
            self.buy.changed = true
            if self.buyFrame and self.buyFrame:IsShown() then
                self:RequestBuyOrders()
            end
        end
    elseif kind == "STATE" then
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
    elseif kind == "PREFS" and parts[2] == "ANNOUNCEMENTS" then
        self.announcementsShown = parts[3] == "1"
        self.announcementsKnown = true
        self:UpdateSettingsUI()
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

function WB:ToggleSettings()
    if not self.settingsFrame then return end
    if self.settingsFrame:IsShown() then
        self.settingsFrame:Hide()
    else
        self.settingsFrame:Show()
        self:UpdateSettingsUI()
        self:RequestAnnouncementPreference()
    end
end

function WB:UpdateSettingsUI()
    if not self.settingsFrame then return end
    EnsureDB()
    local s = self.settingsFrame
    s.bagsMode:SetChecked(WorldBidDB.showMode == "bags" and 1 or nil)
    s.commandMode:SetChecked(WorldBidDB.showMode == "command" and 1 or nil)
    s.lockPosition:SetChecked(WorldBidDB.locked and 1 or nil)
    s.closeWithBags:SetChecked(WorldBidDB.closeWithBags and 1 or nil)
    s.showAnnouncements:SetChecked(self.announcementsShown and 1 or nil)
    if WorldBidDB.showMode == "bags" then
        s.closeWithBags:Enable()
        s.closeWithBags.label:SetTextColor(1, 0.82, 0)
    else
        s.closeWithBags:Disable()
        s.closeWithBags.label:SetTextColor(0.5, 0.5, 0.5)
    end
    if self.announcementsKnown then
        s.showAnnouncements:Enable()
        s.showAnnouncements.label:SetTextColor(1, 1, 1)
    else
        s.showAnnouncements:Disable()
        s.showAnnouncements.label:SetTextColor(0.5, 0.5, 0.5)
    end
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
    f:SetScript("OnDragStart", function(frame)
        if not WorldBidDB.locked then
            frame:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function(frame)
        if WorldBidDB.locked then return end
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
    f:SetMovable(not WorldBidDB.locked)
    f:Hide()
    RegisterEscapeFrame("WorldBidMainFrame")
    f:SetScript("OnHide", function()
        if WB.settingsFrame then
            WB.settingsFrame:Hide()
        end
    end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title = title
    title:SetPoint("TOP", 0, -10)
    title:SetText("WorldBid")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.closeButton = close
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    local settingsBtn = CreateFrame("Button", nil, f)
    f.settingsButton = settingsBtn
    settingsBtn:SetWidth(24)
    settingsBtn:SetHeight(24)
    settingsBtn:SetPoint("TOPRIGHT", close, "TOPLEFT", 5, -4)
    settingsBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    settingsBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    settingsBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")

    local settingsIcon = settingsBtn:CreateTexture(nil, "OVERLAY")
    settingsBtn.icon = settingsIcon
    settingsIcon:SetWidth(12)
    settingsIcon:SetHeight(12)
    settingsIcon:SetPoint("CENTER", 0, 0)
    settingsIcon:SetTexture("Interface\\Icons\\Trade_Engineering")
    settingsIcon:SetTexCoord(0.12, 0.88, 0.12, 0.88)

    settingsBtn:SetScript("OnMouseDown", function(btn)
        btn.icon:ClearAllPoints()
        btn.icon:SetPoint("CENTER", 1, -1)
    end)
    settingsBtn:SetScript("OnMouseUp", function(btn)
        btn.icon:ClearAllPoints()
        btn.icon:SetPoint("CENTER", 0, 0)
    end)
    settingsBtn:SetScript("OnClick", function() WB:ToggleSettings() end)
    settingsBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Налаштування WorldBid")
        GameTooltip:AddLine("Режим показу та поведінка вікна.", 1, 1, 1)
        GameTooltip:Show()
    end)
    settingsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

function WB:UpdateBuySearchUI()
    local f = self.buyFrame
    if not f or not f.searchRows then return end

    local results = self.buy.searchResults or {}
    local visibleRows = #f.searchRows
    local offset = 0
    if f.searchScroll and FauxScrollFrame_Update and FauxScrollFrame_GetOffset then
        FauxScrollFrame_Update(f.searchScroll, #results, visibleRows, 19)
        offset = FauxScrollFrame_GetOffset(f.searchScroll) or 0
    end

    for i, row in ipairs(f.searchRows) do
        local result = results[offset + i]
        if result then
            row.result = result
            row.itemLink = BuildItemLink(result.entry, result.name, result.quality)
            row.icon:SetTexture(GetItemIcon(result.entry) or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.name:SetText("|c" .. ItemQualityHex(result.quality) .. result.name .. "|r")
            row.entry:SetText("#" .. result.entry)
            row:Show()
        else
            row.result = nil
            row.itemLink = nil
            row:Hide()
        end
    end


    if f.searchEmpty then
        if #results == 0 then
            if self.buy.searchPerformed then
                f.searchEmpty:SetText("Нічого не знайдено")
            else
                f.searchEmpty:SetText("Введіть назву та натисніть «Пошук»")
            end
            f.searchEmpty:Show()
        else
            f.searchEmpty:Hide()
        end
    end
end

function WB:UpdateBuyOrdersUI()
    local f = self.buyFrame
    if not f then return end

    local selected = self.buy.selectedItem
    if selected then
        f.selectedItemLink = BuildItemLink(selected.entry, selected.name, selected.quality)
        f.selectedName:SetText("|c" .. ItemQualityHex(selected.quality) .. selected.name .. "|r")
        f.selectedIcon:SetTexture(GetItemIcon(selected.entry) or "Interface\\Icons\\INV_Misc_QuestionMark")
    else
        f.selectedItemLink = nil
        f.selectedName:SetText("Предмет не вибрано")
        f.selectedIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end

    local quantity = math.floor(tonumber(f.quantityBox:GetText() or "") or 0)
    local price = math.floor(tonumber(f.priceBox:GetText() or "") or 0)
    if quantity > 0 and price > 0 then
        f.deposit:SetText(string.format("Застава: |cffffcc00%dг|r", quantity * price))
    else
        f.deposit:SetText("Застава: -")
    end

    f.onlyOwned:SetChecked(self.buy.onlyOwned and true or false)
    f.onlyMine:SetChecked(self.buy.onlyMine and true or false)
    local orders = self.buy.visibleOrders or {}
    local pageSize = #f.orderRows
    local page = self.buy.page or 1
    local first = (page - 1) * pageSize + 1

    for i, row in ipairs(f.orderRows) do
        local order = orders[first + i - 1]
        row.order = order
        if order then
            local have = tonumber(order.have) or 0
            local canSell = not order.isMine and have > 0
            row.itemLink = BuildItemLink(order.entry, order.name, order.quality)
            row.name:SetText("|c" .. ItemQualityHex(order.quality) .. order.name .. "|r")
            row.info:SetText(string.format("%s • x%d • %s/шт.", order.buyerName, order.remaining, CopperToText(order.priceCopper)))
            row.have:SetText(have > 0 and ("|cff50e878Є: " .. have .. "|r") or "|cff888888Немає|r")
            row.icon:SetTexture(GetItemIcon(order.entry) or "Interface\\Icons\\INV_Misc_QuestionMark")
            if canSell then
                row.bg:SetVertexColor(0.08, 0.35, 0.16, 0.55)
            elseif order.isMine then
                row.bg:SetVertexColor(0.35, 0.25, 0.05, 0.45)
            else
                row.bg:SetVertexColor(0.08, 0.08, 0.10, 0.45)
            end
            local pending = self.buy.pendingOrders[tostring(order.id)]
            if pending then
                row.action:SetText("Обробка...")
                row.action:Disable()
            elseif order.isMine then
                row.action:SetText("Скасувати")
                row.action:Enable()
            else
                row.action:SetText("Продати")
                if canSell then row.action:Enable() else row.action:Disable() end
            end
            row:Show()
        else
            row.order = nil
            row.itemLink = nil
            row:Hide()
        end
    end

    local maxPage = math.max(1, math.ceil(#orders / math.max(1, pageSize)))
    f.pageText:SetText(string.format("Сторінка %d/%d • заявок: %d", page, maxPage, #orders))
    if f.ordersEmpty then
        if #orders == 0 then f.ordersEmpty:Show() else f.ordersEmpty:Hide() end
    end
    if page > 1 then f.prev:Enable() else f.prev:Disable() end
    if page < maxPage then f.next:Enable() else f.next:Disable() end
end

function WB:ToggleBuyOrders()
    if not self.buyFrame then return end
    if self.buyFrame:IsShown() then
        self.buyFrame:Hide()
    else
        self.buyFrame:Show()
    end
end

function WB:CreateBuyOrdersFrame()
    local f = CreateFrame("Frame", "WorldBidBuyOrdersFrame", UIParent)
    self.buyFrame = f
    f:SetWidth(720)
    f:SetHeight(540)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame) frame:StopMovingOrSizing() end)
    f:SetScript("OnShow", function()
        WB:RequestBuyOrders()
        WB:RebuildVisibleBuyOrders()
    end)
    f:Hide()
    RegisterEscapeFrame("WorldBidBuyOrdersFrame")

    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })

    local function StylePanel(panel, alpha)
        panel:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        panel:SetBackdropColor(0.025, 0.035, 0.055, alpha or 0.86)
        panel:SetBackdropBorderColor(0.36, 0.43, 0.55, 0.9)
    end

    local function CreateStyledEditBox(parent, width)
        local box = CreateFrame("EditBox", nil, parent)
        box:SetWidth(width)
        box:SetHeight(24)
        box:SetAutoFocus(false)
        box:SetFontObject(GameFontHighlightSmall)
        box:SetTextColor(1, 1, 1)
        box:SetTextInsets(7, 7, 0, 0)
        box:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        box:SetBackdropColor(0.015, 0.02, 0.03, 0.98)
        box:SetBackdropBorderColor(0.45, 0.52, 0.65, 1)
        box:SetScript("OnEditFocusGained", function(edit)
            edit:SetBackdropBorderColor(1, 0.75, 0.18, 1)
        end)
        box:SetScript("OnEditFocusLost", function(edit)
            edit:SetBackdropBorderColor(0.45, 0.52, 0.65, 1)
        end)
        box:SetScript("OnEscapePressed", function(edit) edit:ClearFocus() end)
        return box
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -15)
    title:SetText("Запити на купівлю")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local searchPanel = CreateFrame("Frame", nil, f)
    f.searchPanel = searchPanel
    searchPanel:SetWidth(428)
    searchPanel:SetHeight(166)
    searchPanel:SetPoint("TOPLEFT", 20, -42)
    StylePanel(searchPanel, 0.9)

    local searchTitle = searchPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchTitle:SetPoint("TOPLEFT", 11, -9)
    searchTitle:SetText("1. Знайдіть предмет")

    local searchBox = CreateStyledEditBox(searchPanel, 315)
    f.searchBox = searchBox
    searchBox:SetPoint("TOPLEFT", 10, -30)
    searchBox:SetMaxLetters(60)

    local searchHint = searchPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", searchBox, "LEFT", 8, 0)
    searchHint:SetText("Назва англійською або мовою клієнта")
    searchBox:SetScript("OnTextChanged", function(box)
        if box:GetText() == "" then searchHint:Show() else searchHint:Hide() end
    end)

    local searchBtn = CreateFrame("Button", nil, searchPanel, "UIPanelButtonTemplate")
    searchBtn:SetWidth(82)
    searchBtn:SetHeight(24)
    searchBtn:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
    searchBtn:SetText("Пошук")
    searchBtn:SetScript("OnClick", function() WB:SearchBuyItems(searchBox:GetText()) end)
    searchBox:SetScript("OnEnterPressed", function(box)
        WB:SearchBuyItems(box:GetText())
        box:ClearFocus()
    end)

    local resultsPanel = CreateFrame("Frame", nil, searchPanel)
    f.searchResultsPanel = resultsPanel
    resultsPanel:SetWidth(406)
    resultsPanel:SetHeight(98)
    resultsPanel:SetPoint("TOPLEFT", 10, -58)
    resultsPanel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    resultsPanel:SetBackdropColor(0.01, 0.015, 0.025, 0.94)

    local searchEmpty = resultsPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.searchEmpty = searchEmpty
    searchEmpty:SetPoint("CENTER", 0, 0)
    searchEmpty:SetText("Введіть назву та натисніть «Пошук»")

    f.searchRows = {}
    for i = 1, 5 do
        local row = CreateFrame("Button", nil, resultsPanel)
        f.searchRows[i] = row
        row:SetWidth(386)
        row:SetHeight(19)
        row:SetPoint("TOPLEFT", 1, -1 - ((i - 1) * 19))
        row:SetFrameLevel(resultsPanel:GetFrameLevel() + 2)
        row:RegisterForClicks("LeftButtonUp")

        local bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg = bg
        bg:SetAllPoints(row)
        bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        if i % 2 == 0 then
            bg:SetVertexColor(0.08, 0.10, 0.14, 0.55)
        else
            bg:SetVertexColor(0.035, 0.05, 0.075, 0.55)
        end

        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        local icon = row:CreateTexture(nil, "ARTWORK")
        row.icon = icon
        icon:SetWidth(17)
        icon:SetHeight(17)
        icon:SetPoint("LEFT", 2, 0)

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name = name
        name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        name:SetWidth(305)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)

        local entry = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.entry = entry
        entry:SetPoint("RIGHT", -7, 0)
        entry:SetWidth(55)
        entry:SetJustifyH("RIGHT")

        row:SetScript("OnClick", function(button)
            if not button.result then return end
            if HandleItemModifiedClick(button.itemLink) then return end
            WB.buy.selectedItem = button.result
            WB.buy.searchResults = {}
            WB.buy.searchPerformed = false
            WB:UpdateBuySearchUI()
            WB:UpdateBuyOrdersUI()
        end)
        row:SetScript("OnEnter", function(button)
            if not button.itemLink then return end
            GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(button.itemLink)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Shift+клік: додати посилання в чат", 0.75, 0.82, 1)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:Hide()
    end

    local searchScroll = CreateFrame("ScrollFrame", "WorldBidBuySearchScroll", resultsPanel, "FauxScrollFrameTemplate")
    f.searchScroll = searchScroll
    searchScroll:SetFrameLevel(resultsPanel:GetFrameLevel() + 1)
    searchScroll:SetPoint("TOPLEFT", resultsPanel, "TOPLEFT", 0, -1)
    searchScroll:SetPoint("BOTTOMRIGHT", resultsPanel, "BOTTOMRIGHT", -1, 1)
    searchScroll:SetScript("OnVerticalScroll", function(scroll, offset)
        FauxScrollFrame_OnVerticalScroll(scroll, offset, 19, function() WB:UpdateBuySearchUI() end)
    end)

    local createPanel = CreateFrame("Frame", nil, f)
    f.createPanel = createPanel
    createPanel:SetWidth(244)
    createPanel:SetHeight(166)
    createPanel:SetPoint("TOPRIGHT", -20, -42)
    StylePanel(createPanel, 0.9)

    local createTitle = createPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    createTitle:SetPoint("TOPLEFT", 11, -9)
    createTitle:SetText("2. Створіть заявку")

    local selectedButton = CreateFrame("Button", nil, createPanel)
    f.selectedButton = selectedButton
    selectedButton:SetWidth(34)
    selectedButton:SetHeight(34)
    selectedButton:SetPoint("TOPLEFT", 11, -31)
    selectedButton:RegisterForClicks("LeftButtonUp")
    selectedButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    local selectedIcon = selectedButton:CreateTexture(nil, "ARTWORK")
    f.selectedIcon = selectedIcon
    selectedIcon:SetAllPoints(selectedButton)
    selectedIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

    local selectedBorder = selectedButton:CreateTexture(nil, "OVERLAY")
    selectedBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    selectedBorder:SetPoint("CENTER")
    selectedBorder:SetWidth(58)
    selectedBorder:SetHeight(58)

    local selectedName = createPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.selectedName = selectedName
    selectedName:SetPoint("TOPLEFT", selectedButton, "TOPRIGHT", 8, -2)
    selectedName:SetWidth(178)
    selectedName:SetHeight(34)
    selectedName:SetJustifyH("LEFT")
    selectedName:SetJustifyV("MIDDLE")
    selectedName:SetText("Предмет не вибрано")

    selectedButton:SetScript("OnClick", function()
        HandleItemModifiedClick(f.selectedItemLink)
    end)
    selectedButton:SetScript("OnEnter", function(button)
        if not f.selectedItemLink then return end
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(f.selectedItemLink)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Shift+клік: додати посилання в чат", 0.75, 0.82, 1)
        GameTooltip:Show()
    end)
    selectedButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local qtyLabel = createPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    qtyLabel:SetPoint("TOPLEFT", 12, -77)
    qtyLabel:SetText("Кількість")
    local quantityBox = CreateStyledEditBox(createPanel, 84)
    f.quantityBox = quantityBox
    quantityBox:SetPoint("TOPRIGHT", -11, -72)
    quantityBox:SetNumeric(true)
    quantityBox:SetMaxLetters(6)
    quantityBox:SetText("1")

    local priceLabel = createPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    priceLabel:SetPoint("TOPLEFT", 12, -106)
    priceLabel:SetText("Ціна за 1 шт., г")
    local priceBox = CreateStyledEditBox(createPanel, 84)
    f.priceBox = priceBox
    priceBox:SetPoint("TOPRIGHT", -11, -101)
    priceBox:SetNumeric(true)
    priceBox:SetMaxLetters(7)
    priceBox:SetText("1")

    local deposit = createPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.deposit = deposit
    deposit:SetPoint("BOTTOMLEFT", 12, 15)
    deposit:SetWidth(102)
    deposit:SetJustifyH("LEFT")
    deposit:SetText("Застава: 1г")

    quantityBox:SetScript("OnTextChanged", function() WB:UpdateBuyOrdersUI() end)
    priceBox:SetScript("OnTextChanged", function() WB:UpdateBuyOrdersUI() end)

    local createBtn = CreateFrame("Button", nil, createPanel, "UIPanelButtonTemplate")
    createBtn:SetWidth(116)
    createBtn:SetHeight(24)
    createBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    createBtn:SetText("Створити")
    createBtn:SetScript("OnClick", function() WB:CreateBuyOrder() end)

    local listTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listTitle:SetPoint("TOPLEFT", 23, -220)
    listTitle:SetText("Активні заявки")

    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetWidth(84)
    refresh:SetHeight(22)
    refresh:SetPoint("TOPRIGHT", -23, -214)
    refresh:SetText("Оновити")
    refresh:SetScript("OnClick", function() WB:RequestBuyOrders() end)

    local onlyOwned = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.onlyOwned = onlyOwned
    onlyOwned:SetWidth(24)
    onlyOwned:SetHeight(24)
    onlyOwned:SetPoint("RIGHT", refresh, "LEFT", -174, 0)
    onlyOwned:SetHitRectInsets(0, -160, 0, 0)
    onlyOwned.label = onlyOwned:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    onlyOwned.label:SetPoint("LEFT", onlyOwned, "RIGHT", 1, 0)
    onlyOwned.label:SetText("Лише те, що є в сумках")
    onlyOwned:SetScript("OnClick", function(button)
        WB.buy.onlyOwned = button:GetChecked() and true or false
        if WB.buy.onlyOwned then
            WB.buy.onlyMine = false
            WorldBidDB.buyOnlyMine = false
        end
        WorldBidDB.buyOnlyOwned = WB.buy.onlyOwned
        WB.buy.page = 1
        WB:RebuildVisibleBuyOrders()
    end)

    local onlyMine = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.onlyMine = onlyMine
    onlyMine:SetWidth(24)
    onlyMine:SetHeight(24)
    onlyMine:SetPoint("RIGHT", onlyOwned, "LEFT", -92, 0)
    onlyMine:SetHitRectInsets(0, -82, 0, 0)
    onlyMine.label = onlyMine:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    onlyMine.label:SetPoint("LEFT", onlyMine, "RIGHT", 1, 0)
    onlyMine.label:SetText("Мої запити")
    onlyMine:SetScript("OnClick", function(button)
        WB.buy.onlyMine = button:GetChecked() and true or false
        if WB.buy.onlyMine then
            WB.buy.onlyOwned = false
            WorldBidDB.buyOnlyOwned = false
        end
        WorldBidDB.buyOnlyMine = WB.buy.onlyMine
        WB.buy.page = 1
        WB:RebuildVisibleBuyOrders()
    end)

    local listHeader = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    listHeader:SetPoint("TOPLEFT", 63, -245)
    listHeader:SetText("Предмет / покупець / кількість / ціна")

    local haveHeader = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    haveHeader:SetPoint("TOPRIGHT", -115, -245)
    haveHeader:SetText("У сумках")

    local ordersEmpty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.ordersEmpty = ordersEmpty
    ordersEmpty:SetPoint("CENTER", f, "CENTER", 0, -105)
    ordersEmpty:SetText("Активних заявок за цим фільтром немає")
    ordersEmpty:Hide()

    f.orderRows = {}
    for i = 1, 6 do
        local row = CreateFrame("Button", nil, f)
        f.orderRows[i] = row
        row:SetWidth(676)
        row:SetHeight(38)
        row:SetPoint("TOPLEFT", 22, -259 - ((i - 1) * 40))
        row:RegisterForClicks("LeftButtonUp")

        local bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg = bg
        bg:SetAllPoints(row)
        bg:SetTexture("Interface\\Buttons\\WHITE8X8")

        local separator = row:CreateTexture(nil, "BORDER")
        separator:SetTexture("Interface\\Buttons\\WHITE8X8")
        separator:SetVertexColor(0.35, 0.42, 0.52, 0.35)
        separator:SetHeight(1)
        separator:SetPoint("BOTTOMLEFT", 0, 0)
        separator:SetPoint("BOTTOMRIGHT", 0, 0)

        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        local icon = row:CreateTexture(nil, "ARTWORK")
        row.icon = icon
        icon:SetWidth(32)
        icon:SetHeight(32)
        icon:SetPoint("LEFT", 3, 0)

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name = name
        name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -3)
        name:SetWidth(345)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)

        local info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.info = info
        info:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 8, 3)
        info:SetWidth(430)
        info:SetJustifyH("LEFT")

        local have = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.have = have
        have:SetPoint("RIGHT", row, "RIGHT", -96, 0)
        have:SetWidth(82)
        have:SetJustifyH("RIGHT")

        local action = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.action = action
        action:SetWidth(86)
        action:SetHeight(22)
        action:SetPoint("RIGHT", -4, 0)
        action:SetScript("OnClick", function()
            if not row.order then return end
            if row.order.isMine then WB:CancelBuyOrder(row.order) else WB:FillBuyOrder(row.order) end
        end)

        row:SetScript("OnClick", function(button)
            HandleItemModifiedClick(button.itemLink)
        end)
        row:SetScript("OnEnter", function(button)
            if not button.itemLink then return end
            GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(button.itemLink)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Покупець: " .. tostring(button.order.buyerName), 1, 0.82, 0)
            GameTooltip:AddLine("Потрібно: " .. tostring(button.order.remaining) .. " • У сумках: " .. tostring(button.order.have or 0), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Shift+клік: додати посилання в чат", 0.75, 0.82, 1)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local prev = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.prev = prev
    prev:SetWidth(72)
    prev:SetHeight(22)
    prev:SetPoint("BOTTOMLEFT", 23, 16)
    prev:SetText("Назад")
    prev:SetScript("OnClick", function()
        WB.buy.page = math.max(1, (WB.buy.page or 1) - 1)
        WB:UpdateBuyOrdersUI()
    end)

    local nextBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.next = nextBtn
    nextBtn:SetWidth(72)
    nextBtn:SetHeight(22)
    nextBtn:SetPoint("BOTTOMRIGHT", -23, 16)
    nextBtn:SetText("Далі")
    nextBtn:SetScript("OnClick", function()
        WB.buy.page = (WB.buy.page or 1) + 1
        WB:UpdateBuyOrdersUI()
    end)

    local pageText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.pageText = pageText
    pageText:SetPoint("BOTTOM", 0, 22)

    self:UpdateBuySearchUI()
    self:RebuildVisibleBuyOrders()
end
function WB:CreateSettingsFrame()
    local s = CreateFrame("Frame", "WorldBidSettingsFrame", UIParent)
    self.settingsFrame = s
    s:SetWidth(290)
    s:SetHeight(246)
    s:SetFrameStrata("DIALOG")
    s:SetClampedToScreen(true)
    s:SetPoint("TOPRIGHT", self.frame, "TOPLEFT", -4, 0)
    s:EnableMouse(true)
    s:Hide()
    RegisterEscapeFrame("WorldBidSettingsFrame")

    s:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })

    local title = s:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Налаштування WorldBid")

    local close = CreateFrame("Button", nil, s, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() s:Hide() end)

    local modeTitle = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modeTitle:SetPoint("TOPLEFT", 22, -46)
    modeTitle:SetText("Показ вікна")

    local function CreateOption(name, y, text)
        local option = CreateFrame("CheckButton", nil, s, "UICheckButtonTemplate")
        option:SetWidth(24)
        option:SetHeight(24)
        option:SetPoint("TOPLEFT", 20, y)
        option:SetHitRectInsets(0, -220, 0, 0)
        option.label = option:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        option.label:SetPoint("LEFT", option, "LEFT", 26, 1)
        option.label:SetText(text)
        s[name] = option
        return option
    end

    local bagsMode = CreateOption("bagsMode", -61, "Разом із сумками (Shift+B)")
    bagsMode:SetScript("OnClick", function() WB:SetShowMode("bags") end)

    local commandMode = CreateOption("commandMode", -86, "Тільки вручну командою /wbid")
    commandMode:SetScript("OnClick", function() WB:SetShowMode("command") end)

    local behaviorTitle = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    behaviorTitle:SetPoint("TOPLEFT", 22, -119)
    behaviorTitle:SetText("Поведінка")

    local lockPosition = CreateOption("lockPosition", -134, "Заблокувати позицію вікна")
    lockPosition:SetScript("OnClick", function(btn)
        WB:SetFrameLocked(btn:GetChecked() and true or false)
    end)

    local closeWithBags = CreateOption("closeWithBags", -159, "Закривати разом із сумками")
    closeWithBags:SetScript("OnClick", function(btn)
        WorldBidDB.closeWithBags = btn:GetChecked() and true or false
        WB:UpdateSettingsUI()
    end)

    local showAnnouncements = CreateOption("showAnnouncements", -184, "Показувати оголошення аукціону")
    showAnnouncements:SetScript("OnClick", function(btn)
        WB:SetAnnouncementsShown(btn:GetChecked() and true or false)
    end)
    showAnnouncements:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Оголошення аукціону")
        GameTooltip:AddLine("Стан зберігається сервером окремо для персонажа.", 1, 1, 1)
        GameTooltip:AddLine("Також перемикається командою .bid ignore.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    showAnnouncements:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local resetBtn = CreateFrame("Button", nil, s, "UIPanelButtonTemplate")
    resetBtn:SetWidth(122)
    resetBtn:SetHeight(22)
    resetBtn:SetPoint("BOTTOM", 0, 15)
    resetBtn:SetText("Скинути позицію")
    resetBtn:SetScript("OnClick", function()
        WorldBidDB.point = {"CENTER", "UIParent", "CENTER", -260, 0}
        if WB.frame then
            WB.frame:ClearAllPoints()
            WB.frame:SetPoint("CENTER", UIParent, "CENTER", -260, 0)
        end
    end)

    self:UpdateSettingsUI()
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
    elseif msg == "settings" or msg == "options" then
        if WB.frame and not WB.frame:IsShown() then
            WB:OpenBagFrame()
        end
        WB:ToggleSettings()
    elseif msg == "bags" then
        WB:SetShowMode("bags")
        Print("Режим показу: разом із сумками.")
    elseif msg == "command" then
        WB:SetShowMode("command")
        Print("Режим показу: тільки вручну командою /wbid.")
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
    elseif msg == "buy" or msg == "orders" then
        WB:ToggleBuyOrders()
    else
        Print("Команди: /wbid, /wbid buy, /wbid settings, /wbid bags, /wbid command, /wbid reset, /wbid cancel, /wbid confirm, /wbid deny, /wbid status")
    end
end

SLASH_WORLDBUY1 = "/wbuy"
SLASH_WORLDBUY2 = "/buyorders"
SlashCmdList["WORLDBUY"] = function()
    WB:ToggleBuyOrders()
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
            if WB:ShouldFollowBags() then
                WB:OpenBagFrame()
            end
            WB.lastBagVisible = true
        end)
    end

    if OpenAllBags then
        hooksecurefunc("OpenAllBags", function()
            if WB:ShouldFollowBags() then
                WB:OpenBagFrame()
            end
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

    if self.buy and self.buy.bagsDirty then
        if self.buyFrame and self.buyFrame:IsShown() then
            self.buy.bagRefreshElapsed = (self.buy.bagRefreshElapsed or 0) + (elapsed or 0)
            if self.buy.bagRefreshElapsed >= 0.4 then
                self.buy.bagsDirty = false
                self.buy.bagRefreshElapsed = 0
                self:RequestBuyOrders()
            end
        else
            self.buy.bagsDirty = false
            self.buy.bagRefreshElapsed = 0
        end
    end

    self.bagWatchElapsed = (self.bagWatchElapsed or 0) + (elapsed or 0)
    if self.bagWatchElapsed < 0.15 then
        return
    end
    self.bagWatchElapsed = 0

    local visible = self:IsAnyBagUIShown()

    if not self:ShouldFollowBags() then
        self.lastBagVisible = visible
        return
    end

    if visible and not self.lastBagVisible then
        self.lastBagVisible = true
        self:OpenBagFrame()
    elseif not visible and self.lastBagVisible then
        self.lastBagVisible = false
        if WorldBidDB.closeWithBags and not (self.promptFrame and self.promptFrame:IsShown()) then
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
        self:CreateSettingsFrame()
        self:CreatePromptFrame()
        self:CreateBuyOrdersFrame()
        HookBagToggles()
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        if prefix == self.prefix then
            self:HandleAddonPayload(message)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        self:CloseBagFrame()
        self:UpdateUI()
        self:RequestAnnouncementPreference()
    elseif event == "MAIL_INBOX_UPDATE" then
        self.state.mailWaiting = true
        self:UpdateUI()
    elseif event == "BAG_UPDATE" then
        if self.buyFrame and self.buyFrame:IsShown() then
            self.buy.bagsDirty = true
            self.buy.bagRefreshElapsed = 0
        end
    end
end)

WB:RegisterEvent("ADDON_LOADED")
WB:RegisterEvent("CHAT_MSG_ADDON")
WB:RegisterEvent("PLAYER_ENTERING_WORLD")
WB:RegisterEvent("MAIL_INBOX_UPDATE")
WB:RegisterEvent("BAG_UPDATE")
