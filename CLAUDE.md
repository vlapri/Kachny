# CLAUDE.md – Kachny

Zábavný projekt: kachna, která se prochází po spodním okraji obrazovky a mluví v bublině.
Komunikace s uživatelem, texty v UI i komentáře v kódu jsou **česky**. Kachna mluví v ženském rodě („jsem si jistá“).

## Soubory

| Soubor | Popis |
|---|---|
| `powershell_kachna_v2.ps1` | **Aktuální PowerShell verze** (WPF). Veškerý vývoj probíhá tady. |
| `powershell_kachna_v2.cmd` | Spouštěč v2 pro dvojklik (skrytá konzole, `-ExecutionPolicy Bypass`, `-STA`, Windows PowerShell 5.1). Parametr `ladeni` = viditelná konzole. |
| `tests/Test-KachnaV2.ps1` | Testy v2 bez Windows/WPF (běží i v `pwsh` na Linuxu). |
| `tests/Measure-KachnaV2.ps1` | Měření spotřeby běžící kachny (CPU čas a paměť za interval, jen Windows). |
| `kvak.wav` (volitelný) | Když leží vedle skriptu, přehraje se místo vygenerovaného kváknutí. V repozitáři není. |
| `powershell_kachna.ps1` | Původní v1. **Neměnit**, pokud o to uživatel výslovně nepožádá. |
| `linux_kachna*.sh` | Linuxová verze (bash). Uživatel teď pracuje jen s PowerShell verzí – neměnit bez požádání. |
| `*.gif`, `coffee_qr.png` | Obrázky pro README. |

## Konvence souborů (hlídají je testy)

- `.ps1`: **UTF-8 s BOM** (jinak Windows PowerShell 5.1 rozbije diakritiku) a konce řádků **CRLF**, bez tabulátorů.
  Platí i pro testy a měřicí skript. Nástroje typu Write/Edit BOM ani CRLF nehlídají – po úpravě převeď soubor znovu, např.:
  `python3 -c "p='powershell_kachna_v2.ps1';t=open(p,encoding='utf-8-sig').read().replace('\r\n','\n');open(p,'w',encoding='utf-8-sig',newline='\r\n').write(t)"`
  Na Windows bez Pythonu (v PowerShellu):
  ``$p = (Resolve-Path powershell_kachna_v2.ps1).Path; $t = [IO.File]::ReadAllText($p) -replace "\r?\n", "`r`n"; [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding $true))``
- `.cmd`: **jen ASCII** (cmd čte soubor v OEM kódové stránce), **bez BOM**, **CRLF**.
- `README.md`: UTF-8 bez BOM, LF; dvojjazyčně CZ (EN v závorkách).

## Kompatibilita v2

- Musí fungovat ve **Windows PowerShell 5.1 i PowerShell 7** (jen Windows). Nepoužívat syntaxi jen pro PS 7
  (`??`, `?:`, `&&`, `||`, `?.`, `ForEach-Object -Parallel` …) – test to hlídá.
- Žádné `Add-Type` s C# kódem (P/Invoke) – ve firemním prostředí může být kompilace blokovaná. Stačí WPF + WinForms
  (+ `Microsoft.Win32.SystemEvents`, `System.Media.SoundPlayer`). Proto se nečinnost pozná jen podle myši (klávesnici bez
  P/Invoke nezjistíš) a okno není průchozí pro myš (průhledné pixely ale klik propustí).
- WPF potřebuje STA vlákno; skript se v MTA sám znovu spustí s `-STA`.

## Architektura v2 (`powershell_kachna_v2.ps1`)

Pořadí sekcí: kontrola prostředí → `$config` → hlášky → XAML (kachna, rohlík) → čisté funkce → funkce závislé na Windows
→ stav a pohyb → bublina, animace a chování → menu/ikona → sestavení okna, storyboardy, časovače, události → `Show()` + `Dispatcher.PushFrame`.

