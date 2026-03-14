# SV_Harmony_API

A file-based bridge API that extends Synthesizer V Studio's Lua scripting interface, enabling bidirectional communication between SV and external programs through a pseudo-bus (local JSON files).

## Disclaimer

**Project Scope:** This API is a wrapper for the Synthesizer V Lua scripting interface. It does not modify the Synthesizer V binary.

"SV" in this project refers to **Synthesizer V**, a product of Dreamtonics Co., Ltd. This project is an independent tool and is **not** affiliated with, sponsored by, or endorsed by Dreamtonics.

## Overview

SV_Harmony_API provides a JSON Loop IO Bridge that runs inside Synthesizer V Studio as a Lua script. It continuously exports the live project state to a JSON file and monitors a second JSON file for incoming changes from external programs. This pseudo-bus architecture allows any external tool -- written in Python, C#, Node.js, or any language -- to read, manipulate, and write back project data (notes, parameters, tracks, tempo, etc.) while SV is running.

The system is split into two scripts:

| Script | Purpose |
|--------|---------|
| **Hormony Bridge** (`HormonyBridge.lua`) | Runtime: starts the bridge loop on click. No UI dialogs. |
| **Hormony Settings** (`HormonySettings.lua`) | Configuration UI: update interval, work mode, working directory, session cleanup. Saves to `Hormony_Config.json`. |

### Why a Pseudo-Bus?

Synthesizer V's Lua scripting sandbox does not expose sockets, named pipes, or any network/IPC primitives. The only available I/O is `io.open()` for local files and `SV:setTimeout()` for scheduling. SV_Harmony_API leverages these two primitives to build a poll-based, dual-file IPC channel using the local filesystem as the communication medium.

## Architecture

```
+----------------------------+          +----------------------------+
|   Synthesizer V Studio     |          |   External Program         |
|                            |          |   (Python, C#, etc.)       |
|  +----------------------+  |          |  +----------------------+  |
|  | Hormony Bridge       |  |          |  | Reads/writes JSON    |  |
|  | (HormonyBridge.lua)  |  |          |  |                      |  |
|  +------+----------+----+  |          |  +----+-----------+-----+  |
|         |          ^        |          |       ^           |        |
+---------+----------|-------+          +-------|-----------|-------+
          |          |                          |           |
          v          |                          |           v
   {uuid}_out.json   |                          |    {uuid}_in.json
   (SV --> External)  |                          |    (External --> SV)
                      +--------------------------+

                    hormony/ working directory
                    (default: ~/Documents/Dreamtonics/Synthesizer V Studio/hormony/)
```

**Session-based file naming:** Each loop session generates a unique UUID. Bridge files are named `{uuid}_out.json` and `{uuid}_in.json` in the hormony working directory. Session metadata is tracked in `Hormony_Session.json`.

**Two bridge files prevent read/write collisions:**

| File | Direction | Writer | Reader |
|------|-----------|--------|--------|
| `{uuid}_out.json` | SV --> External | SV (every tick) | External program |
| `{uuid}_in.json` | External --> SV | External program | SV (every tick) |

The bridge uses **read/write alternating**: odd ticks export, even ticks import. The full read/write cycle is 2x the configured interval. This halves per-tick blocking time.

## Features

- **Bidirectional sync** -- export project state and import external modifications in real-time
- **Work modes** -- Full (alternating export/import), Export Only, or Import Only (configurable in Settings)
- **Session cleanup** -- stale sessions auto-detected and removable via Settings checkbox
- **SVP-compatible JSON format** -- output matches the official `.svp` file structure
- **Full project coverage** -- notes, 8 parameter curves (pitchDelta, vibratoEnv, loudness, tension, breathiness, voicing, gender, toneShift), tempo, time signatures, mixer settings, render config
- **Zero dependencies** -- includes a built-in pure-Lua JSON encoder/decoder
- **Session management** -- UUID-based sessions with auto-expiry, tracked in `Hormony_Session.json`
- **Field-level diff import** -- only modifies notes/parameters that actually changed
- **Change detection** -- only applies imports when file content actually changes
- **Configurable** -- update interval, work mode, and working directory via the Settings script
- **Localization** -- UI supports English and Simplified Chinese

## Requirements

