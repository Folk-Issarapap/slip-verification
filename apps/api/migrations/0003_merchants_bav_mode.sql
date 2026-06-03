ALTER TABLE merchants
  ADD COLUMN bav_mode TEXT NOT NULL DEFAULT 'required'
  CHECK (bav_mode IN ('required', 'background', 'skip'));
