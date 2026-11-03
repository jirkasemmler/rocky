# PRD: Osobní trenér (domácí silový trénink s hlasovým vedením)

Verze 1.1, 2. 11. 2026. Autor: Jiri Semmler. Určeno pro: vývojového agenta (web / iOS).

## 1. Cíl a kontext
Aplikace vede jednoho uživatele domácím silovým tréninkem, 3x týdně večer, 20 až 30 minut, s vlastní vahou nebo činkami 2 kg a 5 kg. Hlavní hodnota: **hlídá rytmus tréninku a hlasem říká, kdy změnit cvik nebo odpočívat**, takže uživatel nemusí koukat do telefonu.

Cílový uživatel (v1): jeden člověk (Jiri), čeština, bez nutnosti účtu. Možné rozšíření později na veřejnou aplikaci.

## 2. Problémy, které řešíme
- Při cvičení nejde držet telefon a sledovat časovač.
- Chybí hlas, který přepíná cviky a pauzy.
- Chybí plán s postupným zvyšováním zátěže a evidence, co se cvičilo.

## 3. Rozsah v1 (MVP)
**Ano:**
1. Tři přednastavené tréninky A, B, C (viz příloha) a rotace A, B, C podle dnů.
2. Režim "Spustit trénink": intervalový časovač (výchozí 40 s cvičení, 20 s pauza, 90 s pauza mezi koly, 3 kola) s hlasovými pokyny v češtině.
3. Hlasové pokyny: oznámení názvu dalšího cviku, odpočet posledních 3 s, "změna cviku", "pauza", "konec kola", "konec tréninku", krátký tip na techniku (volitelně vypnutelný).
4. Rozcvička (3 min) před tréninkem a krátké protažení po něm.
5. Plánování: výběr dnů v týdnu a hodiny, lokální notifikace/připomínka večer.
6. Historie: po tréninku zápis (hotovo, subjektivní náročnost 1 až 5, použitá váha činek 2/5 kg, poznámka).
7. Progrese: po 2 týdnech doporučení "přidej opakování / zpomal spouštění / přejdi z 2 na 5 kg" podle zadané náročnosti.
8. Nastavení: délka intervalů, počet kol, hlasitost, zapnutí/vypnutí hlasu, vibrace.

**Ne (mimo v1):** sociální funkce, platby, video cviky, vlastní editor tréninků.

## 4. Uživatelské příběhy a akceptační kritéria
- Jako uživatel chci spustit dnešní trénink jedním klepnutím, aby se začal rozcvičkou.
  - AC: na úvodní obrazovce je tlačítko "Dnešní trénink" s názvem A/B/C podle rotace.
- Jako uživatel chci slyšet, kdy mám změnit cvik, abych se nemusel dívat na telefon.
  - AC: hlas ohlásí cvik 3 s před startem, odpočet 3-2-1 a změnu stavu; funguje se zhasnutou obrazovkou a při zamčeném telefonu.
- Jako uživatel chci pozastavit a pokračovat.
  - AC: tlačítko pauza, přeskočit cvik, zpět o cvik; velká tlačítka čitelná z 2 m.
- Jako uživatel chci připomínku večer v mých dnech.
  - AC: notifikace v nastavenou hodinu s názvem dnešního tréninku.
- Jako uživatel chci vidět, co jsem cvičil, a doporučení postupu.
  - AC: seznam tréninků s datem, váhou a náročností; po 2 týdnech zobrazí doporučení progrese.

## 5. Funkční požadavky
- Stavový automat tréninku: rozcvička, cvik, pauza, pauza mezi koly, protažení, konec.
- Hlas: syntéza řeči v češtině (iOS: AVSpeechSynthesizer, cs-CZ; web: Web Speech API nebo předgenerované audio). Pokyny nesmí překrývat hudbu uživatele (ducking zvuku).
- Obrazovka se při tréninku nezhasíná (wake lock).
- Offline provoz; data lokálně.
- Jazyk UI i hlasu: čeština.

## 6. Datový model (lokální)
- Exercise: id, název, popis techniky, typ (čas / opakování), varianta (vlastní váha / činky), strana (L/P).
- Workout: id (A/B/C), seznam Exercise v pořadí, výchozí intervaly.
- Session: id, datum, workoutId, počet kol, použitá váha (0/2/5 kg), náročnost 1 až 5, poznámka, dokončeno.
- Settings: dny, hodina, délky intervalů, počet kol, hlas zap/vyp, hlasitost.

## 7. Nefunkční požadavky
- Spuštění tréninku do 2 s, žádné přihlášení.
- Přesnost časovače ±200 ms, i v pozadí / při zamčeném telefonu (iOS: background audio režim).
- Přístupnost: velký kontrast, velký text, hlasové ovládání pauzy není nutné ve v1.
- Soukromí: žádná telemetrie ve v1, data jen na zařízení.

## 8. Doporučená technologie
**Rozhodnuto: nativní iOS (SwiftUI) + watchOS aplikace** pro Apple Watch Series 11 (watchOS 26 nebo novější). Web/PWA nepokrývá hodinky ani spolehlivý časovač při zamčené obrazovce, proto se v1 nedělá jako web. Sdílená logika časovače a dat v samostatném Swift balíčku.

## 8a. Rozšíření v1.1

