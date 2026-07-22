const express = require('express');
const router = express.Router();
const authController = require('../controllers/authController');
const auth = require('../middleware/auth');

router.post('/send-otp', authController.sendOtp);
router.post('/verify-otp', authController.verifyOtp);
router.post('/fcm-token', auth, authController.registerFcmToken);
router.post('/logout', auth, authController.logout);
router.get('/test-sms', authController.testSms);

module.exports = router;
