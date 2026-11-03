# Root cause: the hourly CPC checksum loop

Setup where it was found (2026-11-02/03): ZBDongle-E (EFR32MG21, Gecko bootloader 1.12.0) on
Nerivec's v2024.6.2 multi-PAN RCP; host on an arm64 board with Silicon Labs' SiSDK 2026.6.2
packages (cpcd 4.8.0, zigbeed 9.1.1 for Zigbee2MQTT, otbr-agent 3.1.1); UART 460800 baud without
flow control; about 28 Zigbee devices and one Thread device on channel 20.

## Symptom

After 1–3 hours of normal operation, cpcd started logging this about every 3 ms:

```
Host received a packet with an invalid checksum on ep 12
```

Endpoint 12 is the 802.15.4 (spinel) endpoint that both zigbeed and otbr-agent use. Both lost
the radio (`RCP failure detected` every 2 s from otbr-agent), so Zigbee and Thread were down until
the host stack restarted. Overnight that happened at 02:24, 03:45, 04:56 and 07:27 UTC, each time
66–72 minutes after the previous restart. No USB or kernel events at the same times.

## Why it is not the serial line

A frame corrupted on the wire is rejected once, and the resend gets through. Here the same frame
failed every time, thousands of times in a row. The corrupt bytes were therefore in the dongle's
memory, not on the line.

## Evidence

cpc-daemon 4.8.0 was rebuilt with a patch (`host/cpcd-4.8.0-checksum-loop.patch`) that dumps a
frame that fails its checksum. At the next stall:

```
diag: bad payload #1 ep 12 seq 4 expected 4 len 45 fcs rx 833e calc 0000 hdr 140c2f0047ba50
      payload 0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003e83
```

- The 43-byte payload is all zeros, but the checksum sent with it (`833e`) is that of real data.
- The previous good frame was sequence 3, also 45 bytes; the host was still waiting for sequence
  4 (`expected 4`), so frame 4 never arrived intact.
- Every later resend in that episode was identical (the dump repeats every 1000th: `#1000`, `#2000`, …).

## Mechanism

In the SiSDK CPC secondary (`platform/service/cpc/src/sl_cpc.c`):

- `sl_cpc_write()` does not copy data. It links the caller's buffer into the frame and computes
  the payload checksum once (`frame_handle->fcs = sli_cpc_get_crc_sw(data, data_length)`).
- On a checksum reject from the host, `receive_sframe()` resends the head of the resend queue at
  once (`re_transmit_frame`). Nothing limits these resends; the retry limit applies only to the
  resend timer.

In OpenThread's CPC transport on the dongle
(`protocol/openthread/platform-abstraction/ncp/ncp_cpc.cpp`):

- One buffer, `mCpcTxBuffer`, is used for every write; `mIsWriting` guards it.
- `HandleSendDone()`, the write-complete callback, clears `mIsWriting` and runs
  `memset(mCpcTxBuffer, 0, sizeof(mCpcTxBuffer))`. That is the only place that zeroes the buffer.

So CPC reported a write as complete while frame 4 was still queued or being resent: either a
late or second completion for frame 3, or an early one for frame 4. `HandleSendDone` zeroed the
buffer; frame 4 went out with zeros and its old checksum, forever.

Which CPC path produces that completion is not proven (there was no debugger on the dongle). The
most likely one is the resend timer. `re_transmit_timeout_callback()` pops the head of the resend
queue and checks that it is its own frame only with `EFM_ASSERT`, which is compiled out in
release builds. A timer that fires late, for example while a resend after a reject is still in the
UART driver, or after its frame was already acknowledged, can therefore take the wrong frame, or one
the driver still owns, off the queue. One frame can then be completed twice, and the handle can be
freed and reused while it is still queued. The comments in `process_expired_retransmit()` already
admit that an acknowledgement racing a resend "is not handled".

The same `NcpCPC` and CPC code is unchanged in SiSDK 2026.6.2.

## Fix

`patches/sisdk-2024.6.2-cpc-stale-completion.patch`, every change marked `cpcfix:`:

1. `NcpCPC` increments a write token before it claims the buffer, passes it as the completion
   argument of `sl_cpc_write`, and ignores any completion whose argument is not the current
   token. It no longer zeroes the buffer, which nothing needed.
2. `re_transmit_timeout_callback` puts the popped frame back and does nothing when it is not the
   timer's frame or the UART driver still holds it (`ref_count > 0` after the pop). The driver's
   transmit-complete handler re-arms the timer for that frame.
3. `submit_write_completion` completes a frame only once (`write_completion_submitted`).

Known gap: if a frame handle is freed and handed to the next write before a stray completion
arrives, the token check sees the current token and cannot tell. The host patch covers that case:
cpcd exits after ~6 s of a checksum loop so the stack restarts in about a minute.

## Also seen, unrelated

Every build with the SiSDK **2026.6.2** CPC UART driver stayed silent on this chip, even the
working OpenThread RCP project with only its transport switched to CPC, while an SiSDK 2026.6.2
OpenThread RCP (HDLC transport) answered at once. That driver sets only `TXPEN` in `USARTROUTE`,
not `RXPEN`; the 2024.6.2 driver does the same and works, and adding `RXPEN` did not help, so the
hang has another cause. See [TODO.md](../TODO.md).
