// The persistence/sync-transport layer moved to the platform-neutral
// AndeyeTTStore target (iOS shares it). Re-export so AndeyeTTMac's existing
// importers (the app, checks, integration runner, the pro repo) keep
// compiling unchanged.
@_exported import AndeyeTTStore
