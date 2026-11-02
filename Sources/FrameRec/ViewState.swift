import SwiftUI

// An explicit type alias selects the property wrapper rather than the SDK 27
// @State macro, whose compiler plugin is not shipped in Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
