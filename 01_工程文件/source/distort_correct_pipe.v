module distort_correct
#(
    parameter H_ACT = 12'd1280,
    parameter V_ACT = 12'd720,
    // 畸变参数，可根据实际镜头修改
    parameter K1 = 18'sd1000,
    parameter K2 = 18'sd50,
    parameter CX = 12'd640,
    parameter CY = 12'd360
)
(
    input               clk,
    input               rst_n,
    input      [11:0]   pix_x,
    input      [11:0]   pix_y,
    input               pix_valid,
    output reg [11:0]   pix_x_correct,
    output reg [11:0]   pix_y_correct,
    output reg          pix_valid_correct
);

// Q12.4 定点
reg signed [17:0] x0, y0;
reg signed [17:0] x1, y1;
reg signed [35:0] r_sq;
reg signed [35:0] r4;
reg signed [35:0] coeff;

reg [11:0] x_pipe[0:3];
reg [11:0] y_pipe[0:3];
reg        v_pipe[0:3];

// stage1：减去光心
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x0 <= 0; y0 <= 0;
        x_pipe[0] <= 0;
        y_pipe[0] <= 0;
        v_pipe[0] <= 0;
    end
    else begin
        x0 <= $signed({pix_x,4'd0}) - $signed({CX,4'd0});
        y0 <= $signed({pix_y,4'd0}) - $signed({CY,4'd0});
        x_pipe[0] <= pix_x;
        y_pipe[0] <= pix_y;
        v_pipe[0] <= pix_valid;
    end
end

// stage2：r² = x0² + y0²
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        r_sq <= 0;
        x_pipe[1] <= 0;
        y_pipe[1] <= 0;
        v_pipe[1] <= 0;
    end
    else begin
        r_sq <= x0*x0 + y0*y0;
        x_pipe[1] <= x_pipe[0];
        y_pipe[1] <= y_pipe[0];
        v_pipe[1] <= v_pipe[0];
    end
end

// stage3：(1 + K1*r² + K2*r⁴)
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        r4 <= 0;
        coeff <= 0;
        x_pipe[2] <= 0;
        y_pipe[2] <= 0;
        v_pipe[2] <= 0;
    end
    else begin
        r4 <= r_sq * r_sq >>> 4;
        coeff <= 36'h10000 + K1 * r_sq + K2 * r4;
        x_pipe[2] <= x_pipe[1];
        y_pipe[2] <= y_pipe[1];
        v_pipe[2] <= v_pipe[1];
    end
end

// stage4：映射回原图坐标
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        pix_x_correct <= 0;
        pix_y_correct <= 0;
        pix_valid_correct <= 0;
    end
    else begin
        pix_x_correct <= $unsigned( (x0 * coeff) >>> 20 ) + CX;
        pix_y_correct <= $unsigned( (y0 * coeff) >>> 20 ) + CY;
        pix_valid_correct <= v_pipe[2];
    end
end

endmodule
