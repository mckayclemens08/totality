# Instant Gmail sync: what the owner sets up (issue 164)

The code is in PRs #190 (rules and entitlement), #191 (push sender), #193 (Pub/Sub endpoint) and the app PR.
Nothing turns on until every step below is done. No step puts a key, password or card in the repo.

## 1. Check the paid team ID first, before switching anything

1. Open https://developer.apple.com/account and sign in.
2. Click **Membership details**.
3. Note the **Team ID**.

- **If it's `27QNV2A3Z7`** (the same as today's Personal Team), go on to step 2.
- **If it's different, stop and tell Claude before switching.** On iPhone, the app's Keychain items are tied to
  the team ID. A new team ID means the installed app may not read its current keys, and Messages keys live only
  on the phone. Don't delete the installed app. See the "never delete an app first" note.

## 2. Switch Xcode to the paid team

1. Quit Xcode if it's open, then open `App/Totality.xcodeproj`.
2. In the left sidebar, click the blue **Totality** project, then the **Totality** target under TARGETS.
3. Open the **Signing & Capabilities** tab, with **All** selected at the top.
4. In **Team**, choose **McKay Clemens**, the one *without* "(Personal Team)".
5. Check that **Push Notifications** appears in the capability list, from `Totality-iOS.entitlements`. If Xcode
   offers **Fix Issue** or asks to register the app ID `app.totality.ios`, click it. Don't change the bundle ID.
6. Tell Claude the Team ID, so `DEVELOPMENT_TEAM` in the project gets updated in a PR.

## 3. Make the Apple push key (APNs)

1. Go to https://developer.apple.com/account/resources/authkeys/list.
2. Click **+**.
3. Name it `Totality push` and tick **Apple Push Notifications service (APNs)**.
4. Click **Configure**, choose **Sandbox & Production**, then **Save**.
5. Click **Continue**, then **Register**.
6. Click **Download**. Apple lets you download it only once. The file is `AuthKey_<KEYID>.p8`.
7. Note the **Key ID** shown on the page.
8. Keep a copy in your password manager. Never put it in the repo, email or chat.

## 4. Put the key on the server

On the Mac, in Terminal:

```bash
ssh -i ~/.ssh/totality_server ubuntu@158.101.16.156 'mkdir -p ~/totality/secrets/push ~/totality/push-data && chmod 700 ~/totality/secrets/push'
```

```bash
scp -i ~/.ssh/totality_server ~/Downloads/AuthKey_*.p8 ubuntu@158.101.16.156:totality/secrets/push/apns.p8
```

```bash
ssh -i ~/.ssh/totality_server ubuntu@158.101.16.156 'sudo chown -R 1000:1000 ~/totality/secrets/push ~/totality/push-data && chmod 400 ~/totality/secrets/push/apns.p8'
```

Then sign in with `ssh -i ~/.ssh/totality_server ubuntu@158.101.16.156` and edit the env file with
`nano ~/totality/.env`. Add these lines with your own values:

```
APNS_KEY_ID=<the Key ID from step 3>
APNS_TEAM_ID=<the Team ID from step 1>
PUSH_ADDRESS_KEY=<paste the output of: openssl rand -base64 48>
PUBSUB_SENDER=<the service account email from step 5>
```

Then delete the `.p8` from Downloads. The copy in your password manager is the backup.

## 5. Google Cloud Pub/Sub

> **Cost flag, the owner's decision.** Pub/Sub's free tier covers this use many times over, so the expected
> cost is $0. Google may still ask for a billing account (a card on file) to turn the API on. If it asks,
> stop: that's a decision under the cost rule, not a setup step.

All of this is in the existing project `turnkey-point-514103-d9`, at https://console.cloud.google.com.

1. **Turn on the API.** Go to APIs & Services → Library and search **Cloud Pub/Sub API**. Click **Enable**.
2. **Make the topic.**
   1. Go to Pub/Sub → Topics → **Create topic**.
   2. Set Topic ID to `gmail-push` and untick **Add a default subscription**.
   3. Click **Create**.
3. **Let Gmail publish to it.**
   1. Open the topic and go to **Permissions** (on the right, or Show info panel) → **Add principal**.
   2. Add `gmail-api-push@system.gserviceaccount.com` with role **Pub/Sub Publisher**.
   3. Click **Save**.
4. **Make the push sender's account.**
   1. Go to IAM & Admin → Service Accounts → **Create service account**.
   2. Name it `gmail-push-sender` and give it no roles.
   3. Click **Done**.
   4. Copy its email. That's `PUBSUB_SENDER` in step 4.
5. **Make the subscription.** Go to Pub/Sub → Subscriptions → **Create subscription** and set:
   - Subscription ID: `gmail-push-to-totality`
   - Topic: `gmail-push`
   - Delivery type: **Push**
   - Endpoint URL: `https://usetotality.com/push/gmail/notify`
   - Tick **Enable authentication** and choose the service account `gmail-push-sender`.
   - Audience: `https://usetotality.com/push/gmail/notify`
   - Message retention: the shortest allowed (10 minutes).
   - Expiration: **Never expire**.

   Click **Create**. If Google says Pub/Sub's service agent can't make tokens, grant
   `service-<project number>@gcp-sa-pubsub.iam.gserviceaccount.com` the **Service Account Token Creator** role
   on `gmail-push-sender`.
6. Tell Claude the topic name: `projects/turnkey-point-514103-d9/topics/gmail-push`. It goes into
   `App/Backend.xcconfig` (`TOTALITY_GMAIL_PUSH_TOPIC`). It's a name, not a secret.

## 6. Deploy and try it

Once the PRs are merged, ask Claude to deploy. That means copying `server/` to the box and running
`docker compose up -d push cloudflared`. Then:

1. Install the app on the phone.
2. Open Mail. It asks once to allow notifications: allow it.
3. With the app in the background and the phone unlocked, send yourself a Gmail.

The settings are in Mail → Outside Accounts → **Instant Gmail**, and **Notifications show** picks sender and
subject or "New mail" only.

## Known limits

- **Locked phone.** iPhone keeps Totality's keys closed while it's locked, so a push that arrives then can't
  fetch. The mail comes in when the phone is unlocked. Changing that is a security decision, so it's left open.
- **Background pushes.** iOS rations them and doesn't wake an app you swiped away. A Notification Service
  Extension would make delivery dependable, and it's a follow-up.
- **iCloud mail.** It keeps its current schedule, because Apple offers no push for outside apps.
