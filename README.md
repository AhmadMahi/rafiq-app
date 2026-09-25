# Rafiq

The desktop companion for the Rafiq robot: a menu bar app on macOS and a
tray app on Windows. The robot's own firmware lives in
[nexus-face](https://github.com/AhmadMahi/nexus-face).

Twelve tiles in four rows: quick phrases, focus, follow the pointer,
relax, clipboard, breaks, reminders, on a break, camera and mic, robot
updates, deep sleep, and robot settings.

## Getting it

**macOS** (14 or newer, Apple silicon): download the `.dmg`, drag Rafiq
across, and **right-click then Open** the first time. It is ad hoc
signed rather than notarised, so a plain double click is blocked once.

**Windows** (10 or 11, Intel or ARM): download the zip for your machine,
right-click it, Properties, tick **Unblock**, extract it anywhere, and
run `Rafiq.exe`. Nothing needs installing first.

Both update themselves after that: Settings, then Check.

## Pairing

Set the robot's address, then Pair. Six digits appear on the robot's
panel and you type them in. After that only this machine can drive it,
which closes a door that was open before: anyone on the same network
could post to the device.

## Layout

    mac/        SwiftUI, built with the Command Line Tools alone
    windows/    C# on .NET 8 WinForms, built and tested on a real runner

## Releases

    mac-vX.Y.Z      the macOS app
    win-vX.Y.Z      the Windows app

Separate prefixes so neither can be mistaken for the other, or for the
firmware's own `vX.Y.Z` tags in the other repository. That mix-up is
exactly why these moved out.
