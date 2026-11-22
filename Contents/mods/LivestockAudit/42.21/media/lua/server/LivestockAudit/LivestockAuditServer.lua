-- LivestockAuditServer -- records what happens to each claimed animal.
--
-- Receives animal events through LivestockAudit.record (LivestockAuditApi; the claim
-- source calls it), reads the engine, lets LivestockAuditCore decide, and writes one
-- entry per event into a server-only ModData store. The store is NEVER transmitted: clients will only get
-- the slice they ask for. Every entry is echoed to the server console with
-- the [LivestockAudit] tag.
--
-- Kinds recorded: CLAIMED, RELEASED, DIED, PREGNANT, FERTILIZED, GAVE_BIRTH,
-- PREGNANCY_ENDED, GREW_UP, CRITICAL, LEFT_ZONE, ENTERED_ZONE, ATTACKED, HANDLED,
-- PERMISSION, REATTACHED, DOWNED, RENAMED, plus the origin of a CLAIMED and the
-- reason of a RELEASED ("capsule", "ball", "captured"...).
-- Every entry carries the zone group the animal was in, which is what the owner's
-- History filters by; an entry outside any zone is for staff only.
-- It also follows animals NOBODY owns while they are in a pen: hits, handling that moves
-- them, death, rename (announced with no record) and,
-- from this file's own sweep, critical needs and leaving/entering a pen.

if isClient() and not isServer() then return end

require "LivestockAudit/LivestockAuditApi"
require "LivestockAudit/LivestockAuditCore"

LivestockAuditServer = LivestockAuditServer or {}
local Server = LivestockAuditServer
local Core = LivestockAuditCore
local API = LivestockAudit

local MODDATA_KEY = "LivestockAudit"
local LOG_TAG = "[LivestockAudit] "

local store = nil

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- LivestockAudit.migrateHistory (contract in LivestockAuditApi). It opens the store itself, so
-- it works whether the caller's OnInitGlobalModData runs before or after this file's.
local function migrateHistory(opts)
    local current = Core.initStore(ModData.getOrCreate(MODDATA_KEY))
    if Core.importStore(current, opts.store) then
        print(LOG_TAG .. "history kept under another name copied into " .. MODDATA_KEY
            .. ": " .. countKeys(current.byAnimal) .. " animal bucket(s)")
    end
    local renamed = 0
    for field, words in pairs(opts.words or {}) do
        renamed = renamed + Core.renameDetailWords(current, field, words)
    end
    if renamed > 0 then
        print(LOG_TAG .. "renamed the words of " .. renamed .. " stored entr" .. (renamed == 1 and "y" or "ies"))
    end
end
API.setMigrator(migrateHistory)

Events.OnInitGlobalModData.Add(function()
    store = Core.initStore(ModData.getOrCreate(MODDATA_KEY))
    -- Announce it: a listener that silently failed to start would look exactly like
    -- "nothing happened to any animal". The source registers on OnGameBoot, which the server
    -- fires before loading the world (GameServer.doMinimumInit, 42.21), so this line knows.
    local sourceState = API.source() and "registered" or "none (claimed animals are not audited)"
    print(LOG_TAG .. "listening; store has " .. countKeys(store.byAnimal) .. " animal bucket(s); claim source: " .. sourceState)
end)

-- For the other files of this mod (the queries) and the bench.
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

-- The zone group key of a pen. The History finds the pen from a point on the server; a
-- zone key from the client is never trusted.
function Server.penKey(zone)
    return zoneGroupKey(zone)
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

-- ------------------------------------------------------------------ animals nobody owns
local UNCLAIMED_ID_KEY = Core.UNCLAIMED_ID_KEY
local unclaimedStamps = 0

-- With no claim source nothing is claimed: a server without a claim system has only
-- animals nobody owns.
local function isClaimed(aid)
    local source = API.source()
    return source ~= nil and source.isClaimed(aid) == true
end

-- The claim id the animal carries, from the source; nil with no source.
local function claimIdOf(animal)
    local source = API.source()
    return source and source.animalId(animal)
