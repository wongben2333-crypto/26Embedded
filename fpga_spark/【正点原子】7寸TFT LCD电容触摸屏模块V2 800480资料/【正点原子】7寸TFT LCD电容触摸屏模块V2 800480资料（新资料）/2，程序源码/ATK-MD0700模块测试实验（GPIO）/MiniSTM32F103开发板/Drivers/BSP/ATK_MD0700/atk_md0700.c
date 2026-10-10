/**
 ****************************************************************************************************
 * @file        atk_md0700.c
 * @author      正点原子团队(ALIENTEK)
 * @version     V1.0
 * @date        2022-06-21
 * @brief       ATK-MD0700模块驱动代码
 * @license     Copyright (c) 2020-2032, 广州市星翼电子科技有限公司
 ****************************************************************************************************
 * @attention
 *
 * 实验平台:正点原子 MiniSTM32 V4开发板
 * 在线视频:www.yuanzige.com
 * 技术论坛:www.openedv.com
 * 公司网址:www.alientek.com
 * 购买地址:openedv.taobao.com
 *
 ****************************************************************************************************
 */

#include "./BSP/ATK_MD0700/atk_md0700.h"
#include "./BSP/ATK_MD0700/atk_md0700_font.h"
#include "./BSP/ATK_MD0700/atk_md0700_gpio.h"
#include "./SYSTEM/delay/delay.h"

/* ATK-MD0700模块LCD产品ID */
#define ATK_MD0700_PID              0x61    /* 产品ID */

/* ATK-MD0700模块LCD扫描方向 */
#define ATK_MD0700_SCAN_DIR_L2R_U2D (0x0000)
#define ATK_MD0700_SCAN_DIR_L2R_D2U (0x0080)
#define ATK_MD0700_SCAN_DIR_R2L_U2D (0x0040)
#define ATK_MD0700_SCAN_DIR_R2L_D2U (0x00C0)
#define ATK_MD0700_SCAN_DIR_U2D_L2R (0x0020)
#define ATK_MD0700_SCAN_DIR_U2D_R2L (0x0060)
#define ATK_MD0700_SCAN_DIR_D2U_L2R (0x00A0)
#define ATK_MD0700_SCAN_DIR_D2U_R2L (0x00E0)

/* ATK-MD0700模块状态数据结构体 */
static struct
{
    uint8_t pid;                        /* 驱动器PID */
    uint16_t width;                     /* LCD宽度 */
    uint16_t height;                    /* LCD高度 */
    atk_md0700_lcd_scan_dir_t scan_dir; /* LCD扫描方向 */
    atk_md0700_lcd_disp_dir_t disp_dir; /* LCD显示方向 */
} g_atk_md0700_sta = {0};

/**
 * @brief       获取ATK-MD0700模块LCD驱动器PID
 * @param       无
 * @retval      LCD驱动器产品ID
 */
static uint8_t atk_md0700_get_pid(void)
{
    uint8_t pid;
    
    atk_md0700_gpio_write_cmd(0xA1);
    
    atk_md0700_gpio_read_dat();
    atk_md0700_gpio_read_dat();
    pid = atk_md0700_gpio_read_dat();
    
    return pid;
}

/**
 * @brief       ATK-MD0700模块寄存器初始化
 * @param       无
 * @retval      无
 */
