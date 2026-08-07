#if !canImport(Combine)

/// Minimal stand-ins for `ObservableObject`/`@Published` so `PhoneController`
/// compiles unchanged where Combine doesn't exist — the in-container Linux
/// Swift 6.1 toolchain used by `timeandeyeChecks` (see CLAUDE.md "Build,
/// check, run"). `public` only because `PhoneController`'s own `@Published`
/// properties are public and a property wrapper's access level can't be
/// narrower than the property it backs — it never leaks into the Apple build
/// surface because the WHOLE FILE compiles out there (Apple platforms always
/// `canImport(Combine)`), which is what actually keeps it from shadowing the
/// real Combine conformance the iOS app (`ios/Sources/`) relies on via
/// `@StateObject`/`@ObservedObject`/`$controller.settings`. This container
/// cannot compile the iOS app itself to double-check that, so treat
/// "compiles out by construction" as the guarantee, not a tested one.
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}

#endif
