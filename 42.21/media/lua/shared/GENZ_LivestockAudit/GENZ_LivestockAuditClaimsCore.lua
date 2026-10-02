-- GENZ_LivestockAuditClaimsCore -- pure rules of the staff "Animal Claims" window (card #210).
--
-- The window lists every animal claim: whose it is, what it lets everyone do, who the owner
-- let in, when the animal was last seen and when the claim would expire. The claim store
-- belongs to GENZ_Equipamentos (GENZAM.byAnimal / GENZAM.byOwner); the server file reads it
-- and hands the tables over, and everything here works on plain tables -- the whole rule
-- set runs in the lupa bench (scripts/testar_claims_staff.py) without a game.

GENZ_LivestockAuditClaimsCore = {}
local Claims = GENZ_LivestockAuditClaimsCore

Claims.PAGE_SIZE = 50
Claims.DAY_SECONDS = 86400
-- The "not seen for" steps the window offers and the summary counts.
Claims.WEEK_DAYS = 7
Claims.MONTH_DAYS = 30
-- A staff reason is refused below this many characters. GENZ_AnimalManagerServer refuses
-- it again with the same number (STAFF_NOTE_MIN); this one only keeps OK disabled.
Claims.REASON_MIN = 3

local function byName(a, b)
    return string.lower(a.name) < string.lower(b.name)
end

-- The flags of `perms` that are on, in the order of `flags` (GENZAM.PERM_FLAGS, the order
-- of the F5 tab), so two rows read alike.
local function flagsOn(perms, flags)
    local on = {}
    if not perms then return on end
    for _, flag in ipairs(flags) do
        if perms[flag] == true then table.insert(on, flag) end
    end
    return on
end

-- Seconds from `now` until the claim expires: the owner's last login + ClaimTimeout. nil when
-- it never expires (ClaimTimeout <= 0, card #209) or the owner has no login recorded.
-- Negative = overdue (the hourly expiry has not run yet).
function Claims.expiresIn(lastLogon, timeoutHours, now)
    if not lastLogon or not timeoutHours or timeoutHours <= 0 then return nil end
    return lastLogon + timeoutHours * 3600 - now
end

-- opts = { now, timeoutHours, flags }. owner = GENZAM.byOwner[rec.owner] (lastLogon).
function Claims.row(aid, rec, owner, opts)
    local friends = {}
    for sid, perms in pairs(rec.users or {}) do
        table.insert(friends, { sid = sid, name = tostring(perms.name or sid), on = flagsOn(perms, opts.flags) })
    end
    table.sort(friends, byName)
    local lastLogon = owner and owner.lastLogon
    return {
        aid = aid,
        owner = rec.owner,
        ownerName = tostring(rec.ownerName or rec.owner),
        kind = (rec.kind == "cao") and "cao" or "fazenda",
        type = rec.type, breed = rec.breed, name = rec.name, female = rec.female,
        x = rec.x or 0, y = rec.y or 0, z = rec.z or 0,
        claimTime = rec.claimTime,
        seenAt = rec.seenAt,
        lastLogon = lastLogon,
        expiresIn = Claims.expiresIn(lastLogon, opts.timeoutHours, opts.now),
        publicOn = flagsOn(rec.pub, opts.flags),
        friends = friends,
    }
end

-- Every claim as a row, by owner name then id. records = GENZAM.byAnimal, owners =
-- GENZAM.byOwner.
function Claims.rows(records, owners, opts)
    local rows = {}
    for aid, rec in pairs(records) do
        if rec.owner then table.insert(rows, Claims.row(aid, rec, owners[rec.owner], opts)) end
    end
    table.sort(rows, function(a, b)
        local an, bn = string.lower(a.ownerName), string.lower(b.ownerName)
        if an ~= bn then return an < bn end
        return a.aid < b.aid
    end)
    return rows
end

-- Not seen for at least `days`; a claim with no sighting counts. The server repeats it
-- before releasing a ghost (GENZ_AnimalManagerServer, isStillGhost).
function Claims.isUnseen(row, days, now)
    return (row.seenAt or 0) <= now - days * Claims.DAY_SECONDS
end

local function hasFlag(list, flag)
    for _, f in ipairs(list) do
        if f == flag then return true end
    end
    return false
end

local function positive(value)
    local n = tonumber(value)
    if n and n > 0 then return n end
    return nil
end

-- What a client sent, kept only where it makes sense; anything else means "no filter".
-- filter = { owner = sid, type = animal type, kind = "fazenda" | "cao",
--            public = "open" (any flag on) | "pickup" (AllowPickup on),
--            unseenDays = n, expiresDays = n }
function Claims.readFilter(raw)
    if type(raw) ~= "table" then return {} end
    return {
        owner = type(raw.owner) == "string" and raw.owner or nil,
        type = type(raw.type) == "string" and raw.type or nil,
        kind = (raw.kind == "fazenda" or raw.kind == "cao") and raw.kind or nil,
        public = (raw.public == "open" or raw.public == "pickup") and raw.public or nil,
        unseenDays = positive(raw.unseenDays),
        expiresDays = positive(raw.expiresDays),
    }
end

function Claims.matches(row, filter, now)
    if filter.owner and row.owner ~= filter.owner then return false end
    if filter.type and row.type ~= filter.type then return false end
    if filter.kind and row.kind ~= filter.kind then return false end
    if filter.public == "open" and #row.publicOn == 0 then return false end
    if filter.public == "pickup" and not hasFlag(row.publicOn, "AllowPickup") then return false end
    if filter.unseenDays and not Claims.isUnseen(row, filter.unseenDays, now) then return false end
    if filter.expiresDays then
        local soon = row.expiresIn ~= nil and row.expiresIn <= filter.expiresDays * Claims.DAY_SECONDS
        if not soon then return false end
    end
    return true
end

function Claims.filter(rows, filter, now)
    local out = {}
    for _, row in ipairs(rows) do
        if Claims.matches(row, filter, now) then table.insert(out, row) end
    end
    return out
end

-- The line on top of the window, over ALL claims (not the filtered ones). slotsOf(sid) =
-- { owned, budget, extra } of that owner, both pots summed, from the claim store.
function Claims.summary(rows, now, slotsOf)
    local s = { total = #rows, farm = 0, dog = 0, owners = 0, publicOpen = 0, publicPickup = 0,
                unseenWeek = 0, unseenMonth = 0, slotsUsed = 0, slotsTotal = 0, slotsBought = 0 }
    local counted = {}
    for _, row in ipairs(rows) do
        if row.kind == "cao" then s.dog = s.dog + 1 else s.farm = s.farm + 1 end
        if #row.publicOn > 0 then s.publicOpen = s.publicOpen + 1 end
        if hasFlag(row.publicOn, "AllowPickup") then s.publicPickup = s.publicPickup + 1 end
        if Claims.isUnseen(row, Claims.WEEK_DAYS, now) then s.unseenWeek = s.unseenWeek + 1 end
        if Claims.isUnseen(row, Claims.MONTH_DAYS, now) then s.unseenMonth = s.unseenMonth + 1 end
        if not counted[row.owner] then
            counted[row.owner] = true
            s.owners = s.owners + 1
            local slots = slotsOf(row.owner)
            s.slotsUsed = s.slotsUsed + slots.owned
            s.slotsTotal = s.slotsTotal + slots.budget
            s.slotsBought = s.slotsBought + slots.extra
        end
    end
    return s
end

-- Owners with claims and how many, by name: the owner filter.
function Claims.owners(rows)
    local bySid, list = {}, {}
    for _, row in ipairs(rows) do
        local entry = bySid[row.owner]
        if not entry then
            entry = { sid = row.owner, name = row.ownerName, count = 0 }
            bySid[row.owner] = entry
            table.insert(list, entry)
        end
        entry.count = entry.count + 1
    end
    table.sort(list, byName)
    return list
end

-- The animal types that have claims, sorted: the species filter.
function Claims.types(rows)
    local seen, list = {}, {}
    for _, row in ipairs(rows) do
        if row.type and not seen[row.type] then
            seen[row.type] = true
            table.insert(list, row.type)
        end
    end
    table.sort(list)
    return list
end

-- How the claim began, from the audit: the newest CLAIMED entry of the animal's bucket (the
-- claim record does not keep it). nil when the audit has none -- claimed before it existed.
function Claims.originOf(bucket)
    if not bucket then return nil end
    for i = #bucket.items, 1, -1 do
        local entry = bucket.items[i]
        if entry.k == "CLAIMED" then return entry.detail and entry.detail.origin end
    end
    return nil
end

-- A reason the server will take: at least REASON_MIN characters once trimmed.
function Claims.isReason(text)
    if type(text) ~= "string" then return false end
    return #(text:match("^%s*(.-)%s*$")) >= Claims.REASON_MIN
end

-- "Expires" as a translation key and its argument, like GENZ_LivestockAuditCore.ago.
function Claims.expiry(expiresIn, timeoutHours)
    if timeoutHours == nil or timeoutHours <= 0 then return "UI_GENZ_LA_ExpiresNever", {} end
    if expiresIn == nil then return "UI_GENZ_LA_ExpiresUnknown", {} end
    if expiresIn <= 0 then return "UI_GENZ_LA_ExpiresOverdue", {} end
    if expiresIn < Claims.DAY_SECONDS then
        return "UI_GENZ_LA_ExpiresHours", { tostring(math.floor(expiresIn / 3600)) }
    end
    return "UI_GENZ_LA_ExpiresDays", { tostring(math.floor(expiresIn / Claims.DAY_SECONDS)) }
end
