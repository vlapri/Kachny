<#
.SYNOPSIS
    Testy kachny v2, které nepotřebují Windows ani WPF.

.DESCRIPTION
    Kontroluje kódování, syntaxi, XAML, rozměry kresby a převleků, hlášky, spouštěč .cmd a hlavně logiku
    kachny (chůze, pauza, klepnutí, dvojklik, přetažení, pád, chůze přes monitory, změna monitoru, náhodné
    chování, úspora CPU, bublina, skrytí, zamčení PC, spánek, krmení, "Pojď za myší", připomínky, menu)
    na simulovaných monitorech 1080p / 1200p / 2K / 4K s různým škálováním.
    Funkce se berou přímo z powershell_kachna_v2.ps1; okno, animace, časovače, monitory, myš a napájení
    jsou nahrazené jednoduchými náhradními objekty. Simulace posouvá čas: animace počítá stejnými křivkami
    jako WPF (lineárně, QuadraticEase) a po doběhnutí volá Complete-Motion, časovače tikají podle intervalu.
    PSScriptAnalyzer se použije, pokud je k dispozici.

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
$measurePath = Join-Path $RepoRoot 'tests/Measure-KachnaV2.ps1'

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
    # Vyhodnotí pravou stranu přiřazení "$Name = ..." ze skriptu (literály: pole, hashtable, scriptblocky).
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
    # Text XAML ze skriptu podle titulku okna (kachna, rohlík); bez titulku první XAML (v1 titulek nemá).
    param($Ast, [string]$Title)
    $node = $Ast.Find({
            param($n)
            ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Value -match '<Window' -and
            (-not $Title -or $n.Value -match "Title=""$Title""")
        }, $true)
    return $node.Value
}

function Test-FileConvention {
    # .ps1: UTF-8 s BOM, platné UTF-8, CRLF, bez tabulátorů
    param([string]$Path, [string]$Label)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "$Label je UTF-8 s BOM (nutné pro diakritiku v PS 5.1)"
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $text = $null
    try { $text = $strictUtf8.GetString($bytes, 3, $bytes.Length - 3); $valid = $true } catch { $valid = $false }
    Assert-True $valid "$Label je platné UTF-8"
    Assert-True (-not [regex]::IsMatch($text, "(?<!`r)`n")) "$Label má všechny konce řádků CRLF"
    Assert-True (-not $text.Contains("`t")) "$Label neobsahuje tabulátory"
    return $text
}

function Get-PathPoints {
    # Body obrysu cesty z XAML (příkazy M/L/C/Z, relativní i absolutní), Bézierovy křivky se vzorkují.
    param([string]$Figures)
    $tokens = @([regex]::Matches($Figures, '[MmLlCcZz]|-?\d*\.?\d+(?:[eE]-?\d+)?') | ForEach-Object { $_.Value })
    $i = 0; $x = 0.0; $y = 0.0; $sx = 0.0; $sy = 0.0; $cmd = 'M'
    $points = New-Object System.Collections.Generic.List[object]
    while ($i -lt $tokens.Count) {
        if ($tokens[$i] -match '^[A-Za-z]$') { $cmd = $tokens[$i]; $i++ }
        $rel = $cmd -cmatch '^[a-z]$'
        switch ($cmd.ToUpperInvariant()) {
            'Z' { $x = $sx; $y = $sy; continue }
            { $_ -in 'M', 'L' } {
                $nx = [double]$tokens[$i]; $ny = [double]$tokens[$i + 1]; $i += 2
                if ($rel) { $x += $nx; $y += $ny } else { $x = $nx; $y = $ny }
                if ($cmd -ceq 'M' -or $cmd -ceq 'm') { $sx = $x; $sy = $y; $cmd = $(if ($rel) { 'l' } else { 'L' }) }
                $points.Add(@($x, $y))
            }
            'C' {
                $a = @(0..5 | ForEach-Object { [double]$tokens[$i + $_] }); $i += 6
                if ($rel) { $a = @(($a[0] + $x), ($a[1] + $y), ($a[2] + $x), ($a[3] + $y), ($a[4] + $x), ($a[5] + $y)) }
                for ($k = 1; $k -le 50; $k++) {
                    $t = $k / 50; $mt = 1 - $t
                    $points.Add(@(($mt * $mt * $mt * $x + 3 * $mt * $mt * $t * $a[0] + 3 * $mt * $t * $t * $a[2] + $t * $t * $t * $a[4]),
                            ($mt * $mt * $mt * $y + 3 * $mt * $mt * $t * $a[1] + 3 * $mt * $t * $t * $a[3] + $t * $t * $t * $a[5])))
                }
                $x = $a[4]; $y = $a[5]
            }
            default { throw "Nepodporovaný příkaz cesty: $cmd" }
        }
    }
    return , $points.ToArray()
}

function Get-PathBounds {
    param([string]$Figures)
    $points = Get-PathPoints $Figures
    $xs = $points | ForEach-Object { $_[0] } | Measure-Object -Minimum -Maximum
    $ys = $points | ForEach-Object { $_[1] } | Measure-Object -Minimum -Maximum
    return [pscustomobject]@{ Left = $xs.Minimum; Top = $ys.Minimum; Right = $xs.Maximum; Bottom = $ys.Maximum }
}

function Get-ShapePoints {
    # Body obrysu tvaru z XAML (Path s Data nebo PathGeometry, Ellipse) + polovina tahu.
    param($Element)
    $stroke = [double]$Element.GetAttribute('StrokeThickness') / 2
    if ($Element.LocalName -eq 'Ellipse') {
        $l = [double]$Element.GetAttribute('Canvas.Left'); $t = [double]$Element.GetAttribute('Canvas.Top')
        $rx = [double]$Element.Width / 2; $ry = [double]$Element.Height / 2
        $points = @(0..71 | ForEach-Object { $a = $_ * [math]::PI / 36; , @(($l + $rx + $rx * [math]::Cos($a)), ($t + $ry + $ry * [math]::Sin($a))) })
    } else {
        $data = $Element.GetAttribute('Data')
        if (-not $data) { $data = $Element.SelectSingleNode(".//*[local-name()='PathGeometry']").GetAttribute('Figures') }
        $points = Get-PathPoints $data
    }
    return [pscustomobject]@{ Points = $points; Stroke = $stroke }
}

function Get-TriangleDistance {
    # Vzdálenost bodu od trojúhelníku (0 = uvnitř).
    param([double[]]$P, [double[][]]$Tri)
    $sign = @(0..2 | ForEach-Object {
            $a = $Tri[$_]; $b = $Tri[($_ + 1) % 3]
            [math]::Sign(($b[0] - $a[0]) * ($P[1] - $a[1]) - ($b[1] - $a[1]) * ($P[0] - $a[0]))
        })
    if (-not ($sign -contains 1 -and $sign -contains -1)) { return 0.0 }
    $best = [double]::MaxValue
    for ($k = 0; $k -lt 3; $k++) {
        $a = $Tri[$k]; $b = $Tri[($k + 1) % 3]
        $dx = $b[0] - $a[0]; $dy = $b[1] - $a[1]
        $u = [math]::Max(0, [math]::Min(1, (($P[0] - $a[0]) * $dx + ($P[1] - $a[1]) * $dy) / ($dx * $dx + $dy * $dy)))
        $best = [math]::Min($best, [math]::Sqrt([math]::Pow($P[0] - $a[0] - $u * $dx, 2) + [math]::Pow($P[1] - $a[1] - $u * $dy, 2)))
    }
    return $best
}

# ===========================================================================
Write-Section 'Soubory a kódování'
# ===========================================================================
Assert-True (Test-Path $v2Path) 'powershell_kachna_v2.ps1 existuje'
Assert-True (Test-Path $cmdPath) 'powershell_kachna_v2.cmd existuje'
Assert-True (Test-Path $v1Path) 'původní powershell_kachna.ps1 zůstal na místě'
Assert-True (Test-Path $measurePath) 'tests/Measure-KachnaV2.ps1 (měření spotřeby) existuje'

$v2Text = Test-FileConvention $v2Path 'v2'
Assert-True (-not [regex]::IsMatch($v2Text, '__[A-Z0-9_]+__')) 'v2 neobsahuje nevyplněné zástupné značky'
$null = Test-FileConvention $measurePath 'měřicí skript'
$null = Test-FileConvention $PSCommandPath 'test'

$cmdBytes = [System.IO.File]::ReadAllBytes($cmdPath)
$cmdText = [System.Text.Encoding]::ASCII.GetString($cmdBytes)
Assert-True (-not ($cmdBytes[0] -eq 0xEF -and $cmdBytes[1] -eq 0xBB)) '.cmd je bez BOM (jinak cmd nepozná první řádek)'
Assert-True (@($cmdBytes | Where-Object { $_ -gt 127 }).Count -eq 0) '.cmd obsahuje jen ASCII (cmd čte v OEM kódové stránce)'
Assert-True (-not [regex]::IsMatch($cmdText, "(?<!`r)`n")) '.cmd má konce řádků CRLF'
Assert-True ($cmdText.Contains('powershell_kachna_v2.ps1')) '.cmd spouští powershell_kachna_v2.ps1'
Assert-True ($cmdText.Contains('-ExecutionPolicy Bypass') -and $cmdText.Contains('-STA')) '.cmd obchází ExecutionPolicy a spouští v STA'
Assert-True ($cmdText.Contains('%~dp0')) '.cmd hledá skript ve své složce (funguje odkudkoli)'
Assert-True ([regex]::IsMatch($cmdText, '(?m)^start .*powershell\.exe ')) '.cmd spouští Windows PowerShell 5.1 (powershell.exe, menší nároky než pwsh)'

# ===========================================================================
Write-Section 'Syntaxe'
# ===========================================================================
$v2 = Get-ScriptAst $v2Path
$v1 = Get-ScriptAst $v1Path
$measure = Get-ScriptAst $measurePath
Assert-True ($v2.Errors.Count -eq 0) "v2 nemá syntaktické chyby ($($v2.Errors.Count))"
$v2.Errors | ForEach-Object { Write-Host "          $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
Assert-True ($v1.Errors.Count -eq 0) 'v1 nemá syntaktické chyby'
Assert-True ($measure.Errors.Count -eq 0) 'měřicí skript nemá syntaktické chyby'
$ps7Only = @($v2.Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.TernaryExpressionAst] -or
            ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($n.Operator)" -eq 'QuestionQuestion') -or
            ($n -is [System.Management.Automation.Language.PipelineChainAst])
        }, $true))
Assert-True ($ps7Only.Count -eq 0) 'v2 nepoužívá syntaxi jen pro PS 7 (?:, ??, &&, ||)'
Assert-True (-not [regex]::IsMatch($v2Text, '(?m)^\s*Add-Type\s+(-TypeDefinition|-MemberDefinition|@'')')) 'v2 nekompiluje C# (Add-Type jen s -AssemblyName)'

# ===========================================================================
Write-Section 'XAML a kresba kachny'
# ===========================================================================
[xml]$xaml = Get-XamlText $v2.Ast 'Kachna'
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
Assert-True ($usedNames.Count -ge 10) "skript hledá v XAML prvky: $($usedNames -join ', ')"
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
Assert-True ($xamlAnimations.Count -eq 0) 'XAML nemá žádné animace (nohy i tělo řídí skript, aby šly zastavit v pauze, ve spánku a ve skrytu)'
foreach ($n in 'path2', 'path4') {
    $tt = $byName[$n].SelectSingleNode("./*[local-name()='Path.RenderTransform']/*[local-name()='TranslateTransform']")
    Assert-True ($null -ne $tt) "noha $n se posouvá přes TranslateTransform (animace bez přepočtu rozvržení)"
}
Assert-True ($v2Text.Contains('RenderTransformProperty') -and -not $v2Text.Contains('Canvas]::LeftProperty')) 'storyboard nohou animuje RenderTransform, ne Canvas.Left'

