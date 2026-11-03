# Project text: from edit to storage

Source: src/app.ts at the branch head. Read only.

## Requirements

- R1: A project stays in the storage of the browser. — README.md:23
- R2: An edit is saved after a short pause, and when another project opens. — src/app.ts:317

## Bugs

- B1: A save that fails is not tried again, so the edit is lost when the project opens again. — tests/project_save.test.ts fails on the branch head when the test is not marked failing

## Machine save

initial: clean
final:

| state | event | guard | next | req | source |
|---|---|---|---|---|---|
| clean | edit | | dirty | R2 | src/app.ts:327 |
| dirty | edit | | dirty | R2 | src/app.ts:327 |
| dirty | pause | | saving | R2 | src/app.ts:338 |
| dirty | open_other | | saving | R2 | src/app.ts:178 |
| clean | open_other | | clean | R2 | src/app.ts:178 |
| saving | saved | | clean | R1 | src/app.ts:344 |
| saving | save_failed | | clean | | src/app.ts:345 |
| saving | edit | | dirty | R2 | src/app.ts:327 |
| saving | open_other | | saving | R2 | src/app.ts:178 |
| clean | pause | | clean | R2 | src/app.ts:341 |
| clean | saved | | clean | | src/app.ts:344 |
| dirty | saved | | dirty | | src/app.ts:344 |
| clean | save_failed | | clean | | src/app.ts:345 |
| dirty | save_failed | | dirty | | src/app.ts:345 |
| saving | pause | | saving | R2 | src/app.ts:338 |
