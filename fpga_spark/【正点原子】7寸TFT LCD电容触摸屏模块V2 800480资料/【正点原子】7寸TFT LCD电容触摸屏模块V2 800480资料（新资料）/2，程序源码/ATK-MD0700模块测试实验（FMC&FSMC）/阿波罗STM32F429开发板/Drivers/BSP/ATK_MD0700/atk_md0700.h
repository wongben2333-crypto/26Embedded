/**
 ****************************************************************************************************
 * @file        atk_md0700.h
 * @author      正点原子团队(ALIENTEK)
 * @version     V1.0
 * @date        2022-06-21
 * @brief       ATK-MD0700模块驱动代码
 * @license     Copyright (c) 2020-2032, 广州市星翼电子科技有限公司
 ****************************************************************************************************
 * @attention
 *
 * 实验平台:正点原子 Mini Pro H750开发板
 * 在线视频:www.yuanzige.com
 * 技术论坛:www.openedv.com
 * 公司网址:www.alientek.com
 * 购买地址:openedv.taobao.com
 *
 ****************************************************************************************************
 */

#ifndef __ATK_MD0700_H
#define __ATK_MD0700_H

#include "./SYSTEM/sys/sys.h"

/* 定义ATK-MD0700模块LCD尺寸 */
#define ATK_MD0700_LCD_WIDTH            480
#define ATK_MD0700_LCD_HEIGHT           800

/* 定义是否使用ATK-MD0700模块触摸 */
#define ATK_MD0700_USING_TOUCH          1

/* 定义ATK-MD0700模块启用的字体 */
#define ATK_MD0700_FONT_12              1
#define ATK_MD0700_FONT_16              1
#define ATK_MD0700_FONT_24              1
#define ATK_MD0700_FONT_32              1

/* 默认启用触摸 */
#ifndef ATK_MD0700_USING_TOUCH
#define ATK_MD0700_USING_TOUCH 1
#endif

/* 默认启用12号字体 */
#if ((ATK_MD0700_FONT_12 == 0) && (ATK_MD0700_FONT_16 == 0) && (ATK_MD0700_FONT_24 == 0) && (ATK_MD0700_FONT_32 == 0))
#undef ATK_MD0700_FONT_12
#defien ATK_MD0700_FONT_12 1
#endif

/* 包含头文件 */
#if (ATK_MD0700_USING_TOUCH != 0)
#include "./BSP/ATK_MD0700/atk_md0700_touch.h"
#endif

/* ATK-MD0700模块LCD扫描方向枚举 */
typedef enum
{
    ATK_MD0700_LCD_SCAN_DIR_L2R_U2D = 0x0000,   /* 从左到右，从上到下 */
    ATK_MD0700_LCD_SCAN_DIR_L2R_D2U = 0x0080,   /* 从左到右，从下到上 */
    ATK_MD0700_LCD_SCAN_DIR_R2L_U2D = 0x0040,   /* 从右到左，从上到下 */
    ATK_MD0700_LCD_SCAN_DIR_R2L_D2U = 0x00C0,   /* 从右到左，从下到上 */
    ATK_MD0700_LCD_SCAN_DIR_U2D_L2R = 0x0020,   /* 从上到下，从左到右 */
    ATK_MD0700_LCD_SCAN_DIR_U2D_R2L = 0x0060,   /* 从上到下，从右到左 */
    ATK_MD0700_LCD_SCAN_DIR_D2U_L2R = 0x00A0,   /* 从下到上，从左到右 */
    ATK_MD0700_LCD_SCAN_DIR_D2U_R2L = 0x00E0,   /* 从下到上，从右到左 */
} atk_md0700_lcd_scan_dir_t;

/* ATK-MD0700模块LCD旋转方向枚举 */
typedef enum
{
    ATK_MD0700_LCD_DISP_DIR_0 = 0x00,           /* LCD顺时针旋转0°显示内容 */
    ATK_MD0700_LCD_DISP_DIR_90,                 /* LCD顺时针旋转90°显示内容 */
    ATK_MD0700_LCD_DISP_DIR_180,                /* LCD顺时针旋转180°显示内容 */
    ATK_MD0700_LCD_DISP_DIR_270,                /* LCD顺时针旋转270°显示内容 */
} atk_md0700_lcd_disp_dir_t;

/* ATK-MD0700模块LCD显示字体枚举 */
typedef enum
{
#if (ATK_MD0700_FONT_12 != 0)
    ATK_MD0700_LCD_FONT_12,             /* 12号字体 */
#endif
#if (ATK_MD0700_FONT_16 != 0)
    ATK_MD0700_LCD_FONT_16,             /* 16号字体 */
#endif
#if (ATK_MD0700_FONT_24 != 0)
    ATK_MD0700_LCD_FONT_24,             /* 24号字体 */
#endif
#if (ATK_MD0700_FONT_32 != 0)
    ATK_MD0700_LCD_FONT_32,             /* 32号字体 */
#endif
} atk_md0700_lcd_font_t;

