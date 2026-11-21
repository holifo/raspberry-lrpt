#!/usr/bin/env python3

import sqlite3
from datetime import datetime
import os
import sys

def delete_job(target_datetime_str):
    print("Overlapping pass at:", target_datetime_str)

    # Convert the target datetime string to a datetime object
    target_datetime = datetime.strptime(target_datetime_str, "%Y-%m-%d %H:%M:%S")
    # Set the seconds to 0 for target_datetime
    target_datetime = target_datetime.replace(second=0)

    # Get the list of at jobs
    atq_output = os.popen("atq").read().strip()
    atq_lines = atq_output.split("\n")

    # Loop through the at jobs and find the ones scheduled around the target datetime
    for line in atq_lines:
        if not line.strip():
            continue
        job_id, job_datetime = line.split(None, 1)

        # Extract the full date and time string
        job_datetime = " ".join(job_datetime.split()[:5])
        job_datetime_obj = datetime.strptime(job_datetime, "%a %b %d %H:%M:%S %Y")
        # Set the seconds to 0 for job_datetime
        job_datetime_obj = job_datetime_obj.replace(second=0)

        if job_datetime_obj == target_datetime:
            print(f"Removing job with ID: {job_id}")
            os.system("atrm {}".format(job_id))

if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        print("Usage: {} <database_path> <prefer_meteor: true|false> [iss_own_sdr: true|false]".format(sys.argv[0]))
        sys.exit(1)

    database_path = os.path.expanduser(sys.argv[1])
    prefer_meteor = sys.argv[2].lower() == "true"
    conn = sqlite3.connect(database_path)
    cursor = conn.cursor()

    cursor.execute("SELECT sat_name, pass_start, pass_end, max_elev, is_active, pass_start_azimuth, direction, azimuth_at_max, at_job_id FROM predict_passes ORDER BY pass_start")
    passes = cursor.fetchall()
    # the ISS on its own RTL-SDR (iss_sdr_device) records alongside the Meteors: its passes
    # don't compete with theirs, so they are left out of the comparison
    if len(sys.argv) == 4 and sys.argv[3].lower() == "true":
        passes = [p for p in passes if p[0] != "ISS"]

    def loser(a, b):
        """Of two overlapping passes (a starts first), the one to drop: Meteor wins over any other
        satellite when prefer_meteor, otherwise the lower maximum elevation loses."""
        meteor_a, meteor_b = "METEOR" in a[0], "METEOR" in b[0]
        if prefer_meteor and meteor_a != meteor_b:
            return b if meteor_a else a
        return b if a[3] > b[3] else a

    # each pass is compared with the last pass that was kept, not just its neighbour: with an ISS
    # pass between two overlapping Meteor passes, dropping the ISS pass used to leave both Meteors
    kept = None
    for p in passes:
        if kept is not None and kept[1] < p[1] < kept[2]:
            drop = loser(kept, p)
            if drop[8] != 0:
                delete_job(datetime.fromtimestamp(drop[1]).strftime("%Y-%m-%d %H:%M:%S"))
                cursor.execute("DELETE FROM predict_passes WHERE pass_start = ?", (drop[1],))
                conn.commit()
                if drop is kept:
                    kept = p
                continue
        kept = p

    conn.close()
    print("Finished comparing and deleting rows based on max_elev and sat_name")
