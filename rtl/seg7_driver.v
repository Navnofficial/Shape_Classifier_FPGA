// seg7_driver.v
// Displays shape on HEX2:HEX1:HEX0 and sends 1 byte back over TX
// Reuses TX state machine from your working MNIST project

module seg7_driver #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] shape_code,
    input  wire       confident,
    input  wire       send,        // pulse to trigger TX

    output reg  [6:0] HEX0,
    output reg  [6:0] HEX1,
    output reg  [6:0] HEX2,
    output wire       LEDG0,
    output wire       LEDR0,
    output wire       uart_tx
);

// 7-seg patterns (active LOW on DE2)
// gfedcba bit order
localparam SEG_C = 7'b1000110;
localparam SEG_I = 7'b1111001;
localparam SEG_r = 7'b0101111;
localparam SEG_S = 7'b0010010;
localparam SEG_q = 7'b0001000;
localparam SEG_u = 7'b1000001;
localparam SEG_E = 7'b0000110;
localparam SEG_t = 7'b0000111;
localparam SEG_i = 7'b1111011;
localparam SEG_DASH = 7'b0111111;

always @(*) begin
    case (shape_code)
        2'b00: begin HEX2=SEG_C; HEX1=SEG_I; HEX0=SEG_r; end  // CIr
        2'b01: begin HEX2=SEG_S; HEX1=SEG_q; HEX0=SEG_u; end  // Squ
        2'b10: begin HEX2=SEG_r; HEX1=SEG_E; HEX0=SEG_C; end  // rEC
        2'b11: begin HEX2=SEG_t; HEX1=SEG_r; HEX0=SEG_i; end  // tri
        default: begin HEX2=SEG_DASH; HEX1=SEG_DASH; HEX0=SEG_DASH; end
    endcase
end

assign LEDG0 = confident;
assign LEDR0 = ~confident;

// ── TX state machine (identical to your MNIST project) ─────────
localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;
localparam TX_IDLE=2'd0, TX_START=2'd1, TX_DATA=2'd2, TX_STOP=2'd3;

reg [1:0]  tx_st;
reg [15:0] tx_cnt;
reg [2:0]  tx_bit;
reg [7:0]  tx_sr;
reg        tx_r;

assign uart_tx = tx_r;

// Response byte: matches fpga_client_16.py FPGA_RESPONSE map
// We reuse: 0x01=Circle, 0x02=Square, 0x03=Rectangle, 0x04=Triangle
reg [7:0] tx_byte;
always @(*) begin
    case (shape_code)
        2'b00: tx_byte = 8'h01;
        2'b01: tx_byte = 8'h02;
        2'b10: tx_byte = 8'h03;
        2'b11: tx_byte = 8'h04;
        default: tx_byte = 8'hFF;
    endcase
end

always @(posedge clk) begin
    if (!rst_n) begin tx_st<=TX_IDLE; tx_r<=1; tx_cnt<=0; end
    else case (tx_st)
        TX_IDLE:  begin tx_r<=1; if(send) begin tx_sr<=tx_byte; tx_cnt<=BAUD_DIV-1; tx_st<=TX_START; end end
        TX_START: begin tx_r<=0; if(tx_cnt==0) begin tx_cnt<=BAUD_DIV-1; tx_bit<=0; tx_st<=TX_DATA; end else tx_cnt<=tx_cnt-1; end
        TX_DATA:  begin tx_r<=tx_sr[0]; if(tx_cnt==0) begin tx_sr<={1'b0,tx_sr[7:1]}; tx_cnt<=BAUD_DIV-1; if(tx_bit==7) tx_st<=TX_STOP; else tx_bit<=tx_bit+1; end else tx_cnt<=tx_cnt-1; end
        TX_STOP:  begin tx_r<=1; if(tx_cnt==0) tx_st<=TX_IDLE; else tx_cnt<=tx_cnt-1; end
    endcase
end

endmodule