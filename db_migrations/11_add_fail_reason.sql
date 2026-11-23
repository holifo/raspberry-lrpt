-- why a recorded pass gave no images (v1.40.0): no_signal, no_lock, too_short, receiver, no_record
ALTER TABLE predict_passes ADD COLUMN fail_reason text;
ALTER TABLE predict_passes ADD COLUMN fail_detail text;
