#!/usr/bin/env node
/**
 * Local BroPay <-> KBNK staging smoke test.
 *
 * Flow:
 * 1. Check BroPay API and configured KBNK provider health.
 * 2. Create a merchant integration and a provider-backed payment intent through BroPay.
 * 3. Trigger KBNK staging deposit simulation.
 * 4. Poll BroPay until the async KBNK webhook marks the payment intent succeeded.
 *
 * Required:
 *   KBNK_CLIENT_ID / KBNK_CLIENT_SECRET
 *   or KBNK_API_KEY / KBNK_API_SECRET
 *
 * Useful defaults:
 *   BROPAY_URL=https://bropay-api-local.example.com
 *   KBNK_URL=https://kbnk-payment-api-staging.example.com
 */

import crypto from "node:crypto"

const config = {
  bropayUrl: env("BROPAY_URL", "https://bropay-api-local.example.com"),
  kbnkUrl: env("KBNK_URL", "https://kbnk-payment-api-staging.example.com"),
  origin: env("BROPAY_ORIGIN", "http://localhost:3000"),
  adminEmail: env("BROPAY_ADMIN_EMAIL", "admin@bropay.com"),
  adminPassword: env("BROPAY_ADMIN_PASSWORD", "password123"),
  merchantEmail: env("BROPAY_MERCHANT_EMAIL", "merchant.owner@bropay.com"),
  merchantPassword: env("BROPAY_MERCHANT_PASSWORD", "password123"),
  merchantId: env("BROPAY_MERCHANT_ID", "merch-demo-merchant-0000-000000000001"),
  providerId: env("BROPAY_KBNK_PROVIDER_ID", "prov-kbnk-000000-0000-000000000001"),
  amountSatang: numberEnv("KBNK_SMOKE_AMOUNT_SATANG", 5000),
  pollSeconds: numberEnv("KBNK_SMOKE_POLL_SECONDS", 30),
  pollIntervalMs: numberEnv("KBNK_SMOKE_POLL_INTERVAL_MS", 1500),
  simulationMethod: env("KBNK_DEPOSIT_SIMULATION_METHOD", "PATCH"),
  simulationPathTemplate: env(
    "KBNK_DEPOSIT_SIMULATION_PATH_TEMPLATE",
    "/api/v1/deposits/{depositId}/status"
  ),
  simulationBodyTemplate: env("KBNK_DEPOSIT_SIMULATION_BODY", '{"status":"completed"}'),
}

const kbnkClientId = process.env.KBNK_CLIENT_ID ?? process.env.KBNK_API_KEY
const kbnkClientSecret = process.env.KBNK_CLIENT_SECRET ?? process.env.KBNK_API_SECRET

if (!kbnkClientId || !kbnkClientSecret) {
  fail("Set KBNK_CLIENT_ID/KBNK_CLIENT_SECRET or KBNK_API_KEY/KBNK_API_SECRET before running.")
}

const summary = {
  bropayUrl: config.bropayUrl,
  kbnkUrl: config.kbnkUrl,
  providerHealth: "",
  integrationId: "",
  paymentIntentId: "",
  providerDepositId: "",
  finalStatus: "",
}

