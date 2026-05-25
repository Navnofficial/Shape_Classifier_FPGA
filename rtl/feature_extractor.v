// ============================================================
//  feature_extractor.v
//  Computes 5 features from 28x28 binary pixel grid
//  Optimized for HOLLOW shapes (circle, square, rectangle, triangle)
//
//  Features:
//    feat_area     — total pixel count
//    feat_aspect   — bounding box W/H in Q8.8 (256 = 1.0)
//    feat_row_var  — max(row_sums) - min(row_sums)  [circle vs square key]
//    feat_hsym     — horizontal symmetry error
//    feat_vsym     — vertical symmetry error
//
//  Single pass = 784 clock cycles = 15.7 us at 50 MHz
// ============================================================
module feature_extractor (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [783:0] pixels,   // 28x28 flat, pixel[0]=top-left
    input  wire        start,     // 1-cycle pulse to begin

    output reg         done,      // 1-cycle pulse when features ready
    output reg [9:0]   feat_area,
    output reg [15:0]  feat_aspect,   // Q8.8: 256 = 1.0
    output reg [4:0]   feat_row_var,  // 0-28
    output reg [9:0]   feat_hsym,
    output reg [9:0]   feat_vsym
);

localparam GRID = 28;

// FSM
localparam S_IDLE   = 2'd0;
localparam S_SCAN   = 2'd1;
localparam S_FINISH = 2'd2;

reg [1:0] state;

// Scan counters
reg [9:0] idx;       // pixel index 0-783
reg [4:0] row;       // current row  0-27
reg [4:0] col;       // current col  0-27

// Accumulators
reg [9:0] area;
reg [4:0] rmin, rmax, cmin, cmax;
reg [9:0] Q1, Q2, Q3, Q4;
reg [4:0] row_sums [0:27];   // pixels per row

// Current pixel
wire px = pixels[idx];

integer i;

always @(posedge clk) begin
    if (!rst_n) begin
        state    <= S_IDLE;
        done     <= 0;
        idx      <= 0;
        row      <= 0;
        col      <= 0;
        area     <= 0;
        rmin     <= 27; rmax <= 0;
        cmin     <= 27; cmax <= 0;
        Q1 <= 0; Q2 <= 0; Q3 <= 0; Q4 <= 0;
        for (i = 0; i < 28; i = i+1) row_sums[i] <= 0;
        feat_area    <= 0;
        feat_aspect  <= 0;
        feat_row_var <= 0;
        feat_hsym    <= 0;
        feat_vsym    <= 0;
    end else begin
        done <= 0;

        case (state)

            // ── Wait for start pulse ──────────────────────────
            S_IDLE: begin
                if (start) begin
                    // Reset all accumulators
                    area <= 0;
                    rmin <= 27; rmax <= 0;
                    cmin <= 27; cmax <= 0;
                    Q1 <= 0; Q2 <= 0; Q3 <= 0; Q4 <= 0;
                    for (i = 0; i < 28; i = i+1)
                        row_sums[i] <= 0;
                    idx   <= 0;
                    row   <= 0;
                    col   <= 0;
                    state <= S_SCAN;
                end
            end

            // ── Scan all 784 pixels one per clock ─────────────
            S_SCAN: begin
                if (px) begin
                    // Count area
                    area <= area + 1;

                    // Update bounding box
                    if (row < rmin) rmin <= row;
                    if (row > rmax) rmax <= row;
                    if (col < cmin) cmin <= col;
                    if (col > cmax) cmax <= col;

                    // Quadrant counts (14x14 each)
                    if (row < 14 && col < 14) Q1 <= Q1 + 1;  // top-left
                    if (row < 14 && col >= 14) Q2 <= Q2 + 1; // top-right
                    if (row >= 14 && col < 14) Q3 <= Q3 + 1; // bot-left
                    if (row >= 14 && col >= 14) Q4 <= Q4 + 1;// bot-right

                    // Row sum for this row
                    row_sums[row] <= row_sums[row] + 1;
                end

                // Advance pixel pointer
                if (idx == 783) begin
                    state <= S_FINISH;
                end else begin
                    idx <= idx + 1;
                    if (col == 27) begin
                        col <= 0;
                        row <= row + 1;
                    end else begin
                        col <= col + 1;
                    end
                end
            end

            // ── Compute final features ────────────────────────
            S_FINISH: begin

                // Feature A: Area
                feat_area <= area;

                // Feature B: Aspect ratio Q8.8 = (W/H) * 256
                begin : asp_block
                    reg [4:0] W, H;
                    W = (cmax >= cmin) ? (cmax - cmin + 1) : 5'd1;
                    H = (rmax >= rmin) ? (rmax - rmin + 1) : 5'd1;
                    feat_aspect <= ({11'b0, W} << 8) / {11'b0, H};
                end

                // Feature C: Row variance = max(row_sums) - min(row_sums)
                // High for circle (bell curve), Low for square/rectangle (flat)
                begin : rv_block
                    reg [4:0] rv_max, rv_min;
                    integer j;
                    rv_max = 5'd0;
                    rv_min = 5'd28;
                    for (j = 0; j < 28; j = j+1) begin
                        if (row_sums[j] > rv_max) rv_max = row_sums[j];
                        if (row_sums[j] < rv_min) rv_min = row_sums[j];
                    end
                    feat_row_var <= rv_max - rv_min;
                end

                // Feature D: Horizontal symmetry error
                // Low = symmetric left-right (circle, square, rect)
                // High = asymmetric (triangle)
                feat_hsym <= ((Q1 >= Q2) ? (Q1 - Q2) : (Q2 - Q1))
                           + ((Q3 >= Q4) ? (Q3 - Q4) : (Q4 - Q3));

                // Feature E: Vertical symmetry error
                feat_vsym <= ((Q1 >= Q3) ? (Q1 - Q3) : (Q3 - Q1))
                           + ((Q2 >= Q4) ? (Q2 - Q4) : (Q4 - Q2));

                done  <= 1;
                state <= S_IDLE;
            end

        endcase
    end
end

endmodule