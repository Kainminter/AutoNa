
-- AutoNa Addon
-- Automates casting remedy spells on party members and yourself when status ailments are detected.
-- Features: Casting queue (ordered by ailment priority), packet parsing for party buffs,
-- self status polling, dynamic HUD display
--
-- Commands:
--   //autona on                -- Enable the addon.
--   //autona off               -- Disable the addon and clear the queue.
--   //autona hud [on|off]      -- Toggle the HUD display.
--   //autona clear             -- Manually clear the casting queue.
--   //autona disable <status>  -- Ignore a specific status (for example; "paralysis").
--   //autona enable <status>   -- Stop ignoring a specific status.
--   //autona help              -- Display available commands.

_addon.name = 'AutoNa'
_addon.version = '1.0'
_addon.author = 'Kainminter'
_addon.commands = {'autona'}


require('tables')
require('strings')

local packets = require('packets')
local texts   = require('texts')
local res     = require('resources')

----------------------------------------
-- SETTINGS & PRIORITY DEFINITIONS
----------------------------------------

local ADDON_COOLDOWN = 5   -- Seconds to wait after a cast before casting the next.
local CAST_COOLDOWN  = 4   -- Minimum seconds since a cast was performed.
local MOVE_COOLDOWN  = 1   -- Used in movement detection.

-- Ailments to monitor (in priority order, highest first).
-- Each entry: { ailment = "name", spell = "remedy" }
local ailments_priority = {
    { ailment = "doom",                spell = "cursna"   },
    { ailment = "petrification",         spell = "stona"    },
    { ailment = "sleep",               spell = "cure"     },
    { ailment = "silence",             spell = "silena"   },
    { ailment = "paralysis",           spell = "paralyna" },
    { ailment = "curse",               spell = "cursna"   },
    { ailment = "slow",                spell = "erase"    },
    { ailment = "elegy",               spell = "erase"    },
    { ailment = "weight",              spell = "erase"    },
    { ailment = "bind",                spell = "erase"    },
    { ailment = "max hp down",         spell = "erase"    },
    { ailment = "max mp down",         spell = "erase"    },
    { ailment = "attack down",         spell = "erase"    },
    { ailment = "defense down",        spell = "erase"    },
    { ailment = "accuracy down",       spell = "erase"    },
    { ailment = "blindness",           spell = "blindna"  },
    { ailment = "str down",            spell = "erase"    },
    { ailment = "dex down",            spell = "erase"    },
    { ailment = "addle",               spell = "erase"    },
    { ailment = "bio",                 spell = "erase"    },
    { ailment = "disease",             spell = "viruna"   },
    { ailment = "plague",              spell = "viruna"   },
    { ailment = "dia",                 spell = "erase"    },
    { ailment = "magic attack down",   spell = "erase"    },
    { ailment = "magic accuracy down", spell = "erase"    },
    { ailment = "burn",                spell = "erase"    },
    { ailment = "choke",               spell = "erase"    },
    { ailment = "frost",               spell = "erase"    },
    { ailment = "shock",               spell = "erase"    },
    { ailment = "drown",               spell = "erase"    },
    { ailment = "rasp",                spell = "erase"    },
    { ailment = "evasion down",        spell = "erase"    },
    { ailment = "poison",              spell = "poisona"  },
}

----------------------------------------
-- GLOBAL VARIABLES
----------------------------------------

local enabled = true              
local castQueue = {}              

-- Each entry: { slot = <number>, ailment = <string>, spell = <string>, priority = <number>, time = os.clock() }
-- slot: 0 = self, 1-5 = party members.

-- Table of party statuses: for each party slot 1–5, track active ailments.
local party_status = {}
for i = 1, 5 do
    party_status[i] = {}          -- List of ailment strings (lowercase)
end

-- Table for self status (slot 0)
local self_status = {}

-- Table of statuses to ignore (keys are ailment names in lowercase).
local statuses_ignored = {}

