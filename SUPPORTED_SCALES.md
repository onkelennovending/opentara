# Supported scales

Status legend:
- ✅ **verified** — confirmed working on real hardware
- ⚠️ **pending calibration** — driver written, awaiting first real‑hardware check
- 🧪 **experimental** — ported blind from openScale, unverified

| Scale | BLE name | Type | Metrics | Status |
|-------|----------|------|---------|--------|
| Xiaomi Mi Body Composition Scale 2 | `MIBFS` | advertisement | weight + impedance → full body composition | ✅ verified |
| Xiaomi Mi Smart Scale (v1) | `MI_SCALE` / `MI SCALE` | advertisement | weight only | 🧪 experimental |
| Bluetooth‑SIG standard scales | varies | connection (GATT) | weight (0x2A9D); body composition + impedance (0x2A9C, best‑effort) | 🧪 experimental |
| Beurer BF700 / BF710 / BF800, Runtastic Libra, Sanitas SBF70, SilverCrest SBF75, Crane | `BF-700`, `Beurer BF700`, `BF700`, `BF-800`, `RT-Libra-*`, `SANITAS SBF70`, `sbf75`, `AICDSCALE1` | connection (GATT, command/ack on 0xFFE1) | weight + impedance (scale's own fat/water/muscle/bone go to the raw log) | 🧪 experimental |

## Wanted (help welcome)

Common scales openScale supports that could be ported once a tester is available:
Yunmai (Mini/SE), Medisana BS444/BS430, Trisa, Excelvan, and other Bluetooth‑SIG
compliant scales.

The Beurer/Sanitas driver (0xFFE0/0xFFE1 command protocol) was ported blind from openScale
and still needs its first confirmation on a real BF700/BF710/BF800 or SBF70/SBF75.

If you own any Bluetooth body scale, please help verify it — see
[CONTRIBUTING.md](CONTRIBUTING.md). Capturing a few raw‑data lines is enough.
