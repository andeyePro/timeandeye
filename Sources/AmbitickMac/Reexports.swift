// The persistence/sync-transport layer moved to the platform-neutral
// AmbitickStore target (iOS shares it). Re-export so AmbitickMac's existing
// importers (the app, checks, integration runner, the pro repo) keep
// compiling unchanged.
@_exported import AmbitickStore
