module resample_interp
#(
    parameter H_ACT = 12'd1280,
    parameter V_ACT = 12'd720
)
(
    input               clk,
    input               rst_n,
    input      [11:0]   pix_x,
    input      [11:0]   pix_y,
    input               pix_valid,
    input      [7:0]    r_in,
    input      [7:0]    g_in,
    input      [7:0]    b_in,
    output reg [7:0]    r_out,
    output reg [7:0]    g_out,
    output reg [7:0]    b_out
);

// 简单版本：先取就近像素（方便先跑通，后面可以升级双线插值）
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        r_out <= 8'd0;
        g_out <= 8'd0;
        b_out <= 8'd0;
    end
    else begin
        if(pix_valid) begin
            r_out <= r_in;
            g_out <= g_in;
            b_out <= b_in;
        end
        else begin
            r_out <= 8'd0;
            g_out <= 8'd0;
            b_out <= 8'd0;
        end
    end
end

endmodule
