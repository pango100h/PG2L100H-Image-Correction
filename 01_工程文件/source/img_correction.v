module img_correction(
    input               clk,
    input               rst_n,
    input      [11:0]   pix_x,
    input      [11:0]   pix_y,
    input               pix_valid,
    output reg [11:0]   corr_x,
    output reg [11:0]   corr_y,
    output reg          corr_valid
);

// 4级流水线，径向畸变反向映射，Q12.4定点
// k1,k2 畸变系数，你后面可以根据摄像头参数修改
parameter K1 = 16'h0080;
parameter K2 = 16'h0010;
parameter CX = 12'd320;
parameter CY = 12'd240;

// 流水线第1级：去中心
reg signed [15:0] dx_r1, dy_r1;
reg               valid_r1;
// 流水线第2级：r²
reg signed [31:0] r_sq_r2;
reg               valid_r2;
// 流水线第3级：畸变系数计算
reg signed [31:0] scale_r3;
reg signed [15:0] dx_r3, dy_r3;
reg               valid_r3;
// 流水线第4级：恢复坐标
reg signed [15:0] dx_r4, dy_r4;
reg               valid_r4;

// stage1
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        dx_r1 <= 0;
        dy_r1 <= 0;
        valid_r1 <= 0;
    end
    else begin
        dx_r1 <= pix_x - CX;
        dy_r1 <= pix_y - CY;
        valid_r1 <= pix_valid;
    end
end

// stage2 r² = dx*dx + dy*dy
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        r_sq_r2 <= 0;
        valid_r2 <= 0;
    end
    else begin
        r_sq_r2 <= dx_r1 * dx_r1 + dy_r1 * dy_r1;
        valid_r2 <= valid_r1;
    end
end

// stage3 1 + k1*r² + k2*r⁴
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        scale_r3 <= 32'h10000;
        dx_r3 <= 0;
        dy_r3 <= 0;
        valid_r3 <= 0;
    end
    else begin
        scale_r3 <= 32'h10000 + K1 * r_sq_r2 + K2 * r_sq_r2 * r_sq_r2;
        dx_r3 <= dx_r1;
        dy_r3 <= dy_r1;
        valid_r3 <= valid_r2;
    end
end

// stage4 矫正坐标
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        corr_x <= 0;
        corr_y <= 0;
        corr_valid <= 0;
    end
    else begin
        corr_x <= CX + (dx_r3 * scale_r3) >>> 16;
        corr_y <= CY + (dy_r3 * scale_r3) >>> 16;
        corr_valid <= valid_r3;
    end
end

endmodule
