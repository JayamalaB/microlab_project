const express    = require('express');
const router     = express.Router();
const auth       = require('../middleware/auth');
const controller = require('../controllers/prescriptionController');

router.post('/',                   auth, controller.savePrescription);
router.get('/:bookingId',          auth, controller.getByBooking);
router.patch('/:docId/verify',     auth, controller.verifyDoc);
router.delete('/:docId',           auth, controller.deleteDoc);

module.exports = router;
