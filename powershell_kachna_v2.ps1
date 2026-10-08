<#
.SYNOPSIS
    Kachna v2 - kachna, která se prochází po spodním okraji obrazovky (Windows, WPF).

.DESCRIPTION
    Nová verze PowerShell kachny. Původní powershell_kachna.ps1 zůstává beze změny.

    Ovládání:
      - klepnutí levým tlačítkem ...... pauza / pokračování (v pauze si kachna každou minutu postěžuje)
      - dvojklik ...................... poskok
      - přetažení levým tlačítkem ..... přesun kachny kamkoli, i na jiný monitor; po puštění spadne dolů
      - najetí myší na bublinu ........ bublina se na chvíli schová (dá se kliknout na okno pod ní)
      - pravé tlačítko ................ menu (pauza, skrýt, skrýt na čas, nakrmit, pojď za myší, rychlosti,
                                        úsporný režim, připomínky, nastavení, ukončit)
      - ikona v oznamovací oblasti .... stejné menu + "Přivolat kachnu k myši" (také dvojklikem na ikonu);
                                        tady se skrytá kachna zase zobrazí (skrytá stojí, mlčí a nic nedělá)

    Novinky oproti v1:
      - více monitorů s různým rozlišením i škálováním (1080p, 1200p, 2K, 4K ...), chůze na sousední monitor,
      - kachna dojde až k okraji pracovní plochy a respektuje hlavní panel na libovolné straně,
      - plynulý pohyb řízený animacemi WPF, bublina je vždy u hlavy a přizpůsobí se délce textu,
      - hlášky podle denní doby, svátků, baterie a ušlé vzdálenosti; připomínky (pitný režim, Pomodoro),
      - náhodné chování, krmení rohlíkem, "Pojď za myší", poskok, sezónní převleky, volitelný zvuk,
      - úspornost: omezené snímky animací, usnutí při nečinnosti, skrytí při zamčení PC, úsporný režim na baterii,
      - reakce na změnu rozlišení nebo odpojení monitoru (kachna nezmizí mimo obrazovku).

.NOTES
    Spuštění: dvojklik na powershell_kachna_v2.cmd
        nebo: powershell -NoProfile -ExecutionPolicy Bypass -File .\powershell_kachna_v2.ps1
    Funguje ve Windows PowerShell 5.1 i v PowerShell 7 (jen Windows).
    Soubor musí zůstat v kódování UTF-8 s BOM, jinak PowerShell 5.1 rozbije diakritiku.
    Testy (lze spustit i na Linuxu v pwsh): tests/Test-KachnaV2.ps1
    Měření spotřeby běžící kachny (Windows): tests/Measure-KachnaV2.ps1
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
    Speeds               = [ordered]@{ 'Pomalá' = 8; 'Normální' = 15; 'Rychlá' = 35 }  # rychlost chůze v DIP za sekundu
    DefaultSpeed         = 'Normální' # odpovídá rychlosti v1 (5 px každých 350 ms = 14,3 px/s)
    LegsBaseSpeed        = 15         # při této rychlosti nohy kmitají jednou za sekundu (jako ve v1)
    PhraseSpeeds         = [ordered]@{ 'Pomalá' = 15; 'Normální' = 8; 'Rychlá' = 4 }  # po kolika sekundách kachna při chůzi mluví
    DefaultPhraseSpeed   = 'Normální'
    ComplaintIntervalSec = 60         # jak často si kachna stěžuje v pauze (nezávisí na rychlosti hlášek)
    BubbleSec            = 5          # jak dlouho zůstane bublina vidět (0 = pořád)
    ReminderBubbleSec    = 15         # připomínka zůstane vidět déle
    BubbleHoverSec       = 3          # na jak dlouho se bublina schová, když na ni najede myš
    Gravity              = 3000       # zrychlení pádu (DIP/s²)
    RiseSpeed            = 800        # rychlost vynoření, když kachnu pustíš pod spodní okraj (DIP/s)
    HopHeight            = 60         # výška poskoku (DIP)
    ClickTolerance       = 4          # největší posun (DIP), který se ještě bere jako klepnutí
    HeartbeatSec         = 1          # jak často kachna "přemýšlí" (bublina, náhodné chování, připomínky, nečinnost)
    FollowHeartbeatSec   = 0.25       # ... když jde za myší (aby stíhala kurzor)
    SleepCheckSec        = 2          # spící kachna jen jednou za 2 s zkontroluje, jestli se pohnula myš
    IdleSleepMin         = 10         # po kolika minutách bez pohybu myši kachna usne (0 = nikdy)
    AreaCheckSec         = 5          # pojistka: jak často znovu načíst rozměry monitoru (jinak stačí události Windows)
    PowerCheckSec        = 60         # pojistka: jak často zjistit napájení (síť / baterie) a datum pro převlek
    RandomBehavior       = $false      # náhodné zastavení / otočení / změna tempa
    CrossMonitors        = $true      # chůze přes okraj na sousední monitor
    Costumes             = $true      # převleky podle ročního období
    Sound                = $false     # kvák při klepnutí, poskoku, jídle a připomínce
    Topmost              = $true      # kachna vždy navrchu
    Fps                  = @{ Legs = 24; Glow = 10; WalkMin = 8; WalkMax = 30; Fall = 60 }  # snímky za sekundu (WPF jinak kreslí ~60x/s)
    EcoFps               = @{ Legs = 12; Glow = 0; WalkMin = 6; WalkMax = 15; Fall = 30 }   # úsporný režim (Glow 0 = tělo nemění barvu)
    EcoPhraseFactor      = 2          # v úsporném režimu kachna mluví 2x méně často
    EcoModes             = [ordered]@{ 'Vypnutý' = 'Off'; 'Na baterii' = 'Battery'; 'Vždy' = 'On' }
    DefaultEco           = 'Vypnutý'
    HideChoices          = [ordered]@{ '15 minut' = 15; '30 minut' = 30; '1 hodinu' = 60; '2 hodiny' = 120 }
    Reminders            = [ordered]@{ Drink = 60; Stretch = 120 }   # připomínky: po kolika minutách
    PomodoroMin          = @{ Work = 25; Break = 5 }
    EatSec               = 2          # jak dlouho kachna jí rohlík
    CrumbSize            = @{ Width = 40; Height = 24 }  # okno s rohlíkem (DIP, stejně jako v $crumbXaml)
    BeakOffset           = 235        # zobák od levého okraje okna, když kachna jde doprava (DIP)
    SoftwareRendering    = $true      # kreslit bez grafické karty: u malého průhledného okna obvykle levnější (změř tests/Measure-KachnaV2.ps1)
    Priority             = 'BelowNormal'  # kachna nikdy nezpomalí práci
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
    "Nechť tě provází Síla... a střídka chleba.",
    "Toto nejsou kachny, které hledáte.",
    "Mám vyšší břeh, ${Env:UserName}!",
    "Kvákej, nebo nekvákej. Žádné 'zkusím to' neexistuje.",
    "Jednou ti povím o Temné straně rybníka...",
    "Houstone, máme problém...",
    "Jsem král světa! A tohle je můj rybník!",
    "Nejsi ty... tak trochu kachna?",
    "Co se stane ve Vegas, zůstane ve Vegas....",
    "Jdu do toho... po hlavě do rybníka!",
    "Lži mají krátká křídla... a já potřebuju nová.",
    "Na zdraví! A na další potopené rohlíky!",
    "Toto je jen začátek... mého panování nad rybníkem!",
    "Jeden prsten vládne všem... a já chci ten s největší houskou."
    "Hasta la vista, káčátko.",
    "Já se vrátím... pro ten druhý rohlík.",
    "Ve vesmíru tě nikdo neslyší kvákat.",
    "Vezmeš si červeného červíka, nebo modrého?",
    "Žádná lžička neexistuje. Jen zobák.",
    "Odvážně se vydat tam, kam se ještě žádná kachna nevydala!",
    "Neprojdeš dál! Tento rybník je můj!",
    "Můj milášek... můj křupavý rohlíček!",
    "Zima přichází... a s ní zamrzne rybník.",
    "Nevíš nic, ${Env:UserName}!",
    "Jsi kachna, ${Env:UserName}.",
    "Expecto Rohlíku!",
    "První pravidlo Kachního klubu je: nemluvit o Kachním klubu.",
    "Jméno je Pond. Duck Pond.",
    "Protřepat, nemíchat. A rohlík nadrobit.",
    "Dám mu nabídku, kterou nemůže odmítnout... plnou misku zrní.",
    "Život je jako krabice rohlíků... nikdy nevíš, který bude tvrdý.",
    "S velkým kvákáním přichází velká odpovědnost.",
    "Před 3 miliony let kachny vládly vesmíru.",
    "Bazinga! Teda... Kvák!",
    "Ševron 7 uzamčen! Cílová planeta: Rybník.",
    "Pozor na kawoosh! Zmokne vám peří!",
    "Kam vede tato cesta? Doufám, že přímo do pekárny.",
    "Zatáhněte Iris! Ten rohlík letí moc rychle!",
    "Jaffa, Kree! ...Teda, Kachna, Kree!"
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
    "Malá pauza na čištění peří.",
    "GPS přehodnocuje trasu...",
    "Zapomněla jsem, pro co jsem to vlastně šla.",
    "Kdo jsem? Kam kráčím? Proč vlastně kačím?",
    "Sakra, nechala jsem doma zapnutou plotýnku?",
    "Taktická bezpečnostní přestávka.",
    "Předstírám, že jsem socha."
)

# Po zobrazení skryté kachny
$showPhrases = @(
    "Kuk! Už jsem zpátky!",
    "Chyběla jsem ti?",
    "Tak kde jsem to skončila?",
    "Konec schovávané!",
    "Byla jsem si jen zaplavat."
)

# Po odemčení počítače (kachnu schovalo zamčení)
$welcomePhrases = @(
    "Vítej zpět!",
    "Konečně! Už jsem se nudila.",
    "Ahoj! Hlídala jsem ti počítač.",
    "Kvák! Jak bylo venku?"
)

# Usínání (nikdo nehýbe myší) a probuzení
$sleepPhrases = @(
    "Zzz...",
    "Zzz... rohlíky... zzz...",
    "Chrr... kvák... zzz..."
)
$wakePhrases = @(
    "Á, už jsi zpátky!",
    "Nespala jsem, jen jsem šetřila energii.",
    "Kvák! Už jsem vzhůru!",
    "Zdálo se mi o rybníku plném rohlíků..."
)

# Poskok po dvojkliku
$hopPhrases = @(
    "Hop!",
    "Juchů!",
    "Skáču radostí!",
    "Hop a kvák!"
)

# Po přechodu na sousední monitor
$crossPhrases = @(
    "Jé, nový monitor!",
    "Tady jsem ještě nebyla!",
    "Hraniční přechod... nic k proclení, jen peří.",
    "Dobrý den, sousedé!"
)

# Krmení rohlíkem
$foodPhrases = @(
    "Rohlík! Už běžím!",
    "To je pro mě? Jdu na to!",
    "Moje! Všechno moje!"
)
$eatPhrases = @(
    "Mňam!",
    "Mňam mňam, děkuju!",
    "To byl nejlepší rohlík mého života!",
    "Kvák! Ještě jeden?"
)

# Pojď za myší
$followPhrases = @(
    "Jdu za tebou!",
    "Počkej na mě!",
    "Kam jdeme?"
)

# Připomínky (modrá bublina)
$reminderPhrases = @{
    Drink         = @("Napij se! Kachny pijou pořád.", "Pitný režim! Sklenička vody neuškodí.", "Čas na doušek! Já si skočím do rybníka.")
    Stretch       = @("Protáhni se! Kachny to dělají pořád.", "Vstaň a protáhni se, já ti pohlídám počítač.", "Zamávej křídly! Teda rukama.")
    PomodoroStart = @("Pomodoro začíná: 25 minut soustředění. Budu potichu... skoro.")
    PomodoroBreak = @("Pomodoro: 25 minut hotovo! Teď 5 minut pauza.", "Pauza! Odvrať oči od obrazovky a protáhni se.")
    PomodoroWork  = @("Pauza skončila. Zpátky do práce!", "Pomodoro: dalších 25 minut soustředění!")
}

