# Livestock Audit

An audit trail for animals in Project Zomboid (Build 42).

The server records what happens to each animal: claim, release, death with its cause, pregnancy,
birth, growth, critical hunger or thirst, leaving or entering a pen. Staff read it in the Admin Panel
("Animal Events", "Animal Claims"); owners read the history of their own animals in the Check Zone
window, at the detail their Animal Care level allows. Changes nothing on its own.

## Requirements

- Build 42 (the mod folder is `42.21`).
- Nothing else. Animals nobody owns are followed inside pens with the vanilla engine alone; the boot
  line in the server console says `claim source: none`.

## For claim mods: the API

The mod does not own claims, it audits the ones a claim system has. Three calls, in
`LivestockAuditApi.lua`:

- `LivestockAudit.record(kind, data)` (server): the claim system announces what happened
  (`claimed`, `released`, `permission`, `died`, `attacked`, `handled`, `renamed`...).
- `LivestockAudit.registerSource(src)`: the claim system answers the audit's questions
  (`playerId`, `animalId`, `isClaimed`, `claims`, `slots`, `timeoutHours`, `permissionFlags`,
  `isLoaded`; on the client, `claimOf` and, optionally, `actionModule`: the network module of the
  claim server that takes the staff actions of the claims window). An incomplete source is refused
  at registration, saying what is missing.
- `LivestockAudit.migrateHistory(opts)` (server, `OnInitGlobalModData`): a claim mod hands over a
  history it kept under another ModData key, and renames words already stored to the ones this mod
  reads.

Register on `OnGameBoot` (server) and `OnGameStart` (client): then the order of the two mods in
`Mods=` does not matter. The full contract is the header of `LivestockAuditApi.lua`.

## Layout

```
workshop.txt  preview.png
Contents/mods/LivestockAudit/
    common/
    42.21/     mod.info, media/
```

## License

[![Mod permissions: Ask for permission](http://projectzomboid.com/images/MODS_03.png)](http://theindiestone.com/forums/index.php/topic/2530-mod-permissions/?p=36478)

**Ask for permission** (The Indie Stone mod permissions badge): the code and art made for this mod are mine. The source is public so you can read it, but reusing it, changing it, re-uploading it or putting it in a modpack needs my permission first. Ask in the Workshop comments or open an issue here.
