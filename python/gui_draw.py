"""
gui_draw.py
Shape Classifier GUI — DE2 FPGA
Optimized for HOLLOW shapes: circle, square, rectangle, triangle

CALIBRATION WORKFLOW:
  1. Set dropdown to "Circle"
  2. Draw a hollow circle → click ADD → click CLEAR
  3. Repeat step 2  twenty times
  4. Switch dropdown to "Square", repeat 20 times
  5. Switch dropdown to "Rectangle", repeat 20 times
  6. Switch dropdown to "Triangle", repeat 20 times
  7. Click REPORT — copy Mean column values into classifier.v

Run:  python gui_draw.py
Needs: pip install pillow numpy pyserial
"""

import tkinter as tk
from tkinter import ttk, messagebox
import serial
import serial.tools.list_ports
import threading
import numpy as np
from PIL import Image, ImageDraw

from preprocess import (
    preprocess_canvas,
    print_calibration_report,
    GRID_SIZE,
)

# ─────────────────────────────────────────
#  CONFIG
# ─────────────────────────────────────────
CANVAS_SIZE  = 280
STROKE_WIDTH = 12    # thick enough to show clearly on 28x28
BAUD_RATE    = 115_200
SHAPE_LABELS = ["Circle", "Square", "Rectangle", "Triangle"]

FPGA_RESPONSE = {
    0x01: "CIRCLE",
    0x02: "SQUARE",
    0x03: "RECTANGLE",
    0x04: "TRIANGLE",
    0xFF: "CHECKSUM ERR",
}


