---
title: Auto-tracking and attribution
description: How andeye decides which task your time belongs to, and how to see why.
---

Every time the front window, app or tab changes, andeye scores the candidate
tasks and tracks the best one. Sources, strongest first:

1. An explicit **pin** (always 100%).
2. An **OpenProject task URL** in the browser tab (or a work-package id in the
   window title).
3. A **just-opened OP task** priming the next surface you work on.
4. A **remembered surface** from a past correction.
5. **Learned associations** (what you've confirmed before) plus status/recency
   priors.

A brief flit to another window does not immediately re-file your time: a switch
only becomes its own slice once you've held it past the Switch Buffer (and never
below one displayed minute), so glancing at Slack mid-task does not fragment your
timeline.

## Why was this tracked as X?

Open the Time window's timeline, click a slice, then click a window in its detail
strip. The pane explains the decision: the source (pinned / OP URL / remembered /
learned, etc.), the candidate tasks with each score split into its learned and
prior parts, and the exact signal features the learner keys on (app, title
words, URL host). To fix future tracking, move that window to the right task in
the strip below - that teaches the learner, so the window files correctly next
time.