-- Timing variables:
local busyUntil = 0
local last_cast_time = 0
local last_move_time = 0
local last_position = nil

----------------------------------------
-- HUD SETUP
----------------------------------------

local hud_enabled = true
local hud_text = texts.new("", {
    pos = { x = 300, y = 300 },
    bg = { visible = true, color = {0, 0, 0}, alpha = 150 },
    draggable = true,
    fontsize = 12,
})
hud_text:show()

----------------------------------------
-- UTILITY FUNCTIONS
----------------------------------------

-- Check if the player is moving.
local function is_player_moving()
    local player = windower.ffxi.get_mob_by_target('me')
    if not player then return false end
    local current_position = {x = player.x, y = player.y, z = player.z}
    local moving = false
    local now = os.clock()
    if (now - last_move_time) < MOVE_COOLDOWN then
        moving = true
    end
    if last_position then
        local dx = current_position.x - last_position.x
        local dy = current_position.y - last_position.y
        local dz = current_position.z - last_position.z
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if distance > 0.1 then
            moving = true
            last_move_time = now
        end
    end
    last_position = current_position
    return moving
end

-- Check if the player is currently casting (based on a simple cooldown timer).
local function is_casting()
    local now = os.clock()
    return (now - last_cast_time) < CAST_COOLDOWN
end

-- Given a buff ID, return its name in lowercase (using the resources table).
local function get_buff_name(buff_id)
    local buff = res.buffs[buff_id]
    if buff then
        return buff.en:lower()
    else
        return "unknown buff"
    end
end

----------------------------------------
-- SELF STATUS UPDATE FUNCTION
----------------------------------------

local function update_self_status()
    local player = windower.ffxi.get_player()
    local statuses = {}
    if player and player.buffs then
        for i, buff in ipairs(player.buffs) do
            if buff and buff ~= 0 and buff ~= 255 then
                local buff_name = get_buff_name(buff)
                for _, entry in ipairs(ailments_priority) do
                    if buff_name == entry.ailment then
                        table.insert(statuses, buff_name)
                        break
                    end
                end
            end
        end
    end
    self_status = statuses
end

----------------------------------------
-- QUEUE & STATUS UPDATE FUNCTIONS
----------------------------------------

-- Rebuild the castQueue based on current self and party statuses.
local function update_castQueue()
    if not enabled then
        castQueue = {}
        return
    end

    local newQueue = {}

    -- Check self (slot 0)
    local active_statuses = {}
    for _, status in ipairs(self_status) do
        if not statuses_ignored[status] then
            table.insert(active_statuses, status)
        end
    end
    if #active_statuses > 0 then
        local chosen_status, chosen_priority, chosen_spell
        for priority, entry in ipairs(ailments_priority) do
            for _, status in ipairs(active_statuses) do
                if status == entry.ailment then
                    chosen_status = status
                    chosen_priority = priority
                    chosen_spell = entry.spell
                    break
                end
            end
            if chosen_status then break end
        end
        if chosen_status then
            table.insert(newQueue, {
                slot = 0,   -- 0 represents self
                ailment = chosen_status,
                spell = chosen_spell,
                priority = chosen_priority,
                time = os.clock()
            })
        end
    end

    -- Check party members (slots 1-5)
    for slot = 1, 5 do
        local statuses = party_status[slot] or {}
        local active_statuses = {}
        for _, status in ipairs(statuses) do
            if not statuses_ignored[status] then
                table.insert(active_statuses, status)
            end
        end
        if #active_statuses > 0 then
            local chosen_status, chosen_priority, chosen_spell
            for priority, entry in ipairs(ailments_priority) do
                for _, status in ipairs(active_statuses) do
                    if status == entry.ailment then
                        chosen_status = status
                        chosen_priority = priority
                        chosen_spell = entry.spell
                        break
                    end
                end
                if chosen_status then break end
            end
            if chosen_status then
                table.insert(newQueue, {
                    slot = slot,
                    ailment = chosen_status,
                    spell = chosen_spell,
                    priority = chosen_priority,
                    time = os.clock()
                })
            end
        end
    end

    -- Sort the queue so that higher-priority (lower number) entries come first.
    table.sort(newQueue, function(a, b)
        return a.priority < b.priority
    end)
    castQueue = newQueue
