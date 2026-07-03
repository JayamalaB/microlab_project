const express    = require('express');
const router     = express.Router();
const auth       = require('../middleware/auth');
const controller = require('../controllers/prescriptionController');

router.post('/', auth, controller.savePrescription);

module.exports = router;
