# PetMood

**Your hunter pet's happiness at a glance, for WoW Forever.**

A small movable icon shows whether your pet is Happy, Content or Unhappy. The same information is available as a LibDataBroker feed for broker bars such as Bazooka, Titan Panel or ElvUI. When your pet's mood drops, PetMood warns you in the middle of the screen with a sound. If that happens during a fight, the warning waits until combat ends.

WoW Forever only (Interface 16001). Retail pets have no happiness. PetMood only runs on hunters; on other characters it stays inactive, so it is safe to keep enabled for all of them.

## Features

- **Movable icon.** Shows the current mood with the classic happiness faces. Unlock it to drag it, lock it to hide it whenever no hunter pet is out.
- **Broker feed.** The coloured mood text and icon in any LibDataBroker display.
- **Click to feed.** Click the locked icon, or press its key binding, to feed your pet. PetMood picks the food from your bags: the lowest-level food your pet eats that is still close to its level, keeping your better food for later. The tooltip shows the pet's diet and how much food you carry.
- **Mood drop alert.** A centre-screen warning, a chat line and a sound when the mood drops from Happy to Content or from Content to Unhappy. Fights are never interrupted: alerts from combat are shown once it ends.
- **Only when needed.** Optionally hide the icon while your pet is Happy, so it only appears when there is something to do. The key binding keeps working.
- **Quiet in combat.** Tooltips stay closed while you are in combat.

## Commands

| Command | Effect |
|---|---|
| `/petmood lock` | Lock or unlock the icon (locked: click to feed; unlocked: drag to move) |
| `/petmood happy` | Hide the locked icon while your pet is Happy |
| `/petmood alert` | Turn the mood drop alert on or off |
| `/petmood sound` | Turn the alert sound on or off |
| `/petmood test` | Show a test alert |
| `/petmood reset` | Move the icon back to the screen centre |
| `/petmood diag` | Print what the game reports about your pet's happiness |

A key binding for feeding is under *Key Bindings → AddOns → PetMood*.

## Changelog

See [CHANGELOG.md](https://github.com/darktrine-addons/PetMood/blob/main/CHANGELOG.md).

## Feedback

Bug reports and ideas are welcome on the [issue tracker](https://github.com/darktrine-addons/PetMood/issues).
