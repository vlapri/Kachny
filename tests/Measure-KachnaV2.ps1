<#
.SYNOPSIS
    Změří, kolik procesoru a paměti spotřebuje běžící kachna v2 (jen Windows).

.DESCRIPTION
    Najde proces s powershell_kachna_v2.ps1 a každých IntervalSec sekund vypíše, kolik procesorového času
    kachna za tu dobu spotřebovala (v % jednoho jádra i celého počítače) a kolik má paměti.
    Správce úloh zaokrouhluje na celá procenta všech jader, takže rozdíl mezi chůzí, pauzou, spánkem
    a skrytím v něm skoro není vidět – tady ano.

    Postup: spusť kachnu, pak tento skript a během měření ji přepínej z menu (chůze, pauza, skrýt,
    úsporný režim) – každý řádek je jeden interval. Pro porovnání vykreslování změň v powershell_kachna_v2.ps1
    nastavení SoftwareRendering ($true = bez grafické karty, $false = WPF s grafickou kartou) a změř znovu.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Measure-KachnaV2.ps1
    Měří každou minutu, dokud ho neukončíš (Ctrl+C).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Measure-KachnaV2.ps1 -IntervalSec 30 -Count 10
    Deset měření po 30 sekundách a na konci průměr.
#>
param(
    [ValidateRange(1, 3600)]
    [int]$IntervalSec = 60,
    [ValidateRange(0, 100000)]
    [int]$Count = 0,        # 0 = měřit, dokud ho neukončíš (Ctrl+C)
    [int]$ProcessId = 0     # 0 = kachnu najít podle příkazové řádky
)

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Error 'Měření běžící kachny funguje jen ve Windows.'
    return
}

function Get-DuckProcess {
    # Procesy kachny: zadané PID, nebo PowerShell s powershell_kachna_v2.ps1 na příkazové řádce
    # (při spuštění v MTA jsou dva: původní čeká, kachna běží v novém s -STA).
    param([int]$Id)
    if ($Id -gt 0) { return @(Get-Process -Id $Id -ErrorAction Stop) }
    $found = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" |
            Where-Object { $_.CommandLine -like '*powershell_kachna_v2.ps1*' -and $_.ProcessId -ne $PID })
    return @($found | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
}

$processes = @(Get-DuckProcess -Id $ProcessId)
if ($processes.Count -eq 0) {
    Write-Warning 'Kachna neběží. Spusť powershell_kachna_v2.cmd (nebo zadej -ProcessId) a změř znovu.'
    return
}

$cores = [Environment]::ProcessorCount
$format = '{0,-8} {1,7} {2,10} {3,10} {4,11} {5,10} {6,12}'
Write-Output ("Kachna: PID {0}, jader: {1}, interval {2} s" -f (($processes | ForEach-Object { $_.Id }) -join ', '), $cores, $IntervalSec)
Write-Output ($format -f 'Čas', 'PID', 'CPU [s]', 'Jádro [%]', 'Celkem [%]', 'Paměť [MB]', 'Soukromá [MB]')

$last = @{}
$sum = @{}
foreach ($p in $processes) {
    $last[$p.Id] = $p.TotalProcessorTime.TotalSeconds
    $sum[$p.Id] = 0.0
}
$round = 0
while ($Count -eq 0 -or $round -lt $Count) {
    Start-Sleep -Seconds $IntervalSec
    $round++
    foreach ($p in $processes) {
        $p.Refresh()
        if ($p.HasExited) {
            Write-Output ("{0,-8} {1,7}  kachna skončila" -f (Get-Date).ToString('HH:mm:ss'), $p.Id)
            continue
        }
        $cpu = $p.TotalProcessorTime.TotalSeconds
        $delta = $cpu - $last[$p.Id]
        $last[$p.Id] = $cpu
        $sum[$p.Id] += $delta
        $oneCore = 100 * $delta / $IntervalSec
        Write-Output ($format -f (Get-Date).ToString('HH:mm:ss'), $p.Id, ('{0:N3}' -f $delta), ('{0:N2}' -f $oneCore),
            ('{0:N3}' -f ($oneCore / $cores)), ('{0:N0}' -f ($p.WorkingSet64 / 1MB)), ('{0:N0}' -f ($p.PrivateMemorySize64 / 1MB)))
    }
    if (@($processes | Where-Object { -not $_.HasExited }).Count -eq 0) { break }
}

if ($round -gt 0) {
    foreach ($p in $processes) {
        $avg = 100 * $sum[$p.Id] / ($round * $IntervalSec)
        Write-Output ("Průměr PID {0}: {1:N2} % jednoho jádra ({2:N3} % celého počítače)" -f $p.Id, $avg, ($avg / $cores))
    }
}
