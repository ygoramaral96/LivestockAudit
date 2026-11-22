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

The mod does not own claims, it audits the ones a claim system has. Two calls, in
`LivestockAuditApi.lua`:

- `LivestockAudit.record(kind, data)` (server): the claim system announces what happened
  (`claimed`, `released`, `permission`, `died`, `attacked`, `handled`, `renamed`...).
- `LivestockAudit.registerSource(src)`: the claim system answers the audit's questions
  (`isClaimed`, `claims`, `slots`, `timeoutHours`, `permissionFlags`, `isLoaded`, `playerId`; on the
  client, `claimOf`). An incomplete source is refused at registration, saying what is missing.

Register on `OnGameBoot` (server) and `OnGameStart` (client): then the order of the two mods in
`Mods=` does not matter. The full contract is the header of `LivestockAuditApi.lua`.

## Saves from before the rename

This mod used to ship as `GENZ_LivestockAudit`. On the first load, if the new ModData key
(`LivestockAudit`) is empty and the old one (`GENZ_LivestockAudit`) has data, the history is copied
across and the old key is left alone. The per-animal mark `GENZ_LA_ID` is still read when the new one
is missing.

## Layout

```
workshop.txt  preview.png
Contents/mods/LivestockAudit/
    common/
    42.21/     mod.info, media/
```

## License

Not chosen yet (see the open item in the card that created this repository).
