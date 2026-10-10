/**
 ****************************************************************************************************
 * @file        atk_md0700_touch_ftxx.c
 * @author      正点原子团队(ALIENTEK)
 * @version     V1.0
 * @date        2022-06-21
 * @brief       ATK-MD0700模块触摸驱动代码（FTXX）
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

#include "./BSP/ATK_MD0700/atk_md0700_touch.h"
#include "./BSP/ATK_MD0700/atk_md0700_touch_iic.h"
#include "./SYSTEM/delay/delay.h"
#include <string.h>

#if (ATK_MD0700_USING_TOUCH != 0)

/* ATK-MD0700模块最大触摸点数量 */
#define ATK_MD0700_TOUCH_TP_MAX                 5

/* ATK-MD0700模块触摸部分寄存器定义 */
#define ATK_MD0700_TOUCH_REG_DEVIDE_MODE        0x00    /* 设备模式控制寄存器 */
#define ATK_MD0700_TOUCH_REG_ID_G_MODE          0xA4    /* 中断模式控制寄存器 */
#define ATK_MD0700_TOUCH_REG_ID_G_THGROUP       0x80    /* 有效触摸阈值配置寄存器 */
#define ATK_MD0700_TOUCH_REG_ID_G_PERIODACTIVE  0x88    /* 激活周期配置寄存器 */
#define ATK_MD0700_TOUCH_REG_TD_STATUS          0x02    /* 触摸状态寄存器 */
#define ATK_MD0700_TOUCH_REG_TP1                0x03    /* 触摸点1数据寄存器 */
#define ATK_MD0700_TOUCH_REG_TP2                0x09    /* 触摸点2数据寄存器 */
#define ATK_MD0700_TOUCH_REG_TP3                0x0F    /* 触摸点3数据寄存器 */
#define ATK_MD0700_TOUCH_REG_TP4                0x15    /* 触摸点4数据寄存器 */
#define ATK_MD0700_TOUCH_REG_TP5                0x1B    /* 触摸点5数据寄存器 */

/* 触摸状态寄存器掩码 */
#define ATK_MD0700_TOUCH_TD_STATUS_MASK_CNT     0x0F

/* ATK-MD0700模块触摸点数据寄存器 */
static const uint16_t g_atk_md0700_touch_tp_reg[ATK_MD0700_TOUCH_TP_MAX] = {
    ATK_MD0700_TOUCH_REG_TP1,
    ATK_MD0700_TOUCH_REG_TP2,
    ATK_MD0700_TOUCH_REG_TP3,
    ATK_MD0700_TOUCH_REG_TP4,
    ATK_MD0700_TOUCH_REG_TP5,
};

/**
 * @brief       ATK-MD0700模块触摸硬件初始化
 * @param       无
 * @retval      无
 */
static void atk_md0700_touch_hw_init(void)
{
    GPIO_InitTypeDef gpio_init_struct = {0};
    
    /* 使能时钟 */
    ATK_MD0700_TOUCH_PEN_GPIO_CLK_ENABLE();
    ATK_MD0700_TOUCH_CS_GPIO_CLK_ENABLE();
    
    /* 初始化PEN引脚 */
    gpio_init_struct.Pin    = ATK_MD0700_TOUCH_PEN_GPIO_PIN;
    gpio_init_struct.Mode   = GPIO_MODE_INPUT;
    gpio_init_struct.Pull   = GPIO_PULLUP;
    gpio_init_struct.Speed  = GPIO_SPEED_FREQ_HIGH;
    HAL_GPIO_Init(ATK_MD0700_TOUCH_PEN_GPIO_PORT, &gpio_init_struct);
    
    /* 初始化TCS引脚 */
    gpio_init_struct.Pin    = ATK_MD0700_TOUCH_CS_GPIO_PIN;
    gpio_init_struct.Mode   = GPIO_MODE_OUTPUT_PP;
    gpio_init_struct.Pull   = GPIO_PULLUP;
    gpio_init_struct.Speed  = GPIO_SPEED_FREQ_HIGH;
    HAL_GPIO_Init(ATK_MD0700_TOUCH_CS_GPIO_PORT, &gpio_init_struct);
}

