-- GENZ_LivestockAuditReadings -- what the vanilla Animal Info panel would say about an animal
-- at the viewer's Animal Care level, as cells the Check Zone list draws (card #192 F4, card #201).
--
-- THE GATE IS VANILLA ITSELF (decision D8). Each cell is the text the vanilla panel shows at
-- that level (getAppearanceText, getHealthText, getStressTxt, getAgeText, and ISAnimalUI's
-- getPregnantText / getUdderText / getWoolText / getClutchSizeText, called the way the panel
-- calls them) plus the panel's own conditions for showing the line (ISAnimalUI.lua:102-215
-- and :260-330), only turned into a color. No threshold of ours: if the game moves one, the
-- cell moves with it.
--
-- A dot cell is { color, text }; a text cell is { text } and is written in the column. No
-- cell (nil) means the panel would not show that line for this animal at this level.
-- Nothing here draws: GENZ_LivestockAuditDots does. scripts/testar_livestock_readings.py
-- runs this file against the REAL vanilla ISAnimalUI.lua, without a game.

require "ISUI/Animal/ISAnimalUI"
require "XpSystem/ISUI/ISSkillProgressBar"
require "GENZ_LivestockAudit/GENZ_LivestockAuditApi"

GENZ_LivestockAuditReadings = {}
local Readings = GENZ_LivestockAuditReadings

local LOG_TAG = "[GENZ_LivestockAudit] "

local GREEN, YELLOW, ORANGE, RED = { 0.35, 0.75, 0.35 }, { 0.9, 0.8, 0.3 }, { 0.95, 0.55, 0.2 }, { 0.9, 0.25, 0.25 }
local CYAN, GRAY = { 0.35, 0.75, 0.95 }, { 0.5, 0.5, 0.5 }
local MINE, SOMEONE_ELSES = { 0.4, 0.6, 1.0 }, { 0.9, 0.35, 0.35 }
local FEMALE, MALE = { 1.0, 0.62, 0.78 }, { 0.55, 0.75, 1.0 }
Readings.COLORS = { GREEN = GREEN, YELLOW = YELLOW, ORANGE = ORANGE, RED = RED, CYAN = CYAN, GRAY = GRAY,
                    MINE = MINE, SOMEONE_ELSES = SOMEONE_ELSES }

-- The Animal Care level from which vanilla shows each line (ISAnimalUI.lua: `skillLvl > N`).
Readings.LEVEL = { breed = 3, clutch = 4, laying = 4, stud = 4, weight = 5, season = 5 }
local LEVEL = Readings.LEVEL
local TOP_LEVEL = 10

-- The tabs of the list and their columns, in order. A column with `text` is written, the
-- others are dots; `minLevel` hides the column, header included, below that level.
Readings.TABS = {
    { key = "care", label = "UI_GENZ_LA_TabCare", columns = {
        { key = "claim" },
        { key = "hunger", label = "UI_GENZ_LA_ColHunger" },
        { key = "thirst", label = "UI_GENZ_LA_ColThirst" },
        { key = "health", label = "UI_GENZ_LA_ColHealth" },
        { key = "mood", label = "UI_GENZ_LA_ColMood" },
        { key = "alert", label = "UI_GENZ_LA_ColAlert" },
    } },
    { key = "harvest", label = "UI_GENZ_LA_TabHarvest", columns = {
        { key = "claim" },
        { key = "milk", label = "UI_GENZ_LA_ColMilk" },
        { key = "wool", label = "UI_GENZ_LA_ColWool" },
        { key = "clutch", label = "UI_GENZ_LA_ColClutch", minLevel = LEVEL.clutch },
        { key = "laying", label = "UI_GENZ_LA_ColLaying", minLevel = LEVEL.laying },
    } },
    { key = "breeding", label = "UI_GENZ_LA_TabBreeding", columns = {
        { key = "claim" },
        { key = "breed", label = "UI_GENZ_LA_ColPregnant", minLevel = LEVEL.breed },
        { key = "season", label = "UI_GENZ_LA_ColSeason", minLevel = LEVEL.season },
        { key = "stud", label = "UI_GENZ_LA_ColStud", minLevel = LEVEL.stud },
    } },
    { key = "profile", label = "UI_GENZ_LA_TabProfile", columns = {
        { key = "claim" },
        { key = "type", label = "UI_GENZ_LA_ColType", text = true, width = 90 },
        { key = "age", label = "UI_GENZ_LA_ColAge", text = true, width = 110 },
        { key = "weight", label = "UI_GENZ_LA_ColWeight", text = true, width = 70, minLevel = LEVEL.weight },
    } },
}

