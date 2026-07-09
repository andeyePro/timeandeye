// The persistence/sync-transport layer moved to the platform-neutral
// timeandeyeStore target (iOS shares it). Re-export so timeandeyeMac's existing
// importers (the app, checks, integration runner, the pro repo) keep
// compiling unchanged.
@_exported import timeandeyeStore
