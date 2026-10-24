# TestFlight-Verteilung (nur in diesem Fork)

Dieser Fork (`onkelennovending/opentara`) baut OpenTara auf zwei Wegen, beide ohne Mac,
ausschließlich im GitHub-Actions-macOS-Runner:

| Weg | Workflow | Signatur | Bundle-ID | Installation |
|-----|----------|----------|-----------|--------------|
| Fallback | **Build** (`.github/workflows/build-ipa.yml`), jeder Push | unsigniert | `kloster.OpenScaleIOS` (upstream) | Artefakt `OpenTara-unsigned.ipa` herunterladen, mit SideStore/AltStore und eigener Apple-ID signieren |
| TestFlight | **TestFlight** (`.github/workflows/testflight.yml`), Push auf `main` oder *Run workflow* | iPhone Distribution, eigenes Zertifikat + App-Store-Profil (manuell), Team `3P3KVS4BZK` (Onkel Enno Verkaufsautomaten GmbH) | `com.onkelenno.opentara` | TestFlight-App auf dem iPhone, interne Tester |

Der TestFlight-Weg liegt komplett in `.github/testflight/` und `.github/workflows/testflight.yml`;
die Projektdatei bleibt unverändert, damit der Upstream-Pull-Request nichts davon enthält.
Ohne die sechs Secrets überspringt der Workflow den signierten Job sichtbar (Notice im Lauf,
nennt die fehlenden) und bleibt grün. Der Fork muss **öffentlich** bleiben, sonst kosten die macOS-Minuten Geld.

Weil die Bundle-IDs verschieden sind, sind SideStore- und TestFlight-Installation zwei
getrennte Apps mit getrennten Daten (CSV-Export/Import in der App überträgt die Historie).

## Stand 24.10.2026

Eingerichtet (per Claude in Chrome bzw. App-Store-Connect-API, Schlüsselmaterial liegt auf
openclaude1 in `/home/claude/ai/opentara-secrets/`, nur für den Nutzer `claude` lesbar):

| Was | Wert |
|-----|------|
| API-Key | `GitHub Actions OpenTara`, Key-ID `6CH4M49C77`, Rolle App-Manager, Issuer `33d1053e-0414-47ea-90a8-460e8d202438` |
| Bundle-ID | `com.onkelenno.opentara` (Portal-ID `4STA2ZF2P5`, keine Capabilities) |
| App-Eintrag | `OpenTara Enno`, App-ID `6826643751`, SKU `opentara`, Primärsprache Deutsch |
| Zertifikat | `iPhone Distribution: Onkel Enno Verkaufsautomaten GmbH`, Portal-ID `67RYZ62L4X`, gültig bis 24.10.2027 |
| Profil | `OpenTara Enno AppStore CI` (IOS_APP_STORE, Portal-ID `96TH575879`), gültig bis 24.10.2027 |
| Interne Testgruppe | `Onkel Enno` (alle Builds automatisch), Tester `info@onkel-enno-verkaufsautomaten.de` |

