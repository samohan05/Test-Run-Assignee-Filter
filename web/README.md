# web/ — Assignment & Execution Board frontend assets

| File | Authored by | Deploys to | SHA-256 |
|---|---|---|---|
| `executeRunWidget.html` | This customization | `<CB_WEBAPP>/custom/` | `de4006a01bd415f3d9a9176def65fe51eaf570c78cb6051297964578499deb89` |
| `extension.json` | This customization | Your site's configured `externalWidgetExtensions` location | `0c7052ecbd19757892331bc3906afe5d4802ab59e12bbb658357c2960f4f3399` |
| `cb-widget-api.js` | **Codebeamer (PTC) — vendor dependency, pinned here for reproducible deploys** | `<CB_WEBAPP>/custom/`, beside the HTML | `c850cfecd57cdea928fe826ed8e85376783895ee161ebfc9aa57feea7e7dc53d` |
| `menuitem_submenuindicator.png` | Codebeamer (PTC) — stock icon, reused as a placeholder | `<CB_WEBAPP>/custom/` | `b88ce5d706c0449acf7c6815ae5383e33b6535ffe9fce2f13dfab0ba08586adb` |

`cb-widget-api.js` and the icon are **not** written by this project — they are copies of files
already present on a live Codebeamer 3.2.0.2 install, pinned here so a deploy doesn't depend
on assuming they already exist in a clean installation (the implementation guide explicitly
recommends this: "package the known-working file explicitly; do not assume
`/cb/custom/cb-widget-api.js` exists in a clean installation"). Do not modify
`cb-widget-api.js`; if your own site's copy differs (a Codebeamer upgrade shipped a new
bundle), prefer *your site's* copy and re-record its hash here rather than overwriting it with
this one.

`executeRunWidget.html` embeds its own build marker as the `VER` constant near the top of its
`<script>` block (currently `18.4.4-parent-guard-r5.1-20260928`) and in `extension.json`'s
`viewUrl` query string (`?v=18.4.4`). Keep these in sync, and bump both whenever the HTML
changes — see `DEPLOYMENT-RUNBOOK.md` §6.

`extension.json` here targets `philips-execute-run-widget` as an `itemDetailsWidgets` entry
scoped to Test Run items (`"enabled": "${type == 'Testrun'}"`). Replace the `localhost:8080`
host in `viewUrl`/`iconUrl` with your own site's URL before publishing.
