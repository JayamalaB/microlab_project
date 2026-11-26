CREATE TABLE IF NOT EXISTS ip_member_addresses (
  address_id   INT          NOT NULL AUTO_INCREMENT,
  patient_id   INT          NOT NULL,
  label        VARCHAR(50)  NOT NULL DEFAULT 'Home',
  full_address TEXT         NOT NULL,
  pincode      VARCHAR(10)  DEFAULT NULL,
  city         VARCHAR(100) DEFAULT NULL,
  lat          DECIMAL(10,8) DEFAULT NULL,
  lng          DECIMAL(11,8) DEFAULT NULL,
  is_default   TINYINT(1)   NOT NULL DEFAULT 0,
  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (address_id),
  KEY idx_patient (patient_id),
  CONSTRAINT fk_addr_patient
    FOREIGN KEY (patient_id) REFERENCES ip_patients (patient_id)
    ON DELETE CASCADE
);