# Ořez plátna musí obsáhnout celou kresbu včetně pohybu nohou (+-35) a poloviny tahu (2.5); převleky se kontrolují zvlášť
$bounds = @()
foreach ($n in $pathsV2.Keys) {
    $b = Get-PathBounds $pathsV2[$n]
    if ($n -eq 'path2') { $b.Right += 35 }
    if ($n -eq 'path4') { $b.Left -= 35 }
    $bounds += $b
}
foreach ($e in $xaml.SelectNodes("//*[local-name()='Ellipse'][@Name]")) {
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
$bubble = $byName['SpeechBubble']
$tail = $bubble.SelectSingleNode("./*[local-name()='Path']")
$tailPoints = @([regex]::Matches($tail.GetAttribute('Data'), '(-?\d+),(-?\d+)') | ForEach-Object { , @([double]$_.Groups[1].Value, [double]$_.Groups[2].Value) })
$tailMaxY = ($tailPoints | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum
$tailRow = [double]($bubble.SelectNodes("./*[local-name()='Grid.RowDefinitions']/*")[1].GetAttribute('Height'))
Assert-True ($tailMaxY + 1 -le $tailRow) "ocásek bubliny ($tailMaxY + tah) se vejde do řádku ($tailRow)"
Assert-True ($tail.GetAttribute('Fill') -match 'ElementName=SpeechBorder') 'ocásek má barvu bubliny (modré připomínky)'

# Převleky a zavřené oko: souřadnice Layer_1 -> okno (překlopení DuckBox, ořez, Viewbox), totéž zpět
$offX = ($winW - $vbW) / 2; $offY = $winH - $vbH
function ConvertTo-LayerPoint { param([double]$X, [double]$Y) @(($cropL + $boxW - ($X - $offX) / $scaleX), ($cropT + ($Y - $offY) / $scaleY)) }
$bubbleLeft = $winW - [double]($bubble.Margin -split ',')[2] - [double]$bubble.Width
$bubbleBottom = $offY - $tailRow                                  # spodní okraj těla bubliny v okně
$bubbleLimitY = (ConvertTo-LayerPoint 0 $bubbleBottom)[1]          # ... v souřadnicích kresby
$tailTri = [double[][]]@($tailPoints | ForEach-Object { , [double[]](ConvertTo-LayerPoint ($bubbleLeft + $_[0]) ($bubbleBottom + $_[1])) })
$winTopLeft = ConvertTo-LayerPoint $winW 0                           # okno v souřadnicích kresby (x je překlopené)
$winBottomRight = ConvertTo-LayerPoint 0 $winH
foreach ($costume in 'CostumeSanta', 'CostumeWitch', 'CostumeGlasses') {
    $canvas = $byName[$costume]
    $shapes = @($canvas.SelectNodes("./*[local-name()='Path' or local-name()='Ellipse']") | ForEach-Object { Get-ShapePoints $_ })
    $minY = [double]::MaxValue; $minTail = [double]::MaxValue; $inWindow = $true
    foreach ($s in $shapes) {
        foreach ($p in $s.Points) {
            $minY = [math]::Min($minY, $p[1] - $s.Stroke)
            $minTail = [math]::Min($minTail, (Get-TriangleDistance $p $tailTri) - $s.Stroke)
            if ($p[0] - $s.Stroke -lt $winTopLeft[0] -or $p[0] + $s.Stroke -gt $winBottomRight[0] -or $p[1] - $s.Stroke -lt $winTopLeft[1]) { $inWindow = $false }
        }
    }
    Assert-True ($canvas.Visibility -eq 'Collapsed' -and $shapes.Count -ge 3) "$($costume): skrytý, dokud ho nezapne Update-Costume"
    Assert-True ($minY -ge $bubbleLimitY) ("$($costume): nesahá do bubliny (nejvýš y {0:N1}, bublina končí na {1:N1})" -f $minY, $bubbleLimitY)
    Assert-True ($minTail -gt 0) ("$($costume): nezasahuje do ocásku bubliny (odstup {0:N1})" -f $minTail)
    Assert-True $inWindow "$($costume): celý v okně"
}
Assert-True ($byName['SleepEye'].Visibility -eq 'Hidden') 'zavřené oko je vidět jen ve spánku'

# Rohlík pro krmení
[xml]$crumbXaml = Get-XamlText $v2.Ast 'Rohlík'
$config = Get-AssignedValue $v2.Ast 'config'
Assert-True ($crumbXaml.DocumentElement.LocalName -eq 'Window') 'XAML rohlíku je platné XML s kořenem Window'
Assert-True ([double]$crumbXaml.DocumentElement.Width -eq $config.CrumbSize.Width -and [double]$crumbXaml.DocumentElement.Height -eq $config.CrumbSize.Height) 'velikost okna s rohlíkem odpovídá nastavení CrumbSize'
Assert-True ($crumbXaml.DocumentElement.ShowActivated -eq 'False' -and $crumbXaml.DocumentElement.ShowInTaskbar -eq 'False') 'rohlík nekrade fokus a není na hlavním panelu'

# ===========================================================================
Write-Section 'Nastavení a hlášky'
# ===========================================================================
Assert-True ($config.Speeds.Contains($config.DefaultSpeed)) "výchozí rychlost '$($config.DefaultSpeed)' existuje"
$v1Speed = 5 / 0.35
Assert-True ([math]::Abs($config.Speeds[$config.DefaultSpeed] - $v1Speed) -lt 1.5) ("výchozí rychlost {0} DIP/s odpovídá v1 ({1:N1} px/s)" -f $config.Speeds[$config.DefaultSpeed], $v1Speed)
Assert-True ($config.ComplaintIntervalSec -eq 60) 'stížnost v pauze každou minutu'
$ps = $config.PhraseSpeeds
Assert-True ($ps.Contains($config.DefaultPhraseSpeed)) "výchozí rychlost hlášek '$($config.DefaultPhraseSpeed)' existuje"
Assert-True ((@($ps.Keys) -join ',') -eq (@($config.Speeds.Keys) -join ',')) 'rychlost hlášek má stejné volby jako rychlost chůze'
Assert-True ($ps['Pomalá'] -gt $ps['Normální'] -and $ps['Normální'] -gt $ps['Rychlá'] -and $ps['Rychlá'] -ge 3) ("rychlost hlášek: pomalá {0} s, normální {1} s, rychlá {2} s (aspoň 3 s na přečtení)" -f $ps['Pomalá'], $ps['Normální'], $ps['Rychlá'])
$fps = $config.Fps; $eco = $config.EcoFps
Assert-True ($fps.Legs -le 30 -and $fps.Glow -le 15 -and $fps.WalkMax -le 30 -and $fps.Fall -le 60) ("snímky omezené: nohy {0}, tělo {1}, chůze nejvýš {2}, pád {3} (WPF jinak ~60/s)" -f $fps.Legs, $fps.Glow, $fps.WalkMax, $fps.Fall)
Assert-True ($eco.Legs -lt $fps.Legs -and $eco.Glow -eq 0 -and $eco.WalkMax -lt $fps.WalkMax -and $eco.Fall -lt $fps.Fall -and $config.EcoPhraseFactor -gt 1) 'úsporný režim má méně snímků, tělo nemění barvu a kachna mluví méně'
Assert-True ($config.EcoModes.Contains($config.DefaultEco) -and $config.EcoModes[$config.DefaultEco] -eq 'Off') 'úsporný režim je ve výchozím stavu vypnutý'
Assert-True ($config.HeartbeatSec -ge 1 -and $config.AreaCheckSec -ge 5 -and $config.SleepCheckSec -ge 1) ("PowerShell se probouzí nejvýš 1x za sekundu, monitor kontroluje jen jako pojistku po {0} s" -f $config.AreaCheckSec)
Assert-True ($config.CrossMonitors -and $config.Costumes -and -not $config.Sound -and $config.Topmost) 'výchozí: chůze přes monitory a převleky zapnuté, zvuk vypnutý, vždy navrchu'
Assert-True ($config.SoftwareRendering -is [bool] -and $config.Priority -eq 'BelowNormal') 'nastavení vykreslování a priority procesu'
Assert-True ($v2Text.Contains("RenderOptions]::ProcessRenderMode = 'SoftwareOnly'") -and $v2Text.Contains('PriorityClass = $config.Priority')) 'skript nastavuje vykreslování bez GPU a nižší prioritu'

$duckPhrases = Get-AssignedValue $v2.Ast 'duckPhrases'
$duckPhrasesV1 = Get-AssignedValue $v1.Ast 'duckPhrases'
$missingV1 = @($duckPhrasesV1 | Where-Object { $duckPhrases -cnotcontains $_ })
$missingV1 | ForEach-Object { Write-Host "          chybí: $_" -ForegroundColor Red }
Assert-True ($missingV1.Count -eq 0) "v2 má všechny hlášky z v1 beze změny ($($duckPhrasesV1.Count) z v1, celkem $($duckPhrases.Count))"
$lists = [ordered]@{
    complaintPhrases = 'stížnosti'; resumePhrases = 'po pauze'; dropPhrases = 'po přistání'; restPhrases = 'odpočinek'
    showPhrases = 'po zobrazení'; welcomePhrases = 'po odemčení'; sleepPhrases = 'usínání'; wakePhrases = 'probuzení'
    hopPhrases = 'poskok'; crossPhrases = 'nový monitor'; foodPhrases = 'rohlík'; eatPhrases = 'jídlo'; followPhrases = 'za myší'
}
$allPhrases = New-Object System.Collections.Generic.List[string]
$allPhrases.AddRange([string[]]$duckPhrases)
foreach ($name in $lists.Keys) {
    $list = Get-AssignedValue $v2.Ast $name
    Set-Variable -Name $name -Value $list
    $allPhrases.AddRange([string[]]$list)
    Assert-True ($list.Count -ge 3 -and @($list | Sort-Object -Unique).Count -eq $list.Count) "hlášky '$($lists[$name])': aspoň 3, bez duplicit"
}
Assert-True ($complaintPhrases.Count -ge 10) "stížností je dost ($($complaintPhrases.Count))"
$reminderPhrases = Get-AssignedValue $v2.Ast 'reminderPhrases'
foreach ($k in 'Drink', 'Stretch', 'PomodoroStart', 'PomodoroBreak', 'PomodoroWork') {
    Assert-True ($reminderPhrases[$k].Count -ge 1) "připomínka '$k' má hlášky"
    $allPhrases.AddRange([string[]]$reminderPhrases[$k])
}
$situationPhrases = Get-AssignedValue $v2.Ast 'situationPhrases'
foreach ($k in $situationPhrases.Keys) {
    # zástupné {0} nahradit nejdelší možnou hodnotou
    $allPhrases.AddRange([string[]]@($situationPhrases[$k] | ForEach-Object { $_ -f '9999,9 km' }))
}
Assert-True (@($situationPhrases.Battery + $situationPhrases.Distance + $situationPhrases.Uptime | Where-Object { $_ -notmatch '\{0\}' }).Count -eq 0) 'hlášky o baterii, vzdálenosti a době mají místo pro číslo {0}'
# odhad: ~7,2 DIP na znak při FontSize 14, text široký 206 DIP; +20 znaků rezerva na dlouhé uživatelské jméno
$tooLong = @($allPhrases | Where-Object { [math]::Ceiling(($_.Length + 20) * 7.2 / 206) -gt 5 })
$tooLong | ForEach-Object { Write-Host "          příliš dlouhá: $_" -ForegroundColor Red }
Assert-True ($tooLong.Count -eq 0) "všechny hlášky se vejdou do bubliny (max 5 řádků, $($allPhrases.Count) hlášek)"

# ===========================================================================
# Funkce ze skriptu + náhradní objekty místo WPF, WinForms a Windows
# ===========================================================================
$functions = $v2.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($f in $functions) { . ([scriptblock]::Create($f.Extent.Text)) }
$menuSpec = Get-AssignedValue $v2.Ast 'menuSpec'

# ShownAt = kde okno bylo ve chvíli zobrazení (kachna se nemá objevit na staré pozici a pak skočit jinam)
$window = [pscustomobject]@{ Left = 0.0; Top = 0.0; Width = $winW; Height = $winH; IsVisible = $true; ShownAt = $null; Topmost = $true; Closed = $false }
$window | Add-Member -MemberType ScriptMethod -Name Hide -Value { $this.IsVisible = $false }
$window | Add-Member -MemberType ScriptMethod -Name Show -Value { $this.IsVisible = $true; $this.ShownAt = [pscustomobject]@{ Left = $this.Left; Top = $this.Top } }
$window | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Closed = $true }
$ui = @{
    SpeechText   = [pscustomobject]@{ Text = '' }
    SpeechBubble = [pscustomobject]@{ Visibility = 'Visible' }
    SpeechBorder = [pscustomobject]@{ Background = $null }
    RootFlip     = [pscustomobject]@{ ScaleX = 1 }
    TextFlip     = [pscustomobject]@{ ScaleX = 1 }
}
foreach ($n in 'circle12', 'circle14') { $ui[$n] = [pscustomobject]@{ Visibility = 'Visible' } }
$ui.SleepEye = [pscustomobject]@{ Visibility = 'Hidden' }
foreach ($n in 'CostumeSanta', 'CostumeWitch', 'CostumeGlasses') { $ui[$n] = [pscustomobject]@{ Visibility = 'Collapsed' } }
$bubbleBrushes = @{ Normal = 'bílá'; Reminder = 'modrá' }
$clock = [pscustomobject]@{ T = 0.0 }
$clock | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { [TimeSpan]::FromSeconds($this.T) }

function New-TimerMock {
    # Jako DispatcherTimer: Start u běžícího časovače nic nedělá, po tiku další za Interval.
    param([scriptblock]$OnTick)
    $timer = [pscustomobject]@{ Interval = [TimeSpan]::Zero; Running = $false; NextAt = 0.0; OnTick = $OnTick; Ticks = 0 }
    $timer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Running = $false }
    $timer | Add-Member -MemberType ScriptMethod -Name Start -Value {
        if (-not $this.Running) { $this.Running = $true; $this.NextAt = $clock.T + $this.Interval.TotalSeconds }
    }
    return $timer
}
function New-StoryboardMock {
    # Running = spuštěný (Begin) a nezastavený (Stop); Pause se nesmí používat (WPF by dál tikalo)
    $sb = [pscustomobject]@{ Running = $false; Paused = $false; Ratio = 1.0; Fps = 0; Begins = 0 }
    $sb | Add-Member -MemberType ScriptMethod -Name Begin -Value { $this.Running = $true; $this.Paused = $false; $this.Ratio = 1.0; $this.Begins++ }
    $sb | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Running = $false }
    $sb | Add-Member -MemberType ScriptMethod -Name Pause -Value { $this.Paused = $true }
    $sb | Add-Member -MemberType ScriptMethod -Name Resume -Value { $this.Paused = $false }
    $sb | Add-Member -MemberType ScriptMethod -Name SetSpeedRatio -Value { param($o, $r) $this.Ratio = $r }
    return $sb
}
$heartTimer = New-TimerMock { Invoke-Heartbeat }
$speechTimer = New-TimerMock { Invoke-SpeechTick }
$clickTimer = New-TimerMock { Invoke-Click }
$hideTimer = New-TimerMock { Invoke-HideTimer }
$timers = @($heartTimer, $speechTimer, $clickTimer, $hideTimer)
$legs = New-StoryboardMock
$glow = New-StoryboardMock

