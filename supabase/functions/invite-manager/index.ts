import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("APP_ORIGIN") ?? "",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return json({ error: "authentication_required" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const appUrl = Deno.env.get("APP_URL");

  const appOrigin = Deno.env.get("APP_ORIGIN");
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !appUrl || !appOrigin) {
    return json({ error: "server_configuration_incomplete" }, 500);
  }
  if (req.headers.get("Origin") !== appOrigin) {
    return json({ error: "origin_not_allowed" }, 403);
  }

  const token = authHeader.slice("Bearer ".length);
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser(token);
  const caller = userData.user;

  if (userError || !caller || !caller.email_confirmed_at) {
    return json({ error: "verified_authentication_required" }, 401);
  }

  let body: { email?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const email = String(body.email ?? "").trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return json({ error: "valid_email_required" }, 400);
  }
  if (email === "mahdi.alaei64@gmail.com") {
    return json({ error: "owner_account_cannot_be_invited_as_manager" }, 400);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: roleRow, error: roleError } = await adminClient
    .from("app_user_roles")
    .select("role")
    .eq("user_id", caller.id)
    .maybeSingle();

  if (roleError) return json({ error: "role_check_failed" }, 500);
  if (!roleRow || !["owner", "store_manager"].includes(roleRow.role)) {
    return json({ error: "not_authorized_to_invite_managers" }, 403);
  }

  const { data: existingInvite, error: existingError } = await adminClient
    .from("manager_invites")
    .select("id")
    .eq("email", email)
    .is("accepted_at", null)
    .is("revoked_at", null)
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();

  if (existingError) return json({ error: "invite_lookup_failed" }, 500);
  if (existingInvite) return json({ error: "invite_already_pending" }, 409);

  const { data: inviteRow, error: insertError } = await adminClient
    .from("manager_invites")
    .insert({ email, invited_by: caller.id })
    .select("id")
    .single();

  if (insertError || !inviteRow) return json({ error: "invite_record_failed" }, 500);

  const { error: authInviteError } = await adminClient.auth.admin.inviteUserByEmail(email, {
    redirectTo: new URL("/admin.html?accept-manager-invite=1", appUrl).toString(),
  });

  if (authInviteError) {
    await adminClient.from("manager_invites").delete().eq("id", inviteRow.id);
    return json({ error: "auth_invitation_failed", detail: authInviteError.message }, 400);
  }

  const { error: auditError } = await adminClient.from("audit_log").insert({
    admin_email: caller.email?.toLowerCase() ?? "",
    action: "invite_manager",
    new_data: { email, invite_id: inviteRow.id },
  });
  if (auditError) return json({ error: "invite_sent_audit_write_failed" }, 500);

  return json({ ok: true, message: "manager_invitation_sent" }, 200);
});
