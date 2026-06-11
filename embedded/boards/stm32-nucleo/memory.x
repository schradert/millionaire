/* Memory layout for the STM32F411RE on Nucleo-F411RE.
 *
 * Update FLASH and RAM origin/length for your specific chip. See the
 * "Memory mapping" section of the datasheet for your STM32 variant.
 *   F411RE → 512K flash, 128K ram
 *   F446RE → 512K flash, 128K ram
 *   L432KC → 256K flash, 64K ram
 *   G474RE → 512K flash, 128K ram (32k CCM)
 *   H743ZI → 2M flash, 512K DTCM + ~864K AXI ram (more complex)
 */

MEMORY
{
  FLASH : ORIGIN = 0x08000000, LENGTH = 512K
  RAM   : ORIGIN = 0x20000000, LENGTH = 128K
}