# Windows: monitory, myš, napájení, čas, zvuk, rohlík (stav, který by vrátily WinForms Screen, Cursor, PowerStatus ...)
$sim = @{
    WindowArea = $null; CursorArea = $null; CursorDip = $null; Layout = $null; Scale = 1.0; Cursor = '0,0'; Active = $true; Moves = 0
    Power = [pscustomobject]@{ OnBattery = $false; Percent = 100 }; Now = [datetime]'2026-03-11 10:00'
    Sounds = 0; Crumb = $null; Anims = @{}; AnimLog = (New-Object System.Collections.ArrayList)
}
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
function Get-AreaList { if ($sim.Layout) { $sim.Layout } else { @($sim.WindowArea) } }
function Get-DipScale { @($sim.Scale, $sim.Scale) }
function Get-CursorKey {
    # Active = uživatel pracuje (myš se hýbe), jinak kurzor stojí na $sim.Cursor
    if ($sim.Active) { $sim.Moves++; return "pohyb$($sim.Moves)" }
    return $sim.Cursor
}
function Get-PowerInfo { $sim.Power }
function Get-Now { $sim.Now }
function Start-Sound { $sim.Sounds++ }
function Show-Crumb {
    param([double]$X, [double]$Y, [double]$GroundY, [double]$Seconds, [int]$Fps)
    $sim.Crumb = [pscustomobject]@{ X = $X; Y = $Y; GroundY = $GroundY; Seconds = $Seconds; Fps = $Fps; Visible = $true }
}
function Hide-Crumb { if ($sim.Crumb) { $sim.Crumb.Visible = $false } }
function Set-FrameRate { param($Storyboard, [int]$Fps) $Storyboard.Fps = $Fps }

# Animace okna: stejné křivky jako WPF (DoubleAnimation, QuadraticEase), Completed volá Complete-Motion
function Start-WindowAnimation {
    param([string]$Property, [double]$From, [double]$To, [double]$Seconds, [int]$Fps, [string]$Ease = 'Linear')
    $state.MotionId++
    $anim = [pscustomobject]@{ Property = $Property; From = $From; To = $To; Seconds = $Seconds; Fps = $Fps; Ease = $Ease; Start = $clock.T; Id = $state.MotionId }
    $sim.Anims[$Property] = $anim
    [void]$sim.AnimLog.Add($anim)
    $window.$Property = $From
}
function Stop-WindowAnimation { $sim.Anims.Clear() }
function Get-AnimationValue {
    param($Anim, [double]$T)
    $p = if ($Anim.Seconds -le 0) { 1.0 } else { [math]::Min(1.0, [math]::Max(0.0, $T / $Anim.Seconds)) }
    if ($Anim.Ease -eq 'EaseIn') { $p = $p * $p }
    elseif ($Anim.Ease -eq 'EaseOut') { $p = 1 - (1 - $p) * (1 - $p) }
    return $Anim.From + ($Anim.To - $Anim.From) * $p
}

function Step-Sim {
    # Posune čas: nejdřív animace (hodnota podle křivky, po doběhnutí Completed), pak tiky časovačů.
    param([double]$Dt)
    $clock.T += $Dt
    foreach ($anim in @($sim.Anims.Values)) {
        if ($sim.Anims[$anim.Property] -ne $anim) { continue }
        $t = $clock.T - $anim.Start
        $window.($anim.Property) = Get-AnimationValue $anim $t
        if ($t -ge $anim.Seconds) {
            [void]$sim.Anims.Remove($anim.Property)
            if ($anim.Id -eq $state.MotionId) { Complete-Motion }
        }
    }
    foreach ($timer in $timers) {
        $guard = 0
        while ($timer.Running -and $clock.T -ge $timer.NextAt - 1e-9 -and $guard -lt 100) {
            $timer.NextAt += $timer.Interval.TotalSeconds
            $timer.Ticks++
            $guard++
            & $timer.OnTick
        }
    }
}

function Invoke-Sim {
    # Simuluje běh kachny. Track sbírá min/max pozice, otočky, odpočinek, zrcadlení a tempa.
    param([double]$Seconds, [double]$Step = 0.1)
    $track = @{ MinX = [double]::MaxValue; MaxX = [double]::MinValue; Turns = 0; Rested = $false; FlipOk = $true; SpeedFactors = @(); Texts = @() }
    $dir = $state.Direction
    $lastText = $ui.SpeechText.Text
    $n = [int][math]::Ceiling($Seconds / $Step)
    for ($i = 0; $i -lt $n; $i++) {
        Step-Sim $Step
        $track.MinX = [math]::Min($track.MinX, $window.Left)
        $track.MaxX = [math]::Max($track.MaxX, $window.Left)
        if ($state.Direction -ne $dir) { $track.Turns++; $dir = $state.Direction }
        if ($state.Resting) { $track.Rested = $true }
        if ($ui.RootFlip.ScaleX -ne $state.Direction -or $ui.TextFlip.ScaleX -ne $state.Direction) { $track.FlipOk = $false }
        $track.SpeedFactors += $state.SpeedFactor
        if ($ui.SpeechText.Text -ne $lastText) { $lastText = $ui.SpeechText.Text; $track.Texts += $lastText }
    }
    return $track
}

function Reset-Duck {
    # Čerstvá kachna na monitoru, jako po načtení okna (Loaded): okno vidět, chodí doprava, tep i hlášky běží.
    param($Area, [double]$Scale = 1.0)
    $clock.T = 0.0   # časovače i animace se nastavují znovu, hodiny můžou začít od nuly (doba běhu kachny)
    $sim.Anims.Clear(); $sim.AnimLog.Clear()
    foreach ($timer in $timers) { $timer.Running = $false; $timer.Ticks = 0 }
    foreach ($sb in $legs, $glow) { $sb.Running = $false; $sb.Paused = $false; $sb.Begins = 0 }
    $script:state = Get-AssignedValue $v2.Ast 'state'
    $state.RandomBehavior = $false
    $state.AnimReady = $true
    $sim.WindowArea = $Area; $sim.Layout = $null; $sim.Scale = $Scale; $sim.Cursor = '0,0'; $sim.Active = $true; $sim.Crumb = $null
    $sim.Power = [pscustomobject]@{ OnBattery = $false; Percent = 100 }
    $sim.Now = [datetime]'2026-03-11 10:00'
    $window.IsVisible = $true; $window.Topmost = $true
    $ui.SpeechBubble.Visibility = 'Visible'
    Set-EyesClosed $false
    Set-Area $Area
    $state.X = $state.MinX
    $state.Y = $state.GroundY
    Set-Direction 1
    Set-WindowPosition
    $now = $clock.T
    $state.LastActivity = $now
    $state.LastCursor = Get-CursorKey
    $state.NextDecision = $now + 5
    $state.NextAreaCheck = $now + $config.AreaCheckSec
    $state.NextPowerCheck = $now + $config.PowerCheckSec
    Update-Speed
    Update-Power
    Update-Costume
    Initialize-Reminder
    Show-Speech (Get-RandomPhrase $duckPhrases '')
    Update-Animation
    Restart-HeartTimer
    Restart-SpeechTimer
    Start-Walk
}

function New-Monitor {
    # Pracovní plocha i celý monitor v pixelech zařízení + měřítko (TransformFromDevice) -> DIP
    param([string]$Name, [double]$L, [double]$T, [double]$R, [double]$B, [double]$Scale, $Bounds = $null)
    $area = ConvertTo-DipRect -Left $L -Top $T -Right $R -Bottom $B -ScaleX $Scale -ScaleY $Scale
    if (-not $Bounds) { $Bounds = @($L, $T, $R, $B) }
    $area | Add-Member -NotePropertyName Bounds -NotePropertyValue (ConvertTo-DipRect -Left $Bounds[0] -Top $Bounds[1] -Right $Bounds[2] -Bottom $Bounds[3] -ScaleX $Scale -ScaleY $Scale)
    return [pscustomobject]@{ Name = $Name; Area = $area; Scale = $Scale }
}

function Test-OnGround {
    param($Area)
    return ([math]::Abs($window.Top + $window.Height - $Area.Bottom) -lt 0.001)
}

function Find-MenuItem {
    # Položka menu podle cesty popisků (po Update-MenuState), např. 'Nastavení', 'Zvuk (kvák)'.
    param($Items, [string[]]$Path, [switch]$Tray)
    $current = $null
    $level = $Items
    foreach ($text in $Path) {
        $current = $null
        foreach ($item in $level) {
            if ($null -eq $item.Tag) { continue }
            $label = if ($Tray) { $item.Text } else { $item.Header }
            if ($label -eq $text) { $current = $item; break }
        }
        if ($null -eq $current) { return $null }
        $level = if ($Tray) { $current.DropDownItems } else { $current.Items }
    }
    return $current
}

function New-MenuEntry {
    param($Tag, [bool]$Tray, [bool]$Clickable)
    if ($Tray) { return [pscustomobject]@{ Tag = $Tag; Text = ''; Checked = $false; DropDownItems = (New-Object System.Collections.ArrayList); Clickable = $Clickable } }
    return [pscustomobject]@{ Tag = $Tag; Header = ''; IsChecked = $false; Items = (New-Object System.Collections.ArrayList); Clickable = $Clickable; InputGestureText = '' }
}
function New-MenuSeparator { param([bool]$Tray) [pscustomobject]@{ Tag = $null; Tray = $Tray } }
$menuItems = New-Object System.Collections.ArrayList
$trayItems = New-Object System.Collections.ArrayList
Add-MenuEntry -Target $menuItems -Spec $menuSpec -Tray $false
Add-MenuEntry -Target $trayItems -Spec $menuSpec -Tray $true

function Invoke-Menu {
    # Klepnutí na položku menu (menu kachny, nebo s -Tray menu ikony).
    param([string[]]$Path, [switch]$Tray)
    $items = if ($Tray) { $trayItems } else { $menuItems }
    Update-MenuState -Items $items -Tray ([bool]$Tray)
    $item = Find-MenuItem -Items $items -Path $Path -Tray:$Tray
    if ($null -eq $item) { throw "Položka menu $($Path -join ' > ') nenalezena" }
    Invoke-MenuEntry $item.Tag
}

$monitors = @(
    (New-Monitor '1920x1080 @100 %, panel dole' 0 0 1920 1040 1.0 @(0, 0, 1920, 1080)),
    (New-Monitor '1920x1200 @100 %, vpravo od hlavního' 1920 0 3840 1200 1.0),
    (New-Monitor '2560x1440 (2K) @125 %, vlevo, panel vlevo' -2498 -360 0 1080 0.8 @(-2560, -360, 0, 1080)),
    (New-Monitor '3840x2160 (4K) @150 %, panel dole' 0 0 3840 2112 (1 / 1.5) @(0, 0, 3840, 2160)),
    (New-Monitor '3840x2160 (4K) @200 %, vlevo, panel nahoře' -3840 60 0 2160 0.5 @(-3840, 0, 0, 2160))
)
$main = $monitors[0].Area
$right = $monitors[1].Area

