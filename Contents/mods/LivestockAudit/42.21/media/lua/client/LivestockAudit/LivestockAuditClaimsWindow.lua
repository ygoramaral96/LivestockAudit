-- LivestockAuditClaimsWindow -- "Animal Claims" in the vanilla Admin Panel.
--
-- Staff sees every animal claim -- the owner, what it lets EVERYONE do, the friends the owner
-- let in, the last sighting, when it expires -- and, with the role for it, acts on one:
-- release it, clear its public flags, transfer it to a player online, or release the
-- "ghosts" of a page (claims whose animal nobody has seen for days). Without it, "whose
-- sheep is this and what does it let people do?" costs a read of the save.
--
-- The list comes from this mod's server one page at a time (LivestockAuditQuery,
-- module LivestockAudit). The actions go to the claim store's own server, on the network
-- module the claim source names (actionModule, LivestockAuditApi); that server checks the
-- role again, refuses without a reason and writes the audit with the staff member as author.
-- A source that names no module leaves the window read-only.
-- Looking takes AnswerTickets, acting AnimalCheats, teleporting TeleportToCoordinates.
-- Same look as "Animal Events" (the vanilla PVP Log Tool).

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextBox"
require "ISUI/ISModalDialog"
require "LivestockAudit/LivestockAuditApi"
require "LivestockAudit/LivestockAuditClaimsCore"
require "LivestockAudit/LivestockAuditText"
require "LivestockAudit/LivestockAuditAdminPanel"

local Claims = LivestockAuditClaimsCore
local Text = LivestockAuditText
local EventsWindow = LivestockAuditAdminWindow

local NET = "LivestockAudit"
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local PAD = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6
local LINE_HGT = FONT_HGT_SMALL + 2
local DETAIL_LINES = 6
local WINDOW_WIDTH, WINDOW_HEIGHT = 1100, 680
-- The server takes one request of this mod per player every 500 ms and drops the rest
-- (LivestockAuditQuery, REQUEST_COOLDOWN_MS): a filter changed faster than that waits
-- its turn here, so the list on screen is always the one for the filters on screen.
local REQUEST_GAP_MS = 600
-- column x inside a row: animal | owner | kind | seen | in world | friends | public | expires
local COL_OWNER, COL_KIND, COL_SEEN, COL_LOADED, COL_FRIENDS, COL_PUBLIC, COL_EXPIRES =
    250, 420, 500, 600, 690, 770, 900

local function hasCapability(capability)
    local player = getPlayer()
    local role = player and player:getRole()
    return role ~= nil and role:hasCapability(capability)
end

local function canSeeClaims() return hasCapability(Capability.AnswerTickets) end
-- The claim server's network module, or nil when the source takes no staff actions.
local function claimsNet()
    local source = LivestockAudit.source()
    return source and source.actionModule and source.actionModule()
end

local function canActOnClaims() return claimsNet() ~= nil and hasCapability(Capability.AnimalCheats) end

-- Cut to fit `maxWidth` pixels, with "..." when cut.
local function fit(text, maxWidth)
    local measure = getTextManager()
    if measure:MeasureStringX(UIFont.Small, text) <= maxWidth then return text end
    while #text > 0 and measure:MeasureStringX(UIFont.Small, text .. "...") > maxWidth do
        text = text:sub(1, -2)
    end
    return text .. "..."
end

-- Empty data in a combo means "no filter"; it travels as nil.
local function comboValue(combo)
    local data = combo:getOptionData(combo.selected)
    if data == nil or data == "" then return nil end
    return data
end

-- What the server answers after an action, as the arguments of its "done" line.
local DONE_ARGS = {
    unclaim = function() return {} end,
    clearPublic = function(result) return { tostring(result.cleared) } end,
    transfer = function(result) return { tostring(result.toName) } end,
    unclaimMany = function(result) return { tostring(result.released), tostring(result.kept) } end,
}

