use crate::windows::security::{check, error, owned, wide};
use portable_pty::PtySize;
use std::fs::File;
use std::io::{Read, Write};
use std::os::windows::io::{AsRawHandle, OwnedHandle};
use std::path::Path;
use std::ptr::{null, null_mut};
use std::sync::{Arc, Mutex, atomic::{AtomicBool, AtomicUsize, Ordering}, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::System::Console::*;
use windows_sys::Win32::System::IO::CancelSynchronousIo;
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::Pipes::*;
use windows_sys::Win32::System::Threading::*;

static LIVE: AtomicUsize = AtomicUsize::new(0);
struct Slot;
impl Slot {
    fn new() -> Result<Self, String> {
        LIVE.try_update(Ordering::SeqCst, Ordering::SeqCst, |n| (n < 32).then_some(n+1)).map_err(|_| "too many live or cleaning-up ConPTY sessions")?; Ok(Self)
    }
}
impl Drop for Slot { fn drop(&mut self) { LIVE.fetch_sub(1, Ordering::SeqCst); } }
struct Console(HPCON);
impl Drop for Console {
    fn drop(&mut self) {
        // SAFETY: this wrapper exclusively owns the pseudoconsole. Normal teardown runs off-thread while output drains.
        unsafe { ClosePseudoConsole(self.0); }
    }
}
struct Resources {
    console: Option<Console>, closer: Option<JoinHandle<()>>, process: OwnedHandle, job: OwnedHandle, reader: File,
    sender: mpsc::SyncSender<Vec<u8>>, writer: JoinHandle<()>, _slot: Slot,
}
pub struct Pty {
    resources: Option<Resources>, pending: Arc<AtomicBool>, failure: Arc<Mutex<Option<String>>>, code: Option<u32>,
}
fn pipe() -> Result<(File, File), String> {
    let mut read = null_mut(); let mut write = null_mut();
    // SAFETY: output pointers are valid; handles are noninheritable and transferred below.
    check(unsafe { CreatePipe(&mut read, &mut write, null(), 65536) })?;
    // SAFETY: CreatePipe returned two separately owned handles.
    Ok(unsafe { (File::from(owned(read)?), File::from(owned(write)?)) })
}
impl Pty {
    pub fn new(shell: &str, cwd: &Path, integration: &Path, size: PtySize) -> Result<Self, String> {
        let path = Path::new(shell); let name = path.file_name().and_then(|p| p.to_str()).unwrap_or("").to_ascii_lowercase();
        if !path.is_absolute() || !path.is_file() || !["powershell.exe", "pwsh.exe"].contains(&name.as_str()) { return Err("Windows sessions require an absolute PowerShell executable path".into()); }
        if !cwd.is_absolute() || !cwd.is_dir() || !integration.is_absolute() { return Err("invalid session directories".into()); }
        let hook = integration.join("akitty.ps1");
        if !hook.is_file() { return Err("bundled PowerShell integration is missing".into()); }
        let slot = Slot::new()?;
        let (input, mut writer) = pipe()?; let (reader, output) = pipe()?;
        let mut console = 0;
        // No inherited-cursor handshake: startup and teardown must not depend on a renderer reply.
        // SAFETY: pipe handles and output pointer are live, dimensions were validated by Session.
        let result = unsafe { CreatePseudoConsole(COORD { X: size.cols as i16, Y: size.rows as i16 }, input.as_raw_handle(), output.as_raw_handle(), 0, &mut console) };
        if result != 0 { return Err(format!("ConPTY creation failed: {result:#x}")); }
        let console = Console(console); drop(input); drop(output);
        // SAFETY: unnamed job creation returns a new owned handle.
        let job = unsafe { owned(CreateJobObjectW(null(), null())) }?;
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = Default::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: limits points to the declared structure and job is valid.
        check(unsafe { SetInformationJobObject(job.as_raw_handle(), JobObjectExtendedLimitInformation, (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(), std::mem::size_of_val(&limits) as u32) })?;
        let mut length = 0;
        // SAFETY: first call queries storage required for one attribute.
        unsafe { InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut length); }
        let mut attributes = vec![0usize; length.div_ceil(std::mem::size_of::<usize>())];
        let list = attributes.as_mut_ptr().cast();
        // SAFETY: buffer is correctly aligned and sized by the preceding API call.
        check(unsafe { InitializeProcThreadAttributeList(list, 1, 0, &mut length) })?;
        struct Attributes(LPPROC_THREAD_ATTRIBUTE_LIST);
        impl Drop for Attributes { fn drop(&mut self) {
            // SAFETY: list is initialized and its backing buffer outlives this guard.
            unsafe { DeleteProcThreadAttributeList(self.0); }
        } }
        let attributes_guard = Attributes(list);
        // SAFETY: the pseudoconsole attribute takes HPCON by value; list and console remain live through process creation.
        check(unsafe { UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize, console.0 as *const _, std::mem::size_of::<HPCON>(), null_mut(), null()) })?;
        let mut startup: STARTUPINFOEXW = Default::default();
        startup.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32; startup.lpAttributeList = list;
        // Prevent redirected SSH/test stdio from bypassing the pseudoconsole.
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = INVALID_HANDLE_VALUE; startup.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE; startup.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
        let command = format!("\"{shell}\" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File \"{}\"", hook.display());
        let mut command = wide(command);
        let mut environment: std::collections::BTreeMap<_, _> = std::env::vars_os().collect();
        for (key, value) in [("TERM", "xterm-256color"), ("COLORTERM", "truecolor"), ("TERM_PROGRAM", "Akitty"), ("TERM_PROGRAM_VERSION", "0.1.0-experimental")] { environment.insert(key.into(), value.into()); }
        let mut block = Vec::new();
        for (key, value) in environment { let mut entry = key; entry.push("="); entry.push(value); block.extend(wide(entry)); }
        block.push(0);
        let mut process: PROCESS_INFORMATION = Default::default();
        // Spawn suspended so all descendants are contained in the job before any shell code runs.
        // SAFETY: all strings/buffers are live and terminated; startup and process have the documented layout.
        check(unsafe { CreateProcessW(wide(shell).as_ptr(), command.as_mut_ptr(), null(), null(), 0,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED, block.as_ptr().cast(), wide(cwd).as_ptr(), &startup.StartupInfo, &mut process) })?;
        drop(attributes_guard);
        // SAFETY: CreateProcess returned new process and thread handles.
        let (process_handle, main_thread) = unsafe { (owned(process.hProcess)?, owned(process.hThread)?) };
        // SAFETY: both handles remain valid; no shell code has executed yet.
        if unsafe { AssignProcessToJobObject(job.as_raw_handle(), process_handle.as_raw_handle()) } == 0 {
            let message = error();
            // SAFETY: terminate our still-suspended child on containment failure.
            unsafe { TerminateProcess(process_handle.as_raw_handle(), 1); }
            return Err(message);
        }
        // SAFETY: this is the initial thread of our suspended child.
        if unsafe { ResumeThread(main_thread.as_raw_handle()) } == u32::MAX { return Err(error()); }
        let pending = Arc::new(AtomicBool::new(false)); let failure = Arc::new(Mutex::new(None));
        let (sender, receiver) = mpsc::sync_channel::<Vec<u8>>(1);
        let busy = pending.clone(); let failed = failure.clone();
        let worker = thread::Builder::new().name("akitty-conpty-input".into()).spawn(move || {
            while let Ok(bytes) = receiver.recv() {
                let result = writer.write_all(&bytes);
                busy.store(false, Ordering::SeqCst);
                if let Err(error) = result { if let Ok(mut failure) = failed.lock() { *failure = Some(error.to_string()); } break; }
            }
        }).map_err(|e| e.to_string())?;
        Ok(Self { resources: Some(Resources { console: Some(console), closer: None, process: process_handle, job, reader, sender, writer: worker, _slot: slot }), pending, failure, code: None })
    }
    fn resources(&self) -> Result<&Resources, String> { self.resources.as_ref().ok_or_else(|| "ConPTY is closed".into()) }
    pub fn resize(&self, size: PtySize) -> Result<(), String> {
        // SAFETY: console is live and dimensions validated by Session.
        let result = unsafe { ResizePseudoConsole(self.resources()?.console.as_ref().ok_or("ConPTY is closing")?.0, COORD { X: size.cols as i16, Y: size.rows as i16 }) };
        if result == 0 { Ok(()) } else { Err(format!("ConPTY resize failed: {result:#x}")) }
    }
    pub fn input_pending(&self) -> bool { self.pending.load(Ordering::SeqCst) }
    pub fn write(&mut self, bytes: &[u8]) -> Result<usize, String> {
        if let Some(error) = self.failure.lock().map_err(|_| "ConPTY writer unavailable")?.as_ref() { return Err(error.clone()); }
        if self.pending.swap(true, Ordering::SeqCst) { return Ok(0); }
        let count = bytes.len().min(8192);
        if self.resources()?.sender.send(bytes[..count].to_vec()).is_err() { self.pending.store(false, Ordering::SeqCst); return Err("ConPTY writer stopped".into()); }
        Ok(count)
    }
    pub fn read(&mut self, bytes: &mut [u8]) -> Result<Option<usize>, String> {
        self.poll_exit()?;
        let resources = self.resources.as_mut().ok_or("ConPTY is closed")?;
        let mut available = 0;
        // SAFETY: live output pipe; this only queries available bytes.
        if unsafe { PeekNamedPipe(resources.reader.as_raw_handle(), null_mut(), 0, null_mut(), &mut available, null_mut()) } == 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) { return Ok(Some(0)); }
            return Err(error());
        }
        if available == 0 {
            let mut accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = Default::default();
            // SAFETY: accounting is writable and job is live.
            check(unsafe { QueryInformationJobObject(resources.job.as_raw_handle(), JobObjectBasicAccountingInformation, (&mut accounting as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(), std::mem::size_of_val(&accounting) as u32, null_mut()) })?;
            if self.code.is_some() && accounting.ActiveProcesses == 0 && let Some(console) = resources.console.take() {
                // Closing flushes conhost output. Keep draining to actual pipe EOF; an empty pipe
                // immediately after process exit does not prove all terminal output arrived.
                resources.closer = Some(thread::spawn(move || drop(console)));
            }
            return Ok(None);
        }
        let count = bytes.len().min(available as usize);
        resources.reader.read(&mut bytes[..count]).map(Some).map_err(|e| e.to_string())
    }
    pub fn poll_exit(&mut self) -> Result<(), String> {
        if let Some(resources) = &self.resources {
            // SAFETY: process is live; zero timeout is nonblocking.
            if unsafe { WaitForSingleObject(resources.process.as_raw_handle(), 0) } == WAIT_OBJECT_0 {
                let mut code = 0;
                // SAFETY: code points to a writable DWORD.
                check(unsafe { GetExitCodeProcess(resources.process.as_raw_handle(), &mut code) })?; self.code = Some(code);
            }
        }
        Ok(())
    }
    pub fn exit_code(&self) -> Option<u32> { self.code }
    pub fn close(&mut self) -> Result<(), String> {
        self.poll_exit()?;
        let Some(resources) = self.resources.take() else { return Ok(()) };
        // Teardown may block inside Windows. Retain a bounded session slot until all handles/threads
        // are reclaimed, drain output concurrently with ClosePseudoConsole, and never hold the host lock.
        let worker = thread::spawn(move || {
            let Resources { console, closer, process, job, mut reader, sender, writer, _slot } = resources;
            drop(job); drop(sender);
            let closer = closer.unwrap_or_else(|| thread::spawn(move || drop(console)));
            let mut buffer = [0u8; 8192];
            while !closer.is_finished() || !writer.is_finished() {
                // SAFETY: JoinHandle keeps the writer thread handle live; cancellation handles the blocked write race.
                unsafe { CancelSynchronousIo(writer.as_raw_handle()); }
                let mut available = 0;
                // SAFETY: output is still owned; no other reader exists during cleanup.
                if unsafe { PeekNamedPipe(reader.as_raw_handle(), null_mut(), 0, null_mut(), &mut available, null_mut()) } != 0 && available > 0 {
                    let count = buffer.len().min(available as usize); let _ = reader.read(&mut buffer[..count]);
                } else { thread::sleep(Duration::from_millis(5)); }
            }
            let _ = closer.join(); let _ = writer.join(); drop(process); drop(_slot);
        });
        let deadline = Instant::now()+Duration::from_millis(100);
        while !worker.is_finished() && Instant::now() < deadline { thread::sleep(Duration::from_millis(2)); }
        if worker.is_finished() { worker.join().map_err(|_| "ConPTY cleanup panicked".into()) }
        else { Err("ConPTY cleanup continues in the bounded background reaper".into()) }
    }
}
impl Drop for Pty { fn drop(&mut self) { let _ = self.close(); } }
