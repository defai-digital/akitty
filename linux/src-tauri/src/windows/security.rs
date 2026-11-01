use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::System::Threading::*;

pub(crate) fn wide(value: impl AsRef<OsStr>) -> Vec<u16> { value.as_ref().encode_wide().chain(Some(0)).collect() }
pub(crate) fn error() -> String { std::io::Error::last_os_error().to_string() }
pub(crate) fn check(value: i32) -> Result<(), String> { if value == 0 { Err(error()) } else { Ok(()) } }
/// # Safety
/// `raw` must be a newly owned kernel handle or an API failure sentinel.
pub(crate) unsafe fn owned(raw: HANDLE) -> Result<OwnedHandle, String> {
    if raw.is_null() || raw == INVALID_HANDLE_VALUE { return Err(error()); }
    // SAFETY: caller transfers a newly owned handle.
    Ok(unsafe { OwnedHandle::from_raw_handle(raw) })
}
fn sid_text(sid: PSID) -> Result<String, String> {
    let mut text = null_mut();
    // SAFETY: sid points into a live token/security descriptor; API allocates text.
    check(unsafe { ConvertSidToStringSidW(sid, &mut text) })?;
    // SAFETY: conversion returns a null-terminated UTF-16 allocation.
    let result = unsafe {
        let mut len = 0; while *text.add(len) != 0 { len += 1; }
        let value = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
        LocalFree(text.cast()); value
    };
    Ok(result)
}
pub(crate) fn identity(pid: Option<u32>) -> Result<(String, u32), String> {
    // SAFETY: OpenProcess returns a new handle; GetCurrentProcess returns a pseudo handle, not owned.
    let process = if let Some(pid) = pid { Some(unsafe { owned(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)) }?) } else { None };
    let mut raw = null_mut();
    // SAFETY: process handle and output token pointer are valid.
    check(unsafe { OpenProcessToken(process.as_ref().map_or_else(|| GetCurrentProcess(), |p| p.as_raw_handle()), TOKEN_QUERY, &mut raw) })?;
    // SAFETY: OpenProcessToken returned an owned token.
    let token = unsafe { owned(raw) }?;
    let mut needed = 0;
    // SAFETY: query required buffer size without dereferencing a null buffer.
    unsafe { GetTokenInformation(token.as_raw_handle(), TokenUser, null_mut(), 0, &mut needed); }
    if needed == 0 || needed > 65536 { return Err("invalid token size".into()); }
    let mut data = vec![0usize; (needed as usize).div_ceil(std::mem::size_of::<usize>())];
    // SAFETY: buffer is aligned and at least needed bytes; token remains alive.
    check(unsafe { GetTokenInformation(token.as_raw_handle(), TokenUser, data.as_mut_ptr().cast(), needed, &mut needed) })?;
    // SAFETY: a successful TokenUser query initialized TOKEN_USER at the buffer start.
    let sid = sid_text(unsafe { (*(data.as_ptr().cast::<TOKEN_USER>())).User.Sid })?;
    let mut session = 0u32;
    // SAFETY: session points to a writable DWORD.
    check(unsafe { GetTokenInformation(token.as_raw_handle(), TokenSessionId, (&mut session as *mut u32).cast(), 4, &mut needed) })?;
    Ok((sid, session))
}

pub(crate) struct Descriptor(PSECURITY_DESCRIPTOR);
impl Descriptor {
    pub fn new() -> Result<Self, String> {
        let (sid, _) = identity(None)?;
        let sddl = wide(format!("O:{sid}D:P(A;OICI;FA;;;{sid})"));
        let mut descriptor = null_mut();
        // SAFETY: sddl is terminated and descriptor is a valid output pointer.
        check(unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, null_mut()) })?;
        Ok(Self(descriptor))
    }
    pub fn attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: self.0, bInheritHandle: 0 }
    }
}
impl Drop for Descriptor {
    fn drop(&mut self) {
        // SAFETY: descriptor was allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW.
        unsafe { LocalFree(self.0); }
    }
}
pub(crate) fn private_handle(handle: HANDLE) -> Result<(), String> {
    let expected = identity(None)?.0;
    let mut descriptor = null_mut(); let mut owner = null_mut(); let mut acl = null_mut();
    // SAFETY: live handle and all requested output pointers remain valid throughout this call.
    let code = unsafe { GetSecurityInfo(handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        &mut owner, null_mut(), &mut acl, null_mut(), &mut descriptor) };
    if code != 0 { return Err(format!("cannot inspect private object permissions: {code}")); }
    let _descriptor = Descriptor(descriptor);
    if owner.is_null() || acl.is_null() || sid_text(owner)? != expected { return Err("object must have a private user-owned DACL".into()); }
    // SAFETY: GetSecurityInfo initialized acl inside the live descriptor.
    let count = unsafe { (*acl).AceCount };
    if count == 0 || count > 8 { return Err("invalid private object DACL".into()); }
    for i in 0..count {
        let mut ace = null_mut();
        // SAFETY: i is within the initialized ACL's ACE count.
        check(unsafe { GetAce(acl, i as u32, &mut ace) })?;
        // SAFETY: each ACE starts with ACE_HEADER; allow ACE SID begins at SidStart.
        unsafe {
            let header = &*ace.cast::<ACE_HEADER>();
            if header.AceType != 0 || header.AceSize < std::mem::size_of::<ACCESS_ALLOWED_ACE>() as u16 {
                return Err("unsupported private object ACL entry".into());
            }
            let entry = &*ace.cast::<ACCESS_ALLOWED_ACE>();
            if sid_text((&entry.SidStart as *const u32).cast_mut().cast())? != expected { return Err("object grants another identity access".into()); }
        }
    }
    Ok(())
}
