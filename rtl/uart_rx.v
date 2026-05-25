// uart_rx.v
// 8N1 UART receiver for shape classifier
// Frame: [0xAA][98 data bytes][XOR checksum] = 100 bytes total
// Reused from MNIST client — only DATA_BYTES and checksum changed

module uart_rx #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,

    output reg         frame_ready,
    output reg [783:0] pixel_bits,   // 784 bits unpacked
    output reg         rx_error
);

localparam BAUD_DIV  = CLK_FREQ / BAUD_RATE;
localparam HALF_DIV  = BAUD_DIV / 2;
localparam DATA_BYTES  = 98;
localparam FRAME_BYTES = 100;
localparam START_BYTE  = 8'hAA;

// FSM states
localparam S_IDLE  = 3'd0;
localparam S_START = 3'd1;
localparam S_DATA  = 3'd2;
localparam S_STOP  = 3'd3;
localparam S_DONE  = 3'd4;

reg [2:0]  state;
reg [15:0] baud_cnt;
reg [2:0]  bit_idx;
reg [7:0]  shift;
reg [7:0]  rx_buf [0:99];
reg [6:0]  byte_idx;
reg [7:0]  chk;

// 2-FF synchronizer
reg rx0, rx1;
always @(posedge clk) begin rx0 <= rx; rx1 <= rx0; end
wire rxs = rx1;

integer i;

always @(posedge clk) begin
    if (!rst_n) begin
        state       <= S_IDLE;
        frame_ready <= 0;
        rx_error    <= 0;
        baud_cnt    <= 0;
        byte_idx    <= 0;
        pixel_bits  <= 0;
    end else begin
        frame_ready <= 0;
        rx_error    <= 0;

        case (state)
            S_IDLE: begin
                if (!rxs) begin          // falling edge = start bit
                    baud_cnt <= HALF_DIV;
                    state    <= S_START;
                end
            end

            S_START: begin
                if (baud_cnt == 0) begin
                    if (!rxs) begin
                        baud_cnt <= BAUD_DIV - 1;
                        bit_idx  <= 0;
                        state    <= S_DATA;
                    end else state <= S_IDLE;
                end else baud_cnt <= baud_cnt - 1;
            end

            S_DATA: begin
                if (baud_cnt == 0) begin
                    baud_cnt <= BAUD_DIV - 1;
                    shift    <= {rxs, shift[7:1]};  // LSB first
                    if (bit_idx == 7) state <= S_STOP;
                    else bit_idx <= bit_idx + 1;
                end else baud_cnt <= baud_cnt - 1;
            end

            S_STOP: begin
                if (baud_cnt == 0) begin
                    if (rxs) begin       // valid stop bit
                        rx_buf[byte_idx] <= shift;
                        if (byte_idx == FRAME_BYTES - 1) begin
                            byte_idx <= 0;
                            state    <= S_DONE;
                        end else begin
                            byte_idx <= byte_idx + 1;
                            state    <= S_IDLE;
                        end
                    end else begin
                        byte_idx <= 0;  // framing error reset
                        state    <= S_IDLE;
                    end
                end else baud_cnt <= baud_cnt - 1;
            end

            S_DONE: begin
                // Verify start byte
                if (rx_buf[0] == START_BYTE) begin
                    // XOR checksum over bytes 1..98
                    chk = 8'h00;
                    for (i = 1; i <= DATA_BYTES; i = i+1)
                        chk = chk ^ rx_buf[i];

                    if (chk == rx_buf[99]) begin
                        // Unpack 98 bytes → 784 bits
                        // Python packs: pixel[i*8+k] → byte bit (7-k)  [MSB-first]
                        // So to recover pixel k: pixel_bits[i*8+k] = rx_buf[i+1][7-k]
                        for (i = 0; i < DATA_BYTES; i = i+1) begin
                            pixel_bits[i*8+0] <= rx_buf[i+1][7];
                            pixel_bits[i*8+1] <= rx_buf[i+1][6];
                            pixel_bits[i*8+2] <= rx_buf[i+1][5];
                            pixel_bits[i*8+3] <= rx_buf[i+1][4];
                            pixel_bits[i*8+4] <= rx_buf[i+1][3];
                            pixel_bits[i*8+5] <= rx_buf[i+1][2];
                            pixel_bits[i*8+6] <= rx_buf[i+1][1];
                            pixel_bits[i*8+7] <= rx_buf[i+1][0];
                        end
                        frame_ready <= 1;
                    end else rx_error <= 1;
                end else rx_error <= 1;
                state <= S_IDLE;
            end
        endcase
    end
end
endmodule