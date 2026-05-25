// ============================================================
//  top.v  —  Shape Classifier Top Level
//  Target : DE2  Cyclone II  EP2C35F672C6
//  Clock  : 50 MHz
//
//  Wiring:
//    GPIO_0[0]  PIN_D25  ← FPGA RX  (USB-TTL TX)
//    GPIO_0[1]  PIN_J22  → FPGA TX  (USB-TTL RX)
//    KEY[0]              → synchronous reset (press to reset)
//    SW[0]               → freeze display (hold = freeze last result)
//    HEX2 HEX1 HEX0     → shape result
//    LEDG[0]             → confident (green)
//    LEDR[0]             → borderline (red)
//    LEDR[1]             → checksum error (red)
// ============================================================
module top (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,      // KEY[0] = reset, active LOW
    input  wire [17:0] SW,       // SW[0]  = freeze display

    input  wire        GPIO_RX,  // PIN_D25
    output wire        GPIO_TX,  // PIN_J22

    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5,
    output wire [6:0]  HEX6,
    output wire [6:0]  HEX7,

    output wire [8:0]  LEDG,
    output wire [17:0] LEDR
);

wire rst_n = KEY[0];  // active-low reset

// ── UART RX ───────────────────────────────────────────────────
wire        frame_ready;
wire [783:0] pixel_bits;
wire        rx_error;

uart_rx #(
    .CLK_FREQ  (50_000_000),
    .BAUD_RATE (115_200)
) u_rx (
    .clk         (CLOCK_50),
    .rst_n       (rst_n),
    .rx          (GPIO_RX),
    .frame_ready (frame_ready),
    .pixel_bits  (pixel_bits),
    .rx_error    (rx_error)
);

// ── Pixel latch — hold pixels stable during feature extraction
reg [783:0] px_lat;
always @(posedge CLOCK_50) begin
    if (frame_ready) px_lat <= pixel_bits;
end

// ── Feature Extractor ─────────────────────────────────────────
wire        feat_done;
wire [9:0]  feat_area;
wire [15:0] feat_aspect;
wire [4:0]  feat_row_var;
wire [9:0]  feat_hsym;
wire [9:0]  feat_vsym;

feature_extractor u_feat (
    .clk         (CLOCK_50),
    .rst_n       (rst_n),
    .pixels      (px_lat),
    .start       (frame_ready),   // start extraction on new frame
    .done        (feat_done),
    .feat_area   (feat_area),
    .feat_aspect (feat_aspect),
    .feat_row_var(feat_row_var),
    .feat_hsym   (feat_hsym),
    .feat_vsym   (feat_vsym)
);

// ── Classifier ────────────────────────────────────────────────
wire [1:0] shape_code;
wire       confident;

classifier u_cls (
    .feat_area   (feat_area),
    .feat_aspect (feat_aspect),
    .feat_row_var(feat_row_var),
    .feat_hsym   (feat_hsym),
    .feat_vsym   (feat_vsym),
    .shape_code  (shape_code),
    .confident   (confident)
);

// ── Result latch + send pulse ─────────────────────────────────
reg [1:0] shape_lat;
reg       conf_lat;
reg       send_pulse;

always @(posedge CLOCK_50) begin
    if (!rst_n) begin
        shape_lat  <= 2'b00;
        conf_lat   <= 1'b0;
        send_pulse <= 1'b0;
    end else begin
        send_pulse <= 1'b0;
        // Only update display if not frozen (SW[0] = 0)
        if (feat_done && !SW[0]) begin
            shape_lat  <= shape_code;
            conf_lat   <= confident;
            send_pulse <= 1'b1;
        end
    end
end

// ── 7-seg driver + UART TX ────────────────────────────────────
wire [6:0] h0, h1, h2;
wire       lg0, lr0;

seg7_driver #(
    .CLK_FREQ  (50_000_000),
    .BAUD_RATE (115_200)
) u_seg (
    .clk        (CLOCK_50),
    .rst_n      (rst_n),
    .shape_code (shape_lat),
    .confident  (conf_lat),
    .send       (send_pulse),
    .HEX0       (h0),
    .HEX1       (h1),
    .HEX2       (h2),
    .LEDG0      (lg0),
    .LEDR0      (lr0),
    .uart_tx    (GPIO_TX)
);

// ── Output assignments ────────────────────────────────────────
assign HEX0 = h0;
assign HEX1 = h1;
assign HEX2 = h2;

// Blank unused displays
assign HEX3 = 7'b1111111;
assign HEX4 = 7'b1111111;
assign HEX5 = 7'b1111111;
assign HEX6 = 7'b1111111;
assign HEX7 = 7'b1111111;

// LEDG[0] = confident green
// LEDR[0] = borderline red
// LEDR[1] = checksum error red
assign LEDG      = {8'b0, lg0};
assign LEDR[0]   = lr0;
assign LEDR[1]   = rx_error;
assign LEDR[17:2] = 16'b0;

endmodule