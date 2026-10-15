const db     = require('../config/db');
const https  = require('https');
const http   = require('http');

const ADMIN_URL = (process.env.ADMIN_PANEL_URL || '').replace(/\/$/, '');
const BASE_URL  = (process.env.BASE_URL        || '').replace(/\/$/, '');

function imageUrl(filename) {
  if (!filename || filename === 'default') return null;
  // Proxy through Node.js to avoid CORS issues on the CI3 server
  return `${BASE_URL}/api/letterhead/image/${encodeURIComponent(filename)}`;
}

async function getLetterhead(req, res) {
  try {
    const [rows] = await db.query(
      'SELECT * FROM ip_report_letterhead WHERE letterhead_id = 1 LIMIT 1'
    );
    if (!rows.length) return res.status(404).json({ success: false, message: 'No letterhead configured' });

    const r = rows[0];
    res.json({
      success:          true,
      header_mode:      r.header_mode,
      title:            r.title,
      title_color:      r.title_color,
      subtitle:         r.subtitle,
      subtitle_color:   r.subtitle_color,
      info_line:        r.info_line,
      address_line:     r.address_line,
      bar_color:        r.bar_color,
      show_top_bar:     r.show_top_bar === 1,
      show_bottom_bar:  r.show_bottom_bar === 1,
      footer_company:   r.footer_company,
      footer_signatory: r.footer_signatory,
      show_signatory:   r.show_signatory === 1,
      logo_url:         imageUrl(r.logo_file),
      badge_url:        imageUrl(r.badge_file),
      banner_url:       imageUrl(r.banner_file),
    });
  } catch (e) {
    console.error('[letterhead]', e.message);
    res.status(500).json({ success: false, message: e.message });
  }
}

async function proxyImage(req, res) {
  const filename = req.params.filename;
  if (!filename || filename.includes('..') || filename.includes('/')) {
    return res.status(400).end();
  }
  const url = `${ADMIN_URL}/uploads/letterhead/${encodeURIComponent(filename)}`;
  const client = url.startsWith('https') ? https : http;
  client.get(url, (upstream) => {
    if (upstream.statusCode !== 200) {
      return res.status(upstream.statusCode || 502).end();
    }
    res.setHeader('Content-Type', upstream.headers['content-type'] || 'image/png');
    res.setHeader('Cache-Control', 'public, max-age=86400');
    upstream.pipe(res);
  }).on('error', () => res.status(502).end());
}

module.exports = { getLetterhead, proxyImage };