# Hlášky podle situace (Get-SituationPhrase): denní doba, svátky, baterie, ušlá vzdálenost, jak dlouho kachna běží.
# {0} doplní skript (procenta baterie, vzdálenost, doba).
$situationPhrases = @{
    Morning    = @("Dobré ráno, ${Env:UserName}! Kafe už bylo?", "Ráno je moudřejší večera. A kachna je moudřejší než obojí.")
    Lunch      = @("Oběd! Kdo má rohlík?", "Můj žaludek říká, že je čas na oběd.")
    Afternoon  = @("Odpolední krize? Dej si kvák... teda kafe.", "Odpoledne se mi vždycky chce spát.")
    Evening    = @("Už je večer. Nechceš jít domů?", "Večer je na rybníku nejhezčí.")
    Night      = @("Kachny už spí. A ty?", "Je noc, ${Env:UserName}! Jdi spát.")
    Monday     = @("Pondělí... to zvládneme.", "Pondělí je jen pátek obráceně.")
    Friday     = @("Pátek odpoledne! Víkend na obzoru!", "Pátek! Kvákám radostí.")
    NewYear    = @("Šťastný nový rok! Předsevzetí: víc rohlíků.")
    Valentine  = @("Dneska je Valentýn. Kvák a pusu!")
    AprilFool  = @("Dneska věř jen kachnám.", "Apríl! Teda... kvák.")
    MayDay     = @("Lásky čas! Dáš mi pusu pod rozkvetlou třešní?")
    Holiday    = @("Dneska je státní svátek. Proč jsme v práci?")
    Republic   = @("Všechno nejlepší, republiko!")
    Halloween  = @("Bú! Strašidelná kachna!", "Koledu, nebo rohlík!")
    Advent     = @("Už máš dárky? Já chci rohlík.", "Advent! Peču perníčky... teda drobky.")
    Christmas  = @("Veselé Vánoce! Kapr ne, já jsem kachna!", "Šťastné a veselé! Rozbalíme dárky?")
    NewYearEve = @("Silvestr! Pozor na rachejtle, peří mám jen jedno.")
    Easter     = @("Hody, hody, doprovody, dejte kachně rohlíky!", "Veselé Velikonoce! Vejce jsem nesnesla.")
    Battery    = @("Mám jen {0} % baterie! Dej mi nabíječku!", "Baterie {0} %! Kvák, nabíječku!")
    Distance   = @("Dnes jsem ušla už {0}!", "Ušla jsem {0}. Zasloužím si rohlík.")
    Uptime     = @("Už spolu chodíme {0}.", "Jsem s tebou už {0}. Kvák!")
}

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

        <!-- Bublina: výška se přizpůsobí textu, ocásek míří před hlavu kachny; po chvíli se schová (Visibility).
             Ocásek má stejnou barvu jako bublina (připomínky jsou modré). -->
        <Grid x:Name="SpeechBubble" Grid.Row="0" Width="230" Margin="0,0,6,0"
              HorizontalAlignment="Right" VerticalAlignment="Bottom">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="16"/>
            </Grid.RowDefinitions>
            <Border x:Name="SpeechBorder" Grid.Row="0" Background="White" BorderBrush="Black" BorderThickness="2"
                    CornerRadius="16" Padding="10,6,10,6">
                <TextBlock x:Name="SpeechText" Text="Kvák!" FontSize="14" TextWrapping="Wrap"
                           TextAlignment="Center" RenderTransformOrigin="0.5,0.5">
                    <TextBlock.RenderTransform>
                        <ScaleTransform x:Name="TextFlip" ScaleX="1"/>
                    </TextBlock.RenderTransform>
                </TextBlock>
            </Border>
            <!-- Ocásek bubliny: neuzavřená cesta = bílá výplň překryje okraj bubliny, obrys jen po stranách -->
            <Path Grid.Row="1" Fill="{Binding Background, ElementName=SpeechBorder}" Stroke="Black" StrokeThickness="2" StrokeLineJoin="Round"
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
                    <!-- nohy (path2, path4) i barvu těla (path6) animuje skript, aby šly zastavit (pauza, skrytí, spánek);
                         nohy se posouvají přes TranslateTransform, ne Canvas.Left (animace pak nepřepočítává rozvržení) -->
                    <Path Name="path2" Fill="#FFF15A24" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10">
                        <Path.RenderTransform>
                            <TranslateTransform/>
                        </Path.RenderTransform>
                        <Path.Data>
                            <PathGeometry Figures="m 236.71 379.105 c 0 0 15.237 39.537 12.767 58.895 -12.767 -1.854 -32.535 -6.796 -32.535 -6.796 0 0 -9.678 -1.44 -11.738 0.824 -2.06 2.264 -22.239 2.678 -23.475 4.942 -1.235 2.265 -2.266 5.765 -2.06 8.442 0.207 2.677 -8.648 9.265 -7.619 10.913 1.029 1.648 0 2.06 9.678 2.678 9.678 0.617 80.929 1.441 84.84 0 3.912 -1.442 2.677 -12.149 2.471 -14.827 -0.207 -2.677 -18.122 -62.394 -21.623 -65.071 -3.501 -2.677 -4.943 -4.53 -6.59 -4.324 -1.647 0.206 -4.116 4.324 -4.116 4.324 z" FillRule="NonZero"/>
                        </Path.Data>
                    </Path>
                    <Path Name="path4" Fill="#FFF15A24" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10">
                        <Path.RenderTransform>
                            <TranslateTransform/>
                        </Path.RenderTransform>
                        <Path.Data>
                            <PathGeometry Figures="m 295.125 387.11 c 0.57 2.084 4.012 3.529 5.322 5.415 1.521 2.189 3.158 4.339 4.6 6.573 2.977 4.61 5.327 9.352 8.11 13.996 3.083 5.144 6.027 10.228 7.747 15.981 0.76 2.54 3.21 6.122 1.555 8.715 -1.529 2.396 -6.157 2.751 -8.732 2.85 -13.666 0.529 -27.399 2.356 -41.175 1.653 -3.563 -0.182 -7.601 -0.675 -11.114 0.046 -2.211 0.454 -7.535 0.332 -8.68 2.641 -1.548 3.125 2.679 4.707 3.261 7.439 0.532 2.495 -1.232 7.147 0.495 9.049 1.76 1.938 7.09 1.217 9.472 1.688 3.12 0.619 6.549 0.665 8.939 2.644 5.092 4.212 9.153 7.027 15.656 7.703 6.848 0.71 13.464 -0.589 20.046 -1.654 2.795 -0.453 5.258 -1.797 8.061 -2.492 3.057 -0.759 5.883 -1.205 8.687 -2.457 4.99 -2.23 10.663 -5.058 15.247 -8.526 4.371 -3.306 9.693 -7.151 8.938 -13.61 -0.595 -5.099 -5.257 -9.845 -8.07 -13.836 -1.54 -2.185 -2.372 -4.854 -3.876 -7.275 -1.546 -2.487 -3.848 -4.371 -5.372 -6.997 -3.106 -5.339 -6.187 -10.626 -10.127 -15.536 -1.645 -2.047 -3.355 -4.463 -5.271 -6.304 -1.238 -1.188 -2.564 -2.273 -3.513 -3.58 -0.748 -1.033 -1.278 -2.461 -2.263 -3.447 -2.027 -2.022 -4.501 -3.383 -6.568 -5.265 -2.117 -1.926 -4.144 -3.803 -6.452 -5.534 -2.18 -1.636 -6.334 -2.913 -9.215 -1.808 -2.962 1.136 -3.74 5.54 -3.14 8.405 0.606 2.904 3.602 3.971 6.401 3.938" FillRule="NonZero"/>
                        </Path.Data>
                    </Path>
                    <Path Name="path6" Fill="#FFFBB03B" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10">
                        <Path.Data>
                            <PathGeometry Figures="m 547 213 c -5 195.449 -202 195.449 -315.54 195.449 -70.991 0 -128.54 -57.55 -128.54 -128.54 0 -70.991 57.549 -128.54 128.54 -128.54 C 302.451 151.369 381 262 547 213 Z" FillRule="NonZero"/>
                        </Path.Data>
                    </Path>
                    <Ellipse Canvas.Left="124.3" Canvas.Top="31.5" Width="165" Height="165" Name="circle8" Fill="#FFFBB03B" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10"/>
                    <Path Name="path10" Fill="#FFF15A24" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10">
                        <Path.Data>
                            <PathGeometry Figures="m 60.697 124.416 c 7.819 39.094 44.355 36.277 68.726 36.277 15.656 0 28.347 -12.692 28.347 -28.347 0 -15.656 -12.69 -28.347 -28.347 -28.347 -14.871 0 -30.469 22.551 -64.097 15.042 -2.398 0.001 -4.629 2.344 -4.629 5.375 z" FillRule="NonZero"/>
                        </Path.Data>
                    </Path>
                    <Ellipse Canvas.Left="158.8" Canvas.Top="68" Width="40" Height="40" Name="circle12" Fill="#FFFFFFFF" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10"/>
                    <Ellipse Canvas.Left="171.3" Canvas.Top="80.5" Width="15" Height="15" Name="circle14" Fill="#000000" StrokeThickness="5" Stroke="#FF000000" StrokeMiterLimit="10"/>
                    <!-- zavřené oko (spánek, Set-EyesClosed) -->
                    <Path x:Name="SleepEye" Visibility="Hidden" Stroke="#FF000000" StrokeThickness="5"
                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" Data="M 160,86 C 166,98 192,98 198,86"/>
                    <!-- Sezónní převleky (Update-Costume). Čepice přesahují nad ořez kresby do volného místa pod bublinou
                         (Canvas ani Viewbox neořezávají); test hlídá, že nezasahují do bubliny ani do ocásku. -->
                    <Canvas x:Name="CostumeSanta" Visibility="Collapsed">
                        <Path Fill="#FFD62828" Stroke="#FF000000" StrokeThickness="4" StrokeLineJoin="Round"
                              Data="M 170,44 C 176,10 220,-6 258,0 C 290,4 312,22 322,44 C 304,38 286,40 272,52 Z"/>
                        <Path Fill="#FFFFFFFF" Stroke="#FF000000" StrokeThickness="4" StrokeLineJoin="Round"
                              Data="M 164,52 C 176,24 258,20 282,50 L 276,64 C 254,40 184,42 174,62 Z"/>
                        <Ellipse Canvas.Left="311" Canvas.Top="35" Width="26" Height="26" Fill="#FFFFFFFF" Stroke="#FF000000" StrokeThickness="4"/>
                    </Canvas>
                    <Canvas x:Name="CostumeWitch" Visibility="Collapsed">
                        <Path Fill="#FF2E1A47" Stroke="#FF000000" StrokeThickness="4" StrokeLineJoin="Round"
                              Data="M 176,38 C 190,20 200,6 214,2 C 230,-2 252,2 272,14 C 256,14 244,22 246,38 Z"/>
                        <Path Fill="#FF8E44AD" Stroke="#FF000000" StrokeThickness="2"
                              Data="M 178,34 C 200,29 228,29 246,33 L 246,25 C 226,21 200,21 181,26 Z"/>
                        <Ellipse Canvas.Left="134" Canvas.Top="29" Width="156" Height="22" Fill="#FF2E1A47" Stroke="#FF000000" StrokeThickness="4"/>
                    </Canvas>
                    <Canvas x:Name="CostumeGlasses" Visibility="Collapsed">
                        <Path Stroke="#FF1E1E1E" StrokeThickness="7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Data="M 206,80 L 262,71"/>
                        <Path Stroke="#FF1E1E1E" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Data="M 150,82 L 136,87"/>
                        <Path Fill="#FF1E1E1E" Stroke="#FF000000" StrokeThickness="3"
                              Data="M 148,77 C 148,66 206,66 208,78 C 210,96 200,108 180,108 C 160,108 148,96 148,77 Z"/>
                        <Path Stroke="#B3FFFFFF" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                              Data="M 158,80 C 164,74 176,73 186,74"/>
                    </Canvas>
                </Canvas>
            </Canvas>
        </Viewbox>
    </Grid>
</Window>
'@

# Rohlík pro krmení: malé průhledné okno, vznikne až při prvním krmení (Show-Crumb)
[xml]$crumbXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    Title="Rohlík"
    Width="40"
    Height="24"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="False"
    ShowActivated="False"
    ResizeMode="NoResize"
    IsHitTestVisible="False">
    <Canvas>
        <Path Fill="#FFE3A857" Stroke="#FF7A4A12" StrokeThickness="2" StrokeLineJoin="Round"
              Data="M 3,20 C 6,4 34,4 37,20 C 30,14 10,14 3,20 Z"/>
        <Path Stroke="#FF7A4A12" StrokeThickness="1.5" Data="M 13,10 L 15,15 M 20,8 L 20,13 M 27,10 L 25,15"/>
    </Canvas>
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

function Test-SameArea {
    # Stejná plocha monitoru (s tolerancí na zaokrouhlení DIP).
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    foreach ($side in 'Left', 'Top', 'Right', 'Bottom') {
        if ([math]::Abs($A.$side - $B.$side) -gt 0.01) { return $false }
    }
    return $true
}

