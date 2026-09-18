import SwiftUI
import Combine

/// `@State` 的替代实现。
///
/// 背景：Command Line Tools 自带的 macOS SDK 已经把 SwiftUI 的 `@State`
/// 改成宏（SwiftUIMacros.StateMacro），而宏的实现在只随完整 Xcode 分发，
/// 所以纯 CLT 环境下无法使用 `@State`。
/// 这里基于可用的 `@StateObject` 实现一份等价物，用法与 `@State` 完全一致。
final class StateBox<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

@propertyWrapper
struct LocalState<T>: DynamicProperty {
    @StateObject private var box: StateBox<T>

    init(wrappedValue: T) {
        _box = StateObject(wrappedValue: StateBox(wrappedValue))
    }

    var wrappedValue: T {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<T> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
