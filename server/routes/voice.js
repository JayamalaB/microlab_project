const express  = require('express');
const router   = express.Router();
const multer   = require('multer');
const https    = require('https');
const FormData = require('form-data');

const SARVAM_STT_URL  = 'api.sarvam.ai';
const SARVAM_TTS_PATH = '/text-to-speech';
const SARVAM_STT_PATH = '/speech-to-text';
const SARVAM_TRANSLATE_PATH = '/translate';

// bulbul:v2 was deprecated by Sarvam (400 invalid_request_err) — v3 also
// renames some request fields and drops pitch/loudness entirely (tone now
// comes from speaker choice instead). 'anushka' doesn't exist as a v3
// speaker; 'shubh' is v3's documented default.
const TTS_SPEAKER      = 'shubh';
const TTS_MODEL        = 'bulbul:v3';
const TTS_DEFAULT_LANG = 'en-IN';
const TTS_TAMIL_LANG   = 'ta-IN';
const TTS_SAMPLE_RATE  = 22050;
const TTS_PACE         = 0.92;

const TAMIL_RE = /[஀-௿]/;

// Prepend N ms of PCM silence to a WAV base64 string.
// Android's AudioTrack needs time to initialise; the silence plays inaudibly
// while the hardware opens, so the first real word is never clipped.
function prependWavSilence(base64Audio, silenceMs = 250) {
  try {
    const buf = Buffer.from(base64Audio, 'base64');
    if (buf.length < 44) return base64Audio;               // guard: malformed WAV
    const sampleRate    = buf.readUInt32LE(24);
    const numChannels   = buf.readUInt16LE(22);
    const bitsPerSample = buf.readUInt16LE(34);
    const silenceBytes  = Math.floor(sampleRate * silenceMs / 1000)
                          * numChannels * Math.ceil(bitsPerSample / 8);
    const silence = Buffer.alloc(silenceBytes, 0);         // zero = silence for PCM
    const header  = Buffer.from(buf.subarray(0, 44));      // clone header
    const data    = buf.subarray(44);
    const newDataLen = data.length + silenceBytes;
    header.writeUInt32LE(newDataLen + 36, 4);              // RIFF chunk size
    header.writeUInt32LE(newDataLen,      40);             // data chunk size
    return Buffer.concat([header, silence, data]).toString('base64');
  } catch (_) { return base64Audio; }                      // pass through on error
}

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 10 * 1024 * 1024 } });

function detectLang(text) {
  return TAMIL_RE.test(text) ? TTS_TAMIL_LANG : TTS_DEFAULT_LANG;
}

function cleanText(text) {
  return text
    .replace(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/gu, '')
    .replace(/\*\*(.*?)\*\*/gs, '$1')   // strip bold markers, keep text
    .replace(/\*(.*?)\*/gs, '$1')        // strip italic markers, keep text
    .replace(/[•·▶⏸▸►←→↑↓]/g, '')
    .replace(/^\d+\.\s+/gm, '')
    // Pronunciation-friendly substitutions for Sarvam TTS (en-IN)
    .replace(/1800-XXX-XXXX/g, 'our toll-free number')
    .replace(/X{3,}/g, '')
    .replace(/₹/g, 'rupees ')
    .replace(/[—–]/g, ', ')
    .replace(/@/g, ' at ')
    .replace(/^\s*[.:;]\s+/gm, '')      // remove stray leading punctuation
    .replace(/\s{2,}/g, ' ')
    .trim();
}

