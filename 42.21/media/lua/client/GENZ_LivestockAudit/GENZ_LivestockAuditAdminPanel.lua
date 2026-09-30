-- GENZ_LivestockAuditAdminPanel -- "Animal Events" in the vanilla Admin Panel (card #192, F2).
--
-- A button that takes its place among the vanilla ones, and a window in the style of the
-- vanilla PVP Log Tool (ISPVPLogToolUI): owner and kind filters, a page of events, teleport
-- to where one happened. The rows come from the server one page at a time; this file never
-- sees the store. The button is enabled only for AnswerTickets, and the server checks the
-- role again before answering (GENZ_LivestockAuditQuery).

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISScrollingListBox"
require "ISUI/AdminPanel/ISAdminPanelUI"
require "GENZ_LivestockAudit/GENZ_LivestockAuditCore"
require "GENZ_LivestockAudit/GENZ_LivestockAuditText"

local Core = GENZ_LivestockAuditCore
local Text = GENZ_LivestockAuditText

local NET = "GENZ_LivestockAudit"
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local PAD = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6
local WINDOW_WIDTH, WINDOW_HEIGHT = 1000, 600
-- column x inside a row: when | where | animal | owner | what happened (last: it is the long one)
local COL_WHERE, COL_ANIMAL, COL_OWNER, COL_EVENT = 100, 210, 380, 540

local function hasCapability(capability)
    local player = getPlayer()
    local role = player and player:getRole()
    return role ~= nil and role:hasCapability(capability)
end

local function canSeeAnimalEvents()
    return hasCapability(Capability.AnswerTickets)
end

-- ------------------------------------------------------------------ the window
GENZ_LivestockAuditAdminWindow = ISPanel:derive("GENZ_LivestockAuditAdminWindow")
local Window = GENZ_LivestockAuditAdminWindow

function Window:new(width, height)
    local x = getCore():getScreenWidth() / 2 - width / 2
    local y = getCore():getScreenHeight() / 2 - height / 2
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.moveWithMouse = true
    o.page, o.pages, o.total = 1, 1, 0
    o.filterOwner, o.filterKind = nil, nil
    o.isLoading = true
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

function Window:initialise()
    ISPanel.initialise(self)
    local top = FONT_HGT_MEDIUM + PAD * 2

    self.ownerCombo = ISComboBox:new(PAD, top, 280, BUTTON_HGT, self, Window.onFilterChanged)
    self.ownerCombo:initialise()
    self:addChild(self.ownerCombo)
    self.ownerCombo:addOptionWithData(getText("UI_GENZ_LA_AllOwners"), "")

    self.kindCombo = ISComboBox:new(self.ownerCombo:getRight() + PAD, top, 220, BUTTON_HGT, self, Window.onFilterChanged)
    self.kindCombo:initialise()
    self:addChild(self.kindCombo)
    self.kindCombo:addOptionWithData(getText("UI_GENZ_LA_AllKinds"), "")
    for _, kind in ipairs(Core.KINDS) do
        self.kindCombo:addOptionWithData(getText("UI_GENZ_LA_KindName_" .. kind), kind)
    end

    self.refreshButton = addButton(self, self.kindCombo:getRight() + PAD, top, 120, getText("UI_GENZ_LA_Refresh"), "REFRESH")

    local listTop = top + BUTTON_HGT + PAD
    local bottomY = self.height - PAD - BUTTON_HGT
    self.list = ISScrollingListBox:new(PAD, listTop, self.width - PAD * 2, bottomY - PAD - listTop)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = BUTTON_HGT
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list.doDrawItem = Window.drawRow
    self:addChild(self.list)

    self.closeButton = addButton(self, PAD, bottomY, 120, getText("UI_GENZ_LA_Close"), "CLOSE")
    self.closeButton:enableCancelColor()
    self.previousButton = addButton(self, self.width / 2 - 250, bottomY, 120, getText("UI_GENZ_LA_Previous"), "PREVIOUS")
    self.nextButton = addButton(self, self.width / 2 + 130, bottomY, 120, getText("UI_GENZ_LA_Next"), "NEXT")
    self.teleportButton = addButton(self, self.width - PAD - 120, bottomY, 120, getText("UI_GENZ_LA_Teleport"), "TELEPORT")
    self.teleportButton:setVisible(false)

    self:request(1)
end

-- Empty data in a combo means "no filter"; it travels as nil.
local function comboValue(combo)
    local data = combo:getOptionData(combo.selected)
    if data == nil or data == "" then return nil end
    return data
end

function Window:request(page)
    self.isLoading = true
    sendClientCommand(NET, "list", { owner = self.filterOwner, kind = self.filterKind, page = page })
end

function Window:onFilterChanged()
    self.filterOwner = comboValue(self.ownerCombo)
    self.filterKind = comboValue(self.kindCombo)
    self:request(1)
end

-- The owner list comes with every page (owners appear as events do); the choice survives.
function Window:fillOwners(owners)
    self.ownerCombo:clear()
    self.ownerCombo:addOptionWithData(getText("UI_GENZ_LA_AllOwners"), "")
    for _, owner in ipairs(owners) do
        self.ownerCombo:addOptionWithData(getText("UI_GENZ_LA_OwnerCount", owner.name, tostring(owner.count)), owner.sid)
    end
    self.ownerCombo:selectData(self.filterOwner or "")
end

function Window:fill(args)
    self.isLoading = false
    self.page, self.pages, self.total, self.now = args.page, args.pages, args.total, args.now
    self:fillOwners(args.owners)
    self.list:clear()
    for _, item in ipairs(args.items) do
        self.list:addItem(Text.event(item), item)
    end
    self.list.selected = 0
    self.previousButton:setEnable(self.page > 1)
    self.nextButton:setEnable(self.page < self.pages)
end

function Window:selectedItem()
    local row = self.list.items[self.list.selected]
    return row and row.item
end

function Window.drawRow(list, y, row, alt)
    local item = row.item
    if list.selected == row.index then
        list:drawRect(0, y, list:getWidth(), list.itemheight - 1, 0.3, 0.7, 0.35, 0.15)
    end
    list:drawRectBorder(0, y, list:getWidth(), list.itemheight - 1, 0.9, list.borderColor.r, list.borderColor.g, list.borderColor.b)
    local textY = y + 3
    list:drawText(Text.when(item.ts), PAD, textY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    list:drawText(tostring(item.x) .. "," .. tostring(item.y), COL_WHERE, textY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    list:drawText(Text.animal(item), COL_ANIMAL, textY, 1, 1, 1, 1, UIFont.Small)
    list:drawText(getText("UI_GENZ_LA_OwnerOf", tostring(item.ownerName)), COL_OWNER, textY, 0.8, 0.8, 0.8, 1, UIFont.Small)
    list:drawText(row.text, COL_EVENT, textY, 1, 1, 1, 1, UIFont.Small)
    return y + list.itemheight
end

function Window:prerender()
    ISPanel.prerender(self)
    local title = getText("UI_GENZ_LA_AdminTitle")
    self:drawText(title, self.width / 2 - getTextManager():MeasureStringX(UIFont.Medium, title) / 2, PAD, 1, 1, 1, 1, UIFont.Medium)
    local status
    if self.isLoading then
        status = getText("UI_GENZ_LA_Loading")
    elseif self.total == 0 then
        status = getText("UI_GENZ_LA_Empty")
    else
        status = getText("UI_GENZ_LA_PageOf", tostring(self.page), tostring(self.pages), tostring(self.total))
    end
    local statusY = self.previousButton:getY() + 3
    self:drawText(status, self.width / 2 - getTextManager():MeasureStringX(UIFont.Small, status) / 2, statusY, 0.9, 0.9, 0.9, 1, UIFont.Small)
    self.teleportButton:setVisible(self:selectedItem() ~= nil and hasCapability(Capability.TeleportToCoordinates))
end

-- Same command the vanilla PVP Log Tool uses to go to where a kill happened.
local function teleportTo(item)
    local position = tostring(item.x) .. "," .. tostring(item.y) .. "," .. tostring(item.z)
    if isClient() then
        SendCommandToServer("/teleportto " .. position)
    else
        getPlayer():teleportTo(item.x, item.y, item.z)
    end
end

function Window:onClick(button)
    if button.internal == "CLOSE" then self:close() return end
    if button.internal == "REFRESH" then self:request(self.page) return end
    if button.internal == "PREVIOUS" then self:request(self.page - 1) return end
    if button.internal == "NEXT" then self:request(self.page + 1) return end
    if button.internal == "TELEPORT" then
        local item = self:selectedItem()
        if item then teleportTo(item) end
    end
end

function Window:close()
    self:setVisible(false)
    self:removeFromUIManager()
    Window.instance = nil
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= NET or command ~= "listResult" then return end
    if Window.instance then Window.instance:fill(args) end
end)

-- ------------------------------------------------------------------ the Admin Panel button
local function openWindow()
    if Window.instance then Window.instance:close() end
    local window = Window:new(WINDOW_WIDTH, WINDOW_HEIGHT)
    window:initialise()
    window:addToUIManager()
end

-- ISAdminPanelUI:create() builds its buttons, then sorts EVERY child by title into two
-- columns (ISAdminPanelUI.lua:163-177). A button added before the original runs is laid out
-- by that same loop, in alphabetical order, without touching the vanilla layout.
if not ISAdminPanelUI.genzLivestockAuditPatched then
    ISAdminPanelUI.genzLivestockAuditPatched = true

    local originalCreate = ISAdminPanelUI.create
    function ISAdminPanelUI:create()
        local button = ISButton:new(0, 0, 200, BUTTON_HGT, getText("UI_GENZ_LA_AdminButton"), self, openWindow)
        button:initialise()
        button:instantiate()
        button.borderColor = self.buttonBorderColor
        button.tooltip = getText("UI_GENZ_LA_AdminButtonTooltip")
        self:addChild(button)
        self.genzLivestockAuditButton = button
        originalCreate(self)
    end

    -- The original closes the panel when there is no player or role; nothing to enable then.
    local originalUpdateButtons = ISAdminPanelUI.updateButtons
    function ISAdminPanelUI:updateButtons()
        originalUpdateButtons(self)
        local player = getPlayer()
        if self.genzLivestockAuditButton and player and player:getRole() then
            self.genzLivestockAuditButton.enable = canSeeAnimalEvents()
        end
    end
end
