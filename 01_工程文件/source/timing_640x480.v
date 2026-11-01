//==============================================================================
//  timing_640x480.v —— 640x480@60 时序 + 图像源
//
//  时序：800 x 525，像素时钟 25.175MHz  ->  59.94Hz（标准 VESA 640x480@60）
//        H: 有效640 + 前肩16 + 同步96 + 后肩48 = 800
//        V: 有效480 + 前肩10 + 同步2  + 后肩33 = 525
//
//  ---------------------------------------------------------------------------
//  图像源用参数 IMG_SEL 选择（综合时是常数，另一路会被完全优化掉）：
//
//    IMG_SEL = 0  棋盘格（默认，用于图像通路/坐标映射/几何校正标定）
//                 8 列 x 8 行，每格 80 x 60 像素，正好铺满 640x480
//                 格子尺寸是整数且已知 -> 角点坐标可以直接算，不用拟合
//                 最外圈 1 像素 50% 灰边框：用来确认有效区边界是否精确
//                 对齐（四边都看到边框、且只有 1 像素宽，说明时序对了）
//
//    IMG_SEL = 1  老测试图（保留，用来查 HDMI 链路问题）
//                 y   0..399  EBU 8 色条（白黄青绿品红红蓝黑，各 80px）
//                 y 400..439  8 级灰阶 00/24/49/6D/92/B6/DB/FF
//                 y 440..479  1 像素黑白交替（PCLK 相位检测）
//
//  【重要】RGB、DE、HS、VS 全部在同一个时钟沿寄存输出，
//          保证数据与同步信号严格对齐（原来 RGB 寄存了、DE 没寄存，会整体错 1 像素）
//==============================================================================
module video_timing_640x480(
    input  wire        clk,        // 25.175MHz
    input  wire        rst_n,
    output reg  [11:0] pix_x,
    output reg  [11:0] pix_y,
    output reg         hs,
    output reg         vs,
    output reg         de,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

    // 0 = 棋盘格（做图像校正用这个）；1 = 老彩条测试图
    parameter IMG_SEL  = 0;
    // 棋盘格外圈 1 像素灰边框，不想看就置 0
    parameter FRAME_EN = 1;

    localparam [11:0] H_ACT   = 12'd640;
    localparam [11:0] H_FRONT = 12'd16;
    localparam [11:0] H_SYNC  = 12'd96;
    localparam [11:0] H_BACK  = 12'd48;
    localparam [11:0] H_TOTAL = H_ACT + H_FRONT + H_SYNC + H_BACK;   // 800

    localparam [11:0] V_ACT   = 12'd480;
    localparam [11:0] V_FRONT = 12'd10;
    localparam [11:0] V_SYNC  = 12'd2;
    localparam [11:0] V_BACK  = 12'd33;
    localparam [11:0] V_TOTAL = V_ACT + V_FRONT + V_SYNC + V_BACK;   // 525

    //------------------------------------------------------------------
    // 行/场计数器
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_x <= 12'd0;
            pix_y <= 12'd0;
        end
        else if (pix_x == H_TOTAL - 12'd1) begin
            pix_x <= 12'd0;
            pix_y <= (pix_y == V_TOTAL - 12'd1) ? 12'd0 : (pix_y + 12'd1);
        end
        else begin
            pix_x <= pix_x + 12'd1;
        end
    end

    //------------------------------------------------------------------
    // 组合逻辑：先算出本拍应有的同步/有效/颜色
    //------------------------------------------------------------------
    wire hs_c = (pix_x >= H_ACT + H_FRONT) && (pix_x < H_ACT + H_FRONT + H_SYNC);
    wire vs_c = (pix_y >= V_ACT + V_FRONT) && (pix_y < V_ACT + V_FRONT + V_SYNC);
    wire de_c = (pix_x <  H_ACT) && (pix_y < V_ACT);

    //------------------------------------------------------------------
    // 列下标 cell_x：每 80 像素一列，共 8 列
    // （用比较器实现，避免综合出除法器；80/160/.../560 是常数）
    //------------------------------------------------------------------
    reg [2:0] cell_x;
    always @(*) begin
        if      (pix_x < 12'd80 ) cell_x = 3'd0;
        else if (pix_x < 12'd160) cell_x = 3'd1;
        else if (pix_x < 12'd240) cell_x = 3'd2;
        else if (pix_x < 12'd320) cell_x = 3'd3;
        else if (pix_x < 12'd400) cell_x = 3'd4;
        else if (pix_x < 12'd480) cell_x = 3'd5;
        else if (pix_x < 12'd560) cell_x = 3'd6;
        else                      cell_x = 3'd7;
    end

    //------------------------------------------------------------------
    // 行下标 cell_y：每 60 像素一行，共 8 行（8*60 = 480，正好铺满）
    //------------------------------------------------------------------
    reg [2:0] cell_y;
    always @(*) begin
        if      (pix_y < 12'd60 ) cell_y = 3'd0;
        else if (pix_y < 12'd120) cell_y = 3'd1;
        else if (pix_y < 12'd180) cell_y = 3'd2;
        else if (pix_y < 12'd240) cell_y = 3'd3;
        else if (pix_y < 12'd300) cell_y = 3'd4;
        else if (pix_y < 12'd360) cell_y = 3'd5;
        else if (pix_y < 12'd420) cell_y = 3'd6;
        else                      cell_y = 3'd7;
    end

    // 邻居格翻转：行列下标的最低位异或，就是标准棋盘格
    wire chess_white = cell_x[0] ^ cell_y[0];

    // 有效区最外圈 1 像素
    wire frame_px = (pix_x == 12'd0)        || (pix_x == H_ACT - 12'd1) ||
                    (pix_y == 12'd0)        || (pix_y == V_ACT - 12'd1);

    reg [23:0] rgb_c;
    always @(*) begin
        if (IMG_SEL == 0) begin
            //---------------- 棋盘格 ----------------
            if (FRAME_EN && frame_px)
                rgb_c = 24'h80_80_80;              // 50% 灰边框
            else if (chess_white)
                rgb_c = 24'hFF_FF_FF;              // 白格
            else
                rgb_c = 24'h00_00_00;              // 黑格
        end
        else begin
            //---------------- 老测试图 ----------------
            if (pix_y < 12'd400) begin
                // EBU 彩条
                case (cell_x)
                    3'd0: rgb_c = 24'hFF_FF_FF;   // 白
                    3'd1: rgb_c = 24'hFF_FF_00;   // 黄
                    3'd2: rgb_c = 24'h00_FF_FF;   // 青
                    3'd3: rgb_c = 24'h00_FF_00;   // 绿
                    3'd4: rgb_c = 24'hFF_00_FF;   // 品红
                    3'd5: rgb_c = 24'hFF_00_00;   // 红
                    3'd6: rgb_c = 24'h00_00_FF;   // 蓝
                    default: rgb_c = 24'h00_00_00; // 黑
                endcase
            end
            else if (pix_y < 12'd440) begin
                // 8 级灰阶，正好把 8 根数据线逐个点亮
                case (cell_x)
                    3'd0: rgb_c = 24'h00_00_00;
                    3'd1: rgb_c = 24'h24_24_24;
                    3'd2: rgb_c = 24'h49_49_49;
                    3'd3: rgb_c = 24'h6D_6D_6D;
                    3'd4: rgb_c = 24'h92_92_92;
                    3'd5: rgb_c = 24'hB6_B6_B6;
                    3'd6: rgb_c = 24'hDB_DB_DB;
                    default: rgb_c = 24'hFF_FF_FF;
                endcase
            end
            else begin
                // 1 像素黑白交替（PCLK 相位测试）
                rgb_c = pix_x[0] ? 24'hFF_FF_FF : 24'h00_00_00;
            end
        end
    end

    //------------------------------------------------------------------
    // 统一寄存输出：数据与同步在同一拍对齐
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs <= 1'b0;
            vs <= 1'b0;
            de <= 1'b0;
            r  <= 8'd0;
            g  <= 8'd0;
            b  <= 8'd0;
        end
        else begin
            hs <= hs_c;
            vs <= vs_c;
            de <= de_c;
            r  <= de_c ? rgb_c[23:16] : 8'd0;
            g  <= de_c ? rgb_c[15: 8] : 8'd0;
            b  <= de_c ? rgb_c[ 7: 0] : 8'd0;
        end
    end

endmodule


//==============================================================================
//  video_timing_720p —— 1280x720@60 时序 + 纯 RTL 棋盘格（IMG_EN=0 时的兜底测试图）
//
//  PCLK 74.25MHz（27MHz x 33 / 12），CEA-861 720p60：
//        H: 有效1280 + 前肩110 + 同步40 + 后肩220 = 1650
//        V: 有效720  + 前肩5   + 同步5  + 后肩20  = 750
//        74.25e6 / (1650*750) = 60.000Hz
//
//  棋盘格：每格 80x80（正方形），16 列 x 9 行，正好铺满 1280x720
//          换成 720p 后不再被显示器按 4:3->16:9 拉伸，格子看上去应该是正方
//
//  时钟频率从 25.175 提到 74.25 之后，640x480 内容占屏比变小、缩放倍率从
//  3.0 / 2.25 降到 1.5，边缘插值摊开的宽度明显变窄。
//==============================================================================
module video_timing_720p(
    input  wire        clk,        // 74.25MHz
    input  wire        rst_n,
    output reg  [11:0] pix_x,
    output reg  [11:0] pix_y,
    output reg         hs,
    output reg         vs,
    output reg         de,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

    parameter FRAME_EN = 1;

    localparam [11:0] H_ACT   = 12'd1280;
    localparam [11:0] H_FP    = 12'd110;
    localparam [11:0] H_SW    = 12'd40;
    localparam [11:0] H_BP    = 12'd220;
    localparam [11:0] H_TOTAL = 12'd1650;

    localparam [11:0] V_ACT   = 12'd720;
    localparam [11:0] V_FP    = 12'd5;
    localparam [11:0] V_SW    = 12'd5;
    localparam [11:0] V_BP    = 12'd20;
    localparam [11:0] V_TOTAL = 12'd750;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_x <= 12'd0;
            pix_y <= 12'd0;
        end
        else if (pix_x == H_TOTAL - 12'd1) begin
            pix_x <= 12'd0;
            pix_y <= (pix_y == V_TOTAL - 12'd1) ? 12'd0 : (pix_y + 12'd1);
        end
        else begin
            pix_x <= pix_x + 12'd1;
        end
    end

    wire hs_c = (pix_x >= H_ACT + H_FP) && (pix_x < H_ACT + H_FP + H_SW);
    wire vs_c = (pix_y >= V_ACT + V_FP) && (pix_y < V_ACT + V_FP + V_SW);
    wire de_c = (pix_x <  H_ACT) && (pix_y < V_ACT);

    // 行列下标：每 80 像素一格（用比较器，避免综合出除法器）
    reg [3:0] cx;
    reg [3:0] cy;
    integer i;

    always @(*) begin
        cx = 4'd0;
        for (i = 1; i < 16; i = i + 1)
            if (pix_x >= i * 80) cx = i[3:0];
    end

    always @(*) begin
        cy = 4'd0;
        for (i = 1; i < 9; i = i + 1)
            if (pix_y >= i * 80) cy = i[3:0];
    end

    wire chess_white = cx[0] ^ cy[0];

    wire frame_px = (pix_x == 12'd0) || (pix_x == H_ACT - 12'd1) ||
                    (pix_y == 12'd0) || (pix_y == V_ACT - 12'd1);

    reg [23:0] rgb_c;
    always @(*) begin
        if (FRAME_EN && frame_px) rgb_c = 24'h80_80_80;
        else if (chess_white)     rgb_c = 24'hFF_FF_FF;
        else                      rgb_c = 24'h00_00_00;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs <= 1'b0;
            vs <= 1'b0;
            de <= 1'b0;
            r  <= 8'd0;
            g  <= 8'd0;
            b  <= 8'd0;
        end
        else begin
            hs <= hs_c;
            vs <= vs_c;
            de <= de_c;
            r  <= de_c ? rgb_c[23:16] : 8'd0;
            g  <= de_c ? rgb_c[15: 8] : 8'd0;
            b  <= de_c ? rgb_c[ 7: 0] : 8'd0;
        end
    end

endmodule