function Readings.tab(key)
    for _, tab in ipairs(Readings.TABS) do
        if tab.key == key then return tab end
    end
    return Readings.TABS[1]
end

-- The stages of each vanilla reading, as the translation keys its text is built from.
local STAGES = {
    hunger = { { "IGUI_Animal_WellFed", GREEN }, { "IGUI_Animal_Underfed", YELLOW }, { "IGUI_Animal_Starving", RED } },
    thirst = { { "IGUI_Animal_FullyWatered", GREEN }, { "IGUI_Animal_Thirsty", YELLOW }, { "IGUI_Animal_DyingThirst", RED } },
    health = { { "IGUI_Animal_Healthy", GREEN }, { "IGUI_Animal_OffColor", YELLOW }, { "IGUI_Animal_Sickly", ORANGE }, { "IGUI_Animal_Dying", RED } },
    mood = { { "IGUI_Animal_Calm", GREEN }, { "IGUI_Animal_Unnerved", YELLOW }, { "IGUI_Animal_Stressed", ORANGE }, { "IGUI_Animal_Agitated", RED } },
    udder = { { "IGUI_Animal_UdderUrgent", RED }, { "IGUI_Animal_UdderReady", GREEN }, { "IGUI_Animal_UdderSmall", YELLOW },
              { "IGUI_Animal_UdderNotEnough", GRAY }, { "IGUI_Animal_UdderMilked", GRAY }, { "IGUI_Animal_UdderNothing", GRAY } },
    wool = { { "IGUI_Animal_Wool_None", GRAY }, { "IGUI_Animal_Wool_Handful", GRAY }, { "IGUI_Animal_Wool_Little", YELLOW },
             { "IGUI_Animal_Wool_Moderate", YELLOW }, { "IGUI_Animal_Wool_Abundant", GREEN } },
    clutch = { { "IGUI_Animal_ClutchSize_Small", GRAY }, { "IGUI_Animal_ClutchSize_Medium", YELLOW }, { "IGUI_Animal_ClutchSize_Large", GREEN } },
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
-- console: a silent blank dot would look like "fine". `label` prefixes the hover text.
local warnedUnreadable = {}
local function readStage(reading, text, label)
    local prefix = label and (label .. ": ") or ""
    for _, stage in ipairs(stagesOf(reading)) do
        if string.find(text, stage.text, 1, true) then
            return { color = stage.color, text = prefix .. stage.text }
        end
    end
    if not warnedUnreadable[reading] then
        warnedUnreadable[reading] = true
        print(LOG_TAG .. "could not read " .. reading .. " from '" .. tostring(text) .. "'")
    end
    return { color = GRAY, text = prefix .. tostring(text) }
end

local function yesNo(value)
    return getText(value and "IGUI_Yes" or "IGUI_No")
end

-- From the claim source's own client cache (on our server, GENZ_AnimalGuard's; no request of
-- our own). With no source the cell is left out, as for an animal nobody owns.
local function claimCell(animal)
    local source = GENZ_LivestockAudit.source()
    if not source then return nil end
    local claim = source.claimOf(animal)
    if not claim or not claim.owner then return nil end
    if claim.owner == tostring(getCurrentUserSteamID()) then
        return { color = MINE, text = getText("UI_GENZ_LA_ClaimMine") }
    end
    return { color = SOMEONE_ELSES, text = getText("UI_GENZ_LA_ClaimOther") }
end

-- The panel's two red lines (ISAnimalUI.lua:302, :321), shown to any level.
local function alertCell(animal)
    local alerts = {}
    if animal:shouldAnimalStressAboveGround() then
        table.insert(alerts, getText("IGUI_Animal_StressAboveGround"))
    end
    if animal:needHutch() and animal:getDZone() and not animal:getData():getRegionHutch() then
        table.insert(alerts, getText("IGUI_Animal_NoHutch"))
    end
    if #alerts == 0 then return nil end
    return { color = RED, text = table.concat(alerts, " | ") }
end

