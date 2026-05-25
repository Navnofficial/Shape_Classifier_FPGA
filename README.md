# Shape Classifier — FPGA + Python Pipeline

> **No neural network. No ML library. Just math, hardware, and one very stubborn bug.**

A real-time shape-classification system: a Python GUI streams a hand-drawn 28x28 bitmap over UART to an Altera DE2 FPGA, which classifies the shape in **20 ns** using purely combinational Verilog and fixed-point arithmetic.

---

## Repository Layout

```
Shape_Classifier/
├── rtl/                    # Synthesisable Verilog RTL
│   ├── top.v               # Top-level integration
│   ├── uart_rx.v           # UART 8N1 receiver + frame validator
│   ├── feature_extractor.v # FSM — area, aspect ratio, variance, symmetry, perimeter
│   ├── classifier.v        # Nearest-centroid weighted L1 distance (single-cycle)
│   ├── pixel_ram.v         # 784-bit pixel store
│   └── seg7_driver.v       # 7-segment display driver
├── sim/                    # Testbenches (Icarus Verilog / ModelSim)
│   ├── tb_uart_rx.v
│   └── tb_feature_extractor.v
├── constraints/
│   └── de2_pins.qsf        # Altera DE2 pin assignments
├── python/
│   ├── gui_draw.py         # Tkinter GUI — draw, preprocess, send, receive result
│   └── preprocess.py       # Centre-of-mass crop → 28x28 → feature extraction
└── doc/                    # Supporting documentation
```

---

## System Overview

```
 +---------------------------+      UART 115200 baud       +----------------------------------------------+
 |   Python GUI (PC)         |  ------------------------>  |            Altera DE2 FPGA                   |
 |                           |  100-byte frame (784px+CRC) |                                              |
 |  - Draw shape on canvas   |                             |  uart_rx -> feature_extractor -> classifier  |
 |  - Auto-crop to 28x28     |  <------------------------  |                    -> 7-seg display / LEDs   |
 |  - Extract 5 features     |       result byte           |                                              |
 +---------------------------+                             +----------------------------------------------+
```

**Shapes supported:** Circle, Square, Rectangle, Triangle

---

## How Classification Works

### Feature Extraction

The `feature_extractor` module is an FSM that scans all 784 pixels, one per clock cycle, and computes five geometric features entirely in hardware:

| Feature             | Representation                  |
|---------------------|---------------------------------|
| Pixel area          | 10-bit integer                  |
| Aspect ratio        | Q8.8 fixed-point (256 = 1.0)   |
| Row variance        | 5-bit integer                   |
| Horizontal symmetry | 5-bit integer                   |
| Perimeter           | 10-bit integer                  |

### Nearest-Centroid Classification

The `classifier` module calculates the weighted Manhattan (L1) distance to four pre-calibrated shape centroids simultaneously, in a single combinational stage:

```
Distance = W_area x |area - C_area| + W_aspect x |aspect - C_aspect| + ...
```

- Symmetry carries weight 4; all other features carry weight 1.
- The shape with the **lowest total distance** is the classification result.
- The entire decision is resolved in **one clock cycle — 20 ns**.

No floating-point units, no embedded multipliers, no DSP blocks.

---

## Resource Utilisation — Cyclone II EP2C35F672C6

| Resource            | Used   | Available | Utilisation |
|---------------------|--------|-----------|-------------|
| Logic Elements (LEs)| 5,326  | 33,216    | 16%         |
| Registers           | 2,724  | 33,216    | 8%          |
| Pins                | 108    | 475       | 23%         |
| Embedded Multipliers| 0      | 70        | 0%          |

---

## The Bug That Taught Everything

Every shape was classified as **Rectangle** — Circle, Triangle, Square, all of them.

**Root cause:** The Python GUI packs pixels MSB-first (pixel 0 at bit 7). The FPGA was unpacking LSB-first. Every 8-pixel chunk was mirrored, which scrambled the entire 28x28 spatial layout before it ever reached the feature extractor.

The classifier was operating correctly. It was classifying the wrong data correctly.

**Fix:** Reverse the bit-index mapping in the UART unpack loop. One line changed. Everything worked.

> Interface bug masquerading as algorithm failure. In RTL, these look identical until you trace the data path bit by bit.

---

## Quick Start

### Hardware Required

- Altera DE2 board (Cyclone II EP2C35F672C6)
- USB-to-Serial cable connected to PC

### Step 1 — Synthesise and Program the FPGA

1. Open Quartus II and create a new project with `rtl/top.v` as the top-level entity.
2. Import pin assignments: **Assignments → Import Assignments → `constraints/de2_pins.qsf`**.
3. Run full compilation.
4. Program the generated `.sof` file to the DE2 via JTAG.

### Step 2 — Run the Python GUI

```bash
pip install pyserial pillow numpy
python python/gui_draw.py
```

Select the correct COM port from the dropdown, draw a shape in the canvas, and click **Classify**. The result appears in the GUI and simultaneously on the FPGA's 7-segment display and LEDs.

---

## Tech Stack

| Component   | Details                                              |
|-------------|------------------------------------------------------|
| Board       | Altera DE2 — Cyclone II EP2C35F672C6                |
| RTL         | Verilog, synthesised with Quartus II                 |
| Simulation  | Icarus Verilog / ModelSim                            |
| Host        | Python 3, Tkinter, PySerial                          |
| Protocol    | UART 8N1, 115200 baud, 100-byte frame + XOR checksum|
| Latency     | 20 ns classification, ~8.78 ms full round-trip       |

---

## Known Limitations

- **Setup timing violation:** The combinational classifier reports -63.727 ns setup slack at 50 MHz. The design functions correctly on hardware, but pipelining the adder tree is the planned fix.
- Shape centroids are calibrated from 20 hand-drawn samples per class. Different drawing styles or stroke widths may require recalibration.

---

## License

MIT — see [LICENSE](LICENSE) for details.