static void atk_md0700_reg_init(void)
{
    atk_md0700_gpio_write_cmd(0xE2);
    atk_md0700_gpio_write_dat(0x1D);
    atk_md0700_gpio_write_dat(0x02);
    atk_md0700_gpio_write_dat(0x04);
    delay_us(100);
    atk_md0700_gpio_write_cmd(0xE0);
    atk_md0700_gpio_write_dat(0x01);
    delay_ms(10);
    atk_md0700_gpio_write_cmd(0xE0);
    atk_md0700_gpio_write_dat(0x03);
    delay_ms(12);
    atk_md0700_gpio_write_cmd(0x01);
    delay_ms(10);
    atk_md0700_gpio_write_cmd(0xE6);
    atk_md0700_gpio_write_dat(0x2F);
    atk_md0700_gpio_write_dat(0xFF);
    atk_md0700_gpio_write_dat(0xFF);
    atk_md0700_gpio_write_cmd(0xB0);
    atk_md0700_gpio_write_dat(0x20);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x03);
    atk_md0700_gpio_write_dat(0x1F);
    atk_md0700_gpio_write_dat(0x01);
    atk_md0700_gpio_write_dat(0xDF);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_cmd(0xB4);
    atk_md0700_gpio_write_dat(0x04);
    atk_md0700_gpio_write_dat(0x1F);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x2E);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_cmd(0xB6);
    atk_md0700_gpio_write_dat(0x02);
    atk_md0700_gpio_write_dat(0x0C);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x17);
    atk_md0700_gpio_write_dat(0x16);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_cmd(0xF0);
    atk_md0700_gpio_write_dat(0x03);
    atk_md0700_gpio_write_cmd(0x29);
    atk_md0700_gpio_write_cmd(0xD0);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_cmd(0xBE);
    atk_md0700_gpio_write_dat(0x05);
    atk_md0700_gpio_write_dat(0xFE);
    atk_md0700_gpio_write_dat(0x01);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_cmd(0xB8);
    atk_md0700_gpio_write_dat(0x03);
    atk_md0700_gpio_write_dat(0x01);
    atk_md0700_gpio_write_cmd(0xBA);
    atk_md0700_gpio_write_dat(0X01);
}

/**
 * @brief       设置ATK-MD0700模块列地址
 * @param       无
 * @retval      无
 */
static void atk_md0700_set_column_address(uint16_t sc, uint16_t ec)
{
    switch (g_atk_md0700_sta.disp_dir)
    {
        case ATK_MD0700_LCD_DISP_DIR_0:
        case ATK_MD0700_LCD_DISP_DIR_180:
        {
            atk_md0700_gpio_write_cmd(0x2B);
            break;
        }
        case ATK_MD0700_LCD_DISP_DIR_90:
        case ATK_MD0700_LCD_DISP_DIR_270:
        {
            atk_md0700_gpio_write_cmd(0x2A);
            break;
        }
    }
    
    atk_md0700_gpio_write_dat((uint8_t)(sc >> 8) & 0xFF);
    atk_md0700_gpio_write_dat((uint8_t)sc & 0xFF);
    atk_md0700_gpio_write_dat((uint8_t)(ec >> 8) & 0xFF);
    atk_md0700_gpio_write_dat((uint8_t)ec & 0xFF);
}

/**
 * @brief       设置ATK-MD0700模块页地址
 * @param       无
 * @retval      无
 */
static void atk_md0700_set_page_address(uint16_t sp, uint16_t ep)
{
    switch (g_atk_md0700_sta.disp_dir)
    {
        case ATK_MD0700_LCD_DISP_DIR_0:
        case ATK_MD0700_LCD_DISP_DIR_180:
        {
            atk_md0700_gpio_write_cmd(0x2A);
            break;
        }
        case ATK_MD0700_LCD_DISP_DIR_90:
        case ATK_MD0700_LCD_DISP_DIR_270:
        {
            atk_md0700_gpio_write_cmd(0x2B);
            break;
        }
    }
    
    atk_md0700_gpio_write_dat((uint8_t)(sp >> 8) & 0xFF);
    atk_md0700_gpio_write_dat((uint8_t)sp & 0xFF);
    atk_md0700_gpio_write_dat((uint8_t)(ep >> 8) & 0xFF);
    atk_md0700_gpio_write_dat((uint8_t)ep & 0xFF);
}

/**
 * @brief       开始写ATK-MD0700模块显存
 * @param       无
 * @retval      无
 */
static void atk_md0700_start_write_memory(void)
{
    atk_md0700_gpio_write_cmd(0x2C);
}

/**
 * @brief       开始读ATK-MD0700模块显存
 * @param       无
 * @retval      无
 */
static void atk_md0700_start_read_memory(void)
{
    atk_md0700_gpio_write_cmd(0x2E);
}

/**
 * @brief       平方函数，x^y
 * @param       x: 底数
 *              y: 指数
 * @retval      x^y
 */
static uint32_t atk_md0700_pow(uint8_t x, uint8_t y)
{
    uint8_t loop;
    uint32_t res = 1;
    
    for (loop=0; loop<y; loop++)
    {
        res *= x;
    }
    
    return res;
}

/**
 * @brief       ATK-MD0700模块初始化
 * @param       无
 * @retval      ATK_MD0700_EOK  : ATK_MD0700模块初始化成功
 *              ATK_MD0700_ERROR: ATK_MD0700模块初始化失败
 */
