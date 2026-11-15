# Posting passes to Discord

The station can post each pass that made images to a Discord channel: a short message (satellite,
time, maximum elevation, direction, day or night, station name, a link to the capture's page) with
the pass's best images and its sky track.

```
🛰️ METEOR-M2 3 · 15/11/2026 10:42 (08:42 UTC)
Max elevation 67° · northbound · day pass · 15 min
My Meteor station
http://my-station.example.org:8080/captures/listImages?pass_id=123
[MSA image] [AVHRR 221 image] [sky track]
```

It is off until you give it a webhook.

## Set it up

1. In Discord, open the channel's settings: **Edit Channel → Integrations → Webhooks → New
   Webhook**. Name it (for example "Meteor station"), pick the channel and click **Copy Webhook
   URL**. You need the right to manage webhooks on that server.
2. On the Pi, run the install. An upgrade asks the new question once; otherwise answer `n` to
   "Keep these settings?":

   ```bash
   cd ~/raspberry-lrpt && ./install_and_upgrade.sh
   ```

   Paste the URL at **Discord webhook URL to post passes to**, then give the web panel's address
   as people outside your network reach it (for example `http://my-station.example.org:8080`) for
   the link, or `-` for no link.
3. Check it:

   ```bash
   ./scripts/push_discord.sh --test
   ```

   A test message appears in the channel. The next pass with images is posted by itself.

**Keep the webhook URL private.** Anyone who has it can post to your channel. The install keeps it
in `config/settings.local.yml` (not in git, readable by you only) and `~/.raspberry-lrpt.conf`
(mode 600), and the log never shows it. If it leaks, delete the webhook in Discord and make a new
one. To stop posting, run the install again and answer `-` to the webhook question.

## Post earlier captures

New passes are posted by themselves. To post captures that are already on the site:

```bash
./scripts/discord_post.sh -l                 # the newest 20 captures with their numbers
./scripts/discord_post.sh 123 124            # these captures
./scripts/discord_post.sh --last 3           # the newest 3
./scripts/discord_post.sh --today            # every capture of today
./scripts/discord_post.sh --day 2026-11-14   # every capture of that day
```

It lists what it will post and asks first (`-y` skips the question). Captures go out oldest first,
one every few seconds. A capture whose images were already deleted is skipped.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `discord_webhook` | empty | The webhook URL (asked by the install, kept in `settings.local.yml`); empty = don't post |
| `discord_site_url` | empty | The web panel's public address, for the link to the capture (empty = no link) |
| `discord_images` | 2 | How many images to post (0–9), picked in the order of the day or night thumbnail list, then the day or night image list |
| `discord_sky_track` | true | Also post the sky-track graph |

Change the last two in `config/settings.yml` and run the install.

## Details

- Images bigger than Discord's 10 MB limit are posted at a smaller size; the files on the station
  stay as they are.
- The post runs in the background after the capture is saved, so a slow or failed post never holds
  up the station. If Discord says to slow down, it waits and tries once more. The result is in the
  log (`Posted to Discord …` or `Discord post failed …`).
- Re-processed passes (`reprocess_meteor.sh`) are not posted by themselves; post them with
  `discord_post.sh`.