function Get-FallPlan {
    # Pád na zem (GroundY) jako animace: volný pád z klidu je přesně kvadratická křivka (QuadraticEase EaseIn),
    # kachna pod zemí (puštěná nad hlavním panelem) se rovnoměrně vynoří. Vrací dobu a typ křivky.
    param([double]$Y, [double]$GroundY, [double]$Gravity, [double]$RiseSpeed)
    $height = $GroundY - $Y
    if ($height -lt 0) { return [pscustomobject]@{ Seconds = (-$height) / $RiseSpeed; Ease = 'Linear' } }
    return [pscustomobject]@{ Seconds = [math]::Sqrt(2 * $height / $Gravity); Ease = 'EaseIn' }
}

function Get-WalkFrameRate {
    # Snímky za sekundu pro chůzi: zhruba 1 pixel na snímek (víc snímků by okno stejně neposunulo), v mezích Min..Max.
    param([double]$Speed, [double]$PxPerDip, [double]$Min, [double]$Max)
    return [int](Get-Clamped -Value ([math]::Ceiling($Speed * $PxPerDip)) -Min $Min -Max $Max)
}

function Find-NeighborArea {
    # Sousední monitor ve směru chůze: jeho hrana navazuje na hranu aktuálního monitoru (podle celých monitorů,
    # hlavní panel mezi nimi nevadí) a kachna by na něm byla vidět aspoň z poloviny výšky.
    param($Current, $Areas, [int]$Direction, [double]$Top, [double]$Height)
    $cur = if ($Current.Bounds) { $Current.Bounds } else { $Current }
    foreach ($area in $Areas) {
        if (Test-SameArea $area $Current) { continue }
        $b = if ($area.Bounds) { $area.Bounds } else { $area }
        $gap = if ($Direction -gt 0) { $b.Left - $cur.Right } else { $cur.Left - $b.Right }
        if ([math]::Abs($gap) -gt 2) { continue }
        $overlap = [math]::Min($Top + $Height, $area.Bottom) - [math]::Max($Top, $area.Top)
        if ($overlap -ge $Height / 2) { return $area }
    }
    return $null
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

function Format-Decimal {
    # Číslo s nejvýš jedním desetinným místem a desetinnou čárkou (nezávisle na jazyce Windows).
    param([double]$Value)
    return ([math]::Round($Value, 1)).ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture).Replace('.', ',')
}

function Get-DistanceText {
    # Ušlá vzdálenost do hlášky: DIP je 1/96 palce (2,54 cm).
    param([double]$Dip)
    $cm = $Dip / 96 * 2.54
    if ($cm -lt 100) { return '{0} cm' -f [int][math]::Round($cm) }
    if ($cm -lt 100000) { return ((Format-Decimal ($cm / 100)) + ' m') }
    return ((Format-Decimal ($cm / 100000)) + ' km')
}

function Get-DurationText {
    # Doba do hlášky: "45 min", "2 h", "2 h 15 min".
    param([double]$Minutes)
    $total = [int][math]::Floor($Minutes)
    $hours = [int][math]::Floor($total / 60)
    $rest = $total % 60
    if ($hours -eq 0) { return "$rest min" }
    if ($rest -eq 0) { return "$hours h" }
    return "$hours h $rest min"
}

function Get-EasterSunday {
    # Velikonoční neděle (gregoriánský kalendář, tzv. anonymní algoritmus).
    param([int]$Year)
    $a = $Year % 19
    $b = [math]::Floor($Year / 100)
    $c = $Year % 100
    $d = [math]::Floor($b / 4)
    $e = $b % 4
    $f = [math]::Floor(($b + 8) / 25)
    $g = [math]::Floor(($b - $f + 1) / 3)
    $h = (19 * $a + $b - $d - $g + 15) % 30
    $i = [math]::Floor($c / 4)
    $k = $c % 4
    $l = (32 + 2 * $e + 2 * $i - $h - $k) % 7
    $m = [math]::Floor(($a + 11 * $h + 22 * $l) / 451)
    $n = $h + $l - 7 * $m + 114
    return New-Object DateTime $Year, ([int][math]::Floor($n / 31)), ([int]($n % 31) + 1)
}

function Get-SituationKey {
    # Které situační hlášky teď platí: denní doba, pondělní ráno, páteční odpoledne, svátky (jen z data a času).
    param([datetime]$Now)
    $keys = New-Object System.Collections.Generic.List[string]
    $hour = $Now.Hour + $Now.Minute / 60
    if ($hour -ge 6 -and $hour -lt 9) { $keys.Add('Morning') }
    elseif ($hour -ge 11.5 -and $hour -lt 13) { $keys.Add('Lunch') }
    elseif ($hour -ge 14 -and $hour -lt 16) { $keys.Add('Afternoon') }
    elseif ($hour -ge 18 -and $hour -lt 22) { $keys.Add('Evening') }
    elseif ($hour -ge 22 -or $hour -lt 5) { $keys.Add('Night') }
    if ($Now.DayOfWeek -eq 'Monday' -and $hour -lt 12) { $keys.Add('Monday') }
    if ($Now.DayOfWeek -eq 'Friday' -and $hour -ge 12) { $keys.Add('Friday') }
    $day = $Now.Month * 100 + $Now.Day
    $holidays = @{
        101 = 'NewYear'; 214 = 'Valentine'; 401 = 'AprilFool'; 501 = 'MayDay'; 508 = 'Holiday'; 705 = 'Holiday'; 706 = 'Holiday'
        928 = 'Holiday'; 1028 = 'Republic'; 1031 = 'Halloween'; 1117 = 'Holiday'; 1224 = 'Christmas'; 1225 = 'Christmas'
        1226 = 'Christmas'; 1231 = 'NewYearEve'
    }
    if ($holidays.ContainsKey($day)) { $keys.Add($holidays[$day]) }
    elseif ($day -ge 1201 -and $day -le 1223) { $keys.Add('Advent') }
    $fromEaster = ($Now.Date - (Get-EasterSunday $Now.Year)).Days
    if ($fromEaster -ge -2 -and $fromEaster -le 1) { $keys.Add('Easter') }   # Velký pátek až Velikonoční pondělí
    return $keys.ToArray()
}

function Get-SituationPhrase {
    # Hlášky podle situace: denní doba a svátky, slabá baterie, ušlá vzdálenost, jak dlouho kachna běží.
    param([datetime]$Now, $Power, [double]$DistanceDip, [double]$UptimeMin)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($key in @(Get-SituationKey $Now)) {
        foreach ($phrase in $situationPhrases[$key]) { $list.Add($phrase) }
    }
    if ($null -ne $Power -and $Power.OnBattery -and $Power.Percent -le 20) {
        foreach ($phrase in $situationPhrases.Battery) { $list.Add(($phrase -f $Power.Percent)) }
    }
    if ($DistanceDip -ge 96 / 2.54 * 100) {   # aspoň metr
        $text = Get-DistanceText $DistanceDip
        foreach ($phrase in $situationPhrases.Distance) { $list.Add(($phrase -f $text)) }
    }
    if ($UptimeMin -ge 60) {
        $text = Get-DurationText $UptimeMin
        foreach ($phrase in $situationPhrases.Uptime) { $list.Add(($phrase -f $text)) }
    }
    return $list.ToArray()
}

function Get-Costume {
    # Převlek podle data: mikulášská čepice (prosinec až Tři králové), čarodějnický klobouk (konec října),
    # sluneční brýle (léto). Jinak bez převleku.
    param([datetime]$Date)
    $day = $Date.Month * 100 + $Date.Day
    if ($day -ge 1201 -or $day -le 106) { return 'Santa' }
    if ($day -ge 1024 -and $day -le 1031) { return 'Witch' }
    if ($day -ge 621 -and $day -le 831) { return 'Glasses' }
    return ''
}

function New-QuackWave {
    # Krátké "kvák" jako WAV (16 bit, mono): pilovitý tón s klesající výškou, rychlý náběh a doznění.
    # Vrací pole bajtů (přehraje se z paměti, žádný soubor není potřeba).
    param([int]$SampleRate = 22050, [double]$Seconds = 0.22)
    $count = [int]($SampleRate * $Seconds)
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $stream
    $ascii = [System.Text.Encoding]::ASCII
    $writer.Write($ascii.GetBytes('RIFF'))
    $writer.Write([int](36 + 2 * $count))
    $writer.Write($ascii.GetBytes('WAVEfmt '))
    $writer.Write([int]16)
    $writer.Write([int16]1)                  # PCM
    $writer.Write([int16]1)                  # mono
    $writer.Write([int]$SampleRate)
    $writer.Write([int]($SampleRate * 2))    # bajtů za sekundu
    $writer.Write([int16]2)
    $writer.Write([int16]16)
    $writer.Write($ascii.GetBytes('data'))
    $writer.Write([int](2 * $count))
    $phase = 0.0
    for ($i = 0; $i -lt $count; $i++) {
        $t = $i / $count
        $phase += (520 - 220 * $t) / $SampleRate              # výška klesá z 520 na 300 Hz
        $saw = 2 * ($phase - [math]::Floor($phase)) - 1
        $envelope = [math]::Min(1.0, $t * 25) * [math]::Pow(1 - $t, 1.5)
        $writer.Write([int16][math]::Round(9000 * $saw * $envelope))
    }
    $writer.Flush()
    return , $stream.ToArray()
}

# ---------------------------------------------------------------------------
# Windows: monitory, myš, napájení, čas, animace okna, rohlík, zvuk
# (malé funkce závislé na WPF/WinForms, testy je nahrazují; WinForms Screen vrací pixely, WPF pracuje v DIP)
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
    # Pracovní plocha monitoru (bez hlavního panelu) v DIP; Bounds = celý monitor (hledání sousedních monitorů).
    param($Screen)
    $scale = Get-DipScale
    $wa = $Screen.WorkingArea
    $b = $Screen.Bounds
    $area = ConvertTo-DipRect -Left $wa.Left -Top $wa.Top -Right $wa.Right -Bottom $wa.Bottom -ScaleX $scale[0] -ScaleY $scale[1]
    $bounds = ConvertTo-DipRect -Left $b.Left -Top $b.Top -Right $b.Right -Bottom $b.Bottom -ScaleX $scale[0] -ScaleY $scale[1]
    $area | Add-Member -NotePropertyName Bounds -NotePropertyValue $bounds
    return $area
}

function Get-WindowArea { Get-WorkArea ([System.Windows.Forms.Screen]::FromHandle($state.Hwnd)) }

function Get-CursorArea { Get-WorkArea ([System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)) }

function Get-AreaList { @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { Get-WorkArea $_ }) }

function Get-CursorDip {
    $pos = [System.Windows.Forms.Cursor]::Position
    $scale = Get-DipScale
    return [pscustomobject]@{ X = $pos.X * $scale[0]; Y = $pos.Y * $scale[1] }
}

function Get-CursorKey {
    # Poloha kurzoru jako text: stačí ke zjištění, jestli se myš pohnula (nečinnost).
    $pos = [System.Windows.Forms.Cursor]::Position
    return "$($pos.X),$($pos.Y)"
}

function Get-PowerInfo {
    # Napájení: běží počítač na baterii a kolik má procent?
    $power = [System.Windows.Forms.SystemInformation]::PowerStatus
    return [pscustomobject]@{
        OnBattery = ("$($power.PowerLineStatus)" -eq 'Offline')
        Percent   = [int][math]::Round($power.BatteryLifePercent * 100)
    }
}

function Get-Now { Get-Date }

function Start-WindowAnimation {
    # Plynulý pohyb okna animací WPF (Left = chůze, Top = pád a poskok); po doběhnutí zavolá Complete-Motion.
    # PowerShell mezitím nic nedělá. Snímky za sekundu omezuje DesiredFrameRate.
    param([string]$Property, [double]$From, [double]$To, [double]$Seconds, [int]$Fps, [string]$Ease = 'Linear')
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = $From
    $anim.To = $To
    $anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds([math]::Max($Seconds, 0.001)))
    if ($Ease -ne 'Linear') {
        $curve = New-Object System.Windows.Media.Animation.QuadraticEase
        $curve.EasingMode = $Ease    # EaseIn = volný pád z klidu, EaseOut = výskok (zpomaluje)
        $anim.EasingFunction = $curve
    }
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($anim, $Fps)
    # Completed staré (nahrazené) animace se nesmí splést s novou
    $state.MotionId++
    $anim.Name = 'Pohyb' + $state.MotionId
    $anim.Add_Completed({ if ($this.Timeline.Name -eq ('Pohyb' + $state.MotionId)) { Complete-Motion } })
    $target = if ($Property -eq 'Left') { [System.Windows.Window]::LeftProperty } else { [System.Windows.Window]::TopProperty }
    $window.BeginAnimation($target, $anim)
}

