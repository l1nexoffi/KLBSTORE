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

export function getSupabaseSecretKey(): string {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || keyFromEnvironmentMap("SUPABASE_SECRET_KEYS");
  if (!key) throw new Error("Supabase secret/service-role key is not configured in Edge Function environment");
  return key;
}

export function getSupabasePublishableKey(): string {
  const key = Deno.env.get("SUPABASE_ANON_KEY") || keyFromEnvironmentMap("SUPABASE_PUBLISHABLE_KEYS");
  if (!key) throw new Error("Supabase publishable/anon key is not configured in Edge Function environment");
  return key;
}
