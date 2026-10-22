# [L4D2] Tank Reset Fix

A SourceMod plugin for Left 4 Dead 2. It stops finales from skipping their Tank stage, and the Tank music from restarting, when a bot Tank's AI is reset by a script or plugin.

## The problem

Scripts and plugins often hand a bot Tank back to the game's AI with `CommandABot({cmd = BOT_CMD_RESET, bot = tank})`. During a finale this often has two side effects:

- The finale moves on to its next stage while the Tank is still alive.
- The Tank music starts over.

## Why it happens

The director counts a bot Tank as "in play" (what `Director.IsTankInPlay()` returns) only while his body's arousal is not neutral. His attack behaviour raises it when it starts.

A reset rebuilds every part of the bot, which sets his arousal back to neutral at once. The new attack behaviour only raises it again on the Tank's next AI update. The director updates before bot AI and before any script each tick, and bot AI only updates every `nb_update_frequency` seconds (0.1 by default). So after a reset, the director always sees at least one tick with no Tank in play:

- A finale's Tank stage ends on the first tick it sees no Tank in play.
- When the Tank is counted again, the director treats it as a new Tank entering play, which restarts the music.

VScript can't avoid this. A bot given a `BOT_CMD_MOVE` order stays on it until he is reset, and no script function can set a bot's arousal or update him right away.

## What the plugin does

When a living bot Tank is reset, the plugin keeps the arousal he had before the reset. The director goes on counting him, and his AI sets the arousal again on its next update as usual. Nothing else about the reset changes.

Other NextBots that reset through the same function (common infected, Witches, other bots) are left alone.

## Requirements

- Left 4 Dead 2 server (dedicated or listen), Windows or Linux.
- SourceMod 1.12 or newer. DHooks is built into SourceMod, so nothing else is needed.

## Installation

Copy the `addons` folder into your `left4dead2` folder:

```
addons/sourcemod/plugins/l4d2_tank_reset_fix.smx
addons/sourcemod/gamedata/l4d2_tank_reset_fix.txt
addons/sourcemod/scripting/l4d2_tank_reset_fix.sp   (source, not needed to run)
```

Then restart the server or change the map. The plugin creates `cfg/sourcemod/l4d2_tank_reset_fix.cfg` on first load.

## Console variables

| Variable | Default | Description |
| --- | --- | --- |
| `l4d2_tank_reset_fix_enable` | `1` | 1 keeps a bot Tank counted as in play through an AI reset. 0 turns the fix off. |
| `l4d2_tank_reset_fix_debug` | `0` | 1 prints a line to the server console each time a Tank's arousal is kept. |
| `l4d2_tank_reset_fix_version` | | Plugin version. |

## Commands

| Command | Access | Description |
| --- | --- | --- |
| `sm_tank_arousal` | Generic admin | Prints the arousal of every living bot Tank (0 neutral, 1 alert, 2 intense). |

## Checking that it works

1. During a Tank fight, run `sm_tank_arousal`. A Tank who is attacking should show 2. If he does, the gamedata matches your server.
2. Set `l4d2_tank_reset_fix_debug 1`. The server console shows a line each time a reset is caught.
3. Play a finale with a script that resets the Tank. The Tank stage should last until the Tank dies, and the music should not restart.

If the plugin ever reads an arousal outside 0 to 2, the gamedata does not match the game. It then logs an error and stops itself rather than writing anything.

## Gamedata

| Entry | Windows | Linux |
| --- | --- | --- |
| `INextBot::Reset` (detoured) | Signature | `_ZN8INextBot5ResetEv` |
| `CBaseEntity::MyNextBotPointer` | 81 | 82 |
| `INextBot::GetEntity` | 44 | 45 |
| `INextBot::GetBodyInterface` | 48 | 49 |
| `IBody::SetArousal` | 66 | `PlayerBody::SetArousal` symbol, 67 as a fallback |
| `IBody::GetArousal` | 67 | `PlayerBody::GetArousal` symbol, 68 as a fallback |

The Windows values were read from the game's `server.dll`. The Linux reset symbol and the `MyNextBotPointer` and `GetEntity` offsets match the Linux gamedata of the [Actions](https://github.com/Vinillia/actions.ext) extension. The other Linux offsets follow the same pattern (the Windows index plus one).

## Compiling

```
spcomp l4d2_tank_reset_fix.sp -o l4d2_tank_reset_fix.smx
```

Use the compiler from SourceMod 1.12 or newer, with its standard include files.

## Compatibility

The [Actions](https://github.com/Vinillia/actions.ext) extension also hooks `INextBot::Reset`. Running both together has not been tested.

## Credits

- Thumos: Plugin.
- Claude Opus 5.5: Coding and debugging.
- [Actions](https://github.com/Vinillia/actions.ext) by BHaptop: Linux gamedata reference for `INextBot::Reset` and the NextBot offsets.
