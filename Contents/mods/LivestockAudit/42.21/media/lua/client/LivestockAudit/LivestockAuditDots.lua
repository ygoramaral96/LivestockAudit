-- LivestockAuditDots -- the vanilla Check Zone list, extended (card #192 F4, card #201):
-- status cells per animal in four tabs (care, harvest, breeding, profile), the species icon,
-- the name colored by sex, an Animal Care bar and a header row.
--
-- WHAT EACH CELL SAYS comes from LivestockAuditReadings: the text the vanilla Animal
-- Info panel shows at the viewer's level, as a color or a short text (decision D8). This
-- file only draws.
--
-- Drawn OVER the vanilla window, nothing replaced: the tab buttons and one header row are
-- added after the vanilla initialise (the list and the tick box move down one row to make
-- room; the window grows by itself, it sets its height from the tick box every frame), the
-- icon and the cells after the list's prerender (inside the clipping it opens), the hover
-- text after its render, the headers and the bar after the window's render. After every
-- vanilla updateAnimals the name labels and the buttons are moved right by the icon's width
-- and the labels colored.

require "ISUI/Animal/ISDesignationAnimalZoneUI"
require "ISUI/ISButton"
require "LivestockAudit/LivestockAuditReadings"

local Readings = LivestockAuditReadings

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_NEW_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)   -- the font of vanilla's "Animals: N" line
local DOT_SIZE = 10
local ICON_SIZE = 16
local ICON_X = 4
local ICON_SHIFT = ICON_SIZE + 8           -- the name and the buttons move right by this
local LABEL_X = 10                         -- where vanilla puts the name (ISDesignationAnimalZoneUI.lua:412)
local COLUMN_GAP = 12
local HEADER_ROW = FONT_HGT_SMALL + 4      -- the row added between the tabs and the list
local TAB_PAD = 8
local TAB_GAP = 4
local BAR_WIDTH, BAR_HEIGHT = 90, 6
-- Vanilla opens the Check Zone at 600 px (ISAnimalContextMenu.lua:1070): with a long name, the
-- Info button and "In hutch" there is no room left for a tab of columns, and the shared layout
-- squeezes every header to "F..." (30/09). The window is asked wider BEFORE vanilla lays it out,
-- so the list width, the right-hand buttons and the centered title follow by themselves.
-- Not wider than the widest tab needs: the profile tab (claim dot + Type + Age + Weight) takes
-- 316 px after the Info button and "In hutch", which the longest vanilla breed name fits in
-- 762 px; 820 was "too big" in the next test (30/09), 780 keeps ~19 px of slack.
local WINDOW_WIDTH = 780
local REFRESH_MS = 1000                    -- the vanilla list itself refreshes once a second
local DOT_TEXTURE = getTexture("media/ui/circle.png")
local ELLIPSIS = "..."

-- The chosen tab is remembered between windows, like vanilla's "Show zone" tick.
ISDesignationZoneAnimalZoneUI.livestockAuditTab = ISDesignationZoneAnimalZoneUI.livestockAuditTab or Readings.TABS[1].key

local function measure(text)
    return getTextManager():MeasureStringX(UIFont.Small, text)
end

local function currentTab()
    return Readings.tab(ISDesignationZoneAnimalZoneUI.livestockAuditTab)
end

local function levelOf(panel)
    return panel.ui.player:getPerkLevel(Perks.Husbandry)
end

-- Readings are refreshed at most once per REFRESH_MS; between refreshes a frame reuses them.
local cache, cacheAt = {}, 0
local function cachedCells(animal, level)
    local now = getTimestampMs()
    if now - cacheAt > REFRESH_MS then cache, cacheAt = {}, now end
    if not cache[animal] then cache[animal] = Readings.cellsOf(animal, level) end
    return cache[animal]
end

