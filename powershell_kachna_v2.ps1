<#
.SYNOPSIS
    Kachna v2 - kachna, která se prochází po spodním okraji obrazovky (Windows, WPF).

.DESCRIPTION
    Nová verze PowerShell kachny. Původní powershell_kachna.ps1 zůstává beze změny.

    Ovládání:
      - klepnutí levým tlačítkem ...... pauza / pokračování (v pauze si kachna každou minutu postěžuje)
      - přetažení levým tlačítkem ..... přesun kachny kamkoli, i na jiný monitor; po puštění spadne dolů
      - pravé tlačítko ................ menu (pauza, rychlost, náhodné chování, ukončit)
      - ikona v oznamovací oblasti .... stejné menu + "Přivolat kachnu k myši" (také dvojklikem na ikonu)

    Novinky oproti v1:
      - více monitorů s různým rozlišením i škálováním (1080p, 1200p, 2K, 4K ...),
      - kachna dojde až k okraji pracovní plochy a respektuje hlavní panel na libovolné straně,
      - plynulý pohyb (~33 snímků/s), bublina je vždy u hlavy a přizpůsobí se délce textu,
      - hlášky se neopakují hned po sobě, náhodné chování (zastavení, otočení, změna tempa),
      - reakce na změnu rozlišení nebo odpojení monitoru (kachna nezmizí mimo obrazovku).

.NOTES
    Spuštění: dvojklik na powershell_kachna_v2.cmd
        nebo: powershell -NoProfile -ExecutionPolicy Bypass -File .\powershell_kachna_v2.ps1
    Funguje ve Windows PowerShell 5.1 i v PowerShell 7 (jen Windows).
    Soubor musí zůstat v kódování UTF-8 s BOM, jinak PowerShell 5.1 rozbije diakritiku.
    Testy (lze spustit i na Linuxu v pwsh): tests/Test-KachnaV2.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Funkce mění jen stav kachny v jejím okně, ne systém.')]
param()

# ---------------------------------------------------------------------------
# Kontrola prostředí
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Error 'Kachna v2 potřebuje Windows (WPF). Pro Linux použij linux_kachna_v2_launch.sh.'
    return
}

