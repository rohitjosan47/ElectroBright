# ElectroBright Hardware & Wiring Guide (ESP32-C3 Edition)

This document details the circuit connections, wiring structure, and important notes for building the ElectroBright hardware specifically using an ESP32-C3 microcontroller (based on the `ElectroBright_ESP32C3_BLE.ino` firmware).

## 1. Components Required
*   **Microcontroller:** ESP32-C3 Development Board
*   **LED Strip:** RGBW LED strip (e.g., 5050 RGBW) - usually 12V, 24V, or 5V (ensure power supply matches the strip's rating).
*   **Power Supply:** Appropriately rated for the LED strip (e.g., 12V 5A, up to much larger depending on strip length).
*   **MOSFETs:** 4x Logic-Level N-Channel MOSFETs (e.g., IRLZ44N, IRLB8721) for driving the R, G, B, and W channels.
*   **Resistors:**
    *   4x 10kΩ Pull-down resistors (for MOSFET gates to keep them off by default / prevent floating states).
    *   4x 220Ω - 470Ω Gate resistors (optional but recommended to protect microcontroller pins from high current spikes).
*   **Buzzer:** 1x Active or Passive Piezo Buzzer (Passive allows for the tone/music generation seen in the code).
*   **Status LED:** 1x standard LED (if you want an external status LED) + 220Ω current-limiting resistor.

## 2. ESP32-C3 Pin Configuration

| Component | Pin | Note |
| :--- | :--- | :--- |
| Red Channel (MOSFET) | GPIO 2 | PWM capable |
| Green Channel (MOSFET) | GPIO 3 | PWM capable |
| Blue Channel (MOSFET) | GPIO 4 | PWM capable |
| White Channel (MOSFET) | GPIO 5 | PWM capable |
| Buzzer | GPIO 6 | PWM capable |
| Status LED | GPIO 7 | |

## 3. Detailed Wiring Structure

### Power Connections
1.  **Main Power Supply:** Connect the positive (+) of your power supply to the `VCC` or `12V/24V` pad on the LED strip.
2.  **Common Ground:** Connect the negative (-) of the power supply to the LED Strip Ground (if applicable), the **Source** pins of all MOSFETs, and the **GND** pin of your ESP32-C3. **(CRITICAL: All grounds must be tied together)**.
3.  **ESP32-C3 Power:**
    *   If using a 12V/24V supply for the LED strip, **do not** connect it directly to the ESP32-C3's `VIN/5V`. You must use a **Buck Converter** to step down the voltage to a safe 5V. 
    *   Connect the output of the buck converter to the `5V` (or `VIN`) and `GND` pins of the ESP32-C3 board.

### MOSFET Wiring (For R, G, B, and W Channels)
For each color channel (Red, Green, Blue, White), wire a logic-level N-channel MOSFET as follows:
1.  **Gate (Pin 1):** Connect to the corresponding ESP32-C3 GPIO Pin (via a 220Ω series resistor). Also, connect a 10kΩ pull-down resistor between the Gate and Ground.
2.  **Drain (Pin 2):** Connect to the corresponding color pad (R, G, B, or W) on the LED strip.
3.  **Source (Pin 3):** Connect directly to the common Ground.

### Buzzer Wiring
*   **Positive Pin:** Connect to GPIO 6 on the ESP32-C3.
*   **Negative Pin:** Connect to Ground.
*   *Note: If the buzzer draws more current than the GPIO pin can safely source (usually max 12-40mA for ESP32), use a small NPN transistor (like 2N2222) to drive it.*

### Status LED Wiring
*   Connect the Anode (+) of your external LED to GPIO 7.
*   Connect the Cathode (-) through a 220Ω resistor to Ground.

## 4. Important Points & Precautions
1.  **ESP32 3.3V Logic:** The ESP32-C3 operates on 3.3V logic. If you use standard MOSFETs (like IRF540) that barely trigger at 3.3V, they will get very hot and fail. You **MUST** use Logic-Level MOSFETs (like IRLZ44N) and verify the `Vgs(th)` in the MOSFET datasheet is significantly lower than 3.3V (ideally around 1.5V-2.0V max) to ensure full saturation.
2.  **Current Draw:** LED strips draw a lot of current (roughly 20mA per color per LED. A 5m 300-LED RGBW strip can draw 24 Amps at peak brightness!). Ensure your power supply, wires, and MOSFETs can handle this load safely. Thicker gauge wire must be used for all high-current power routing to the strip and MOSFETs.
3.  **Heat Dissipation:** If driving long LED strips, your MOSFETs may require heatsinks as they will generate heat under heavy loads.
4.  **Common Ground:** The failure to connect the power supply ground and microcontroller ground together is the #1 cause of flickering or non-working lights.
5.  **Safety:** High current DC circuits pose a fire risk if shorted. Always double-check polarity, use appropriate wire gauges, and insulate exposed connections with heat shrink.
