const express = require('express');
const router = express.Router();
const auth = require('../middleware/auth');
const patientsController = require('../controllers/patientsController');

router.get('/',        auth, patientsController.getPatients);
router.post('/',       auth, patientsController.savePatient);
router.put('/:id',     auth, patientsController.updatePatient);
router.delete('/:id',  auth, patientsController.deletePatient);

module.exports = router;