uint8_t atk_md0700_init(void)
{
    uint8_t pid;
    
    atk_md0700_gpio_init();             /* ATK-MD0700模块FSMC接口初始化 */
    pid = atk_md0700_get_pid();         /* 获取ATK-MD0700模块LCD驱动器PID */
    if (pid != ATK_MD0700_PID)
    {
        return ATK_MD0700_ERROR;
    }
    else
    {
        g_atk_md0700_sta.pid = pid;
        g_atk_md0700_sta.width = ATK_MD0700_LCD_WIDTH;
        g_atk_md0700_sta.height = ATK_MD0700_LCD_HEIGHT;
    }
    atk_md0700_reg_init();
    atk_md0700_backlight_config(UINT8_MAX);
    atk_md0700_set_disp_dir(ATK_MD0700_LCD_DISP_DIR_0);
    atk_md0700_clear(ATK_MD0700_WHITE);
    atk_md0700_display_on();
#if (ATK_MD0700_USING_TOUCH != 0)
    atk_md0700_touch_init();
#endif
    
    return ATK_MD0700_EOK;
}

/**
 * @brief       获取ATK-MD0700模块LCD宽度
 * @param       无
 * @retval      ATK-MD0700模块LCD宽度
 */
uint16_t atk_md0700_get_lcd_width(void)
{
    return g_atk_md0700_sta.width;
}

/**
 * @brief       获取ATK-MD0700模块LCD高度
 * @param       无
 * @retval      ATK-MD0700模块LCD高度
 */
uint16_t atk_md0700_get_lcd_height(void)
{
    return g_atk_md0700_sta.height;
}

/**
 * @brief       设置ATK-MD0700模块LCD背光亮度
 * @param       pwm: LCD背光亮度，0：最暗；255：最亮
 * @retval      无
 */
void atk_md0700_backlight_config(uint8_t pwm)
{
    atk_md0700_gpio_write_cmd(0xBE);
    atk_md0700_gpio_write_cmd(0x05);
    atk_md0700_gpio_write_dat(pwm);
    atk_md0700_gpio_write_dat(0x01);
    atk_md0700_gpio_write_dat(0xFF);
    atk_md0700_gpio_write_dat(0x00);
    atk_md0700_gpio_write_dat(0x00);
}

/**
 * @brief       开启ATK-MD0700模块LCD显示
 * @param       无
 * @retval      无
 */
void atk_md0700_display_on(void)
{
    atk_md0700_gpio_write_cmd(0x29);
}

/**
 * @brief       关闭ATK-MD0700模块LCD显示
 * @param       无
 * @retval      无
 */
void atk_md0700_display_off(void)
{
    atk_md0700_gpio_write_cmd(0x28);
}

/**
 * @brief       设置ATK-MD0700模块LCD扫描方向
 * @param       scan_dir: ATK_MD0700_LCD_SCAN_DIR_L2R_U2D: 从左到右，从上到下
 *                        ATK_MD0700_LCD_SCAN_DIR_L2R_D2U: 从左到右，从下到上
 *                        ATK_MD0700_LCD_SCAN_DIR_R2L_U2D: 从右到左，从上到下
 *                        ATK_MD0700_LCD_SCAN_DIR_R2L_D2U: 从右到左，从下到上
 *                        ATK_MD0700_LCD_SCAN_DIR_U2D_L2R: 从上到下，从左到右
 *                        ATK_MD0700_LCD_SCAN_DIR_U2D_R2L: 从上到下，从右到左
 *                        ATK_MD0700_LCD_SCAN_DIR_D2U_L2R: 从下到上，从左到右
 *                        ATK_MD0700_LCD_SCAN_DIR_D2U_R2L: 从下到上，从右到左
 * @retval      ATK_MD0700_EOK   : 设置ATK-MD0700模块LCD扫描方向成功
 *              ATK_MD0700_ERROR : 设置ATK-MD0700模块LCD扫描方向失败
*               ATK_MD0700_EINVAL: 传入参数错误
 */
