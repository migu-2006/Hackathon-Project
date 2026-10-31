# SkyFindr — Flutter app

The passenger app follows the design in `../GUI.png` (light + dark, follows the system
setting; switch in Account ⚙ → Appearance).

| Passenger tab | Screens |
|---|---|
| **Home** | "Let's get you reunited." · airport card · Report a lost item · Browse found items · latest report |
| **Find items** | Search + filters (date, category, terminal) · photo search ("A familiar starting point." → "A closer look.") · terminal map (🗺 icon) · item details → Verify ownership & claim |
| **My reports** | Active / Closed · progress timeline · next step · private claim details · **Pickup pass** (QR) |
| **Help** | Desk info, how it works, FAQ, settings |

Claim flow: *Verify ownership* (private answer) → **Claim under review** → staff approve → **Ready for pickup** (QR) → desk scan → **Recovered**.

**Staff mode** (Home → account icon → Airport staff mode):

| Tab | What it does |
|---|---|
| Intake | Photograph a found item → AI fills category / color / text → pick zone → register (auto-notifies matching passengers) |
| Inventory | Available / recovered items |
| Review | Compare the passenger's private answer with the hidden detail → Approve (passenger gets the pickup pass) / Reject |
| Pick-up | Scan the passenger QR (or type the code) → identity check → Hand over |

Optional: put a terminal photo at `assets/images/airport.jpg` to replace the illustrated header on Home.

Realtime match notifications arrive over the backend WebSocket (`/ws/{userId}`) and show as a snackbar + badge.

## Run

Start the backend first (see `../backend/README.md`), then:

```powershell
flutter run -d chrome          # web (camera = file picker / webcam)
flutter run -d <android-id>    # Android emulator uses http://10.0.2.2:8000 automatically
```

On a physical phone, tap ⚙ on the start screen and set the backend URL to your PC's LAN IP,
e.g. `http://192.168.1.10:8000` (the backend must run with `--host 0.0.0.0`).

### Windows desktop

```powershell
flutter run -d windows                 # dev, with hot reload
flutter build windows --release        # -> build\windows\x64\runner\Release\SkyFindr.exe
```

Needs Windows **Developer Mode** and Visual Studio (C++ desktop workload). Ship the whole `Release`
folder (zipped in `../dist/SkyFindr-windows.zip`), not just the `.exe`. On desktop, photos are
picked from files and the pick-up desk uses typed codes (the QR scanner plugin is mobile/web only;
a USB barcode scanner that types into the code field also works).

## Structure

```
lib/
  main.dart            role selection, backend URL setting, anonymous passenger id
  api.dart             HTTP + WebSocket client for the FastAPI backend
  models.dart          FoundItem, LostReport, Match, Zone, ...
  widgets.dart         shared UI (item cards, photo picker, dropdowns)
  screens/staff/       intake, inventory, pick-up desk (QR scanner + claim review)
  screens/passenger/   search, map, report, my items, claim + QR
```

## Launcher icon

The SkyFindr icon is drawn by `tool/make_icon.py` (writes `assets/icon/`) and installed for Android
(adaptive), iOS, web and Windows with `flutter_launcher_icons`:

```powershell
..\backend\.venv\Scripts\python tool\make_icon.py
dart run flutter_launcher_icons
```
