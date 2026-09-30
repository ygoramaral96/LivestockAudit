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
-- A change of zone counts only after this many sweeps in a row (~1 minute each), so an
-- animal walking along the fence line does not log a leave/enter pair every minute.
Core.ZONE_CONFIRM_PASSES = 2
-- The same actor doing the same thing to the same animal is logged once per this many
-- seconds: a guard's isValid() runs in bursts and a fight is many hits.
Core.REPEAT_SECONDS = 60
-- A death this soon after an ALLOWED attack is blamed on the attacker.
Core.ATTACK_WINDOW_SECONDS = 300
-- Leaving the zone this soon after someone moved the animal names who moved it.
Core.MOVER_WINDOW_SECONDS = 600

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

-- Returns true when this key was already logged less than REPEAT_SECONDS ago; otherwise
-- marks it. Stale keys are forgotten on the way, so visitors do not pile up in the state.
function Core.isRepeat(state, key, now)
    state.recent = state.recent or {}
    local last = state.recent[key]
    if last and now - last < Core.REPEAT_SECONDS then return true end
    state.recent[key] = now
    local stale = {}
    for other, seen in pairs(state.recent) do
        if now - seen >= Core.REPEAT_SECONDS then table.insert(stale, other) end
    end
    for _, other in ipairs(stale) do state.recent[other] = nil end
    return false
end

-- mark = { actor, actorName, action, ts }; returns it only when at most `window` seconds old.
function Core.recentMark(mark, now, window)
    if mark and now - mark.ts <= window then return mark end
    return nil
end

-- snapshot = { hunger, thirst, geriatric } read from the dead animal. A value that could
-- not be read is nil and simply does not match. recentAttack = an allowed attack inside
-- ATTACK_WINDOW_SECONDS (see recentMark), or nil.
function Core.deathCause(snapshot, recentAttack)
    if recentAttack then return "attacked" end
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

-- zoneKey = key of the zone group the animal is in now, or false when it is in no zone.
-- state.zone is nil until the first sighting, which only sets the baseline (the animal was
-- already there; nothing happened). Returns the transitions to record, in order:
--   { kind = "LEFT_ZONE", zone = <left>, other = <new key or false> }
--   { kind = "ENTERED_ZONE", zone = <entered>, other = <old key or false> }
function Core.zoneTransitions(state, zoneKey)
    if state.zone == nil then
        state.zone = zoneKey
        return {}
    end
    if zoneKey == state.zone then
        state.pendingZone, state.pendingPasses = nil, 0
        return {}
    end
    if state.pendingZone == zoneKey then
        state.pendingPasses = state.pendingPasses + 1
    else
        state.pendingZone, state.pendingPasses = zoneKey, 1
    end
    if state.pendingPasses < Core.ZONE_CONFIRM_PASSES then return {} end

    local transitions = {}
    if state.zone then
        table.insert(transitions, { kind = "LEFT_ZONE", zone = state.zone, other = zoneKey })
    end
    if zoneKey then
        table.insert(transitions, { kind = "ENTERED_ZONE", zone = zoneKey, other = state.zone })
    end
    state.zone = zoneKey
    state.pendingZone, state.pendingPasses = nil, 0
    return transitions
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
    if entry.zone then
        table.insert(parts, "zone=" .. tostring(entry.zone))
    end
    if entry.actorName then
        table.insert(parts, "actor=" .. tostring(entry.actorName) .. "(" .. tostring(entry.actor) .. ")")
    end
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

-- ------------------------------------------------------------------ reading the store
-- The staff list (F2) and the owner History (F3) are both cut here, on the server side of
-- the wire: a client only ever receives the slice its role and its level allow.

Core.PAGE_SIZE = 50
Core.HISTORY_LIMIT = 120                    -- decision D16

-- Every kind the audit writes, in the order the staff filter lists them.
Core.KINDS = {
    "CLAIMED", "RELEASED", "DIED", "ATTACKED", "HANDLED", "LEFT_ZONE", "ENTERED_ZONE",
    "PREGNANT", "FERTILIZED", "GAVE_BIRTH", "PREGNANCY_ENDED", "GREW_UP", "CRITICAL",
    "PERMISSION", "REATTACHED", "DOWNED",
}
-- Engine-side incidents: staff reads them, an owner's History does not.
Core.STAFF_ONLY = { REATTACHED = true, DOWNED = true }
-- Kinds that reveal what vanilla hides below an Animal Care level: fertilized/pregnant only
-- from level 3 (ISAnimalUI.lua:138). A birth is not here: the young is there for anyone to see.
Core.MIN_LEVEL = { PREGNANT = 3, FERTILIZED = 3, PREGNANCY_ENDED = 3 }
-- "Old age" as a cause shows from level 5, like vanilla's late readings (weight, mating
-- season: ISAnimalUI.lua:102, :161). Provisional until getAgeText is measured per level.
Core.OLD_AGE_LEVEL = 5

