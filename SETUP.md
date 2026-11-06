# Proview Bookings – going live with the cloud

Proview Bookings already works on its own, with data saved in each device's browser. Connect it to the cloud and you get:

- **One shared, live list** on every iPad, phone and computer, with staff logins.
- **A public booking page** for guests: bookings, group enquiries, the waitlist and a sign-up form – `https://bookings.proviewcrm.co.uk/book/`.
- **A live queue page** where guests see their place in line and get a text when their table is ready.
- **Emails and texts:** confirmations, reminders (reply 1 to confirm, 5 to cancel), cancellations, birthday offers, two-way chat and the nightly summary.
- **Deposits** taken with Stripe on the booking page.

You need three accounts in your company's name. Claude can't create these or handle their keys for you.

| What | Service | Cost (roughly) | Needed for |
|---|---|---|---|
| Database and logins | [Supabase](https://supabase.com) | Free tier; Pro £20/month | Everything below |
| Email | [Resend](https://resend.com) | Free up to 3,000 emails/month | Confirmations, offers |
| Text messages | [Twilio](https://twilio.com) | Around 4p per UK text, plus a number at around £1/month | Reminders, queue texts, chat |
| Deposits | [Stripe](https://stripe.com) | 1.5% + 20p per UK card | Deposits and no-show fees |

---

## 1. Supabase (about 10 minutes)

1. Sign up at supabase.com and create a project. Choose region **London (eu-west-2)** and keep the database password somewhere safe.
2. Open **SQL Editor → New query**.
3. Open [`supabase/schema.sql`](supabase/schema.sql), copy all of it and paste it in.
4. At the bottom of the script, change `you@yourcompany.co.uk` to your email. Leave `proview-kitchen` as the venue ID, or choose your own (lower case and dashes, e.g. `brags-and-brams`).
5. Press **Run**.
6. Go to **Authentication → Providers → Email** and decide whether staff must confirm their email. Leaving it on is safer.
7. Go to **Project Settings → API** and copy the **Project URL** and the **anon public** key. These two are safe to put in a website; the database rules protect your data.

## 2. Connect the app

**Option A (recommended) – everyone at once.** Put the values in `cloud.json` in this repository:

```json
{ "url": "https://YOURPROJECT.supabase.co", "anonKey": "eyJ...", "venue": "proview-kitchen" }
```

Commit it. Every device, and the public booking page, picks it up automatically.

**Option B – one device to try it.** Open the app, go to **Settings → Integrations → Cloud sync**, paste the URL, key and venue ID, then press **Connect**.

Then:

1. Open https://bookings.proviewcrm.co.uk and choose **First time? Create your account**, using the email from step 1.4.
2. The first time you connect, choose **Upload what's on this device** to keep the sample data, or **Start fresh** to keep only your settings, tables and menus.
3. The dot next to the search icon turns green when everything is saved to the cloud.

**Adding staff:** go to **Settings → Account → Team members**, enter their name and email, then press **Add member**. They then open the site and choose **Create your account** with that email.

## 3. Server functions (emails, texts, deposits)

Install the [Supabase CLI](https://supabase.com/docs/guides/cli), then run these from this folder:

```bash
supabase login
supabase link --project-ref YOURPROJECTREF
supabase functions deploy bk-notify
supabase functions deploy bk-sms-in --no-verify-jwt
supabase functions deploy bk-deposit --no-verify-jwt
supabase functions deploy bk-stripe-webhook --no-verify-jwt
```

Add the keys under **Project Settings → Edge Functions → Secrets**. Only add the ones for the services you use.

| Secret | Where to find it |
|---|---|
| `BK_RESEND_API_KEY` | Resend → API Keys |
| `BK_FROM_EMAIL` | An address on a domain you've verified in Resend, e.g. `bookings@proviewcrm.co.uk` |
| `BK_TWILIO_ACCOUNT_SID`, `BK_TWILIO_AUTH_TOKEN` | Twilio Console home page |
| `BK_TWILIO_FROM` | Your Twilio UK mobile number, e.g. `+447...` |
| `BK_STRIPE_SECRET_KEY` | Stripe → Developers → API keys (start with the `sk_test_` key) |
| `BK_STRIPE_WEBHOOK_SECRET` | From the webhook you create in Stripe, below |

**Twilio replies:** in Twilio → Phone Numbers → your number → *A message comes in*, set the webhook to:
`https://YOURPROJECT.supabase.co/functions/v1/bk-sms-in?venue=proview-kitchen`

**Stripe deposits:**
1. In Stripe → Developers → Webhooks, add the endpoint `https://YOURPROJECT.supabase.co/functions/v1/bk-stripe-webhook` for the event `checkout.session.completed`.
2. Copy its signing secret into `BK_STRIPE_WEBHOOK_SECRET`.
3. In the app, turn on **Settings → Integrations → Stripe deposits**.
4. Choose **Take a deposit per guest** under **Settings → Bookings → Policies**.

**Email domain:** in Resend → Domains, add `proviewcrm.co.uk`. Then add the DNS records it shows in GoDaddy (DNS → Add New Record), the same way as the `bookings` record.

## 4. Check it works

1. Make a booking on `https://bookings.proviewcrm.co.uk/book/`. It should appear on every signed-in device within a few seconds, and the guest gets an email.
2. Join the queue from your phone, then press **Notify** on the iPad. The phone should get a text and its queue page should say the table is ready.
3. Reply `1` to a reminder text. The booking should show as Confirmed.

## How the data is protected

- Staff can only read and change their own venue's data (row-level security in `schema.sql`).
- The public page only sees a cut-down copy: times, table sizes and settings, with no names, emails or phone numbers.
- Guests can only *send requests* (bookings, enquiries, queue joins, cancellations). The staff app checks each one before it becomes a booking.
- Each venue accepts at most 20 guest requests a minute.
- Texts and emails can only be sent by signed-in staff. Twilio and Stripe callbacks are checked with their signatures.
