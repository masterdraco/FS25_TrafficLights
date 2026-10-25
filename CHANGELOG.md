# Changelog

## 1.0.2 (2026-10-25)
- Street lamp on the taller EU mast sits on the pole again (no gap).

## 1.0.1 (2026-10-25)
- EU masts 35 % taller: the arm with the light heads now clears tractors and trailers (`tlMastHeight` tunes it in debug mode).

## 1.0.0 (2026-10-25)
- First release candidate. Debug mode off by default (`tlDebug` toggles the overlay, `tlStatus` logs the state).
- Proven in game: AutoDrive and map traffic hold at red, 16 AD tractors without collisions, flashing amber
  on a stuck vehicle, railway clearance, US span wire/masts, stop-line adjustment, multiplayer on a dedicated server.

## 0.9.1 (2026-10-25)
- Mod description, README and Danish shop names ("Lyskryds") updated.

## 0.9.0
- Adjust stop lines on foot (Alt+T near the light): move forward/back, light on/off per approach, reset;
  outdated adjustments shown and deletable. Saved in the savegame; works in multiplayer.

## 0.8.0
- Multiplayer: the server sends the lights' layout and signals; clients build the same lights.

## 0.7.x
- Masts and stop lines keep clear of railways (no waiting on a level crossing).
- American version picks span wire (small intersections) or arm masts (large); heads hang over their own lane.
- Approaches whose AD lanes merge before the stop line get one light.
- Control box not at an AutoDrive junction: the light switches itself off with a message.
- Base-game AI driving (helpers, Courseplay's drive to the field) holds at red on maps with an AI road network.
- Log line when an intersection starts/stops flashing amber.

## 0.6.x
- American version with span wire between wooden poles; EU arm shortened.

## 0.5.x
- The building is a control box on the corner of the intersection; the intersection centre is found automatically.
- Fast vehicles are held while they can still brake; flashing-amber reminder message.

## 0.4.x and earlier
- Traffic-light logic (one green at a time, first come first served, max 4 per green), AutoDrive and map-traffic
  holds, visible masts and lamps.
