# Emits the remaining .dc.html artboards.
#
# Each screen's markup is authored ONCE against CSS custom properties, then
# emitted twice — into a .light and a .dark phone frame — so the two themes can
# never drift apart. Edit SCREENS below and re-run; do not hand-edit the
# generated .dc.html files.
#
#   python build_screens.py

import io

STYLE = """  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap">
  <style>
    * { box-sizing: border-box; }
    body { margin:0; background:#EEF0F4; font-family:'Inter',system-ui,sans-serif; -webkit-font-smoothing:antialiased; }
    a { color:#0037B7; } a:hover { color:#002E9B; }
    .light { --bg:#F8F9FA; --surface:#FFFFFF; --text:#141414; --muted:#737373; --outline:#DDE2E7;
             --brand:#0037B7; --brandc:#E3EDFA; --field:#F9F9F9; --green:#00B14F; --red:#FF1717;
             --amber:#FFB038; --tab:#F1F3F8; --tint:rgba(20,20,20,.04);
             --greent:rgba(0,177,79,.12); --redt:rgba(255,23,23,.10); --ambert:rgba(255,176,56,.14); }
    .dark  { --bg:#181818; --surface:#1A1A1A; --text:#FFFFFF; --muted:#8A8A8A; --outline:#333333;
             --brand:#4A6CF7; --brandc:#1D242F; --field:#1E1E1E; --green:#00B14F; --red:#FF6B6B;
             --amber:#FFB038; --tab:#24242B; --tint:rgba(255,255,255,.05);
             --greent:rgba(0,177,79,.16); --redt:rgba(255,107,107,.14); --ambert:rgba(255,176,56,.16); }
    .phone { width:390px; height:844px; border-radius:26px; overflow:hidden; display:flex;
             flex-direction:column; background:var(--bg); color:var(--text); border:1px solid var(--outline); }
    /* The real OS status bar paints here. Nothing is drawn into it. */
    .safe { height:44px; flex:none; background:var(--surface); }
    .cap { font-size:12px; font-weight:600; letter-spacing:.08em; text-transform:uppercase; color:#8A8F98; }
    .bar { height:56px; flex:none; display:flex; align-items:center; gap:12px; padding:0 16px; background:var(--surface); }
    .bar h1 { margin:0; font-size:18px; font-weight:600; letter-spacing:-0.01em; }
    .scroll { flex:1; overflow:hidden; padding:16px; display:flex; flex-direction:column; gap:14px; }
    .card { background:var(--surface); border:1px solid var(--outline); border-radius:12px; }
    .btn { height:50px; border-radius:8px; display:flex; align-items:center; justify-content:center;
           gap:8px; font-size:15px; font-weight:600; }
    .fill { background:var(--brand); color:#FFFFFF; }
    .out { color:var(--brand); border:1px solid var(--outline); }
    .num { font-variant-numeric:tabular-nums; }
    .ico { width:38px; height:38px; border-radius:10px; display:flex; align-items:center; justify-content:center; flex:none; }
    .row { display:flex; align-items:center; gap:12px; padding:12px 14px; }
    .sep { height:1px; background:var(--outline); }
    .pill { height:26px; border-radius:8px; display:inline-flex; align-items:center; gap:6px;
            padding:0 9px; font-size:12px; font-weight:600; }
    .chip { height:34px; border-radius:8px; display:inline-flex; align-items:center; padding:0 14px;
            font-size:13.5px; font-weight:500; color:var(--muted); background:var(--tab); }
    .chip.on { background:var(--brand); color:#FFFFFF; font-weight:600; }
    .sect { font-size:12px; font-weight:600; letter-spacing:.06em; text-transform:uppercase; color:var(--muted); }
  </style>"""

PAGE = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
{style}
</helmet>

<div style="display: flex; gap: 48px; padding: 40px; align-items: flex-start;">

  <div style="display: flex; flex-direction: column; gap: 12px;">
    <div class="cap">Light</div>
    <div class="phone light">
{body}
    </div>
  </div>

  <div style="display: flex; flex-direction: column; gap: 12px;">
    <div class="cap">Dark</div>
    <div class="phone dark">
{body}
    </div>
  </div>

