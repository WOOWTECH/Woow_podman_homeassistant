# Hardware: USB radios, Bluetooth and the time zone

Every hardware setting lives in `~/.config/homeassistant/homeassistant.env`. Change the file and
re-run `scripts/install.sh`; it renders the settings into the unit and restarts Home Assistant
only when the unit file actually changed.

Back to [README](../README.md).

## Zigbee / Thread / Z-Wave sticks

Always identify a stick by its stable `/dev/serial/by-id/` path. `/dev/ttyACM0` and `/dev/ttyUSB0`
are assigned in plug order and change after a reboot or a re-plug.

```bash
ls -l /dev/serial/by-id/
# usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_20230803153503-if00 -> ../../ttyACM0
```

```ini
HA_ZIGBEE_DEVICE=/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_20230803153503-if00
HA_ZIGBEE_TARGET=/dev/ttyACM0
```

- `HA_ZIGBEE_DEVICE` is the host path. Empty means no stick is passed.
- `HA_ZIGBEE_TARGET` is the path Home Assistant sees inside the container. **It must match the
  serial port in the ZHA or Z-Wave JS config entry**, which is stored in `.storage` and is not
  changed by this repo.
- `HA_EXTRA_DEVICES` passes more nodes, space separated, each `host[:container[:perms]]`:

```ini
HA_EXTRA_DEVICES=/dev/ttyUSB0:/dev/ttyUSB0:rwm /dev/video0
```

`scripts/install.sh` refuses to install when a configured device does not exist or does not
resolve to a character device.

## Privileged or not

```ini
HA_PRIVILEGED=true     # PodmanArgs=--privileged      (default, upstream parity)
HA_PRIVILEGED=false    # PodmanArgs=--group-add=keep-groups + AddDevice= per device
```

`true` is what the upstream Home Assistant container documentation assumes: every host device
node is visible inside the container. `false` passes only the devices you list and keeps your
supplementary groups (`keep-groups`), so the container process stays in `dialout` and can open
the stick. With `false` you need read/write access to the device on the host — group membership
or a udev rule. `install.sh` warns when the node is not readable and writable by you.

### Finding F2: `--device` is ignored while `--privileged` is set

Under rootless podman 4.9.3, `--device host:container` mappings are silently dropped when
`--privileged` is also set. Home Assistant then sees the **host** node name, not the mapped one.
So with `HA_PRIVILEGED=true`:

- the rendered `AddDevice=` line is inert, and the unit says so in a comment;
- `install.sh` requires `readlink -f "$HA_ZIGBEE_DEVICE"` to equal `HA_ZIGBEE_TARGET` exactly, and
  aborts otherwise, because otherwise the ZHA entry would point at a path that does not exist in
  the container.

If the by-id link resolves to `/dev/ttyACM1` after a re-plug, either set
`HA_ZIGBEE_TARGET=/dev/ttyACM1` and change the ZHA entry to match, or set `HA_PRIVILEGED=false`,
which makes the mapping real and pins the in-container path for good.

## Bluetooth

```ini
HA_BLUETOOTH=true
```

This mounts `/run/dbus` read-only into the container so the Bluetooth integration can talk to the
host's BlueZ. BlueZ itself stays on the host; nothing is installed in the container.

## Known rootless limits (finding F3)

With rootless podman and host networking, two capabilities cannot be granted, with or without
`--privileged`, because the network namespace is the host's and the process is unprivileged:

- **DHCP discovery.** `aiodhcpwatcher` logs `Cannot watch for dhcp packets: [Errno 1]`. Integrations
  that discover devices from DHCP traffic will not find new devices; they still work when you add
  the device by IP or host name.
- **Bluetooth adapter recovery.** `habluetooth` logs `Missing NET_ADMIN/NET_RAW`. Normal scanning
  works through BlueZ; automatic recovery of a wedged adapter does not. Power-cycle the adapter or
  restart `bluetooth.service` on the host instead.

Adding `AddCapability=NET_ADMIN` or `NET_RAW` does not help and is deliberately not in the unit.
The only fix is a rootful container, which this repo does not support.

## Time zone

```ini
HA_TZ=local          # follow the host's /etc/localtime  (renders Timezone=local)
HA_TZ=Asia/Taipei    # pin an IANA name                  (renders Timezone=Asia/Taipei)
HA_TZ=               # no Timezone= at all: the container runs in UTC
```

The container's time zone only affects log timestamps and anything a custom component does with a
naive `datetime.now()`. Home Assistant's own time zone is set in the UI and stored in `.storage`.
Change `HA_TZ` on its own day and watch schedule-driven custom components afterwards.

## Stopping Home Assistant

The unit has `Restart=always`, so calling the `homeassistant.stop` service from inside Home
Assistant **restarts** it a few seconds later instead of leaving it down. To really stop it:

```bash
systemctl --user stop homeassistant.service
```

Stops are graceful: the container gets 300 s (`PodmanArgs=--stop-timeout=300`), which the image's
s6 supervisor needs to flush the recorder.

## See also

- [docs/matter.md](matter.md) - the optional Matter server
- [docs/postgres.md](postgres.md) - the optional PostgreSQL recorder
- [docs/reverse-proxy.md](reverse-proxy.md) - Cloudflare tunnel and Nginx Proxy Manager
- [docs/migrating.md](migrating.md) - adopting an existing hand-made deployment