uint8_t atk_md0700_set_scan_dir(atk_md0700_lcd_scan_dir_t scan_dir)
{
    uint16_t reg36;
    
    switch (g_atk_md0700_sta.disp_dir)
    {
        case ATK_MD0700_LCD_DISP_DIR_0:
        {
            switch (scan_dir)
            {
                case ATK_MD0700_LCD_SCAN_DIR_L2R_U2D:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_U2D_L2R;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_L2R_D2U:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_U2D_R2L;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_R2L_U2D:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_D2U_L2R;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_R2L_D2U:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_D2U_R2L;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_U2D_L2R:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_L2R_U2D;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_U2D_R2L:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_L2R_D2U;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_D2U_L2R:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_R2L_U2D;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_D2U_R2L:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_R2L_D2U;
                    break;
                }
                default:
                {
                    return ATK_MD0700_EINVAL;
                }
            }
            reg36 |= 0x01;
            break;
        }
        case ATK_MD0700_LCD_DISP_DIR_90:
        {
            reg36 = scan_dir;
            break;
        }
        case ATK_MD0700_LCD_DISP_DIR_180:
        {
            switch (scan_dir)
            {
                case ATK_MD0700_LCD_SCAN_DIR_L2R_U2D:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_U2D_L2R;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_L2R_D2U:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_U2D_R2L;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_R2L_U2D:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_D2U_L2R;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_R2L_D2U:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_D2U_R2L;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_U2D_L2R:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_L2R_U2D;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_U2D_R2L:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_L2R_D2U;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_D2U_L2R:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_R2L_U2D;
                    break;
                }
                case ATK_MD0700_LCD_SCAN_DIR_D2U_R2L:
                {
                    reg36 = ATK_MD0700_LCD_SCAN_DIR_R2L_D2U;
                    break;
                }
                default:
                {
                    return ATK_MD0700_EINVAL;
                }
            }
            reg36 |= 0x02;
            break;
        }
        case ATK_MD0700_LCD_DISP_DIR_270:
        {
            reg36 = scan_dir;
            reg36 |= 0x03;
            break;
        }
        default:
        {
            return ATK_MD0700_ERROR;
        }
    }
    
    g_atk_md0700_sta.scan_dir = (atk_md0700_lcd_scan_dir_t)reg36;
    atk_md0700_gpio_write_reg(0x36, reg36);
    atk_md0700_set_column_address(0, g_atk_md0700_sta.width - 1);
    atk_md0700_set_page_address(0, g_atk_md0700_sta.height - 1);
    
    return ATK_MD0700_EOK;
}

/**
 * @brief       设置ATK-MD0700模块LCD显示方向
 * @param       disp_dir: ATK_MD0700_LCD_DISP_DIR_0  : LCD顺时针旋转0°显示内容
 *                        ATK_MD0700_LCD_DISP_DIR_90 : LCD顺时针旋转90°显示内容
 *                        ATK_MD0700_LCD_DISP_DIR_180: LCD顺时针旋转180°显示内容
 *                        ATK_MD0700_LCD_DISP_DIR_270: LCD顺时针旋转270°显示内容
 * @retval      ATK_MD0700_EOK   : 设置ATK-MD0700模块LCD显示方向成功
 *              ATK_MD0700_EINVAL: 传入参数错误
 */
uint8_t atk_md0700_set_disp_dir(atk_md0700_lcd_disp_dir_t disp_dir)
{
    switch (disp_dir)
    {
        case ATK_MD0700_LCD_DISP_DIR_0:
        {
            g_atk_md0700_sta.width = ATK_MD0700_LCD_WIDTH;
            g_atk_md0700_sta.height = ATK_MD0700_LCD_HEIGHT;
            break;
        }
        case ATK_MD0700_LCD_DISP_DIR_90:
        {
            g_atk_md0700_sta.width = ATK_MD0700_LCD_HEIGHT;
            g_atk_md0700_sta.height = ATK_MD0700_LCD_WIDTH;
            break;
        }
        case ATK_MD0700_LCD_DISP_DIR_180:
        {
            g_atk_md0700_sta.width = ATK_MD0700_LCD_WIDTH;
            g_atk_md0700_sta.height = ATK_MD0700_LCD_HEIGHT;
            break;
        }
        case ATK_MD0700_LCD_DISP_DIR_270:
        {
            g_atk_md0700_sta.width = ATK_MD0700_LCD_HEIGHT;
            g_atk_md0700_sta.height = ATK_MD0700_LCD_WIDTH;
            break;
        }
        default:
        {
            return ATK_MD0700_EINVAL;
        }
    }
    
    g_atk_md0700_sta.disp_dir = disp_dir;
    atk_md0700_set_scan_dir(ATK_MD0700_LCD_SCAN_DIR_L2R_U2D);
    
    return ATK_MD0700_EOK;
}

