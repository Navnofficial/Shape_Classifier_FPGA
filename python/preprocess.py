"""
preprocess.py
Shape Classifier Preprocessing Pipeline
Canvas image → 28x28 binary grid → 100-byte UART frame
"""

import numpy as np
from PIL import Image

# ─────────────────────────────────────────
#  PROTOCOL CONSTANTS
# ─────────────────────────────────────────
START_BYTE  = 0xAA
GRID_SIZE   = 28
PIXEL_COUNT = GRID_SIZE * GRID_SIZE   # 784
BYTE_COUNT  = (PIXEL_COUNT + 7) // 8  # 98
FRAME_SIZE  = 1 + BYTE_COUNT + 1      # 100


# ─────────────────────────────────────────
#  MAIN PIPELINE
# ─────────────────────────────────────────
def preprocess_canvas(canvas_image, debug=False):
    """
    PIL Image (white bg, black drawing) →
        (grid 28x28 ndarray, uart_frame bytearray 100, features dict)
    Returns (None, None, None) if canvas is empty.
    """
    img     = canvas_image.convert("L")
    img_arr = np.array(img, dtype=np.uint8)
    binary  = (img_arr < 200).astype(np.uint8)

    if binary.sum() < 10:
        return None, None, None

    # Bounding box + 10% padding
    rows = np.any(binary, axis=1)
    cols = np.any(binary, axis=0)
    rmin, rmax = np.where(rows)[0][[0, -1]]
    cmin, cmax = np.where(cols)[0][[0, -1]]
    h, w   = rmax - rmin + 1, cmax - cmin + 1
    pad_r  = max(int(h * 0.10), 2)
    pad_c  = max(int(w * 0.10), 2)
    rmin_p = max(rmin - pad_r, 0)
    rmax_p = min(rmax + pad_r, binary.shape[0] - 1)
    cmin_p = max(cmin - pad_c, 0)
    cmax_p = min(cmax + pad_c, binary.shape[1] - 1)
    cropped = binary[rmin_p:rmax_p+1, cmin_p:cmax_p+1]

    # Resize to 28x28
    crop_img = Image.fromarray((cropped * 255).astype(np.uint8), mode="L")
    resized  = crop_img.resize((GRID_SIZE, GRID_SIZE), Image.LANCZOS)
    res_arr  = np.array(resized, dtype=np.uint8)
    binary28 = (res_arr > 127).astype(np.uint8)

    # Morphological closing (fill gaps)
    binary28 = _morph_close(binary28, 3)

    # Center of mass centering
    binary28 = _center_image(binary28)

    features   = compute_features(binary28)
    uart_frame = pack_uart_frame(binary28)

    if debug:
        _print_grid(binary28)
        print("Features:", features)

    return binary28, uart_frame, features


# ─────────────────────────────────────────
#  FEATURE COMPUTATION
#  Mirrors the FPGA feature_extractor.v
# ─────────────────────────────────────────
def compute_features(grid):
    N    = GRID_SIZE
    area = int(grid.sum())

    rows_any = np.any(grid, axis=1)
    cols_any = np.any(grid, axis=0)
    if rows_any.sum() == 0 or cols_any.sum() == 0:
        return {}

    rmin, rmax = np.where(rows_any)[0][[0, -1]]
    cmin, cmax = np.where(cols_any)[0][[0, -1]]
    H = max(rmax - rmin + 1, 1)
    W = max(cmax - cmin + 1, 1)
    aspect_ratio = round(W / H, 4)

    # Perimeter: pixels with at least one empty 4-neighbor
    perimeter = 0
    for r in range(N):
        for c in range(N):
            if grid[r, c]:
                n = 0
                if r > 0:   n += grid[r-1, c]
                if r < N-1: n += grid[r+1, c]
                if c > 0:   n += grid[r, c-1]
                if c < N-1: n += grid[r, c+1]
                if n < 4:
                    perimeter += 1

    circularity = round((area ** 2) / max(perimeter, 1), 2)

    half = N // 2
    Q1 = int(grid[:half, :half].sum())
    Q2 = int(grid[:half, half:].sum())
    Q3 = int(grid[half:, :half].sum())
    Q4 = int(grid[half:, half:].sum())
    horiz_sym = abs(Q1 - Q2) + abs(Q3 - Q4)
    vert_sym  = abs(Q1 - Q3) + abs(Q2 - Q4)

    row_sums = grid.sum(axis=1).astype(int)
    col_sums = grid.sum(axis=0).astype(int)

    return {
        "area":         area,
        "aspect_ratio": aspect_ratio,
        "perimeter":    perimeter,
        "circularity":  circularity,
        "horiz_sym":    horiz_sym,
        "vert_sym":     vert_sym,
        "row_var":      int(row_sums.max() - row_sums.min()),
        "col_var":      int(col_sums.max() - col_sums.min()),
        "Q1": Q1, "Q2": Q2, "Q3": Q3, "Q4": Q4,
    }


