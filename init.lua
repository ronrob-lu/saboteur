-- saboteur/init.lua
-- Persistent roaming Saboteur NPC Mod for Luanti/Minetest
-- Built for Lua 5.1/LuaJIT compatibility (no goto, clean functions)

-- ============================================================================
-- 1. Configuration & Settings loader
-- ============================================================================
local function get_config(name, default)
    local val = minetest.settings:get(name)
    if not val then return default end
    return tonumber(val) or default
end

local CONFIG = {
    place_tnt_chance   = get_config("saboteur.place_tnt_chance", 0.4),
    stay_and_die_chance= get_config("saboteur.stay_and_die_chance", 0.3),
    spawn_radius_min   = get_config("saboteur.spawn_radius_min", 60),
    spawn_radius_max   = get_config("saboteur.spawn_radius_max", 90),
    rare_multi_chance  = get_config("saboteur.rare_multi_chance", 0.05),
    max_persistent     = get_config("saboteur.max_persistent", 20),
    wander_speed       = get_config("saboteur.wander_speed", 2.5),
    flee_speed         = get_config("saboteur.flee_speed", 4.0),
}

-- ============================================================================
-- 2. CVCVC Nametag Generator
-- ============================================================================
local CONSONANTS = {"b","c","d","f","g","h","j","k","l","m","n","p","r","s","t","v","w","x","z"}
local VOWELS = {"a","e","i","o","u"}