# ===========================================================================
Write-Section 'Čisté funkce'
# ===========================================================================
Assert-True ((Get-Clamped -Value 5 -Min 0 -Max 10) -eq 5 -and (Get-Clamped -Value -5 -Min 0 -Max 10) -eq 0 -and (Get-Clamped -Value 50 -Min 0 -Max 10) -eq 10) 'Get-Clamped omezí hodnotu do intervalu'
Assert-True ((Get-Clamped -Value 5 -Min 10 -Max 0) -eq 10) 'Get-Clamped zvládne Max < Min'
$r = ConvertTo-DipRect -Left 0 -Top 0 -Right 3840 -Bottom 2160 -ScaleX (1 / 1.5) -ScaleY (1 / 1.5)
Assert-True ([math]::Abs($r.Right - 2560) -lt 0.01 -and [math]::Abs($r.Bottom - 1440) -lt 0.01) 'ConvertTo-DipRect: 4K při 150 % = 2560 x 1440 DIP'
Assert-True ((Test-SameArea $main $main) -and -not (Test-SameArea $main $right) -and -not (Test-SameArea $main $null)) 'Test-SameArea porovná plochy monitorů'
$r = Get-FallPlan -Y 0 -GroundY 1000 -Gravity 3000 -RiseSpeed 800
Assert-True ([math]::Abs($r.Seconds - [math]::Sqrt(2 * 1000 / 3000)) -lt 1e-9 -and $r.Ease -eq 'EaseIn') ("Get-FallPlan: volný pád z 1000 DIP trvá {0:N3} s, kvadratická křivka" -f $r.Seconds)
$r = Get-FallPlan -Y 1100 -GroundY 1000 -Gravity 3000 -RiseSpeed 800
Assert-True ([math]::Abs($r.Seconds - 0.125) -lt 1e-9 -and $r.Ease -eq 'Linear') 'Get-FallPlan: pod zemí se rovnoměrně vynoří'
Assert-True ((Get-FallPlan -Y 500 -GroundY 500 -Gravity 3000 -RiseSpeed 800).Seconds -eq 0) 'Get-FallPlan: na zemi nepadá'
Assert-True ((Get-WalkFrameRate -Speed 15 -PxPerDip 1 -Min 8 -Max 30) -eq 15 -and (Get-WalkFrameRate -Speed 15 -PxPerDip 2 -Min 8 -Max 30) -eq 30) 'Get-WalkFrameRate: 1 pixel na snímek (15 DIP/s: 15 snímků při 100 %, 30 při 200 %)'
Assert-True ((Get-WalkFrameRate -Speed 4 -PxPerDip 1 -Min 8 -Max 30) -eq 8 -and (Get-WalkFrameRate -Speed 56 -PxPerDip 1 -Min 8 -Max 30) -eq 30) 'Get-WalkFrameRate: v mezích Min..Max'
$sideBySide = @($main, $right)
Assert-True ((Find-NeighborArea -Current $main -Areas $sideBySide -Direction 1 -Top 682 -Height 358) -eq $right) 'Find-NeighborArea: najde monitor vpravo'
Assert-True ($null -eq (Find-NeighborArea -Current $main -Areas $sideBySide -Direction -1 -Top 682 -Height 358)) 'Find-NeighborArea: vlevo nic není'
Assert-True ((Find-NeighborArea -Current $right -Areas $sideBySide -Direction -1 -Top 842 -Height 358) -eq $main) 'Find-NeighborArea: z pravého monitoru zpět na hlavní'
$panelRight = (New-Monitor 'panel vpravo' 0 0 1880 1080 1.0 @(0, 0, 1920, 1080)).Area
Assert-True ((Find-NeighborArea -Current $panelRight -Areas @($panelRight, $right) -Direction 1 -Top 722 -Height 358) -eq $right) 'Find-NeighborArea: hlavní panel mezi monitory nevadí (hrany celých monitorů)'
$high = (New-Monitor 'vysoko vpravo' 1920 -1500 3840 -300 1.0).Area
Assert-True ($null -eq (Find-NeighborArea -Current $main -Areas @($main, $high) -Direction 1 -Top 682 -Height 358)) 'Find-NeighborArea: monitor mimo výšku kachny se nepočítá'
$belowMain = (New-Monitor 'pod hlavním' 0 1080 1920 2120 1.0).Area
Assert-True ($null -eq (Find-NeighborArea -Current $main -Areas @($main, $belowMain) -Direction 1 -Top 682 -Height 358)) 'Find-NeighborArea: monitor pod hlavním není soused do strany'
$last = ''; $repeat = $false
for ($i = 0; $i -lt 500; $i++) { $p = Get-RandomPhrase $duckPhrases $last; if ($p -eq $last) { $repeat = $true }; $last = $p }
Assert-True (-not $repeat) 'Get-RandomPhrase: stejná hláška nikdy dvakrát po sobě (500 pokusů)'
Assert-True ((Get-RandomPhrase @('jen jedna') 'jen jedna') -eq 'jen jedna') 'Get-RandomPhrase: zvládne seznam s jedinou hláškou'
Assert-True ((Get-RandomAction 0) -eq 'Turn' -and (Get-RandomAction 20) -eq 'Rest' -and (Get-RandomAction 99) -eq 'Stroll') 'Get-RandomAction: rozdělení otočení / odpočinek / tempo'
Assert-True ((Format-Decimal 12.345) -eq '12,3' -and (Format-Decimal 2) -eq '2') 'Format-Decimal: desetinná čárka'
Assert-True ((Get-DistanceText 96) -eq '3 cm' -and (Get-DistanceText (96 / 2.54 * 1430)) -eq '14,3 m' -and (Get-DistanceText (96 / 2.54 * 250000)) -eq '2,5 km') 'Get-DistanceText: cm, m, km (DIP = 1/96 palce)'
Assert-True ((Get-DurationText 45) -eq '45 min' -and (Get-DurationText 120) -eq '2 h' -and (Get-DurationText 135.7) -eq '2 h 15 min') 'Get-DurationText: 45 min, 2 h, 2 h 15 min'
Assert-True ((Get-EasterSunday 2024).ToString('yyyy-MM-dd') -eq '2024-03-31' -and (Get-EasterSunday 2025).ToString('yyyy-MM-dd') -eq '2025-04-20' -and (Get-EasterSunday 2026).ToString('yyyy-MM-dd') -eq '2026-04-05') 'Get-EasterSunday: Velikonoce 2024, 2025, 2026'
$keys = @(Get-SituationKey ([datetime]'2026-03-09 07:30'))
Assert-True ($keys -contains 'Morning' -and $keys -contains 'Monday') "pondělí 7:30: $($keys -join ', ')"
$keys = @(Get-SituationKey ([datetime]'2026-03-13 14:30'))
Assert-True ($keys -contains 'Afternoon' -and $keys -contains 'Friday') "pátek 14:30: $($keys -join ', ')"
$keys = @(Get-SituationKey ([datetime]'2026-12-24 19:00'))
Assert-True ($keys -contains 'Evening' -and $keys -contains 'Christmas') "Štědrý večer: $($keys -join ', ')"
$keys = @(Get-SituationKey ([datetime]'2026-04-03 10:00'))
Assert-True ($keys -contains 'Easter' -and $keys -notcontains 'Friday') "Velký pátek dopoledne: $($keys -join ', ')"
Assert-True ((@(Get-SituationKey ([datetime]'2026-10-28 10:00')) -contains 'Republic') -and (@(Get-SituationKey ([datetime]'2026-12-10 10:00')) -contains 'Advent') -and (@(Get-SituationKey ([datetime]'2026-07-06 10:00')) -contains 'Holiday')) 'svátky: 28. října, advent, státní svátek'
Assert-True (@(Get-SituationKey ([datetime]'2026-03-11 10:00')).Count -eq 0) 'obyčejná středa v 10:00: žádná situační hláška'
$power = [pscustomobject]@{ OnBattery = $true; Percent = 15 }
$phrases = @(Get-SituationPhrase -Now ([datetime]'2026-03-11 10:00') -Power $power -DistanceDip (96 / 2.54 * 1430) -UptimeMin 135)
Assert-True (@($phrases | Where-Object { $_ -match '15 %' }).Count -ge 1) 'slabá baterie: hláška s procenty'
Assert-True (@($phrases | Where-Object { $_ -match '14,3 m' }).Count -ge 1 -and @($phrases | Where-Object { $_ -match '2 h 15 min' }).Count -ge 1) 'hlášky s ušlou vzdáleností a dobou běhu'
$phrases = @(Get-SituationPhrase -Now ([datetime]'2026-03-11 10:00') -Power ([pscustomobject]@{ OnBattery = $false; Percent = 15 }) -DistanceDip 100 -UptimeMin 10)
Assert-True ($phrases.Count -eq 0) 'na síti, krátká chůze a krátký běh: žádné situační hlášky'
Assert-True ((Get-Costume ([datetime]'2026-12-24')) -eq 'Santa' -and (Get-Costume ([datetime]'2027-01-05')) -eq 'Santa' -and (Get-Costume ([datetime]'2027-01-07')) -eq '') 'Get-Costume: čepice od prosince do Tří králů'
Assert-True ((Get-Costume ([datetime]'2026-10-30')) -eq 'Witch' -and (Get-Costume ([datetime]'2026-07-15')) -eq 'Glasses' -and (Get-Costume ([datetime]'2026-03-01')) -eq '') 'Get-Costume: klobouk na Halloween, brýle v létě, jinak nic'
$wave = New-QuackWave
$riff = [System.Text.Encoding]::ASCII.GetString($wave, 0, 4) + [System.Text.Encoding]::ASCII.GetString($wave, 8, 4)
Assert-True ($wave -is [byte[]] -and $riff -eq 'RIFFWAVE' -and [BitConverter]::ToInt32($wave, 24) -eq 22050 -and $wave.Length -eq 44 + 2 * [int](22050 * 0.22)) ("New-QuackWave: WAV 22 kHz, {0} bajtů" -f $wave.Length)

# ===========================================================================
Write-Section 'Chůze na různých monitorech (rozlišení i škálování)'
# ===========================================================================
foreach ($m in $monitors) {
    Reset-Duck $m.Area $m.Scale
    Set-Speed 'Rychlá'
    $a = $m.Area
    $t = Invoke-Sim -Seconds 250 -Step 0.2
    $inside = $t.MinX -ge $a.Left - 0.001 -and ($t.MaxX + $window.Width) -le $a.Right + 0.001
    $edges = [math]::Abs($t.MinX - $a.Left) -lt 0.001 -and [math]::Abs($t.MaxX + $window.Width - $a.Right) -lt 0.001
    $ground = (Test-OnGround $a) -and $window.Top -ge $a.Top
    Assert-True ($inside -and $edges -and $ground -and $t.Turns -ge 2 -and $t.FlipOk) ("{0}: plocha {1:N0}x{2:N0} DIP, chodí od okraje k okraji ({3} otoček), stojí na spodním okraji" -f $m.Name, ($a.Right - $a.Left), ($a.Bottom - $a.Top), $t.Turns)
}
foreach ($case in @(@{ Scale = 1.0; Fps = 15 }, @{ Scale = 0.8; Fps = 19 }, @{ Scale = 0.5; Fps = 30 })) {
    Reset-Duck $main $case.Scale
    $walk = $sim.Anims['Left']
    Assert-True ($null -ne $walk -and $walk.Fps -eq $case.Fps) ("chůze při {0:N0} %: {1} snímků/s (1 pixel na snímek)" -f (100 / $case.Scale), $walk.Fps)
}

# ===========================================================================
Write-Section 'Šetření procesorem: snímky, tep, pauza'
# ===========================================================================
Reset-Duck $main
$walk = $sim.Anims['Left']
Assert-True ($null -ne $walk -and $walk.Ease -eq 'Linear' -and $walk.To -eq $main.Right - $window.Width -and [math]::Abs($walk.Seconds - ($walk.To - $walk.From) / 15) -lt 1e-9) ("chůze je jedna animace WPF až k okraji ({0:N0} s), ne krok po kroku" -f $walk.Seconds)
Assert-True ($legs.Running -and $legs.Fps -eq $config.Fps.Legs -and $glow.Running -and $glow.Fps -eq $config.Fps.Glow) ("nohy {0} snímků/s, tělo {1} snímků/s" -f $legs.Fps, $glow.Fps)
Assert-True ($heartTimer.Running -and $heartTimer.Interval.TotalSeconds -eq 1) 'PowerShell se při chůzi probouzí jen 1x za sekundu (tep)'
[void](Invoke-Sim -Seconds 60)
Assert-True ($sim.AnimLog.Count -le 2 -and $heartTimer.Ticks -le 61) ("za minutu chůze: {0} animace, {1} tepů (dřív ~2000 tiků časovače pohybu)" -f $sim.AnimLog.Count, $heartTimer.Ticks)
Assert-True (-not $legs.Paused -and -not $glow.Paused) 'storyboardy se nikdy nepozastavují (Pause), jen zastavují (Stop)'
Set-Paused $true
Assert-True ($sim.Anims.Count -eq 0 -and $state.Motion -eq 'None') 'pauza: okno se nehýbe, žádná animace polohy'
Assert-True (-not $legs.Running -and -not $legs.Paused -and -not $glow.Running) 'pauza: nohy i tělo zastavené přes Stop (WPF netiká)'
Assert-True ($heartTimer.Interval.TotalSeconds -eq 1 -and -not $clickTimer.Running) 'pauza: zůstává jen tep 1x za sekundu a hlášky jednou za minutu'
Set-Paused $false
Assert-True ($legs.Running -and [math]::Abs($legs.Ratio - 1.0) -lt 0.001 -and $glow.Running -and $null -ne $sim.Anims['Left']) 'po pauze: nohy kmitají jako ve v1, tělo mění barvu, kachna jde'
$state.SpeedFactor = 1.0
$state.RandomBehavior = $true
$state.NextDecision = $clock.T
$null = Get-Random -SetSeed 3
$rested = $false
for ($i = 0; $i -lt 40 -and -not $rested; $i++) {
    $state.NextDecision = $clock.T
    Step-Sim 1.0
    if ($state.Resting) { $rested = $true }
}
Assert-True ($rested -and -not $legs.Running -and $sim.Anims.Count -eq 0 -and $glow.Running) 'odpočinek: kachna stojí a nohy se zastaví, tělo dál mění barvu'
$state.RandomBehavior = $false

Reset-Duck $main
Set-EcoMode 'Vždy'
$walk = $sim.Anims['Left']
Assert-True ($state.EcoActive -and $legs.Fps -eq $config.EcoFps.Legs -and -not $glow.Running -and $walk.Fps -le $config.EcoFps.WalkMax) ("úsporný režim: nohy {0} snímků/s, tělo stojí, chůze {1} snímků/s" -f $legs.Fps, $walk.Fps)
Assert-True ($speechTimer.Interval.TotalSeconds -eq $config.PhraseSpeeds[$config.DefaultPhraseSpeed] * $config.EcoPhraseFactor) "úsporný režim: hlášky každých $($speechTimer.Interval.TotalSeconds) s"
Set-EcoMode 'Vypnutý'
Assert-True (-not $state.EcoActive -and $legs.Fps -eq $config.Fps.Legs -and $glow.Running -and $sim.Anims['Left'].Fps -eq 15) 'úsporný režim vypnutý: zpět plné snímky'
Set-EcoMode 'Na baterii'
$sim.Power = [pscustomobject]@{ OnBattery = $true; Percent = 60 }
Update-Power
Assert-True ($state.EcoActive -and -not $glow.Running) 'na baterii se úsporný režim zapne sám'
$sim.Power = [pscustomobject]@{ OnBattery = $false; Percent = 60 }
Update-Power
Assert-True (-not $state.EcoActive -and $glow.Running) 'po připojení nabíječky se vypne'
$sim.Power = [pscustomobject]@{ OnBattery = $true; Percent = 60 }
$state.NextPowerCheck = $clock.T
Step-Sim 1.0
Assert-True $state.EcoActive 'napájení se ověří i bez události (pojistka jednou za minutu)'

