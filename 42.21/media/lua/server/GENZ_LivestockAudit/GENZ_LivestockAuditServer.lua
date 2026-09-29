-- GENZ_LivestockAuditServer -- records what happens to each claimed animal (card #192).
--
-- Listens to GENZ_AnimalEvents (announced by the creatures domain of GENZ_Equipamentos),
-- reads the engine, lets GENZ_LivestockAuditCore decide, and writes one entry per event
-- into a server-only ModData store. The store is NEVER transmitted: clients will only get
-- the slice they ask for (phases F2/F3). Every entry is echoed to the server console with
-- the [GENZ_LivestockAudit] tag.
--
-- Kinds recorded so far: CLAIMED, RELEASED, DIED, PREGNANT, FERTILIZED, GAVE_BIRTH,
-- PREGNANCY_ENDED, GREW_UP, CRITICAL (F1a); LEFT_ZONE, ENTERED_ZONE (F1b); ATTACKED,
-- HANDLED (F1c).
-- Every entry carries the zone group the animal was in, which is what the owner's
-- History (F3) filters by; an entry outside any zone is for staff only (decision D13).

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

-- Connected zones count as one: walking into a linked pen is not leaving. The group key is
-- the smallest id in the group, compared as text so it works whatever type the id has.
local function zoneGroupKey(zone)
    local key = tostring(zone:getId())
    local group = DesignationZoneAnimal.getAllDZones(nil, zone, nil)
    for i = 0, group:size() - 1 do
        local id = tostring(group:get(i):getId())
        if id < key then key = id end
    end
    return key
end

-- An animal inside a hutch has no zone of its own; the hutch's zone counts, so going to
-- the nest is not leaving. false = in no zone at all.
local function zoneKeyOf(animal)
    local zone = animal:getDZone()
    if not zone then
        local hutch = animal:getHutch()
        if hutch then
            local entrance = hutch:getEntrySq()
            zone = DesignationZoneAnimal.getZone(entrance:getX(), entrance:getY(), entrance:getZ())
        end
    end
    if not zone then return false end
    return zoneGroupKey(zone)
end

-- opts = { animal, detail, zone, actor }, all optional.
--   zone:  the group key to file the entry under; when nil, the zone the animal was last
--          confirmed in. false (no zone) is stored as no zone at all.
--   actor: { sid, name } of the player who did it.
local function logEvent(aid, kind, record, opts)
    local where = positionOf(opts.animal, record)
    local zone = opts.zone
    if zone == nil then zone = Core.bucketFor(store, aid).state.zone end
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
        zone = zone or nil,
        actor = opts.actor and opts.actor.sid,
        actorName = opts.actor and opts.actor.name,
        detail = opts.detail,
    }
    Core.append(store, aid, entry)
    print(LOG_TAG .. Core.consoleLine(aid, entry))
end

-- robustSid can be nil for a player the server never matched to a SteamID; the name is
-- always there, so the entry still says who it was.
local function actorOf(player)
    return { sid = GENZAM.robustSid(player), name = player:getUsername() }
end

-- Actions that take the animal somewhere. They are logged even when the owner does them,
-- because they are what explains a LEFT_ZONE.
local MOVING_ACTIONS = {
    ISPickupAnimal = true, ISAttachAnimalToPlayer = true, ISAttachAnimalToTree = true,
    ISLureAnimal = true, ISPutAnimalInHutch = true, ISHutchGrabAnimal = true,
    ISAddAnimalInTrailer = true, ISRemoveAnimalFromTrailer = true,
}
-- Slaughter passes through the same guard hook as petting, but it is an attack.
local KILL_ACTIONS = { ISKillAnimal = true, ISKillAnimalInInventory = true }

local handlers = {}

-- The claim is the first sighting: it sets the zone baseline, so the entry is filed under
-- the zone the animal was claimed in.
function handlers.claimed(data)
    Core.zoneTransitions(Core.bucketFor(store, data.aid).state, zoneKeyOf(data.animal))
    logEvent(data.aid, "CLAIMED", data.record, { animal = data.animal, detail = { kind = data.record.kind } })
end

function handlers.released(data)
    logEvent(data.aid, "RELEASED", data.record, { detail = { reason = data.reason or "unspecified" } })
end