-- ------------------------------------------------------------------ the window
LivestockAuditClaimsWindow = ISPanel:derive("LivestockAuditClaimsWindow")
local Window = LivestockAuditClaimsWindow

function Window:new(width, height)
    local x = getCore():getScreenWidth() / 2 - width / 2
    local y = getCore():getScreenHeight() / 2 - height / 2
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.moveWithMouse = true
    o.page, o.pages, o.total, o.now = 1, 1, 0, 0
    o.filter = {}
    o.items = {}
    o.onlineNames = {}
    o.isLoading = true
    o.wantedPage = nil      -- the page to ask for on the next tick the server takes
    o.lastRequestAt = 0
    Window.instance = o
    return o
end

local function addButton(self, x, y, width, title, internal)
    local button = ISButton:new(x, y, width, BUTTON_HGT, title, self, Window.onClick)
    button.internal = internal
    button:initialise()
    button:instantiate()
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.1 }
    self:addChild(button)
    return button
end

local function addCombo(self, x, y, width, firstLabel, onChange)
    local combo = ISComboBox:new(x, y, width, BUTTON_HGT, self, onChange)
    combo:initialise()
    self:addChild(combo)
    combo:addOptionWithData(firstLabel, "")
    return combo
end

local function addFilterCombo(self, x, top, width, firstLabel, options)
    local combo = addCombo(self, x, top, width, firstLabel, Window.onFilterChanged)
    for _, option in ipairs(options) do combo:addOptionWithData(option[1], option[2]) end
    return combo
end

function Window:initialise()
    ISPanel.initialise(self)
    local top = FONT_HGT_MEDIUM + PAD * 3 + LINE_HGT   -- under the title and the summary line
    local week, month = tostring(Claims.WEEK_DAYS), tostring(Claims.MONTH_DAYS)

    self.ownerCombo = addFilterCombo(self, PAD, top, 200, getText("UI_LivestockAudit_AllOwners"), {})
    self.typeCombo = addFilterCombo(self, self.ownerCombo:getRight() + PAD, top, 140, getText("UI_LivestockAudit_AllTypes"), {})
    self.kindCombo = addFilterCombo(self, self.typeCombo:getRight() + PAD, top, 110, getText("UI_LivestockAudit_AllClaimKinds"), {
        { getText("UI_LivestockAudit_ClaimKind_farm"), "farm" }, { getText("UI_LivestockAudit_ClaimKind_dog"), "dog" },
    })
    self.publicCombo = addFilterCombo(self, self.kindCombo:getRight() + PAD, top, 150, getText("UI_LivestockAudit_PublicAny"), {
        { getText("UI_LivestockAudit_PublicOpen"), "open" }, { getText("UI_LivestockAudit_PublicPickup"), "pickup" },
    })
    self.unseenCombo = addFilterCombo(self, self.publicCombo:getRight() + PAD, top, 140, getText("UI_LivestockAudit_SeenAny"), {
        { getText("UI_LivestockAudit_UnseenFor", week), Claims.WEEK_DAYS }, { getText("UI_LivestockAudit_UnseenFor", month), Claims.MONTH_DAYS },
    })
    self.expiresCombo = addFilterCombo(self, self.unseenCombo:getRight() + PAD, top, 140, getText("UI_LivestockAudit_ExpiresAny"), {
        { getText("UI_LivestockAudit_ExpiresWithin", week), Claims.WEEK_DAYS }, { getText("UI_LivestockAudit_ExpiresWithin", month), Claims.MONTH_DAYS },
    })
    self.refreshButton = addButton(self, self.expiresCombo:getRight() + PAD, top, 90, getText("UI_LivestockAudit_Refresh"), "REFRESH")

    local navY = self.height - PAD - BUTTON_HGT
    local actionsY = navY - PAD - BUTTON_HGT
    self.detailTop = actionsY - PAD - DETAIL_LINES * LINE_HGT
    local listTop = top + BUTTON_HGT + PAD
    self.list = ISScrollingListBox:new(PAD, listTop, self.width - PAD * 2, self.detailTop - PAD - listTop)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = BUTTON_HGT
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list.doDrawItem = Window.drawRow
    self.list.window = self
    self:addChild(self.list)

    self.historyButton = addButton(self, PAD, actionsY, 110, getText("UI_LivestockAudit_HistoryButton"), "HISTORY")
    self.teleportButton = addButton(self, self.historyButton:getRight() + PAD, actionsY, 110, getText("UI_LivestockAudit_Teleport"), "TELEPORT")
    self.clearPublicButton = addButton(self, self.teleportButton:getRight() + PAD, actionsY, 150, getText("UI_LivestockAudit_ClearPublic"), "CLEAR_PUBLIC")
    self.releaseButton = addButton(self, self.clearPublicButton:getRight() + PAD, actionsY, 130, getText("UI_LivestockAudit_Release"), "RELEASE")
    self.transferCombo = addCombo(self, self.releaseButton:getRight() + PAD * 3, actionsY, 200, getText("UI_LivestockAudit_TransferTo"), nil)
    self.transferButton = addButton(self, self.transferCombo:getRight() + PAD, actionsY, 120, getText("UI_LivestockAudit_Transfer"), "TRANSFER")

    self.closeButton = addButton(self, PAD, navY, 120, getText("UI_LivestockAudit_Close"), "CLOSE")
    self.closeButton:enableCancelColor()
    self.previousButton = addButton(self, self.width / 2 - 250, navY, 120, getText("UI_LivestockAudit_Previous"), "PREVIOUS")
    self.nextButton = addButton(self, self.width / 2 + 130, navY, 120, getText("UI_LivestockAudit_Next"), "NEXT")
    self.unseenButton = addButton(self, self.width - PAD - 260, navY, 260, getText("UI_LivestockAudit_ReleaseUnseen"), "RELEASE_UNSEEN")

    self:request(1)
    if canActOnClaims() then sendClientCommand(claimsNet(), "adminOnline", {}) end
