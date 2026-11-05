// Diagnostic add-on for the SiSDK 2026.6.x multi-PAN RCP on the ZBDongle-E (EFR32MG21), whose
// CPC UART never answers. Writes plain text straight to USART0 (TX on PB1), bypassing CPC:
//  - "BOOT" from app_init_early(), before drivers and CPC start (UART set up here);
//  - right after CPC init (app_init_post_platform) a snapshot of the registers the driver set;
//    then a sleeptimer prints "DIAG" every 2 s for 60 s from interrupt context, so it keeps
//    reporting even if the main loop hangs later: stage reached, the snapshot ("S") and the
//    current values ("N") of USART0, its GPIO route and all 8 LDMA channels;
//  - "ASSERT <file>:<line>" for any EFM/CPC assert (built with DEBUG_EFM_USER);
//  - "HARDFAULT" with the fault status registers.
// The host captures it with fwtest-diag.sh (460800 baud, 8N1).
#include <stdbool.h>
#include <stdint.h>
#include "em_device.h"
#include "sl_sleeptimer.h"
#include "sl_clock_manager.h"
#include "sl_device_peripheral.h"
#include "sl_hal_usart.h"

#define DIAG_BAUD 460800u

static volatile uint32_t stage;  // 1 early, 2 after CPC init, 3 app_init, 4 main loop
static uint32_t snap[48];
static bool have_snap;
static sl_sleeptimer_timer_handle_t timer;

static bool diag_putc(char c)
{
  // Bounded wait: with TX disabled TXBL never comes back, and a hang here would hide everything.
  // ~22 us per character at 460800; 5000 polls is ample and keeps a dead UART from stalling the
  // firmware under test (report() also runs in interrupt context).
  for (uint32_t i = 0; i < 5000u; i++) {
    if (USART0->STATUS & USART_STATUS_TXBL) {
      USART0->TXDATA = (uint32_t)(uint8_t)c;
      return true;
    }
  }
  return false;
}

static void diag_puts(const char *s)
{
  while (*s != '\0' && diag_putc(*s)) {
    s++;
  }
}

static void diag_hex(uint32_t v)
{
  static const char digits[] = "0123456789abcdef";
  for (int shift = 28; shift >= 0; shift -= 4) {
    diag_putc(digits[(v >> shift) & 0xFu]);
  }
}

static void diag_dec(uint32_t v)
{
  char num[11];
  int n = 0;
  do {
    num[n++] = (char)('0' + (v % 10u));
    v /= 10u;
  } while (v != 0u && n < 10);
  while (n > 0) {
    diag_putc(num[--n]);
  }
}

// Register set, same order for the snapshot and the live values.
static int read_regs(uint32_t *r)
{
  int n = 0;
  r[n++] = USART0->EN;
  r[n++] = USART0->STATUS;
  r[n++] = USART0->CTRL;
  r[n++] = USART0->FRAME;
  r[n++] = USART0->CLKDIV;
  r[n++] = USART0->IEN;
  r[n++] = USART0->IF;
  r[n++] = GPIO->USARTROUTE[0].ROUTEEN;
  r[n++] = GPIO->USARTROUTE[0].RXROUTE;
  r[n++] = GPIO->USARTROUTE[0].TXROUTE;
  r[n++] = GPIO->P[1].MODEL;
  r[n++] = LDMA->EN;
  r[n++] = LDMA->CHEN;
  r[n++] = LDMA->CHDONE;
  r[n++] = LDMA->IF;
  r[n++] = LDMA->IEN;
  for (int ch = 0; ch < 8; ch++) {
    r[n++] = LDMAXBAR->CH[ch].REQSEL;
    r[n++] = LDMA->CH[ch].CTRL;
    r[n++] = LDMA->CH[ch].LINK;
    r[n++] = LDMA->CH[ch].DST;
  }
  return n;  // 48
}

static void print_regs(const char *tag, const uint32_t *r, int n)
{
  diag_puts(tag);
  for (int i = 0; i < n; i++) {
    diag_putc(i == 0 ? '=' : ' ');
    diag_hex(r[i]);
  }
  diag_puts("\r\n");
}

// Makes TX on PB1 work at DIAG_BAUD without touching what the driver configured, unless the
// driver has not configured anything yet (then set up a plain 8N1 transmitter).
static void diag_tx_ready(void)
{
  if (!(USART0->EN & USART_EN_EN) || USART0->CLKDIV == 0u) {
    uint32_t freq = 0;
    sl_clock_branch_t branch = sl_device_peripheral_get_clock_branch(SL_PERIPHERAL_USART0);
    sl_hal_usart_async_init_t init = SL_HAL_USART_INIT_ASYNC_DEFAULT;

    (void)sl_clock_manager_enable_bus_clock(SL_BUS_CLOCK_GPIO);
    (void)sl_clock_manager_get_clock_branch_frequency(branch, &freq);
    init.clock_div = sl_hal_usart_async_calculate_clock_div(freq, DIAG_BAUD, init.oversampling);
    sl_hal_usart_init_async(USART0, &init);
  }
  GPIO->P[1].MODEL = (GPIO->P[1].MODEL & ~_GPIO_P_MODEL_MODE1_MASK) | GPIO_P_MODEL_MODE1_PUSHPULL;
  GPIO->P[1].DOUT |= 1u << 1;
  GPIO->USARTROUTE[0].TXROUTE = (1u << _GPIO_USART_TXROUTE_PORT_SHIFT)  // port B
                                | (1u << _GPIO_USART_TXROUTE_PIN_SHIFT);
  GPIO->USARTROUTE[0].ROUTEEN |= GPIO_USART_ROUTEEN_TXPEN;
  USART0->EN_SET = USART_EN_EN;
  USART0->CMD = USART_CMD_TXEN;
}

