const express = require('express');
const router  = express.Router();
const { getLetterhead, proxyImage } = require('../controllers/letterheadController');

// GET /api/letterhead
router.get('/', getLetterhead);

// GET /api/letterhead/image/:filename  — proxies uploaded images from the CI3 server
router.get('/image/:filename', proxyImage);

module.exports = router;
