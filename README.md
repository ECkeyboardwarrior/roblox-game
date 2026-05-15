# Spirit Grove

A Roblox experience inspired by *Bee Swarm Simulator*, themed around nature wisps that follow the player and harvest **Essence** from biomes. Players deposit essence at the **World Tree** for **Spirit Shards**, then spend shards on better **Staffs** and more **Wisp Slots**.

## Project layout (Rojo)

```
D:\roblox game\
├── default.project.json     # Rojo config — maps folders to DataModel
├── .gitignore
├── README.md                # this file
└── src\
    ├── ReplicatedStorage\   # shared code (server + client can see it)
    │   └── Shared\
    │       ├── Constants.lua
    │       ├── Remotes.lua
    │       └── WispTypes.lua
    ├── ServerScriptService\ # server-only scripts
    │   ├── Main.server.lua
    │   └── Services\
    │       ├── PlayerDataService.lua
    │       ├── WispService.lua
    │       └── EssenceService.lua
    ├── ServerStorage\       # server-only assets (placeholder)
    └── StarterPlayer\
        └── StarterPlayerScripts\
            ├── Main.client.lua
            ├── WispController.client.lua
            └── HarvestController.client.lua

> **Note**: `Main.server.lua` and `Main.client.lua` are named *Main* (not *Init*) on purpose. Rojo reserves `init.server.lua` / `init.client.lua` as a magic filename that turns the *parent folder* into a script — using that name here would collide with `$className` in the project file.
```

### Rojo file-name conventions

- `Foo.lua`          → **ModuleScript** named `Foo`
- `Foo.server.lua`   → **Script** named `Foo` (server-side)
- `Foo.client.lua`   → **LocalScript** named `Foo` (client-side)
- `init.lua` inside a folder → the folder itself becomes a script with that file as its body

## First-time setup

1. **Install the Rojo VS Code extension** (search "Rojo" in the Extensions tab, publisher `evaera`).
2. Open this folder (`D:\roblox game`) in VS Code: `File → Open Folder…`
3. Open a terminal in VS Code (``Ctrl + ` ``) and run:
   ```
   rojo serve
   ```
   You should see something like `Rojo server listening on port 34872`.
4. In Roblox Studio:
   - Create a new **Baseplate** place (`File → New From Template → Baseplate`).
   - Install the **Rojo** Studio plugin if you haven't (one-time, from the [Rojo docs](https://rojo.space)).
   - Click the **Rojo** button in the Plugins tab → **Connect**.
   - Studio will now mirror this folder into the DataModel. Saving any `.lua` file in VS Code instantly updates Studio.
5. Press **F5** in Studio to play-test.

## Architecture notes

- **Client-authoritative wisp movement.** Each player simulates their own wisps locally (spring math, no network cost). The server only knows *how many* wisps a player owns and *what type* — it never simulates positions. This is how Bee Swarm scales to 30+ followers.
- **Server-authoritative harvesting.** When the player clicks a node, the client sends a `RequestHarvest` remote. The server validates (distance, node state, cooldown) and awards essence.
- **DataStore on join/leave.** `PlayerDataService` loads a profile when a player joins and saves on leave + every 60 s. Schema is versioned in `Constants.lua` so we can migrate safely later.
- **Modular wisp types.** Every wisp type is a row in `WispTypes.lua`. Adding a new wisp = adding one entry. Stats (`collectionAmount`, `attackDamage`, `moveSpeed`, `ability`) come from there.

## Roadmap (high-level)

**Alpha — Core Loop** (where this scaffold gets you started)
- One starter wisp, one starter field with essence nodes
- Click-to-harvest staff
- Lantern capacity bar, deposit at World Tree
- Spirit Shards currency, shop with 2 staffs and 2 extra wisp slots
- Save/load via DataStore

**Beta — Depth**
- 5+ biomes with gated entry (wisp-count requirement)
- Quests from NPCs near the World Tree
- Hostile mobs that wisps fight (uses `attackDamage` stat)
- Wisp abilities (Spark AoE, Mist slow, etc.)
- Spirit Logs (bestiary unlocked by encountering things)

**Full Release — Endgame & Polish**
- Canopy of Ancients final zone + Great Spirit donation ritual
- **Ascension** rebirth → permanent buffs + Prismatic wisp variants
- Limited-time events (Solstice, Eclipse) with cosmetic rewards
- Tutorial flow, polish pass, sound design, particle FX

## Monetization (planned, not built yet)

- **Gamepasses** (one-time): 2× Lantern Capacity, +5 Wisp Slots, Auto-Deposit, Cosmetic staff skins.
- **Developer Products** (consumable): Shard bundles, time-limited 2× harvest boost.
- **Fair-play rule.** Nothing paid should bypass progression gates — gamepasses *speed up* the loop, they don't skip biome unlocks. Prismatic wisps stay locked behind Ascension regardless of spending.
