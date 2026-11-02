//! Windows adapters. Authority and observation models remain platform independent.
pub(crate) mod security;

pub(crate) fn shells() -> Vec<String> {
    let mut paths = Vec::new();
    if let Some(root) = std::env::var_os("ProgramFiles") {
        paths.push(std::path::PathBuf::from(root).join("PowerShell/7/pwsh.exe"));
    }
    if let Some(root) = std::env::var_os("SystemRoot") {
        paths.push(std::path::PathBuf::from(root).join("System32/WindowsPowerShell/v1.0/powershell.exe"));
    }
    paths.into_iter().filter(|p| p.is_file()).map(|p| p.to_string_lossy().into_owned()).collect()
}
