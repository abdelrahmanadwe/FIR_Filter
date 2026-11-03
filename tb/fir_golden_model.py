#!/usr/bin/env python3
"""
FIR Filter Golden Model and Stimulus Generator
Generates:
1. Low-Pass Filter coefficients (16-tap Q15 fixed-point)
2. Noisy input signal (Low frequency carrier + High frequency noise)
3. Bit-accurate expected hardware output (with rounding & saturation)
"""

import math
import os

NUM_TAPS = 16
DATA_WIDTH = 16
COEFF_WIDTH = 16
SCALE_SHIFT = 15  # For Q15 coefficients: sum / 2^15

MAX_POS = (1 << (DATA_WIDTH - 1)) - 1   # +32767
MIN_NEG = -(1 << (DATA_WIDTH - 1))       # -32768

def design_fir_lowpass(num_taps, cutoff=0.2):
    """Design a simple windowed-sinc lowpass filter (Hamming window)."""
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

def quantize_coeffs(float_coeffs, scale_factor=32767):
    """Quantize floating point coefficients to signed integer Q15."""
    q_coeffs = []
    for c in float_coeffs:
        val = int(round(c * scale_factor))
        val = max(min(val, 32767), -32768)
        q_coeffs.append(val)
    return q_coeffs

def generate_signals(num_samples=128):
    """Generate low-frequency tone + high-frequency noise."""
    samples = []
    for n in range(num_samples):
        # Desired signal: Low frequency sine (e.g. 5 kHz at 100 kHz sample rate -> norm freq 0.05)
        clean = 0.6 * math.sin(2.0 * math.pi * 0.04 * n)
        # Noise: High frequency tone (e.g. 35 kHz -> norm freq 0.35)
        noise = 0.35 * math.sin(2.0 * math.pi * 0.38 * n)
        total = clean + noise
        int_sample = int(round(total * 20000))
        int_sample = max(min(int_sample, MAX_POS), MIN_NEG)
        samples.append(int_sample)
    return samples

def fir_hardware_model(samples, coeffs, scale_shift=SCALE_SHIFT):
    """
    Bit-accurate simulation of the SystemVerilog hardware:
    y[n] = round_sat( (sum_{k=0}^{TAPS-1} x[n-k] * h[k]) >> scale_shift )
    """
    taps = len(coeffs)
    shift_reg = [0] * taps
    outputs = []
    
    round_addend = (1 << (scale_shift - 1)) if scale_shift > 0 else 0
    
    for x in samples:
        # Shift in new sample
        shift_reg = [x] + shift_reg[:-1]
        
        # Multiply & Accumulate with full precision
        acc = 0
        for k in range(taps):
            acc += shift_reg[k] * coeffs[k]
        
        # Rounding
        rounded = acc + round_addend
        scaled = rounded >> scale_shift
        
        # Saturation to signed 16-bit
        if scaled > MAX_POS:
            y = MAX_POS
        elif scaled < MIN_NEG:
            y = MIN_NEG
        else:
            y = scaled
        
        outputs.append(y)
    return outputs

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    # 1. Generate Lowpass Coefficients
    float_coeffs = design_fir_lowpass(NUM_TAPS, cutoff=0.18)
    q_coeffs = quantize_coeffs(float_coeffs)
    
    # 2. Generate Stimulus & Golden Output
    input_samples = generate_signals(128)
    golden_output = fir_hardware_model(input_samples, q_coeffs)
    
    # Write to files for simulation
    with open(os.path.join(script_dir, "coeffs.txt"), "w") as f:
        for c in q_coeffs:
            # 16-bit hex
            hex_val = f"{(c & 0xFFFF):04X}"
            f.write(f"{hex_val}\n")
            
    with open(os.path.join(script_dir, "input_samples.txt"), "w") as f:
        for s in input_samples:
            hex_val = f"{(s & 0xFFFF):04X}"
            f.write(f"{hex_val}\n")
            
    with open(os.path.join(script_dir, "golden_output.txt"), "w") as f:
        for g in golden_output:
            hex_val = f"{(g & 0xFFFF):04X}"
            f.write(f"{hex_val}\n")
            
    print(f"[Golden Model] Generated {len(q_coeffs)} coefficients:")
    for i, (fc, qc) in enumerate(zip(float_coeffs, q_coeffs)):
        print(f"  Tap {i:2d}: float = {fc:8.5f} -> int16 = {qc:6d} (0x{(qc & 0xFFFF):04X})")
    print(f"[Golden Model] Generated {len(input_samples)} stimulus samples and expected outputs.")

if __name__ == "__main__":
    main()

