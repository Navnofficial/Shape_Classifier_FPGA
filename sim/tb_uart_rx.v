// ============================================================
//  tb_uart_rx.v
//  Testbench for uart_rx.v
//  Sends a complete 100-byte frame and verifies pixel_ram output
// ============================================================
`timescale 1ns/1ps

module tb_uart_rx;

// ── DUT signals ───────────────────────────────────────────────
reg        clk  = 0;
reg        rst_n = 0;
reg        rx   = 1;   // idle high

wire        frame_ready;
wire [783:0] pixel_ram;
wire        rx_error;

// ── Clock: 50 MHz → 20ns period ──────────────────────────────
always #10 clk = ~clk;

// ── DUT instantiation ─────────────────────────────────────────
uart_rx #(
    .CLK_FREQ  (50_000_000),
    .BAUD_RATE (115_200)
) dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .rx          (rx),
    .frame_ready (frame_ready),
    .pixel_ram   (pixel_ram),
    .rx_error    (rx_error)
);

// ── Baud period ───────────────────────────────────────────────
localparam BAUD_PERIOD_NS = 1_000_000_000 / 115_200;  // ~8680 ns

// ── Task: send one 8N1 byte ───────────────────────────────────
task send_byte;
    input [7:0] data;
    integer i;
    begin
        // Start bit
        rx = 0;
        #(BAUD_PERIOD_NS);
        // Data bits LSB first
        for (i = 0; i < 8; i = i + 1) begin
            rx = data[i];
            #(BAUD_PERIOD_NS);
        end
        // Stop bit
        rx = 1;
        #(BAUD_PERIOD_NS);
    end
endtask

// ── Test frame ────────────────────────────────────────────────
reg [7:0] test_frame [0:99];
integer i;

initial begin
    $dumpfile("tb_uart_rx.vcd");
    $dumpvars(0, tb_uart_rx);

    // Build test frame: 0xAA + 98 bytes pattern + checksum
    test_frame[0] = 8'hAA;  // start

    // Fill pixel data: alternating 0x55 / 0xAA pattern
    for (i = 1; i <= 98; i = i + 1)
        test_frame[i] = (i % 2 == 1) ? 8'h55 : 8'hAA;

    // Compute XOR checksum
    test_frame[99] = 8'h00;
    for (i = 1; i <= 98; i = i + 1)
        test_frame[99] = test_frame[99] ^ test_frame[i];

    // Release reset
    #100;
    rst_n = 1;
    #200;

    $display("=== Sending 100-byte frame ===");

    for (i = 0; i < 100; i = i + 1)
        send_byte(test_frame[i]);

    // Wait for frame_ready
    @(posedge frame_ready);
    $display("PASS: frame_ready asserted!");
    $display("pixel_ram[7:0]   = %08b (expect: %08b)", pixel_ram[7:0],   test_frame[1]);
    $display("pixel_ram[15:8]  = %08b (expect: %08b)", pixel_ram[15:8],  test_frame[2]);
    $display("pixel_ram[783:776] = %08b (expect: %08b)",
              pixel_ram[783:776], test_frame[98]);

    // Verify no error
    if (rx_error)
        $display("FAIL: rx_error unexpectedly asserted");
    else
        $display("PASS: no rx_error");

    // ── Test 2: Bad checksum ──────────────────────────────────
    #(BAUD_PERIOD_NS * 10);

    test_frame[99] = test_frame[99] ^ 8'hFF;  // corrupt checksum

    $display("\n=== Sending frame with bad checksum ===");
    for (i = 0; i < 100; i = i + 1)
        send_byte(test_frame[i]);

    @(posedge rx_error);
    $display("PASS: rx_error correctly asserted on bad checksum");

    #1000;
    $display("\n=== Testbench complete ===");
    $finish;
end

// Timeout watchdog
initial begin// ============================================================
//  tb_uart_rx.v  —  Testbench for uart_rx.v
//  Tests: valid frame, bad checksum, bad start byte,
//         two consecutive frames
// ============================================================
`timescale 1ns/1ps

module tb_uart_rx;

reg        clk   = 0;
reg        rst_n = 0;
reg        rx    = 1;       // idle high

wire        frame_ready;
wire [783:0] pixel_bits;
wire        rx_error;

// 50 MHz clock
always #10 clk = ~clk;

uart_rx #(
    .CLK_FREQ  (50_000_000),
    .BAUD_RATE (115_200)
) dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .rx          (rx),
    .frame_ready (frame_ready),
    .pixel_bits  (pixel_bits),
    .rx_error    (rx_error)
);

// Baud period = 1/115200 seconds in nanoseconds
localparam BAUD_NS = 8680;

integer pass = 0;
integer fail = 0;

