# -*- coding: utf-8 -*-
"""给顶层补上 MS7210 的 SDA 驱动仲裁（幂等）。
用法: python apply_sda_fix.py source/img_correct_top.v
"""
import sys, io, re

path = sys.argv[1]
s = io.open(path, 'r', encoding='utf-8', errors='replace', newline='').read()

if 'tx_sda_en' in s:
    print('SKIP: already patched')
    sys.exit(0)

old = """    ms7210_cfg u_ms7210_cfg(
        .clk       (sys_clk  ),
        .rst_n     (sys_rst_n),
        .iic_scl   (hd_scl   ),
        .iic_sda   (hd_sda   ),
        .cfg_done  (cfg_done ),
        .dbg_state (dbg_state)
    );"""

new = """    //------------------------------------------------------------------
    // 【关键修复 2026-10-31】ms7210_cfg 已改为 "SDA 驱动权外置"，
    //   内部不再 assign iic_sda，而是交出 sda_out/sda_out_en。
    //   HDMI 版顶层加了仲裁，本 ROM 版顶层漏了 —— hd_sda 只挂上拉，
    //   MS7210 收不到命令，永远卡 CONECT：LED 快闪 + 黑屏。
    //------------------------------------------------------------------
    wire tx_sda_out;
    wire tx_sda_en;

    ms7210_cfg u_ms7210_cfg(
        .clk          (sys_clk  ),
        .rst_n        (sys_rst_n),
        .iic_scl      (hd_scl   ),
        .iic_sda      (hd_sda   ),   // 只用于回读总线电平
        .cfg_done     (cfg_done ),
        .dbg_state    (dbg_state),
        .sda_out_o    (tx_sda_out),
        .sda_out_en_o (tx_sda_en )
    );

    // MS7210 是唯一的 I2C 从机，驱动权直接给它
    assign hd_sda = tx_sda_en ? tx_sda_out : 1'bz;"""

# 兼容 CRLF / LF
old_crlf = old.replace('\n', '\r\n')
if old in s:
    s = s.replace(old, new, 1)
elif old_crlf in s:
    s = s.replace(old_crlf, new.replace('\n', '\r\n'), 1)
else:
    print('ERROR: 实例化块没匹配上')
    sys.exit(1)

io.open(path, 'w', encoding='utf-8', newline='').write(s)
print('PATCH OK')
