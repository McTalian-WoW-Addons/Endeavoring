# Endeavoring

_Endeavor together._

A World of Warcraft addon that enhances the Endeavors system for your neighborhood. Instead of just seeing task names and progress bars, actually see who's contributing what, compete with your neighbors on a leaderboard, and track activity over time.

## What It Does

Blizzard's Endeavors UI is pretty basic - you can see tasks and overall progress, but that's about it. This addon adds:

- **Better task view** - See House XP and Coupons rewards at a glance. Sort by contribution, rewards, or task name. Shift-click to track tasks.
- **Leaderboard** - Your guildmates' contributions aggregated (and sortable) by player (not character). Nothing like a little friendly competition to get those tasks done!
- **Activity log** - Chronological feed of task completions with filtering by time range and player (sorting here as well :D ).
- **Profile sync** - Shares your character list and alias with guild members so the leaderboard shows a chosen alias for all of your characters instead of "Charactername", "Sameperson", "Anotheralt".

All your characters are automatically grouped under your player alias (or BattleTag if you don't set one).

## Installation

### Via Addon Manager (Recommended)

Install directly through your favorite addon manager:
- **CurseForge App**: Search for "Endeavoring"
- **Wago App**: Search for "Endeavoring"  
- **WoWUp**: Add from CurseForge or Wago

### Manual Install

1. Download the latest release from [GitHub Releases](https://github.com/McTalian-WoW-Addons/Endeavoring/releases), [CurseForge](https://www.curseforge.com/wow/addons/endeavoring), [WoWInterface](https://www.wowinterface.com/downloads/info27047-Endeavoring.html), or [Wago](https://addons.wago.io/addons/endeavoring)
2. Extract to `World of Warcraft/_retail_/Interface/AddOns/`
3. Make sure the folder is named `Endeavoring`
4. Restart WoW or `/reload`

## Usage

**Open the main window:**
- Type `/endeavoring` or `/ndvr` or Click the "Endeavoring" button in the Blizzard UI Housing Dashboard (Endeavors tab)

**Set your alias:**

- Open settings panel: `/endeavoring settings` or click gear icon
- Click "Change Player Alias" button
- Defaults to your BattleTag if not set

**Commands:**

- `/endeavoring` or `/ndvr` - Toggle main window
- `/endeavoring settings` - Open settings panel
- `/endeavoring alias <name>` - Set your alias via command

## Requirements

- **WoW Client:** Midnight (12.0.0+) - this addon only works with the Midnight expansion
- **Guild membership:** Profile sync uses guild chat, so you need to be in a guild with others running the addon to see other neighbors custom aliases and character groupings on the leaderboard.
- **Endeavors access:** Must have unlocked the Endeavors system (neighborhood + housing)

## Known Limitations

- **Guild-scoped sync** - Only syncs with guild members running the addon. No cross-guild support.
- **Untested with multi-neighborhoods** - there are probably some features that need to be added to smooth out the experience for players with multiple neighborhoods, but it might still be functional. Please report any issues you encounter in this scenario.

## Support & Bugs

- **GitHub:** [McTalian-WoW-Addons/Endeavoring](https://github.com/McTalian-WoW-Addons/Endeavoring)
- **Discord:** [Join here](https://discord.gg/czRYVWhe33)

Found a bug? Open an issue on GitHub or ping me on Discord. Include any error messages from BugSnag/BugGrabber or `/console scriptErrors 1` if you can.

## Other Great Endeavor Addons

**[Vamooses Endeavors](https://www.curseforge.com/wow/addons/vamooses-endeavors)** has a many of the same features with a different look and feel. Major props to the House XP cap tracking. There's no API for that and they went through the effort of coming up with a heuristic to track it based on task completions, rewards, and diminishing returns calculations. If that feature is important to you, check it out! I started my work on Endeavoring before I found out about Vamoose's addon know that someone would beat me to the punch, but I decided to release Endeavoring anyways since I learned a lot building it and I think the profile/player/account sync and activity log features are unique and valuable additions to the addon community.

## Attribution

Addon icon by [Delapouite](https://delapouite.com), licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). Modified and downloaded via [game-icons.net](https://game-icons.net).
