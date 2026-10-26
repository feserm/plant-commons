-- PLANT-COMMONS: bootstrap the first admin with ORCID:INVITE_ONLY (docs/plant-commons/configuration.md section 3).
-- Replace the ORCID iD and the name, then run it ONCE as the database owner rsd or a superuser (see README.md, "First admin").
-- Tested against a throwaway rsd/database container in Phase 2 (not against the cluster; nothing here runs it).
WITH new_account AS (
  INSERT INTO account DEFAULT VALUES RETURNING id
), new_login AS (
  INSERT INTO login_for_account (account, provider, sub, name)
  SELECT id, 'orcid', '0000-0000-0000-0000', 'Your Name'   -- <-- your ORCID iD and name
  FROM new_account
  RETURNING account
)
INSERT INTO admin_account (account_id) SELECT account FROM new_login;
