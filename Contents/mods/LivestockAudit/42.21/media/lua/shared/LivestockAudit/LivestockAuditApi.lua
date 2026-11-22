-- LivestockAuditApi -- the only door into LivestockAudit from another mod (card #299).
--
-- WHY IT EXISTS
-- This mod is standalone: it is published on its own. It must not read anyone's internals (study of card #142, §R.9). Whoever owns
-- claimed animals TELLS it what happens, through two calls:
--
--   LivestockAudit.record(kind, data)    an animal event, as it happens (server only)
--   LivestockAudit.registerSource(src)   who answers questions about the claims
--
-- With nobody calling either, the mod still follows animals nobody owns inside a pen
-- (vanilla engine only), and its boot line in the server console says "claim source: none".
--
-- EVENTS (kind -> data). `record` is the claim record at that moment, READ-ONLY here;
-- `animal` is the live IsoAnimal when there is one; `actor` is an IsoPlayer.
--   "claimed"    { aid, record, animal, origin, actor, note }
--   "released"   { aid, record, reason, actor, note }
--   "permission" { aid, record, actor, change, flag, value, target, targetName, flags, note }
--   "reattached" { aid, record, animal, via }
--   "downed"     { aid, record, animal, health, state }
--   "died"       { aid, record, animal, source }
--   "observed"   { aid, record, animal }                 a periodic visit of a claimed animal
--   "attacked"   { aid, record, animal, actor, weapon, allowed }
--   "handled"    { aid, record, animal, actor, action, allowed }   action = timed action class
--   "renamed"    { aid, record, animal, actor, from, to, allowed }
-- "attacked", "handled", "renamed" and "died" may also come for an animal nobody owns:
-- record = nil. An unknown kind is ignored, so a source may announce more than this mod reads.
-- A claim record carries: owner (player id), ownerName, kind ("fazenda" | "cao"), type,
-- breed, name, female, x, y, z, claimTime, seenAt, users = { [id] = { name, <flag> = bool } },
-- pub = { <flag> = bool }.
--
-- SOURCE. One table; each function is asked for only where it is used.
--   server:  playerId(player) -> id or nil      the id claim records use as `owner`
--            isClaimed(aid) -> bool
--            claims() -> records, owners         records[aid] = claim record;
--                                                owners[id] = { lastLogon = <epoch s> }
--            slots(id) -> { owned, budget, extra }
--            timeoutHours() -> number            <= 0 means claims never expire
--            permissionFlags() -> { "AllowFeed", ... }   display order of the flags
--            isLoaded(aid) -> bool               the animal is in a loaded cell now
--   client:  claimOf(animal) -> { owner } or nil
-- Register it when every mod's Lua has loaded (OnGameBoot on the server, OnGameStart on the
-- client): then the order of the two mods in `Mods=` does not matter.

LivestockAudit = LivestockAudit or {}
local API = LivestockAudit

local LOG_TAG = "[LivestockAudit] "
local SERVER_FUNCTIONS = { "playerId", "isClaimed", "claims", "slots", "timeoutHours", "permissionFlags", "isLoaded" }
local CLIENT_FUNCTIONS = { "claimOf" }

local registeredSource = nil
local recorder = nil

local function isServerSide()
    return isServer() or not isClient()
end

local function requiredFunctions()
    local names = {}
    if isServerSide() then
        for _, name in ipairs(SERVER_FUNCTIONS) do table.insert(names, name) end
    end
    if isClient() or not isServer() then
        for _, name in ipairs(CLIENT_FUNCTIONS) do table.insert(names, name) end
    end
    return names
end

-- A source missing a function would only fail the day a staff member opens the window,
-- so it is refused here, naming what is missing.
function API.registerSource(source)
    if type(source) ~= "table" then
        error("LivestockAudit.registerSource: the source must be a table, got " .. type(source))
    end
    for _, name in ipairs(requiredFunctions()) do
        if type(source[name]) ~= "function" then
            error("LivestockAudit.registerSource: the source has no function '" .. name .. "'")
        end
    end
    if registeredSource == source then return end
    if registeredSource ~= nil then
        error("LivestockAudit.registerSource: a claim source is already registered; only one is supported")
    end
    registeredSource = source
    print(LOG_TAG .. "claim source registered")
end

-- The registered source, or nil: on a server with no claim system that is normal; on ours it
-- means the bridge never registered, and the boot line says so.
function API.source()
    return registeredSource
end

-- For this mod's server file only: who handles record().
function API.setRecorder(handler)
    recorder = handler
end

function API.record(kind, data)
    if recorder == nil then
        error("LivestockAudit.record: no recorder -- record() runs on the server, after the audit server file loaded")
    end
    recorder(kind, data)
end
