# TODO

## Verdict
- [ ] 24-hour soak on the reference setup (from 2026-11-03 08:00 UTC) with no
  `diag: bad payload` line. One `RCP failure detected` in the first minute after a start is
  normal. Then drop "experimental" and the pre-release flag.
- [ ] Longer run (7 days): compare Zigbee reliability with plain EmberZNet NCP firmware.

## Upstream
- [ ] Report to Silicon Labs: the CPC secondary resend timer (`re_transmit_timeout_callback`) relies
  on a compiled-out `EFM_ASSERT`, and `NcpCPC::HandleSendDone` zeroes a buffer CPC may still send.
  Include the frame dump from docs/root-cause.md.
- [ ] Offer the host patch's loop detection to cpc-daemon (exit or reset after N identical
  checksum rejects instead of looping forever).
- [ ] Let Nerivec/silabs-firmware-builder know: their v2024.6.2 multi-PAN builds for other sticks
  likely have the same bug.

## Firmware
- [ ] Port the patch to SiSDK 2025.12.x and 2026.6.x (the same code is there).
- [ ] Find why SiSDK 2026.6.2 CPC UART builds stay silent on EFR32MG21 (TXPEN/RXPEN ruled out).
  Needs a debugger (SWD pads on the ZBDongle-E) or UART logging on a spare pin.
- [ ] Build for other EFR32MG21/MG24 multi-PAN sticks (Nerivec's v2024.6.2 manifests: SkyConnect,
  Yellow, ZB-GW04, SLZB-06M/07, MGM240P, …), untested.
- [ ] Hardware-flow-control variant for sticks that wire RTS/CTS.
- [ ] Optional: report how often the guards fire (a CPC debug counter readable from the host).

## Project
- [ ] Release automation: check the first tag build in GitHub Actions; attach build logs.
- [ ] Test with Home Assistant's former Silicon Labs Multiprotocol add-on.
- [ ] A short migration guide from an EmberZNet NCP to zigbeed (frame counter, IEEE address).
