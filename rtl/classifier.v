// classifier.v
// Nearest-centroid for HOLLOW shapes
// Circularity removed (useless for hollow) — row_var added
//
// Shape codes: 00=Circle 01=Square 10=Rectangle 11=Triangle
//
// CALIBRATION: draw 20+ hollow samples per shape in GUI
// click REPORT, take Mean column, paste below

module classifier (
    input  wire [9:0]  feat_area,
    input  wire [15:0] feat_aspect,   // Q8.8: 256 = 1.0
    input  wire [4:0]  feat_row_var,  // max-min of row sums
    input  wire [9:0]  feat_hsym,
    input  wire [9:0]  feat_vsym,

    output reg  [1:0]  shape_code,
    output reg         confident
);

// ── CENTROIDS — paste your Mean values here after calibration ──
// These are starting estimates — replace after your REPORT

// Circle: round hollow ring  [calibrated — 20 samples]
localparam C_AREA    = 10'd133;   // mean area
localparam C_ASPECT  = 16'd256;   // 1.0 × 256 = 256
localparam C_ROWVAR  =  5'd12;    // mean row_var
localparam C_HSYM    = 10'd9;     // mean horiz_sym
localparam C_VSYM    = 10'd11;    // mean vert_sym

// Square: hollow square outline  [calibrated — 20 samples]
localparam S_AREA    = 10'd180;   // mean area
localparam S_ASPECT  = 16'd256;   // 1.0 × 256 = 256
localparam S_ROWVAR  =  5'd22;    // mean row_var
localparam S_HSYM    = 10'd12;    // mean horiz_sym
localparam S_VSYM    = 10'd13;    // mean vert_sym

// Rectangle: hollow rectangle outline  [calibrated — 20 samples]
localparam R_AREA    = 10'd179;   // mean area
localparam R_ASPECT  = 16'd282;   // 1.1 × 256 = 282
localparam R_ROWVAR  =  5'd23;    // mean row_var
localparam R_HSYM    = 10'd14;    // mean horiz_sym
localparam R_VSYM    = 10'd11;    // mean vert_sym

// Triangle: hollow triangle outline  [calibrated — 20 samples]
localparam T_AREA    = 10'd126;   // mean area
localparam T_ASPECT  = 16'd256;   // 1.0 × 256 = 256
localparam T_ROWVAR  =  5'd17;    // mean row_var
localparam T_HSYM    = 10'd11;    // mean horiz_sym
localparam T_VSYM    = 10'd18;    // mean vert_sym

// ── WEIGHTS ───────────────────────────────────────────────────
// Symmetry separates triangle best → weight 4
// Aspect ratio separates rectangle → weight 4
// Row variance separates circle vs square → weight 3
// Area is secondary → weight 1
localparam W_AREA   = 1;
localparam W_ASPECT = 4;
localparam W_ROWVAR = 3;
localparam W_HSYM   = 4;
localparam W_VSYM   = 2;

// ── Absolute difference macro ─────────────────────────────────
`define ABS(a,b) ((a >= b) ? (a - b) : (b - a))

// ── L1 weighted distances ─────────────────────────────────────
wire [23:0] d_circ, d_sq, d_rect, d_tri;

assign d_circ = W_AREA   * `ABS(feat_area,    C_AREA)
              + W_ASPECT * `ABS(feat_aspect,   C_ASPECT)
              + W_ROWVAR * `ABS(feat_row_var,  C_ROWVAR)
              + W_HSYM   * `ABS(feat_hsym,     C_HSYM)
              + W_VSYM   * `ABS(feat_vsym,     C_VSYM);

assign d_sq   = W_AREA   * `ABS(feat_area,    S_AREA)
              + W_ASPECT * `ABS(feat_aspect,   S_ASPECT)
              + W_ROWVAR * `ABS(feat_row_var,  S_ROWVAR)
              + W_HSYM   * `ABS(feat_hsym,     S_HSYM)
              + W_VSYM   * `ABS(feat_vsym,     S_VSYM);

assign d_rect = W_AREA   * `ABS(feat_area,    R_AREA)
              + W_ASPECT * `ABS(feat_aspect,   R_ASPECT)
              + W_ROWVAR * `ABS(feat_row_var,  R_ROWVAR)
              + W_HSYM   * `ABS(feat_hsym,     R_HSYM)
              + W_VSYM   * `ABS(feat_vsym,     R_VSYM);

assign d_tri  = W_AREA   * `ABS(feat_area,    T_AREA)
              + W_ASPECT * `ABS(feat_aspect,   T_ASPECT)
              + W_ROWVAR * `ABS(feat_row_var,  T_ROWVAR)
              + W_HSYM   * `ABS(feat_hsym,     T_HSYM)
              + W_VSYM   * `ABS(feat_vsym,     T_VSYM);

// ── Argmin ─────────────────────────────────────────────────────
wire [23:0] min_ab  = (d_circ  <= d_sq)   ? d_circ  : d_sq;
wire [23:0] min_cd  = (d_rect  <= d_tri)  ? d_rect  : d_tri;
wire [23:0] winner  = (min_ab  <= min_cd) ? min_ab  : min_cd;

// Second smallest (for confidence)
wire [23:0] second =
    (winner == d_circ) ? ((d_sq <= d_rect && d_sq <= d_tri)   ? d_sq   :
                          (d_rect <= d_tri)                    ? d_rect : d_tri) :
    (winner == d_sq)   ? ((d_circ <= d_rect && d_circ<=d_tri) ? d_circ :
                          (d_rect <= d_tri)                    ? d_rect : d_tri) :
    (winner == d_rect) ? ((d_circ <= d_sq && d_circ <= d_tri) ? d_circ :
                          (d_sq <= d_tri)                      ? d_sq   : d_tri) :
                         ((d_circ <= d_sq && d_circ<=d_rect)  ? d_circ :
                          (d_sq <= d_rect)                     ? d_sq   : d_rect);

always @(*) begin
    if      (winner == d_circ) shape_code = 2'b00;
    else if (winner == d_sq)   shape_code = 2'b01;
    else if (winner == d_rect) shape_code = 2'b10;
    else                       shape_code = 2'b11;

    confident = (winner <= (second - (second >> 2)));
end

endmodule