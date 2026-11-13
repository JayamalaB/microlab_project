-- Which branches a technician's slot is offered at.
--
-- When saving availability, a technician who works at several branches picks
-- the branch(es) for each slot, per day. The slot itself stays ONE row in
-- ip_technician_slots with one capacity, so when it is offered at several
-- branches, whichever branch's customer books a time first takes it and it is
-- gone for the others.
--
-- A slot counts for branch X when this table has (tech_slot_id, X). Slots
-- saved before this table existed have no rows here and keep counting for
-- their own ip_technician_slots.branch_id (the technician's own branch).
--
-- Run BEFORE restarting the server — the customer slot list, branch selection
-- and dispatch read it. Safe to run more than once.
CREATE TABLE IF NOT EXISTS ip_technician_slot_branches (
  tech_slot_id  INT(11)  NOT NULL,
  branch_id     INT(11)  NOT NULL,
  created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (tech_slot_id, branch_id),
  KEY idx_slot_branches_branch (branch_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
