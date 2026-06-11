/* Memory layout — EDIT for your STM32 variant (datasheet "Memory mapping").
 *
 * embassy-stm32's `memory-x` feature also emits a layout derived from the
 * chip feature; this file is the explicit override and what cortex-m-rt's
 * link.x includes. Keep FLASH/RAM in sync with your actual part.
 *   F411RE → 512K flash, 128K ram      L432KC → 256K flash, 64K ram
 *   F446RE → 512K flash, 128K ram      G474RE → 512K flash, 128K ram (+32K CCM)
 */
MEMORY
{
  FLASH : ORIGIN = 0x08000000, LENGTH = {{flash_kb}}K
  RAM   : ORIGIN = 0x20000000, LENGTH = {{ram_kb}}K
}
