/**
 ****************************************************************************************************
 * @file        atk_md0700_fmc.c
 * @author      正点原子团队(ALIENTEK)
 * @version     V1.0
 * @date        2022-06-21
 * @brief       ATK-MD0700模块FMC接口驱动代码
 * @license     Copyright (c) 2020-2032, 广州市星翼电子科技有限公司
 ****************************************************************************************************
 * @attention
 *
 * 实验平台:正点原子 阿波罗 F429开发板
 * 在线视频:www.yuanzige.com
 * 技术论坛:www.openedv.com
 * 公司网址:www.alientek.com
 * 购买地址:openedv.taobao.com
 *
 ****************************************************************************************************
 */

#include "./BSP/ATK_MD0700/atk_md0700_fmc.h"

/* ATK-MD0700模块FMC句柄 */
static SRAM_HandleTypeDef g_sram_handle = {0};

/**
 * @brief       ATK-MD0700模块FMC接口初始化
 * @param       无
 * @retval      无
 */
void atk_md0700_fmc_init(void)
{
    GPIO_InitTypeDef gpio_init_struct = {0};
    FMC_NORSRAM_TimingTypeDef read_timing = {0};
    FMC_NORSRAM_TimingTypeDef write_timing = {0};
    
    /* 使能时钟 */
    ATK_MD0700_FMC_CLK_ENABLE();
    ATK_MD0700_FMC_RS_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_CS_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_RD_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_WR_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D0_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D1_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D2_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D3_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D4_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D5_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D6_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D7_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D8_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D9_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D10_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D11_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D12_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D13_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D14_GPIO_CLK_ENABLE();
    ATK_MD0700_FMC_D15_GPIO_CLK_ENABLE();
    
    /* 初始化RS引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_RS_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_RS_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_RS_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化CS引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_CS_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_CS_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_CS_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化RD引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_RD_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_RD_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_RD_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化WR引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_WR_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_WR_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_WR_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D0引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D0_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D0_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D0_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D1引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D1_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D1_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D1_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D2引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D2_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D2_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D2_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D3引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D3_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D3_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D3_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D4引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D4_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D4_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D4_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D5引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D5_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D5_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D5_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D6引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D6_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D6_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D6_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D7引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D7_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D7_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D7_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D8引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D8_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D8_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D8_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D9引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D9_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D9_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D9_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D10引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D10_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D10_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D10_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D11引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D11_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D11_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D11_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D12引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D12_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D12_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D12_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D13引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D13_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D13_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D13_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D14引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D14_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D14_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D14_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化D15引脚 */
    gpio_init_struct.Pin        = ATK_MD0700_FMC_D15_GPIO_PIN;
    gpio_init_struct.Mode       = GPIO_MODE_AF_PP;
    gpio_init_struct.Speed      = GPIO_SPEED_FREQ_HIGH;
    gpio_init_struct.Alternate  = ATK_MD0700_FMC_D15_GPIO_AF;
    HAL_GPIO_Init(ATK_MD0700_FMC_D15_GPIO_PORT, &gpio_init_struct);
    
    /* FMC配置 */
    g_sram_handle.Instance                  = FMC_NORSRAM_DEVICE;
    g_sram_handle.Extended                  = FMC_NORSRAM_EXTENDED_DEVICE;
    g_sram_handle.Init.NSBank               = ATK_MD0700_FMC_BANK;
    g_sram_handle.Init.DataAddressMux       = FMC_DATA_ADDRESS_MUX_DISABLE;
    g_sram_handle.Init.MemoryType           = FMC_MEMORY_TYPE_SRAM;
    g_sram_handle.Init.MemoryDataWidth      = FMC_NORSRAM_MEM_BUS_WIDTH_16;
    g_sram_handle.Init.BurstAccessMode      = FMC_BURST_ACCESS_MODE_DISABLE;
    g_sram_handle.Init.WaitSignalPolarity   = FMC_WAIT_SIGNAL_POLARITY_LOW;
    g_sram_handle.Init.WaitSignalActive     = FMC_WAIT_TIMING_BEFORE_WS;
    g_sram_handle.Init.WriteOperation       = FMC_WRITE_OPERATION_ENABLE;
    g_sram_handle.Init.WaitSignal           = FMC_WAIT_SIGNAL_DISABLE;
    g_sram_handle.Init.ExtendedMode         = FMC_EXTENDED_MODE_ENABLE;
    g_sram_handle.Init.AsynchronousWait     = FMC_ASYNCHRONOUS_WAIT_DISABLE;
    g_sram_handle.Init.WriteBurst           = FMC_WRITE_BURST_DISABLE;
    g_sram_handle.Init.ContinuousClock      = FMC_CONTINUOUS_CLOCK_SYNC_ONLY;
    g_sram_handle.Init.PageSize             = FMC_PAGE_SIZE_NONE;
    /* FMC读时序配置 */
    read_timing.AddressSetupTime            = ATK_MD0700_FMC_READ_AST;
    read_timing.DataSetupTime               = ATK_MD0700_FMC_READ_DST;
    read_timing.BusTurnAroundDuration       = 0;
    read_timing.AccessMode                  = FMC_ACCESS_MODE_A;
    /* FMC写时序配置 */
    write_timing.AddressSetupTime           = ATK_MD0700_FMC_WRITE_AST;
    write_timing.DataSetupTime              = ATK_MD0700_FMC_WRITE_DST;
    write_timing.BusTurnAroundDuration      = 0;
    write_timing.AccessMode                 = FMC_ACCESS_MODE_A;
    /* 初始化FMC */
    HAL_SRAM_Init(&g_sram_handle, &read_timing, &write_timing);
}