end

-- ------------------------------------------------------------------ the list
function Window:request(page)
    self.wantedPage = page
    self.isLoading = true
end

function Window:update()
    ISPanel.update(self)
    if not self.wantedPage or getTimestampMs() - self.lastRequestAt < REQUEST_GAP_MS then return end
    sendClientCommand(NET, "claims", { filter = self.filter, page = self.wantedPage })
    self.lastRequestAt = getTimestampMs()
    self.wantedPage = nil
end

function Window:onFilterChanged()
    self.filter = {
        owner = comboValue(self.ownerCombo), type = comboValue(self.typeCombo), kind = comboValue(self.kindCombo),
        public = comboValue(self.publicCombo), unseenDays = comboValue(self.unseenCombo),
        expiresDays = comboValue(self.expiresCombo),
    }
    self:request(1)
end

-- Back to the first option, then to `keep` if it is still there. ISComboBox:clear() keeps the
-- selected INDEX and selectData() keeps it when the value is gone: without the reset the combo
-- would quietly point at whoever took that place in the new list.
local function reselect(combo, keep)
    combo.selected = 1
    combo:selectData(keep or "")
end

-- The owner and species lists come with every page (claims come and go); the choice survives.
local function refill(combo, firstKey, entries, optionOf, keep)
    combo:clear()
    combo:addOptionWithData(getText(firstKey), "")
    for _, entry in ipairs(entries) do
        local text, data = optionOf(entry)
        combo:addOptionWithData(text, data)
    end
    reselect(combo, keep)
end

function Window:selectedRow()
    local listed = self.list.items[self.list.selected]
    return listed and listed.item
end

