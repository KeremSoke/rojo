# rojo

Rojo is MATE's color management daemon, or at least will be one day.

Today it does Night Light and gamma, and it works the same on the X session and the Wayland (hopefully) session. 

It started as a replacement of `redshift` and `redshift-gtk` as the backend of the Night Light settings dialog I coded, since redshift and redshift-gtk can randomly be sketcy. Color management (colord profiles and calibration) is planned to live here too, so everything that touches the screen's gamma ramps stays in one process.

D-Bus name `org.mate.rojo`; Night Light is the interface `org.mate.rojo.NightLight`.

One long-running service owns the screen's color, decides what it should be, and is controlled over D-Bus. Only the last step, writing gamma ramps, depends on the display server. It uses Vala mainly for everything except gamma settings for X server and Wayland.

## What it does

- Automatic schedule from sunset to sunrise, or fixed times; without a location, automatic falls back to the fixed times.
- Sun times from the NOAA formulas.
- "Disable until tomorrow": `DeactivateUntil(0)` lasts until the next night is over.
- Smooth changes instead of jumps, and the sunrise/sunset times exposed for the UI.
- The last known coordinates are cached.
- Separate day and night temperatures, a transition length, and an always-on mode.
- Overrides, kept across restarts: `ActivateUntil`, `ActivateManual`, `DeactivateUntil`, `DeactivateManual`.
- Reference-counted `Inhibit`, released automatically when the caller leaves the bus. `Toggle` is meant for a keyboard shortcut.
- `Preview` for settings dialogs, which ends by itself after 15 s.
- Quick animated adjustment for big changes and slow stepping along the schedule.
- Clock-skew handling: timers are re-armed when the wall clock jumps. Resume from suspend is handled immediately through logind.
- Rich state for UIs: current and target temperature, daylight, previous and next transition times and lengths.

MATE has no GeoClue agent, so GeoClue refuses unknown programs, as it does
for Redshift. The build installs `/etc/geoclue/conf.d/rojo.conf`
to allow the daemon (`-Dgeoclue_conf=false` to skip it).
