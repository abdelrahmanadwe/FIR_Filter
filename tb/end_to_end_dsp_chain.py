#!/usr/bin/env python3
"""
End-to-End Real-World DSP Chain Simulation:
1. Continuous-time (Analog) Signal Generation (Clean tone + High-frequency noise)
2. Realistic Parameterized ADC Model (Sampling -> Quantization into 2^N levels -> Two's complement Encoding)
3. Digital FIR Filter IP Model (Fixed-Point RTL Golden Model)
4. Realistic Parameterized DAC Model (Digital Codes -> Discrete Analog Voltage)
5. Analog Reconstruction Filter (Whittaker-Shannon Sinc Interpolation)
6. Comparison & Verification of Reconstructed Signal vs Original Clean Signal
"""

import numpy as np
import matplotlib
matplotlib.use('Agg') # Headless backend
import matplotlib.pyplot as plt
import os

# -----------------------------------------------------------------------------
# Hardware Parameters
# -----------------------------------------------------------------------------
DATA_WIDTH  = 16
COEFF_WIDTH = 16
NUM_TAPS    = 16
SCALE_SHIFT = COEFF_WIDTH - 1

MAX_DATA    = (1 << (DATA_WIDTH - 1)) - 1
MIN_DATA    = -(1 << (DATA_WIDTH - 1))

MAX_COEFF   = (1 << (COEFF_WIDTH - 1)) - 1
MIN_COEFF   = -(1 << (COEFF_WIDTH - 1))

# -----------------------------------------------------------------------------
# System & Signal Specifications
# -----------------------------------------------------------------------------
FS = 100_000.0             # ADC/DAC Sampling Frequency: 100 kHz (Ts = 10 us)
TS = 1.0 / FS

F_CLEAN = 5_000.0          # Desired audio tone: 5 kHz (inside passband)
F_NOISE = 35_000.0         # Noise frequency: 35 kHz (inside stopband)

A_CLEAN = 0.65             # Amplitude: 0.65 V
A_NOISE = 0.30             # Amplitude: 0.30 V

NUM_SAMPLES = 128          # Number of samples to process
DURATION = NUM_SAMPLES * TS

# -----------------------------------------------------------------------------
# 1. Realistic Parameterized ADC Model
# -----------------------------------------------------------------------------
class ParameterizedADC:
    """
    Models a true Bipolar Analog-to-Digital Converter.
    - Full-scale Voltage: -Vref to +Vref
    - Quantization Levels: 2^bits distinct discrete voltage bins
    - Resolution (LSB / Delta): 2 * Vref / 2^bits
    - Output Encoding: Signed Two's Complement
    """
    def __init__(self, v_ref=1.0, bits=DATA_WIDTH):
        self.v_ref = v_ref
        self.bits = bits
        self.num_levels = 1 << bits
        self.max_code = (1 << (bits - 1)) - 1
        self.min_code = -(1 << (bits - 1))
        self.lsb = (2.0 * self.v_ref) / float(self.num_levels)

    def quantize_and_encode(self, analog_voltages):
        raw_codes = np.round(analog_voltages / self.lsb)
        encoded_codes = np.clip(raw_codes, self.min_code, self.max_code).astype(np.int64)
        return encoded_codes

# -----------------------------------------------------------------------------
# 2. Realistic Parameterized DAC Model
# -----------------------------------------------------------------------------
class ParameterizedDAC:
    """
    Models a true Digital-to-Analog Converter (Zero-Order Hold).
    - Takes signed digital codes
    - Converts each code back to analog voltage: V = code * LSB
    """
    def __init__(self, v_ref=1.0, bits=DATA_WIDTH):
        self.v_ref = v_ref
        self.bits = bits
        self.num_levels = 1 << bits
        self.lsb = (2.0 * self.v_ref) / float(self.num_levels)

    def decode(self, digital_codes):
        return digital_codes.astype(np.float64) * self.lsb

# -----------------------------------------------------------------------------
# 3. Whittaker-Shannon Sinc Interpolator (Analog Reconstruction Filter)
# -----------------------------------------------------------------------------
def analog_reconstruct(sample_times, dac_voltages, t_fine, fs):
    """
    Implements ideal continuous-time analog reconstruction:
    x_analog(t) = sum_n (x[n] * sinc((t - n*Ts) / Ts))
    """
    t_matrix = (t_fine[:, None] - sample_times[None, :]) * fs
    sinc_matrix = np.sinc(t_matrix) # In numpy, np.sinc(x) is sin(pi*x)/(pi*x)
    reconstructed_analog = sinc_matrix @ dac_voltages
    return reconstructed_analog

