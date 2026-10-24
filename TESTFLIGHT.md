# TestFlight-Verteilung (nur in diesem Fork)

Dieser Fork (`onkelennovending/opentara`) baut OpenTara auf zwei Wegen, beide ohne Mac,
ausschließlich im GitHub-Actions-macOS-Runner:

| Weg | Workflow | Signatur | Bundle-ID | Installation |
|-----|----------|----------|-----------|--------------|
| Fallback | **Build** (`.github/workflows/build-ipa.yml`), jeder Push | unsigniert | `kloster.OpenScaleIOS` (upstream) | Artefakt `OpenTara-unsigned.ipa` herunterladen, mit SideStore/AltStore und eigener Apple-ID signieren |
| TestFlight | **TestFlight** (`.github/workflows/testflight.yml`), Push auf `main` oder *Run workflow* | Apple Distribution, cloud-managed, Team `3P3KVS4BZK` (Onkel Enno Verkaufsautomaten GmbH) | `com.onkelenno.opentara` | TestFlight-App auf dem iPhone, interne Tester |

Der TestFlight-Weg liegt komplett in `.github/testflight/` und `.github/workflows/testflight.yml`;
die Projektdatei bleibt unverändert, damit der Upstream-Pull-Request nichts davon enthält.
Ohne die drei Secrets überspringt der Workflow den signierten Job sichtbar (Notice im Lauf)
und bleibt grün. Der Fork muss **öffentlich** bleiben, sonst kosten die macOS-Minuten Geld.

Weil die Bundle-IDs verschieden sind, sind SideStore- und TestFlight-Installation zwei
getrennte Apps mit getrennten Daten (CSV-Export/Import in der App überträgt die Historie).

## Einmalig von Hand (Browser und iPhone)

1. **Bundle-ID registrieren** – [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   → **+** → *App IDs* → *App* → Description `OpenTara`, Bundle ID *Explicit*
   `com.onkelenno.opentara`, **keine** Capabilities ankreuzen (OpenTara nutzt kein HealthKit,
   kein iCloud, keine Push-Nachrichten). Der Workflow könnte die ID mit `-allowProvisioningUpdates`
   auch selbst anlegen, aber Schritt 2 braucht sie vorher.
2. **App-Eintrag anlegen** – [App Store Connect → Apps](https://appstoreconnect.apple.com/apps)
   → **+** → *Neue App*: Plattform iOS, Name (muss im ganzen App Store eindeutig sein, z. B.
   `OpenTara Enno`), Primäre Sprache Deutsch, Bundle-ID aus Schritt 1, SKU z. B. `opentara`,
   Zugriff *Vollzugriff*. Das geht nicht per API. Für internes Testing ist kein App-Review nötig.
3. **API-Key** – [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
   → *Team Keys* → **+**: Name `GitHub Actions OpenTara`, Rolle **App Manager** (oder Admin);
   falls die Option erscheint, *Access to Cloud Managed Distribution Certificate* ankreuzen.
   Die `.p8` lässt sich **nur einmal** herunterladen. Der vorhandene Key `5BMYQUA359` ist
   brauchbar, wenn seine `.p8` noch vorliegt und die Rolle App Manager/Admin ist.
   Die *Issuer ID* steht oben auf derselben Seite, die *Key ID* in der Tabelle.
4. **Secrets im Fork setzen** – [Settings → Secrets and variables → Actions](https://github.com/onkelennovending/opentara/settings/secrets/actions):
   - `ASC_KEY_ID` – die Key ID (10 Zeichen)
   - `ASC_ISSUER_ID` – die Issuer ID (UUID)
   - `ASC_PRIVATE_KEY` – der komplette Inhalt der `.p8` inklusive der Zeilen
     `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----` (alternativ base64-kodiert)
5. **Workflow starten** – [Actions → TestFlight](https://github.com/onkelennovending/opentara/actions/workflows/testflight.yml)
   → *Run workflow* auf `main` (oder einfach auf `main` pushen). Der erste Lauf legt das
   cloud-verwaltete Distribution-Zertifikat und das Provisioning-Profil selbst an. Die
   Build-Nummer ist die Run-Nummer des Workflows, jeder Lauf liefert also eine neue.
6. **Tester eintragen** – App Store Connect → App → *TestFlight* → *Interne Tests* → Gruppe
   anlegen (z. B. `Onkel Enno`) → Tester hinzufügen. Interne Tester müssen Mitglied des Teams
   sein (*Users and Access*). Build der Gruppe zuordnen, sobald die Verarbeitung fertig ist
   (Mail „ready to test“, meist nach 5–15 Minuten).
7. **iPhone** – App *TestFlight* aus dem App Store installieren, Einladung annehmen, OpenTara
   installieren. Builds laufen nach **90 Tagen** ab; ein neuer Workflow-Lauf verlängert.

## Was der Workflow tut

- `xcodebuild archive` mit `-xcconfig .github/testflight/OnkelEnno.xcconfig`
  (Bundle-ID, Team, automatisches Signieren, `ITSAppUsesNonExemptEncryption = NO`),
  `-allowProvisioningUpdates` und dem API-Key (`-authenticationKeyPath/-KeyID/-KeyIssuerID`),
  `CURRENT_PROJECT_VERSION` = Run-Nummer.
- `xcodebuild -exportArchive` mit `.github/testflight/ExportOptions.plist`
  (`method: app-store-connect`, `destination: upload`): Export und Upload in einem Schritt,
  kein `altool` nötig.
- Die `.p8` wird nach `~/private_keys/AuthKey_<KEY_ID>.p8` geschrieben und am Ende gelöscht.
  Logs liegen als Artefakt `testflight-logs` am Lauf.

## Wenn etwas hakt

| Meldung im Log | Ursache |
|----------------|---------|
| `No profiles for 'com.onkelenno.opentara' were found` / `Provisioning profile … doesn't include` | Bundle-ID nicht registriert (Schritt 1) oder Key-Rolle reicht nicht für Cloud-Signing (Schritt 3) |
| `No suitable application records were found` / `bundle identifier … is not available` | App-Eintrag fehlt oder hat eine andere Bundle-ID (Schritt 2) |
| `Authentication credentials are missing or invalid` | Key ID, Issuer ID und `.p8` passen nicht zusammen, oder die `.p8` ist unvollständig kopiert |
| `The bundle version must be higher than the previously uploaded version` | Nur bei manuell hochgeladenen Builds möglich; dann `workflow_dispatch` erneut starten, die Run-Nummer steigt |
| `Missing Compliance` in App Store Connect | Darf nicht mehr vorkommen (`ITSAppUsesNonExemptEncryption = NO` in der xcconfig); sonst einmal im Browser „Nein“ beantworten |
| Job *Signed archive → TestFlight* ist `skipped` | Mindestens eines der drei Secrets fehlt oder ist leer (Schritt 4) |
