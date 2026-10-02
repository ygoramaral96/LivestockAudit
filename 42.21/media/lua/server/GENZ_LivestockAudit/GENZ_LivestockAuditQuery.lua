-- GENZ_LivestockAuditQuery -- answers the staff list (F2), the owner History (F3) and the
-- staff "Animal Claims" list (card #210).
--
-- Every answer is cut here, on the server: a client never receives the store, only the
-- slice its role (staff) or its claims, its distance to the pen and its Animal Care level
-- (History) allow. A request that fails a check gets no answer or an empty one, and leaves
-- one line in the server console.

if isClient() and not isServer() then return end

require "GENZ_LivestockAudit/GENZ_LivestockAuditCore"
require "GENZ_LivestockAudit/GENZ_LivestockAuditClaimsCore"
require "GENZ_LivestockAudit/GENZ_LivestockAuditServer"

local Core = GENZ_LivestockAuditCore
local Claims = GENZ_LivestockAuditClaimsCore
local Server = GENZ_LivestockAuditServer

local NET = "GENZ_LivestockAudit"
local LOG_TAG = "[GENZ_LivestockAudit] "
-- A page click or a History button pressed twice is fine; a client flooding the command is not.
local REQUEST_COOLDOWN_MS = 500

local lastRequestAt = {}

-- The same capability that enables vanilla's "See tickets" in the admin panel: whoever
-- answers support is whoever investigates "my animal is gone" (decision D18).
local function hasCapability(player, capability)
    local role = player:getRole()
    return role ~= nil and role:hasCapability(capability)
end

local function isSupportStaff(player)
    return hasCapability(player, Capability.AnswerTickets)
end

local function isTooSoon(player)
    local key = player:getUsername()
    local now = getTimestampMs()
    local last = lastRequestAt[key]
    if last and now - last < REQUEST_COOLDOWN_MS then return true end
    lastRequestAt[key] = now
    return false
end

-- args = { owner = sid, kind = kind, aid = aid, page = n }; all optional.
local function answerList(player, args)
    if not isSupportStaff(player) then
        print(LOG_TAG .. "refused the staff list to " .. player:getUsername() .. " (no AnswerTickets)")
        return
    end
    local store = Server.store()
    local rows = Core.collect(store, { owner = args.owner, kind = args.kind, aid = args.aid })
    local slice, page, pages = Core.page(rows, tonumber(args.page) or 1, Core.PAGE_SIZE)
    sendServerCommand(player, NET, "listResult", {
        items = Core.toWire(slice), page = page, pages = pages, total = #rows,
        owners = Core.ownerSummary(store), now = os.time(),
    })
end

local function penRect(zone)
    return { x = zone:getX(), y = zone:getY(), w = zone:getW(), h = zone:getH() }
end

-- args = { x, y, z } of the pen whose Check Zone window asked. The answer holds the asker's
-- own entries plus those of animals nobody owned (D26), so the pen must be one the asker is
-- near: without that, a forged command could scan the map for pens -- that is, for bases.
local function answerHistory(player, args)
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    local zone = x and y and z and DesignationZoneAnimal.getZone(x, y, z)
    local where = tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
    local items = {}
    if not zone then
        print(LOG_TAG .. "history for " .. player:getUsername() .. " answered empty: no pen at " .. where)
    elseif not Core.isWithinReach(penRect(zone), player:getX(), player:getY()) then
        print(LOG_TAG .. "history for " .. player:getUsername() .. " answered empty: too far from the pen at " .. where)
    else
        local level = player:getPerkLevel(Perks.Husbandry)
        items = Core.toWire(Core.history(Server.store(), GENZAM.robustSid(player), Server.penKey(zone), level))
    end
    sendServerCommand(player, NET, "historyResult", { items = items, now = os.time() })
end

-- One owner's pots summed (farm + dog), for the summary's slot line.
local function slotsOf(sid)
    return {
        owned = GENZAM.ownedCount(sid),
        budget = GENZAM.budget(sid, "fazenda") + GENZAM.budget(sid, "cao"),
        extra = GENZAM.extra(sid, "fazenda") + GENZAM.extra(sid, "cao"),
    }
end

-- args = { filter = {...}, page = n } (card #210). The staff "Animal Claims" window: every
-- claim of the claim store -- read here, never written -- cut to one page. Whether the
-- animal is loaded now and how its claim began (from this mod's store) are added to that
-- page only: the first walks the loaded animals, the second a bucket.
local function answerClaims(player, args)
    if not isSupportStaff(player) then
        print(LOG_TAG .. "refused the claims list to " .. player:getUsername() .. " (no AnswerTickets)")
        return
    end
    local now = getTimestamp()
    local opts = { now = now, timeoutHours = GENZAM.claimTimeoutHours(), flags = GENZAM.PERM_FLAGS }
    local all = Claims.rows(GENZAM.byAnimal, GENZAM.byOwner, opts)
    local rows = Claims.filter(all, Claims.readFilter(args.filter), now)
    local slice, page, pages = Core.page(rows, tonumber(args.page) or 1, Claims.PAGE_SIZE)
    local store = Server.store()
    for _, row in ipairs(slice) do
        row.loaded = GENZAM.findAnimal(row.aid) ~= nil
        row.origin = Claims.originOf(store.byAnimal[row.aid])
    end
    sendServerCommand(player, NET, "claimsResult", {
        items = slice, page = page, pages = pages, total = #rows,
        summary = Claims.summary(all, now, slotsOf),
        owners = Claims.owners(all), types = Claims.types(all),
        now = now, timeoutHours = opts.timeoutHours,
    })
end

local handlers = { list = answerList, history = answerHistory, claims = answerClaims }

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= NET then return end
    local handler = handlers[command]
    if not handler or isTooSoon(player) then return end
    handler(player, args or {})
end)
