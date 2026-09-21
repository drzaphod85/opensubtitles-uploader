import SwiftUI

/// `@State` in recent SDKs is a macro backed by the `SwiftUIMacros` compiler plugin, which is only
/// shipped with Xcode.app. This typealias refers to the underlying property wrapper directly so
/// the project also builds with the Command Line Tools (`swift build`). It behaves exactly like `@State`.
typealias ViewState<Value> = SwiftUICore.State<Value>
