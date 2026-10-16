CREATE TABLE IF NOT EXISTS ip_report_status_log (
  id             INT(11)      NOT NULL AUTO_INCREMENT,
  bill_id        VARCHAR(100) DEFAULT NULL,
  report_status  VARCHAR(50)  DEFAULT NULL,
  ip_address     VARCHAR(45)  DEFAULT NULL,
  auth_result    VARCHAR(30)  NOT NULL,
  http_status    SMALLINT     NOT NULL,
  created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_bill_id     (bill_id),
  KEY idx_auth_result (auth_result),
  KEY idx_created_at  (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