- **Stav** je v hashtable `$state` (pozice `X`/`Y` v DIP, `Direction`, `Motion`, `Paused`, `Hidden`, `Sleeping`, `Dragging`,
  `Falling`, `Crossing`, `Resting`, `Area` + odvozené `MinX`/`MaxX`/`GroundY`/`PxPerDip` …). Obsluhy událostí běží v podřízeném
  oboru, proto se mění **klíče hashtable**, ne obyčejné proměnné (nebo `$script:`).
- **Pohyb řídí animace WPF, ne PowerShell.** `Start-WindowAnimation` spustí `DoubleAnimation` na `Window.Left` (chůze až k cíli)
  nebo `Window.Top` (pád = `QuadraticEase EaseIn`, tj. přesně volný pád z klidu; výskok poskoku = `EaseOut`; vynoření zpod
  okraje = lineárně). Po doběhnutí `Completed` → `Complete-Motion` → `Complete-Goal` (okraj: otočit nebo přejít na sousední
  monitor, rohlík: jíst, kurzor: stát). `$state.Motion` = běžící animace (`None`/`Walk`/`Fall`/`HopUp`), `MotionId` odliší
  `Completed` nahrazené animace. Během animace platí `$window.Left/Top`, `Sync-Position` je přepíše do `$state.X/Y`.
  - Doběhnutou animaci je nutné **uvolnit** (`Stop-WindowAnimation`: nejdřív `SetValue` aktuální hodnoty, pak
    `BeginAnimation(..., $null)`) – jinak by držela polohu a `Set-WindowPosition` by nic neudělal, a hlavně **před `DragMove`**
    (`Start-Drag` → `Stop-Motion`).
  - Snímky: chůze ~1 pixel na snímek (`Get-WalkFrameRate`, 8–30/s podle rychlosti a škálování), pád 60/s; `DesiredFrameRate`.
  - Po změně rychlosti, směru, plochy nebo úsporného režimu se chůze spustí znovu z aktuální polohy (`Start-Walk`).
  - Uspání PC (`Invoke-PowerModeChange Suspend`) pohyb zastaví, jinak by animace po probuzení dohnala dobu spánku.
- **Tep** `$heartTimer` (`Invoke-Heartbeat`, 1 s; „Pojď za myší“ 0,25 s; spící kachna 2 s): nečinnost a spánek, schování bubliny,
  napájení a převlek (1× za minutu), pojistná kontrola monitoru (`AreaCheckSec` = 5 s), připomínky (výchozí zapnuté podle `RemindersOn`, čas počítá `Initialize-Reminder` v `Loaded`), jídlo, odpočinek,
  náhodné chování, sledování kurzoru. Jiný „snímkový“ časovač není – PowerShell běží ~1× za sekundu.
- **Ostatní časovače:** `$speechTimer` (hlášky; v pauze `ComplaintIntervalSec` = 60 s a jen stížnosti, jinak `PhraseSpeeds`,
  v úsporném režimu 2× déle; interval vždy nastavuje `Restart-SpeechTimer`), `$clickTimer` (klepnutí se vyhodnotí až po době
  dvojkliku), `$hideTimer` („Skrýt na…“). DispatcherTimer.Start u běžícího časovače nic nedělá, proto vždy Stop → Start.
- **Souřadnice:** WinForms `Screen` vrací pixely, WPF `Window.Left/Top` je v DIP. Převod jde přes
  `PresentationSource.CompositionTarget.TransformFromDevice` (`Get-DipScale`, `Get-WorkArea`, `ConvertTo-DipRect`).
  `Get-WorkArea` vrací pracovní plochu a v `Bounds` celý monitor. Díky tomu funguje škálování 100–200 % i monitory s různým rozlišením.
- **Monitor:** `Screen.FromHandle` (monitor okna). Změny hlásí Windows (`SystemEvents.DisplaySettingsChanged`,
  `UserPreferenceChanged`, `Window.DpiChanged` → `Request-AreaUpdate`), pojistka každých `AreaCheckSec`. `Update-WorkArea`
  nic nepřeruší, když se plocha nezměnila. Po puštění/přivolání `Screen.FromPoint(kurzor)` a plocha se během pádu **nemění**
  (u monitorů nad sebou by kachna dopadla na špatný monitor), stejně tak během přechodu na sousední monitor (`Crossing`).