# WPF potřebuje STA vlákno (např. integrovaná konzole VS Code může běžet v MTA) -> spustit znovu s -STA
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    if ($PSCommandPath) {
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -STA -File $PSCommandPath
    } else {
        Write-Error 'Kachna potřebuje STA vlákno. Spusť PowerShell s parametrem -STA.'
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Nastavení
# ---------------------------------------------------------------------------
$config = @{
    FrameMs              = 30         # krok animace pohybu v ms (~33 snímků/s)
    Speeds               = [ordered]@{ 'Pomalá' = 8; 'Normální' = 15; 'Rychlá' = 35 }  # rychlost chůze v DIP za sekundu
    DefaultSpeed         = 'Normální' # odpovídá rychlosti v1 (5 px každých 350 ms = 14,3 px/s)
    LegsBaseSpeed        = 15         # při této rychlosti nohy kmitají jednou za sekundu (jako ve v1)
    PhraseIntervalSec    = 4          # jak často kachna mluví při chůzi
    ComplaintIntervalSec = 60         # jak často si kachna stěžuje v pauze
    Gravity              = 3000       # zrychlení pádu po puštění (DIP/s²)
    RiseSpeed            = 800        # rychlost vynoření, když kachnu pustíš pod spodní okraj (DIP/s)
    ClickTolerance       = 4          # největší posun (DIP), který se ještě bere jako klepnutí
    AreaCheckSec         = 0.5        # jak často znovu načíst rozměry monitoru
    RandomBehavior       = $true      # náhodné zastavení / otočení / změna tempa
}

# ---------------------------------------------------------------------------
# Hlášky
# ---------------------------------------------------------------------------
# Hlášky z v1 (duplicitní položky zvyšují pravděpodobnost, že padnou)
$duckPhrases = @(
    "Kvák! Jak se dnes máš?",
    "Kachní život je nejlepší život!",
    "Máš nějaký chleba?",
    "Kachna kachně kachnou o kachně...",
    "Příště zkus nějaké zábavné kachní video!",
    "Jsem kachna, ne kačer Howard!",
    "Když se kachna nudí, hraje Duck Hunt obráceně.",
    "Kachna vchází do baru...",
    "KVÁK! KVÁK! (překlad: Ahoj!)",
    "Víš, že kachny mají 3 víčka?",
    "Jsi v kachním teritoriu!",
    "Co říká kachna programátorovi? Quack overflow!",
    "Dej mi křídla a poletím ti na nervy!",
    "Plovoucí bug byl objeven...",
    "Zkontroluj si email, možná tam je kachna.",
    "Virtuální kachny nepotřebují krmit",
    "Kvák! Restartuj počítač, to pomůže.",
    "Gazpacho polévka? To je ale pěkná kachní kaše!",
    "Cože? Budeme jíst kuře? To je ale kanibalismus!",
    "Tohle je můj osobní prostor! Drž se od mého rybníčku dál!",
    "Není to můj den, nemám ani pírko na česání.",
    "Vesmír je velký a plný... zrníček?",
    "Až budu kapitán, zavedu povinné plavání pro všechny!",
    "Kdy už konečně přistaneme na planetě s pořádnou louží?",
    "Ach jo, zase pondělí... a žádný nový rybníček na obzoru.",
    "Jsem si jistá, že tam venku existuje planeta plná kachních piškotů.",
    "${Env:UserName}, jsem tvůj otec.",
    "${Env:UserName}, jsem tvůj otec.",
    "${Env:UserName}, jsem tvůj otec.",
    "${Env:UserName}, jsem tvůj otec.",
    "Houstone, máme problém...",
    "Jsem král světa! A tohle je můj rybník!",
    "Nejsi ty... tak trochu kachna?",
    "Co se stane ve Vegas, zůstane ve Vegas....",
    "Jdu do toho... po hlavě do rybníka!",
    "Lži mají krátká křídla... a já potřebuju nová.",
    "Na zdraví! A na další potopené rohlíky!",
    "Toto je jen začátek... mého panování nad rybníkem!",
    "Jeden prsten vládne všem... a já chci ten s největší houskou."
)

# Stížnosti v pauze (hned po zapauzování a pak každou minutu)
$complaintPhrases = @(
    "Hej! Proč se nemůžu hýbat?!",
    "Pusť mě! Mám nohy na chození, ne na stání!",
    "Tohle je kachní vězení!",
    "Stojím tu jak socha v parku...",
    "Nohy mi tuhnou. Klepni na mě, prosím!",
    "Stávkuju! Teda... nic jiného mi nezbývá.",
    "Zavolám kachní odbory!",
    "Takhle vypadá ochrana zvířat?",
    "Stojím tu tak dlouho, že mi roste mech.",
    "Kvák... kvák... nuda...",
    "Ostatní kachny chodí, jen já tu trčím.",
    "Jestli mě nepustíš, začnu zpívat!",
    "Jsem kachna, ne zátiší!",
    "Pauza na kávu? Já ani kávu nepiju!",
    "${Env:UserName}, pamatuješ si ještě na mě?"
)

# Po zrušení pauzy
$resumePhrases = @(
    "Konečně! Nohy, vpřed!",
    "Svoboda! Kvák!",
    "Díky! Už jsem myslela, že tu zapustím kořeny.",
    "Jdeme na to!"
)

# Po přistání (přetažení myší nebo přivolání)
$dropPhrases = @(
    "Juchů! Nové teritorium!",
    "Uf, to byl let!",
    "Příště mě aspoň upozorni!",
    "Tady se mi líbí. Je tu rybník?",
    "Kachní aerolinie děkují za let."
)

# Když se kachna sama zastaví (náhodné chování)
$restPhrases = @(
    "Chvilku si odpočinu...",
    "Ty jo, to je ale výhled!",
    "Kam jsem to vlastně šla?",
    "Malá pauza na čištění peří."
)

# ---------------------------------------------------------------------------
# Vzhled okna (XAML)
# ---------------------------------------------------------------------------
# Celý obsah je nakreslený pro chůzi doprava; při chůzi doleva se zrcadlí (RootFlip),
# text v bublině se zrcadlí zpět (TextFlip), aby zůstal čitelný.
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Kachna"
    Width="260"
    Height="358"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="False"
    ResizeMode="NoResize"
    UseLayoutRounding="True">
    <Grid x:Name="Root" RenderTransformOrigin="0.5,0.5">
        <Grid.RenderTransform>
            <ScaleTransform x:Name="RootFlip" ScaleX="1"/>
        </Grid.RenderTransform>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Bublina: výška se přizpůsobí textu, ocásek míří před hlavu kachny -->
        <Grid x:Name="SpeechBubble" Grid.Row="0" Width="230" Margin="0,0,6,0"
              HorizontalAlignment="Right" VerticalAlignment="Bottom">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="16"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="White" BorderBrush="Black" BorderThickness="2"
                    CornerRadius="16" Padding="10,6,10,6">
                <TextBlock x:Name="SpeechText" Text="Kvák!" FontSize="14" TextWrapping="Wrap"
                           TextAlignment="Center" RenderTransformOrigin="0.5,0.5">
                    <TextBlock.RenderTransform>
                        <ScaleTransform x:Name="TextFlip" ScaleX="1"/>
                    </TextBlock.RenderTransform>
                </TextBlock>
            </Border>
            <!-- Ocásek bubliny: neuzavřená cesta = bílá výplň překryje okraj bubliny, obrys jen po stranách -->
            <Path Grid.Row="1" Fill="White" Stroke="Black" StrokeThickness="2" StrokeLineJoin="Round"
                  Data="M 168,-2 L 205,13 L 192,-2"/>
        </Grid>

        <!-- Kachna: plátno 640x480 z v1, oříznuté na samotnou kresbu (x 54..554, y 25..481) a zmenšené na polovinu -->
        <Viewbox x:Name="DuckViewbox" Grid.Row="1" Width="250" Height="228" Stretch="Uniform"
                 HorizontalAlignment="Center" VerticalAlignment="Bottom">
            <Canvas x:Name="DuckBox" Width="500" Height="456" RenderTransformOrigin="0.5,0.5">
                <Canvas.RenderTransform>
                    <!-- kresba z v1 kouká doleva, tady ji otočíme doprava -->
                    <ScaleTransform ScaleX="-1"/>
                </Canvas.RenderTransform>
                <Canvas Name="Layer_1" Width="640" Height="480" Canvas.Left="-54" Canvas.Top="-25">
                    <!-- nohy (path2, path4) animuje skript, aby šly zastavit v pauze -->
                    <Path Name="path2" Fill="#FFF15A24" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10">
                        <Path.Data>
                            <PathGeometry Figures="m 236.71 379.105 c 0 0 15.237 39.537 12.767 58.895 -12.767 -1.854 -32.535 -6.796 -32.535 -6.796 0 0 -9.678 -1.44 -11.738 0.824 -2.06 2.264 -22.239 2.678 -23.475 4.942 -1.235 2.265 -2.266 5.765 -2.06 8.442 0.207 2.677 -8.648 9.265 -7.619 10.913 1.029 1.648 0 2.06 9.678 2.678 9.678 0.617 80.929 1.441 84.84 0 3.912 -1.442 2.677 -12.149 2.471 -14.827 -0.207 -2.677 -18.122 -62.394 -21.623 -65.071 -3.501 -2.677 -4.943 -4.53 -6.59 -4.324 -1.647 0.206 -4.116 4.324 -4.116 4.324 z" FillRule="NonZero"/>
                        </Path.Data>
                    </Path>
                    <Path Name="path4" Fill="#FFF15A24" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10">
                        <Path.Data>
                            <PathGeometry Figures="m 295.125 387.11 c 0.57 2.084 4.012 3.529 5.322 5.415 1.521 2.189 3.158 4.339 4.6 6.573 2.977 4.61 5.327 9.352 8.11 13.996 3.083 5.144 6.027 10.228 7.747 15.981 0.76 2.54 3.21 6.122 1.555 8.715 -1.529 2.396 -6.157 2.751 -8.732 2.85 -13.666 0.529 -27.399 2.356 -41.175 1.653 -3.563 -0.182 -7.601 -0.675 -11.114 0.046 -2.211 0.454 -7.535 0.332 -8.68 2.641 -1.548 3.125 2.679 4.707 3.261 7.439 0.532 2.495 -1.232 7.147 0.495 9.049 1.76 1.938 7.09 1.217 9.472 1.688 3.12 0.619 6.549 0.665 8.939 2.644 5.092 4.212 9.153 7.027 15.656 7.703 6.848 0.71 13.464 -0.589 20.046 -1.654 2.795 -0.453 5.258 -1.797 8.061 -2.492 3.057 -0.759 5.883 -1.205 8.687 -2.457 4.99 -2.23 10.663 -5.058 15.247 -8.526 4.371 -3.306 9.693 -7.151 8.938 -13.61 -0.595 -5.099 -5.257 -9.845 -8.07 -13.836 -1.54 -2.185 -2.372 -4.854 -3.876 -7.275 -1.546 -2.487 -3.848 -4.371 -5.372 -6.997 -3.106 -5.339 -6.187 -10.626 -10.127 -15.536 -1.645 -2.047 -3.355 -4.463 -5.271 -6.304 -1.238 -1.188 -2.564 -2.273 -3.513 -3.58 -0.748 -1.033 -1.278 -2.461 -2.263 -3.447 -2.027 -2.022 -4.501 -3.383 -6.568 -5.265 -2.117 -1.926 -4.144 -3.803 -6.452 -5.534 -2.18 -1.636 -6.334 -2.913 -9.215 -1.808 -2.962 1.136 -3.74 5.54 -3.14 8.405 0.606 2.904 3.602 3.971 6.401 3.938" FillRule="NonZero"/>
                        </Path.Data>
                    </Path>
                    <Path Name="path6" Fill="#FFFBB03B" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10">
                        <Path.Data>
                            <PathGeometry Figures="m 547 213 c -5 195.449 -202 195.449 -315.54 195.449 -70.991 0 -128.54 -57.55 -128.54 -128.54 0 -70.991 57.549 -128.54 128.54 -128.54 C 302.451 151.369 381 262 547 213 Z" FillRule="NonZero"/>
                        </Path.Data>
                        <Path.Triggers>
                            <EventTrigger RoutedEvent="Window.Loaded">
                                <BeginStoryboard>
                                    <Storyboard>
                                        <ColorAnimation Storyboard.TargetName="path6"
                                            Storyboard.TargetProperty="(Rectangle.Fill).Color" To="#FFFBE03B"
                                            Duration="00:00:03" AutoReverse="True" RepeatBehavior="Forever"/>
                                    </Storyboard>
                                </BeginStoryboard>
                            </EventTrigger>
                        </Path.Triggers>
                    </Path>
                    <Ellipse Canvas.Left="124.3" Canvas.Top="31.5" Width="165" Height="165" Name="circle8" Fill="#FFFBB03B" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10"/>
                    <Path Name="path10" Fill="#FFF15A24" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10">
                        <Path.Data>
                            <PathGeometry Figures="m 60.697 124.416 c 7.819 39.094 44.355 36.277 68.726 36.277 15.656 0 28.347 -12.692 28.347 -28.347 0 -15.656 -12.69 -28.347 -28.347 -28.347 -14.871 0 -30.469 22.551 -64.097 15.042 -2.398 0.001 -4.629 2.344 -4.629 5.375 z" FillRule="NonZero"/>
                        </Path.Data>
                    </Path>
                    <Ellipse Canvas.Left="158.8" Canvas.Top="68" Width="40" Height="40" Name="circle12" Fill="#FFFFFFFF" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10"/>
                    <Ellipse Canvas.Left="171.3" Canvas.Top="80.5" Width="15" Height="15" Name="circle14" Fill="#000000" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10"/>
                </Canvas>
            </Canvas>
        </Viewbox>
    </Grid>
</Window>
'@

# ---------------------------------------------------------------------------
# Čisté pomocné funkce (bez WPF; testuje je tests/Test-KachnaV2.ps1)
# ---------------------------------------------------------------------------
function Get-Clamped {
    # Omezí hodnotu do intervalu <Min, Max>.
    param([double]$Value, [double]$Min, [double]$Max)
    if ($Max -lt $Min) { $Max = $Min }
    return [math]::Min([math]::Max($Value, $Min), $Max)
}

function ConvertTo-DipRect {
    # Převede obdélník z pixelů zařízení na jednotky WPF (DIP). ScaleX/ScaleY pochází z TransformFromDevice:
    # 1.0 při 100 %, 0.8 při 125 %, 0.6667 při 150 %, 0.5 při 200 %.
    param([double]$Left, [double]$Top, [double]$Right, [double]$Bottom, [double]$ScaleX = 1, [double]$ScaleY = 1)
    return [pscustomobject]@{
        Left   = $Left * $ScaleX
        Top    = $Top * $ScaleY
        Right  = $Right * $ScaleX
        Bottom = $Bottom * $ScaleY
    }
}

function Step-Walk {
    # Jeden krok chůze. Na okraji se kachna zastaví a otočí směrem dovnitř.
    param([double]$X, [int]$Direction, [double]$Speed, [double]$Dt, [double]$MinX, [double]$MaxX)
    if ($MaxX -lt $MinX) { $MaxX = $MinX }
    $newX = $X + $Direction * $Speed * $Dt
    if ($newX -ge $MaxX) {
        $newX = $MaxX
        if ($Direction -gt 0) { $Direction = -1 }
    } elseif ($newX -le $MinX) {
        $newX = $MinX
        if ($Direction -lt 0) { $Direction = 1 }
    }
    return [pscustomobject]@{ X = $newX; Direction = $Direction }
}

function Step-Fall {
    # Jeden krok pádu na zem (GroundY), nebo vynoření, když je kachna pod zemí (např. puštěná nad hlavním panelem).
    param([double]$Y, [double]$Velocity, [double]$Dt, [double]$GroundY, [double]$Gravity, [double]$RiseSpeed)
    if ($Y -gt $GroundY) {
        $newY = [math]::Max($GroundY, $Y - $RiseSpeed * $Dt)
        return [pscustomobject]@{ Y = $newY; Velocity = 0.0; Landed = ($newY -le $GroundY) }
    }
    $v = $Velocity + $Gravity * $Dt
    $newY = $Y + $v * $Dt
    if ($newY -ge $GroundY) {
        return [pscustomobject]@{ Y = $GroundY; Velocity = 0.0; Landed = $true }
    }
    return [pscustomobject]@{ Y = $newY; Velocity = $v; Landed = $false }
}

function Get-RandomPhrase {
    # Náhodná hláška, která není stejná jako ta předchozí.
    param([string[]]$Phrases, [string]$Last)
    $candidates = @($Phrases | Where-Object { $_ -ne $Last })
    if ($candidates.Count -eq 0) { $candidates = @($Phrases) }
    return $candidates[(Get-Random -Maximum $candidates.Count)]
}

function Get-RandomAction {
    # Náhodné chování podle hodu 0..99: 15 % otočení, 20 % odpočinek, jinak změna tempa.
    param([int]$Roll)
    if ($Roll -lt 15) { return 'Turn' }
    if ($Roll -lt 35) { return 'Rest' }
    return 'Stroll'
}

# ---------------------------------------------------------------------------
# Monitory a souřadnice (WinForms Screen vrací pixely, WPF pracuje v DIP)
# ---------------------------------------------------------------------------
function Get-DipScale {
    # Měřítko pixely -> DIP pro okno kachny (podle DPI, ve kterém WPF okno vykresluje).
    $source = [System.Windows.PresentationSource]::FromVisual($window)
    if ($null -ne $source -and $null -ne $source.CompositionTarget) {
        $m = $source.CompositionTarget.TransformFromDevice
        return @($m.M11, $m.M22)
    }
    return @(1.0, 1.0)
}

function Get-WorkArea {
    # Pracovní plocha monitoru (bez hlavního panelu) v DIP.
    param($Screen)
    $wa = $Screen.WorkingArea
    $scale = Get-DipScale
    return ConvertTo-DipRect -Left $wa.Left -Top $wa.Top -Right $wa.Right -Bottom $wa.Bottom -ScaleX $scale[0] -ScaleY $scale[1]
}

function Get-WindowArea { Get-WorkArea ([System.Windows.Forms.Screen]::FromHandle($state.Hwnd)) }

function Get-CursorArea { Get-WorkArea ([System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)) }

function Get-CursorDip {
    $pos = [System.Windows.Forms.Cursor]::Position
    $scale = Get-DipScale
    return [pscustomobject]@{ X = $pos.X * $scale[0]; Y = $pos.Y * $scale[1] }
}

# ---------------------------------------------------------------------------
# Stav a chování kachny
# ---------------------------------------------------------------------------
function Get-GroundY { $state.Area.Bottom - $window.Height }
function Get-MinX { $state.Area.Left }
function Get-MaxX { $state.Area.Right - $window.Width }
function Get-CurrentSpeed { $config.Speeds[$state.SpeedName] * $state.SpeedFactor }

function Update-WorkArea { $state.Area = Get-WindowArea }

function Set-WindowPosition {
    $window.Left = $state.X
    $window.Top = $state.Y
}

function Show-Speech {
    param([string]$Text)
    $ui.SpeechText.Text = $Text
    $state.LastPhrase = $Text
}

function Restart-SpeechTimer {
    # Nová hláška má zůstat vidět celý interval.
    $speechTimer.Stop()
    $speechTimer.Start()
}

function Set-Direction {
    param([int]$Direction)
    $state.Direction = $Direction
    $ui.RootFlip.ScaleX = $Direction
    $ui.TextFlip.ScaleX = $Direction
}

function Update-LegAnimation {
    # Nohy stojí v pauze a při odpočinku, při pádu a přenášení kmitají rychle, jinak podle rychlosti chůze.
    if (-not $state.LegsReady) { return }
    if ($state.Dragging -or $state.Falling) {
        $legs.Resume($window)
        $legs.SetSpeedRatio($window, 4.0)
    } elseif ($state.Paused -or $state.Resting) {
        $legs.Pause($window)
        $legs.Seek($window, [TimeSpan]::Zero, 'BeginTime')   # nohy u sebe (TimeSeekOrigin.BeginTime)
    } else {
        $legs.Resume($window)
        $legs.SetSpeedRatio($window, [math]::Max(0.2, (Get-CurrentSpeed) / $config.LegsBaseSpeed))
    }
}

function Set-Paused {
    param([bool]$Paused)
    $state.Paused = $Paused
    $state.Resting = $false
    $speechTimer.Stop()
    if ($Paused) {
        Show-Speech (Get-RandomPhrase $complaintPhrases $state.LastPhrase)
        $speechTimer.Interval = [TimeSpan]::FromSeconds($config.ComplaintIntervalSec)
    } else {
        Show-Speech (Get-RandomPhrase $resumePhrases $state.LastPhrase)
        $speechTimer.Interval = [TimeSpan]::FromSeconds($config.PhraseIntervalSec)
    }
    $speechTimer.Start()
    Update-LegAnimation
}

function Switch-Pause { Set-Paused (-not $state.Paused) }

function Set-Speed {
    param([string]$Name)
    if ($config.Speeds.Contains($Name)) {
        $state.SpeedName = $Name
        Update-LegAnimation
    }
}

function Set-RandomBehavior {
    param([bool]$Enabled)
    $state.RandomBehavior = $Enabled
    $state.Resting = $false
    $state.SpeedFactor = 1.0
    $state.NextDecision = $clock.Elapsed.TotalSeconds + 5
    Update-LegAnimation
}

function Start-Fall {
    # Kachna spadne (nebo se vynoří) na spodní okraj pracovní plochy zadaného monitoru.
    param($Area, [double]$X, [double]$Y)
    $state.Area = $Area
    $state.X = Get-Clamped -Value $X -Min $Area.Left -Max ($Area.Right - $window.Width)
    $state.Y = $Y
    $state.VY = 0.0
    $state.Falling = $true
    $state.Resting = $false
    Update-LegAnimation
}

function Invoke-Summon {
    # Přivolá kachnu na monitor s kurzorem myši: objeví se nahoře nad kurzorem a spadne dolů.
    $area = Get-CursorArea
    $cursor = Get-CursorDip
    Start-Fall -Area $area -X ($cursor.X - $window.Width / 2) -Y $area.Top
}

function Complete-Drag {
    # Vyhodnotí stisk levého tlačítka po DragMove: malý posun = klepnutí (pauza), jinak pád na monitoru pod kurzorem.
    param([double]$StartLeft, [double]$StartTop)
    $state.Dragging = $false
    $moved = [math]::Max([math]::Abs($window.Left - $StartLeft), [math]::Abs($window.Top - $StartTop))
    if ($moved -le $config.ClickTolerance) {
        Set-WindowPosition
        Switch-Pause
    } else {
        Start-Fall -Area (Get-CursorArea) -X $window.Left -Y $window.Top
    }
    Update-LegAnimation
}

function Invoke-RandomBehavior {
    param([double]$Now)
    if ($state.Resting) {
        if ($Now -ge $state.RestUntil) {
            $state.Resting = $false
            Update-LegAnimation
        }
        return
    }
    if ($Now -lt $state.NextDecision) { return }
    $state.NextDecision = $Now + (Get-Random -Minimum 6.0 -Maximum 16.0)
    switch (Get-RandomAction (Get-Random -Maximum 100)) {
        'Turn' {
            Set-Direction (-$state.Direction)
        }
        'Rest' {
            $state.Resting = $true
            $state.RestUntil = $Now + (Get-Random -Minimum 2.0 -Maximum 6.0)
            if ((Get-Random -Maximum 2) -eq 0) {
                Show-Speech (Get-RandomPhrase $restPhrases $state.LastPhrase)
                Restart-SpeechTimer
            }
            Update-LegAnimation
        }
        default {
            $state.SpeedFactor = Get-Random -Minimum 0.6 -Maximum 1.6
            Update-LegAnimation
        }
    }
}

function Invoke-MoveTick {
    # Jeden snímek pohybu: pád, nebo chůze po spodním okraji aktuálního monitoru.
    $now = $clock.Elapsed.TotalSeconds
    $dt = [math]::Min($now - $state.LastTick, 0.1)   # po zaseknutí (např. uspání PC) neskákat
    $state.LastTick = $now
    if ($state.Dragging -or $null -eq $state.Area) { return }

    if ($state.Falling) {
        $r = Step-Fall -Y $state.Y -Velocity $state.VY -Dt $dt -GroundY (Get-GroundY) -Gravity $config.Gravity -RiseSpeed $config.RiseSpeed
        $state.Y = $r.Y
        $state.VY = $r.Velocity
        if ($r.Landed) {
            $state.Falling = $false
            $state.NextAreaCheck = 0.0
            if (-not $state.Paused) {
                Show-Speech (Get-RandomPhrase $dropPhrases $state.LastPhrase)
                Restart-SpeechTimer
            }
            Update-LegAnimation
        }
    } else {
        # Rozměry monitoru se můžou změnit (rozlišení, hlavní panel, odpojení monitoru, DPI)
        if ($now -ge $state.NextAreaCheck) {
            $state.NextAreaCheck = $now + $config.AreaCheckSec
            Update-WorkArea
        }
        $state.Y = Get-GroundY
        if (-not $state.Paused) {
            if ($state.RandomBehavior) { Invoke-RandomBehavior -Now $now }
            if (-not $state.Resting) {
                $r = Step-Walk -X $state.X -Direction $state.Direction -Speed (Get-CurrentSpeed) -Dt $dt -MinX (Get-MinX) -MaxX (Get-MaxX)
                $state.X = $r.X
                if ($r.Direction -ne $state.Direction) { Set-Direction $r.Direction }
            }
        }
        $state.X = Get-Clamped -Value $state.X -Min (Get-MinX) -Max (Get-MaxX)
    }
    Set-WindowPosition
}

function Invoke-SpeechTick {
    if ($state.Paused) {
        Show-Speech (Get-RandomPhrase $complaintPhrases $state.LastPhrase)
    } else {
        Show-Speech (Get-RandomPhrase $duckPhrases $state.LastPhrase)
    }
}

# ---------------------------------------------------------------------------
# Menu (pravé tlačítko na kachně) a ikona v oznamovací oblasti
# ---------------------------------------------------------------------------
function New-WpfMenuItem {
    param([string]$Header, [scriptblock]$OnClick)
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = $Header
    if ($OnClick) { $item.Add_Click($OnClick) }
    return $item
}

function Update-MenuState {
    # Popisky a zaškrtnutí podle aktuálního stavu (volá se při otevření obou menu).
    $pauseText = if ($state.Paused) { 'Pokračovat' } else { 'Pauza' }
    $menuItems.Pause.Header = $pauseText
    $menuItems.TrayPause.Text = $pauseText
    foreach ($item in $menuItems.Speed.Items) { $item.IsChecked = ($item.Header -eq $state.SpeedName) }
    foreach ($item in $menuItems.TraySpeed.DropDownItems) { $item.Checked = ($item.Text -eq $state.SpeedName) }
    $menuItems.Random.IsChecked = $state.RandomBehavior
    $menuItems.TrayRandom.Checked = $state.RandomBehavior
}

function New-DuckIcon {
    # Malá kachna pro oznamovací oblast (32x32).
    try {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 1.5
            $yellow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 251, 176, 59))
            $orange = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 241, 90, 36))
            $g.FillEllipse($yellow, 7, 14, 23, 14)
            $g.DrawEllipse($pen, 7, 14, 23, 14)
            $g.FillEllipse($yellow, 5, 3, 14, 14)
            $g.DrawEllipse($pen, 5, 3, 14, 14)
            $beak = [System.Drawing.Point[]]@(
                (New-Object System.Drawing.Point 0, 10),
                (New-Object System.Drawing.Point 7, 8),
                (New-Object System.Drawing.Point 7, 13))
            $g.FillPolygon($orange, $beak)
            $g.DrawPolygon($pen, $beak)
            $g.FillEllipse([System.Drawing.Brushes]::Black, 9, 7, 3, 3)
        } finally {
            $g.Dispose()
        }
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } catch {
        return [System.Drawing.SystemIcons]::Application
    }
}

