//==============================================================================
//  ms7210_cfg.v —— MS7210 初始化（官方 iic_dri + 官方 ms7210_ctl + 胶合层）
//  来源：D:/微信/.../2026-10/hdmi/hdmi/  官方例程
//  修改点：1) 去掉 MS7200 分支，器件地址固定 0xB2
//          2) ms7210_ctl 增加 dbg_state 输出用于点 LED
//          3) I2C 时钟由 27MHz 直接驱动（官方写死 10MHz，与实际不符）
//==============================================================================
`timescale 1ns / 1ps
`define UD #1

//------------------------------------------------------------------------------
//  以下为官方 iic_dri（I2C 位时序，逻辑未改动）
//------------------------------------------------------------------------------
//////////////////////////////////////////////////////////////////////////////////
// Company:Meyesemi 
// Engineer: Will
// 
// Create Date: 2023-01-29 20:31  
// Design Name:  
// Module Name: 
// Project Name: 
// Target Devices: Pango
// Tool Versions: 
// Description: 
//      
// Dependencies: 
// 
// Revision:
// Revision 1.0 - File Created
// Additional Comments: 修改IIC状态机，第二段为组合逻辑，赋值应使用“=”，将“=”替换“<= `UD”
//                       修改busy区间，由于iic_dri不能缓冲命令，应在接收一次触发后就进入busy状态，
//                                修改语句：if(start_en)       busy <= `UD 1'b1;   
//////////////////////////////////////////////////////////////////////////////////
module iic_dri #(
    parameter            CLK_FRE = 27'd50_000_000,  //system clock frequency
    parameter            IIC_FREQ = 20'd400_000,    //I2c clock frequency
    parameter            T_WR = 10'd5,              //I2c transmit delay ms
    parameter            ADDR_BYTE = 2'd1,          //I2C addr byte number
    parameter            LEN_WIDTH = 8'd3,          //I2C transmit byte width
    parameter            DATA_BYTE = 2'd1           //I2C data byte number
)(                       
    input                clk,
    input                rstn,
    input                pluse,                     //I2C transmit trigger
    input  [7:0]         device_id,                 //I2C divice id
    input                w_r,                       //I2C transmit direction 1:send  0:receive
    input  [LEN_WIDTH:0] byte_len,                  //I2C transmit data byte length of once trigger
                    
    input  [ADDR_BYTE*8 - 1:0]         addr,                      //I2C transmit addr
    input  [7:0]         data_in,                   //I2C send data
                         
    output reg           busy=0,                    //I2C bus status
    output reg           byte_over=0,               //I2C byte transmit over flag
                         
    output reg[7:0]      data_out,                  //I2C receive data
                         
    output               scl,
    input                sda_in,
    output   reg         sda_out=1'b1,
    output               sda_out_en
);

    localparam CLK_DIV = CLK_FRE/IIC_FREQ;  //计数器计数最大值，产生时钟用
    localparam ID_ADDR_BYTE = ADDR_BYTE + 1'b1;//地址加deviceID字节数
    localparam DATA_SET = CLK_DIV>>2;//输出data变化位置
    localparam T_WR_DELAY = T_WR*CLK_FRE/1000_000;

    //  iic clock time counter
    reg [20:0] fre_cnt;//=21'd0;
    always @(posedge clk)
    begin
        if(!rstn)
            fre_cnt <= `UD 21'd0;
        else if(fre_cnt == CLK_DIV - 1'b1)
            fre_cnt <= `UD 21'd0;
        else
            fre_cnt <= `UD fre_cnt + 1'b1;
    end
    
    wire  full_cycle;
    wire  half_cycle;
    assign full_cycle = (fre_cnt == CLK_DIV - 1'b1) ? 1'b1 : 1'b0;  //SCL上升沿：1个SCL周期位置
    assign half_cycle = (fre_cnt == (CLK_DIV>>1'b1) - 1'b1) ? 1'b1 : 1'b0;//SCL下降沿：1/2个SCL周期位置
    
    wire start_h;
    wire dsu;
    assign start_h = (fre_cnt == DATA_SET - 1'b1) ? 1'b1 : 1'b0; //开始停止标志SDA翻转位置 ：1/4个SCL周期位置
    assign dsu = (fre_cnt == (CLK_DIV>>1'b1) + DATA_SET - 1'b1) ? 1'b1 : 1'b0; //数据传输过程SDA变化位置：3/4个SCL周期位置
    
    //============================================================================
    //pluse trige the iic bus transmit start
    wire   start;
    reg    start_en;
    reg    pluse_1d,pluse_2d,pluse_3d;
    always @(posedge clk)
    begin
        if(!rstn)
        begin
            pluse_1d <= `UD 1'b0;
            pluse_2d <= `UD 1'b0;
            pluse_3d <= `UD 1'b0;
        end
        else
        begin
            pluse_1d <= `UD pluse   ;
            pluse_2d <= `UD pluse_1d;//同步
            pluse_3d <= `UD pluse_2d;//取边沿用
        end
    end
    
    always @ (posedge clk)
    begin
        if(start || (!rstn))//开始后开始使能信号拉低
            start_en <= `UD 1'b0;
        else if(~pluse_3d & pluse_2d)//上升沿
            start_en <= `UD 1'b1;
        else
            start_en <= `UD start_en;
    end
    
    assign start = (start_en & full_cycle) ? 1'b1 : 1'b0;
    
    reg w_r_1d=1'b0,w_r_2d=1'b0;
    always @(posedge clk)
    begin
        if(!rstn)
        begin
            w_r_1d <= `UD 1'b0;
            w_r_2d <= `UD 1'b0;
        end
        else
        begin
            w_r_1d <= `UD w_r;
            w_r_2d <= `UD w_r_1d;
        end
    end

    //==========================================================================
    //     IIC FSM STATE
    //==========================================================================
    localparam IDLE   = 3'd0;
    localparam S_START= 3'd1;
    localparam SEND   = 3'd2;
    localparam S_ACK  = 3'd3;
    localparam RECEIV = 3'd4;
    localparam R_ACK  = 3'd5;
    localparam STOP   = 3'd6;
    reg [2:0] state;
    reg [2:0] state_n;
    reg [2:0] trans_bit = 3'd0;
    
    reg [LEN_WIDTH :0] trans_byte = 5'd0;
    reg [LEN_WIDTH :0] trans_byte_max = 5'd0;
    reg       restart = 1'b0;
    reg [7:0] send_data=8'd0;
    reg [7:0] receiv_data=8'd0;
    reg       trans_en=0;
    reg       trans_over=0;
    reg       scl_out= 1'b1/*synthesis PAP_MARK_DEBUG="true"*/;
    