# -----------------------------------------------------------------------------
# 4. Filter Design & Hardware Fixed-Point Core Simulation
# -----------------------------------------------------------------------------
def design_fir_lowpass(num_taps=NUM_TAPS, cutoff_ratio=0.18, coeff_width=COEFF_WIDTH):
    """Designs Hamming windowed-sinc Low-Pass Filter."""
    mid = (num_taps - 1) / 2.0
    h = []
    for i in range(num_taps):
        n = i - mid
        sinc_val = 2.0 * cutoff_ratio if n == 0 else np.sin(2.0 * np.pi * cutoff_ratio * n) / (np.pi * n)
        w = 0.54 - 0.46 * np.cos(2.0 * np.pi * i / (num_taps - 1))
        h.append(sinc_val * w)
    h_norm = np.array(h) / np.sum(h) # Unity DC Gain
    scale_factor = (1 << (coeff_width - 1)) - 1
    q_coeffs = np.clip(np.round(h_norm * scale_factor), MIN_COEFF, MAX_COEFF).astype(np.int64)
    return q_coeffs

def fir_hardware_filter(input_codes, q_coeffs, scale_shift=SCALE_SHIFT, data_width=DATA_WIDTH):
    """Hardware bit-accurate model identical to SystemVerilog core."""
    taps = len(q_coeffs)
    shift_reg = np.zeros(taps, dtype=np.int64)
    output_codes = []
    round_addend = (1 << (scale_shift - 1)) if scale_shift > 0 else 0
    max_d = (1 << (data_width - 1)) - 1
    min_d = -(1 << (data_width - 1))

    for x in input_codes:
        shift_reg = np.roll(shift_reg, 1)
        shift_reg[0] = x
        acc = np.sum(shift_reg * q_coeffs)
        # Round and arithmetic right shift
        rounded = acc + round_addend
        scaled = rounded >> scale_shift
        # Saturation
        sat = np.clip(scaled, min_d, max_d)
        output_codes.append(sat)
    return np.array(output_codes, dtype=np.int64)

