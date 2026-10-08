# Rafiq

The desktop companion for the Rafiq robot: a menu bar app on macOS and a
tray app on Windows. The robot's own firmware lives in
[nexus-face](https://github.com/AhmadMahi/nexus-face).

Twelve tiles in four rows: quick phrases, focus, follow the pointer,
relax, clipboard, breaks, reminders, on a break, camera and mic, robot
updates, deep sleep, and robot settings.

## 4.0: Bluetooth first

Since firmware 6.0 the robot lives on Bluetooth, so the Mac app now reaches
it there first (CoreBluetooth, firmware 7.2 or newer), with no address to
type. macOS asks once to pair. WiFi by address still works, for the times
the robot is on WiFi and for the features that still need it.

| Over Bluetooth | Still needs the robot on WiFi |
|---|---|
| Say something, phrases, Timer, Away, Find, Relax, Zikr, Sync, Sleep, restart, update, brightness, face | Follow the pointer, Gestures, canvas, reminder lists, on a break, camera and mic light, networks |

The second column moves to Bluetooth when the firmware gains the channels
for it (event, pointer and request channels, planned for firmware 7.4).

The header shows the robot's battery, the timer and Away. The Mac tells
the robot who it is, so it appears by name in the robot's Devices list
and can be chosen as Second.

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
