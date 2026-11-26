import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Inlined from _shared/keys.ts so the function deploys from the dashboard editor too.
function keyFromEnvironmentMap(name: string): string | null {
  const raw = Deno.env.get(name);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    if (typeof parsed.default === "string" && parsed.default.length > 0) return parsed.default;
    const first = Object.values(parsed).find(
      (value) => typeof value === "string" && value.length > 0,
    );
    return typeof first === "string" ? first : null;
  } catch {
    return null;
  }
}

function getSupabaseSecretKey(): string {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || keyFromEnvironmentMap("SUPABASE_SECRET_KEYS");
  if (!key) throw new Error("Supabase secret/service-role key is not configured in Edge Function environment");
  return key;
}

function getSupabasePublishableKey(): string {
  const key = Deno.env.get("SUPABASE_ANON_KEY") || keyFromEnvironmentMap("SUPABASE_PUBLISHABLE_KEYS");
  if (!key) throw new Error("Supabase publishable/anon key is not configured in Edge Function environment");
  return key;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, "Content-Type": "application/json" },
});
const baseUrl = (raw: string) => raw.endsWith("/") ? raw : `${raw}/`;
function adminSectionUrl(siteUrl: string, view: string) {
  const url = new URL("admin.html", baseUrl(siteUrl));
  url.searchParams.set("view", view);
  return url.toString();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const anon = getSupabasePublishableKey();
    const service = getSupabaseSecretKey();
    const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
    const siteUrl = Deno.env.get("SITE_URL");
    if (!url || !botToken || !siteUrl) return json({ error: "Set TELEGRAM_BOT_TOKEN and SITE_URL in Edge Function Secrets" }, 503);

    const authorization = req.headers.get("Authorization") || "";
    if (!authorization.startsWith("Bearer ")) return json({ error: "Authentication required" }, 401);
    const userClient = createClient(url, anon, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) return json({ error: "Invalid session" }, 401);

    const body = await req.json();
    const kind = String(body?.kind || "");
    const recordId = String(body?.record_id || "");
    if (!recordId) return json({ error: "Missing record_id" }, 400);

    const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
    const actorId = authData.user.id;
    let view = "overview";
    let title = "Новое событие KLB STORE";
    let lines: string[] = [];
    let supportMode = false;
    let ticketId: string | null = null;

    if (kind === "deposit_created" || kind === "deposit_checking") {
      const { data: row, error } = await admin.from("deposit_requests")
        .select("id,user_id,amount,comment_code,status,created_at").eq("id", recordId).single();
      if (error) throw error;
      if (row.user_id !== actorId) return json({ error: "Deposit request does not belong to current user" }, 403);
      view = "deposits";
      title = kind === "deposit_checking" ? "Пользователь отметил пополнение как оплаченное" : "Новая заявка на пополнение";
      const { data: profile } = await admin.from("profiles").select("username").eq("id", row.user_id).maybeSingle();
      lines = [`Пользователь: ${profile?.username || "—"}`, `Сумма: ${Number(row.amount).toLocaleString("ru-RU")} ₽`, `Код перевода: ${row.comment_code}`, `Статус: ${row.status === "checking" ? "Проверка оплаты" : "Ожидает оплаты"}`];
    } else if (kind === "seller_application") {
      const { data: row, error } = await admin.from("seller_applications")
        .select("id,user_id,username,age,telegram,description,benefits,status,created_at").eq("id", recordId).single();
      if (error) throw error;
      if (row.user_id !== actorId) return json({ error: "Seller application does not belong to current user" }, 403);
      const { data: profile } = await admin.from("profiles").select("username").eq("id", row.user_id).maybeSingle();
      view = "sellers";
      title = "Новая заявка продавца";
      lines = [`Пользователь: ${profile?.username || row.username || "—"}`, `Telegram: ${row.telegram || "—"}`, `Возраст: ${row.age || "—"}`, `Описание: ${String(row.description || "").slice(0, 500)}`];
    } else if (kind === "listing") {
      const { data: row, error } = await admin.from("seller_listings")
        .select("id,seller_id,title,price,stock,catalog_category,catalog_subcategory,status,created_at").eq("id", recordId).single();
      if (error) throw error;
      if (row.seller_id !== actorId) return json({ error: "Listing does not belong to current user" }, 403);
      const { data: profile } = await admin.from("profiles").select("username,role").eq("id", row.seller_id).maybeSingle();
      view = "moderation";
      title = "Новое объявление ожидает проверки";
      lines = [`Продавец: ${profile?.role === "admin" ? "KLB STORE" : profile?.username || "—"}`, `Товар: ${row.title}`, `Цена: ${Number(row.price).toLocaleString("ru-RU")} ₽`, `Количество: ${row.stock}`, `Категория: ${row.catalog_category || "—"} / ${row.catalog_subcategory || "—"}`];
    } else if (kind === "account_report") {
      const { data: row, error } = await admin.from("marketplace_reports")
        .select("id,reporter_id,target_user_id,description,created_at").eq("id", recordId).single();
      if (error) throw error;
      if (row.reporter_id !== actorId) return json({ error: "Report does not belong to current user" }, 403);
      const [{ data: reporter }, { data: target }] = await Promise.all([
        admin.from("profiles").select("username").eq("id", row.reporter_id).maybeSingle(),
        admin.from("profiles").select("username").eq("id", row.target_user_id).maybeSingle(),
      ]);
      view = "reports";
      title = "Новая жалоба на пользователя";
      lines = [`Кто пожаловался: ${reporter?.username || "—"}`, `На кого: ${target?.username || "—"}`, `Описание: ${String(row.description || "").slice(0, 700)}`];
    } else if (kind === "dispute") {
      const { data: row, error } = await admin.from("marketplace_disputes")
        .select("id,buyer_id,seller_id,order_id,reason,created_at").eq("id", recordId).single();
      if (error) throw error;
      if (row.buyer_id !== actorId && row.seller_id !== actorId) return json({ error: "Dispute does not involve current user" }, 403);
      const [{ data: order }, { data: buyer }, { data: seller }] = await Promise.all([
        admin.from("marketplace_orders").select("listing_title,gross_amount").eq("id", row.order_id).maybeSingle(),
        admin.from("profiles").select("username").eq("id", row.buyer_id).maybeSingle(),
        admin.from("profiles").select("username").eq("id", row.seller_id).maybeSingle(),
      ]);
      view = "reports";
      title = "Открыт спор по заказу";
      lines = [`Товар: ${order?.listing_title || "—"}`, `Сумма: ${Number(order?.gross_amount || 0).toLocaleString("ru-RU")} ₽`, `Покупатель: ${buyer?.username || "—"}`, `Продавец: ${seller?.username || "—"}`, `Причина: ${String(row.reason || "").slice(0, 700)}`];
    } else if (kind === "support_ticket" || kind === "support_message") {
      // Обращение в поддержку: уведомление получают администраторы и модераторы 1/2 уровня.
      let messageText = "";
      ticketId = recordId;
      if (kind === "support_message") {
        const { data: m, error: mErr } = await admin.from("klb_support_messages")
          .select("id,ticket_id,sender_id,is_staff,body").eq("id", recordId).single();
        if (mErr) throw mErr;
        if (m.sender_id !== actorId || m.is_staff) return json({ error: "Support message does not belong to current user" }, 403);
        ticketId = m.ticket_id;
        messageText = m.body;
      }
      const { data: t, error: tErr } = await admin.from("klb_support_tickets")
        .select("id,user_id,subject,created_at").eq("id", ticketId).single();
      if (tErr) throw tErr;
      if (t.user_id !== actorId) return json({ error: "Support request does not belong to current user" }, 403);
      if (kind === "support_ticket") {
        const { data: first } = await admin.from("klb_support_messages")
          .select("body").eq("ticket_id", t.id).order("created_at", { ascending: true }).limit(1).maybeSingle();
        messageText = first?.body || "";
      }
      const { data: profile } = await admin.from("profiles").select("username").eq("id", t.user_id).maybeSingle();
      supportMode = true;
      view = "support";
      title = kind === "support_ticket" ? "Новое обращение в поддержку" : "Новое сообщение в поддержке";
      lines = [`Пользователь: ${profile?.username || "—"}`, `Тема: ${String(t.subject).slice(0, 120)}`, `Сообщение: ${String(messageText).slice(0, 600)}`];
    } else {
      return json({ error: "Unsupported notification kind" }, 400);
    }

    // Обращения в поддержку идут и модераторам (1 и 2 уровня); остальные события только администраторам.
    let recipientsQuery = admin.from("profiles").select("id,username").eq("status", "active");
    recipientsQuery = supportMode
      ? recipientsQuery.or("role.eq.admin,and(moderator_level.gte.1,moderator_level.lte.2)")
      : recipientsQuery.eq("role", "admin");
    const { data: admins, error: adminsError } = await recipientsQuery;
    if (adminsError) throw adminsError;
    const adminIds = (admins || []).map((a) => a.id).filter((id) => !supportMode || id !== actorId);
    if (!adminIds.length) return json({ sent: 0, reason: "No active admin or moderator profiles found" });
    const { data: linked, error: linkedError } = await admin.from("klb_telegram_accounts")
      .select("user_id,telegram_chat_id,telegram_user_id").in("user_id", adminIds);
    if (linkedError) throw linkedError;
    const targets = (linked || []).map((a) => ({ user_id: a.user_id, chat_id: a.telegram_chat_id || a.telegram_user_id })).filter((a) => a.chat_id);
    if (!targets.length) return json({ sent: 0, reason: "No active admin has linked a Telegram chat. Link Telegram in the admin profile and press Start in the bot." });

    const text = [`🔔 ${title}`, "", ...lines, "", supportMode ? "Ответьте пользователю в админ-панели, раздел «Поддержка»." : "Откройте нужный раздел админ-панели для обработки."].join("\n");
    const panelUrl = new URL(adminSectionUrl(siteUrl, view));
    if (supportMode && ticketId) panelUrl.searchParams.set("ticket", ticketId);
    const results = await Promise.allSettled(targets.map(async (account) => {
      const response = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: account.chat_id,
          text,
          disable_web_page_preview: true,
          reply_markup: { inline_keyboard: [[{ text: supportMode ? "Открыть обращение" : "Открыть админ-панель", url: panelUrl.toString() }]] },
        }),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.ok) throw new Error(result.description || `Telegram HTTP ${response.status}`);
      return account.user_id;
    }));
    const sent = results.filter((r) => r.status === "fulfilled").length;
    const failed = results.filter((r) => r.status === "rejected").map((r) => r.reason instanceof Error ? r.reason.message : String(r.reason));
    if (failed.length) console.error("Some admin Telegram notifications failed", failed);
    return json({ sent, total_admin_chats: targets.length, failed, kind, record_id: recordId });
  } catch (error) {
    console.error("telegram-admin-notify error", error);
    return json({ error: (error as { message?: string })?.message || String(error) }, 500);
  }
});
