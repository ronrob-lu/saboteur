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
    max_spawns_per_day = get_config("saboteur.max_spawns_per_day", 40),
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

local function init_global_state()
    if saboteur.initialized then return end

    saboteur.last_day = storage:get_int("last_day")
    if saboteur.last_day == 0 then
        saboteur.last_day = minetest.get_day_count() or 1
        storage:set_int("last_day", saboteur.last_day)
    end

    saboteur.spawned_count_today = storage:get_int("spawned_count_today")
    saboteur.max_spawns_today = storage:get_int("max_spawns_today")
    if saboteur.max_spawns_today < CONFIG.max_spawns_per_day then
        saboteur.max_spawns_today = CONFIG.max_spawns_per_day
        storage:set_int("max_spawns_today", CONFIG.max_spawns_per_day)
    end

    saboteur.initialized = true
    minetest.log("action", "[saboteur] Initialized: day=" .. saboteur.last_day
        .. " spawned_today=" .. saboteur.spawned_count_today
        .. " max_spawns=" .. saboteur.max_spawns_today)
end

local function clean_active_tracker()
    local clean = {}
    for _, obj in ipairs(saboteur.active) do
        if obj and obj:is_valid() then
            clean[#clean + 1] = obj
        end
    end
    saboteur.active = clean
end

local function is_protected(pos)
    return minetest.is_protected(pos, "")
end

-- ============================================================================
-- 5. Serialization helpers
-- ============================================================================
local function serialize_state(self)
    return minetest.serialize({
        state        = self.state,
        decision     = self.decision,
        wander_dir   = self.wander_dir,
        wander_timer = self.wander_timer,
        flee_dir     = self.flee_dir,
        place_timer  = self.place_timer,
        nametag      = self.nametag,
        last_roll_day= self.last_roll_day,
    })
end

local function deserialize_state(self, staticdata)
    if not staticdata or staticdata == "" then return false end
    local data = minetest.deserialize(staticdata)
    if not data then return false end
    self.state        = data.state or self.state
    self.decision     = data.decision or self.decision
    self.wander_dir   = data.wander_dir or self.wander_dir
    self.wander_timer = data.wander_timer or self.wander_timer
    self.flee_dir     = data.flee_dir or self.flee_dir
    self.place_timer  = data.place_timer or self.place_timer
    self.nametag      = data.nametag or self.nametag
    self.last_roll_day= data.last_roll_day or self.last_roll_day
    return true
end

-- ============================================================================
-- 6. Find a valid TNT placement position near the NPC
--    Tries 8 compass directions at 1-2 node distance, then fallback
-- ============================================================================
local function find_tnt_placement_pos(pos)
    local foot_y = math.floor(pos.y)  -- Node the NPC stands ON top of is foot_y
    -- The NPC stands at pos.y, which is on top of node at foot_y.
    -- The air space at foot level is foot_y + 1... no.
    -- Actually: entity at y=9.5 stands on node y=9. Feet are in node space y=10 (9.5 to 10.5).
    -- We want to place TNT in an air node that has a solid node below it.

    -- Try 8 directions around the NPC, at distances 1 and 2
    local directions = {
        {x=1, z=0}, {x=-1, z=0}, {x=0, z=1}, {x=0, z=-1},
        {x=1, z=1}, {x=1, z=-1}, {x=-1, z=1}, {x=-1, z=-1},
    }

    local base_x = math.floor(pos.x + 0.5)
    local base_z = math.floor(pos.z + 0.5)

    -- Try multiple Y levels around the NPC's feet (±2)
    for y_offset = 0, 2 do
        for _, ydir in ipairs({0, -1, 1}) do
            local check_y = foot_y + y_offset * ydir
            for _, dir in ipairs(directions) do
                for dist = 1, 2 do
                    local try_pos = {
                        x = base_x + dir.x * dist,
                        y = check_y,
                        z = base_z + dir.z * dist,
                    }
                    local node_here = minetest.get_node(try_pos)
                    local node_below = minetest.get_node({x = try_pos.x, y = try_pos.y - 1, z = try_pos.z})
                    local def_here = minetest.registered_nodes[node_here.name]
                    local def_below = minetest.registered_nodes[node_below.name]

                    -- Want: air (or non-walkable) here, solid below
                    if def_here and not def_here.walkable
                        and def_below and def_below.walkable
                        and not is_protected(try_pos) then
                        return try_pos
                    end
                end
            end
        end
    end

    -- Last resort: at NPC's own rounded position
    local fallback = {
        x = base_x,
        y = foot_y,
        z = base_z,
    }
    local node = minetest.get_node(fallback)
    local def = minetest.registered_nodes[node.name]
    if def and not def.walkable and not is_protected(fallback) then
        return fallback
    end

    return nil
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
-- 8. Ignite TNT helper & Daily Decision Roller
-- ============================================================================
local function ignite_tnt_node(tnt_pos)
    if not tnt_pos then return false end
    if HAS_TNT_MOD and tnt then
        if tnt.burn then
            tnt.burn(tnt_pos)
            return true
        elseif tnt.ignite then
            tnt.ignite(tnt_pos)
            return true
        end
    end
    return false
end

local function roll_daily_decision(ent, day)
    ent.decision = {
        place_tnt    = false,
        strike_at    = nil,
        placed       = false,
        ignited      = false,
        tnt_pos      = nil,
        detonate_at  = nil,
        stay_and_die = false,
    }
    ent.place_timer = 0
    ent.ignite_timer = 0
    ent.last_roll_day = day

    if math.random() < CONFIG.place_tnt_chance then
        ent.decision.place_tnt = true
        local delay = math.random(10, 600)
        ent.decision.strike_at = minetest.get_gametime() + delay
        ent.state = "wander"
        ent.wander_timer = 0
        minetest.log("action", "[saboteur] " .. (ent.nametag or "?")
            .. " daily roll (day " .. day .. "): PLACE TNT (strikes in " .. delay .. "s)")
    else
        ent.state = "wander"
        ent.wander_timer = 0
        minetest.log("action", "[saboteur] " .. (ent.nametag or "?")
            .. " daily roll (day " .. day .. "): wander today")
    end
end

-- ============================================================================
-- 9. Saboteur Entity Registration
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
    -- on_activate
    -- ----------------------------------------------------------------
    on_activate = function(self, staticdata)
        -- Physics
        self.object:set_armor_groups({fleshy = 100})
        self.object:set_acceleration({x = 0, y = -9.8, z = 0})

        -- Default state
        self.state = "wander"
        self.decision = {
            place_tnt    = false,
            strike_at    = nil,
            placed       = false,
            ignited      = false,
            tnt_pos      = nil,
            detonate_at  = nil,
            stay_and_die = false,
        }
        self.wander_dir   = {x = 0, z = 0}
        self.wander_timer = 0
        self.flee_dir     = {x = 0, z = 0}
        self.place_timer  = 0
        self.ignite_timer = 0
        self.nametag      = generate_name()
        self.current_anim = ""
        self.last_roll_day = 0

        -- Restore from staticdata if available
        local restored = deserialize_state(self, staticdata)

        -- Nametag
        self.object:set_properties({
            nametag = self.nametag,
            nametag_color = "#FFFFFF",
        })

        -- Track
        saboteur.active[#saboteur.active + 1] = self.object

        if restored then
            -- CRITICAL FIX: Check if we missed a daily roll while deactivated.
            -- Entities outside activation range don't get the globalstep daily roll.
            -- When they reactivate, check if a new day has passed since their last roll.
            local current_day = minetest.get_day_count()
            if current_day and self.last_roll_day < current_day then
                minetest.log("action", "[saboteur] " .. self.nametag
                    .. " missed daily roll (last=" .. self.last_roll_day
                    .. " now=" .. current_day .. "), rolling now")
                roll_daily_decision(self, current_day)
            else
                minetest.log("action", "[saboteur] " .. self.nametag
                    .. " restored, state=" .. self.state
                    .. (self.decision.placed and " (TNT placed)" or ""))
            end
        else
            -- Fresh spawn: roll decision for today
            local current_day = minetest.get_day_count() or 0
            self.last_roll_day = current_day
            roll_daily_decision(self, current_day)
        end
    end,

    -- ----------------------------------------------------------------
    -- on_deactivate
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
    -- get_staticdata
    -- ----------------------------------------------------------------
    get_staticdata = function(self)
        return serialize_state(self)
    end,

    -- ----------------------------------------------------------------
    -- on_step: Main state machine
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
            self.object:set_velocity({
                x = self.wander_dir.x, y = vel.y, z = self.wander_dir.z,
            })
            -- Random jump when on ground
            if math.random() < 0.01 and math.abs(vel.y) < 0.1 then
                self.object:set_velocity({
                    x = self.wander_dir.x, y = 4.5, z = self.wander_dir.z,
                })
            end

            -- Transition to placing if it's time to strike
            if self.decision.place_tnt
                and not self.decision.placed
                and self.decision.strike_at
                and minetest.get_gametime() >= self.decision.strike_at
            then
                self.state = "placing"
                self.place_timer = 0
            end

        -- ==== STATE: PLACING ====
        elseif self.state == "placing" then
            self.object:set_velocity({x = 0, y = vel.y, z = 0})
            self.place_timer = self.place_timer + dtime

            if self.place_timer >= 2 and not self.decision.placed then
                local tnt_pos = find_tnt_placement_pos(pos)

                if not tnt_pos then
                    -- Could not find spot — keep trying for a few more seconds
                    if self.place_timer >= 10 then
                        minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                            .. " could not find placement spot after 10s, will retry later")
                        -- Go wander for a bit, then try placing again
                        self.state = "wander"
                        self.wander_timer = math.random(5, 15)
                        self.place_timer = 0
                        -- Shift strike time slightly in the future to allow wandering first
                        self.decision.strike_at = minetest.get_gametime() + math.random(10, 30)
                    end
                elseif is_protected(tnt_pos) then
                    minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                        .. " protected area, aborting placement")
                    self.state = "wander"
                    self.decision.place_tnt = false
                    self.decision.strike_at = nil
                    self.wander_timer = 0
                else
                    -- Place the TNT!
                    local tnt_name = get_tnt_node_name()
                    minetest.set_node(tnt_pos, {name = tnt_name})
                    self.decision.placed = true
                    self.decision.tnt_pos = {x = tnt_pos.x, y = tnt_pos.y, z = tnt_pos.z}

                    minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                        .. " placed TNT at " .. minetest.pos_to_string(tnt_pos))

                    -- Switch to igniting state to light the fuse
                    self.state = "igniting"
                    self.ignite_timer = 0
                end
            end

        -- ==== STATE: IGNITING ====
        elseif self.state == "igniting" then
            self.object:set_velocity({x = 0, y = vel.y, z = 0})
            self.ignite_timer = self.ignite_timer + dtime

            -- Face the TNT during ignition
            if self.decision.tnt_pos then
                local dir = vector.direction(pos, self.decision.tnt_pos)
                local atan2 = math.atan2 or math.atan
                local yaw = atan2(-dir.x, dir.z)
                self.object:set_yaw(yaw)
            end

            -- Sizzle effect / sparks while lighting
            if math.random() < 0.2 and self.decision.tnt_pos then
                minetest.add_particlespawner({
                    amount = 3, time = 0.1,
                    minpos = vector.subtract(self.decision.tnt_pos, 0.2),
                    maxpos = vector.add(self.decision.tnt_pos, 0.2),
                    minvel = {x = -0.5, y = 0.5, z = -0.5},
                    maxvel = {x = 0.5, y = 1.5, z = 0.5},
                    minexptime = 0.2, maxexptime = 0.5,
                    minsize = 1, maxsize = 2,
                    texture = "saboteur_agent.png^[colorize:#FFAA00:200",
                })
                -- light crackle sound
                minetest.sound_play("default_cool_lava", {
                    pos = self.decision.tnt_pos, gain = 0.2, max_hear_distance = 16,
                }, true)
            end

            if self.ignite_timer >= 1.5 and not self.decision.ignited then
                local tnt_pos = self.decision.tnt_pos
                if tnt_pos then
                    local node = minetest.get_node(tnt_pos)
                    local expected_tnt = get_tnt_node_name()
                    if node.name == expected_tnt then
                        minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                            .. " LIGHTS UP TNT at " .. minetest.pos_to_string(tnt_pos))

                        local ignited_ok = ignite_tnt_node(tnt_pos)
                        if not ignited_ok then
                            -- Fallback ignite: play ignite sound
                            minetest.sound_play("tnt_ignite", {
                                pos = tnt_pos, gain = 1.0, max_hear_distance = 32,
                            }, true)
                        end

                        self.decision.ignited = true
                        self.decision.detonate_at = minetest.get_gametime() + 4

                        -- Stay and die (suicide style) or go away (flee)?
                        if math.random() < CONFIG.stay_and_die_chance then
                            self.decision.stay_and_die = true
                            self.state = "stand"

                            -- Shout something dramatic
                            local shouts = {
                                "For the cause!",
                                "Victory or death!",
                                "Witness me!",
                                "Kaboom time!",
                                "Say goodbye!",
                            }
                            local shout = shouts[math.random(#shouts)]
                            minetest.chat_send_all("[saboteur] " .. (self.nametag or "?") .. " shouts: " .. shout)

                            minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                                .. " decided to STAY AND DIE (suicide style)")
                        else
                            self.decision.stay_and_die = false
                            self.state = "flee"

                            -- Calculate flee direction away from TNT
                            local flee_vec = vector.direction(tnt_pos, pos)
                            if vector.length(flee_vec) < 0.1 then
                                local a = math.random() * math.pi * 2
                                flee_vec = {x = math.cos(a), y = 0, z = math.sin(a)}
                            end
                            self.flee_dir = {
                                x = flee_vec.x * CONFIG.flee_speed,
                                z = flee_vec.z * CONFIG.flee_speed,
                            }
                            minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                                .. " decided to FLEE")
                        end
                    else
                        minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                            .. " TNT disappeared before ignition, aborting")
                        self.state = "wander"
                        self.decision.place_tnt = false
                        self.decision.placed = false
                        self.decision.strike_at = nil
                        self.wander_timer = 0
                    end
                else
                    self.state = "wander"
                    self.decision.place_tnt = false
                    self.decision.placed = false
                    self.decision.strike_at = nil
                    self.wander_timer = 0
                end
            end

        -- ==== STATE: STAND (stay near TNT, wait for death) ====
        elseif self.state == "stand" then
            self.object:set_velocity({x = 0, y = vel.y, z = 0})

        -- ==== STATE: FLEE ====
        elseif self.state == "flee" then
            if self.decision.tnt_pos then
                local d = vector.distance(pos, self.decision.tnt_pos)
                if d >= 25 then
                    self.state = "wander"
                    self.wander_timer = 0
                else
                    self.object:set_velocity({
                        x = self.flee_dir.x, y = vel.y, z = self.flee_dir.z,
                    })
                    if math.random() < 0.01 and math.abs(vel.y) < 0.1 then
                        self.object:set_velocity({
                            x = self.flee_dir.x, y = 4.5, z = self.flee_dir.z,
                        })
                    end
                end
            else
                self.state = "wander"
                self.wander_timer = 0
            end
        end

        -- If NPC has a place_tnt decision but is wandering (retry after failed placement),
        -- switch back to placing after the wander timer expires
        if self.state == "wander" and self.decision.place_tnt
            and not self.decision.placed and self.decision.strike_at then
            if self.wander_timer <= 0 and minetest.get_gametime() >= self.decision.strike_at then
                self.state = "placing"
                self.place_timer = 0
            end
        end

        -- ==== ANIMATIONS ====
        local want_anim = "stand"
        if self.state == "wander" or self.state == "flee" then
            want_anim = "walk"
        elseif self.state == "igniting" then
            want_anim = "mine"
        end
        if self.current_anim ~= want_anim then
            self.current_anim = want_anim
            if want_anim == "walk" then
                self.object:set_animation({x = 168, y = 187}, 30, 0)
            elseif want_anim == "mine" then
                self.object:set_animation({x = 189, y = 198}, 30, 0)
            else
                self.object:set_animation({x = 0, y = 79}, 30, 0)
            end
        end

        -- ==== DETONATION CHECK ====
        if self.decision.ignited
            and self.decision.tnt_pos
            and self.decision.detonate_at
            and minetest.get_gametime() >= self.decision.detonate_at
        then
            -- If not using external TNT mod (or it failed), trigger manual explosion
            local using_tnt_mod = (HAS_TNT_MOD and tnt and (tnt.burn or tnt.ignite))
            if not using_tnt_mod then
                minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                    .. " DETONATING fallback TNT at " .. minetest.pos_to_string(self.decision.tnt_pos))
                do_explosion(self.decision.tnt_pos)
            else
                minetest.log("action", "[saboteur] " .. (self.nametag or "?")
                    .. " TNT fuse finished at " .. minetest.pos_to_string(self.decision.tnt_pos))
            end

            if self.decision.stay_and_die then
                minetest.log("action", "[saboteur] " .. (self.nametag or "?") .. " died in the explosion")
                self.object:remove()
                return
            else
                self.decision.place_tnt    = false
                self.decision.strike_at    = nil
                self.decision.placed       = false
                self.decision.ignited      = false
                self.decision.tnt_pos      = nil
                self.decision.detonate_at  = nil
                self.decision.stay_and_die = false
                self.state = "wander"
                self.wander_timer = 0
            end
        end
    end,
})

