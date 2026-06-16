// broadcast-worker.js — polls Supabase for queued broadcasts and sends them via Baileys
import { createClient } from '@supabase/supabase-js';
import { baileys } from './baileys-client.js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const BOT_EMAIL = process.env.SUPABASE_BOT_EMAIL;
const BOT_PASSWORD = process.env.SUPABASE_BOT_PASSWORD;

const SEND_DELAY_MIN_MS = parseInt(process.env.SEND_DELAY_MIN_MS || '8000', 10);
const SEND_DELAY_MAX_MS = parseInt(process.env.SEND_DELAY_MAX_MS || '15000', 10);
const MAX_PER_HOUR = parseInt(process.env.MAX_PER_HOUR || '120', 10);
const MAX_PER_DAY = parseInt(process.env.MAX_PER_DAY || '500', 10);
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || '8000', 10);

let supabase = null;
let supabaseAuthed = false;
let pollTimer = null;
let isProcessing = false;

const sentTimestamps = []; // sliding window of timestamps for rate limiting

function logInfo(...args) { console.log('[Worker]', ...args); }
function logWarn(...args) { console.warn('[Worker]', ...args); }
function logErr(...args) { console.error('[Worker]', ...args); }

async function initSupabase() {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    logErr('Missing SUPABASE_URL or SUPABASE_ANON_KEY env vars');
    return false;
  }
  supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: true },
  });

  if (BOT_EMAIL && BOT_PASSWORD) {
    try {
      const { data, error } = await supabase.auth.signInWithPassword({ email: BOT_EMAIL, password: BOT_PASSWORD });
      if (error) {
        logErr('Bot login failed:', error.message);
        return false;
      }
      supabaseAuthed = true;
      logInfo(`Bot logged in as ${data.user?.email}`);
    } catch (e) {
      logErr('Bot login exception:', e.message);
      return false;
    }
  } else {
    logWarn('SUPABASE_BOT_EMAIL/PASSWORD not set — worker may fail on RLS-protected writes');
  }
  return true;
}

function withinRateLimit() {
  const now = Date.now();
  while (sentTimestamps.length && sentTimestamps[0] < now - 3600000) sentTimestamps.shift();
  if (sentTimestamps.length >= MAX_PER_HOUR) {
    return { ok: false, reason: `hourly limit (${MAX_PER_HOUR}) reached, next slot in ${Math.ceil((sentTimestamps[0] + 3600000 - now) / 60000)} min` };
  }
  return { ok: true };
}

async function getDailyCount() {
  if (!supabase) return 0;
  const { data } = await supabase.from('wa_relay_status').select('daily_sent_count,daily_sent_reset_at').eq('id', 'singleton').maybeSingle();
  if (!data) return 0;
  const last = new Date(data.daily_sent_reset_at);
  const now = new Date();
  if (last.toISOString().slice(0, 10) !== now.toISOString().slice(0, 10)) {
    await supabase.from('wa_relay_status').update({ daily_sent_count: 0, daily_sent_reset_at: now.toISOString() }).eq('id', 'singleton');
    return 0;
  }
  return data.daily_sent_count || 0;
}

async function bumpDailyCount(n = 1) {
  if (!supabase) return;
  const cur = await getDailyCount();
  await supabase.from('wa_relay_status').update({ daily_sent_count: cur + n, updated_at: new Date().toISOString() }).eq('id', 'singleton');
}

