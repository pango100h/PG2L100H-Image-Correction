//==============================================================================
//  img_correct_top.v —— MES2L676-100HP (PG2L100H-6IFBG676) HDMI 输出顶层
//
//  信号链：
//    sys_clk(27MHz, D18) -> pll_27m_to_vga(74.25MHz) -> video_timing_720p
//                                                     -> RGB/DE/HS/VS
//                                                     -> pixclk_out(反相)
//    sys_clk(27MHz)      -> ms7210_cfg -> I2C 配置底板 U14 MS7210 -> 输出 TMDS
//    片内 4 bank ROM     -> img_path   -> 仿射矩阵 -> 二阶径向/切向校正
//                                       -> 双线性插值 -> 自适应 Gamma -> 上屏
//
//  引脚全部按 hdmi_loop_tx.fdc（随工程提交）命名，一一对应：
//    sys_clk=D18   rst_n=C22(USER_BUTTON0)
//    r_out[7:0]=HD_TX_D23..16 (P16 K25 K26 L24 L25 L22 L23 N21)
//    g_out[7:0]=HD_TX_D15..8  (N22 N23 N24 P23 P25 R25 P24 T25)
//    b_out[7:0]=HD_TX_D7..0   (T22 R22 N18 M21 M22 P20 P21 P19)
//    de_out=N19  hs_out=R20  vs_out=R21  pixclk_out=T24
//    hd_sda=K23  hd_scl=K22
//    rstn_out=G25 (-> R134 -> MS7210 pin33 RSTN)
//    led_int=A20  (USER_LED0，用来看配置状态)
//
//  LED(A20) 状态：
//    慢闪 ~1.6Hz   : I2C 49 条寄存器全部写完，配置成功
//    快闪 ~13Hz    : 卡在 CONECT，MS7210 完全没应答（查 SDA/SCL/复位/芯片型号）
//    中速 ~6.4Hz   : 正在写寄存器（1~2 秒后应转为慢闪）
//==============================================================================
module img_correct_top(
    input  wire       sys_clk,      // D18  27MHz
    input  wire       rst_n,        // C22  按键，低有效，10K 上拉

    output wire [7:0] r_out,        // HD_TX_D23..16
    output wire [7:0] g_out,        // HD_TX_D15..8
    output wire [7:0] b_out,        // HD_TX_D7..0
    output wire       de_out,       // HD_TX_DE
    output wire       hs_out,       // HD_TX_HS
    output wire       vs_out,       // HD_TX_VS
    output wire       pixclk_out,   // HD_TX_PCLK

    inout  wire       hd_sda,       // HSP_SDA  -> MS7210 pin11
    output wire       hd_scl,       // HSP_SCL  -> MS7210 pin12

    output wire       led_int,      // A20 USER_LED0
    output wire       rstn_out,     // G25 -> MS7210 pin33 RSTN

    input  wire       uart_rxd,     // B24  CP2102 TXD -> FPGA
    output wire       uart_txd      // C24  FPGA -> CP2102 RXD
);

    //==================================================================
    // 1. 上电复位（不依赖外部按键，保证一定能启动）
    //    27MHz 下 2^16 = 65536 拍 ≈ 2.4ms
    //==================================================================
    reg [15:0] por_cnt;
    reg        por_n;

    always @(posedge sys_clk) begin
        if (por_cnt != 16'hFFFF) begin
            por_cnt <= por_cnt + 1'b1;
            por_n   <= 1'b0;
        end
        else begin
            por_n   <= 1'b1;
        end
    end

    wire sys_rst_n = por_n & rst_n;

    //==================================================================
    // 2. 像素时钟 PLL：27MHz -> 25.175MHz
    //    pll_27m_to_vga.v : RATIOI=1 RATIOM=1 RATIOF=41.375 RATIO0=44.375
    //    VCO = 27*41.375 = 1117.125MHz，CLKOUT0 = 1117.125/44.375 = 25.175MHz
    //==================================================================
    wire clk_vga_raw;
    wire pll_lock;

    pll_27m_to_vga u_pll(
        .clkin1  (sys_clk    ),
        .clkout0 (clk_vga_raw),
        .lock    (pll_lock   )
    );

    // PLL 设为 NO BUFFER，需要自己加一级全局时钟缓冲
    wire clk_vga;
    GTP_CLKBUFG u_clkbufg(
        .CLKIN  (clk_vga_raw),
        .CLKOUT (clk_vga    )
    );

    //==================================================================
    // 3. 复位跨时钟域：异步置位、同步释放（三级）
    //    直接拿 27MHz 域的 por_n 扇出到 25MHz 域全部复位端会造成
    //    recovery 违规（实测 WNS -3.42ns），这里做同步器。
    //==================================================================
    reg [2:0] por_vga_sync;

    always @(posedge clk_vga or negedge sys_rst_n) begin
        if (!sys_rst_n) por_vga_sync <= 3'b000;
        else            por_vga_sync <= {por_vga_sync[1:0], 1'b1};
    end

    wire rst_n_vga = por_vga_sync[2];

    //==================================================================
    // 4. 视频时序：1280x720@60，PCLK 74.25MHz（CEA-861）
    //==================================================================
    wire [11:0] pix_x;
    wire [11:0] pix_y;

    wire [7:0] r_t, g_t, b_t;      // timing 自己产生的 720p 棋盘格（IMG_EN=0 兜底）
    wire       hs_t, vs_t, de_t;

    video_timing_720p u_timing(
        .clk   (clk_vga  ),
        .rst_n (rst_n_vga),
        .pix_x (pix_x    ),
        .pix_y (pix_y    ),
        .hs    (hs_t     ),
        .vs    (vs_t     ),
        .de    (de_t     ),
        .r     (r_t      ),
        .g     (g_t      ),
        .b     (b_t      )
    );

    //==================================================================
    // 4b. 图像通路：左右并排 A/B 对比
    //
    //   左半屏 x 0..639    : raw_sel=1，直通不校正 -> 畸变原图（格线弯曲）
    //   右半屏 x 640..1279 : 二阶径向 + 切向校正 + 双线性（格线笔直）
    //
    //   两块都是 1:1、512x480 有效区、左右各 64px 黑边。一屏同时读出：
    //     · 左边弯曲、右边笔直  -> 畸变模型与逆映射都对
    //     · 中间 128px 黑带      -> 两块窗口的边界都在正确位置
    //     · 上下深蓝带           -> 720p 时序正确、显示器锁定
    //     · 顶部左暗红/右暗绿    -> 一眼分清哪边是哪个
    //  IMG_EN = 0 时整体旁路，回到 720p 原生棋盘格（查 HDMI 链路用）
    //==================================================================
    parameter IMG_EN = 1'b1;

    localparam [11:0] WIN_OY = 12'd120;        // 480 高窗口在 720 里居中
    localparam [11:0] LAB_OY = 12'd100;        // 彩色标签带 100..119
    localparam [23:0] BORDER = 24'h00_30_70;   // 深蓝底
    localparam [23:0] TAG_A  = 24'hC0_28_28;   // 左：暗红
    localparam [23:0] TAG_B  = 24'h28_C0_28;   // 右：暗绿

    wire in_row  = (pix_y >= WIN_OY) && (pix_y < WIN_OY + 12'd480);
    wire lab_row = (pix_y >= LAB_OY) && (pix_y < WIN_OY);
    wire right_p = (pix_x >= 12'd640);

    // 窗口内局部坐标；行外回 0，避免 12 位相减回绕把 Q8 坐标算溢出
    wire [11:0] wx = right_p ? (pix_x - 12'd640) : pix_x;
    wire [11:0] wy = in_row  ? (pix_y - WIN_OY)  : 12'd0;

    wire [7:0] r_i, g_i, b_i;
    wire       hs_i, vs_i, de_i;

    //==================================================================
    // 4b1. 仿射模式轮换（高阶任务 1 的演示节奏）
    //      74.25MHz 下数 371,250,000 拍 = 5.00 秒，每 5 秒换一种几何：
    //      0 恒等 -> 1 旋转 8° -> 2 剪切 -> 3 旋转+放大 -> 回到 0
    //      接上串口后，把 af_mode 改成"上位机下发寄存器"即可，其余一行不用改
    //==================================================================
    parameter AF_EN = 1'b1;
    reg [28:0] af_tick;
    reg [1:0]  af_mode;

    always @(posedge clk_vga or negedge rst_n_vga) begin
        if (!rst_n_vga) begin
            af_tick <= 29'd0;
            af_mode <= 2'd0;
        end
        else if (!AF_EN) af_mode <= 2'd0;
        else if (af_tick >= 29'd371_250_000) begin
            af_tick <= 29'd0;
            af_mode <= af_mode + 1'b1;
        end
        else begin
            af_tick <= af_tick + 1'b1;
        end
    end

    //------------------------------------------------------------------
    // 串口指令（高阶任务 1）：sys_clk 域接收解析，跨到 clk_vga 域使用
    //------------------------------------------------------------------
    wire signed [15:0] cmd_a, cmd_b, cmd_c, cmd_d, cmd_tx, cmd_ty;
    wire               cmd_ovr;
    wire [2:0]         cmd_gam;
    wire [7:0]         cmd_cnt;

    uart_cmd u_uart_cmd(
        .clk     (sys_clk   ),
        .rst_n   (sys_rst_n ),
        .rxd     (uart_rxd  ),
        .txd     (uart_txd  ),
        .af_a    (cmd_a     ),
        .af_b    (cmd_b     ),
        .af_c    (cmd_c     ),
        .af_d    (cmd_d     ),
        .af_tx   (cmd_tx    ),
        .af_ty   (cmd_ty    ),
        .af_ovr  (cmd_ovr   ),
        .gam_fix (cmd_gam   ),
        .dbg_cnt (cmd_cnt   )
    );

    // 两级同步 + 帧同步锁存：参数是慢变量，但必须整组生效，
    // 否则一帧内只更新了半个矩阵会看到画面错位一格
    wire [96:0] cmd_bus = {cmd_ovr, cmd_a, cmd_b, cmd_c, cmd_d, cmd_tx, cmd_ty};
    reg  [96:0] cmd_s1, cmd_s2, afm_lat;
    reg         vs_sd;

    always @(posedge clk_vga or negedge rst_n_vga) begin
        if (!rst_n_vga) begin
            cmd_s1  <= 97'd0;
            cmd_s2  <= 97'd0;
            afm_lat <= 97'd0;
            vs_sd   <= 1'b0;
        end
        else begin
            cmd_s1 <= cmd_bus;
            cmd_s2 <= cmd_s1;
            vs_sd  <= vs_t;
            if (vs_t && !vs_sd) afm_lat <= cmd_s2;   // 帧起始整组锁存
        end
    end

    // gamma 档位（0~3 固定档，4 = 交给自适应/DEMO 逻辑）
    reg [2:0] cmd_gam_s1, cmd_gam_s2;
    always @(posedge clk_vga or negedge rst_n_vga) begin
        if (!rst_n_vga) begin
            cmd_gam_s1 <= 3'd4;
            cmd_gam_s2 <= 3'd4;
        end
        else begin
            cmd_gam_s1 <= cmd_gam;
            cmd_gam_s2 <= cmd_gam_s1;
        end
    end

    img_path u_img_path(
        .clk    (clk_vga       ),
        .rst_n  (rst_n_vga     ),
        .pix_x  (wx            ),
        .pix_y  (wy            ),
        .de_in  (de_t & in_row ),
        .hs_in  (hs_t          ),
        .vs_in  (vs_t          ),
        .raw_sel(~right_p      ),
        .af_mode(af_mode       ),
        .afm_en (afm_lat[96]   ),
        .afm_a  (afm_lat[95:80]),
        .afm_b  (afm_lat[79:64]),
        .afm_c  (afm_lat[63:48]),
        .afm_d  (afm_lat[47:32]),
        .afm_tx (afm_lat[31:16]),
        .afm_ty (afm_lat[15: 0]),
        .r_out  (r_i           ),
        .g_out  (g_i           ),
        .b_out  (b_i           ),
        .de_out (de_i          ),
        .hs_out (hs_i          ),
        .vs_out (vs_i          )
    );

    //==================================================================
    // 4b2. Gamma 校正（高阶任务 3 —— 自适应预处理）
    //
    //  3 块 1024x8 同步读 RAM，地址 {档位[1:0], 像素[7:0]}：
    //      档位 0  γ=0.55  强提亮（夜景 / 逆光下补偿）
    //      档位 1  γ=0.78  轻提亮
    //      档位 2  γ=1.00  直通（正常光照）
    //      档位 3  γ=1.45  压暗（强光 / 过曝）
    //  曲线由 gam_lut.hex 给（4 档 x 256），改曲线只换文件，不动 RTL。
    //
    //  自适应：按帧统计有效区亮度均值（每像素加 G 通道，窗口 512x480，
    //  帧末右移 18 位 ≈ /262144，与 /245760 差 6.7%，做选档足够），
    //  再按阈值自动选档 —— 这就是"针对强光/夜间环境的自适应 Gamma"。
    //
    //  插入位置：双线性插值之后、送屏之前（S10），只加 1 拍延迟。
    //==================================================================
    parameter GAMMA_EN = 1'b1;
    // 演示模式：1 = 四档曲线每 5 秒循环（灰阶图对比录屏用），0 = 正常自适应
    parameter GAMMA_DEMO = 1'b0;

    // 三个独立数组（而不是一个数组读三次）：单口 RAM 只有一个读口，
    // 三个地址同时读会逼综合器复制三份，不如一开始就分开写，各推一块 BRAM
    reg [7:0] gam_rt [0:1023];
    reg [7:0] gam_gt [0:1023];
    reg [7:0] gam_bt [0:1023];

    initial begin
        $readmemh("D:/pango/img_correct/img_correct_backup_vga/gam_lut.hex", gam_rt);
        $readmemh("D:/pango/img_correct/img_correct_backup_vga/gam_lut.hex", gam_gt);
        $readmemh("D:/pango/img_correct/img_correct_backup_vga/gam_lut.hex", gam_bt);
    end

    // 逐帧亮度统计（用未加 Gamma 的原始值）
    reg [31:0] lum_sum;
    reg [7:0]  lum_mean;
    reg        vs_id;

    always @(posedge clk_vga or negedge rst_n_vga) begin
        if (!rst_n_vga) begin
            lum_sum  <= 32'd0;
            lum_mean <= 8'd128;
            vs_id    <= 1'b0;
        end
        else begin
            vs_id <= vs_i;
            if (de_i)                lum_sum <= lum_sum + {24'd0, g_i};
            if (vs_i && !vs_id) begin
                lum_mean <= lum_sum[25:18];
                lum_sum  <= 32'd0;
            end
        end
    end

    // 演示档位轮换（GAMMA_DEMO=1 时生效，节拍与仿射一样是 5 秒）
    reg [28:0] gd_tick;
    reg [1:0]  gd_sel;

    always @(posedge clk_vga or negedge rst_n_vga) begin
        if (!rst_n_vga) begin
            gd_tick <= 29'd0;
            gd_sel  <= 2'd0;
        end
        else if (GAMMA_DEMO == 1'b0) begin
            gd_tick <= 29'd0;
            gd_sel  <= 2'd0;
        end
        else if (gd_tick >= 29'd371_250_000) begin
            gd_tick <= 29'd0;
            gd_sel  <= gd_sel + 1'b1;
        end
        else begin
            gd_tick <= gd_tick + 1'b1;
        end
    end

    // 自适应选档
    reg [1:0] gam_sel;

    always @(posedge clk_vga or negedge rst_n_vga) begin
        if (!rst_n_vga)              gam_sel <= 2'd2;
        else if (GAMMA_EN == 1'b0)   gam_sel <= 2'd2;
        else if (GAMMA_DEMO == 1'b1) gam_sel <= gd_sel;
        else if (lum_mean < 8'd50 )  gam_sel <= 2'd0;   // 很暗 -> 强提亮
        else if (lum_mean < 8'd110)  gam_sel <= 2'd1;   // 偏暗 -> 轻提亮
        else if (lum_mean < 8'd190)  gam_sel <= 2'd2;   // 正常 -> 直通
        else                         gam_sel <= 2'd3;   // 过亮 -> 压暗
    end

    // 串口下发的固定档优先（G0~G3）；bit2=1 表示"自动"，交回自适应/DEMO 逻辑
    wire [1:0] gam_use = cmd_gam_s2[2] ? gam_sel : cmd_gam_s2[1:0];

    wire [9:0] gam_ar = {gam_use, r_i};
    wire [9:0] gam_ag = {gam_use, g_i};
    wire [9:0] gam_ab = {gam_use, b_i};

    reg [7:0] gr_10, gg_10, gb_10;

    always @(posedge clk_vga) begin
        gr_10 <= gam_rt[gam_ar];
        gg_10 <= gam_gt[gam_ag];
        gb_10 <= gam_bt[gam_ab];
    end

    // img_path 是 9 级流水，行有效/标签/左右 也要延迟 9 拍才能对齐
    reg [9:0] de_d, row_d, lab_d, rgt_d;
    always @(posedge clk_vga or negedge rst_n_vga) begin
        if (!rst_n_vga) begin
            de_d  <= 10'd0;
            row_d <= 10'd0;
            lab_d <= 10'd0;
            rgt_d <= 10'd0;
        end
        else begin
            de_d  <= {de_d[8:0],  de_t   };
            row_d <= {row_d[8:0], in_row };
            lab_d <= {lab_d[8:0], lab_row};
            rgt_d <= {rgt_d[8:0], right_p};
        end
    end

    // Gamma 多了一拍，img_path 的 de/hs/vs 也要跟着多延一拍，否则同步信号
    // 会早于像素一个 clock，屏幕上表现为整体右移 1 像素 + 顶部一行错位
    reg de_i_d, hs_i_d, vs_i_d;
    always @(posedge clk_vga or negedge rst_n_vga) begin
        if (!rst_n_vga) begin
            de_i_d <= 1'b0;  hs_i_d <= 1'b0;  vs_i_d <= 1'b0;
        end
        else begin
            de_i_d <= de_i;  hs_i_d <= hs_i;  vs_i_d <= vs_i;
        end
    end

    wire de_img  = de_d[9];
    wire row_img = row_d[9];
    wire lab_img = lab_d[9];
    wire rgt_img = rgt_d[9];

    // Gamma 只作用于右半屏（校正链输出），左半屏保持原始线性灰阶，
    // 这样同一帧内左右并排就是"处理前 / 处理后"的直接对比。
    wire gam_on  = GAMMA_EN && rgt_img;
    wire [7:0] r_g = gam_on ? gr_10 : r_i;
    wire [7:0] g_g = gam_on ? gg_10 : g_i;
    wire [7:0] b_g = gam_on ? gb_10 : b_i;

    wire [23:0] bg = lab_img ? (rgt_img ? TAG_B : TAG_A) : BORDER;

    // 有效区内：img_path 有值就出图；窗口内但无值（左右 64px 黑边）出纯黑；窗口外出底
    assign r_out  = IMG_EN ? (de_img ? (de_i_d ? r_g : (row_img ? 8'd0 : bg[23:16])) : 8'd0) : r_t;
    assign g_out  = IMG_EN ? (de_img ? (de_i_d ? g_g : (row_img ? 8'd0 : bg[15: 8])) : 8'd0) : g_t;
    assign b_out  = IMG_EN ? (de_img ? (de_i_d ? b_g : (row_img ? 8'd0 : bg[ 7: 0])) : 8'd0) : b_t;
    assign de_out = IMG_EN ? de_img : de_t;
    assign hs_out = IMG_EN ? hs_i_d : hs_t;
    assign vs_out = IMG_EN ? vs_i_d : vs_t;

    //==================================================================
    // 5. 像素时钟输出（反相）
    //    数据在 clk_vga 上升沿更新，PCLK 反相后在数据眼图正中间采样
    //==================================================================
    parameter PCLK_INVERT = 1'b1;
    assign pixclk_out = PCLK_INVERT ? ~clk_vga : clk_vga;

    //==================================================================
    // 6. MS7210 初始化（27MHz 直接驱动 I2C）
    //==================================================================
    wire       cfg_done;
    wire [5:0] dbg_state;

    //------------------------------------------------------------------
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
    assign hd_sda = tx_sda_en ? tx_sda_out : 1'bz;

    //==================================================================
    // 7. 复位输出：让 MS7210 尽早上电，不等 PLL
    //==================================================================
    assign rstn_out = por_n;

    //==================================================================
    // 8. LED 状态指示
    //==================================================================
    reg [23:0] led_cnt;
    always @(posedge sys_clk) begin
        if (!sys_rst_n) led_cnt <= 24'd0;
        else            led_cnt <= led_cnt + 1'b1;
    end

    // 状态机 one-hot：IDLE=000001 CONECT=000010 INIT=000100
    wire stuck_connect = (dbg_state == 6'b000010);

    assign led_int = cfg_done      ? led_cnt[23] :   // 1.61Hz 慢闪：全部配完
                     stuck_connect ? led_cnt[20] :   // 12.9Hz 快闪：芯片无应答
                                     led_cnt[21];    // 6.44Hz 中速：正在写表

endmodule

//==============================================================================
//  9. 图像通路：畸变反变换 + 双线性重采样（赛题二 基础任务 2 + 3）
//
//  说明：本模块原先单独放在 source/img_path.v，但 PDS 界面每次编译都会重写
//        .pds 的源文件列表，把不在界面列表里的文件抹掉，导致
//        "img_path is referred to undefined module"。
//        因此并入顶层文件，界面怎么重写工程都不影响。
//        改这里的参数（K1_Q14 / K2_Q14 / CORRECT_EN）即可调校正强度。
//==============================================================================
//  9. 图像通路：二阶径向 + 切向畸变校正 + 双线性重采样
//
//  模型（OpenCV 惯例，坐标按"角上半径 = 1.0"归一化）：
//     r2  = x^2 + y^2
//     R   = 1 + k1*r2 + k2*r2^2
//     xd  = x*R + 2*p1*x*y + p2*(r2 + 2*x^2)
//     yd  = y*R + p1*(r2 + 2*y^2) + 2*p2*x*y
//
//  校正走的是"逆向映射"：对每个输出（理想）像素，算出它在畸变图上的
//  落点 (xd,yd)，到那里去采样。这样每个输出像素都有值、不会出现空洞，
//  这是和"正向映射撒点"最本质的区别。
//
//  流水线 9 级，每级同步传递 {valid, hs, vs}，与数据严格对齐：
//     S1 坐标差 Q8 + 归一化乘 s    S2 r2/xx/yy/xy Q16   S3 scale/tx/ty Q16
//     S4 源坐标 Q8                S5 边缘钳位 + 拆地址/权重
//     S6 ROM 同步读               S7 解包              S8 水平插值
//     S9 垂直插值
//
//  黑边怎么消的（赛题二 基础任务 3 的"消除黑边/空洞"）：
//     逆向映射本身不会产生空洞，但枕形校正要往画面外取点，源图边界外没数据
//     就是黑的（未归一化时越界 20.58%，四角黑块约 60px）。
//     解法是先把输出坐标乘 s=0.83466 再进畸变模型，让最外圈正好落在源图
//     边界内 —— 越界降到 0.000%，等效画面放大 1.198 倍，且有边缘钳位兜底。
//     注意 s 必须乘在"坐标"上，不能乘在 k1/k2/基数上（见 S1 那段注释）。
//
//  参数共三套（见下方 parameter 区，切换时注释掉现用那 4 行再放开目标那 4 行）：
//    桶形    k1=-0.120 k2=+0.040 p1=+0.020 p2=+0.012  ← 已上板验证，保留在注释里
//    枕形轻量 k1=+0.100 k2=+0.020 p1=+0.010 p2=+0.006  ← 第一版枕形，屏上看不明显
//    枕形加强 k1=+0.200 k2=+0.050 p1=+0.010 p2=+0.006  ← 当前生效
//  算法/流水线/ROM 全不用动，只换常数。
//  raw_sel=1 时旁路校正，直出畸变原图做左右对比（1:1，不缩放）。
//==============================================================================
module img_path(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] pix_x,      // 窗口内坐标 0..639
    input  wire [11:0] pix_y,      // 窗口内坐标 0..479
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        raw_sel,    // 1 = 不校正，直出畸变原图
    input  wire [1:0]  af_mode,    // 仿射模式（高阶任务1）：0=恒等 1=旋转 2=剪切 3=旋转+缩放
    input  wire        afm_en,     // 1 = 使用上位机串口下发的自定义矩阵
    input  wire signed [15:0] afm_a,
    input  wire signed [15:0] afm_b,
    input  wire signed [15:0] afm_c,
    input  wire signed [15:0] afm_d,
    input  wire signed [15:0] afm_tx,
    input  wire signed [15:0] afm_ty,
    output reg  [7:0]  r_out,
    output reg  [7:0]  g_out,
    output reg  [7:0]  b_out,
    output reg         de_out,
    output reg         hs_out,
    output reg         vs_out
);

    //------------------------------------------------------------------
    // 畸变系数（Q2.14）—— 三套参数，默认枕形加强版，前两套备份在注释里
    //------------------------------------------------------------------
    // 【当前生效】枕形加强版（k1 > 0）：格子向外侧撑开，越到边上越大
    //   上一版 k1=+0.100 在屏上只看到边缘格子大 5%，因为可见区只到 r≈0.8，
    //   角上那 +43px 被窗口裁掉了。提到 +0.200 后：边中点 +40.7px、角上 +90.5px，
    //   边缘格子比中心大 9~12%，左右一眼能分开。
    //   代价：越界 12.4% → 20.6%，右图黑边变宽（下一步归一化消掉）
    parameter signed [15:0] K1_Q14 =  16'sd3277;   // +0.200  径向一阶（正=枕形 负=桶形）
    parameter signed [15:0] K2_Q14 =  16'sd819;    // +0.050  径向二阶（四阶项）
    parameter signed [15:0] P1_Q14 =  16'sd164;    // +0.010  切向 p1
    parameter signed [15:0] P2_Q14 =  16'sd98;     // +0.006  切向 p2
    parameter               CORRECT_EN = 1'b1;     // 0 = 全局关掉校正

    //【备份】枕形轻量版（第一版上板，屏上看"不明显"）
    // parameter signed [15:0] K1_Q14 =  16'sd1638;   // +0.100
    // parameter signed [15:0] K2_Q14 =  16'sd328;    // +0.020
    // parameter signed [15:0] P1_Q14 =  16'sd164;    // +0.010
    // parameter signed [15:0] P2_Q14 =  16'sd98;     // +0.006
    //
    //【备份】桶形（k1 < 0，已上板验证通过：角上 -29.0px、边中点 -12.8px）
    //        要切回桶形，注释掉上面 4 行、放开下面 4 行即可，其余逻辑不用动
    // parameter signed [15:0] K1_Q14 = -16'sd1966;   // -0.120  径向一阶（正=枕形 负=桶形）
    // parameter signed [15:0] K2_Q14 =  16'sd655;    // +0.040  径向二阶（四阶项）
    // parameter signed [15:0] P1_Q14 =  16'sd328;    // +0.020  切向 p1
    // parameter signed [15:0] P2_Q14 =  16'sd197;    // +0.012  切向 p2
    //
    //【备份】仅 k1、无二阶无切向（最早期版本，只用来验证一阶径向项）
    // parameter signed [15:0] K1_Q14 = -16'sd1966;   // -0.120
    // parameter signed [15:0] K2_Q14 =  16'sd0;      //  0
    // parameter signed [15:0] P1_Q14 =  16'sd0;      //  0
    // parameter signed [15:0] P2_Q14 =  16'sd0;      //  0

    localparam [11:0] WIN_X0 = 12'd64;             // 512 宽窗口在 640 里居中
    localparam [11:0] WIN_X1 = 12'd576;
    localparam [11:0] WIN_Y1 = 12'd480;

    localparam signed [19:0] CX20 = 20'sd320;      // = WIN_X0 + 256
    localparam signed [19:0] CY20 = 20'sd240;      // 源图中心 256 对齐到输出 y=240

    // 362.04 px（半对角线）的 Q8，把 Q16 归一化量换成 Q8 像素
    localparam signed [21:0] TANQ = 22'sd92682;

    //==================================================================
    // S1：像素坐标差（Q8），并判断是否在显示窗口内
    //     —— 校正支路在这里先把坐标乘归一化系数 s，消黑边（见文件头）
    //==================================================================
    wire win_c = (pix_x >= WIN_X0) && (pix_x < WIN_X1) && (pix_y < WIN_Y1);

    wire signed [19:0] dx_c = ($signed({1'b0, pix_x}) - CX20) <<< 8;
    wire signed [19:0] dy_c = ($signed({1'b0, pix_y}) - CY20) <<< 8;

    //------------------------------------------------------------------
    // 归一化缩放 s：消黑边的核心
    //
    //  枕形校正要往画面外取点（src = r·(1+k1r²) > r），源图只有 512×512，
    //  取不到就是黑的。做法是把输出坐标先乘 s 再送进畸变模型：
    //      src = CEN + (s·dx)·R(s·dx) = CEN + D(s·p)
    //  反解出来是 ideal(s·p)，也就是"均匀放大 1/s 倍的理想图"——
    //  几何严格正确，只是视野略收窄，四周一个黑点都没有。
    //
    //  注意不能把 s 乘到 k1/k2/65536 上：那样算的是 s·D(p)，
    //  反解会残留 (1+k1p²(1-s²)) 的随半径起伏（k=0.2/s=0.8 时格宽
    //  75,78,80,80,77,76，本该均匀 80），模型已实测证伪。
    //
    //  s 的取值：扫出"全场源坐标都不越界"的最大值 = 0.83508；
    //  这里取 0.83466（Q16=54700）留一点余量。
    //  等效放大 1.198 倍 → 校正后格宽 64 → 76.6 px（模型残差 1.19/255）。
    //------------------------------------------------------------------
    localparam signed [16:0] S_Q16 = 17'sd54700;   // s = 0.83466

    //==================================================================
    // S0b：仿射变换（高阶任务 1 —— 任意角度 / 动态矫正）
    //
    //  在畸变逆映射之前，对输出坐标做一次 2x3 仿射：
    //      x' = a*x + b*y + tx
    //      y' = c*x + d*y + ty
    //  系数 Q12（1.0 = 4096），平移 Q8（1px = 256）。
    //      旋转 θ：a=cosθ  b=-sinθ  c=sinθ  d=cosθ
    //      剪切  ：b≠0 或 c≠0   （等价于相机侧倾的线性近似）
    //      缩放  ：a=d=1/s
    //
    //  为什么放在畸变之前：world --仿射--> --畸变逆映射--> 源坐标，
    //  几何上等于"先把相机摆正、再纠镜头畸变"，两步解耦，换 k1 不用重算仿射。
    //
    //  模式由 af_mode 选择（当前每 5 秒自动轮换一次，方便现场演示；
    //  接上串口后把 af_mode 换成上位机下发的寄存器即可）。
    //  raw_sel=1（左半屏）走 1:1 直通，保持"未经处理的畸变原图"做对比。
    //==================================================================
    reg signed [15:0] af_a, af_b, af_c, af_d, af_tx, af_ty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            af_a <= 16'sd4096; af_b <= 16'sd0;
            af_c <= 16'sd0;    af_d <= 16'sd4096;
            af_tx<= 16'sd0;    af_ty<= 16'sd0;
        end
        else if (afm_en) begin          // 上位机通过串口下发的自定义矩阵
            af_a <= afm_a;  af_b <= afm_b;
            af_c <= afm_c;  af_d <= afm_d;
            af_tx<= afm_tx; af_ty<= afm_ty;
        end
        else begin
            case (af_mode)
                2'd0: begin   // 恒等（验证仿射通路本身不引入形变）
                    af_a <= 16'sd4096; af_b <= 16'sd0;
                    af_c <= 16'sd0;    af_d <= 16'sd4096;
                    af_tx<= 16'sd0;    af_ty<= 16'sd0;
                end
                2'd1: begin   // 旋转 +8°: cos=0.9903 sin=0.1392
                    af_a <= 16'sd4056; af_b <= -16'sd570;
                    af_c <= 16'sd570;  af_d <= 16'sd4056;
                    af_tx<= 16'sd0;    af_ty<= 16'sd0;
                end
                2'd2: begin   // 剪切（相机侧倾的线性近似）
                    af_a <= 16'sd4096; af_b <= 16'sd820;
                    af_c <= 16'sd0;    af_d <= 16'sd4096;
                    af_tx<= 16'sd0;    af_ty<= 16'sd0;
                end
                default: begin // 旋转 8° + 放大 1.111（视场收窄，看是否仍不出黑边）
                    af_a <= 16'sd4551; af_b <= -16'sd633;
                    af_c <= 16'sd633;  af_d <= 16'sd4551;
                    af_tx<= 16'sd0;    af_ty<= 16'sd0;
                end
            endcase
        end
    end

    wire signed [35:0] af_ax = dx_c * af_a;
    wire signed [35:0] af_by = dy_c * af_b;
    wire signed [35:0] af_cx = dx_c * af_c;
    wire signed [35:0] af_dy = dy_c * af_d;

    wire signed [35:0] af_xq = (af_ax + af_by) >>> 12;   // 回到 Q8
    wire signed [35:0] af_yq = (af_cx + af_dy) >>> 12;

    wire signed [19:0] dx_af = af_xq[19:0] + {{4{af_tx[15]}}, af_tx};
    wire signed [19:0] dy_af = af_yq[19:0] + {{4{af_ty[15]}}, af_ty};

    wire signed [36:0] dx_nw = (dx_af * S_Q16) >>> 16;
    wire signed [36:0] dy_nw = (dy_af * S_Q16) >>> 16;

    // 直通（raw_sel）支路保持 1:1，不缩放 —— 左边那张要的是"原封不动的原图"
    wire signed [19:0] dx_s = raw_sel ? dx_c : $signed(dx_nw[19:0]);
    wire signed [19:0] dy_s = raw_sel ? dy_c : $signed(dy_nw[19:0]);

    reg signed [19:0] dx1, dy1;
    reg        [2:0]  f1;                          // {valid, hs, vs}
    reg               raw1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dx1  <= 20'sd0;
            dy1  <= 20'sd0;
            f1   <= 3'b000;
            raw1 <= 1'b0;
        end
        else begin
            dx1  <= dx_s;
            dy1  <= dy_s;
            f1   <= {win_c & de_in, hs_in, vs_in};
            raw1 <= raw_sel;
        end
    end

    //==================================================================
    // S2：归一化到 Q14，求 r2 / x^2 / y^2 / x*y（均 Q16，角上 = 65536）
    //==================================================================
    wire signed [17:0] u_w = dx1 >>> 2;            // Q14
    wire signed [17:0] v_w = dy1 >>> 2;
    wire signed [35:0] u2_w = u_w * u_w;
    wire signed [35:0] v2_w = v_w * v_w;
    wire signed [35:0] uv_w = u_w * v_w;

    wire signed [33:0] r2_w  = (u2_w + v2_w) >>> 13;
    wire signed [33:0] xx_w  = u2_w >>> 13;
    wire signed [33:0] yy_w  = v2_w >>> 13;
    wire signed [33:0] pxy_w = uv_w >>> 13;

    reg signed [33:0] r2_2, xx_2, yy_2, pxy_2;
    reg signed [19:0] dx2, dy2;
    reg        [2:0]  f2;
    reg               raw2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_2 <= 34'sd0;  xx_2 <= 34'sd0;
            yy_2 <= 34'sd0;  pxy_2 <= 34'sd0;
            dx2  <= 20'sd0;  dy2  <= 20'sd0;
            f2   <= 3'b000;  raw2 <= 1'b0;
        end
        else begin
            r2_2  <= r2_w;
            xx_2  <= xx_w;
            yy_2  <= yy_w;
            pxy_2 <= pxy_w;
            dx2   <= dx1;
            dy2   <= dy1;
            f2    <= f1;
            raw2  <= raw1;
        end
    end

    //==================================================================
    // S3：径向 scale = 1 + k1*r2 + k2*r2^2   (Q16)
    //     切向 tx = 2*p1*xy + p2*(r2 + 2x^2) / ty = p1*(r2 + 2y^2) + 2*p2*xy
    //==================================================================
    // r2^2 先降精度再平方，省乘法器：r2>>8 = Q8，平方后正好回到 Q16
    wire signed [25:0] r2s_w  = r2_2 >>> 8;
    wire signed [51:0] r2sq_w = r2s_w * r2s_w;

    wire signed [49:0] t1p_w  = K1_Q14 * r2_2;      // Q2.30
    wire signed [39:0] t1_w   = t1p_w >>> 14;       // Q2.16
    wire signed [49:0] t2p_w  = K2_Q14 * r2sq_w;
    wire signed [39:0] t2_w   = t2p_w >>> 14;

    wire signed [39:0] rad_w  = 40'sd65536 + t1_w + t2_w;

    // 切向：先算 r2 + 2x^2 / r2 + 2y^2
    wire signed [34:0] r2xx_w = r2_2 + (xx_2 <<< 1);
    wire signed [34:0] r2yy_w = r2_2 + (yy_2 <<< 1);

    wire signed [50:0] ta1_w = P1_Q14 * pxy_2;      // p1*xy
    wire signed [50:0] ta2_w = P2_Q14 * r2xx_w;     // p2*(r2+2x^2)
    wire signed [50:0] ta3_w = P1_Q14 * r2yy_w;     // p1*(r2+2y^2)
    wire signed [50:0] ta4_w = P2_Q14 * pxy_2;      // p2*xy

    wire signed [39:0] tx_w = ((ta1_w <<< 1) + ta2_w) >>> 14;   // Q16
    wire signed [39:0] ty_w = (ta3_w + (ta4_w <<< 1)) >>> 14;

    wire use_corr = CORRECT_EN & ~raw2;

    wire signed [39:0] scale_w = use_corr ? rad_w : 40'sd65536;
    wire signed [39:0] tx_o_w  = use_corr ? tx_w  : 40'sd0;
    wire signed [39:0] ty_o_w  = use_corr ? ty_w  : 40'sd0;

    reg signed [39:0] sc_3, tx_3, ty_3;
    reg signed [19:0] dx3, dy3;
    reg        [2:0]  f3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sc_3 <= 40'sd65536;
            tx_3 <= 40'sd0;  ty_3 <= 40'sd0;
            dx3  <= 20'sd0;  dy3  <= 20'sd0;
            f3   <= 3'b000;
        end
        else begin
            sc_3 <= scale_w;
            tx_3 <= tx_o_w;
            ty_3 <= ty_o_w;
            dx3  <= dx2;
            dy3  <= dy2;
            f3   <= f2;
        end
    end

    //==================================================================
    // S4：源坐标（Q8，以源图左上角为原点）
    //     src = 256 + dx*scale + tx*362      （tx 单位是"角上半径"，1.0=362px）
    //==================================================================
    wire signed [59:0] sxd_p = dx3 * sc_3;       // Q8 * Q16 = Q24
    wire signed [59:0] syd_p = dy3 * sc_3;
    wire signed [43:0] sxd_w = sxd_p >>> 16;     // -> Q8
    wire signed [43:0] syd_w = syd_p >>> 16;

    wire signed [61:0] txp_p = tx_3 * TANQ;      // Q16 * Q8 = Q24
    wire signed [61:0] typ_p = ty_3 * TANQ;
    wire signed [45:0] txp_w = txp_p >>> 16;     // -> Q8 像素
    wire signed [45:0] typ_w = typ_p >>> 16;

    wire signed [45:0] sx_w = 46'sd65536 + {{2{sxd_w[43]}}, sxd_w} + txp_w;
    wire signed [45:0] sy_w = 46'sd65536 + {{2{syd_w[43]}}, syd_w} + typ_w;

    reg signed [45:0] sx_4, sy_4;
    reg        [2:0]  f4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sx_4 <= 46'sd0;
            sy_4 <= 46'sd0;
            f4   <= 3'b000;
        end
        else begin
            sx_4 <= sx_w;
            sy_4 <= sy_w;
            f4   <= f3;
        end
    end

    //==================================================================
    // S5：边缘钳位 + 拆成整数部分（寻址）和 8 位小数（插值权重）
    //
    //  归一化之后理论上全场都不越界（模型实测 0.000%），这里的钳位只是
    //  兜底：万一还有个别像素跑出去，就贴边取像素（fx/fy 自然为 0），
    //  显示成"边界像素被拉了一下"，而不是一个黑点。
    //  取 510 而不是 511，保证 x0+1 / y0+1 落在 ROM 内。
    //==================================================================
    localparam signed [45:0] SRC_MAX = 46'sd130560;    // 510 << 8

    wire signed [45:0] sx_c = (sx_4 < 46'sd0)     ? 46'sd0  :
                              (sx_4 > SRC_MAX)    ? SRC_MAX : sx_4;
    wire signed [45:0] sy_c = (sy_4 < 46'sd0)     ? 46'sd0  :
                              (sy_4 > SRC_MAX)    ? SRC_MAX : sy_4;

    wire inrng_w = 1'b1;                   // 钳位后不存在"取不到"的像素

    wire [8:0] x0_w = sx_c[16:8];
    wire [8:0] y0_w = sy_c[16:8];
    wire [7:0] fx_w = sx_c[7:0];
    wire [7:0] fy_w = sy_c[7:0];

    wire [7:0] c0_w  = x0_w[8:1];                  // x0 >> 1
    wire [7:0] c1_w  = (x0_w + 9'd1) >> 1;         // (x0+1) >> 1
    wire [7:0] r0_w  = y0_w[8:1];                  // y0 >> 1
    wire [7:0] r1_w  = (y0_w + 9'd1) >> 1;

    wire xp_w = x0_w[0];
    wire yp_w = y0_w[0];

    // 4 块 ROM 各自的地址：行取 r0/r1 中奇偶匹配的那个，列同理
    wire [15:0] addr_ee = { (yp_w ? r1_w : r0_w), (xp_w ? c1_w : c0_w) };
    wire [15:0] addr_eo = { (~yp_w ? r1_w : r0_w), (xp_w ? c1_w : c0_w) };
    wire [15:0] addr_oe = { (yp_w ? r1_w : r0_w), (~xp_w ? c1_w : c0_w) };
    wire [15:0] addr_oo = { (~yp_w ? r1_w : r0_w), (~xp_w ? c1_w : c0_w) };

    reg [15:0] a_ee, a_eo, a_oe, a_oo;
    reg [7:0]  fx_5, fy_5;
    reg        xp_5, yp_5, rng5;
    reg [2:0]  f5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_ee <= 16'd0;  a_eo <= 16'd0;
            a_oe <= 16'd0;  a_oo <= 16'd0;
            fx_5 <= 8'd0;   fy_5 <= 8'd0;
            xp_5 <= 1'b0;   yp_5 <= 1'b0;  rng5 <= 1'b0;
            f5   <= 3'b000;
        end
        else begin
            a_ee <= addr_ee;  a_eo <= addr_eo;
            a_oe <= addr_oe;  a_oo <= addr_oo;
            fx_5 <= fx_w;     fy_5 <= fy_w;
            xp_5 <= xp_w;     yp_5 <= yp_w;  rng5 <= inrng_w;
            f5   <= f4;
        end
    end

    //==================================================================
    // S6：4 块 ROM 同步读出（同步读 -> 推断为 BRAM）
    //==================================================================
    reg [15:0] mem_ee [0:65535];
    reg [15:0] mem_eo [0:65535];
    reg [15:0] mem_oe [0:65535];
    reg [15:0] mem_oo [0:65535];

    // 绝对路径：综合时的工作目录是 temp_projects/Main_Flow，
    // 用相对路径会找不到文件。换机器要改这四行。
    initial begin
        $readmemh("D:/pango/img_correct/img_correct_backup_vga/rom_ee.hex", mem_ee);
        $readmemh("D:/pango/img_correct/img_correct_backup_vga/rom_eo.hex", mem_eo);
        $readmemh("D:/pango/img_correct/img_correct_backup_vga/rom_oe.hex", mem_oe);
        $readmemh("D:/pango/img_correct/img_correct_backup_vga/rom_oo.hex", mem_oo);
    end

    reg [15:0] q_ee, q_eo, q_oe, q_oo;
    reg [7:0]  fx_6, fy_6;
    reg        xp_6, yp_6, rng6;
    reg [2:0]  f6;

    always @(posedge clk) begin
        q_ee <= mem_ee[a_ee];
        q_eo <= mem_eo[a_eo];
        q_oe <= mem_oe[a_oe];
        q_oo <= mem_oo[a_oo];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fx_6 <= 8'd0;  fy_6 <= 8'd0;
            xp_6 <= 1'b0;  yp_6 <= 1'b0;  rng6 <= 1'b0;
            f6   <= 3'b000;
        end
        else begin
            fx_6 <= fx_5;  fy_6 <= fy_5;
            xp_6 <= xp_5;  yp_6 <= yp_5;  rng6 <= rng5;
            f6   <= f5;
        end
    end

    //==================================================================
    // S7：按奇偶把 4 块 ROM 的输出还原成 2x2 邻域，并解包成 RGB888
    //==================================================================
    wire [15:0] row0_xp0 = yp_6 ? q_eo : q_ee;
    wire [15:0] row0_xp1 = yp_6 ? q_oo : q_oe;
    wire [15:0] row1_xp0 = yp_6 ? q_ee : q_eo;
    wire [15:0] row1_xp1 = yp_6 ? q_oe : q_oo;

    wire [15:0] p00_w = xp_6 ? row0_xp1 : row0_xp0;
    wire [15:0] p10_w = xp_6 ? row0_xp0 : row0_xp1;
    wire [15:0] p01_w = xp_6 ? row1_xp1 : row1_xp0;
    wire [15:0] p11_w = xp_6 ? row1_xp0 : row1_xp1;

    // RGB565 -> RGB888（低位补高位，绿色 6bit）
    function [23:0] unpack565;
        input [15:0] p;
        begin
            unpack565 = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
        end
    endfunction

    wire [23:0] c00 = unpack565(p00_w);
    wire [23:0] c10 = unpack565(p10_w);
    wire [23:0] c01 = unpack565(p01_w);
    wire [23:0] c11 = unpack565(p11_w);

    reg [7:0] r_7, g_7, b_7;          // 左上
    reg [7:0] r_7b, g_7b, b_7b;       // 右上
    reg [7:0] r_7c, g_7c, b_7c;       // 左下
    reg [7:0] r_7d, g_7d, b_7d;       // 右下
    reg [7:0] fx_7, fy_7;
    reg       rng7;
    reg [2:0] f7;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {r_7, g_7, b_7}    <= 24'd0;
            {r_7b, g_7b, b_7b} <= 24'd0;
            {r_7c, g_7c, b_7c} <= 24'd0;
            {r_7d, g_7d, b_7d} <= 24'd0;
            fx_7 <= 8'd0;  fy_7 <= 8'd0;  rng7 <= 1'b0;
            f7   <= 3'b000;
        end
        else begin
            {r_7, g_7, b_7}    <= c00;
            {r_7b, g_7b, b_7b} <= c10;
            {r_7c, g_7c, b_7c} <= c01;
            {r_7d, g_7d, b_7d} <= c11;
            fx_7 <= fx_6;  fy_7 <= fy_6;  rng7 <= rng6;
            f7   <= f6;
        end
    end

    //==================================================================
    // S8：水平方向插值（左右两点按 fx 混合）
    //==================================================================
    function [7:0] lerp8;
        input [7:0] pa;
        input [7:0] pb;
        input [7:0] pw;               // 0..255
        reg signed [9:0]  d;
        reg signed [19:0] m;
        begin
            d     = $signed({2'b00, pb}) - $signed({2'b00, pa});
            m     = d * $signed({2'b00, pw});
            lerp8 = pa + (m >>> 8);
        end
    endfunction

    reg [7:0] tr_8, tg_8, tb_8;       // 上边两点混合
    reg [7:0] br_8, bg_8, bb_8;       // 下边两点混合
    reg [7:0] fy_8;
    reg       rng8;
    reg [2:0] f8;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tr_8 <= 8'd0; tg_8 <= 8'd0; tb_8 <= 8'd0;
            br_8 <= 8'd0; bg_8 <= 8'd0; bb_8 <= 8'd0;
            fy_8 <= 8'd0; rng8 <= 1'b0;
            f8   <= 3'b000;
        end
        else begin
            tr_8 <= lerp8(r_7,  r_7b, fx_7);
            tg_8 <= lerp8(g_7,  g_7b, fx_7);
            tb_8 <= lerp8(b_7,  b_7b, fx_7);
            br_8 <= lerp8(r_7c, r_7d, fx_7);
            bg_8 <= lerp8(g_7c, g_7d, fx_7);
            bb_8 <= lerp8(b_7c, b_7d, fx_7);
            fy_8 <= fy_7;  rng8 <= rng7;
            f8   <= f7;
        end
    end

    //==================================================================
    // S9：垂直方向插值，输出
    //==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_out <= 8'd0;  g_out <= 8'd0;  b_out <= 8'd0;
            de_out <= 1'b0; hs_out <= 1'b0; vs_out <= 1'b0;
        end
        else begin
            r_out  <= lerp8(tr_8, br_8, fy_8);
            g_out  <= lerp8(tg_8, bg_8, fy_8);
            b_out  <= lerp8(tb_8, bb_8, fy_8);
            de_out <= f8[2] & rng8;
            hs_out <= f8[1];
            vs_out <= f8[0];
        end
    end

endmodule

//==================================================================
// 高阶任务 1：上位机串口指令下发
//
//   板上 CP2102（USB Type-C 接口），115200 8N1，一根 Type-C 线接电脑即出现 COM 口
//       FPGA_UART_RXD = B24   （电脑 -> FPGA）
//       FPGA_UART_TXD = C24   （FPGA -> 电脑，字节原样回显）
//
//   协议（ASCII，串口助手直接敲，末尾回车）：
//     S + 24 个十六进制字符  -> 一次写入 6 个系数 a,b,c,d,tx,ty
//                              a~d 为 Q12（1.0 = 4096），tx/ty 为 Q8 有符号
//     M + 1 位数字 0~3       -> 回到内置预设，关闭自定义矩阵
//     G + 1 位数字 0~4       -> 固定 Gamma 档 0~3；4 = 恢复自动/演示档
//     D                      -> 全部恢复默认
//   例：S10000000000001000000000000000        （恒等）
//==================================================================
module uart_cmd #(
    parameter integer CLK_FREQ = 27_000_000,
    parameter integer BAUD     = 115200
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               rxd,
    output wire               txd,

    output reg  signed [15:0] af_a,
    output reg  signed [15:0] af_b,
    output reg  signed [15:0] af_c,
    output reg  signed [15:0] af_d,
    output reg  signed [15:0] af_tx,
    output reg  signed [15:0] af_ty,
    output reg                af_ovr,     // 1 = 使用上面这组自定义矩阵
    output reg  [2:0]         gam_fix,    // 0~3 固定档；4 = 自动
    output reg  [7:0]         dbg_cnt     // 成功执行的指令条数
);

    localparam integer DIV  = CLK_FREQ / BAUD;   // 27MHz/115200 = 234
    localparam integer HALF = DIV / 2;

    //------------------------------------------------------------------
    // 接收
    //------------------------------------------------------------------
    reg  [2:0]  rx_s;
    wire        rxd_s = rx_s[2];

    localparam [1:0] R_IDLE = 2'd0, R_START = 2'd1, R_DATA = 2'd2, R_STOP = 2'd3;

    reg  [1:0]  rst;
    reg  [15:0] rcnt;
    reg  [3:0]  bitn;
    reg  [7:0]  rsh;
    reg  [7:0]  rx_data;
    reg         rx_vld;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s <= 3'b111;  rst <= R_IDLE;  rcnt <= 16'd0;
            bitn <= 4'd0;    rsh  <= 8'd0;   rx_data <= 8'd0;  rx_vld <= 1'b0;
        end
        else begin
            rx_s   <= {rx_s[1:0], rxd};
            rx_vld <= 1'b0;
            case (rst)
                R_IDLE: begin
                    if (!rxd_s) begin rst <= R_START; rcnt <= 16'd0; end
                end
                R_START: begin
                    if (rcnt == HALF - 1) begin
                        rcnt <= 16'd0;
                        if (!rxd_s) begin rst <= R_DATA; bitn <= 4'd0; end
                        else               rst <= R_IDLE;
                    end
                    else rcnt <= rcnt + 1'b1;
                end
                R_DATA: begin
                    if (rcnt == DIV - 1) begin
                        rcnt <= 16'd0;
                        rsh  <= {rxd_s, rsh[7:1]};
                        if (bitn == 4'd7) rst <= R_STOP;
                        else              bitn <= bitn + 1'b1;
                    end
                    else rcnt <= rcnt + 1'b1;
                end
                default: begin   // R_STOP
                    if (rcnt == DIV - 1) begin
                        rst <= R_IDLE;  rx_data <= rsh;  rx_vld <= 1'b1;
                    end
                    else rcnt <= rcnt + 1'b1;
                end
            endcase
        end
    end

    //------------------------------------------------------------------
    // 发送（只做单字节回显，确认链路）
    //------------------------------------------------------------------
    reg  [1:0]  tst;
    reg  [15:0] tcnt;
    reg  [3:0]  tbit;
    reg  [7:0]  tsh;
    reg         txd_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tst <= 2'd0; tcnt <= 16'd0; tbit <= 4'd0; tsh <= 8'd0; txd_r <= 1'b1;
        end
        else begin
            case (tst)
                2'd0: begin
                    txd_r <= 1'b1;
                    if (rx_vld) begin tsh <= rx_data; tst <= 2'd1; tcnt <= 16'd0; end
                end
                2'd1: begin      // 起始位
                    txd_r <= 1'b0;
                    if (tcnt == DIV - 1) begin tcnt <= 16'd0; tst <= 2'd2; tbit <= 4'd0; end
                    else tcnt <= tcnt + 1'b1;
                end
                2'd2: begin      // 8 位数据，LSB 先发
                    txd_r <= tsh[0];
                    if (tcnt == DIV - 1) begin
                        tcnt <= 16'd0;
                        tsh  <= {1'b0, tsh[7:1]};
                        if (tbit == 4'd7) tst <= 2'd3;
                        else              tbit <= tbit + 1'b1;
                    end
                    else tcnt <= tcnt + 1'b1;
                end
                default: begin   // 停止位
                    txd_r <= 1'b1;
                    if (tcnt == DIV - 1) begin tcnt <= 16'd0; tst <= 2'd0; end
                    else tcnt <= tcnt + 1'b1;
                end
            endcase
        end
    end

    assign txd = txd_r;

    //------------------------------------------------------------------
    // 指令解析
    //------------------------------------------------------------------
    function [3:0] hx;
        input [7:0] c;
        begin
            if      (c >= 8'h30 && c <= 8'h39) hx = c - 8'h30;
            else if (c >= 8'h41 && c <= 8'h46) hx = c - 8'h37;
            else if (c >= 8'h61 && c <= 8'h66) hx = c - 8'h57;
            else                               hx = 4'h0;
        end
    endfunction

    localparam [1:0] C_IDLE = 2'd0, C_S = 2'd1, C_M = 2'd2, C_G = 2'd3;

    reg  [1:0]  cst;
    reg  [4:0]  hcnt;
    reg  [95:0] shf;

    wire [95:0] shf_nx = {shf[91:0], hx(rx_data)};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst <= C_IDLE; hcnt <= 5'd0; shf <= 96'd0;
            af_a <= 16'sd4096; af_b <= 16'sd0;
            af_c <= 16'sd0;    af_d <= 16'sd4096;
            af_tx <= 16'sd0;   af_ty <= 16'sd0;
            af_ovr <= 1'b0;    gam_fix <= 3'd4;   dbg_cnt <= 8'd0;
        end
        else if (rx_vld) begin
            case (cst)
                C_IDLE: begin
                    case (rx_data)
                        8'h53: begin cst <= C_S; hcnt <= 5'd0; shf <= 96'd0; end  // 'S'
                        8'h4D: cst <= C_M;                                        // 'M'
                        8'h47: cst <= C_G;                                        // 'G'
                        8'h44: begin                                              // 'D'
                            af_a <= 16'sd4096; af_b <= 16'sd0;
                            af_c <= 16'sd0;    af_d <= 16'sd4096;
                            af_tx <= 16'sd0;   af_ty <= 16'sd0;
                            af_ovr <= 1'b0;    gam_fix <= 3'd4;
                            dbg_cnt <= dbg_cnt + 1'b1;
                        end
                        default: ;
                    endcase
                end
                C_S: begin
                    shf  <= shf_nx;
                    hcnt <= hcnt + 1'b1;
                    if (hcnt == 5'd23) begin
                        af_a  <= shf_nx[95:80];
                        af_b  <= shf_nx[79:64];
                        af_c  <= shf_nx[63:48];
                        af_d  <= shf_nx[47:32];
                        af_tx <= shf_nx[31:16];
                        af_ty <= shf_nx[15: 0];
                        af_ovr <= 1'b1;
                        cst <= C_IDLE;
                        dbg_cnt <= dbg_cnt + 1'b1;
                    end
                end
                C_M: begin
                    if (rx_data >= 8'h30 && rx_data <= 8'h33) begin
                        af_ovr <= 1'b0;
                        dbg_cnt <= dbg_cnt + 1'b1;
                    end
                    cst <= C_IDLE;
                end
                default: begin   // C_G
                    if (rx_data >= 8'h30 && rx_data <= 8'h34) begin
                        gam_fix <= {1'b0, rx_data[1:0]};
                        if (rx_data == 8'h34) gam_fix <= 3'd4;
                        dbg_cnt <= dbg_cnt + 1'b1;
                    end
                    cst <= C_IDLE;
                end
            endcase
        end
    end

endmodule
