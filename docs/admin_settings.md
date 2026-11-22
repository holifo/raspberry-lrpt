# Admin > Settings

> **Not security-reviewed. Use it at your own risk.** The page changes the station's settings, and
> the admin login travels with every request, so use it over HTTPS ([TLS](tls_webserver.md)) if the
> web panel can be reached from the internet, and keep `lock_admin_page: true`.

`/admin/settings` shows every setting of `config/settings.yml` on one page, in ten sections:
Station, Receiver, Meteor, ISS (extra), Images, Image label, Maps, Web panel, Discord and
Housekeeping. Each section folds its rarely used settings (test scripts, SDR indexes, frequency
offsets, ...) under **Advanced**. The search box finds a setting by its name, key or help text.

## Saving

**Save** sends only the settings you changed. The station checks each against
`config/settings_schema.json` (ranges, choices, formats); if one is wrong, nothing is saved and
it is marked in red with what you typed. Otherwise:

- the values go to `config/settings.local.yml`, exactly as `scripts/tools/settings.py set` would,
  so updates and the install keep them;
- `~/.raspberry-lrpt.conf` and the web panel's `Config.php` are written again from the same
  templates the install uses (`scripts/tools/render_config.py`), so most settings work from the
  next pass or page;
- settings marked **reschedules** (which satellites, minimum elevations, days ahead, ISS dates,
  ...) schedule the passes again in the background (`schedule.sh -t -x`);
- saving is refused while a pass is being recorded;
- the Live log notes which settings changed.

## Settings that need the install

Some settings change things only the install can: the receiver's drivers (`receiver_type`,
`sdrplay_licence_accepted`), nginx (`web_port`, `enable_tls`, ...), the clock (`ntp_server`),
predict's and SatDump's location (`latitude`, `longitude`, `altitude`), SatDump's map labels
(`map_capitals`), the RAM disk (`storage`) and `disable_wifi_power_mgmt`. They are marked
**needs the install**. They are saved, but the station keeps using the installed values until you run

```bash
cd ~/raspberry-lrpt && ./install_and_upgrade.sh
```

Until then the page lists them as **waiting for the install** (the installed values wait in
`config/.settings.pending.yml`, which the install deletes).

## Never on the page

The admin password and the Discord webhook are shown only as "Set" / "Not set", and the admin user
name and `lock_admin_page` are shown but can't be changed here: a mistake there could lock you out
or open the admin pages to everyone. Change them over SSH: the install's setup questions ask for
them, or edit `config/settings.local.yml` and run the install.

## How it runs

The web server (www-data) may run exactly two commands as the station user, through the sudo rule
in `/etc/sudoers.d/030_www-data-switch`: `scripts/settings_web.sh show` and
`scripts/settings_web.sh apply` (the changes come as JSON on standard input). The page only
accepts posts from its own site (Origin / Referer check). Values with line breaks or control
characters are refused, and the templates quote every text value, so text such as a station name
with an apostrophe can't break the shell or PHP settings files.
