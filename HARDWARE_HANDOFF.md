# Tin Can — HANDOFF dla fazy HARDWARE (Faza 3 / „żelazo")

> Ten plik to samowystarczalny punkt startu dla **osobnego czatu zajmującego się HARDWARE** (nie softem).
> Cały software (apka + backend) już działa — urządzenie ma się **podpiąć pod istniejący backend Supabase** i wyświetlać rysunki.

## 1. Czym jest Tin Can
Intymny komunikator-rysownik dla dwojga/bliskich. Rysujesz obrazek (sztandarowo: krzywy kot materializujący się kreska po kresce) i wysyłasz do drugiej osoby — u niej pojawia się na płótnie. Metafora: dwie puszki połączone sznurkiem.
Zasada przewodnia: „magia najpierw, hydraulika na końcu".

**Fazy:** P1 canvas lokalnie ✅ · P2 software end-to-end ✅ (Flutter web+Android: konta, znajomi/zaproszenia, grupy, powiadomienia push) · **P3 = TA FAZA: fizyczne urządzenie**, które „budzi się samo", gdy przyjdzie rysunek, i go wyświetla. Firmware planowany **MicroPython** (atut: właściciel jest mocny w Pythonie).

## 2. Cel fazy hardware
Fizyczne urządzenie, które:
- łączy się z internetem (WiFi),
- **nasłuchuje na nowe rysunki** adresowane do swojego użytkownika,
- gdy przyjdzie rysunek → **sygnalizuje** (LED/dźwięk/„budzi się") i **wyświetla** go (najlepiej materializując kreska po kresce, jak apka).

**Decyzje otwarte (do ustalenia w hardware-czacie):** płytka (ESP32 / Raspberry Pi Pico W / RPi?), wyświetlacz (e-ink? kolorowy LCD/TFT? matryca LED?), zasilanie/bateria, obudowa („puszka"). Właściciel poda, co ma / co kupić.

## 3. Backend do integracji — Supabase (KLUCZOWE)
Urządzenie czyta z tej samej bazy co apka.
- **URL:** `https://safvbfwtqjlgcegnyckp.supabase.co`
- **Anon key (publiczny, do client-side):**
  `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNhZnZiZnd0cWpsZ2NlZ255Y2twIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI2NTg3NjAsImV4cCI6MjA5ODIzNDc2MH0.06giB9KYiw9BI1Q0FYijhn3-QO5PdcV9pZ0mi8ejS00`
- Projekt Firebase (push mobilny) `tin-can-d1502` — dla urządzenia NIEistotny (urządzenie jest zasilane, może trzymać socket/polling).

### Tabela `drawings`
`id uuid · created_at timestamptz · sender text (=user_id nadawcy) · recipient text (=user_id odbiorcy) · strokes jsonb · group_id uuid null`
- RLS włączone: authenticated widzi wiersze gdzie `sender = auth.uid()` LUB `recipient = auth.uid()`. Insert tylko `sender = auth.uid()` (+ istnieje connection). **Więc urządzenie musi mieć JWT użytkownika** (patrz „Tożsamość").
- W publikacji `supabase_realtime` (można subskrybować INSERT-y realtime).

### Format `strokes` (jak renderować rysunek)
`strokes` = lista kresek. Każda kreska:
```json
{ "color": "RRGGBB", "width": 4.0, "points": [x0,y0, x1,y1, x2,y2, ...] }
```
- `color` = hex RRGGBB (np. `"000000"` czarny, `"ff6b6b"` koral). Gumka = biały `"ffffff"`.
- `points` = spłaszczona lista współrzędnych (piksele płótna NADAWCY). Rysuj linię łamaną łączącą kolejne (x,y), grubością `width`, kolorem `color`, zaokrąglone końce.
- Materializacja (opcjonalnie, jak apka): odsłaniaj punkty po kolei przez X sekund → efekt „rysuje się sam".
- Uwaga: współrzędne są w pikselach ekranu nadawcy (różne rozmiary) → na urządzeniu policz bounding box wszystkich punktów i przeskaluj do rozdzielczości wyświetlacza (z marginesem).

## 4. Jak nasłuchiwać (opcje, od najprostszej)
**a) Polling REST (REKOMENDACJA na start — łatwe w MicroPython `urequests`):**
```
GET https://safvbfwtqjlgcegnyckp.supabase.co/rest/v1/drawings
    ?recipient=eq.<UID>&order=created_at.desc&limit=1
Headers: apikey: <ANON>   Authorization: Bearer <JWT_uzytkownika>
```
Co np. 3–5 s; jeśli `id`/`created_at` nowszy niż ostatnio widziany → nowy rysunek → pobierz `strokes` i wyświetl.

**b) Supabase Realtime (WebSocket, mniejsze opóźnienie, trudniejsze na MicroPython):** subskrypcja `postgres_changes` INSERT na `public.drawings` filtr `recipient=eq.<UID>` (protokół Phoenix Supabase; wymaga JWT). Do rozważenia po działającym pollingu.

## 5. Tożsamość urządzenia
Urządzenie reprezentuje JEDNO konto (np. „puszka Ani"). Najprościej na prototyp:
- Zaloguj urządzenie jako to konto (email+hasło zaszyte w firmware):
  `POST /auth/v1/token?grant_type=password` z body `{"email":..,"password":..}` + header `apikey: <ANON>` → dostaniesz `access_token` (JWT) i `refresh_token`. Używaj access_token jako Bearer; odświeżaj gdy wygaśnie (grant_type=refresh_token).
- `UID` (do filtra recipient) = `sub` z JWT albo z odpowiedzi logowania (`user.id`).
- Bezpieczniej docelowo: osobny „device token"/RPC — ale na prototyp email+hasło wystarcza.

## 6. Stan software / repo
- Repo prywatne: `github.com/theMike07/tin-can` (commituj jako **theMike07**, NIE konto PW `MichalKosmatkaKos`).
- Publiczne APK: `github.com/theMike07/tin-can-app` (v1.1.0 live; nowe funkcje: znajomi/grupy są na `main`, niewydane).
- Apka Flutter: `C:\src\tin_can` (web + Android). App ID `pl.themike07.tincan`.
- Pełen stan softu jest w pamięci Claude Code: `C:\Users\micha\.claude\projects\C--src\memory\` (`tin-can-project.md` itd.).

## 7. Sugerowane pierwsze kroki w hardware-czacie
1. Ustalić płytkę + wyświetlacz (właściciel poda co ma).
2. „Hello listen": MicroPython + WiFi → **polling REST** → wykryj nowy rysunek dla `UID` → wypisz surowe `strokes` na konsoli.
3. Render `strokes` na wyświetlaczu (skalowanie do rozdzielczości, linie łamane).
4. Sygnalizacja „przyszło" (LED/buzzer) + opcjonalna materializacja.
5. Obudowa „puszka".

---
**TL;DR dla żelaza:** backend (Supabase) i format rysunku już istnieją i działają. Urządzenie = MicroPython + WiFi, loguje się jako konto użytkownika, pollinguje `drawings` po `recipient=<UID>`, i renderuje `strokes` (color RRGGBB, points spłaszczone) na wyświetlaczu, sygnalizując „przyszło".