-- Only a female that can have young gets the line, as in the panel (ISAnimalUI.lua:139).
-- Egg layers show "fertilized"; the others show the vanilla pregnancy text for this level.
local function breedingCell(animal, level)
    if not (animal:getBabyType() and animal:isFemale()) then return nil end
    local data = animal:getData()
    if animal:getEggsPerDay() > 0 then
        local fertilized = data:isFertilized()
        return { color = fertilized and CYAN or GRAY, text = getText("IGUI_Animal_Fertilized") .. ": " .. yesNo(fertilized) }
    end
    local stage = getText("IGUI_No")
    if data:isPregnant() then
        stage = ISAnimalUI.getPregnantText({ animal = animal, skillLvl = level })
    end
    return { color = stage ~= getText("IGUI_No") and CYAN or GRAY, text = getText("IGUI_Animal_Pregnant") .. ": " .. stage }
end

-- The udder line as the panel shows it (ISAnimalUI.lua:260-275): only for a species that
-- can be milked; "needs a baby" before there is milk; the vanilla udder text past 0.1 l.
local function milkCell(animal, level)
    if not animal:canBeMilked() then return nil end
    local data = animal:getData()
    local label = getText("IGUI_Animal_Udder")
    if animal:hasUdder() and not data:canHaveMilk() then
        return { color = GRAY, text = label .. ": " .. getText("IGUI_Animal_NeedBaby") }
    end
    if animal:hasUdder() and data:getMilkQuantity() > 0.1 then
        return readStage("udder", ISAnimalUI.getUdderText({ animal = animal, skillLvl = level }), label)
    end
    return nil
end

local function woolCell(animal)
    if not animal:canBeSheared() then return nil end
    return readStage("wool", ISAnimalUI.getWoolText({ animal = animal }), getText("IGUI_Animal_Wool"))
end

local function clutchCell(animal, level)
    if level < LEVEL.clutch or animal:getData():getClutchSize() <= 0 then return nil end
    return readStage("clutch", ISAnimalUI.getClutchSizeText({ animal = animal }), getText("IGUI_Animal_ClutchSize"))
end

local function layingCell(animal, level)
    local data = animal:getData()
    if level < LEVEL.laying or not data:haveLayingEggPeriod() then return nil end
    local laying = data:isInLayingEggPeriod(getGameTime():getCalender())
    return { color = laying and GREEN or GRAY, text = getText("IGUI_Animal_LayingEggPeriod") .. ": " .. yesNo(laying) }
end

-- The mating season line (ISAnimalUI.lua:161-183 for a female, :195-199 for a young male).
local function seasonCell(animal, level)
    if level < LEVEL.season then return nil end
    local data = animal:getData()
    local label = getText("IGUI_Animal_MatingSeason")
    local tooYoung = data:getDaysSurvived() < animal:getMinAgeForBaby()
    if not animal:isFemale() then
        if not tooYoung then return nil end
        return { color = GRAY, text = label .. ": " .. getText("IGUI_Animal_TooYoungForBaby") }
    end
    if not animal:getBabyType() or animal:isBaby() then return nil end
    if data:getLastPregnancyPeriod() then
        return { color = GRAY, text = label .. ": " .. getText("IGUI_Animal_TooSoonForBaby") }
    end
    if tooYoung then
        return { color = GRAY, text = label .. ": " .. getText("IGUI_Animal_TooYoungForBaby") }
    end
    local inSeason = animal:isInMatingSeason()
    return { color = inSeason and GREEN or GRAY, text = label .. ": " .. yesNo(inSeason) }
end

-- A male's "ready to impregnate" line (ISAnimalUI.lua:202-214).
local function studCell(animal, level)
    if level < LEVEL.stud or animal:isFemale() then return nil end
    local period = animal:getData():getLastImpregnatePeriod(nil)
    if period < 0 then return nil end
    if period == 0 then
        if animal:haveMatingSeason() and not animal:isInMatingSeason() then
            return { color = GRAY, text = getText("IGUI_Animal_MatingSeason") .. ": " .. getText("IGUI_No") }
        end
        return { color = GREEN, text = getText("IGUI_Animal_ReadyToImpregnate") }
    end
    return { color = YELLOW, text = getText("IGUI_Animal_ReadyToImpregnateIn") .. " " .. period .. " " .. getText("IGUI_Gametime_hours") }
end

local function typeCell(animal)
    return { text = getText("IGUI_AnimalType_" .. animal:getAnimalType()) }
end

-- The age text is cut by the engine itself at this level (getAgeText(cheat, skillLvl)).
local function ageCell(animal, level)
    return { text = tostring(animal:getAgeText(false, level)) }
end

-- Kilos past 1 kg, grams below, like the panel (ISAnimalUI.lua:109-113).
local function weightCell(animal, level)
    if level < LEVEL.weight then return nil end
    local weight = animal:getData():getWeight()
    if weight > 1 then return { text = getText("IGUI_AnimalWeight", round(weight, 2)) } end
    return { text = getText("IGUI_AnimalWeightG", round(weight * 1000, 2)) }