// ── Task: send one 8N1 byte ───────────────────────────────────
task send_byte;
    input [7:0] data;
    integer b;
    begin
        rx = 0; #(BAUD_NS);                         // start bit
        for (b = 0; b < 8; b = b+1) begin
            rx = data[b]; #(BAUD_NS);               // data LSB first
        end
        rx = 1; #(BAUD_NS);                         // stop bit
    end
endtask

// ── Task: send full 100-byte frame ────────────────────────────
//    start_byte  : first byte (should be 0xAA for valid)
//    bad_chk     : 1 = corrupt the checksum byte
task send_frame;
    input [7:0] start_byte;
    input       bad_chk;
    reg [7:0] frame [0:99];
    reg [7:0] chk;
    integer i;
    begin
        frame[0] = start_byte;
        for (i = 1; i <= 98; i = i+1)
            frame[i] = i[7:0];      // bytes 1..98 = 1,2,3...98

        // XOR checksum over bytes 1..98
        chk = 8'h00;
        for (i = 1; i <= 98; i = i+1)
            chk = chk ^ frame[i];
        frame[99] = bad_chk ? (chk ^ 8'hFF) : chk;

        $display("  Sending: start=0x%02X  chk=0x%02X  bad_chk=%0b",
                  start_byte, frame[99], bad_chk);
        for (i = 0; i < 100; i = i+1)
            send_byte(frame[i]);
    end
endtask

// ── Main test sequence ────────────────────────────────────────
initial begin
    $dumpfile("tb_uart_rx.vcd");
    $dumpvars(0, tb_uart_rx);

    // Release reset
    #100; rst_n = 1; #200;

    // =========================================================
    // TEST 1: Valid frame → expect frame_ready pulse
    // =========================================================
    $display("\n--- TEST 1: Valid frame ---");
    fork
        begin : send1
            send_frame(8'hAA, 0);
        end
        begin : wait1
            @(posedge frame_ready);
            $display("  PASS: frame_ready asserted");
            pass = pass + 1;

            if (pixel_bits[7:0] === 8'h01) begin
                $display("  PASS: pixel_bits[7:0]=0x01 correct");
                pass = pass + 1;
            end else begin
                $display("  FAIL: pixel_bits[7:0]=0x%02X expected 0x01",
                          pixel_bits[7:0]);
                fail = fail + 1;
            end

            if (rx_error === 1'b0) begin
                $display("  PASS: no rx_error");
                pass = pass + 1;
            end else begin
                $display("  FAIL: rx_error unexpectedly set");
                fail = fail + 1;
            end
            disable send1;
        end
    join

    #(BAUD_NS * 20);

    // =========================================================
    // TEST 2: Bad checksum → expect rx_error pulse
    // =========================================================
    $display("\n--- TEST 2: Corrupted checksum ---");
    fork
        begin : send2
            send_frame(8'hAA, 1);
        end
        begin : wait2
            @(posedge rx_error);
            $display("  PASS: rx_error asserted on bad checksum");
            pass = pass + 1;

            if (frame_ready === 1'b0) begin
                $display("  PASS: frame_ready NOT asserted");
                pass = pass + 1;
            end else begin
                $display("  FAIL: frame_ready should not be set");
                fail = fail + 1;
            end
            disable send2;
        end
    join

    #(BAUD_NS * 20);

    // =========================================================
    // TEST 3: Wrong start byte → expect rx_error pulse
    // =========================================================
    $display("\n--- TEST 3: Wrong start byte (0x55) ---");
    fork
        begin : send3
            send_frame(8'h55, 0);
        end
        begin : wait3
            @(posedge rx_error);
            $display("  PASS: rx_error asserted on bad start byte");
            pass = pass + 1;
            disable send3;
        end
    join

    #(BAUD_NS * 20);

    // =========================================================
    // TEST 4: Two consecutive valid frames
    // =========================================================
    $display("\n--- TEST 4: Two consecutive valid frames ---");
    send_frame(8'hAA, 0);
    @(posedge frame_ready);
    $display("  PASS: frame 1 ready");
    pass = pass + 1;

    #(BAUD_NS * 3);
    send_frame(8'hAA, 0);
    @(posedge frame_ready);
    $display("  PASS: frame 2 ready");
    pass = pass + 1;

    // =========================================================
    // RESULTS
    // =========================================================
    #1000;
    $display("\n======================================");
    $display("  PASSED: %0d   FAILED: %0d", pass, fail);
    if (fail == 0)
        $display("  ALL TESTS PASSED — safe to proceed");
    else
        $display("  FIX FAILURES BEFORE PROCEEDING");
    $display("======================================");
    $finish;
end

// Watchdog — if nothing happens in 1 second sim time, abort
initial begin
    #900_000_000;
    $display("WATCHDOG TIMEOUT — check baud divider");
    $finish;
end

endmodule
    #500_000_000;
    $display("FAIL: Timeout!");
    $finish;
end

endmodule