//    assign sda = sda_out_en ? sda_out : 1'bz;
//    assign sda_in = sda;
    assign scl = scl_out;
    
    //============================================================================
    //transmit status
    always @ (posedge clk)
    begin
        if(start)//传输操作开始标志
            trans_en <= `UD 1'b1;
        else if(state == STOP && start_h)//传输STOP标志输出完成
            trans_en <= `UD 1'b0;
        else
            trans_en <= `UD trans_en;
    end
    
//    always @(posedge clk)//冗余
//    begin
//        if(start)
//            trans_over <= `UD 1'b0;
//        else if(state == STOP && start_h)
//            trans_over <= `UD 1'b1;
//        else 
//            trans_over <= `UD trans_over;
//    end
    
    //===========================================================================
    // IIC Bus status
    reg           twr_en=0;
    reg  [26:0]   twr_cnt=0;
    always @(posedge clk)
    begin
        if(state == STOP && dsu)//STOP状态后开始延时
            twr_en <= `UD 1'b1;
        else if(twr_cnt == T_WR_DELAY)//延时满5ms
            twr_en <= `UD 1'b0;
        else
            twr_en <= `UD twr_en;    
    end
    
    always @(posedge clk)
    begin
        if(twr_en)
        begin
            if(twr_cnt == T_WR_DELAY)//延时满5ms
                twr_cnt <= `UD 1'b0;
            else
                twr_cnt <= `UD twr_cnt + 1'b1; 
        end
        else
            twr_cnt <= `UD twr_cnt;
    end
    
    always @(posedge clk)
    begin
        if(start_en)  //接收开始指令进入busy
            busy <= `UD 1'b1;
        else if(twr_cnt == T_WR_DELAY)//busy延时完成
            busy <= `UD 1'b0;
        else
            busy <= `UD busy;
    end
    
    //============================================================================
    //iic bus controller
    always @(posedge clk)
    begin
        if(trans_en)
        begin
            if(half_cycle || full_cycle)
                scl_out <= ~scl_out;
            else
                scl_out <= scl_out;
        end
        else
            scl_out <= 1'b1;
    end
    
    assign sda_out_en = ((state == S_ACK) || (state == RECEIV)) ? 1'b0 : 1'b1;
    
    //tx data control
    always @(posedge clk)
    begin
        if(start)//开始传输时提前准备第一个设备ID+写标志
            send_data <= `UD {device_id[7:1],1'b0};//{设备ID，读写标志}   传输高位在前
        else if(state == S_ACK && full_cycle) //在SACK状态中取一个点提前准备数据
        begin
        	if(ADDR_BYTE == 2'd1)
        	begin
                case(trans_byte)//传输内容变化
                    5'd0 : send_data <= `UD {device_id[7:1],1'b0};
                    5'd1 : send_data <= `UD addr[7:0];
                    5'd2 : send_data <= `UD (w_r_2d) ? data_in : {device_id[7:1],1'b1};
                    default: send_data <= `UD data_in;
                endcase
            end
            else
            begin
            	case(trans_byte)//传输内容变化
                    5'd0 : send_data <= `UD {device_id[7:1],1'b0};
                    5'd1 : send_data <= `UD addr[ 7:0];
                    5'd2 : send_data <= `UD addr[15:8];
                    5'd3 : send_data <= `UD (w_r_2d) ? data_in : {device_id[7:1],1'b1};
                    default: send_data <= `UD data_in;
                endcase
            end
        end
        else
            send_data <= `UD send_data;
    end
    
    //transmit byte number,contain device ID，ADDR，DATA
    always @(posedge clk)
    begin
        if(start)
        begin
            if(w_r_2d)
                trans_byte_max <= `UD ADDR_BYTE + byte_len + 2'd1;
            else
                trans_byte_max <= `UD ADDR_BYTE + byte_len + 2'd2;
        end
        else
            trans_byte_max <= `UD trans_byte_max;
    end
    
    //sda out control
    always @(posedge clk)
    begin
        case(state)
            IDLE  ://空闲状态
            begin
                sda_out <= `UD 1'b1;
            end
            S_START ://开始状态
            begin
                if(start_h)//开始标志产生
                    sda_out <= `UD 1'b0;
                else if(dsu)//数据在SCL上升沿前发出
                    sda_out <= `UD send_data[7-trans_bit];//高位先发
                else
                    sda_out <= `UD sda_out;
            end
            SEND  :
            begin
                sda_out <= `UD send_data[7-trans_bit];//变化数据，高位先发
            end
            S_ACK :
            begin
                if(trans_byte == ID_ADDR_BYTE && dsu && !w_r_2d)//读状态下地址传输完成，准备进入第二次S_START
                    sda_out <= `UD 1'b1;
                else
                    sda_out <= `UD 1'h0;
            end
            R_ACK :
            begin
                if(trans_byte < trans_byte_max)//继续读取回复ACK
                    sda_out <= `UD 1'b0;
                else
                begin
                    if(dsu)//反馈ACK结束，进入STOP状态，提前将SDA拉低
                        sda_out <= `UD 1'b0;
                    else//反馈不再继续读，提示切换传输方向；
                        sda_out <= `UD 1'b1;
                end
            end
            STOP  :
            begin
                if(start_h)//停止标志，
                    sda_out <= `UD 1'b1;
                else
                    sda_out <= `UD sda_out;
            end
            default: sda_out <= `UD 1'b1;
        endcase
    end
    
    // iic read data
    always @(posedge clk)
    begin
        if(state == RECEIV)
        begin
            if(full_cycle)//上升沿位置接收输入数据
                receiv_data <= `UD {receiv_data[6:0],sda_in};
            else
                receiv_data <= `UD receiv_data;
        end
        else
            receiv_data <= `UD 8'd0;
    end
    
    always @(posedge clk)
    begin
        if(state == RECEIV && trans_bit == 3'd7 && half_cycle)//接收1byte数据后，将数据传出
            data_out <= `UD receiv_data;
        else
            data_out <= `UD data_out;
    end
    
    //one byte data transmit over flag
    always @(posedge clk)
    begin
        if(w_r_2d)
        begin
            if(trans_byte > ID_ADDR_BYTE - 1'b1 && dsu && trans_bit == 3'd7)//写地址完成后再传输字节进行标识
                byte_over <= `UD 1'b1;
            else
                byte_over <= `UD 1'b0;
        end
        else
        begin
            if(trans_byte > ID_ADDR_BYTE && dsu && trans_bit == 3'd7)//写完第二次ID后，再传输字节进行标识
                byte_over <= `UD 1'b1;
            else
                byte_over <= `UD 1'b0;
        end
    end
    
    always @(posedge clk)
    begin
        if(state == SEND || state == RECEIV)
        begin
            if(dsu)
                trans_bit <= `UD trans_bit + 1'b1;
            else
                trans_bit <= `UD trans_bit;
        end
        else
            trans_bit <= `UD 3'd0;
    end
    
    always @(posedge clk)
    begin
        if(start)//每次开始传输时清零byte计数
            trans_byte <= `UD 5'd0;
        else if(state == SEND || state == RECEIV)//读写状态需要计数
        begin
            if(dsu && trans_bit == 3'd7)//传输满1byte时计数加1
                trans_byte <= `UD trans_byte + 1'b1;
            else//其他时候保持状态
                trans_byte <= `UD trans_byte;
        end
        else//其他时候保持状态
            trans_byte <= `UD trans_byte;
    end
    
    //==========================================================================
    //     IIC FSM STATE CHANGE
    //==========================================================================
    always @(posedge clk)
    begin
        if(!rstn)
            state <= `UD IDLE;
        else
            state <= `UD state_n;
    end
    
    // next state set
    always @(*)
    begin
        state_n = state;
        case(state)
            IDLE  :
            begin
                if(start)
                    state_n = S_START;
                else
                    state_n = state;
            end
            S_START :
            begin