end

-- The list icon: the animal's inventory icon when the engine resolves it. The companion
-- mods (CompanionDogs, CompanionCat) register their textures by PATH only, so the bare
-- invIcon name the engine returns for them ("CDDogPaw_64") never resolves; their own kennel
-- UI draws "media/textures/CDPortrait_<breed key>.png" with the paw by path as fallback
-- (CompanionDogs_KennelUI.lua:99-108), and so does the list. Nothing is copied: the textures
-- are read from the loaded mods, and without them the row just has no icon.
local COMPANION_PORTRAIT = "media/textures/CDPortrait_%s.png"
local COMPANION_ICON = "media/textures/%s.png"
local TYPE_SUFFIXES = { "female", "male", "pup" }   -- "female" before "male": it ends with it

-- "huskyfemale" -> "husky"; the five cat coats share "cat" (CompanionCat_Breed.lua:47).
local function typePrefix(animalType)
    local t = tostring(animalType)
    for _, suffix in ipairs(TYPE_SUFFIXES) do
        if #t > #suffix and string.sub(t, -#suffix) == suffix then
            return string.sub(t, 1, #t - #suffix)
        end
    end
    return nil
end

-- The keys of CompanionDogs.BREEDS with this type prefix, sorted so the answer is stable.
local function companionKeys(prefix)
    local keys = {}
    local breeds = CompanionDogs and CompanionDogs.BREEDS
    if not breeds or not prefix then return keys end
    for key, def in pairs(breeds) do
        if type(def) == "table" and def.typePrefix == prefix then table.insert(keys, key) end
    end
    table.sort(keys)
    return keys
end

function Readings.iconOf(animal)
    local texture = animal:getInventoryIconTexture()
    if texture then return texture end
    local name = animal:getInventoryIconTextureName()
    if not name or name == "" then return nil end
    local prefix = typePrefix(animal:getAnimalType())
    local candidates = { prefix }
    for _, key in ipairs(companionKeys(prefix)) do table.insert(candidates, key) end
    for _, key in ipairs(candidates) do
        texture = getTexture(string.format(COMPANION_PORTRAIT, key))
        if texture then return texture end
    end
    return getTexture(string.format(COMPANION_ICON, name))
end

-- Every cell the level allows, keyed by column, plus the row's icon; the tab picks the
-- columns it shows.
function Readings.cellsOf(animal, level)
    local appearance = animal:getAppearanceText(false)
    local cells = {
        icon = Readings.iconOf(animal),
        claim = claimCell(animal),
        hunger = readStage("hunger", appearance),
        thirst = readStage("thirst", appearance),
        health = readStage("health", animal:getHealthText(false, level)),
        mood = readStage("mood", animal:getStressTxt(false, level)),
        alert = alertCell(animal),
        milk = milkCell(animal, level),
        wool = woolCell(animal),
        clutch = clutchCell(animal, level),
        laying = layingCell(animal, level),
        season = seasonCell(animal, level),
        stud = studCell(animal, level),
        type = typeCell(animal),
        age = ageCell(animal, level),
        weight = weightCell(animal, level),
    }
    if level >= LEVEL.breed then cells.breed = breedingCell(animal, level) end
    return cells
end

-- The name's color: sex as hue, a young one lighter. Both are things anyone sees on the
-- animal itself (the type name already says calf, lamb...).
function Readings.nameColor(animal)
    local base = animal:isFemale() and FEMALE or MALE
    if animal:isBaby() then
        return { (base[1] + 1) / 2, (base[2] + 1) / 2, (base[3] + 1) / 2 }
    end
    return base
end

-- The viewer's Animal Care: level, progress to the next level (0..1) and the perk's name.
-- The progress is vanilla's own arithmetic (ISSkillProgressBar.lua:250-291).
function Readings.skillProgress(player)
    local perk = PerkFactory.getPerk(Perks.Husbandry)
    local level = player:getPerkLevel(Perks.Husbandry)
    local fraction = 1
    if level < TOP_LEVEL then
        local gained = player:getXp():getXP(Perks.Husbandry) - ISSkillProgressBar.getPreviousXpLvl(perk, level)
        fraction = math.max(0, math.min(1, gained / ISSkillProgressBar.getXpForLvl(perk, level)))
    end
    return level, fraction, perk:getName()
end
