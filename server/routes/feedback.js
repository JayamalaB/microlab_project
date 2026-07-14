const express    = require('express');
const router     = express.Router();
const feedback   = require('../controllers/feedbackController');
const auth       = require('../middleware/auth');

// POST /api/feedback — submit feedback for a completed booking
router.post('/', auth, feedback.submitFeedback);

// GET /api/feedback/booking/:bookingId — check if feedback exists
router.get('/booking/:bookingId', auth, feedback.getFeedbackByBooking);

module.exports = router;