/**
 * @brief       获取ATK-MD0700模块LCD扫描方向
 * @param       无
 * @retval      ATK-MD0700模块LCD扫描方向
 */
atk_md0700_lcd_scan_dir_t atk_md0700_get_scan_dir(void)
{
    return g_atk_md0700_sta.scan_dir;
}

/**
 * @brief       获取ATK-MD0700模块LCD显示方向
 * @param       无
 * @retval      ATK-MD0700模块LCD显示方向
 */
atk_md0700_lcd_disp_dir_t atk_md0700_get_disp_dir(void)
{
    return g_atk_md0700_sta.disp_dir;
}

/**
 * @brief       ATK-MD0700模块LCD区域填充
 * @param       xs   : 区域起始X坐标
 *              ys   : 区域起始Y坐标
 *              xe   : 区域终止X坐标
 *              ye   : 区域终止Y坐标
 *              color: 区域填充颜色
 * @retval      无
 */
void atk_md0700_fill(uint16_t xs, uint16_t ys, uint16_t xe, uint16_t ye, uint16_t color)
{
    uint16_t x_index;
    uint16_t y_index;
    
    atk_md0700_set_column_address(xs, xe);
    atk_md0700_set_page_address(ys, ye);
    atk_md0700_start_write_memory();
    for (y_index=ys; y_index<=ye; y_index++)
    {
        for (x_index=xs; x_index<= xe; x_index++)
        {
            atk_md0700_gpio_write_dat(color);
        }
    }
}

/**
 * @brief       ATK-MD0700模块LCD清屏
 * @param       color: 清屏颜色
 * @retval      无
 */
void atk_md0700_clear(uint16_t color)
{
    atk_md0700_fill(0, 0, g_atk_md0700_sta.width - 1, g_atk_md0700_sta.height - 1, color);
}

/**
 * @brief       ATK-MD0700模块LCD画点
 * @param       x    : 待画点的X坐标
 *              y    : 待画点的Y坐标
 *              color: 待画点的颜色
 * @retval      无
 */
void atk_md0700_draw_point(uint16_t x, uint16_t y, uint16_t color)
{
    atk_md0700_set_column_address(x, x);
    atk_md0700_set_page_address(y, y);
    atk_md0700_start_write_memory();
    atk_md0700_gpio_write_dat(color);
}

/**
 * @brief       ATK-MD0700模块LCD读点
 * @param       x    : 待读点的X坐标
 *              y    : 待读点的Y坐标
 * @retval      待读点的颜色
 */
uint16_t atk_md0700_read_point(uint16_t x, uint16_t y)
{
    uint16_t color;
    
    if ((x >= g_atk_md0700_sta.width) || (y >= g_atk_md0700_sta.height))
    {
        return ATK_MD0700_EINVAL;
    }
    
    atk_md0700_set_column_address(x, x);
    atk_md0700_set_page_address(y, y);
    atk_md0700_start_read_memory();
    
    color = atk_md0700_gpio_read_dat();
    
    return color;
}

/**
 * @brief       ATK-MD0700模块LCD画线段
 * @param       x1   : 待画线段端点1的X坐标
 *              y1   : 待画线段端点1的Y坐标
 *              x2   : 待画线段端点2的X坐标
 *              y2   : 待画线段端点2的Y坐标
 *              color: 待画线段的颜色
 * @retval      无
 */
void atk_md0700_draw_line(uint16_t x1, uint16_t y1, uint16_t x2, uint16_t y2, uint16_t color)
{
    uint16_t x_delta;
    uint16_t y_delta;
    int16_t x_sign;
    int16_t y_sign;
    int16_t error;
    int16_t error2;
    
    x_delta = (x1 < x2) ? (x2 - x1) : (x1 - x2);
    y_delta = (y1 < y2) ? (y2 - y1) : (y1 - y2);
    x_sign = (x1 < x2) ? 1 : -1;
    y_sign = (y1 < y2) ? 1 : -1;
    error = x_delta - y_delta;
    
    atk_md0700_draw_point(x2, y2, color);
    
    while ((x1 != x2) || (y1 != y2))
    {
        atk_md0700_draw_point(x1, y1, color);
        
        error2 = error << 1;
        if (error2 > -y_delta)
        {
            error -= y_delta;
            x1 += x_sign;
        }
        
        if (error2 < x_delta)
        {
            error += x_delta;
            y1 += y_sign;
        }
    }
}

