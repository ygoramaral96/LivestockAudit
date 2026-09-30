-- GENZ_LivestockAuditDots -- status dots in the vanilla Check Zone list (card #192, F4):
-- whose animal it is, hunger, thirst, health, mood and (from Animal Care 3) breeding.
--
-- THE GATE IS VANILLA ITSELF. Every dot is read from the text the vanilla Animal Info panel
-- shows at the player's Animal Care level (getAppearanceText, getHealthText, getStressTxt,
-- ISAnimalUI:getPregnantText) and only turned into a color. A dot never says more than that
-- panel would, and if the game moves a threshold the dot moves with it (decision D8).
--
-- Drawn OVER the vanilla list: after its prerender, inside the clipping it sets, and the
-- hover text after its render. Nothing vanilla is replaced.

require "ISUI/Animal/ISDesignationAnimalZoneUI"
require "ISUI/Animal/ISAnimalUI"

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local LOG_TAG = "[GENZ_LivestockAudit] "
local DOT_SIZE = 10
local COLUMN_GAP = 12
local REFRESH_MS = 1000            -- the vanilla list itself refreshes once a second
local BREEDING_LEVEL = 3           -- vanilla shows fertilized/pregnant from level 3 (ISAnimalUI.lua:138)
local DOT_TEXTURE = getTexture("media/ui/circle.png")

local GREEN, YELLOW, ORANGE, RED = { 0.35, 0.75, 0.35 }, { 0.9, 0.8, 0.3 }, { 0.95, 0.55, 0.2 }, { 0.9, 0.25, 0.25 }
local CYAN, GRAY = { 0.35, 0.75, 0.95 }, { 0.5, 0.5, 0.5 }
local MINE, SOMEONE_ELSES = { 0.4, 0.6, 1.0 }, { 0.9, 0.35, 0.35 }

-- The stages of each reading, as the vanilla translation keys the Java text is built from.
local STAGES = {
    hunger = { { "IGUI_Animal_WellFed", GREEN }, { "IGUI_Animal_Underfed", YELLOW }, { "IGUI_Animal_Starving", RED } },
    thirst = { { "IGUI_Animal_FullyWatered", GREEN }, { "IGUI_Animal_Thirsty", YELLOW }, { "IGUI_Animal_DyingThirst", RED } },
    health = { { "IGUI_Animal_Healthy", GREEN }, { "IGUI_Animal_OffColor", YELLOW }, { "IGUI_Animal_Sickly", ORANGE }, { "IGUI_Animal_Dying", RED } },
    mood = { { "IGUI_Animal_Calm", GREEN }, { "IGUI_Animal_Unnerved", YELLOW }, { "IGUI_Animal_Stressed", ORANGE }, { "IGUI_Animal_Agitated", RED } },
}
local COLUMNS = {
    { key = "claim" },
    { key = "hunger", label = "UI_GENZ_LA_ColHunger" },
    { key = "thirst", label = "UI_GENZ_LA_ColThirst" },
    { key = "health", label = "UI_GENZ_LA_ColHealth" },
    { key = "mood", label = "UI_GENZ_LA_ColMood" },
    { key = "breed", label = "UI_GENZ_LA_ColPregnant", minLevel = BREEDING_LEVEL },
}

