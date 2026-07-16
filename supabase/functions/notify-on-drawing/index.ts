// Supabase Edge Function: powiadomienia push (FCM) dla Tin Can.
// Jedna funkcja, webhooki z trzech tabel (payload.table mówi skąd):
// - drawings INSERT           -> "przysłał(a) Ci rysunek [emotka]" do ODBIORCY
//   (emotkę wybiera nadawca na płótnie; kolumna drawings.notif_emoji)
// - drawings UPDATE           -> liked_at null->wartość: "polubił(a) Twój
//   rysunek" do NADAWCY (read_at itp. ignorowane)
// - messages INSERT           -> "💬 nowa wiadomość" do ODBIORCY
// - message_reactions INS/UPD -> "zareagował(a) X na Twoją wiadomość" do
//   AUTORA wiadomości (reakcja na własną = cisza)
//
// Payload zawiera też `data.kind` (drawing|like|message|reaction) — apka używa
// go w tle (onBackgroundMessage) m.in. do odświeżenia widżetu ekranu głównego.
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

// Ładna nazwa użytkownika: @nazwa albo e-mail.
async function displayName(supabase: any, userId: string | undefined) {
  if (!userId) return "ktoś";
  const { data: prof } = await supabase
    .from("profiles")
    .select("username, email")
    .eq("id", userId)
    .maybeSingle();
  if (prof?.username) return "@" + prof.username;
  if (prof?.email) return prof.email as string;
  return "ktoś";
}

// Wysyła push na wszystkie urządzenia użytkownika. Zwraca statusy HTTP.
async function pushToUser(
  supabase: any,
  userId: string,
  title: string,
  body: string,
  data: Record<string, string>,
): Promise<number[]> {
  const { data: tokens } = await supabase
    .from("device_tokens")
    .select("token")
    .eq("user_id", userId);
  if (!tokens || tokens.length === 0) return [];

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
          notification: { title, body },
          data,
          android: { priority: "HIGH" },
        },
      }),
    });
    results.push(r.status);
  }
  return results;
}

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const type = (payload.type as string | undefined) ?? "INSERT";
    const table = (payload.table as string | undefined) ?? "drawings";
    const record = payload.record ?? payload;
    const oldRecord = payload.old_record ?? {};
    const recipient = record?.recipient as string | undefined;
    const sender = record?.sender as string | undefined;

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // --- Wiadomość DM: powiadom odbiorcę. ---
    if (table === "messages") {
      if (type !== "INSERT" || !recipient || sender === recipient) {
        return new Response("ignore", { status: 200 });
      }
      const from = await displayName(supabase, sender);
      const text = ((record?.body as string | undefined) ?? "").trim();
      const hasImage = !!(record?.image_url as string | undefined);
      const isEnc = !!(record?.enc as string | undefined);
      // E2E: serwer nie widzi treści -> bez podglądu (tylko „nowa wiadomość").
      const preview = isEnc
        ? "🔒 Nowa wiadomość"
        : text
        ? (text.length > 90 ? text.slice(0, 90) + "…" : text)
        : (hasImage ? "📷 obrazek" : "wiadomość");
      const sent = await pushToUser(
        supabase,
        recipient,
        "Tin Can 💬",
        `${from}: ${preview}`,
        { kind: "message" },
      );
      return new Response(JSON.stringify({ message: sent }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // --- Reakcja na wiadomość: powiadom autora wiadomości. ---
    if (table === "message_reactions") {
      if (type === "DELETE") return new Response("ignore", { status: 200 });
      const messageId = record?.message_id as string | undefined;
      const reactor = record?.user_id as string | undefined;
      const emoji = (record?.emoji as string | undefined) ?? "";
      if (!messageId || !reactor) {
        return new Response("ignore", { status: 200 });
      }
      const { data: msg } = await supabase
        .from("messages")
        .select("sender, recipient")
        .eq("id", messageId)
        .maybeSingle();
      // reakcja na własną wiadomość -> cisza
      if (!msg || msg.sender === reactor) {
        return new Response("ignore", { status: 200 });
      }
      const who = await displayName(supabase, reactor);
      const sent = await pushToUser(
        supabase,
        msg.sender as string,
        "Tin Can 💬",
        `${who} zareagował(a) ${emoji} na Twoją wiadomość`,
        { kind: "reaction" },
      );
      return new Response(JSON.stringify({ reaction: sent }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (type === "UPDATE") {
      // Lajk: liked_at przeszło z null na wartość. (read_at itp. ignorujemy;
      // odlubienie — też cisza.)
      const wasLiked = oldRecord?.liked_at != null;
      const isLiked = record?.liked_at != null;
      if (wasLiked || !isLiked) return new Response("ignore", { status: 200 });
      if (!sender) return new Response("no sender", { status: 200 });
      // self-kopia w grupach: nie powiadamiaj samego siebie
      if (sender === recipient) return new Response("self", { status: 200 });

      const who = await displayName(supabase, recipient); // lajkuje odbiorca
      const sent = await pushToUser(
        supabase,
        sender,
        "Tin Can ❤️",
        `${who} polubił(a) Twój rysunek`,
        { kind: "like" },
      );
      return new Response(JSON.stringify({ like: sent }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // INSERT — nowy rysunek dla odbiorcy.
    if (!recipient) return new Response("no recipient", { status: 200 });
    // #3 grupy: nie wysyłaj push do samego siebie (self-kopia nadawcy).
    if (sender && sender === recipient) {
      return new Response("self", { status: 200 });
    }

    const from = await displayName(supabase, sender);
    // Emotka wybrana przez nadawcę na płótnie (kolumna notif_emoji).
    const emoji = ((record?.notif_emoji as string | undefined) ?? "").trim();
    const sent = await pushToUser(
      supabase,
      recipient,
      "Tin Can 🥫",
      `${from} przysłał(a) Ci rysunek${emoji ? " " + emoji : ""}`,
      { kind: "drawing" },
    );
    return new Response(JSON.stringify({ sent }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response("error: " + String(e), { status: 500 });
  }
});
