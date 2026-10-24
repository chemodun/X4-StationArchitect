# Station Auto Builder

Building a large station by hand means dragging every module into place; the game's generator places a whole list at once but with random results and no second chance. This extension fills your station's build plan from a bill of modules inside the build menu, one module at a time, and lets the game's own editor snap each one into place while you watch. Nothing is bought or built until you press the usual Apply.

## Features

- A planner panel in the station build menu: pick modules from your blueprints, set a count per module, press Run.
- Modules are placed one after another on the station's free connections, visibly, in the real build plan.
- The plan stays yours: undo, save and load plans, add or move modules by hand, Apply and pay as usual.
- A module the planner cannot place is reported, not silently dropped; the game's own generator stays available for the rest.

## Limitations

- Works only inside the open build menu of a station you own.
- Windows version of the game only: the placement route reads the game's own editor in memory, which the native Linux build does not expose the same way. On a game build where that route is not available the panel says so and Run stays off; nothing else in the build menu changes.
- Modules are placed on free connections of the current plan; a module that fits nowhere is reported as failed. The plot is not grown automatically: give the station enough plot room in the game's own plot panel first.

## Requirements

- **X4: Foundations**: Version **9.00** or higher, Windows version.
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

## Installation

You can download the latest version via Steam client - [Station Auto Builder](https://steamcommunity.com/sharedfiles/filedetails/?id=)
Or you can do it via the Nexus Mods - [Station Auto Builder](https://www.nexusmods.com/x4foundations/mods/)

## Save state

**No** (removing the extension does not break saves).

## Usage

Open the build menu of one of your stations. The planner panel sits under the menu's title bar.

![The planner panel with a bill of two module types](docs/images/panel_bill.png)

1. Pick a category and a module from your blueprints, set the count, press Add. Repeat for every module type you want; a row's X removes it, Clear empties the bill.
2. Press Run. Modules are placed one after another; the panel counts placed, failed and left. Stop halts the run after the current module.
3. When the run ends, check the plan, move or remove what you like by hand, and press Apply as usual. The build menu's own Cancel discards the whole unconfirmed plan. Optimize plot fits the plot to the planned modules on every side (the smallest plot on an empty plan), so a plot a run grew or one you emptied is not paid larger than needed.

![A run in progress](docs/images/panel_running.png)

![The build menu during a run: the new modules appear on the station one by one](docs/images/build_menu_run.png)

Connection modules in the bill are not placed as such: they are the budget of connectors the planner may insert when a module finds no free connection. Big modules go first and nearest to the station's centre, docks, piers, build and defence modules on outward connections with clearance around them.

## Options

In the game's Extension Options, the Station Auto Builder page has a Debug Level setting (None, Debug, Trace) for the game log.

## Credits

- Author: Chem O`Dun, on [Nexus Mods](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659) and [Steam Workshop](https://steamcommunity.com/id/chemodun/myworkshopfiles/?appid=392160)
- *"X4: Foundations"* is a trademark of [Egosoft](https://www.egosoft.com).

## Acknowledgements

- [EGOSOFT](https://www.egosoft.com) for the X series.
- [SirNukes](https://next.nexusmods.com/profile/sirnukes?gameId=2659) for the Mod Support APIs that power the UI hooks.

## Changelog

### [1.00] - 2026-10-23

- Added
  - Initial version