/**
 * @brief       ATK-MD0700模块触摸硬件复位
 * @param       无
 * @retval      无
 */
static void atk_md0700_touch_hw_reset(void)
{
    ATK_MD0700_TOUCH_TCS(0);
    delay_ms(20);
    ATK_MD0700_TOUCH_TCS(1);
    delay_ms(50);
}

/**
 * @brief       写ATK-MD0700模块触摸寄存器
 * @param       reg: 待写寄存器地址
 *              buf: 待写入的数据
 *              len: 待写入数据的长度
 * @retval      ATK_MD0700_TOUCH_IIC_EOK  : 写ATK-MD0700模块触摸寄存器成功
 *              ATK_MD0700_TOUCH_IIC_ERROR: 写ATK-MD0700模块触摸寄存器失败
 */
static uint8_t atk_md0700_touch_iic_write_reg(uint8_t reg, uint8_t *buf, uint8_t len)
{
    uint8_t buf_index;
    uint8_t ret;
    
    atk_md0700_touch_iic_start();
    atk_md0700_touch_iic_send_byte((ATK_MD0700_TOUCH_IIC_ADDR_38 << 1) | ATK_MD0700_TOUCH_IIC_WRITE);
    atk_md0700_touch_iic_wait_ack();
    atk_md0700_touch_iic_send_byte(reg);
    atk_md0700_touch_iic_wait_ack();
    
    for (buf_index=0; buf_index<len; buf_index++)
    {
        atk_md0700_touch_iic_send_byte(buf[buf_index]);
        ret = atk_md0700_touch_iic_wait_ack();
        if (ret != 0)
        {
            break;
        }
    }
    
    atk_md0700_touch_iic_stop();
    
    if (ret != 0)
    {
        return ATK_MD0700_TOUCH_IIC_ERROR;
    }
    
    return ATK_MD0700_TOUCH_IIC_EOK;
}

/**
 * @brief       读ATK-MD0700模块触摸寄存器
 * @param       reg: 待读寄存器地址
 *              buf: 读取的数据
 *              len: 待读取数据的长度
 * @retval      ATK_MD0700_TOUCH_IIC_EOK  : 读ATK-MD0700模块触摸寄存器成功
 *              ATK_MD0700_TOUCH_IIC_ERROR: 读ATK-MD0700模块触摸寄存器失败
 */
void atk_md0700_touch_iic_read_reg(uint8_t reg, uint8_t *buf, uint8_t len)
{
    uint8_t buf_index;
    
    atk_md0700_touch_iic_start();
    atk_md0700_touch_iic_send_byte((ATK_MD0700_TOUCH_IIC_ADDR_38 << 1) | ATK_MD0700_TOUCH_IIC_WRITE);
    atk_md0700_touch_iic_wait_ack();
    atk_md0700_touch_iic_send_byte(reg);
    atk_md0700_touch_iic_wait_ack();
    atk_md0700_touch_iic_start();
    atk_md0700_touch_iic_send_byte((ATK_MD0700_TOUCH_IIC_ADDR_38 << 1) | ATK_MD0700_TOUCH_IIC_READ);
    atk_md0700_touch_iic_wait_ack();
    
    for (buf_index=0; buf_index<len - 1; buf_index++)
    {
        buf[buf_index] = atk_md0700_touch_iic_recv_byte(1);
    }
    
    buf[buf_index] = atk_md0700_touch_iic_recv_byte(0);
    
    atk_md0700_touch_iic_stop();
}

/**
 * @brief       ATK-MD0700模块触摸寄存器初始化
 * @param       无
 * @retval      无
 */