# ---------------------------------------------------------------------------
# Sestavení okna
# ---------------------------------------------------------------------------
$window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($name in 'RootFlip', 'TextFlip', 'SpeechText', 'path2', 'path4') { $ui[$name] = $window.FindName($name) }

$clock = [System.Diagnostics.Stopwatch]::StartNew()
$state = @{
    X              = 0.0
    Y              = 0.0
    VY             = 0.0
    Direction      = 1           # 1 = doprava, -1 = doleva
    Paused         = $false
    Dragging       = $false
    Falling        = $false
    Resting        = $false
    RestUntil      = 0.0
    NextDecision   = 5.0
    SpeedFactor    = 1.0
    SpeedName      = $config.DefaultSpeed
    RandomBehavior = $config.RandomBehavior
    Area           = $null       # pracovní plocha aktuálního monitoru v DIP
    NextAreaCheck  = 0.0
    LastTick       = 0.0
    LastPhrase     = ''
    Hwnd           = [IntPtr]::Zero
    LegsReady      = $false
    ErrorShown     = $false
}

# Nohy: storyboard v kódu (ne v XAML), aby šel v pauze zastavit a zrychlit podle rychlosti chůze
$legs = New-Object System.Windows.Media.Animation.Storyboard
foreach ($leg in @(@{ Name = 'path2'; To = 35 }, @{ Name = 'path4'; To = -35 })) {
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = 0
    $anim.To = $leg.To
    $anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(1))
    $anim.AutoReverse = $true
    $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    [System.Windows.Media.Animation.Storyboard]::SetTarget($anim, $ui[$leg.Name])
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($anim,
        (New-Object System.Windows.PropertyPath ([System.Windows.Controls.Canvas]::LeftProperty)))
    $legs.Children.Add($anim)
}

