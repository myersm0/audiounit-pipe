# midi-audio-streamer

## Introduction
A Swift application that loads and runs MIDI software instruments on macOS. Exposes the real-time audio buffer stream over a named pipe, allowing an external application (minimal example shown at the end of this readme) to capture and handle the raw audio data.

Optionally, if your VST is by Modartt (i.e. Pianoteq or Organteq), you can monitor a JSON-RPC server to track your instrument's parameter changes and update in real-time.

## Requirements
- macOS 13.0+
- Swift 5.9+
- A software instrument (like Pianoteq, Organteq, or Apple's built-in synthesizers)
- A MIDI keyboard or controller

## Setup and installation

### Building
```bash
git clone https://github.com/myersm0/midi-audio-streamer
cd midi-audio-streamer
swift build -c release
```
The executable will be created at `.build/release/AudioUnitHost`.

### Finding your instrument codes
To run the application, you need to find the 4-character subtype and manufacturer codes for your software instrument:

1. List all available instruments:
   ```bash
   auval -a | grep aumu
   ```

2. The format is: `aumu SUBTYPE MANUFACTURER`
   - `aumu` means it's a software instrument
   - `SUBTYPE` is exactly 4 characters (pad with spaces if needed)
   - `MANUFACTURER` is exactly 4 characters

3. Examples:
   - Apple DLS Synth: `aumu    dls     appl` → `--subtype "dls " --manufacturer "appl"`
   - Pianoteq 9: `--subtype "Pt9q" --manufacturer "Mdrt"`
   - Organteq 2: `--subtype "Orgq" --manufacturer "Mdrt"`

## Usage

### Basic usage
```bash
# With Apple's built-in DLS synth
./AudioUnitHost --subtype "dls " --manufacturer "appl"

# With Pianoteq 9
./AudioUnitHost --subtype "Pt9q" --manufacturer "Mdrt"

# With verbose output
./AudioUnitHost --subtype "Pt9q" --manufacturer "Mdrt" --verbose

# With UVI Workstation, restoring a saved instrument state
./AudioUnitHost --subtype "UVIW" --manufacturer "UVI " \
  --preset ~/Library/Audio/Presets/UVI/UVIWorkstation/my-test-preset.aupreset

# With velocity remapping through a lookup table
./AudioUnitHost --subtype "UVIW" --manufacturer "UVI " \
  --preset ~/Library/Audio/Presets/UVI/UVIWorkstation/my-test-preset.aupreset \
  --velocity-table ~/velocity_tables/current.json
```

### State restore from .aupreset
Since the host runs the audio unit without a UI, plugins that need configuration (which instrument to load, internal settings) can be restored from a standard `.aupreset` file via `--preset`. To produce one: host the plugin in any AU host with a UI (AU Lab, Logic, Reaper), configure it, and use the plugin window's preset menu ("Save Preset As..."), which writes to `~/Library/Audio/Presets/MANUFACTURER/PLUGIN/`. The host warns if the preset's subtype/manufacturer codes don't match the loaded audio unit. Sample-based instruments may stream content for several seconds after restore before rendering sound.

### Velocity remapping
`--velocity-table PATH` remaps note-on velocities through a per-note lookup table before they reach the instrument. The file is JSON:

```json
{
  "metadata": { "description": "free-form, ignored by the host" },
  "table": [ "... 128 rows (one per MIDI note 0-127), each 128 integers (one output velocity per input velocity) ..." ]
}
```

Semantics: `table[note][velocity_in] = velocity_out`. Entry 0 of each row is unused (velocity 0 is a note-off by MIDI convention and passes through untouched, as do note-offs, control changes, and all other message types); outputs are clamped to 1–127 so a mapping can never turn a note-on into a note-off. The file is polled for modification every 0.5 s and hot-reloaded, so an external process can rewrite it (atomically: write temp file, then rename) and hear the change on the next keystroke. If a reload fails to parse, the previous table is kept and a warning is printed.

### With JSON-RPC monitoring
To monitor parameter changes from Pianoteq or Organteq's GUI:

1. Start Pianoteq with JSON-RPC server:
   ```bash
    /Applications/Pianoteq\ 9/Pianoteq\ 9.app/Contents/MacOS/Pianoteq\ 9 --serve ""
   ```

2. In another terminal, run the audio streamer with RPC enabled:
   ```bash
   ./.build/release/AudioUnitHost --subtype "Pt9q" --manufacturer "Mdrt" --enable-rpc
   ```

3. Changes you make in the Pianoteq GUI will be logged to stdout:
   ```
   [RPC] Parameter changed: Output Volume = -6.0 dB (id: output_volume)
   [RPC] Preset changed to: NY Steinway D
   [RPC] Preset reset to saved state
   ```

### Advanced usage
```bash
# Custom TCP host and port for audio streaming
./.build/release/AudioUnitHost -s "Pt9q" -m "Mdrt" -h "192.168.1.100" -p 8888

# Use planar format for better memory contiguity in per-channel processing
# (for stereo, output will be e.g. LLRR instead of LRLR)
./.build/release/AudioUnitHost -s "Pt9q" -m "Mdrt" --format planar

# Custom buffer size and RPC polling interval
./.build/release/AudioUnitHost -s "Pt9q" -m "Mdrt" --enable-rpc \
  --buffer-size 1024 \
  --rpc-poll-interval 0.3

# Connect to RPC server on different host/port
./.build/release/AudioUnitHost -s "Pt9q" -m "Mdrt" --enable-rpc \
  --rpc-host "127.0.0.1" \
  --rpc-port 8082
```

## Command line options

### Required
- `-s, --subtype SUBTYPE` - Software instrument identifier (e.g., "Pt9q")
- `-m, --manufacturer MANUFACTURER` - Software instrument manufacturer code (e.g., "Mdrt")

### Optional - audio streaming
- `-v, --verbose` - Enable verbose logging
- `-p, --port PORT` - TCP port for audio streaming (default: 9999)
- `-h, --host HOST` - TCP host for audio streaming (default: 127.0.0.1)
- `--buffer-size SIZE` - Audio buffer size in frames (default: 512)
- `--format FORMAT` - Audio output format: 'planar' or 'interleaved' (default: interleaved)
- `--preset PATH` - Restore audio unit state from an `.aupreset` file
- `--velocity-table PATH` - Remap note-on velocities via a JSON lookup table (hot-reloaded on change)

### Optional - JSON-RPC monitoring
- `--enable-rpc` - Enable JSON-RPC parameter monitoring
- `--rpc-host HOST` - JSON-RPC server host (default: 127.0.0.1)
- `--rpc-port PORT` - JSON-RPC server port (default: 8081)
- `--rpc-poll-interval SECONDS` - How often to check for parameter changes (default: 0.5)


### Example third-party client
Here's a minimal client in the Julia language to listen to and process the audio buffer that this swift app serves:
```julia
const sample_rate = 44100
const channel_count = 2
const frames_per_block = 512

# for interleaved format (default)
const samples_per_block = frames_per_block * channel_count
const bytes_per_block = samples_per_block * sizeof(Float32)

pipe_path = "/tmp/audio_pipe"
pipe = open(pipe_path, "r")
println("Reading audio data...")

while true
	data = read(pipe, bytes_per_block)
	interleaved = reinterpret(Float32, data)
	
	# deinterleave: LRLRLR... -> L, R
	left = interleaved[1:channel_count:end]
	right = interleaved[2:channel_count:end]
	
	max_left = maximum(abs.(left))
	max_right = maximum(abs.(right))
	println("L: $max_left, R: $max_right")
end
```

For planar format (--format planar), the data is already separated by channel:
```julia
while true
	data = read(pipe, bytes_per_block)
	floats = reinterpret(Float32, data)
	
	# channels are contiguous: LLL...RRR...
	left = floats[1:frames_per_block]
	right = floats[frames_per_block+1:2*frames_per_block]
	
	# or equivalently: 
    channels = reshape(floats, frames_per_block, channel_count)
end
```

