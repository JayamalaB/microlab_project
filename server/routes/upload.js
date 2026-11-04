const express  = require('express');
const multer   = require('multer');
const path     = require('path');
const fs       = require('fs');
const auth     = require('../middleware/auth');

const router = express.Router();

const UPLOAD_DIR = path.join(__dirname, '..', 'uploads');
if (!fs.existsSync(UPLOAD_DIR)) fs.mkdirSync(UPLOAD_DIR, { recursive: true });

const storage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, UPLOAD_DIR),
  filename:    (_req, file, cb) => {
    const ext  = path.extname(file.originalname) || '.jpg';
    const name = `patient_${Date.now()}_${Math.random().toString(36).slice(2, 8)}${ext}`;
    cb(null, name);
  },
});

// /uploads is served publicly, so only photos and PDFs are stored: an uploaded
// .html or .js file would run as a page on this domain.
const ALLOWED_TYPES = new Set(['.jpg', '.jpeg', '.png', '.webp', '.heic', '.pdf']);

const upload = multer({
  storage,
  limits: { fileSize: 5 * 1024 * 1024 }, // 5 MB
  fileFilter: (_req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase();
    if (ext === '' || ALLOWED_TYPES.has(ext)) return cb(null, true);
    cb(new Error('Only photos and PDF files can be uploaded'));
  },
});

router.post('/', auth, upload.single('photo'), (req, res) => {
  if (!req.file) {
    return res.status(422).json({ success: false, message: 'No file uploaded' });
  }
  const baseUrl = process.env.BASE_URL || `http://localhost:${process.env.PORT || 3000}`;
  const url = `${baseUrl}/uploads/${req.file.filename}`;
  res.json({ success: true, url });
});

// Catch multer errors (size limit, wrong file type, write failures)
// eslint-disable-next-line no-unused-vars
router.use((err, _req, res, _next) => {
  console.error('upload error:', err.message);
  res.status(422).json({ success: false, message: err.message || 'Upload failed' });
});

module.exports = router;
