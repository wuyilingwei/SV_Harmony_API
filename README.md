# SV_Harmony_API

A file-based bridge API that extends Synthesizer V Studio's Lua scripting interface, enabling bidirectional communication between SV and external programs through a pseudo-bus (local JSON files).

## Disclaimer

**Project Scope:** This API is a wrapper for the Synthesizer V Lua scripting interface. It does not modify the Synthesizer V binary.

"SV" in this project refers to **Synthesizer V**, a product of Dreamtonics Co., Ltd. This project is an independent tool and is **not** affiliated with, sponsored by, or endorsed by Dreamtonics.

## Overview

SV_Harmony_API provides a JSON Loop IO Bridge that runs inside Synthesizer V Studio as a Lua script. It continuously exports the live project state to a JSON file and monitors a second JSON file for incoming changes from external programs. This pseudo-bus architecture allows any external tool -- written in Python, C#, Node.js, or any language -- to read, manipulate, and write back project data (notes, parameters, tracks, tempo, etc.) while SV is running.

### Why a Pseudo-Bus?

Synthesizer V's Lua scripting sandbox does not expose sockets, named pipes, or any network/IPC primitives. The only available I/O is `io.open()` for local files and `SV:setTimeout()` for scheduling. SV_Harmony_API leverages these two primitives to build a poll-based, dual-file IPC channel using the local filesystem as the communication medium.

## Architecture

```
+----------------------------+          +----------------------------+
|   Synthesizer V Studio     |          |   External Program         |
|                            |          |   (Python, C#, etc.)       |
|  +----------------------+  |          |  +----------------------+  |
|  | SVPJsonLoopIOBridge   |  |          |  | Reads/writes JSON    |  |
|  | (Lua script)          |  |          |  |                      |  |
|  +------+----------+----+  |          |  +----+-----------+-----+  |
|         |          ^        |          |       ^           |        |
+---------+----------|-------+          +-------|-----------|-------+
          |          |                          |           |
          v          |                          |           v
   bridge_out.json   |                          |    bridge_in.json
   (SV --> External) |                          |    (External --> SV)
                     +--------------------------+
```

**Two bridge files prevent read/write collisions:**

| File | Direction | Writer | Reader |
|------|-----------|--------|--------|
| `bridge_out.json` | SV --> External | SV (every tick) | External program |
| `bridge_in.json` | External --> SV | External program | SV (every tick) |

The bridge polls every 1000ms. On each tick it exports the full project state and checks `bridge_in.json` for changes (via string comparison against a cache) to avoid feedback loops.

## Features

- **Bidirectional sync** -- export project state and import external modifications in real-time
- **SVP-compatible JSON format** -- output matches the official `.svp` file structure
- **Full project coverage** -- notes, 8 parameter curves (pitchDelta, vibratoEnv, loudness, tension, breathiness, voicing, gender, toneShift), tempo, time signatures, mixer settings, render config
- **Zero dependencies** -- includes a built-in pure-Lua JSON encoder/decoder
- **Three operating modes** -- Loop Mode (continuous), one-shot Export, one-shot Import
- **Change detection** -- only applies imports when file content actually changes
- **Localization** -- UI supports English and Simplified Chinese

## Requirements

- **Synthesizer V Studio** v1.0.1+ (some features like `getMixer()` require v2.1.1+)
- **Operating System**: Windows (fallback path uses `D:/`; path handling supports both `/` and `\`)
- No external Lua installation or libraries required

## Installation

1. Copy `SVPJsonLoopIOBridge.lua` into your Synthesizer V Studio scripts directory:
   ```
   <SV Install Dir>/scripts/
   ```
   or a subdirectory (e.g., `scripts/Utilities/`).

2. In Synthesizer V Studio, go to **Scripts > Rescan** to detect the new script.

## Usage

1. **Save your project** (`Ctrl+S`) before running the bridge. The script reads the `.svp` file on disk to extract voice library (database) and `systemPitchDelta` data that are not accessible through the scripting API.

2. From the **Scripts** menu, select **JSON Loop IO Bridge** (category: IO).

3. Choose an operating mode:

   | Mode | Behavior |
   |------|----------|
   | **Start Loop Mode** | Continuously exports project state and monitors for external changes. Runs until you stop scripts in SV. |
   | **Export to JSON** | One-shot export to `bridge_out.json`. |
   | **Import from JSON** | One-shot import from `bridge_in.json`. |

4. **For external program integration**, write your tool to:
   - **Read** `bridge_out.json` to get the current SV project state
   - **Write** `bridge_in.json` to push changes back into SV

### Bridge File Location

Bridge files are created in the same directory as the saved `.svp` project file. If the project is unsaved or the path is not writable (e.g., Unicode path issues), files fall back to `D:/`.

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

- **Latency**: 1-second polling interval; changes are reflected with up to 1s delay
- **Full export per tick**: The entire project is re-serialized every cycle, not incremental deltas
- **Import overwrites**: Import replaces all notes in the main group; no merge/diff logic
- **No file locking**: An external program could theoretically read a partially-written file
- **Main group only**: Import only processes `mainGroup` of each track; additional groups are exported but not imported back
- **Voice library**: Database info is read from the saved `.svp` file, not from the live editor. Changing the voice library requires saving the project first

## Project Structure

```
SVPJsonLoopIOBridge.lua    # Core bridge script
Test_Loop.lua              # Proof-of-concept file-polling loop
test_io.lua                # Basic file I/O validation test
LICENSE.txt                # ALE 1.1 + GPL v3.0 dual license
agents/                    # Development planning documents
```

## License

This project is dual-licensed under the [Anti-Labor Exploitation License 1.1](https://github.com/nickyc975/Anti-Labor-Exploitation-License) and [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html). The permissions granted under GPL v3.0 are conditional upon full compliance with ALE 1.1. See [LICENSE.txt](LICENSE.txt) for details.
