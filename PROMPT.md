# Vagnkoll — komplett specifikation

Detta är ett självständigt dokument som beskriver Vagnkoll-appen i sin helhet — syfte, hårdvara, tech stack, arkitektur, designbeslut, byggsystem, konfiguration, och pågående arbete. Avsett att kunna användas som en prompt för att återskapa eller vidareutveckla projektet.

---

## 1. Syfte

Always-on display i husvagn som visar Victron-batteristatus (SoC, V, A, sol-effekt, beräknad återstående laddtid, larm). Körs på en dedikerad Honor 9 (Android 9, arm64) som ligger uppvänd i vagnen. Användaren har även iPhone och vill kunna kolla läget hemifrån via webbgränssnitt över Tailscale.

## 2. Hårdvara

- **Display:** Honor 9 (modell STF-L09), Android 9 / EMUI 9, arm64-v8a
- **Victron-enheter:**
  - SmartShunt 500A/50mV (BLE Instant Readout)
  - SmartSolar MPPT 75/15 (BLE Instant Readout, inbyggd radio)
- **Batteri:** 150 Ah LiFePO4
- **Sol:** Max 160 W
- **Inverter:** 12V → 230V, idle ~0.5 A
- **Nätverk:** WiFi (hotspot eller routern i vagnen) + Tailscale för fjärråtkomst

## 3. Tech stack

- **Flutter 3.29 (Dart, SDK ≥3.5)** — cross-platform-ramverk, bygger för Android arm64
- **GitHub Actions** för byggsystem
- Ingen native Kotlin/Java skriven av oss — Flutter genererar Android-projektet, vi patchar bara Gradle-filerna

### Beroenden (`pubspec.yaml`)

| Paket | Version | Användning |
|---|---|---|
| `flutter_blue_plus` | 1.34.5 | BLE advertisement-lyssning (passiv) |
| `permission_handler` | ^11.3.1 | Bluetooth + plats-rättigheter |
| `cryptography` | ^2.7.0 | AES-CTR-dekryptering av Victron Instant Readout |
| `sqflite` | ^2.4.1 | Historik (SoC/V/A/sol-W) över tid |
| `path` / `path_provider` | ^1.9 / ^2.1 | Filsystemvägar för SQLite |
| `fl_chart` | ^0.69.0 | Grafer i historikvy |
| `shelf` + `shelf_router` | ^1.4 / ^1.1 | Inbäddad HTTP-server (port 8080) |
| `wakelock_plus` | ^1.2.10 | Håller skärmen tänd när appen är fram |
| `shared_preferences` | ^2.3.3 | Persistens för EnergyCounter, Classifier, ApplianceStore |
| `file_picker` | ^8.1.4 | Import/export av apparat-bibliotek |
| `intl` | ^0.19.0 | Datum/tidsformatering |
| `audioplayers` | ^6.1.0 | Larm-ljud |
| `flutter_foreground_task` | ^8.10.0 | Foreground service (BLE i bakgrunden, skärmlås) |

## 4. Vad appen kan (funktioner)

### Hemskärm
- Stor SoC-siffra med dynamisk färg (grön / gul / röd beroende på SoC-tröskelvärden)
- Spänning, ström, Ah kvar
- **Återstående laddtid** ("Full om Xh Ymin") eller **återstående drifttid** ("Tom om Xh Ymin") under SoC, baserat på `|ström| > 0.5 A`
- Sol-rutan: ampere/watt produktion + laddläge (bulk/absorption/float)
- Förbrukningsrutan: total last (A/W) beräknat från `sol − shunt`
- "Laddat idag" / "Använt idag" i Ah, persisterat över dygnet
- Lista över aktivt identifierade apparater
- Aktiva larm överst

### Webbgränssnitt (port 8080)
- Auto-refresh var 3:e sekund
- Samma data som hemskärmen i mobilanpassad layout
- "Senast Xs sen" diskret bredvid BATTERI/SOL när data är ≥15 s gammal (gult)
- Röd banner "⚠ Ingen Victron-data på Xs" när båda är ≥30 s gamla
- Gul banner "⏳ Väntar på första Victron-paket" före första kontakt
- Nåbar från alla nätverksinterface (LAN + Tailscale-IP)

### Historik
- SQLite-lagring, sampling var 10:e sekund
- Tunnas ut äldre data (downsampling)
- Grafer för SoC, ström, sol-effekt över valt tidsspann

### Apparatigenkänning
- Apparat-bibliotek (namn, förväntad effekt i W, tolerans i %, min varaktighet i s)
- Tröskel-baserad klassificering med subset-matching över alla kombinationer
- "Mät nu (5 sek)" som genväg för att fylla i förväntad effekt
- Stabilitetsfilter per apparat (måste hålla i sig N sekunder för att räknas)
- Persistent "aktiv apparat-set" — överlever app-omstart