# ─────────────────────────────────────────
#  UART FRAME PACKER
#  [0xAA][98 bytes pixel data][XOR checksum]
# ─────────────────────────────────────────
def pack_uart_frame(grid):
    flat       = grid.flatten()
    data_bytes = bytearray(BYTE_COUNT)
    for i in range(BYTE_COUNT):
        byte_val = 0
        for bit in range(8):
            pidx = i * 8 + bit
            if pidx < PIXEL_COUNT and flat[pidx]:
                byte_val |= (1 << (7 - bit))
        data_bytes[i] = byte_val

    checksum = 0
    for b in data_bytes:
        checksum ^= b

    frame = bytearray([START_BYTE]) + data_bytes + bytearray([checksum])
    assert len(frame) == FRAME_SIZE
    return frame


# ─────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────
def _morph_close(binary, kernel_size=3):
    k = kernel_size // 2
    dilated = np.zeros_like(binary)
    for dr in range(-k, k+1):
        for dc in range(-k, k+1):
            shifted = np.roll(np.roll(binary, dr, axis=0), dc, axis=1)
            dilated = np.maximum(dilated, shifted)
    eroded = np.ones_like(dilated)
    for dr in range(-k, k+1):
        for dc in range(-k, k+1):
            shifted = np.roll(np.roll(dilated, dr, axis=0), dc, axis=1)
            eroded = np.minimum(eroded, shifted)
    return eroded.astype(np.uint8)


def _center_image(binary):
    N = binary.shape[0]
    if binary.sum() == 0:
        return binary
    ri, ci = np.where(binary)
    cy, cx  = int(ri.mean()), int(ci.mean())
    dr, dc  = N//2 - cy, N//2 - cx
    centered = np.zeros_like(binary)
    for r in range(N):
        for c in range(N):
            nr, nc = r + dr, c + dc
            if 0 <= nr < N and 0 <= nc < N:
                centered[nr, nc] = binary[r, c]
    return centered


def _print_grid(grid):
    print("┌" + "─" * GRID_SIZE + "┐")
    for row in grid:
        print("│" + "".join("█" if p else " " for p in row) + "│")
    print("└" + "─" * GRID_SIZE + "┘")


# ─────────────────────────────────────────
#  CALIBRATION REPORT PRINTER
# ─────────────────────────────────────────
def print_calibration_report(features_list, label):
    if not features_list:
        return
    keys = features_list[0].keys()
    print(f"\n{'='*52}")
    print(f"  CALIBRATION REPORT — {label.upper()}")
    print(f"{'='*52}")
    print(f"  Samples : {len(features_list)}")
    print(f"  {'Feature':<16} {'Min':>8} {'Max':>8} {'Mean':>8}")
    print(f"  {'-'*46}")
    for k in keys:
        vals = [f[k] for f in features_list if k in f]
        if vals:
            print(f"  {k:<16} {min(vals):>8.1f} {max(vals):>8.1f}"
                  f" {np.mean(vals):>8.1f}")
    print()