static void atk_md0700_touch_reg_init(void)
{
    uint8_t dat;
    
    /* 设备模式控制寄存器 */
    dat = 0x00;
    atk_md0700_touch_iic_write_reg(ATK_MD0700_TOUCH_REG_DEVIDE_MODE, &dat, sizeof(dat));
    
    /* 中断模式控制寄存器 */
    dat = 0x00;
    atk_md0700_touch_iic_write_reg(ATK_MD0700_TOUCH_REG_ID_G_MODE, &dat, sizeof(dat));
    
    /* 有效触摸阈值配置寄存器 */
    dat = 22;
    atk_md0700_touch_iic_write_reg(ATK_MD0700_TOUCH_REG_ID_G_THGROUP, &dat, sizeof(dat));
    
    /* 激活周期配置寄存器，不能小于12 */
    dat = 12;
    atk_md0700_touch_iic_write_reg(ATK_MD0700_TOUCH_REG_ID_G_PERIODACTIVE, &dat, sizeof(dat));
}

/**
 * @brief       ATK-MD0700模块触摸初始化
 * @param       无
 * @retval      无
 */
uint8_t atk_md0700_touch_init(void)
{
    atk_md0700_touch_hw_init();
    atk_md0700_touch_hw_reset();
    atk_md0700_touch_iic_init();
    atk_md0700_touch_reg_init();
    
    return ATK_MD0700_TOUCH_EOK;
}

/**
 * @brief       ATK-MD0700模块触摸扫描
 * @note        连续调用间隔需大于4ms
 * @param       point: 扫描到的触摸点信息
 *              cnt  : 需要扫描的触摸点数量（1~ATK_MD0700_TOUCH_TP_MAX）
 * @retval      0   : 没有扫描到触摸点
 *              其他: 实际获取到的触摸点信息数量
 */
uint8_t atk_md0700_touch_scan(atk_md0700_touch_point_t *point, uint8_t cnt)
{
    uint8_t tp_stat;
    uint8_t tp_cnt;
    uint8_t point_index;
    atk_md0700_lcd_disp_dir_t dir;
    uint8_t tpn_info[4];
    atk_md0700_touch_point_t point_raw;
    
    if ((cnt == 0) || (cnt > ATK_MD0700_TOUCH_TP_MAX))
    {
        return 0;
    }
    
    for (point_index=0; point_index<cnt; point_index++)
    {
        if (&point[point_index] == NULL)
        {
            return 0;
        }
    }
    
    atk_md0700_touch_iic_read_reg(ATK_MD0700_TOUCH_REG_TD_STATUS, &tp_stat, sizeof(tp_stat));
    tp_cnt = tp_stat & ATK_MD0700_TOUCH_TD_STATUS_MASK_CNT;
    if ((tp_cnt != 0) && (tp_cnt <= ATK_MD0700_TOUCH_TP_MAX))
    {
        tp_cnt = (cnt < tp_cnt) ? cnt : tp_cnt;
        
        for (point_index=0; point_index<tp_cnt; point_index++)
        {
            atk_md0700_touch_iic_read_reg(g_atk_md0700_touch_tp_reg[point_index], tpn_info, sizeof(tpn_info));
            point_raw.x = (uint16_t)((tpn_info[0] & 0x0F) << 8) | tpn_info[1];
            point_raw.y = (uint16_t)((tpn_info[2] & 0x0F) << 8) | tpn_info[3];
            
            dir = atk_md0700_get_disp_dir();
            switch (dir)
            {
                case ATK_MD0700_LCD_DISP_DIR_0:
                {
                    point[point_index].x = atk_md0700_get_lcd_width() - point_raw.x;
                    point[point_index].y = point_raw.y;
                    break;
                }
                case ATK_MD0700_LCD_DISP_DIR_90:
                {
                    point[point_index].x = point_raw.y;
                    point[point_index].y = point_raw.x;
                    break;
                }
                case ATK_MD0700_LCD_DISP_DIR_180:
                {
                    point[point_index].x = point_raw.x;
                    point[point_index].y = atk_md0700_get_lcd_height() - point_raw.y;
                    break;
                }
                case ATK_MD0700_LCD_DISP_DIR_270:
                {
                    point[point_index].x = atk_md0700_get_lcd_width() - point_raw.y;
                    point[point_index].y = atk_md0700_get_lcd_height() - point_raw.x;
                    break;
                }
            }
        }
        
        return tp_cnt;
    }
    else
    {
        return 0;
    }
}

#endif /* ATK_MD0700_USING_TOUCH */
