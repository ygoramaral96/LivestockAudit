-- GENZ_LivestockAuditQuery -- answers the staff list (F2) and the owner History (F3).
--
-- Every answer is cut here, on the server: a client never receives the store, only the
-- slice its role (staff) or its claims and Animal Care level (owner) allow. A request that
-- fails the check gets no answer and leaves one line in the server console.

if isClient() and not isServer() then return end

require "GENZ_LivestockAudit/GENZ_LivestockAuditCore"
require "GENZ_LivestockAudit/GENZ_LivestockAuditServer"

local Core = GENZ_LivestockAuditCore
local Server = GENZ_LivestockAuditServer

local NET = "GENZ_LivestockAudit"
local LOG_TAG = "[GENZ_LivestockAudit] "
-- A page click or a History button pressed twice is fine; a client flooding the command is not.
local REQUEST_COOLDOWN_MS = 500

local lastRequestAt = {}

-- The same capability that enables vanilla's "See tickets" in the admin panel: whoever
-- answers support is whoever investigates "my animal is gone" (decision D18).
local function isSupportStaff(player)
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.AnswerTickets)
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

-- args = { x, y, z } of the pen whose Check Zone window asked. Only the asker's own entries
-- are returned, so the point needs no proximity check: there is nothing of anyone else to see.
local function answerHistory(player, args)
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    local zoneKey = x and y and z and Server.zoneKeyAt(x, y, z)
    local ownerSid = GENZAM.robustSid(player)
    local items = {}
    if zoneKey and ownerSid then
        local level = player:getPerkLevel(Perks.Husbandry)
        items = Core.toWire(Core.history(Server.store(), ownerSid, zoneKey, level))
    else
        print(LOG_TAG .. "history for " .. player:getUsername() .. " answered empty: "
              .. (zoneKey and "no SteamID matched" or "no pen at " .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)))
    end
    sendServerCommand(player, NET, "historyResult", { items = items, now = os.time() })
end

local handlers = { list = answerList, history = answerHistory }

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= NET then return end
    local handler = handlers[command]
    if not handler or isTooSoon(player) then return end
    handler(player, args or {})
end)