end

-- Process incoming party buff packet (ID 0x076) to update party_status.
local function process_party_buffs(original)
    for slot = 1, 5 do
        local player_id = original:unpack('I', (slot - 1) * 48 + 5)
        if player_id and player_id ~= 0 then
            local statuses = {}
            for i = 1, 32 do
                local offset = (slot - 1) * 48 + 5 + 16 + i - 1
                local buff = original:byte(offset)
                if buff then
                    local extra = 256 * (math.floor(original:byte((slot - 1) * 48 + 5 + 8 + math.floor((i - 1) / 4)) / (4 ^ ((i - 1) % 4))) % 4)
                    buff = buff + extra
                    if buff ~= 255 then
                        local buff_name = get_buff_name(buff)
                        -- Check if this buff is one of the ailments we monitor.
                        for _, entry in ipairs(ailments_priority) do
                            if buff_name == entry.ailment then
                                table.insert(statuses, buff_name)
                                break
                            end
                        end
                    end
                end
            end
            party_status[slot] = statuses
        else
            party_status[slot] = {}
        end
    end
    update_castQueue()
end

----------------------------------------
-- EVENT HANDLERS
----------------------------------------

-- Incoming chunk: Handle packets for party buffs and party/alliance changes.
windower.register_event('incoming chunk', function(id, original)
    if not enabled then return end

    if id == 0x076 then
        process_party_buffs(original)
    elseif id == 0xC8 then
        -- Alliance update: clear party statuses.
        for slot = 1, 5 do
            party_status[slot] = {}
        end
        update_castQueue()
    elseif id == 0xDD then
        -- Party member update: clear statuses for the affected member.
        local packet = packets.parse('incoming', original)
        if packet then
            local playerId = packet['ID']
            local party = windower.ffxi.get_party()
            for slot = 1, 5 do
                if party['p' .. slot] and party['p' .. slot].id == playerId then
                    party_status[slot] = {}
                    break
                end
            end
        end
        update_castQueue()
    end
end)

-- Combined prerender: update self status, perform casting (if conditions are met) and update the HUD.
windower.register_event('prerender', function()
    if not enabled then return end
    local now = os.clock()

    -- Update self status each frame.
    update_self_status()
    update_castQueue()

    -- Casting logic.
    if not is_player_moving() and not is_casting() and now >= busyUntil and #castQueue > 0 and enabled then
        local entry = table.remove(castQueue, 1)
        local target_cmd = ""
        if entry.slot == 0 then
            -- Casting on self.
            local active = false
            for _, status in ipairs(self_status or {}) do
                if status == entry.ailment then
                    active = true
                    break
                end
            end
            if active then
                target_cmd = "<me>"
            end
        else
            -- Casting on a party member.
            local active = false
            for _, status in ipairs(party_status[entry.slot] or {}) do
                if status == entry.ailment then
                    active = true
                    break
                end
            end
            if active then
                target_cmd = string.format("<p%d>", entry.slot)
            end
        end

        if target_cmd ~= "" then
            local player = windower.ffxi.get_player()
            local use_healing_waltz = false
            if player then
                if (player.main_job == "DNC" and player.main_job_level >= 35) or (player.sub_job == "DNC" and player.sub_job_level >= 35) then
                    use_healing_waltz = true
                end
            end
			local cmd = ""
            if use_healing_waltz then
                cmd = string.format('input /ja "Healing Waltz" %s', target_cmd)
            windower.add_to_chat(207, string.format("Casting Healing Waltz on %s for %s", (entry.slot==0 and "self" or ("party slot " .. entry.slot)), entry.ailment))
            last_cast_time = now
			busyUntil = now + ADDON_COOLDOWN + 3
            else
                cmd = string.format('input /ma "%s" %s', entry.spell, target_cmd)
            windower.add_to_chat(207, string.format("Casting %s on %s for %s", entry.spell, (entry.slot==0 and "self" or ("party slot " .. entry.slot)), entry.ailment))
            last_cast_time = now
			busyUntil = now + ADDON_COOLDOWN
            end
            -- windower.add_to_chat(207, string.format("Casting %s on %s for %s", entry.spell, (entry.slot==0 and "self" or ("party slot " .. entry.slot)), entry.ailment))
            windower.send_command(cmd)
        else
            update_castQueue() -- the condition no longer holds; update the queue
        end
    end

    -- HUD update.
    if hud_enabled then
        local display = "AutoNa Queue:\n"
        if #castQueue == 0 then
            display = display .. "Empty"
        else
            for i, entry in ipairs(castQueue) do
                local target = (entry.slot == 0 and "Self") or ("Party " .. entry.slot)
                display = display .. string.format("%s: %s -> %s\n", target, entry.ailment, entry.spell)
            end
        end
        hud_text:text(display)
        hud_text:show()
    else
        hud_text:hide()
    end
end)