local function generate_name()
    return CONSONANTS[math.random(#CONSONANTS)]
        .. VOWELS[math.random(#VOWELS)]
        .. CONSONANTS[math.random(#CONSONANTS)]
        .. VOWELS[math.random(#VOWELS)]
        .. CONSONANTS[math.random(#CONSONANTS)]
end

-- ============================================================================
-- 3. Fallback TNT Node (if tnt mod is missing)
-- ============================================================================
local HAS_TNT_MOD = minetest.get_modpath("tnt") ~= nil

if not HAS_TNT_MOD then
    minetest.register_node("saboteur:fallback_tnt", {
        description = "Fallback TNT",
        tiles = {"saboteur_agent.png^[colorize:#FF0000:150"},
        groups = {dig_immediate = 2},
        sounds = minetest.node_sound_stone_defaults and minetest.node_sound_stone_defaults() or nil,
    })
end

-- The node name to use for placement
local function get_tnt_node_name()
    if HAS_TNT_MOD and minetest.registered_nodes["tnt:tnt"] then
        return "tnt:tnt"
    end
    return "saboteur:fallback_tnt"
end

-- ============================================================================
-- 4. Active tracker & persistence
-- ============================================================================
saboteur = {
    active = {},
    initialized = false,
    last_day = 0,
    spawned_count_today = 0,
    max_spawns_today = 1,
}

local storage = minetest.get_mod_storage()

-- Lazy init: minetest.get_day_count() returns nil during mod loading
local function init_global_state()
    if saboteur.initialized then return end

    saboteur.last_day = storage:get_int("last_day")
    if saboteur.last_day == 0 then
        saboteur.last_day = minetest.get_day_count() or 1
        storage:set_int("last_day", saboteur.last_day)
    end

    saboteur.spawned_count_today = storage:get_int("spawned_count_today")
    saboteur.max_spawns_today = storage:get_int("max_spawns_today")
    if saboteur.max_spawns_today == 0 then
        saboteur.max_spawns_today = 1
        storage:set_int("max_spawns_today", 1)
    end

    saboteur.initialized = true
    minetest.log("action", "[saboteur] Initialized: day=" .. saboteur.last_day
        .. " spawned_today=" .. saboteur.spawned_count_today
        .. " max_spawns=" .. saboteur.max_spawns_today)
end

-- Remove invalid/removed objects from the tracker
local function clean_active_tracker()
    local clean = {}
    for _, obj in ipairs(saboteur.active) do
        if obj and obj:is_valid() then
            clean[#clean + 1] = obj
        end
    end
    saboteur.active = clean
end

-- Protection helper
local function is_protected(pos)
    return minetest.is_protected(pos, "")
end

-- ============================================================================
-- 5. Serialization helpers
-- ============================================================================
local function serialize_state(self)
    return minetest.serialize({
        state       = self.state,
        decision    = self.decision,
        wander_dir  = self.wander_dir,
        wander_timer= self.wander_timer,
        flee_dir    = self.flee_dir,
        place_timer = self.place_timer,
        nametag     = self.nametag,
    })
end

local function deserialize_state(self, staticdata)
    if not staticdata or staticdata == "" then return false end
    local data = minetest.deserialize(staticdata)
    if not data then return false end
    self.state       = data.state or self.state
    self.decision    = data.decision or self.decision
    self.wander_dir  = data.wander_dir or self.wander_dir
    self.wander_timer= data.wander_timer or self.wander_timer
    self.flee_dir    = data.flee_dir or self.flee_dir
    self.place_timer = data.place_timer or self.place_timer
    self.nametag     = data.nametag or self.nametag
    return true
end

-- ============================================================================
-- 6. Find a safe position to place TNT near the NPC
--    Places TNT on the ground block in front of the NPC (direction it faces)
--    Returns a valid node position or nil if no suitable spot
-- ============================================================================
local function find_tnt_placement_pos(pos, wander_dir)
    -- Calculate "in front" direction from wander_dir, or use a random dir
    local dx, dz = 0, 1
    if wander_dir then
        local len = math.sqrt(wander_dir.x * wander_dir.x + wander_dir.z * wander_dir.z)
        if len > 0.1 then
            dx = wander_dir.x / len
            dz = wander_dir.z / len
        end
    end

    -- Try 1-2 nodes in front of NPC at ground level
    local foot_y = math.floor(pos.y + 0.5)
    for dist = 1, 2 do
        local try_pos = {
            x = math.floor(pos.x + dx * dist + 0.5),
            y = foot_y,
            z = math.floor(pos.z + dz * dist + 0.5),
        }
        -- Check: this node should be air/replaceable, and the node below should be solid
        local node_here = minetest.get_node(try_pos)
        local node_below = minetest.get_node({x = try_pos.x, y = try_pos.y - 1, z = try_pos.z})
        local def_here = minetest.registered_nodes[node_here.name]
        local def_below = minetest.registered_nodes[node_below.name]

        if def_here and not def_here.walkable and def_below and def_below.walkable then
            return try_pos
        end
    end

    -- Fallback: try placing at the NPC's own foot position
    local fallback = {
        x = math.floor(pos.x + 0.5),
        y = foot_y,
        z = math.floor(pos.z + 0.5),
    }
    local node = minetest.get_node(fallback)
    local def = minetest.registered_nodes[node.name]
    if def and not def.walkable then
        return fallback
    end

    return nil  -- Nowhere suitable
end

-- ============================================================================
-- 7. Explosion helper
-- ============================================================================
local function do_explosion(tnt_pos)
    if not tnt_pos then return end

    local node = minetest.get_node(tnt_pos)
    local tnt_name = get_tnt_node_name()

    -- Only explode if the TNT node is still there (player might have dug it)
    if node.name ~= tnt_name then
        minetest.log("action", "[saboteur] TNT at "
            .. minetest.pos_to_string(tnt_pos) .. " was removed before detonation")
        return
    end

    -- Use native tnt.boom if available
    if HAS_TNT_MOD and tnt and tnt.boom then
        tnt.boom(tnt_pos, {radius = 3})
        return
    end

    -- Fallback manual explosion
    minetest.set_node(tnt_pos, {name = "air"})

    minetest.sound_play("tnt_explode", {
        pos = tnt_pos, gain = 1.0, max_hear_distance = 64,
    }, true)

    minetest.add_particlespawner({
        amount = 40, time = 0.5,
        minpos = vector.subtract(tnt_pos, 1.5),
        maxpos = vector.add(tnt_pos, 1.5),
        minvel = {x = -4, y = -4, z = -4},
        maxvel = {x = 4, y = 4, z = 4},
        minacc = {x = -0.5, y = -0.5, z = -0.5},
        maxacc = {x = 0.5, y = 0.5, z = 0.5},
        minexptime = 0.5, maxexptime = 1.5,
        minsize = 2, maxsize = 5,
        texture = "saboteur_agent.png^[colorize:#FF5500:180",
    })

    -- Radial damage with distance falloff
    for _, obj in ipairs(minetest.get_objects_inside_radius(tnt_pos, 6)) do
        if obj:is_valid() then
            local obj_pos = obj:get_pos()
            if obj_pos then
                local d = vector.distance(tnt_pos, obj_pos)
                local damage = math.max(1, math.floor((6 - d) * 4))
                obj:punch(obj, 1.0, {
                    full_punch_interval = 1.0,
                    damage_groups = {fleshy = damage},
                }, vector.direction(tnt_pos, obj_pos))
            end
        end
    end
end

-- ============================================================================
-- 8. Saboteur Entity Registration
-- ============================================================================
minetest.register_entity("saboteur:agent", {
    hp_max = 20,
    physical = true,
    collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
    visual = "mesh",
    mesh = "character.b3d",
    textures = {"saboteur_agent.png"},
    visual_size = {x = 1, y = 1, z = 1},
    stepheight = 1.1,
    automatic_face_movement_dir = true,

    -- ----------------------------------------------------------------
    -- on_activate: Called when entity spawns or loads from staticdata
    -- ----------------------------------------------------------------
    on_activate = function(self, staticdata)
        -- Physics
        self.object:set_armor_groups({fleshy = 100})
        self.object:set_acceleration({x = 0, y = -9.8, z = 0})

        -- Default state
        self.state = "wander"
        self.decision = {
            place_tnt    = false,
            detonate_at  = nil,
            stay_and_die = false,
            placed       = false,
            tnt_pos      = nil,
        }
        self.wander_dir   = {x = 0, z = 0}
        self.wander_timer = 0
        self.flee_dir     = {x = 0, z = 0}
        self.place_timer  = 0
        self.nametag      = generate_name()
        self.current_anim = ""

        -- Restore from staticdata if available
        local restored = deserialize_state(self, staticdata)

        -- Nametag
        self.object:set_properties({
            nametag = self.nametag,
            nametag_color = "#FFFFFF",
        })

        -- Track
        saboteur.active[#saboteur.active + 1] = self.object

        -- Fresh spawn: roll daily decision immediately
        if not restored then
            if math.random() < CONFIG.place_tnt_chance then
                self.decision.place_tnt    = true
                self.decision.stay_and_die = (math.random() < CONFIG.stay_and_die_chance)
                self.decision.detonate_at  = minetest.get_gametime() + math.random(10, 7200)
                self.state = "placing"
                self.place_timer = 0
                minetest.log("action", "[saboteur] " .. self.nametag
                    .. " spawned and will place TNT (detonate in "
                    .. (self.decision.detonate_at - minetest.get_gametime()) .. "s)")
            else
                minetest.log("action", "[saboteur] " .. self.nametag .. " spawned, wandering today")
            end
        else
            minetest.log("action", "[saboteur] " .. self.nametag
                .. " restored from staticdata, state=" .. self.state)
        end
    end,

    -- ----------------------------------------------------------------
    -- on_deactivate: Remove from tracker
    -- ----------------------------------------------------------------
    on_deactivate = function(self)
        for i, obj in ipairs(saboteur.active) do
            if obj == self.object then
                table.remove(saboteur.active, i)
                break
            end
        end
    end,

    -- ----------------------------------------------------------------
    -- get_staticdata: Serialize for persistence across restarts
    -- ----------------------------------------------------------------
    get_staticdata = function(self)
        return serialize_state(self)
    end,

    -- ----------------------------------------------------------------
    -- on_step: Main state machine, runs every server tick
    -- ----------------------------------------------------------------
    on_step = function(self, dtime)
        if not self.object:is_valid() then return end
        local pos = self.object:get_pos()
        if not pos then return end
        local vel = self.object:get_velocity()
        if not vel then return end

        -- ==== STATE: WANDER ====
        if self.state == "wander" then
            self.wander_timer = self.wander_timer - dtime
            if self.wander_timer <= 0 then
                local angle = math.random() * math.pi * 2
                self.wander_dir = {
                    x = math.cos(angle) * CONFIG.wander_speed,
                    z = math.sin(angle) * CONFIG.wander_speed,
                }
                self.wander_timer = math.random(3, 8)
            end
            -- Preserve vel.y so gravity works
            self.object:set_velocity({
                x = self.wander_dir.x, y = vel.y, z = self.wander_dir.z,
            })
            -- Random jump when on ground
            if math.random() < 0.01 and math.abs(vel.y) < 0.1 then
                self.object:set_velocity({
                    x = self.wander_dir.x, y = 4.5, z = self.wander_dir.z,
                })
            end

        -- ==== STATE: PLACING ====
        -- NPC stops and places TNT after a 2s delay
        elseif self.state == "placing" then
            -- Stand still while preparing
            self.object:set_velocity({x = 0, y = vel.y, z = 0})

            self.place_timer = self.place_timer + dtime
            if self.place_timer >= 2 and not self.decision.placed then
                -- Find a safe spot to place TNT (in front of the NPC)
                local tnt_pos = find_tnt_placement_pos(pos, self.wander_dir)

                if not tnt_pos then
                    -- No valid position found, abort
                    minetest.log("action", "[saboteur] " .. self.nametag
                        .. " could not find placement spot, aborting")
                    self.state = "wander"
                    self.wander_timer = 0
                elseif is_protected(tnt_pos) then
                    -- Protected area, abort
                    minetest.log("action", "[saboteur] " .. self.nametag
                        .. " tried to place TNT in protected area, aborting")
                    self.state = "wander"
                    self.decision.place_tnt = false
                    self.decision.detonate_at = nil
                    self.wander_timer = 0
                else
                    -- Place the TNT!
                    local tnt_name = get_tnt_node_name()
                    minetest.set_node(tnt_pos, {name = tnt_name})
                    self.decision.placed = true
                    self.decision.tnt_pos = {x = tnt_pos.x, y = tnt_pos.y, z = tnt_pos.z}

                    minetest.log("action", "[saboteur] " .. self.nametag
                        .. " placed TNT at " .. minetest.pos_to_string(tnt_pos))

                    if self.decision.stay_and_die then
                        self.state = "stand"
                    else
                        self.state = "flee"
                        -- Flee opposite to wander direction
                        local dx = -self.wander_dir.x
                        local dz = -self.wander_dir.z
                        local len = math.sqrt(dx * dx + dz * dz)
                        if len > 0.1 then
                            self.flee_dir = {
                                x = (dx / len) * CONFIG.flee_speed,
                                z = (dz / len) * CONFIG.flee_speed,
                            }
                        else
                            local a = math.random() * math.pi * 2
                            self.flee_dir = {
                                x = math.cos(a) * CONFIG.flee_speed,
                                z = math.sin(a) * CONFIG.flee_speed,
                            }
                        end
                    end
                end
            end

        -- ==== STATE: STAND (stay near TNT, wait for death) ====
        elseif self.state == "stand" then
            self.object:set_velocity({x = 0, y = vel.y, z = 0})

        -- ==== STATE: FLEE (run away from placed TNT) ====
        elseif self.state == "flee" then
            if self.decision.tnt_pos then
                local d = vector.distance(pos, self.decision.tnt_pos)
                if d >= 25 then
                    -- Far enough, resume wandering
                    self.state = "wander"
                    self.wander_timer = 0
                else
                    self.object:set_velocity({
                        x = self.flee_dir.x, y = vel.y, z = self.flee_dir.z,
                    })
                    -- Random jump while fleeing
                    if math.random() < 0.01 and math.abs(vel.y) < 0.1 then
                        self.object:set_velocity({
                            x = self.flee_dir.x, y = 4.5, z = self.flee_dir.z,
                        })
                    end
                end
            else
                -- No TNT pos recorded, just wander
                self.state = "wander"
                self.wander_timer = 0
            end
        end

        -- ==== ANIMATIONS ====
        local want_anim = "stand"
        if self.state == "wander" or self.state == "flee" then
            want_anim = "walk"
        end
        if self.current_anim ~= want_anim then
            self.current_anim = want_anim
            if want_anim == "walk" then
                self.object:set_animation({x = 168, y = 187}, 30, 0)
            else
                self.object:set_animation({x = 0, y = 79}, 30, 0)
            end
        end

        -- ==== DETONATION CHECK ====
        -- Only fires if TNT was actually placed AND the timer has elapsed
        if self.decision.placed
            and self.decision.tnt_pos
            and self.decision.detonate_at
            and minetest.get_gametime() >= self.decision.detonate_at
        then
            minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                .. " detonating TNT at " .. minetest.pos_to_string(self.decision.tnt_pos))

            do_explosion(self.decision.tnt_pos)

            if self.decision.stay_and_die then
                self.object:remove()
                return  -- Entity is gone, stop processing
            else
                -- Survive: reset decisions, go back to wandering
                self.decision.place_tnt    = false
                self.decision.detonate_at  = nil
                self.decision.placed       = false
                self.decision.tnt_pos      = nil
                self.decision.stay_and_die = false
                self.state = "wander"
                self.wander_timer = 0
            end
        end
    end,
})

-- ============================================================================
-- 9. Global Step Manager: Daily Decisions & Spawning
-- ============================================================================
local spawn_check_timer = 0

minetest.register_globalstep(function(dtime)
    local current_day = minetest.get_day_count()
    if not current_day then return end

    init_global_state()

    -- ---- Day transition: new day detected ----
    if current_day ~= saboteur.last_day then
        saboteur.last_day = current_day
        storage:set_int("last_day", current_day)

        -- Reset daily spawn counter
        saboteur.spawned_count_today = 0
        storage:set_int("spawned_count_today", 0)

        -- 5% chance for a second spawn today
        if math.random() < CONFIG.rare_multi_chance then
            saboteur.max_spawns_today = 2
        else
            saboteur.max_spawns_today = 1
        end
        storage:set_int("max_spawns_today", saboteur.max_spawns_today)

        -- Clean up dead/invalid references
        clean_active_tracker()

        -- Daily Roll: each alive saboteur makes a new decision
        local now = minetest.get_gametime()
        for _, obj in ipairs(saboteur.active) do
            if obj and obj:is_valid() then
                local ent = obj:get_luaentity()
                if ent and ent.name == "saboteur:agent" then
                    -- Reset daily decisions
                    ent.decision = {
                        place_tnt    = false,
                        detonate_at  = nil,
                        stay_and_die = false,
                        placed       = false,
                        tnt_pos      = nil,
                    }
                    ent.place_timer = 0

                    if math.random() < CONFIG.place_tnt_chance then
                        ent.decision.place_tnt    = true
                        ent.decision.stay_and_die = (math.random() < CONFIG.stay_and_die_chance)
                        ent.decision.detonate_at  = now + math.random(10, 7200)
                        ent.state = "placing"
                        minetest.log("action", "[saboteur] " .. (ent.nametag or "?")
                            .. " daily roll: PLACE TNT (det in "
                            .. (ent.decision.detonate_at - now) .. "s"
                            .. (ent.decision.stay_and_die and ", stay&die" or ", flee") .. ")")
                    else
                        ent.state = "wander"
                        ent.wander_timer = 0
                        minetest.log("action", "[saboteur] " .. (ent.nametag or "?")
                            .. " daily roll: wander today")
                    end
                end
            end
        end

        minetest.log("action", "[saboteur] Day " .. current_day
            .. ": " .. #saboteur.active .. " active agents")
    end

    -- ---- Spawn check (every 5 seconds) ----
    spawn_check_timer = spawn_check_timer + dtime
    if spawn_check_timer < 5 then return end
    spawn_check_timer = 0

    clean_active_tracker()

    -- Hard cap
    if #saboteur.active >= CONFIG.max_persistent then return end

    -- Already spawned enough today?
    if saboteur.spawned_count_today >= saboteur.max_spawns_today then return end

    -- Need players online
    local players = minetest.get_connected_players()
    if #players == 0 then return end

    local player = players[math.random(#players)]
    local ppos = player:get_pos()
    if not ppos then return end

    local angle = math.random() * math.pi * 2
    local dist = math.random(CONFIG.spawn_radius_min, CONFIG.spawn_radius_max)
    local spawn_x = ppos.x + math.cos(angle) * dist
    local spawn_z = ppos.z + math.sin(angle) * dist

    -- Search for walkable ground with 2 blocks of headroom
    local found_ground = false
    local spawn_y = ppos.y
    for y = ppos.y + 40, ppos.y - 40, -1 do
        local check_pos = {x = spawn_x, y = y, z = spawn_z}
        local node = minetest.get_node_or_nil(check_pos)
        if node then
            local ndef = minetest.registered_nodes[node.name]
            if ndef and ndef.walkable then
                -- Verify 2 blocks of clear headroom above
                local a1 = minetest.get_node_or_nil({x = spawn_x, y = y + 1, z = spawn_z})
                local a2 = minetest.get_node_or_nil({x = spawn_x, y = y + 2, z = spawn_z})
                local d1 = a1 and minetest.registered_nodes[a1.name]
                local d2 = a2 and minetest.registered_nodes[a2.name]
                if (not d1 or not d1.walkable) and (not d2 or not d2.walkable) then
                    spawn_y = y + 1
                    found_ground = true
                    break
                end
            end
        end
    end

    if not found_ground then return end

    local spawn_pos = {x = spawn_x, y = spawn_y, z = spawn_z}

    -- Off-screen check: must NOT be in line of sight from player
    local eye_pos = {x = ppos.x, y = ppos.y + 1.62, z = ppos.z}
    if minetest.line_of_sight(eye_pos, spawn_pos) then return end

    -- Protection check
    if is_protected(spawn_pos) then return end

    -- Spawn!
    local obj = minetest.add_entity(spawn_pos, "saboteur:agent")
    if obj then
        saboteur.spawned_count_today = saboteur.spawned_count_today + 1
        storage:set_int("spawned_count_today", saboteur.spawned_count_today)
        minetest.log("action", "[saboteur] Spawned agent at "
            .. minetest.pos_to_string(spawn_pos)
            .. " (day " .. saboteur.last_day
            .. ", spawn #" .. saboteur.spawned_count_today .. ")")
    end
end)

-- ============================================================================
-- 10. Hard Purge Command
-- ============================================================================
local function purge_all_saboteurs()
    init_global_state()
    local count = 0

    -- Scan minetest.luaentities directly (catches everything)
    for _, def in pairs(minetest.luaentities) do
        if def.name == "saboteur:agent" then
            if def.object and def.object:is_valid() then
                def.object:remove()
                count = count + 1
            end
        end
    end

    -- Also scan via get_all_objects for any orphans
    if minetest.get_all_objects then
        for _, obj in ipairs(minetest.get_all_objects()) do
            if obj:is_valid() then
                local ent = obj:get_luaentity()
                if ent and ent.name == "saboteur:agent" then
                    obj:remove()
                    count = count + 1
                end
            end
        end
    end

    saboteur.active = {}
    saboteur.spawned_count_today = 0
    storage:set_int("spawned_count_today", 0)

    return count
end

minetest.register_chatcommand("purge_saboteurs", {
    params = "",
    description = "Hard remove ALL saboteur entities",
    privs = {server = true},
    func = function(name)
        local count = purge_all_saboteurs()
        return true, "Purge complete: " .. count .. " saboteur entities removed."
    end,
})

minetest.log("action", "[saboteur] Mod loaded successfully")