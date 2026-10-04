<#
.SYNOPSIS
    Testy kachny v2, které nepotřebují Windows ani WPF.

.DESCRIPTION
    Kontroluje kódování, syntaxi, XAML, rozměry kresby, hlášky, spouštěč .cmd a hlavně logiku
    kachny (chůze, pauza, klepnutí, přetažení, pád, změna monitoru, náhodné chování, rychlost hlášek,
    skrytí a zobrazení) na simulovaných monitorech 1080p / 1200p / 2K / 4K s různým škálováním.
    Funkce se berou přímo z powershell_kachna_v2.ps1; okno, časovače a monitory jsou nahrazené
    jednoduchými náhradními objekty. PSScriptAnalyzer se použije, pokud je k dispozici.

.EXAMPLE
    pwsh -NoProfile -File tests/Test-KachnaV2.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-KachnaV2.ps1
#>
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'

$v2Path = Join-Path $RepoRoot 'powershell_kachna_v2.ps1'
$v1Path = Join-Path $RepoRoot 'powershell_kachna.ps1'
$cmdPath = Join-Path $RepoRoot 'powershell_kachna_v2.cmd'

$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:passed++
        Write-Host "  [OK]    $Name" -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host "  [CHYBA] $Name" -ForegroundColor Red
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Get-ScriptAst {
    param([string]$Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    return [pscustomobject]@{ Ast = $ast; Errors = $errors }
}

function Get-AssignedValue {
    # Vyhodnotí pravou stranu přiřazení "$Name = ..." ze skriptu (jen pro literály: pole, hashtable).
    param($Ast, [string]$Name)
    $assign = $Ast.Find({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.Left.VariablePath.UserPath -eq $Name
        }, $true)
    if (-not $assign) { throw "Přiřazení `$$Name nenalezeno" }
    return , (& ([scriptblock]::Create($assign.Right.Extent.Text)))
}

function Get-XamlText {
    param($Ast)
    $node = $Ast.Find({
            param($n)
            ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Value -match '<Window'
        }, $true)
    return $node.Value
}

function Get-PathBounds {
    # Obrys cesty z XAML (příkazy M/L/C/Z, relativní i absolutní), Bézierovy křivky se vzorkují.
    param([string]$Figures)
    $tokens = @([regex]::Matches($Figures, '[MmLlCcZz]|-?\d*\.?\d+(?:[eE]-?\d+)?') | ForEach-Object { $_.Value })
    $i = 0; $x = 0.0; $y = 0.0; $sx = 0.0; $sy = 0.0; $cmd = 'M'
    $xs = New-Object System.Collections.Generic.List[double]
    $ys = New-Object System.Collections.Generic.List[double]
    while ($i -lt $tokens.Count) {
        if ($tokens[$i] -match '^[A-Za-z]$') { $cmd = $tokens[$i]; $i++ }
        $rel = $cmd -cmatch '^[a-z]$'
        switch ($cmd.ToUpperInvariant()) {
            'Z' { $x = $sx; $y = $sy; continue }
            { $_ -in 'M', 'L' } {
                $nx = [double]$tokens[$i]; $ny = [double]$tokens[$i + 1]; $i += 2
                if ($rel) { $x += $nx; $y += $ny } else { $x = $nx; $y = $ny }
                if ($cmd -ceq 'M' -or $cmd -ceq 'm') { $sx = $x; $sy = $y; $cmd = $(if ($rel) { 'l' } else { 'L' }) }
                $xs.Add($x); $ys.Add($y)
            }
            'C' {
                $a = @(0..5 | ForEach-Object { [double]$tokens[$i + $_] }); $i += 6
                if ($rel) { $a = @(($a[0] + $x), ($a[1] + $y), ($a[2] + $x), ($a[3] + $y), ($a[4] + $x), ($a[5] + $y)) }
                for ($k = 1; $k -le 50; $k++) {
                    $t = $k / 50; $mt = 1 - $t
                    $xs.Add($mt * $mt * $mt * $x + 3 * $mt * $mt * $t * $a[0] + 3 * $mt * $t * $t * $a[2] + $t * $t * $t * $a[4])
                    $ys.Add($mt * $mt * $mt * $y + 3 * $mt * $mt * $t * $a[1] + 3 * $mt * $t * $t * $a[3] + $t * $t * $t * $a[5])
                }
                $x = $a[4]; $y = $a[5]
            }
            default { throw "Nepodporovaný příkaz cesty: $cmd" }
        }
    }
    $mx = $xs | Measure-Object -Minimum -Maximum
    $my = $ys | Measure-Object -Minimum -Maximum
    return [pscustomobject]@{ Left = $mx.Minimum; Top = $my.Minimum; Right = $mx.Maximum; Bottom = $my.Maximum }
}

# ===========================================================================
Write-Section 'Soubory a kódování'
# ===========================================================================
Assert-True (Test-Path $v2Path) 'powershell_kachna_v2.ps1 existuje'
Assert-True (Test-Path $cmdPath) 'powershell_kachna_v2.cmd existuje'
Assert-True (Test-Path $v1Path) 'původní powershell_kachna.ps1 zůstal na místě'

$bytes = [System.IO.File]::ReadAllBytes($v2Path)
Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'v2 je UTF-8 s BOM (nutné pro diakritiku v PS 5.1)'
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$v2Text = $null
try { $v2Text = $strictUtf8.GetString($bytes, 3, $bytes.Length - 3); $validUtf8 = $true } catch { $validUtf8 = $false }
Assert-True $validUtf8 'v2 je platné UTF-8'
Assert-True (-not [regex]::IsMatch($v2Text, "(?<!`r)`n")) 'v2 má všechny konce řádků CRLF'
Assert-True (-not $v2Text.Contains("`t")) 'v2 neobsahuje tabulátory'
Assert-True (-not [regex]::IsMatch($v2Text, '__[A-Z0-9_]+__')) 'v2 neobsahuje nevyplněné zástupné značky'

$cmdBytes = [System.IO.File]::ReadAllBytes($cmdPath)
$cmdText = [System.Text.Encoding]::ASCII.GetString($cmdBytes)
Assert-True (-not ($cmdBytes[0] -eq 0xEF -and $cmdBytes[1] -eq 0xBB)) '.cmd je bez BOM (jinak cmd nepozná první řádek)'
Assert-True (@($cmdBytes | Where-Object { $_ -gt 127 }).Count -eq 0) '.cmd obsahuje jen ASCII (cmd čte v OEM kódové stránce)'
Assert-True (-not [regex]::IsMatch($cmdText, "(?<!`r)`n")) '.cmd má konce řádků CRLF'
Assert-True ($cmdText.Contains('powershell_kachna_v2.ps1')) '.cmd spouští powershell_kachna_v2.ps1'
Assert-True ($cmdText.Contains('-ExecutionPolicy Bypass') -and $cmdText.Contains('-STA')) '.cmd obchází ExecutionPolicy a spouští v STA'
Assert-True ($cmdText.Contains('%~dp0')) '.cmd hledá skript ve své složce (funguje odkudkoli)'

# ===========================================================================
Write-Section 'Syntaxe'
# ===========================================================================
$v2 = Get-ScriptAst $v2Path
$v1 = Get-ScriptAst $v1Path
Assert-True ($v2.Errors.Count -eq 0) "v2 nemá syntaktické chyby ($($v2.Errors.Count))"
$v2.Errors | ForEach-Object { Write-Host "          $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
Assert-True ($v1.Errors.Count -eq 0) 'v1 nemá syntaktické chyby'

# ===========================================================================
Write-Section 'XAML a kresba kachny'
# ===========================================================================
[xml]$xaml = Get-XamlText $v2.Ast
[xml]$xamlV1 = Get-XamlText $v1.Ast
Assert-True ($xaml.DocumentElement.LocalName -eq 'Window') 'XAML je platné XML s kořenem Window'

$byName = @{}
foreach ($el in $xaml.SelectNodes('//*')) {
    # Name="..." i x:Name="..."
    foreach ($n in @($el.GetAttribute('Name'), $el.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml'))) {
        if ($n) { $byName[$n] = $el }
    }
}
$findNameLine = [regex]::Match($v2Text, "foreach \(\`$name in ([^)]+)\) \{ \`$ui\[").Groups[1].Value
$usedNames = @([regex]::Matches($findNameLine, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
Assert-True ($usedNames.Count -ge 5) "skript hledá v XAML prvky: $($usedNames -join ', ')"
foreach ($n in $usedNames) { Assert-True $byName.ContainsKey($n) "XAML obsahuje prvek '$n'" }

$win = $xaml.DocumentElement
$winW = [double]$win.Width; $winH = [double]$win.Height
$viewbox = $byName['DuckViewbox']; $duckBox = $byName['DuckBox']; $layer = $byName['Layer_1']
$vbW = [double]$viewbox.Width; $vbH = [double]$viewbox.Height
$boxW = [double]$duckBox.Width; $boxH = [double]$duckBox.Height
$scaleX = $vbW / $boxW; $scaleY = $vbH / $boxH
Assert-True ([math]::Abs($scaleX - $scaleY) -lt 0.001) "Viewbox nedeformuje kachnu (měřítko $scaleX x $scaleY)"
$v1Win = $xamlV1.DocumentElement
$v1Scale = [math]::Min([double]$v1Win.Width / 640, [double]$v1Win.Height / 480)
Assert-True ([math]::Abs($scaleX - $v1Scale) -lt 0.001) "kachna je stejně velká jako ve v1 (měřítko $v1Scale)"
Assert-True ($winW -ge $vbW -and $winW - $vbW -le 20) "okno ($winW) je jen o málo širší než kachna ($vbW) -> kachna dojde k okraji"
Assert-True (($winH - $vbH) -ge 120) "nad kachnou je místo na bublinu ($($winH - $vbH) DIP, aspoň 5 řádků)"
Assert-True ([double]$byName['SpeechBubble'].Width -le $winW - 10) 'bublina se vejde do šířky okna'

# Tvary kachny jsou stejné jako ve v1
$pathsV2 = @{}; $pathsV1 = @{}
foreach ($p in $xaml.SelectNodes("//*[local-name()='Path'][@Name]")) { $pathsV2[$p.GetAttribute('Name')] = $p.SelectSingleNode(".//*[local-name()='PathGeometry']").GetAttribute('Figures') }
foreach ($p in $xamlV1.SelectNodes("//*[local-name()='Path'][@Name]")) { $pathsV1[$p.GetAttribute('Name')] = $p.SelectSingleNode(".//*[local-name()='PathGeometry']").GetAttribute('Figures') }
foreach ($n in 'path2', 'path4', 'path6', 'path10') { Assert-True ($pathsV2[$n] -eq $pathsV1[$n]) "tvar $n je stejný jako ve v1" }
$xamlAnimations = $xaml.SelectNodes("//*[local-name()='EventTrigger' or local-name()='Storyboard']")
Assert-True ($xamlAnimations.Count -eq 0) 'XAML nemá žádné animace (nohy i tělo řídí skript, aby šly zastavit v pauze a ve skrytu)'

# Ořez plátna musí obsáhnout celou kresbu včetně pohybu nohou (+-35) a poloviny tahu (2.5)
$bounds = @()
foreach ($n in $pathsV2.Keys) {
    $b = Get-PathBounds $pathsV2[$n]
    if ($n -eq 'path2') { $b.Right += 35 }
    if ($n -eq 'path4') { $b.Left -= 35 }
    $bounds += $b
}
foreach ($e in $xaml.SelectNodes("//*[local-name()='Ellipse']")) {
    $l = [double]$e.GetAttribute('Canvas.Left'); $t = [double]$e.GetAttribute('Canvas.Top')
    $bounds += [pscustomobject]@{ Left = $l; Top = $t; Right = $l + [double]$e.Width; Bottom = $t + [double]$e.Height }
}
$drawL = ($bounds | Measure-Object Left -Minimum).Minimum - 2.5
$drawT = ($bounds | Measure-Object Top -Minimum).Minimum - 2.5
$drawR = ($bounds | Measure-Object Right -Maximum).Maximum + 2.5
$drawB = ($bounds | Measure-Object Bottom -Maximum).Maximum + 2.5
$cropL = - [double]$layer.GetAttribute('Canvas.Left'); $cropT = - [double]$layer.GetAttribute('Canvas.Top')
$cropR = $cropL + $boxW; $cropB = $cropT + $boxH
Write-Host ("          kresba x {0:N1}..{1:N1}, y {2:N1}..{3:N1}; ořez x {4}..{5}, y {6}..{7}" -f $drawL, $drawR, $drawT, $drawB, $cropL, $cropR, $cropT, $cropB)
Assert-True ($drawL -ge $cropL -and $drawR -le $cropR) 'ořez neusekne kachnu do stran'
Assert-True ($drawT -ge $cropT -and $drawB -le $cropB) 'ořez neusekne kachnu nahoře ani dole (nohy)'
Assert-True (($cropR - $cropL) - ($drawR - $drawL) -le 20) 'ořez je těsný (kachna dojde až k okraji obrazovky)'

# Ocásek bubliny se musí vejít do svého řádku, jinak by ho WPF ořízlo
$tail = $xaml.SelectSingleNode("//*[local-name()='Grid'][@*[local-name()='Name']='SpeechBubble']/*[local-name()='Path']")
$tailMaxY = ([regex]::Matches($tail.GetAttribute('Data'), '-?\d+,(-?\d+)') | ForEach-Object { [double]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum
$tailRow = [double]($xaml.SelectNodes("//*[local-name()='Grid'][@*[local-name()='Name']='SpeechBubble']/*[local-name()='Grid.RowDefinitions']/*")[1].GetAttribute('Height'))
Assert-True ($tailMaxY + 1 -le $tailRow) "ocásek bubliny ($tailMaxY + tah) se vejde do řádku ($tailRow)"

# ===========================================================================
Write-Section 'Nastavení a hlášky'
# ===========================================================================
$config = Get-AssignedValue $v2.Ast 'config'
Assert-True ($config.Speeds.Contains($config.DefaultSpeed)) "výchozí rychlost '$($config.DefaultSpeed)' existuje"
$v1Speed = 5 / 0.35
Assert-True ([math]::Abs($config.Speeds[$config.DefaultSpeed] - $v1Speed) -lt 1.5) ("výchozí rychlost {0} DIP/s odpovídá v1 ({1:N1} px/s)" -f $config.Speeds[$config.DefaultSpeed], $v1Speed)
Assert-True ($config.ComplaintIntervalSec -eq 60) 'stížnost v pauze každou minutu'
$ps = $config.PhraseSpeeds
Assert-True ($ps.Contains($config.DefaultPhraseSpeed)) "výchozí rychlost hlášek '$($config.DefaultPhraseSpeed)' existuje"
Assert-True ((@($ps.Keys) -join ',') -eq (@($config.Speeds.Keys) -join ',')) 'rychlost hlášek má stejné volby jako rychlost chůze'
Assert-True ($ps['Pomalá'] -gt $ps['Normální'] -and $ps['Normální'] -gt $ps['Rychlá'] -and $ps['Rychlá'] -ge 3) ("rychlost hlášek: pomalá {0} s, normální {1} s, rychlá {2} s (aspoň 3 s na přečtení)" -f $ps['Pomalá'], $ps['Normální'], $ps['Rychlá'])
Assert-True ($config.FrameMs -le 50) "plynulý pohyb ($([math]::Round(1000 / $config.FrameMs)) snímků/s, v1 měla 3)"

$duckPhrases = Get-AssignedValue $v2.Ast 'duckPhrases'
$duckPhrasesV1 = Get-AssignedValue $v1.Ast 'duckPhrases'
$complaintPhrases = Get-AssignedValue $v2.Ast 'complaintPhrases'
$resumePhrases = Get-AssignedValue $v2.Ast 'resumePhrases'
$dropPhrases = Get-AssignedValue $v2.Ast 'dropPhrases'
$restPhrases = Get-AssignedValue $v2.Ast 'restPhrases'
$showPhrases = Get-AssignedValue $v2.Ast 'showPhrases'
$missingV1 = @($duckPhrasesV1 | Where-Object { $duckPhrases -cnotcontains $_ })
$missingV1 | ForEach-Object { Write-Host "          chybí: $_" -ForegroundColor Red }
Assert-True ($missingV1.Count -eq 0) "v2 má všechny hlášky z v1 beze změny ($($duckPhrasesV1.Count) z v1, celkem $($duckPhrases.Count))"
Assert-True ($complaintPhrases.Count -ge 10) "stížností je dost ($($complaintPhrases.Count))"
foreach ($list in @(@{ N = 'stížnosti'; L = $complaintPhrases }, @{ N = 'po pauze'; L = $resumePhrases }, @{ N = 'po přistání'; L = $dropPhrases }, @{ N = 'odpočinek'; L = $restPhrases }, @{ N = 'po zobrazení'; L = $showPhrases })) {
    Assert-True ($list.L.Count -ge 3 -and @($list.L | Sort-Object -Unique).Count -eq $list.L.Count) "hlášky '$($list.N)': aspoň 3, bez duplicit"
}
# odhad: ~7,2 DIP na znak při FontSize 14, text široký 206 DIP; +20 znaků rezerva na dlouhé uživatelské jméno
$tooLong = @(@($duckPhrases) + $complaintPhrases + $resumePhrases + $dropPhrases + $restPhrases + $showPhrases |
        Where-Object { [math]::Ceiling(($_.Length + 20) * 7.2 / 206) -gt 5 })
$tooLong | ForEach-Object { Write-Host "          příliš dlouhá: $_" -ForegroundColor Red }
Assert-True ($tooLong.Count -eq 0) 'všechny hlášky se vejdou do bubliny (max 5 řádků)'

# ===========================================================================
# Funkce ze skriptu + náhradní objekty místo WPF
# ===========================================================================
$functions = $v2.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($f in $functions) { . ([scriptblock]::Create($f.Extent.Text)) }

# ShownAt = kde okno bylo ve chvíli zobrazení (kachna se nemá objevit na staré pozici a pak skočit jinam)
$window = [pscustomobject]@{ Left = 0.0; Top = 0.0; Width = $winW; Height = $winH; IsVisible = $true; ShownAt = $null }
$window | Add-Member -MemberType ScriptMethod -Name Hide -Value { $this.IsVisible = $false }
$window | Add-Member -MemberType ScriptMethod -Name Show -Value { $this.IsVisible = $true; $this.ShownAt = [pscustomobject]@{ Left = $this.Left; Top = $this.Top } }
$ui = @{
    SpeechText = [pscustomobject]@{ Text = '' }
    RootFlip   = [pscustomobject]@{ ScaleX = 1 }
    TextFlip   = [pscustomobject]@{ ScaleX = 1 }
}
function New-TimerMock {
    $timer = [pscustomobject]@{ Interval = [TimeSpan]::Zero; Running = $false }
    $timer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Running = $false }
    $timer | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Running = $true }
    return $timer
}
function New-StoryboardMock {
    # Running = spuštěný (Begin) a nezastavený (Stop), Paused = pozastavený (Pause)
    $sb = [pscustomobject]@{ Running = $false; Paused = $false; Ratio = 1.0 }
    $sb | Add-Member -MemberType ScriptMethod -Name Begin -Value { $this.Running = $true; $this.Paused = $false; $this.Ratio = 1.0 }
    $sb | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Running = $false }
    $sb | Add-Member -MemberType ScriptMethod -Name Pause -Value { $this.Paused = $true }
    $sb | Add-Member -MemberType ScriptMethod -Name Resume -Value { $this.Paused = $false }
    $sb | Add-Member -MemberType ScriptMethod -Name Seek -Value { }
    $sb | Add-Member -MemberType ScriptMethod -Name SetSpeedRatio -Value { param($o, $r) $this.Ratio = $r }
    return $sb
}
$moveTimer = New-TimerMock
$speechTimer = New-TimerMock
$legs = New-StoryboardMock
$glow = New-StoryboardMock
# Menu: položky se stejnými vlastnostmi jako WPF MenuItem (Header, IsChecked) a WinForms ToolStripMenuItem (Text, Checked)
function New-ChoiceMenuMock {
    param([string[]]$Choices, [switch]$Tray)
    if ($Tray) { return [pscustomobject]@{ DropDownItems = @($Choices | ForEach-Object { [pscustomobject]@{ Text = $_; Checked = $false } }) } }
    return [pscustomobject]@{ Items = @($Choices | ForEach-Object { [pscustomobject]@{ Header = $_; IsChecked = $false } }) }
}
$menuItems = @{
    Pause           = [pscustomobject]@{ Header = '' }
    TrayPause       = [pscustomobject]@{ Text = '' }
    TrayHide        = [pscustomobject]@{ Text = '' }
    Speed           = New-ChoiceMenuMock $config.Speeds.Keys
    TraySpeed       = New-ChoiceMenuMock $config.Speeds.Keys -Tray
    PhraseSpeed     = New-ChoiceMenuMock $config.PhraseSpeeds.Keys
    TrayPhraseSpeed = New-ChoiceMenuMock $config.PhraseSpeeds.Keys -Tray
    Random          = [pscustomobject]@{ IsChecked = $false }
    TrayRandom      = [pscustomobject]@{ Checked = $false }
}
$clock = [pscustomobject]@{ T = 0.0 }
$clock | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { [TimeSpan]::FromSeconds($this.T) }

# Monitory: stav, který by vrátily WinForms Screen + TransformFromDevice
$sim = @{ WindowArea = $null; CursorArea = $null; CursorDip = $null; Layout = $null }
function Get-WindowArea {
    # Jako Screen.FromHandle (MonitorFromWindow): monitor s největším překryvem okna.
    if (-not $sim.Layout) { return $sim.WindowArea }
    $best = $null; $bestOverlap = -1.0
    foreach ($a in $sim.Layout) {
        $w = [math]::Min($window.Left + $window.Width, $a.Right) - [math]::Max($window.Left, $a.Left)
        $h = [math]::Min($window.Top + $window.Height, $a.Bottom) - [math]::Max($window.Top, $a.Top)
        $overlap = [math]::Max(0.0, $w) * [math]::Max(0.0, $h)
        if ($overlap -gt $bestOverlap) { $best = $a; $bestOverlap = $overlap }
    }
    return $best
}
function Get-CursorArea { $sim.CursorArea }
function Get-CursorDip { $sim.CursorDip }
function Get-DipScale { @(1.0, 1.0) }

function Reset-Duck {
    param($Area)
    $script:state = Get-AssignedValue $v2.Ast 'state'
    $state.LegsReady = $true
    $state.RandomBehavior = $false
    $state.Area = $Area
    $sim.WindowArea = $Area
    $sim.Layout = $null
    $state.X = $Area.Left
    $state.Y = $Area.Bottom - $window.Height
    $state.LastTick = $clock.T
    $state.NextAreaCheck = $clock.T + 1000
    Set-Direction 1
    Set-WindowPosition
    # jako po načtení okna (Loaded): okno je vidět, časovače běží, animace taky
    $window.IsVisible = $true
    $legs.Begin($window, $true)
    $glow.Begin($window, $true)
    Update-LegAnimation
    $moveTimer.Start()
    Restart-SpeechTimer
}

function Invoke-Ticks {
    # Simuluje běh časovače pohybu (jen když běží). Track sbírá min/max pozice a otočky.
    param([double]$Seconds, [double]$Step = 0.1)
    $track = @{ MinX = [double]::MaxValue; MaxX = [double]::MinValue; Turns = 0; Rested = $false; FlipOk = $true; SpeedFactors = @() }
    $dir = $state.Direction
    $n = [int][math]::Ceiling($Seconds / $Step)
    for ($i = 0; $i -lt $n; $i++) {
        $clock.T += $Step
        if ($moveTimer.Running) { Invoke-MoveTick }
        $track.MinX = [math]::Min($track.MinX, $window.Left)
        $track.MaxX = [math]::Max($track.MaxX, $window.Left)
        if ($state.Direction -ne $dir) { $track.Turns++; $dir = $state.Direction }
        if ($state.Resting) { $track.Rested = $true }
        if ($ui.RootFlip.ScaleX -ne $state.Direction -or $ui.TextFlip.ScaleX -ne $state.Direction) { $track.FlipOk = $false }
        $track.SpeedFactors += $state.SpeedFactor
    }
    return $track
}

function New-Monitor {
    # Pracovní plocha v pixelech zařízení + měřítko (TransformFromDevice) -> DIP
    param([string]$Name, [double]$L, [double]$T, [double]$R, [double]$B, [double]$Scale)
    return [pscustomobject]@{ Name = $Name; Area = (ConvertTo-DipRect -Left $L -Top $T -Right $R -Bottom $B -ScaleX $Scale -ScaleY $Scale) }
}

# ===========================================================================
Write-Section 'Čisté funkce'
# ===========================================================================
Assert-True ((Get-Clamped -Value 5 -Min 0 -Max 10) -eq 5 -and (Get-Clamped -Value -5 -Min 0 -Max 10) -eq 0 -and (Get-Clamped -Value 50 -Min 0 -Max 10) -eq 10) 'Get-Clamped omezí hodnotu do intervalu'
Assert-True ((Get-Clamped -Value 5 -Min 10 -Max 0) -eq 10) 'Get-Clamped zvládne Max < Min'
$r = ConvertTo-DipRect -Left 0 -Top 0 -Right 3840 -Bottom 2160 -ScaleX (1 / 1.5) -ScaleY (1 / 1.5)
Assert-True ([math]::Abs($r.Right - 2560) -lt 0.01 -and [math]::Abs($r.Bottom - 1440) -lt 0.01) 'ConvertTo-DipRect: 4K při 150 % = 2560 x 1440 DIP'
$r = Step-Walk -X 95 -Direction 1 -Speed 100 -Dt 0.1 -MinX 0 -MaxX 100
Assert-True ($r.X -eq 100 -and $r.Direction -eq -1) 'Step-Walk: na pravém okraji se zastaví a otočí'
$r = Step-Walk -X 5 -Direction -1 -Speed 100 -Dt 0.1 -MinX 0 -MaxX 100
Assert-True ($r.X -eq 0 -and $r.Direction -eq 1) 'Step-Walk: na levém okraji se zastaví a otočí'
$r = Step-Walk -X 150 -Direction -1 -Speed 10 -Dt 0.1 -MinX 0 -MaxX 100
Assert-True ($r.X -eq 100 -and $r.Direction -eq -1) 'Step-Walk: mimo plochu se vrátí na okraj bez zbytečného otočení'
$r = Step-Walk -X -500 -Direction 1 -Speed 10 -Dt 0.1 -MinX -1000 -MaxX 0
Assert-True ($r.X -eq -499 -and $r.Direction -eq 1) 'Step-Walk: funguje i na monitoru se zápornými souřadnicemi'
$r = Step-Fall -Y 0 -Velocity 0 -Dt 0.1 -GroundY 1000 -Gravity 3000 -RiseSpeed 800
Assert-True ($r.Y -gt 0 -and $r.Velocity -gt 0 -and -not $r.Landed) 'Step-Fall: padá a zrychluje'
$r = Step-Fall -Y 990 -Velocity 2000 -Dt 0.1 -GroundY 1000 -Gravity 3000 -RiseSpeed 800
Assert-True ($r.Y -eq 1000 -and $r.Landed) 'Step-Fall: přistane přesně na zemi'
$r = Step-Fall -Y 1100 -Velocity 0 -Dt 0.1 -GroundY 1000 -Gravity 3000 -RiseSpeed 800
Assert-True ($r.Y -eq 1020 -and -not $r.Landed) 'Step-Fall: pod zemí se vynořuje nahoru'
$last = ''; $repeat = $false
for ($i = 0; $i -lt 500; $i++) { $p = Get-RandomPhrase $duckPhrases $last; if ($p -eq $last) { $repeat = $true }; $last = $p }
Assert-True (-not $repeat) 'Get-RandomPhrase: stejná hláška nikdy dvakrát po sobě (500 pokusů)'
Assert-True ((Get-RandomPhrase @('jen jedna') 'jen jedna') -eq 'jen jedna') 'Get-RandomPhrase: zvládne seznam s jedinou hláškou'
Assert-True ((Get-RandomAction 0) -eq 'Turn' -and (Get-RandomAction 20) -eq 'Rest' -and (Get-RandomAction 99) -eq 'Stroll') 'Get-RandomAction: rozdělení otočení / odpočinek / tempo'

# ===========================================================================
Write-Section 'Chůze na různých monitorech (rozlišení i škálování)'
# ===========================================================================
$monitors = @(
    (New-Monitor '1920x1080 @100 %, panel dole' 0 0 1920 1040 1.0),
    (New-Monitor '1920x1200 @100 %, vpravo od hlavního' 1920 0 3840 1200 1.0),
    (New-Monitor '2560x1440 (2K) @125 %, vlevo, panel vlevo' -2498 -360 0 1080 0.8),
    (New-Monitor '3840x2160 (4K) @150 %, panel dole' 0 0 3840 2112 (1 / 1.5)),
    (New-Monitor '3840x2160 (4K) @200 %, vlevo, panel nahoře' -3840 60 0 2160 0.5)
)
foreach ($m in $monitors) {
    Reset-Duck $m.Area
    $state.SpeedName = 'Rychlá'
    $a = $m.Area
    $t = Invoke-Ticks -Seconds 250
    $inside = $t.MinX -ge $a.Left - 0.001 -and ($t.MaxX + $window.Width) -le $a.Right + 0.001
    $edges = [math]::Abs($t.MinX - $a.Left) -lt 0.001 -and [math]::Abs($t.MaxX + $window.Width - $a.Right) -lt 0.001
    $ground = [math]::Abs($window.Top + $window.Height - $a.Bottom) -lt 0.001 -and $window.Top -ge $a.Top
    Assert-True ($inside -and $edges -and $ground -and $t.Turns -ge 2 -and $t.FlipOk) ("{0}: plocha {1:N0}x{2:N0} DIP, chodí od okraje k okraji ({3} otoček), stojí na spodním okraji" -f $m.Name, ($a.Right - $a.Left), ($a.Bottom - $a.Top), $t.Turns)
}

# ===========================================================================
Write-Section 'Pauza, klepnutí a stížnosti'
# ===========================================================================
$main = $monitors[0].Area
Reset-Duck $main
$state.SpeedName = 'Normální'
[void](Invoke-Ticks -Seconds 5)
$xBefore = $state.X
Set-Paused $true
Assert-True ($ui.SpeechText.Text -in $complaintPhrases) "po zapauzování si hned stěžuje: '$($ui.SpeechText.Text)'"
Assert-True ($speechTimer.Interval.TotalSeconds -eq 60 -and $speechTimer.Running) 'další stížnost za 60 s'
Assert-True ($legs.Paused) 'nohy se v pauze zastaví'
[void](Invoke-Ticks -Seconds 30)
Assert-True ($state.X -eq $xBefore) 'v pauze se kachna nehýbe'
$first = $ui.SpeechText.Text
Invoke-SpeechTick
Assert-True ($ui.SpeechText.Text -in $complaintPhrases -and $ui.SpeechText.Text -ne $first) 'po minutě přijde jiná stížnost (žádné běžné hlášky)'
Set-Paused $false
$normalInterval = $config.PhraseSpeeds[$config.DefaultPhraseSpeed]
Assert-True ($ui.SpeechText.Text -in $resumePhrases -and $speechTimer.Interval.TotalSeconds -eq $normalInterval) "po zrušení pauzy poděkuje a mluví zase každých $normalInterval s"
Assert-True (-not $legs.Paused -and [math]::Abs($legs.Ratio - 1.0) -lt 0.001) 'nohy zase kmitají jako ve v1'
[void](Invoke-Ticks -Seconds 5)
Assert-True ($state.X -gt $xBefore) 'po zrušení pauzy jde dál'
Invoke-SpeechTick
Assert-True ($ui.SpeechText.Text -in $duckPhrases) 'při chůzi říká běžné hlášky'

# Klepnutí = DragMove skoro bez pohybu
Set-WindowPosition
$state.Dragging = $true
$window.Left += 2
Complete-Drag -StartLeft ($window.Left - 2) -StartTop $window.Top
Assert-True ($state.Paused -and $window.Left -eq $state.X) 'klepnutí (posun 2 DIP) zapauzuje a vrátí okno na místo'
$state.Dragging = $true
Complete-Drag -StartLeft $window.Left -StartTop $window.Top
Assert-True (-not $state.Paused) 'další klepnutí kachnu rozběhne'

# ===========================================================================
Write-Section 'Přetažení na jiný monitor a pád'
# ===========================================================================
$right = $monitors[1].Area   # 1920x1200 vpravo od hlavního
Reset-Duck $main
$sim.Layout = @($main, $right)
$state.Dragging = $true
[void](Invoke-Ticks -Seconds 2)
Assert-True ($window.Left -eq $main.Left) 'během tažení časovač s oknem nehýbe'
# uživatel pustí kachnu na pravém monitoru vysoko nahoře
$window.Left = 2500; $window.Top = 100
$sim.CursorArea = $right
Complete-Drag -StartLeft 0 -StartTop 682
Assert-True ($state.Falling -and $legs.Ratio -eq 4.0) 'po puštění padá a nohy kmitají rychle'
$fallTime = 0.0
while ($state.Falling -and $fallTime -lt 5) { $clock.T += 0.03; $fallTime += 0.03; Invoke-MoveTick }
Assert-True (-not $state.Falling -and $fallTime -lt 1.5) ("dopadla za {0:N2} s" -f $fallTime)
Assert-True ([math]::Abs($window.Top + $window.Height - $right.Bottom) -lt 0.001 -and $window.Left -eq 2500) 'stojí na spodním okraji monitoru, kam byla puštěna'
Assert-True ($ui.SpeechText.Text -in $dropPhrases) "po přistání něco řekne: '$($ui.SpeechText.Text)'"
$t = Invoke-Ticks -Seconds 120
Assert-True ($t.MinX -ge $right.Left -and $t.MaxX + $window.Width -le $right.Right) 'pak chodí jen po novém monitoru'

# Monitory nad sebou: kurzor už je na spodním monitoru, okno ale leží většinou na horním
$below = (New-Monitor '1920x1080 pod hlavním' 0 1080 1920 2120 1.0).Area
Reset-Duck $main
$sim.Layout = @($main, $below)
$state.Dragging = $true
$window.Left = 300; $window.Top = 750
$sim.CursorArea = $below
Complete-Drag -StartLeft 0 -StartTop 682
[void](Invoke-Ticks -Seconds 2)
Assert-True ([math]::Abs($window.Top + $window.Height - $below.Bottom) -lt 0.001) 'monitory nad sebou: spadne na monitor pod kurzorem, ne na ten s větším překryvem'
[void](Invoke-Ticks -Seconds 30)
Assert-True ([math]::Abs($window.Top + $window.Height - $below.Bottom) -lt 0.001) 'monitory nad sebou: zůstane na spodním monitoru'

# Puštění částečně mimo plochu a pod spodní okraj (nad hlavním panelem)
Reset-Duck $main
$window.Left = 1900; $window.Top = 1000
$sim.CursorArea = $main
Complete-Drag -StartLeft 0 -StartTop 682
Assert-True ($state.X -eq $main.Right - $window.Width) 'puštění přes okraj: kachna se posune celá na monitor'
[void](Invoke-Ticks -Seconds 1)
Assert-True (-not $state.Falling -and [math]::Abs($window.Top + $window.Height - $main.Bottom) -lt 0.001) 'puštění pod spodní okraj: vynoří se na zem'

# Puštění v pauze
Reset-Duck $main
Set-Paused $true
$complaint = $ui.SpeechText.Text
$window.Left = 800; $window.Top = 50
$state.Dragging = $true
Complete-Drag -StartLeft 0 -StartTop 682
[void](Invoke-Ticks -Seconds 2)
$xLanded = $state.X
[void](Invoke-Ticks -Seconds 10)
Assert-True ($state.Paused -and $ui.SpeechText.Text -eq $complaint -and $state.X -eq $xLanded) 'v pauze po přistání zůstane stát a bublina dál ukazuje stížnost'
Set-Paused $false

# Přivolání z ikony v oznamovací oblasti
Reset-Duck $main
$sim.Layout = @($main, $right)
$sim.CursorArea = $right
$sim.CursorDip = [pscustomobject]@{ X = 3000; Y = 1150 }
Invoke-Summon
Assert-True ($state.Falling -and $state.Y -eq $right.Top -and $state.X -eq 3000 - $window.Width / 2) 'přivolání: objeví se nahoře nad kurzorem na jeho monitoru'
[void](Invoke-Ticks -Seconds 2)
Assert-True ([math]::Abs($window.Top + $window.Height - $right.Bottom) -lt 0.001) 'přivolání: spadne na spodní okraj'
$t = Invoke-Ticks -Seconds 30
Assert-True ($t.MinX -ge $right.Left -and [math]::Abs($window.Top + $window.Height - $right.Bottom) -lt 0.001) 'přivolání: pak chodí po monitoru s kurzorem'

# ===========================================================================
Write-Section 'Změna monitorů za běhu'
# ===========================================================================
Reset-Duck $monitors[1].Area
$state.X = 3500; Set-WindowPosition
$state.NextAreaCheck = 0
# monitor odpojen -> Windows hlásí nejbližší monitor (hlavní)
$sim.WindowArea = $main
[void](Invoke-Ticks -Seconds 1)
Assert-True ($window.Left -ge $main.Left -and $window.Left + $window.Width -le $main.Right -and [math]::Abs($window.Top + $window.Height - $main.Bottom) -lt 0.001) 'odpojení monitoru: kachna se do 1 s přesune na zbylý monitor'
# změna rozlišení / hlavního panelu
$small = (New-Monitor '1280x720' 0 0 1280 680 1.0).Area
$sim.WindowArea = $small
$state.X = 1600; Set-WindowPosition
[void](Invoke-Ticks -Seconds 1)
Assert-True ($window.Left + $window.Width -le $small.Right -and [math]::Abs($window.Top + $window.Height - $small.Bottom) -lt 0.001) 'snížení rozlišení: kachna zůstane na obrazovce'

# ===========================================================================
Write-Section 'Náhodné chování a rychlost'
# ===========================================================================
$null = Get-Random -SetSeed 42
Reset-Duck $main
Set-RandomBehavior $true
$t = Invoke-Ticks -Seconds 600
$factors = @($t.SpeedFactors | Sort-Object -Unique)
Assert-True $t.Rested 'kachna si občas sama odpočine'
Assert-True ($factors.Count -gt 2 -and ($factors | Measure-Object -Minimum).Minimum -ge 0.6 -and ($factors | Measure-Object -Maximum).Maximum -le 1.6) "mění tempo v rozmezí 0,6-1,6x ($($factors.Count) různých)"
Assert-True ($t.MinX -ge $main.Left -and $t.MaxX + $window.Width -le $main.Right) 'i při náhodném chování zůstává na monitoru'
Set-RandomBehavior $false
Assert-True ($state.SpeedFactor -eq 1.0 -and -not $state.Resting) 'vypnutí náhodného chování vrátí normální tempo'
Set-Speed 'Rychlá'
Assert-True ($state.SpeedName -eq 'Rychlá' -and (Get-CurrentSpeed) -eq $config.Speeds['Rychlá']) 'změna rychlosti z menu'
Set-Speed 'Neexistuje'
Assert-True ($state.SpeedName -eq 'Rychlá') 'neznámá rychlost se ignoruje'

# ===========================================================================
Write-Section 'Rychlost hlášek'
# ===========================================================================
Reset-Duck $main
Assert-True ($state.PhraseSpeedName -eq $config.DefaultPhraseSpeed -and $speechTimer.Running -and $speechTimer.Interval.TotalSeconds -eq $normalInterval) "po startu mluví každých $normalInterval s ($($config.DefaultPhraseSpeed))"
foreach ($name in $config.PhraseSpeeds.Keys) {
    Set-PhraseSpeed $name
    $sec = $config.PhraseSpeeds[$name]
    Assert-True ($state.PhraseSpeedName -eq $name -and $speechTimer.Running -and $speechTimer.Interval.TotalSeconds -eq $sec) "rychlost hlášek '$name': mluví každých $sec s"
}
Set-PhraseSpeed 'Rychlá'
Set-PhraseSpeed 'Neexistuje'
Assert-True ($state.PhraseSpeedName -eq 'Rychlá' -and $speechTimer.Interval.TotalSeconds -eq $config.PhraseSpeeds['Rychlá']) 'neznámá rychlost hlášek se ignoruje'
Set-Paused $true
Set-PhraseSpeed 'Pomalá'
Assert-True ($state.PhraseSpeedName -eq 'Pomalá' -and $speechTimer.Interval.TotalSeconds -eq $config.ComplaintIntervalSec) 'v pauze si kachna dál stěžuje jednou za minutu, ať je rychlost hlášek jakákoli'
Set-Paused $false
Assert-True ($speechTimer.Interval.TotalSeconds -eq $config.PhraseSpeeds['Pomalá']) 'po zrušení pauzy mluví podle rychlosti hlášek zvolené v pauze'
Set-Speed 'Rychlá'
Assert-True ($state.SpeedName -eq 'Rychlá' -and $state.PhraseSpeedName -eq 'Pomalá') 'rychlost chůze a rychlost hlášek se nastavují nezávisle'
Update-MenuState
$checked = @($menuItems.Speed.Items | Where-Object IsChecked | ForEach-Object Header) + @($menuItems.TraySpeed.DropDownItems | Where-Object Checked | ForEach-Object Text)
Assert-True (($checked -join ',') -eq 'Rychlá,Rychlá') 'menu: u rychlosti chůze je zaškrtnutá jen zvolená možnost (u kachny i u ikony)'
$checked = @($menuItems.PhraseSpeed.Items | Where-Object IsChecked | ForEach-Object Header) + @($menuItems.TrayPhraseSpeed.DropDownItems | Where-Object Checked | ForEach-Object Text)
Assert-True (($checked -join ',') -eq 'Pomalá,Pomalá') 'menu: u rychlosti hlášek je zaškrtnutá jen zvolená možnost (u kachny i u ikony)'

# ===========================================================================
Write-Section 'Skrytí a zobrazení'
# ===========================================================================
Reset-Duck $main
[void](Invoke-Ticks -Seconds 5)
Update-MenuState
Assert-True ($menuItems.TrayHide.Text -eq 'Skrýt kachnu') "ikona: nabízí '$($menuItems.TrayHide.Text)', když je kachna vidět"
$xHidden = $state.X; $dirHidden = $state.Direction; $textHidden = $ui.SpeechText.Text
Set-Hidden $true
Assert-True (-not $window.IsVisible -and $state.Hidden) 'skrytí: okno zmizí'
Assert-True (-not $moveTimer.Running -and -not $speechTimer.Running) 'skrytí: oba časovače stojí'
# jen pozastavený storyboard nestačí, WPF by dál tikalo ~60x za sekundu
Assert-True (-not $legs.Running -and -not $glow.Running) 'skrytí: animace nohou i těla jsou zastavené (program jen čeká)'
Update-MenuState
Assert-True ($menuItems.TrayHide.Text -eq 'Zobrazit kachnu') "ikona: nabízí '$($menuItems.TrayHide.Text)', když je kachna skrytá"
[void](Invoke-Ticks -Seconds 120)
Assert-True ($state.X -eq $xHidden -and $window.Left -eq $xHidden -and $ui.SpeechText.Text -eq $textHidden) 'skrytá kachna se 2 minuty nepohnula ani nepromluvila'
Set-Hidden $true
Assert-True ($state.Hidden -and -not $window.IsVisible -and -not $moveTimer.Running) 'opakované skrytí nic nerozbije'
# v menu u ikony jde nastavení měnit i ve skrytu, kachnu to ale neprobudí
Set-Speed 'Pomalá'; Set-PhraseSpeed 'Rychlá'; Set-RandomBehavior $true; Switch-Pause; Switch-Pause
Assert-True (-not $window.IsVisible -and -not $moveTimer.Running -and -not $speechTimer.Running -and -not $legs.Running -and -not $glow.Running) 'změny nastavení ve skrytu kachnu neprobudí'
Switch-Hidden
Assert-True ($window.IsVisible -and -not $state.Hidden -and $moveTimer.Running -and $speechTimer.Running) 'zobrazení: okno i oba časovače zase běží'
Assert-True ($legs.Running -and -not $legs.Paused -and $glow.Running) 'zobrazení: nohy i tělo se zase hýbou'
Assert-True ($ui.SpeechText.Text -in $showPhrases) "zobrazení: kachna se ozve: '$($ui.SpeechText.Text)'"
Assert-True ($speechTimer.Interval.TotalSeconds -eq $config.PhraseSpeeds['Rychlá']) 'zobrazení: mluví podle rychlosti hlášek zvolené ve skrytu'
Assert-True ($window.ShownAt.Left -eq $xHidden -and $state.Direction -eq $dirHidden) 'zobrazení: kachna je tam, kde zmizela, a jde stejným směrem'
[void](Invoke-Ticks -Seconds 2)
Assert-True ($state.X -ne $xHidden) 'zobrazení: chodí dál'

# Zapauzovaná kachna zůstane po zobrazení zapauzovaná
Reset-Duck $main
Set-Paused $true
Set-Hidden $true
Set-Hidden $false
Assert-True ($state.Paused -and $legs.Running -and $legs.Paused -and $ui.SpeechText.Text -in $complaintPhrases -and $speechTimer.Interval.TotalSeconds -eq $config.ComplaintIntervalSec) 'zapauzovaná kachna po zobrazení dál stojí a stěžuje si jednou za minutu'
Set-Paused $false

# Monitor odpojený ve skrytu: kachna se nesmí objevit mimo obrazovku
Reset-Duck $right
$state.X = 3500; Set-WindowPosition
Set-Hidden $true
$sim.WindowArea = $main
Set-Hidden $false
$at = $window.ShownAt
Assert-True ($at.Left -ge $main.Left -and $at.Left + $window.Width -le $main.Right -and [math]::Abs($at.Top + $window.Height - $main.Bottom) -lt 0.001) 'monitor odpojený ve skrytu: kachna se ukáže rovnou na zbylém monitoru'

# Přivolání skryté kachny z ikony
Reset-Duck $main
$sim.Layout = @($main, $right)
Set-Hidden $true
$sim.CursorArea = $right
$sim.CursorDip = [pscustomobject]@{ X = 3000; Y = 1150 }
$textBefore = $ui.SpeechText.Text
Invoke-Summon
Assert-True ($window.IsVisible -and $moveTimer.Running -and $state.Falling -and $window.ShownAt.Top -eq $right.Top -and $window.ShownAt.Left -eq 3000 - $window.Width / 2) 'přivolání skryté kachny: zobrazí se rovnou nahoře nad kurzorem'
Assert-True ($ui.SpeechText.Text -eq $textBefore) 'přivolání skryté kachny: během pádu nic neříká'
[void](Invoke-Ticks -Seconds 2)
Assert-True (-not $state.Falling -and [math]::Abs($window.Top + $window.Height - $right.Bottom) -lt 0.001 -and $ui.SpeechText.Text -in $dropPhrases) 'přivolání skryté kachny: dopadne a promluví'

# Skrytí během pádu
Reset-Duck $main
$sim.CursorArea = $main
$window.Left = 800; $window.Top = 50
Complete-Drag -StartLeft 0 -StartTop 682
[void](Invoke-Ticks -Seconds 0.2)
Set-Hidden $true
$yHidden = $state.Y
[void](Invoke-Ticks -Seconds 5)
Assert-True ($state.Falling -and $state.Y -eq $yHidden) 'skrytí během pádu: pád se zastaví'
Set-Hidden $false
[void](Invoke-Ticks -Seconds 2)
Assert-True (-not $state.Falling -and [math]::Abs($window.Top + $window.Height - $main.Bottom) -lt 0.001) 'po zobrazení pád dokončí a stojí na zemi'

# ===========================================================================
Write-Section 'PSScriptAnalyzer'
# ===========================================================================
$pssa = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
if (-not $pssa -and $env:KACHNA_PSSA) { $pssa = $env:KACHNA_PSSA }
if ($pssa) {
    Import-Module $pssa -ErrorAction Stop
    $findings = @(Invoke-ScriptAnalyzer -Path $v2Path -Severity Error, Warning)
    $findings | ForEach-Object { Write-Host "          $($_.Line): $($_.RuleName) - $($_.Message)" -ForegroundColor Yellow }
    Assert-True ($findings.Count -eq 0) "v2 bez chyb a varování PSScriptAnalyzeru ($($findings.Count))"
} else {
    Write-Host '  [PŘESKOČENO] PSScriptAnalyzer není nainstalovaný (Install-Module PSScriptAnalyzer)' -ForegroundColor Yellow
}

# ===========================================================================
Write-Host ''
$color = if ($script:failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "Výsledek: $script:passed OK, $script:failed chyb" -ForegroundColor $color
if ($script:failed -gt 0) { exit 1 }
exit 0
