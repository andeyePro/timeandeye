---
title: Data, sync and safety
description: Where your data lives, what syncs, and crash safety.
---

- Your time is journalled to a local SQLite database; that is the source of
  truth. Confident OP tasks push to your OpenProject automatically (above a
  certainty threshold you set).
- The OP API key is stored in an owner-only (0600) file in the app support
  folder, not the Keychain.
- A crash-safe checkpoint means a hard crash loses at most a short tail of the
  current session.