- **Chůze přes monitory** (menu, výchozí zapnuto): na okraji `Find-NeighborArea` hledá monitor, jehož celá plocha (`Bounds`)
  navazuje (hlavní panel mezi nimi nevadí) a na kterém by byla kachna vidět aspoň z půlky výšky. Kachna se stane jeho
  obyvatelkou (`Set-Area`), dojde na něj celá (cíl `Entry`) a spadne / vynoří se na jeho zem.
- **Myš:** `MouseLeftButtonDown` → `Start-Drag` → `DragMove()` (blokuje do puštění tlačítka) → `Complete-Drag`: posun
  ≤ `ClickTolerance` = klepnutí (pauza se přepne až po `DoubleClickTime`, `Invoke-Click`), jinak `Start-Fall` na monitoru pod
  kurzorem. Dvojklik (`ClickCount` 2) = `Start-Hop` a zrušení čekajícího klepnutí. Najetí na bublinu → `Hide-BubbleForHover`.
- **Bublina:** `Show-Speech` (po `BubbleSec` zmizí, `-Sticky` spánek, `-Reminder` modrá a déle), `Show-Phrase` = náhodná hláška +
  restart časovače hlášek. Tichý režim: žádné bubliny, časovač hlášek stojí. Vypnuté „kachní hlášky“ (`Set-PhrasesEnabled`): časovač hlášek stojí, reakce a připomínky zůstávají. Ocásek má barvu bubliny (binding v XAML).
  Hlášky podle situace (`Get-SituationKey`, `Get-SituationPhrase`: denní doba, svátky vč. Velikonoc, baterie, ušlá vzdálenost,
  doba běhu) tvoří asi čtvrtinu hlášek, pokud nějaké platí.
- **Animace těla:** storyboardy `$legs` (nohy přes `TranslateTransform.X`, ne `Canvas.Left` – nepřepočítává se rozvržení) a `$glow`
  (barva těla) vznikají v kódu (ne v XAML), aby šly zastavit, zrychlit (`SetSpeedRatio`) a omezit (`Set-FrameRate` = `DesiredFrameRate`,
  nohy 24/s, tělo 10/s). `Update-Animation`: nohy jen při pohybu, tělo jen u bdělé kachny mimo pauzu a úsporný režim.
  Zastavuje se vždy přes `Stop`, **ne `Pause`**: i pozastavený storyboard nechá WPF tikat ~60× za sekundu (ověřeno měřením).
  Test hlídá, že XAML animace nemá.
- **Šetření:** `ProcessRenderMode = SoftwareOnly` (`SoftwareRendering`; malé průhledné okno se jinak každý snímek kopíruje
  z GPU – změřit `tests/Measure-KachnaV2.ps1`), priorita `BelowNormal`, úsporný režim (`Vypnutý`/`Na baterii`/`Vždy`,
  `Update-Eco`: méně snímků, tělo stojí, méně hlášek).
- **Skrytí:** `Set-Hidden` zavolá `Hide()`, zastaví pohyb, všechny časovače i oba storyboardy (skrytá kachna má mít ~0 % CPU).
  Zobrazení: `Update-WorkArea -Force` ještě před `Show()` (monitor se mohl mezitím změnit), pak animace, tep a hlášky.
  Proto okno běží přes `Show()` + `Dispatcher.PushFrame`, ne `ShowDialog()` – ten by `Hide()` ukončilo (a s ním celý skript).
  „Skrýt na…“ = `Start-TimedHide` + `$hideTimer`. Zamčení PC (`SessionSwitch` → `Invoke-SessionSwitch`) kachnu schová
  (`HiddenByLock`), odemčení ji vrátí – ručně skrytou ne.
- **Spánek:** bez pohybu myši `IdleSleepMin` (10 min) → `Set-Sleeping`: zavřené oči (`SleepEye`), bublina Zzz, vše stojí, tep 2 s.
  Probudí ji pohyb myši, klepnutí, přivolání nebo připomínka.
