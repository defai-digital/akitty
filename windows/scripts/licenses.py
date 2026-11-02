"""Collect the Windows wrapper's exact resolved dependency licenses."""
import os
import pathlib
import runpy
root = pathlib.Path(__file__).resolve().parents[2]
os.environ["AKITTY_DESKTOP_PACKAGE"] = str(root / "windows")
os.environ["AKITTY_LINUX_TARGET"] = "x86_64-pc-windows-msvc"
runpy.run_path(str(root / "linux/scripts/licenses.py"), run_name="__main__")
