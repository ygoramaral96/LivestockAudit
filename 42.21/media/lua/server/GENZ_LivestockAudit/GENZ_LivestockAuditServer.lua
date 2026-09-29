-- GENZ_LivestockAuditServer -- records what happens to each claimed animal (card #192).
--
-- Listens to GENZ_AnimalEvents (announced by the creatures domain of GENZ_Equipamentos),
-- reads the engine, lets GENZ_LivestockAuditCore decide, and writes one entry per event
-- into a server-only ModData store. The store is NEVER transmitted: clients will only get
-- the slice they ask for (phases F2/F3). Every entry is echoed to the server console with
-- the [GENZ_LivestockAudit] tag.
--
-- Kinds recorded so far (F1a): CLAIMED, RELEASED, DIED, PREGNANT, FERTILIZED, GAVE_BIRTH,
-- PREGNANCY_ENDED, GREW_UP, CRITICAL.

if isClient() and not isServer() then return end

require "criaturas/GENZ_AnimalEvents"
require "GENZ_LivestockAudit/GENZ_LivestockAuditCore"

GENZ_LivestockAuditServer = GENZ_LivestockAuditServer or {}
local Server = GENZ_LivestockAuditServer
local Core = GENZ_LivestockAuditCore

local MODDATA_KEY = "GENZ_LivestockAudit"
local LOG_TAG = "[GENZ_LivestockAudit] "

local store = nil

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

Events.OnInitGlobalModData.Add(function()
    store = Core.initStore(ModData.getOrCreate(MODDATA_KEY))
    -- Announce it: a listener that silently failed to start would look exactly like
    -- "nothing happened to any animal".
    print(LOG_TAG .. "listening; store has " .. countKeys(store.byAnimal) .. " animal bucket(s)")
end)

-- For the other files of this mod (the F2/F3 queries) and the bench.
function Server.store()
    return store
end

local function positionOf(animal, record)
    if animal then
        return { x = math.floor(animal:getX()), y = math.floor(animal:getY()), z = math.floor(animal:getZ()) }
    end
    -- released by id: the animal may be far away; use the last position the claim store saw
    return { x = record.x, y = record.y, z = record.z }
end

local function logEvent(aid, kind, record, animal, detail)
    local where = positionOf(animal, record)
    local entry = {
        t = getGameTime():getWorldAgeHours(),
        ts = os.time(),
        k = kind,
        owner = record.owner,
        ownerName = record.ownerName,
        name = record.name,
        type = record.type,
        breed = record.breed,
        x = where.x, y = where.y, z = where.z,
        detail = detail,
    }
    Core.append(store, aid, entry)
    print(LOG_TAG .. Core.consoleLine(aid, entry))
end

local handlers = {}

function handlers.claimed(data)
    logEvent(data.aid, "CLAIMED", data.record, data.animal, { kind = data.record.kind })
end

function handlers.released(data)
    logEvent(data.aid, "RELEASED", data.record, nil, { reason = data.reason or "unspecified" })
end

-- The announcer reports each death once: the death event and the sweep both unclaim, so
-- whichever comes second no longer finds the record.
function handlers.died(data)
    local animal = data.animal
    local cause = Core.deathCause({
        hunger = animal:getHunger(),
        thirst = animal:getThirst(),
        geriatric = animal:isGeriatric(),
    })
    logEvent(data.aid, "DIED", data.record, animal, { cause = cause, source = data.source })
end

-- Vanilla decides "fertilized" versus "pregnant" by the species laying eggs
-- (ISAnimalUI.lua: getEggsPerDay() > 0); a pregnant mammal is not "fertilized" here.
local function reproductionOf(animal)
    local animalData = animal:getData()
    local pregnant = animalData:isPregnant()
    local ratio = nil
    if pregnant then
        ratio = animalData:getPregnancyTime() / animalData:getPregnantPeriod()
    end
    return {
        pregnant = pregnant,
        ratio = ratio,
        fertilized = animal:getEggsPerDay() > 0 and animalData:isFertilized(),
    }
end

function handlers.observed(data)
    local animal = data.animal
    local state = Core.bucketFor(store, data.aid).state

    for _, kind in ipairs(Core.reproductionEvents(state, reproductionOf(animal))) do
        logEvent(data.aid, kind, data.record, animal, nil)
    end

    local currentType = animal:getAnimalType()
    local grewFrom = Core.growthFrom(state, currentType)
    if grewFrom then
        logEvent(data.aid, "GREW_UP", data.record, animal, { from = grewFrom, to = currentType })
    end

    local needs = { hunger = animal:getHunger(), thirst = animal:getThirst() }
    for _, need in ipairs(Core.criticalNeeds(state, needs)) do
        logEvent(data.aid, "CRITICAL", data.record, animal, { need = need })
    end
end

-- Kinds without a handler belong to later phases (attacked, handled, delivered...) and
-- are ignored until then; the announcer does not care who listens to what.
local function onAnimalEvent(kind, data)
    local handler = handlers[kind]
    if not handler then return end
    if not store then
        error("store not initialised: OnInitGlobalModData has not run yet")
    end
    handler(data)
end

GENZ_AnimalEvents.subscribe(onAnimalEvent)

local function isClaimed(aid)
    return GENZAM.byAnimal[aid] ~= nil
end

Events.EveryDays.Add(function()
    local removed = Core.prune(store, os.time(), isClaimed)
    if removed > 0 then
        print(LOG_TAG .. "pruned " .. removed .. " unclaimed bucket(s) with no entry for 30 days")
    end
end)
