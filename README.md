# zbdonglee-multipan

Multi-PAN RCP firmware for the **SONOFF Zigbee 3.0 USB Dongle Plus V2 (ZBDongle-E, EFR32MG21)**:
Zigbee and Thread on one radio, through Silicon Labs' CPC protocol. It is
[Nerivec's v2024.6.2 multi-PAN build](https://github.com/Nerivec/silabs-firmware-builder/releases/tag/v2024.6.2)
(the last published one for this dongle) rebuilt with a fix for a bug that stalls the radio link
about once an hour, and a build of Silicon Labs' SiSDK 2026.6.2 multi-PAN RCP sample with the same fix
(see [SiSDK 2026.6.2 build](#sisdk-202662-build)).

> **Status: soak test passed (2026-11-04).** Running on one dongle since 2026-11-03 (Zigbee2MQTT on
> zigbeed with 28 devices, an OpenThread border router, Matter-over-Thread devices). Before the fix
> that setup stalled every ~70 minutes; over the 24-hour soak it logged no bad frame, needed no
> stack restart and answered every Zigbee probe (2016/2016). Tested on one dongle only; see
> [TODO.md](TODO.md) for the longer comparison and other sticks.
>
> **SiSDK 2026.6.2 build: soak test passed (2026-11-12)** on the same dongle and host, live since
> 2026-11-11: no bad frame, no stack restart, no radio tx timeout in 24 hours (the 2024.6.2 build logs
> about five a day), 99.9 % of Zigbee probes answered, Thread devices attached throughout.

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
SiSDK 2026.6.2; the port in [patches-2026.6.2/](patches-2026.6.2/) is in the 2026.6.2 build. The port also counts how often each guard fires and reports changes as an
OpenThread warning, which otbr-agent logs as `RCP => cpcfix: stale_completions=… double_completions=…
timer_skips=…`; this needs `OPENTHREAD_CONFIG_LOG_OUTPUT_APP` and `OPENTHREAD_CONFIG_LOG_LEVEL
OT_LOG_LEVEL_WARN`. The release build keeps the sample's default (log output off), so the counters stay
silent there; log output on together with `DEBUG_EFM` (next section) has not been tested.

## SiSDK 2026.6.2 build

Silicon Labs' own multi-PAN RCP sample from SiSDK 2026.6.2
(`openthread_app/ot-ncp/cpc/rcp-uart-802154`, "OpenThread Zigbee CMP - RCP UART"), built with
[Nerivec's builder](https://github.com/Nerivec/silabs-firmware-builder) (branch `sisdk-2026.6.x`, pinned
commit) and the stick settings from the v2024.6.2 manifest
([firmware-2026.6.2/](firmware-2026.6.2/)), plus:

- the CPC fix ported to 2026.6.2 ([patches-2026.6.2/](patches-2026.6.2/));
- `DEBUG_EFM` and `DEBUG_EFM_USER` defined. **Without them every 2026.6.2 CPC UART build stayed
  silent on this chip** (no byte on the UART at any baud rate, in every test flash); with them it
  answers. The two defines turn on the SDK's asserts and nothing else in the compiler flags; why that
  matters is still open (see [TODO.md](TODO.md));
- [firmware-2026.6.2/efmreset.c](firmware-2026.6.2/efmreset.c): the `assertEFM()` that
  `DEBUG_EFM_USER` asks for. A failed assert resets the chip, so cpcd sees a secondary reset and
  reconnects, instead of the chip hanging with interrupts off.

No BLE (the sample has none) and no CPC security: run cpcd with `disable_encryption: true`. Tested on
one dongle with the SiSDK 2026.6.2 host stack below; 24-hour soak passed 2026-11-12 (no bad frame, no
stack restart, no radio tx timeout, mean Zigbee probe latency the same as with the 2024.6.2 build), so
the asserts cost nothing measurable there.

## Download

[Releases](../../releases) have the firmware (`.gbl`) and `SHA256SUMS`. Release builds come from
GitHub Actions running `./build.sh` on the tagged commit.

| File | What |
|---|---|
| `sonoff_zbdonglee_rcp-uart-802154-blehci-sw_460800_2024.6.2-cpcfix.N.gbl` | multi-PAN RCP (802.15.4 + BLE HCI over CPC), 460800 baud, no hardware flow control; SiSDK 2024.6.2, CPC protocol v5 (secondary 4.5.0), OpenThread RCP 2.5.1. Releases `v2024.6.2-cpcfix.N` |
| `sonoff_zbdonglee_rcp-uart-802154_460800_2026.6.2-cpcfix.N.gbl` | multi-PAN RCP (802.15.4 over CPC, no BLE), 460800 baud, no hardware flow control; SiSDK 2026.6.2, CPC secondary 4.9.2, OpenThread RCP 3.1.2.0. Releases `v2026.6.2-cpcfix.N` |

Prefer the 2026.6.2 build with a SiSDK 2026.6.2 host stack (same release on both sides, and no radio tx
timeouts in its soak); the 2024.6.2 build if you need BLE.

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

Needs Docker on an x86_64 machine; everything else is downloaded inside the image. For 2024.6.2
(slc, Commander, GCC 12.2.rel1, SiSDK 2024.6.2) the downloads are checked against pinned SHA-256 sums;
for 2026.6.2 the image comes from the builder's own Dockerfile at the pinned commit (slt, GCC 14.2.1).

```bash
./build.sh                    # 2024.6.2: dist/…2024.6.2-cpcfix.N.gbl + dist/SHA256SUMS
./build.sh --stock            # the same build without patches
./build-2026.6.2.sh           # 2026.6.2: dist/…2026.6.2-cpcfix.N.gbl + dist/SHA256SUMS
./build-2026.6.2.sh --stock   # no CPC fix, no DEBUG_EFM (expect it to stay silent)
```

The 2024.6.2 project, manifest and build script come from Nerivec's builder at tag v2024.6.2 (pinned
commit). A stock build matches Nerivec's published file except for build stamps (14–16 bytes). The
2026.6.2 release is built from the same project inputs as the soak-tested file; the two differ only in
embedded name and path strings (28 bytes).

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
