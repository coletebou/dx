# roles/local/wsl.sh — local+WSL specific (Windows interop)
#
# Sourced when /mnt/c/Windows exists (WSL detection). Contains the
# Windows-tool passthroughs that only make sense from inside WSL.

# VS Code launcher (bridges to the Windows-installed executable). The Windows
# profile path is resolved on first use, not at shell startup: cmd.exe takes
# about 100 ms to answer.
code() {
    if [[ -z "${_WSL_VSCODE:-}" ]]; then
        local appdata
        appdata="$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')"
        [[ -n "$appdata" ]] || { echo "code: cannot ask Windows for %LOCALAPPDATA%" >&2; return 1; }
        _WSL_VSCODE="$(wslpath "$appdata")/Programs/Microsoft VS Code/bin/code"
    fi
    "$_WSL_VSCODE" "$@"
}