# -----------------------------------------------------------------------------
# Main Simulation Flow
# -----------------------------------------------------------------------------
def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.abspath(os.path.join(script_dir, ".."))

    # High-resolution time axis for "Continuous-Time Analog World"
    t_fine = np.linspace(0, DURATION, NUM_SAMPLES * 100)

    # True continuous analog signals
    analog_clean_ideal = A_CLEAN * np.sin(2.0 * np.pi * F_CLEAN * t_fine)
    analog_noise = A_NOISE * np.sin(2.0 * np.pi * F_NOISE * t_fine)
    analog_input_composite = analog_clean_ideal + analog_noise

    # Discrete sample clock instants
    n_indices = np.arange(NUM_SAMPLES)
    sample_times = n_indices * TS
    analog_samples_at_adc = A_CLEAN * np.sin(2.0 * np.pi * F_CLEAN * sample_times) + \
                            A_NOISE * np.sin(2.0 * np.pi * F_NOISE * sample_times)

    # --- Step 1: Parameterized ADC ---
    adc = ParameterizedADC(v_ref=1.0, bits=DATA_WIDTH)
    digital_input_codes = adc.quantize_and_encode(analog_samples_at_adc)

    # --- Step 2: Digital FIR Filter ---
    q_coeffs = design_fir_lowpass(num_taps=NUM_TAPS, cutoff_ratio=0.18, coeff_width=COEFF_WIDTH)
    digital_output_codes = fir_hardware_filter(digital_input_codes, q_coeffs, scale_shift=SCALE_SHIFT, data_width=DATA_WIDTH)

    # --- Step 3: Parameterized DAC ---
    dac = ParameterizedDAC(v_ref=1.0, bits=DATA_WIDTH)
    analog_dac_voltage = dac.decode(digital_output_codes)

    # --- Step 4: Analog Reconstruction Filter (Interpolation) ---
    reconstructed_analog = analog_reconstruct(sample_times, analog_dac_voltage, t_fine, FS)

    # Delay compensation: The N-tap FIR filter has a linear phase delay of (N-1)/2 samples
    filter_delay_sec = (NUM_TAPS - 1) / (2.0 * FS)
    delayed_clean_ideal = A_CLEAN * np.sin(2.0 * np.pi * F_CLEAN * (t_fine - filter_delay_sec))

    # Evaluate performance after the filter pipeline settles
    settled_mask = t_fine > (NUM_TAPS * TS)
    error = reconstructed_analog[settled_mask] - delayed_clean_ideal[settled_mask]
    signal_power = np.mean(delayed_clean_ideal[settled_mask] ** 2)
    noise_power  = np.mean(error ** 2)
    snr_db = 10.0 * np.log10(signal_power / noise_power)

    print("================================================================================")
    print("           END-TO-END DSP CHAIN SIMULATION (ADC -> FIR -> DAC -> INTERPOLATION) ")
    print("================================================================================")
    print(f"1. Parameters: DATA_WIDTH={DATA_WIDTH}, COEFF_WIDTH={COEFF_WIDTH}, TAPS={NUM_TAPS}")
    print(f"2. ADC Model: {DATA_WIDTH}-Bit Bipolar (-1.0V to +1.0V)")
    print(f"   -> Number of Discrete Quantization Levels: {adc.num_levels:,} levels")
    print(f"   -> Quantization Step Size (LSB):           {adc.lsb * 1e6:.3f} uV")
    print(f"3. Input Signal:")
    print(f"   -> Desired Clean Tone:                     {F_CLEAN/1000:.1f} kHz, Amplitude = {A_CLEAN:.2f} V")
    print(f"   -> Unwanted Stopband Noise:                {F_NOISE/1000:.1f} kHz, Amplitude = {A_NOISE:.2f} V")
    print(f"4. Analog Reconstruction (Interpolation):")
    print(f"   -> FIR Group Delay:                        {filter_delay_sec * 1e6:.1f} us ({(NUM_TAPS - 1)/2.0} clock cycles)")
    print(f"   -> Recovered Signal-to-Noise Ratio (SNR):  {snr_db:.2f} dB (High Fidelity Clean Tone Recovered!)")
    print("================================================================================")

    # Generate Visualization Plot
    plt.figure(figsize=(12, 10))

    # Plot 1: Analog Input with Noise
    plt.subplot(3, 1, 1)
    plt.plot(t_fine * 1e3, analog_input_composite, color='red', alpha=0.6, label='Noisy Analog Input (5 kHz + 35 kHz Noise)')
    plt.plot(t_fine * 1e3, analog_clean_ideal, color='black', linestyle='--', linewidth=1.5, label='Original Clean 5 kHz Signal')
    plt.ylabel('Voltage (V)')
    plt.title('Stage 1: Continuous Analog Input Signal (Before ADC)')
    plt.legend(loc='upper right')
    plt.grid(True, alpha=0.3)
    plt.xlim(0.1, 0.8)

    # Plot 2: ADC Quantized Digital Samples vs Filter Output Samples
    plt.subplot(3, 1, 2)
    plt.stem(sample_times * 1e3, digital_input_codes, linefmt='r:', markerfmt='ro', basefmt=' ', label=f'ADC {DATA_WIDTH}-bit Quantized Input Codes (Noisy)')
    plt.stem(sample_times * 1e3, digital_output_codes, linefmt='b-', markerfmt='bo', basefmt=' ', label='FIR Filter Output Codes (Cleaned)')
    plt.ylabel(f'{DATA_WIDTH}-bit Integer Code')
    plt.title('Stage 2 & 3: Digital Domain Processing (ADC Codes & FIR Filter Output)')
    plt.legend(loc='upper right')
    plt.grid(True, alpha=0.3)
    plt.xlim(0.1, 0.8)

    # Plot 3: DAC & Reconstructed Analog Signal vs Original
    plt.subplot(3, 1, 3)
    plt.plot(t_fine * 1e3, delayed_clean_ideal, color='black', linestyle='--', linewidth=2.0, label='Expected Clean Signal (Delay Compensated)')
    plt.plot(t_fine * 1e3, reconstructed_analog, color='blue', linewidth=1.8, label='DAC + Sinc Interpolated Reconstructed Signal')
    plt.xlabel('Time (ms)')
    plt.ylabel('Voltage (V)')
    plt.title(f'Stage 4 & 5: DAC & Continuous Analog Reconstruction (Recovered SNR = {snr_db:.2f} dB)')
    plt.legend(loc='upper right')
    plt.grid(True, alpha=0.3)
    plt.xlim(0.1, 0.8)

    plt.tight_layout()
    plot_docs = os.path.join(project_root, "docs", "images", "end_to_end_dsp_chain.png")
    os.makedirs(os.path.dirname(plot_docs), exist_ok=True)
    plt.savefig(plot_docs, dpi=150)
    print(f"\n[Plot Saved] Visualization plot exported to: {plot_docs}")

if __name__ == "__main__":
    main()