function Stop-WindowAnimation {
    # Uvolní polohu okna z animace tam, kde právě je: nejdřív základní hodnota = aktuální poloha, pak sundat
    # animaci (jinak by okno na okamžik skočilo zpět na hodnotu před animací).
    foreach ($target in @([System.Windows.Window]::LeftProperty, [System.Windows.Window]::TopProperty)) {
        $window.SetValue($target, $window.GetValue($target))
        $window.BeginAnimation($target, $null)
    }
}

function Set-FrameRate {
    # Kolikrát za sekundu WPF animaci přepočítá a překreslí (DesiredFrameRate; platí od dalšího Begin).
    param($Storyboard, [int]$Fps)
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($Storyboard, $Fps)
}

function Show-Crumb {
    # Rohlík: malé průhledné okno, které spadne na zem stejně jako kachna (okno vznikne až při prvním krmení).
    param([double]$X, [double]$Y, [double]$GroundY, [double]$Seconds, [int]$Fps)
    if ($null -eq $state.CrumbWindow) {
        $state.CrumbWindow = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $crumbXaml))
    }
    $crumb = $state.CrumbWindow
    $crumb.BeginAnimation([System.Windows.Window]::TopProperty, $null)
    $crumb.Topmost = $state.Topmost
    $crumb.Left = $X
    $crumb.Top = $Y
    $crumb.Show()
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = $Y
    $anim.To = $GroundY
    $anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds([math]::Max($Seconds, 0.001)))
    $curve = New-Object System.Windows.Media.Animation.QuadraticEase
    $curve.EasingMode = 'EaseIn'
    $anim.EasingFunction = $curve
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($anim, $Fps)
    $crumb.BeginAnimation([System.Windows.Window]::TopProperty, $anim)
}

function Hide-Crumb { if ($null -ne $state.CrumbWindow) { $state.CrumbWindow.Hide() } }

function Start-Sound {
    # Přehraje kvák: kvak.wav vedle skriptu, jinak vygenerovaný zvuk (přehrávač vznikne až při prvním použití).
    if ($null -eq $state.Player) {
        if ($PSVersionTable.PSEdition -eq 'Core') { Add-Type -AssemblyName System.Windows.Extensions }   # SoundPlayer v PS 7
        $file = Join-Path $PSScriptRoot 'kvak.wav'
        if (Test-Path -LiteralPath $file) {
            $state.Player = New-Object System.Media.SoundPlayer $file
        } else {
            $state.Player = New-Object System.Media.SoundPlayer (New-Object System.IO.MemoryStream (, (New-QuackWave)))
        }
        $state.Player.Load()
    }
    $state.Player.Play()
}

