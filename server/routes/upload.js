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

const upload = multer({
  storage,
  limits: { fileSize: 5 * 1024 * 1024 }, // 5 MB
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