/**
 * @brief       ATK-MD0700模块LCD画矩形框
 * @param       x1   : 待画矩形框端点1的X坐标
 *              y1   : 待画矩形框端点1的Y坐标
 *              x2   : 待画矩形框端点2的X坐标
 *              y2   : 待画矩形框端点2的Y坐标
 *              color: 待画矩形框的颜色
 * @retval      无
 */
void atk_md0700_draw_rect(uint16_t x1, uint16_t y1, uint16_t x2, uint16_t y2, uint16_t color)
{
    atk_md0700_draw_line(x1, y1, x2, y1, color);
    atk_md0700_draw_line(x1, y2, x2, y2, color);
    atk_md0700_draw_line(x1, y1, x1, y2, color);
    atk_md0700_draw_line(x2, y1, x2, y2, color);
}

/**
 * @brief       ATK-MD0700模块LCD画圆形框
 * @param       x    : 待画圆形框原点的X坐标
 *              y    : 待画圆形框原点的Y坐标
 *              r    : 待画圆形框的半径
 *              color: 待画圆形框的颜色
 * @retval      无
 */
void atk_md0700_draw_circle(uint16_t x, uint16_t y, uint16_t r, uint16_t color)
{
    int32_t x_t;
    int32_t y_t;
    int32_t error;
    int32_t error2;
    
    x_t = -r;
    y_t = 0;
    error = 2 - 2 * r;
    
    do {
        atk_md0700_draw_point(x - x_t, y + y_t, color);
        atk_md0700_draw_point(x + x_t, y + y_t, color);
        atk_md0700_draw_point(x + x_t, y - y_t, color);
        atk_md0700_draw_point(x - x_t, y - y_t, color);
        
        error2 = error;
        if (error2 <= y_t)
        {
            y_t++;
            error = error + (y_t * 2 + 1);
            if ((-x_t == y_t) && (error2 <= x_t))
            {
                error2 = 0;
            }
        }
        
        if (error2 > x_t)
        {
            x_t++;
            error = error + (x_t * 2 + 1);
        }
    } while (x_t <= 0);
}

/**
 * @brief       ATK-MD0700模块LCD显示1个字符
 * @param       x    : 待显示字符的X坐标
 *              y    : 待显示字符的Y坐标
 *              ch   : 待显示字符
 *              font : 待显示字符的字体
 *              color: 待显示字符的颜色
 * @retval      无
 */
void atk_md0700_show_char(uint16_t x, uint16_t y, char ch, atk_md0700_lcd_font_t font, uint16_t color)
{
    const uint8_t *ch_code;
    uint8_t ch_width;
    uint8_t ch_height;
    uint8_t ch_size;
    uint8_t ch_offset;
    uint8_t byte_index;
    uint8_t byte_code;
    uint8_t bit_index;
    uint8_t width_index = 0;
    uint8_t height_index = 0;
    
    ch_offset = ch - ' ';
    
    switch (font)
    {
#if (ATK_MD0700_FONT_12 != 0)
        case ATK_MD0700_LCD_FONT_12:
        {
            ch_code = atk_md0700_font_1206[ch_offset];
            ch_width = ATK_MD0700_FONT_12_CHAR_WIDTH;
            ch_height = ATK_MD0700_FONT_12_CHAR_HEIGHT;
            ch_size = ATK_MD0700_FONT_12_CHAR_SIZE;
            break;
        }
#endif
#if (ATK_MD0700_FONT_16 != 0)
        case ATK_MD0700_LCD_FONT_16:
        {
            ch_code = atk_md0700_font_1608[ch_offset];
            ch_width = ATK_MD0700_FONT_16_CHAR_WIDTH;
            ch_height = ATK_MD0700_FONT_16_CHAR_HEIGHT;
            ch_size = ATK_MD0700_FONT_16_CHAR_SIZE;
            break;
        }
#endif
#if (ATK_MD0700_FONT_24 != 0)
        case ATK_MD0700_LCD_FONT_24:
        {
            ch_code = atk_md0700_font_2412[ch_offset];
            ch_width = ATK_MD0700_FONT_24_CHAR_WIDTH;
            ch_height = ATK_MD0700_FONT_24_CHAR_HEIGHT;
            ch_size = ATK_MD0700_FONT_24_CHAR_SIZE;
            break;
        }
#endif
#if (ATK_MD0700_FONT_32 != 0)
        case ATK_MD0700_LCD_FONT_32:
        {
            ch_code = atk_md0700_font_3216[ch_offset];
            ch_width = ATK_MD0700_FONT_32_CHAR_WIDTH;
            ch_height = ATK_MD0700_FONT_32_CHAR_HEIGHT;
            ch_size = ATK_MD0700_FONT_32_CHAR_SIZE;
            break;
        }
#endif
        default:
        {
            return;
        }
    }
    
    if ((x + ch_width > ATK_MD0700_LCD_WIDTH) || (y + ch_height > ATK_MD0700_LCD_HEIGHT))
    {
        return;
    }
    
    for (byte_index=0; byte_index<ch_size; byte_index++)
    {
        byte_code = ch_code[byte_index];
        for (bit_index=0; bit_index<8; bit_index++)
        {
            if ((byte_code & 0x80) != 0)
            {
                atk_md0700_draw_point(x + width_index, y + height_index, color);
            }
            height_index++;
            if (height_index == ch_height)
            {
                height_index = 0;
                width_index++;
                break;
            }
            byte_code <<= 1;
        }
    }
}