async function bumpStatusCounters(sent = 0, failed = 0) {
  if (!supabase) return;
  const { data } = await supabase.from('wa_relay_status').select('total_sent,total_failed').eq('id', 'singleton').maybeSingle();
  await supabase.from('wa_relay_status').update({
    total_sent: (data?.total_sent || 0) + sent,
    total_failed: (data?.total_failed || 0) + failed,
    last_heartbeat: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq('id', 'singleton');
}

async function updateRelayStatus() {
  if (!supabase) return;
  await supabase.from('wa_relay_status').update({
    connection_state: baileys.state,
    qr_code: baileys.qrCodeDataUrl || '',
    phone_number: baileys.phoneNumber || '',
    last_heartbeat: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq('id', 'singleton');
}

async function getNextRecipient() {
  if (!supabase) return null;
  // Find a running baileys-mode campaign with a queued recipient
  const { data: camps, error: cerr } = await supabase
    .from('wa_campaigns')
    .select('id,name,status,send_mode')
    .eq('status', 'running')
    .eq('send_mode', 'baileys')
    .order('created_at', { ascending: true })
    .limit(5);
  if (cerr) {
    logErr('Fetch campaigns:', cerr.message);
    return null;
  }
  if (!camps || !camps.length) return null;

  for (const camp of camps) {
    const { data: recs, error: rerr } = await supabase
      .from('wa_campaign_recipients')
      .select('*')
      .eq('campaign_id', camp.id)
      .eq('status', 'queued')
      .order('position_in_queue', { ascending: true })
      .limit(1);
    if (rerr) {
      logErr('Fetch recipients:', rerr.message);
      continue;
    }
    if (recs && recs.length) return { campaign: camp, recipient: recs[0] };
  }
  return null;
}

async function markRecipient(recId, status, errorMsg = '') {
  if (!supabase) return;
  const update = { status };
  if (status === 'sent') update.sent_at = new Date().toISOString();
  if (status === 'failed') {
    update.error_msg = errorMsg.slice(0, 500);
    update.last_error_at = new Date().toISOString();
  }
  await supabase.from('wa_campaign_recipients').update(update).eq('id', recId);
}

async function bumpCampaign(campId, field) {
  if (!supabase) return;
  const { data } = await supabase.from('wa_campaigns').select('sent_count,failed_count,total_recipients').eq('id', campId).maybeSingle();
  if (!data) return;
  const update = {};
  if (field === 'sent') update.sent_count = (data.sent_count || 0) + 1;
  if (field === 'failed') update.failed_count = (data.failed_count || 0) + 1;
  const newSent = update.sent_count != null ? update.sent_count : data.sent_count;
  const newFailed = update.failed_count != null ? update.failed_count : data.failed_count;
  if ((newSent + newFailed) >= data.total_recipients) {
    update.status = 'completed';
    update.completed_at = new Date().toISOString();
  }
  await supabase.from('wa_campaigns').update(update).eq('id', campId);
}

async function processOne() {
  if (isProcessing) return;
  if (!baileys.isConnected()) return;

  // rate limit check
  const rl = withinRateLimit();
  if (!rl.ok) {
    logWarn(rl.reason);
    return;
  }
  const dailyCount = await getDailyCount();
  if (dailyCount >= MAX_PER_DAY) {
    logWarn(`Daily limit (${MAX_PER_DAY}) reached, sleeping until midnight UTC.`);
    return;
  }

  isProcessing = true;
  try {
    const next = await getNextRecipient();
    if (!next) {
      return;
    }
    const { campaign, recipient } = next;
    logInfo(`Sending to ${recipient.phone} (campaign ${campaign.name})`);

    const result = await baileys.sendText(recipient.phone, recipient.rendered_message);

    if (result.success) {
      await markRecipient(recipient.id, 'sent');
      await bumpCampaign(campaign.id, 'sent');
      await bumpDailyCount(1);
      await bumpStatusCounters(1, 0);
      sentTimestamps.push(Date.now());
      logInfo(`✓ Sent to ${recipient.phone}`);
    } else {
      await markRecipient(recipient.id, 'failed', result.error);
      await bumpCampaign(campaign.id, 'failed');
      await bumpStatusCounters(0, 1);
      logWarn(`✗ Failed to ${recipient.phone}: ${result.error}`);
    }

    // Random delay before next send
    const delay = SEND_DELAY_MIN_MS + Math.floor(Math.random() * (SEND_DELAY_MAX_MS - SEND_DELAY_MIN_MS));
    await new Promise(r => setTimeout(r, delay));
  } catch (e) {
    logErr('processOne error:', e.message);
  } finally {
    isProcessing = false;
  }
}

async function tick() {
  try {
    await updateRelayStatus();
    if (baileys.isConnected()) {
      await processOne();
    }
  } catch (e) {
    logErr('tick error:', e.message);
  }
}

export async function startWorker() {
  if (!(await initSupabase())) {
    logErr('Worker cannot start without Supabase.');
    return;
  }
  logInfo(`Starting worker — poll interval ${POLL_INTERVAL_MS}ms, ${MAX_PER_HOUR}/h, ${MAX_PER_DAY}/d`);
  // initial status push
  await updateRelayStatus();
  pollTimer = setInterval(tick, POLL_INTERVAL_MS);
}

export function stopWorker() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}