// POST to Sarvam TTS; returns { audio: base64string } or { error: string } on failure
function ttsSarvam(text) {
  const apiKey = process.env.SARVAM_API_KEY;
  if (!apiKey) {
    console.error('[Sarvam TTS] SARVAM_API_KEY is not set in environment');
    return Promise.resolve({ error: 'SARVAM_API_KEY not configured on server' });
  }

  const lang = detectLang(text);
  const body = JSON.stringify({
    text:                 text,
    language_code:        lang,
    speaker:              TTS_SPEAKER,
    pace:                 TTS_PACE,
    speech_sample_rate:   TTS_SAMPLE_RATE,
    model:                TTS_MODEL,
  });

  return new Promise((resolve) => {
    const request = https.request(
      {
        hostname: 'api.sarvam.ai',
        path:     SARVAM_TTS_PATH,
        method:   'POST',
        headers: {
          'api-subscription-key': apiKey,
          'Content-Type':         'application/json',
          'Content-Length':       Buffer.byteLength(body),
        },
      },
      (response) => {
        const parts = [];
        response.on('data', c => parts.push(c));
        response.on('end', () => {
          const raw = Buffer.concat(parts).toString('utf8');
          if (response.statusCode === 200) {
            try {
              const audios = JSON.parse(raw).audios || [];
              if (audios.length) {
                console.log(`[Sarvam TTS] ${text.length}ch (${lang}) → ok`);
                return resolve({ audio: audios[0] });
              }
            } catch (e) {
              console.error('[Sarvam TTS] JSON parse error:', e.message);
            }
            console.error('[Sarvam TTS] empty audios[] in response:', raw.slice(0, 200));
          } else {
            console.error(`[Sarvam TTS] ${response.statusCode}: ${raw.slice(0, 300)}`);
          }
          resolve({ error: `Sarvam ${response.statusCode}: ${raw.slice(0, 120)}` });
        });
      }
    );
    request.on('error', (e) => {
      console.error('[Sarvam TTS] request error:', e.message);
      resolve({ error: e.message });
    });
    request.setTimeout(15000, () => {
      request.destroy();
      resolve({ error: 'Sarvam TTS request timed out' });
    });
    request.write(body);
    request.end();
  });
}

// POST audio buffer to Sarvam STT; returns { transcript } or { error } on failure
function sttSarvam(buffer) {
  const apiKey = process.env.SARVAM_API_KEY;
  if (!apiKey) {
    console.error('[Sarvam STT] SARVAM_API_KEY is not set in environment');
    return Promise.resolve({ error: 'SARVAM_API_KEY not configured on server' });
  }

  const form = new FormData();
  form.append('file',          buffer, { filename: 'audio.wav', contentType: 'audio/wav' });
  // 'unknown' asks Saaras to auto-detect the spoken language instead of
  // assuming English — the response's own language_code field then tells us
  // what was actually detected (see below), driving Tamil translation.
  form.append('language_code', 'unknown');
  form.append('model',         'saaras:v3');

  return new Promise((resolve) => {
    const request = https.request(
      {
        hostname: 'api.sarvam.ai',
        path:     SARVAM_STT_PATH,
        method:   'POST',
        headers: {
          ...form.getHeaders(),
          'api-subscription-key': apiKey,
        },
      },
      (response) => {
        const parts = [];
        response.on('data', c => parts.push(c));
        response.on('end', () => {
          const raw = Buffer.concat(parts).toString('utf8');
          if (response.statusCode === 200) {
            try {
              const parsed = JSON.parse(raw);
              const t = (parsed.transcript || '').trim();
              const detectedLang = parsed.language_code || 'en-IN';
              console.log(`[Sarvam STT] transcript (${detectedLang}): ${JSON.stringify(t)}`);
              return resolve({ transcript: t, languageCode: detectedLang });
            } catch (e) {
              console.error('[Sarvam STT] JSON parse error:', e.message);
            }
          } else {
            console.error(`[Sarvam STT] ${response.statusCode}: ${raw.slice(0, 300)}`);
          }
          resolve({ error: `Sarvam STT ${response.statusCode}: ${raw.slice(0, 120)}` });
        });
      }
    );
    request.on('error', (e) => {
      console.error('[Sarvam STT] request error:', e.message);
      resolve({ error: e.message });
    });
    request.setTimeout(20000, () => {
      request.destroy();
      resolve({ error: 'Sarvam STT request timed out' });
    });
    form.pipe(request);
  });
}

