-- GENZ_LivestockAuditCore -- pure rules of the livestock audit (card #192).
--
-- No engine call lives here: every function receives plain values and tables, so the
-- whole rule set runs in the lupa bench (scripts/testar_livestock_audit.py) without a
-- game. The server file reads the engine and hands the values over.
--
-- STORE (server-only ModData, never transmitted):
--   store.byAnimal[aid] = { last = <os.time of the newest entry>, items = { entry... }, state = {...} }
--   store.byOwner[sid]  = { name = <newest owner name>, animals = { [aid] = true } }
-- One bucket per ANIMAL (Ygor, 29/09): a noisy animal cannot push another animal's
-- history out, and the bucket outlives the claim record, which is deleted on death.

GENZ_LivestockAuditCore = {}
local Core = GENZ_LivestockAuditCore

Core.MAX_EVENTS_PER_ANIMAL = 150            -- decision D15
Core.RETENTION_SECONDS = 30 * 24 * 60 * 60  -- D15: unclaimed bucket with no new entry for 30 days is dropped
Core.CRITICAL_ON = 0.8                      -- hunger/thirst above this is critical
Core.CRITICAL_OFF = 0.6                     -- re-armed only below this, so a need hovering at 0.8 logs once
Core.DEATH_NEED = 0.9                       -- a need above this at death is named as the cause
-- The coarse branch of vanilla ISAnimalUI:getPregnantText (skill <= 4) shows nothing below
-- 20% of the pregnancy. Logging only from there means the log never reveals a pregnancy
-- earlier than the game itself would (decision D8).
Core.PREGNANCY_VISIBLE = 0.2
-- A pregnancy last seen at 95%+ that ends is a birth; ending earlier has no known reason
-- and is logged as such, never guessed.
Core.BIRTH_NEAR = 0.95

local NEEDS = { "hunger", "thirst" }

local function isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

function Core.initStore(store)
    store.byAnimal = store.byAnimal or {}
    store.byOwner = store.byOwner or {}
    return store
end

-- The bucket is created on first use: animals claimed before this mod existed get one
-- the first time the sweep sees them.
function Core.bucketFor(store, aid)
    local bucket = store.byAnimal[aid]
    if not bucket then
        bucket = { items = {}, state = {} }
        store.byAnimal[aid] = bucket
    end
    return bucket
end

function Core.append(store, aid, entry)
    local bucket = Core.bucketFor(store, aid)
    table.insert(bucket.items, entry)
    while #bucket.items > Core.MAX_EVENTS_PER_ANIMAL do
        table.remove(bucket.items, 1)
    end
    bucket.last = entry.ts
    if entry.owner then
        local index = store.byOwner[entry.owner] or { animals = {} }
        index.name = entry.ownerName or index.name
        index.animals[aid] = true
        store.byOwner[entry.owner] = index
    end
    return bucket
end

-- isClaimed(aid) answers whether the animal still has an owner; the claim store lives in
-- another mod, so the caller supplies it. Removals are collected first: clearing keys of
-- the table being walked by pairs() is not something to bet on in Kahlua.
function Core.prune(store, now, isClaimed)
    local expired = {}
    for aid, bucket in pairs(store.byAnimal) do
        if not isClaimed(aid) and (bucket.last or 0) < now - Core.RETENTION_SECONDS then
            table.insert(expired, aid)
        end
    end
    for _, aid in ipairs(expired) do store.byAnimal[aid] = nil end

    local emptyOwners = {}
    for sid, index in pairs(store.byOwner) do
        for _, aid in ipairs(expired) do index.animals[aid] = nil end
        if isEmpty(index.animals) then table.insert(emptyOwners, sid) end
    end
    for _, sid in ipairs(emptyOwners) do store.byOwner[sid] = nil end
    return #expired
end

-- snapshot = { hunger, thirst, geriatric } read from the dead animal. A value that could
-- not be read is nil and simply does not match.
function Core.deathCause(snapshot)
    if snapshot.hunger and snapshot.hunger > Core.DEATH_NEED then return "hunger" end
    if snapshot.thirst and snapshot.thirst > Core.DEATH_NEED then return "thirst" end
    if snapshot.geriatric then return "old_age" end
    return "unknown"
end

-- now = { pregnant, ratio = pregnancyTime / pregnantPeriod (nil when not pregnant), fertilized }
-- Mutates state; returns the kinds to record, in order.
function Core.reproductionEvents(state, now)
    local kinds = {}
    if now.pregnant and now.ratio and now.ratio >= Core.PREGNANCY_VISIBLE and not state.pregnancyLogged then
        table.insert(kinds, "PREGNANT")
        state.pregnancyLogged = true
    end
    if state.wasPregnant and not now.pregnant and state.pregnancyLogged then
        local nearTerm = state.lastRatio ~= nil and state.lastRatio >= Core.BIRTH_NEAR
        table.insert(kinds, nearTerm and "GAVE_BIRTH" or "PREGNANCY_ENDED")
        state.pregnancyLogged = false
    end
    if now.fertilized and not state.fertilized then
        table.insert(kinds, "FERTILIZED")
    end
    state.wasPregnant = now.pregnant
    state.lastRatio = now.ratio
    state.fertilized = now.fertilized
    return kinds
end

-- Returns the previous type when the animal grew into another one (lamb -> ewe);
-- the first sighting only sets the baseline.
function Core.growthFrom(state, animalType)
    local previous = state.type
    state.type = animalType
    if previous and animalType and previous ~= animalType then return previous end
    return nil
end

-- needs = { hunger = 0..1, thirst = 0..1 }; returns the needs that just became critical.
function Core.criticalNeeds(state, needs)
    state.critical = state.critical or {}
    local crossed = {}
    for _, need in ipairs(NEEDS) do
        local value = needs[need]
        if value then
            if not state.critical[need] and value > Core.CRITICAL_ON then
                state.critical[need] = true
                table.insert(crossed, need)
            elseif state.critical[need] and value < Core.CRITICAL_OFF then
                state.critical[need] = false
            end
        end
    end
    return crossed
end

-- One console line per entry, "key=value" pairs so the console reader can grep them.
function Core.consoleLine(aid, entry)
    local parts = {
        entry.k,
        "aid=" .. tostring(aid),
        "type=" .. tostring(entry.type),
        "owner=" .. tostring(entry.ownerName) .. "(" .. tostring(entry.owner) .. ")",
        "at=" .. tostring(entry.x) .. "," .. tostring(entry.y) .. "," .. tostring(entry.z),
    }
    if entry.detail then
        local keys = {}
        for key in pairs(entry.detail) do table.insert(keys, key) end
        table.sort(keys)
        for _, key in ipairs(keys) do
            table.insert(parts, key .. "=" .. tostring(entry.detail[key]))
        end
    end
    return table.concat(parts, " ")
end
