# -*- coding: utf-8 -*-
path = 'C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/rtl/lcd_test_top.v'
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

# Replace reinit_req in FSM
old_pw = """            M_PRINT_WAIT: begin
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

new_pw = """            M_PRINT_WAIT: begin
                frame_cnt <= frame_cnt + 1'b1;
                if (reinit_req) begin
                    reinit_clear_req <= 1'b1;
                    seg              <= 2'd0;
                    pc               <= SEG_INIT;
                    ms               <= M_SEQ;
                end else begin
                    seg              <= 2'd1;
                    pc               <= SEG_FRAME;
                    ms               <= M_SEQ;
                end
            end"""

text = text.replace(old_pw, new_pw)
text = text.replace(old_pw.replace("\n", "\r\n"), new_pw.replace("\n", "\r\n"))

# Add reinit_clear_req to declaration
old_decl = "    reg       snap_clear_req;\n    reg       frame_end_pulse;\n    reg       reinit_req;"
new_decl = "    reg       snap_clear_req;\n    reg       reinit_clear_req;\n    reg       frame_end_pulse;\n    reg       reinit_req;"
text = text.replace(old_decl, new_decl)
text = text.replace(old_decl.replace("\n", "\r\n"), new_decl.replace("\n", "\r\n"))

# In UART RX: clear reinit_req on reinit_clear_req
old_rx_rst = "            if (snap_clear_req) snap_req <= 1'b0;"
new_rx_rst = "            if (snap_clear_req)   snap_req   <= 1'b0;\n            if (reinit_clear_req) reinit_req <= 1'b0;"
text = text.replace(old_rx_rst, new_rx_rst)
text = text.replace(old_rx_rst.replace("\n", "\r\n"), new_rx_rst.replace("\n", "\r\n"))

# In main FSM: default reinit_clear_req <= 1'b0
old_fsm_rst = "            snap_clear_req  <= 1'b0;\n            frame_end_pulse <= 1'b0;"
new_fsm_rst = "            snap_clear_req   <= 1'b0;\n            reinit_clear_req <= 1'b0;\n            frame_end_pulse  <= 1'b0;"
text = text.replace(old_fsm_rst, new_fsm_rst)
text = text.replace(old_fsm_rst.replace("\n", "\r\n"), new_fsm_rst.replace("\n", "\r\n"))

# In main FSM reset:
old_rst_init = "            snap_clear_req <= 1'b0; frame_end_pulse <= 1'b0;"
new_rst_init = "            snap_clear_req <= 1'b0; reinit_clear_req <= 1'b0; frame_end_pulse <= 1'b0;"
text = text.replace(old_rst_init, new_rst_init)
text = text.replace(old_rst_init.replace("\n", "\r\n"), new_rst_init.replace("\n", "\r\n"))

with open(path, 'w', encoding='utf-8') as f:
    f.write(text)

print('Patch applied successfully!')
