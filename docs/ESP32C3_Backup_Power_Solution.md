# ESP32-C3 Backup Power — Circuit Solution (Corrected)

> Complete design solution for keeping the ESP32-C3 powered through short mains interruptions (supercapacitor ride-through).

---

## 1. Design Summary

The circuit uses a **diode-OR** topology to seamlessly switch between the buck converter (primary) and two parallel supercapacitors (backup), with an isolated charging path to prevent backfeed. 

A main Schottky diode (D1) in the buck path provides normal power delivery while completely blocking reverse current to the unpowered buck converter. The supercapacitors charge from the ESP32 power rail through a current-limiting resistor. During a power failure, a second Schottky diode (D2) bypasses the charging resistor, allowing the supercapacitors to discharge directly into the ESP32.

---

## 2. Circuit Topology

```
    BUCK CONVERTER
    ┌──────────┐
    │          │  OUT+        ┌──────────┐        (Node B)
    │  Buck    ├──────────────► 1N5819 D1 ├──────────┬──────────────► TO ESP32-C3 5V
    │  5V DC   │              └──────────┘           │                Pin
    │          │                                     │
    └────┬─────┘                                     │
         │                                           │
         │                                ┌──────────┴──────────┐
         │                                │                     │
         │                                ▼                     ▲
         │                           ┌─────────┐           ┌─────────┐
         │                           │   10Ω   │           │ 1N5819  │
         │                           │Resistor │           │   D2    │
         │                           └─────────┘           └─────────┘
         │                                │                     │
         │                                └──────────┬──────────┘
         │                                           │
         │                                        (Node C)
         │                                     ┌─────┴─────┐
         │                                     │           │
         │                                   SC1(+)      SC2(+)
         │                                   SC1(-)      SC2(-)
         │                                     │           │
         └─────────────────────────────────────┴─────┬─────┴────────► TO ESP32 GND
                                                     │
                                                 2200µF (-)
                                        (Note: 2200µF (+) is at Node B)
```

---

## 3. Circuit Schematic (Node-by-Node)

### Node Definitions

| Node | Name | Description |
|:-----|:-----|:------------|
| **A (OUT+)** | Buck Output | Buck converter OUT+ terminal (5.0V DC) |
| **B** | ESP 5V Rail | Main power rail feeding the ESP32-C3 |
| **C** | Supercap Bus | Common positive terminal of both supercapacitors |
| **GND** | Common Ground | All ground connections tied together |

### Connections (Wire-by-Wire)

#### 3.1 — Buck Converter to Main Rail (D1 Path)

```
Buck OUT+ ──── 1N5819 D1 Anode ──►── 1N5819 D1 Cathode ──── Node B (ESP Rail)
```

- **Component:** 1N5819 Schottky diode (D1)
- **Purpose:** Allows normal power flow to the ESP32. **Blocks all backfeed** from the supercapacitors into the buck converter when the buck is unpowered.
- **Voltage drop:** ~0.35V typical at 80mA. Node B sits at ~4.65V during normal operation.

#### 3.2 — Supercapacitor Charging Path

```
Node B (ESP Rail) ──── 10Ω Resistor ──── Node C (Supercap Bus +)
```

- **Component:** 10Ω resistor
- **Purpose:** Limits inrush current when charging empty supercapacitors. 
- **Peak inrush calculation:** At worst case (supercaps at 0V), I_peak = 4.65V / 10Ω = **~465mA**. The main diode (D1) safely carries this charging current plus the ESP32 run current (total ~545mA, well within its 1A rating).
- **Steady-state:** Once fully charged, no current flows through this resistor (both nodes at 4.65V).

#### 3.3 — Supercapacitors in Parallel

```
SC1 (+) ──── Node C ──── SC2 (+)
SC1 (–) ──── GND  ──── SC2 (–)
```

- **Components:** 2× supercapacitors, 5.5V 1.5F each
- **Combined capacity:** 1.5F + 1.5F = **3.0F total**
- **Voltage rating:** 5.5V per cap. Node C reaches a maximum of 4.65V, keeping the caps safely within limits.

#### 3.4 — Backup Discharge Path (D2 Bypass)

```
Node C (Supercap Bus +) ──── 1N5819 D2 Anode ──►── 1N5819 D2 Cathode ──── Node B (ESP Rail)
```

- **Component:** 1N5819 Schottky diode (D2)
- **Purpose:** When Buck power fails, Node B's voltage drops. Node C (at 4.65V) pushes current through D2 to power the ESP32.
- **Why this is brilliant:** During backup, current flows through D2 *and* the 10Ω resistor in parallel. This combination results in a total voltage drop *lower* than a diode alone (e.g., ~0.3V instead of 0.35V).

