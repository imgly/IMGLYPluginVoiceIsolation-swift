"""Writes the DeepFilterNet3 output of the upstream DeepFilterNet Python package for an input file.

Usage: python make_reference.py [--leading-silence SECONDS] <input> <output>
With --leading-silence, the package cleans that much digital silence followed by the input, and the output holds only
the part after the silence. Needs deepfilternet==0.5.6, which downloads the DeepFilterNet3 checkpoint on its first run."""

import argparse
import sys

import numpy
import soundfile
import torch
from df.enhance import enhance, init_df

parser = argparse.ArgumentParser()
parser.add_argument("--leading-silence", type=int, default=0)
parser.add_argument("input")
parser.add_argument("output")
arguments = parser.parse_args()

model, df_state, _ = init_df(model_base_dir="DeepFilterNet3")
samples, sample_rate = soundfile.read(arguments.input, dtype="float32")
if sample_rate != df_state.sr():
    sys.exit(f"{arguments.input}: {sample_rate} Hz, DeepFilterNet3 needs {df_state.sr()} Hz")
silence = arguments.leading_silence * sample_rate
samples = numpy.concatenate([numpy.zeros(silence, numpy.float32), samples])
enhanced = enhance(model, df_state, torch.from_numpy(samples[None, :].copy()))[0].numpy()
soundfile.write(arguments.output, enhanced[silence:], sample_rate, subtype="PCM_16")