### Apple Watch (watchOS)
- Samostatná aplikace s komplikací; trénink lze spustit z hodinek i z telefonu a oba displeje jsou synchronizované (WatchConnectivity).
- Na hodinkách: název cviku, velký časovač (cvičení/pauza), kolo X/3, další cvik, pauza/pokračovat, přeskočit.
- Haptika místo/spolu s hlasem: odlišné vzory pro start cvičení, odpočet posledních 3 s, pauzu a konec kola.
- Trénink běží jako HKWorkoutSession (typ: funkční silový trénink), takže časovač běží i při zhasnutém displeji; zápis tréninku do Apple Health (tep, kalorie, doba) je v rozsahu v1.1.
- Hlasové pokyny lze přehrávat z telefonu nebo přes sluchátka; na hodinkách jen haptika, pokud není zapnut zvuk.
- Hodinky fungují i bez telefonu v dosahu; sync po návratu.

### Měření timingu
- Aplikace měří skutečné časy: celková doba tréninku, doba každého cviku/pauzy, skutečné odchylky od plánu (pauzy, přeskočené cviky).
- Shrnutí po tréninku: plánovaný vs. skutečný čas, graf týdne, průměrná délka pauzy.
- Doporučení: pokud pauzy trvají trvale déle, nabídnout zkrácení; pokud trénink přesahuje 30 min, nabídnout menší počet kol.

### Checklist
- Před tréninkem: voda, činky 2/5 kg, podložka, rozcvička hotová.
- Během tréninku: odškrtávání cviků a kol (klepnutí na displeji nebo hodinkách; auto-odškrtnutí po dokončení intervalu).
- Po tréninku: protažení, zápis náročnosti.
- Checklist je součástí záznamu Session.

### Dohánění vynechaných tréninků
- Týdenní plán má 3 sloty (např. po, st, pá). Slot je "splněno" jen po dokončeném tréninku.
- Pokud slot do konce dne (23:59) není splněn, stav je "zameškáno" a vzniká **dluh**: zameškaný trénink se přesune na další den jako povinný dohon.
- Dohánění je vynucující, ale ne nebezpečné:
  - Další den se zobrazí jako první a nelze odložit bez zvolení důvodu (nemoc, zranění, cestování).
  - Eskalující připomínky: večer v nastavenou hodinu, o 1 hodinu později, o 2 hodiny později (notifikace + haptika na hodinkách), do 22:30.
  - Dohon nahrazuje plánovaný trénink toho dne, nepřidává se navíc (max. 1 trénink denně), aby nevznikalo přetížení; posune se rotace A/B/C a týden se tím zhustí.
  - Pokud je dluh více než 2 dny, aplikace nabídne zkrácenou verzi (2 kola) a neptá se na další dohnání, dokud není dluh splacen.
  - Volba "Nemoc/zranění" dluh vymaže a obnoví plán s lehčím návratem; bez důvodu nejde dluh smazat.
- Přehled série: počet týdnů v řadě s 3/3 splněnými tréninky.

### Akceptační kritéria v1.1
- Trénink spuštěný na hodinkách se zobrazí na telefonu do 2 s a naopak.
- Časovač nepřeruší zhasnutý displej hodinek ani zamčený telefon.
- Zameškaný trénink se automaticky objeví jako dohon další den s první notifikací v nastavenou hodinu.
- Po dokončení tréninku se dluh zruší a eskalující notifikace přestanou.
- Skutečné časy cviků jsou uloženy a zobrazeny ve shrnutí.

## 9. UX obrazovky
1. Domů: dnešní trénink, tlačítko Start, další tréninky v týdnu.
2. Náhled tréninku: seznam cviků, možnost změnit váhu a intervaly.
3. Běžící trénink: název cviku, velký časovač, kolo X/3, další cvik, pauza/přeskočit.
4. Shrnutí: hodnocení náročnosti, váha, poznámka, uložit.
5. Historie a progrese.
6. Nastavení.
7. Checklist tréninku.
8. Dluh / dohánění (banner na domovské obrazovce).
9. Apple Watch: Start, Běžící trénink, Shrnutí.

## 10. Metriky úspěchu
- 3 dokončené tréninky týdně po dobu 4 týdnů.
- Aspoň 90 % tréninků dokončeno bez ručního zásahu do časovače.

## 11. Otevřené otázky
- Přesná hodina nejzazší eskalace notifikací (výchozí 22:30)?
- Má dohánění povolit jen zkrácenou verzi, když je dluh delší než 2 dny?
- Mužský nebo ženský hlas, tempo řeči?
- Přidat hudbu / metronom pro tempo spouštění?

## Příloha A: Tréninky (3 kola, rozcvička 3 min)
**A:** dřepy s činkami (12 až 15), kliky (8 až 12), veslování s činkou v předklonu (12 na stranu), plank (30 až 45 s).
**B:** výpady vzad s činkami (10 na nohu), tlaky nad hlavu (10 až 12), glute bridge s činkou (15), dead bug (10 na stranu).
**C:** bulharský dřep (8 až 10 na nohu), kliky s užším postavením rukou (8 až 12), rumunský mrtvý tah s činkami (12 až 15), boční plank (20 až 30 s na stranu).

Progrese: po 2 týdnech přidat opakování nebo zpomalit spouštění (3 s dolů); při 15 snadných opakováních přejít z 2 kg na 5 kg.
