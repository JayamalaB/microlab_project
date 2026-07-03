const db   = require('../config/db');
const fs   = require('fs');
const path = require('path');
const { fetchPatientData } = require('../utils/secureId');

const LOG_FILE = path.join(__dirname, '..', 'logs', 'patients.log');
function writeLog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  fs.appendFileSync(LOG_FILE, `[${ist}] ${msg}\n`, 'utf8');
}

function parseDob(str) {
  if (!str) return null;
  const parts = str.split('-');
  if (parts.length !== 3) return null;
  if (parts[0].length <= 2) return `${parts[2]}-${parts[1]}-${parts[0]}`;
  return str;
}

// Aliases ip_patients columns to the field names PatientModel.fromJson() expects
const PATIENT_SELECT = `
  patient_id, patient_id_ref,
  patient_name      AS name,
  patient_mobile    AS mobile,
  patient_gender    AS gender,
  patient_city      AS location,
  patient_address   AS address,
  patient_email     AS email,
  patient_dob       AS date_of_birth,
  patient_age       AS age,
  patient_relation  AS relation,
  health_conditions AS health_condition,
  patient_photo     AS photo
`;

exports.getPatients = async (req, res) => {
  try {
    const { user_id, client_id, mobile, user_type } = req.user;

    if (user_type === 'patient_user') {
      try {
        writeLog(`[getPatients] start sync for user_id=${user_id} mobile=${mobile}`);
        const patientRes = await fetchPatientData(mobile, 'customer');
        const rawPatients = (patientRes && Array.isArray(patientRes.patient))
          ? patientRes.patient : [];
        writeLog(`[getPatients] fetchPatientData returned ${rawPatients.length} patient(s)`);

        const selfP = rawPatients.find(p => p.relation === 'Self') || rawPatients[0];
        const createdBy = selfP?.name || mobile;

        for (const p of rawPatients) {
          const dob = parseDob(p.date_of_birth);
          writeLog(`[getPatients] processing patient_id_ref=${p.patient_id} name=${p.name}`);
          const [existing] = await db.query(
            'SELECT patient_id FROM ip_patients WHERE patient_id_ref = ? AND client_id = ?',
            [p.patient_id, client_id]
          );
          if (existing.length > 0) {
            await db.query(
              `UPDATE ip_patients
               SET patient_name=?, patient_gender=?, patient_city=?, patient_address=?,
                   patient_email=?, patient_dob=?, patient_age=?, patient_relation=?,
                   health_conditions=?, patient_photo=?, updated_by=?, updated_at=NOW()
               WHERE patient_id_ref=? AND client_id=?`,
              [p.name, p.gender, p.location, p.address, p.email || null,
               dob, p.age || null, p.relation || null, p.health_condition || null, p.photo || null,
               createdBy, p.patient_id, client_id]
            );
          } else {
            await db.query(
              `INSERT INTO ip_patients
                 (patient_id_ref, client_id, patient_name, patient_mobile, patient_gender,
                  patient_city, patient_address, patient_email, patient_dob, patient_age,
                  patient_relation, health_conditions, patient_photo, created_by)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
              [p.patient_id, client_id, p.name, mobile, p.gender, p.location, p.address,
               p.email || null, dob, p.age || null, p.relation || null,
               p.health_condition || null, p.photo || null, createdBy]
            );
          }
        }

        if (rawPatients.length > 0) {
          const selfP = rawPatients.find(p => p.relation === 'Self') || rawPatients[0];
          if (selfP && selfP.name) {
            await db.query(
              'UPDATE ip_users SET user_name=?, user_email=?, user_date_modified=NOW() WHERE user_id=?',
              [selfP.name, selfP.email || null, user_id]
            );
            await db.query(
              'UPDATE ip_clients SET client_name=?, client_date_modified=NOW() WHERE client_id=?',
              [selfP.name, client_id]
            );
            writeLog(`[getPatients] client_name updated to "${selfP.name}" for client_id=${client_id}`);
          }
        }
        writeLog(`[getPatients] sync complete`);
      } catch (syncErr) {
        writeLog(`[getPatients] SYNC ERROR: ${syncErr.message}`);
        console.error('getPatients sync error:', syncErr.message);
      }
    }

    const [rows] = await db.query(
      `SELECT ${PATIENT_SELECT}
       FROM ip_patients
       WHERE client_id = ? AND deleted_at IS NULL
       ORDER BY (patient_relation = 'Self') DESC, patient_id ASC`,
      [client_id]
    );
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error('getPatients error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

exports.savePatient = async (req, res) => {
  try {
    const { user_id, client_id } = req.user;
    const {
      name, mobile, gender, location, address,
      email, date_of_birth, age, relation, health_condition, photo_url,
    } = req.body;

    if (!name || !mobile || !gender || !location || !address) {
      return res.status(422).json({ success: false, message: 'Required fields missing' });
    }

    const [[userRow]] = await db.query('SELECT user_name FROM ip_users WHERE user_id = ?', [user_id]);
    const createdBy = relation === 'Self' ? name : (userRow?.user_name || mobile);

    if (relation === 'Self') {
      await db.query(
        'UPDATE ip_users SET user_name=?, user_email=?, user_date_modified=NOW() WHERE user_id=?',
        [name, email || null, user_id]
      );
      await db.query(
        'UPDATE ip_clients SET client_name=?, client_date_modified=NOW() WHERE client_id=?',
        [name, client_id]
      );
    }

    const [result] = await db.query(
      `INSERT INTO ip_patients
         (client_id, patient_name, patient_mobile, patient_gender, patient_city,
          patient_address, patient_email, patient_dob, patient_age, patient_relation,
          health_conditions, patient_photo, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [client_id, name, mobile, gender, location, address,
       email || null, date_of_birth || null, age || null,
       relation || null, health_condition || null, photo_url || null, createdBy]
    );

    const [rows] = await db.query(
      `SELECT ${PATIENT_SELECT} FROM ip_patients WHERE patient_id = ?`,
      [result.insertId]
    );
    res.json({ success: true, data: rows[0] });
  } catch (err) {
    console.error('savePatient error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

exports.updatePatient = async (req, res) => {
  try {
    const { user_id, client_id } = req.user;
    const { id } = req.params;
    const {
      name, mobile, gender, location, address,
      email, date_of_birth, age, relation, health_condition, photo_url,
    } = req.body;

    if (!name || !mobile || !gender || !location || !address) {
      return res.status(422).json({ success: false, message: 'Required fields missing' });
    }

    const [[userRow]] = await db.query('SELECT user_name FROM ip_users WHERE user_id = ?', [user_id]);
    const updatedBy = relation === 'Self' ? name : (userRow?.user_name || mobile);

    if (relation === 'Self') {
      await db.query(
        'UPDATE ip_users SET user_name=?, user_email=?, user_date_modified=NOW() WHERE user_id=?',
        [name, email || null, user_id]
      );
      await db.query(
        'UPDATE ip_clients SET client_name=?, client_date_modified=NOW() WHERE client_id=?',
        [name, client_id]
      );
    }

    const fields = [name, mobile, gender, location, address,
      email || null, date_of_birth || null, age || null,
      relation || null, health_condition || null, photo_url || null, updatedBy, updatedBy];

    let [result] = await db.query(
      `UPDATE ip_patients
       SET patient_name=?, patient_mobile=?, patient_gender=?, patient_city=?, patient_address=?,
           patient_email=?, patient_dob=?, patient_age=?, patient_relation=?,
           health_conditions=?, patient_photo=?, updated_by=?,
           created_by=COALESCE(NULLIF(created_by,''), ?), updated_at=NOW()
       WHERE patient_id=? AND client_id=?`,
      [...fields, id, client_id]
    );

    if (result.affectedRows === 0) {
      [result] = await db.query(
        `UPDATE ip_patients
         SET patient_name=?, patient_mobile=?, patient_gender=?, patient_city=?, patient_address=?,
             patient_email=?, patient_dob=?, patient_age=?, patient_relation=?,
             health_conditions=?, patient_photo=?, updated_by=?,
             created_by=COALESCE(NULLIF(created_by,''), ?), updated_at=NOW()
         WHERE patient_id_ref=? AND client_id=?`,
        [...fields, id, client_id]
      );
    }

    if (result.affectedRows === 0) {
      return res.status(404).json({ success: false, message: 'Patient not found' });
    }

    const [rows] = await db.query(
      `SELECT ${PATIENT_SELECT} FROM ip_patients
       WHERE (patient_id=? OR patient_id_ref=?) AND client_id=? LIMIT 1`,
      [id, id, client_id]
    );
    res.json({ success: true, data: rows[0] });
  } catch (err) {
    console.error('updatePatient error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

exports.deletePatient = async (req, res) => {
  try {
    const { client_id } = req.user;
    const { id } = req.params;

    const [result] = await db.query(
      `UPDATE ip_patients SET deleted_at = NOW()
       WHERE patient_id = ? AND client_id = ? AND deleted_at IS NULL`,
      [id, client_id]
    );

    if (result.affectedRows === 0) {
      return res.status(404).json({ success: false, message: 'Patient not found' });
    }

    res.json({ success: true, message: 'Patient removed' });
  } catch (err) {
    console.error('deletePatient error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
