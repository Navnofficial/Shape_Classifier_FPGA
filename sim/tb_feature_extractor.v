// ============================================================
//  tb_feature_extractor.v
//  Tests feature_extractor.v with 4 known pixel patterns:
//  filled circle, square, wide rectangle, right triangle
//  Prints all 5 feature values — use these as initial centroids
// ============================================================
`timescale 1ns/1ps

module tb_feature_extractor;

reg        clk   = 0;
reg        rst_n = 0;
reg [783:0] pixels = 0;
reg        start  = 0;

wire        done;
wire [9:0]  feat_area;
wire [15:0] feat_aspect;
wire [23:0] feat_circ;
wire [9:0]  feat_hsym;
wire [9:0]  feat_vsym;

always #10 clk = ~clk;   // 50 MHz

feature_extractor dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .pixels     (pixels),
    .start      (start),
    .done       (done),
    .feat_area  (feat_area),
    .feat_aspect(feat_aspect),
    .feat_circ  (feat_circ),
    .feat_hsym  (feat_hsym),
    .feat_vsym  (feat_vsym)
);

// ── Helper: set pixel (r,c) ───────────────────────────────────
task set_px;
    input integer r, c;
    begin
        if (r >= 0 && r < 28 && c >= 0 && c < 28)
            pixels[r*28 + c] = 1'b1;
    end
endtask

// ── Run extractor and display results ────────────────────────
task run_and_show;
    input [8*16-1:0] name;
    begin
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        @(posedge done);
        @(posedge clk); #1;

        $display("-----------------------------");
        $display("Shape: %s", name);
        $display("  feat_area   = %0d", feat_area);
        $display("  feat_aspect = %0d  (float=%.3f, 1.0=256)",
                  feat_aspect, feat_aspect / 256.0);
        $display("  feat_circ   = %0d", feat_circ);
        $display("  feat_hsym   = %0d", feat_hsym);
        $display("  feat_vsym   = %0d", feat_vsym);
        $display("  → Use these as centroid values in classifier.v");
        #100;
    end
endtask

integer r, c, dr, dc, r2;

initial begin
    $dumpfile("tb_feature_extractor.vcd");
    $dumpvars(0, tb_feature_extractor);

    #50; rst_n = 1; #50;

    // =========================================================
    // PATTERN 1: Filled circle  (center=13,13  radius=10)
    // Expected: high area ~314, aspect~1.0(256), high circularity
    //           low symmetry error
    // =========================================================
    pixels = 784'b0;
    for (r = 0; r < 28; r = r+1)
        for (c = 0; c < 28; c = c+1) begin
            dr = r - 13; dc = c - 13;
            r2 = dr*dr + dc*dc;
            if (r2 <= 100) set_px(r, c);   // radius 10
        end
    run_and_show("CIRCLE      ");

    // =========================================================
    // PATTERN 2: Filled square  (rows 7-20, cols 7-20 = 14x14)
    // Expected: area=196, aspect=1.0(256), moderate circ, low sym error
    // =========================================================
    pixels = 784'b0;
    for (r = 7; r <= 20; r = r+1)
        for (c = 7; c <= 20; c = c+1)
            set_px(r, c);
    run_and_show("SQUARE      ");

    // =========================================================
    // PATTERN 3: Wide rectangle  (rows 10-17, cols 3-24 = 8x22)
    // Expected: area=176, aspect>1.0 (wide), low circ, low sym error
    // =========================================================
    pixels = 784'b0;
    for (r = 10; r <= 17; r = r+1)
        for (c = 3; c <= 24; c = c+1)
            set_px(r, c);
    run_and_show("RECTANGLE   ");

    // =========================================================
    // PATTERN 4: Right triangle  (bottom-left, 20 rows)
    // Expected: low area, high sym error
    // =========================================================
    pixels = 784'b0;
    for (r = 4; r <= 23; r = r+1)
        for (c = 4; c <= 4+(r-4); c = c+1)
            set_px(r, c);
    run_and_show("TRIANGLE    ");

    $display("\n==============================================");
    $display("Copy the values above into classifier.v");
    $display("C_AREA/S_AREA/R_AREA/T_AREA  etc.");
    $display("==============================================");
    $finish;
end

initial begin
    #10_000_000;
    $display("TIMEOUT"); $finish;
end

endmodule