function Register-SystemEvent {
    # Události Windows místo neustálého dotazování: monitory a rozlišení, hlavní panel, napájení, zamčení PC.
    # SystemEvents v STA vlákně používá vlákno kachny, obsluhy tedy běží ve vlákně okna.
    $state.SysHandlers = @{
        Display = [System.EventHandler]{ Request-AreaUpdate }
        Pref    = [Microsoft.Win32.UserPreferenceChangedEventHandler]{ if ("$($_.Category)" -in 'Desktop', 'General') { Request-AreaUpdate } }
        Power   = [Microsoft.Win32.PowerModeChangedEventHandler]{ Invoke-PowerModeChange "$($_.Mode)" }
        Session = [Microsoft.Win32.SessionSwitchEventHandler]{ Invoke-SessionSwitch "$($_.Reason)" }
    }
    [Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($state.SysHandlers.Display)
    [Microsoft.Win32.SystemEvents]::add_UserPreferenceChanged($state.SysHandlers.Pref)
    [Microsoft.Win32.SystemEvents]::add_PowerModeChanged($state.SysHandlers.Power)
    [Microsoft.Win32.SystemEvents]::add_SessionSwitch($state.SysHandlers.Session)
}

function Unregister-SystemEvent {
    $handlers = $state.SysHandlers
    if ($null -eq $handlers) { return }
    [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($handlers.Display)
    [Microsoft.Win32.SystemEvents]::remove_UserPreferenceChanged($handlers.Pref)
    [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($handlers.Power)
    [Microsoft.Win32.SystemEvents]::remove_SessionSwitch($handlers.Session)
    $state.SysHandlers = $null
}

# ---------------------------------------------------------------------------
# Stav a pohyb kachny
# ---------------------------------------------------------------------------
# Pohyb okna řídí animace WPF (Start-WindowAnimation): chůze k cíli, pád, poskok. PowerShell se ozve, až animace
# doběhne (Complete-Motion), a jednou za sekundu v Invoke-Heartbeat. $state.X/Y je poslední známá poloha;
# během animace platí $window.Left/Top (Sync-Position). $state.Motion = běžící animace (None/Walk/Fall/HopUp).

function Set-Area {
    # Nová plocha monitoru a z ní odvozené meze chůze (počítají se jen při změně, ne při každém kroku).
    param($Area)
    $state.Area = $Area
    $state.MinX = $Area.Left
    $state.MaxX = [math]::Max($Area.Left, $Area.Right - $window.Width)
    $state.GroundY = $Area.Bottom - $window.Height
    $state.PxPerDip = 1 / (Get-DipScale)[0]
}

function Update-Speed { $state.Speed = [math]::Max(1.0, $config.Speeds[$state.SpeedName] * $state.SpeedFactor) }

function Get-FpsConfig { if ($state.EcoActive) { $config.EcoFps } else { $config.Fps } }

function Set-WindowPosition {
    $window.Left = $state.X
    $window.Top = $state.Y
}

function Sync-Position {
    $state.X = $window.Left
    $state.Y = $window.Top
}

function Add-Distance {
    # Ušlá vzdálenost pro hlášky (počítá se od půlnoci).
    $today = (Get-Now).Date
    if ($state.DistanceDate -ne $today) {
        $state.DistanceDate = $today
        $state.Distance = 0.0
    }
    $state.Distance += [math]::Abs($state.X - $state.WalkFromX)
    $state.WalkFromX = $state.X
}

function Stop-Motion {
    # Zastaví pohyb okna tam, kde právě je. Přerušený výskok pokračuje jako pád.
    if ($state.Motion -eq 'None') { return }
    Stop-WindowAnimation
    Sync-Position
    if ($state.Motion -eq 'Walk') { Add-Distance }
    if ($state.Motion -eq 'HopUp') { $state.Falling = $true }
    $state.Motion = 'None'
}

function Set-Direction {
    param([int]$Direction)
    $state.Direction = $Direction
    $ui.RootFlip.ScaleX = $Direction
    $ui.TextFlip.ScaleX = $Direction
}

function Test-CanWalk {
    # Chodí jen viditelná a bdělá kachna na zemi: ne v pauze, při odpočinku, jídle, pádu, poskoku ani tažení.
    return -not ($state.Hidden -or $state.Sleeping -or $state.Paused -or $state.Resting -or $state.Eating -or
        $state.Falling -or $state.Dragging -or $state.Motion -eq 'HopUp' -or $null -eq $state.Area)
}

function Get-WalkPlan {
    # Kam kachna jde: celá na nový monitor (přechod), k rohlíku, pod kurzor (Pojď za myší), jinak k okraji.
    # Vrací cíl X, směr a důvod (Entry/Food/Cursor/Edge); $null = má stát (už je pod kurzorem).
    $width = $window.Width
    if ($state.Crossing) {
        $x = if ($state.Direction -gt 0) { $state.MinX } else { $state.MaxX }
        return [pscustomobject]@{ X = $x; Direction = $state.Direction; Goal = 'Entry' }
    }
    if ($null -ne $state.Food) {
        # zobák nad rohlík: kachna jde vždy dopředu (zobákem napřed), rohlík pod tělem sní na místě
        $right = Get-Clamped -Value ($state.Food.X - $config.BeakOffset) -Min $state.MinX -Max $state.MaxX
        $left = Get-Clamped -Value ($state.Food.X - ($width - $config.BeakOffset)) -Min $state.MinX -Max $state.MaxX
        if ($right -ge $state.X) { return [pscustomobject]@{ X = $right; Direction = 1; Goal = 'Food' } }
        if ($left -le $state.X) { return [pscustomobject]@{ X = $left; Direction = -1; Goal = 'Food' } }
        $dir = if ($state.Food.X -ge $state.X + $width / 2) { 1 } else { -1 }
        return [pscustomobject]@{ X = $state.X; Direction = $dir; Goal = 'Food' }
    }
    if ($state.Follow) {
        $x = (Get-CursorDip).X - $width / 2
        if ($x -gt $state.MaxX + 1 -or $x -lt $state.MinX - 1) {
            # kurzor je za okrajem (na jiném monitoru): dojít k okraji, odtud případně přejít
            $dir = if ($x -gt $state.MaxX) { 1 } else { -1 }
            $edge = if ($dir -gt 0) { $state.MaxX } else { $state.MinX }
            return [pscustomobject]@{ X = $edge; Direction = $dir; Goal = 'Edge' }
        }
        if ([math]::Abs($x - $state.X) -lt 3) { return $null }
        $dir = if ($x -gt $state.X) { 1 } else { -1 }
        return [pscustomobject]@{ X = $x; Direction = $dir; Goal = 'Cursor' }
    }
    $edge = if ($state.Direction -gt 0) { $state.MaxX } else { $state.MinX }
    return [pscustomobject]@{ X = $edge; Direction = $state.Direction; Goal = 'Edge' }
}

function Start-Walk {
    # Chůze jako animace WPF: okno dojde samo až k cíli, teprve pak se ozve PowerShell (Complete-Motion).
    # Snímků za sekundu je zhruba tolik, kolik pixelů za sekundu kachna ujde (víc by okno stejně neposunulo).
    Stop-Motion
    for ($attempt = 0; $attempt -lt 3 -and (Test-CanWalk); $attempt++) {
        $plan = Get-WalkPlan
        if ($null -eq $plan) { break }
        if ($plan.Direction -ne $state.Direction) { Set-Direction $plan.Direction }
        $distance = [math]::Abs($plan.X - $state.X)
        if ($distance -ge 0.5) {
            $fps = Get-FpsConfig
            $walkFps = Get-WalkFrameRate -Speed $state.Speed -PxPerDip $state.PxPerDip -Min $fps.WalkMin -Max $fps.WalkMax
            $state.Motion = 'Walk'
            $state.WalkGoal = $plan.Goal
            $state.WalkTarget = $plan.X
            $state.WalkFromX = $state.X
            Start-WindowAnimation -Property 'Left' -From $state.X -To $plan.X -Seconds ($distance / $state.Speed) -Fps $walkFps
            break
        }
        if (-not (Complete-Goal $plan.Goal)) { break }   # už je v cíli (třeba stojí na okraji)
    }
    Update-Animation
}

function Complete-Goal {
    # Kachna došla do cíle chůze. Vrací $true, když má hned jít dál (další cíl naplánuje Start-Walk).
    param([string]$Goal)
    switch ($Goal) {
        'Entry' {
            # celá na novém monitoru: spadnout (nebo se vynořit) na jeho zem a jít dál
            $state.Crossing = $false
            if ([math]::Abs($state.Y - $state.GroundY) -gt 0.5) {
                Start-Fall -Area $state.Area -X $state.X -Y $state.Y -Reason 'Cross'
                return $false
            }
            Show-Phrase $crossPhrases
            return $true
        }
        'Food' {
            Start-Eating
            return $false
        }
        'Cursor' { return $false }   # stojí pod kurzorem, až se myš pohne, pošle ji dál Update-Follow
        default {
            if ($state.CrossMonitors -and (Start-Crossing)) { return $true }
            if ($state.Follow) { return $false }   # kurzor je za okrajem, kam se nedá přejít: počkat
            Set-Direction (-$state.Direction)
            return $true
        }
    }
}

function Start-Crossing {
    # Na okraji navazuje sousední monitor: kachna se stane jeho obyvatelkou a dojde celá na něj (cíl Entry).
    $next = Find-NeighborArea -Current $state.Area -Areas (Get-AreaList) -Direction $state.Direction -Top $state.Y -Height $window.Height
    if ($null -eq $next) { return $false }
    Stop-Feeding
    Set-Area $next
    $state.Crossing = $true
    return $true
}

function Complete-Motion {
    # Animace doběhla: chůze do cíle, pád na zem, nebo vrchol poskoku. Poloha se uvolní z animace,
    # aby ji šlo dál nastavovat (jinak by ji držela doběhnutá animace).
    $motion = $state.Motion
    $state.Motion = 'None'
    Stop-WindowAnimation
    Sync-Position
    switch ($motion) {
        'Walk' {
            Add-Distance
            if (Complete-Goal $state.WalkGoal) { Start-Walk } else { Update-Animation }
        }
        'Fall' { Complete-Fall }
        'HopUp' {
            $state.Falling = $true
            Start-FallMotion
        }
    }
}

function Update-Motion {
    # Rozběhne pohyb podle stavu (po pauze, zobrazení, probuzení, klepnutí...): dokončí pád, nebo jde dál.
    if ($state.Hidden -or $state.Dragging -or $state.Sleeping -or $null -eq $state.Area -or $state.Motion -ne 'None') { return }
    if ($state.Falling) { Start-FallMotion } else { Start-Walk }
}

function Start-Fall {
    # Kachna spadne (nebo se vynoří) na spodní okraj pracovní plochy zadaného monitoru.
    # Reason určuje, co řekne po přistání: Drop (puštění, přivolání), Cross (nový monitor), Hop (poskok).
    param($Area, [double]$X, [double]$Y, [string]$Reason = 'Drop')
    Stop-Motion
    if (-not (Test-SameArea $Area $state.Area)) { Stop-Feeding }
    Set-Area $Area
    $state.Crossing = $false
    $state.X = Get-Clamped -Value $X -Min $state.MinX -Max $state.MaxX
    $state.Y = $Y
    $state.Falling = $true
    $state.FallReason = $Reason
    $state.Resting = $false
    Set-WindowPosition
    Update-Motion
}

function Start-FallMotion {
    # Pád jako animace: volný pád z klidu (QuadraticEase EaseIn), nebo rovnoměrné vynoření zpod spodního okraje.
    $plan = Get-FallPlan -Y $state.Y -GroundY $state.GroundY -Gravity $config.Gravity -RiseSpeed $config.RiseSpeed
    if ($plan.Seconds -lt 0.001) {
        Complete-Fall
        return
    }
    $state.Motion = 'Fall'
    Start-WindowAnimation -Property 'Top' -From $state.Y -To $state.GroundY -Seconds $plan.Seconds -Fps (Get-FpsConfig).Fall -Ease $plan.Ease
    Update-Animation
}

function Complete-Fall {
    # Přistání: kachna promluví (po puštění, přivolání, přechodu na jiný monitor) a jde dál.
    $state.Y = $state.GroundY
    $state.Falling = $false
    Set-WindowPosition
    $state.NextAreaCheck = 0.0   # monitor pod kachnou se ověří při příštím tepu
    if (-not $state.Paused) {
        if ($state.FallReason -eq 'Drop') { Show-Phrase $dropPhrases }
        elseif ($state.FallReason -eq 'Cross') { Show-Phrase $crossPhrases }
    }
    Update-Animation
    Start-Walk
}

function Start-Hop {
    # Poskok (dvojklik, radost z rohlíku): nahoru zpomaluje (QuadraticEase EaseOut), dolů padá jako volný pád.
    param([switch]$Quiet)
    if ($state.Hidden -or $state.Sleeping -or $state.Falling -or $state.Dragging -or $state.Motion -eq 'HopUp' -or $null -eq $state.Area) { return }
    Stop-Motion
    $state.FallReason = 'Hop'
    $state.Motion = 'HopUp'
    $height = $config.HopHeight
    Start-WindowAnimation -Property 'Top' -From $state.Y -To ($state.Y - $height) -Seconds ([math]::Sqrt(2 * $height / $config.Gravity)) -Fps (Get-FpsConfig).Fall -Ease 'EaseOut'
    if (-not $Quiet) {
        Show-Phrase $hopPhrases
        Invoke-Quack
    }
    Update-Animation
}

function Start-Drag {
    # Levé tlačítko na kachně: pohyb se zastaví (DragMove přesouvá okno sám), nohy kmitají rychle.
    $state.Dragging = $true
    Stop-Motion
    Update-Animation
}

function Complete-Drag {
    # Vyhodnotí stisk levého tlačítka po DragMove: malý posun = klepnutí (pauza se přepne až po době dvojkliku,
    # dvojklik = poskok), jinak pád na monitoru pod kurzorem.
    param([double]$StartLeft, [double]$StartTop)
    $state.Dragging = $false
    $moved = [math]::Max([math]::Abs($window.Left - $StartLeft), [math]::Abs($window.Top - $StartTop))
    if ($moved -le $config.ClickTolerance) {
        Set-WindowPosition
        Start-ClickTimer
        Update-Animation
        Update-Motion
    } else {
        Start-Fall -Area (Get-CursorArea) -X $window.Left -Y $window.Top -Reason 'Drop'
    }
}

function Start-ClickTimer {
    $clickTimer.Stop()
    $clickTimer.Interval = [TimeSpan]::FromSeconds($state.DoubleClickSec)
    $clickTimer.Start()
}

function Invoke-Click {
    # Klepnutí, ke kterému nepřišel druhý klik: pauza / pokračování.
    $clickTimer.Stop()
    if ($state.Hidden) { return }
    Switch-Pause
    Invoke-Quack
}

function Invoke-Summon {
    # Přivolá kachnu na monitor s kurzorem myši: objeví se nahoře nad kurzorem a spadne dolů (i když byla skrytá).
    if ($state.Sleeping) { Set-Sleeping $false }
    $area = Get-CursorArea
    $cursor = Get-CursorDip
    Start-Fall -Area $area -X ($cursor.X - $window.Width / 2) -Y $area.Top -Reason 'Drop'
    Set-Hidden $false
}

function Update-WorkArea {
    # Znovu načte plochu monitoru, na kterém kachna stojí (rozlišení, hlavní panel, odpojení monitoru, DPI)
    # a postaví ji do nových mezí. Během pádu, poskoku a tažení se plocha nemění (u monitorů nad sebou by kachna
    # dopadla jinam), během přechodu na sousední monitor jen s -Force.
    param([switch]$Force)
    if ($state.Falling -or $state.Dragging -or $state.Motion -eq 'HopUp') { return }
    if ($state.Crossing -and -not $Force) { return }
    if ($state.Motion -eq 'Walk') { Sync-Position }
    $area = Get-WindowArea
    if ($null -eq $area) { return }
    $pxPerDip = 1 / (Get-DipScale)[0]
    $inside = $state.X -ge $state.MinX - 0.5 -and $state.X -le $state.MaxX + 0.5 -and [math]::Abs($state.Y - $state.GroundY) -lt 0.5
    if (-not $state.Crossing -and (Test-SameArea $area $state.Area) -and $pxPerDip -eq $state.PxPerDip -and $inside) { return }
    $walking = $state.Motion -eq 'Walk'
    Stop-Motion
    if (-not (Test-SameArea $area $state.Area)) { Stop-Feeding }
    Set-Area $area
    $state.Crossing = $false
    $state.X = Get-Clamped -Value $state.X -Min $state.MinX -Max $state.MaxX
    $state.Y = $state.GroundY
    Set-WindowPosition
    if ($walking) { Start-Walk }
}

function Request-AreaUpdate {
    # Windows ohlásil změnu monitorů, hlavního panelu nebo DPI: plochu načíst hned (skrytá kachna ji načte
    # při zobrazení, přecházející kachna při příštím tepu po přechodu).
    $state.NextAreaCheck = 0.0
    if (-not $state.Hidden) { Update-WorkArea }
}

# ---------------------------------------------------------------------------
# Bublina, hlášky a animace kachny
# ---------------------------------------------------------------------------
function Show-Speech {
    # Nová hláška do bubliny. Bublina po chvíli zmizí (Update-Bubble), v tichém režimu se neukáže vůbec.
    # Sticky = zůstane, dokud ji nevystřídá jiná (spánek), Reminder = modrá a déle vidět.
    param([string]$Text, [switch]$Sticky, [switch]$Reminder)
    $state.LastPhrase = $Text
    if ($state.Quiet) {
        Set-BubbleVisible $false
        return
    }
    $ui.SpeechText.Text = $Text
    $ui.SpeechBorder.Background = if ($Reminder) { $bubbleBrushes.Reminder } else { $bubbleBrushes.Normal }
    $seconds = if ($Reminder) { $config.ReminderBubbleSec } else { $config.BubbleSec }
    $state.BubbleUntil = if ($Sticky -or $seconds -le 0) { [double]::MaxValue } else { $clock.Elapsed.TotalSeconds + $seconds }
    $state.BubbleBackAt = 0.0
    Set-BubbleVisible $true
}

function Show-Phrase {
    # Náhodná hláška ze seznamu (jiná než minulá); další přijde až po celém intervalu hlášek.
    param([string[]]$Phrases)
    Show-Speech (Get-RandomPhrase $Phrases $state.LastPhrase)
    Restart-SpeechTimer
}

function Set-BubbleVisible {
    param([bool]$Visible)
    $ui.SpeechBubble.Visibility = if ($Visible) { 'Visible' } else { 'Hidden' }
}

function Hide-BubbleForHover {
    # Myš najela na bublinu: na chvíli ji schovat. Průhledné místo okna propustí kliknutí na okno pod ní.
    if ("$($ui.SpeechBubble.Visibility)" -ne 'Visible') { return }
    Set-BubbleVisible $false
    $state.BubbleBackAt = $clock.Elapsed.TotalSeconds + $config.BubbleHoverSec
}

function Update-Bubble {
    # Bublina zmizí po BubbleSec; schovaná kvůli myši se vrátí, pokud hláška ještě nemá zmizet.
    param([double]$Now)
    if ($Now -ge $state.BubbleUntil) {
        Set-BubbleVisible $false
        $state.BubbleBackAt = 0.0
        return
    }
    if ($state.BubbleBackAt -gt 0 -and $Now -ge $state.BubbleBackAt) {
        $state.BubbleBackAt = 0.0
        if (-not $state.Quiet) { Set-BubbleVisible $true }
    }
}

function Restart-SpeechTimer {
    # Nová hláška má zůstat vidět celý interval: v pauze minutu (stížnosti), jinak podle rychlosti hlášek
    # (v úsporném režimu 2x delší). Skrytá, spící nebo tichá kachna mlčí.
    $speechTimer.Stop()
    $seconds = if ($state.Paused) { $config.ComplaintIntervalSec } else { $config.PhraseSpeeds[$state.PhraseSpeedName] }
    if (-not $state.Paused -and $state.EcoActive) { $seconds *= $config.EcoPhraseFactor }
    $speechTimer.Interval = [TimeSpan]::FromSeconds($seconds)
    if (-not ($state.Hidden -or $state.Sleeping -or $state.Quiet)) { $speechTimer.Start() }
}

function Invoke-SpeechTick {
    if ($state.Paused) {
        Show-Speech (Get-RandomPhrase $complaintPhrases $state.LastPhrase)
        return
    }
    $phrases = $duckPhrases
    if ((Get-Random -Maximum 4) -eq 0) {
        # zhruba každá čtvrtá hláška podle situace (denní doba, svátky, baterie, ušlá vzdálenost), pokud nějaká platí
        $extra = @(Get-SituationPhrase -Now (Get-Now) -Power $state.Power -DistanceDip $state.Distance -UptimeMin $clock.Elapsed.TotalMinutes)
        if ($extra.Count -gt 0) { $phrases = $extra }
    }
    Show-Speech (Get-RandomPhrase $phrases $state.LastPhrase)
}

function Update-Animation {
    # Nohy kmitají jen při pohybu, tělo mění barvu jen u bdělé kachny mimo pauzu a úsporný režim.
    # Zastavuje se přes Stop, ne Pause: i pozastavený storyboard by WPF nechalo tikat ~60x za sekundu.
    # DesiredFrameRate (Set-FrameRate) platí od Begin, proto se po změně snímků storyboard spustí znovu.
    if (-not $state.AnimReady) { return }
    $fps = Get-FpsConfig
    $moving = -not ($state.Hidden -or $state.Sleeping) -and ($state.Dragging -or $state.Motion -ne 'None')
    if ($moving) {
        if (-not $state.LegsRunning -or $state.LegsFps -ne $fps.Legs) {
            Set-FrameRate $legs $fps.Legs
            $legs.Begin($window, $true)
            $state.LegsRunning = $true
            $state.LegsFps = $fps.Legs
        }
        # při pádu, poskoku a přenášení kmitají rychle, při chůzi podle rychlosti
        $ratio = if ($state.Dragging -or $state.Motion -ne 'Walk') { 4.0 } else { [math]::Max(0.2, $state.Speed / $config.LegsBaseSpeed) }
        $legs.SetSpeedRatio($window, $ratio)
    } elseif ($state.LegsRunning) {
        $legs.Stop($window)   # nohy u sebe
        $state.LegsRunning = $false
    }
    if ($fps.Glow -gt 0 -and -not ($state.Hidden -or $state.Sleeping -or $state.Paused)) {
        if (-not $state.GlowRunning -or $state.GlowFps -ne $fps.Glow) {
            Set-FrameRate $glow $fps.Glow
            $glow.Begin($window, $true)
            $state.GlowRunning = $true
            $state.GlowFps = $fps.Glow
        }
    } elseif ($state.GlowRunning) {
        $glow.Stop($window)
        $state.GlowRunning = $false
    }
}

function Set-EyesClosed {
    param([bool]$Closed)
    $open = if ($Closed) { 'Hidden' } else { 'Visible' }
    $ui.circle12.Visibility = $open
    $ui.circle14.Visibility = $open
    $ui.SleepEye.Visibility = if ($Closed) { 'Visible' } else { 'Hidden' }
}

function Update-Costume {
    # Převlek podle data (Get-Costume), pokud jsou převleky zapnuté. Datum se kontroluje jednou za minutu.
    $name = if ($state.Costumes) { Get-Costume (Get-Now) } else { '' }
    $state.Costume = $name
    foreach ($costume in 'Santa', 'Witch', 'Glasses') {
        $ui["Costume$costume"].Visibility = if ($costume -eq $name) { 'Visible' } else { 'Collapsed' }
    }
}

# ---------------------------------------------------------------------------
# Chování: pauza, rychlost, náhodné chování, spánek, skrytí, úsporný režim, připomínky, krmení
# ---------------------------------------------------------------------------
function Set-Paused {
    param([bool]$Paused)
    $state.Paused = $Paused
    $state.Resting = $false
    if ($Paused) {
        Show-Speech (Get-RandomPhrase $complaintPhrases $state.LastPhrase)
        if ($state.Motion -eq 'Walk') { Stop-Motion }   # rozpracovaný pád nebo poskok doběhne
    } else {
        Show-Speech (Get-RandomPhrase $resumePhrases $state.LastPhrase)
    }
    Restart-SpeechTimer
    Update-Animation
    Update-Motion
}

function Switch-Pause { Set-Paused (-not $state.Paused) }

function Set-Speed {
    param([string]$Name)
    if (-not $config.Speeds.Contains($Name)) { return }
    $state.SpeedName = $Name
    Update-Speed
    if ($state.Motion -eq 'Walk') { Start-Walk } else { Update-Animation }   # dojít k cíli novou rychlostí
}

function Set-PhraseSpeed {
    param([string]$Name)
    if (-not $config.PhraseSpeeds.Contains($Name)) { return }
    $state.PhraseSpeedName = $Name
    if (-not $state.Paused) { Restart-SpeechTimer }   # v pauze si kachna dál stěžuje jednou za minutu
}

function Set-RandomBehavior {
    param([bool]$Enabled)
    $state.RandomBehavior = $Enabled
    $state.Resting = $false
    $state.SpeedFactor = 1.0
    $state.NextDecision = $clock.Elapsed.TotalSeconds + 5
    Update-Speed
    if ($state.Motion -eq 'Walk') { Start-Walk } else { Update-Motion }
}

function Invoke-RandomBehavior {
    # Občas se zastaví, otočí nebo změní tempo (jen při obyčejné chůzi po zemi).
    param([double]$Now)
    if ($state.Paused -or $state.Falling -or $state.Dragging -or $state.Crossing -or $state.Eating -or $state.Motion -eq 'HopUp') { return }
    if ($state.Resting) {
        if ($Now -ge $state.RestUntil) {
            $state.Resting = $false
            Start-Walk
        }
        return
    }
    if ($Now -lt $state.NextDecision) { return }
    $state.NextDecision = $Now + (Get-Random -Minimum 6.0 -Maximum 16.0)
    switch (Get-RandomAction (Get-Random -Maximum 100)) {
        'Turn' {
            Stop-Motion
            Set-Direction (-$state.Direction)
            Start-Walk
        }
        'Rest' {
            Stop-Motion
            $state.Resting = $true
            $state.RestUntil = $Now + (Get-Random -Minimum 2.0 -Maximum 6.0)
            if ((Get-Random -Maximum 2) -eq 0) { Show-Phrase $restPhrases }
            Update-Animation
        }
        default {
            $state.SpeedFactor = Get-Random -Minimum 0.6 -Maximum 1.6
            Update-Speed
            Start-Walk
        }
    }
}

function Set-Sleeping {
    # Usnutí (nikdo nehýbe myší): kachna stojí se zavřenýma očima a mlčí, animace stojí a jen jednou za pár
    # sekund zkontroluje myš (~0 % CPU). Probudí ji pohyb myši, klepnutí nebo přivolání.
    param([bool]$Sleeping)
    if ($state.Sleeping -eq $Sleeping) { return }
    if ($Sleeping) {
        Stop-Motion
        $state.Sleeping = $true
        $state.Resting = $false
        Set-EyesClosed $true
        Show-Speech (Get-RandomPhrase $sleepPhrases $state.LastPhrase) -Sticky
        $speechTimer.Stop()
    } else {
        $state.Sleeping = $false
        Set-EyesClosed $false
        $now = $clock.Elapsed.TotalSeconds
        $state.LastActivity = $now
        $state.NextDecision = $now + 5
        if ($state.Paused) { Show-Speech (Get-RandomPhrase $complaintPhrases $state.LastPhrase) }
        else { Show-Speech (Get-RandomPhrase $wakePhrases $state.LastPhrase) }
        Restart-SpeechTimer
    }
    Update-Animation
    Restart-HeartTimer
    Update-Motion
}

function Set-Hidden {
    # Skrytá kachna nic nedělá: okno je schované, časovače i animace stojí a program jen čeká.
    # Po zobrazení pokračuje tam, kde přestala (pozice, směr, pauza i rozpracovaný pád zůstávají).
    param([bool]$Hidden, [string[]]$Phrases = $showPhrases)
    if ($state.Hidden -eq $Hidden) { return }
    $state.HiddenByLock = $false
    if ($Hidden) {
        Stop-Motion
        $state.Hidden = $true
        $heartTimer.Stop()
        $speechTimer.Stop()
        $clickTimer.Stop()
        if ($state.Sleeping) {
            $state.Sleeping = $false
            Set-EyesClosed $false
        }
        Stop-Feeding
        Update-Animation
        $window.Hide()
        return
    }
    $state.Hidden = $false
    $hideTimer.Stop()
    # Čas ve skrytu se nepočítá: náhodné chování i nečinnost začnou nanovo jako po startu.
    $now = $clock.Elapsed.TotalSeconds
    $state.NextDecision = $now + 5
    $state.Resting = $false
    $state.LastActivity = $now
    $state.LastCursor = Get-CursorKey
    # Ve skrytu se mohlo změnit rozlišení nebo odpojit monitor: plochu načíst ještě před zobrazením,
    # aby se kachna neobjevila mimo obrazovku. Rozpracovaný pád pokračuje na svém monitoru.
    if ($state.Falling) { Set-WindowPosition } else { Update-WorkArea -Force }
    if ($state.Paused) {
        Show-Speech (Get-RandomPhrase $complaintPhrases $state.LastPhrase)
    } elseif (-not $state.Falling) {
        Show-Speech (Get-RandomPhrase $Phrases $state.LastPhrase)   # přivolaná kachna promluví až po přistání
    }
    $window.Show()
    Update-Animation
    Restart-HeartTimer
    Restart-SpeechTimer
    Update-Motion
}

function Switch-Hidden { Set-Hidden (-not $state.Hidden) }

function Start-TimedHide {
    # Skrýt na čas (schůzka, sdílení obrazovky): po uplynutí se kachna sama vrátí.
    param([string]$Name)
    if (-not $config.HideChoices.Contains($Name)) { return }
    Set-Hidden $true
    $hideTimer.Stop()
    $hideTimer.Interval = [TimeSpan]::FromMinutes($config.HideChoices[$Name])
    $hideTimer.Start()
}

function Invoke-HideTimer {
    $hideTimer.Stop()
    if (-not $state.Hidden) { return }
    if ($state.Locked) {
        $state.HiddenByLock = $true   # vrátí se až po odemčení
        return
    }
    Set-Hidden $false
}

function Invoke-SessionSwitch {
    # Zamčení nebo odpojení relace: nikdo se nedívá, kachna se schová (~0 % CPU). Po odemčení se vrátí,
    # ale jen když ji schovalo zamčení (ručně skrytá zůstane skrytá).
    param([string]$Reason)
    if ($Reason -in 'SessionLock', 'ConsoleDisconnect', 'RemoteDisconnect') {
        $state.Locked = $true
        if (-not $state.Hidden) {
            Set-Hidden $true
            $state.HiddenByLock = $true
        }
    } elseif ($Reason -in 'SessionUnlock', 'ConsoleConnect', 'RemoteConnect') {
        $state.Locked = $false
        if ($state.HiddenByLock) { Set-Hidden $false -Phrases $welcomePhrases }
    }
}

function Test-EcoActive {
    return ($state.EcoMode -eq 'On' -or ($state.EcoMode -eq 'Battery' -and $null -ne $state.Power -and $state.Power.OnBattery))
}

function Update-Eco {
    # Úsporný režim se zapnul / vypnul (volba v menu, odpojení nabíječky): méně snímků animací,
    # tělo nemění barvu, kachna mluví méně často.
    $eco = Test-EcoActive
    if ($eco -eq $state.EcoActive) { return }
    $state.EcoActive = $eco
    Update-Animation
    if (-not $state.Paused) { Restart-SpeechTimer }
    if ($state.Motion -eq 'Walk') { Start-Walk }   # chůze s novým počtem snímků
}

function Set-EcoMode {
    param([string]$Name)
    if (-not $config.EcoModes.Contains($Name)) { return }
    $state.EcoName = $Name
    $state.EcoMode = $config.EcoModes[$Name]
    Update-Eco
}

function Update-Power {
    $state.Power = Get-PowerInfo
    Update-Eco
}

function Invoke-PowerModeChange {
    # Napájení (síť / baterie) a uspání počítače. Před uspáním se pohyb zastaví: animace by po probuzení
    # "dohnala" celou dobu spánku a kachna by skočila až k cíli.
    param([string]$Mode)
    if ($Mode -eq 'StatusChange') {
        Update-Power
    } elseif ($Mode -eq 'Suspend') {
        Stop-Motion
        Update-Animation
    } elseif ($Mode -eq 'Resume') {
        $state.LastActivity = $clock.Elapsed.TotalSeconds
        Update-Power
        Update-Motion
    }
}

function Set-Reminder {
    # Zapne / vypne připomínku (Drink, Stretch, Pomodoro). Pomodoro začíná 25 minutami práce.
    param([string]$Key, [bool]$Enabled)
    $now = $clock.Elapsed.TotalSeconds
    if ($Key -eq 'Pomodoro') {
        $state.Pomodoro = $Enabled
        $state.PomodoroPhase = 'Work'
        $state.PomodoroDue = $now + $config.PomodoroMin.Work * 60
        if ($Enabled -and -not $state.Hidden) { Show-Reminder $reminderPhrases.PomodoroStart }
        return
    }
    if (-not $config.Reminders.Contains($Key)) { return }
    $state.Reminders[$Key] = $Enabled
    $state.ReminderDue[$Key] = $now + $config.Reminders[$Key] * 60
}

function Invoke-Reminder {
    # Připomínky (pitný režim, protažení, Pomodoro). Ve skrytu se nekontrolují: zmeškaná připomínka
    # se ozve jednou po zobrazení a další se počítá od té chvíle. Spící kachnu připomínka probudí.
    param([double]$Now)
    foreach ($key in @($config.Reminders.Keys)) {
        if ($state.Reminders[$key] -and $Now -ge $state.ReminderDue[$key]) {
            $state.ReminderDue[$key] = $Now + $config.Reminders[$key] * 60
            Show-Reminder $reminderPhrases[$key]
        }
    }
    if ($state.Pomodoro -and $Now -ge $state.PomodoroDue) {
        if ($state.PomodoroPhase -eq 'Work') {
            $state.PomodoroPhase = 'Break'
            $state.PomodoroDue = $Now + $config.PomodoroMin.Break * 60
            Show-Reminder $reminderPhrases.PomodoroBreak
        } else {
            $state.PomodoroPhase = 'Work'
            $state.PomodoroDue = $Now + $config.PomodoroMin.Work * 60
            Show-Reminder $reminderPhrases.PomodoroWork
        }
    }
}

function Show-Reminder {
    # Připomínka: modrá bublina, déle vidět, s kvákem (je-li zapnutý zvuk). Spící kachnu probudí
    # (spánek se pozná jen podle myši, uživatel může zrovna psát).
    param([string[]]$Phrases)
    if ($state.Sleeping) { Set-Sleeping $false }
    Show-Speech (Get-RandomPhrase $Phrases $state.LastPhrase) -Reminder
    Restart-SpeechTimer
    Invoke-Quack
}

function Set-Follow {
    # "Pojď za myší": kachna jde pod kurzor (i přes sousední monitory); tep je častější, aby stíhala myš.
    param([bool]$On)
    $state.Follow = $On
    $state.Resting = $false
    if ($On -and -not $state.Hidden) { Show-Phrase $followPhrases }
    Restart-HeartTimer
    if ($state.Motion -eq 'Walk') { Start-Walk } else { Update-Motion }
}

function Update-Follow {
    # Cíl chůze se mění s kurzorem; nová animace jen při znatelném posunu cíle nebo změně směru.
    if (-not (Test-CanWalk) -or $state.Crossing) { return }
    if ($state.Motion -eq 'Walk') { Sync-Position }
    $plan = Get-WalkPlan
    if ($null -eq $plan) {
        # kachna je skoro pod kurzorem: rozpracovaný krok nechat doběhnout, zastavit jen když vede jinam
        if ($state.Motion -eq 'Walk' -and [math]::Abs($state.WalkTarget - ((Get-CursorDip).X - $window.Width / 2)) -ge 3) {
            Stop-Motion
            Update-Animation
        }
        return
    }
    if ($state.Motion -eq 'Walk' -and $plan.Direction -eq $state.Direction -and [math]::Abs($plan.X - $state.WalkTarget) -lt 3) { return }
    Start-Walk
}

function Start-Feeding {
    # Rohlík spadne u kurzoru (je-li na monitoru kachny), jinak kus před kachnu; kachna k němu doběhne a sní ho.
    if ($state.Hidden) { Set-Hidden $false }
    if ($state.Sleeping) { Set-Sleeping $false }
    if ($null -eq $state.Area -or $state.Falling) { return }
    $area = $state.Area
    $size = $config.CrumbSize
    $cursor = Get-CursorDip
    if ($cursor.X -ge $area.Left -and $cursor.X -le $area.Right -and $cursor.Y -ge $area.Top -and $cursor.Y -le $area.Bottom) {
        $x = $cursor.X
        $y = $cursor.Y - $size.Height / 2
    } else {
        $x = $state.X + $window.Width / 2 + $state.Direction * 300
        $y = $area.Top
    }
    $x = Get-Clamped -Value $x -Min ($area.Left + $size.Width) -Max ($area.Right - $size.Width)
    $ground = $area.Bottom - $size.Height
    $y = [math]::Min($y, $ground)
    $plan = Get-FallPlan -Y $y -GroundY $ground -Gravity $config.Gravity -RiseSpeed $config.RiseSpeed
    Show-Crumb -X ($x - $size.Width / 2) -Y $y -GroundY $ground -Seconds $plan.Seconds -Fps (Get-FpsConfig).Fall
    $state.Food = [pscustomobject]@{ X = $x }
    $state.Eating = $false
    $state.Resting = $false
    Show-Phrase $foodPhrases
    if ($state.Motion -eq 'Walk') { Start-Walk } else { Update-Motion }
}

function Start-Eating {
    $state.Eating = $true
    $state.EatUntil = $clock.Elapsed.TotalSeconds + $config.EatSec
    Show-Phrase $eatPhrases
    Invoke-Quack
    Update-Animation
}

function Complete-Eating {
    # Dojedeno: rohlík zmizí a kachna radostí poskočí.
    Stop-Feeding
    Start-Hop -Quiet
    Update-Motion
}

function Stop-Feeding {
    if ($null -eq $state.Food -and -not $state.Eating) { return }
    $state.Food = $null
    $state.Eating = $false
    Hide-Crumb
}

function Set-Quiet {
    # Tichý režim: žádné bubliny ani hlášky (časovač hlášek stojí).
    param([bool]$Quiet)
    $state.Quiet = $Quiet
    if ($Quiet) { Set-BubbleVisible $false }
    Restart-SpeechTimer
}

function Invoke-Quack {
    if (-not $state.Sound) { return }
    try { Start-Sound } catch { Write-Verbose "Kachna: zvuk nejde přehrát: $_" }
}

function Set-Sound {
    param([bool]$Enabled)
    $state.Sound = $Enabled
    Invoke-Quack
}

function Set-CostumeEnabled {
    param([bool]$Enabled)
    $state.Costumes = $Enabled
    Update-Costume
}

function Set-MonitorCrossing {
    param([bool]$Enabled)
    $state.CrossMonitors = $Enabled
}

function Set-Topmost {
    param([bool]$Enabled)
    $state.Topmost = $Enabled
    $window.Topmost = $Enabled
    if ($null -ne $state.CrumbWindow) { $state.CrumbWindow.Topmost = $Enabled }
}

function Restart-HeartTimer {
    # Tep kachny: 1x za sekundu, při "Pojď za myší" častěji, spící kachna jen jednou za 2 s zkontroluje myš.
    $heartTimer.Stop()
    if ($state.Hidden) { return }
    $seconds = if ($state.Sleeping) { $config.SleepCheckSec } elseif ($state.Follow) { $config.FollowHeartbeatSec } else { $config.HeartbeatSec }
    $heartTimer.Interval = [TimeSpan]::FromSeconds($seconds)
    $heartTimer.Start()
}

function Invoke-Heartbeat {
    # Tep kachny: nečinnost a spánek, bublina, napájení a převlek, pojistná kontrola monitoru, připomínky,
    # rohlík, odpočinek a náhodné chování, "Pojď za myší". Samotný pohyb řídí animace WPF.
    $now = $clock.Elapsed.TotalSeconds
    $cursor = Get-CursorKey
    if ($cursor -ne $state.LastCursor) {
        $state.LastCursor = $cursor
        $state.LastActivity = $now
        if ($state.Sleeping) {
            Set-Sleeping $false
            return
        }
    }
    if ($state.Sleeping) {
        Invoke-Reminder -Now $now   # připomínka spící kachnu probudí
        return
    }
    $busy = $state.Falling -or $state.Dragging -or $state.Motion -eq 'HopUp'
    if ($config.IdleSleepMin -gt 0 -and $now - $state.LastActivity -ge $config.IdleSleepMin * 60 -and -not $busy) {
        Set-Sleeping $true
        return
    }
    Update-Bubble -Now $now
    if ($now -ge $state.NextPowerCheck) {
        $state.NextPowerCheck = $now + $config.PowerCheckSec
        Update-Power
        Update-Costume
    }
    if ($now -ge $state.NextAreaCheck -and -not $state.Crossing) {
        $state.NextAreaCheck = $now + $config.AreaCheckSec
        Update-WorkArea
    }
    Invoke-Reminder -Now $now
    if ($state.Eating -and $now -ge $state.EatUntil) { Complete-Eating }
    if ($state.Follow) { Update-Follow }
    elseif ($state.RandomBehavior -and $null -eq $state.Food) { Invoke-RandomBehavior -Now $now }
}

# ---------------------------------------------------------------------------
# Menu (pravé tlačítko na kachně) a ikona v oznamovací oblasti – obě podle stejného seznamu položek
# ---------------------------------------------------------------------------
# Text: popisek (text, nebo scriptblock podle stavu), Action: co udělat (u voleb dostane zvolenou možnost),
# Check: zaškrtnutí podle stavu, Choices: podmenu s výběrem jedné možnosti, Items: podmenu, Tray: jen u ikony,
# Gesture: nápověda vpravo v menu kachny. '-' = oddělovač.
$menuSpec = @(
    @{ Text = { if ($state.Paused) { 'Pokračovat' } else { 'Pauza' } }; Action = { Switch-Pause }; Gesture = 'klepnutí' }
    @{ Text = { if ($state.Hidden) { 'Zobrazit kachnu' } else { 'Skrýt kachnu' } }; Action = { Switch-Hidden } }
    @{ Text = 'Skrýt na…'; Choices = { $config.HideChoices.Keys }; Action = { param($Choice) Start-TimedHide $Choice } }
    @{ Text = 'Přivolat kachnu k myši'; Action = { Invoke-Summon }; Tray = $true }
    '-'
    @{ Text = 'Nakrmit rohlíkem'; Action = { Start-Feeding } }
    @{ Text = 'Pojď za myší'; Check = { $state.Follow }; Action = { Set-Follow (-not $state.Follow) } }
    '-'
    @{ Text = 'Rychlost chůze'; Choices = { $config.Speeds.Keys }; Check = { param($Choice) $Choice -eq $state.SpeedName }; Action = { param($Choice) Set-Speed $Choice } }
    @{ Text = 'Rychlost hlášek'; Choices = { $config.PhraseSpeeds.Keys }; Check = { param($Choice) $Choice -eq $state.PhraseSpeedName }; Action = { param($Choice) Set-PhraseSpeed $Choice } }
    @{ Text = 'Úsporný režim'; Choices = { $config.EcoModes.Keys }; Check = { param($Choice) $Choice -eq $state.EcoName }; Action = { param($Choice) Set-EcoMode $Choice } }
    @{
        Text  = 'Připomínky'
        Items = @(
            @{ Text = 'Pitný režim (každou hodinu)'; Check = { $state.Reminders.Drink }; Action = { Set-Reminder 'Drink' (-not $state.Reminders.Drink) } }
            @{ Text = 'Protažení (každé 2 hodiny)'; Check = { $state.Reminders.Stretch }; Action = { Set-Reminder 'Stretch' (-not $state.Reminders.Stretch) } }
            @{ Text = 'Pomodoro (25 min práce, 5 min pauza)'; Check = { $state.Pomodoro }; Action = { Set-Reminder 'Pomodoro' (-not $state.Pomodoro) } }
        )
    }
    @{
        Text  = 'Nastavení'
        Items = @(
            @{ Text = 'Náhodné chování'; Check = { $state.RandomBehavior }; Action = { Set-RandomBehavior (-not $state.RandomBehavior) } }
            @{ Text = 'Chůze přes monitory'; Check = { $state.CrossMonitors }; Action = { Set-MonitorCrossing (-not $state.CrossMonitors) } }
            @{ Text = 'Sezónní převleky'; Check = { $state.Costumes }; Action = { Set-CostumeEnabled (-not $state.Costumes) } }
            @{ Text = 'Tichý režim (bez bublin)'; Check = { $state.Quiet }; Action = { Set-Quiet (-not $state.Quiet) } }
            @{ Text = 'Zvuk (kvák)'; Check = { $state.Sound }; Action = { Set-Sound (-not $state.Sound) } }
            @{ Text = 'Vždy navrchu'; Check = { $state.Topmost }; Action = { Set-Topmost (-not $state.Topmost) } }
        )
    }
    '-'
    @{ Text = 'Ukončit'; Action = { $window.Close() } }
)

function New-MenuEntry {
    # Jedna položka: WPF MenuItem (menu kachny), nebo WinForms ToolStripMenuItem (menu ikony).
    # Tag nese popis položky (Spec) a u voleb zvolenou možnost (Choice); kliknutí řeší Invoke-MenuEntry.
    param($Tag, [bool]$Tray, [bool]$Clickable)
    if ($Tray) { $item = New-Object System.Windows.Forms.ToolStripMenuItem } else { $item = New-Object System.Windows.Controls.MenuItem }
    $item.Tag = $Tag
    if ($Clickable) { $item.Add_Click({ Invoke-MenuEntry $this.Tag }) }
    return $item
}

function New-MenuSeparator {
    param([bool]$Tray)
    if ($Tray) { return (New-Object System.Windows.Forms.ToolStripSeparator) }
    return (New-Object System.Windows.Controls.Separator)
}

function Add-MenuEntry {
    # Naplní menu podle $menuSpec (stejné položky u kachny i u ikony, položky s Tray jen u ikony).
    # Podmenu (Choices, Items) nemá vlastní akci – klik na volbu by k němu jinak ve WPF probublal.
    param($Target, $Spec, [bool]$Tray)
    foreach ($entry in $Spec) {
        if ($entry -is [string]) {
            [void]$Target.Add((New-MenuSeparator $Tray))
            continue
        }
        if ($entry.Tray -and -not $Tray) { continue }
        $isSubmenu = $null -ne $entry.Choices -or $null -ne $entry.Items
        $item = New-MenuEntry -Tag @{ Spec = $entry; Choice = $null } -Tray $Tray -Clickable (-not $isSubmenu)
        if ($entry.Gesture -and -not $Tray) { $item.InputGestureText = $entry.Gesture }
        # přiřadit přímo (ne $x = if ...): přes if by se prázdná kolekce rozbalila na $null
        if ($Tray) { $children = $item.DropDownItems } else { $children = $item.Items }
        if ($null -ne $entry.Choices) {
            foreach ($choice in @(& $entry.Choices)) {
                [void]$children.Add((New-MenuEntry -Tag @{ Spec = $entry; Choice = $choice } -Tray $Tray -Clickable $true))
            }
        }
        if ($null -ne $entry.Items) { Add-MenuEntry -Target $children -Spec $entry.Items -Tray $Tray }
        [void]$Target.Add($item)
    }
}

function Invoke-MenuEntry {
    param($Tag)
    if ($null -ne $Tag.Choice) { & $Tag.Spec.Action $Tag.Choice } else { & $Tag.Spec.Action }
}

function Update-MenuState {
    # Popisky a zaškrtnutí podle aktuálního stavu (volá se při otevření obou menu, i v podmenu).
    param($Items, [bool]$Tray)
    foreach ($item in $Items) {
        $tag = $item.Tag
        if ($null -eq $tag) { continue }   # oddělovač
        $spec = $tag.Spec
        if ($null -ne $tag.Choice) { $text = [string]$tag.Choice }
        elseif ($spec.Text -is [scriptblock]) { $text = & $spec.Text }
        else { $text = $spec.Text }
        $checked = $false
        if ($null -ne $spec.Check) {
            if ($null -ne $tag.Choice) { $checked = [bool](& $spec.Check $tag.Choice) } else { $checked = [bool](& $spec.Check) }
        }
        if ($Tray) {
            $item.Text = $text
            $item.Checked = $checked
            Update-MenuState -Items $item.DropDownItems -Tray $true
        } else {
            $item.Header = $text
            $item.IsChecked = $checked
            Update-MenuState -Items $item.Items -Tray $false
        }
    }
}

function New-DuckIcon {
    # Malá kachna pro oznamovací oblast (32x32).
    try {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 1.5
        $yellow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 251, 176, 59))
        $orange = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 241, 90, 36))
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
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
            $pen.Dispose()
            $yellow.Dispose()
            $orange.Dispose()
        }
        $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())   # ikona má vlastní kopii obrázku
        $bmp.Dispose()
        return $icon
    } catch {
        return [System.Drawing.SystemIcons]::Application
    }
}