/* ATK-MD0700模块LCD显示数字模式枚举 */
typedef enum
{
    ATK_MD0700_NUM_SHOW_NOZERO = 0x00,  /* 数字高位0不显示 */
    ATK_MD0700_NUM_SHOW_ZERO,           /* 数字高位0显示 */
} atk_md0700_num_mode_t;

/* 常用颜色定义（RGB565） */
#define ATK_MD0700_WHITE        0xFFFF
#define ATK_MD0700_BLACK        0x0000
#define ATK_MD0700_BLUE         0x001F
#define ATK_MD0700_BRED         0XF81F
#define ATK_MD0700_GRED         0XFFE0
#define ATK_MD0700_GBLUE        0X07FF
#define ATK_MD0700_RED          0xF800
#define ATK_MD0700_MAGENTA      0xF81F
#define ATK_MD0700_GREEN        0x07E0
#define ATK_MD0700_CYAN         0x7FFF
#define ATK_MD0700_YELLOW       0xFFE0
#define ATK_MD0700_BROWN        0XBC40
#define ATK_MD0700_BRRED        0XFC07
#define ATK_MD0700_GRAY         0X8430

/* 错误代码 */
#define ATK_MD0700_EOK          0   /* 没有错误 */
#define ATK_MD0700_ERROR        1   /* 错误 */
#define ATK_MD0700_EINVAL       2   /* 非法参数 */

/* 操作函数 */
uint8_t atk_md0700_init(void);                                                                                                                          /* ATK-MD0700模块初始化 */
uint16_t atk_md0700_get_lcd_width(void);                                                                                                                /* 获取ATK-MD0700模块LCD宽度 */
uint16_t atk_md0700_get_lcd_height(void);                                                                                                               /* 获取ATK-MD0700模块LCD高度 */
void atk_md0700_backlight_config(uint8_t pwm);                                                                                                          /* 设置ATK-MD0700模块LCD背光亮度 */
void atk_md0700_display_on(void);                                                                                                                       /* 开启ATK-MD0700模块LCD显示 */
void atk_md0700_display_off(void);                                                                                                                      /* 关闭ATK-MD0700模块LCD显示 */
uint8_t atk_md0700_set_scan_dir(atk_md0700_lcd_scan_dir_t scan_dir);                                                                                    /* 设置ATK-MD0700模块LCD扫描方向 */
uint8_t atk_md0700_set_disp_dir(atk_md0700_lcd_disp_dir_t disp_dir);                                                                                    /* 设置ATK-MD0700模块LCD显示方向 */
atk_md0700_lcd_scan_dir_t atk_md0700_get_scan_dir(void);                                                                                                /* 获取ATK-MD0700模块LCD扫描方向 */
atk_md0700_lcd_disp_dir_t atk_md0700_get_disp_dir(void);                                                                                                /* 获取ATK-MD0700模块LCD显示方向 */
void atk_md0700_fill(uint16_t xs, uint16_t ys, uint16_t xe, uint16_t ye, uint16_t color);                                                               /* ATK-MD0700模块LCD区域填充 */
void atk_md0700_clear(uint16_t color);                                                                                                                  /* ATK-MD0700模块LCD清屏 */
void atk_md0700_draw_point(uint16_t x, uint16_t y, uint16_t color);                                                                                     /* ATK-MD0700模块LCD画点 */
uint16_t atk_md0700_read_point(uint16_t x, uint16_t y);                                                                                                 /* ATK-MD0700模块LCD读点 */
void atk_md0700_draw_line(uint16_t x1, uint16_t y1, uint16_t x2, uint16_t y2, uint16_t color);                                                          /* ATK-MD0700模块LCD画线段 */
void atk_md0700_draw_rect(uint16_t x1, uint16_t y1, uint16_t x2, uint16_t y2, uint16_t color);                                                          /* ATK-MD0700模块LCD画矩形框 */
void atk_md0700_draw_circle(uint16_t x, uint16_t y, uint16_t r, uint16_t color);                                                                        /* ATK-MD0700模块LCD画圆形框 */
void atk_md0700_show_char(uint16_t x, uint16_t y, char ch, atk_md0700_lcd_font_t font, uint16_t color);                                                 /* ATK-MD0700模块LCD显示1个字符 */
void atk_md0700_show_string(uint16_t x, uint16_t y, uint16_t width, uint16_t height, char *str, atk_md0700_lcd_font_t font, uint16_t color);            /* ATK-MD0700模块LCD显示字符串 */
void atk_md0700_show_xnum(uint16_t x, uint16_t y, uint32_t num, uint8_t len, atk_md0700_num_mode_t mode, atk_md0700_lcd_font_t font, uint16_t color);   /* ATK-MD0700模块LCD显示数字，可控制显示高位0 */
void atk_md0700_show_num(uint16_t x, uint16_t y, uint32_t num, uint8_t len, atk_md0700_lcd_font_t font, uint16_t color);                                /* ATK-MD0700模块LCD显示数字，不显示高位0 */
void atk_md0700_show_pic(uint16_t x, uint16_t y, uint16_t width, uint16_t height, uint8_t *pic);                                                        /* ATK-MD0700模块LCD图片 */

#endif
