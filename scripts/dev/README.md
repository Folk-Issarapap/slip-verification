# scripts/dev — local development helpers

## webhook-receiver.py

Tiny stdlib-only HTTP server that receives + pretty-prints inbound webhooks.
Use it to verify outbound merchant webhook delivery without webhook.site.

### Quick start

```bash
# 1. Start the receiver (defaults to :9000)
python3 scripts/dev/webhook-receiver.py --log /tmp/webhooks.jsonl

# 2. Expose it publicly (BroPay's URL validator rejects http://localhost
#    for SSRF protection, so a public HTTPS URL is required)
npx cloudflared tunnel --url http://localhost:9000
#    → grab the https://<random>.trycloudflare.com URL

# 3. Register it as a webhook endpoint for the demo merchant
BROPAY=http://localhost:8787
OWNER=$(curl -s "$BROPAY/v1/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"owner@demo.com","password":"Password123!"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['accessToken'])")
MID=<demo merchant id>
INT_ID=<demo integration id>
RECV_URL=https://<random>.trycloudflare.com

curl "$BROPAY/v1/merchant/webhook-endpoints" -X POST \
  -H "Authorization: Bearer $OWNER" -H "X-Merchant-Id: $MID" \
  -H 'Origin: http://localhost:3000' -H 'Content-Type: application/json' \
  -d "{\"integration_id\":\"$INT_ID\",\"url\":\"$RECV_URL/\",\"subscribed_events\":[\"payment.completed\",\"settlement.completed\"]}"

# 4. Trigger an event — e.g. complete a PI via the admin route or
#    let KBNK fire deposit.completed. The receiver prints each request.
```

### CLI flags

| flag | default | meaning |
|---|---|---|
| `--port` | `9000` | port to bind |
| `--host` | `0.0.0.0` | bind address (0.0.0.0 so cloudflared can reach it) |
| `--log <path>` | none | append each request as one JSON line for replay/grep |

### Output format

```
━━ 2026-04-27T16:24:27.956  POST /  event=payment.completed
  Webhook-Id              23ba0b27-fefb-452d-b64b-62b3c0e06d4c
  Webhook-Signature       v1,bIqxiZru8/DM2H6YeMUrJokQNEAo6hGeKJta9TU61eM=
  Webhook-Timestamp       1777281867
  Content-Type            application/json
{
  "event": "payment.completed",
  "eventId": "23ba0b27-fefb-452d-b64b-62b3c0e06d4c",
  "timestamp": "2026-04-27T09:24:27.781Z",
  "data": { ... }
}
```

The `--log` JSONL contains the full headers + body of every request, suitable
for `jq`, `grep`, or replaying with `cat … | curl`.

### Verifying signatures

BroPay signs outbound webhooks per [Standard Webhooks](https://www.standardwebhooks.com):

```
signed_payload = "${webhook_id}.${webhook_timestamp}.${raw_body}"
header         = "v1," + base64(HMAC-SHA256(signing_secret, signed_payload))
```

The `signing_secret` is returned exactly once when you create the endpoint
(in `data.signing_secret`). To verify a captured request:

```python
import hmac, hashlib, base64, json
secret  = "wh_…"
record  = json.loads(open("/tmp/webhooks.jsonl").readline())
msg     = f"{record['headers']['Webhook-Id']}.{record['headers']['Webhook-Timestamp']}.{json.dumps(record['body'], separators=(',', ':'))}"
sig     = "v1," + base64.b64encode(hmac.new(secret.encode(), msg.encode(), hashlib.sha256).digest()).decode()
print(sig == record['headers']['Webhook-Signature'])
```

### Why not webhook.site

It works, but: requires internet, tokens expire, captures are public, and
signature verification needs you to copy each body out manually. The local
receiver is one file, no deps, and the `--log` file is grep/jq-friendly.

### Why we still need a tunnel

BroPay's webhook URL validator (`apps/api/src/routes/v1/merchant/webhook-endpoints.ts`)
rejects URLs that are non-HTTPS or target private/loopback addresses — basic
SSRF protection. Cloudflared's quick-tunnel gives us a public HTTPS URL that
forwards to localhost:9000, satisfying the validator without weakening it.