# ===========================================================================
Write-Section 'Pauza, klepnutí, dvojklik a stížnosti'
# ===========================================================================
Reset-Duck $main
[void](Invoke-Sim -Seconds 5)
$xBefore = $window.Left
Set-Paused $true
Assert-True ($ui.SpeechText.Text -in $complaintPhrases) "po zapauzování si hned stěžuje: '$($ui.SpeechText.Text)'"
Assert-True ($speechTimer.Interval.TotalSeconds -eq 60 -and $speechTimer.Running) 'další stížnost za 60 s'
[void](Invoke-Sim -Seconds 30)
Assert-True ($window.Left -eq $xBefore -and $state.X -eq $xBefore) 'v pauze se kachna nehýbe'
$first = $ui.SpeechText.Text
Invoke-SpeechTick
Assert-True ($ui.SpeechText.Text -in $complaintPhrases -and $ui.SpeechText.Text -ne $first) 'po minutě přijde jiná stížnost (žádné běžné hlášky)'
Set-Paused $false
$normalInterval = $config.PhraseSpeeds[$config.DefaultPhraseSpeed]
Assert-True ($ui.SpeechText.Text -in $resumePhrases -and $speechTimer.Interval.TotalSeconds -eq $normalInterval) "po zrušení pauzy poděkuje a mluví zase každých $normalInterval s"
[void](Invoke-Sim -Seconds 5)
Assert-True ($window.Left -gt $xBefore) 'po zrušení pauzy jde dál'
$null = Get-Random -SetSeed 1
Invoke-SpeechTick
Assert-True ($ui.SpeechText.Text -in $duckPhrases) 'při chůzi říká běžné hlášky'

# Klepnutí = DragMove skoro bez pohybu; pauza se přepne až po době dvojkliku
Start-Drag
Assert-True ($sim.Anims.Count -eq 0 -and $legs.Ratio -eq 4.0) 'stisk tlačítka: pohyb se zastaví, nohy kmitají rychle'
$window.Left += 2
Complete-Drag -StartLeft ($window.Left - 2) -StartTop $window.Top
Assert-True (-not $state.Paused -and $clickTimer.Running -and $window.Left -eq $state.X) 'klepnutí (posun 2 DIP): okno zpět na místo, pauza čeká na případný dvojklik'
Step-Sim 0.6
Assert-True ($state.Paused -and -not $clickTimer.Running -and $sim.Anims.Count -eq 0) 'po době dvojkliku se kachna zapauzuje'
Start-Drag
Complete-Drag -StartLeft $window.Left -StartTop $window.Top
Step-Sim 0.6
Assert-True (-not $state.Paused -and $null -ne $sim.Anims['Left']) 'další klepnutí kachnu rozběhne'

# Dvojklik: první klepnutí spustí čekání, druhé (ClickCount 2) místo pauzy poskočí
$ground = $state.GroundY
Start-Drag
Complete-Drag -StartLeft $window.Left -StartTop $window.Top
Step-Sim 0.2
$clickTimer.Stop(); Start-Hop        # totéž dělá obsluha MouseLeftButtonDown při ClickCount 2
Assert-True ($state.Motion -eq 'HopUp' -and $ui.SpeechText.Text -in $hopPhrases -and $legs.Ratio -eq 4.0) "dvojklik: poskok ('$($ui.SpeechText.Text)')"
$minTop = $window.Top
for ($i = 0; $i -lt 10; $i++) { Step-Sim 0.05; $minTop = [math]::Min($minTop, $window.Top) }
Assert-True ([math]::Abs($minTop - ($ground - $config.HopHeight)) -lt 1 -and [math]::Abs($window.Top - $ground) -lt 0.001 -and -not $state.Falling) ("poskok do výšky {0:N0} DIP a zpět na zem za 0,5 s" -f ($ground - $minTop))
Step-Sim 1.0
Assert-True (-not $state.Paused -and $ui.SpeechText.Text -in $hopPhrases -and $null -ne $sim.Anims['Left']) 'po dvojkliku kachna není zapauzovaná, po dopadu nic dalšího neříká a jde dál'
Set-Paused $true
Start-Hop
[void](Invoke-Sim -Seconds 1)
Assert-True ($state.Paused -and (Test-OnGround $main) -and $sim.Anims.Count -eq 0) 'poskok v pauze: dopadne a stojí dál'
Set-Paused $false

# ===========================================================================
Write-Section 'Přetažení na jiný monitor a pád'
# ===========================================================================
Reset-Duck $main
$state.CrossMonitors = $false
$sim.Layout = @($main, $right)
Start-Drag
[void](Invoke-Sim -Seconds 2)
Assert-True ($window.Left -eq $main.Left -and $sim.Anims.Count -eq 0) 'během tažení s oknem nic nehýbe (DragMove ho přesouvá sám)'
# uživatel pustí kachnu na pravém monitoru vysoko nahoře
$window.Left = 2500; $window.Top = 100
$sim.CursorArea = $right
Complete-Drag -StartLeft 0 -StartTop 682
$fall = $sim.Anims['Top']
$expected = [math]::Sqrt(2 * ($right.Bottom - $window.Height - 100) / $config.Gravity)
Assert-True ($state.Falling -and $legs.Ratio -eq 4.0 -and $fall.Ease -eq 'EaseIn' -and [math]::Abs($fall.Seconds - $expected) -lt 1e-9) ("po puštění padá volným pádem ({0:N2} s) a nohy kmitají rychle" -f $fall.Seconds)
Assert-True ($fall.Fps -eq $config.Fps.Fall) "pád má $($fall.Fps) snímků/s"
$fallTime = 0.0
while ($state.Falling -and $fallTime -lt 5) { Step-Sim 0.05; $fallTime += 0.05 }
Assert-True (-not $state.Falling -and $fallTime -lt 1.5) ("dopadla za {0:N2} s" -f $fallTime)
Assert-True ((Test-OnGround $right) -and $window.Left -eq 2500) 'stojí na spodním okraji monitoru, kam byla puštěna'
Assert-True ($ui.SpeechText.Text -in $dropPhrases) "po přistání něco řekne: '$($ui.SpeechText.Text)'"
$t = Invoke-Sim -Seconds 120
Assert-True ($t.MinX -ge $right.Left -and $t.MaxX + $window.Width -le $right.Right) 'pak chodí jen po novém monitoru (chůze přes monitory vypnutá)'

# Monitory nad sebou: kurzor už je na spodním monitoru, okno ale leží většinou na horním
$below = (New-Monitor '1920x1080 pod hlavním' 0 1080 1920 2120 1.0).Area
Reset-Duck $main
$sim.Layout = @($main, $below)
Start-Drag
$window.Left = 300; $window.Top = 750
$sim.CursorArea = $below
Complete-Drag -StartLeft 0 -StartTop 682
[void](Invoke-Sim -Seconds 2)
Assert-True (Test-OnGround $below) 'monitory nad sebou: spadne na monitor pod kurzorem, ne na ten s větším překryvem'
[void](Invoke-Sim -Seconds 30)
Assert-True (Test-OnGround $below) 'monitory nad sebou: zůstane na spodním monitoru'

# Puštění částečně mimo plochu a pod spodní okraj (nad hlavním panelem)
Reset-Duck $main
Start-Drag
$window.Left = 1900; $window.Top = 1000
$sim.CursorArea = $main
Complete-Drag -StartLeft 0 -StartTop 682
Assert-True ($state.X -eq $main.Right - $window.Width -and $sim.Anims['Top'].Ease -eq 'Linear') 'puštění přes okraj: kachna se posune celá na monitor a vynořuje se rovnoměrně'
[void](Invoke-Sim -Seconds 1)
Assert-True (-not $state.Falling -and (Test-OnGround $main)) 'puštění pod spodní okraj: vynoří se na zem'

# Puštění v pauze
Reset-Duck $main
Set-Paused $true
$complaint = $ui.SpeechText.Text
Start-Drag
$window.Left = 800; $window.Top = 50
Complete-Drag -StartLeft 0 -StartTop 682
[void](Invoke-Sim -Seconds 2)
$xLanded = $window.Left
[void](Invoke-Sim -Seconds 10)
Assert-True ($state.Paused -and $ui.SpeechText.Text -eq $complaint -and $window.Left -eq $xLanded -and (Test-OnGround $main)) 'v pauze po přistání zůstane stát a ukazuje stížnost'
Set-Paused $false

# Klepnutí během pádu: pád pokračuje
Reset-Duck $main
$sim.CursorArea = $main
Start-Drag
$window.Left = 800; $window.Top = 50
Complete-Drag -StartLeft 0 -StartTop 682
Step-Sim 0.2
Start-Drag
Complete-Drag -StartLeft $window.Left -StartTop $window.Top
Assert-True ($state.Falling -and $sim.Anims['Top'].From -gt 50) 'klepnutí během pádu: kachna padá dál z místa, kde byla'
[void](Invoke-Sim -Seconds 2)
Assert-True (-not $state.Falling -and (Test-OnGround $main) -and $state.Paused) 'po klepnutí dopadne a zapauzuje se'
Set-Paused $false

# Přivolání z ikony v oznamovací oblasti
Reset-Duck $main
$state.CrossMonitors = $false
$sim.Layout = @($main, $right)
$sim.CursorArea = $right
$sim.CursorDip = [pscustomobject]@{ X = 3000; Y = 1150 }
Invoke-Summon
Assert-True ($state.Falling -and $window.Top -eq $right.Top -and $window.Left -eq 3000 - $window.Width / 2) 'přivolání: objeví se nahoře nad kurzorem na jeho monitoru'
[void](Invoke-Sim -Seconds 2)
Assert-True (Test-OnGround $right) 'přivolání: spadne na spodní okraj'
$t = Invoke-Sim -Seconds 30
Assert-True ($t.MinX -ge $right.Left -and (Test-OnGround $right)) 'přivolání: pak chodí po monitoru s kurzorem'

# ===========================================================================
Write-Section 'Změna monitorů za běhu'
# ===========================================================================
Reset-Duck $right
Stop-Motion
$state.X = 3500; Set-WindowPosition
Start-Walk
# monitor odpojen -> Windows hlásí nejbližší monitor (hlavní) a pošle událost DisplaySettingsChanged
$sim.WindowArea = $main
Request-AreaUpdate
Assert-True ($window.Left -ge $main.Left -and $window.Left + $window.Width -le $main.Right -and (Test-OnGround $main) -and $null -ne $sim.Anims['Left']) 'odpojení monitoru (událost Windows): kachna je hned na zbylém monitoru a jde dál'
# změna rozlišení bez události: pojistná kontrola do AreaCheckSec
$small = (New-Monitor '1280x720' 0 0 1280 680 1.0).Area
$sim.WindowArea = $small
[void](Invoke-Sim -Seconds ($config.AreaCheckSec + 1))
Assert-True ($window.Left + $window.Width -le $small.Right + 0.001 -and (Test-OnGround $small)) "snížení rozlišení bez události: kachna je na obrazovce do $($config.AreaCheckSec + 1) s (pojistka)"
# jiné škálování (DPI): chůze dostane jiný počet snímků
$sim.Scale = 0.5
Request-AreaUpdate
Assert-True ($state.PxPerDip -eq 2 -and $sim.Anims['Left'].Fps -eq 30) 'změna škálování na 200 %: chůze 30 snímků/s'
# událost bez změny nic nepřeruší
$sim.Scale = 1.0
Request-AreaUpdate
$count = $sim.AnimLog.Count
Request-AreaUpdate
Assert-True ($sim.AnimLog.Count -eq $count) 'událost Windows beze změny plochy rozpracovanou chůzi nepřeruší'

# ===========================================================================
Write-Section 'Chůze přes monitory'
# ===========================================================================
Reset-Duck $main
$sim.Layout = @($main, $right)
Stop-Motion
$state.X = $state.MaxX - 30; Set-WindowPosition
Start-Walk
$t = Invoke-Sim -Seconds 30 -Step 0.1
Assert-True ((Test-SameArea $state.Area $right) -and (Test-OnGround $right) -and $state.Direction -eq 1) 'na okraji navazuje monitor: kachna na něj přejde a dopadne na jeho zem'
Assert-True (@($t.Texts | Where-Object { $_ -in $crossPhrases }).Count -ge 1) 'po přechodu se ozve'
Assert-True ($t.Turns -eq 0 -and $window.Left -gt $right.Left) 'neotočila se a jde dál po novém monitoru'
$t = Invoke-Sim -Seconds 200
Assert-True ($t.Turns -ge 1 -and $t.MaxX + $window.Width -le $right.Right + 0.001) 'na vnějším okraji, kde nic nenavazuje, se otočí'
Stop-Motion
$state.Direction = -1; Set-Direction -1
$state.X = $state.MinX + 10; Set-WindowPosition
Start-Walk
[void](Invoke-Sim -Seconds 40)
Assert-True ((Test-SameArea $state.Area $main) -and (Test-OnGround $main)) 'přejde i zpět doleva (vynoří se na nižší zem hlavního monitoru)'

