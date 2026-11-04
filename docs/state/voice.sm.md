# Kokoro voice: from download to delete

Source: src/voice.ts at the branch head. Read only.

## Requirements

- R1: Settings downloads the Kokoro voice, and the browser keeps it. (README.md:15)
- R2: After a failed download, you can try again. (src/panels.ts:140)
- R3: Delete the Voice removes the voice from this browser. (src/panels.ts:147)

## Fixed

- B1: Delete the Voice during a download cancels the download, so the voice stays removed. (tests/voice_state.test.ts)

## Machine voice

initial: unloaded
final:

| state | event | guard | next | req | source |
|---|---|---|---|---|---|
| unloaded | load | | loading | R1 | src/voice.ts:56 |
| loading | load | | loading | R1 | src/voice.ts:78 |
| loading | loaded | | ready | R1 | src/voice.ts:74 |
| loading | failed | | unloaded | R2 | src/voice.ts:76 |
| loading | remove | | unloaded | R3 | src/voice.ts:90 |
| ready | load | | ready | R1 | src/voice.ts:53 |
| ready | remove | | unloaded | R3 | src/voice.ts:90 |
| unloaded | remove | | unloaded | R3 | src/voice.ts:90 |
| unloaded | loaded | | unloaded | R3 | src/voice.ts:73 |
| unloaded | failed | | unloaded | R2 | src/voice.ts:76 |
| ready | loaded | | ready | | src/voice.ts:73 |
| ready | failed | | ready | R2 | src/voice.ts:76 |
