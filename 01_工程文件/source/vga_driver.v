module vga_driver(
input        clk,        //31.5MHz
input        rst_n,
output reg   vga_hsync,
output reg   vga_vsync,
output reg   pix_valid,
output reg [11:0] pix_x,
output reg [11:0] pix_y
);

//===== 640*480 @75Hz 标准时序，像素时钟31.5MHz =====
parameter H_ACT   = 12'd640;
parameter H_FP    = 12'd16;
parameter H_SYNC  = 12'd96;
parameter H_BP    = 12'd48;
parameter H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP; // 800

parameter V_ACT   = 12'd480;
parameter V_FP    = 12'd11;
parameter V_SYNC  = 12'd2;
parameter V_BP    = 12'd32;
parameter V_TOTAL = V_ACT + V_FP + V_SYNC + V_BP; // 525

reg [11:0] h_cnt;
reg [11:0] v_cnt;

//行计数器
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        h_cnt <= 12'd0;
    end
    else if(h_cnt == H_TOTAL - 12'd1) begin
        h_cnt <= 12'd0;
    end
    else begin
        h_cnt <= h_cnt + 12'd1;
    end
end

//场计数器
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        v_cnt <= 12'd0;
    end
    else if(h_cnt == H_TOTAL - 12'd1) begin
        if(v_cnt == V_TOTAL - 12'd1)
            v_cnt <= 12'd0;
        else
            v_cnt <= v_cnt + 12'd1;
    end
end

//同步信号（高有效）
always @(*) begin
    vga_hsync = (h_cnt >= H_ACT + H_FP) && (h_cnt < H_ACT + H_FP + H_SYNC);
    vga_vsync = (v_cnt >= V_ACT + V_FP) && (v_cnt < V_ACT + V_FP + V_SYNC);
end

//像素有效信号 + 像素坐标
always @(*) begin
    pix_valid = (h_cnt < H_ACT) && (v_cnt < V_ACT);
    pix_x = h_cnt;
    pix_y = v_cnt;
end

endmodule
