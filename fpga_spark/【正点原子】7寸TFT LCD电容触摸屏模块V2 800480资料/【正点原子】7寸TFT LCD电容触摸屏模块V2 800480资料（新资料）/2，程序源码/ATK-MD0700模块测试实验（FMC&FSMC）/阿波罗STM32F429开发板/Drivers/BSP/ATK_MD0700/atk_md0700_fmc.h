/**
 ****************************************************************************************************
 * @file        atk_md0700_fmc.h
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

#ifndef __ATK_MD0700_FMC_H
#define __ATK_MD0700_FMC_H

#include "./SYSTEM/sys/sys.h"

/* ATK-MD0700模块FMC接口定义 */
#define ATK_MD0700_FMC_BANK                    FMC_NORSRAM_BANK1                            /* ATK-MD0700模块所接FMC的Bank */
#define ATK_MD0700_FMC_BANK_ADDR               (0x60000000)
#define ATK_MD0700_FMC_REG_SEL                 (18)
#define ATK_MD0700_FMC_READ_AST                0x0F                                         /* 读时序的地址建立时间，单位：HCLK */
#define ATK_MD0700_FMC_READ_DST                0x46                                         /* 读时序的数据建立时间，单位：HCLK */
#define ATK_MD0700_FMC_WRITE_AST               0x04                                         /* 写时序的地址建立时间，单位：HCLK */
#define ATK_MD0700_FMC_WRITE_DST               0x04                                         /* 写时序的数据建立时间，单位：HCLK */
#define ATK_MD0700_FMC_CLK_ENABLE()            do{ __HAL_RCC_FMC_CLK_ENABLE(); }while(0)    /* ATK-MD0700模块所接FMC时钟使能 */

/* ATK-MD0700模块FMC接口读写命令、数据地址 */
#define ATK_MD0700_FMC_CMD_ADDR                (ATK_MD0700_FMC_BANK_ADDR | (((1U << ATK_MD0700_FMC_REG_SEL) - 1) << 1))
#define ATK_MD0700_FMC_DAT_ADDR                (ATK_MD0700_FMC_BANK_ADDR | ((1U << ATK_MD0700_FMC_REG_SEL) << 1))

/* ATK-MD0700模块FMC接口读写命令、数据 */
#define ATK_MD0700_FMC_CMD_REG                 (*(volatile uint16_t *)ATK_MD0700_FMC_CMD_ADDR)
#define ATK_MD0700_FMC_DAT_REG                 (*(volatile uint16_t *)ATK_MD0700_FMC_DAT_ADDR)