-- Translated stage texts, longest first: "Not Thirsty" must be found before "Thirsty".
-- Built on first use, when the translator has the player's language loaded.
local stageTexts = {}
local function stagesOf(reading)
    if not stageTexts[reading] then
        local list = {}
        for _, stage in ipairs(STAGES[reading]) do
            table.insert(list, { text = getText(stage[1]), color = stage[2] })
        end
        table.sort(list, function(a, b) return #a.text > #b.text end)
        stageTexts[reading] = list
    end
    return stageTexts[reading]
end

-- A text the stages do not match is shown gray with the text itself, and said once in the
-- console: a silent blank dot would look like "fine".
local warnedUnreadable = {}
local function readStage(reading, text)
    for _, stage in ipairs(stagesOf(reading)) do
        if string.find(text, stage.text, 1, true) then
            return { color = stage.color, text = stage.text }
        end
    end
    if not warnedUnreadable[reading] then
        warnedUnreadable[reading] = true
        print(LOG_TAG .. "could not read " .. reading .. " from '" .. tostring(text) .. "'")
    end
    return { color = GRAY, text = tostring(text) }
end

-- Only a female that can have young gets the dot, as in the Info panel (ISAnimalUI.lua:139).
-- Egg layers show "fertilized"; the others show the vanilla pregnancy text for this level,
-- asked of ISAnimalUI:getPregnantText the way the Info panel asks it.
local function breedingCell(animal, level)
    if not (animal:getBabyType() and animal:isFemale()) then return nil end
    local data = animal:getData()
    if animal:getEggsPerDay() > 0 then
        local fertilized = data:isFertilized()
        return { color = fertilized and CYAN or GRAY,
                 text = getText("IGUI_Animal_Fertilized") .. ": " .. getText(fertilized and "IGUI_Yes" or "IGUI_No") }
    end
    local stage = getText("IGUI_No")
    if data:isPregnant() then
        stage = ISAnimalUI.getPregnantText({ animal = animal, skillLvl = level })
    end
    return { color = stage ~= getText("IGUI_No") and CYAN or GRAY, text = getText("IGUI_Animal_Pregnant") .. ": " .. stage }
end

-- From the claim cache GENZ_AnimalGuard already keeps on the client (no request of our own).
local function claimCell(animal)
    local claim = GENZ_AnimalGuard.claimOf(animal)
    if not claim or not claim.owner then return nil end
    if claim.owner == tostring(getCurrentUserSteamID()) then
        return { color = MINE, text = getText("UI_GENZ_LA_ClaimMine") }
    end
    return { color = SOMEONE_ELSES, text = getText("UI_GENZ_LA_ClaimOther") }
end

local function cellsOf(animal, level)
    local appearance = animal:getAppearanceText(false)
    local cells = {
        claim = claimCell(animal),
        hunger = readStage("hunger", appearance),
        thirst = readStage("thirst", appearance),
        health = readStage("health", animal:getHealthText(false, level)),
        mood = readStage("mood", animal:getStressTxt(false, level)),
    }
    if level >= BREEDING_LEVEL then cells.breed = breedingCell(animal, level) end
    return cells
end

-- Readings are refreshed at most once per REFRESH_MS; between refreshes a frame reuses them.
local cache, cacheAt = {}, 0
local function cachedCells(animal, level)
    local now = getTimestampMs()
    if now - cacheAt > REFRESH_MS then cache, cacheAt = {}, now end
    if not cache[animal] then cache[animal] = cellsOf(animal, level) end
    return cache[animal]
end

-- Column x positions inside the list. The first column starts after the vanilla "In hutch"
-- note, which vanilla writes 20 px after the Info button (ISDesignationAnimalZoneUI.lua:54-58).
local function layoutOf(panel, level)
    local first = panel.ui.animalbuttons[1]
    if not first then return nil end
    local anchor = first:isVisible() and first:getRight() or first:getX()
    local x = anchor + 20 + getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_DesignationZone_InHutch")) + COLUMN_GAP
    local columns = {}
    for _, column in ipairs(COLUMNS) do
        if not column.minLevel or level >= column.minLevel then
            local label = column.label and getText(column.label)
            local width = math.max(DOT_SIZE, label and getTextManager():MeasureStringX(UIFont.Small, label) or 0)
            table.insert(columns, { key = column.key, label = label, x = x, width = width })
            x = x + width + COLUMN_GAP
        end
    end
    return columns
end

local function levelOf(panel)
    return panel.ui.player:getPerkLevel(Perks.Husbandry)
end

local function drawDot(panel, column, centerY, color)
    local dotX = column.x + (column.width - DOT_SIZE) / 2
    panel:drawTextureScaled(DOT_TEXTURE, dotX, centerY - DOT_SIZE / 2, DOT_SIZE, DOT_SIZE, 1, color[1], color[2], color[3])
end

-- Rows are as vanilla lays them: row i spans (i-1)*itemHgt to i*itemHgt, the same arithmetic
-- vanilla uses to find the row under the mouse (AnimalsPanel:highlightAnimal).
local function drawDots(panel)
    panel.genzLivestockHover = nil
    local level = levelOf(panel)
    local columns = layoutOf(panel, level)
    if not columns then return end
    local rowHeight = panel.ui.itemHgt
    local hoverRow = panel:isMouseOver() and math.floor(panel:getMouseY() / rowHeight) + 1 or nil
    for index, button in ipairs(panel.ui.animalbuttons) do
        if instanceof(button.animal, "IsoAnimal") then
            local cells = cachedCells(button.animal, level)
            local centerY = (index - 1) * rowHeight + rowHeight / 2
            for _, column in ipairs(columns) do
                local cell = cells[column.key]
                if cell then
                    drawDot(panel, column, centerY, cell.color)
                    local mouseX = panel:getMouseX()
                    if hoverRow == index and mouseX >= column.x and mouseX < column.x + column.width + COLUMN_GAP then
                        panel.genzLivestockHover = { text = cell.text, x = panel:getMouseX(), y = panel:getMouseY() }
                    end
                end
            end
        end
    end
end

local function drawHover(panel)
    local hover = panel.genzLivestockHover
    if not hover then return end
    local width = getTextManager():MeasureStringX(UIFont.Small, hover.text) + 8
    local x, y = hover.x + 14, hover.y + 14
    panel:drawRect(x, y, width, FONT_HGT_SMALL + 4, 0.9, 0, 0, 0)
    panel:drawRectBorder(x, y, width, FONT_HGT_SMALL + 4, 0.6, 1, 1, 1)
    panel:drawText(hover.text, x + 4, y + 2, 1, 1, 1, 1, UIFont.Small)
end

local function drawHeaders(zoneWindow)
    local panel = zoneWindow.animalPanel
    local columns = layoutOf(panel, levelOf(panel))
    if not columns then return end
    local y = panel:getY() - FONT_HGT_SMALL - 2
    for _, column in ipairs(columns) do
        if column.label then
            local labelX = panel:getX() + column.x + (column.width - getTextManager():MeasureStringX(UIFont.Small, column.label)) / 2
            zoneWindow:drawText(column.label, labelX, y, 0.75, 0.75, 0.75, 1, UIFont.Small)
        end
    end
end

local AnimalsPanel = ISDesignationZoneAnimalZoneUI_AnimalsPanel
if not AnimalsPanel.genzLivestockAuditPatched then
    AnimalsPanel.genzLivestockAuditPatched = true

    -- The original prerender opens the list's clipping and leaves it open (render closes it):
    -- dots drawn here are cut to the list like the vanilla rows.
    local originalPrerender = AnimalsPanel.prerender
    function AnimalsPanel:prerender()
        originalPrerender(self)
        drawDots(self)
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
    end
end
