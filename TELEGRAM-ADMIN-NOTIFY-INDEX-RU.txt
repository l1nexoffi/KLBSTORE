import { getSupabasePublishableKey, getSupabaseSecretKey } from "../_shared/keys.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
    } else {
      return json({ error: "Unsupported notification kind" }, 400);
    }

    const { data: admins, error: adminsError } = await admin.from("profiles")
      .select("id,username").eq("role", "admin").eq("status", "active");
    if (adminsError) throw adminsError;
    const adminIds = (admins || []).map((a) => a.id);
    if (!adminIds.length) return json({ sent: 0, reason: "No active admin profiles found" });
    const { data: linked, error: linkedError } = await admin.from("klb_telegram_accounts")
      .select("user_id,telegram_chat_id").in("user_id", adminIds).not("telegram_chat_id", "is", null);
    if (linkedError) throw linkedError;
    if (!linked?.length) return json({ sent: 0, reason: "No active admin has linked a Telegram chat. Link Telegram in the admin profile and press Start in the bot." });

    const text = [`🔔 ${title}`, "", ...lines, "", "Откройте нужный раздел админ-панели для обработки."].join("\n");
    const panelUrl = adminSectionUrl(siteUrl, view);
    const results = await Promise.allSettled(linked.map(async (account) => {
      const response = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: account.telegram_chat_id,
          text,
          disable_web_page_preview: true,
          reply_markup: { inline_keyboard: [[{ text: "Открыть админ-панель", url: panelUrl }]] },
        }),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.ok) throw new Error(result.description || `Telegram HTTP ${response.status}`);
      return account.user_id;
    }));
    const sent = results.filter((r) => r.status === "fulfilled").length;
    const failed = results.filter((r) => r.status === "rejected").map((r) => r.reason instanceof Error ? r.reason.message : String(r.reason));
    if (failed.length) console.error("Some admin Telegram notifications failed", failed);
    return json({ sent, total_admin_chats: linked.length, failed, kind, record_id: recordId });
  } catch (error) {
    console.error("telegram-admin-notify error", error);
    return json({ error: error instanceof Error ? error.message : "Admin notification failed" }, 500);
  }
});
