"""Launch the installed-app smoke under a kill-on-exit job, with bounded waits."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

# Retain this handle until process exit: Windows then terminates only this test's
# job and descendants, including a driver/browser that failed before session setup.
class BasicLimits(c.Structure):
    _fields_ = [('process_time', c.c_int64), ('job_time', c.c_int64), ('flags', w.DWORD),
                ('min_working', c.c_size_t), ('max_working', c.c_size_t), ('active', w.DWORD),
                ('affinity', c.c_size_t), ('priority', w.DWORD), ('scheduling', w.DWORD)]
class Limits(c.Structure):
    _fields_ = [('basic', BasicLimits), ('io', c.c_uint64 * 6), ('process_memory', c.c_size_t),
                ('job_memory', c.c_size_t), ('peak_process', c.c_size_t), ('peak_job', c.c_size_t)]
kernel = c.WinDLL('kernel32', use_last_error=True)
kernel.CreateJobObjectW.argtypes = [w.LPVOID, w.LPCWSTR]
kernel.CreateJobObjectW.restype = w.HANDLE
kernel.GetCurrentProcess.restype = w.HANDLE
kernel.SetInformationJobObject.argtypes = [w.HANDLE, c.c_int, w.LPVOID, w.DWORD]
kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
job = kernel.CreateJobObjectW(None, None)
limits = Limits(); limits.basic.flags = 0x2000
if not job or not kernel.SetInformationJobObject(job, 9, c.byref(limits), c.sizeof(limits)) or not kernel.AssignProcessToJobObject(job, kernel.GetCurrentProcess()):
    raise c.WinError(c.get_last_error())

parser = argparse.ArgumentParser()
parser.add_argument('--application', required=True)
parser.add_argument('--companion', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
output = pathlib.Path(args.output).resolve(); output.mkdir(parents=True, exist_ok=True)
os.environ['AKITTY_DESKTOP_BINARY'] = str(pathlib.Path(args.application).resolve())
os.environ['AKITTY_AGENT_BINARY'] = str(pathlib.Path(args.companion).resolve())
os.environ['AKITTY_SMOKE_OUTPUT_DIR'] = str(output)
with (output / 'driver.log').open('w') as stdout, (output / 'driver-error.log').open('w') as stderr:
    driver = subprocess.Popen(['tauri-driver'], stdout=stdout, stderr=stderr)
    for attempt in range(30):
        if driver.poll() is not None:
            raise RuntimeError('tauri-driver exited before accepting a session')
        try:
            urllib.request.urlopen('http://127.0.0.1:4444/status', timeout=2).close()
            break
        except OSError:
            time.sleep(1)
    else:
        raise TimeoutError('tauri-driver did not become ready')
    script = pathlib.Path(__file__).resolve().parents[2] / 'linux/tests/desktop_smoke.py'
    result = subprocess.run([sys.executable, str(script)], timeout=100)
    sys.exit(result.returncode)