/**
 * @brief       ATK-MD0700模块LCD显示字符串
 * @note        会自动换行和换页
 * @param       x     : 待显示字符串的X坐标
 *              y     : 待显示字符串的Y坐标
 *              width : 待显示字符串的显示高度
 *              height: 待显示字符串的显示宽度
 *              str   : 待显示字符串
 *              font  : 待显示字符串的字体
 *              color : 待显示字符串的颜色
 * @retval      无
 */
void atk_md0700_show_string(uint16_t x, uint16_t y, uint16_t width, uint16_t height, char *str, atk_md0700_lcd_font_t font, uint16_t color)
{
    uint8_t ch_width;
    uint8_t ch_height;
    uint16_t x_raw;
    uint16_t y_raw;
    uint16_t x_limit;
    uint16_t y_limit;
    
    switch (font)
    {
#if (ATK_MD0700_FONT_12 != 0)
        case ATK_MD0700_LCD_FONT_12:
        {
            ch_width = ATK_MD0700_FONT_12_CHAR_WIDTH;
            ch_height = ATK_MD0700_FONT_12_CHAR_HEIGHT;
            break;
        }
#endif
#if (ATK_MD0700_FONT_16 != 0)
        case ATK_MD0700_LCD_FONT_16:
        {
            ch_width = ATK_MD0700_FONT_16_CHAR_WIDTH;
            ch_height = ATK_MD0700_FONT_16_CHAR_HEIGHT;
            break;
        }
#endif
#if (ATK_MD0700_FONT_24 != 0)
        case ATK_MD0700_LCD_FONT_24:
        {
            ch_width = ATK_MD0700_FONT_24_CHAR_WIDTH;
            ch_height = ATK_MD0700_FONT_24_CHAR_HEIGHT;
            break;
        }
#endif
#if (ATK_MD0700_FONT_32 != 0)
        case ATK_MD0700_LCD_FONT_32:
        {
            ch_width = ATK_MD0700_FONT_32_CHAR_WIDTH;
            ch_height = ATK_MD0700_FONT_32_CHAR_HEIGHT;
            break;
        }
#endif
        default:
        {
            return;
        }
    }
    
    x_raw = x;
    y_raw = y;
    x_limit = ((x + width + 1) > ATK_MD0700_LCD_WIDTH) ? ATK_MD0700_LCD_WIDTH : (x + width + 1);
    y_limit = ((y + height + 1) > ATK_MD0700_LCD_HEIGHT) ? ATK_MD0700_LCD_HEIGHT : (y + height + 1);
    
    while ((*str >= ' ') && (*str <= '~'))
    {
        if (x + ch_width >= x_limit)
        {
            x = x_raw;
            y += ch_height;
        }
        
        if (y + ch_height >= y_limit)
        {
            y = x_raw;
            x = y_raw;
        }
        
        atk_md0700_show_char(x, y, *str, font, color);
        
        x += ch_width;
        str++;
    }
}

