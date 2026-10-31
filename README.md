# SkyFindr — Smart Airport Lost & Found

Our project for Craiova Hackathon.

- [`backend/`](backend/README.md) — FastAPI + YOLO (detection, classification, embeddings, color, optional OCR), matching, claims & QR
- [`app/`](app/README.md) — Flutter app (staff + passenger)

## Quick start

```powershell
# terminal 1
cd backend
.venv\Scripts\python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# terminal 2
cd app
flutter run -d chrome
```

## Demo script

1. **Passenger** (phone) → Home → **Report a lost item**: Bags · Backpack, Terminal 5 · Gate B4, "Black backpack with a Lufthansa sticker".
2. **Staff** (PC: Home → account icon → Airport staff mode) → Intake: photograph a black backpack, zone Gate B4, hidden detail "Lufthansa sticker" → Register.
3. Passenger instantly gets *"Possible match found!"* → My reports → **Review potential match** → **Verify ownership & claim** → answer → *Claim under review*.
4. Staff → **Review** → compare answer with hidden detail → **Approve**. Passenger gets *"Ready for pickup"* → **Open pickup pass** (QR).
5. Staff → **Pick-up** → scan / enter the code → **Hand over** → report moves to *Closed*, status *Recovered*.