</div>
</x-dc>
<script data-dc-script data-props='{{}}'>
class Component extends DCLogic {{
  renderVals() {{
    return {{}};
  }}
}}
</script>
</body>
</html>
"""

# --- icons ------------------------------------------------------------------
def ic(path, size=20, color="currentColor", width="1.8"):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="{width}" stroke-linecap="round" '
            f'stroke-linejoin="round" style="color: {color};">{path}</svg>')

P_PHONE = '<path d="M5 4h3l2 5-2.5 1.5a12 12 0 0 0 5 5L14 13l5 2v3a2 2 0 0 1-2.2 2A17 17 0 0 1 3 6.2 2 2 0 0 1 5 4Z"/>'
P_IN = '<path d="M19 5 11 13"/><path d="M11 7v6h6"/>'
P_OUT = '<path d="M12 12 20 4"/><path d="M20 10V4h-6"/>'
P_MISS = '<path d="M19 5 13 11"/><path d="M13 5h6v6"/>'
P_CHECK = '<path d="m5 13 4 4L19 7"/>'
P_SYNC = '<path d="M21 12a9 9 0 1 1-2.6-6.4"/><path d="M21 3v6h-6"/>'
P_UP = '<path d="M12 19V5"/><path d="m5 12 7-7 7 7"/>'
P_CLOCK = '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'
P_ALERT = '<path d="M12 4 2 20h20L12 4Z"/><path d="M12 10v4"/><path d="M12 17.5v.01"/>'
P_SHIELD = '<path d="M12 3 4 6v6c0 5 3.4 8.4 8 9 4.6-.6 8-4 8-9V6l-8-3Z"/>'
P_BACK = '<path d="M15 5 8 12l7 7"/>'
P_CHEV = '<path d="m9 5 7 7-7 7"/>'
P_USER = '<circle cx="12" cy="8" r="3.5"/><path d="M5 20a7 7 0 0 1 14 0"/>'
P_CONTACTS = '<rect x="4" y="3" width="16" height="18" rx="2"/><circle cx="12" cy="10" r="2.5"/><path d="M8 17a4 4 0 0 1 8 0"/>'
P_BELL = '<path d="M18 9a6 6 0 1 0-12 0c0 5-2 6-2 6h16s-2-1-2-6Z"/><path d="M10.5 19a1.8 1.8 0 0 0 3 0"/>'
P_BATTERY = '<rect x="2" y="8" width="16" height="9" rx="2"/><path d="M21 11v3"/><path d="M6 11v3"/>'
P_SIM = '<path d="M6 3h8l5 5v13H6Z"/><rect x="9" y="12" width="7" height="6" rx="1"/>'
P_MIC_OFF = '<path d="M3 3l18 18"/><path d="M9 9v3a3 3 0 0 0 4.6 2.5"/><path d="M15 10V6a3 3 0 0 0-5.7-1.3"/><path d="M18 11a6 6 0 0 1-.8 3"/><path d="M6 11a6 6 0 0 0 9 5.2"/><path d="M12 19v3"/>'
P_DEVICE = '<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M11 18.5h2"/>'
P_LOCK = '<rect x="4" y="10" width="16" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>'
P_DB = '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>'
P_WIFI = '<path d="M2.5 9a15 15 0 0 1 19 0"/><path d="M6 12.5a10 10 0 0 1 12 0"/><path d="M9.5 16a5 5 0 0 1 5 0"/><path d="M12 19.5v.01"/>'
P_PLAY = '<path d="M8 5.5v13l11-6.5Z"/>'
P_INFO = '<circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 8v.01"/>'
P_REVIEW = '<path d="M12 4 2 20h20L12 4Z"/><path d="M12 10v4"/><path d="M12 17.5v.01"/>'
P_OUTLINK = '<path d="M14 4h6v6"/><path d="M20 4 11 13"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>'

# --- shared fragments -------------------------------------------------------
def navbar(active):
    items = [("Home", '<path d="M4 10 12 4l8 6v9a1 1 0 0 1-1 1h-4v-6H9v6H5a1 1 0 0 1-1-1Z"/>'),
             ("Calls", P_PHONE),
             ("Sync", P_SYNC),
             ("Settings", '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.2 5.2l1.4 1.4M17.4 17.4l1.4 1.4M18.8 5.2l-1.4 1.4M6.6 17.4l-1.4 1.4"/>')]
    out = ['<div style="height:64px; flex:none; display:flex; background:var(--surface); border-top:1px solid var(--outline);">']
    for name, path in items:
        color = "var(--brand)" if name == active else "var(--muted)"
        out.append(
            f'<div style="flex:1; display:flex; flex-direction:column; align-items:center; '
            f'justify-content:center; gap:4px; font-size:12px; font-weight:500; color:{color};">'
            f'{ic(path, 22)}<span>{name}</span></div>')
    out.append('</div>')
    return "".join(out)


def appbar(title, subtitle=None, back=False, trailing=""):
    lead = f'<div style="width:32px; height:32px; display:flex; align-items:center;">{ic(P_BACK, 22)}</div>' if back else ""
    sub = f'<span style="font-size:12px; color:var(--muted);">{subtitle}</span>' if subtitle else ""
    return (f'<div class="bar">{lead}'
            f'<div style="flex:1; display:flex; flex-direction:column; gap:1px;">'
            f'<h1>{title}</h1>{sub}</div>{trailing}</div>')


# --- screens ----------------------------------------------------------------
SCREENS = {}

# ---------------------------------------------------------------- Permissions
def perm_card(icon, title, why, state):
    if state == "granted":
        badge = (f'<div class="pill" style="background:var(--greent); color:var(--green);">'
                 f'{ic(P_CHECK, 14, width="2.6")}Enabled</div>')
    elif state == "action":
        badge = ('<div class="pill" style="background:var(--brand); color:#FFFFFF; height:34px; padding:0 14px;">Enable</div>')
    else:
        badge = ('<div class="pill" style="background:var(--tab); color:var(--muted); height:34px; padding:0 14px;">Open settings</div>')
    tint = "var(--greent)" if state == "granted" else "var(--brandc)"
    color = "var(--green)" if state == "granted" else "var(--brand)"
    return (f'<div class="card" style="padding:14px; display:flex; gap:12px;">'
            f'<div class="ico" style="background:{tint};">{ic(icon, 20, color)}</div>'
            f'<div style="flex:1; min-width:0; display:flex; flex-direction:column; gap:4px;">'
            f'<div style="font-size:15px; font-weight:600;">{title}</div>'
            f'<div style="font-size:13px; line-height:1.5; color:var(--muted);">{why}</div>'
            f'<div style="margin-top:6px;">{badge}</div>'
            f'</div></div>')

SCREENS["Permissions"] = f"""      <div class="safe"></div>
      {appbar("Set up tracking", "Step 2 of 3")}
      <div class="scroll">

        <div style="display:flex; align-items:center; gap:10px;">
          <div style="flex:1; height:6px; border-radius:3px; background:var(--tint); overflow:hidden;">
            <div style="width:50%; height:100%; background:var(--brand);"></div>
          </div>
          <span class="num" style="font-size:12px; font-weight:600; color:var(--muted);">2 of 4</span>
        </div>

        <p style="margin:0; font-size:14px; line-height:1.55; color:var(--muted);">
          Each permission is requested only when it is needed, and only with the reason shown.
          You can decline any of them &mdash; the app keeps working with less detail.
        </p>

        {perm_card(P_PHONE, "Phone &amp; call log", "Detects when a call starts and ends, and reads its final duration and status. Without this nothing is tracked.", "granted")}
        {perm_card(P_CONTACTS, "Contacts", "Shows a name instead of a bare number. Declining keeps the number; only the name is missing.", "granted")}
        {perm_card(P_BELL, "Notifications", "Tells you when an upload fails so calls do not sit unsynced without you noticing.", "action")}
        {perm_card(P_BATTERY, "Background activity", "Samsung power saving can stop the app from uploading while the screen is off.", "settings")}

      </div>
      <div style="padding:16px; display:flex; flex-direction:column; gap:10px; background:var(--surface); border-top:1px solid var(--outline);">
        <div class="btn fill">Continue</div>
        <div style="text-align:center; font-size:12px; color:var(--muted);">Change any of these later in Settings &rsaquo; Permissions</div>
      </div>"""

# --------------------------------------------------------------- Call History
def call_row(icon, tint, color, name, meta, time, status, dim=False):
    name_color = "color:var(--muted);" if dim else ""
    if status == "ok":
        mark = ic(P_CHECK, 14, "var(--green)", width="2.6")
    elif status == "up":
        mark = ic(P_UP, 14, "var(--brand)", width="2")
    elif status == "wait":
        mark = ic(P_CLOCK, 14, "var(--amber)", width="2")
    else:
        mark = ic(P_ALERT, 14, "var(--red)", width="2")
    return (f'<div class="row">'
            f'<div class="ico" style="background:{tint};">{ic(icon, 18, color)}</div>'
            f'<div style="flex:1; min-width:0;">'
            f'<div style="font-size:15px; font-weight:600; {name_color}">{name}</div>'
            f'<div class="num" style="font-size:13px; color:var(--muted);">{meta}</div></div>'
            f'<div style="display:flex; flex-direction:column; align-items:flex-end; gap:5px;">'
            f'<span class="num" style="font-size:12px; color:var(--muted);">{time}</span>{mark}</div>'
            f'</div>')

SEP = '<div class="sep" style="margin-left:64px;"></div>'

P_SEARCH = '<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/>'
P_FILTER = '<path d="M4 6h16"/><path d="M7 12h10"/><path d="M10 18h4"/>'
_ch_actions = (
    '<div style="display:flex; gap:6px;">'
    + '<div class="ico" style="width:36px;height:36px;background:var(--tint);">' + ic(P_SEARCH, 18) + '</div>'
    + '<div class="ico" style="width:36px;height:36px;background:var(--tint);">' + ic(P_FILTER, 18) + '</div>'
    + '</div>'
)

SCREENS["CallHistory"] = f"""      <div class="safe"></div>
      {appbar("Calls", None, False, _ch_actions)}
      <div class="scroll" style="gap:12px;">

        <div style="display:flex; gap:8px;">
          <div class="chip on">All</div>
          <div class="chip">Incoming</div>
          <div class="chip">Outgoing</div>
          <div class="chip">Missed</div>
        </div>

        <div class="sect" style="margin-top:2px;">Today</div>
        <div class="card" style="overflow:hidden;">
          {call_row(P_IN, "var(--greent)", "var(--green)", "Ramesh Kumar", "+91 98&bull;&bull;&bull; &bull;&bull;210 &middot; 4m 32s", "14:32", "ok")}
          {SEP}
          {call_row(P_OUT, "var(--brandc)", "var(--brand)", "Priya Nair", "+91 90&bull;&bull;&bull; &bull;&bull;446 &middot; 2m 18s", "13:47", "up")}
          {SEP}
          {call_row(P_MISS, "var(--redt)", "var(--red)", "Unknown number", "+91 74&bull;&bull;&bull; &bull;&bull;538 &middot; Missed", "13:02", "ok", dim=True)}
          {SEP}
          {call_row(P_IN, "var(--greent)", "var(--green)", "Private number", "Number withheld &middot; 1m 05s", "11:20", "wait", dim=True)}
        </div>

        <div class="sect" style="margin-top:4px;">Yesterday</div>
        <div class="card" style="overflow:hidden;">
          {call_row(P_OUT, "var(--brandc)", "var(--brand)", "Anil Desai", "+91 99&bull;&bull;&bull; &bull;&bull;173 &middot; 8m 41s", "17:55", "fail")}
          {SEP}
          {call_row(P_IN, "var(--greent)", "var(--green)", "Meera Iyer", "+91 87&bull;&bull;&bull; &bull;&bull;902 &middot; 3m 12s", "16:10", "ok")}
          {SEP}
          {call_row(P_MISS, "var(--redt)", "var(--red)", "Sales desk", "+91 44&bull;&bull;&bull; &bull;&bull;800 &middot; Missed", "15:38", "ok")}
        </div>

      </div>
      {navbar("Calls")}"""

# ---------------------------------------------------------------- Call Detail
def tl_step(label, time, note, color, last=False):
    tail = "" if last else '<div style="width:2px; flex:1; background:var(--outline); margin:4px 0;"></div>'
    return (f'<div style="display:flex; gap:14px;">'
            f'<div style="display:flex; flex-direction:column; align-items:center; width:12px;">'
            f'<div style="width:10px; height:10px; border-radius:5px; background:{color}; flex:none; margin-top:5px;"></div>{tail}</div>'
            f'<div style="flex:1; padding-bottom:{"0" if last else "18px"};">'
            f'<div style="display:flex; justify-content:space-between; align-items:baseline;">'
            f'<span style="font-size:14px; font-weight:600;">{label}</span>'
            f'<span class="num" style="font-size:13px; color:var(--muted);">{time}</span></div>'
            f'<div style="font-size:12.5px; color:var(--muted); margin-top:2px;">{note}</div>'
            f'</div></div>')

SCREENS["CallDetail"] = f"""      <div class="safe"></div>
      {appbar("Call detail", None, True)}
      <div class="scroll">

        <div class="card" style="padding:18px; display:flex; gap:14px; align-items:center;">
          <div style="width:52px; height:52px; border-radius:26px; background:var(--brandc); color:var(--brand);
                      display:flex; align-items:center; justify-content:center; font-size:19px; font-weight:600; flex:none;">RK</div>
          <div style="flex:1; min-width:0;">
            <div style="font-size:19px; font-weight:600; letter-spacing:-0.01em;">Ramesh Kumar</div>
            <div class="num" style="font-size:14px; color:var(--muted); margin-top:2px;">+91 98&bull;&bull;&bull; &bull;&bull;210</div>
            <div style="display:flex; gap:6px; margin-top:10px;">
              <div class="pill" style="background:var(--greent); color:var(--green);">{ic(P_IN, 13, "var(--green)", width="2.2")}Incoming</div>
              <div class="pill" style="background:var(--tint); color:var(--muted);">Answered</div>
            </div>
          </div>
        </div>

        <div class="card" style="padding:18px;">
          <div class="sect" style="margin-bottom:16px;">Timeline</div>
          {tl_step("Started", "14:32:08", "Ringing", "var(--muted)")}
          {tl_step("Answered", "14:32:14", "After 6 seconds", "var(--green)")}
          {tl_step("Ended", "14:36:40", "Ended by remote party", "var(--muted)", last=True)}
          <div class="sep" style="margin:16px 0;"></div>
          <div style="display:flex; justify-content:space-between; align-items:center;">
            <span style="font-size:14px; color:var(--muted);">Duration</span>
            <span class="num" style="font-size:22px; font-weight:700; letter-spacing:-0.02em;">4m 32s</span>
          </div>
        </div>

        <div class="card" style="padding:14px 16px; display:flex; align-items:center; gap:12px;">
          <div class="ico" style="background:var(--tint);">{ic(P_SIM, 20, "var(--muted)")}</div>
          <div style="flex:1;">
            <div style="font-size:14px; font-weight:600;">SIM 1 &middot; Airtel</div>
            <div style="font-size:12.5px; color:var(--muted);">Subscription 1</div>
          </div>
        </div>

        <div class="card" style="overflow:hidden;">
          <div style="padding:14px 16px; display:flex; gap:12px; align-items:center;">
            <div class="ico" style="background:var(--greent);">{ic(P_PLAY, 20, "var(--green)")}</div>
            <div style="flex:1; min-width:0;">
              <div style="font-size:14px; font-weight:600;">Recording</div>
              <div class="num" style="font-size:12.5px; color:var(--muted);">4m 32s &middot; 1.8 MB &middot; m4a</div>
            </div>
            <div class="pill" style="background:var(--greent); color:var(--green);">Matched</div>
          </div>
          <div style="padding:0 16px 14px; display:flex; align-items:center; gap:12px;">
            <div style="flex:1; height:4px; border-radius:2px; background:var(--tint); overflow:hidden;">
              <div style="width:34%; height:100%; background:var(--brand);"></div>
            </div>
            <span class="num" style="font-size:12px; color:var(--muted);">01:32 / 04:32</span>
          </div>
          <div class="sep"></div>
          <div style="padding:12px 16px; display:flex; gap:10px; align-items:flex-start;">
            {ic(P_INFO, 16, "var(--muted)")}
            <div style="flex:1; font-size:12px; line-height:1.55; color:var(--muted);">
              Captured by the phone&rsquo;s own call recorder, then matched to this call on
              duration and timing. <span class="num">99.6% confidence</span>.
            </div>
          </div>
        </div>

        <div class="card" style="padding:14px 16px; display:flex; align-items:center; gap:12px;">
          <div class="ico" style="background:var(--greent);">{ic(P_CHECK, 20, "var(--green)", width="2.4")}</div>
          <div style="flex:1;">
            <div style="font-size:14px; font-weight:600;">Uploaded</div>
            <div style="font-size:12.5px; color:var(--muted);">2 minutes ago &middot; confirmed by server</div>
          </div>
        </div>

      </div>"""

# ----------------------------------------------------------------------- Sync
def sync_row(icon, color, tint, label, count, note, last=False):
    sep = "" if last else '<div class="sep" style="margin-left:56px;"></div>'
    return (f'<div style="display:flex; align-items:center; gap:12px; padding:13px 14px;">'
            f'<div class="ico" style="width:32px; height:32px; border-radius:8px; background:{tint};">{ic(icon, 17, color, width="2")}</div>'
            f'<div style="flex:1;"><div style="font-size:14.5px; font-weight:600;">{label}</div>'
            f'<div style="font-size:12.5px; color:var(--muted);">{note}</div></div>'
            f'<span class="num" style="font-size:19px; font-weight:700; letter-spacing:-0.02em; color:{color};">{count}</span>'
            f'</div>{sep}')

def meta_row(icon, label, value, color="var(--muted)", last=False):
    sep = "" if last else '<div class="sep" style="margin-left:44px;"></div>'
    return (f'<div style="display:flex; align-items:center; gap:12px; padding:13px 14px;">'
            f'{ic(icon, 18, "var(--muted)")}'
            f'<span style="flex:1; font-size:14px;">{label}</span>'
            f'<span style="font-size:13.5px; font-weight:600; color:{color};">{value}</span>'
            f'</div>{sep}')

SCREENS["SyncStatus"] = f"""      <div class="safe"></div>
      {appbar("Sync", None, False)}
      <div class="scroll">

        <div class="card" style="padding:18px; display:flex; gap:14px; align-items:center; border-color:var(--amber);">
          <div class="ico" style="width:44px; height:44px; background:var(--ambert);">{ic(P_UP, 22, "var(--amber)", width="2")}</div>
          <div style="flex:1;">
            <div style="font-size:16px; font-weight:600;">Syncing 3 of 8</div>
            <div style="font-size:13px; color:var(--muted); margin-top:2px;">Started 12 seconds ago</div>
          </div>
        </div>

        <div style="height:6px; border-radius:3px; background:var(--tint); overflow:hidden; margin-top:-4px;">
          <div style="width:38%; height:100%; background:var(--brand);"></div>
        </div>

        <div class="card" style="overflow:hidden;">
          {sync_row(P_CHECK, "var(--green)", "var(--greent)", "Uploaded", "128", "Confirmed by the server")}
          {sync_row(P_UP, "var(--brand)", "var(--brandc)", "Uploading", "3", "In flight now")}
          {sync_row(P_CLOCK, "var(--amber)", "var(--ambert)", "Waiting", "5", "Queued for the next window")}
          {sync_row(P_ALERT, "var(--red)", "var(--redt)", "Failed", "1", "Retried 4 times", last=True)}
        </div>

        <div class="btn out">{ic(P_SYNC, 18, "var(--brand)")}Retry failed uploads</div>

        <div class="sect" style="margin-top:4px;">Recordings</div>
        <div class="card" style="overflow:hidden;">
          {sync_row(P_CHECK, "var(--green)", "var(--greent)", "Matched", "112", "Associated with a call")}
          {sync_row(P_REVIEW, "var(--amber)", "var(--ambert)", "Needs review", "2", "Match was not clear enough")}
          {sync_row(P_MIC_OFF, "var(--muted)", "var(--tint)", "No recording", "31", "Missed calls and unrecorded calls", last=True)}
        </div>

        <div class="sect" style="margin-top:4px;">Status</div>
        <div class="card" style="overflow:hidden;">
          {meta_row(P_CLOCK, "Last successful sync", "2 min ago")}
          {meta_row(P_WIFI, "Network", "Wi-Fi", "var(--green)")}
          {meta_row(P_DB, "Server", "Reachable", "var(--green)")}
          {meta_row(P_DEVICE, "Queue size", "9 records", last=True)}
        </div>

        <p style="margin:4px 2px 0; font-size:12.5px; line-height:1.55; color:var(--muted);">
          Calls are saved on the device the moment they end. Nothing is lost while offline &mdash;
          the queue drains when a connection returns.
        </p>

      </div>
      {navbar("Sync")}"""

# ------------------------------------------------------------------- Settings
def set_row(icon, label, value="", last=False, danger=False):
    sep = "" if last else '<div class="sep" style="margin-left:52px;"></div>'
    color = "var(--red)" if danger else "var(--text)"
    icon_color = "var(--red)" if danger else "var(--muted)"
    trail = (f'<span style="font-size:13.5px; color:var(--muted);">{value}</span>' if value else "")
    return (f'<div style="display:flex; align-items:center; gap:14px; padding:14px;">'
            f'{ic(icon, 19, icon_color)}'
            f'<span style="flex:1; font-size:15px; color:{color};">{label}</span>'
            f'{trail}{ic(P_CHEV, 16, "var(--muted)", width="2")}</div>{sep}')

SCREENS["Settings"] = f"""      <div class="safe"></div>
      {appbar("Settings", None, False)}
      <div class="scroll">

        <div class="card" style="padding:16px; display:flex; gap:14px; align-items:center;">
          <div style="width:48px; height:48px; border-radius:24px; background:var(--brand); color:#FFFFFF;
                      display:flex; align-items:center; justify-content:center; font-size:17px; font-weight:600; flex:none;">SV</div>
          <div style="flex:1; min-width:0;">
            <div style="font-size:16px; font-weight:600;">Suresh Venkat</div>
            <div class="num" style="font-size:13px; color:var(--muted); margin-top:2px;">EMP-4471 &middot; Dealing desk</div>
          </div>
        </div>

        <div class="card" style="padding:14px 16px; display:flex; gap:12px; align-items:center;">
          <div class="ico" style="background:var(--greent);">{ic(P_DEVICE, 20, "var(--green)")}</div>
          <div style="flex:1; min-width:0;">
            <div style="font-size:14px; font-weight:600;">Samsung SM-M356B</div>
            <div style="font-size:12.5px; color:var(--muted);">Registered 12 Aug &middot; Android 16</div>
          </div>
          <div class="pill" style="background:var(--greent); color:var(--green);">Active</div>
        </div>

        <div class="sect" style="margin-top:4px;">Tracking</div>
        <div class="card" style="overflow:hidden;">
          {set_row(P_SHIELD, "Permissions", "3 of 4")}
          {set_row(P_PLAY, "Recording ingestion", "On")}
          {set_row(P_SYNC, "Sync &amp; upload", "Wi-Fi + mobile", last=True)}
        </div>

        <div class="sect" style="margin-top:4px;">Data</div>
        <div class="card" style="overflow:hidden;">
          {set_row(P_DB, "Storage used", "4.2 MB")}
          {set_row(P_WIFI, "Network usage", "18 MB this month")}
          {set_row(P_LOCK, "Privacy", "", last=True)}
        </div>

        <div class="sect" style="margin-top:4px;">Actions</div>
        <div class="card" style="overflow:hidden;">
          {set_row(P_SYNC, "Sync now")}
          {set_row(P_ALERT, "Retry failed uploads", "1")}
          {set_row(P_OUTLINK, "Open app permissions", "", last=True)}
        </div>

        <div class="card" style="overflow:hidden; margin-top:4px;">
          {set_row(P_USER, "Sign out", "", last=True, danger=True)}
        </div>

        <div style="text-align:center; font-size:12px; color:var(--muted); padding:8px 0 4px;">
          Call Tracker 1.0.0 &middot; Internal build
        </div>

      </div>
      {navbar("Settings")}"""


for name, body in SCREENS.items():
    out = PAGE.format(style=STYLE, body=body)
    path = f"{name}.dc.html"
    io.open(path, "w", encoding="utf-8", newline="\n").write(out)
    print(f"wrote {path} ({len(out)} chars)")
