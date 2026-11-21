import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
const cors = {
  "Access-Control-Allow-Origin": "https://arghavan-mobile.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors });
const allowed = new Set([
  "kiosk_attendance_code",
  "kiosk_my_records_pin",
  "kiosk_my_requests_pin",
  "employee_submit_leave_request_pin",
  "employee_submit_attendance_request_pin"
]);

async function verifyPin(pin: string) {
  const { data, error } = await admin.rpc("device_gateway_verify_pin", { p_pin: pin });
  if (error) throw new Error("pin_verification_unavailable");
  return Array.isArray(data) && data.length === 1 ? data[0] : null;
}
async function getDevice(deviceId: string, employeeId: string) {
  const { data, error } = await admin.from("employee_devices")
    .select("id,employee_id,public_jwk,status")
    .eq("id", deviceId).eq("employee_id", employeeId).maybeSingle();
  if (error) throw new Error("device_lookup_failed");
  return data;
}
async function verifySignature(jwk: JsonWebKey, message: string, signatureB64: string) {
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
  const raw = Uint8Array.from(atob(signatureB64), c => c.charCodeAt(0));
  return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, new TextEncoder().encode(message));
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "method_not_allowed" }, 405);
  const origin = req.headers.get("origin");
  if (origin !== "https://arghavan-mobile.github.io") return reply({ error: "origin_not_allowed" }, 403);
  try {
    const body = await req.json();
    const action = String(body.action || "");
    const pin = String(body.pin || "");
    if (!/^\d{4,6}$/.test(pin)) return reply({ error: "invalid_pin" }, 400);
    const employee = await verifyPin(pin);
    if (!employee) return reply({ error: "invalid_pin" }, 401);

    if (action === "enroll") {
      const jwk = body.public_jwk as JsonWebKey;
      if (!jwk || jwk.kty !== "EC" || jwk.crv !== "P-256" || !jwk.x || !jwk.y) {
        return reply({ error: "invalid_public_key" }, 400);
      }
      const { data: current, error: currentError } = await admin.from("employee_devices")
        .select("id,status,public_jwk").eq("employee_id", employee.employee_id).in("status", ["active", "pending"]);
      if (currentError) throw new Error("device_state_unavailable");
      if ((current || []).some((d: any) => d.status === "active")) return reply({ error: "device_already_registered" }, 409);
      const pending = (current || []).find((d: any) => d.status === "pending");
      if (pending) {
        const sameKey = pending.public_jwk?.kty === jwk.kty && pending.public_jwk?.crv === jwk.crv &&
          pending.public_jwk?.x === jwk.x && pending.public_jwk?.y === jwk.y;
        if (!sameKey) return reply({ error: "another_device_is_waiting_for_approval" }, 409);
        return reply({ ok: true, device_id: pending.id, status: "pending", employee_name: employee.employee_name });
      }
      const status = employee.enrollment_authorized ? "active" : "pending";
      const { data: device, error: insertError } = await admin.from("employee_devices")
        .insert({ employee_id: employee.employee_id, public_jwk: jwk, device_label: String(body.device_label || "گوشی پرسنل").slice(0, 80), status,
          approved_at: status === "active" ? new Date().toISOString() : null, approved_by: status === "active" ? employee.device_enrollment_authorized_by : null })
        .select("id,status").single();
      if (insertError) throw new Error("device_enrollment_failed");
      if (status === "active") {
        await admin.from("employees").update({ device_enrollment_authorized: false, device_enrollment_authorized_by: null, device_enrollment_authorized_at: null }).eq("id", employee.employee_id);
      }
      await admin.from("audit_log").insert({ admin_email: "device-gateway", action: status === "active" ? "employee_device_replacement_enrolled" : "employee_device_enrollment_requested",
        employee_id: employee.employee_id, new_data: { device_id: device.id, status } });
      return reply({ ok: true, device_id: device.id, status, employee_name: employee.employee_name });
    }

    const deviceId = String(body.device_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(deviceId)) return reply({ error: "invalid_device" }, 400);
    const device = await getDevice(deviceId, employee.employee_id);
    if (!device) return reply({ error: "device_not_found" }, 404);

    if (action === "status") return reply({ ok: true, status: device.status, employee_name: employee.employee_name, enrollment_authorized: employee.enrollment_authorized });

    if (action === "challenge") {
      if (device.status !== "active") return reply({ error: device.status === "pending" ? "device_pending_approval" : "device_not_active" }, 403);
      const nonce = crypto.randomUUID();
      const expires = new Date(Date.now() + 120_000).toISOString();
      const { error } = await admin.from("employee_device_challenges").insert({ nonce, device_id: deviceId, expires_at: expires });
      if (error) throw new Error("challenge_creation_failed");
      return reply({ ok: true, nonce, expires_at: expires });
    }

    if (action === "execute") {
      const op = String(body.operation || "");
      if (!allowed.has(op)) return reply({ error: "operation_not_allowed" }, 403);
      if (device.status !== "active") return reply({ error: "device_not_active" }, 403);
      const timestamp = Number(body.timestamp);
      if (!Number.isFinite(timestamp) || Math.abs(Date.now() - timestamp) > 120_000) return reply({ error: "request_expired" }, 401);
      const args = body.args && typeof body.args === "object" && !Array.isArray(body.args) ? body.args : {};
      const signed = JSON.stringify({ v: 1, device_id: deviceId, nonce: String(body.nonce), operation: op, args, timestamp });
      const valid = await verifySignature(device.public_jwk as JsonWebKey, signed, String(body.signature || ""));
      if (!valid) return reply({ error: "invalid_device_signature" }, 401);
      const { data: consumed, error: consumeError } = await admin.rpc("consume_employee_device_challenge", { p_nonce: body.nonce, p_device_id: deviceId });
      if (consumeError || consumed !== true) return reply({ error: "challenge_used_or_expired" }, 409);
      const { data, error } = await admin.rpc(op, { ...args, p_pin: pin });
      if (error) {
        const message = error.message || "operation_failed";
        return reply({ error: message.replace(/[^a-zA-Z0-9_ -]/g, "").slice(0, 100) }, 400);
      }
      await admin.from("employee_devices").update({ last_seen_at: new Date().toISOString() }).eq("id", deviceId);
      return reply({ ok: true, result: data });
    }
    return reply({ error: "unknown_action" }, 400);
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "internal_error" }, 500);
  }
});
