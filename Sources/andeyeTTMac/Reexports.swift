// The persistence/sync-transport layer moved to the platform-neutral
// andeyeTTStore target (iOS shares it). Re-export so andeyeTTMac's existing
// importers (the app, checks, integration runner, the pro repo) keep
// compiling unchanged.
@_exported import andeyeTTStore
