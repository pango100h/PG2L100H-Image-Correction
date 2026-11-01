// 本文件只保留 i2c_master 模块。原先文件末尾误粘了一份 img_correct_top（与新顶层重名），已删除。
module i2c_master(
input        clk,
input        rst_n,

input        start,         //����һ�δ���
input        rw,            //0д 1��
input [6:0]  dev_addr,      //�ӻ���ַ
input [7:0]  reg_addr,      //�Ĵ�����ַ
input [7:0]  wdata,         //д������
output reg [7:0] rdata,     //����������
output reg   done,          //�������
output reg   ack_err,       //Ӧ�����

inout        sda,
output reg   scl
);

localparam I2C_DIV = 16'd250; // clk=31.5M��i2c ~100K

reg [15:0] cnt;
reg [3:0]  bit_cnt;
reg [7:0]  shift_reg;
reg        sda_o;
reg        sda_en;

assign sda = sda_en ? sda_o : 1'bz;

//��Ƶ������
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        cnt <= 16'd0;
    else if(cnt == I2C_DIV)
        cnt <= 16'd0;
    else
        cnt <= cnt + 16'd1;
end

wire tick = (cnt == I2C_DIV);

localparam IDLE    = 4'd0;
localparam START   = 4'd1;
localparam WR_DEV  = 4'd2;
localparam ACK1    = 4'd3;
localparam WR_REG  = 4'd4;
localparam ACK2    = 4'd5;
localparam WR_DATA = 4'd6;
localparam ACK3    = 4'd7;
localparam STOP    = 4'd8;
localparam RD_DATA = 4'd9;
localparam ACK_RD  = 4'd10;

reg [3:0] state;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state    <= IDLE;
        scl      <= 1'b1;
        sda_o    <= 1'b1;
        sda_en   <= 1'b1;
        done     <= 1'b0;
        ack_err  <= 1'b0;
        rdata    <= 8'd0;
        bit_cnt  <= 4'd0;
        shift_reg<= 8'd0;
    end
    else if(tick) begin
        case(state)
        IDLE: begin
            scl <= 1'b1;
            sda_o <= 1'b1;
            sda_en <= 1'b1;
            done <= 1'b0;
            ack_err <= 1'b0;
            if(start) begin
                shift_reg <= {dev_addr, rw};
                bit_cnt <= 4'd7;
                state <= START;
            end
        end
        START: begin
            sda_o <= 1'b0;
            state <= WR_DEV;
        end
        WR_DEV: begin
            scl <= 1'b0;
            sda_o <= shift_reg[bit_cnt];
            scl <= 1'b1;
            if(bit_cnt == 0) begin
                state <= ACK1;
                sda_en <= 1'b0;
            end else begin
                bit_cnt <= bit_cnt - 1'b1;
            end
        end
        ACK1: begin
            scl <= 1'b0;
            if(sda == 1'b1) ack_err <= 1'b1;
            sda_en <= 1'b1;
            if(rw==1'b0) begin
                shift_reg <= reg_addr;
                bit_cnt <=4'd7;
                state <= WR_REG;
            end else begin
                state <= STOP;
            end
        end
        WR_REG: begin
            scl <= 1'b0;
            sda_o <= shift_reg[bit_cnt];
            scl <= 1'b1;
            if(bit_cnt == 0) begin
                state <= ACK2;
                sda_en <= 1'b0;
            end else begin
                bit_cnt <= bit_cnt - 1'b1;
            end
        end
        ACK2: begin
            scl <= 1'b0;
            if(sda ==1'b1) ack_err <=1'b1;
            sda_en <= 1'b1;
            shift_reg <= wdata;
            bit_cnt <=4'd7;
            state <= WR_DATA;
        end
        WR_DATA: begin
            scl <= 1'b0;
            sda_o <= shift_reg[bit_cnt];
            scl <= 1'b1;
            if(bit_cnt == 0) begin
                state <= ACK3;
                sda_en <= 1'b0;
            end else begin
                bit_cnt <= bit_cnt -1'b1;
            end
        end
        ACK3: begin
            scl <= 1'b0;
            if(sda ==1'b1) ack_err <=1'b1;
            sda_en <=1'b1;
            state <= STOP;
        end
        STOP: begin
            scl <= 1'b1;
            sda_o <= 1'b0;
            sda_o <= 1'b1;
            done <= 1'b1;
            state <= IDLE;
        end
        default: state <= IDLE;
        endcase
    end
end

endmodule