-- Addon command handler.
windower.register_event('addon command', function(command, ...)
    local args = {...}
    command = command and command:lower() or ""
    
    if command == "on" then
        enabled = true
        windower.add_to_chat(207, "AutoNa enabled.")
    elseif command == "off" then
        enabled = false
        castQueue = {}
        for i = 1, 5 do party_status[i] = {} end
        self_status = {}
        windower.add_to_chat(207, "AutoNa disabled and queue cleared.")
    elseif command == "hud" then
        if #args > 0 then
            local arg = args[1]:lower()
            if arg == "on" then
                hud_enabled = true
            elseif arg == "off" then
                hud_enabled = false
            end
        else
            hud_enabled = not hud_enabled
        end
        if hud_enabled then
            hud_text:show()
            windower.add_to_chat(207, "AutoNa HUD enabled.")
        else
            hud_text:hide()
            windower.add_to_chat(207, "AutoNa HUD disabled.")
        end
    elseif command == "clear" then
        castQueue = {}
        windower.add_to_chat(207, "AutoNa queue cleared.")
    elseif command == "disable" then
        if #args >= 1 then
            local status = table.concat(args, " "):lower()
            statuses_ignored[status] = true
            windower.add_to_chat(207, "AutoNa now ignoring status: " .. status)
            update_castQueue()
        else
            windower.add_to_chat(207, "Usage: //autona disable <status>")
        end
    elseif command == "enable" then
        if #args >= 1 then
            local status = table.concat(args, " "):lower()
            statuses_ignored[status] = nil
            windower.add_to_chat(207, "AutoNa no longer ignoring status: " .. status)
            update_castQueue()
        else
            windower.add_to_chat(207, "Usage: //autona enable <status>")
        end
    else
        windower.add_to_chat(207, "AutoNa commands:")
        windower.add_to_chat(207, "//autona on                - Enable the addon")
        windower.add_to_chat(207, "//autona off               - Disable the addon and clear the queue")
        windower.add_to_chat(207, "//autona hud [on|off]      - Toggle HUD display")
        windower.add_to_chat(207, "//autona clear             - Clear the casting queue")
        windower.add_to_chat(207, "//autona disable <status>  - Ignore a specific status")
        windower.add_to_chat(207, "//autona enable <status>   - Stop ignoring a specific status")
    end
end)

windower.register_event('buff change', function(buff, gain)
    -- Whenever your buffs change, update self_status.
    update_self_status()
    update_castQueue()
end)

