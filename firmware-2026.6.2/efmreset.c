// Add-on for the SiSDK 2026.6.2 multi-PAN RCP on the ZBDongle-E (EFR32MG21). That build only
// answers the host when DEBUG_EFM and DEBUG_EFM_USER are defined (cause still open, see TODO.md),
// and DEBUG_EFM_USER needs an application assertEFM(). Here a failed assert resets the chip instead
// of hanging with interrupts off, so the host (cpcd) sees a secondary reset and reconnects; a hang
// would keep the radio dead until the dongle is unplugged. No UART, no timers.
#include "em_device.h"

void assertEFM(const char *file, int line)
{
  (void)file;
  (void)line;
  NVIC_SystemReset();
}
