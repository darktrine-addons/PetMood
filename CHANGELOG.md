# Changelog

## [v0.3.0-beta](https://github.com/darktrine-addons/PetMood/releases/tag/v0.3.0-beta) — 2026-11-27

### New features
- Options panel: type `/petmood`, or open Options → AddOns → PetMood. Set the icon size, and switch the icon, food count, glow, one-click feeding, alerts, the reminder before pulls and the broker display on or off.
- Excluded food: drag items from your bags onto the list, and PetMood never feeds them to your pet. Excluded items don't count towards the food count. From chat: `/petmood exclude` and `/petmood include` followed by a shift-clicked item.

### Improvements
- `/petmood` opens the options; `/petmood help` lists the commands.

## [v0.2.0-beta](https://github.com/darktrine-addons/PetMood/releases/tag/v0.2.0-beta) — 2026-11-27

### New features
- The icon glows yellow (Content) or red (Unhappy) when your pet needs food (`/petmood glow`).
- A small number on the icon shows how much food your pet eats you have left. It turns red when you are running low.
- Feeding timer: while your pet eats, a timer sweeps over the icon, and the tooltip shows the time left.
- Reminder before the pull: on a ready check, or when you enter a dungeon or raid, PetMood reminds you if your pet isn't Happy (`/petmood reminder`).
- Pet level, XP, XP per hour and an estimated time to the next level in the tooltip.
- The broker display now also shows your food count and your pet's level progress, e.g. "Happy · 23 · L12 64%".

## [v0.1.0-beta](https://github.com/darktrine-addons/PetMood/releases/tag/v0.1.0-beta) — 2026-11-26

First beta.

### New features
- Movable pet happiness icon with the classic Happy / Content / Unhappy faces.
- Alert when your pet's mood drops: centre-screen warning, chat line and sound. During a fight it waits until combat is over.
- One-click feeding: click the locked icon, or press its key binding, to feed your pet suitable food from your bags.
- Tooltip with mood, damage bonus, loyalty, diet and the amount of food you carry.
- LibDataBroker feed for Bazooka, Titan Panel, ElvUI and other broker displays.
- Option to hide the icon while your pet is Happy (`/petmood happy`).

### Improvements
- No tooltips in combat.
- Inactive on characters that aren't hunters.
