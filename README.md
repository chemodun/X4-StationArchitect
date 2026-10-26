# Station Auto Builder

Building a large station by hand means working out every module it needs and then dragging each one into place; the game's generator places a whole list at once, but with random results and no second chance. This extension does both steps for you inside the build menu: tell it what the station should produce or build, and it computes every module the goal needs, then places them one at a time while the game's own editor snaps each one into place. Nothing is bought or built until you press the usual Apply.

## Features

- **Target planner**: choose what the station should do, not which modules it needs. A target is a ware to produce (a number of its production modules) or ships to build or maintain (a number of build modules); several targets fit in one plan.
- **Full cycle**: every intermediate ware down to the raw resources and the energy cells, with the storage to hold them. Without it, only the target's own modules and their storage.
- **Workforce**: habitats for the workforce the planned modules need; **Self-sufficient workforce** adds the food and medical supplies that workforce eats. The workforce race and the race of all other modules are separate choices; "Any" picks the best of your blueprints for each module.
- **Read from the game, not from tables**: production rates with the workforce and sunlight bonuses of each production method, module sizes, connections, docking bays and approach zones, ship build times at the station's workforce. Docks and piers are sized for the station's planned traffic.
- **A preview before anything is placed**: the planned modules, each ware's net per hour now and after the plan, workforce, trade volume in and out, and warnings.
- **Existing stations**: the planner reads what a station already makes as its current targets, ticks Full cycle and Workforce when the station looks like it, and adds the modules for any shortfall it finds (a missing resource, habitats short of the workforce).
- **Compact layout**: production, storage and habitats are packed in a tight block linked by connection modules; ship build modules sit on the sides with their approach corridors clear; docks and piers go outward.
- **A new station from the map**: right-click empty space in a sector, choose **Plan a station here**, set the target, and OK reserves the plot, opens the build menu and starts the run.
- **Bill route**: the manual alternative, a list of modules and counts from your blueprints, placed the same way.
- **Plot licence**: where the plot costs money, the run shows the plot size it needs and the price, and places nothing until you buy the licence. **Optimize plot** shrinks the plot to the planned modules afterwards.
- **The plan stays yours**: move, add or remove modules by hand, save or load plans, and press Apply to pay as usual; the build menu's Cancel discards the whole unconfirmed plan.

## Limitations

- Works only inside the open build menu of a station you own, with your own blueprints.
- This mod requires `Protected UI Mode` in the game's Extensions settings to be disabled.
- Windows version of the game only: the placement route reads the game's own editor in memory, which the native Linux build does not expose the same way. The Windows game running on Linux through Proton or Wine should work.
- Verified on the 8.00 and 9.00 builds of the game. On a build it does not recognise, the panel says the editor is not reachable and Run stays off; nothing else in the build menu changes.
- The plot is limited to the game's 20 km: a layout that needs more is refused before anything is placed.
- Ship build times assume the station has its build drones; a shipyard without them builds several times slower than planned.
- A module that fits nowhere is reported as failed, never silently dropped.

## Requirements