-- ============================================================================
-- 10. Global Step Manager: Daily Decisions & Spawning
-- ============================================================================
local spawn_check_timer = 0

minetest.register_globalstep(function(dtime)
    local current_day = minetest.get_day_count()
    if not current_day then return end

    init_global_state()

    -- ---- Day transition ----
    if current_day ~= saboteur.last_day then
        saboteur.last_day = current_day
        storage:set_int("last_day", current_day)

        saboteur.spawned_count_today = 0
        storage:set_int("spawned_count_today", 0)

        local base_max = CONFIG.max_spawns_per_day
        if math.random() < CONFIG.rare_multi_chance then
            saboteur.max_spawns_today = math.ceil(base_max * 1.5)
        else
            saboteur.max_spawns_today = base_max
        end
        storage:set_int("max_spawns_today", saboteur.max_spawns_today)

        clean_active_tracker()

        -- Daily roll for all currently active (loaded) entities
        for _, obj in ipairs(saboteur.active) do
            if obj and obj:is_valid() then
                local ent = obj:get_luaentity()
                if ent and ent.name == "saboteur:agent" then
                    roll_daily_decision(ent, current_day)
                end
            end
        end

        minetest.log("action", "[saboteur] Day " .. current_day
            .. ": " .. #saboteur.active .. " active agents"
            .. " (others will roll when they re-enter range)")
    end

    -- ---- Spawn check (dynamic interval based on spawns per day, assuming 20 min day) ----
    local spawn_interval = 1200 / math.max(1, CONFIG.max_spawns_per_day)
    spawn_check_timer = spawn_check_timer + dtime
    if spawn_check_timer < spawn_interval then return end
    spawn_check_timer = 0

    clean_active_tracker()

    if #saboteur.active >= CONFIG.max_persistent then return end
    if saboteur.spawned_count_today >= saboteur.max_spawns_today then return end

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

    -- Off-screen check
    local eye_pos = {x = ppos.x, y = ppos.y + 1.62, z = ppos.z}
    if minetest.line_of_sight(eye_pos, spawn_pos) then return end

    if is_protected(spawn_pos) then return end

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
-- 11. Chat Commands
-- ============================================================================

-- /purge_saboteurs - Hard remove all saboteur entities
local function purge_all_saboteurs()
    init_global_state()
    local count = 0

    for _, def in pairs(minetest.luaentities) do
        if def.name == "saboteur:agent" then
            if def.object and def.object:is_valid() then
                def.object:remove()
                count = count + 1
            end
        end
    end

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
    saboteur.max_spawns_today = CONFIG.max_spawns_per_day
    storage:set_int("max_spawns_today", CONFIG.max_spawns_per_day)

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

-- /saboteur_status - Show active saboteurs and their states
minetest.register_chatcommand("saboteur_status", {
    params = "",
    description = "Show status of all active saboteur agents",
    privs = {server = true},
    func = function(name)
        init_global_state()
        clean_active_tracker()

        local lines = {}
        lines[#lines + 1] = "=== Saboteur Status ==="
        lines[#lines + 1] = "Day: " .. saboteur.last_day
            .. " | Spawned today: " .. saboteur.spawned_count_today
            .. "/" .. saboteur.max_spawns_today
        lines[#lines + 1] = "Active (loaded): " .. #saboteur.active
            .. " | Max: " .. CONFIG.max_persistent

        if #saboteur.active == 0 then
            lines[#lines + 1] = "(No agents currently in activation range)"
        else
            for i, obj in ipairs(saboteur.active) do
                if obj and obj:is_valid() then
                    local ent = obj:get_luaentity()
                    if ent and ent.name == "saboteur:agent" then
                        local pos = obj:get_pos()
                        local pos_str = pos and minetest.pos_to_string(vector.round(pos)) or "?"
                        local info = ent.nametag .. " | " .. ent.state
                        if ent.decision.place_tnt then
                            info = info .. " | TNT planned"
                            if ent.decision.placed then
                                info = info .. " (PLACED at " .. minetest.pos_to_string(ent.decision.tnt_pos) .. ")"
                                if ent.decision.ignited then
                                    local remaining = ent.decision.detonate_at - minetest.get_gametime()
                                    info = info .. " | IGNITED (Boom in " .. math.floor(remaining) .. "s)"
                                else
                                    info = info .. " (lighting...)"
                                end
                            else
                                local remaining = ent.decision.strike_at - minetest.get_gametime()
                                info = info .. " (strike in " .. math.floor(remaining) .. "s)"
                            end
                            if ent.decision.stay_and_die then
                                info = info .. " [SUICIDE]"
                            end
                        end
                        info = info .. " | " .. pos_str
                        lines[#lines + 1] = " " .. i .. ". " .. info
                    end
                end
            end
        end

        local msg = table.concat(lines, "\n")
        minetest.chat_send_player(name, msg)
        return true
    end,
})

minetest.log("action", "[saboteur] Mod loaded successfully")
