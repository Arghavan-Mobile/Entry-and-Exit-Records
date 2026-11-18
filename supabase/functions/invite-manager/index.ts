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

  // Expired pending invitations must be revoked because the partial unique
  // index intentionally includes every non-revoked, unaccepted invitation.
  const nowIso = new Date().toISOString();
  const { error: expireError } = await adminClient
    .from("manager_invites")
    .update({ revoked_at: nowIso })
    .eq("email", email)
    .is("accepted_at", null)
    .is("revoked_at", null)
    .lte("expires_at", nowIso);
  if (expireError) return json({ error: "expired_invite_cleanup_failed" }, 500);

  const { data: existingInvite, error: existingError } = await adminClient
    .from("manager_invites")
    .select("id")
    .eq("email", email)
    .is("accepted_at", null)
    .is("revoked_at", null)
    .gt("expires_at", nowIso)
    .maybeSingle();

  if (existingError) return json({ error: "invite_lookup_failed" }, 500);
  if (existingInvite) return json({ error: "invite_already_pending" }, 409);

  // If the target already has an Auth account, create a pending invitation
  // that they can claim after signing in with that same verified email.
  let existingUser: { id: string; email?: string; email_confirmed_at?: string } | undefined;
  for (let page = 1; page <= 20; page++) {
    const { data: usersPage, error: usersError } = await adminClient.auth.admin.listUsers({
      page,
      perPage: 1000,
    });
    if (usersError) return json({ error: "auth_user_lookup_failed" }, 500);
    existingUser = usersPage.users.find(
      (user) => (user.email ?? "").toLowerCase() === email,
    );
    if (existingUser || usersPage.users.length < 1000) break;
  }

  if (existingUser && !existingUser.email_confirmed_at) {
    return json({ error: "existing_user_must_confirm_email_first" }, 409);
  }

  if (existingUser) {
    const { data: existingRole, error: existingRoleError } = await adminClient
      .from("app_user_roles")
      .select("role")
      .eq("user_id", existingUser.id)
      .maybeSingle();
    if (existingRoleError) return json({ error: "target_role_lookup_failed" }, 500);
    if (existingRole?.role === "owner") {
      return json({ error: "owner_account_cannot_be_invited_as_manager" }, 409);
    }
    if (existingRole?.role === "store_manager") {
      return json({ error: "user_is_already_a_store_manager" }, 409);
    }
  }

  const { count: recentInviteCount, error: rateError } = await adminClient
    .from("manager_invites")
    .select("id", { count: "exact", head: true })
    .eq("invited_by", caller.id)
    .gte("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString());
  if (rateError) return json({ error: "invitation_rate_check_failed" }, 500);
  if ((recentInviteCount ?? 0) >= 10) {
    return json({ error: "daily_invitation_limit_reached" }, 429);
  }

  const { data: inviteRow, error: insertError } = await adminClient
    .from("manager_invites")
    .insert({ email, invited_by: caller.id })
    .select("id")
    .single();

  if (insertError || !inviteRow) return json({ error: "invite_record_failed" }, 500);

  if (!existingUser) {
    const { error: authInviteError } = await adminClient.auth.admin.inviteUserByEmail(email, {
      redirectTo: new URL("/admin.html?accept-manager-invite=1", appUrl).toString(),
    });

    if (authInviteError) {
      await adminClient.from("manager_invites").delete().eq("id", inviteRow.id);
      return json({ error: "auth_invitation_failed", detail: authInviteError.message }, 400);
    }
  }

  const { error: auditError } = await adminClient.from("audit_log").insert({
    admin_email: caller.email?.toLowerCase() ?? "",
    action: "invite_manager",
    new_data: { email, invite_id: inviteRow.id, existing_auth_user: Boolean(existingUser) },
  });

  const claimUrl = new URL("/admin.html?accept-manager-invite=1", appUrl).toString();
  return json({
    ok: true,
    message: existingUser ? "existing_user_must_sign_in_and_claim" : "manager_invitation_sent",
    existing_user: Boolean(existingUser),
    claim_url: existingUser ? claimUrl : undefined,
    audit_warning: auditError ? "audit_log_write_failed" : undefined,
  }, 200);
});
