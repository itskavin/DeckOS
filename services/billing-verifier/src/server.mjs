import http from 'node:http';
import { pathToFileURL } from 'node:url';

const MAX_BODY_BYTES = 64 * 1024;

export function createBillingHttpServer(service) {
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url || '/', 'http://localhost');
      if (req.method === 'GET' && url.pathname === '/healthz') {
        return sendJson(res, 200, { status: 'ok' });
      }
      if (req.method !== 'POST') {
        return sendJson(res, 405, { code: 'method_not_allowed' });
      }
      // Reject tokens in query strings to prevent accidental server/proxy logging.
      if (url.search && url.search.length > 0) {
        return sendJson(res, 400, { code: 'query_params_not_allowed' });
      }

      let body;
      try {
        body = await readJsonBody(req);
        if (!body || typeof body !== 'object' || Array.isArray(body)) return sendJson(res, 400, { code: 'invalid_body' });
      } catch (err) {
        return sendJson(res, err.statusCode || 400, {
          code: err.code || 'invalid_json',
        });
      }

      if (url.pathname === '/v1/billing/verify') {
        const result = await service.verifyPurchase(body);
        return sendJson(
          res,
          result.statusCode,
          result.ok ? { entitlement: result.entitlement } : { code: result.code },
        );
      }

      if (url.pathname === '/v1/billing/refresh') {
        const result = await service.refreshEntitlement(body);
        return sendJson(
          res,
          result.statusCode,
          result.ok ? { entitlement: result.entitlement } : { code: result.code },
        );
      }

      if (url.pathname === '/v1/billing/rtdn') {
        const result = await service.handleRtdnPush({
          authorizationHeader: req.headers.authorization || '',
          body,
        });
        return sendJson(
          res,
          result.statusCode,
          result.ok ? { ok: true } : { code: result.code },
        );
      }

      return sendJson(res, 404, { code: 'not_found' });
    } catch {
      // Never expose exceptions, request bodies, credentials or purchase tokens.
      if (!res.headersSent) sendJson(res, 503, { code: 'service_unavailable' });
      else res.destroy();
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  server.setTimeout(20000, (socket) => socket.destroy());
  return server;
}

function sendJson(res, statusCode, payload) {
  const text = JSON.stringify(payload);
  res.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(text);
}

async function readJsonBody(req) {
  let total = 0;
  const chunks = [];
  for await (const chunk of req) {
    total += chunk.length;
    if (total > MAX_BODY_BYTES) {
      const err = new Error('Payload too large');
      err.statusCode = 413;
      err.code = 'payload_too_large';
      throw err;
    }
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  return JSON.parse(raw);
}

// No production launcher is supplied by this template. Environment variables
// cannot turn fixture storage or placeholder OIDC checks into trusted adapters.
export function assertProductionReady() {
  throw new Error('Billing verifier template cannot start: implement and review durable transactional encrypted ownership storage, authenticated account recovery and Google Pub/Sub OIDC validation before supplying a production launcher.');
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  try { assertProductionReady(); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