# Hlavní panel mezi monitory (vpravo na hlavním) nevadí
$mainPanelRight = (New-Monitor 'hlavní, panel vpravo' 0 0 1880 1080 1.0 @(0, 0, 1920, 1080)).Area
Reset-Duck $mainPanelRight
$sim.Layout = @($mainPanelRight, $right)
Stop-Motion; $state.X = $state.MaxX - 10; Set-WindowPosition; Start-Walk
[void](Invoke-Sim -Seconds 30)
Assert-True ((Test-SameArea $state.Area $right)) 'hlavní panel mezi monitory nevadí'

# Pauza uprostřed přechodu
Reset-Duck $main
$sim.Layout = @($main, $right)
Stop-Motion; $state.X = $state.MaxX - 5; Set-WindowPosition; Start-Walk
[void](Invoke-Sim -Seconds 5)
Assert-True $state.Crossing 'kachna je uprostřed přechodu'
Set-Paused $true
$xPaused = $window.Left
[void](Invoke-Sim -Seconds 10)
Assert-True ($window.Left -eq $xPaused -and $state.Crossing) 'pauza uprostřed přechodu: stojí na hranici monitorů (pojistná kontrola ji nepřesune)'
Set-Paused $false
[void](Invoke-Sim -Seconds 30)
Assert-True (-not $state.Crossing -and (Test-SameArea $state.Area $right) -and (Test-OnGround $right)) 'po pauze přechod dokončí'

# Vypnuto v menu, monitor vysoko nebo pod hlavním: otočí se
Reset-Duck $main
$sim.Layout = @($main, $right)
Invoke-Menu 'Nastavení', 'Chůze přes monitory'
Assert-True (-not $state.CrossMonitors) 'menu: chůze přes monitory jde vypnout'
Stop-Motion; $state.X = $state.MaxX - 10; Set-WindowPosition; Start-Walk
$t = Invoke-Sim -Seconds 30
Assert-True ((Test-SameArea $state.Area $main) -and $t.Turns -ge 1 -and $t.MaxX + $window.Width -le $main.Right + 0.001) 'vypnutá chůze přes monitory: na okraji se otočí'
foreach ($case in @(@{ N = 'monitor vysoko nad kachnou'; A = $high }, @{ N = 'monitor pod hlavním'; A = $belowMain })) {
    Reset-Duck $main
    $sim.Layout = @($main, $case.A)
    Stop-Motion; $state.X = $state.MaxX - 10; Set-WindowPosition; Start-Walk
    $t = Invoke-Sim -Seconds 30
    Assert-True ((Test-SameArea $state.Area $main) -and $t.Turns -ge 1) "$($case.N): kachna se otočí"
}

# ===========================================================================
Write-Section 'Náhodné chování a rychlost'
# ===========================================================================
$null = Get-Random -SetSeed 42
Reset-Duck $main
Set-RandomBehavior $true
$t = Invoke-Sim -Seconds 600 -Step 0.2
$factors = @($t.SpeedFactors | Sort-Object -Unique)
Assert-True $t.Rested 'kachna si občas sama odpočine'
Assert-True ($factors.Count -gt 2 -and ($factors | Measure-Object -Minimum).Minimum -ge 0.6 -and ($factors | Measure-Object -Maximum).Maximum -le 1.6) "mění tempo v rozmezí 0,6-1,6x ($($factors.Count) různých)"
Assert-True ($t.MinX -ge $main.Left -and $t.MaxX + $window.Width -le $main.Right + 0.001 -and $t.FlipOk) 'i při náhodném chování zůstává na monitoru a otáčí se celá'
Set-RandomBehavior $false
Assert-True ($state.SpeedFactor -eq 1.0 -and -not $state.Resting -and $state.Speed -eq 15) 'vypnutí náhodného chování vrátí normální tempo'
Set-Speed 'Rychlá'
$walk = $sim.Anims['Left']
Assert-True ($state.SpeedName -eq 'Rychlá' -and $state.Speed -eq $config.Speeds['Rychlá'] -and [math]::Abs(($walk.To - $walk.From) / $walk.Seconds - 35) -lt 1e-6) 'změna rychlosti z menu: chůze hned pokračuje novou rychlostí'
Set-Speed 'Neexistuje'
Assert-True ($state.SpeedName -eq 'Rychlá') 'neznámá rychlost se ignoruje'

