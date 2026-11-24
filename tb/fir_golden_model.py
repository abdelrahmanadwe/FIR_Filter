#!/usr/bin/env python3
"""
FIR Filter Golden Model and Stimulus Generator
Fully parameterized for arbitrary DATA_WIDTH and COEFF_WIDTH.
Generates:
1. Low-Pass Filter coefficients (Q-format signed fixed-point)
2. Noisy input signal passed through a parameterized physical ADC model
3. Bit-accurate expected hardware output (matching RTL rounding & saturation)
"""

import math
import os

# -----------------------------------------------------------------------------
# Hardware Parameters (Change here to re-parameterize the system)
# -----------------------------------------------------------------------------
NUM_TAPS    = 16
DATA_WIDTH  = 16
COEFF_WIDTH = 16
SCALE_SHIFT = COEFF_WIDTH - 1  # Standard Q-format unity scaling (e.g. 15 for 16-bit Q15)

# Derived Integer Limits for Data Path
MAX_DATA        = (1 << (DATA_WIDTH - 1)) - 1
MIN_DATA        = -(1 << (DATA_WIDTH - 1))
DATA_HEX_FORMAT = f"0{((DATA_WIDTH + 3) // 4)}X"
DATA_MASK       = (1 << DATA_WIDTH) - 1

# Derived Integer Limits for Coefficients
MAX_COEFF        = (1 << (COEFF_WIDTH - 1)) - 1
MIN_COEFF        = -(1 << (COEFF_WIDTH - 1))
COEFF_HEX_FORMAT = f"0{((COEFF_WIDTH + 3) // 4)}X"
COEFF_MASK       = (1 << COEFF_WIDTH) - 1


def design_fir_lowpass(num_taps, cutoff=0.18):
    """Design a windowed-sinc lowpass filter (Hamming window)."""
    h = []
    mid = (num_taps - 1) / 2.0
    for i in range(num_taps):
        n = i - mid
        if n == 0:
            sinc_val = 2.0 * cutoff
        else:
            sinc_val = math.sin(2.0 * math.pi * cutoff * n) / (math.pi * n)
        # Hamming window
        w = 0.54 - 0.46 * math.cos(2.0 * math.pi * i / (num_taps - 1))
        h.append(sinc_val * w)

    # Normalize for unity DC gain (sum(h) = 1.0)
    total_gain = sum(h)
    h_norm = [val / total_gain for val in h]
    return h_norm


def quantize_coeffs(float_coeffs, coeff_width=COEFF_WIDTH):
    """Quantize floating point coefficients to signed fixed-point integers."""
    scale_factor = (1 << (coeff_width - 1)) - 1
    max_c = (1 << (coeff_width - 1)) - 1
    min_c = -(1 << (coeff_width - 1))

    q_coeffs = []
    for c in float_coeffs:
        val = int(round(c * scale_factor))
        val = max(min(val, max_c), min_c)
        q_coeffs.append(val)
    return q_coeffs


def adc_quantize(analog_voltage, v_ref=1.0, data_width=DATA_WIDTH):
    """
    Physical Bipolar ADC Model parameterized by data_width:
    - Quantization levels: 2^data_width levels
    - LSB step size = (2 * V_ref) / 2^data_width
    - Maps analog voltage [-Vref, +Vref] to signed Two's Complement code
    """
    num_levels = 1 << data_width
    lsb = (2.0 * v_ref) / float(num_levels)
    raw_code = int(round(analog_voltage / lsb))
    max_d = (1 << (data_width - 1)) - 1
    min_d = -(1 << (data_width - 1))
    return max(min(raw_code, max_d), min_d)


def generate_signals(num_samples=128, data_width=DATA_WIDTH):
    """Generate analog voltage signals and pass through the ADC."""
    samples = []
    for n in range(num_samples):
        # Desired analog signal: Low frequency sine (5 kHz at 100 kHz sample rate -> norm freq 0.05)
        clean = 0.60 * math.sin(2.0 * math.pi * 0.05 * n)
        # Unwanted analog noise: High frequency tone (35 kHz -> norm freq 0.35)
        noise = 0.30 * math.sin(2.0 * math.pi * 0.35 * n)
        total_voltage = clean + noise

        # Quantize and encode via parameterized ADC model
        digital_sample = adc_quantize(total_voltage, v_ref=1.0, data_width=data_width)
        samples.append(digital_sample)
    return samples


def fir_hardware_model(samples, coeffs, scale_shift=SCALE_SHIFT, data_width=DATA_WIDTH):
    """
    Bit-accurate simulation of the SystemVerilog hardware:
    y[n] = round_sat( (sum_{k=0}^{TAPS-1} x[n-k] * h[k]) >> scale_shift )
    """
    taps = len(coeffs)
    shift_reg = [0] * taps
    outputs = []

    round_addend = (1 << (scale_shift - 1)) if scale_shift > 0 else 0
    max_d = (1 << (data_width - 1)) - 1
    min_d = -(1 << (data_width - 1))

    for x in samples:
        # Shift in new sample
        shift_reg = [x] + shift_reg[:-1]

        # Multiply & Accumulate with full precision
        acc = sum(shift_reg[k] * coeffs[k] for k in range(taps))

        # Rounding
        rounded = acc + round_addend
        scaled = rounded >> scale_shift

        # Saturation to signed data_width limits
        if scaled > max_d:
            y = max_d
        elif scaled < min_d:
            y = min_d
        else:
            y = scaled

        outputs.append(y)
    return outputs


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # 1. Generate Lowpass Coefficients
    float_coeffs = design_fir_lowpass(NUM_TAPS, cutoff=0.18)
    q_coeffs = quantize_coeffs(float_coeffs, COEFF_WIDTH)

    # 2. Generate Stimulus & Golden Output
    input_samples = generate_signals(128, DATA_WIDTH)
    golden_output = fir_hardware_model(input_samples, q_coeffs, SCALE_SHIFT, DATA_WIDTH)

    # Write to files for SystemVerilog $readmemh simulation
    with open(os.path.join(script_dir, "coeffs.txt"), "w") as f:
        for c in q_coeffs:
            hex_val = format(c & COEFF_MASK, COEFF_HEX_FORMAT)
            f.write(f"{hex_val}\n")

    with open(os.path.join(script_dir, "input_samples.txt"), "w") as f:
        for s in input_samples:
            hex_val = format(s & DATA_MASK, DATA_HEX_FORMAT)
            f.write(f"{hex_val}\n")

    with open(os.path.join(script_dir, "golden_output.txt"), "w") as f:
        for g in golden_output:
            hex_val = format(g & DATA_MASK, DATA_HEX_FORMAT)
            f.write(f"{hex_val}\n")

    print(f"[Golden Model] Generated {len(q_coeffs)} coefficients (DATA_WIDTH={DATA_WIDTH}, COEFF_WIDTH={COEFF_WIDTH}):")
    for i, (fc, qc) in enumerate(zip(float_coeffs, q_coeffs)):
        hex_val = format(qc & COEFF_MASK, COEFF_HEX_FORMAT)
        print(f"  Tap {i:2d}: float = {fc:8.5f} -> int = {qc:6d} (0x{hex_val})")
    print(f"[Golden Model] Generated {len(input_samples)} stimulus samples and expected outputs.")


if __name__ == "__main__":
    main()