# Časovače
$moveTimer = New-Object System.Windows.Threading.DispatcherTimer
$moveTimer.Interval = [TimeSpan]::FromMilliseconds($config.FrameMs)
$moveTimer.Add_Tick({
    try {
        Invoke-MoveTick
    } catch {
        if (-not $state.ErrorShown) {
            $state.ErrorShown = $true
            Write-Warning "Kachna: chyba při pohybu: $_"
        }
    }
})

$speechTimer = New-Object System.Windows.Threading.DispatcherTimer
$speechTimer.Interval = [TimeSpan]::FromSeconds($config.PhraseIntervalSec)
$speechTimer.Add_Tick({ Invoke-SpeechTick })

# Menu na pravém tlačítku
$menuItems = @{}
$menu = New-Object System.Windows.Controls.ContextMenu
$menuItems.Pause = New-WpfMenuItem 'Pauza' { Switch-Pause }
$menuItems.Pause.InputGestureText = 'klepnutí'
$menuItems.Speed = New-WpfMenuItem 'Rychlost' $null
foreach ($speedName in $config.Speeds.Keys) {
    $item = New-WpfMenuItem $speedName { Set-Speed $this.Header }
    $item.IsCheckable = $true
    [void]$menuItems.Speed.Items.Add($item)
}
$menuItems.Random = New-WpfMenuItem 'Náhodné chování' { Set-RandomBehavior $this.IsChecked }
$menuItems.Random.IsCheckable = $true
[void]$menu.Items.Add($menuItems.Pause)
[void]$menu.Items.Add($menuItems.Speed)
[void]$menu.Items.Add($menuItems.Random)
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add((New-WpfMenuItem 'Ukončit' { $window.Close() }))
$menu.Add_Opened({ Update-MenuState })
$window.ContextMenu = $menu