class ShapeClassifierApp:
    def __init__(self, root):
        self.root  = root
        self.root.title("Shape Classifier — DE2 FPGA")
        self.root.configure(bg="#1a1a2e")
        self.root.resizable(False, False)

        self.ser       = None
        self.connected = False
        self.last_x    = None
        self.last_y    = None

        self.calib_data = {lbl: [] for lbl in SHAPE_LABELS}

        self.pil_image = Image.new("L", (CANVAS_SIZE, CANVAS_SIZE), color=255)
        self.pil_draw  = ImageDraw.Draw(self.pil_image)

        self._build_ui()
        self._refresh_ports()

        # Always enable classify — works offline too
        self.btn_classify.config(state="normal")

    # ─────────────────────────────────────
    #  UI
    # ─────────────────────────────────────
    def _build_ui(self):
        tf = tk.Frame(self.root, bg="#0f3460", pady=8)
        tf.pack(fill="x")
        tk.Label(tf, text="FPGA SHAPE CLASSIFIER",
                 font=("Courier New", 16, "bold"),
                 fg="#e94560", bg="#0f3460").pack()
        tk.Label(tf, text="DE2  ·  Cyclone II  ·  USB-TTL @ 115200",
                 font=("Courier New", 9),
                 fg="#a0a0c0", bg="#0f3460").pack()

        content = tk.Frame(self.root, bg="#1a1a2e", padx=15, pady=12)
        content.pack()

        # LEFT — canvas
        left = tk.Frame(content, bg="#1a1a2e")
        left.grid(row=0, column=0, padx=(0, 15))

        tk.Label(left, text="DRAW SHAPE",
                 font=("Courier New", 10, "bold"),
                 fg="#53d8fb", bg="#1a1a2e").pack(anchor="w")

        cborder = tk.Frame(left, bg="#e94560", padx=2, pady=2)
        cborder.pack()
        self.canvas = tk.Canvas(cborder,
                                width=CANVAS_SIZE, height=CANVAS_SIZE,
                                bg="white", cursor="crosshair",
                                highlightthickness=0)
        self.canvas.pack()
        self.canvas.bind("<ButtonPress-1>",   self._on_press)
        self.canvas.bind("<B1-Motion>",       self._on_drag)
        self.canvas.bind("<ButtonRelease-1>", self._on_release)

        tk.Label(left,
                 text="Draw hollow outline. Large. Fill canvas. Clear between each.",
                 font=("Courier New", 7), fg="#606080",
                 bg="#1a1a2e").pack(pady=(4, 0))

        # RIGHT — controls
        right = tk.Frame(content, bg="#1a1a2e")
        right.grid(row=0, column=1, sticky="n")

        # Port
        self._section(right, "UART PORT")
        pr = tk.Frame(right, bg="#1a1a2e")
        pr.pack(fill="x", pady=(0, 6))
        self.port_var = tk.StringVar()
        self.port_combo = ttk.Combobox(pr, textvariable=self.port_var,
                                       width=18, font=("Courier New", 9))
        self.port_combo.pack(side="left")
        tk.Button(pr, text="↻", command=self._refresh_ports,
                  font=("Courier New", 9, "bold"),
                  bg="#53d8fb", fg="#1a1a2e", relief="flat",
                  padx=6, pady=3, cursor="hand2").pack(side="left", padx=4)

        self.btn_connect = self._bigbtn(right, "CONNECT",
                                        self._toggle_connect, "#53d8fb")
        self.btn_connect.pack(fill="x", pady=(0, 10))

        # Classify + Clear
        self._section(right, "CLASSIFY")
        self.btn_classify = self._bigbtn(right, "SEND & CLASSIFY",
                                          self._classify, "#e94560")
        self.btn_classify.pack(fill="x", pady=(0, 4))
        self._bigbtn(right, "CLEAR", self._clear,
                     "#404060").pack(fill="x", pady=(0, 10))

        # Result
        self._section(right, "RESULT")
        rb = tk.Frame(right, bg="#0f3460", padx=10, pady=10)
        rb.pack(fill="x", pady=(0, 6))
        self.result_var = tk.StringVar(value="---")
        self.result_lbl = tk.Label(rb, textvariable=self.result_var,
                                   font=("Courier New", 20, "bold"),
                                   fg="#00ff88", bg="#0f3460", width=14)
        self.result_lbl.pack()
        self.conf_var = tk.StringVar(value="draw a shape and classify")
        tk.Label(rb, textvariable=self.conf_var,
                 font=("Courier New", 8),
                 fg="#a0a0c0", bg="#0f3460").pack()

        # Feature debug
        self._section(right, "FEATURES")
        feat_bg = tk.Frame(right, bg="#0a0a18", padx=6, pady=6)
        feat_bg.pack(fill="x", pady=(0, 8))
        self.feat_var = tk.StringVar(value="classify a shape to see values")
        tk.Label(feat_bg, textvariable=self.feat_var,
                 font=("Courier New", 8),
                 fg="#53d8fb", bg="#0a0a18",
                 justify="left").pack(anchor="w")

        # Preview
        self._section(right, "28×28 PREVIEW")
        pb = tk.Frame(right, bg="#404060", padx=1, pady=1)
        pb.pack()
        self.preview = tk.Canvas(pb,
                                 width=GRID_SIZE * 6,
                                 height=GRID_SIZE * 6,
                                 bg="#111122",
                                 highlightthickness=0)
        self.preview.pack()

        # Calibration
        self._section(right, "CALIBRATION")
        tk.Label(right,
                 text="Draw → ADD → CLEAR → repeat 20x per shape → REPORT",
                 font=("Courier New", 7), fg="#a0a060",
                 bg="#1a1a2e", wraplength=230).pack(anchor="w", pady=(0, 4))

        cr = tk.Frame(right, bg="#1a1a2e")
        cr.pack(fill="x", pady=(0, 4))
        self.calib_var = tk.StringVar(value=SHAPE_LABELS[0])
        ttk.Combobox(cr, textvariable=self.calib_var,
                     values=SHAPE_LABELS, width=11,
                     font=("Courier New", 9),
                     state="readonly").pack(side="left")
        tk.Button(cr, text="ADD",
                  command=self._calib_add,
                  font=("Courier New", 8, "bold"),
                  bg="#f0a500", fg="#1a1a2e", relief="flat",
                  padx=8, pady=3, cursor="hand2").pack(side="left", padx=4)
        tk.Button(cr, text="REPORT",
                  command=self._calib_report,
                  font=("Courier New", 8, "bold"),
                  bg="#a0ff80", fg="#1a1a2e", relief="flat",
                  padx=8, pady=3, cursor="hand2").pack(side="left")

        self.calib_count = tk.StringVar(value="Samples: 0/0/0/0  (Cir/Sq/Rct/Tri)")
        tk.Label(right, textvariable=self.calib_count,
                 font=("Courier New", 8),
                 fg="#707090", bg="#1a1a2e").pack(anchor="w")

        # Status bar
        self.status_var = tk.StringVar(
            value="Ready — draw a shape and click ADD to calibrate.")
        tk.Label(self.root, textvariable=self.status_var,
                 font=("Courier New", 8),
                 fg="#808090", bg="#0a0a18",
                 anchor="w", padx=8, pady=4).pack(fill="x")

    def _section(self, parent, text):
        tk.Label(parent, text=text,
                 font=("Courier New", 8, "bold"),
                 fg="#53d8fb", bg="#1a1a2e",
                 anchor="w").pack(fill="x", pady=(6, 2))

    def _bigbtn(self, parent, text, cmd, color):
        return tk.Button(parent, text=text, command=cmd,
                         font=("Courier New", 10, "bold"),
                         bg=color, fg="#ffffff",
                         activebackground=color,
                         relief="flat", padx=8, pady=6,
                         cursor="hand2")

    # ─────────────────────────────────────
    #  DRAWING
    # ─────────────────────────────────────
    def _on_press(self, e):
        self.last_x, self.last_y = e.x, e.y

    def _on_drag(self, e):
        if self.last_x is None:
            return
        self.canvas.create_line(
            self.last_x, self.last_y, e.x, e.y,
            fill="black", width=STROKE_WIDTH,
            capstyle=tk.ROUND, smooth=True)
        self.pil_draw.line(
            [self.last_x, self.last_y, e.x, e.y],
            fill=0, width=STROKE_WIDTH)
        self.last_x, self.last_y = e.x, e.y

    def _on_release(self, e):
        self.last_x = self.last_y = None

    def _clear(self):
        self.canvas.delete("all")
        self.pil_image = Image.new("L", (CANVAS_SIZE, CANVAS_SIZE), color=255)
        self.pil_draw  = ImageDraw.Draw(self.pil_image)
        self.preview.delete("all")
        self.result_var.set("---")
        self.conf_var.set("draw a shape and classify")
        self.feat_var.set("classify a shape to see values")
        self._status("Canvas cleared — draw next shape.")

    # ─────────────────────────────────────
    #  SERIAL
    # ─────────────────────────────────────
    def _refresh_ports(self):
        ports = [p.device for p in serial.tools.list_ports.comports()]
        self.port_combo["values"] = ports
        if ports:
            self.port_var.set(ports[0])
        self._status(f"Found {len(ports)} port(s).")

    def _toggle_connect(self):
        if self.connected:
            self._disconnect()
        else:
            self._connect()

    def _connect(self):
        port = self.port_var.get()
        if not port:
            messagebox.showerror("Error", "Select a COM port first.")
            return
        try:
            self.ser = serial.Serial(
                port=port, baudrate=BAUD_RATE,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=3)
            self.connected = True
            self.btn_connect.config(text="DISCONNECT", bg="#ff4040")
            self._status(f"Connected: {port} @ {BAUD_RATE} baud")
        except serial.SerialException as e:
            messagebox.showerror("Connection Error", str(e))

    def _disconnect(self):
        if self.ser and self.ser.is_open:
            self.ser.close()
        self.connected = False
        self.btn_connect.config(text="CONNECT", bg="#53d8fb")
        self._status("Disconnected.")

    # ─────────────────────────────────────
    #  CLASSIFY
    # ─────────────────────────────────────
    def _classify(self):
        grid, frame, features = preprocess_canvas(self.pil_image, debug=False)
        if grid is None:
            messagebox.showwarning("Empty Canvas", "Draw a shape first.")
            return

        self._update_preview(grid)
        self._show_features(features)

        if self.connected and self.ser:
            threading.Thread(
                target=self._send_recv,
                args=(frame, features),
                daemon=True).start()
        else:
            shape = self._py_predict(features)
            self.result_var.set(shape)
            self.conf_var.set("offline — Python nearest-centroid")
            self.result_lbl.config(fg="#f0a500")

    def _send_recv(self, frame, features):
        try:
            self.ser.reset_input_buffer()
            self.ser.write(frame)
            resp = self.ser.read(1)
            self.root.after(0, self._update_result, resp, features)
        except serial.SerialException as e:
            self.root.after(0, self._status, f"UART Error: {e}")

    def _update_result(self, resp, features):
        if resp:
            code  = resp[0]
            shape = FPGA_RESPONSE.get(code, f"RAW:0x{code:02X}")
            self.result_var.set(shape)
            self.result_lbl.config(fg="#00ff88")
            self.conf_var.set("← result from FPGA")
        else:
            shape = self._py_predict(features)
            self.result_var.set(shape + " (timeout)")
            self.result_lbl.config(fg="#f0a500")
            self.conf_var.set("FPGA timeout — Python fallback used")

    # ─────────────────────────────────────
    #  PYTHON NEAREST-CENTROID PREDICTION
    #
    #  *** UPDATE THESE after running REPORT ***
    #  Take Mean values from REPORT terminal output.
    #  For aspect: Mean=1.02 → write int(1.02*256)=261
    # ─────────────────────────────────────
    def _py_predict(self, f):
        # ── Calibrated centroids — 20 samples each (2026-05-08) ──────────────
        # area: raw pixel count on 28×28  |  aspect: mean_aspect_ratio × 256
        # row_var: mean row_var  |  hsym/vsym: mean horiz/vert symmetry
        centroids = {
            "CIRCLE":    {"area": 133, "aspect": 256, "row_var": 12, "hsym":  9, "vsym": 11},
            "SQUARE":    {"area": 180, "aspect": 256, "row_var": 22, "hsym": 12, "vsym": 13},
            "RECTANGLE": {"area": 179, "aspect": 282, "row_var": 23, "hsym": 14, "vsym": 11},
            "TRIANGLE":  {"area": 126, "aspect": 256, "row_var": 17, "hsym": 11, "vsym": 18},
        }
        weights = {"area": 1, "aspect": 4, "row_var": 3, "hsym": 4, "vsym": 2}

        inp = {
            "area":    f["area"],
            "aspect":  int(f["aspect_ratio"] * 256),
            "row_var": f["row_var"],
            "hsym":    f["horiz_sym"],
            "vsym":    f["vert_sym"],
        }

        best, best_d = None, float("inf")
        for shape, c in centroids.items():
            d = sum(weights[k] * abs(inp[k] - c[k]) for k in weights)
            if d < best_d:
                best_d, best = d, shape
        return best

    # ─────────────────────────────────────
    #  FEATURE DISPLAY
    # ─────────────────────────────────────
    def _show_features(self, f):
        if not f:
            return
        text = (f"area={f['area']}  AR={f['aspect_ratio']:.2f}  "
                f"row_var={f['row_var']}\n"
                f"hsym={f['horiz_sym']}  vsym={f['vert_sym']}")
        self.feat_var.set(text)
        self._status(f"area={f['area']}  AR={f['aspect_ratio']:.2f}  "
                     f"row_var={f['row_var']}  "
                     f"hsym={f['horiz_sym']}  vsym={f['vert_sym']}")

    # ─────────────────────────────────────
    #  PREVIEW
    # ─────────────────────────────────────
    def _update_preview(self, grid):
        self.preview.delete("all")
        cell = 6
        for r in range(GRID_SIZE):
            for c in range(GRID_SIZE):
                if grid[r, c]:
                    x0 = c * cell
                    y0 = r * cell
                    self.preview.create_rectangle(
                        x0, y0, x0 + cell - 1, y0 + cell - 1,
                        fill="#00ff88", outline="")

    # ─────────────────────────────────────
    #  CALIBRATION
    # ─────────────────────────────────────
    def _calib_add(self):
        grid, _, features = preprocess_canvas(self.pil_image)
        if grid is None:
            messagebox.showwarning("Empty Canvas",
                                   "Draw a shape first, then click ADD.")
            return
        label = self.calib_var.get()
        self.calib_data[label].append(features)
        self._update_calib_count()
        self._update_preview(grid)
        n = len(self.calib_data[label])
        self._status(
            f"[{label}] sample #{n} added — now click CLEAR and draw the next one.")

    def _calib_report(self):
        missing = [l for l in SHAPE_LABELS
                   if len(self.calib_data[l]) < 5]
        if missing:
            messagebox.showwarning(
                "Not Enough Samples",
                f"Need at least 5 samples each.\n"
                f"Missing: {', '.join(missing)}\n"
                f"Counts: " +
                "/".join(str(len(self.calib_data[l]))
                         for l in SHAPE_LABELS))
            return

        print()
        print("=" * 62)
        print("  CALIBRATION REPORT — Shape Classifier")
        print("=" * 62)
        print()
        print("  STEP 1: Read the MEAN column for each shape.")
        print("  STEP 2: Open rtl/classifier.v")
        print("  STEP 3: Update localparam values using this mapping:")
        print()
        print("    area Mean      → C_AREA / S_AREA / R_AREA / T_AREA")
        print("    aspect Mean×256→ C_ASPECT etc  (e.g. 1.02 × 256 = 261)")
        print("    row_var Mean   → C_ROWVAR / S_ROWVAR / R_ROWVAR / T_ROWVAR")
        print("    horiz_sym Mean → C_HSYM / S_HSYM / R_HSYM / T_HSYM")
        print("    vert_sym Mean  → C_VSYM / S_VSYM / R_VSYM / T_VSYM")
        print()
        print("  STEP 4: Update _py_predict() in gui_draw.py same values.")
        print("  STEP 5: Re-compile Quartus → re-flash → test.")
        print()

        for lbl in SHAPE_LABELS:
            print_calibration_report(self.calib_data[lbl], lbl)

        print("=" * 62)
        self._status(
            "Report printed to terminal. Update classifier.v with Mean values.")

    def _update_calib_count(self):
        counts = "/".join(
            str(len(self.calib_data[l])) for l in SHAPE_LABELS)
        total = sum(len(self.calib_data[l]) for l in SHAPE_LABELS)
        self.calib_count.set(
            f"Samples: {counts}  (Cir/Sq/Rct/Tri)  total={total}")

    def _status(self, msg):
        self.status_var.set(f"  {msg}")


def main():
    root = tk.Tk()
    style = ttk.Style()
    style.theme_use("clam")
    style.configure("TCombobox",
                    fieldbackground="#0f3460",
                    background="#0f3460",
                    foreground="#ffffff",
                    selectbackground="#e94560",
                    selectforeground="#ffffff")
    ShapeClassifierApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()