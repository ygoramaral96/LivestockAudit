-- GENZ_LivestockAuditHistory -- the "History" button next to Help in the vanilla Check
-- Zone window (card #192, F3): what happened in this pen to the asker's claimed animals and
-- to the animals nobody owns (F5, decision D26).
--
-- The window sends one point of the pen; the server finds the pen itself, checks the asker
-- is near it, keeps the asker's own entries plus the unowned ones and cuts them to the
-- asker's Animal Care level (GENZ_LivestockAuditQuery). Nothing about another owner's
-- animals reaches this client.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "ISUI/Animal/ISDesignationAnimalZoneUI"
require "GENZ_LivestockAudit/GENZ_LivestockAuditText"

local Text = GENZ_LivestockAuditText

local NET = "GENZ_LivestockAudit"
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local PAD = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6
local WINDOW_WIDTH, WINDOW_HEIGHT = 720, 480
-- column x inside a row: how long ago | animal | what happened
local COL_ANIMAL, COL_EVENT = 110, 270

GENZ_LivestockAuditHistoryWindow = ISPanel:derive("GENZ_LivestockAuditHistoryWindow")
local Window = GENZ_LivestockAuditHistoryWindow

function Window:new(zone)
    local x = getCore():getScreenWidth() / 2 - WINDOW_WIDTH / 2
    local y = getCore():getScreenHeight() / 2 - WINDOW_HEIGHT / 2
    local o = ISPanel:new(x, y, WINDOW_WIDTH, WINDOW_HEIGHT)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.moveWithMouse = true
    o.zone = zone
    o.isLoading = true
    o.itemCount = 0
    Window.instance = o
    return o
end

function Window:initialise()
    ISPanel.initialise(self)
    local listTop = FONT_HGT_MEDIUM + PAD * 3 + FONT_HGT_SMALL
    local bottomY = self.height - PAD - BUTTON_HGT
    self.list = ISScrollingListBox:new(PAD, listTop, self.width - PAD * 2, bottomY - PAD - listTop)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = BUTTON_HGT
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list.doDrawItem = Window.drawRow
    self:addChild(self.list)

    self.closeButton = ISButton:new(self.width - PAD - 120, bottomY, 120, BUTTON_HGT, getText("UI_GENZ_LA_Close"), self, Window.close)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self.closeButton:enableCancelColor()
    self:addChild(self.closeButton)

    sendClientCommand(NET, "history", { x = self.zone:getX(), y = self.zone:getY(), z = self.zone:getZ() })
end

function Window:fill(args)
    self.isLoading = false
    self.now = args.now
    self.itemCount = #args.items
    self.list:clear()
    for _, item in ipairs(args.items) do
        self.list:addItem(Text.event(item), item)
    end
end

function Window.drawRow(list, y, row, alt)
    local item = row.item
    local window = Window.instance
    list:drawRectBorder(0, y, list:getWidth(), list.itemheight - 1, 0.9, list.borderColor.r, list.borderColor.g, list.borderColor.b)
    local textY = y + 3
    list:drawText(Text.ago(window.now - item.ts), PAD, textY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    list:drawText(Text.animal(item), COL_ANIMAL, textY, 1, 1, 1, 1, UIFont.Small)
    list:drawText(row.text, COL_EVENT, textY, 1, 1, 1, 1, UIFont.Small)
    return y + list.itemheight
end

function Window:prerender()
    ISPanel.prerender(self)
    local title = getText("UI_GENZ_LA_HistoryTitle", self.zone:getName())
    self:drawText(title, self.width / 2 - getTextManager():MeasureStringX(UIFont.Medium, title) / 2, PAD, 1, 1, 1, 1, UIFont.Medium)
    local hint = getText("UI_GENZ_LA_HistoryHint")
    if self.isLoading then
        hint = getText("UI_GENZ_LA_Loading")
    elseif self.itemCount == 0 then
        hint = getText("UI_GENZ_LA_Empty")
    end
    self:drawText(hint, PAD, FONT_HGT_MEDIUM + PAD * 2, 0.8, 0.8, 0.8, 1, UIFont.Small)
end

function Window:close()
    self:setVisible(false)
    self:removeFromUIManager()
    Window.instance = nil
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= NET or command ~= "historyResult" then return end
    if Window.instance then Window.instance:fill(args) end
end)

-- ------------------------------------------------------------------ the Check Zone button
local function openHistory(zoneWindow)
    if Window.instance then Window.instance:close() end
    local window = Window:new(zoneWindow.zone)
    window:initialise()
    window:addToUIManager()
end

-- Added AFTER the vanilla initialise, beside Help: Help sits at x 10-110 and the vanilla
-- "Info" (only shown with a controller) starts at 270 (ISDesignationAnimalZoneUI.lua:212-248),
-- so 120-220 is free. Nothing vanilla is replaced.
if not ISDesignationZoneAnimalZoneUI.genzLivestockAuditPatched then
    ISDesignationZoneAnimalZoneUI.genzLivestockAuditPatched = true

    local originalInitialise = ISDesignationZoneAnimalZoneUI.initialise
    function ISDesignationZoneAnimalZoneUI:initialise()
        originalInitialise(self)
        local help = self.infoBtn
        local button = ISButton:new(help:getRight() + PAD, help:getY(), help:getWidth(), help:getHeight(),
            getText("UI_GENZ_LA_HistoryButton"), self, openHistory)
        button.anchorTop = false
        button.anchorBottom = true
        button:initialise()
        button:instantiate()
        button.borderColor = { r = 1, g = 1, b = 1, a = 0.1 }
        self:addChild(button)
        self.genzLivestockAuditHistoryButton = button
    end
end
