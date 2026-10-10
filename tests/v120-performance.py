#!/usr/bin/env python3
"""Run the unchanged v1.1 matrix as regression against a v1.1 implementation.

The earlier version's four improvement promises are checked separately against
its original pre-optimization baseline. This runner does not require a second
30-percent improvement over the already optimized v1.1 implementation.
"""
import importlib.util
from pathlib import Path
spec=importlib.util.spec_from_file_location("measure",Path(__file__).with_name("v11-measure.py"))
measure=importlib.util.module_from_spec(spec);spec.loader.exec_module(measure)
if __name__=="__main__":raise SystemExit(measure.main(regression=True))
