---
title: Pinning
description: Locking a window, site or app to a task at 100%, by component, expression, or AI-assisted rule.
---

A pin says "this surface is ALWAYS this task" at 100%, overriding everything
else. Click the pin button in the popover to open the pin editor.

- **Components** (the default) - the captured identity is shown broad to narrow
  (host then path for a URL; app then window-name parts for an app). Blue parts
  are pinned, grey are not. Click a part, or use ← / → , to widen or narrow the
  scope. App pins default to app + window name and match on PRESENCE, so a pinned
  terminal window keeps matching even when the terminal prepends its mode to the
  title.
- **Expression** (via the hamburger menu) - a typed boolean rule. Fields: `app`,
  `title`, `url`, `sender` (alias `from`), `subject`, `any`. Operators: `is`,
  `contains`, `starts with`, `matches` (regex). Logic: `and`, `or`, `not`,
  parentheses. Negation reads naturally too (`app is not "Ghostty"`, `url does
  not contain "github"`). `from`/`sender` match the email correspondents and
  `subject` the email subject (so `from contains "harborlane.example"` pins all
  mail to/from that company); `any` – and bare text with no field – searches
  every field including the correspondents and subject. A parse error shows in
  full above the buttons.
- **AI** (via the hamburger menu) - for a window whose own app/title/url don't
  obviously say which task it is. It builds a prompt from the captured fields plus
  an editable guidance box (pre-seeded to prefer a stable pattern over a volatile
  title), copies it to the clipboard for you to paste into any AI, and takes the
  reply back: paste the rule it returns and ↵ turns it into an ordinary, editable
  Expression rule (or shows a parse error). When a typed Expression won't parse,
  a **Fix with AI** button hands the failed rule straight to this mode.
- **Enter** pins. The **✕** (or esc) means "no pin here": it unpins when you
  opened on an existing pin, or drops a never-saved draft.