Secrets im Fork: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` (API-Key) sowie
`ASC_DIST_P12`, `ASC_DIST_P12_PASSWORD`, `ASC_PROVISIONING_PROFILE` (Signatur, base64).

**Warum manuell signiert wird:** `xcodebuild archive` mit automatischem Signieren verlangt auf
dem Runner ein *Development*-Profil, und das gibt es nur mit mindestens einem registrierten
Gerät im Team („Your team has no devices from which to generate a provisioning profile“). Ein
App-Store-Profil braucht kein Gerät. Deshalb erzeugt `asc.py` Zertifikat und Profil über die
API, und der Workflow importiert beides in einen temporären Schlüsselbund.

**Verlängern (vor dem 24.10.2027 oder nach Widerruf):** auf openclaude1
`python3 -I .github/testflight/asc.py issue-signing 6CH4M49C77 <ISSUER_ID> <AuthKey.p8>` –
erzeugt neues Zertifikat, neues Profil, neue `.p12` und setzt die drei Signatur-Secrets.

## Einmalig von Hand (Browser und iPhone) – bereits erledigt, zur Nachvollziehbarkeit

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
   - `ASC_DIST_P12`, `ASC_DIST_P12_PASSWORD`, `ASC_PROVISIONING_PROFILE` – legt
     `asc.py issue-signing` an (Distribution-Zertifikat als `.p12`, Passwort, App-Store-Profil).
     Von Hand: `set-secrets.sh` für die ersten drei, dann `asc.py issue-signing`.
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

## Automatische Verlängerung alle ~80 Tage

TestFlight-Builds laufen 90 Tage nach dem Upload ab. Der Workflow läuft deshalb zusätzlich
**jeden Montag 05:17 UTC** per Zeitplan; der Vorab-Job fragt über die API den neuesten gültigen
Build ab und lädt nur dann neu hoch, wenn er **80 Tage oder älter** ist (sonst „TestFlight up to
date“ als Notice, Job übersprungen). Jeder Push auf `main` und *Run workflow* laden weiterhin
immer hoch; mit dem Häkchen *only_if_due* verhält sich ein manueller Lauf wie der Zeitplan.

Drei Dinge dazu:

- **GitHub schaltet Zeitpläne nach 60 Tagen ohne Push ab.** Deshalb committet der Workflow nach
  jedem Upload die Marker-Datei `.github/testflight/last-upload.txt` (`[skip ci]`, löst nichts
  aus). Sollte der Zeitplan trotzdem abgeschaltet sein, steht im Actions-Tab ein gelbes Banner
  „This scheduled workflow is disabled“ mit *Enable*.
- Auf dem iPhone aktualisiert die TestFlight-App den Build selbst, wenn dort *Automatische
  Updates* für OpenTara Enno an ist (Standard).
- Zertifikat und Profil laufen am **24.10.2027** ab. Der Vorab-Job warnt ab 30 Tagen vorher
  (`::warning`); dann einmal `asc.py issue-signing` ausführen (unten), fertig.

## Was der Workflow tut

- Temporärer Schlüsselbund: Apple-WWDR-G3-Zwischenzertifikat, die `.p12` aus `ASC_DIST_P12`
  und das Profil aus `ASC_PROVISIONING_PROFILE` (nach `~/Library/MobileDevice/Provisioning Profiles/`).
- `xcodebuild archive` mit `-xcconfig .github/testflight/OnkelEnno.xcconfig`
  (Bundle-ID, Team, `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = iPhone Distribution`,
  `ITSAppUsesNonExemptEncryption = NO`), `PROVISIONING_PROFILE_SPECIFIER` = Name aus dem Profil,
  `CURRENT_PROJECT_VERSION` = Run-Nummer. Achtung: Werte aus `-xcconfig` schlagen Kommandozeilen-
  Argumente, deshalb stehen Profilname und Build-Nummer nicht in der Datei.
- `xcodebuild -exportArchive` mit einer im Lauf erzeugten `ExportOptions.plist`
  (`method: app-store-connect`, `destination: upload`, `signingStyle: manual`) und dem API-Key
  (`-authenticationKeyPath/-KeyID/-KeyIssuerID`): Export und Upload in einem Schritt, kein `altool`.
- `.p8`, Schlüsselbund und Profil werden am Ende gelöscht. Logs liegen als Artefakt
  `testflight-logs` am Lauf.

## Wenn etwas hakt

| Meldung im Log | Ursache |
|----------------|---------|
| `No profiles for 'com.onkelenno.opentara' were found` / `Your team has no devices` | Automatisches Signieren aktiv (xcconfig verändert?) – der Workflow signiert manuell, siehe oben |
| `No signing certificate "iOS Distribution" found` / `0 valid identities found` | `.p12` oder Passwort passen nicht, oder das Zertifikat wurde widerrufen → `asc.py issue-signing` |
| `Provisioning profile … doesn't include signing certificate` | Profil gehört zu einem anderen Zertifikat → `asc.py issue-signing` erzeugt beides zusammen neu |
| `No suitable application records were found` / `bundle identifier … is not available` | App-Eintrag fehlt oder hat eine andere Bundle-ID (Schritt 2) |
| `Authentication credentials are missing or invalid` | Key ID, Issuer ID und `.p8` passen nicht zusammen, oder die `.p8` ist unvollständig kopiert |
| `The bundle version must be higher than the previously uploaded version` | Nur bei manuell hochgeladenen Builds möglich; dann `workflow_dispatch` erneut starten, die Run-Nummer steigt |
| `Missing Compliance` in App Store Connect | Darf nicht mehr vorkommen (`ITSAppUsesNonExemptEncryption = NO` in der xcconfig); sonst einmal im Browser „Nein“ beantworten |
| Job *Signed archive → TestFlight* ist `skipped` | Mindestens eines der sechs Secrets fehlt oder ist leer; die Notice im Lauf nennt welche (Schritt 4) |
