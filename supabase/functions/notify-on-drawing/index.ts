// Supabase Edge Function: gdy wpadnie nowy rysunek (webhook INSERT na tabeli
// drawings), wysyła powiadomienie push (FCM) na urządzenia odbiorcy.
//
// Sekrety: FCM_SERVICE_ACCOUNT = cała zawartość klucza serwisowego Firebase (JSON).
// SUPABASE_URL i SUPABASE_SERVICE_ROLE_KEY są dostępne automatycznie.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "https://esm.sh/jose@5";

async function getAccessToken(sa: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const key = await importPKCS8(
    (sa.private_key as string).replace(/\\n/g, "\n"),
    "RS256",
  );
  const jwt = await new SignJWT({
    scope: "https://www.googleapis.com/auth/firebase.messaging",
  })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const data = await res.json();
  if (!data.access_token) throw new Error("no access_token: " + JSON.stringify(data));
  return data.access_token;
}

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const record = payload.record ?? payload;
    const recipient = record?.recipient as string | undefined;
    const sender = record?.sender as string | undefined;
    if (!recipient) return new Response("no recipient", { status: 200 });

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // tokeny urządzeń odbiorcy
    const { data: tokens } = await supabase
      .from("device_tokens")
      .select("token")
      .eq("user_id", recipient);
    if (!tokens || tokens.length === 0) {
      return new Response("no tokens", { status: 200 });
    }

    // ładna nazwa nadawcy
    let from = "ktoś";
    if (sender) {
      const { data: prof } = await supabase
        .from("profiles")
        .select("username, email")
        .eq("id", sender)
        .maybeSingle();
      if (prof?.username) from = "@" + prof.username;
      else if (prof?.email) from = prof.email;
    }

    const sa = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT")!);
    const accessToken = await getAccessToken(sa);
    const url =
      `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;

    const results: number[] = [];
    for (const t of tokens) {
      const r = await fetch(url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          message: {
            token: t.token,
            notification: {
              title: "Tin Can 🥫",
              body: `${from} przysłał(a) Ci rysunek`,
            },
            android: { priority: "HIGH" },
          },
        }),
      });
      results.push(r.status);
    }
    return new Response(JSON.stringify({ sent: results }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response("error: " + String(e), { status: 500 });
  }
});
