import SwiftUI

/// Command Line Tools on this SDK do not ship SwiftUIMacros, so `@State` cannot expand.
/// This wrapper uses the underlying `State` type directly.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }

    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State(initialValue: wrappedValue)
    }

    init(initialValue: Value) {
        storage = SwiftUI.State(initialValue: initialValue)
    }
}