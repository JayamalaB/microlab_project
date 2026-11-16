# MicroLab

MicroLab is a home blood-test booking platform for a diagnostic lab chain with several branches.

- **Customers** book tests or packages for themselves and their family, either as a **home collection** (a technician comes to the house) or a **lab visit**.
- **Technicians** receive booking requests on their phone, travel to the customer, collect samples, take payment, and hand the samples to the lab.
- The lab's own billing system (the **ASMX** web service) is kept in sync at every step.

This repository holds the **API server** and the **Flutter mobile app** (one app with a customer mode and a technician mode). The admin panel is maintained separately.

> **New here?** Read this file, then [docs/architecture/overview.md](docs/architecture/overview.md), then [docs/database/data-dictionary.md](docs/database/data-dictionary.md). The [docs index](docs/README.md) lists everything else.

---

## Repository layout

```
microlab_project/
├── server/            Node.js API + Socket.IO server  (the core of the system)
│   ├── server.js      entry point: Express app, Socket.IO, schedulers, startup
│   ├── routes/        URL → controller wiring, one file per resource
│   ├── controllers/   request handlers (bookings, technicians, auth, branches…)
│   ├── services/      business logic shared across controllers
│   │                  (service charge, dispatch distance, ASMX sync, payments…)
│   ├── socket/        real-time dispatch + visit workflow (bookingSocket.js)
│   ├── scheduler/     node-cron jobs (scheduled dispatch, reminders, sweeps)
│   ├── middleware/    auth (JWT + session), access rules, admin HMAC, errors
│   ├── config/        DB pool, Firebase, ip_settings cache
│   ├── migrations/    SQL files, run by hand (see "Database migrations")
│   ├── rag/ data/     chatbot knowledge base (OpenAI)
│   ├── tests/         Jest: api/, services/, socket/, e2e/, …
│   └── logs/          runtime log files (git-ignored: contain phone numbers)
├── client/            Flutter app (Android / iOS / web)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── constants/app_constants.dart   server URL, timeouts
│   │   ├── models.dart, models/           data classes
│   │   ├── services/                      API, auth, socket, payments, notifications
│   │   └── screens/
│   │       ├── shared/       splash, login, OTP, location picker
│   │       ├── customer/     dashboard, booking, checkout, tracking, reports
│   │       └── technician/   dashboard, booking request overlay, visit detail, slots
│   └── backend/       legacy PHP helpers (not used by the Node server)
└── php/               legacy PHP scripts for the customer registry
```

## Tech stack

| Layer | Technology |
|---|---|
| API server | Node.js, **Express 5**, **Socket.IO 4**, `mysql2` (raw SQL; a few Sequelize models for tracking tables) |
| Database | **MySQL / MariaDB**. All application tables are prefixed `ip_` |
| Scheduled jobs | `node-cron`, running inside the server process |
| Mobile app | **Flutter** (Dart ≥ 3), `socket_io_client`, `google_maps_flutter`, `geolocator`, `firebase_messaging`, `razorpay_flutter` |
| Push notifications | Firebase Cloud Messaging (`firebase-admin` on the server) |
| Payments | Razorpay (orders, QR codes, webhook) |
| SMS / OTP | Ping4SMS |
| Lab system | NeuralArc **ASMX** web service: patient registry, technician login check, booking / payment / visit sync |
| Chatbot and voice | OpenAI (RAG over the lab website and FAQ), Sarvam (speech-to-text and text-to-speech) |
| Maps | Google Maps SDK and Directions API (in the app) |
| Tests | Jest, Supertest, socket.io-client |

## Running locally

### Prerequisites
- Node.js 20+ and npm
- Flutter SDK (Dart 3.x) plus Android Studio or Xcode for a device or emulator
- A MySQL / MariaDB database with the MicroLab schema. Ask the team lead for a **schema-only** dump of a test database; never use a production copy that contains patient data.

### Server

```bash
cd server
npm install
# Create server/.env. Ask the team lead for the values (see "Configuration").
npm run dev        # nodemon, restarts on file changes
# or: npm start
```

The server listens on `PORT` (default 3000). Check it with `GET /health` → `{"status":"ok"}`.

At startup the server:
1. loads `ip_settings` into memory;
2. loads the ASMX shared secret;
3. loads the chatbot knowledge base;
4. rebuilds the in-memory dispatch state from the database;
5. starts listening;
6. 60 seconds later, restarts any booking searches that were cut off by the restart.

### App

```bash
cd client
flutter pub get
# Point the app at your own server (the default is production):
flutter run --dart-define=MICROLAB_SERVER_URL=http://<your-ip>:3000
```

The same app serves both roles. After the OTP login, the server returns the user's role and the app opens either the customer dashboard or the technician dashboard (see `screens/shared/splash_screen.dart`).

### Tests

```bash
cd server
npm test                                            # whole suite
npx jest tests/api/technician.bookingOtp.test.js    # one file
```

Most tests mock the database (`config/__mocks__/db.js`): they queue the rows each SQL call should return, in order. **When you add a query to a handler, the mock order in its tests shifts.** Update the tests in the same change.

## Configuration

### `server/.env` (never committed)

Ask the team lead for the values. The variable **names** are listed below. Never paste the values into code, documentation, chat or tickets.

