const express    = require('express');
const router     = express.Router();
const { handleWebhook } = require('../controllers/razorpayWebhookController');

// Raw body required for HMAC-SHA256 signature verification
router.post('/', express.raw({ type: 'application/json' }), handleWebhook);

module.exports = router;
