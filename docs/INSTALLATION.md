# Installing BunnyBar

BunnyBar is a standard WoW addon folder. All you need to do is put the `BunnyBar` folder in WoW Forever's `Interface/AddOns` directory.

## 1. Download

Get `BunnyBar-<version>.zip` from <https://github.com/aivarnit/BunnyBar/releases/latest>.

The ZIP contains a single folder:

```text
BunnyBar/
├── BunnyBar.toc
├── Util.lua
├── Config.lua
├── Appearance.lua
├── Placement.lua
├── Animation.lua
├── Ears.lua
├── Options.lua
├── Core.lua
├── LICENSE.txt
└── Textures/
    ├── bunny-ears.tga
    ├── bunny-hop.tga
    ├── bunny-icon.tga
    ├── bunny-idle.tga
    ├── bunny-land.tga
    ├── bunny-sleep.tga
    ├── bunny-sleepy.tga
    └── bunny-wake.tga
```

## 2. Find your AddOns folder

WoW Forever has its own game folder, `_forever_`, next to `_retail_` and `_classic_era_` inside your World of Warcraft installation.

> The `_forever_` name comes from add-on manager and community guides around the 4 November 2026 launch. If your install has a different folder, use whichever one contains `Wow.exe` (Windows) or `World of Warcraft.app` for Forever. During the beta it was `_classic_beta_`.

**Shortcut:** open the Battle.net launcher, choose **WoW Forever** in the game version dropdown, then go to the ⚙️ gear menu and click **Show in Explorer** (Windows) or **Show in Finder** (macOS). This opens the game folder.

### Windows

Default path:

```text
C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\
```

1. Open File Explorer and go to `…\World of Warcraft\_forever_\`.
2. If there's no `Interface` folder, or no `AddOns` folder inside it, create them. The names are case-sensitive in some tools, so use exactly `Interface` and `AddOns`.
3. Right-click the downloaded ZIP and choose **Extract All…**, then extract into the `AddOns` folder.
4. Check that you have `…\Interface\AddOns\BunnyBar\BunnyBar.toc`. If you see `AddOns\BunnyBar-0.2.0\BunnyBar\…`, move the inner `BunnyBar` folder up one level.

### macOS (Apple Silicon or Intel)

Default path:

```text
/Applications/World of Warcraft/_forever_/Interface/AddOns/
```

1. In Finder, press **⇧⌘G** and paste `/Applications/World of Warcraft/_forever_/`.
2. Create `Interface/AddOns` if it doesn't exist.
3. Double-click the ZIP in Downloads. Safari usually extracts it automatically.
4. Drag the `BunnyBar` folder into `AddOns`.
5. Check that `…/Interface/AddOns/BunnyBar/BunnyBar.toc` exists.

From Terminal:

```sh
cd "/Applications/World of Warcraft/_forever_/Interface/AddOns" \
  && unzip -o ~/Downloads/BunnyBar-*.zip
```

## 3. Enable it

1. **Fully restart** the game client. `/reload` often doesn't detect a newly added addon folder.
2. On the character select screen, click **AddOns** (bottom left).
3. Make sure **BunnyBar** is ticked.
4. If it shows as *Out of date*, a client patch has raised the interface number. Tick **Load out of date AddOns** and check for a BunnyBar update.
5. Log in. A small bunny should appear just above your action bar. Type `/bunny` for help.

## Updating

Delete the old `AddOns/BunnyBar` folder and extract the new ZIP. Your settings live separately in `WTF/Account/<ACCOUNT>/SavedVariables/BunnyBar.lua` and are kept.

## Uninstalling

Delete `AddOns/BunnyBar`. To remove saved settings as well, delete `WTF/Account/<ACCOUNT>/SavedVariables/BunnyBar.lua` (and its `.bak`).

## Troubleshooting

| Problem | Fix |
|---|---|
| Not in the AddOns list | Check the folder nesting (`AddOns/BunnyBar/BunnyBar.toc`), then fully restart the client. |
| Listed as out of date | Tick **Load out of date AddOns**. |
| No bunny visible | Type `/bunny show`, then `/bunny reset`. |
| Bunny is in a strange place | Type `/bunny unlock`, drag the blue track, then `/bunny lock`. Or use `/bunny reset`. |
| Lua error on login | Please [open an issue](https://github.com/aivarnit/BunnyBar/issues) with the error text, your client build (shown at the login screen) and your OS. |
