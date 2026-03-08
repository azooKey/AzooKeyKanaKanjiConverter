import Foundation

extension AncoSession {
    package init(
        defaultDictionaryRequestOptions requestOptions: ConvertRequestOptions,
        preloadDictionary: Bool = false,
        inputStyle: InputStyle = .direct,
        displayTopN: Int = 1,
        preset: String? = nil,
        debugPossibleNexts: Bool = false,
        userDictionaryItems: [InputUserDictionaryItem] = []
    ) {
        self.init(
            converter: .withDefaultDictionary(preloadDictionary: preloadDictionary),
            requestOptions: requestOptions,
            inputStyle: inputStyle,
            displayTopN: displayTopN,
            preset: preset,
            debugPossibleNexts: debugPossibleNexts,
            userDictionaryItems: userDictionaryItems
        )
    }
}
