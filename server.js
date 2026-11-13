'use strict';

// Cloady hub: public ingress + task queue + artifact panel.
// Zero third-party dependencies, sized for the free tier (0.5 vCPU / 1 GB).
//
// State is IN-MEMORY on purpose: the free app has no persistent volume and is
// redeployed on every git push. Box republishes artifacts every cycle, so the
// panel self-heals after a restart. Durable history belongs in GitHub.

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 3000);
const PUBLIC_DIR = path.join(__dirname, 'public');
const STARTED_AT = new Date().toISOString();

const MAX_BODY = 1024 * 1024;            // 1 MB request cap
const MAX_TASKS = 200;
const MAX_ARTIFACTS = 80;
const MAX_ARTIFACT_BYTES = 512 * 1024;  // per binary artifact
const MAX_RESULT_CHARS = 32 * 1024;
const CLAIM_TIMEOUT_MS = 10 * 60 * 1000;

const HUB_TOKEN = process.env.HUB_TOKEN || '';
const GITHUB_WEBHOOK_SECRET = process.env.GITHUB_WEBHOOK_SECRET || '';
const BOT_SECRET = process.env.BOT_SECRET || '';
const GITHUB_TOKEN = process.env.GITHUB_TOKEN || '';   // optional Issue mirror
const GITHUB_REPO = process.env.GITHUB_REPO || '';     // "owner/repo"

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
};

const tasks = new Map();
const artifacts = new Map();

// ---------------------------------------------------------------- helpers

function json(res, status, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        settled = true;
        reject(new Error('payload too large (1 MB max)'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (!settled) { settled = true; resolve(Buffer.concat(chunks)); }
    });
    req.on('error', (err) => {
      if (!settled) { settled = true; reject(err); }
    });
  });
}

async function readJson(req) {
  const buf = await readBody(req);
  const raw = buf.toString('utf8');
  try { return { raw, value: raw ? JSON.parse(raw) : {} }; }
  catch { throw new Error('invalid JSON body'); }
}

function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ha = crypto.createHash('sha256').update(a).digest();
  const hb = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function suppliedToken(req, url) {
  const h = req.headers['x-hub-token'];
  if (typeof h === 'string' && h) return h;
  return url.searchParams.get('key') || '';
}

function accessOk(req, url) {
  if (!HUB_TOKEN) return false;           // fail closed, never open by default
  return safeEqual(suppliedToken(req, url), HUB_TOKEN);
}

function requireAccess(req, res, url) {
  if (accessOk(req, url)) return true;
  json(res, HUB_TOKEN ? 401 : 503, {
    error: HUB_TOKEN ? 'unauthorized: send X-Hub-Token or ?key=' : 'HUB_TOKEN is not configured on this app',
  });
  return false;
}

function githubSigOk(req, raw, url) {
  if (!GITHUB_WEBHOOK_SECRET) return accessOk(req, url);
  const sig = req.headers['x-hub-signature-256'];
  if (typeof sig !== 'string') return false;
  const expected = 'sha256=' + crypto.createHmac('sha256', GITHUB_WEBHOOK_SECRET).update(raw).digest('hex');
  return safeEqual(sig, expected);
}

function botSecretOk(req, url) {
  const h = req.headers['x-telegram-bot-api-secret-token'];
  if (BOT_SECRET && typeof h === 'string' && safeEqual(h, BOT_SECRET)) return true;
  return accessOk(req, url);
}

function serveStatic(req, res, pathname) {
  let rel;
  if (pathname === '/') rel = 'index.html';
  else if (pathname === '/panel') rel = 'panel.html';
  else rel = pathname.replace(/^\/+/, '');
  const file = path.resolve(PUBLIC_DIR, rel);
  if (!file.startsWith(PUBLIC_DIR + path.sep)) return json(res, 403, { error: 'forbidden' });
  fs.readFile(file, (err, data) => {
    if (err) return json(res, 404, { error: 'not found', path: pathname });
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(file)] || 'application/octet-stream',
      'Content-Length': data.length,
      'X-Content-Type-Options': 'nosniff',
    });
    res.end(req.method === 'HEAD' ? undefined : data);
  });
}

function clip(value, max) {
  const s = typeof value === 'string' ? value : JSON.stringify(value ?? null);
  return s.length > max ? s.slice(0, max) + '…[truncated]' : s;
}

function trimMap(map, max) {
  while (map.size > max) map.delete(map.keys().next().value);
}

// ---------------------------------------------------------------- state

function publicTask(t) {
  return {
    id: t.id, type: t.type, source: t.source, status: t.status,
    payload: t.payload, createdAt: t.createdAt, claimedAt: t.claimedAt,
    claimedBy: t.claimedBy, finishedAt: t.finishedAt,
    result: t.result, error: t.error, issue: t.issue,
  };
}

