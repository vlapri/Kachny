# CLAUDE.md – Kachny

Zábavný projekt: kachna, která se prochází po spodním okraji obrazovky a mluví v bublině.
Komunikace s uživatelem, texty v UI i komentáře v kódu jsou **česky**. Kachna mluví v ženském rodě („jsem si jistá“).

## Soubory

| Soubor | Popis |
|---|---|
| `powershell_kachna_v2.ps1` | **Aktuální PowerShell verze** (WPF). Veškerý vývoj probíhá tady. |
| `powershell_kachna_v2.cmd` | Spouštěč v2 pro dvojklik (skrytá konzole, `-ExecutionPolicy Bypass`, `-STA`). Parametr `ladeni` = viditelná konzole. |
| `tests/Test-KachnaV2.ps1` | Testy v2 bez Windows/WPF (běží i v `pwsh` na Linuxu). |
| `powershell_kachna.ps1` | Původní v1. **Neměnit**, pokud o to uživatel výslovně nepožádá. |
| `linux_kachna*.sh` | Linuxová verze (bash). Uživatel teď pracuje jen s PowerShell verzí – neměnit bez požádání. |
| `*.gif`, `coffee_qr.png` | Obrázky pro README. |

## Konvence souborů (hlídají je testy)

- `.ps1`: **UTF-8 s BOM** (jinak Windows PowerShell 5.1 rozbije diakritiku) a konce řádků **CRLF**, bez tabulátorů.
  Nástroje typu Write/Edit BOM ani CRLF nehlídají – po úpravě převeď soubor znovu, např.:
  `python3 -c "p='powershell_kachna_v2.ps1';t=open(p,encoding='utf-8-sig').read().replace('\r\n','\n');open(p,'w',encoding='utf-8-sig',newline='\r\n').write(t)"`
- `.cmd`: **jen ASCII** (cmd čte soubor v OEM kódové stránce), **bez BOM**, **CRLF**.
- `README.md`: UTF-8 bez BOM, LF; dvojjazyčně CZ (EN v závorkách).

## Kompatibilita v2

- Musí fungovat ve **Windows PowerShell 5.1 i PowerShell 7** (jen Windows). Nepoužívat syntaxi jen pro PS 7
  (`??`, `?:`, `&&`, `||`, `ForEach-Object -Parallel` …).
- Žádné `Add-Type` s C# kódem (P/Invoke) – ve firemním prostředí může být kompilace blokovaná. Stačí WPF + WinForms.
- WPF potřebuje STA vlákno; skript se v MTA sám znovu spustí s `-STA`.

## Architektura v2 (`powershell_kachna_v2.ps1`)

Pořadí sekcí: kontrola prostředí → `$config` → hlášky → XAML → čisté funkce → monitory → stav a chování → menu/ikona → sestavení okna, časovače, události → `ShowDialog()`.

- **Stav** je v hashtable `$state` (pozice `X`/`Y` v DIP, `Direction`, `Paused`, `Dragging`, `Falling`, `Resting`, `Area` …).
  Obsluhy událostí běží v podřízeném oboru, proto se mění **klíče hashtable**, ne obyčejné proměnné (nebo `$script:`).
- **Souřadnice:** WinForms `Screen` vrací pixely, WPF `Window.Left/Top` je v DIP. Převod jde přes
  `PresentationSource.CompositionTarget.TransformFromDevice` (`Get-DipScale`, `Get-WorkArea`, `ConvertTo-DipRect`).
  Díky tomu funguje škálování 100–200 % i monitory s různým rozlišením.
- **Monitor:** při chůzi `Screen.FromHandle` (monitor okna), kontrola každých `AreaCheckSec` → reakce na změnu rozlišení,
  hlavního panelu nebo odpojení monitoru. Po puštění/přivolání `Screen.FromPoint(kurzor)` a plocha se během pádu
  **nemění** (jinak by u monitorů nad sebou kachna dopadla na špatný monitor).
- **Myš:** `MouseLeftButtonDown` → `DragMove()` (blokuje do puštění tlačítka) → `Complete-Drag`: posun ≤ `ClickTolerance`
  = klepnutí (pauza), jinak `Start-Fall` na monitoru pod kurzorem. Během tažení časovač s oknem nehýbe (`Dragging`).