function Window:fill(args)
    local selected = self:selectedRow()
    self.isLoading = false
    self.page, self.pages, self.total, self.now = args.page, args.pages, args.total, args.now
    self.summary, self.timeoutHours = args.summary, args.timeoutHours
    self.noSource = args.noSource == true
    refill(self.ownerCombo, "UI_LivestockAudit_AllOwners", args.owners, function(owner)
        return getText("UI_LivestockAudit_OwnerCount", owner.name, tostring(owner.count)), owner.sid
    end, self.filter.owner)
    refill(self.typeCombo, "UI_LivestockAudit_AllTypes", args.types, function(animalType)
        return getText("IGUI_AnimalType_" .. animalType), animalType
    end, self.filter.type)
    -- the owner (or species) filtered on is gone from the lists -- staff released their last
    -- animal: the combo fell back to "all", so the filter follows and the page is asked again
    local owner, animalType = comboValue(self.ownerCombo), comboValue(self.typeCombo)
    if owner ~= self.filter.owner or animalType ~= self.filter.type then
        self.filter.owner, self.filter.type = owner, animalType
        self:request(1)
    end
    self.items = args.items
    self.list:clear()
    for _, row in ipairs(args.items) do self.list:addItem(Text.animal(row), row) end
    -- the row stays selected across a refresh, so an action's result shows on it
    self.list.selected = 0
    for index, listed in ipairs(self.list.items) do
        if selected and listed.item.aid == selected.aid then self.list.selected = index end
    end
    self.previousButton:setEnable(self.page > 1)
    self.nextButton:setEnable(self.page < self.pages)
end

