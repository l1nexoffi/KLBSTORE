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
const siteBase = (value: string) => value.endsWith("/") ? value : `${value}/`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const anon = getSupabasePublishableKey();
    const service = getSupabaseSecretKey();
    const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
    const siteUrl = Deno.env.get("SITE_URL");
    if (!url || !token || !siteUrl) return json({ error: "Set TELEGRAM_BOT_TOKEN and SITE_URL in Edge Function Secrets" }, 503);

    const authorization = req.headers.get("Authorization") || "";
    if (!authorization.startsWith("Bearer ")) return json({ error: "Authentication required" }, 401);
    const userClient = createClient(url, anon, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) return json({ error: "Invalid session" }, 401);

    const body = await req.json();
    const orderId = String(body?.order_id || "");
    if (!orderId) return json({ error: "Missing order_id" }, 400);

    const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: order, error: orderError } = await admin.from("marketplace_orders")
      .select("id,buyer_id,seller_id,listing_title,quantity,unit_price,gross_amount,created_at")
      .eq("id", orderId).single();
    if (orderError) throw orderError;
    if (order.buyer_id !== authData.user.id) return json({ error: "Order does not belong to the current buyer" }, 403);

    const [{ data: buyer, error: buyerError }, { data: sellerTelegram, error: telegramError }, { data: chat, error: chatError }] = await Promise.all([
      admin.from("profiles").select("username").eq("id", order.buyer_id).single(),
      admin.from("klb_telegram_accounts").select("telegram_chat_id,telegram_username").eq("user_id", order.seller_id).maybeSingle(),
      admin.from("marketplace_chats").select("id").eq("order_id", order.id).maybeSingle(),
    ]);
    if (buyerError) throw buyerError;
    if (telegramError) throw telegramError;
    if (chatError) throw chatError;
    if (!chat?.id) return json({ sent: false, reason: "Order chat was not found" });
    if (!sellerTelegram?.telegram_chat_id) {
      console.warn("Seller Telegram chat is missing", { seller_id: order.seller_id, order_id: order.id });
      return json({ sent: false, reason: "Seller Telegram is linked without a chat ID. Ask the seller to use Profile → Link Telegram and press Start in the bot." });
    }

    const chatUrl = new URL(siteBase(siteUrl));
    chatUrl.searchParams.set("chat", chat.id);
    const createdAt = new Date(order.created_at).toLocaleString("ru-RU", { timeZone: "Europe/Moscow" });
    const buyerName = buyer?.username ? `@${buyer.username}` : "Покупатель";
    const message = [
      "🛍 НОВАЯ ПОКУПКА KLB STORE",
      "",
      `👤 Покупатель: ${buyerName}`,
      `📦 Товар: ${order.listing_title}`,
      `🔢 Количество: ${Number(order.quantity || 1)}`,
      `💰 Оплачено: ${Number(order.gross_amount).toLocaleString("ru-RU")} ₽`,
      `🕒 Время: ${createdAt} (МСК)`,
      "",
      "Ответьте покупателю в чате KLB STORE.",
    ].join("\n");

    const response = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: sellerTelegram.telegram_chat_id,
        text: message,
        disable_web_page_preview: true,
        reply_markup: { inline_keyboard: [[{ text: "Открыть чат с покупателем", url: chatUrl.toString() }]] },
      }),
    });
    const telegramResult = await response.json().catch(() => ({}));
    if (!response.ok || !telegramResult.ok) {
      console.error("Telegram seller message rejected", response.status, telegramResult.description || "unknown error");
      return json({ sent: false, reason: telegramResult.description || "Telegram did not accept the message" }, 502);
    }
    return json({ sent: true, order_id: order.id, seller_id: order.seller_id });
  } catch (error) {
    console.error("telegram-order-notify error", error);
    return json({ error: error instanceof Error ? error.message : "Notification failed" }, 500);
  }
});