- **Zrcadlení:** obsah okna je nakreslený pro chůzi doprava; `RootFlip.ScaleX = Direction` zrcadlí kachnu i bublinu,
  `TextFlip` vrací text zpět, aby byl čitelný.
- **Kresba:** tvary kachny jsou převzaté z v1 beze změny; plátno 640×480 je oříznuté na kresbu (`Canvas.Left=-54`,
  `Canvas.Top=-25`, `DuckBox` 500×456) a Viewbox ho zmenší na 0,5 (stejná velikost jako v1). Při změně tvarů
  uprav ořez – test „ořez neusekne kachnu“ to hlídá. Převleky (`CostumeSanta`/`Witch`/`Glasses`, `Get-Costume` podle data,
  menu, výchozí zapnuto) přesahují nad ořez do volného místa pod bublinou (Canvas ani Viewbox neořezávají) – test hlídá,
  že nezasahují do bubliny, ocásku ani mimo okno.
- **Krmení:** rohlík je malé samostatné okno (`$crumbXaml`, `Show-Crumb`, vznikne až při prvním krmení), padá stejnou křivkou.
  Kachna jde k němu zobákem napřed (`BeakOffset`), `EatSec` jí, pak poskočí. Přenesení na jiný monitor rohlík zruší.
- **Zvuk** (výchozí vypnuto): `New-QuackWave` vygeneruje WAV do paměti, `Start-Sound` přehraje (`kvak.wav` má přednost).
- **Menu:** obě menu (WPF `ContextMenu` na kachně, WinForms `ContextMenuStrip` u ikony) se staví z jednoho seznamu `$menuSpec`
  (`Text` nebo scriptblock, `Action`, `Check`, `Choices`, `Items`, `Tray` = jen u ikony, `Gesture`). `Add-MenuEntry` je postaví,
  `Update-MenuState` při otevření nastaví popisky a zaškrtnutí, `Invoke-MenuEntry` provede akci. Podmenu nemají vlastní akci
  (klik na volbu ve WPF probublá k rodiči). Skrytou kachnu jde zobrazit jen z menu ikony (nebo přivoláním).

### Úskalí PowerShellu s WPF

- V obsluze události je `$this` = odesílatel a `$_` = argumenty události (platí i pro scriptblock převedený na delegát
  se dvěma parametry, např. `[Microsoft.Win32.SessionSwitchEventHandler]{ ... $_.Reason }`).
- `$x = if (...) { $kolekce }` prázdnou kolekci (třeba `MenuItem.Items`) rozbalí na `$null` – přiřazuj uvnitř větví.
- Funkce volané v podmínkách (`if (Complete-Goal ...)`) nesmí nic vypisovat do výstupu, jinak se podmínka rozbije.
- Uvnitř funkcí, které testy volají na Linuxu, nepoužívej literály typů WPF/WinForms (např. výčtové typy) –
  na Linuxu neexistují. Výčtové hodnoty předávej jako řetězec (`'Hidden'`, `'EaseIn'`), PowerShell je převede.
- Funkce závislé na WPF/WinForms (`Get-DipScale`, `Get-WindowArea`, `Get-CursorArea`, `Get-AreaList`, `Get-CursorDip`,
  `Get-CursorKey`, `Get-PowerInfo`, `Get-Now`, `Start-WindowAnimation`, `Stop-WindowAnimation`, `Set-FrameRate`, `Show-Crumb`,
  `Hide-Crumb`, `Start-Sound`, `New-MenuEntry`, `New-MenuSeparator`) jsou malé, aby je testy mohly nahradit.

## Testování

```bash
pwsh -NoProfile -File tests/Test-KachnaV2.ps1          # návratový kód 0 = vše OK (~20 s)
KACHNA_PSSA=/cesta/PSScriptAnalyzer.psd1 pwsh -NoProfile -File tests/Test-KachnaV2.ps1   # i s PSScriptAnalyzerem
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-KachnaV2.ps1               # Windows PowerShell 5.1
```