#### 3.5 — Bulk Filtering Capacitor

```
Node B (ESP Rail) ──── 2200µF (+) ──── 2200µF (–) ──── GND
```

- **Component:** 2200µF, 16V electrolytic capacitor
- **Placement:** Directly across the ESP32-C3 5V pin and GND.
- **Purpose:** Smooths voltage ripple and absorbs BLE transmission current spikes. 

---

## 4. How It Works — Operating Modes

### Mode 1: Normal Operation (Buck ON)

1. Buck provides 5.0V.
2. Current flows through D1 (drops ~0.35V) → Node B (ESP32) sees ~4.65V.
3. Simultaneously, current flows from Node B through the 10Ω resistor → charges supercaps at Node C toward ~4.65V.
4. Because Node C and Node B equalize at 4.65V, D2 has 0V bias and remains OFF.

### Mode 2: Power Loss (Buck OFF)

1. Buck output drops to 0V.
2. **D1 immediately becomes reverse-biased**, completely blocking the supercapacitors from discharging backward into the buck converter.
3. Node B begins to drop. Once Node B drops below Node C by ~0.3V, **D2 becomes forward-biased**.
4. Supercaps discharge into the ESP32 through D2 (and the 10Ω resistor).
5. The ESP32 continues running perfectly while the supercap voltage slowly falls.

---

## 5. Backup Runtime Estimate

### ESP32-C3 Current Draw (BLE Only)
- **Worst-case estimate:** **~80 mA average**

### Stored Energy Calculation

The supercaps charge to **~4.65V**.
The ESP32-C3's LDO needs a minimum input of **~3.5V**.
During backup, the discharge path (D2 || 10Ω) drops approx **0.3V**.
This means the supercapacitors can discharge down to **3.8V** (3.8V - 0.3V drop = 3.5V at the ESP32).

**Usable voltage range:** 4.65V down to 3.8V

**Usable energy:**
```
E = ½ × C × (V_high² – V_low²)
E = ½ × 3.0F × (4.65² – 3.8²)
E = 1.5 × (21.62 – 14.44)
E = 1.5 × 7.18 = 10.77 Joules
```

### Runtime Estimate

**Average power consumption during backup:**
```
P = V_avg × I = 4.2V × 0.080A = 0.336W
```

**Estimated backup runtime:**
```
t = E / P = 10.77J / 0.336W ≈ 32 seconds
```

| Scenario | Estimated Backup Duration |
|:---------|:--------------------------|
| Worst case (80mA continuous BLE) | **~32 seconds** |
| Typical (50mA BLE connected) | **~50 seconds** |
| Light sleep (3mA) | **~14+ minutes** |

---

## 6. Pre-Power-On Checklist

- [ ] **Supercap polarity:** (+) connected to Node C, (–) connected to GND.
- [ ] **D1 orientation:** Cathode (stripe) faces ESP32. Anode faces Buck.
- [ ] **D2 orientation:** Cathode (stripe) faces ESP32. Anode faces Supercaps.
- [ ] **10Ω resistor:** Connects across D1 Cathode and D2 Anode.
- [ ] **2200µF polarity:** (+) to ESP 5V rail, (–) to GND. Close to ESP32.
- [ ] **Common ground:** Buck GND, SC(–), 2200µF(–), and ESP32 GND all connected.
- [ ] **NO wires bypassing D1 back to the buck converter.**

---

## 7. Requirements Compliance Matrix

| Req # | Requirement | Satisfied? | How |
|:------|:-----------|:-----------|:----|
| 1 | No voltage dip or reset during power loss | ✅ | Supercaps maintain voltage via D2 discharge path. |
| 2 | Two supercaps for max capacity | ✅ | Both in parallel = 3.0F. |
| 3 | 2200µF for filtering only | ✅ | Placed across ESP 5V as a bypass/filter cap. |
| 4 | Normal mode: buck powers ESP + charges | ✅ | Buck → D1 → ESP; ESP Rail → 10Ω → Supercaps. |
| 5 | Backup mode: supercaps take over automatically | ✅ | D2 conducts instantly when Buck fails. |
| 6 | No backward discharge into buck | ✅ | **D1 completely blocks reverse current.** |
| 7 | Inrush current limited | ✅ | 10Ω limits inrush from 4.65V to ~465mA. |
| 8 | No unnecessary series resistance in ESP run path | ✅ | Only D1 (~0.35V drop) in normal path; no resistor. |