try {
  section("1. BroPay provider health")
  const adminToken = await login("staff", config.adminEmail, config.adminPassword)
  const providerHealth = await bropayJson(`/v1/admin/providers/${config.providerId}/health-check`, {
    method: "POST",
    token: adminToken,
    body: {},
  })
  const healthData = providerHealth.body.data
  if (providerHealth.status !== 200 || !["healthy", "degraded"].includes(healthData?.status)) {
    fail(`Provider health check failed: ${formatBody(providerHealth)}`)
  }
  summary.providerHealth = healthData.status
  pass(`KBNK provider health is ${healthData.status} (${healthData.response_time_ms}ms)`)

  section("2. Create provider-backed payment intent")
  const merchantToken = await login("merchant", config.merchantEmail, config.merchantPassword)
  const integration = await createIntegration(merchantToken)
  summary.integrationId = integration.id
  pass(`Integration active: ${short(integration.id)}`)

  const paymentIntent = await createPaymentIntent(integration)
  summary.paymentIntentId = paymentIntent.id
  summary.providerDepositId = paymentIntent.provider_deposit_id
  if (paymentIntent.status !== "requires_action" || !paymentIntent.provider_deposit_id) {
    fail(`Payment intent did not reach provider action state: ${JSON.stringify(paymentIntent)}`)
  }
  pass(
    `Payment intent ${short(paymentIntent.id)} is ${paymentIntent.status}; provider deposit ${paymentIntent.provider_deposit_id}`
  )

  section("3. Trigger KBNK staging simulation")
  const kbnkToken = await getKbnkToken()
  const simulation = await simulateDeposit(kbnkToken, paymentIntent.provider_deposit_id)
  if (simulation.status < 200 || simulation.status >= 300) {
    fail(`KBNK simulation failed: HTTP ${simulation.status} ${JSON.stringify(simulation.body)}`)
  }
  pass(`Simulation accepted by KBNK: HTTP ${simulation.status}`)

  section("4. Wait for async KBNK webhook")
  const finalPi = await pollPaymentIntent(merchantToken, paymentIntent.id)
  summary.finalStatus = finalPi.status
  if (finalPi.status !== "succeeded") {
    fail(`Payment intent did not succeed before timeout; final status=${finalPi.status}`)
  }
  pass(`Payment intent ${short(finalPi.id)} succeeded via KBNK webhook`)

  section("Summary")
  console.log(JSON.stringify(summary, null, 2))
} catch (error) {
  console.error("")
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
}

async function createIntegration(token) {
  const slug = `kbnk-local-smoke-${Date.now()}`
  const create = await bropayJson("/v1/merchant/integrations", {
    method: "POST",
    token,
    merchantId: config.merchantId,
    body: { name: "KBNK Local Smoke", slug },
  })
  if (create.status !== 201 || !create.body.data?.id) {
    fail(`Integration creation failed: ${formatBody(create)}`)
  }
  const integration = create.body.data
  if (!integration.api_key || !integration.secret_key) {
    fail("Integration response did not include one-time HMAC credentials.")
  }

  const activate = await bropayJson(`/v1/merchant/integrations/${integration.id}`, {
    method: "PUT",
    token,
    merchantId: config.merchantId,
    body: { status: "active" },
  })
  if (activate.status !== 200 || activate.body.data?.status !== "active") {
    fail(`Integration activation failed: ${formatBody(activate)}`)
  }

  return integration
}

async function createPaymentIntent(integration) {
  const body = JSON.stringify({
    amount: config.amountSatang,
    currency: "THB",
    payment_method: "promptpay",
    description: "KBNK local smoke test",
    idempotency_key: `kbnk-local-smoke-${Date.now()}`,
    customer: {
      bank_code: "004",
      account_number: "0123456789",
      account_holder_name: "KBNK Local Smoke",
    },
  })
  const timestamp = Math.floor(Date.now() / 1000).toString()
  const signature = crypto
    .createHmac("sha256", integration.secret_key)
    .update(`POST./v1/api/payment-intents.${timestamp}.${body}`)
    .digest("hex")

  const created = await bropayRaw("/v1/api/payment-intents", {
    method: "POST",
    headers: {
      "X-Api-Key": integration.api_key,
      "X-Timestamp": timestamp,
      "X-Signature": signature,
    },
    body,
  })
  if (created.status !== 201 || !created.body.data?.id) {
    fail(`Payment intent creation failed: ${formatBody(created)}`)
  }
  return created.body.data
}