function enqueue({ type, payload, source }) {
  const id = 't_' + Date.now().toString(36) + '_' + crypto.randomBytes(4).toString('hex');
  const t = {
    id,
    type: String(type || 'generic').slice(0, 40),
    payload: (() => {
      try {
        const s = clip(payload, 16 * 1024);
        return s.endsWith('…[truncated]') ? { _truncated: true, preview: s } : JSON.parse(s);
      } catch { return { _unparsed: true }; }
    })(),
    source: String(source || 'api').slice(0, 60),
    status: 'pending',
    createdAt: new Date().toISOString(),
    claimedAt: null, claimedBy: null, finishedAt: null,
    result: null, error: null, issue: null,
  };
  tasks.set(id, t);
  trimMap(tasks, MAX_TASKS);
  mirrorIssue(t);
  return t;
}

function reapStale() {
  const now = Date.now();
  for (const t of tasks.values()) {
    if (t.status === 'claimed' && t.claimedAt && now - Date.parse(t.claimedAt) > CLAIM_TIMEOUT_MS) {
      t.status = 'pending';
      t.claimedBy = null;
      t.claimedAt = null;
      t.error = 'requeued: worker timed out';
    }
  }
}

function publicArtifact(a) {
  return {
    id: a.id, kind: a.kind, title: a.title, url: a.url,
    contentType: a.contentType, meta: a.meta,
    updatedAt: a.updatedAt, size: a.buffer ? a.buffer.length : Buffer.byteLength(a.body || ''),
    hasRaw: !!(a.buffer || a.body),
    preview: a.buffer ? null : (a.body || '').slice(0, 4000),
  };
}

function healthPayload() {
  const counts = { pending: 0, claimed: 0, done: 0, failed: 0 };
  for (const t of tasks.values()) if (counts[t.status] !== undefined) counts[t.status]++;
  return {
    ok: true,
    startedAt: STARTED_AT,
    uptimeSeconds: Math.round(process.uptime()),
    memoryMB: Math.round(process.memoryUsage().rss / 1048576),
    tasks: { ...counts, total: tasks.size },
    artifacts: artifacts.size,
    config: {
      access: !!HUB_TOKEN,
      githubWebhook: !!GITHUB_WEBHOOK_SECRET,
      botSecret: !!BOT_SECRET,
      githubIssueMirror: !!(GITHUB_TOKEN && GITHUB_REPO),
    },
  };
}

// ---------------------------------------------------------------- optional GitHub Issue mirror

function ghHeaders() {
  return {
    'Authorization': 'Bearer ' + GITHUB_TOKEN,
    'Accept': 'application/vnd.github+json',
    'Content-Type': 'application/json',
    'User-Agent': 'cloady-hub',
    'X-GitHub-Api-Version': '2022-11-28',
  };
}

async function mirrorIssue(t) {
  if (!(GITHUB_TOKEN && GITHUB_REPO)) return;
  try {
    const r = await fetch(`https://api.github.com/repos/${GITHUB_REPO}/issues`, {
      method: 'POST',
      headers: ghHeaders(),
      body: JSON.stringify({
        title: `[hub:${t.type}] ${t.id}`,
        labels: ['cloady-hub'],
        body: `Source: \`${t.source}\`\nCreated: ${t.createdAt}\n\n\`\`\`json\n${clip(t.payload, 8000)}\n\`\`\``,
      }),
      signal: AbortSignal.timeout(8000),
    });
    if (r.ok) {
      const d = await r.json();
      t.issue = { number: d.number, url: d.html_url };
    }
  } catch (e) { console.warn('[issue mirror] create failed:', e.message); }
}

async function commentIssue(t, text) {
  if (!(GITHUB_TOKEN && GITHUB_REPO) || !t.issue) return;
  try {
    await fetch(`https://api.github.com/repos/${GITHUB_REPO}/issues/${t.issue.number}/comments`, {
      method: 'POST', headers: ghHeaders(), body: JSON.stringify({ body: clip(text, 60000) }),
      signal: AbortSignal.timeout(8000),
    });
  } catch (e) { console.warn('[issue mirror] comment failed:', e.message); }
}

// ---------------------------------------------------------------- router

