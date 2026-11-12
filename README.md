# Rebuff

Shows the next buff that is missing or about to run out, on you or your party, and casts it with one hotkey. For WoW Forever.

## Features

- **Your buffs:** Drop spells from your spellbook onto the options window. Each one is kept up on yourself or on your party. A party buff can be kept to the classes you pick.
- **One icon:** The next buff to cast shows as a button, with the time it has left and who needs it. Group versions count: Prayer of Fortitude satisfies Power Word: Fortitude.
- **One hotkey:** Mouse wheel down by default. It casts what the icon shows, and is Rebuff's only while a buff is due and in range. The rest of the time the key does what it always did.
- **In combat:** Rebuff steps aside. The icon hides and the hotkey is given back, also while dead or mounted.

## Getting started

1. Type `/rebuff` to open the options.
2. Drop the buffs you want kept up from your spellbook onto the grid.
3. Pick for each whether it goes on yourself or on your party. In a raid, your party is your own raid group.

While the options are open the icon shows, to be dragged into place. Later, Alt-drag it. `/rebuff status` tells what Rebuff sees right now, and `/rebuff help` lists the commands.

## Installation

Download `Rebuff-<version>-forever.zip` from the latest [release](https://github.com/casperstorm/rebuff/releases), extract the `Rebuff` folder into `World of Warcraft/_forever_/Interface/AddOns`, and restart the game.

Take that file, not GitHub's **Source code** zip or the green **Code** button: those unpack to a folder named `rebuff-…`, which the game does not recognise as the addon.

## Development

`tests/run.sh` runs the addon's logic against a stand-in for the WoW API (needs Lua 5.1). A release is cut by running the **Release** workflow with a version number.

Rebuff is released under the [GPL-3.0 License](LICENSE).
