// server.js — entrypoint: Express HTTP API + Baileys + worker
import express from 'express';
import { baileys } from './baileys-client.js';
import { startWorker } from './broadcast-worker.js';

const PORT = parseInt(process.env.PORT || '3000', 10);
const RELAY_AUTH_TOKEN = process.env.RELAY_AUTH_TOKEN || '';

const app = express();
app.use(express.json({ limit: '1mb' }));

// CORS - allow front-end on GitHub Pages
app.use((req, res, next) => {
  const allowed = (process.env.CORS_ORIGINS || 'https://mrchiealgerie-hub.github.io').split(',');
  const origin = req.headers.origin;
  if (origin && allowed.includes(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
  } else if (allowed.includes('*')) {
    res.setHeader('Access-Control-Allow-Origin', '*');
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

function authMiddleware(req, res, next) {
  if (!RELAY_AUTH_TOKEN) return next(); // no auth configured (dev mode)
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (token !== RELAY_AUTH_TOKEN) return res.status(401).json({ error: 'Unauthorized' });
  next();
}

// PUBLIC: health check
app.get('/', (_req, res) => {
  res.json({
    service: 'wacrm-baileys-relay',
    state: baileys.state,
    connected: baileys.isConnected(),
    timestamp: new Date().toISOString(),
  });
});

app.get('/health', (_req, res) => res.json({ ok: true, state: baileys.state }));

// PROTECTED: detailed status + QR code (token required)
app.get('/status', authMiddleware, (_req, res) => {
  res.json({
    state: baileys.state,
    connected: baileys.isConnected(),
    phone: baileys.phoneNumber,
    qr: baileys.qrCodeDataUrl,  // base64 data URL when in 'qr' state
    qrText: baileys.qrCode,
  });
});

// PROTECTED: force logout (re-scan QR next start)
app.post('/logout', authMiddleware, async (_req, res) => {
  await baileys.logout();
  setTimeout(() => baileys.start(), 2000);
  res.json({ ok: true, message: 'Logged out, restarting…' });
});

// PROTECTED: send a single test message (for diagnostics)
app.post('/test', authMiddleware, async (req, res) => {
  const { phone, message } = req.body || {};
  if (!phone || !message) return res.status(400).json({ error: 'phone and message required' });
  const result = await baileys.sendText(phone, message);
  res.json(result);
});

app.listen(PORT, () => {
  console.log(`╔════════════════════════════════════════════╗`);
  console.log(`║  wacrm-baileys-relay running on :${PORT}      ║`);
  console.log(`║  Auth: ${RELAY_AUTH_TOKEN ? 'TOKEN required' : '⚠ NO TOKEN (dev)'}${' '.repeat(Math.max(0,20-(RELAY_AUTH_TOKEN?14:18)))}║`);
  console.log(`╚════════════════════════════════════════════╝`);
});

// Start Baileys + worker
(async () => {
  console.log('[Boot] Starting Baileys...');
  await baileys.start();
  console.log('[Boot] Starting broadcast worker...');
  await startWorker();
})();

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('[SIGTERM] shutting down...');
  process.exit(0);
});
process.on('uncaughtException', (e) => {
  console.error('[uncaughtException]', e);
});
process.on('unhandledRejection', (e) => {
  console.error('[unhandledRejection]', e);
});