const server = http.createServer(async (req, res) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  } catch {
    return json(res, 400, { error: 'bad request' });
  }
  const p = url.pathname;

  try {
    // ---- public probes -------------------------------------------------
    if (p === '/api/health' && (req.method === 'GET' || req.method === 'HEAD')) {
      return json(res, 200, healthPayload());
    }
    if (p === '/api/hello') {
      return json(res, 200, { message: 'Hello from Cloady', time: new Date().toISOString(), query: Object.fromEntries(url.searchParams) });
    }
    if (p === '/api/echo' && req.method === 'POST') {
      const raw = (await readBody(req)).toString('utf8');
      let value;
      try { value = raw ? JSON.parse(raw) : null; } catch { value = raw; }
      return json(res, 200, { received: value });
    }
    if (p === '/api/version') {
      let version = 'dev';
      try { version = fs.readFileSync(path.join(__dirname, 'VERSION'), 'utf8').trim(); } catch { /* no VERSION file */ }
      return json(res, 200, { version, startedAt: STARTED_AT });
    }

    // ---- read-only panel ----------------------------------------------
    if (p === '/panel' && (req.method === 'GET' || req.method === 'HEAD')) {
      if (!requireAccess(req, res, url)) return;
      return serveStatic(req, res, '/panel');
    }
    if (p === '/api/panel') {
      if (!requireAccess(req, res, url)) return;
      return json(res, 200, {
        health: healthPayload(),
        tasks: [...tasks.values()].slice(-40).reverse().map(publicTask),
        artifacts: [...artifacts.values()].slice(-40).reverse().map(publicArtifact),
      });
    }
    if (p === '/api/artifact') { /* alias hint */ }

    // ---- queue: read ---------------------------------------------------
    if (p === '/api/tasks') {
      if (!requireAccess(req, res, url)) return;
      reapStale();
      const status = url.searchParams.get('status');
      const list = [...tasks.values()].filter((t) => !status || t.status === status).map(publicTask);
      return json(res, 200, { tasks: list, total: list.length });
    }

    // ---- queue: claim --------------------------------------------------
    if (p === '/api/tasks/claim' && req.method === 'POST') {
      if (!requireAccess(req, res, url)) return;
      const { value } = await readJson(req);
      reapStale();
      const worker = String(value.worker || 'anonymous').slice(0, 60);
      const limit = Math.min(Math.max(Number(value.limit) || 1, 1), 10);
      const types = Array.isArray(value.types) ? value.types.map(String) : null;
      const claimed = [];
      for (const t of tasks.values()) {
        if (claimed.length >= limit) break;
        if (t.status !== 'pending') continue;
        if (types && !types.includes(t.type)) continue;
        t.status = 'claimed';
        t.claimedBy = worker;
        t.claimedAt = new Date().toISOString();
        claimed.push(publicTask(t));
      }
      return json(res, 200, { claimed, worker, at: new Date().toISOString() });
    }

    // ---- queue: create -------------------------------------------------
    if (p === '/api/task' && req.method === 'POST') {
      if (!requireAccess(req, res, url)) return;
      const { value } = await readJson(req);
      if (!value || typeof value !== 'object' || Array.isArray(value)) return json(res, 400, { error: 'expected a JSON object' });
      if (!value.type) return json(res, 400, { error: 'missing "type"' });
      const t = enqueue({ type: value.type, payload: value.payload ?? {}, source: value.source || 'api' });
      return json(res, 202, { accepted: true, task: publicTask(t) });
    }

    // ---- queue: result -------------------------------------------------
    if (p === '/api/result' && req.method === 'POST') {
      if (!requireAccess(req, res, url)) return;
      const { value } = await readJson(req);
      const t = tasks.get(String(value.id || ''));
      if (!t) return json(res, 404, { error: 'unknown task id' });
      t.status = value.ok === false ? 'failed' : 'done';
      t.finishedAt = new Date().toISOString();
      t.result = value.result === undefined ? null : clip(value.result, MAX_RESULT_CHARS);
      t.error = value.error ? String(value.error).slice(0, 2000) : null;
      commentIssue(t, `**${t.status}** by \`${t.claimedBy || 'unknown'}\` at ${t.finishedAt}\n\n\`\`\`\n${t.result || t.error}\n\`\`\``);
      return json(res, 200, { ok: true, task: publicTask(t) });
    }

    // ---- artifacts: publish -------------------------------------------
    if (p === '/api/publish' && req.method === 'POST') {
      if (!requireAccess(req, res, url)) return;
      const { value } = await readJson(req);
      const id = String(value.id || '').slice(0, 120);
      if (!/^[A-Za-z0-9._:-]{1,120}$/.test(id)) return json(res, 400, { error: 'invalid "id" (letters, digits, . _ : - only)' });
      let buffer = null;
      if (value.bodyBase64) {
        buffer = Buffer.from(String(value.bodyBase64), 'base64');
        if (buffer.length > MAX_ARTIFACT_BYTES) return json(res, 413, { error: 'binary artifact exceeds 512 KB' });
      }
      const a = {
        id,
        kind: String(value.kind || 'other').slice(0, 40),
        title: String(value.title || id).slice(0, 200),
        body: value.body === undefined ? '' : String(value.body).slice(0, 64 * 1024),
        buffer,
        contentType: String(value.contentType || (buffer ? 'application/octet-stream' : 'text/plain; charset=utf-8')).slice(0, 100),
        url: value.url ? String(value.url).slice(0, 500) : null,
        meta: value.meta && typeof value.meta === 'object' ? value.meta : {},
        updatedAt: new Date().toISOString(),
      };
      artifacts.delete(id);
      artifacts.set(id, a);
      trimMap(artifacts, MAX_ARTIFACTS);
      return json(res, 200, { ok: true, artifact: publicArtifact(a) });
    }

    // ---- artifacts: raw ------------------------------------------------
    if (p.startsWith('/api/artifact/') && p.endsWith('/raw') && (req.method === 'GET' || req.method === 'HEAD')) {
      if (!requireAccess(req, res, url)) return;
      const id = decodeURIComponent(p.slice('/api/artifact/'.length, -'/raw'.length));
      const a = artifacts.get(id);
      if (!a) return json(res, 404, { error: 'unknown artifact' });
      const data = a.buffer || Buffer.from(a.body || '', 'utf8');
      const type = a.buffer ? a.contentType : (a.contentType.startsWith('text/') ? a.contentType : 'text/plain; charset=utf-8');
      res.writeHead(200, {
        'Content-Type': type,
        'Content-Length': data.length,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'Content-Disposition': 'inline',
      });
      return res.end(req.method === 'HEAD' ? undefined : data);
    }

    // ---- webhooks (public ingress) ------------------------------------
    if (p === '/api/webhook/github' && req.method === 'POST') {
      const buf = await readBody(req);
      const raw = buf.toString('utf8');
      // Signature MUST be checked against the exact raw bytes, before parsing.
      const sigHeader = req.headers['x-hub-signature-256'];
      let verified = false;
      if (GITHUB_WEBHOOK_SECRET && typeof sigHeader === 'string') {
        const expected = 'sha256=' + crypto.createHmac('sha256', GITHUB_WEBHOOK_SECRET).update(raw).digest('hex');
        verified = safeEqual(sigHeader, expected);
      }
      if (!verified && !accessOk(req, url)) return json(res, 401, { error: 'bad GitHub signature' });
      let value = {};
      try { value = raw ? JSON.parse(raw) : {}; } catch { /* keep empty */ }
      const event = String(req.headers['x-github-event'] || 'push').slice(0, 40);
      const repo = value && value.repository ? value.repository.full_name : '';
      const t = enqueue({
        type: 'github.' + event,
        source: 'github:' + repo,
        payload: {
          event, repo,
          ref: value && value.ref,
          sha: value && value.after,
          pusher: value && value.pusher && value.pusher.name,
          action: value && value.action,
          subject: (value && value.head_commit && value.head_commit.message) || (value && value.issue && value.issue.title),
        },
      });
      return json(res, 202, { accepted: true, task: publicTask(t) });
    }

    if (p === '/api/webhook/bot' && req.method === 'POST') {
      const { value } = await readJson(req);
      if (!botSecretOk(req, url)) return json(res, 401, { error: 'unauthorized bot' });
      const msg = (value && (value.message || value.edited_message)) || {};
      const text = (msg.text || value.text || '').toString().slice(0, 2000);
      const t = enqueue({
        type: text.startsWith('/') ? 'command' : 'message',
        source: 'bot',
        payload: { text, chatId: msg.chat && msg.chat.id, updateId: value && value.update_id, raw: value },
      });
      return json(res, 200, { ok: true, task: publicTask(t) });
    }

    if (p === '/api/webhook' && req.method === 'POST') {
      const { value } = await readJson(req);
      if (!accessOk(req, url)) return json(res, 401, { error: 'unauthorized' });
      const t = enqueue({
        type: (value && value.type) || 'webhook',
        source: (value && value.source) || 'webhook',
        payload: (value && value.payload) || value,
      });
      return json(res, 202, { accepted: true, task: publicTask(t) });
    }

    // ---- static --------------------------------------------------------
    if (req.method === 'GET' || req.method === 'HEAD') return serveStatic(req, res, p);

    return json(res, 405, { error: 'method not allowed' });
  } catch (err) {
    const tooLarge = err.message && err.message.includes('too large');
    return json(res, tooLarge ? 413 : 400, { error: err.message });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[cloady-hub] listening on 0.0.0.0:${PORT}`);
  console.log(`[cloady-hub] access=${!!HUB_TOKEN} githubWebhook=${!!GITHUB_WEBHOOK_SECRET} bot=${!!BOT_SECRET} issueMirror=${!!(GITHUB_TOKEN && GITHUB_REPO)}`);
});
