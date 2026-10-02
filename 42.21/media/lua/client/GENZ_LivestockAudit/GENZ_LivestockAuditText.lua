-- GENZ_LivestockAuditText -- turns an audit entry into the words a window shows.
--
-- GENZ_LivestockAuditCore decides WHAT an entry says (a translation key plus arguments,
-- testable without the game); this file only resolves those into text with the engine's
-- translator. Shared by the staff window (F2) and the owner History (F3).

require "GENZ_LivestockAudit/GENZ_LivestockAuditCore"

GENZ_LivestockAuditText = {}
local Text = GENZ_LivestockAuditText
local Core = GENZ_LivestockAuditCore

local function resolve(arg)
    if type(arg) == "table" then
        if arg.key then return getText(arg.key) end
        if arg.item then return getItemNameFromFullType(arg.item) end
    end
    return tostring(arg)
end

-- getText takes the arguments one by one (%1, %2, %3); the entries use at most three.
function Text.translate(key, args)
    local count = #args
    if count == 0 then return getText(key) end
    if count == 1 then return getText(key, resolve(args[1])) end
    if count == 2 then return getText(key, resolve(args[1]), resolve(args[2])) end
    return getText(key, resolve(args[1]), resolve(args[2]), resolve(args[3]))
end

function Text.event(item)
    return Text.translate(Core.describe(item))
end

function Text.animal(item)
    return resolve(Core.animalLabel(item))
end

function Text.ago(seconds)
    return Text.translate(Core.ago(seconds))
end

-- for the staff claims window (card #210)
function Text.flag(flag)
    return resolve(Core.flagLabel(flag))
end

function Text.origin(origin)
    return resolve(Core.originLabel(origin))
end

-- Real date and time of the entry (server clock), for staff cross-checking with logs.
function Text.when(timestamp)
    return os.date("%d/%m %H:%M", timestamp)
end
