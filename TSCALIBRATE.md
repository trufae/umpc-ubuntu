# Touchscreen Calibration on Wayland

This image targets GNOME Wayland, so the old Xorg tools are usually the wrong
path for touchscreen calibration.

Do not rely on:

```bash
xinput
xinput_calibrator
```

On Wayland these either do nothing useful for native applications, or only touch
the Xwayland compatibility layer.

## Recommended tool

Use the `libinput` snap. It includes a small graphical calibration helper named
`libinput.calibrate-touchscreen`.

```bash
sudo snap install libinput
sudo libinput.list-devices
libinput.calibrate-touchscreen
```

The calibrator shows touch targets on screen and prints a six-value calibration
matrix:

```text
Calibration = A, B, C, D, E, F
```

The values must be persisted through a udev rule as `LIBINPUT_CALIBRATION_MATRIX`.

## Persistent fix

For the installed system, edit:

```text
/etc/udev/rules.d/99-gpd-pocket-touch.rules
```

For the image build, edit:

```text
data/99-gpd-pocket-touch.rules
```

Use this format:

```text
ACTION=="add|change", KERNEL=="event[0-9]*", ATTRS{name}=="Goodix Capacitive TouchScreen", ENV{LIBINPUT_CALIBRATION_MATRIX}="A B C D E F"
```

Replace `A B C D E F` with the matrix printed by
`libinput.calibrate-touchscreen`.

Then reload udev:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger -s input
```

Log out and back in, or reboot. libinput reads this property when the device is
added.

## Rotation-only fixes

If the touchscreen is not imprecise but simply rotated relative to the display,
try the known libinput rotation matrices first.

Default/no transform:

```text
1 0 0 0 1 0
```

90 degrees clockwise:

```text
0 -1 1 1 0 0
```

180 degrees clockwise:

```text
-1 0 1 0 -1 1
```

270 degrees clockwise:

```text
0 1 0 -1 0 1
```

The current GPD Pocket rule in this repository uses the 270-degree clockwise
matrix:

```text
0 1 0 -1 0 1
```

If touches are rotated the opposite way, try:

```text
0 -1 1 1 0 0
```

## Verify the active device

Find the touchscreen event node:

```bash
sudo libinput.list-devices
```

Then inspect its udev properties, replacing `eventX`:

```bash
udevadm info -q property -n /dev/input/eventX | grep -E 'NAME|ID_INPUT_TOUCHSCREEN|LIBINPUT_CALIBRATION_MATRIX'
```

After applying the rule and rebooting, `LIBINPUT_CALIBRATION_MATRIX` should show
up in the device properties and `sudo libinput.list-devices` should report a
non-identity calibration for the touchscreen.

## GNOME monitor mapping

GNOME has an internal setting to map a touchscreen to a specific monitor, but it
is not exposed in GNOME Settings yet. This is useful for multi-monitor setups,
but it is not a replacement for calibration.

The setting is a relocatable GSettings schema:

```bash
gsettings set org.gnome.desktop.peripherals.touchscreen:/org/gnome/desktop/peripherals/touchscreens/VENDOR:PRODUCT/ output "['MONITOR_VENDOR', 'MONITOR_PRODUCT', 'MONITOR_SERIAL']"
```

The monitor values come from:

```text
~/.config/monitors.xml
```

For the internal GPD Pocket panel, the udev/libinput calibration matrix is the
more relevant fix.

## References

- libinput udev calibration matrix documentation:
  https://wayland.freedesktop.org/libinput/doc/1.25.0/device-configuration-via-udev.html
- Canonical touchscreen calibration flow:
  https://canonical.com/mir/docs/2.17/how-to/how-to-calibrate-a-touchscreen-device/
- Snap package for libinput tools:
  https://snapcraft.io/libinput
- GNOME touchscreen output mapping note:
  https://who-t.blogspot.com/2024/03/enforcing-touchscreen-mapping-in-gnome.html
