# Vagnkoll

Victron BLE-monitor för husvagn, körs som always-on display på en Android-telefon.

## Status

På väg mot Play Store-release (svensk + engelsk). Aktuell TODO-lista finns i [BESLUT.md](BESLUT.md) under "TODO inför release".

## Hårdvara

- **Display:** Honor 9, Android 9
- **Victron-enheter:** SmartShunt 150A + SmartSolar MPPT 75/15

## Bygga APK

GitHub Actions bygger automatiskt när du pushar till `main`:

1. Gå till **Actions**-fliken på GitHub
2. Välj senaste **Build APK**-körningen
3. Ladda ner artefakten `vagnkoll-release-apk`
4. Överför `app-release.apk` till telefonen och installera

## Installera på Honor 9

1. Aktivera **Inställningar → Säkerhet → Okända källor**
2. Öppna APK-filen → installera
3. Vid första start: ge **Bluetooth** + **plats**-rättigheter (plats krävs för BLE-skanning i Android)

## Hemligheter

`lib/secrets.dart` innehåller dina Victron-krypteringsnycklar och är `.gitignore`-ad så de
hamnar aldrig på GitHub. Mall finns i `lib/secrets.example.dart`.