- **X4: Foundations**: Version **8.00** or higher, Windows version.
- **Mod Support APIs**: Version **1.95** or higher by [SirNukes](https://next.nexusmods.com/profile/sirnukes?gameId=2659).
  - Available on Steam: [SirNukes Mod Support APIs](https://steamcommunity.com/sharedfiles/filedetails/?id=2042901274)
  - Available on Nexus Mods: [Mod Support APIs](https://www.nexusmods.com/x4foundations/mods/503)
- **Options Helper**: Version **1.10** or higher by [Chem O`Dun](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659).
  - Available on Steam: [Options Helper](https://steamcommunity.com/sharedfiles/filedetails/?id=3715253556)
  - Available on Nexus Mods: [Options Helper](https://www.nexusmods.com/x4foundations/mods/2155)
- **Print Extension List**: Version **1.00** or higher by [Chem O`Dun](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659).
  - Available on Steam: [Print Extension List](https://steamcommunity.com/sharedfiles/filedetails/?id=3770927339)
  - Available on Nexus Mods: [Print Extension List](https://www.nexusmods.com/x4foundations/mods/2191)
- **Lua Log API**: Version **1.00** or higher by [Chem O`Dun](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659).
  - Available on Steam: [Lua Log API](https://steamcommunity.com/sharedfiles/filedetails/?id=3823580916)
  - Available on Nexus Mods: [Lua Log API](https://www.nexusmods.com/x4foundations/mods/2473)
- **Extra Data API**: Version **1.00** or higher by [Chem O`Dun](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659).
  - Available on Steam: [Extra Data API](https://steamcommunity.com/sharedfiles/filedetails/?id=3825599643)
  - Available on Nexus Mods: [Extra Data API](https://www.nexusmods.com/x4foundations/mods/)

## Installation

You can download the latest version via Steam client - [Station Auto Builder](https://steamcommunity.com/sharedfiles/filedetails/?id=)
Or you can do it via the Nexus Mods - [Station Auto Builder](https://www.nexusmods.com/x4foundations/mods/)

## Save state

**No** (removing the extension does not break saves).

## Usage

Open the build menu of one of your stations. The Station Auto Builder panel sits under the menu's title bar; expand it to plan. It has two tabs: **Target** and **Bill**.

### Target

1. Pick the kind of target (**Produce a ware** or **Build or maintain ships**), then the ware or the build module, and press **Add a target**. Each added target gets a slider for its number of production or build modules; on an existing station a slider starts at what the station already has, and releasing it at that lowest value removes the target.
2. Set the options: **Modules race**, **Full cycle**, **Workforce**, **Self-sufficient workforce**, **Workforce race**, **Denser packing** (a smaller block on an empty plan, at the cost of a longer planning step) and **Storage, hours of flow** (how many hours of each ware's flow the storage holds).
3. Check the preview: the planned modules, each ware's net per hour now and planned, the workforce and trade line, and any warning.
4. Press **Run**. The run first finds a layout, then places the modules one after another; the panel shows the progress, and **Stop** halts it after the current module. **Modules per frame** sets how many modules are placed per frame.
5. When the run ends the panel folds to its result (placed, failed). Check the plan, change what you like by hand, and press Apply as usual. **Optimize plot** fits the plot to the planned modules, so a plot the run grew is not paid larger than needed. **Reset** starts the target over from what the station has.

### From the map

Right-click empty space in a sector on the map and choose **Plan a station here**. The dialog shows the same target form, plus **Preset for all station modules** (the loadout of the new modules), the plot size and its price. OK reserves the plot at that spot, opens the build menu and starts the run; Apply stays your click.

### Bill

The manual route: pick a category and a module from your blueprints, set the count, press **Add**. Repeat for every module type; a row's X removes it, **Clear** empties the bill. **Run** places the modules on the station's free connections, nearest to the centre first, docks, piers, build and defence modules on outward connections.

![The planner panel with a bill of two module types](docs/images/panel_bill.png)

![A run in progress](docs/images/panel_running.png)

![The build menu during a run: the new modules appear on the station one by one](docs/images/build_menu_run.png)

Connection modules in the bill are not placed as such: they are the budget of connectors the run may insert when a module finds no free connection.

## Options

In the game's Extension Options, the Station Auto Builder page has a Debug Level setting (None, Debug, Trace) for the game log.

## Credits

- Author: Chem O`Dun, on [Nexus Mods](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659) and [Steam Workshop](https://steamcommunity.com/id/chemodun/myworkshopfiles/?appid=392160)
- *"X4: Foundations"* is a trademark of [Egosoft](https://www.egosoft.com).

## Acknowledgements

- [EGOSOFT](https://www.egosoft.com) for the X series.
- [SirNukes](https://next.nexusmods.com/profile/sirnukes?gameId=2659) for the Mod Support APIs that power the UI hooks.

## Changelog

### [1.00] - 2026-10-??

- Added
  - Initial version
