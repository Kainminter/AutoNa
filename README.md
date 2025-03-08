**AutoNA** (Experimental Build, Currently unreliable for regular use)

FFXI Windower Addon

**DISCLAIMER:**

This addon is a third-party tool designed for use with Final Fantasy XI. Use it at your own risk. The creator of this addon is not affiliated with Square Enix and is not responsible for any consequences arising from its use, including but not limited to violations of the game’s terms of service, account penalties, or unintended game behavior. By using this addon, you acknowledge and accept any potential risks involved.

**DESCRIPTION:**

The AutoNA addon is a tool that automates casting na spells / erase / healing waltz on party members and yourself when status ailments are detected.

**KNOWN ISSUES:**

Detection for when its safe to cast not always accurate. If spell interupted or cannot be cast, it will try again.

Under certain conditions, it may begin to have issues tracking which party members have status ailments correctly. For example party member 3 might have paralyze, but the addon will become certain its party member 5 for some reason. Potentially an issue with multiple instances of the addon running in multiple windows.

I am noticing this happening enough to say the addon is broken and should not be relied on.

**INSTRUCTIONS:**

In the windower console;

lua l autona -- Loads the addon

lua u autona -- Unloads the addon

--   //autona on                -- Enable the addon to cast.

--   //autona off               -- Disable the addon from casting and clear the queue.

--   //autona hud [on|off]      -- Toggle the HUD display.

--   //autona clear             -- Manually clear the casting queue in case something got stuck in queue.

--   //autona disable <status>  -- Ignore a specific status (for example; "paralysis").

--   //autona enable <status>   -- Stop ignoring a specific status.

--   //autona help              -- Display available commands.
