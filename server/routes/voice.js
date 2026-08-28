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
    // Tamil TTS auto-narrates a raw "H:MM" digit pattern as "<number>
    // மணிக்கு" on its own — with the written "மணி" that already follows it
    // (e.g. "9:00 மணி") also being read, the result is "9 மணிக்கு மணி".
    // Times in this app are always on the hour, so dropping the ":00"
    // leaves no colon-time pattern for that auto-narration to trigger on —
    // just a plain "9" followed by the already-correct written "மணி",
    // read once as "ஒன்பது மணி".
    .replace(/(\d{1,2}):00(?=\s*மணி)/g, '$1')
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

// POST audio buffer to Sarvam STT with an explicit language_code (or
// 'unknown' for full auto-detect). Returns { transcript, languageCode } or
// { error } on failure.
function _sttSarvamCall(buffer, languageCode) {
  const apiKey = process.env.SARVAM_API_KEY;
  if (!apiKey) {
    console.error('[Sarvam STT] SARVAM_API_KEY is not set in environment');
    return Promise.resolve({ error: 'SARVAM_API_KEY not configured on server' });
  }

  const form = new FormData();
  form.append('file',          buffer, { filename: 'audio.wav', contentType: 'audio/wav' });
  form.append('language_code', languageCode);
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

// Public entry point: auto-detects the spoken language first. Trusts that
// transcript outright when it's en-IN or ta-IN — those are the only two
// languages this app supports, and re-decoding audio the model already
// transcribed correctly (via a second, language-forced call) was found to
// make results *worse*, not better: a forced language_code makes Saaras
// commit to that language's phonetics/vocabulary even when unsure, and it
// tends to fall back to a short generic guess (e.g. "சரி") rather than the
// actual words spoken. The retry is reserved for the one real failure case
// observed — full auto-detect mis-decoding Tamil speech as some unrelated
// third language entirely (e.g. Gujarati script, not just a wrong label) —
// so it only re-runs (forcing ta-IN) when the detected language is neither
// of the two this app understands. Returns { transcript, languageCode } or
// { error }.
async function sttSarvam(buffer) {
  const auto = await _sttSarvamCall(buffer, 'unknown');
  if (auto.error) return auto;
  if (auto.languageCode === 'en-IN' || auto.languageCode === 'ta-IN') return auto;

  const forced = await _sttSarvamCall(buffer, 'ta-IN');
  if (forced.error) return forced;
  return { transcript: forced.transcript, languageCode: 'ta-IN' };
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

// Static, pre-verified Tamil labels for known "Label: Value" bullet lines.
// Translating a short label word in isolation is unreliable — Sarvam has
// been observed picking an unrelated meaning depending on what follows it
// (e.g. "Mobile: N/A" → "ஊடறுதல்: இல்லை" instead of "கைபேசி", with the
// SAME word translating correctly elsewhere in the same response as soon
// as a real number follows it). Extend this map as new mistranslated
// labels turn up; anything not listed here still falls through to the
// normal per-line API translation below.
const TAMIL_LABELS = {
  'mobile':         'கைபேசி',
  'working hours':  'வேலை நேரம்',
};

// Sarvam's Translate API only accepts one string per call and doesn't
// preserve line breaks/bullet layout when given a multi-line blob (it
// reflows everything into a single paragraph — observed on translated
// branch/booking listings, which formatBranchInfo()/formatBookingDetails()
// etc. build with \n and "   • " bullets). Splitting here and rejoining
// with the ORIGINAL line breaks afterward keeps that structure intact,
// since the API is only ever asked to translate one line at a time and
// never has a chance to reflow anything. Blank lines are preserved as-is
// (not sent to the API) — the visual paragraph spacing survives untouched.
// Calls run in parallel so wall-clock latency stays close to a single call.
async function translateMultiline(text, sourceLanguageCode, targetLanguageCode) {
  if (!text || !text.trim()) return { text: '' };

  const lines = text.split('\n');
  const results = await Promise.all(
    lines.map((line) => line.trim()
      ? _translateLine(line, sourceLanguageCode, targetLanguageCode)
      : Promise.resolve({ text: '' }))
  );

  const failed = results.find(r => r.error);
  if (failed) return { error: failed.error };

  return { text: results.map(r => r.text).join('\n') };
}

// One "   • Label: Value" bullet line — uses the static TAMIL_LABELS
// dictionary for the label when known (skipping the API for it entirely),
// and skips translating values that don't need it (phone numbers, "N/A").
// Falls back to translating the whole line via the API when the label
// isn't recognized, or the target language isn't Tamil.
async function _translateLine(line, sourceLanguageCode, targetLanguageCode) {
  // Branch/place names are proper nouns — never translate them. Sarvam has
  // been observed translating the brand name "MicroLab" literally into
  // "சிறிய ஆய்வகம்" ("small laboratory") instead of preserving it.
  // formatBranchInfo() always marks a name line with a leading 🏥.
  if (targetLanguageCode === 'ta-IN' && line.trim().startsWith('🏥')) {
    return { text: line };
  }

  const match = targetLanguageCode === 'ta-IN'
    ? line.match(/^(\s*(?:•\s*)?)([A-Za-z][A-Za-z ]*?):\s*(.*)$/)
    : null;
  const knownLabel = match ? TAMIL_LABELS[match[2].trim().toLowerCase()] : null;

  if (match && knownLabel) {
    const [, prefix, , rawValue] = match;
    const value = rawValue.trim();

    if (!value || value.toUpperCase() === 'N/A') {
      return { text: `${prefix}${knownLabel}: இல்லை` };
    }
    if (/^[\d\s+\-()]+$/.test(value)) {
      // Phone numbers etc. — nothing to translate, and translating digits
      // risks the model "reading" them into words.
      return { text: `${prefix}${knownLabel}: ${value}` };
    }
    const translatedValue = await translateText(value, sourceLanguageCode, targetLanguageCode);
    if (translatedValue.error) return translatedValue;
    return { text: `${prefix}${knownLabel}: ${translatedValue.text}` };
  }

  return translateText(line, sourceLanguageCode, targetLanguageCode);
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
module.exports.translateMultiline = translateMultiline;