function Window.drawRow(list, y, row, alt)
    local item = row.item
    local window = list.window
    if list.selected == row.index then
        list:drawRect(0, y, list:getWidth(), list.itemheight - 1, 0.3, 0.7, 0.35, 0.15)
    end
    list:drawRectBorder(0, y, list:getWidth(), list.itemheight - 1, 0.9, list.borderColor.r, list.borderColor.g, list.borderColor.b)
    local textY = y + 3
    list:drawText(fit(row.text, COL_OWNER - PAD * 2), PAD, textY, 1, 1, 1, 1, UIFont.Small)
    list:drawText(fit(item.ownerName, COL_KIND - COL_OWNER - PAD), COL_OWNER, textY, 0.8, 0.8, 0.8, 1, UIFont.Small)
    list:drawText(getText("UI_LivestockAudit_ClaimKind_" .. item.kind), COL_KIND, textY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    local seen = item.seenAt and Text.ago(window.now - item.seenAt) or "?"
    list:drawText(seen, COL_SEEN, textY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    if item.loaded then
        list:drawText(getText("UI_LivestockAudit_InWorld"), COL_LOADED, textY, 0.55, 0.85, 0.35, 1, UIFont.Small)
    end
    list:drawText(tostring(#item.friends), COL_FRIENDS, textY, 0.8, 0.8, 0.8, 1, UIFont.Small)
    -- amber: something is open to every player on the server
    local publicCount = #item.publicOn
    if publicCount > 0 then
        list:drawText(getText("UI_LivestockAudit_PublicCount", tostring(publicCount)), COL_PUBLIC, textY, 1, 0.7, 0.2, 1, UIFont.Small)
    else
        list:drawText("-", COL_PUBLIC, textY, 0.5, 0.5, 0.5, 1, UIFont.Small)
    end
    list:drawText(Text.translate(Claims.expiry(item.expiresIn, window.timeoutHours)), COL_EXPIRES, textY, 0.8, 0.8, 0.8, 1, UIFont.Small)
    return y + list.itemheight
end

-- ------------------------------------------------------------------ what the window draws
local function joinedFlags(flags)
    local names = {}
    for _, flag in ipairs(flags) do table.insert(names, Text.flag(flag)) end
    return table.concat(names, ", ")
end

local function joinedFriends(friends)
    local names = {}
    for _, friend in ipairs(friends) do
        table.insert(names, getText("UI_LivestockAudit_FriendFlags", friend.name, tostring(#friend.on)))
    end
    return table.concat(names, ", ")
end

local function describeAnimal(row)
    local parts = { Text.animal(row) }
    if row.breed then table.insert(parts, getText("IGUI_Breed_" .. row.breed)) end
    if row.female == true then table.insert(parts, getText("UI_LivestockAudit_Female")) end
    if row.female == false then table.insert(parts, getText("UI_LivestockAudit_Male")) end
    return table.concat(parts, " - ")
end

function Window:detailLines(row)
    local public = #row.publicOn > 0 and joinedFlags(row.publicOn) or getText("UI_LivestockAudit_NothingPublic")
    local friends = #row.friends > 0 and joinedFriends(row.friends) or getText("UI_LivestockAudit_NoFriends")
    local ownerSeen = row.lastLogon and Text.ago(self.now - row.lastLogon) or "?"
    local claimed = row.claimTime and Text.when(row.claimTime) or "?"
    local seen = row.seenAt and Text.ago(self.now - row.seenAt) or "?"
    local where = tostring(row.x) .. "," .. tostring(row.y) .. "," .. tostring(row.z)
    return {
        getText("UI_LivestockAudit_DetailAnimal", describeAnimal(row), getText("UI_LivestockAudit_ClaimKind_" .. row.kind), row.aid),
        getText("UI_LivestockAudit_DetailOwner", row.ownerName, row.owner, ownerSeen),
        getText("UI_LivestockAudit_DetailClaimed", claimed, Text.origin(row.origin),
            Text.translate(Claims.expiry(row.expiresIn, self.timeoutHours))),
        getText("UI_LivestockAudit_DetailPublic", public),
        getText("UI_LivestockAudit_DetailFriends", friends),
        getText("UI_LivestockAudit_DetailWhere", where, seen,
            getText(row.loaded and "UI_LivestockAudit_LoadedNow" or "UI_LivestockAudit_NotLoaded")),
    }
end

function Window:summaryLine()
    local s = self.summary
    return table.concat({
        getText("UI_LivestockAudit_SummaryClaims", tostring(s.total), tostring(s.farm), tostring(s.dog)),
        getText("UI_LivestockAudit_SummaryOwners", tostring(s.owners), s.slotsUsed .. "/" .. s.slotsTotal, tostring(s.slotsBought)),
        getText("UI_LivestockAudit_SummaryPublic", tostring(s.publicOpen), tostring(s.publicPickup)),
        getText("UI_LivestockAudit_SummaryUnseen", tostring(s.unseenWeek), tostring(s.unseenMonth)),
    }, "   |   ")
end

-- The ghosts of the page on screen, as { aid, owner } (the server checks both again). One
-- loaded now is not a ghost, whatever its last sighting says: the sweep refreshes seenAt
-- only some records a minute.
function Window:unseenClaims()
    local claims = {}
    local days = self.filter.unseenDays
    if not days then return claims end
    for _, row in ipairs(self.items) do
        if not row.loaded and Claims.isUnseen(row, days, self.now) then
            table.insert(claims, { aid = row.aid, owner = row.owner })
        end
    end
    return claims
end

function Window:updateButtons()
    local row = self:selectedRow()
    local canAct = canActOnClaims()
    self.historyButton:setEnable(row ~= nil)
    self.teleportButton:setEnable(row ~= nil and hasCapability(Capability.TeleportToCoordinates))
    self.clearPublicButton:setEnable(canAct and row ~= nil and #row.publicOn > 0)
    self.releaseButton:setEnable(canAct and row ~= nil)
    -- a dog is not transferred: it follows its owner, not a pen
    self.transferButton:setEnable(canAct and row ~= nil and row.kind ~= "dog" and comboValue(self.transferCombo) ~= nil)
    self.unseenButton:setEnable(canAct and #self:unseenClaims() > 0)
end

function Window:prerender()
    ISPanel.prerender(self)
    local title = getText("UI_LivestockAudit_ClaimsTitle")
    self:drawText(title, self.width / 2 - getTextManager():MeasureStringX(UIFont.Medium, title) / 2, PAD, 1, 1, 1, 1, UIFont.Medium)
    local summaryY = FONT_HGT_MEDIUM + PAD * 2
    if self.summary then
        self:drawText(fit(self:summaryLine(), self.width - PAD * 2), PAD, summaryY, 0.85, 0.85, 0.85, 1, UIFont.Small)
    end

    local row = self:selectedRow()
    local lines = row and self:detailLines(row) or { getText("UI_LivestockAudit_PickAClaim") }
    for i, line in ipairs(lines) do
        self:drawText(fit(line, self.width - PAD * 2), PAD, self.detailTop + (i - 1) * LINE_HGT, 0.9, 0.9, 0.9, 1, UIFont.Small)
    end

    local status
    if self.isLoading then
        status = getText("UI_LivestockAudit_Loading")
    elseif self.noSource then
        status = getText("UI_LivestockAudit_NoClaimSource")
    elseif self.total == 0 then
        status = getText("UI_LivestockAudit_NoClaims")
    else
        status = getText("UI_LivestockAudit_ClaimsPageOf", tostring(self.page), tostring(self.pages), tostring(self.total))
    end
    if self.actionStatus then status = self.actionStatus .. "   " .. status end
    local statusY = self.previousButton:getY() + 3
    self:drawText(status, self.width / 2 - getTextManager():MeasureStringX(UIFont.Small, status) / 2, statusY, 0.9, 0.9, 0.9, 1, UIFont.Small)
    self:updateButtons()
end

-- ------------------------------------------------------------------ acting
-- The reason box every action opens. OK stays off until the reason has REASON_MIN
-- characters; the server refuses a shorter one anyway.
function Window:askReason(question, send)
    local box = ISTextBox:new(0, 0, 460, 180, question, "", self, Window.onReason, getPlayer():getPlayerNum(), send)
    box:setValidateFunction(nil, function(_, text) return Claims.isReason(text) end)
    box:setValidateTooltipText(getText("UI_LivestockAudit_ReasonHint", tostring(Claims.REASON_MIN)))
    box:initialise()
    box:addToUIManager()
end

function Window:onReason(button, send)
    if button.internal ~= "OK" then return end
    send(button.parent.entry:getText())
end

function Window:act(command, args)
    self.actionStatus = getText("UI_LivestockAudit_Working")
    sendClientCommand(claimsNet(), command, args)
end

-- Every action carries the owner the window showed: the server refuses ("changed") when the
-- animal has changed hands since, instead of acting on someone else's claim.
function Window:release(row)
    self:askReason(getText("UI_LivestockAudit_AskRelease", Text.animal(row), row.ownerName), function(reason)
        self:act("adminUnclaim", { aid = row.aid, owner = row.owner, reason = reason })
    end)
end

function Window:clearPublic(row)
    self:askReason(getText("UI_LivestockAudit_AskClearPublic", tostring(#row.publicOn), Text.animal(row)), function(reason)
        self:act("adminClearPublic", { aid = row.aid, owner = row.owner, reason = reason })
    end)
end

-- The request is kept for the override box: if the answer is "no room", YES resends THIS
-- transfer, whatever was sent in between.
function Window:transfer(row)
    local toSid = comboValue(self.transferCombo)
    local toName = self.onlineNames[toSid] or toSid
    self:askReason(getText("UI_LivestockAudit_AskTransfer", Text.animal(row), row.ownerName, toName), function(reason)
        self.transferRequest = { aid = row.aid, owner = row.owner, toSid = toSid, reason = reason }
        self:act("adminTransfer", self.transferRequest)
    end)
end

-- The question names how many go: this is the confirmation of the batch.
function Window:releaseUnseen()
    local days = self.filter.unseenDays
    local claims = self:unseenClaims()
    self:askReason(getText("UI_LivestockAudit_AskUnseen", tostring(#claims), tostring(days)), function(reason)
        self:act("adminUnclaimMany", { claims = claims, unseenDays = days, reason = reason })
    end)
end

-- The new owner has no room in that pot: staff may pass over it, knowing.
function Window:askOverride(result)
    local box = ISModalDialog:new(0, 0, 440, 160,
        getText("UI_LivestockAudit_AskOverride", tostring(result.owned), tostring(result.budget),
            getText("UI_LivestockAudit_ClaimKind_" .. tostring(result.kind))),
        true, self, Window.onOverride, getPlayer():getPlayerNum(), self.transferRequest)
    box:initialise()
    box:addToUIManager()
end

function Window:onOverride(button, request)
    if button.internal ~= "YES" or not request then return end
    request.override = true
    self:act("adminTransfer", request)
end

function Window:onActionResult(result)
    if result.code == "noslot" then
        self.actionStatus = nil
        self:askOverride(result)
        return
    end
    if result.ok then
        local argsOf = DONE_ARGS[result.action] or DONE_ARGS.unclaim
        self.actionStatus = Text.translate("UI_LivestockAudit_Done_" .. tostring(result.action), argsOf(result))
    else
        self.actionStatus = getText("UI_LivestockAudit_Refused_" .. tostring(result.code))
    end
    self:request(self.page)
    if canActOnClaims() then sendClientCommand(claimsNet(), "adminOnline", {}) end
end

function Window:fillOnline(list)
    local keep = comboValue(self.transferCombo)
    self.onlineNames = {}
    self.transferCombo:clear()
    self.transferCombo:addOptionWithData(getText("UI_LivestockAudit_TransferTo"), "")
    for _, online in ipairs(list) do
        self.onlineNames[online.sid] = online.name
        self.transferCombo:addOptionWithData(online.name, online.sid)
    end
    -- a target who left the server leaves the choice empty, never on the next name in the list
    reselect(self.transferCombo, keep)
end

function Window:onClick(button)
    local internal = button.internal
    if internal == "CLOSE" then self:close() return end
    if internal == "REFRESH" then self:request(self.page) return end
    if internal == "PREVIOUS" then self:request(self.page - 1) return end
    if internal == "NEXT" then self:request(self.page + 1) return end
    if internal == "RELEASE_UNSEEN" then self:releaseUnseen() return end
    local row = self:selectedRow()
    if not row then return end
    if internal == "HISTORY" then EventsWindow.open({ aid = row.aid, label = Text.animal(row) }) return end
    if internal == "TELEPORT" then EventsWindow.teleportTo(row) return end
    if internal == "RELEASE" then self:release(row) return end
    if internal == "CLEAR_PUBLIC" then self:clearPublic(row) return end
    if internal == "TRANSFER" then self:transfer(row) end
end

function Window:close()
    self:setVisible(false)
    self:removeFromUIManager()
    Window.instance = nil
end

Events.OnServerCommand.Add(function(module, command, args)
    local window = Window.instance
    if not window then return end
    if module == NET and command == "claimsResult" then
        window:fill(args)
    elseif module == claimsNet() and command == "adminActionResult" then
        window:onActionResult(args)
    elseif module == claimsNet() and command == "adminOnline" then
        window:fillOnline(args.list)
    end
end)

-- ------------------------------------------------------------------ the Admin Panel button
local function openWindow()
    if Window.instance then Window.instance:close() end
    local window = Window:new(WINDOW_WIDTH, WINDOW_HEIGHT)
    window:initialise()
    window:addToUIManager()
end

EventsWindow.addAdminButton({
    title = "UI_LivestockAudit_ClaimsButton", tooltip = "UI_LivestockAudit_ClaimsButtonTooltip",
    open = openWindow, canUse = canSeeClaims,
})