| Group | Variables |
|---|---|
| Server | `PORT`, `BASE_URL`, `NODE_ENV`, `ADMIN_PANEL_URL`, `WEBSITE_URL` |
| Database | `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_NAME`; chatbot DB: `CHATBOT_DB_HOST`, `CHATBOT_DB_PORT`, `CHATBOT_DB_USER`, `CHATBOT_DB_PASSWORD`, `CHATBOT_DB_NAME` |
| Auth | `JWT_SECRET`, `OTP_EXPIRY_MINUTES`, `OTP_MAX_ATTEMPTS`; demo / store-review login: `DEMO_MOBILE`, `DEMO_TECH_MOBILE`, `DEMO_OTP` |
| SMS | `PING4SMS_API_KEY`, `PING4SMS_SENDER_ID`, `PING4SMS_LOGIN_TEMPLATE_ID`, `PING4SMS_BOOKING_OTP_TEMPLATE_ID`, `PING4SMS_BOOKING_OTP_MESSAGE` |
| Payments | `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET` |
| ASMX (lab system) | `CLIENT_SERVER_SECRET`, `CLIENT_SERVER_URL`, `CLIENT_PATIENT_URL`, `TECHNICIAN_LOGIN_URL`, `CLIENT_BOOKING_URL`, `NEURALARC_BOOKING_URL`, `NEURALARC_EXISTING_BOOKING_URL`, `NEURALARC_CANCEL_URL`, `NEURALARC_RESCHEDULE_URL`, `NEURALARC_PAYMENT_URL`, `NEURALARC_PACKAGE_UPDATE_URL`, `NEURALARC_GET_REPORT_URL`, `VISIT_COMPLETED_URL` |
| Admin and keys | `ADMIN_WEBHOOK_SECRET`, `ADMIN_PORTAL_SECRET`, `DYNAMIC_KEY_ADMIN_HMAC_SECRET`, `DYNAMIC_KEY_MASTER_KEY` |
| AI | `OPENAI_API_KEY`, `SARVAM_API_KEY` |
| Tuning | `DISPATCH_LEAD_MINUTES` (default 60), `APPOINTMENT_BUFFER_MINUTES` (default 10), `LOG_RETENTION_DAYS` (default 90) |

`server/firebase-service-account.json` (Firebase Admin credentials) is also required and is git-ignored.

### `ip_settings` (business switches, kept in the database)

Business rules that change without a deploy live in the `ip_settings` table (key / value) and are cached in memory (`config/settings.js`). Examples:
- `client_sync_enabled`
- `api_auth_required`
- `family_booking_max_members`
- `cancel_*` and `reschedule_*` rules
- `technician_reminder_*`
- `technician_offline_timeout_sec`
- `branch_lookup_days`

The full list is in the [data dictionary](docs/database/data-dictionary.md#ip_settings).

## Database migrations

- Migrations are plain `.sql` files in [server/migrations/](server/migrations/).
- **They are not run automatically.** Someone runs each one by hand (phpMyAdmin or the `mysql` CLI), first on a test database and then on production.
- Most use `ADD COLUMN IF NOT EXISTS` / `CREATE TABLE IF NOT EXISTS`, so running one twice is harmless.
- New code is written to keep working (in a reduced way) when its migration has not run yet. A missing column is caught (`ER_BAD_FIELD_ERROR`) and the feature is skipped. **A missing table usually is not:** for example, `/api/technicians/:id/slots` returns 500 until `add_technician_slot_branches.sql` has run.
- When you add a migration, note it in the PR description so whoever deploys runs it **before** uploading the code.

## Deployment (current process)

The server runs on a VPS under `~/public_html/<domain>/server`, started with `nohup node server.js` (output in `~/server.out`). Deploys are manual:

1. Run any new migrations on the live database.
2. Upload the changed server files.
3. Restart the Node process. Nothing restarts it automatically, so check `GET /health` afterwards.
4. For app changes, build and release a new APK / IPA. The server must keep working with older app versions already on customers' phones. For example, `api_auth_required` stays `false` until every app version sends a token.

Logs on the server: `server/logs/*.log` (`dispatch.log`, `collection.log`, `client_sync.log`, `otp.log`, branch lookup…). Some of these are also written to `ip_*_logs` tables, which are purged after 90 days.

## Working on the code

- **Branches:** each developer works on their own branch and merges into `main` (the branch that is deployed). Pull `main` before you start, and merge it again before you push.
- **Commits:** Conventional Commits, for example `feat: …`, `fix: …`, `chore: …`.
- **Never commit:**
  - `server/.env` or any secret value;
  - `firebase-service-account.json`, `google-services.json`;
  - `server/logs/`, `server/uploads/`;
  - load-test env files;
  - zip archives;
  - local changes to `client/lib/constants/app_constants.dart` that point the app at a test server.
- **Tests:** add or update Jest tests for any server change, and run `npm test` before pushing.

## Team

| Area | Owner |
|---|---|
| Server: dispatch, technician flows | _to fill in_ |
| Customer app flows | _to fill in_ |
| Chatbot and voice | _to fill in_ |
| VPS and deployments | _to fill in_ |
| ASMX (lab system) contact | _to fill in_ |

*(Keep this table current. It is the first place a new joiner looks for who to ask.)*
