const express = require('express');
const router = express.Router();
const auth = require('../middleware/auth');
const addressController = require('../controllers/addressController');

router.get('/',           auth, addressController.getAddresses);
router.post('/',          auth, addressController.addAddress);
router.put('/:id',        auth, addressController.updateAddress);
router.delete('/:id',     auth, addressController.deleteAddress);
router.put('/:id/default', auth, addressController.setDefault);

module.exports = router;