# ===========================================================================
Write-Section 'Rychlost hlášek'
# ===========================================================================
Reset-Duck $main
Assert-True ($state.PhraseSpeedName -eq $config.DefaultPhraseSpeed -and $speechTimer.Running -and $speechTimer.Interval.TotalSeconds -eq $normalInterval) "po startu mluví každých $normalInterval s ($($config.DefaultPhraseSpeed))"
foreach ($name in $config.PhraseSpeeds.Keys) {
    Invoke-Menu 'Rychlost hlášek', $name
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
Invoke-Menu 'Rychlost chůze', 'Rychlá'
Assert-True ($state.SpeedName -eq 'Rychlá' -and $state.PhraseSpeedName -eq 'Pomalá') 'rychlost chůze a rychlost hlášek se nastavují nezávisle'

# ===========================================================================
Write-Section 'Bublina a tichý režim'
# ===========================================================================
Reset-Duck $main
Show-Phrase $dropPhrases
Assert-True ($ui.SpeechBubble.Visibility -eq 'Visible' -and $ui.SpeechBorder.Background -eq 'bílá') 'nová hláška: bílá bublina je vidět'
[void](Invoke-Sim -Seconds ($config.BubbleSec + 1.1))
Assert-True ($ui.SpeechBubble.Visibility -eq 'Hidden') "bublina po $($config.BubbleSec) s zmizí (průhledné okno pak nepřekáží)"
Show-Phrase $dropPhrases
Step-Sim 0.5
Hide-BubbleForHover
Assert-True ($ui.SpeechBubble.Visibility -eq 'Hidden') 'najetí myší na bublinu: bublina se schová'
[void](Invoke-Sim -Seconds ($config.BubbleHoverSec + 0.6))
Assert-True ($ui.SpeechBubble.Visibility -eq 'Visible') "za $($config.BubbleHoverSec) s se vrátí, pokud hláška ještě nemá zmizet"
[void](Invoke-Sim -Seconds 3)
Assert-True ($ui.SpeechBubble.Visibility -eq 'Hidden') 'a pak normálně zmizí'
Invoke-Menu 'Nastavení', 'Tichý režim (bez bublin)'
$text = $ui.SpeechText.Text
Invoke-SpeechTick
Assert-True ($state.Quiet -and -not $speechTimer.Running -and $ui.SpeechBubble.Visibility -eq 'Hidden' -and $ui.SpeechText.Text -eq $text) 'tichý režim: žádné bubliny, časovač hlášek stojí'
Set-Paused $true
Assert-True ($ui.SpeechBubble.Visibility -eq 'Hidden' -and -not $speechTimer.Running) 'tichý režim: ani stížnost v pauze'
Set-Paused $false
Invoke-Menu 'Nastavení', 'Tichý režim (bez bublin)'
Assert-True (-not $state.Quiet -and $speechTimer.Running) 'vypnutí tichého režimu: kachna zase mluví'
Assert-True ($state.Phrases) 'kachní hlášky jsou ve výchozím stavu zapnuté'
Invoke-Menu 'Nastavení', 'Zapnuté kachní hlášky'
$text = $ui.SpeechText.Text
[void](Invoke-Sim -Seconds 60)
Assert-True (-not $state.Phrases -and -not $speechTimer.Running -and $ui.SpeechText.Text -eq $text) 'vypnuté kachní hlášky: minutu nic neřekne, časovač hlášek stojí'
Set-Paused $true
[void](Invoke-Sim -Seconds ($config.ComplaintIntervalSec + 1))
Assert-True (-not $speechTimer.Running -and $ui.SpeechText.Text -in $complaintPhrases) 'vypnuté kachní hlášky: v pauze jen jedna stížnost hned po klepnutí, další už ne'
Set-Paused $false
Start-Hop
[void](Invoke-Sim -Seconds 2)
Assert-True ($ui.SpeechBubble.Visibility -eq 'Visible' -and -not $speechTimer.Running) 'vypnuté kachní hlášky: reakce (poskok, přistání…) v bublině zůstávají'
Invoke-Menu 'Nastavení', 'Zapnuté kachní hlášky'
Assert-True ($state.Phrases -and $speechTimer.Running) 'zapnutí kachních hlášek: kachna zase mluví'

# ===========================================================================
Write-Section 'Skrytí a zobrazení'
# ===========================================================================
Reset-Duck $main
[void](Invoke-Sim -Seconds 5)
Update-MenuState -Items $trayItems -Tray $true
Assert-True ($null -ne (Find-MenuItem -Items $trayItems -Path 'Skrýt kachnu' -Tray)) 'ikona: nabízí Skrýt kachnu, když je kachna vidět'
$xHidden = $window.Left; $dirHidden = $state.Direction; $textHidden = $ui.SpeechText.Text
Invoke-Menu 'Skrýt kachnu' -Tray
Assert-True (-not $window.IsVisible -and $state.Hidden) 'skrytí: okno zmizí'
Assert-True (@($timers | Where-Object Running).Count -eq 0 -and $sim.Anims.Count -eq 0) 'skrytí: žádný časovač ani animace okna neběží'
# jen pozastavený storyboard nestačí, WPF by dál tikalo ~60x za sekundu
Assert-True (-not $legs.Running -and -not $glow.Running) 'skrytí: animace nohou i těla jsou zastavené (program jen čeká)'
Update-MenuState -Items $trayItems -Tray $true
Assert-True ($null -ne (Find-MenuItem -Items $trayItems -Path 'Zobrazit kachnu' -Tray)) 'ikona: nabízí Zobrazit kachnu, když je kachna skrytá'
[void](Invoke-Sim -Seconds 120 -Step 1)
Assert-True ($window.Left -eq $xHidden -and $ui.SpeechText.Text -eq $textHidden) 'skrytá kachna se 2 minuty nepohnula ani nepromluvila'
Set-Hidden $true
Assert-True ($state.Hidden -and -not $window.IsVisible -and -not $heartTimer.Running) 'opakované skrytí nic nerozbije'
# v menu u ikony jde nastavení měnit i ve skrytu, kachnu to ale neprobudí
Set-Speed 'Pomalá'; Set-PhraseSpeed 'Rychlá'; Set-RandomBehavior $true; Switch-Pause; Switch-Pause; Set-EcoMode 'Vždy'; Set-EcoMode 'Na baterii'
Set-Follow $true; Set-Follow $false; Set-Quiet $true; Set-Quiet $false
Assert-True (-not $window.IsVisible -and @($timers | Where-Object Running).Count -eq 0 -and $sim.Anims.Count -eq 0 -and -not $legs.Running -and -not $glow.Running) 'změny nastavení ve skrytu kachnu neprobudí'
Set-RandomBehavior $false
Invoke-Menu 'Zobrazit kachnu' -Tray
Assert-True ($window.IsVisible -and -not $state.Hidden -and $heartTimer.Running -and $speechTimer.Running) 'zobrazení: okno, tep i hlášky zase běží'
Assert-True ($legs.Running -and $glow.Running -and $null -ne $sim.Anims['Left']) 'zobrazení: nohy i tělo se hýbou a kachna jde'
Assert-True ($ui.SpeechText.Text -in $showPhrases) "zobrazení: kachna se ozve: '$($ui.SpeechText.Text)'"
Assert-True ($speechTimer.Interval.TotalSeconds -eq $config.PhraseSpeeds['Rychlá']) 'zobrazení: mluví podle rychlosti hlášek zvolené ve skrytu'
Assert-True ($window.ShownAt.Left -eq $xHidden -and $state.Direction -eq $dirHidden) 'zobrazení: kachna je tam, kde zmizela, a jde stejným směrem'
[void](Invoke-Sim -Seconds 2)
Assert-True ($window.Left -ne $xHidden) 'zobrazení: chodí dál'

# Zapauzovaná kachna zůstane po zobrazení zapauzovaná
Reset-Duck $main
Set-Paused $true
Set-Hidden $true
Set-Hidden $false
Assert-True ($state.Paused -and -not $legs.Running -and $ui.SpeechText.Text -in $complaintPhrases -and $speechTimer.Interval.TotalSeconds -eq $config.ComplaintIntervalSec -and $sim.Anims.Count -eq 0) 'zapauzovaná kachna po zobrazení dál stojí a stěžuje si jednou za minutu'
Set-Paused $false

# Monitor odpojený ve skrytu: kachna se nesmí objevit mimo obrazovku
Reset-Duck $right
Stop-Motion; $state.X = 3500; Set-WindowPosition
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
Invoke-Menu 'Přivolat kachnu k myši' -Tray
Assert-True ($window.IsVisible -and $heartTimer.Running -and $state.Falling -and $window.ShownAt.Top -eq $right.Top -and $window.ShownAt.Left -eq 3000 - $window.Width / 2) 'přivolání skryté kachny: zobrazí se rovnou nahoře nad kurzorem'
Assert-True ($ui.SpeechText.Text -eq $textBefore) 'přivolání skryté kachny: během pádu nic neříká'
[void](Invoke-Sim -Seconds 2)
Assert-True (-not $state.Falling -and (Test-OnGround $right) -and $ui.SpeechText.Text -in $dropPhrases) 'přivolání skryté kachny: dopadne a promluví'
Assert-True (@($menuItems | Where-Object { $_.Tag -and $_.Tag.Spec.Text -eq 'Přivolat kachnu k myši' }).Count -eq 0) 'přivolání je jen v menu ikony (kachnu, na kterou jde kliknout, není kam volat)'

# Skrytí během pádu
Reset-Duck $main
$sim.CursorArea = $main
Start-Drag
$window.Left = 800; $window.Top = 50
Complete-Drag -StartLeft 0 -StartTop 682
Step-Sim 0.2
Set-Hidden $true
$yHidden = $window.Top
[void](Invoke-Sim -Seconds 5)
Assert-True ($state.Falling -and $window.Top -eq $yHidden -and $sim.Anims.Count -eq 0) 'skrytí během pádu: pád se zastaví'
Set-Hidden $false
[void](Invoke-Sim -Seconds 2)
Assert-True (-not $state.Falling -and (Test-OnGround $main)) 'po zobrazení pád dokončí a stojí na zemi'

# Skrýt na čas (schůzka)
Reset-Duck $main
Invoke-Menu 'Skrýt na…', '15 minut'
Assert-True ($state.Hidden -and $hideTimer.Running -and $hideTimer.Interval.TotalMinutes -eq 15 -and -not $heartTimer.Running) 'skrýt na 15 minut: kachna zmizí, běží jen jednorázový časovač'
[void](Invoke-Sim -Seconds 899 -Step 1)
Assert-True ($state.Hidden) 'po 14:59 je pořád schovaná'
[void](Invoke-Sim -Seconds 2 -Step 1)
Assert-True (-not $state.Hidden -and $window.IsVisible -and -not $hideTimer.Running -and $ui.SpeechText.Text -in $showPhrases) 'po 15 minutách se sama vrátí a ozve se'
Invoke-Menu 'Skrýt na…', '1 hodinu'
Invoke-Menu 'Zobrazit kachnu' -Tray
Assert-True (-not $state.Hidden -and -not $hideTimer.Running) 'ruční zobrazení zruší odpočet'

# Vždy navrchu
Invoke-Menu 'Nastavení', 'Vždy navrchu'
Assert-True (-not $state.Topmost -and -not $window.Topmost) 'menu: vždy navrchu jde vypnout (kachna pak chodí za okny)'
Invoke-Menu 'Nastavení', 'Vždy navrchu'
Assert-True ($state.Topmost -and $window.Topmost) 'a zase zapnout'

# ===========================================================================
Write-Section 'Zamčení PC a spánek při nečinnosti'
# ===========================================================================
Reset-Duck $main
Invoke-SessionSwitch 'SessionLock'
Assert-True ($state.Hidden -and $state.HiddenByLock -and -not $window.IsVisible -and @($timers | Where-Object Running).Count -eq 0 -and -not $legs.Running) 'zamčení PC: kachna se schová a nic neběží (~0 % CPU)'
Invoke-SessionSwitch 'SessionUnlock'
Assert-True (-not $state.Hidden -and $window.IsVisible -and $ui.SpeechText.Text -in $welcomePhrases -and $null -ne $sim.Anims['Left']) "odemčení: kachna se vrátí ('$($ui.SpeechText.Text)') a jde dál"
Set-Hidden $true
Invoke-SessionSwitch 'SessionLock'
Invoke-SessionSwitch 'SessionUnlock'
Assert-True ($state.Hidden) 'ručně skrytá kachna zůstane po odemčení skrytá'
Set-Hidden $false
Invoke-SessionSwitch 'RemoteDisconnect'
Invoke-SessionSwitch 'RemoteConnect'
Assert-True (-not $state.Hidden) 'odpojení a připojení vzdálené plochy funguje stejně'
Start-TimedHide '15 minut'
Invoke-SessionSwitch 'SessionLock'
[void](Invoke-Sim -Seconds 901 -Step 1)
Assert-True ($state.Hidden) 'skrytí na čas skončí během zamčení: kachna počká na odemčení'
Invoke-SessionSwitch 'SessionUnlock'
Assert-True (-not $state.Hidden -and $window.IsVisible) '... a po odemčení se ukáže'

Reset-Duck $main
$sim.Active = $false   # myš stojí
[void](Invoke-Sim -Seconds 30)
$state.LastActivity = $clock.T - $config.IdleSleepMin * 60 + 1.5
[void](Invoke-Sim -Seconds 1)
Assert-True (-not $state.Sleeping) "kachna je vzhůru, dokud se myš hnula před méně než $($config.IdleSleepMin) min"
[void](Invoke-Sim -Seconds 1.5)
Assert-True ($state.Sleeping -and $ui.SpeechText.Text -in $sleepPhrases -and $ui.SleepEye.Visibility -eq 'Visible' -and $ui.circle12.Visibility -eq 'Hidden') "po $($config.IdleSleepMin) min bez pohybu myši usne: '$($ui.SpeechText.Text)', zavřené oči"
Assert-True ($sim.Anims.Count -eq 0 -and -not $legs.Running -and -not $glow.Running -and -not $speechTimer.Running -and $heartTimer.Interval.TotalSeconds -eq $config.SleepCheckSec) "spánek: animace i hlášky stojí, jen jednou za $($config.SleepCheckSec) s kontrola myši"
$ticks = $heartTimer.Ticks
[void](Invoke-Sim -Seconds 600 -Step 1)
Assert-True ($state.Sleeping -and $ui.SpeechBubble.Visibility -eq 'Visible' -and $heartTimer.Ticks - $ticks -le 301) ("10 minut spánku: {0} krátkých probuzení PowerShellu, bublina Zzz zůstává" -f ($heartTimer.Ticks - $ticks))
$sim.Cursor = '500,500'
[void](Invoke-Sim -Seconds 2.1)
Assert-True (-not $state.Sleeping -and $ui.SpeechText.Text -in $wakePhrases -and $ui.circle12.Visibility -eq 'Visible' -and $ui.SleepEye.Visibility -eq 'Hidden') "pohyb myši ji probudí: '$($ui.SpeechText.Text)'"
Assert-True ($null -ne $sim.Anims['Left'] -and $legs.Running -and $glow.Running -and $speechTimer.Running -and $heartTimer.Interval.TotalSeconds -eq 1) 'po probuzení zase chodí a mluví'
Set-Sleeping $true
Invoke-Summon
Assert-True (-not $state.Sleeping -and $state.Falling) 'přivolání spící kachnu probudí'
[void](Invoke-Sim -Seconds 2)
Set-Sleeping $true
Set-Hidden $true
Set-Hidden $false
Assert-True (-not $state.Sleeping -and $ui.circle12.Visibility -eq 'Visible') 'skrytí a zobrazení spící kachnu probudí (oči otevřené)'

# Uspání počítače: pohyb se zastaví (animace by po probuzení dohnala celou dobu spánku a kachna by skočila)
Reset-Duck $main
[void](Invoke-Sim -Seconds 5)
$xSuspend = $window.Left
Invoke-PowerModeChange 'Suspend'
Assert-True ($sim.Anims.Count -eq 0 -and $state.Motion -eq 'None' -and -not $legs.Running -and $window.Left -eq $xSuspend) 'uspání PC: kachna se zastaví tam, kde je'
$state.LastActivity = -9999
Invoke-PowerModeChange 'Resume'
Assert-True ($null -ne $sim.Anims['Left'] -and $sim.Anims['Left'].From -eq $xSuspend -and $legs.Running) 'probuzení PC: jde dál z téhož místa'
Assert-True ($clock.T - $state.LastActivity -lt 1) 'probuzení PC se počítá jako aktivita (kachna hned neusne)'

# ===========================================================================
Write-Section 'Pojď za myší'
# ===========================================================================
Reset-Duck $main
$sim.CursorDip = [pscustomobject]@{ X = 1000; Y = 500 }
Invoke-Menu 'Pojď za myší'
Assert-True ($state.Follow -and $heartTimer.Interval.TotalSeconds -eq $config.FollowHeartbeatSec -and $ui.SpeechText.Text -in $followPhrases) "zapnutí: '$($ui.SpeechText.Text)', tep $($config.FollowHeartbeatSec) s"
[void](Invoke-Sim -Seconds 60)
Assert-True ([math]::Abs($window.Left - (1000 - $window.Width / 2)) -lt 0.01 -and $sim.Anims.Count -eq 0 -and -not $legs.Running) 'dojde pod kurzor a stojí (nohy u sebe)'
$sim.CursorDip = [pscustomobject]@{ X = 400; Y = 500 }
[void](Invoke-Sim -Seconds 1)
Assert-True ($state.Direction -eq -1 -and $null -ne $sim.Anims['Left']) 'kurzor se posune doleva: otočí se a jde za ním'
$count = $sim.AnimLog.Count
$sim.CursorDip = [pscustomobject]@{ X = 401; Y = 500 }
[void](Invoke-Sim -Seconds 2)
Assert-True ($sim.AnimLog.Count -eq $count) 'malý posun kurzoru (1 DIP) chůzi nepřeruší'
[void](Invoke-Sim -Seconds 60)
Assert-True ([math]::Abs($window.Left - (401 - $window.Width / 2)) -lt 3) 'dojde pod nové místo'
$sim.Layout = @($main, $right)
$sim.CursorDip = [pscustomobject]@{ X = 2600; Y = 900 }
[void](Invoke-Sim -Seconds 200)
Assert-True ((Test-SameArea $state.Area $right) -and [math]::Abs($window.Left - (2600 - $window.Width / 2)) -lt 0.01 -and (Test-OnGround $right)) 'kurzor na sousedním monitoru: kachna přejde a dojde pod něj'
Invoke-Menu 'Pojď za myší'
Assert-True (-not $state.Follow -and $heartTimer.Interval.TotalSeconds -eq 1 -and $null -ne $sim.Anims['Left']) 'vypnutí: tep zase 1x za sekundu a kachna se prochází'

# ===========================================================================
Write-Section 'Krmení rohlíkem'
# ===========================================================================
Reset-Duck $main
$sim.CursorDip = [pscustomobject]@{ X = 1500; Y = 300 }
Invoke-Menu 'Nakrmit rohlíkem'
$crumb = $sim.Crumb
Assert-True ($crumb.Visible -and $crumb.X -eq 1500 - $config.CrumbSize.Width / 2 -and $crumb.GroundY -eq $main.Bottom - $config.CrumbSize.Height) 'rohlík spadne u kurzoru na zem'
Assert-True ($ui.SpeechText.Text -in $foodPhrases -and $state.Direction -eq 1 -and $sim.Anims['Left'].To -eq 1500 - $config.BeakOffset) "kachna k němu běží: '$($ui.SpeechText.Text)'"
[void](Invoke-Sim -Seconds 120)
Assert-True ($null -eq $state.Food -and -not $crumb.Visible) 'rohlík snědla a zmizel'
Assert-True ($sim.AnimLog.Where({ $_.Property -eq 'Top' -and $_.Ease -eq 'EaseOut' }).Count -ge 1 -and $null -ne $sim.Anims['Left']) 'po jídle radostí poskočí a jde dál'
Reset-Duck $main
Stop-Motion; $state.X = 1200; Set-WindowPosition; Start-Walk
$sim.CursorDip = [pscustomobject]@{ X = 600; Y = 300 }
Start-Feeding
Assert-True ($state.Direction -eq -1 -and $sim.Anims['Left'].To -eq 600 - ($window.Width - $config.BeakOffset)) 'rohlík za kachnou: otočí se a jde k němu zobákem napřed'
$eaten = $false
for ($i = 0; $i -lt 600 -and -not $eaten; $i++) { Step-Sim 0.1; if ($state.Eating) { $eaten = $true } }
Assert-True ($eaten -and $ui.SpeechText.Text -in $eatPhrases -and $sim.Anims.Count -eq 0) "u rohlíku se zastaví a jí: '$($ui.SpeechText.Text)'"
Reset-Duck $main
Stop-Motion; $state.X = 800; Set-WindowPosition; Start-Walk
$sim.CursorDip = [pscustomobject]@{ X = 900; Y = 300 }
Start-Feeding
Assert-True ($state.Eating -or $sim.Anims.Count -eq 0) 'rohlík přímo pod kachnou: sní ho na místě'
Reset-Duck $main
Set-Hidden $true
$sim.CursorDip = [pscustomobject]@{ X = 5000; Y = 300 }
Invoke-Menu 'Nakrmit rohlíkem' -Tray
Assert-True (-not $state.Hidden -and $sim.Crumb.Visible -and $sim.Crumb.Y -eq $main.Top) 'krmení skryté kachny z ikony: kachna se ukáže, rohlík spadne shora před ni (kurzor je jinde)'
$sim.CursorArea = $right
Start-Drag
$window.Left = 2500; $window.Top = 100
Complete-Drag -StartLeft 0 -StartTop 682
Assert-True ($null -eq $state.Food -and -not $sim.Crumb.Visible) 'přenesení na jiný monitor: rohlík zmizí'

# ===========================================================================
Write-Section 'Připomínky'
# ===========================================================================
Reset-Duck $main
Assert-True ($state.Reminders.Drink -and $state.Reminders.Stretch -and $state.Pomodoro) 'všechny připomínky jsou ve výchozím stavu zapnuté'
[void](Invoke-Sim -Seconds 60)
$reminderTexts = @($reminderPhrases.Values | ForEach-Object { $_ })
Assert-True ($ui.SpeechText.Text -notin $reminderTexts -and $state.PomodoroDue -ge 25 * 60) 'po startu se připomínky neozvou hned, Pomodoro začíná prací'
[void](Invoke-Sim -Seconds (25 * 60 - 60 + 1) -Step 1)
Assert-True ($ui.SpeechText.Text -in $reminderPhrases.PomodoroBreak -and $state.PomodoroPhase -eq 'Break') 'výchozí Pomodoro: po 25 minutách pauza'
foreach ($item in 'Pitný režim (každou hodinu)', 'Protažení (každé 2 hodiny)', 'Pomodoro (25 min práce, 5 min pauza)') { Invoke-Menu 'Připomínky', $item }
Assert-True (-not ($state.Reminders.Drink -or $state.Reminders.Stretch -or $state.Pomodoro)) 'menu: připomínky jdou vypnout'
Reset-Duck $main
foreach ($key in 'Drink', 'Stretch', 'Pomodoro') { Set-Reminder $key $false }
Set-Paused $true
Invoke-Menu 'Připomínky', 'Pitný režim (každou hodinu)'
Assert-True ($state.Reminders.Drink) 'menu: pitný režim zapnutý'
[void](Invoke-Sim -Seconds 3599 -Step 1)
Assert-True ($ui.SpeechText.Text -notin $reminderPhrases.Drink) 'před hodinou se neozve'
[void](Invoke-Sim -Seconds 2 -Step 1)
Assert-True ($ui.SpeechText.Text -in $reminderPhrases.Drink -and $ui.SpeechBorder.Background -eq 'modrá' -and $ui.SpeechBubble.Visibility -eq 'Visible') "po hodině připomene pití (modrá bublina): '$($ui.SpeechText.Text)'"
[void](Invoke-Sim -Seconds ($config.ReminderBubbleSec - 2) -Step 1)
Assert-True ($ui.SpeechBubble.Visibility -eq 'Visible') "připomínka je vidět aspoň $($config.ReminderBubbleSec - 2) s"
Invoke-Menu 'Připomínky', 'Pitný režim (každou hodinu)'
Invoke-Menu 'Připomínky', 'Pomodoro (25 min práce, 5 min pauza)'
Assert-True ($state.Pomodoro -and $ui.SpeechText.Text -in $reminderPhrases.PomodoroStart) 'Pomodoro: začátek'
[void](Invoke-Sim -Seconds (25 * 60 + 1) -Step 1)
Assert-True ($ui.SpeechText.Text -in $reminderPhrases.PomodoroBreak) 'Pomodoro: po 25 minutách pauza'
[void](Invoke-Sim -Seconds (5 * 60 + 1) -Step 1)
Assert-True ($ui.SpeechText.Text -in $reminderPhrases.PomodoroWork) 'Pomodoro: po 5 minutách zpátky do práce'
Invoke-Menu 'Připomínky', 'Pomodoro (25 min práce, 5 min pauza)'
Invoke-Menu 'Připomínky', 'Protažení (každé 2 hodiny)'
Set-Hidden $true
[void](Invoke-Sim -Seconds (3 * 3600) -Step 10)
Assert-True ($state.Hidden -and $ui.SpeechText.Text -notin $reminderPhrases.Stretch) 'skrytá kachna nepřipomíná'
Set-Hidden $false
Step-Sim 1.0
Assert-True ($ui.SpeechText.Text -in $reminderPhrases.Stretch -and $state.ReminderDue.Stretch -ge $clock.T + 7000) 'po zobrazení připomene jednou a další připomínka je za 2 hodiny'
Set-Paused $false
# Spánek se pozná jen podle myši (uživatel může psát): připomínka spící kachnu probudí
Set-Sleeping $true
$state.ReminderDue.Stretch = $clock.T + 1
[void](Invoke-Sim -Seconds 3)
Assert-True (-not $state.Sleeping -and $ui.SpeechText.Text -in $reminderPhrases.Stretch -and $ui.SpeechBorder.Background -eq 'modrá') 'připomínka spící kachnu probudí a ukáže se'

# ===========================================================================
Write-Section 'Hlášky podle situace'
# ===========================================================================
Reset-Duck $main
Set-Paused $false
$sim.Now = [datetime]'2026-12-24 19:00'
$null = Get-Random -SetSeed 7
$said = @(1..80 | ForEach-Object { Invoke-SpeechTick; $ui.SpeechText.Text })
$special = @($said | Where-Object { $_ -in ($situationPhrases.Christmas + $situationPhrases.Evening) })
Assert-True ($special.Count -ge 5 -and $special.Count -le 40) "Štědrý večer: z 80 hlášek je $($special.Count) vánočních nebo večerních (asi čtvrtina)"
$sim.Now = [datetime]'2026-03-11 10:00'
$said = @(1..80 | ForEach-Object { Invoke-SpeechTick; $ui.SpeechText.Text })
Assert-True (@($said | Where-Object { $_ -notin $duckPhrases }).Count -eq 0) 'obyčejná středa dopoledne: jen běžné hlášky'
$sim.Power = [pscustomobject]@{ OnBattery = $true; Percent = 9 }
Update-Power
$said = @(1..80 | ForEach-Object { Invoke-SpeechTick; $ui.SpeechText.Text })
Assert-True (@($said | Where-Object { $_ -match ' 9 %' }).Count -ge 3) 'slabá baterie: kachna si řekne o nabíječku'
$state.Distance = 96 / 2.54 * 4200
$state.DistanceDate = $sim.Now.Date
$sim.Power = [pscustomobject]@{ OnBattery = $false; Percent = 100 }
Update-Power
$said = @(1..80 | ForEach-Object { Invoke-SpeechTick; $ui.SpeechText.Text })
Assert-True (@($said | Where-Object { $_ -match '42 m' }).Count -ge 3) 'kachna se pochlubí ušlou vzdáleností (42 m)'
Reset-Duck $main
$before = $state.Distance
[void](Invoke-Sim -Seconds 20)
Set-Paused $true
Assert-True ([math]::Abs(($state.Distance - $before) - 20 * 15) -lt 1) ("ušlá vzdálenost se počítá: {0:N0} DIP za 20 s" -f ($state.Distance - $before))
Set-Paused $false

# ===========================================================================
Write-Section 'Sezónní převleky'
# ===========================================================================
Reset-Duck $main
$sim.Now = [datetime]'2026-12-10 10:00'
Update-Costume
Assert-True ($ui.CostumeSanta.Visibility -eq 'Visible' -and $ui.CostumeWitch.Visibility -eq 'Collapsed' -and $ui.CostumeGlasses.Visibility -eq 'Collapsed') 'v prosinci má kachna mikulášskou čepici (převleky jsou ve výchozím stavu zapnuté)'
Invoke-Menu 'Nastavení', 'Sezónní převleky'
Assert-True (-not $state.Costumes -and $ui.CostumeSanta.Visibility -eq 'Collapsed') 'menu: převleky jdou vypnout'
Invoke-Menu 'Nastavení', 'Sezónní převleky'
Assert-True ($state.Costumes -and $ui.CostumeSanta.Visibility -eq 'Visible') 'a zase zapnout'
$sim.Now = [datetime]'2026-07-15 10:00'
$state.NextPowerCheck = $clock.T
Step-Sim 1.0
Assert-True ($ui.CostumeGlasses.Visibility -eq 'Visible' -and $ui.CostumeSanta.Visibility -eq 'Collapsed') 'změna data za běhu: v létě sluneční brýle (kontrola jednou za minutu)'

# ===========================================================================
Write-Section 'Zvuk'
# ===========================================================================
Reset-Duck $main
$sim.Sounds = 0
Start-Hop
[void](Invoke-Sim -Seconds 1)
Start-Drag; Complete-Drag -StartLeft $window.Left -StartTop $window.Top; Step-Sim 0.6
Assert-True ($sim.Sounds -eq 0 -and -not $state.Sound) 'zvuk je ve výchozím stavu vypnutý (poskok ani klepnutí nekvákají)'
Invoke-Menu 'Nastavení', 'Zvuk (kvák)'
Assert-True ($state.Sound -and $sim.Sounds -eq 1) 'zapnutí zvuku: kachna hned kvákne na ukázku'
Start-Drag; Complete-Drag -StartLeft $window.Left -StartTop $window.Top; Step-Sim 0.6
Start-Hop
Assert-True ($sim.Sounds -eq 3) 'se zvukem kvákne při klepnutí i poskoku'
Invoke-Menu 'Nastavení', 'Zvuk (kvák)'
Assert-True (-not $state.Sound) 'zvuk jde zase vypnout'

# ===========================================================================
Write-Section 'Menu kachny a ikony'
# ===========================================================================
Reset-Duck $main
Update-MenuState -Items $menuItems -Tray $false
Update-MenuState -Items $trayItems -Tray $true
$duckTop = @($menuItems | Where-Object { $_.Tag } | ForEach-Object { $_.Header })
$trayTop = @($trayItems | Where-Object { $_.Tag } | ForEach-Object { $_.Text })
Assert-True ((@($trayTop | Where-Object { $_ -ne 'Přivolat kachnu k myši' }) -join '|') -eq ($duckTop -join '|')) "obě menu mají stejné položky: $($duckTop -join ', ')"
Assert-True ($menuItems[0].Header -eq 'Pauza' -and $menuItems[0].InputGestureText -eq 'klepnutí') 'menu kachny: Pauza (klepnutí)'
$expectChecked = [ordered]@{
    'Rychlost chůze|Normální' = $true; 'Rychlost chůze|Rychlá' = $false; 'Úsporný režim|Vypnutý' = $true; 'Úsporný režim|Na baterii' = $false
    'Nastavení|Náhodné chování' = $false; 'Nastavení|Chůze přes monitory' = $true; 'Nastavení|Sezónní převleky' = $true
    'Nastavení|Zapnuté kachní hlášky' = $true; 'Nastavení|Tichý režim (bez bublin)' = $false; 'Nastavení|Zvuk (kvák)' = $false; 'Nastavení|Vždy navrchu' = $true
    'Připomínky|Pitný režim (každou hodinu)' = $true; 'Připomínky|Protažení (každé 2 hodiny)' = $true
    'Připomínky|Pomodoro (25 min práce, 5 min pauza)' = $true; 'Pojď za myší' = $false
}
$state.RandomBehavior = $false
Update-MenuState -Items $menuItems -Tray $false
Update-MenuState -Items $trayItems -Tray $true
foreach ($path in $expectChecked.Keys) {
    $duckItem = Find-MenuItem -Items $menuItems -Path ($path -split '\|')
    $trayItem = Find-MenuItem -Items $trayItems -Path ($path -split '\|') -Tray
    Assert-True ($null -ne $duckItem -and $null -ne $trayItem -and $duckItem.IsChecked -eq $expectChecked[$path] -and $trayItem.Checked -eq $expectChecked[$path]) ("menu: '{0}' {1} (u kachny i u ikony)" -f ($path -replace '\|', ' > '), $(if ($expectChecked[$path]) { 'zaškrtnuté' } else { 'nezaškrtnuté' }))
}
$submenus = @($menuItems + $trayItems | Where-Object { $_.Tag -and ($_.Tag.Spec.Choices -or $_.Tag.Spec.Items) -and $null -eq $_.Tag.Choice })
Assert-True ($submenus.Count -eq 12 -and @($submenus | Where-Object Clickable).Count -eq 0) 'podmenu nemají vlastní akci (klik na volbu k nim ve WPF probublá)'
Set-Paused $true
Update-MenuState -Items $menuItems -Tray $false
Assert-True ($menuItems[0].Header -eq 'Pokračovat') 'v pauze menu nabízí Pokračovat'
Invoke-Menu 'Pokračovat'
Assert-True (-not $state.Paused) 'Pokračovat kachnu rozběhne'
Invoke-Menu 'Ukončit'
Assert-True $window.Closed 'Ukončit zavře okno (skript pak skončí)'

# ===========================================================================
Write-Section 'PSScriptAnalyzer'
# ===========================================================================
$pssa = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
if (-not $pssa -and $env:KACHNA_PSSA) { $pssa = $env:KACHNA_PSSA }
if ($pssa) {
    Import-Module $pssa -ErrorAction Stop
    foreach ($path in $v2Path, $measurePath) {
        $findings = @(Invoke-ScriptAnalyzer -Path $path -Severity Error, Warning)
        $findings | ForEach-Object { Write-Host "          $($_.Line): $($_.RuleName) - $($_.Message)" -ForegroundColor Yellow }
        Assert-True ($findings.Count -eq 0) "$(Split-Path -Leaf $path) bez chyb a varování PSScriptAnalyzeru ($($findings.Count))"
    }
} else {
    Write-Host '  [PŘESKOČENO] PSScriptAnalyzer není nainstalovaný (Install-Module PSScriptAnalyzer)' -ForegroundColor Yellow
}

# ===========================================================================
Write-Host ''
$color = if ($script:failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "Výsledek: $script:passed OK, $script:failed chyb" -ForegroundColor $color
if ($script:failed -gt 0) { exit 1 }
exit 0