async function pollPaymentIntent(token, paymentIntentId) {
  const startedAt = Date.now()
  let last
  while (Date.now() - startedAt <= config.pollSeconds * 1000) {
    const detail = await bropayJson(`/v1/merchant/payment-intents/${paymentIntentId}`, {
      token,
      merchantId: config.merchantId,
    })
    if (detail.status !== 200 || !detail.body.data) {
      fail(`Payment intent detail failed while polling: ${formatBody(detail)}`)
    }
    last = detail.body.data
    if (["succeeded", "failed", "cancelled", "expired"].includes(last.status)) return last
    await sleep(config.pollIntervalMs)
  }
  return last
}

async function simulateDeposit(token, providerDepositId) {
  const path = config.simulationPathTemplate.replace(
    "{depositId}",
    encodeURIComponent(providerDepositId)
  )
  const renderedBody = config.simulationBodyTemplate.replaceAll("{depositId}", providerDepositId)
  let body
  try {
    body = JSON.parse(renderedBody)
  } catch {
    fail(`KBNK_DEPOSIT_SIMULATION_BODY must be valid JSON after template render: ${renderedBody}`)
  }

  return kbnkJson(path, {
    method: config.simulationMethod,
    token,
    body,
  })
}

async function getKbnkToken() {
  const token = await kbnkJson("/api/v1/auth/token", {
    method: "POST",
    body: {
      grant_type: "client_credentials",
      client_id: kbnkClientId,
      client_secret: kbnkClientSecret,
    },
    skipAuth: true,
  })
  if (token.status !== 200 || !token.body.access_token) {
    fail(`KBNK auth failed: HTTP ${token.status}`)
  }
  return token.body.access_token
}

async function login(kind, email, password) {
  const res = await bropayJson(`/v1/auth/${kind}/login`, {
    method: "POST",
    body: { email, password },
  })
  const token = res.body.data?.accessToken ?? res.body.data?.access_token ?? res.body.access_token
  if (res.status !== 200 || !token) {
    fail(`${kind} login failed: ${formatBody(res)}`)
  }
  return token
}

async function bropayJson(path, options = {}) {
  return bropayRaw(path, {
    ...options,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  })
}

async function bropayRaw(path, options = {}) {
  return requestJson(`${config.bropayUrl}${path}`, {
    ...options,
    headers: {
      Origin: config.origin,
      ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
      ...(options.merchantId ? { "X-Merchant-Id": options.merchantId } : {}),
      ...(options.headers ?? {}),
    },
  })
}

async function kbnkJson(path, options = {}) {
  return requestJson(`${config.kbnkUrl}${path}`, {
    ...options,
    headers: {
      ...(options.skipAuth ? {} : { Authorization: `Bearer ${options.token}` }),
      ...(options.headers ?? {}),
    },
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  })
}

async function requestJson(url, options = {}) {
  const headers = {
    ...(options.body === undefined ? {} : { "Content-Type": "application/json" }),
    ...(options.headers ?? {}),
  }
  const response = await fetch(url, {
    method: options.method ?? "GET",
    headers,
    body: options.body,
  })
  const text = await response.text()
  let body
  try {
    body = text.length ? JSON.parse(text) : null
  } catch {
    body = { raw: text }
  }
  return { status: response.status, body }
}

function env(name, fallback) {
  return process.env[name] && process.env[name].length > 0 ? process.env[name] : fallback
}

function numberEnv(name, fallback) {
  const value = process.env[name]
  if (!value) return fallback
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed <= 0) fail(`${name} must be a positive number`)
  return parsed
}

function section(title) {
  console.log("")
  console.log(`--- ${title} ---`)
}

function pass(message) {
  console.log(`OK ${message}`)
}

function fail(message) {
  throw new Error(message)
}

function formatBody(response) {
  return `HTTP ${response.status} ${JSON.stringify(response.body)}`
}

function short(id) {
  return typeof id === "string" && id.length > 12 ? `${id.slice(0, 8)}...` : id
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
