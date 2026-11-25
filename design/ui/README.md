# Design backup

A 2x PNG of every artboard in the Paper file "OpenRig — Canvas prototype" (file `01M7P253KBMTNSBCBX3V1CRWRB`), exported 2026-11-19 (`7-review-decisions/` on 2026-11-21, `8-toolbar-on-resize/` on 2026-11-22, `9-menu-bar-icon/` and `10-wire-labels/` on 2026-11-23), plus its design tokens. The Paper file is the source; this is a snapshot.

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
| `9-menu-bar-icon/` | Menu bar icon · options: the mark at menu bar size, then three ways to say something needs you. Picked (file names end in `-picked`): A, a count beside the mark, and a hollow centre seat for the canary |
| `10-wire-labels/` | Wire labels in a pod · options: the overview, today's problem (a card hides the label), then three options. A (the label hangs beside its wire, over the pod's border) is built; file name ends in `-picked` |
| `11-ios-remote/` | The iPhone app, one board per question. Boards 1 to 4 are from "iOS remote · options" and boards 5 and 6 from "iOS remote · options 2", exported 2026-11-23 and 2026-11-24. Picks: 1B a tab bar; 2A every question on one page; 3B an explainer before the scanner; 4A a Phone tab in the Mac's Settings; 5A a prompt on its own screen; 6B a Rigs tab, rigs first |

`tokens.css` holds the file's tokens. In Paper, font tokens don't resolve inside `font-family`, so boards set the family by name.
