# Shape Classifier — FPGA + Python Pipeline

> **No neural network. No ML library. Just math, hardware, and one very stubborn bug.**

A real-time shape-classification system: a Python GUI streams a hand-drawn 28×28 bitmap over UART to an Altera DE2 FPGA, which classifies the shape in **20 ns** using purely combinational Verilog and fixed-point arithmetic.

---

## 🗂️ Repository Layout

```
Shape_Classifier/
├── rtl/                   # Synthesisable Verilog RTL
│   ├── top.v              # Top-level integration
│   ├── uart_rx.v          # UART 8N1 receiver + frame validator
│   ├── feature_extractor.v# FSM — area, aspect ratio, variance, symmetry, perimeter
│   ├── classifier.v       # Nearest-centroid weighted L1 distance (single-cycle)
│   ├── pixel_ram.v        # 784-bit pixel store
│   └── seg7_driver.v      # 7-segment display driver
├── sim/                   # Icarus / ModelSim testbenches
│   ├── tb_uart_rx.v
│   └── tb_feature_extractor.v
├── constraints/
│   └── de2_pins.qsf       # Altera DE2 pin assignments
├── python/
│   ├── gui_draw.py        # Tkinter GUI — draw, preprocess, send, receive
│   └── preprocess.py      # Centre-of-mass crop → 28×28 → feature extraction
└── doc/                   # Supporting documentation / images
```

---

## ⚙️ System Overview

```
 ┌──────────────────────────┐        UART 115 200 baud        ┌─────────────────────────────────────┐
 │   Python GUI (PC)        │  ──────────────────────────►    │       Altera DE2 FPGA               │
 │                          │                                  │                                     │
 │  • Draw shape on canvas  │  100-byte frame (784 px + CRC)  │  uart_rx  →  feature_extractor  →   │
 │  • Auto-crop & 28×28     │ ◄──────────────────────────────  │  classifier  →  seg7 / LEDs         │
 │  • 5 geometric features  │        result byte              │                                     │
 └──────────────────────────┘                                  └─────────────────────────────────────┘
```

**Shapes supported:** Circle · Square · Rectangle · Triangle

---

## 🧮 How Classification Works

The `feature_extractor` FSM scans all 784 pixels (one per clock cycle) and computes five features in hardware:

| Feature | Representation |
|---|---|
| Pixel area | 10-bit integer |
| Aspect ratio | Q8.8 fixed-point (256 = 1.0) |
| Row variance | 5-bit integer |
| Horizontal symmetry | 5-bit integer |
| Perimeter | 10-bit integer |

The `classifier` then calculates the weighted Manhattan (L1) distance to four pre-calibrated centroids **simultaneously** in combinational logic:

```
Distance = W_area×|area − C_area| + W_aspect×|aspect − C_aspect| + …
```

Symmetry carries weight 4; all other features weight 1. The shape with the **lowest total distance wins** — computed in a single 20 ns clock cycle.

No floating-point, no multipliers, no DSP blocks.

---

## 📊 Resource Utilisation (Cyclone II EP2C35F672C6)

| Resource | Used | Available | % |
|---|---|---|---|
| Logic Elements (LEs) | 5 326 | 33 216 | **16 %** |
| Registers | 2 724 | 33 216 | 8 % |
| Pins | 108 | 475 | 23 % |
| Embedded Multipliers | 0 | 70 | **0 %** |

---

## 🐛 The Bug That Taught Everything

Every shape was classified as **Rectangle**.

The Python GUI packs pixels **MSB-first** (pixel 0 at bit 7). The FPGA was unpacking **LSB-first**. Every 8-pixel chunk was mirrored, scrambling the entire 28×28 spatial layout before it reached the feature extractor.

The classifier was doing its job perfectly — classifying the **wrong data** perfectly.

**Fix:** reverse the bit-index mapping in the UART unpack loop. One line. Everything worked.

> *Interface bug masquerading as algorithm failure. In RTL these look identical until you trace the data path bit by bit.*

---

## 🚀 Quick Start

### Hardware Required
- Altera DE2 board (Cyclone II EP2C35F672C6)
- USB-Serial cable to PC

### 1 — Synthesise the RTL
1. Open Quartus II and create a new project pointing at `rtl/top.v`.
2. Import pin assignments from `constraints/de2_pins.qsf`.
3. Compile → Program the `.sof` to the DE2.

### 2 — Run the Python GUI
```bash
pip install pyserial pillow numpy
python python/gui_draw.py
```
Select the correct COM port, draw a shape, and press **Classify**.

---

## 🛠️ Stack

| | |
|---|---|
| **Board** | Altera DE2 · Cyclone II EP2C35F672C6 |
| **RTL** | Verilog · Quartus II |
| **Simulation** | Icarus Verilog / ModelSim |
| **Host** | Python 3 · Tkinter · PySerial |
| **Protocol** | UART 115 200 baud · 8N1 · 100-byte frame + XOR checksum |
| **Latency** | 20 ns classification · ~8.78 ms full round-trip |

---

## 📝 Known Limitations

- **Setup timing violation:** The combinational classifier has −63.727 ns setup slack at 50 MHz. It works on hardware, but pipelining the adder tree is the planned next step.
- Centroids are hard-coded from 20 hand-drawn samples per shape; recalibration required for different drawing styles.

---

## 📄 License

MIT — see [LICENSE](LICENSE) for details.
