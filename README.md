# zbdonglee-multipan

Multi-PAN RCP firmware for the **SONOFF Zigbee 3.0 USB Dongle Plus V2 (ZBDongle-E, EFR32MG21)**:
Zigbee and Thread on one radio, through Silicon Labs' CPC protocol. It is
[Nerivec's v2024.6.2 multi-PAN build](https://github.com/Nerivec/silabs-firmware-builder/releases/tag/v2024.6.2)
(the last published one for this dongle) rebuilt with a fix for a bug that stalls the radio link
about once an hour.

> **Status: soak test passed (2026-11-04).** Running on one dongle since 2026-11-03 (Zigbee2MQTT on
> zigbeed with 28 devices, an OpenThread border router, Matter-over-Thread devices). Before the fix
> that setup stalled every ~70 minutes; over the 24-hour soak it logged no bad frame, needed no
> stack restart and answered every Zigbee probe (2016/2016). Tested on one dongle only; see
> [TODO.md](TODO.md) for the longer comparison and other sticks.

## The bug it fixes

With the stock firmware, cpcd on the host suddenly logs this every few milliseconds:

```
WARNING in function 'transmit_reject' in file ./server_core/core/core.c at line #1707 :
  Host received a packet with an invalid checksum on ep 12
```

and otbr-agent and zigbeed lose the radio (`P-RadioSpinel-: RCP failure detected`,
`Wait for response timeout`). Nothing recovers until the host stack is restarted, which also
resets the dongle.

Cause, found with a cpcd that dumps the rejected frame: the dongle keeps resending a frame whose
payload has been overwritten with zeros after its checksum was computed. CPC sends straight from
the caller's buffer. OpenThread's CPC transport (`NcpCPC`) zeroes that buffer whenever CPC
reports a write as complete, and CPC sometimes reports a completion late, or twice, while the
next frame is already in that buffer. The dongle then resends a frame that can never pass the
host's checksum, with no retry limit. The full analysis is in
[docs/root-cause.md](docs/root-cause.md).

The fix ([patches/](patches/)): `NcpCPC` tags each write and ignores completions for any other
write (and no longer zeroes the buffer); CPC's resend timer no longer takes a frame it does not
own off the queue; a frame is completed only once. The same CPC and `NcpCPC` code is still in
SiSDK 2026.6.2; a port is in [patches-2026.6.2/](patches-2026.6.2/) (untested on hardware, see
[TODO.md](TODO.md)).

## Download

[Releases](../../releases) have the firmware (`.gbl`) and `SHA256SUMS`. Release builds come from
GitHub Actions running `./build.sh` on the tagged commit.

| File | What |
|---|---|
| `sonoff_zbdonglee_rcp-uart-802154-blehci-sw_460800_2024.6.2-cpcfix.N.gbl` | multi-PAN RCP (802.15.4 + BLE HCI over CPC), 460800 baud, no hardware flow control |

Versions inside: SiSDK 2024.6.2, CPC protocol v5 (secondary 4.5.0), OpenThread RCP 2.5.1.

## Flashing

The dongle's Gecko bootloader accepts it like any other `.gbl`. With
[universal-silabs-flasher](https://github.com/NabuCasa/universal-silabs-flasher) (stop whatever
uses the port first: Zigbee2MQTT, ZHA or the multi-PAN host stack):

```bash
DEV=/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_<serial>-if00
docker run --rm --device "$DEV:/dev/zigbee" -v "$PWD:/fw:ro" python:3.12-slim sh -c '
  pip install -q universal-silabs-flasher &&
  universal-silabs-flasher --device /dev/zigbee \
    --probe-methods ezsp:115200,cpc:460800,spinel:460800,bootloader:115200 \
    flash --firmware /fw/sonoff_zbdonglee_rcp-uart-802154-blehci-sw_460800_2024.6.2-cpcfix.1.gbl'
```

If the firmware on the dongle does not answer any probe, add `--bootloader-reset rts_dtr`: the
ZBDongle-E enters its bootloader through the RTS/DTR lines. Going back: flash Nerivec's original
or SONOFF's NCP firmware the same way.

**Replacing another multi-PAN RCP** (e.g. Nerivec's 2024.6.2): a drop-in swap. The Zigbee and
Thread networks live on the host (zigbeed and otbr-agent state), not on the dongle.

**Coming from an EmberZNet NCP** (plain Zigbee firmware): the Zigbee network moves from the dongle
to zigbeed on the host. That is a migration, not a firmware swap: back up first, and read up on
moving a network to zigbeed (frame counter, coordinator IEEE address) before you flash.

## Host side

Tested with Silicon Labs' SiSDK 2026.6.2 Debian packages
([sisdk-release](https://github.com/SiliconLabsSoftware/sisdk-release), arm64 bookworm): cpcd
4.8.0 (accepts protocol v5), zigbeed 9.1.1 (EmberZNet 9.1.1, EZSP 19, works with Zigbee2MQTT's
`ember` adapter over TCP) and otbr-agent 3.1.1. cpcd settings:

```yaml
bus_type: UART
uart_device_baud: 460800
uart_hardflow: false
disable_encryption: true   # the firmware has no CPC security component
```

Not tested yet: Home Assistant's former Silicon Labs Multiprotocol add-on, other host versions.

**Optional host patch** ([host/cpcd-4.8.0-checksum-loop.patch](host/cpcd-4.8.0-checksum-loop.patch),
for cpc-daemon v4.8.0): logs the frame that fails its checksum and the last good one, logs only a
few warnings per episode instead of hundreds of thousands, and exits after 2000 bad frames in a
row (~6 s) so a supervisor can restart the stack. Useful with any firmware; it is how this bug was
found.

## Building

Needs Docker on an x86_64 machine; everything else (slc, Commander, GCC 12.2.rel1, SiSDK 2024.6.2)
is downloaded inside the image and checked against pinned SHA-256 sums.

```bash
./build.sh            # dist/…-cpcfix.N.gbl + dist/SHA256SUMS
./build.sh --stock    # the same build without patches
```

The project, manifest and build script come from Nerivec's builder at tag v2024.6.2 (pinned
commit). A stock build matches Nerivec's published file except for build stamps (14–16 bytes).

## Credits

- [Nerivec/silabs-firmware-builder](https://github.com/Nerivec/silabs-firmware-builder): the
  ZBDongle-E multi-PAN project, manifest and build tooling this is built from.
- [NabuCasa/silabs-firmware-builder](https://github.com/NabuCasa/silabs-firmware-builder), which that
  builder derives from.
- Silicon Labs: Simplicity SDK, CPC, the multi-PAN RCP.

## License

- Scripts and documentation: [MIT](LICENSE).
- [patches/](patches/) modify Silicon Labs files licensed under Zlib; the patches are under the
  same Zlib terms and mark every change with `cpcfix:`. [host/](host/) modifies cpc-daemon
  (Zlib) the same way.
- Released firmware is built from the Silicon Labs Simplicity SDK and contains components under
  Silicon Labs' own licenses (the Master Software License Agreement for parts of the radio and
  Zigbee stacks); see [NOTICE](NOTICE). It is meant for use with Silicon Labs devices.
