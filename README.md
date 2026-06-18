# 🧨 Saboteur NPC

A persistent, AI-driven NPC that roams your world and makes independent decisions every in-game day. Will it place TNT today? Will it flee or stay to watch the explosion? Survivors persist indefinitely, creating dynamic, emergent tension in survival and building servers.

## ✨ Features
- **Daily Decision Loop**: At midnight, every alive saboteur independently rolls whether to place TNT today.
- **Persistent Population**: If they choose not to act, they simply wander until the next midnight. Survivors stack over time.
- **Smart Spawning**: Spawns 1/day max, always off-screen near a random online player. Rare chance for extra spawns.
- **Self-Destruct or Escape**: If placing TNT, randomly decides to stand their ground or flee to safety.
- **Protection-Aware**: Never places explosives in protected zones. Aborts and resumes wandering if blocked.
- **Lightweight AI**: Decisions run once/day. Movement is physics-driven with automatic stair climbing and jumping.
- **Fully Configurable**: Tune spawn rates, chances, speeds, and caps via `minetest.conf`.

## ⚙️ Configuration (`minetest.conf`)
```ini
saboteur.place_tnt_chance = 0.4          # 40% chance to place TNT each day
saboteur.stay_and_die_chance = 0.3       # 30% chance to stay near TNT after placing
saboteur.spawn_radius_min = 60           # Minimum distance from players
saboteur.spawn_radius_max = 90           # Maximum distance from players
saboteur.rare_multi_chance = 0.05        # 5% chance for an extra spawn per day
saboteur.max_persistent = 20             # Hard cap on alive saboteurs (0 = unlimited)
saboteur.wander_speed = 2.5              # Base movement speed
saboteur.flee_speed = 4.0                # Speed when running from explosion