# Ikona v oznamovací oblasti (kachnu jde ovládat i když není vidět)
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuItems.TrayPause = New-Object System.Windows.Forms.ToolStripMenuItem 'Pauza'
$menuItems.TrayPause.Add_Click({ Switch-Pause })
$traySummon = New-Object System.Windows.Forms.ToolStripMenuItem 'Přivolat kachnu k myši'
$traySummon.Add_Click({ Invoke-Summon })
$menuItems.TraySpeed = New-Object System.Windows.Forms.ToolStripMenuItem 'Rychlost'
foreach ($speedName in $config.Speeds.Keys) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $speedName
    $item.Add_Click({ Set-Speed $this.Text })
    [void]$menuItems.TraySpeed.DropDownItems.Add($item)
}
$menuItems.TrayRandom = New-Object System.Windows.Forms.ToolStripMenuItem 'Náhodné chování'
$menuItems.TrayRandom.Add_Click({ Set-RandomBehavior (-not $state.RandomBehavior) })
$trayExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Ukončit'
$trayExit.Add_Click({ $window.Close() })
foreach ($item in @($menuItems.TrayPause, $traySummon, $menuItems.TraySpeed, $menuItems.TrayRandom,
        (New-Object System.Windows.Forms.ToolStripSeparator), $trayExit)) {
    [void]$trayMenu.Items.Add($item)
}
$trayMenu.Add_Opening({ Update-MenuState })

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-DuckIcon
$tray.Text = 'Kachna (dvojklik = přivolat k myši)'
$tray.ContextMenuStrip = $trayMenu
$tray.Add_DoubleClick({ Invoke-Summon })

