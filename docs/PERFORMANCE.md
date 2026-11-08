# Prestanda (steg 10, 8 nov 2026)

MacBook Pro M3 Pro, macOS 15.7, nätadapter, batteri 100 % (fulladdat). CPU är processens förbrukade CPU-tid under mätfönstret, delad med fönstrets längd (`ps -o time`). 100 % motsvarar en kärna. Minne är RSS.

## Stängd popover, Release-byggen

Forken och upstream 1.4.0 (`upstream/main`, `fc348a5`) kördes samtidigt. Inga systemdialoger var öppna före eller efter mätningen.

| Läge | Fönster | Forken | Upstream 1.4.0 |
|---|---|---|---|
| Användarens inställningar (ring Battery, mitt Wi-Fi, prickar Wi-Fi Signal) | 300 s | 0,10 % · 29 MB | 0,13 % · 35 MB |
| CPU i ring och mitt, nätverk i prickarna, före åtgärd | 180 s | 11,65 % · 61 MB | 0,03 % |
| Samma, omätning före åtgärd | 90 s | 11,16 % · 62 MB | – |
| Samma, efter åtgärd | 180 s | 1,49 % · 31 MB | 0,28 % |

**Klart-kravet är uppfyllt:** med stängd popover ligger forken inom mätbruset från upstream.

**Hittat och åtgärdat:** platser med mätvärden (CPU, minne, disk, nätverk) ändras varannan sekund. Varje ändring animerades, och under animationen ritade macOS om menyradsikonen i full bildfrekvens (`NSStatusItem _updateReplicants`, `CVDisplayLink`). Nu byter sådana värden direkt (`DuoGlyphView.animatesSampledValues`, falskt när `GlyphConfiguration.neededMetrics` inte är tom). Live-händelser animeras som vanligt. Kostnaden på cirka 1,5 % finns bara när användaren själv väljer sådana platser.

## Popoverns vyer, Debug-bygge

Mätt med debugstyrningen, 60 s per läge. Debug-bygget är långsammare än Release, så siffrorna är en övre gräns. Upstream saknar debugstyrning och dessa vyer och är inte med här. Claude-delen av AI Usage var avstängd för att undvika nyckelringsfrågor, och Codex-delen var på.

| Läge | CPU | Minne |
|---|---|---|
| Stängd, före öppning | 0,83 % | 56 MB |
| Huvudvy | 2,55 % | 70 MB |
| Detalj: Network | 1,47 % | 67 MB |
| Detalj: Battery | 0,87 % | 66 MB |
| Detalj: Bluetooth | 0,92 % | 64 MB |
| Detalj: System | 3,20 % | 73 MB |
| Detalj: Disk | 0,88 % | 59 MB |
| Detalj: AI Usage | 0,70 % | 59 MB |
| Stängd, efter stängning | 0,33 % | 59 MB |

System är dyrast, eftersom CPU-grafen ritas om varje sekund och toppprocesser mäts var 3:e sekund. CPU-tiden går tillbaka efter stängning, och minnet växer inte.

## Stationär Mac (simulerad), Debug-bygge

`simulateDesktopMac`, stängd popover, 120 s: 0,60 % · 56 MB. Här körs `AdaptiveRingMonitor` var 1,5 s, vilket är upstreams beteende. Upstream kan inte simulera läget, så ingen direkt jämförelse finns.

## Timers med stängd popover

`ModuleActivityTests` kör varje modul genom öppna, detalj, stäng och avaktivera och kontrollerar att `StatusModule.activeWork` är tom efteråt, med och utan batteri.

## Avvikelser från planen

- `powermetrics` kräver `sudo` och kördes inte, så energipåverkan är inte mätt. CPU-tid användes i stället.
- Time Profiler ersattes av `sample`.
- Popoverns vyer mättes 60 s per läge, inte 5 min.
- Den första mätningen av stängt läge kasserades, eftersom en behörighetsdialog kan ha hållit appen stilla. Tabellen visar omätningen utan dialoger.