/* 引脚定义 */
#define ATK_MD0700_FMC_RS_GPIO_PORT             GPIOD
#define ATK_MD0700_FMC_RS_GPIO_PIN              GPIO_PIN_13
#define ATK_MD0700_FMC_RS_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_RS_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_CS_GPIO_PORT             GPIOD
#define ATK_MD0700_FMC_CS_GPIO_PIN              GPIO_PIN_7
#define ATK_MD0700_FMC_CS_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_CS_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_RD_GPIO_PORT             GPIOD
#define ATK_MD0700_FMC_RD_GPIO_PIN              GPIO_PIN_4
#define ATK_MD0700_FMC_RD_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_RD_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_WR_GPIO_PORT             GPIOD
#define ATK_MD0700_FMC_WR_GPIO_PIN              GPIO_PIN_5
#define ATK_MD0700_FMC_WR_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_WR_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D0_GPIO_PORT             GPIOD
#define ATK_MD0700_FMC_D0_GPIO_PIN              GPIO_PIN_14
#define ATK_MD0700_FMC_D0_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D0_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D1_GPIO_PORT             GPIOD
#define ATK_MD0700_FMC_D1_GPIO_PIN              GPIO_PIN_15
#define ATK_MD0700_FMC_D1_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D1_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D2_GPIO_PORT             GPIOD
#define ATK_MD0700_FMC_D2_GPIO_PIN              GPIO_PIN_0
#define ATK_MD0700_FMC_D2_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D2_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D3_GPIO_PORT             GPIOD
#define ATK_MD0700_FMC_D3_GPIO_PIN              GPIO_PIN_1
#define ATK_MD0700_FMC_D3_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D3_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D4_GPIO_PORT             GPIOE
#define ATK_MD0700_FMC_D4_GPIO_PIN              GPIO_PIN_7
#define ATK_MD0700_FMC_D4_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D4_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOE_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D5_GPIO_PORT             GPIOE
#define ATK_MD0700_FMC_D5_GPIO_PIN              GPIO_PIN_8
#define ATK_MD0700_FMC_D5_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D5_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOE_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D6_GPIO_PORT             GPIOE
#define ATK_MD0700_FMC_D6_GPIO_PIN              GPIO_PIN_9
#define ATK_MD0700_FMC_D6_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D6_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOE_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D7_GPIO_PORT             GPIOE
#define ATK_MD0700_FMC_D7_GPIO_PIN              GPIO_PIN_10
#define ATK_MD0700_FMC_D7_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D7_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOE_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D8_GPIO_PORT             GPIOE
#define ATK_MD0700_FMC_D8_GPIO_PIN              GPIO_PIN_11
#define ATK_MD0700_FMC_D8_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D8_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOE_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D9_GPIO_PORT             GPIOE
#define ATK_MD0700_FMC_D9_GPIO_PIN              GPIO_PIN_12
#define ATK_MD0700_FMC_D9_GPIO_AF               GPIO_AF12_FMC
#define ATK_MD0700_FMC_D9_GPIO_CLK_ENABLE()     do{ __HAL_RCC_GPIOE_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D10_GPIO_PORT            GPIOE
#define ATK_MD0700_FMC_D10_GPIO_PIN             GPIO_PIN_13
#define ATK_MD0700_FMC_D10_GPIO_AF              GPIO_AF12_FMC
#define ATK_MD0700_FMC_D10_GPIO_CLK_ENABLE()    do{ __HAL_RCC_GPIOE_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D11_GPIO_PORT            GPIOE
#define ATK_MD0700_FMC_D11_GPIO_PIN             GPIO_PIN_14
#define ATK_MD0700_FMC_D11_GPIO_AF              GPIO_AF12_FMC
#define ATK_MD0700_FMC_D11_GPIO_CLK_ENABLE()    do{ __HAL_RCC_GPIOE_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D12_GPIO_PORT            GPIOE
#define ATK_MD0700_FMC_D12_GPIO_PIN             GPIO_PIN_15
#define ATK_MD0700_FMC_D12_GPIO_AF              GPIO_AF12_FMC
#define ATK_MD0700_FMC_D12_GPIO_CLK_ENABLE()    do{ __HAL_RCC_GPIOE_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D13_GPIO_PORT            GPIOD
#define ATK_MD0700_FMC_D13_GPIO_PIN             GPIO_PIN_8
#define ATK_MD0700_FMC_D13_GPIO_AF              GPIO_AF12_FMC
#define ATK_MD0700_FMC_D13_GPIO_CLK_ENABLE()    do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D14_GPIO_PORT            GPIOD
#define ATK_MD0700_FMC_D14_GPIO_PIN             GPIO_PIN_9
#define ATK_MD0700_FMC_D14_GPIO_AF              GPIO_AF12_FMC
#define ATK_MD0700_FMC_D14_GPIO_CLK_ENABLE()    do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)
#define ATK_MD0700_FMC_D15_GPIO_PORT            GPIOD
#define ATK_MD0700_FMC_D15_GPIO_PIN             GPIO_PIN_10
#define ATK_MD0700_FMC_D15_GPIO_AF              GPIO_AF12_FMC
#define ATK_MD0700_FMC_D15_GPIO_CLK_ENABLE()    do{ __HAL_RCC_GPIOD_CLK_ENABLE(); }while(0)

/* 操作函数 */
void atk_md0700_fmc_init(void);                                                             /* ATK-MD0700模块FMC接口初始化 */
static inline void atk_md0700_fmc_write_cmd(volatile uint16_t cmd)                          /* ATK-MD0700模块通过FMC接口写命令 */
{
    ATK_MD0700_FMC_CMD_REG = cmd;
}
static inline void atk_md0700_fmc_write_dat(volatile uint16_t dat)                          /* ATK-MD0700模块通过FMC接口写数据 */
{
    ATK_MD0700_FMC_DAT_REG = dat;
}
static inline void atk_md0700_fmc_write_reg(volatile uint16_t reg, volatile uint16_t dat)   /* ATK-MD0700模块通过FMC接口写寄存器 */
{
    ATK_MD0700_FMC_CMD_REG = reg;
    ATK_MD0700_FMC_DAT_REG = dat;
}
static inline uint16_t atk_md0700_fmc_read_dat(void)                                        /* ATK-MD0700模块通过FMC接口读数据 */
{
    uint16_t dat;
    
    __nop();
    __nop();
    dat = ATK_MD0700_FMC_DAT_REG;
    
    return dat;
}

#endif
