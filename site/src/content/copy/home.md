---
# ------------------------------------------------------------------
# andeye landing page copy (src/pages/index.astro)
#
# Edit the strings below freely - no code required. index.astro reads
# this file once, server-side, via `getEntry('copy', 'home')`, and
# interpolates every field into the page. Fields ending in `_html`
# (h2_html, intro_html) are rendered as raw HTML on purpose - they carry
# an inline tag (<br>, a coloured <span>) - so keep any markup in those
# fields balanced.
#
# NOT here, and deliberately so: the demo's simulated inbox/browser
# content (Sarah Coleman, Priya, the Anthropic newsletter, the research/
# client/kitten tabs, mail bodies, the "template" HTML for each) - those
# strings are coupled to the demo's internal state keys and stay
# hardcoded in index.astro's inline script.
#
# A few fields below only ever render on hover/click, never into the
# static HTML: flow.nodes.*.body/manual_href/manual_label (the flow
# section's per-node detail text and manual link) and
# tiers.pro_body/pro_cta_label (the Community/Pro "pro" tab). Editing
# them here DOES take effect - they're passed into the page through a
# small `<script define:vars={{ COPY }}>` block that the main inline
# script reads from - there's just no static fallback to eyeball; you
# have to click/hover the section to see the result.
# ------------------------------------------------------------------

hero:
  eyebrow: "andeye · automatic time tracking for macOS"
  h1:
    - "andeye watches."
    - "You just work."
  lede: "A menu-bar tracker that attributes your time to tasks by itself – on your Mac, never phoning home."
  cta_star_label: "Star on GitHub"
  cta_waitlist_label: "Join the waitlist"
  # CTA-row subtext: sub_default shows at rest, sub_tech/sub_app on hover
  # of the two buttons above (read by the inline demo script via COPY).
  sub_default: "Free and open source today. A ready-to-download app is on the way."
  sub_tech: "It's free and open source. Clone the repo and build it on your Mac today – every last line of it."
  sub_app: "Not a coder? No problem. Join the list and we'll email you the moment andeye is a normal app you just download and open – nothing to build, nothing to set up."
  fineprint: "macOS 14+ · free and open source · build from source today"

demo:
  # server-rendered fallback for first paint / no-JS; the script overwrites
  # it once at load with the visitor's real day/time - that "It's <day>,
  # <time>" FORMAT is code, not copy, so only edit the example values here.
  heading_fallback: "It’s Tuesday, 9:41"
  intro_html: 'Click around like it’s your desk – answer Sarah, settle the accountant’s question, sneak a kitten. The eye follows, winks when you switch, and its tint is its confidence: <span class="cert-gradient">red when unsure, green when sure</span>.'
  drive_idle: "Click an email or a tab – watch andeye follow you"
  drive_active: "andeye is following you – keep clicking around"
  caption: "Those two boxes are andeye’s own timeline and time pie, filling in live as you click. At the end of a real day, the billable slice is your invoice, and you never wrote anything down."

flow:
  eyebrow: "How it works"
  h2: "Your timesheet writes itself in three moves"
  default_line: "It reads the room, so every minute finds its task, and completes your timesheets for you."
  nodes:
    observe:
      label: "observe"
      body: "andeye watches your active window, tab and app as you work – and who a piece of mail is from. No screenshots, no keystrokes. It all stays on your Mac."
      manual_href: "/manual/auto-tracking-and-attribution/"
      manual_label: "more in the manual →"
    attribute:
      label: "attribute"
      body: "Each minute lands on a task with a certainty score. 94% sure that thread was the Coleman retainer; not at all sure the newsletter was work – and it says so. A kitten break is a break. It never rounds up."
      manual_href: "/manual/auto-tracking-and-attribution/"
      manual_label: "more in the manual →"
    post:
      label: "post"
      body: "The hours you approve post to your own tools – OpenProject today, Xero (and others) via Pro later. You keep the final say on every entry, and it only goes where you already keep your work."
      manual_href: "/manual/data-sync-and-safety/"
      manual_label: "more in the manual →"

privacy:
  eyebrow: "Privacy"
  h2_html: "It watches for you.<br>Not on you."
  lede: "Most tracking software points the camera at the worker and hands the film to someone else. andeye inverts that: the eye answers to the person it watches, and to no one else."
  claims:
    - head: "Your day stays on your Mac."
      body: "Observation, attribution and learning all run on-device. There is no server, no account, no telemetry."
    - head: "Only what you approve ever leaves."
      body: "The only thing that ever leaves is a finished time entry you approve, sent to your own OpenProject – or your Xero (and others), later. Never to us."
    - head: "Learning stays local."
      body: "The model of how you work is built on your Mac and lives on your Mac. It gets smarter about you without anyone else getting smarter about you."
    - head: "Your rules, on your disk."
      body: 'Pin rules like “mail from this client goes to this project” are files on your Mac. Read them, edit them, delete them.'

# "Light by design" - between Privacy and Community/Pro. No numbers, no
# competitor names, no CO2 quantities: keep it honest and unquantified.
light:
  eyebrow: "Light by design"
  h2: "Tracking that doesn’t cost the earth"
  lede: "Some trackers send your screen to a cloud AI every few minutes to guess what you’re doing. andeye doesn’t. Attribution is a handful of rules that run on your Mac in less time than a blink – no server anywhere, nothing kept warm in a datacenter, no AI inference ticking away in the background."
  line2: "The only thing it spends is a whisper of your Mac’s attention – and it pays that back with the timesheet you never have to write."

tiers:
  eyebrow: "Community & Pro"
  h2: "Open where it matters"
  tracker_label: "Tracker – free forever"
  tracker_body: "The macOS app is open source under AGPL-3.0. Clone the repo and build it today – observation, attribution, certainty scores and the OpenProject connector, all included."
  tracker_cta_label: "Star on GitHub →"
  pro_label: "andeyePro"
  pro_body: "andeyePro adds the paid extras: Xero (and others), plus an iPhone companion. The tracker itself stays free, local and yours."
  pro_cta_label: "Join the waitlist →"

footer:
  company_line: "© andeye Ltd · SC665704 · Scotland"
---