end

local function isClaimedAnimal(animal)
    local aid = claimIdOf(animal)
    return aid ~= nil and isClaimed(aid)
end

-- The id an animal nobody owns is filed under, or nil. One that had an owner keeps its claim
-- id, so its history goes on in the same bucket. One that never had an owner gets an id of
-- this mod, stamped only when it is in a pen, only on the server, never sent.
-- The claim id itself is NEVER written here: a claim system may re-attach exactly the animals
-- that have none, and stamping a claimed animal that just lost its id in someone's arms would
-- cost its owner the claim.
local function unclaimedId(animal, inPen)
    local modData = animal:getModData()
    local id = claimIdOf(animal) or modData[UNCLAIMED_ID_KEY]
    if id or not inPen then return id end
    unclaimedStamps = unclaimedStamps + 1
    id = "w" .. tostring(getTimestamp()) .. "_" .. tostring(unclaimedStamps)
    modData[UNCLAIMED_ID_KEY] = id
    return id
end

-- What a claim record would say about the animal, for one that has none.
local function unclaimedRecord(animal)
    local breed = animal:getBreed()
    return {
        name = animal:getCustomName(),
        type = animal:getAnimalType(),
        breed = breed and breed:getName(),
    }
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

-- The id the claim source gives the player (typically the SteamID). It can be nil:
-- no source, or a player the server never matched; the name is always there, so the entry
-- still says who it was.
function Server.playerId(player)
    local source = API.source()
    return source and source.playerId(player)
end

local function actorOf(player)
    return { sid = Server.playerId(player), name = player:getUsername() }
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

-- Claimed after being followed with no owner: that history joins the claim's. The stamp
-- goes, so the animal is filed under its claim id from now on.
local function adoptUnclaimedHistory(data)
    local modData = data.animal:getModData()
    local unclaimed = modData[UNCLAIMED_ID_KEY]
    if not unclaimed then return end
    modData[UNCLAIMED_ID_KEY] = nil
    Core.merge(store, unclaimed, data.aid)
end

-- The claim is the first sighting: it sets the zone baseline, so the entry is filed under
-- the zone the animal was claimed in. A staff transfer may come with no animal
-- (it can be far away): no baseline then, and the entry goes where the claim store last saw it.
function handlers.claimed(data)
    if data.animal then
        adoptUnclaimedHistory(data)
        Core.zoneTransitions(Core.bucketFor(store, data.aid).state, zoneKeyOf(data.animal))
    end
    logEvent(data.aid, "CLAIMED", data.record, {
        animal = data.animal,
        actor = data.actor and actorOf(data.actor),
        detail = { kind = data.record.kind, origin = data.origin or "unspecified", note = data.note },
    })
end

-- The owner giving or taking access: who can now touch the animal is part of its story.
-- Staff clearing the public flags comes here too, with the flags that were on
-- and the staff reason.
function handlers.permission(data)
    local cleared = data.flags and table.concat(data.flags, ",") or nil
    logEvent(data.aid, "PERMISSION", data.record, {
        actor = actorOf(data.actor),
        detail = {
            change = data.change, flag = data.flag, value = data.value,
            target = data.target, targetName = data.targetName,
            flags = cleared, note = data.note,
        },
    })
end

-- Engine-side incidents the creatures domain already detects; staff-facing.
function handlers.reattached(data)
    logEvent(data.aid, "REATTACHED", data.record, { animal = data.animal, detail = { via = data.via } })
end

function handlers.downed(data)
    logEvent(data.aid, "DOWNED", data.record, {
        animal = data.animal, detail = { health = data.health, state = data.state },
    })
end

-- A staff release or transfer names the staff member and their reason.
function handlers.released(data)
    logEvent(data.aid, "RELEASED", data.record, {
        actor = data.actor and actorOf(data.actor),
        detail = { reason = data.reason or "unspecified", note = data.note },
    })
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