# Myš: klepnutí = pauza, tažení = přesun (DragMove čeká, dokud se tlačítko nepustí)
$window.Add_MouseLeftButtonDown({
    $_.Handled = $true
    $startLeft = $window.Left
    $startTop = $window.Top
    $state.Dragging = $true
    Update-LegAnimation
    try { $window.DragMove() } catch { Write-Verbose "DragMove selhal: $_" }
    Complete-Drag -StartLeft $startLeft -StartTop $startTop
})

# Okno vzniklo (ještě není vidět): umístit na levý spodní okraj hlavního monitoru, jako ve v1
$window.Add_SourceInitialized({
    $state.Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    $state.Area = Get-WorkArea ([System.Windows.Forms.Screen]::PrimaryScreen)
    $state.X = Get-MinX
    $state.Y = Get-GroundY
    Set-WindowPosition
})

$window.Add_Loaded({
    $legs.Begin($window, $true)
    $state.LegsReady = $true
    Update-LegAnimation
    Show-Speech (Get-RandomPhrase $duckPhrases '')
    $state.LastTick = $clock.Elapsed.TotalSeconds
    $state.NextDecision = $state.LastTick + 5
    $moveTimer.Start()
    $speechTimer.Start()
})

# Neošetřená chyba v obsluze události nemá shodit celou kachnu
$window.Dispatcher.Add_UnhandledException({
    Write-Warning "Kachna: neočekávaná chyba: $($_.Exception.Message)"
    $_.Handled = $true
})

# Předběžná pozice podle hlavního monitoru (přesně se nastaví v SourceInitialized)
$primaryArea = [System.Windows.SystemParameters]::WorkArea
$window.Left = $primaryArea.Left
$window.Top = $primaryArea.Bottom - $window.Height

# ---------------------------------------------------------------------------
# Spuštění
# ---------------------------------------------------------------------------
try {
    $tray.Visible = $true
    [void]$window.ShowDialog()
} finally {
    $moveTimer.Stop()
    $speechTimer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    $trayMenu.Dispose()
}