### Larm
- SoC under tröskelvärden (warn/critical/emergency)
- Inverter idle (ström −0.5 A i mer än 5 min utan känd förbrukare)
- Hög förbrukning >72 W i 10 minuter
- Apparat-specifika varningar
- Larmljud + visning på skärm och i webvyn

### Bakgrundsdrift
- Foreground service körs som "Vagnkoll övervakar"-notifiering
- Wakelock + wifilock
- Auto-start vid paketuppdatering (men inte vid telefonomstart)

## 5. Arkitektur (översikt)

```
HomeScreen (main.dart)
  ├── VictronScanner (BLE → VictronState stream)
  │     • flutter_blue_plus med scan-filter (withRemoteIds)
  │     • Lyssnar passivt på Instant Readout-advertisements (inte GATT)
  │     • Watchdog: starta om scan om inga paket på 20 sek
  │     • Parsar shunt + solar separat, behåller egna timestamps
  ├── EnergyCounter (integrerar Ah använt/laddat med trapezmetoden)
  │     • Persisteras till SharedPreferences var 30:e sek + vid dispose
  │     • Återställs vid midnatt
  ├── HistoryStore (SQLite, samplar var 10 sek, tunnas ut)
  ├── ApplianceStore (apparatbibliotek, JSON i SharedPreferences)
  ├── Classifier (matchar last mot apparater, 5 s smoothing, subset matching)
  ├── AlarmEngine (SoC, inverter idle, hög förbrukning, apparat-varningar)
  ├── WebServer (HTTP shelf på port 8080, auto-refresh 3s, läser scanner.current)
  └── ForegroundService (flutter_foreground_task, håller appen vid liv vid skärmlås)
```

Alla komponenter delar samma `VictronState` via `VictronScanner.stream` / `.current`. Webservern läser direkt från samma objekt — inget IPC, ingen extra process.

## 6. Designbeslut (varför)

### BLE advertisement-lyssning (inte GATT)
**Beslut:** Passivt lyssna på Victron Instant Readout-advertisements.
**Varför:** Konfliktar inte med VictronConnect-appen (som tar GATT-slot). Lägre batteridrift. Enklare kod.
**Pris:** ~1 Hz sample rate — kan inte fånga snabba transienter (inrush-spikar).

### Scan-filter (withRemoteIds)
**Beslut:** Filtrera BLE-scan på MAC-adresserna till våra Victron-enheter.
**Varför:** Android 8.1+ levererar inga scan-resultat när skärmen är låst om filter saknas. Utan filter tystnar appen så fort telefonen låses.

### Apparatidentifiering — TRÖSKEL-baserad, inte vågforms-baserad
**Beslut:** Apparater identifieras via förväntad effekt (W) + tolerans (%) + min varaktighet (s).
**Varför:** Vågforms-baserad identifiering med Pearson-korrelation testades men gav inkonsekventa resultat pga BLE 1 Hz sample rate (kunde inte fånga inrush-detaljer). Tröskel-baserad är enklare, mer förutsägbar och tillräcklig för användarens behov (skilja kaffe 970 W från golvvärme 1500 W).

### Solar smoothing i klassificerare
**Beslut:** Solar och shunt utjämnas SEPARAT över 5 sek innan last beräknas.
**Varför:** Solar-paket och shunt-paket kommer i olika takt. Om solar uppdateras före shunt blir momentan last (solar − shunt) tillfälligt fel → falsklarm. Separat utjämning eliminerar timing-mismatch.

### Foreground Service
**Beslut:** Använder `flutter_foreground_task` med minimal TaskHandler.
**Varför:** Användaren vill kunna låsa telefonen (säkerhet om stulen) utan att appen stannar. Foreground service hindrar Android från att pausa BLE-stream + webbserver i bakgrunden.

### Hamilton-prioritering
**Beslut:** Under apparat-träning pausas Classifier, EnergyCounter, HistoryStore och telemetri-timer.
**Varför:** Honor 9 har begränsade resurser. Alla system samtidigt orsakade lagg som störde 1 Hz-samplingen. Endast BLE-stream + Trainer's captureTimer körs under inspelning.

### Persistent aktiv apparat-set
**Beslut:** `_activeIds` lagras i SharedPreferences.
**Varför:** App-omstart eller bakgrund-paus bör inte glömma vad som är "på".

### EnergyCounter persistens
**Beslut:** `usedAhToday` / `solarAhToday` / `netAhToday` + dagsnyckel persisteras i SharedPreferences.
**Varför:** Värdena ska överleva app-omstart inom samma dygn men nollas vid midnatt.

