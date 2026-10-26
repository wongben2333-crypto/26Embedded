# -*- coding: utf-8 -*-
path = 'C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/rtl/lcd_test_top.v'
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

# 1. replace PWM param 4
assert "8'd51: rom_q = `D(8'hFF);" in text
assert "8'd77: rom_q = `D(8'hFF);" in text

text = text.replace("8'd51: rom_q = `D(8'hFF);", "8'd51: rom_q = `D(8'h00);       // DBC manual brightness = 0")
text = text.replace("8'd77: rom_q = `D(8'hFF);", "8'd77: rom_q = `D(8'h00);       // DBC manual brightness = 0")

# 2. increase reset delay
text = text.replace("dly <= 24'd1000000;", "dly <= 24'd2500000;")  # 50ms at 50MHz
text = text.replace("dly <= 24'd2000000;", "dly <= 24'd5000000;")  # 100ms at 50MHz

# 3. add reinit_req
old_decl = "    reg       snap_clear_req;\n    reg       frame_end_pulse;"
new_decl = "    reg       snap_clear_req;\n    reg       frame_end_pulse;\n    reg       reinit_req;"
if old_decl in text:
    text = text.replace(old_decl, new_decl)
else:
    text = text.replace(old_decl.replace("\n", "\r\n"), new_decl.replace("\n", "\r\n"))

old_rx = '                    "a", "A": begin pat_lock <= 1\'b0; end'
new_rx = '                    "a", "A": begin pat_lock <= 1\'b0; end\n                    "r", "R", "i", "I": begin reinit_req <= 1\'b1; end'
if old_rx in text:
    text = text.replace(old_rx, new_rx)
else:
    text = text.replace(old_rx.replace("\n", "\r\n"), new_rx.replace("\n", "\r\n"))

old_rst = "            snap_wait_frm <= 2'd0;"
new_rst = "            snap_wait_frm <= 2'd0;\n            reinit_req    <= 1'b0;"
if old_rst in text:
    text = text.replace(old_rst, new_rst)
else:
    text = text.replace(old_rst.replace("\n", "\r\n"), new_rst.replace("\n", "\r\n"))

old_pw = """            M_PRINT_WAIT: begin
                frame_cnt <= frame_cnt + 1'b1;
                seg       <= 2'd1;
                pc        <= SEG_FRAME;
                ms        <= M_SEQ;
            end"""

new_pw = """            M_PRINT_WAIT: begin
                frame_cnt <= frame_cnt + 1'b1;
                if (reinit_req) begin
                    reinit_req <= 1'b0;
                    seg        <= 2'd0;
                    pc         <= SEG_INIT;
                    ms         <= M_SEQ;
                end else begin
                    seg        <= 2'd1;
                    pc         <= SEG_FRAME;
                    ms         <= M_SEQ;
                end
            end"""

if old_pw in text:
    text = text.replace(old_pw, new_pw)
else:
    text = text.replace(old_pw.replace("\n", "\r\n"), new_pw.replace("\n", "\r\n"))

with open(path, 'w', encoding='utf-8') as f:
    f.write(text)

print('Update successful!')