/**
 * @brief       ATK-MD0700模块LCD显示数字，可控制显示高位0
 * @param       x    : 待显示数字的X坐标
 *              y    : 待显示数字的Y坐标
 *              num  : 待显示数字
 *              len  : 待显示数字的位数
 *              mode : ATK_MD0700_NUM_SHOW_NOZERO: 数字高位0不显示
 *                     ATK_MD0700_NUM_SHOW_ZERO  : 数字高位0显示
 *              font : 待显示数字的字体
 *              color: 待显示数字的颜色
 * @retval      无
 */
void atk_md0700_show_xnum(uint16_t x, uint16_t y, uint32_t num, uint8_t len, atk_md0700_num_mode_t mode, atk_md0700_lcd_font_t font, uint16_t color)
{
    uint8_t ch_width;
    uint8_t len_index;
    uint8_t num_index;
    uint8_t first_nozero = 0;
    char pad;
    
    switch (font)
    {
#if (ATK_MD0700_FONT_12 != 0)
        case ATK_MD0700_LCD_FONT_12:
        {
            ch_width = ATK_MD0700_FONT_12_CHAR_WIDTH;
            break;
        }
#endif
#if (ATK_MD0700_FONT_16 != 0)
        case ATK_MD0700_LCD_FONT_16:
        {
            ch_width = ATK_MD0700_FONT_16_CHAR_WIDTH;
            break;
        }
#endif
#if (ATK_MD0700_FONT_24 != 0)
        case ATK_MD0700_LCD_FONT_24:
        {
            ch_width = ATK_MD0700_FONT_24_CHAR_WIDTH;
            break;
        }
#endif
#if (ATK_MD0700_FONT_32 != 0)
        case ATK_MD0700_LCD_FONT_32:
        {
            ch_width = ATK_MD0700_FONT_32_CHAR_WIDTH;
            break;
        }
#endif
        default:
        {
            return;
        }
    }
    
    switch (mode)
    {
        case ATK_MD0700_NUM_SHOW_NOZERO:
        {
            pad = ' ';
            break;
        }
        case ATK_MD0700_NUM_SHOW_ZERO:
        {
            pad = '0';
            break;
        }
        default:
        {
            return;
        }
    }
    
    for (len_index=0; len_index<len; len_index++)
    {
        num_index = (num / atk_md0700_pow(10, len - len_index - 1)) % 10;
        if ((first_nozero == 0) && (len_index < (len - 1)))
        {
            if (num_index == 0)
            {
                atk_md0700_show_char(x + ch_width * len_index, y, pad, font, color);
                continue;
            }
            else
            {
                first_nozero = 1;
            }
        }
        
        atk_md0700_show_char(x + ch_width * len_index, y, num_index + '0', font, color);
    }
}

/**
 * @brief       ATK-MD0700模块LCD显示数字，不显示高位0
 * @param       x    : 待显示数字的X坐标
 *              y    : 待显示数字的Y坐标
 *              num  : 待显示数字
 *              len  : 待显示数字的位数
 *              font : 待显示数字的字体
 *              color: 待显示数字的颜色
 * @retval      无
 */
void atk_md0700_show_num(uint16_t x, uint16_t y, uint32_t num, uint8_t len, atk_md0700_lcd_font_t font, uint16_t color)
{
    atk_md0700_show_xnum(x, y, num, len, ATK_MD0700_NUM_SHOW_NOZERO, font, color);
}

/**
 * @brief       ATK-MD0700模块LCD图片
 * @note        图片取模方式: 水平扫描、RGB565、高位在前
 * @param       x     : 待显示图片的X坐标
 *              y     : 待显示图片的Y坐标
 *              width : 待显示图片的宽度
 *              height: 待显示图片的高度
 *              pic   : 待显示图片数组首地址
 * @retval      无
 */
void atk_md0700_show_pic(uint16_t x, uint16_t y, uint16_t width, uint16_t height, uint8_t *pic)
{
    uint16_t x_index;
    uint16_t y_index;
    
    if ((x + width > ATK_MD0700_LCD_WIDTH) || (y + height > ATK_MD0700_LCD_HEIGHT))
    {
        return;
    }
    
    atk_md0700_set_column_address(x, x + width - 1);
    atk_md0700_set_page_address(y, y + height - 1);
    atk_md0700_start_write_memory();
    for (y_index=y; y_index<=(y + height); y_index++)
    {
        for (x_index=x; x_index<=(x + width); x_index++)
        {
            atk_md0700_gpio_write_dat(*pic);
            pic++;
        }
    }
}
