# TODO

## Verdict
- [x] 24-hour soak on the reference setup (2026-11-03 08:00 → 2026-11-04 08:17 UTC): no
  `diag: bad payload` line, no stack restart, Zigbee probe 2016/2016. Four isolated OpenThread
  "radio tx timeout" events, each recovered in ~50 ms (not the checksum loop). Release flag:
  switch `v2024.6.2-cpcfix.1` from pre-release to release on GitHub.
- [ ] Find the cause of the rare OpenThread "radio tx timeout" (4 in 24 h, self-recovering);
  compare with the 2026.6.x RCP.
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
- [x] Port the patch to SiSDK 2026.6.2: [patches-2026.6.2/](patches-2026.6.2/) (applies to the
  SDK root as installed by `slt`, compiles; not tested on hardware, because 2026.6.2 CPC UART builds
  are silent on this chip, see the next item).
- [ ] Port to 2025.12.x if a bisect needs it.
- [ ] Find why SiSDK 2026.6.2 CPC UART builds stay silent on EFR32MG21 (TXPEN/RXPEN ruled out).
  Biggest driver change since 2025.6.3: DMADRV → `sl_dma_manager` and emlib USART → `sl_hal_usart`.
  Prepared: [tools/diag.c](tools/diag.c), a diagnostic add-on for the 2026.6.2 sample (build with
  `DEBUG_EFM_USER` and `DEBUG_EFM` defined and `diag_report()`/`diag_tick()` called from `app_init`/
  `app_process_action`): prints the reset cause at boot, `ASSERT file:line`, `HARDFAULT`, and every 2 s
  for 60 s a snapshot of USART0, its GPIO route and all 8 LDMA channels as the CPC driver left them.
  Capture with any serial reader at 460800 8N1. Then a bisect with each SDK's own sample
  (2024.6.2 control, 2025.6.3). Results will land here.
- [ ] Build for other EFR32MG21/MG24 multi-PAN sticks (Nerivec's v2024.6.2 manifests: SkyConnect,
  Yellow, ZB-GW04, SLZB-06M/07, MGM240P, …), untested.
- [ ] Hardware-flow-control variant for sticks that wire RTS/CTS.
- [x] Report how often the guards fire: done in the 2026.6.2 port (OpenThread log stream, see
  README). Not in the 2024.6.2 build yet (that needs another flash of a working dongle).

## Project
- [ ] Release automation: check the first tag build in GitHub Actions; attach build logs.
- [ ] Test with Home Assistant's former Silicon Labs Multiprotocol add-on.
- [ ] A short migration guide from an EmberZNet NCP to zigbeed (frame counter, IEEE address).