- **Synthesizer V Studio** v1.0.1+ (some features like `getMixer()` require v2.1.1+)
- **Operating System**: Windows (fallback path uses `D:/`; path handling supports both `/` and `\`)
- No external Lua installation or libraries required

## Installation

1. Copy both scripts into your Synthesizer V Studio scripts directory:
   ```
   HormonyBridge.lua          (Hormony Bridge - runtime)
   HormonySettings.lua       (Hormony Settings - configuration)
   ```
   Place them in:
   ```
   <SV Install Dir>/scripts/
   ```
   or a subdirectory (e.g., `scripts/Utilities/`).

2. In Synthesizer V Studio, go to **Scripts > Rescan** to detect the new scripts.

## Usage

1. **Save your project** (`Ctrl+S`) before running the bridge. The script reads the `.svp` file on disk to extract voice library (database) and `systemPitchDelta` data that are not accessible through the scripting API.

2. **(Optional) Configure settings**: From the **Scripts** menu, select **Hormony Settings** to set the update interval, work mode, and working directory. Settings are saved to `Hormony_Config.json`.

   **Work modes:**
   | Mode | Behavior | Use case |
   |------|----------|----------|
   | **Full** (default) | Alternating export/import (odd tick = export, even tick = import) | Normal bidirectional workflow |
   | **Export Only** | Export every tick, no import | Read-only external tools (monitoring, analysis) |
   | **Import Only** | Import every tick, no export | One-way external control |

   > **Note:** Export Only / Import Only should only be used if the external script requires it or you know what you are doing. The default Full mode is recommended for most use cases.

3. **Start the bridge**: From the **Scripts** menu, select **Hormony Bridge**. The loop starts immediately (no dialog). The hormony working directory will be created automatically if needed.

4. **Stop the bridge**: The bridge runs until SV stops the script (e.g., closing SV, rescanning scripts, or running another script). There is no toggle mechanism -- the loop simply runs until interrupted.

5. **For external program integration**, write your tool to:
   - Read `Hormony_Session.json` to discover the active session UUID and file paths
   - **Read** `{uuid}_out.json` to get the current SV project state
   - **Write** `{uuid}_in.json` to push changes back into SV

> **WARNING: Switching .svp projects while a session is running**
>
> You **must** stop the bridge before opening or switching to a different `.svp` project. The session is bound to the project that was active when it started. If you switch projects without stopping first, the bridge will continue exporting/importing against the wrong project context. The resulting behavior is undefined -- you have been warned.

### Session Cleanup

Over time, stale sessions and orphan bridge files can accumulate in the hormony working directory. To clean them up, open **Hormony Settings** and check the **Clean Sessions** checkbox before clicking OK.

Cleanup rules:
- Sessions with `state == "stopped"` are removed immediately, along with their bridge files.
- Sessions with `state == "running"` that have not updated their heartbeat in **>60 seconds** are considered dead and removed, along with their bridge files.
- After session cleanup, all `*_out.json` / `*_in.json` files in the working directory are scanned. Any files whose UUID does not belong to a surviving session are deleted as orphans.

### Bridge File Location

Bridge files are created in the **hormony working directory**:
```
~/Documents/Dreamtonics/Synthesizer V Studio/hormony/
```
This can be overridden in Hormony Settings. The directory is created automatically on first run.

## JSON Data Format

The bridge produces JSON structurally identical to the official `.svp` format. Time values use **blicks** (1 quarter note = 705,600,000 blicks).

```json
{
  "version": 153,
  "time": {
    "meter": [{ "index": 0, "numerator": 4, "denominator": 4 }],
    "tempo": [{ "position": 0, "bpm": 120.0 }]
  },
  "tracks": [{
    "name": "Track 1",
    "mixer": { "gainDecibel": 0.0, "pan": 0.0, "mute": false, "solo": false },
    "mainGroup": {
      "notes": [{
        "onset": 0,
        "duration": 705600000,
        "pitch": 60,
        "lyrics": "la",
        "phonemes": ""
      }],
      "parameters": {
        "pitchDelta":   { "mode": "cubic", "points": [] },
        "vibratoEnv":   { "mode": "cubic", "points": [] },
        "loudness":     { "mode": "cubic", "points": [] },
        "tension":      { "mode": "cubic", "points": [] },
        "breathiness":  { "mode": "cubic", "points": [] },
        "voicing":      { "mode": "cubic", "points": [] },
        "gender":       { "mode": "cubic", "points": [] },
        "toneShift":    { "mode": "cubic", "points": [] }
      }
    }
  }],
  "renderConfig": { "sampleRate": 44100, "bitDepth": 16 }
}
```

## Known Limitations

- **Latency**: Configurable polling interval (default 1s); full cycle is 2x interval due to read/write alternating
- **Full export per tick**: The entire project is re-serialized every export cycle, not incremental deltas
- **No file locking**: An external program could theoretically read a partially-written file
- **Main group only**: Import only processes `mainGroup` of each track; additional groups are exported but not imported back
- **Voice library**: Database info is read from the saved `.svp` file, not from the live editor. Changing the voice library requires saving the project first
- **Song length**: Designed for songs up to ~10 minutes (parameter curve range covers ~3000 beats)
- **Project switching**: You must stop the session before switching `.svp` projects. Behavior is undefined otherwise

## Project Structure

```
HormonyBridge.lua          # Runtime bridge (starts loop on click, no UI)
HormonySettings.lua        # Settings UI (interval, work mode, working dir, session cleanup)
Test_Loop.lua              # Proof-of-concept file-polling loop
test_io.lua                # Basic file I/O validation test
LICENSE.txt                # ALE 1.1 + GPL v3.0 dual license
agents/                    # Development planning documents
```

## License

This project is dual-licensed under the [Anti-Labor Exploitation License 1.1](https://github.com/nickyc975/Anti-Labor-Exploitation-License) and [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html). The permissions granted under GPL v3.0 are conditional upon full compliance with ALE 1.1. See [LICENSE.txt](LICENSE.txt) for details.
