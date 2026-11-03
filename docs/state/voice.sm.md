# Kokoro voice: from download to delete

Source: src/voice.ts at the branch head. Read only.

## Requirements

- R1: Settings downloads the Kokoro voice, and the browser keeps it. — README.md:15
- R2: A failed download can be tried again. — src/panels.ts:140
- R3: Delete the Voice removes the voice from this browser. — src/panels.ts:147

## Bugs

- B1: Delete the Voice during a download leaves the voice loaded, because the download sets the voice after the delete. — tests/voice_state.test.ts fails on the branch head when the test is not marked failing

## Machine voice

initial: unloaded
final:

| state | event | guard | next | req | source |
|---|---|---|---|---|---|
| unloaded | load | | loading | R1 | src/voice.ts:54 |
| loading | load | | loading | R1 | src/voice.ts:75 |
| loading | loaded | | ready | R1 | src/voice.ts:70 |
| loading | failed | | unloaded | R2 | src/voice.ts:72 |
| loading | remove | | unloaded | R3 | src/voice.ts:86 |
| ready | load | | ready | R1 | src/voice.ts:52 |
| ready | remove | | unloaded | R3 | src/voice.ts:86 |
| unloaded | remove | | unloaded | R3 | src/voice.ts:86 |
| unloaded | loaded | | ready | | src/voice.ts:70 |
| unloaded | failed | | unloaded | R2 | src/voice.ts:72 |
| ready | loaded | | ready | | src/voice.ts:70 |
| ready | failed | | ready | R2 | src/voice.ts:72 |