// POST to Sarvam Translate; returns { text: translatedString } or { error } on failure.
// Used only at the /api/chat/ask boundary (chat.js) to bridge a Tamil voice
// question into the English-only intent/DB pipeline and back — llmRetriever.js
// and llmService.js never see or produce anything but English.
function translateText(text, sourceLanguageCode, targetLanguageCode) {
  const apiKey = process.env.SARVAM_API_KEY;
  if (!apiKey) {
    console.error('[Sarvam Translate] SARVAM_API_KEY is not set in environment');
    return Promise.resolve({ error: 'SARVAM_API_KEY not configured on server' });
  }
  if (!text || !text.trim()) return Promise.resolve({ text: '' });

  const body = JSON.stringify({
    input:                 text,
    source_language_code:  sourceLanguageCode,
    target_language_code:  targetLanguageCode,
  });

  return new Promise((resolve) => {
    const request = https.request(
      {
        hostname: 'api.sarvam.ai',
        path:     SARVAM_TRANSLATE_PATH,
        method:   'POST',
        headers: {
          'api-subscription-key': apiKey,
          'Content-Type':         'application/json',
          'Content-Length':       Buffer.byteLength(body),
        },
      },
      (response) => {
        const parts = [];
        response.on('data', c => parts.push(c));
        response.on('end', () => {
          const raw = Buffer.concat(parts).toString('utf8');
          if (response.statusCode === 200) {
            try {
              const translated = JSON.parse(raw).translated_text || '';
              return resolve({ text: translated });
            } catch (e) {
              console.error('[Sarvam Translate] JSON parse error:', e.message);
            }
          } else {
            console.error(`[Sarvam Translate] ${response.statusCode}: ${raw.slice(0, 300)}`);
          }
          resolve({ error: `Sarvam Translate ${response.statusCode}: ${raw.slice(0, 120)}` });
        });
      }
    );
    request.on('error', (e) => {
      console.error('[Sarvam Translate] request error:', e.message);
      resolve({ error: e.message });
    });
    request.setTimeout(15000, () => {
      request.destroy();
      resolve({ error: 'Sarvam Translate request timed out' });
    });
    request.write(body);
    request.end();
  });
}

// ── Routes ────────────────────────────────────────────────────────────────────

// POST /transcribe  — Sarvam Saaras v3 STT
router.post('/transcribe', upload.single('audio'), async (req, res) => {
  if (!req.file) {
    return res.status(400).json({ success: false, error: 'No audio file' });
  }
  try {
    const result = await sttSarvam(req.file.buffer);
    if (result.error) {
      return res.status(500).json({ success: false, error: result.error });
    }
    if (!result.transcript) {
      return res.status(400).json({
        success: false, transcript: '',
        error: 'No speech detected. Please try again.',
      });
    }
    res.json({ success: true, transcript: result.transcript, language_code: result.languageCode });
  } catch (e) {
    console.error('[STT]', e.message);
    res.status(500).json({ success: false, error: e.message });
  }
});

// POST /speak-stream  — chunked NDJSON streaming TTS
router.post('/speak-stream', async (req, res) => {
  const chunks  = req.body.chunks || [];
  const cleaned = chunks.map(c => cleanText(c).slice(0, 500)).filter(c => c);

  if (!cleaned.length) {
    return res.status(400).json({ success: false, error: 'No chunks provided' });
  }

  res.setHeader('Content-Type',     'application/x-ndjson');
  res.setHeader('X-Accel-Buffering','no');
  res.setHeader('Cache-Control',    'no-cache');

  for (let idx = 0; idx < cleaned.length; idx++) {
    const result = await ttsSarvam(cleaned[idx]);
    if (result.audio) {
      res.write(JSON.stringify({ idx, audio: prependWavSilence(result.audio), done: false }) + '\n');
    } else {
      console.warn(`[TTS-STREAM] chunk ${idx} failed: ${result.error}`);
    }
  }
  res.write(JSON.stringify({ idx: -1, done: true }) + '\n');
  res.end();
});

// POST /speak-multi  — batch TTS (used for cache replay)
router.post('/speak-multi', async (req, res) => {
  const chunks  = req.body.chunks || [];
  const cleaned = chunks.map(c => cleanText(c).slice(0, 500)).filter(c => c);

  if (!cleaned.length) {
    return res.status(400).json({ success: false, error: 'No chunks provided' });
  }

  const results = await Promise.all(cleaned.map(t => ttsSarvam(t)));
  const audios  = results.filter(r => r.audio).map(r => prependWavSilence(r.audio));

  if (!audios.length) {
    const firstError = results.find(r => r.error)?.error || 'TTS failed';
    console.error('[speak-multi] all chunks failed. First error:', firstError);
    return res.status(500).json({ success: false, error: firstError });
  }
  res.json({ success: true, audios });
});

// POST /speak  — single-chunk TTS (backwards compat)
router.post('/speak', async (req, res) => {
  const text = (req.body.text || '').trim();
  if (!text) {
    return res.status(400).json({ success: false, error: 'No text provided' });
  }
  const result = await ttsSarvam(cleanText(text).slice(0, 500));
  if (!result.audio) {
    return res.status(500).json({ success: false, error: result.error || 'TTS failed' });
  }
  res.json({ success: true, audio_base64: result.audio });
});

module.exports = router;
module.exports.translateText = translateText;
