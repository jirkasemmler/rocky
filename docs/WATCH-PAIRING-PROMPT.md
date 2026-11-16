# Analýza: Apple Watch se nepáruje s Xcode (vývojářská instalace)

Jsi zkušený iOS/watchOS vývojář a síťový diagnostik. Pomoz mi zjistit, proč se moje Apple Watch
nedaří spárovat s Xcode, a navrhni postup, jak ji spárovat. Pracuješ na mém Macu a můžeš spouštět
diagnostické příkazy. Nic neodinstalovávej, neodpárovávej hodinky od iPhonu a neměň síťové
nastavení, dokud mi neřekneš proč a já to neschválím.

## Cíl
Nainstalovat vlastní watchOS aplikaci (Rocky, bundle `cz.semmler.rocky.watchkitapp`, embedded
v iOS aplikaci `cz.semmler.rocky`) z Xcode na moje skutečné hodinky.

## Prostředí
- **Mac:** macOS (Darwin 27), Xcode 27.2 (iOS/watchOS 27.2 SDK). Podepisování přes bezplatný
  Apple ID „Personal Team“ (team `664248ZZ76`).
- **iPhone:** iPhone 15, iOS 27.0.1, Vývojářský režim zapnutý, připojený kabelem USB-C. Párování
  s Xcode funguje: `xcrun devicectl list devices` ho ukazuje jako `connected`/`physical` a iOS
  aplikaci na něj normálně instaluji.
- **Hodinky:** spárované s tímto iPhonem. Model a verzi watchOS doplním (viz níže).
- **Síť:**
  - Mac je na Wi-Fi a má zapnutý Bluetooth.
  - Na Macu běží Tailscale (VPN). Při pokusech byl odpojený, bez změny.
  - Firewall na Macu je zapnutý (stealth mode vypnutý).
  - Docker (OrbStack/Docker Desktop) vytvořil hodně bridge rozhraní. V `netstat -rn` je kromě
    `default 192.168.191.1 en0` i řada `default link#NN bridge100…bridge108`. Docker má
    vyčerpaný pool adres (40 sítí).
  - iPhone na screenshotu Xcode ukazoval operátora „T-Mobile CZ“; nevím jistě, jestli byl na
    stejné Wi-Fi jako Mac.

## Co se dělo
1. `xcrun devicectl list devices` ani `xcrun xctrace list devices` hodinky **nikdy** neukázaly
   (jen iPhone a simulátory).
2. Na hodinkách jsem v Nastavení → Soukromí a zabezpečení našel **Vývojářský režim**.
3. Xcode 27 → Window → Devices and Simulators → **+** → první ikona (telefon/tablet/hodinky)
   ukáže dialog **„Waiting to pair“** s textem: „On the device you'd like to pair, go to
   Settings > Privacy & Security > Developer Mode. Make sure Developer Mode is turned on.“
   Dole: „For devices running iOS 26 or watchOS 26 (or earlier), see WWDC 2022: Get to know
   Developer Mode.“
4. Na hodinkách se ve Vývojářském režimu objevila nabídka párování. Hodinky chtěly **svůj
   kód (jako při odemčení)**. Zadal jsem ho, ale Xcode zůstal na „Waiting to pair“. Žádný kód
   jsem do Xcode zadávat nemusel.
5. Hlídal jsem `devicectl` 2× po 30 minutách. Hodinky se neobjevily, ani po vypnutí Tailscale
   a opakovaném spuštění párování (Cancel → + → znovu potvrzení na hodinkách).
6. Xcode při instalaci na iPhone hlásil u iPhonu: „Auto-pair failed … Manual pairing of this
   device is already in progress“ (CoreDeviceError 4001). Visel tedy nějaký nedokončený
   ruční pokus o párování.

## Co od tebe chci
1. **Seřazené hypotézy** (nejpravděpodobnější první), proč párování nedoběhne. Zvaž zejména:
   - nesoulad verze watchOS a pairing flow (Xcode 27 vs. watchOS 26 a starší);
   - Bonjour/mDNS nebo lokální síť: Wi-Fi s izolací klientů, Docker bridge rozhraní a výchozí
     trasy, VPN, firewall;
   - visící „manual pairing in progress“ v CoreDevice;
   - stav párování iPhone ↔ hodinky ↔ Mac;
   - omezení bezplatného Personal Team;
   - známé chyby Xcode 27 / watchOS 27.
2. **Diagnostické příkazy** pro každou hypotézu, s vysvětlením, co výsledek znamená. Například:
   - `xcrun devicectl list devices -v`
   - `xcrun devicectl manage …`
   - `dns-sd -B _remotepairing._tcp` a podobné služby
   - `log stream --predicate` na `remotepairingd`, `CoreDevice`, `devicectl`
   - `ifconfig` / `netstat -rn`
   - stav firewallu pro Xcode a `remotepairingd`
   Spouštěj jen čtecí příkazy; pro všechno ostatní se nejdřív zeptej.
3. **Postup opravy** krok za krokem, od nejméně invazivního: resetovat visící párování,
   ověřit síť, dočasně vypnout Docker sítě/VPN/firewall (s mým souhlasem), restartovat
   služby. Až nakonec drastické kroky (odpárování hodinek), a jen s jasným varováním.
4. Až se hodinky v `devicectl` objeví, ověř, že jsou `available`/`connected`, a napiš, co
   musím udělat dál (Developer Mode, důvěra, podepsání cílů `RockyWatch` a
   `RockyWatchWidgets` týmem `664248ZZ76`).

## Údaje, které doplním (zeptej se na ně, pokud chybí)
- Model hodinek a verze watchOS (Nastavení → Obecné → Informace).
- Jsou hodinky i iPhone na stejné Wi-Fi jako Mac? Jaký typ sítě (domácí/firemní/hotspot)?
- Výstup `xcrun devicectl list devices -v` a `dns-sd -B _remotepairing._tcp` (spusť sám).
- Screenshot obrazovky Vývojářského režimu na hodinkách během párování.

Odpovídej česky, stručně a konkrétně.