### Stale-data-varning i webvyn
**Beslut:** Visa "(X s sen)" vid ≥15 s, röd banner vid ≥30 s.
**Varför:** Användaren tittar från iPhone och måste se direkt om streamen tystnat — annars kan han stå och titta på gammal data utan att förstå att något är fel.

## 7. Byggsystem (GitHub Actions)

- Bygger APK vid varje push till `main`
- Cache: Gradle, Android SDK/NDK, Pub-paket, Flutter .dart_tool → bygget tar ~3–5 min
- **`--split-per-abi`** → en APK per arkitektur, bara `arm64-v8a` packas ut
- **Signering via Secrets:** `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`
- Workflow patchar `flutter create`-genererade Gradle-filer för Kotlin 2.1.0 + release-signering
- Tidsstämpel i Stockholm-tid via `TZ='Europe/Stockholm'`
- APK-filnamn: `vagnkoll-{HHMM}-{RUN}-{SHA}.apk`
- Build-ID syns även i appen (genereras till `lib/build_info.dart`)

## 8. Konfiguration

`lib/secrets.dart` är `.gitignore`-ad. Innehåller:

```dart
class VictronDevice {
  final String name;
  final String mac;           // ex 'F2:9D:4C:1A:BE:92'
  final String encryptionKey; // 32 hex tecken från VictronConnect
  final String kind;          // 'shunt' eller 'solar'
}

const List<VictronDevice> kVictronDevices = [/* en per enhet */];
const double kBatteryCapacityAh = 150.0;
const String kBatteryType = 'LiFePO4';
const double kSolarPanelMaxW = 160.0;
const double kSocWarn = 30.0;
const double kSocCritical = 20.0;
const double kSocEmergency = 15.0;
const double kInverterIdleAmps = 0.5;
const double kHighLoadWattsThreshold = 72.0;
const int kHighLoadMinutes = 10;
```

Mall finns i `lib/secrets.example.dart`. I CI skapas `secrets.dart` från GitHub Secrets.

Encryption key hittas i VictronConnect: enhet → inställningar → produktinfo → instant readout → encryption key.

## 9. Pågående / TODO

Se **`BESLUT.md` → "TODO inför release"** — den kanoniska listan.

## 10. Kända begränsningar

- **1 Hz BLE-sample rate** — kan inte fånga inrush-transienter
- **LiFePO4-laddtid optimistisk vid hög SoC** — absorption-fasen drar ner strömmen mot slutet
- **EMUI är aggressiv** — användaren måste manuellt lägga till appen i "Telefonhanteraren → App-start → tillåt automatisk start + bakgrundskörning". Detta är telefoninställning, inte kodfix.
- **Battery optimization** — bör manuellt undantas i Android-inställningar för säkerhets skull
- **Bara arm64** — andra Android-arkitekturer byggs inte
- **Inte iOS-testad** — Flutter kan bygga iOS men inget testat; inverkan på BLE-pluginet okänd
- **Webvyn är auto-refresh, inte WebSocket** — uppdateras var 3:e sekund, inte realtid

## 11. Användarpreferenser

- Användaren har stressrelaterad arbetsskada → **ETT steg i taget** vid sammansatta instruktioner
- **Diskutera UI-ändringar innan push** — pusha aldrig smågrejer mitt i diskussion
- **Aldrig manuella kod-redigeringar** — assistenten har Edit/Write/Bash, användaren ska inte be ändras själv
- **Tidsstämpel HHMM Stockholm-tid i alla commits**
- "r" för roger (radioamatör SM5TOG)

## 12. Referensfiler

- `BESLUT.md` — levande beslutsdokument (motivering bakom designval)
- `README.md` — användarinstruktioner (ska byggas ut, se TODO)
- `pubspec.yaml` — beroenden
- `.github/workflows/build-apk.yml` — bygg + signering
- `.github/workflows/generate-keystore.yml` — engångskörning för att skapa keystore till secrets
- `lib/secrets.example.dart` — mall för konfiguration
- `lib/main.dart` — HomeScreen + lifecycle
- `lib/victron/victron_scanner.dart` — BLE-scanning
- `lib/victron/victron_parser.dart` — AES-CTR-dekryptering + paket-tolkning
- `lib/energy_counter.dart` — Ah-integrering över dygn
- `lib/web/web_server.dart` — shelf HTTP-server
- `lib/foreground_task.dart` — bakgrundsservice
- `lib/appliances/` — apparat-bibliotek + klassificering
- `lib/history/` — SQLite-historik + grafer
- `lib/alarms/alarm_engine.dart` — larm-regler
