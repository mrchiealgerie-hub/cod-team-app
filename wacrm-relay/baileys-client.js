// baileys-client.js — manages the WhatsApp connection lifecycle
import pkg from '@whiskeysockets/baileys';
const { default: makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion, makeCacheableSignalKeyStore } = pkg;
import { Boom } from '@hapi/boom';
import pino from 'pino';
import qrcode from 'qrcode';
import { EventEmitter } from 'events';
import fs from 'fs';
import path from 'path';

const AUTH_DIR = process.env.AUTH_DIR || './auth_info_baileys';
const logger = pino({ level: process.env.LOG_LEVEL || 'warn' });

if (!fs.existsSync(AUTH_DIR)) fs.mkdirSync(AUTH_DIR, { recursive: true });

class BaileysClient extends EventEmitter {
  constructor() {
    super();
    this.sock = null;
    this.state = 'disconnected';
    this.qrCode = '';
    this.qrCodeDataUrl = '';
    this.phoneNumber = '';
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 5;
  }

  setState(state, extra = {}) {
    this.state = state;
    this.emit('state', { state, ...extra });
    console.log(`[Baileys] State: ${state}`, extra.error ? `(${extra.error})` : '');
  }

  async start() {
    try {
      const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
      const { version } = await fetchLatestBaileysVersion();
      console.log(`[Baileys] Using WA version ${version.join('.')}`);

      this.sock = makeWASocket({
        version,
        auth: {
          creds: state.creds,
          keys: makeCacheableSignalKeyStore(state.keys, logger),
        },
        printQRInTerminal: false,
        logger,
        browser: ['COD Team CRM', 'Chrome', '1.0.0'],
        syncFullHistory: false,
        markOnlineOnConnect: false,
        generateHighQualityLinkPreview: false,
      });

      this.sock.ev.on('creds.update', saveCreds);

      this.sock.ev.on('connection.update', async (update) => {
        const { connection, lastDisconnect, qr } = update;

        if (qr) {
          this.qrCode = qr;
          try {
            this.qrCodeDataUrl = await qrcode.toDataURL(qr, { width: 320, margin: 1 });
          } catch (e) {
            console.error('[Baileys] QR encode error:', e.message);
          }
          this.setState('qr');
        }

        if (connection === 'open') {
          this.qrCode = '';
          this.qrCodeDataUrl = '';
          this.phoneNumber = this.sock.user?.id?.split(':')[0]?.split('@')[0] || '';
          this.reconnectAttempts = 0;
          this.setState('connected', { phone: this.phoneNumber });
        }

        if (connection === 'close') {
          const boomError = lastDisconnect?.error;
          const statusCode = boomError instanceof Boom ? boomError.output?.statusCode : 0;
          const shouldReconnect = statusCode !== DisconnectReason.loggedOut;
          this.setState('disconnected', { error: boomError?.message || 'unknown' });

          if (shouldReconnect && this.reconnectAttempts < this.maxReconnectAttempts) {
            this.reconnectAttempts++;
            const delay = Math.min(30000, 2000 * Math.pow(2, this.reconnectAttempts));
            console.log(`[Baileys] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts}/${this.maxReconnectAttempts})`);
            setTimeout(() => this.start(), delay);
          } else if (statusCode === DisconnectReason.loggedOut) {
            console.warn('[Baileys] Logged out — clearing auth state. Re-scan QR to reconnect.');
            this.clearAuth();
            setTimeout(() => this.start(), 3000);
          }
        }
      });

      this.sock.ev.on('messages.upsert', (m) => {
        this.emit('messages', m);
      });

      return true;
    } catch (e) {
      console.error('[Baileys] Start error:', e.message);
      this.setState('error', { error: e.message });
      return false;
    }
  }

  clearAuth() {
    try {
      fs.rmSync(AUTH_DIR, { recursive: true, force: true });
      fs.mkdirSync(AUTH_DIR, { recursive: true });
    } catch (e) {
      console.error('[Baileys] Clear auth error:', e.message);
    }
  }

  async logout() {
    if (this.sock) {
      try {
        await this.sock.logout();
      } catch (e) {
        console.error('[Baileys] Logout error:', e.message);
      }
    }
    this.clearAuth();
  }

  isConnected() {
    return this.state === 'connected';
  }

  /**
   * Send a text message to a phone number.
   * @param {string} rawPhone - phone number, any format
   * @param {string} text - message body
   * @returns {Promise<{success:boolean, error?:string, messageId?:string}>}
   */
  async sendText(rawPhone, text) {
    if (!this.isConnected()) {
      return { success: false, error: 'Not connected to WhatsApp' };
    }
    if (!text || !text.trim()) {
      return { success: false, error: 'Empty message' };
    }

    const cleaned = this.cleanPhone(rawPhone);
    if (!cleaned) {
      return { success: false, error: 'Invalid phone number' };
    }

    const jid = `${cleaned}@s.whatsapp.net`;

    try {
      // Verify number exists on WhatsApp (cheap check)
      const [check] = await this.sock.onWhatsApp(cleaned);
      if (!check || !check.exists) {
        return { success: false, error: 'Number not registered on WhatsApp' };
      }

      const res = await this.sock.sendMessage(jid, { text });
      return { success: true, messageId: res?.key?.id || '' };
    } catch (e) {
      return { success: false, error: e.message || 'send failed' };
    }
  }

  cleanPhone(phone) {
    if (!phone) return '';
    let p = String(phone).replace(/[^0-9]/g, '');
    if (p.startsWith('00')) p = p.slice(2);
    // Algerian local format 0XXX → 213XXX
    if (p.startsWith('0') && p.length >= 10) p = '213' + p.slice(1);
    if (p.length < 8) return '';
    return p;
  }
}

export const baileys = new BaileysClient();