-- Every rename is news, the owner's too; a refused attempt is logged once a minute
-- per person, since the button can be pressed again and again.
function handlers.renamed(data)
    local actor = actorOf(data.actor)
    local state = Core.bucketFor(store, data.aid).state
    if not data.allowed and Core.isRepeat(state, "renamed|" .. tostring(actor.sid or actor.name), os.time()) then
        return
    end
    logEvent(data.aid, "RENAMED", data.record, {
        animal = data.animal, actor = actor,
        detail = { from = data.from, to = data.to, allowed = data.allowed },
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

-- What is kept of an animal nobody owns: only inside a pen, and of the handling only
-- what moves it (it explains a LEFT_ZONE) or kills it -- anyone petting or feeding a
-- stray is not news.
local UNCLAIMED_KINDS = { attacked = true, handled = true, died = true, renamed = true }

local function onUnclaimedEvent(kind, data)
    if not UNCLAIMED_KINDS[kind] or not data.animal then return end
    if kind == "handled" and not (MOVING_ACTIONS[data.action] or KILL_ACTIONS[data.action]) then return end
    local zone = zoneKeyOf(data.animal)
    if not zone then return end
    local id = unclaimedId(data.animal, true)
    local state = Core.bucketFor(store, id).state
    if state.zone == nil then state.zone = zone end
    data.aid, data.record = id, unclaimedRecord(data.animal)
    handlers[kind](data)
end

-- A kind without a handler is ignored: the source does not care what this mod reads, and
-- a new kind added there must not break this one.
local function onAnimalEvent(kind, data)
    if not handlers[kind] then return end
    if not store then
        error("store not initialised: OnInitGlobalModData has not run yet")
    end
    if data.record == nil then
        onUnclaimedEvent(kind, data)
        return
    end
    handlers[kind](data)
end

API.setRecorder(onAnimalEvent)

-- The claim sweep visits claimed animals only; one nobody owns is followed here, once a
-- minute, while it is in a pen or has a bucket from before. One that was never in
-- a pen is not stamped, not stored, not followed. Needs count only inside a pen.
local function observeUnclaimed(animal)
    if animal:isDead() or isClaimedAnimal(animal) then return end
    local zone = zoneKeyOf(animal)
    local id = unclaimedId(animal, zone ~= false)
    if not id then return end
    if not zone and not store.byAnimal[id] then return end
    local state = Core.bucketFor(store, id).state
    local data = { aid = id, record = unclaimedRecord(animal), animal = animal }
    -- the zone first: on a first sighting it sets the baseline the needs are filed under
    for _, change in ipairs(Core.zoneTransitions(state, zone)) do
        logZoneChange(data, state, change)
    end
    if zone then
        local needs = { hunger = animal:getHunger(), thirst = animal:getThirst() }
        for _, need in ipairs(Core.criticalNeeds(state, needs)) do
            logEvent(id, "CRITICAL", data.record, { animal = animal, detail = { need = need } })
        end
    end
end

Events.EveryOneMinute.Add(function()
    local animals = getCell():getAnimals()
    for i = 0, animals:size() - 1 do
        -- isolated the way the announcer isolates its listeners: one odd animal must not stop
        -- the sweep for all the others, and it says so every time
        local ok, err = pcall(observeUnclaimed, animals:get(i))
        if not ok then
            print(LOG_TAG .. "unclaimed sweep failed on one animal: " .. tostring(err))
        end
    end
end)

-- With no claim source registered, "not claimed" cannot be told from "the source failed to
-- register", and pruning on that guess would erase the history of claimed animals. So only
-- the buckets this mod opened itself (ids stamped "w...", unclaimedId) may go then.
local UNCLAIMED_ID_PREFIX = "w"

local function isKept(aid)
    if API.source() then return isClaimed(aid) end
    return string.sub(tostring(aid), 1, #UNCLAIMED_ID_PREFIX) ~= UNCLAIMED_ID_PREFIX
end

Events.EveryDays.Add(function()
    local removed = Core.prune(store, os.time(), isKept)
    if removed > 0 then
        print(LOG_TAG .. "pruned " .. removed .. " unclaimed bucket(s) with no entry for 30 days")
    end
end)
