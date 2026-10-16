# Worktime v0.1 — macOS native MVP

A lightweight, local-only time tracker. SwiftUI menu bar app + draggable always-on-top floating timer (8px status dot), foreground application and window-title tracking, idle detection, local JSON persistence, daily application/window report, CSV export.

## Requirements
- macOS 14+ (Apple Silicon or Intel)
- Xcode 15+ (Swift 5.9+)

## Run
1. Install Xcode from Apple and launch it once to accept its license.
2. Open Terminal and navigate to the `Worktime` folder.
3. Run `swift run Worktime` (or open `Package.swift` in Xcode and select the `Worktime` executable scheme).
4. Click the Worktime menu bar icon to open the menu and show the floating timer.
5. Click the small circle on the floating timer to start/stop. Drag the pill to reposition it. Use **Activity report…** to view statistics.
6. To capture window titles, grant Accessibility permission under **System Settings → Privacy & Security → Accessibility**. Without it, tracking works at the app level and titles show as `Untitled window`.

## How time is counted
- Checks input idle time once per second (keyboard, mouse motion/clicks and scrolling).
- Default idle threshold is 60 seconds; counted time stops after that, and resumes automatically after activity.
- Sleep/lock and unusually long timer gaps do not count.
- Each interval is assigned to the previously observed foreground app/window; daily totals split at midnight.
- Turning tracking off preserves prior data; the toggle state persists across launches.

## Data & privacy
- Data stored at `~/Library/Application Support/Worktime/activity.json`.
- No keystroke content, screenshots, mouse positions, or web-page body are captured.
- Window titles may contain sensitive document names. Keep the JSON and exported CSV private.
- Delete the JSON file while Worktime is stopped to clear history.

## Current MVP limitations / next validation
- Source has **not been compiled or tested on macOS** in this environment. Xcode build and macOS permission testing are required.
- The floating panel is initialized when the menu is first opened, not necessarily immediately at login.
- It does not yet provide a dedicated preferences control for hiding individual apps, automatic launch at login, an hourly timeline, or a weekly chart.
- macOS privacy and app behavior may prevent retrieving certain window titles.
- To create a distributable `.app`, build/sign/package in Xcode on a Mac. `swift run` is the development path.
