"""Run desktop tests at medium integrity, including on an elevated SSH/CI account.

No account, policy, registry or persistent token settings are changed. WebView2
ignores WebDriver environment overrides in an elevated host. A filtered token
also needs a user-owned default DACL so its child processes can communicate.
"""
import ctypes as c
from ctypes import wintypes as w
import subprocess
import sys

kernel = c.WinDLL('kernel32', use_last_error=True)
security = c.WinDLL('advapi32', use_last_error=True)
class SidAttributes(c.Structure):
    _fields_ = [('sid', w.LPVOID), ('attributes', w.DWORD)]
class Startup(c.Structure):
    _fields_ = [('cb', w.DWORD), ('reserved', w.LPWSTR), ('desktop', w.LPWSTR), ('title', w.LPWSTR),
                ('x', w.DWORD), ('y', w.DWORD), ('width', w.DWORD), ('height', w.DWORD),
                ('xchars', w.DWORD), ('ychars', w.DWORD), ('fill', w.DWORD), ('flags', w.DWORD),
                ('show', w.WORD), ('reserved_size', w.WORD), ('reserved_bytes', w.LPVOID),
                ('stdin', w.HANDLE), ('stdout', w.HANDLE), ('stderr', w.HANDLE)]
class Process(c.Structure):
    _fields_ = [('process', w.HANDLE), ('thread', w.HANDLE), ('pid', w.DWORD), ('tid', w.DWORD)]
def checked(value):
    if not value:
        raise c.WinError(c.get_last_error())

kernel.GetCurrentProcess.restype = w.HANDLE
kernel.CloseHandle.argtypes = [w.HANDLE]
kernel.LocalFree.argtypes = [w.LPVOID]
kernel.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
kernel.GetExitCodeProcess.argtypes = [w.HANDLE, c.POINTER(w.DWORD)]
security.OpenProcessToken.argtypes = [w.HANDLE, w.DWORD, c.POINTER(w.HANDLE)]
security.GetTokenInformation.argtypes = [w.HANDLE, c.c_int, w.LPVOID, w.DWORD, c.POINTER(w.DWORD)]
security.SetTokenInformation.argtypes = [w.HANDLE, c.c_int, w.LPVOID, w.DWORD]
security.ConvertStringSidToSidW.argtypes = [w.LPCWSTR, c.POINTER(w.LPVOID)]
security.ConvertSidToStringSidW.argtypes = [w.LPVOID, c.POINTER(w.LPWSTR)]
security.GetLengthSid.argtypes = [w.LPVOID]
security.GetLengthSid.restype = w.DWORD
security.CreateRestrictedToken.argtypes = [w.HANDLE, w.DWORD, w.DWORD, c.POINTER(SidAttributes), w.DWORD, w.LPVOID, w.DWORD, w.LPVOID, c.POINTER(w.HANDLE)]
security.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [w.LPCWSTR, w.DWORD, c.POINTER(w.LPVOID), w.LPVOID]
security.GetSecurityDescriptorDacl.argtypes = [w.LPVOID, c.POINTER(w.BOOL), c.POINTER(w.LPVOID), c.POINTER(w.BOOL)]
security.CreateProcessAsUserW.argtypes = [w.HANDLE, w.LPCWSTR, w.LPWSTR, w.LPVOID, w.LPVOID, w.BOOL, w.DWORD, w.LPVOID, w.LPCWSTR, c.POINTER(Startup), c.POINTER(Process)]

def run(arguments):
    if not arguments:
        raise ValueError('a test command is required')
    token, filtered = w.HANDLE(), w.HANDLE()
    admin, medium, descriptor = w.LPVOID(), w.LPVOID(), w.LPVOID()
    sid_text = w.LPWSTR()
    process = Process()
    try:
        checked(security.OpenProcessToken(kernel.GetCurrentProcess(), 0xF01FF, c.byref(token)))
        elevation, needed = w.DWORD(), w.DWORD()
        checked(security.GetTokenInformation(token, 20, c.byref(elevation), 4, c.byref(needed)))
        if not elevation.value:
            return subprocess.call(arguments, timeout=180)
        checked(security.ConvertStringSidToSidW('S-1-5-32-544', c.byref(admin)))
        deny_admin = SidAttributes(admin, 0)
        # DISABLE_MAX_PRIVILEGE | LUA_TOKEN, plus an explicit administrator deny-only SID.
        checked(security.CreateRestrictedToken(token, 5, 1, c.byref(deny_admin), 0, None, 0, None, c.byref(filtered)))
        checked(security.ConvertStringSidToSidW('S-1-16-8192', c.byref(medium)))
        label = SidAttributes(medium, 0x20)
        checked(security.SetTokenInformation(filtered, 25, c.byref(label), c.sizeof(label) + security.GetLengthSid(medium)))
        user = c.create_string_buffer(4096)
        checked(security.GetTokenInformation(filtered, 1, user, len(user), c.byref(needed)))
        owner = w.LPVOID(c.cast(user, c.POINTER(SidAttributes)).contents.sid)
        checked(security.SetTokenInformation(filtered, 4, c.byref(owner), c.sizeof(owner)))
        checked(security.ConvertSidToStringSidW(owner, c.byref(sid_text)))
        checked(security.ConvertStringSecurityDescriptorToSecurityDescriptorW('D:(A;;GA;;;' + sid_text.value + ')', 1, c.byref(descriptor), None))
        present, defaulted, acl = w.BOOL(), w.BOOL(), w.LPVOID()
        checked(security.GetSecurityDescriptorDacl(descriptor, c.byref(present), c.byref(acl), c.byref(defaulted)))
        checked(security.SetTokenInformation(filtered, 6, c.byref(acl), c.sizeof(acl)))
        checked(security.GetTokenInformation(filtered, 20, c.byref(elevation), 4, c.byref(needed)))
        if elevation.value:
            raise RuntimeError('test token is still elevated')
        startup = Startup(); startup.cb = c.sizeof(startup)
        command = c.create_unicode_buffer(subprocess.list2cmdline(arguments))
        checked(security.CreateProcessAsUserW(filtered, None, command, None, None, False, 0, None, None, c.byref(startup), c.byref(process)))
        if kernel.WaitForSingleObject(process.process, 180000) != 0:
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], check=False)
            raise TimeoutError('desktop test exceeded 180 seconds')
        code = w.DWORD(); checked(kernel.GetExitCodeProcess(process.process, c.byref(code)))
        return code.value
    finally:
        for handle in (process.thread, process.process, filtered.value, token.value):
            if handle:
                kernel.CloseHandle(handle)
        for pointer in (admin, medium, descriptor, c.cast(sid_text, w.LPVOID)):
            if pointer:
                kernel.LocalFree(pointer)

if __name__ == '__main__':
    sys.exit(run(sys.argv[1:]))