// The CPC driver enables the USART0 TXC interrupt; our polled characters would set TXC with no
// CPC frame submitted and trip SLI_CPC_ASSERT(buffer_handle != NULL) in the driver's TX ISR
// (seen in test window 1, 2026-11-05). Mask TXC while we print, wait for our last character,
// clear the flag, restore the mask. Only safe while no CPC frame is in flight, which holds in
// fwtest-diag.sh: no host is connected, so the secondary never sends.
static uint32_t diag_quiet_begin(void)
{
  uint32_t txc_enabled = USART0->IEN & USART_IEN_TXC;
  USART0->IEN_CLR = USART_IEN_TXC;
  return txc_enabled;
}

static void diag_quiet_end(uint32_t txc_enabled)
{
  for (uint32_t i = 0; i < 20000u && !(USART0->STATUS & USART_STATUS_TXC); i++) {
  }
  USART0->IF_CLR = USART_IF_TXC;
  if (txc_enabled) {
    USART0->IEN_SET = USART_IEN_TXC;
  }
}

static void report(uint32_t ms)
{
  uint32_t now[48];
  int n = read_regs(now);
  uint32_t quiet = diag_quiet_begin();

  diag_tx_ready();
  if (!diag_putc('\n')) {
    diag_quiet_end(quiet);
    return;  // TX dead: give up this report instead of polling 48 registers' worth of characters
  }
  diag_puts("\r\nDIAG ms=");
  diag_dec(ms);
  diag_puts(" stage=");
  diag_dec(stage);
  diag_puts("\r\n");
  if (have_snap) {
    print_regs("S", snap, n);
  }
  print_regs("N", now, n);
  diag_quiet_end(quiet);
}

static void on_timer(sl_sleeptimer_timer_handle_t *handle, void *data)
{
  (void)data;
  uint64_t ms = 0;
  (void)sl_sleeptimer_tick64_to_ms(sl_sleeptimer_get_tick_count64(), &ms);
  report((uint32_t)ms);
  if (ms > 60000u) {
    (void)sl_sleeptimer_stop_timer(handle);
  }
}

void app_init_early(void)
{
  stage = 1;
  diag_tx_ready();  // before CPC init: TXC is not enabled yet, no masking needed
  // Repeated BOOT lines without DIAG = a reset loop (OpenThread's fault handlers reset).
  diag_puts("\r\nBOOT rstcause=");
  diag_hex(EMU->RSTCAUSE);
  diag_puts("\r\n");
  // The sleeptimer already runs here: report even if init hangs before CPC is up.
  (void)sl_sleeptimer_start_periodic_timer_ms(&timer, 2000, on_timer, NULL, 0, 0);
}

void app_init_post_platform(void)
{
  stage = 2;
  (void)read_regs(snap);
  have_snap = true;
}

// Called from app_init() and app_process_action() (patched into app.c by the build script).
void diag_report(unsigned long where)
{
  if (stage < 3) {
    stage = 3;
  }
  (void)where;
}

void diag_tick(void)
{
  stage = 4;
}

// With DEBUG_EFM_USER the SDK's assertEFM() is not built; EFM_ASSERT and SLI_CPC_ASSERT land here.
void assertEFM(const char *file, int line)
{
  __disable_irq();
  for (;;) {
    diag_tx_ready();
    diag_puts("\r\nASSERT ");
    diag_puts(file);
    diag_putc(':');
    diag_dec((uint32_t)line);
    diag_puts(" stage=");
    diag_dec(stage);
    diag_puts("\r\n");
    for (volatile uint32_t i = 0; i < 4000000u; i++) {
    }
  }
}

void HardFault_Handler(void)
{
  __disable_irq();
  for (;;) {
    diag_tx_ready();
    diag_puts("\r\nHARDFAULT stage=");
    diag_dec(stage);
    diag_puts(" CFSR=");
    diag_hex(SCB->CFSR);
    diag_puts(" HFSR=");
    diag_hex(SCB->HFSR);
    diag_puts(" BFAR=");
    diag_hex(SCB->BFAR);
    diag_puts(" MMFAR=");
    diag_hex(SCB->MMFAR);
    diag_puts("\r\n");
    for (volatile uint32_t i = 0; i < 4000000u; i++) {
    }
  }
}
