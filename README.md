# 🧨 Saboteur NPC

A persistent, AI-driven NPC mod for Luanti/Minetest. Saboteurs roam your world and make independent decisions every in-game day. Will they place TNT today? Will they flee or stay to watch the explosion? Survivors persist indefinitely, creating dynamic, emergent tension in survival and building servers.

> [!CAUTION]
> **CRITICAL WARNING:** This mod causes severe, irreversible damage to the map. By default, saboteurs spawn very frequently (40 spawns per day) and will ignite TNT that destroys terrain, structures, and kills players. **Do not use this mod on production building/creative servers! Use with extreme caution on backup-enabled or test worlds.**

---

## ✨ Features
- **Daily Decision Loop**: At midnight, every alive saboteur independently rolls whether to place TNT today, scheduling a dynamic strike time during the day.
- **Stand & Light State**: When striking, the NPC stops, plays an arm-swing lighting animation, and triggers sizzling sparks and crackle sounds at the TNT.
- **TNT Ignition & Fuse**: Triggers the official `tnt` mod's ignition (`tnt.burn` or `tnt.ignite`), turning the static node into a live burning TNT entity with a 4-second fuse.
- **Suicide Bomber vs. Escape**: When the fuse is lit, they decide to either flee at high speed or stand next to the sizzling TNT (shouting a dramatic line in the chat before dying in the blast).
- **Persistent Population**: Saboteurs that don't act or survive their escape persist across days and server restarts.
- **Protection-Aware**: Never places explosives in protected zones (supports `protector` and `areas`). Aborts and wanders away if blocked.
- **Lightweight AI**: Movement is physics-driven with automatic stair climbing, random jumps, and off-screen spawning.

---

## ⚙️ Configuration (`minetest.conf`)
You can tune the saboteur settings by adding these lines to your `minetest.conf` file:

```ini
saboteur.max_spawns_per_day = 40        # Default: 40. Controls daily spawn count and spawn frequency.
saboteur.place_tnt_chance = 0.4          # Default: 0.4 (40% chance to place TNT each day)
saboteur.stay_and_die_chance = 0.3       # Default: 0.3 (30% chance to stay and die suicide-style)
saboteur.spawn_radius_min = 60           # Default: 60 (Minimum spawn distance from players)
saboteur.spawn_radius_max = 90           # Default: 90 (Maximum spawn distance from players)
saboteur.rare_multi_chance = 0.05        # Default: 0.05 (5% chance for a 1.5x daily spawn bonus)
saboteur.max_persistent = 20             # Default: 20 (Hard cap on total active saboteurs)
saboteur.wander_speed = 2.5              # Default: 2.5 (Base movement speed)
saboteur.flee_speed = 4.0                # Default: 4.0 (Speed when running from live TNT)
```

---

## 🛠️ Admin Commands
These commands require the `server` privilege:
- `/saboteur_status`: Shows the status of all active saboteurs, their coordinates, strike timers, and ignition states.
- `/purge_saboteurs`: Instantly deletes all active saboteur entities, resets the daily spawn counters, and updates the spawn limit to the configuration default. Run this after changing the config to apply changes immediately.