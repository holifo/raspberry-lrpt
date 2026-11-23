-- the pass's signal numbers, from the spectrogram recorder (v1.40.0): quality 0-100 = share of
-- the time above the minimum elevation that the decoder was locked; empty for older passes
ALTER TABLE decoded_passes ADD COLUMN quality integer;
ALTER TABLE decoded_passes ADD COLUMN snr_peak real;
ALTER TABLE decoded_passes ADD COLUMN snr_avg real;
ALTER TABLE decoded_passes ADD COLUMN locked_s integer;
