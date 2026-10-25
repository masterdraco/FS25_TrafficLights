# FS25 Traffic Lights

Traffic lights for Farming Simulator 25 intersections. Only one approach gets green at a time, so AutoDrive
vehicles and the map's own traffic never lock each other up in the middle of a crossing.

## How it works

- Buy a **control box** in the build menu (*Traffic Light (European)* or *(American)*) and place it on a
  corner of the intersection. The mod finds the intersection from the AutoDrive network next to the box.
- Stop lines are set back far enough for long trailers to turn, never on a railway crossing.
- An empty intersection gives green at once; first come, first served; at most 4 vehicles per green while
  others wait. If a vehicle gets stuck inside for 60 s the light switches to flashing amber (everyone may
  drive) and you get a message; it returns to normal by itself.
- **European**: an arm mast at each stop line. **American**: lights hanging on a span wire over small
  intersections, arm masts at large ones.
- To move a light: place a new box, then sell the old one (FS25 cannot move buildings).

## Who stops

| | |
|---|---|
| AutoDrive | holds at the stop line |
| Map traffic | holds at the stop line |
| Base-game helpers and Courseplay's drive to the field | hold on maps with an AI road network |

AutoDrive is required (the intersection is found from its network). Courseplay is optional.

## Adjusting stop lines

Stand near a traffic light and press **Alt+T**:

| Key | |
|---|---|
| Alt+T | open/close the view |
| Alt+J | next approach |
| Alt+I / Alt+K | move stop line forward / back (0.5 m) |
| Alt+U | light on/off for this approach |
| Alt+R | reset (on "outdated": delete outdated adjustments) |

Adjustments are saved with the savegame. Keys can be changed in the game's controls menu.

## Multiplayer

The server runs the lights; clients see the same lights and signals.

## Development

Pure logic is tested with LuaJIT: `bash tests/run_all.sh`. `./build.sh --install` builds the zip and installs
it (only when the game is not running).
