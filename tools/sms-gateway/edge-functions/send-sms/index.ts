// Supabase Auth "Send SMS" hook -> BlueBubbles gateway.
//
// Flow: Supabase Auth generates an OTP -> fires this hook (signed with SEND_SMS_HOOK_SECRET)
//       -> we verify the signature, resolve the BlueBubbles server's LIVE url from Firebase
//       (it rotates), then POST the code as a text via the BlueBubbles REST API.
//
// Deploy with verify_jwt = false (the caller is Supabase Auth, not a logged-in user;
// authenticity is proven by the Standard Webhooks signature instead).
//
// Required function secrets (supabase dashboard -> Edge Functions -> Manage secrets, or CLI):
//   SEND_SMS_HOOK_SECRET  the hook secret Supabase shows when you create the Send-SMS hook ("v1,whsec_...")
//   BB_RTDB               https://bluebubbles-thesequel-default-rtdb.firebaseio.com  (no trailing slash)
//   BB_PASSWORD           the BlueBubbles server password (guid auth key)

import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";

const HOOK_SECRET = Deno.env.get("SEND_SMS_HOOK_SECRET");
const BB_RTDB = Deno.env.get("BB_RTDB");
const BB_PASSWORD = Deno.env.get("BB_PASSWORD");

// Customize the text recipients receive. {otp} is replaced with the code.
const MESSAGE_TEMPLATE = "Your DFD verification code is {otp}";

Deno.serve(async (req) => {
  // Fail loud if the function is misconfigured — these are deploy-time mistakes, not runtime ones.
  if (!HOOK_SECRET || !BB_RTDB || !BB_PASSWORD) {
    console.error("Missing required secret(s): SEND_SMS_HOOK_SECRET / BB_RTDB / BB_PASSWORD");
    return json({ error: { http_code: 500, message: "Function not configured" } }, 500);
  }

  const rawBody = await req.text();

  // 1. Verify the request really came from Supabase Auth (reject forgeries).
  let payload: { user: { phone: string }; sms: { otp: string } };
  try {
    const wh = new Webhook(HOOK_SECRET.replace("v1,whsec_", ""));
    payload = wh.verify(rawBody, Object.fromEntries(req.headers)) as typeof payload;
  } catch (e) {
    console.error("Signature verification failed:", String(e));
    return json({ error: { http_code: 401, message: "Invalid signature" } }, 401);
  }

  const otp = payload.sms?.otp;
  const rawPhone = payload.user?.phone ?? "";
  const phone = rawPhone.startsWith("+") ? rawPhone : `+${rawPhone}`;
  if (!otp || rawPhone === "") {
    return json({ error: { http_code: 400, message: "Missing phone or otp" } }, 400);
  }

  // 2. Resolve the BlueBubbles server's current url from Firebase (it changes; Firebase tracks it).
  let serverUrl: string;
  try {
    const r = await fetch(`${BB_RTDB}/config/serverUrl.json`);
    serverUrl = (await r.json()) as string;
    if (!serverUrl || typeof serverUrl !== "string") throw new Error("serverUrl missing in Firebase");
  } catch (e) {
    console.error("Could not resolve server url from Firebase:", String(e));
    return json({ error: { http_code: 502, message: "Server URL unavailable" } }, 502);
  }

  // 3. Send the code as a text. service:"SMS" so it delivers to any phone (Android + iPhone alike).
  const message = MESSAGE_TEMPLATE.replace("{otp}", otp);
  try {
    const send = await fetch(
      `${serverUrl}/api/v1/chat/new?guid=${encodeURIComponent(BB_PASSWORD)}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          addresses: [phone],
          message,
          service: "SMS",
          method: "private-api",
        }),
      },
    );
    if (!send.ok) {
      const detail = await send.text();
      console.error(`BlueBubbles send failed (${send.status}): ${detail}`);
      return json({ error: { http_code: 502, message: "Text send failed" } }, 502);
    }
  } catch (e) {
    console.error("BlueBubbles request threw:", String(e));
    return json({ error: { http_code: 502, message: "Text send error" } }, 502);
  }

  console.log(`OTP sent to ${phone}`);
  return json({}, 200);
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
