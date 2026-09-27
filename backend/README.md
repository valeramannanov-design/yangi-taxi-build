# Yangi Taxi backend v0.2

The Android app never stores the TaxiMaster CommonAPI secret. The app talks to this backend; the backend talks to TaxiMaster 3.16.

## Test in demo mode

1. Install Node.js 20 or newer.
2. Copy `.env.example` to `.env`.
3. Keep `TM_API_MOCK=true`.
4. Run:

```
node server.mjs
```

The backend listens on port 8787. In the Yangi Taxi app open the gear icon and enter, for example:

```
http://192.168.1.254:8787
```

when the phone and the backend computer are on the same LAN.

## Connect TaxiMaster

Change `.env`:

```
TM_API_MOCK=false
TM_API_BASE_URL=https://192.168.1.254:8089/common_api/1.0
TM_API_USER_ID=5
TM_API_SECRET=YOUR_NEW_SECRET
SESSION_SECRET=LONG_RANDOM_VALUE
```

Do not commit the real secret to GitHub and do not send it in chat.

For Internet access, put this backend behind HTTPS/VPN. Do not publish TaxiMaster port 8089 directly.
