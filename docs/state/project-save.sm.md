# Project text: from edit to storage

Source: src/app.ts at the branch head. Read only.

## Requirements

- R1: A project stays in the storage of the browser. (README.md:23)
- R2: The app saves an edit after a short pause, and when another project opens. (src/app.ts:321)
- R3: When a save fails, the current project stays open with the edit, and the next save tries again. (src/app.ts:179)

## Fixed

- B1: A save that fails keeps the text dirty, and the project switch stops. Thus the edit stays when each save fails. (tests/project_save.test.ts)

## Machine save

initial: clean
final:

| state | event | guard | next | req | source |
|---|---|---|---|---|---|
| clean | edit | | dirty | R2 | src/app.ts:331 |
| dirty | edit | | dirty | R2 | src/app.ts:331 |
| dirty | pause | | saving | R2 | src/app.ts:341 |
| dirty | open_other | | saving | R2 | src/app.ts:179 |
| clean | open_other | | clean | R2 | src/app.ts:179 |
| saving | saved | | clean | R1 | src/app.ts:349 |
| saving | save_failed | | dirty | R3 | src/app.ts:351 |
| saving | edit | | dirty | R2 | src/app.ts:331 |
| saving | open_other | | saving | R2 | src/app.ts:179 |
| clean | pause | | clean | R2 | src/app.ts:346 |
| clean | saved | | clean | | src/app.ts:349 |
| dirty | saved | | dirty | | src/app.ts:349 |
| clean | save_failed | | clean | | src/app.ts:351 |
| dirty | save_failed | | dirty | | src/app.ts:351 |
| saving | pause | | saving | R2 | src/app.ts:341 |
