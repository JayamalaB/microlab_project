const db = require('../config/db');

// ─── List addresses for the authenticated member ──────────────────────────────
exports.getAddresses = async (req, res) => {
  try {
    const patientId = req.user.id;
    const [rows] = await db.query(
      `SELECT address_id, label, full_address, pincode, city, lat, lng, is_default
       FROM ip_member_addresses
       WHERE patient_id = ?
       ORDER BY is_default DESC, created_at ASC`,
      [patientId]
    );
    res.json({ success: true, addresses: rows });
  } catch (err) {
    console.error('[getAddresses]', err);
    res.status(500).json({ success: false, message: 'Failed to fetch addresses' });
  }
};

// ─── Add a new address ────────────────────────────────────────────────────────
exports.addAddress = async (req, res) => {
  try {
    const patientId = req.user.id;
    const { label = 'Home', full_address, pincode, city, lat, lng, is_default = false } = req.body;
    if (!full_address || full_address.trim() === '') {
      return res.status(400).json({ success: false, message: 'Address is required' });
    }
    if (is_default) {
      await db.query(
        'UPDATE ip_member_addresses SET is_default = 0 WHERE patient_id = ?',
        [patientId]
      );
    }
    const [result] = await db.query(
      `INSERT INTO ip_member_addresses (patient_id, label, full_address, pincode, city, lat, lng, is_default)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [patientId, label, full_address.trim(), pincode || null, city || null, lat || null, lng || null, is_default ? 1 : 0]
    );
    res.json({ success: true, addressId: result.insertId });
  } catch (err) {
    console.error('[addAddress]', err);
    res.status(500).json({ success: false, message: 'Failed to add address' });
  }
};

// ─── Update an address ────────────────────────────────────────────────────────
exports.updateAddress = async (req, res) => {
  try {
    const patientId = req.user.id;
    const { id } = req.params;
    const { label, full_address, pincode, city, lat, lng, is_default } = req.body;
    // Verify ownership
    const [check] = await db.query(
      'SELECT address_id FROM ip_member_addresses WHERE address_id = ? AND patient_id = ?',
      [id, patientId]
    );
    if (check.length === 0) {
      return res.status(404).json({ success: false, message: 'Address not found' });
    }
    if (is_default) {
      await db.query(
        'UPDATE ip_member_addresses SET is_default = 0 WHERE patient_id = ?',
        [patientId]
      );
    }
    await db.query(
      `UPDATE ip_member_addresses
       SET label = ?, full_address = ?, pincode = ?, city = ?, lat = ?, lng = ?, is_default = ?
       WHERE address_id = ? AND patient_id = ?`,
      [label || 'Home', full_address.trim(), pincode || null, city || null, lat || null, lng || null, is_default ? 1 : 0, id, patientId]
    );
    res.json({ success: true });
  } catch (err) {
    console.error('[updateAddress]', err);
    res.status(500).json({ success: false, message: 'Failed to update address' });
  }
};

// ─── Delete an address ────────────────────────────────────────────────────────
exports.deleteAddress = async (req, res) => {
  try {
    const patientId = req.user.id;
    const { id } = req.params;
    const [result] = await db.query(
      'DELETE FROM ip_member_addresses WHERE address_id = ? AND patient_id = ?',
      [id, patientId]
    );
    if (result.affectedRows === 0) {
      return res.status(404).json({ success: false, message: 'Address not found' });
    }
    res.json({ success: true });
  } catch (err) {
    console.error('[deleteAddress]', err);
    res.status(500).json({ success: false, message: 'Failed to delete address' });
  }
};

// ─── Set an address as default ────────────────────────────────────────────────
exports.setDefault = async (req, res) => {
  try {
    const patientId = req.user.id;
    const { id } = req.params;
    await db.query(
      'UPDATE ip_member_addresses SET is_default = 0 WHERE patient_id = ?',
      [patientId]
    );
    const [result] = await db.query(
      'UPDATE ip_member_addresses SET is_default = 1 WHERE address_id = ? AND patient_id = ?',
      [id, patientId]
    );
    if (result.affectedRows === 0) {
      return res.status(404).json({ success: false, message: 'Address not found' });
    }
    res.json({ success: true });
  } catch (err) {
    console.error('[setDefault]', err);
    res.status(500).json({ success: false, message: 'Failed to set default address' });
  }
};