-- The announcer reports each death once: the death event and the sweep both unclaim, so
-- whichever comes second no longer finds the record.
function handlers.died(data)
    local animal = data.animal
    local state = Core.bucketFor(store, data.aid).state
    local attack = Core.recentMark(state.lastAttack, os.time(), Core.ATTACK_WINDOW_SECONDS)
    local cause = Core.deathCause({
        hunger = animal:getHunger(),
        thirst = animal:getThirst(),
        geriatric = animal:isGeriatric(),
    }, attack)
    local detail = { cause = cause, source = data.source }
    if attack then detail.by = attack.actorName end
    logEvent(data.aid, "DIED", data.record, { animal = animal, detail = detail })
end

-- weapon: the item full type, "projectile" or "slaughter".
local function recordAttack(data, weapon)
    local actor = actorOf(data.actor)
    local state = Core.bucketFor(store, data.aid).state
    local now = os.time()
    if data.allowed then
        state.lastAttack = { actor = actor.sid, actorName = actor.name, ts = now }
    end
    local key = "attacked|" .. tostring(actor.sid or actor.name) .. "|" .. tostring(data.allowed)
    if Core.isRepeat(state, key, now) then return end
    logEvent(data.aid, "ATTACKED", data.record, {
        animal = data.animal, actor = actor,
        detail = { weapon = weapon or "unknown", allowed = data.allowed },
    })
end

function handlers.attacked(data)
    recordAttack(data, data.weapon)
end

-- The owner's routine care (petting, milking, feeding their own animal) is not news and
-- would fill the 150 slots in days; someone else doing it, any refusal and anything that
-- moves the animal is.
function handlers.handled(data)
    if KILL_ACTIONS[data.action] then
        recordAttack(data, "slaughter")
        return
    end
    local actor = actorOf(data.actor)
    local state = Core.bucketFor(store, data.aid).state
    local now = os.time()
    local moving = MOVING_ACTIONS[data.action] == true
    if data.allowed and moving then
        state.lastMover = { actor = actor.sid, actorName = actor.name, action = data.action, ts = now }
    end
    local isOwner = actor.sid ~= nil and actor.sid == data.record.owner
    if data.allowed and isOwner and not moving then return end
    local key = "handled|" .. tostring(actor.sid or actor.name) .. "|" .. data.action .. "|" .. tostring(data.allowed)
    if Core.isRepeat(state, key, now) then return end
    logEvent(data.aid, "HANDLED", data.record, {
        animal = data.animal, actor = actor,
        detail = { action = data.action, allowed = data.allowed },
    })
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

-- LEFT_ZONE is filed under the zone it left, so it shows in that zone's History even with
-- the animal now outside; "none" means no zone at all. It names whoever moved the animal
-- in the last MOVER_WINDOW_SECONDS, and says so when nobody did.
local function logZoneChange(data, state, change)
    local detail = {}
    if change.kind == "LEFT_ZONE" then
        detail.to = change.other or "none"
        local mover = Core.recentMark(state.lastMover, os.time(), Core.MOVER_WINDOW_SECONDS)
        detail.by = mover and mover.actorName or "unidentified"
        if mover then detail.action = mover.action end
    else
        detail.from = change.other or "none"
    end
    logEvent(data.aid, change.kind, data.record, { animal = data.animal, detail = detail, zone = change.zone })
end

function handlers.observed(data)
    local animal = data.animal
    local state = Core.bucketFor(store, data.aid).state

    for _, kind in ipairs(Core.reproductionEvents(state, reproductionOf(animal))) do
        logEvent(data.aid, kind, data.record, { animal = animal })
    end

    local currentType = animal:getAnimalType()
    local grewFrom = Core.growthFrom(state, currentType)
    if grewFrom then
        logEvent(data.aid, "GREW_UP", data.record, { animal = animal, detail = { from = grewFrom, to = currentType } })
    end

    local needs = { hunger = animal:getHunger(), thirst = animal:getThirst() }
    for _, need in ipairs(Core.criticalNeeds(state, needs)) do
        logEvent(data.aid, "CRITICAL", data.record, { animal = animal, detail = { need = need } })
    end

    for _, change in ipairs(Core.zoneTransitions(state, zoneKeyOf(animal))) do
        logZoneChange(data, state, change)
    end
end

-- Kinds without a handler belong to later phases (delivered, captured...) and are ignored
-- until then; the announcer does not care who listens to what.
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