# ---------------------------------------------------------------------------
# Sestavení okna
# ---------------------------------------------------------------------------
# Kreslení bez grafické karty: malé průhledné okno by se jinak po každém snímku kopírovalo z GPU do paměti.
# Nižší priorita procesu: kachna nikdy nezpomalí práci. (Obojí jen nastavení, žádný kód navíc.)
if ($config.SoftwareRendering) { [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly' }
try {
    [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = $config.Priority
} catch {
    Write-Verbose "Kachna: prioritu procesu nejde změnit: $_"
}

$window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($name in 'RootFlip', 'TextFlip', 'SpeechText', 'SpeechBubble', 'SpeechBorder', 'path2', 'path4', 'path6', 'circle12', 'circle14', 'SleepEye', 'CostumeSanta', 'CostumeWitch', 'CostumeGlasses') { $ui[$name] = $window.FindName($name) }
$bubbleBrushes = @{
    Normal   = [System.Windows.Media.Brushes]::White
    Reminder = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFDDEEFF'))
}

$clock = [System.Diagnostics.Stopwatch]::StartNew()
$state = @{
    X               = 0.0
    Y               = 0.0
    Direction       = 1           # 1 = doprava, -1 = doleva
    Motion          = 'None'      # běžící animace okna: None / Walk / Fall / HopUp
    MotionId        = 0           # číslo poslední animace (Completed nahrazené animace se ignoruje)
    WalkGoal        = 'Edge'      # cíl chůze: Edge / Entry / Food / Cursor
    WalkTarget      = 0.0
    WalkFromX       = 0.0
    Paused          = $false
    Hidden          = $false
    HiddenByLock    = $false      # schovalo ji zamčení PC (po odemčení se vrátí)
    Locked          = $false
    Sleeping        = $false
    Dragging        = $false
    Falling         = $false
    FallReason      = 'Drop'      # Drop / Cross / Hop: co kachna řekne po přistání
    Crossing        = $false      # přechází na sousední monitor
    Resting         = $false
    RestUntil       = 0.0
    NextDecision    = 5.0
    SpeedFactor     = 1.0
    Speed           = 15.0        # aktuální rychlost chůze v DIP/s (Update-Speed)
    SpeedName       = $config.DefaultSpeed
    PhraseSpeedName = $config.DefaultPhraseSpeed
    RandomBehavior  = $config.RandomBehavior
    CrossMonitors   = $config.CrossMonitors
    Costumes        = $config.Costumes
    Costume         = ''
    Sound           = $config.Sound
    Topmost         = $config.Topmost
    Quiet           = $false
    Follow          = $false
    EcoName         = $config.DefaultEco
    EcoMode         = $config.EcoModes[$config.DefaultEco]
    EcoActive       = $false
    Power           = $null       # napájení (Get-PowerInfo)
    Area            = $null       # pracovní plocha aktuálního monitoru v DIP
    MinX            = 0.0         # meze chůze odvozené z plochy (Set-Area)
    MaxX            = 0.0
    GroundY         = 0.0
    PxPerDip        = 1.0
    NextAreaCheck   = 0.0
    NextPowerCheck  = 0.0
    LastActivity    = 0.0         # kdy se naposledy pohnula myš
    LastCursor      = ''
    LastPhrase      = ''
    BubbleUntil     = [double]::MaxValue
    BubbleBackAt    = 0.0
    Food            = $null       # rohlík (X = střed v DIP)
    Eating          = $false
    EatUntil        = 0.0
    Distance        = 0.0         # dnes ušlá vzdálenost (DIP)
    DistanceDate    = [datetime]::MinValue
    Reminders       = @{ Drink = $false; Stretch = $false }
    ReminderDue     = @{ Drink = 0.0; Stretch = 0.0 }
    Pomodoro        = $true
    PomodoroPhase   = 'Work'
    PomodoroDue     = 0.0
    DoubleClickSec  = 0.5
    Hwnd            = [IntPtr]::Zero
    AnimReady       = $false
    LegsRunning     = $false
    LegsFps         = 0
    GlowRunning     = $false
    GlowFps         = 0
    CrumbWindow     = $null
    Player          = $null
    SysHandlers     = $null
    ErrorShown      = $false
}

# Nohy: storyboard v kódu (ne v XAML), aby šel zastavit (Stop), zrychlit podle chůze a omezit snímky
$legs = New-Object System.Windows.Media.Animation.Storyboard
foreach ($leg in @(@{ Name = 'path2'; To = 35 }, @{ Name = 'path4'; To = -35 })) {
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = 0
    $anim.To = $leg.To
    $anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(1))
    $anim.AutoReverse = $true
    $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    [System.Windows.Media.Animation.Storyboard]::SetTarget($anim, $ui[$leg.Name])
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($anim, (New-Object System.Windows.PropertyPath '(0).(1)',
            ([System.Windows.UIElement]::RenderTransformProperty), ([System.Windows.Media.TranslateTransform]::XProperty)))
    $legs.Children.Add($anim)
}

# Tělo pomalu mění odstín žluté (jako ve v1); také v kódu, aby šlo zastavit (pauza, spánek, skrytí, úsporný režim)
$glow = New-Object System.Windows.Media.Animation.Storyboard
$anim = New-Object System.Windows.Media.Animation.ColorAnimation
$anim.To = [System.Windows.Media.ColorConverter]::ConvertFromString('#FFFBE03B')
$anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(3))
$anim.AutoReverse = $true
$anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
[System.Windows.Media.Animation.Storyboard]::SetTarget($anim, $ui.path6)
[System.Windows.Media.Animation.Storyboard]::SetTargetProperty($anim, (New-Object System.Windows.PropertyPath '(0).(1)',
        ([System.Windows.Shapes.Shape]::FillProperty), ([System.Windows.Media.SolidColorBrush]::ColorProperty)))
$glow.Children.Add($anim)

# Časovače (pohyb samotný řídí animace WPF, PowerShell běží jen jednou za sekundu)
$heartTimer = New-Object System.Windows.Threading.DispatcherTimer    # interval nastavuje Restart-HeartTimer
$heartTimer.Add_Tick({
    try {
        Invoke-Heartbeat
    } catch {
        if (-not $state.ErrorShown) {
            $state.ErrorShown = $true
            Write-Warning "Kachna: chyba: $_"
        }
    }
})
$speechTimer = New-Object System.Windows.Threading.DispatcherTimer   # interval nastavuje Restart-SpeechTimer
$speechTimer.Add_Tick({ Invoke-SpeechTick })
$clickTimer = New-Object System.Windows.Threading.DispatcherTimer    # klepnutí se vyhodnotí až po době dvojkliku
$clickTimer.Add_Tick({ Invoke-Click })
$hideTimer = New-Object System.Windows.Threading.DispatcherTimer     # "Skrýt na..."
$hideTimer.Add_Tick({ Invoke-HideTimer })

# Menu na pravém tlačítku
$menu = New-Object System.Windows.Controls.ContextMenu
Add-MenuEntry -Target $menu.Items -Spec $menuSpec -Tray $false
$menu.Add_Opened({ Update-MenuState -Items $menu.Items -Tray $false })
$window.ContextMenu = $menu

# Ikona v oznamovací oblasti (kachnu jde ovládat, i když není vidět; tady se skrytá kachna zase zobrazí)
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
Add-MenuEntry -Target $trayMenu.Items -Spec $menuSpec -Tray $true
$trayMenu.Add_Opening({ Update-MenuState -Items $trayMenu.Items -Tray $true })

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-DuckIcon
$tray.Text = 'Kachna (dvojklik = přivolat k myši)'
$tray.ContextMenuStrip = $trayMenu
$tray.Add_DoubleClick({ Invoke-Summon })

# Myš: klepnutí = pauza, dvojklik = poskok, tažení = přesun (DragMove čeká, dokud se tlačítko nepustí)
$window.Add_MouseLeftButtonDown({
    $_.Handled = $true
    if ($_.ClickCount -ge 2) {
        $clickTimer.Stop()   # první klepnutí dvojkliku pauzu nepřepne
        Start-Hop
        return
    }
    if ($state.Sleeping) { Set-Sleeping $false }
    $startLeft = $window.Left
    $startTop = $window.Top
    Start-Drag
    try { $window.DragMove() } catch { Write-Verbose "DragMove selhal: $_" }
    Complete-Drag -StartLeft $startLeft -StartTop $startTop
})

# Bublina uhne myši (dá se kliknout na okno pod ní)
$ui.SpeechBubble.Add_MouseEnter({ Hide-BubbleForHover })

# Okno vzniklo (ještě není vidět): umístit na levý spodní okraj hlavního monitoru, jako ve v1
$window.Add_SourceInitialized({
    $state.Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    $state.DoubleClickSec = [System.Windows.Forms.SystemInformation]::DoubleClickTime / 1000
    Set-Area (Get-WorkArea ([System.Windows.Forms.Screen]::PrimaryScreen))
    $state.X = $state.MinX
    $state.Y = $state.GroundY
    Set-WindowPosition
})

$window.Add_Loaded({
    $now = $clock.Elapsed.TotalSeconds
    $state.AnimReady = $true
    $state.LastActivity = $now
    $state.LastCursor = Get-CursorKey
    $state.NextDecision = $now + 5
    $state.NextAreaCheck = $now + $config.AreaCheckSec
    $state.NextPowerCheck = $now + $config.PowerCheckSec
    Update-Speed
    Update-Power
    Update-Costume
    try { Register-SystemEvent } catch { Write-Warning "Kachna: události Windows nejsou k dispozici, stačí pojistné kontroly: $_" }
    Show-Speech (Get-RandomPhrase $duckPhrases '')
    Update-Animation
    Restart-HeartTimer
    Restart-SpeechTimer
    Start-Walk
})

# Změna DPI okna (jiné škálování monitoru) – jen ve .NET Framework 4.6.2 a novějším
try { $window.Add_DpiChanged({ Request-AreaUpdate }) } catch { Write-Verbose "DpiChanged není k dispozici: $_" }

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
# Show + vlastní smyčka zpráv místo ShowDialog: ShowDialog by skončil už při skrytí okna (Hide), ne až při zavření.
$frame = New-Object System.Windows.Threading.DispatcherFrame
$window.Add_Closed({ $frame.Continue = $false })
try {
    $tray.Visible = $true
    $window.Show()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
} finally {
    foreach ($timer in @($heartTimer, $speechTimer, $clickTimer, $hideTimer)) { $timer.Stop() }
    Unregister-SystemEvent
    if ($null -ne $state.CrumbWindow) { $state.CrumbWindow.Close() }
    $tray.Visible = $false
    $tray.Dispose()
    $trayMenu.Dispose()
}