- **Časovače:** `$moveTimer` (DispatcherTimer, `FrameMs`) → `Invoke-MoveTick`; `$speechTimer` → `Invoke-SpeechTick`.
  V pauze má `$speechTimer` interval `ComplaintIntervalSec` (60 s) a říká jen stížnosti, jinak `PhraseIntervalSec` (4 s).
- **Nohy:** storyboard `$legs` vzniká v kódu (ne v XAML), aby šel pozastavit (`Pause`/`Seek`) a zrychlit (`SetSpeedRatio`).
- **Zrcadlení:** obsah okna je nakreslený pro chůzi doprava; `RootFlip.ScaleX = Direction` zrcadlí kachnu i bublinu,
  `TextFlip` vrací text zpět, aby byl čitelný.
- **Kresba:** tvary kachny jsou převzaté z v1 beze změny; plátno 640×480 je oříznuté na kresbu (`Canvas.Left=-54`,
  `Canvas.Top=-25`, `DuckBox` 500×456) a Viewbox ho zmenší na 0,5 (stejná velikost jako v1). Při změně tvarů
  uprav ořez – test „ořez neusekne kachnu“ to hlídá.
- **Menu:** WPF `ContextMenu` na kachně + WinForms `NotifyIcon` s `ContextMenuStrip`; stav položek synchronizuje `Update-MenuState`.

### Úskalí PowerShellu s WPF

- V obsluze události je `$this` = odesílatel a `$_` = argumenty události.
- Uvnitř funkcí, které testy volají na Linuxu, nepoužívej literály typů WPF/WinForms (např. výčtové typy) –
  na Linuxu neexistují. Výčtové hodnoty předávej jako řetězec (`'BeginTime'`), PowerShell je převede.
- Funkce závislé na WPF/WinForms (`Get-DipScale`, `Get-WindowArea`, `Get-CursorArea`, `Get-CursorDip`) jsou malé,
  aby je testy mohly nahradit.

## Testování

```bash
pwsh -NoProfile -File tests/Test-KachnaV2.ps1          # návratový kód 0 = vše OK
KACHNA_PSSA=/cesta/PSScriptAnalyzer.psd1 pwsh -NoProfile -File tests/Test-KachnaV2.ps1   # i s PSScriptAnalyzerem
```

- Test načte funkce přímo z `powershell_kachna_v2.ps1` (AST) a nahradí okno, časovače a monitory náhradními objekty.
  Pokrývá: kódování, syntaxi, XAML, ořez kresby, hlášky (v1 ⊂ v2), `.cmd`, čisté funkce, chůzi na monitorech
  1080p/1200p/2K/4K se škálováním 100–200 %, pauzu a stížnosti, klepnutí, přetažení, pád, přivolání,
  změnu monitorů za běhu, náhodné chování a PSScriptAnalyzer (pokud je k dispozici).
- Když `pwsh` chybí (Linux): stáhni tarball z GitHub releases PowerShellu do scratchpadu a spusť ho odtud.
  PSGallery může být v sandboxu blokovaná – PSScriptAnalyzer jde stáhnout jako `.nupkg` z GitHub releases
  (`PowerShell/PSScriptAnalyzer`), rozbalit a předat cestu přes `KACHNA_PSSA`.
- Po každé změně v2 spusť testy; nové chování pokryj testem v `tests/Test-KachnaV2.ps1`.

### Co testy neověří (ruční kontrola na Windows)

Vykreslení WPF, skutečné DPI a chování myši se na Linuxu otestovat nedá. Ručně ověřit:
1. Start přes `powershell_kachna_v2.cmd` – žádné okno konzole, kachna vlevo dole na hlavním monitoru, ikona vedle hodin.
2. Kachna dojde k oběma okrajům, otočí se, bublina je vždy u hlavy a text je čitelný.
3. Klepnutí = pauza (nohy stojí, stížnost hned a pak každou minutu), další klepnutí = pokračování.
4. Přetažení na jiný monitor (i s jiným rozlišením/škálováním) → pád na spodní okraj, chůze jen po tom monitoru.
5. Pravé tlačítko → menu (pauza, rychlost, náhodné chování, ukončit); ikona vedle hodin → totéž + přivolání.
6. Změna rozlišení / odpojení monitoru → kachna zůstane vidět.
7. Ve Windows PowerShell 5.1 i PowerShell 7.
