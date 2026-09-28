# ElectroBright Hardware & Wiring Guide (ESP32-C3 Edition)

A circuit connection and hardware assembly guide for building the **ElectroBright** 4-channel RGBW smart lighting system powered by the **ESP32-C3** microcontroller with native Bluetooth Low Energy (BLE 5.0).

The same board also builds two other fixtures:
- the **3-channel RGB fixture**: leave the white channel unpopulated (see [§6](#6-rgb-fixture-3-channels));
- the **5-channel RGBCCT fixture**: add a warm-white channel (see [§7](#7-rgbcct-fixture-5-channels));
- the **2-channel CCT fixture**: only the cool-white and warm-white channels (see [§8](#8-cct-fixture-2-channels));
- the **1-channel single-white fixture**: only the W channel (see [§9](#9-single-white-fixture-1-channel)).

Every PCB has the same pin layout and runs the same universal firmware (3.7.0+): the light stores its fixture type, and the app can change it. Flashing a sketch from `firmware/fixtures/` only sets the type a *new* light gets; see [firmware.md](firmware.md). Upgrading from an Arduino Nano build? See [Appendix A](#appendix-a-arduino-nano-to-esp32-c3-migration).

---

## 1. Bill of Materials (BOM)

| Category | Component | Specification | Quantity |
| :--- | :--- | :--- | :--- |
| **Microcontroller** | ESP32-C3 Dev Board | ESP32-C3 SuperMini, Xiao C3, or DevKitM-1, with **at least 4 MB of flash** (see §3.5) | 1 |
| **Lighting** | RGBW LED Strip | Common-Anode 12V or 24V (e.g., SMD 5050 RGBW / SK6812 RGBW non-addressable) | 1 |
| **Main Power** | DC Power Supply | 12V or 24V (matches strip voltage; sized for strip current: 2A–10A+) | 1 |
| **Logic Power** | DC-DC Buck Converter | LM2596, MP1584, or Mini360 step-down module (12V/24V $\to$ 5V DC) | 1 |
| **Switches** | Logic-Level N-MOSFETs | **IRLZ44N**, **IRLB8721**, **AO3400**, or 4-channel MOSFET driver module | 4 |
| **Gate Resistors** | Metal Film Resistors | **220Ω**, 1/4W; **100Ω** for large MOSFETs such as IRLZ44N (see §3.6) | 4 |
| **Pull-down Resistors**| Metal Film Resistors | **10kΩ**, 1/4W (ties MOSFET Gates to GND to prevent boot flicker) | 4 |
| **Audio** | Piezo Buzzer | Passive Piezo Buzzer (enables frequency generation in firmware) | 1 |
| **Buzzer Protection** | Series Resistor | **100Ω**, 1/4W (optional current limiting for buzzer) | 1 |
| **LED supply filter** (optional) | Low-ESR electrolytic | **470–1000 µF**, rated above the strip voltage (e.g. 35 V for 24 V), across the LED supply (see §3.6) | 1 |

---

## 2. High-Level System Architecture

```mermaid
graph TD
    PSU["Main Power Supply (12V / 24V DC)"]
    BUCK["DC-DC Buck Converter (Step Down to 5V)"]
    ESP["ESP32-C3 Microcontroller (3.3V Logic)"]
    STRIP["RGBW LED Strip (+12V/+24V Common Anode)"]
    MOS["4x Logic-Level N-MOSFETs (R, G, B, W)"]
    BUZZ["Piezo Buzzer (GPIO 6)"]

    PSU -->|"+12V / +24V"| STRIP
    PSU -->|"+12V / +24V"| BUCK
    BUCK -->|"+5V DC"| ESP
    
    ESP -->|"GPIO 1 (Red PWM)"| MOS
    ESP -->|"GPIO 3 (Green PWM)"| MOS
    ESP -->|"GPIO 4 (Blue PWM)"| MOS
    ESP -->|"GPIO 5 (White PWM)"| MOS
    
    MOS -->|"Low-Side Switch (R-, G-, B-, W-)"| STRIP
    ESP -->|"GPIO 6"| BUZZ
    
    PSU -.->|"Common Ground"| BUCK
    BUCK -.->|"Common Ground"| ESP
    ESP -.->|"Common Ground"| MOS
    ESP -.->|"Common Ground"| BUZZ
```

---

## 3. Detailed Wiring Schematics

### 3.1 Power Distribution & Common Ground

> [!WARNING]
> **COMMON GROUND IS CRITICAL:** The negative output of the 12V/24V power supply, the output ground of the DC-DC buck converter, the Source pins of all 4 MOSFETs, and the ESP32-C3 `GND` pin **must all be tied together**. Missing a common ground is the leading cause of random flashing, unresponsive LEDs, and electrical damage.

1. **LED Strip Power:** Connect the Power Supply Positive (+) directly to the `+12V` (or `+24V`) terminal of the RGBW LED strip.
2. **Buck Converter Input:** Connect Power Supply Positive (+) to Buck `IN+`, and Power Supply Negative (-) to Buck `IN-`.
3. **Step Down Adjustment:** Before connecting the ESP32-C3, measure the buck converter output with a multimeter and adjust the trimmer potentiometer until `OUT+` reads exactly **5.0V DC**.
4. **ESP32-C3 Power:** Connect Buck `OUT+` to the ESP32-C3 **5V / VBUS / VIN** pin, and Buck `OUT-` to the ESP32-C3 **GND** pin.

---

### 3.2 MOSFET Drive Circuit (Per Channel: R, G, B, W)

Each color channel uses a low-side N-channel MOSFET switch:

```
                  +12V / +24V Main Power
                            │
                            ▼
                    ┌───────────────┐
                    │ RGBW Strip +  │
                    │               │
                    │ Color Pin (R-)│
                    └───────┬───────┘
                            │ Drain (D / Pin 2)
                        ┌───┴───┐
      ESP32-C3          │       │ Logic-Level N-MOSFET
      GPIO Pin ───[220Ω]┤ Gate  │ (IRLZ44N / AO3400)
    (GPIO 1/3/4/5)      │ (G)   │
                        └───┬───┘
                            │ Source (S / Pin 3)
                            ├─── Common Ground (GND)
                            │
                       [10kΩ Pull-down]
                            │
                           GND
```

* **Gate Resistor (220Ω; 100Ω for large MOSFETs, see §4.6):** Placed in series between the ESP32-C3 GPIO pin and the MOSFET Gate. Protects the GPIO output driver from high inrush charging current caused by Gate capacitance.
* **Pull-down Resistor (10kΩ):** Connected between MOSFET Gate and Ground. Guarantees the channel remains 100% OFF while the ESP32-C3 boots or is in deep sleep.
* **Drain:** Connected directly to the cathode pad of the strip channel (`R-`, `G-`, `B-`, or `W-`).
* **Source:** Connected directly to the system Common Ground.

---

### 3.3 Status LED (not used)

The current firmware does not drive a status LED; all feedback comes from the buzzer. GPIO 7 and 8 are never configured and stay at their reset state (inputs).

* **New builds:** leave GPIO 7 and 8 unconnected; no LED or resistors are needed.
* **Existing builds** with the old dual-colour LED (anode on 3.3 V, cathodes to GPIO 7 / 8) can leave it in place: it simply stays dark. GPIO 8 is a boot strapping pin; the LED's connection to 3.3 V keeps it high, which is harmless.

---

### 3.4 Piezo Buzzer Connection

```
      ESP32-C3 GPIO 6 ────[100Ω Resistor]────(+) Buzzer Leg
                                                 (-) Buzzer Leg ──── Common Ground (GND)
```

* **GPIO 6:** Connected to Buzzer positive leg (via optional 100Ω resistor for current limit).
* **Ground:** Connected to common GND.
* Non-blocking melodic feedback: boot chime, mode change, preset save / load / delete, timer set / cancel, sleep / wake, errors. It can be muted from the app (the setting is remembered).

### 3.5 Board and flash requirement

The firmware needs an ESP32-C3 with **at least 4 MB of flash**: the partition table has two 1,310,720-byte app slots (`app0`, `app1`), one running and one receiving a wireless update. Build with the default partition scheme, shown in the Arduino IDE as **Tools → Partition Scheme → "Default 4MB with spiffs (1.2MB APP/1.5MB SPIFFS)"** (the sketches' `sketch.yaml` sets no scheme, so this default applies). `firmware/tools/flash.sh` refuses a board with less than 4 MB. Full IDE settings: [firmware.md](firmware.md).

### 3.6 PWM, MOSFET heat and noise

- **PWM frequency:** 25 kHz with an 11-bit counter plus 4 bits of hardware dithering (15 effective bits; `firmware/core/ElectroBrightCore/src/config/Config.h`). 25 kHz is above hearing. Firmware before 3.6.1 used 4.9 kHz, which made the buck converters whine under the pulsed load.
- **Gate resistor:** the gate now switches about five times as often, so large MOSFETs with a high gate charge (such as **IRLZ44N**) behind 220 Ω spend longer in their linear region and run warmer. If they get warm, use a **100 Ω** gate resistor or a low-gate-charge MOSFET such as **AO3400** or **IRLB8721**.
- **Residual noise:** if a supply still makes a faint noise, fit an optional **470–1000 µF low-ESR capacitor** across the LED supply (+V to GND, close to the MOSFETs), rated above the strip voltage.
- **Full brightness** (3.6.2+) holds the pin high instead of switching, so a channel at 100 % makes no switching noise or switching loss at all.

---

## 4. Critical Electrical & Engineering Precautions

> [!CAUTION]
> **3.3V Logic Level Requirement:** The ESP32-C3 digital pins operate at **3.3V**, not 5V.
> * Use **True Logic-Level MOSFETs** with Gate-Source Threshold $V_{GS(th)} \le 2.0\text{V}$ (such as **IRLZ44N**, **IRLB8721**, or **AO3400**).
> * Avoid standard MOSFETs like **IRF540N** or **IRFZ44N**; these require 10V at the gate to fully turn on. At 3.3V, they operate in the linear resistance region, overheat rapidly, and may burn out under load.

> [!IMPORTANT]
> **Current & Wire Gauge:** 
> * A 5-meter RGBW strip running at 100% white can draw between **4A to 12A+**.
> * Use appropriately sized stranded wire (minimum **18 AWG** to **16 AWG** for main power and ground leads).
> * High-current traces should not pass through a solderless breadboard. Solder power leads directly to heavy-duty strip terminals or use a dedicated terminal block distribution board.

---

## 5. Pre-Power On Checklist

Before plugging in your main power supply, verify each connection:

- [ ] **External Bluetooth Disconnected:** Old HC-05/JDY module removed; pins D0/D1 wires eliminated.
- [ ] **Buck Converter Calibrated:** Tested with a multimeter; output verified at **5.0V** before connecting to ESP32-C3.
- [ ] **Common Ground Unified:** PSU (-), Buck OUT (-), ESP32 GND, and MOSFET Sources all connected together.
- [ ] **MOSFET Gates Protected:** 220Ω series resistors installed on GPIO 1, 3, 4, 5 with 10kΩ pull-downs to GND.
- [ ] **LED Strip Polarity:** Strip `+12V/+24V` connected to PSU (+); `R, G, B, W` connected to MOSFET Drains.
- [ ] **Buzzer Wiring:** Connected between GPIO 6 and GND.

---

## 6. RGB fixture (3 channels)

The RGB fixture is this board without the white channel. Flash `firmware/fixtures/ElectroBright_RGB` instead of the RGBW sketch, or set the type of an existing light to RGB from the app.

| Function | ESP32-C3 pin | Change from RGBW |
| :--- | :--- | :--- |
| Red / Green / Blue | GPIO 1 / 3 / 4 | unchanged |
| White | GPIO 5 | **not fitted:** no MOSFET, gate resistor or pull-down needed. The firmware drives GPIO 5 low anyway |
| Buzzer | GPIO 6 | unchanged |

- **BOM changes:** 3 MOSFETs, 3 gate resistors (220 Ω, or 100 Ω per §3.6) and 3 pull-downs (10 kΩ). The strip is a common-anode **RGB** strip (`+V`, `R-`, `G-`, `B-`).
- **Current:** an RGB strip at full white draws all three channels at once. Size the supply and wiring for the strip's rated RGB-white current.
- **Checklist deltas** (vs §5):
  - MOSFET gates protected on GPIO 1, 3, 4. Nothing is connected to GPIO 5.
  - Strip `R, G, B` go to the MOSFET drains.
- **Reusing an RGBW board:** set the light's type to RGB (in the app: Settings → Advanced → Developer tools) and connect an RGB strip. Leave the W output unconnected; the firmware holds its gate low. Changing the type clears the light's presets.

---

## 7. RGBCCT fixture (5 channels)

The RGBCCT fixture drives an RGB+CCT ("RGBWW", 6-pin) common-anode strip: three colour channels plus cool white and warm white. It is the RGBW board plus one channel. Flash `firmware/fixtures/ElectroBright_RGBCCT`.

| Function | ESP32-C3 pin | Change from RGBW |
| :--- | :--- | :--- |
| Red / Green / Blue | GPIO 1 / 3 / 4 | unchanged |
| Cool white | GPIO 5 | the RGBW "White" channel, now wired to the strip's `CW-` |
| **Warm white** | **GPIO 10** | **new:** 5th MOSFET, 220 Ω gate resistor (100 Ω for large MOSFETs, §3.6), 10 kΩ pull-down, drain to the strip's `WW-` |
| Buzzer | GPIO 6 | unchanged |

- **BOM changes:**
  - 5 logic-level MOSFETs, 5 gate resistors and 5 pull-downs;
  - an RGB+CCT strip (`+V`, `R-`, `G-`, `B-`, `CW-`, `WW-`).
- **GPIO 10:** not a strapping pin and not used for USB or UART. Most ESP32-C3 boards (SuperMini, DevKitM-1) break it out. On a board without it, pick another free non-strapping GPIO (not 2, 8 or 9) and change `board::kPinWarm` in `firmware/core/ElectroBrightCore/src/fixture/Profiles.h` (this changes it for every type, since all types share one pin layout).
- **Current:** both white channels can run at full together (the power-up default). Size the supply and wiring for the strip's combined CW + WW current, plus RGB if colours are mixed in.
- **Checklist deltas** (vs §5):
  - MOSFET gates protected on GPIO 1, 3, 4, 5 and 10.
  - Strip `R, G, B, CW, WW` go to the matching MOSFET drains.
- **Storage:** every type keeps its settings and presets in the same flash area; changing the type clears the presets, so types never mix them.

---

## 8. CCT fixture (2 channels)

The CCT fixture drives a tunable-white (CCT, 3-pin) common-anode strip: cool white and warm white only. It uses the two white positions of the RGBCCT board, so a 5-channel PCB becomes a CCT light by fitting only those two MOSFETs. Flash `firmware/fixtures/ElectroBright_CCT`.

| Function | ESP32-C3 pin | Notes |
| :--- | :--- | :--- |
| Cool white | GPIO 5 | MOSFET, 220 Ω gate resistor (100 Ω for large MOSFETs, §3.6), 10 kΩ pull-down, drain to the strip's `CW-` |
| Warm white | GPIO 10 | same, drain to the strip's `WW-` |
| Buzzer | GPIO 6 | unchanged |
| *(R / G / B positions)* | GPIO 1 / 3 / 4 | **not fitted.** The firmware drives them low anyway |

- **BOM:**
  - 2 logic-level MOSFETs, 2 gate resistors, 2 pull-downs;
  - a CCT strip (`+V`, `CW-`, `WW-`).
- **Current:** the power-up default is both whites at full. Size the supply for the strip's combined CW + WW current.
- **Checklist deltas** (vs §5):
  - MOSFET gates protected on GPIO 5 and 10. Nothing is connected to GPIO 1, 3, 4.
  - Strip `CW, WW` go to the MOSFET drains.
- **GPIO 10 missing on your board:** change `board::kPinWarm` in `fixture/Profiles.h`, as for RGBCCT (§7).

---

## 9. Single-white fixture (1 channel)

The single-white fixture drives a single-colour white strip (2-pin, common anode). It uses the W position of the RGBW board, which is the cool-white position on RGBCCT/CCT boards, so any ElectroBright PCB becomes a single-white light by fitting one MOSFET. Flash `firmware/fixtures/ElectroBright_W`.

| Function | ESP32-C3 pin | Notes |
| :--- | :--- | :--- |
| White | GPIO 5 | MOSFET, 220 Ω gate resistor (100 Ω for large MOSFETs, §3.6), 10 kΩ pull-down, drain to the strip's `−` |
| Buzzer | GPIO 6 | unchanged |
| *(other LED positions)* | GPIO 1 / 3 / 4 / 10 | **not fitted.** The firmware drives them low anyway |

- **BOM:**
  - 1 logic-level MOSFET, 1 gate resistor, 1 pull-down;
  - a single-colour strip (`+V`, `−`).
- **Checklist deltas** (vs §5):
  - The MOSFET gate is protected on GPIO 5. Nothing is connected to GPIO 1, 3, 4, 10.
  - The strip's `−` goes to the MOSFET drain.
- **Modes:** this light has 12 of the 13 modes. Rainbow is left out because it only changes colour.

---

## Appendix A. Arduino Nano to ESP32-C3 migration

If you are upgrading an existing build from an **Arduino Nano** (ATmega328P) to the **ESP32-C3**, use this quick wire-transfer table:

| Function | Old Arduino Nano Pin | New ESP32-C3 Pin | Signal / Logic Level | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **Red Channel** | **D3** (PWM) | **GPIO 1** | 3.3V PWM (25 kHz, 11-bit + dithering) | Connects to Red MOSFET Gate via 220Ω (Avoids strapping conflict on GPIO 2) |
| **Green Channel** | **D5** (PWM) | **GPIO 3** | 3.3V PWM (25 kHz, 11-bit + dithering) | Connects to Green MOSFET Gate via 220Ω |
| **Blue Channel** | **D6** (PWM) | **GPIO 4** | 3.3V PWM (25 kHz, 11-bit + dithering) | Connects to Blue MOSFET Gate via 220Ω |
| **White Channel** | **D9** (PWM) | **GPIO 5** | 3.3V PWM (25 kHz, 11-bit + dithering) | Connects to White MOSFET Gate via 220Ω |
| **Audio Buzzer** | **D10** | **GPIO 6** | 3.3V Pulse | Positive (+) leg of piezo buzzer |
| **Status LED** | *None* (Old D13) | **GPIO 7 / 8 — not used** | — | The current firmware has no status LED (see §3.3). |
| **Power Input** | **5V / VIN** | **5V / VBUS** | 5V DC (regulated) | From DC-DC Buck Converter or USB |
| **Ground** | **GND** | **GND** | 0V Common | Must connect to all circuit grounds |

> [!TIP]
> **Components to REMOVE (Hardware Simplification):**
> Disconnect and completely discard the external Bluetooth module (**HC-05**, **HC-06**, **JDY-31**, or **HM-10**) and its wires from **D0 (RX)** and **D1 (TX)**. The ESP32-C3 features **native, built-in BLE 5.0**, eliminating the need for external serial wireless modules or voltage divider circuits.