//                if(full_cycle && trans_byte == 3'd0) //读写操作第一次
//                    state_n = SEND;
//                else if(!w_r_2d && trans_byte == ID_ADDR_BYTE && dsu)//读操作第二次
//                    state_n = SEND;
                if(dsu) 
                    state_n = SEND;
                else
                    state_n = state;
            end
            SEND  :
            begin
                if(trans_bit == 3'd7 & dsu)
                    state_n = S_ACK;
                else
                    state_n = state;
            end
            S_ACK :
            begin
                if(dsu)// & sda_in)
                begin
                    if(w_r_2d)
                    begin
                        if(trans_byte < ID_ADDR_BYTE)//写入ID+ADDR
                            state_n = SEND;
                        else if(trans_byte < trans_byte_max)//写入数据
                            state_n = SEND;
                        else//写入数据完成
                            state_n = STOP;
                    end
                    else
                    begin
                        if(trans_byte < ID_ADDR_BYTE)//写入ID+ADDR
                            state_n = SEND;
                        else if(trans_byte == ID_ADDR_BYTE)//重新开始，写入ID和读标志位
                            state_n = S_START;
                        else//进入读状态
                            state_n = RECEIV;
                    end
                end
                else
                    state_n = state;
            end
            RECEIV:
            begin
                if(trans_bit == 3'd7 & dsu)
                    state_n = R_ACK;
                else
                    state_n = state;
            end
            R_ACK :
            begin
                if(dsu)
                begin
                    if(trans_byte < trans_byte_max)
                        state_n = RECEIV;
                    else
                        state_n = STOP;
                end
                else
                    state_n = state;
            end
            STOP  :
            begin
                if(dsu)
                    state_n = IDLE;
                else
                    state_n = state;
            end
            default: state_n = IDLE;
        endcase
    end
    
    //===========================================================================

endmodule
 

//------------------------------------------------------------------------------
//  以下为官方 ms7210_ctl（49 条寄存器表，仅增加 dbg_state 输出）
//------------------------------------------------------------------------------
//////////////////////////////////////////////////////////////////////////////////
// Company:Meyesemi 
// Engineer: Will
// 
// Create Date: 2023-01-29 20:31  
// Design Name:  
// Module Name: 
// Project Name: 
// Target Devices: Pango
// Tool Versions: 
// Description: 
//      
// Dependencies: 
// 
// Revision:
// Revision 1.0 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
module ms7210_ctl(
    input               clk,
    input               rstn,
                        
    output reg          init_over,
    output       [ 5:0] dbg_state,
    output        [7:0] device_id,
    output reg          iic_trig ,
    output reg          w_r      ,
    output reg   [15:0] addr     ,
    output reg   [ 7:0] data_in  ,
    input               busy     ,
    input        [ 7:0] data_out ,
    input               byte_over 
);
    assign device_id = 8'hB2;
function [23:0] cmd_data;
input [5:0] index;
    begin
        case(index)
            6'd0     : cmd_data = {16'h1281,8'h04};
            6'd1     : cmd_data = {16'h0016,8'h04};//
            6'd2     : cmd_data = {16'h0009,8'h01};//
            6'd3     : cmd_data = {16'h0007,8'h09};//
            6'd4     : cmd_data = {16'h0008,8'hF0};//
            6'd5     : cmd_data = {16'h000A,8'hF0};//
            6'd6     : cmd_data = {16'h0006,8'h11};//
            6'd7     : cmd_data = {16'h0531,8'h84};//
            6'd8     : cmd_data = {16'h0900,8'h20};//
            6'd9     : cmd_data = {16'h0901,8'h47};//
            6'd10    : cmd_data = {16'h0904,8'h09};
            6'd11    : cmd_data = {16'h0923,8'h07};//
            6'd12    : cmd_data = {16'h0924,8'h44};//
            6'd13    : cmd_data = {16'h0925,8'h44};//
            6'd14    : cmd_data = {16'h090F,8'h80};//
            6'd15    : cmd_data = {16'h091F,8'h07};//
            6'd16    : cmd_data = {16'h0920,8'h1E};//  INT EN
            6'd17    : cmd_data = {16'h0018,8'h20};//
            6'd18    : cmd_data = {16'h05c0,8'hFE};//
            6'd19    : cmd_data = {16'h000B,8'h00};//  seting
            6'd20    : cmd_data = {16'h0507,8'h06};
            6'd21    : cmd_data = {16'h0906,8'h04};//
            6'd22    : cmd_data = {16'h0920,8'h5E};//
            6'd23    : cmd_data = {16'h0926,8'hDD};//
            6'd24    : cmd_data = {16'h0927,8'h0D};//
            6'd25    : cmd_data = {16'h0928,8'h88};//
            6'd26    : cmd_data = {16'h0929,8'h08};//
            6'd27    : cmd_data = {16'h0910,8'h01};//
            6'd28    : cmd_data = {16'h000B,8'h11};//
            6'd29    : cmd_data = {16'h050E,8'h00};//
            6'd30    : cmd_data = {16'h050A,8'h82};
            6'd31    : cmd_data = {16'h0509,8'h02};//
            6'd32    : cmd_data = {16'h050B,8'h0D};//
            6'd33    : cmd_data = {16'h050D,8'h06};//
            6'd34    : cmd_data = {16'h050D,8'h11};//
            6'd35    : cmd_data = {16'h050D,8'h58};//
            6'd36    : cmd_data = {16'h050D,8'h00};//
            6'd37    : cmd_data = {16'h050D,8'h00};//
            6'd38    : cmd_data = {16'h050D,8'h00};//
            6'd39    : cmd_data = {16'h050D,8'h00};//
            6'd40    : cmd_data = {16'h050D,8'h00};
            6'd41    : cmd_data = {16'h050D,8'h00};//
            6'd42    : cmd_data = {16'h050D,8'h00};//
            6'd43    : cmd_data = {16'h050D,8'h00};//
            6'd44    : cmd_data = {16'h050D,8'h00};//
            6'd45    : cmd_data = {16'h050D,8'h00};//
            6'd46    : cmd_data = {16'h050D,8'h00};//
            6'd47    : cmd_data = {16'h050E,8'h40};//
            6'd48    : cmd_data = {16'h0507,8'h00};//
       endcase 
    end
endfunction
    //===========================================================================
    //  MS7210 driver control FSM
    //===========================================================================
    parameter    IDLE   = 6'b00_0001;
    parameter    CONECT = 6'b00_0010;
    parameter    INIT   = 6'b00_0100;
    parameter    WAIT   = 6'b00_1000;
    parameter    SETING = 6'b01_0000;
    parameter    STA_RD = 6'b10_0000;
    reg [ 5:0]   state;
    reg [ 5:0]   state_n;
    reg [ 4:0]   dri_cnt;
    reg [21:0]   delay_cnt;
    reg [ 5:0]   cmd_index;

    reg          busy_1d;
    wire         busy_falling;
    
    assign busy_falling = ((~busy) & busy_1d);
    always @(posedge clk)
    begin
        busy_1d <= busy;
    end
    //===========================================================================
    //  MS7210 driver control FSM    First Step
    always @(posedge clk)
    begin
        if(!rstn)
            state <= IDLE;
        else
            state <= state_n;
    end
    
    //===========================================================================
    //  MS7210 driver control FSM    Second Step
    always @(*)
    begin
        state_n = state;
        case(state)
            IDLE     : begin
                state_n = CONECT;
            end
            CONECT   : begin
                if(dri_cnt == 5'd1 && busy_falling && data_out == 8'h5A)
                    state_n = INIT;
                else
                    state_n = state;
            end
            INIT     : begin
                if(dri_cnt == 5'd18 && busy_falling)
                    state_n = WAIT;
                else
                    state_n = state;
            end
            WAIT     : begin
                if(delay_cnt == 22'h30D399)//)//
                    state_n = SETING;
                else
                    state_n = state;
            end
            SETING   : begin
                if(dri_cnt == 5'd29 && busy_falling)
                    state_n = STA_RD;
                else
                    state_n = state;
            end
            STA_RD   : begin
                state_n = state;
            end
            default  : begin
                state_n = IDLE;
            end
        endcase
    end
    
    //===========================================================================
    //  MS7210 driver control FSM    Third Step
    always @(posedge clk)
    begin
        if(!rstn)
            dri_cnt <= 5'd0;
        else
        begin
            case(state)
                IDLE     ,
                WAIT     ,
                STA_RD   : dri_cnt <= 5'd0;
                CONECT   : begin
                    if(busy_falling)
                    begin
                        if(dri_cnt == 5'd1)
                            dri_cnt <= 5'd0;
                        else
                            dri_cnt <= dri_cnt + 5'd1;
                    end
                    else
                        dri_cnt <= dri_cnt;
                end
                INIT     : begin
                    if(busy_falling)
                    begin
                        if(dri_cnt == 5'd18)
                            dri_cnt <= 5'd0;
                        else
                            dri_cnt <= dri_cnt + 5'd1;
                    end
                    else
                        dri_cnt <= dri_cnt;
                end
                SETING   : begin
                    if(busy_falling)
                    begin
                        if(dri_cnt == 5'd29)
                            dri_cnt <= 5'd0;
                        else
                            dri_cnt <= dri_cnt + 5'd1;
                    end
                    else
                        dri_cnt <= dri_cnt;
                end
                default  : dri_cnt <= 5'd0;
            endcase
        end
    end
    
    always @(posedge clk)
    begin
        if(state == WAIT)
        begin
            if(delay_cnt == 22'h30D399)
                delay_cnt <= 22'd0;
            else
                delay_cnt <= delay_cnt + 22'd1;
        end
        else
            delay_cnt <= 22'd0;
    end
    
    always @(posedge clk)
    begin
        if(!rstn)
            iic_trig <= 1'd0;
        else
        begin
            case(state)
                IDLE     : iic_trig <= 1'b1;
                WAIT     : iic_trig <= (delay_cnt == 22'h30D399);
                CONECT   ,
                INIT     ,
                SETING   ,
                STA_RD   : iic_trig <= busy_falling;
                default  : iic_trig <= 1'd0;
            endcase
        end
    end
    
    always @(posedge clk)
    begin
        if(!rstn)
            w_r <= 1'd1;
        else
        begin
            case(state)
                IDLE     : w_r <= 1'b1;
                CONECT   : begin
                    if(dri_cnt == 5'd0 && busy_falling)
                        w_r <= 1'b0;
                    else if(dri_cnt == 5'd1 && busy_falling)
                        w_r <= 1'b1;
                    else
                        w_r <= w_r;
                end
                INIT     ,
                STA_RD   ,
                WAIT     : w_r <= w_r;
                SETING   : begin
                    if(dri_cnt == 5'd29 && busy_falling)
                        w_r <= 1'b0;
                    else
                        w_r <= w_r;
                end
                default  : w_r <= 1'b1;
            endcase
        end
    end
    
    always @(posedge clk)
    begin
        if(!rstn)
            cmd_index <= 6'd0;
        else
        begin
            case(state)
                IDLE     : cmd_index <= 6'd0;
                CONECT   : cmd_index <= 6'd0;
                INIT     ,
                SETING   :begin
                    if(byte_over)
                        cmd_index <= cmd_index + 1'b1;
                    else
                        cmd_index <= cmd_index;
                end
                WAIT     ,
                STA_RD   : cmd_index <= cmd_index;
                default  : cmd_index <= 6'd0;
            endcase
        end
    end
    
    reg [23:0] cmd_iic;
    always@(posedge clk)
	begin
		if(~rstn)
			cmd_iic <= 0;
		else if(state == IDLE)
			cmd_iic <= 24'd0;
        else //if(state == WAIT || state == SETING)
            cmd_iic <= cmd_data(cmd_index);
	end
    
    always @(posedge clk)
    begin
        if(!rstn)
        begin
            addr    <= 16'd0;
            data_in <= 8'd0;
        end
        else
        begin
            case(state)
                IDLE     : begin
                    addr    <= 16'h0003;
                    data_in <= 8'h5A;
                end
                CONECT   : begin
                    if(dri_cnt == 5'd1 && busy_falling && data_out == 8'h5A)
                    begin
                        addr    <= cmd_iic[23:8];
                        data_in <= cmd_iic[ 7:0];
                    end
                    else
                    begin
                        addr    <= addr;
                        data_in <= data_in;
                    end
                end
                INIT     ,
                WAIT     ,
                SETING   :begin
                	addr    <= cmd_iic[23:8];
                    data_in <= cmd_iic[ 7:0];
                end
                STA_RD   :begin
                    addr    <= 16'h0502;
                    data_in <= 8'd0;
                end
                default  : begin
                    addr    <= 0;
                    data_in <= 0;
                end
            endcase
        end
    end

    always @(posedge clk)
    begin
    	if(!rstn)
    	    init_over <= 1'b0;
    	else if(state == STA_RD)// && busy_falling)
    	    init_over <= 1'b1;
    end

    assign dbg_state = state;

endmodule


//==============================================================================
//  ms7210_cfg —— MS7210 初始化胶合层
//  替代官方 ms72xx_ctl：去掉 MS7200(HDMI RX, 0x56) 分支，器件地址固定 0xB2
//  官方逻辑里 device_id 依赖 7200 握手完成才切到 0xB2，只做输出会永远卡在 RX。
//==============================================================================
module ms7210_cfg #(
    parameter CLK_HZ    = 27_000_000,   // 系统时钟
    parameter IIC_HZ    = 100_000,      // I2C 速率（芯片支持 400k，100k 更稳）
    parameter PWR_MS    = 5,            // 复位释放后再等几毫秒才开始通信
    parameter T_WR_UNIT = 10            // iic_dri 的 T_WR：实际间隔 = T_WR*CLK_FRE/1e6 个时钟
)(
    input  wire       clk,
    input  wire       rst_n,
    output wire       iic_scl,
    inout  wire       iic_sda,          // 只用来读总线电平（回读校验用）
    output wire       cfg_done,         // 49 条寄存器全部写完
    output wire [5:0] dbg_state,        // MS7210 FSM 状态，用于点 LED
    //------------------------------------------------------------------
    // SDA 驱动权外置：把"这一拍要不要拉低 SDA"报给顶层，由顶层仲裁
    //   原来是本模块自己 assign iic_sda = sda_out_en ? sda_out : 1'bz;
    //   现在 RX 的 I2C 主机也要用同一根线，必须由顶层统一切换。
    //   顶层表达式与原来那行逐字等价，TX 行为不变。
    //------------------------------------------------------------------
    output wire       sda_out_o,
    output wire       sda_out_en_o
);

    //--------------------------------------------------------------
    // 上电延时：复位释放后等 PWR_MS 毫秒，再启动 I2C
    //--------------------------------------------------------------
    localparam integer PWR_CNT = PWR_MS * (CLK_HZ / 1000);

    reg [20:0] pwr_cnt;
    reg        run;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwr_cnt <= 21'd0;
            run     <= 1'b0;
        end
        else if (pwr_cnt != PWR_CNT) begin
            pwr_cnt <= pwr_cnt + 1'b1;
            run     <= 1'b0;
        end
        else begin
            run <= 1'b1;
        end
    end

    //--------------------------------------------------------------
    // 注意：iic_dri 内部 T_WR_DELAY = T_WR * CLK_FRE / 1_000_000 是 32 位乘法，
    // 27MHz 下 T_WR 超过 79 就溢出。取 10 => 270 clk = 10us，满足 tBUF。
    //--------------------------------------------------------------
    localparam [9:0] T_WR = T_WR_UNIT;

    wire [ 7:0] device_id;
    wire        iic_trig;
    wire        w_r;
    wire [15:0] addr;
    wire [ 7:0] data_in;
    wire [ 7:0] data_out;
    wire        busy;
    wire        byte_over;
    wire        init_over;

    ms7210_ctl u_ms7210_ctl (
        .clk        (clk        ),
        .rstn       (run        ),
        .init_over  (init_over  ),
        .dbg_state  (dbg_state  ),
        .device_id  (device_id  ),
        .iic_trig   (iic_trig   ),
        .w_r        (w_r        ),
        .addr       (addr       ),
        .data_in    (data_in    ),
        .busy       (busy       ),
        .data_out   (data_out   ),
        .byte_over  (byte_over  )
    );

    wire sda_in;
    wire sda_out;
    wire sda_out_en;

    iic_dri #(
        .CLK_FRE    (CLK_HZ    ),
        .IIC_FREQ   (IIC_HZ    ),
        .T_WR       (T_WR      ),
        .ADDR_BYTE  (2'd2      ),   // 2 字节寄存器地址（先低字节，后高字节）
        .LEN_WIDTH  (8'd3      ),
        .DATA_BYTE  (2'd1      )
    ) u_iic_dri (
        .clk        (clk        ),
        .rstn       (run        ),
        .device_id  (device_id  ),
        .pluse      (iic_trig   ),
        .w_r        (w_r        ),
        .byte_len   (4'd1       ),
        .addr       (addr       ),
        .data_in    (data_in    ),
        .busy       (busy       ),
        .byte_over  (byte_over  ),
        .data_out   (data_out   ),
        .scl        (iic_scl    ),
        .sda_in     (sda_in     ),
        .sda_out    (sda_out    ),
        .sda_out_en (sda_out_en )
    );

    // 不再直接驱动总线（驱动权在顶层，见端口说明）
    assign sda_in = iic_sda;

    assign sda_out_o    = sda_out;
    assign sda_out_en_o = sda_out_en;

    assign cfg_done = init_over;

endmodule
