# Design backup

A 2x PNG of every artboard in the Paper file "OpenRig — Canvas prototype" (file `01M7P253KBMTNSBCBX3V1CRWRB`), exported 2026-11-19 (`7-review-decisions/` on 2026-11-21, `8-toolbar-on-resize/` on 2026-11-22), plus its design tokens. The Paper file is the source; this is a snapshot.

| Folder | Paper page |
|---|---|
| `1-starter-rig-canvas/` | Starter · Rig canvas: the main window (canvas, queue board, terminals, terminals in Type mode) and inline action states |
| `2-remaining-items-options/` | Remaining items · options: answering options, which rig has something for you, queue search, closed-row wording |
| `3-wiring-explorations/` | Wiring explorations: four wire styles for the canvas |
| `4-settings-window/` | Settings window: the four tabs and the States board |
| `5-style-guide/` | Style guide |
| `6-rig-controls/` | Rig controls · options (2026-11-20): status, stop, stopped rig, start progress, a seat down. The picked variant on each board is marked "picked" |
| `7-review-decisions/` | Review 2026-11-20 · decisions: canvas jump on a prompt, what orange means, queue wording, how long Sent stays, Go to by name, app icon, Help menu, shrinking with the inspector open |
| `8-toolbar-on-resize/` | Toolbar on resize · options: the overview, then each option as a wide and a narrow window. A (icons at every width) is built; C (view tabs in the content) is to investigate |

`tokens.css` holds the file's tokens. In Paper, font tokens don't resolve inside `font-family`, so boards set the family by name.
