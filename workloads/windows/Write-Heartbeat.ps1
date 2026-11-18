Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$file = 'C:\ProgramData\OT-Lab\data\sample-state.json'
$heartbeat = [ordered]@{
    timestamp = [DateTime]::UtcNow.ToString('o')
    correlationId = [guid]::NewGuid().ToString()
    computer = $env:COMPUTERNAME
    scenario = 'synthetic-only'
    state = 'healthy'
}
$json = $heartbeat | ConvertTo-Json -Compress
$json | Set-Content -LiteralPath $file -Encoding UTF8
Write-EventLog -LogName Application -Source 'OT-Lab' -EventId 1000 -EntryType Information -Message $json