- Test načte funkce přímo z `powershell_kachna_v2.ps1` (AST) a nahradí okno, animace, časovače, storyboardy, položky menu,
  monitory, myš, napájení, čas, zvuk a rohlík náhradními objekty. `Step-Sim`/`Invoke-Sim` posouvá čas: náhradní animace
  počítá polohu stejnými křivkami jako WPF a po doběhnutí volá `Complete-Motion`, časovače tikají podle intervalu.
  `$sim.Active` = uživatel hýbe myší (kachna neusne), pro test spánku se vypne. `Reset-Duck` = čerstvá kachna jako po `Loaded`.
  Pokrývá: kódování, syntaxi (i bez syntaxe jen pro PS 7), XAML, ořez kresby a převleků, hlášky (v1 ⊂ v2, délka), `.cmd`,
  čisté funkce, chůzi na monitorech 1080p/1200p/2K/4K se škálováním 100–200 %, snímky a tep (šetření CPU), úsporný režim,
  pauzu a stížnosti, klepnutí a dvojklik, přetažení, pád, přivolání, změnu monitorů za běhu (události i pojistku), chůzi přes
  monitory, náhodné chování, rychlost hlášek, bublinu a tichý režim, skrytí (i na čas), zamčení PC, uspání PC, spánek při
  nečinnosti, „Pojď za myší“, krmení, připomínky, situační hlášky, převleky, zvuk, menu a PSScriptAnalyzer (v2 i měřicí skript).
- Když `pwsh` chybí (Linux): stáhni tarball z GitHub releases PowerShellu do scratchpadu a spusť ho odtud.
  PSGallery může být v sandboxu blokovaná – PSScriptAnalyzer jde stáhnout jako `.nupkg` z GitHub releases
  (`PowerShell/PSScriptAnalyzer`), rozbalit a předat cestu přes `KACHNA_PSSA`.
- Po každé změně v2 spusť testy; nové chování pokryj testem v `tests/Test-KachnaV2.ps1`.

### Co testy neověří (ruční kontrola na Windows)

Vykreslení WPF, skutečné DPI, chování myši a události Windows se na Linuxu otestovat nedají. Ručně ověřit:
1. Start přes `powershell_kachna_v2.cmd` – žádné okno konzole, kachna vlevo dole na hlavním monitoru, ikona vedle hodin.
2. Kachna plynule dojde k oběma okrajům, otočí se, bublina je vždy u hlavy, text je čitelný a bublina po pár sekundách zmizí;
   najetí myší na bublinu ji schová.
3. Klepnutí = pauza (nohy stojí, stížnost a pak každou minutu), další klepnutí = pokračování; dvojklik = poskok bez pauzy.
4. Přetažení na jiný monitor (i s jiným rozlišením/škálováním) → pád na spodní okraj; na okraji přejde na sousední monitor
   (po vypnutí „Chůze přes monitory“ se otočí).
5. Pravé tlačítko → menu; ikona vedle hodin → totéž + přivolání. Vyzkoušet „Skrýt na…“, „Nakrmit rohlíkem“, „Pojď za myší“,
   úsporný režim, připomínky, převleky (změnou data), tichý režim, zvuk a „Vždy navrchu“.
6. Skrýt kachnu → zmizí a proces má ~0 % CPU; „Zobrazit kachnu“ u ikony → objeví se na stejném místě, ozve se a jde dál;
   přivolání skryté kachny ji ukáže u kurzoru.
7. Zamčení PC (Win+L) → kachna zmizí, po odemčení „Vítej zpět!“; 10 minut bez myši → usne (Zzz), pohyb myši ji probudí.
8. Změna rozlišení / odpojení monitoru / přesun hlavního panelu → kachna zůstane vidět (i když se to stane, zatímco je skrytá).
9. Spotřeba: `tests\Measure-KachnaV2.ps1` při chůzi, pauze, spánku a skrytí; porovnat `SoftwareRendering = $true` a `$false`.
10. Ve Windows PowerShell 5.1 i PowerShell 7.