-- Cuts a text to a width with "...", never inside a UTF-8 character.
local function fitText(text, width)
    if measure(text) <= width then return text end
    local cut = text
    while #cut > 0 and measure(cut .. ELLIPSIS) > width do
        cut = string.sub(cut, 1, #cut - 1)
        while #cut > 0 and string.byte(cut, #cut) >= 0x80 and string.byte(cut, #cut) < 0xC0 do
            cut = string.sub(cut, 1, #cut - 1)
        end
    end
    return cut .. ELLIPSIS
end

-- Column x positions inside the list for the current tab. The first column starts after the
-- vanilla "In hutch" note, which vanilla writes 20 px after the Info button
-- (ISDesignationAnimalZoneUI.lua:54-58), and the last one ends before the scroll bar. When
-- the natural widths do not fit (the "Alert" header fell outside the list in PT-BR, 30/09),
-- the columns share the room equally and a header is cut with "..." -- the dots are what
-- matter, and the hover text says the rest.
local function layoutOf(panel, level, tab)
    local first = panel.ui.animalbuttons[1]
    if not first then return nil end
    local anchor = first:isVisible() and first:getRight() or first:getX()
    local start = anchor + 20 + measure(getText("IGUI_DesignationZone_InHutch")) + COLUMN_GAP
    local scrollBar = panel.vscroll and panel.vscroll:getWidth() or 0
    local room = panel.width - scrollBar - COLUMN_GAP - start

    local columns = {}
    local natural = 0
    for _, column in ipairs(tab.columns) do
        if not column.minLevel or level >= column.minLevel then
            local label = column.label and getText(column.label)
            local width = math.max(column.width or DOT_SIZE, label and measure(label) or 0)
            table.insert(columns, { key = column.key, label = label, width = width, text = column.text })
            natural = natural + width
        end
    end
    if #columns == 0 then return columns end
    local gaps = COLUMN_GAP * (#columns - 1)
    if natural + gaps > room then
        local shared = math.max(DOT_SIZE, math.floor((room - gaps) / #columns))
        for _, column in ipairs(columns) do column.width = shared end
    end
    local x = start
    for _, column in ipairs(columns) do
        column.x = x
        column.header = column.label and fitText(column.label, column.width)
        x = x + column.width + COLUMN_GAP
    end
    return columns
end

local function drawDot(panel, column, centerY, color)
    local dotX = column.x + (column.width - DOT_SIZE) / 2
    panel:drawTextureScaled(DOT_TEXTURE, dotX, centerY - DOT_SIZE / 2, DOT_SIZE, DOT_SIZE, 1, color[1], color[2], color[3])
end

local function drawTextCell(panel, column, centerY, text)
    panel:drawText(fitText(text, column.width), column.x, centerY - FONT_HGT_SMALL / 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
end

-- The icon comes with the cells (Readings.iconOf), so it is looked up once a second, not per frame.
local function drawIcon(panel, texture, centerY)
    if texture then
        panel:drawTextureScaled(texture, ICON_X, centerY - ICON_SIZE / 2, ICON_SIZE, ICON_SIZE, 1, 1, 1, 1)
    end
end

-- Rows are as vanilla lays them: row i spans (i-1)*itemHgt to i*itemHgt, the same arithmetic
-- vanilla uses to find the row under the mouse (AnimalsPanel:highlightAnimal).
local function drawRows(panel)
    panel.livestockAuditHover = nil
    local level = levelOf(panel)
    local columns = layoutOf(panel, level, currentTab())
    if not columns then return end
    local rowHeight = panel.ui.itemHgt
    local hoverRow = panel:isMouseOver() and math.floor(panel:getMouseY() / rowHeight) + 1 or nil
    local mouseX = panel:getMouseX()
    for index, button in ipairs(panel.ui.animalbuttons) do
        if instanceof(button.animal, "IsoAnimal") then
            local centerY = (index - 1) * rowHeight + rowHeight / 2
            local cells = cachedCells(button.animal, level)
            drawIcon(panel, cells.icon, centerY)
            for _, column in ipairs(columns) do
                local cell = cells[column.key]
                if cell then
                    if column.text then
                        drawTextCell(panel, column, centerY, cell.text)
                    else
                        drawDot(panel, column, centerY, cell.color)
                    end
                    if hoverRow == index and mouseX >= column.x and mouseX < column.x + column.width + COLUMN_GAP then
                        panel.livestockAuditHover = { text = cell.text, x = mouseX, y = panel:getMouseY() }
                    end
                end
            end
        end
    end
end

local function drawHover(panel)
    local hover = panel.livestockAuditHover
    if not hover then return end
    local width = measure(hover.text) + 8
    local x, y = hover.x + 14, hover.y + 14
    panel:drawRect(x, y, width, FONT_HGT_SMALL + 4, 0.9, 0, 0, 0)
    panel:drawRectBorder(x, y, width, FONT_HGT_SMALL + 4, 0.6, 1, 1, 1)
    panel:drawText(hover.text, x + 4, y + 2, 1, 1, 1, 1, UIFont.Small)
end

-- The header row sits right above the list, in the room made at initialise.
local function drawHeaders(zoneWindow)
    local panel = zoneWindow.animalPanel
    local columns = layoutOf(panel, levelOf(panel), currentTab())
    if not columns then return end
    local y = panel:getY() - FONT_HGT_SMALL - 2
    for _, column in ipairs(columns) do
        if column.header then
            local labelX = panel:getX() + column.x + (column.width - measure(column.header)) / 2
            zoneWindow:drawText(column.header, labelX, y, 0.75, 0.75, 0.75, 1, UIFont.Small)
        end
    end
end

-- "Animal Care N" and the progress to the next level, top right, beside the vanilla title.
local function drawSkillBar(zoneWindow)
    local level, fraction, name = Readings.skillProgress(zoneWindow.player)
    local text = name .. " " .. tostring(level)
    -- As wide as the text when it is longer: "Cuidados com Animais 10" centered on a 90 px bar
    -- stuck out past the window's right edge (30/09).
    local width = math.max(BAR_WIDTH, measure(text))
    local x = zoneWindow.width - 10 - width
    local y = 20   -- vanilla's title line (ISDesignationAnimalZoneUI.lua:279)
    zoneWindow:drawText(text, x + (width - measure(text)) / 2, y, 0.75, 0.75, 0.75, 1, UIFont.Small)
    local barY = y + FONT_HGT_SMALL + 2
    zoneWindow:drawRect(x, barY, width, BAR_HEIGHT, 0.8, 0.15, 0.15, 0.15)
    zoneWindow:drawRect(x, barY, width * fraction, BAR_HEIGHT, 1, 0.35, 0.75, 0.35)
    zoneWindow:drawRectBorder(x, barY, width, BAR_HEIGHT, 0.6, 1, 1, 1)
end

-- ------------------------------------------------------------------ tabs
local function selectTab(zoneWindow, key)
    ISDesignationZoneAnimalZoneUI.livestockAuditTab = key
    for _, button in ipairs(zoneWindow.livestockAuditTabButtons) do
        local selected = button.internal == key
        button.backgroundColor = { r = 0.25, g = 0.25, b = 0.25, a = selected and 1 or 0.4 }
        button.borderColor = { r = 1, g = 1, b = 1, a = selected and 0.5 or 0.1 }
    end
end

local function onTabClick(zoneWindow, button)
    selectTab(zoneWindow, button.internal)
end

-- Right-aligned on vanilla's "Animals: N / Corpses: N" line, which ends well before the
-- middle of the window; the tab strip grows leftwards from the right edge.
local function addTabs(zoneWindow, lineY)
    local height = FONT_HGT_SMALL + 4
    local x = zoneWindow.width - 10
    zoneWindow.livestockAuditTabButtons = {}
    for i = #Readings.TABS, 1, -1 do
        local tab = Readings.TABS[i]
        local title = getText(tab.label)
        local width = measure(title) + TAB_PAD * 2
        x = x - width
        local button = ISButton:new(x, lineY - 2, width, height, title, zoneWindow, onTabClick)
        button.internal = tab.key
        button:initialise()
        button:instantiate()
        zoneWindow:addChild(button)
        table.insert(zoneWindow.livestockAuditTabButtons, 1, button)
        x = x - TAB_GAP
    end
    selectTab(zoneWindow, ISDesignationZoneAnimalZoneUI.livestockAuditTab)
end

local AnimalsPanel = ISDesignationZoneAnimalZoneUI_AnimalsPanel
if not AnimalsPanel.livestockAuditPatched then
    AnimalsPanel.livestockAuditPatched = true

    -- The original prerender opens the list's clipping and leaves it open (render closes it):
    -- cells drawn here are cut to the list like the vanilla rows.
    local originalPrerender = AnimalsPanel.prerender
    function AnimalsPanel:prerender()
        originalPrerender(self)
        drawRows(self)
    end

    -- After the original render the clipping is closed, so the hover text may cross the edge.
    local originalRender = AnimalsPanel.render
    function AnimalsPanel:render()
        originalRender(self)
        drawHover(self)
    end

    local originalZoneRender = ISDesignationZoneAnimalZoneUI.render
    function ISDesignationZoneAnimalZoneUI:render()
        originalZoneRender(self)
        drawHeaders(self)
        drawSkillBar(self)
    end

    -- Wider than vanilla asks, never narrower (see WINDOW_WIDTH).
    local originalNew = ISDesignationZoneAnimalZoneUI.new
    function ISDesignationZoneAnimalZoneUI:new(x, y, width, height, player, zone)
        return originalNew(self, x, y, math.max(width, WINDOW_WIDTH), height, player, zone)
    end

    -- The vanilla initialise lays the list right under the "Animals: N" line; the tabs take
    -- that line's free right side and the list moves down one row for the headers.
    local originalInitialise = ISDesignationZoneAnimalZoneUI.initialise
    function ISDesignationZoneAnimalZoneUI:initialise()
        originalInitialise(self)
        local lineY = self.animalPanel:getY() - FONT_HGT_NEW_SMALL
        self.animalPanel:setY(self.animalPanel:getY() + HEADER_ROW)
        self.showZoneTickBox:setY(self.showZoneTickBox:getY() + HEADER_ROW)
        addTabs(self, lineY)
    end

    -- Vanilla places every button at the widest name and every new label at LABEL_X, and
    -- keeps a label's x when it reuses it: the label gets an absolute x, the button a shift.
    local originalUpdateAnimals = ISDesignationZoneAnimalZoneUI.updateAnimals
    function ISDesignationZoneAnimalZoneUI:updateAnimals()
        originalUpdateAnimals(self)
        for _, button in ipairs(self.animalbuttons) do
            button:setX(button:getX() + ICON_SHIFT)
        end
        for _, label in ipairs(self.animalLabels) do
            label:setX(LABEL_X + ICON_SHIFT)
            if instanceof(label.animal, "IsoAnimal") then
                local color = Readings.nameColor(label.animal)
                label:setColor(color[1], color[2], color[3])
            end
        end
    end
end