-- filter = { owner = sid, aid = aid, kind = kind, zone = zone key }, each optional.
-- Returns { aid, entry } rows, newest first.
function Core.collect(store, filter)
    local rows = {}
    for aid, bucket in pairs(store.byAnimal) do
        if not filter.aid or filter.aid == aid then
            for _, entry in ipairs(bucket.items) do
                if (not filter.owner or entry.owner == filter.owner)
                    and (not filter.kind or entry.k == filter.kind)
                    and (not filter.zone or entry.zone == filter.zone) then
                    table.insert(rows, { aid = aid, entry = entry })
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.entry.ts ~= b.entry.ts then return a.entry.ts > b.entry.ts end
        return a.entry.t > b.entry.t
    end)
    return rows
end

-- page is 1-based and clamped; returns the slice, the page actually served and the page
-- count (at least 1, so an empty list is "page 1 of 1").
function Core.page(rows, page, size)
    local pages = math.max(1, math.ceil(#rows / size))
    page = math.min(math.max(1, page), pages)
    local slice = {}
    for i = (page - 1) * size + 1, math.min(page * size, #rows) do
        table.insert(slice, rows[i])
    end
    return slice, page, pages
end

-- Owners with at least one entry, and how many, sorted by name: the staff owner filter.
function Core.ownerSummary(store)
    local owners = {}
    for sid, index in pairs(store.byOwner) do
        local count = 0
        for aid in pairs(index.animals) do
            local bucket = store.byAnimal[aid]
            if bucket then
                for _, entry in ipairs(bucket.items) do
                    if entry.owner == sid then count = count + 1 end
                end
            end
        end
        if count > 0 then
            table.insert(owners, { sid = sid, name = index.name or sid, count = count })
        end
    end
    table.sort(owners, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return owners
end

-- What an owner may see of an entry at their Animal Care level: nil when hidden, the entry
-- itself, or a copy with the part their level does not reveal taken out.
function Core.visibleTo(entry, level)
    if Core.STAFF_ONLY[entry.k] then return nil end
    local minLevel = Core.MIN_LEVEL[entry.k]
    if minLevel and level < minLevel then return nil end
    local isOldAge = entry.k == "DIED" and entry.detail and entry.detail.cause == "old_age"
    if isOldAge and level < Core.OLD_AGE_LEVEL then
        local copy = {}
        for key, value in pairs(entry) do copy[key] = value end
        copy.detail = { source = entry.detail.source }
        return copy
    end
    return entry
end

-- The owner's History of one zone group: only their entries (the owner at the time of each
-- entry), only this zone, cut to their level, newest first, at most HISTORY_LIMIT.
function Core.history(store, ownerSid, zoneKey, level)
    local visible = {}
    for _, row in ipairs(Core.collect(store, { owner = ownerSid, zone = zoneKey })) do
        local entry = Core.visibleTo(row.entry, level)
        if entry then
            table.insert(visible, { aid = row.aid, entry = entry })
            if #visible >= Core.HISTORY_LIMIT then break end
        end
    end
    return visible
end

-- Rows as they travel to the client: the entry fields plus its aid, one flat table each.
function Core.toWire(rows)
    local items = {}
    for _, row in ipairs(rows) do
        local item = { aid = row.aid }
        for key, value in pairs(row.entry) do item[key] = value end
        table.insert(items, item)
    end
    return items
end

-- ------------------------------------------------------------------ how an entry reads
-- Returns a translation key and its arguments. An argument is plain text, or
-- { key = <translation key> } / { item = <item full type> } for the client to resolve.
-- A value this version does not know travels as plain text instead of being hidden.

local KEY = "UI_GENZ_LA_"

local ORIGINS = { manual = "manual", capsule = "capsule", genzball = "genzball", unspecified = "unspecified" }
local REASONS = {
    morreu = "Died", ["animal morto"] = "Died", ["dono abriu mao"] = "OwnerLetGo",
    admin = "Admin", captured = "Captured", unclaim = "Unclaim", expired = "Expired",
}
local CAUSES = { hunger = "hunger", thirst = "thirst", old_age = "old_age", unknown = "unknown" }
local ACTIONS = {
    ISPickupAnimal = "Pickup", ISAttachAnimalToPlayer = "Leash", ISAttachAnimalToTree = "Tree",
    ISLureAnimal = "Lure", ISPutAnimalInHutch = "PutInHutch", ISHutchGrabAnimal = "GrabFromHutch",
    ISAddAnimalInTrailer = "TrailerIn", ISRemoveAnimalFromTrailer = "TrailerOut",
    ISMilkAnimal = "Milk", ISShearAnimal = "Shear", ISPetAnimal = "Pet",
    ISFeedAnimalFromHand = "Feed", ISGiveWaterToAnimal = "Water",
}
local FLAGS = {
    AllowFeed = "Feed", AllowPet = "Pet", AllowRename = "Rename", AllowMilk = "Milk",
    AllowShear = "Shear", AllowEgg = "Egg", AllowPickup = "Pickup", AllowHutch = "Hutch",
    AllowTrailer = "Trailer", AllowLeash = "Leash", AllowKill = "Kill",
}
local WEAPONS = { projectile = "projectile", slaughter = "slaughter", unknown = "unknown" }

local function label(map, value, prefix)
    local suffix = map[value]
    if suffix then return { key = KEY .. prefix .. suffix } end
    return tostring(value)
end

local function weaponArg(weapon)
    if weapon == nil or WEAPONS[weapon] then return label(WEAPONS, weapon or "unknown", "Weapon_") end
    return { item = weapon }
end

local function describePermission(entry, d)
    local actor = entry.actorName or "?"
    if d.change == "user_added" then return KEY .. "PermUserAdded", { actor, d.targetName or "?" } end
    if d.change == "user_removed" then return KEY .. "PermUserRemoved", { actor, d.targetName or "?" } end
    local target = d.target == "pub" and { key = KEY .. "Everyone" } or (d.targetName or "?")
    return KEY .. (d.value and "PermFlagOn" or "PermFlagOff"), { actor, label(FLAGS, d.flag, "Flag_"), target }
end

function Core.describe(entry)
    local d = entry.detail or {}
    local kind = entry.k
    local actor = entry.actorName or "?"
    if kind == "CLAIMED" then return KEY .. "Claimed", { label(ORIGINS, d.origin, "Origin_") } end
    if kind == "RELEASED" then return KEY .. "Released", { label(REASONS, d.reason, "Reason_") } end
    if kind == "DIED" then
        if d.cause == "attacked" then return KEY .. "DiedAttacked", { d.by or "?" } end
        if d.cause == nil then return KEY .. "Died", {} end
        return KEY .. "DiedOf", { label(CAUSES, d.cause, "Cause_") }
    end
    if kind == "ATTACKED" then
        return KEY .. (d.allowed and "Attacked" or "AttackBlocked"), { actor, weaponArg(d.weapon) }
    end
    if kind == "HANDLED" then
        return KEY .. (d.allowed and "Handled" or "HandleBlocked"), { actor, label(ACTIONS, d.action, "Action_") }
    end
    if kind == "LEFT_ZONE" then
        if d.by == nil or d.by == "unidentified" then return KEY .. "LeftZone", {} end
        return KEY .. "LeftZoneBy", { d.by, label(ACTIONS, d.action, "Action_") }
    end
    if kind == "CRITICAL" then return KEY .. "Critical_" .. tostring(d.need), {} end
    if kind == "GREW_UP" then
        return KEY .. "GrewUp", { { key = "IGUI_AnimalType_" .. tostring(d.from) }, { key = "IGUI_AnimalType_" .. tostring(d.to) } }
    end
    if kind == "PERMISSION" then return describePermission(entry, d) end
    if kind == "REATTACHED" then return KEY .. "Reattached", { tostring(d.via) } end
    if kind == "DOWNED" then return KEY .. "Downed", { tostring(d.health) } end
    -- ENTERED_ZONE, PREGNANT, FERTILIZED, GAVE_BIRTH, PREGNANCY_ENDED: the kind says it all
    return KEY .. "Kind_" .. tostring(kind), {}
end

-- The animal as a row shows it: its custom name, or the vanilla name of its type.
function Core.animalLabel(entry)
    if entry.name and entry.name ~= "" then return entry.name end
    return { key = "IGUI_AnimalType_" .. tostring(entry.type) }
end

-- "How long ago", as a translation key and its argument.
function Core.ago(seconds)
    if seconds < 60 then return KEY .. "AgoNow", {} end
    if seconds < 3600 then return KEY .. "AgoMinutes", { tostring(math.floor(seconds / 60)) } end
    if seconds < 86400 then return KEY .. "AgoHours", { tostring(math.floor(seconds / 3600)) } end
    return KEY .. "AgoDays", { tostring(math.floor(seconds / 86400)) }
end
